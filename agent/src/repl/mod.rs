//! repl.rs —— 会话与交互循环（`src/agentmode.cpp` 的 `AgentSession` + `runAgentRepl` 镜像）
//!
//! 三件事：
//!   1. **一轮任务**（`run_turn`）：任务开始前整块裁剪旧历史 → `begin_task()` 清
//!      任务内预算 → `runner(task).history(历史).max_turns(预算)` 走流式面
//!      （`.stream()`，缺省）或阻塞面（`.run()`，`--llm-no-stream`）。**模型输出由
//!      本层打到 stdout**：流式逐 delta（`out!` 逐条 flush），阻塞整段。成功把本轮
//!      新消息（含按位物化的图片后注）并进历史；失败**回滚到钩子记下的边界**（已完整
//!      跑完的轮留在历史里）——不留半截 tool_calls 序列，会话可以继续下一条。
//!      两条面共用 rig 的 drive loop 与 AgentHook：墙钟/单轮上限/回滚边界一致。
//!   2. **审计**：model 行由本层写（turn/ok/status/error/ms/req+resp 字节/attempts/token，
//!      数据来自模型装饰器记的逐次调用记录）；session 行在 `Session::new`/
//!      `write_session_end`。**tool 行不在这里**——工具全经后端帧，后端
//!      `mybot --mcp-backend` 自己落（见 audit.rs 模块头）。
//!   3. **交互循环**（`run_repl`）：提示符、内置命令、单轮失败不结束会话；取消
//!      （SIGINT/SIGTERM）与 C++ 同口径——循环退出、会话照常收尾。
//!
//! 如实差异（记录在案）：
//!   * `PromptResponse.messages` 只含**本轮**新消息（rig 的 `new_messages`，不含传入
//!     的 chat_history）→ 这里拼成「旧历史 + 本轮」。
//!   * 图片注入只作用于**发出去的请求**（模型装饰器按请求重建的时机注入），rig 的
//!     transcript 里没有它 → 任务结束（或失败）后由 `hook::materialize` 按记录的
//!     位置插回会话历史，与 C++ 的「tool 消息之后另起一条 user 图片消息」同序。
//!   * `/hardware` / `/scripts` / `/sql` 在 C++ 是**本地**直读机器人与 `runSqlCommand`；
//!     本进程不持有硬件，一律经工具（`list_hardware` / `list_action_scripts` /
//!     `apply_sql` / `query_sql`）——所以「后端没给这个工具」时会明确报出缺哪个开关，
//!     不假装执行过。
//!   * 流式下失败发生在文本已经打出一部分之后时，已打出的文本**不会收回**（终端上
//!     留着），stderr 再报错误；历史回滚口径不变（半截轮不进历史）。C++ 是整段
//!     输出，没有这种「半句话」形态。思维链 delta 不打印。

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use futures::StreamExt;
use rig_agent::agent::{AgentRunner, MultiTurnStreamItem, PromptResponse, StreamingError};
use rig_agent::completion::{Message, PromptError};
use rig_core::streaming::StreamedAssistantContent;

mod slash;

use crate::audit::{AuditLog, ModelEntry, SessionEntry, ToolEntry};
use crate::bridge::{Bridge, ToolOutcome};
use crate::config::Config;
use crate::history::ConversationHistory;
use crate::hook::{self, CallRecord, HookState, LocalToolRecord};
use crate::linein::{LineInput, LineRead};
use crate::out::{errln, out, outln};
use crate::prompt::PromptMaterial;
use crate::provider::Backend;
use crate::record::RecordStore;
use crate::session::SessionFileWriter;
use crate::summary;

/// `PromptError` → 操作者可见文本：剥掉 rig 的枚举前缀（`PromptCancelled: `）——
/// 钩子给的 reason 正是要让操作者看到的那句话（「执行被中断」「达到单任务墙钟预算
/// （N 秒）…」），C++ 侧的异常文本同样没有前缀。
fn format_prompt_error(e: PromptError) -> String {
    strip_cancel_prefix(e.to_string())
}

fn strip_cancel_prefix(s: String) -> String {
    match s.strip_prefix("PromptCancelled: ") {
        Some(rest) => rest.to_string(),
        None => s,
    }
}

/// `StreamingError` → 操作者可见文本：与阻塞面同形。rig 的流式错误多包一层
/// `PromptError: `（`PromptError: PromptCancelled: 执行被中断`），剥掉后余下的正是
/// 阻塞面 `format_prompt_error` 看到的那一串；`CompletionError: …` 形态两面一致。
fn format_stream_error(e: StreamingError) -> String {
    let s = e.to_string();
    let s = match s.strip_prefix("PromptError: ") {
        Some(rest) => rest.to_string(),
        None => s,
    };
    strip_cancel_prefix(s)
}

/// REPL 单行输入上限（与 C++ `kMaxReplInputBytes` 逐值对齐）：超限**响亮拒绝**并
/// 提示，不静默截断（getline/read_line 本身无限制）。
pub const K_MAX_REPL_INPUT_BYTES: usize = 10 << 20;

/// 「思考中…」进度动画（交互 REPL 专用）。
///
/// 两处防线（2026-09-24 复查，取代仓促版本）：
///   * **写出**经 `libc::write` 直写 fd 2——与 out.rs 的检查式口径同源：
///     `eprint!` 对 EPIPE/ENOSPC 直接 panic（退出码 101、审计收尾丢失），
///     这正是审计 H2 修掉的 panic 面，动画不许把它带回来。写失败即丢一帧。
///   * **停止**经 oneshot 唤醒 + await JoinHandle 后再清行——裸 `abort()` 后
///     立即清行有竞态：多线程 runtime 下动画任务可能已被唤醒、正要落笔，
///     清行先执行就会留下一格残影。置停 → join（最后一帧写完）→ 清行是全序。
struct Progress {
    stop: tokio::sync::oneshot::Sender<()>,
    handle: tokio::task::JoinHandle<()>,
}

impl Progress {
    /// 清行序列：与最长一帧（"思考中... "）同宽，回到行首。
    const CLEAR: &str = "\r                \r";

    fn start() -> Self {
        let (stop, mut stopped) = tokio::sync::oneshot::channel::<()>();
        let handle = tokio::spawn(async move {
            let mut dots = 0usize;
            loop {
                let frame = format!("\r思考中{} ", ".".repeat(dots));
                // SAFETY: 对 fd 2 的单次 write 是 async-signal-safe 级原语；失败即丢帧。
                unsafe {
                    libc::write(2, frame.as_ptr().cast(), frame.len());
                }
                dots = (dots + 1) % 4;
                tokio::select! {
                    _ = &mut stopped => break,
                    _ = tokio::time::sleep(std::time::Duration::from_millis(500)) => {}
                }
            }
        });
        Self { stop, handle }
    }

    /// 停止并清行（顺序保证见类型注释）。
    async fn finish(self) {
        let _ = self.stop.send(());
        let _ = self.handle.await;
        // SAFETY: 同上。
        unsafe {
            libc::write(2, Self::CLEAR.as_ptr().cast(), Self::CLEAR.len());
        }
    }
}

/// 会话统计（`/status` 用）：只记真实发生过的数字，不推算。
#[derive(Debug, Default, Clone)]
pub struct SessionStats {
    pub model_turns: u64,
    pub model_ms: u128,
    pub last_prompt_tokens: Option<i64>,
    pub last_completion_tokens: Option<i64>,
}

/// 审计/统计面（拆自 Session，2026-10-01）：会话统计 + 审计落行。Session 此前
/// 11 个字段里 audit/stats/started 三个只服务「记账与落行」这一件事，抽成独立
/// 结构后 Session 只剩真实的装配输入。
pub struct SessionAudit {
    audit: Option<AuditLog>,
    stats: SessionStats,
    started: Instant,
}

impl SessionAudit {
    /// 建审计面并**立刻**写审计的 session start 行（driver/model/接入点/密钥来源；
    /// 接入点在 audit 侧去凭据）。写不出 start 是审计自己的告警，不阻断会话。
    pub fn new(cfg: &Config, mut audit: Option<AuditLog>, resumed: bool) -> Self {
        if let Some(a) = audit.as_mut() {
            a.write_session(&SessionEntry {
                status: "start".to_string(),
                driver: cfg.driver.clone(),
                model: cfg.model.clone(),
                endpoint: cfg.endpoint.clone(),
                api_key_source: cfg.api_key_source.to_string(),
                resumed,
                ..Default::default()
            });
        }
        Self {
            audit,
            stats: SessionStats::default(),
            started: Instant::now(),
        }
    }

    /// 会话结束行（`end` / `error`）。C++ 的 `writeSessionEnd` 同契约：失败会话也
    /// 必须留一条——「这次会话怎么结束的」是复盘的第一句话。
    pub fn write_session_end(&mut self, status: &str, error: &str) {
        let ms = self.started.elapsed().as_millis().min(i64::MAX as u128) as i64;
        if let Some(a) = self.audit.as_mut() {
            a.write_session(&SessionEntry {
                status: status.to_string(),
                error: error.to_string(),
                ms,
                ..Default::default()
            });
        }
    }

    /// 把逐次模型调用的观测值落成审计 model 行 + 会话统计。turn 与 status 由调用方
    /// 按轮次语义给：普通轮 = `turn-1` / `ok|error`（rig 从 1 数起，C++ 的 turn 从 0
    /// 数起——两侧审计口径必须一致）；摘要轮 = `-1` / `summary|summary_error`。
    /// 此前普通轮（record_calls）与摘要轮（compact_history 内联）各写一份同构循环、
    /// 仅 turn/status 不同，合一为映射器参数。`track_tokens` 控制「最近一次 token」
    /// 是否跟进：普通轮跟、摘要轮不跟——摘要请求是内部的模型调用，/status 的
    /// 「最近一次」应反映任务轮而不是压缩器。
    pub fn record_calls(
        &mut self,
        calls: &[CallRecord],
        turn_of: impl Fn(&CallRecord) -> i64,
        status_of: impl Fn(&CallRecord) -> String,
        track_tokens: bool,
    ) {
        for rec in calls {
            self.stats.model_turns += 1;
            self.stats.model_ms += rec.ms.max(0) as u128;
            if track_tokens && (rec.prompt_tokens.is_some() || rec.completion_tokens.is_some()) {
                self.stats.last_prompt_tokens = rec.prompt_tokens;
                self.stats.last_completion_tokens = rec.completion_tokens;
            }
            let entry = ModelEntry {
                turn: turn_of(rec),
                ok: rec.ok,
                status: status_of(rec),
                error: rec.error.clone(),
                ms: rec.ms,
                req_bytes: rec.req_bytes,
                resp_bytes: rec.resp_bytes,
                attempts: rec.attempts,
                prompt_tokens: rec.prompt_tokens,
                completion_tokens: rec.completion_tokens,
            };
            if let Some(a) = self.audit.as_mut() {
                a.write_model(&entry);
            }
        }
    }

    /// 本侧本地工具的审计 tool 行（turn 减一，口径同 [`Self::record_calls`] 的普通轮）。
    pub fn record_local_tools(&mut self, recs: &[LocalToolRecord]) {
        let Some(a) = self.audit.as_mut() else { return };
        for r in recs {
            a.write_tool(&ToolEntry {
                turn: r.turn.saturating_sub(1) as i64,
                tool: r.tool.clone(),
                args: r.args.clone(),
                ok: r.ok,
                error: r.error.clone(),
                ms: r.ms,
                bytes: r.bytes,
                summary: r.summary.clone(),
            });
        }
    }

    /// `/status` 的统计渲染（只渲染、不判定）。
    pub fn stats(&self) -> &SessionStats {
        &self.stats
    }

    /// `/status` 的审计落点描述。
    pub fn audit_landing(&self) -> String {
        match self.audit.as_ref() {
            Some(a) => format!("{}（session {}）", a.path(), a.session_id()),
            None => "(未开启)".to_string(),
        }
    }
}

/// `--resume` 载入结果（Session 装配件的组成部分）：历史已过三道判据
/// （逐行解析/指纹核对/协议自洽），非恢复路径传空历史与 `false`。
pub struct ResumeContext {
    pub history: Vec<Message>,
    pub summary: Option<String>,
    pub resumed: bool,
}

/// 会话装配件（Session::new 的入参打包，2026-10-01）：构造参数从 11 个收敛为 1
/// 个结构体——参数数量本身曾是全仓两处 clippy too_many_arguments 豁免之一；
/// 打包后豁免移除。字段语义见 Session 各字段注释。
pub struct SessionAssembly {
    pub cfg: Config,
    pub backend: Backend,
    pub bridge: Arc<Bridge>,
    /// 循环层共享状态（预算/图片/回滚边界/取消标志）
    pub state: Arc<HookState>,
    /// 后端 `tool.list` 给的工具名（`/sql` 能力预检用：缺工具时点名后端开关，
    /// 而不是把一句含糊的「未知工具」丢给操作者）。
    pub tool_names: Vec<String>,
    /// 首轮 `context.get` 素材（结构脚本路径、动作脚本目录……）
    pub material: PromptMaterial,
    pub audit: Option<AuditLog>,
    /// 会话持久化写入器（批次 D；`None` = 未开启 `--session-file`）。
    pub writer: Option<SessionFileWriter>,
    /// 录制模式（`--record` / `--record-dir`；`None` = 未开启）。完整上下文采集
    /// （含图片本体），微调数据用 scripts/record_export.py 导出，见 record.rs 模块头。
    pub record: Option<RecordStore>,
    pub resume: ResumeContext,
}

pub struct Session {
    cfg: Config,
    backend: Backend,
    bridge: Arc<Bridge>,
    /// 循环层共享状态（预算/图片/回滚边界/取消标志）
    state: Arc<HookState>,
    audit: SessionAudit,
    /// 首轮 `context.get` 素材（结构脚本路径、动作脚本目录……；**硬件数每轮重取**，
    /// 因为后端的 /sql 热插会长出新硬件，缓存首轮值会让提示符一直少报）。
    material: PromptMaterial,
    /// 后端 `tool.list` 给的工具名（`/sql` 能力预检用：缺工具时点名后端开关，
    /// 而不是把一句含糊的「未知工具」丢给操作者）。
    tool_names: Vec<String>,
    history: ConversationHistory,
    /// 会话持久化写入器（批次 D；`None` = 未开启 `--session-file`）。
    writer: Option<SessionFileWriter>,
    /// 录制模式（`None` = 未开启）。事件面见 record.rs；所有挂钩都只转发不判定。
    record: Option<RecordStore>,
    /// 「思考中…」动画只在交互 REPL 开（`run_repl` 入口置位）；`--task` 一次性
    /// 模式的输出常被管道消费，逐格动画只会污染 stderr。
    show_progress: bool,
}

impl Session {
    /// 建会话（审计的 session start 行由 SessionAudit::new 立即写）。
    pub fn new(parts: SessionAssembly) -> Self {
        let SessionAssembly {
            cfg,
            backend,
            bridge,
            state,
            tool_names,
            material,
            audit,
            writer,
            record,
            resume,
        } = parts;
        let audit = SessionAudit::new(&cfg, audit, resume.resumed);
        Self {
            cfg,
            backend,
            bridge,
            state,
            audit,
            material,
            tool_names,
            history: ConversationHistory::resumed(resume.history, resume.summary),
            writer,
            record,
            show_progress: false,
        }
    }

    /// 录制事件面的快捷口（`None` = 未开启；调用点只转发，语义在 record.rs）。
    fn rec(&mut self) -> Option<&mut RecordStore> {
        self.record.as_mut()
    }

    /// 录制当前完整历史（任务收尾观察点；`None` = 未开启零行为）。直接借
    /// `record`/`history` 两个字段做不相交借用，免掉 `snapshot` 式整份克隆。
    fn record_full_history(&mut self) {
        if let Some(r) = self.record.as_mut() {
            r.record_history(self.history.messages());
        }
    }

    /// `/clear`：只裁会话历史（硬件保持上电，系统提示词不变——rig 的 preamble 在
    /// agent 上，不在历史里）。落一行 `session_clear` 分界标记：恢复时该标记
    /// 丢弃此前的全部消息，否则「忘掉对话」会在下次恢复时复活。
    pub fn clear_history(&mut self) {
        self.history.clear();
        self.bridge.ica.clear();
        if let Some(r) = self.rec() {
            r.reset_after_clear();
        }
        if let Some(w) = self.writer.as_mut() {
            w.write_clear_marker();
        }
        if let Err(e) = self.bridge.ica.save(&self.cfg.session_file) {
            errln!("[ICA] 清空后保存账本失败: {e}");
        }
    }

    /// 会话结束行（`end` / `error`）。C++ 的 `writeSessionEnd` 同契约：失败会话也
    /// 必须留一条——「这次会话怎么结束的」是复盘的第一句话。
    pub fn write_session_end(&mut self, status: &str, error: &str) {
        self.audit.write_session_end(status, error);
        if let Some(r) = self.rec() {
            r.session_end(status, error);
        }
    }

    /// 历史压缩（改进项 #7）：整块裁剪 + 把被裁块压进摘要。
    ///
    /// 预算先扣掉摘要一节在请求体里的体积（摘要挂在 preamble 上，history 的记账看
    /// 不见它），再交给 `evict`；`max(1)` 是因为 0 对 evict 意味着「不裁」。摘要走
    /// `model_handle()`——AgentBuilder 抹掉类型后的模型句柄，底下仍是 BudgetModel，
    /// 超时/重试/停止标志/审计观测与正常请求同一套。摘要失败只告知不阻断：任务
    /// 照跑，只是这次裁掉的上下文没进摘要（会话文件也什么都不写，下次恢复自愈）。
    async fn compact_history(&mut self) {
        let budget = self.cfg.max_history_bytes as usize;
        if budget == 0 {
            return;
        }
        let reserve = self
            .history
            .summary()
            .map_or(0, summary::summary_section_weight);
        let evicted = self
            .history
            .evict(budget.saturating_sub(reserve).max(1), &mut |t| {
                errln!("{t}")
            });
        // 录制：被裁块已经作为消息事件在盘上（录制是全量留档），只落裁剪标记并
        // 回退水位——导出器据此知道「有效上下文」从此少了一截。
        if let Some(r) = self.rec() {
            r.note_evicted(evicted.len());
        }
        if evicted.is_empty() || !self.cfg.history_summary {
            return;
        }
        let previous = self.history.summary().map(str::to_string);
        let handle = self.backend.agent.model_handle().clone();
        let result = summary::summarize(
            &handle,
            previous.as_deref(),
            &evicted,
            self.cfg.max_summary_bytes as usize,
            self.cfg.max_tokens as u64,
            &mut |w| errln!("{w}"),
        )
        .await;
        // 摘要请求的观测值单独落审计：turn=-1（不属于任何任务轮）、status=summary；
        // track_tokens=false——摘要请求是内部模型调用，/status 的「最近一次 token」
        // 应反映任务轮而不是压缩器。
        let calls = self.state.drain_calls();
        self.audit.record_calls(
            &calls,
            |_| -1,
            |rec| if rec.ok { "summary" } else { "summary_error" }.to_string(),
            false,
        );
        if let Some(r) = self.rec() {
            r.model_calls(&calls, "summary");
        }
        match result {
            Ok(text) => {
                errln!(
                    "[历史] 已将裁掉的 {} 条消息压缩进摘要（{} 字节）",
                    evicted.len(),
                    text.len()
                );
                if let Some(w) = self.writer.as_mut() {
                    w.write_summary(&text, self.history.persisted_blocks());
                }
                if let Some(r) = self.rec() {
                    r.history_summary(true, &text, "");
                }
                self.history.set_summary(text);
            }
            Err(e) => {
                errln!("[历史] 摘要失败（{e}），本次裁掉的上下文未进摘要，仅整块裁剪");
                if let Some(r) = self.rec() {
                    r.history_summary(false, "", &e.to_string());
                }
            }
        }
    }

    /// 跑一轮任务；模型输出由本函数打到 stdout（流式逐 delta / 阻塞整段）。
    /// `Err` = 本轮失败（历史已回滚到完整边界，会话可继续）。
    pub async fn run_turn(&mut self, task: &str) -> Result<(), String> {
        // 任务内预算清零（含墙钟起点）与上一轮的观测值/图片清理。必须先于压缩：
        // 摘要请求走同一个 BudgetModel，上一轮残留的图片后注不能混进它。
        self.state.begin_task();
        self.bridge.observe_user(task);
        if let Some(r) = self.rec() {
            r.task_begin(task);
        }
        // 任务开始前：按字节预算**整块**裁掉最早的旧任务块（最新块无条件保留；
        // 0 = 不裁剪），被裁的块交给摘要器。裁剪日志走 stderr：更早的任务上下文
        // 不再可见（或只剩摘要）是必须告知的事实。
        self.compact_history().await;
        // 前缀历史里的工具结果条数：图片批次按「整份请求历史从头数」编号
        // （model.rs::inject_images），收尾增量物化尾段时要把它扣掉。
        let prefix_tool_results = self
            .history
            .messages()
            .iter()
            .filter(|m| hook::has_tool_result(m))
            .count();
        let snapshot = self.history.snapshot();
        let preamble = self
            .history
            .summary()
            .map(|s| summary::preamble_with_summary(&self.backend.preamble, s));

        // 借用只活在块内：`result` 是拥有所有权的值，块一结束 `self.backend` 的
        // 不可变借用就结束，后面才能改 `self.history`。
        //
        // snapshot 只此一份搬进 runner（整份历史含 base64 图片，clone 一份是实打实
        // 的峰值内存）：成功路径收尾走 history.append 增量并入、失败路径的回滚边界
        // 自带基线，都不再需要拿回这份快照。
        let result = if self.backend.stream {
            self.drive_stream(task, snapshot, preamble).await
        } else {
            self.drive_blocking(task, snapshot, preamble).await
        };

        // 逐次模型调用的观测值（含重试与失败那一次）与图片注入批次。流式面的
        // 观测值由模型层的流适配器在流结束/被丢弃时落——drive_* 返回前流已释放。
        let calls = self.state.drain_calls();
        let local_tools = self.state.drain_local_tools();
        let injections = self.state.take_injections();
        // 录制：模型调用元数据先落（时间线上它们发生在各轮），消息增量随后补
        if let Some(r) = self.rec() {
            r.model_calls(&calls, "task");
        }

        match result {
            Ok(resp) => {
                // 新消息（含 tool_calls / tool 结果）并进历史。空则退回「user + 最终
                // 文本」，宁可少记也不留空洞（历史里出现过半截序列是查不出来的坑）。
                let mut new = resp.messages.unwrap_or_default();
                if new.is_empty() {
                    new.push(Message::user(task.to_string()));
                    new.push(Message::assistant(resp.output));
                }
                // 图片后注物化：注入只作用于发出去的请求，这里按记录的位置把
                // 「tool 消息之后的图片消息」插回会话历史（与 C++ 同序）。只物化本轮
                // 新增的尾段再增量并入，不为收尾把整份历史（含 base64 图片）克隆一遍。
                let materialized =
                    hook::materialize_appended(new, &injections, prefix_tool_results);
                self.history.append(materialized);
                self.record_full_history();
                if let Some(w) = self.writer.as_mut() {
                    self.history.persist(|m| w.append_message(m));
                }
                if let Err(e) = self.bridge.ica.save(&self.cfg.session_file) {
                    errln!("[ICA] 保存账本失败: {e}");
                }
                self.record_calls(&calls);
                self.audit.record_local_tools(&local_tools);
                if let Some(r) = self.rec() {
                    r.task_end(true, "");
                }
                if let Some(note) = self.bridge.ica.note() {
                    outln!("\n{note}");
                }
                Ok(())
            }
            Err(e) => {
                // 回滚：钩子记下的边界 = 已完整跑完的轮（含工具回执与其中的图片），
                // 半截的 tool_calls 序列不留在历史里。边界缺失 = 本轮连一次模型调用
                // 都没发生——历史没动过，也不该有图片批次（注入只在模型调用里产生，
                // model.rs::inject_images），无需回写；违例出现时响亮告警，绝不静默丢图。
                match self.state.rollback_boundary() {
                    Some(base) => self.history.replace(hook::materialize(base, &injections)),
                    None => {
                        if !injections.is_empty() {
                            errln!(
                                "[mybot-agent] 警告: 本轮无模型调用却收到 {} 个图片批次，\
                                 未并入会话历史",
                                injections.len()
                            );
                        }
                    }
                }
                self.record_full_history();
                self.record_calls(&calls);
                self.audit.record_local_tools(&local_tools);
                if let Some(r) = self.rec() {
                    r.task_end(false, &e);
                }
                Err(e)
            }
        }
    }

    /// 装配模型循环 runner（B4 拆出）：阻塞面与流式面共用的三件套
    /// （任务文本 + 历史快照 + 轮次上限）与可选 preamble。
    fn prime_runner(
        &self,
        task: &str,
        snapshot: Vec<Message>,
        preamble: Option<String>,
    ) -> AgentRunner {
        let mut runner = self
            .backend
            .agent
            .runner(task.to_string())
            .history(snapshot)
            .max_turns(self.cfg.max_turns as usize);
        if let Some(p) = preamble {
            runner = runner.preamble(p);
        }
        runner
    }

    /// 阻塞面：整轮跑完后一次性打印最终文本。
    async fn drive_blocking(
        &self,
        task: &str,
        snapshot: Vec<Message>,
        preamble: Option<String>,
    ) -> Result<PromptResponse, String> {
        let progress = self.show_progress.then(Progress::start);
        let runner = self.prime_runner(task, snapshot, preamble);
        let result = runner.run().await.map_err(format_prompt_error);
        if let Some(p) = progress {
            p.finish().await;
        }
        let resp = result?;
        outln!("{}", resp.output);
        Ok(resp)
    }

    /// 流式面：文本 delta 逐条打到 stdout；工具轮之间换行并重开「思考中…」；
    /// 思维链不打印。流的 `FinalResponse` 与阻塞面的返回值同型，后处理共用。
    async fn drive_stream(
        &self,
        task: &str,
        snapshot: Vec<Message>,
        preamble: Option<String>,
    ) -> Result<PromptResponse, String> {
        let mut progress = self.show_progress.then(Progress::start);
        let mut stream = self.prime_runner(task, snapshot, preamble).stream().await;
        // 本模型轮是否已打过文本（决定要不要在工具轮/结束时补换行）
        let mut printed = false;
        let mut final_resp: Option<PromptResponse> = None;
        let mut failure: Option<String> = None;
        while let Some(item) = stream.next().await {
            match item {
                Ok(MultiTurnStreamItem::StreamAssistantItem(StreamedAssistantContent::Text(t))) => {
                    if t.text.is_empty() {
                        continue;
                    }
                    if let Some(p) = progress.take() {
                        p.finish().await;
                    }
                    out!("{}", t.text);
                    printed = true;
                }
                Ok(MultiTurnStreamItem::StreamAssistantItem(
                    StreamedAssistantContent::ToolCall { .. },
                )) => {
                    // 工具轮：本轮文本收口，工具执行 + 等下一轮模型期间重开动画
                    if printed {
                        outln!("");
                        printed = false;
                    }
                    if self.show_progress && progress.is_none() {
                        progress = Some(Progress::start());
                    }
                }
                Ok(MultiTurnStreamItem::ModelTurnRetried { turn }) => {
                    errln!("[agent] 第 {turn} 轮模型响应被判定重来");
                }
                Ok(MultiTurnStreamItem::FinalResponse(resp)) => final_resp = Some(resp),
                Ok(_) => {}
                Err(e) => {
                    failure = Some(format_stream_error(e));
                    break;
                }
            }
        }
        // 先释放流（模型层的适配器在 Drop 时落最后一条审计行），再收动画
        drop(stream);
        if let Some(p) = progress {
            p.finish().await;
        }
        if let Some(e) = failure {
            if printed {
                outln!("");
            }
            return Err(e);
        }
        let resp = final_resp.ok_or_else(|| "模型流结束但没有最终响应".to_string())?;
        if printed {
            outln!("");
        } else if !resp.output.is_empty() {
            // provider 只给整段不给 delta 的兜底：最终文本仍要让操作者看到
            outln!("{}", resp.output);
        }
        Ok(resp)
    }

    /// 把逐次模型调用的观测值落成审计 model 行（turn 减一：rig 从 1 数起，
    /// C++ 的 turn 从 0 数起——两侧审计口径必须一致）+ 会话统计。
    fn record_calls(&mut self, calls: &[CallRecord]) {
        self.audit.record_calls(
            calls,
            |rec| rec.turn.saturating_sub(1) as i64,
            |rec| if rec.ok { "ok" } else { "error" }.to_string(),
            true,
        );
    }

    /// 每轮重取硬件数（`context.get` 的 `hardwareCount`）。取不到 → `None`
    /// （提示符里显示 `?`，不编数字）。
    async fn hardware_count(&self) -> Option<u64> {
        let ctx = self.bridge.context_get().await.ok()?;
        Some(ctx.hardware_count)
    }

    /// `/status` 一览（只渲染、不判定；缺的数字给 `?`，不给假值）。
    fn status_text(&self, hw: Option<u64>) -> String {
        let st = self.audit.stats();
        let mut s = String::new();
        s += "会话状态:\n";
        s += &format!(
            "  模型/接入点 : {} @ {}（超时 {}s，最大 {} 轮模型调用）\n",
            self.cfg.model, self.backend.effective_url, self.cfg.timeout_sec, self.cfg.max_turns
        );
        s += &format!(
            "  输出模式    : {}\n",
            if self.backend.stream {
                "流式（逐 delta 打到 stdout）"
            } else {
                "阻塞（整段输出）"
            }
        );
        s += &format!(
            "  本会话统计  : 模型 {} 轮/{}ms",
            st.model_turns, st.model_ms
        );
        if st.last_prompt_tokens.is_some() || st.last_completion_tokens.is_some() {
            let fmt = |v: Option<i64>| v.map(|x| x.to_string()).unwrap_or_else(|| "?".to_string());
            s += &format!(
                "，最近一次 token {}→{}",
                fmt(st.last_prompt_tokens),
                fmt(st.last_completion_tokens)
            );
        }
        s += "\n";
        s += &format!(
            "  对话历史    : {} 条消息（rig transcript）\n",
            self.history.len()
        );
        s += &format!("  审计落点    : {}\n", self.audit.audit_landing());
        s += "  工具审计    : 工具行由后端 mybot --mcp-backend 落（含 exit_code/image_fp/summary），\
              本进程只记 session/model 行\n";
        s += &format!(
            "  会话持久化  : {}\n",
            match self.writer.as_ref() {
                Some(_) => format!(
                    "{}（已落盘 {} 条）",
                    self.cfg.session_file,
                    self.history.written_prefix()
                ),
                None => "(未开启)".to_string(),
            }
        );
        s += &format!(
            "  录制        : {}\n",
            match self.record.as_ref() {
                Some(r) => {
                    let (ev, img) = r.stats();
                    format!("{}（事件 {} 条，图片 {} 张）", r.dir(), ev, img)
                }
                None => "(未开启)".to_string(),
            }
        );
        s += &format!(
            "  硬件        : {}，{} 个变量（/hardware 看清单）\n",
            self.material.structure_path,
            hw.map(|n| n.to_string()).unwrap_or_else(|| "?".to_string())
        );
        s += &format!("  动作脚本目录: {}\n", self.material.scripts_dir);
        if let Some(summary) = self.bridge.ica.summary() {
            s += &format!(
                "  ICA 账本    : {}\n",
                summary.replace('\n', "\n                ")
            );
        }
        s
    }

    /// `tool_names` 里有没有这个工具（`/sql` 的能力预检）。
    fn has_tool(&self, name: &str) -> bool {
        self.tool_names.iter().any(|t| t == name)
    }

    /// 调一个工具并把回执渲染成给操作者看的文本（REPL 命令用；**不**进模型历史）。
    async fn call_tool(&self, name: &str, args: serde_json::Value) -> String {
        match self.bridge.call(name, args).await {
            Ok(o) => render_outcome(&o),
            Err(e) => format!("错误: {e}"),
        }
    }
}

/// 把工具回执渲染成一行文本：成功给回执文本，失败给「错误: …」（C++ 的 REPL 命令
/// 一律以「错误: 」前缀报告失败，这里同口径）。
fn render_outcome(o: &ToolOutcome) -> String {
    if o.ok {
        o.model_text()
    } else {
        format!("错误: {}", o.model_text())
    }
}

/// 交互 REPL（C++ `runAgentRepl` 镜像）。返回进程退出码（恒 0：退出是操作者的
/// 意思，不是失败）。日志/告警走 stderr，界面走 stdout。
pub async fn run_repl(session: &mut Session) -> i32 {
    // 交互 REPL 才开「思考中…」动画（--task 的输出常被管道消费）
    session.show_progress = true;

    let robot_name = if session.material.robot_name.is_empty() {
        "(未命名)".to_string()
    } else {
        session.material.robot_name.clone()
    };
    outln!(
        "agent 模式：机器人已上电常驻（结构脚本 {}）。",
        session.material.structure_path
    );
    outln!(
        "直接输入任务；/hardware 看硬件清单，/scripts 看动作脚本，/sql 执行结构 SQL，\
         /status 看会话状态，/clear 清空对话记忆，/help 看帮助，/exit 退出。"
    );

    // 终端上：行编辑 / ↑↓ 历史 / Tab 补全（linein.rs）；管道上：裸逐行，行为不变
    let mut input = LineInput::new();
    loop {
        // D4：Ctrl-C / SIGTERM 之后不再接新任务（与 C++ `while (!stopRequested())`
        // 同口径：取消是操作者的意思，循环退出、会话照常收尾）
        if session.state.stop.load(Ordering::Relaxed) {
            break;
        }
        // 提示符 mybot[robotName|llmVar|Nhw]>（硬件数每轮重取：热插后不能少报）
        let hw = session.hardware_count().await;
        let prompt = format!(
            "mybot[{}|{}|{}hw]> ",
            robot_name,
            session.cfg.llm_var,
            hw.map(|n| n.to_string()).unwrap_or_else(|| "?".to_string())
        );

        let line = match input.read_line(prompt).await {
            LineRead::Line(l) => l,
            LineRead::Interrupted => {
                outln!("（已丢弃当前行；退出请用 /exit 或 Ctrl-D）");
                continue;
            }
            LineRead::Eof => break, // Ctrl-D
            LineRead::Error(e) => {
                errln!("错误: 读取输入失败: {e}");
                break;
            }
        };
        if line.len() > K_MAX_REPL_INPUT_BYTES {
            errln!(
                "错误: 输入过长（{} 字节，上限 {K_MAX_REPL_INPUT_BYTES} 字节）；\
                 请缩短输入或分多次提交",
                line.len()
            );
            continue;
        }
        let task = line.trim();
        if task.is_empty() {
            continue;
        }
        if task == "/exit" || task == "/quit" {
            break;
        }
        input.remember(task);
        if slash::handle_slash_command(session, task, hw).await {
            continue;
        }

        match session.run_turn(task).await {
            Ok(()) => {}
            Err(e) => {
                // REPL：单轮失败不结束会话（历史已回滚，可继续下一条任务）
                errln!("错误: {e}");
            }
        }
    }
    input.save_history();
    outln!("");
    0
}

/// 一次性任务（`--task`）：输出已由 `run_turn` 打到 stdout；失败 `Err(错误文本)`。
/// 退出码与结束行的分派在 main（`end`/0 或 `error`/1）。
pub async fn run_task_once(session: &mut Session, task: &str) -> Result<(), String> {
    session.run_turn(task).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use rig_agent::completion::CompletionError;

    #[test]
    fn stream_error_text_matches_blocking_face() {
        // 流式面的错误外面多套一层 `PromptError: `，取消再套一层 `PromptCancelled: `；
        // 两个面给操作者看的文本必须一字不差（E2E 与文档都按同一份口径断言）
        let cancelled = StreamingError::Prompt(Box::new(PromptError::PromptCancelled {
            chat_history: Vec::new(),
            reason: "任务被取消".to_string(),
        }));
        assert_eq!(format_stream_error(cancelled), "任务被取消");
        let blocking = PromptError::PromptCancelled {
            chat_history: Vec::new(),
            reason: "任务被取消".to_string(),
        };
        assert_eq!(format_prompt_error(blocking), "任务被取消");
        // 非取消类保留 rig 原文（不吞信息）
        let other = StreamingError::Completion(CompletionError::ProviderError("boom".to_string()));
        assert_eq!(
            format_stream_error(other),
            "CompletionError: ProviderError: boom"
        );
    }

    #[test]
    fn render_outcome_prefixes_errors_only() {
        let ok = ToolOutcome {
            text: "硬件清单：\n  relay0".to_string(),
            ok: true,
            ..Default::default()
        };
        assert_eq!(render_outcome(&ok), "硬件清单：\n  relay0");
        let bad = ToolOutcome {
            text: "设备忙".to_string(),
            ok: false,
            error: "设备忙".to_string(),
            ..Default::default()
        };
        assert_eq!(render_outcome(&bad), "错误: 设备忙");
    }

    // ---- SessionAudit（审计/统计面拆分的核心语义，2026-10-01 补测）----

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        crate::testutil::tmpdir("mybot_auditface", tag)
    }

    fn call(ms: i64, tokens: Option<(i64, i64)>) -> CallRecord {
        CallRecord {
            turn: 2, // rig 1-based：审计 turn 应记 1
            req_bytes: 100,
            resp_bytes: 50,
            attempts: 1,
            ms,
            ok: true,
            error: String::new(),
            prompt_tokens: tokens.map(|t| t.0),
            completion_tokens: tokens.map(|t| t.1),
        }
    }

    fn audit_log_lines(path: &std::path::Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    /// 最小可用的 Config：SessionAudit 只读 driver/model/endpoint/api_key_source
    /// 四个字段写 start 行，其余字段与审计面无关（此处只求构造合法）。
    fn test_config() -> Config {
        Config {
            socket: String::new(),
            config_path: String::new(),
            driver: "mcp".to_string(),
            llm_var: "llm0".to_string(),
            endpoint: "http://example.invalid/v1".to_string(),
            model: "test-model".to_string(),
            api_key: crate::config::Secret::new(String::new()),
            api_key_source: "env",
            config_warning: String::new(),
            timeout_sec: 60,
            max_tokens: 1024,
            temperature: 1.0,
            top_p: 1.0,
            max_turns: 20,
            max_task_seconds: 0,
            max_history_bytes: 0,
            max_task_tool_result_bytes: 0,
            max_task_image_bytes: 0,
            max_calls_per_round: 10,
            max_retries: 3,
            retry_backoff_ms: 500,
            reasoning_effort: String::new(),
            thinking: String::new(),
            stream: true,
            history_summary: false,
            max_summary_bytes: 0,
            prompt_files: Vec::new(),
            prompt_pack: String::new(),
            audit_log: String::new(),
            session_file: String::new(),
            session_path_source: crate::config::SessionPathSource::Default,
            session_file_from_cli: false,
            resume: false,
            new_session: false,
            state_dir: String::new(),
            state_dir_source: "",
            state_dir_ok: false,
            allow_hosts: Vec::new(),
            http_fetch_timeout_sec: crate::config::DEFAULT_HTTP_FETCH_TIMEOUT_SEC,
            http_fetch_max_bytes: crate::config::DEFAULT_HTTP_FETCH_MAX_BYTES,
            record_enabled: false,
            record_dir: String::new(),
            record_max_image_bytes: 0,
        }
    }

    #[test]
    fn audit_face_records_turn_mapping_and_stats() {
        let dir = tmpdir("turnmap");
        let path = dir.join("audit.jsonl");
        let log = AuditLog::open(path.to_str().unwrap()).unwrap();
        let cfg = test_config();
        let mut face = SessionAudit::new(&cfg, Some(log), false);
        let calls = vec![call(120, Some((10, 20))), call(300, None)];
        face.record_calls(
            &calls,
            |r| r.turn.saturating_sub(1) as i64,
            |r| if r.ok { "ok" } else { "error" }.to_string(),
            true,
        );
        // 统计：两轮、420ms；「最近一次 token」跟进到有值的那次（第二次无值不覆盖）
        assert_eq!(face.stats().model_turns, 2);
        assert_eq!(face.stats().model_ms, 420);
        assert_eq!(face.stats().last_prompt_tokens, Some(10));
        assert_eq!(face.stats().last_completion_tokens, Some(20));
        // 审计行：turn 从 rig 的 1-based 2 记成 C++ 口径 1；token 字段在行里
        let lines = audit_log_lines(&path);
        let models: Vec<_> = lines
            .iter()
            .filter(|l| l.get("kind").and_then(|v| v.as_str()) == Some("model"))
            .collect();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].get("turn").and_then(|v| v.as_i64()), Some(1));
        assert_eq!(
            models[0].get("prompt_tokens").and_then(|v| v.as_i64()),
            Some(10)
        );
        assert_eq!(models[1].get("prompt_tokens"), None);
    }

    #[test]
    fn audit_face_writes_local_tool_rows_in_backend_shape() {
        let dir = tmpdir("localtool");
        let path = dir.join("audit.jsonl");
        let log = AuditLog::open(path.to_str().unwrap()).unwrap();
        let cfg = test_config();
        let mut face = SessionAudit::new(&cfg, Some(log), false);
        face.record_local_tools(&[LocalToolRecord {
            turn: 3,
            tool: "http_fetch".to_string(),
            args: serde_json::json!({"url": "https://api.example.com/v1"}),
            ok: false,
            error: "HTTP 404 Not Found".to_string(),
            ms: 12,
            bytes: 34,
            summary: "status=404".to_string(),
        }]);
        let lines = audit_log_lines(&path);
        let tools: Vec<_> = lines
            .iter()
            .filter(|l| l.get("kind").and_then(|v| v.as_str()) == Some("tool"))
            .collect();
        assert_eq!(tools.len(), 1);
        let t = tools[0];
        // turn 同 model 行口径：rig 1-based 3 → 2
        assert_eq!(t["turn"], 2);
        assert_eq!(t["tool"], "http_fetch");
        assert_eq!(t["args"]["url"], "https://api.example.com/v1");
        assert_eq!(t["ok"], false);
        assert_eq!(t["error"], "HTTP 404 Not Found");
        assert_eq!(t["ms"], 12);
        assert_eq!(t["bytes"], 34);
        assert_eq!(t["summary"], "status=404");
    }

    #[test]
    fn audit_face_summary_rows_do_not_track_tokens() {
        // 摘要轮：turn 恒 -1、status=summary；track_tokens=false 不跟进「最近一次」
        let dir = tmpdir("summary");
        let path = dir.join("audit.jsonl");
        let log = AuditLog::open(path.to_str().unwrap()).unwrap();
        let cfg = test_config();
        let mut face = SessionAudit::new(&cfg, Some(log), false);
        face.record_calls(
            &[call(50, Some((7, 8)))],
            |_| -1,
            |_| "summary".to_string(),
            false,
        );
        assert_eq!(face.stats().model_turns, 1);
        assert_eq!(
            face.stats().last_prompt_tokens,
            None,
            "摘要轮不跟进最近 token"
        );
        let lines = audit_log_lines(&path);
        let models: Vec<_> = lines
            .iter()
            .filter(|l| l.get("kind").and_then(|v| v.as_str()) == Some("model"))
            .collect();
        // turn<0 不写字段（ModelEntry 契约）：摘要轮的 -1 落形就是「无 turn 键」
        assert_eq!(models[0].get("turn"), None);
        assert_eq!(
            models[0].get("status").and_then(|v| v.as_str()),
            Some("summary")
        );
    }

    #[test]
    fn audit_face_session_start_and_end_land() {
        // SessionAudit::new 即写 start 行；write_session_end 写 end 行（含 ms）
        let dir = tmpdir("lifetime");
        let path = dir.join("audit.jsonl");
        let log = AuditLog::open(path.to_str().unwrap()).unwrap();
        let cfg = test_config();
        let mut face = SessionAudit::new(&cfg, Some(log), false);
        face.write_session_end("end", "");
        let lines = audit_log_lines(&path);
        let kinds: Vec<_> = lines
            .iter()
            .filter(|l| l.get("kind").and_then(|v| v.as_str()) == Some("session"))
            .map(|l| l.get("status").and_then(|v| v.as_str()).unwrap_or(""))
            .collect();
        assert_eq!(kinds, vec!["start", "end"]);
    }
}

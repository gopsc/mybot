//! hook.rs —— 循环层的钩子状态与 rig 钩子实现（C++ agentloop.cpp 的循环语义落点）
//!
//! C++ 的循环语义散在 `AgentSession::runTurn` / `executeToolRound` 里：轮循环开头的
//! 中断与墙钟判定、逐条派发前的墙钟判定、单轮调用上限、失败回滚边界；rig 侧这些都
//! 走 `AgentHook`（批次 C 落点设计见迁移提交说明，git log -- agent/src/hook.rs）。
//!
//! 本文件只放**判定与记账**；桥（bridge.rs）在工具回执到手时做任务内预算降级，
//! 模型装饰器（model.rs）负责图片注入与重试，REPL（repl.rs）负责裁剪、物化与回滚。
//!
//! 两处墙钟判定点（C++ 也有两处，语义不同）：
//!   * 判定点①（`on_completion_call`）：预算已耗尽就**不再发起新的模型调用**，
//!     以失败收场并如实说明「此前已执行的动作不会回退」；
//!   * 判定点②（`on_tool_call`，逐条派发之前）：轮内耗尽时剩下的调用**不派发**，
//!     但每条都补一条回执——说清「没下发、也没有副作用」，不是执行失败。
//!
//! 单轮工具调用上限：C++ 把超限的调用从 assistant.tool_calls 里**剔除**并把截断
//! 说明追加进 assistant 文本；rig 侧等价物是 `ToolCallAction::Skip`（不派发、模型
//! 看到「未派发」回执）。不派发语义一致，呈现位置不同——已记档为如实偏差。

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

use rig_agent::agent::{
    AgentHook, CompletionCallAction, CompletionCallEvent, HookContext, ToolCall, ToolCallAction,
};
use rig_agent::completion::message::UserContent;
use rig_agent::completion::Message;

use crate::budget::TaskBudget;
use crate::out::errln;

/// 图片后注的说明文字（逐字同 C++ `executeToolRound` 里那条 user 消息）。
pub const IMAGE_CAPTION: &str = "以上工具返回的图片如下，请结合画面内容继续。";

/// 取消文案（逐字同 C++ `runTurn` 与 `agentdriver.cpp` 的「执行被中断」口径）。
pub const STOP_TEXT: &str = "执行被中断";

/// 一次模型调用的观测值（供 REPL 落审计的 model 行）。
#[derive(Debug, Clone, Default)]
pub struct CallRecord {
    /// rig 的 1-based 模型调用序号（写审计时减一，对齐 C++ 的 0-based turn）
    pub turn: usize,
    /// 请求体估算字节（线上体积下界，口径同 C++ SAN-9）
    pub req_bytes: u64,
    /// 模型可见文本字节（C++ 记的是 `resp.content.size()`）
    pub resp_bytes: u64,
    /// 实际尝试次数（>1 = 发生过重试）
    pub attempts: u64,
    pub ms: i64,
    pub ok: bool,
    pub error: String,
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
}

/// 一次本侧本地工具调用的观测值（供 REPL 落审计的 tool 行，字段对齐 C++ 工具行）。
#[derive(Debug, Clone, Default)]
pub struct LocalToolRecord {
    /// rig 的 1-based 模型调用序号（写审计时减一，同 [`CallRecord::turn`]）
    pub turn: usize,
    pub tool: String,
    /// 已脱敏的参数（http_fetch：url 去 query/fragment/userinfo）
    pub args: serde_json::Value,
    pub ok: bool,
    pub error: String,
    pub ms: i64,
    pub bytes: u64,
    /// 工具自报的生效摘要（G2 同字段；http_fetch：`status=200`）
    pub summary: String,
}

/// 一批待注入的图片，以及它应当落在哪条工具结果消息之后。
///
/// `ordinal` 是「本次请求里第几条带工具结果的 user 消息」（1-based，从头数）。
/// 记序号而不是下标：同一个任务里每轮的请求都是重新拼出来的（外层 seed + 本轮消息），
/// 序号在任意前缀上都稳定。
#[derive(Debug, Clone)]
pub struct Injection {
    pub ordinal: usize,
    /// 该批次的 user 消息内容（说明文字 + 若干图片）
    pub content: Vec<UserContent>,
}

/// 本轮已发出的工具调用计数（单轮上限用；turn 变化即重置）。
#[derive(Debug, Clone, Copy, Default)]
struct RoundCalls {
    turn: usize,
    calls: usize,
}

/// 钩子、桥、模型装饰器、REPL 共享的运行期状态。
///
/// 2026-10-01 结构治理：判定核心已收进 `gate_completion`/`gate_tool_call`
/// （可单测接缝）；pub 面收紧为 pub(crate)（六个消费者全在本 crate）。字段
/// 分组评估后**保持单结构**：12 个字段同属「一轮任务」的生命周期
/// （begin_task 一并清零），拆子结构只加间接层而不改变任何消费者契约；
/// 真正的共享面已全部经方法（记账/取队列/判定）而非裸字段。
pub struct HookState {
    pub(crate) max_task_seconds: i64,
    /// 0 = 不限
    pub(crate) max_calls_per_round: i64,
    /// SIGINT/SIGTERM 置位（一次置位即锁存：取消是操作者的意思，不该被下一轮任务清掉）
    pub(crate) stop: AtomicBool,
    pub(crate) budget: Mutex<TaskBudget>,
    /// 当前模型调用序号（1-based）——模型装饰器记审计用
    pub(crate) current_turn: AtomicUsize,
    round: Mutex<RoundCalls>,
    /// 本轮的「[上限]」stderr 行只打一次
    round_capped: AtomicBool,
    /// 失败回滚边界（rig 的 CompletionError 不带历史，必须自记）
    rollback: Mutex<Option<Vec<Message>>>,
    calls: Mutex<Vec<CallRecord>>,
    /// 本侧本地工具（http_fetch）的审计观测值：后端工具的工具行由后端自己落，
    /// 本地工具不经后端，只能由本侧落（REPL 任务结束时 drain）
    local_tools: Mutex<Vec<LocalToolRecord>>,
    /// 桥收集到的、尚未注入的图片（data URL）
    pending_images: Mutex<Vec<String>>,
    /// 已注入的批次（供 REPL 在任务结束时物化进会话历史）
    injections: Mutex<Vec<Injection>>,
}

impl HookState {
    pub(crate) fn new(max_task_seconds: i64, max_calls_per_round: i64, budget: TaskBudget) -> Self {
        Self {
            max_task_seconds,
            max_calls_per_round,
            stop: AtomicBool::new(false),
            budget: Mutex::new(budget),
            current_turn: AtomicUsize::new(0),
            round: Mutex::new(RoundCalls::default()),
            round_capped: AtomicBool::new(false),
            rollback: Mutex::new(None),
            calls: Mutex::new(Vec::new()),
            local_tools: Mutex::new(Vec::new()),
            pending_images: Mutex::new(Vec::new()),
            injections: Mutex::new(Vec::new()),
        }
    }

    /// 一轮任务开始：任务内预算清零（含墙钟起点）、清空上一轮留下的观测值与图片。
    /// **不**清 stop —— 取消是锁存的。
    pub fn begin_task(&self) {
        self.budget.lock().unwrap_or_else(poisoned).reset_task();
        *self.round.lock().unwrap_or_else(poisoned) = RoundCalls::default();
        self.round_capped.store(false, Ordering::Relaxed);
        *self.rollback.lock().unwrap_or_else(poisoned) = None;
        self.calls.lock().unwrap_or_else(poisoned).clear();
        self.local_tools.lock().unwrap_or_else(poisoned).clear();
        self.pending_images.lock().unwrap_or_else(poisoned).clear();
        self.injections.lock().unwrap_or_else(poisoned).clear();
    }

    /// 取走本轮全部模型调用记录（审计落行用）。
    pub fn drain_calls(&self) -> Vec<CallRecord> {
        std::mem::take(&mut *self.calls.lock().unwrap_or_else(poisoned))
    }

    pub fn record_call(&self, rec: CallRecord) {
        self.calls.lock().unwrap_or_else(poisoned).push(rec);
    }

    /// 取走本轮全部本地工具调用记录（审计 tool 行用）。
    pub fn drain_local_tools(&self) -> Vec<LocalToolRecord> {
        std::mem::take(&mut *self.local_tools.lock().unwrap_or_else(poisoned))
    }

    pub fn record_local_tool(&self, rec: LocalToolRecord) {
        self.local_tools.lock().unwrap_or_else(poisoned).push(rec);
    }

    /// 失败的**回滚边界**：已经完整跑完的轮（含 tool_calls 与其工具回执）。
    /// `None` = 还没发生任何模型调用（此时回滚到任务开始的历史）。
    pub fn rollback_boundary(&self) -> Option<Vec<Message>> {
        self.rollback.lock().unwrap_or_else(poisoned).clone()
    }

    /// 桥收下一张待注入的图片（data URL）。
    pub fn push_image(&self, data_url: String) {
        self.pending_images
            .lock()
            .unwrap_or_else(poisoned)
            .push(data_url);
    }

    /// 取走并物化「本任务已注入的图片批次」——任务结束时由 REPL 调用。
    pub fn take_injections(&self) -> Vec<Injection> {
        std::mem::take(&mut *self.injections.lock().unwrap_or_else(poisoned))
    }

    /// 取走桥收集到、尚未注入的图片（模型装饰器在每次请求前调用）。
    pub fn take_pending_images(&self) -> Vec<String> {
        std::mem::take(&mut *self.pending_images.lock().unwrap_or_else(poisoned))
    }

    /// 记下一个已注入的图片批次（含它挂在哪条工具结果之后）。
    pub fn push_injection(&self, inj: Injection) {
        self.injections.lock().unwrap_or_else(poisoned).push(inj);
    }

    /// 当前已注入的批次快照（每次请求都要重新注入：请求是从外层历史重新拼的）。
    pub fn injections(&self) -> Vec<Injection> {
        self.injections.lock().unwrap_or_else(poisoned).clone()
    }

    /// 判定点①的决策核心（on_completion_call 的可单测接缝，2026-10-13 抽出：
    /// rig 的 HookContext 是 pub(crate) 构造，钩子方法本身进不了单测——决策
    /// 收在状态上，钩子方法只剩装配）。返回 Some(理由) = 本轮不发起新的模型
    /// 调用；None = 放行。
    pub(crate) fn gate_completion(&self) -> Option<String> {
        if self.stop.load(Ordering::Relaxed) {
            return Some(STOP_TEXT.to_string());
        }
        if self.budget.lock().unwrap_or_else(poisoned).exhausted() {
            return Some(wall_clock_turn_text(self.max_task_seconds));
        }
        None
    }

    /// 判定点② + 单轮调用上限的决策核心（on_tool_call 的可单测接缝，同上）。
    /// 先做单轮计数（turn 一变即新一轮，从零起），再依次过停止/墙钟/单轮上限
    /// 三道闸。返回 Some(回执文案) = 不派发（模型收到「未派发」回执）；
    /// None = 放行派发。
    pub(crate) fn gate_tool_call(&self, turn: usize) -> Option<String> {
        let nth = {
            let mut round = self.round.lock().unwrap_or_else(poisoned);
            if round.turn != turn {
                round.turn = turn;
                round.calls = 0;
                self.round_capped.store(false, Ordering::Relaxed);
            }
            round.calls += 1;
            round.calls
        };
        if self.stop.load(Ordering::Relaxed) {
            return Some(STOP_TEXT.to_string());
        }
        if self.budget.lock().unwrap_or_else(poisoned).exhausted() {
            return Some(wall_clock_call_text(self.max_task_seconds));
        }
        if self.max_calls_per_round > 0 && nth > self.max_calls_per_round as usize {
            if !self.round_capped.swap(true, Ordering::Relaxed) {
                errln!(
                    "[上限] 本轮工具调用超过单轮上限 {} 条，超出部分未派发\
                     （模型收到「未派发」回执，不是执行失败）",
                    self.max_calls_per_round
                );
            }
            return Some(format!(
                "未派发：本轮工具调用数超过单轮上限（{} 条），本条调用没有下发\
                 （不是执行失败，也没有产生任何副作用）。",
                self.max_calls_per_round
            ));
        }
        None
    }
}

/// mutex 中毒恢复的唯一口径（2026-10-01 收敛，bridge.rs 的 ICA 账本 11 处匿名
/// `unwrap_or_else(|e| e.into_inner())` 换用此单点）：中毒是「某持锁线程 panic 过」
/// 的信号，恢复内部值的同时必须留痕——静默恢复会让 hook/ICA 状态完整性问题的
/// 第一次现场消失。共享状态经 panic 中途改写过属逻辑错误，留痕只是让它可观测，
/// 恢复口径本身与旧行为一致。
pub(crate) fn poisoned<T>(e: std::sync::PoisonError<T>) -> T {
    // errln（而非裸 eprintln）：检查式写出（out.rs），stderr 坏了也不 panic——
    // 本函数处在锁恢复路径上，再 panic 就没有恢复可言了（H2 口径）。
    errln!("[warn] mutex poisoned — recovering inner value");
    e.into_inner()
}

/// 消息里有没有工具结果（rig 把工具回执装在 `User{content:[ToolResult..]}` 里）。
pub fn has_tool_result(m: &Message) -> bool {
    match m {
        Message::User { content } => content
            .iter()
            .any(|c| matches!(c, UserContent::ToolResult(_))),
        _ => false,
    }
}

/// 把已注入的图片批次物化进一段历史（任务结束后调用）：每个批次插到它对应的
/// 工具结果消息**之后**，与 C++「tool 消息之后另起一条 user 图片消息」逐位同序。
/// `msgs` 是整份历史（序号从头数，`prefix_tool_results = 0`）。
pub fn materialize(msgs: Vec<Message>, injections: &[Injection]) -> Vec<Message> {
    materialize_appended(msgs, injections, 0)
}

/// materialize 的增量形态：`msgs` 只是历史的**尾段**（本轮新增），落点定位要把
/// 前缀扣掉——`Injection::ordinal` 按「整份请求历史从头数」编号（model.rs 的
/// `apply_injections` 同口径），`prefix_tool_results` 是前缀历史里的工具结果条数。
/// 供追加收尾路径用，避免为物化把整份历史（含 base64 图片）搬进搬出；序号落不进
/// 尾段时照旧响亮告警，绝不静默丢图。
pub fn materialize_appended(
    mut msgs: Vec<Message>,
    injections: &[Injection],
    prefix_tool_results: usize,
) -> Vec<Message> {
    let mut ordered: Vec<&Injection> = injections.iter().collect();
    ordered.sort_by_key(|i| i.ordinal);
    for inj in ordered {
        let mut count = prefix_tool_results;
        let mut at = None;
        for (idx, m) in msgs.iter().enumerate() {
            if has_tool_result(m) {
                count += 1;
                if count == inj.ordinal {
                    at = Some(idx);
                    break;
                }
            }
        }
        match at {
            Some(idx) => msgs.insert(
                idx + 1,
                Message::User {
                    content: inj.content.clone(),
                },
            ),
            None => errln!(
                "[mybot-agent] 警告: 图片批次（第 {} 条工具结果之后）找不到落点，未并入会话历史；\
                 该批次在本次任务里已按请求内注注入给模型",
                inj.ordinal
            ),
        }
    }
    msgs
}

/// 墙钟判定点①的文案（逐字同 C++）。
fn wall_clock_turn_text(seconds: i64) -> String {
    format!(
        "达到单任务墙钟预算（{seconds} 秒）仍未得到最终回答；此前已执行的动作不会回退。\
         可调大 --llm-task-timeout（或配置文件的 max_task_seconds），或把任务拆小"
    )
}

/// 墙钟判定点②的逐条回执文案（逐字同 C++）。
fn wall_clock_call_text(seconds: i64) -> String {
    format!(
        "未派发：单任务墙钟预算（{seconds} 秒）已耗尽，本条调用没有下发\
         （不是执行失败，也没有产生任何副作用）。"
    )
}

/// 循环层钩子。
pub struct SessionHook {
    state: std::sync::Arc<HookState>,
}

impl SessionHook {
    pub fn new(state: std::sync::Arc<HookState>) -> Self {
        Self { state }
    }
}

impl AgentHook for SessionHook {
    /// 判定点① + 回滚边界（见模块头）。
    async fn on_completion_call(
        &self,
        _ctx: &HookContext,
        event: CompletionCallEvent<'_>,
    ) -> CompletionCallAction {
        // D4：Ctrl-C 之后不再发起新的模型轮，让主流程尽快走清理链；
        // 墙钟耗尽同理（判定核心在 gate_completion，见模块头「可单测接缝」注）
        if let Some(reason) = self.state.gate_completion() {
            return CompletionCallAction::Stop(reason);
        }
        // 回滚边界：turn 1 时 history 恰是任务开始前的历史（本轮 user 任务还只是
        // prompt）→ 失败要连它一起丢掉，与 C++ 的 `complete = base` 同口径；
        // turn ≥ 2 时 history + prompt 是一次完整轮（assistant.tool_calls + 全部
        // tool 回执）——硬件动作已经发生，回滚不该假装什么都没做。
        //
        // 为什么逐轮 `to_vec()` 整份克隆而**不**只记边界下标：完整轮的消息只
        // 存在于 runner 的内部历史里（Session::history 在任务期间不更新），失败
        // 回滚要把它们「带回来」而不是截掉，下标取不到内容。代价是每次模型
        // 调用一次 O(历史) 的拷贝——与请求管线每轮对同一份历史的序列化同量级，
        // 不是额外的主要开销；带图片的长会话想省掉它，得让 rig 暴露「任务结束
        // 时的完整 transcript」出口（上游 API 变更），暂不为省一份拷贝引耦合。
        let boundary = if event.turn <= 1 {
            event.history.to_vec()
        } else {
            let mut v = event.history.to_vec();
            v.push(event.prompt.clone());
            v
        };
        *self.state.rollback.lock().unwrap_or_else(poisoned) = Some(boundary);
        self.state.current_turn.store(event.turn, Ordering::Relaxed);
        CompletionCallAction::Continue
    }

    /// 判定点② + 单轮调用上限。
    async fn on_tool_call(&self, ctx: &HookContext, _event: ToolCall<'_>) -> ToolCallAction {
        // 判定核心（单轮计数 + 停止/墙钟/单轮上限三道闸）在 gate_tool_call——
        // 决策收在状态上便于单测；「未派发」语义与 C++ 的 excess 分支一致
        // （呈现位置不同：C++ 挂 assistant 文本，rig 挂回执）。
        match self.state.gate_tool_call(ctx.turn()) {
            Some(receipt) => ToolCallAction::Skip(receipt),
            None => ToolCallAction::Run,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rig_agent::completion::message::ToolResultContent;

    fn tool_result_msg(id: &str) -> Message {
        Message::User {
            content: vec![UserContent::tool_result(
                id,
                "capture_image",
                vec![ToolResultContent::Text("ok".to_string().into())],
            )],
        }
    }

    #[test]
    fn materialize_inserts_each_batch_after_its_own_tool_result() {
        let msgs = vec![
            Message::user("任务一"),
            tool_result_msg("call_0"),
            Message::assistant("一做完"),
            Message::user("任务二"),
            tool_result_msg("call_1"),
            Message::assistant("二做完"),
        ];
        let injections = vec![
            Injection {
                ordinal: 2,
                content: vec![UserContent::text("批二")],
            },
            Injection {
                ordinal: 1,
                content: vec![UserContent::text("批一")],
            },
        ];
        let out = materialize(msgs, &injections);
        assert_eq!(out.len(), 8);
        // 批一跟在第一条工具结果之后；批二跟在第二条之后（各自归位，互不串位）
        assert_eq!(out[2], Message::user("批一"));
        assert_eq!(out[3], Message::assistant("一做完"));
        assert_eq!(out[6], Message::user("批二"));
        assert_eq!(out[7], Message::assistant("二做完"));
    }

    #[test]
    fn materialize_appended_offsets_ordinals_past_prefix() {
        // 前缀历史已有 2 条工具结果；尾段（本轮新增）里的工具结果是全局第 3 条。
        let injections = vec![Injection {
            ordinal: 3,
            content: vec![UserContent::text("批三")],
        }];
        let out = materialize_appended(tail_with_one_tool_result(), &injections, 2);
        assert_eq!(out.len(), 4);
        assert_eq!(out[2], Message::user("批三")); // 跟在 call_2 之后
        assert_eq!(out[3], Message::assistant("二做完"));
    }

    #[test]
    fn materialize_appended_never_lands_on_a_prefix_result() {
        // 序号指向前缀里的工具结果（全局第 2 条）时尾段里找不到落点：原样返回、
        // 响亮告警（告警文本不进断言），绝不插错位。
        let injections = vec![Injection {
            ordinal: 2,
            content: vec![UserContent::text("批二")],
        }];
        let out = materialize_appended(tail_with_one_tool_result(), &injections, 2);
        assert_eq!(out.len(), 3);
    }

    fn tail_with_one_tool_result() -> Vec<Message> {
        vec![
            Message::user("任务二"),
            tool_result_msg("call_2"),
            Message::assistant("二做完"),
        ]
    }

    #[test]
    fn has_tool_result_distinguishes_plain_user_messages() {
        assert!(has_tool_result(&tool_result_msg("call_0")));
        assert!(!has_tool_result(&Message::user("任务")));
        assert!(!has_tool_result(&Message::assistant("答")));
        // 图片后注（user + Image）不算工具结果
        let img = Message::User {
            content: vec![UserContent::image_base64("AAAA", None, None)],
        };
        assert!(!has_tool_result(&img));
    }

    fn state_with(max_calls: i64) -> HookState {
        HookState::new(60, max_calls, TaskBudget::new(0, 0, 0))
    }

    #[test]
    fn gate_tool_call_caps_round_and_resets_on_new_turn() {
        let st = state_with(2);
        // 第 1 轮：前 2 条放行，第 3 条起「未派发」且回执点名上限与无副作用
        assert!(st.gate_tool_call(1).is_none());
        assert!(st.gate_tool_call(1).is_none());
        for _ in 0..3 {
            let why = st.gate_tool_call(1).expect("超限应 Skip");
            assert!(why.contains("本轮工具调用数超过单轮上限（2 条）"), "{why}");
            assert!(why.contains("不是执行失败，也没有产生任何副作用"), "{why}");
        }
        // 第 2 轮：计数随 turn 重置，重新放行
        assert!(st.gate_tool_call(2).is_none());
        assert!(st.gate_tool_call(2).is_none());
        assert!(st.gate_tool_call(2).is_some());
    }

    #[test]
    fn gate_tool_call_zero_limit_means_unlimited() {
        let st = state_with(0);
        for _ in 0..10 {
            assert!(st.gate_tool_call(1).is_none(), "0 = 不限");
        }
    }

    #[test]
    fn stop_latches_across_begin_task_and_gates_both_sides() {
        let st = state_with(0);
        // 未停止：两侧放行
        assert!(st.gate_completion().is_none());
        assert!(st.gate_tool_call(1).is_none());
        st.stop.store(true, Ordering::Relaxed);
        // 判定点①：不再发起新的模型轮，文案逐字同 C++
        assert_eq!(st.gate_completion().as_deref(), Some(STOP_TEXT));
        // 判定点②：本条不派发（回执同口径）
        assert_eq!(st.gate_tool_call(1).as_deref(), Some(STOP_TEXT));
        // begin_task 清观测值但**不清 stop**——取消是操作者的意思，锁存到进程退出
        st.begin_task();
        assert_eq!(st.gate_completion().as_deref(), Some(STOP_TEXT));
    }

    #[test]
    fn wall_clock_gates_report_verbatim_texts() {
        let mut budget = TaskBudget::new(0, 0, 30);
        // 把任务起点拨回过去：墙钟 30 秒预算已耗尽（单调时钟，不受 NTP 拨动影响）
        budget.task_start = std::time::Instant::now() - std::time::Duration::from_secs(31);
        let st = HookState::new(30, 0, budget);
        // 判定点①：不再发起新的模型调用，如实说明「已执行的动作不会回退」
        let why = st.gate_completion().expect("墙钟耗尽应停");
        assert_eq!(
            why,
            "达到单任务墙钟预算（30 秒）仍未得到最终回答；此前已执行的动作不会回退。\
             可调大 --llm-task-timeout（或配置文件的 max_task_seconds），或把任务拆小"
        );
        // 判定点②：剩余调用不派发，回执说清「没下发、也没有副作用」
        let why = st.gate_tool_call(1).expect("墙钟耗尽应 Skip");
        assert_eq!(
            why,
            "未派发：单任务墙钟预算（30 秒）已耗尽，本条调用没有下发\
             （不是执行失败，也没有产生任何副作用）。"
        );
    }

    #[test]
    fn begin_task_clears_observations_and_image_queues() {
        let st = state_with(0);
        st.record_call(CallRecord {
            turn: 1,
            ..Default::default()
        });
        st.push_image("data:image/png;base64,AAAA".to_string());
        st.push_injection(Injection {
            ordinal: 1,
            content: vec![],
        });
        st.record_local_tool(LocalToolRecord {
            turn: 1,
            ..Default::default()
        });
        assert_eq!(st.drain_calls().len(), 1);
        assert_eq!(st.drain_local_tools().len(), 1);
        assert_eq!(st.take_pending_images().len(), 1);
        assert_eq!(st.take_injections().len(), 1);
        // 再填一遍：begin_task 后应全空（回滚边界回到「任务开始前」= None）
        st.record_call(CallRecord {
            turn: 2,
            ..Default::default()
        });
        st.record_local_tool(LocalToolRecord {
            turn: 2,
            ..Default::default()
        });
        st.push_image("data:image/png;base64,BBBB".to_string());
        st.push_injection(Injection {
            ordinal: 2,
            content: vec![],
        });
        st.begin_task();
        assert!(st.drain_calls().is_empty());
        assert!(st.drain_local_tools().is_empty());
        assert!(st.take_pending_images().is_empty());
        assert!(st.take_injections().is_empty());
        assert!(st.rollback_boundary().is_none());
    }
}

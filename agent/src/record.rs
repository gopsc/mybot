//! record.rs —— 录制模式（--record / --record-dir）：会话完整上下文的采集通道
//!
//! **定位**：审计轨迹记「计时与次数」，会话文件记「可恢复的历史文本」（图片刻意
//! 不落盘），录制是第三条通道——把每段会话的**完整详细上下文**留档，主要用途是
//! **微调小模型的训练数据采集**（scripts/record_export.py 导出），顺带供事后复盘
//! 「模型当时实际看到了什么（含照片）、说了什么」。
//!
//! ## 与既有两条通道的分工（不改它们的契约）
//!
//! * 会话文件 v1 行格式**逐字节不变**：图片排除是已留档的有意决策（体积与隐私），
//!   录制不改写它；两者互补——会话文件有未裁剪的全量文本，录制段有图片本体，
//!   `record_export.py --context full` 靠这对组合还原占位文本背后的画面。
//! * 审计日志**不替代**：工具行的计时/exit_code/image_fp 仍由两端审计落；录制里
//!   不重复记工具事件——工具调用的参数在 assistant 消息的 tool_calls 里、回执全文
//!   在 tool_result 里，消息流本身就是训练数据要的形态。
//!
//! ## 布局（一个录制段 = 一个目录，append-only）
//!
//! ```text
//! <录制根>/                       # --record-dir 显式给，或 $MYBOT_HOME/robots/<机器人>/recordings
//! ├── latest                      # 指针（0600）：当前段目录名，续接时链回前段
//! └── <UTC 段名>/                 # 段目录（0700，O_EXCL 占位，同名退 -<pid>）
//!     ├── meta.json               # 会话元信息（0600）：模型/工具/指纹/落点，写一次
//!     ├── system.txt              # 系统提示词全文（0600，写一次）——重放需要，会话文件刻意不落它
//!     ├── events.jsonl            # 事件流（0600，逐行 flush，追加写）
//!     └── images/<序号>-<指纹>.<ext>   # 图片本体（0600，base64 解码后的二进制）
//! ```
//!
//! ## 事件流（delta + 水位，不整轮快照）
//!
//! 每行 `{ts, seq, event, …}`。消息按**增量**记录：REPL 在每轮任务结束时把会话
//! 历史交给 [`RecordStore::record_history`]，本模块只落水位之后的新消息——任意轮次
//! 的有效上下文可由「事件重放」重建（任务块边界 = task_begin，轮边界 = assistant
//! 消息），不需要每轮整份快照（那是 O(n²)）。三个会改写历史长度的操作各有对应
//! 事件维持水位一致性：裁剪（[`Self::note_evicted`] 回退水位）、/clear
//! （[`Self::reset_after_clear`] 归零）、续接（[`Self::note_resumed`] 直接对齐，
//! 前缀由会话文件承载，meta 记路径）。
//!
//! 消息编码保持 rig 的**内容块次序**（一条 user 消息可能是
//! `[tool_result, text(图片说明), image]`——正是图片注入后的线上形态），图片块
//! 只落引用 `{file, bytes, fp, mime}`，base64 永不进 JSONL。
//!
//! ## 失败语义（对齐会话文件）
//!
//! * 打不开/建不成 → 启动期 Err（main 退出 2，配置错误不碰真机）；
//! * 中途写失败 → stderr 告警**一次**并停用录制，对话照常进行（不静默丢历史，
//!   也不打断机器人）；水位记账继续，但停用后不再恢复。
//! * 图片仓总量超 `--record-max-bytes` → **响亮降级**为「仅元数据」（`stored:false`），
//!   告警一次；文本事件不受限（体积小）。缺省 0 = 不限。
//!
//! ## 密钥纪律
//!
//! meta 只记 `api_key_source` 枚举与脱敏后的接入点（复用 audit 的
//! `sanitize_endpoint`，剥 query/userinfo）；**密钥值绝不出现**。工具回执按
//! 「进入上下文的原样」记录——后端工具已过 maskSecretsInText，`http_fetch`
//! 在定界前过同一套形态的 `mask_secrets`。不在那套形态里的凭据仍会进录制段。

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

use base64::Engine as _;
use rig_agent::completion::message::{
    DocumentSourceKind, ImageMediaType, MimeType, ToolResultContent, UserContent,
};
use rig_agent::completion::{AssistantContent, Message};
use serde_json::{json, Map, Value};

use crate::audit::{audit_timestamp, fingerprint64, fingerprint64_bytes, sanitize_endpoint};
use crate::hook::CallRecord;
use crate::out::errln;
use crate::session::reasoning_text;
use crate::session_store::{ensure_dir_0700, robot_dir_name, segment_name};

/// 录制格式版本（meta 的 `version`；升格格式时递增，导出器按版本分派）。
pub const RECORD_VERSION: i64 = 1;

/// 缺省布局的录制根：`$MYBOT_HOME/robots/<机器人>/recordings`。
pub fn default_record_root(state_dir: &str, robot_name: &str) -> String {
    format!(
        "{state_dir}/robots/{}/recordings",
        robot_dir_name(robot_name)
    )
}

/// main 的装配口：未开启返回 `Ok(None)`；开启则解析录制根（显式 `--record-dir`
/// 优先，否则缺省布局——缺省根要等后端给出机器人名，只能在 main 这一层拼）。
/// `--record` 无状态目录的判据已在 `config::build` 报过，这里到不了。
/// 参数多是门面本色：全数展开进 [`RecordOpen`] 字段，为凑数再包一层分组结构
/// 只增加转发，故显式放行该 lint（先例：audit.rs now_timespec）。
#[allow(clippy::too_many_arguments)]
pub fn open_from_config(
    cfg: &crate::config::Config,
    material: &crate::prompt::PromptMaterial,
    tool_names: &[String],
    specs: &[crate::toolspec::ToolSpec],
    preamble: &str,
    audit_session_id: &str,
    resumed: bool,
    now_sec: i64,
) -> Result<Option<RecordStore>, String> {
    if !cfg.record_enabled {
        return Ok(None);
    }
    let root = if !cfg.record_dir.is_empty() {
        cfg.record_dir.clone()
    } else {
        default_record_root(&cfg.state_dir, &material.robot_name)
    };
    RecordStore::open(RecordOpen {
        root,
        max_image_bytes: cfg.record_max_image_bytes.max(0) as u64,
        session_file: &cfg.session_file,
        session_id: audit_session_id,
        robot: &material.robot_name,
        driver: &cfg.driver,
        model: &cfg.model,
        endpoint: &cfg.endpoint,
        api_key_source: cfg.api_key_source,
        tools: tool_names,
        tool_specs: tool_specs_json(specs),
        system_prompt: preamble,
        stream: cfg.stream,
        resumed,
        now_sec,
    })
    .map(Some)
}

/// `Vec<ToolSpec>` → meta 的 `tool_specs` 数组（一次序列化，main 装配时调用）。
fn tool_specs_json(specs: &[crate::toolspec::ToolSpec]) -> Value {
    Value::Array(
        specs
            .iter()
            .map(|s| {
                json!({
                    "name": s.name,
                    "description": s.description,
                    "parameters": s.parameters,
                })
            })
            .collect(),
    )
}

/// 录制段打开参数（main 装配；字段语义见 meta.json 的落盘键）。
pub struct RecordOpen<'a> {
    /// 录制根（已解析：显式目录或缺省布局）
    pub root: String,
    /// 图片仓总量上限（字节，0 = 不限）
    pub max_image_bytes: u64,
    pub session_file: &'a str,
    pub session_id: &'a str,
    pub robot: &'a str,
    pub driver: &'a str,
    pub model: &'a str,
    /// 原始接入点（落盘前经 sanitize_endpoint 脱敏）
    pub endpoint: &'a str,
    pub api_key_source: &'a str,
    pub tools: &'a [String],
    /// 工具 schema 快照（`[{name,description,parameters}]`，随样本导出——微调后
    /// 的模型与线上工具面一致；工具集会话中途不变，写一次就够）
    pub tool_specs: Value,
    /// 系统提示词全文（落 system.txt；指纹落 meta）
    pub system_prompt: &'a str,
    pub stream: bool,
    /// 会话是否续接（决定要不要读 latest 指针链回前段）
    pub resumed: bool,
    pub now_sec: i64,
}

/// 一个录制段。`events = None` = 已停用（写失败后降级，见模块头）。
#[derive(Debug)]
pub struct RecordStore {
    dir: PathBuf,
    events: Option<File>,
    seq: u64,
    /// 已记录的消息条数（增量水位，见模块头「事件流」）
    recorded: usize,
    image_seq: u64,
    image_bytes_used: u64,
    max_image_bytes: u64,
    /// 图片仓已降级（只落元数据）——只告警一次
    degraded: bool,
    /// 事件/图片写失败已告警——只告警一次
    warn_broken: bool,
    /// 图片指纹 → 文件名（去重：同一画面反复进上下文只存一份）
    index: HashMap<String, String>,
    stats_images: u64,
    stats_events: u64,
}

impl RecordStore {
    /// 占一个新录制段：建目录链（0700）→ O_EXCL 占段目录 → 写指针/meta/system →
    /// 打开事件流并落 session_start。任一步失败即 Err（main 退出 2）。
    pub fn open(o: RecordOpen) -> Result<Self, String> {
        if let Some(w) = dir_perms_warning(&o.root) {
            errln!("[mybot-agent] {w}");
        }
        ensure_dir_0700(&o.root)?;
        let segment = create_segment_dir(&o.root, o.now_sec)?;
        let dir = PathBuf::from(format!("{}/{}", o.root, segment));
        fs::create_dir_all(dir.join("images"))
            .map_err(|e| format!("无法创建录制图片目录 {}（{e}）", dir.display()))?;
        crate::fssec::set_dir_0700(&dir.join("images"), "录制目录")?;

        // 续接链：resumed 时读指针找前一段（读不到就 None，不阻断——链是尽力而为）
        let resumed_from = if o.resumed {
            read_pointer_best_effort(&o.root)
        } else {
            None
        };
        write_pointer(&o.root, &segment)?;

        let system_fp = fingerprint64(o.system_prompt);
        let tools_fp = crate::session::tools_fingerprint(o.tools);
        let meta = json!({
            "version": RECORD_VERSION,
            "agent_version": env!("CARGO_PKG_VERSION"),
            "started": audit_timestamp(),
            "segment": segment,
            "session_id": o.session_id,
            "session_file": o.session_file,
            "robot": o.robot,
            "driver": o.driver,
            "model": o.model,
            "endpoint": sanitize_endpoint(o.endpoint),
            "api_key_source": o.api_key_source,
            "tools": o.tools,
            "tools_fp": tools_fp,
            "tool_specs": o.tool_specs,
            "system_fp": system_fp,
            "system_prompt_file": "system.txt",
            "stream": o.stream,
            "resumed": o.resumed,
            "resumed_from": resumed_from,
            "record_max_image_bytes": o.max_image_bytes,
        });
        write_file_0600(&dir.join("meta.json"), meta.to_string().as_bytes())?;
        write_file_0600(&dir.join("system.txt"), o.system_prompt.as_bytes())?;

        let events = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(dir.join("events.jsonl"))
            .map_err(|e| format!("无法创建录制事件流 {}（{e}）", dir.display()))?;
        set_file_0600(&dir.join("events.jsonl"));

        let mut store = Self {
            dir,
            events: Some(events),
            seq: 0,
            recorded: 0,
            image_seq: 0,
            image_bytes_used: 0,
            max_image_bytes: o.max_image_bytes,
            degraded: false,
            warn_broken: false,
            index: HashMap::new(),
            stats_images: 0,
            stats_events: 0,
        };
        store.emit("session_start", |line| {
            line.insert("dir".into(), json!(segment));
            line.insert("session_file".into(), json!(o.session_file));
            line.insert("robot".into(), json!(o.robot));
            line.insert("model".into(), json!(o.model));
            line.insert("resumed".into(), json!(o.resumed));
            if let Some(from) = resumed_from.as_deref() {
                line.insert("resumed_from".into(), json!(from));
            }
        });
        Ok(store)
    }

    /// 段目录名（meta/指针/`/status` 展示用）。
    pub fn dir(&self) -> String {
        self.dir.to_string_lossy().to_string()
    }

    /// `/status` 的统计：已落事件数与图片数。
    pub fn stats(&self) -> (u64, u64) {
        (self.stats_events, self.stats_images)
    }

    /// 续接对齐水位：恢复进来的 N 条历史不重复落事件（前缀由会话文件承载），
    /// 只落一行 `resume` 说明从哪来、多少条。
    pub fn note_resumed(&mut self, messages: usize, session_file: &str) {
        self.recorded = messages;
        self.emit("resume", |line| {
            line.insert("messages".into(), json!(messages));
            line.insert("session_file".into(), json!(session_file));
        });
    }

    /// 历史裁剪：被裁的 N 条已经作为消息事件落在盘上（录制是全量留档，比内存历史
    /// 只多不少），水位回退 N 保持与内存历史的前缀对齐。
    pub fn note_evicted(&mut self, messages: usize) {
        self.recorded = self.recorded.saturating_sub(messages);
        self.emit("history_evict", |line| {
            line.insert("messages".into(), json!(messages));
        });
    }

    /// `/clear`：水位归零（其后新任务的消息从 0 重数）；已录事件原样保留。
    pub fn reset_after_clear(&mut self) {
        self.recorded = 0;
        self.emit("clear", |_| {});
    }

    pub fn task_begin(&mut self, task: &str) {
        let task = task.to_string();
        self.emit("task_begin", |line| {
            line.insert("task".into(), json!(task));
        });
    }

    pub fn task_end(&mut self, ok: bool, error: &str) {
        self.emit("task_end", |line| {
            line.insert("ok".into(), json!(ok));
            if !error.is_empty() {
                line.insert("error".into(), json!(error));
            }
        });
    }

    /// 每次模型调用的元数据（同 CallRecord 的口径；`kind` 区分任务轮与摘要轮）。
    pub fn model_calls(&mut self, calls: &[CallRecord], kind: &str) {
        for rec in calls {
            let r = rec.clone();
            self.emit("model_call", |line| {
                line.insert("kind".into(), json!(kind));
                // 任务轮记 0-based（与审计 model 行同口径）；摘要轮不带 turn
                if kind == "task" {
                    line.insert("turn".into(), json!(r.turn.saturating_sub(1) as i64));
                }
                line.insert("ok".into(), json!(r.ok));
                if !r.error.is_empty() {
                    line.insert("error".into(), json!(r.error));
                }
                line.insert("ms".into(), json!(r.ms));
                if r.req_bytes > 0 {
                    line.insert("req_bytes".into(), json!(r.req_bytes));
                }
                if r.resp_bytes > 0 {
                    line.insert("resp_bytes".into(), json!(r.resp_bytes));
                }
                if r.attempts > 0 {
                    line.insert("attempts".into(), json!(r.attempts));
                }
                if let Some(v) = r.prompt_tokens {
                    line.insert("prompt_tokens".into(), json!(v));
                }
                if let Some(v) = r.completion_tokens {
                    line.insert("completion_tokens".into(), json!(v));
                }
            });
        }
    }

    /// 历史摘要落成（或失败）：正文全文进事件（≤ max_summary_bytes，量级小），
    /// 导出器据此重建「有效上下文」——被裁块在请求里已由这段摘要顶替。
    pub fn history_summary(&mut self, ok: bool, text: &str, error: &str) {
        let (text, error) = (text.to_string(), error.to_string());
        self.emit("history_summary", |line| {
            line.insert("ok".into(), json!(ok));
            if ok {
                line.insert("bytes".into(), json!(text.len()));
                line.insert("text".into(), json!(text));
            } else if !error.is_empty() {
                line.insert("error".into(), json!(error));
            }
        });
    }

    pub fn session_end(&mut self, status: &str, error: &str) {
        let (status, error) = (status.to_string(), error.to_string());
        self.emit("session_end", |line| {
            line.insert("status".into(), json!(status));
            if !error.is_empty() {
                line.insert("error".into(), json!(error));
            }
        });
    }

    /// 增量落消息：只编码水位之后的新消息（见模块头）。借用不移动——调用方随后
    /// 仍可把整份历史 `replace` 进 ConversationHistory。
    pub fn record_history(&mut self, history: &[Message]) {
        let start = self.recorded.min(history.len());
        for (idx, m) in history.iter().enumerate().skip(start) {
            if let Some(v) = self.encode_message(m) {
                let idx = idx as u64;
                self.emit("msg", |line| {
                    line.insert("idx".into(), json!(idx));
                    line.insert("msg".into(), v);
                });
            }
        }
        self.recorded = history.len();
    }

    /// rig Message → 事件里的消息对象。`None` = 不落（system 消息不在会话历史里；
    /// 调用方保证不会传，传了也不写）。编码保持内容块次序（见模块头）。
    fn encode_message(&mut self, m: &Message) -> Option<Value> {
        match m {
            Message::System { .. } => None,
            Message::User { content } => {
                let mut parts = Vec::with_capacity(content.len());
                for item in content {
                    match item {
                        UserContent::ToolResult(r) => {
                            let mut inner = Vec::new();
                            for c in &r.content {
                                inner.push(self.encode_tool_result_content(c));
                            }
                            parts.push(json!({
                                "type": "tool_result",
                                "call_id": r.call.as_str(),
                                "name": r.name,
                                "parts": inner,
                            }));
                        }
                        UserContent::Text(t) => {
                            parts.push(json!({ "type": "text", "text": t.text }));
                        }
                        UserContent::Image(i) => {
                            parts.push(self.store_image(&i.data, i.media_type.as_ref()));
                        }
                        // 本项目不产生音频/视频/文档；如实落成标记而不是静默丢
                        UserContent::Audio(a) => parts.push(json!({
                            "type": "audio", "bytes":
                            crate::placeholder::source_len(&a.data),
                        })),
                        UserContent::Video(v) => parts.push(json!({
                            "type": "video", "bytes":
                            crate::placeholder::source_len(&v.data),
                        })),
                        UserContent::Document(d) => parts.push(json!({
                            "type": "document", "bytes":
                            crate::placeholder::source_len(&d.data),
                        })),
                    }
                }
                Some(json!({ "role": "user", "parts": parts }))
            }
            Message::Assistant { id, content } => {
                let mut text = String::new();
                let mut calls: Vec<Value> = Vec::new();
                let mut reasoning = String::new();
                for item in content {
                    match item {
                        AssistantContent::Text(t) => text.push_str(&t.text),
                        AssistantContent::ToolCall(c) => calls.push(json!({
                            "id": c.id.as_str(),
                            "name": c.function.name,
                            // arguments 是对象（rig 的 ToolFunction::arguments），
                            // 原样落对象——导出器不必再解一层字符串
                            "arguments": c.function.arguments,
                        })),
                        AssistantContent::Reasoning(r) => {
                            let joined = r
                                .content
                                .iter()
                                .filter_map(reasoning_text)
                                .collect::<Vec<_>>()
                                .join("\n");
                            if !joined.is_empty() {
                                if !reasoning.is_empty() {
                                    reasoning.push('\n');
                                }
                                reasoning.push_str(&joined);
                            }
                        }
                        // assistant 侧图片本项目不产生；占位而不是静默丢（同 session.rs）
                        AssistantContent::Image(i) => text.push_str(&format!(
                            "[assistant 图片 {} 字节]",
                            crate::placeholder::source_len(&i.data)
                        )),
                    }
                }
                let mut v = json!({ "role": "assistant", "text": text });
                if !calls.is_empty() {
                    v["tool_calls"] = json!(calls);
                }
                if !reasoning.is_empty() {
                    v["reasoning"] = json!(reasoning);
                }
                if let Some(id) = id {
                    if !id.is_empty() {
                        v["id"] = json!(id);
                    }
                }
                Some(v)
            }
        }
    }

    fn encode_tool_result_content(&mut self, c: &ToolResultContent) -> Value {
        match c {
            ToolResultContent::Text(t) => json!({ "type": "text", "text": t.text }),
            ToolResultContent::Json { value } => {
                json!({ "type": "json", "json": value })
            }
            ToolResultContent::Image(i) => self.store_image(&i.data, i.media_type.as_ref()),
        }
    }

    /// 图片入库：解码 → 指纹 → 去重 → 落二进制文件，返回事件里的引用块。
    /// 不可解码/超预算/写失败都**不阻断**——落 `stored:false` 并说明原因，正文
    /// 事件照常（导出器据此知道画面缺失，而不是拿到一条静默残缺的记录）。
    fn store_image(&mut self, data: &DocumentSourceKind, media: Option<&ImageMediaType>) -> Value {
        let mime = media
            .map(|m| m.to_mime_type().to_string())
            .unwrap_or_else(|| "application/octet-stream".to_string());
        let ext = media.map(media_ext).unwrap_or("bin");
        // 取二进制：本项目链路里恒为 Base64（后端 data URL → model.rs 拆开）；
        // Raw 是调用方直接给字节的形态；其余来源拿不到字节，如实标注。
        let raw: Vec<u8> = match data {
            DocumentSourceKind::Base64(s) => {
                match base64::engine::general_purpose::STANDARD.decode(s.as_bytes()) {
                    Ok(b) => b,
                    Err(e) => {
                        return json!({
                            "type": "image", "mime": mime, "stored": false,
                            "reason": format!("base64 解码失败: {e}"),
                        });
                    }
                }
            }
            DocumentSourceKind::Raw(b) => b.clone(),
            other => {
                return json!({
                    "type": "image", "mime": mime, "stored": false,
                    "reason": format!("非内联图片源（{} 字节线上体积），未落盘",
                        crate::placeholder::source_len(other)),
                });
            }
        };
        let fp = fingerprint64_bytes(&raw);
        let bytes = raw.len() as u64;
        // 去重命中：同一画面（指纹相同）不重复落盘，引用已有文件
        if let Some(file) = self.index.get(&fp) {
            return json!({
                "type": "image", "mime": mime, "bytes": bytes, "fp": fp,
                "file": format!("images/{file}"), "stored": true, "dedup": true,
            });
        }
        // 预算：只约束图片仓（文本事件不受限）；超限响亮降级一次
        if self.max_image_bytes > 0 && self.image_bytes_used + bytes > self.max_image_bytes {
            if !self.degraded {
                self.degraded = true;
                errln!(
                    "[mybot-agent] 警告: 录制图片仓已达 --record-max-bytes 上限（{} 字节），\
                     后续图片只记元数据不落盘；文本事件不受影响",
                    self.max_image_bytes
                );
            }
            return json!({
                "type": "image", "mime": mime, "bytes": bytes, "fp": fp,
                "stored": false, "reason": "cap",
            });
        }
        let name = format!("{:04}-{fp}.{ext}", self.image_seq);
        self.image_seq += 1;
        let path = self.dir.join("images").join(&name);
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        crate::fssec::opts_0600(&mut opts);
        match opts.open(&path).and_then(|mut f| {
            f.write_all(&raw)?;
            f.flush()
        }) {
            Ok(()) => {
                self.image_bytes_used += bytes;
                self.stats_images += 1;
                self.index.insert(fp.clone(), name.clone());
                json!({
                    "type": "image", "mime": mime, "bytes": bytes, "fp": fp,
                    "file": format!("images/{name}"), "stored": true,
                })
            }
            Err(e) => {
                self.warn_broken_once(&format!("录制图片写入失败（{e}）"));
                json!({
                    "type": "image", "mime": mime, "bytes": bytes, "fp": fp,
                    "stored": false, "reason": "write_error",
                })
            }
        }
    }

    fn warn_broken_once(&mut self, what: &str) {
        if !self.warn_broken {
            self.warn_broken = true;
            errln!(
                "[mybot-agent] 警告: {what}；录制已停用（本次会话后续内容不再落录制），\
                 对话不受影响"
            );
        }
    }

    /// 落一行事件：公共字段 ts/seq，写失败告警一次并停用（水位等纯内存记账不受影响）。
    fn emit(&mut self, event: &str, fill: impl FnOnce(&mut Map<String, Value>)) {
        self.stats_events += 1;
        let Some(f) = self.events.as_mut() else {
            return;
        };
        let mut line = Map::new();
        line.insert("ts".into(), json!(audit_timestamp()));
        line.insert("seq".into(), json!(self.seq));
        line.insert("event".into(), json!(event));
        fill(&mut line);
        self.seq += 1;
        let mut text = Value::Object(line).to_string();
        text.push('\n');
        if f.write_all(text.as_bytes()).is_err() || f.flush().is_err() {
            let what = "录制事件流写入失败（磁盘满/权限？）".to_string();
            self.warn_broken_once(&what);
            self.events = None;
        }
    }
}

/// 段目录名（单测用；对外落点是 [`RecordStore::dir`] 的完整路径）。
#[cfg(test)]
fn store_dir_name(store: &RecordStore) -> String {
    store
        .dir
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn media_ext(m: &ImageMediaType) -> &'static str {
    match m {
        ImageMediaType::JPEG => "jpg",
        ImageMediaType::PNG => "png",
        ImageMediaType::GIF => "gif",
        ImageMediaType::WEBP => "webp",
        ImageMediaType::HEIC => "heic",
        ImageMediaType::HEIF => "heif",
        ImageMediaType::SVG => "svg",
    }
}

/// O_EXCL 占一个段目录；同名退 `-<pid>`、`-<pid>-<n>`（同 session_store::create_segment
/// 的判据，目录版；第五轮 Phase 4 评估过不合并两者——占文件 vs 占目录、报错文案不同，
/// 抽象面大于复制面）。返回段目录名。
fn create_segment_dir(root: &str, now_sec: i64) -> Result<String, String> {
    let base = segment_name(now_sec);
    for attempt in 0..16u32 {
        let name = match attempt {
            0 => base.clone(),
            1 => format!("{base}-{}", std::process::id()),
            n => format!("{base}-{}-{n}", std::process::id()),
        };
        let path = format!("{root}/{name}");
        match fs::create_dir(&path) {
            Ok(()) => {
                crate::fssec::set_dir_0700(std::path::Path::new(&path), "录制目录")?;
                return Ok(name);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("无法创建录制段 {path}（{e}）")),
        }
    }
    Err(format!(
        "无法在同秒内为 {base} 找到可用录制段名（同名冲突过多）"
    ))
}

fn write_file_0600(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    crate::fssec::opts_0600(&mut opts);
    let mut f = opts
        .open(path)
        .map_err(|e| format!("无法创建 {}（{e}）", path.display()))?;
    f.write_all(bytes)
        .and_then(|()| f.flush())
        .map_err(|e| format!("写入 {} 失败（{e}）", path.display()))
}

fn set_file_0600(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

/// 段目录指针（`<root>/latest`，0600，tmp+rename 原子落）：内容是段目录名。
/// 只在名字「像段名」（`[A-Za-z0-9_-]{1,64}`）时采纳——指针是磁盘上的可变内容，
/// 按不可信输入对待，不把它原样拼进路径。第五轮 Phase 4 评估过不与
/// session_store::write_pointer 合并——那边带 fsync、指针名/文案不同，语义差异是实的。
fn write_pointer(root: &str, segment: &str) -> Result<(), String> {
    let ptr = format!("{root}/latest");
    let tmp = format!("{ptr}.{}.tmp", std::process::id());
    write_file_0600(std::path::Path::new(&tmp), segment.as_bytes())
        .map_err(|e| format!("写入录制段指针失败（{e}）"))?;
    fs::rename(&tmp, &ptr).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("无法把录制段指针落到 {ptr}（{e}）")
    })
}

fn read_pointer_best_effort(root: &str) -> Option<String> {
    let name = fs::read_to_string(format!("{root}/latest")).ok()?;
    let name = name.trim().to_string();
    let ok = !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    ok.then_some(name)
}

/// 录制根目录已存在且权限宽于 0700 时的告警（判据单点在 [`crate::fssec::wide_perms`]，
/// 与 audit 的 wide_perms_warning 同源；新建目录由 ensure_dir_0700 兜住，不会走到这里）。
fn dir_perms_warning(root: &str) -> Option<String> {
    crate::fssec::wide_perms(root, crate::fssec::PermKind::Dir).then(|| {
        format!(
            "警告: 录制根目录 '{root}' 权限宽于 700（录制含完整对话与图片，同等敏感），\
             建议 chmod 700 {root}"
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rig_agent::completion::message::{
        ImageMediaType, Reasoning, ReasoningContent, ToolFunction, ToolResultContent,
    };

    fn tmpdir(tag: &str) -> PathBuf {
        crate::testutil::tmpdir("mybot_record", tag)
    }

    fn open_store(root: &std::path::Path, max_image_bytes: u64) -> RecordStore {
        RecordStore::open(RecordOpen {
            root: root.to_string_lossy().to_string(),
            max_image_bytes,
            session_file: "/tmp/s.jsonl",
            session_id: "sess1",
            robot: "relay-test",
            driver: "LlmOpenAI",
            model: "m0",
            endpoint: "https://user:tok@host/v1/chat?key=SECRET",
            api_key_source: "env",
            tools: &["capture_image".to_string(), "run_action_script".to_string()],
            tool_specs: serde_json::json!([
                {"name": "capture_image", "description": "拍一张", "parameters": {"type": "object"}}
            ]),
            system_prompt: "你是测试机器人",
            stream: true,
            resumed: false,
            now_sec: 1_700_000_000,
        })
        .unwrap()
    }

    fn events(store: &RecordStore) -> Vec<Value> {
        std::fs::read_to_string(store.dir.join("events.jsonl"))
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn image_msg(b64: &str) -> Message {
        Message::User {
            content: vec![
                UserContent::text("以上工具返回的图片如下"),
                UserContent::image_base64(b64, Some(ImageMediaType::PNG), None),
            ],
        }
    }

    #[test]
    fn open_lays_out_meta_system_pointer_and_start_event() {
        let root = tmpdir("layout");
        let store = open_store(&root, 0);
        // meta：版本/指纹/脱敏接入点；密钥与凭据不出现
        let meta: Value =
            serde_json::from_str(&std::fs::read_to_string(store.dir.join("meta.json")).unwrap())
                .unwrap();
        assert_eq!(meta["version"], RECORD_VERSION);
        assert_eq!(meta["robot"], "relay-test");
        assert_eq!(meta["endpoint"], "https://host/v1/chat");
        assert_eq!(meta["system_prompt_file"], "system.txt");
        assert_eq!(meta["tools"].as_array().unwrap().len(), 2);
        assert_eq!(meta["system_fp"], fingerprint64("你是测试机器人"));
        let all = std::fs::read_to_string(store.dir.join("meta.json")).unwrap();
        assert!(
            !all.contains("SECRET") && !all.contains("user:tok"),
            "{all}"
        );
        assert!(
            all.contains("\"tool_specs\"") && all.contains("capture_image"),
            "工具 schema 快照应在 meta: {all}"
        );
        assert_eq!(
            std::fs::read_to_string(store.dir.join("system.txt")).unwrap(),
            "你是测试机器人"
        );
        // 指针指向段目录
        let seg = store_dir_name(&store);
        assert!(seg.starts_with("20231114T"));
        assert_eq!(std::fs::read_to_string(root.join("latest")).unwrap(), seg);
        // 首事件是 session_start
        let evs = events(&store);
        assert_eq!(evs[0]["event"], "session_start");
        assert_eq!(evs[0]["seq"], 0);
        assert!(evs[0]["ts"].is_string());
    }

    #[test]
    fn perms_are_0700_dir_and_0600_files() {
        use std::os::unix::fs::PermissionsExt;
        let root = tmpdir("perms");
        let store = open_store(&root, 0);
        let dir_mode = |p: &std::path::Path| fs::metadata(p).unwrap().permissions().mode();
        assert_eq!(dir_mode(&store.dir) & 0o777, 0o700, "段目录 0700");
        assert_eq!(dir_mode(&store.dir.join("images")) & 0o777, 0o700);
        assert_eq!(dir_mode(&store.dir.join("meta.json")) & 0o777, 0o600);
        assert_eq!(dir_mode(&store.dir.join("system.txt")) & 0o777, 0o600);
        assert_eq!(dir_mode(&store.dir.join("events.jsonl")) & 0o777, 0o600);
    }

    #[test]
    fn images_decode_to_binary_files_and_dedup() {
        let root = tmpdir("images");
        let mut store = open_store(&root, 0);
        // "hello" 的 base64
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"hello");
        let history = vec![
            Message::user("拍张照"),
            image_msg(&b64),
            Message::assistant("看到了"),
        ];
        store.record_history(&history);
        // 同一张图再来一次（跨任务重复进上下文）：去重，images/ 只有一份
        let history2 = vec![
            Message::user("拍张照"),
            image_msg(&b64),
            Message::assistant("看到了"),
            Message::user("再拍一张"),
            image_msg(&b64),
        ];
        store.record_history(&history2);

        let evs = events(&store);
        let msgs: Vec<&Value> = evs.iter().filter(|e| e["event"] == "msg").collect();
        assert_eq!(msgs.len(), 5, "增量水位：第二次只补 2 条新消息");
        let img_parts: Vec<&Value> = msgs
            .iter()
            .filter_map(|m| m["msg"]["parts"].as_array())
            .flat_map(|a| a.iter())
            .filter(|p| p["type"] == "image")
            .collect();
        assert_eq!(img_parts.len(), 2, "两次图片引用");
        let first = img_parts[0];
        assert_eq!(first["stored"], true);
        assert_eq!(first["bytes"], 5);
        assert_eq!(first["mime"], "image/png");
        assert_eq!(first["fp"], fingerprint64_bytes(b"hello"));
        let file = first["file"].as_str().unwrap();
        assert!(
            file.starts_with("images/0000-") && file.ends_with(".png"),
            "{file}"
        );
        assert_eq!(img_parts[1]["dedup"], true, "重复图引用已有文件");
        assert_eq!(
            img_parts[1]["file"].as_str().unwrap(),
            file,
            "去重引用同一文件名"
        );
        // 文件内容 = 解码后的原始字节
        let raw = fs::read(store.dir.join(file)).unwrap();
        assert_eq!(raw, b"hello");
        // base64 永不进事件流
        let text = std::fs::read_to_string(store.dir.join("events.jsonl")).unwrap();
        assert!(!text.contains(&b64), "base64 不得进 JSONL");
    }

    #[test]
    fn image_cap_degrades_loudly_to_metadata_only() {
        let root = tmpdir("cap");
        let mut store = open_store(&root, 6); // 只够存 "hello"(5)
        let b64_hello = base64::engine::general_purpose::STANDARD.encode(b"hello");
        let b64_world = base64::engine::general_purpose::STANDARD.encode(b"world!");
        // 水位语义：第二次调用要带全量历史（调用方 REPL 正是这么传的）
        store.record_history(&[image_msg(&b64_hello)]);
        store.record_history(&[image_msg(&b64_hello), image_msg(&b64_world)]);
        let evs = events(&store);
        let imgs: Vec<&Value> = evs
            .iter()
            .filter_map(|e| e["msg"]["parts"].as_array())
            .flat_map(|a| a.iter())
            .filter(|p| p["type"] == "image")
            .collect();
        assert_eq!(imgs[0]["stored"], true, "第一张在预算内");
        assert_eq!(imgs[1]["stored"], false, "第二张超预算降级");
        assert_eq!(imgs[1]["reason"], "cap");
        assert_eq!(imgs[1]["bytes"], 6, "元数据照记");
        assert_eq!(
            fs::read_dir(store.dir.join("images")).unwrap().count(),
            1,
            "图片仓只有第一张"
        );
        // 文本事件不受限
        store.task_begin("预算耗尽后的任务");
        let evs = events(&store);
        assert!(evs.iter().any(|e| e["event"] == "task_begin"));
    }

    #[test]
    fn watermark_tracks_evict_clear_and_resume() {
        let root = tmpdir("watermark");
        let mut store = open_store(&root, 0);
        let mk = |t: &str| Message::user(t);
        // 任务一：2 条
        store.record_history(&[mk("a1"), Message::assistant("r1")]);
        // 裁掉最老 1 条：内存历史变 [r1]，水位回退到 1（r1 已录过）
        store.note_evicted(1);
        // 新任务补 1 条：调用方传裁剪后的全量历史 [r1, b1]
        store.record_history(&[Message::assistant("r1"), mk("b1")]);
        let evs = events(&store);
        let msgs: Vec<&Value> = evs.iter().filter(|e| e["event"] == "msg").collect();
        assert_eq!(msgs.len(), 3, "a1/r1/b1 各一条（录制是全量留档）");
        assert_eq!(msgs[2]["msg"]["parts"][0]["text"], "b1");
        assert!(evs
            .iter()
            .any(|e| e["event"] == "history_evict" && e["messages"] == 1));
        // /clear：水位归零，其后整段重录
        store.reset_after_clear();
        store.record_history(&[mk("c1")]);
        let evs = events(&store);
        assert!(evs.iter().any(|e| e["event"] == "clear"));
        let msgs: Vec<&Value> = evs.iter().filter(|e| e["event"] == "msg").collect();
        assert_eq!(msgs.len(), 4, "clear 后 c1 也入列（全量留档）");
        // 续接：水位对齐 N，不重复落
        store.note_resumed(9, "/tmp/s.jsonl");
        let hist: Vec<Message> = (0..9).map(|i| mk(&format!("h{i}"))).collect();
        store.record_history(&hist);
        let evs = events(&store);
        assert!(evs
            .iter()
            .any(|e| e["event"] == "resume" && e["messages"] == 9));
        let msgs: Vec<&Value> = evs.iter().filter(|e| e["event"] == "msg").collect();
        assert_eq!(msgs.len(), 4, "恢复前缀不重复落事件");
    }

    #[test]
    fn assistant_tool_calls_and_reasoning_encode_with_ids() {
        let root = tmpdir("assistant");
        let mut store = open_store(&root, 0);
        let call = rig_agent::completion::message::ToolCall::new(
            rig_agent::completion::message::ToolCallId::new_or_mint("call_0"),
            ToolFunction::new(
                "run_action_script".to_string(),
                serde_json::json!({"script": "wave.mt", "vars": {"deg": 35}}),
            ),
        );
        let msg = Message::Assistant {
            id: Some("asst_1".to_string()),
            content: vec![
                AssistantContent::text("好的"),
                AssistantContent::ToolCall(call),
                AssistantContent::Reasoning(Reasoning {
                    id: None,
                    content: vec![ReasoningContent::Summary("先看脚本".to_string())],
                }),
            ],
        };
        store.record_history(&[msg]);
        let evs = events(&store);
        let m = &evs[1]["msg"];
        assert_eq!(m["role"], "assistant");
        assert_eq!(m["text"], "好的");
        assert_eq!(m["id"], "asst_1");
        assert_eq!(m["reasoning"], "先看脚本");
        assert_eq!(m["tool_calls"][0]["id"], "call_0");
        assert_eq!(m["tool_calls"][0]["name"], "run_action_script");
        assert_eq!(m["tool_calls"][0]["arguments"]["vars"]["deg"], 35);
    }

    #[test]
    fn tool_result_parts_preserve_order_with_caption() {
        // 图片注入后的线上形态：[tool_result, text(说明), image] 同一条 user 消息
        let root = tmpdir("order");
        let mut store = open_store(&root, 0);
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"png!");
        let msg = Message::User {
            content: vec![
                UserContent::tool_result(
                    "call_0",
                    "capture_image",
                    vec![ToolResultContent::Text("已采集 640x480".into())],
                ),
                UserContent::text(crate::hook::IMAGE_CAPTION),
                UserContent::image_base64(b64.as_str(), Some(ImageMediaType::JPEG), None),
            ],
        };
        store.record_history(&[msg]);
        let evs = events(&store);
        let parts = evs[1]["msg"]["parts"].as_array().unwrap();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[0]["type"], "tool_result");
        assert_eq!(parts[0]["call_id"], "call_0");
        assert_eq!(parts[0]["name"], "capture_image");
        assert_eq!(parts[0]["parts"][0]["text"], "已采集 640x480");
        assert_eq!(parts[1]["type"], "text");
        assert_eq!(parts[2]["type"], "image");
        assert_eq!(parts[2]["mime"], "image/jpeg");
        assert_eq!(
            fs::read(store.dir.join(parts[2]["file"].as_str().unwrap())).unwrap(),
            b"png!"
        );
    }

    #[test]
    fn model_calls_and_lifecycle_events_carry_audit_shaped_fields() {
        let root = tmpdir("lifecycle");
        let mut store = open_store(&root, 0);
        store.task_begin("让机器人站立");
        store.model_calls(
            &[CallRecord {
                turn: 1,
                req_bytes: 24616,
                resp_bytes: 82,
                attempts: 2,
                ms: 812,
                ok: true,
                error: String::new(),
                prompt_tokens: Some(1234),
                completion_tokens: Some(56),
            }],
            "task",
        );
        store.task_end(true, "");
        store.history_summary(true, "更早的对话：用户让机器人走了两步", "");
        store.session_end("end", "");
        let evs = events(&store);
        let kinds: Vec<&str> = evs.iter().map(|e| e["event"].as_str().unwrap()).collect();
        assert_eq!(
            kinds,
            vec![
                "session_start",
                "task_begin",
                "model_call",
                "task_end",
                "history_summary",
                "session_end"
            ]
        );
        let mc = &evs[2];
        assert_eq!(mc["kind"], "task");
        assert_eq!(mc["turn"], 0, "rig 1-based → 0-based（审计同口径）");
        assert_eq!(mc["attempts"], 2);
        assert_eq!(mc["prompt_tokens"], 1234);
        let hs = &evs[4];
        assert_eq!(hs["ok"], true);
        assert_eq!(hs["text"], "更早的对话：用户让机器人走了两步");
        // 摘要轮的 model_call 不带 turn（与审计口径一致）
        store.model_calls(
            &[CallRecord {
                turn: 3,
                ms: 5,
                ok: false,
                error: "net".into(),
                ..Default::default()
            }],
            "summary",
        );
        let evs = events(&store);
        let last = evs.last().unwrap();
        assert_eq!(last["kind"], "summary");
        assert!(last.get("turn").is_none());
    }

    #[test]
    fn segment_name_collisions_fall_back_to_pid_suffix() {
        let root = tmpdir("collision");
        let a = create_segment_dir(&root.to_string_lossy(), 1_700_000_000).unwrap();
        let b = create_segment_dir(&root.to_string_lossy(), 1_700_000_000).unwrap();
        assert_eq!(a, segment_name(1_700_000_000));
        assert_ne!(a, b, "同秒第二段必须换名");
        assert!(b.starts_with(&format!("{a}-")), "{b}");
        // 指针由 open/write_pointer 落（create_segment_dir 只占目录）：写了才可读回
        assert!(read_pointer_best_effort(&root.to_string_lossy()).is_none());
        write_pointer(&root.to_string_lossy(), &b).unwrap();
        assert_eq!(
            read_pointer_best_effort(&root.to_string_lossy()),
            Some(b.clone())
        );
        // 非法指针内容（穿越尝试）不被采纳
        fs::write(root.join("latest"), "../../etc\n").unwrap();
        assert!(read_pointer_best_effort(&root.to_string_lossy()).is_none());
    }

    #[test]
    fn bad_root_fails_loudly() {
        // A regular file cannot be used as the recording root, regardless of
        // whether the test runs as root (where /nonexistent-xyz may be creatable).
        let blocker = std::env::temp_dir().join(format!(
            "mybot-record-block-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&blocker, b"not a directory").unwrap();
        let root = blocker.join("recordings").to_string_lossy().to_string();
        let e = RecordStore::open(RecordOpen {
            root,
            max_image_bytes: 0,
            session_file: "",
            session_id: "",
            robot: "r",
            driver: "LlmOpenAI",
            model: "m",
            endpoint: "https://h/v1",
            api_key_source: "env",
            tools: &[],
            tool_specs: serde_json::json!([]),
            system_prompt: "",
            stream: true,
            resumed: false,
            now_sec: 0,
        })
        .unwrap_err();
        let _ = fs::remove_file(&blocker);
        assert!(e.contains("无法创建"), "{e}");
    }
}

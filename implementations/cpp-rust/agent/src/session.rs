//! session.rs —— 会话文件的读写原语（批次 D；`src/agenthistory.cpp` 的 Rust 对等实现）
//!
//! **批次 D 落地后 C++ 侧 `agenthistory.{hpp,cpp}` 与 `test_sessionfile.cpp` 已删**，
//! 本文件成为唯一实现。行格式与 C++ 版**逐字节兼容**（首行会话头 + 其后一消息一行，
//! JSON Lines 追加写），因此 C++ 时代落下的会话文件仍可被本进程 `--resume` 读回
//! （反之亦然——格式是对外契约，不是内部实现细节）。
//!
//! 为什么**不复用 rig 的 serde**：`Message` 的序列化形状是
//! `{"role":"user","content":[{"type":"text",...}]}`（标签化内容块），与 C++ 行的
//! `{"role":"user","content":"…"}`（content 是**字符串**）不兼容。会话文件是跨版本
//! 存量数据，格式不能随 rig 的序列化实现漂移，故自带一套行编解码。
//!
//! 落盘单位 = rig 的 `Message`（历史所有权在 repl.rs / history.rs）。三条映射约定：
//!
//!   * **system 不落盘**：恢复时由当前进程重建，经会话头的 `system_fp` 核对——
//!     落盘反而会让「提示词换了没有」失去单一事实来源（同 C++）。
//!   * **图片写入期排除**：图片字节（data URL）不落盘，落的是占位文本
//!     「[图片 N 字节，未随会话恢复]」+ 文本部分。只有写入期排除才真的做到
//!     「体积与隐私都不落盘」；恢复期占位意味着磁盘上仍躺着 base64 画面。
//!     **有意偏离 C++**：C++ 参考把整条 content 换成占位文本，本实现保留 caption
//!     文本（如 capture_image 的说明）再追加占位——恢复后模型仍能看到这句话。
//!   * **tool 名回查**：行格式只在 assistant 的 `tool_calls` 里记工具名，tool 行不记；
//!     载入时按 `tool_call_id` 从**前序** assistant 的 tool_calls 回查（协议自洽检查
//!     在前，孤儿/重复已被拒，名字必有解）。这与 C++ 的 ChatMessage 不同：C++ 的
//!     tool 消息本就不带工具名，线上转换时才补——rig 的 `ToolResult` 却**要求**非空
//!     name，故必须在载入期定名。

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;

use rig_agent::completion::message::{
    AssistantContent, Reasoning, ReasoningContent, ToolCall, ToolCallId, ToolFunction,
    ToolResultContent, UserContent,
};
use rig_agent::completion::Message;
use serde_json::{json, Map, Value};

use crate::audit::{audit_timestamp, fingerprint64};
use crate::out::errln;
use crate::placeholder::{image_placeholder, source_len};

/// 会话文件版本（本程序只认 v=1；v 之外整份拒绝，口径同 C++ 参考）。
pub const SESSION_FILE_VERSION: i64 = 1;

/// 会话头（会话文件的第 1 行）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SessionHead {
    pub version: i64,
    /// 审计会话 id（空 = 审计未开；恢复时据此沿用原 session id）
    pub session_id: String,
    /// 结构脚本展示名（去目录去 .sql）
    pub robot: String,
    /// 工具集指纹（按注册序拼接工具名后取 fingerprint64）
    pub tools_fp: String,
    /// 系统提示词指纹（fingerprint64）
    pub system_fp: String,
}

/* 图片占位文本与图片后注判据（image_placeholder / is_image_placeholder_notice）
 * 已下沉到叶子模块 placeholder.rs（2026-10-01，解 session ↔ history 环）；
 * 本模块经下方 use 继续使用。 */

/// 工具集指纹：按注册序拼接工具名后取 fingerprint64（与 C++
/// `sessionToolsFingerprint` 同式；名字串撞车概率与既有 image_fp 同量级，可接受）。
pub fn tools_fingerprint(tool_names: &[String]) -> String {
    fingerprint64(&tool_names.join(","))
}

// ---------------- 落盘：rig Message → 行 JSON ----------------

/// 单条消息 → 会话文件的一行 JSON 对象。`None` = 不落盘（system 消息；调用方
/// 保证不会传，传了也不写——system 由恢复期重建）。
///
/// **一条 rig 消息可能拆成多行**：`User{content:[ToolResult, Text…, Image…]}`
/// （图片注入期请求内的形态）会拆成「tool 行 + user 行」，因为行格式里一条消息
/// 只有一个 role——拆开后与 C++ 的「tool 消息之后另起一条 user 图片消息」同序。
pub fn encode_message(m: &Message) -> Vec<Value> {
    match m {
        Message::System { .. } => Vec::new(),
        Message::User { content } => encode_user(content),
        Message::Assistant { id, content } => vec![encode_assistant(id.as_deref(), content)],
    }
}

/// user 侧的拆分：先出所有工具结果行，再把剩下的文本/图片并成一条 user 行。
fn encode_user(content: &[UserContent]) -> Vec<Value> {
    let mut lines = Vec::new();
    let mut text = String::new();
    let mut image_bytes = 0usize;
    let mut image_count = 0usize;
    for item in content {
        match item {
            UserContent::ToolResult(r) => {
                let body = tool_result_text(&r.content);
                lines.push(json!({
                    "role": "tool",
                    "content": body,
                    "tool_call_id": r.call.as_str(),
                }));
            }
            UserContent::Text(t) => text.push_str(&t.text),
            // 图片：只累计字节与张数（写入期排除，见模块头）
            UserContent::Image(i) => {
                image_bytes += source_len(&i.data);
                image_count += 1;
            }
            // 其余多模态（音频/视频/文档）本项目不产生；如实落成文本标记而不是静默丢
            UserContent::Audio(a) => text.push_str(&format!(
                "[音频 {} 字节，未随会话恢复]",
                source_len(&a.data)
            )),
            UserContent::Video(v) => text.push_str(&format!(
                "[视频 {} 字节，未随会话恢复]",
                source_len(&v.data)
            )),
            UserContent::Document(d) => text.push_str(&format!(
                "[文档 {} 字节，未随会话恢复]",
                source_len(&d.data)
            )),
        }
    }
    if image_count > 0 || !text.is_empty() {
        // 有意偏离 C++（见模块头）：caption 文本保留，占位追加在后面。
        let mut body = text;
        if image_count > 0 {
            body.push_str(&image_placeholder(image_bytes));
        }
        let mut line = json!({ "role": "user", "content": body });
        if image_count > 0 {
            line["images_omitted"] = json!(image_count);
        }
        lines.push(line);
    }
    lines
}

fn encode_assistant(id: Option<&str>, content: &[AssistantContent]) -> Value {
    let mut text = String::new();
    let mut calls: Vec<Value> = Vec::new();
    let mut extras = Map::new();
    for item in content {
        match item {
            AssistantContent::Text(t) => text.push_str(&t.text),
            AssistantContent::ToolCall(c) => calls.push(json!({
                "id": c.id.as_str(),
                "name": c.function.name,
                "arguments": serde_json::to_string(&c.function.arguments)
                    .unwrap_or_else(|_| "{}".to_string()),
            })),
            // 思维链（DeepSeek 的 reasoning_content 等）随历史逐轮回传，恢复后若
            // 丢失会话照样 400——原样落进 extras，读回时还原成 Reasoning 块。
            AssistantContent::Reasoning(r) => {
                let joined = r
                    .content
                    .iter()
                    .filter_map(reasoning_text)
                    .collect::<Vec<_>>()
                    .join("\n");
                if !joined.is_empty() {
                    extras.insert("reasoning_content".into(), Value::String(joined));
                }
            }
            // assistant 侧图片本项目不产生；占位而不是静默丢
            AssistantContent::Image(i) => text.push_str(&format!(
                "[图片 {} 字节，未随会话恢复]",
                source_len(&i.data)
            )),
        }
    }
    if let Some(id) = id {
        if !id.is_empty() {
            extras.insert("__rig_id".into(), Value::String(id.to_string()));
        }
    }
    let mut line = Map::new();
    line.insert("role".into(), Value::String("assistant".into()));
    line.insert("content".into(), Value::String(text));
    if !calls.is_empty() {
        line.insert("tool_calls".into(), Value::Array(calls));
    }
    if !extras.is_empty() {
        line.insert("extras".into(), Value::Object(extras));
    }
    Value::Object(line)
}

/// provider 附加字段**原样透传**（与 C++ 的 extras 通道同待遇：不理解、只带回）。
/// 但有两个键是本实现的私有元数据，读回时要摘出来：
///   * `reasoning_content` → 还原成 `AssistantContent::Reasoning` 块；
///   * `__rig_id` → rig 的 assistant 消息 id（C++ 无此概念）。
///
/// record.rs 录制事件流共用同一判据（不可还原的加密块不落）。
pub(crate) fn reasoning_text(c: &ReasoningContent) -> Option<String> {
    match c {
        ReasoningContent::Text { text, .. } => Some(text.clone()),
        ReasoningContent::Summary(s) => Some(s.clone()),
        ReasoningContent::Redacted { data } => Some(data.clone()),
        ReasoningContent::Encrypted(_) => None,
    }
}

fn tool_result_text(content: &[ToolResultContent]) -> String {
    let mut out = String::new();
    for item in content {
        match item {
            ToolResultContent::Text(t) => out.push_str(&t.text),
            ToolResultContent::Json { value } => out.push_str(&value.to_string()),
            ToolResultContent::Image(i) => out.push_str(&format!(
                "[图片 {} 字节，未随会话恢复]",
                source_len(&i.data)
            )),
        }
    }
    out
}

// ---------------- 载入：行 JSON → rig Message ----------------

/// 载入期的逐行状态：tool 行的工具名要从**前序** assistant 的 tool_calls 回查。
#[derive(Default)]
struct DecodeState {
    /// tool_call_id → 工具名（按 assistant 行出现的先后登记）
    names: HashMap<String, String>,
}

fn decode_message(v: &Value, st: &mut DecodeState) -> Result<Message, String> {
    let role = v
        .get("role")
        .and_then(Value::as_str)
        .ok_or_else(|| "缺 role 或不是字符串".to_string())?;
    let content = v
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| "缺 content 或不是字符串".to_string())?;
    match role {
        "user" => Ok(Message::User {
            content: vec![UserContent::text(content)],
        }),
        "assistant" => decode_assistant(v, content, st),
        "tool" => {
            let id = v
                .get("tool_call_id")
                .and_then(Value::as_str)
                .ok_or_else(|| "tool 消息缺 tool_call_id".to_string())?;
            let name = st.names.get(id).cloned().ok_or_else(|| {
                format!("tool_call_id '{id}' 不匹配任何 assistant 声明的工具调用（孤儿 tool 消息）")
            })?;
            Ok(Message::User {
                content: vec![UserContent::tool_result(
                    id,
                    name,
                    vec![ToolResultContent::Text(content.to_string().into())],
                )],
            })
        }
        other => Err(format!("未知 role '{other}'")),
    }
}

fn decode_assistant(v: &Value, content: &str, st: &mut DecodeState) -> Result<Message, String> {
    let mut items: Vec<AssistantContent> = Vec::new();
    if !content.is_empty() {
        items.push(AssistantContent::text(content));
    }
    let mut id: Option<String> = None;
    if let Some(extras) = v.get("extras") {
        let obj = extras
            .as_object()
            .ok_or_else(|| "extras 不是对象".to_string())?;
        if let Some(Value::String(r)) = obj.get("reasoning_content") {
            if !r.is_empty() {
                items.push(AssistantContent::Reasoning(Reasoning::new(r)));
            }
        }
        if let Some(Value::String(rid)) = obj.get("__rig_id") {
            if !rid.is_empty() {
                id = Some(rid.clone());
            }
        }
    }
    if let Some(calls) = v.get("tool_calls") {
        let arr = calls
            .as_array()
            .ok_or_else(|| "tool_calls 不是数组".to_string())?;
        for (i, c) in arr.iter().enumerate() {
            let obj = c
                .as_object()
                .ok_or_else(|| format!("tool_calls[{i}] 不是对象"))?;
            let cid = obj.get("id").and_then(Value::as_str);
            let cname = obj.get("name").and_then(Value::as_str);
            let cargs = obj.get("arguments").and_then(Value::as_str);
            let (Some(cid), Some(cname), Some(cargs)) = (cid, cname, cargs) else {
                return Err(format!("tool_calls[{i}] 缺 id/name/arguments"));
            };
            let arguments: Value = serde_json::from_str(cargs).unwrap_or_else(|_| json!({}));
            st.names.insert(cid.to_string(), cname.to_string());
            items.push(AssistantContent::ToolCall(ToolCall::new(
                ToolCallId::new_or_mint(cid),
                ToolFunction::new(cname.to_string(), arguments),
            )));
        }
    }
    if items.is_empty() {
        // 空 assistant 行（C++ 侧可能落过 content="" 且无 tool_calls 的行）：rig 的
        // Message::Assistant 允许空内容（工具调用轮次合法），保留一条空助手消息。
        items.push(AssistantContent::text(""));
    }
    Ok(Message::Assistant { id, content: items })
}

// ---------------- 会话头与消息的协议自洽（恢复三道判据之二三） ----------------

/// 恢复前的指纹核对。返回 `None` = 一致；`Some(人话原因)` = 不一致（点名差异）；
/// session_id 不参与比对（恢复本来就是要沿用它的）。与 C++
/// `sessionHeadMismatch` 的文案逐字对齐。
pub fn head_mismatch(expected: &SessionHead, found: &SessionHead) -> Option<String> {
    if expected.robot != found.robot {
        return Some(format!(
            "结构脚本不同（会话头是 '{}'，当前是 '{}'）；旧上下文与当前机器人对不上号",
            found.robot, expected.robot
        ));
    }
    if expected.tools_fp != found.tools_fp {
        return Some(format!(
            "工具集不同（会话头的工具集指纹 {}，当前 {}）；工具调用历史对当前会话不再适用",
            found.tools_fp, expected.tools_fp
        ));
    }
    if expected.system_fp != found.system_fp {
        return Some(
            "系统提示词不同（提示词包或脚本清单变了）；旧上下文基于另一份系统提示词".to_string(),
        );
    }
    None
}

/// 历史必须能被服务端接受（SAN-1）。三条判据（与 C++ `historyProtocolViolation`
/// 逐条对应，文案同）：
///   ① 每个 tool 回执的 id 必须出现在某条 assistant 的 tool_calls 里（无孤儿）；
///   ② 同一个 id 只能被回答**一次**（服务端 400 `answered more than once`）；
///   ③ 某条 assistant 声明的每个工具调用都必须被回答过（无漏答）。
/// 返回 `None` = 合法；`Some(人话原因)` = 不合法。
pub fn protocol_violation(history: &[Message]) -> Option<String> {
    let mut declared: Vec<String> = Vec::new();
    for (i, m) in history.iter().enumerate() {
        if let Message::Assistant { content, .. } = m {
            for item in content {
                if let AssistantContent::ToolCall(c) = item {
                    if c.id.as_str().is_empty() {
                        return Some(format!(
                            "messages[{i}]: assistant 声明了一条 id 为空的工具调用（服务端 400）"
                        ));
                    }
                    declared.push(c.id.as_str().to_string());
                }
            }
        }
    }
    let mut answered: Vec<String> = Vec::new();
    for (i, m) in history.iter().enumerate() {
        let Message::User { content } = m else {
            continue;
        };
        for item in content {
            let UserContent::ToolResult(r) = item else {
                continue;
            };
            let id = r.call.as_str();
            if id.is_empty() {
                return Some(format!(
                    "messages[{i}]: tool 消息缺少 tool_call_id（服务端 400）"
                ));
            }
            if !declared.iter().any(|d| d == id) {
                return Some(format!(
                    "messages[{i}]: tool_call_id '{id}' 不匹配任何 assistant 声明的工具调用（孤儿 tool 消息）"
                ));
            }
            if answered.iter().any(|a| a == id) {
                return Some(format!(
                    "messages[{i}]: tool_call_id '{id}' 被回答了不止一次（服务端 400 answered more than once）"
                ));
            }
            answered.push(id.to_string());
        }
    }
    for id in &declared {
        if !answered.iter().any(|a| a == id) {
            return Some(format!(
                "assistant 声明的工具调用 '{id}' 没有得到任何 tool 回传（服务端 400）"
            ));
        }
    }
    None
}

// ---------------- 读 ----------------

/// 会话文件载入结果。
#[derive(Debug, Default)]
pub struct LoadedSession {
    pub head: SessionHead,
    pub messages: Vec<Message>,
    /// 最后一条 `session_summary` 记录的正文（`/clear` 之后为 None）。
    pub summary: Option<String>,
}

/// 读入会话文件（三道判据之一「逐行解析」由本函数承担）。
///
/// 首行必须是合法会话头（没有头就无从核对指纹，整份拒绝）；其后的行逐行解析，
/// **损坏行跳过并点名**（含行号与人话原因，进 warnings）不整份作废——崩溃留下的
/// 最后一行残缺不该抹掉此前的完整历史。`/clear` 分界标记丢弃此前累积的全部消息
/// （否则「忘掉对话」会在下次恢复时复活）。
///
/// `session_summary` 记录（改进项 #7）：写它的那一刻，磁盘上「摘要已覆盖」的旧任务
/// 块之后只剩 `keep_blocks` 个块，本函数据此把此前累积的消息收口成最后 `keep_blocks`
/// 个块并记下摘要正文——恢复后的历史与写入进程当时送给模型的一致，不多不少。
/// 摘要失败时进程什么都不写，下次恢复照旧按预算整块裁剪（自愈）。
///
/// 第二、三道判据（指纹核对、协议自洽）由调用方在拿到结果后执行——本函数只管
/// 单行形态与分界语义。
pub fn load_session_file(
    path: &str,
    out: &mut LoadedSession,
    warnings: &mut Vec<String>,
) -> Result<(), String> {
    // 读前设限（2026-10-01 批次 A / P1-2）：与配置 64 KiB、提示词 1 MiB、密钥
    // 64 KiB 的处处设限同纪律——误把大文件（如视频）当会话文件时，不该整份
    // 读进内存。上限与上下文预算同源（`limits::BUDGET_BYTES_MAX`）：会话内容
    // 本就受该预算约束，超过它就不像会话文件。
    let cap = crate::config::limits::BUDGET_BYTES_MAX as u64;
    let len = std::fs::metadata(path)
        .map_err(|_| format!("无法读取会话文件 '{path}'（不存在或没有读权限）"))?
        .len();
    if len > cap {
        return Err(format!(
            "会话文件 '{path}' 大小 {len} 字节，超过上限 {cap} 字节（与上下文预算同源）——\
             不像会话文件，可能指向了别的大文件；拒绝读入"
        ));
    }
    let text = std::fs::read_to_string(path)
        .map_err(|_| format!("无法读取会话文件 '{path}'（不存在或没有读权限）"))?;

    let mut head_seen = false;
    let mut st = DecodeState::default();
    let mut messages: Vec<Message> = Vec::new();
    let mut head = SessionHead::default();
    let mut summary: Option<String> = None;

    for (idx, line) in text.lines().enumerate() {
        let line_no = idx + 1;
        /* 跳行告警的单点（2026-10-01 收敛）：此前 8 处手拼「会话文件 '{path}'
         * 第 {line_no} 行…，已跳过该行」——前置/尾缀样板漂移会让告警文案在
         * 恢复日志里长短不一。只改落形，文案逐字保持。 */
        let mut skip = |why: &str| {
            warnings.push(format!(
                "会话文件 '{path}' 第 {line_no} 行{why}，已跳过该行"
            ));
        };
        if line.trim().is_empty() {
            continue;
        }
        let parsed: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => {
                // 崩溃可能留下最后一行残缺：跳过并点名，不整份作废
                skip(&format!("不是合法 JSON（{e}）"));
                continue;
            }
        };
        let Some(obj) = parsed.as_object() else {
            skip("不是 JSON 对象");
            continue;
        };
        // /clear 分界标记：丢弃此前累积的消息
        if obj.get("type").and_then(Value::as_str) == Some("session_clear") {
            if !head_seen {
                skip("的 session_clear 出现在会话头之前");
                continue;
            }
            messages.clear();
            summary = None;
            st = DecodeState::default();
            continue;
        }
        if obj.get("type").and_then(Value::as_str) == Some("session_summary") {
            if !head_seen {
                skip("的 session_summary 出现在会话头之前");
                continue;
            }
            let (Some(content), Some(keep)) = (
                obj.get("content").and_then(Value::as_str),
                obj.get("keep_blocks").and_then(Value::as_u64),
            ) else {
                skip("的 session_summary 缺 content/keep_blocks");
                continue;
            };
            let starts = crate::history::block_starts(&messages);
            let keep = keep as usize;
            let cut = if keep == 0 {
                messages.len()
            } else if keep >= starts.len() {
                0
            } else {
                starts[starts.len() - keep]
            };
            messages.drain(0..cut);
            summary = Some(content.to_string());
            continue;
        }
        if !head_seen {
            head = match parse_head(&parsed, path)? {
                Some(h) => h,
                None => {
                    skip("不是合法消息行（首行必须是会话头）");
                    continue;
                }
            };
            head_seen = true;
            continue;
        }
        match decode_message(&parsed, &mut st) {
            Ok(m) => messages.push(m),
            Err(e) => skip(&format!("不是合法消息行（{e}）")),
        }
    }

    if !head_seen {
        return Err(format!("会话文件 '{path}' 为空或缺会话头，无会话可恢复"));
    }
    out.head = head;
    out.messages = messages;
    out.summary = summary;
    Ok(())
}

/// 解析会话头行。`Ok(None)` = 不是会话头（调用方按损坏行处理）；`Err` = 是会话头
/// 但版本/必备字段不合格（整份拒绝——没有头或版本不认就无从核对指纹）。
fn parse_head(parsed: &Value, path: &str) -> Result<Option<SessionHead>, String> {
    let Some(obj) = parsed.as_object() else {
        return Ok(None);
    };
    let type_ok = obj.get("type").and_then(Value::as_str) == Some("session_head");
    let ver = obj.get("v").and_then(Value::as_i64);
    if !type_ok {
        return Ok(None);
    }
    let Some(ver) = ver else {
        return Err(format!(
            "会话文件 '{path}' 首行不是会话头（缺 v/type=session_head），指纹无从核对，拒绝恢复"
        ));
    };
    if ver != SESSION_FILE_VERSION {
        return Err(format!(
            "会话文件 '{path}' 版本为 {ver}（本程序只认 v={SESSION_FILE_VERSION}），拒绝恢复"
        ));
    }
    let (Some(robot), Some(tools_fp), Some(system_fp)) = (
        obj.get("robot").and_then(Value::as_str),
        obj.get("tools_fp").and_then(Value::as_str),
        obj.get("system_fp").and_then(Value::as_str),
    ) else {
        return Err(format!(
            "会话文件 '{path}' 会话头缺 robot/tools_fp/system_fp，拒绝恢复"
        ));
    };
    let session_id = obj
        .get("session")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok(Some(SessionHead {
        version: ver,
        session_id,
        robot: robot.to_string(),
        tools_fp: tools_fp.to_string(),
        system_fp: system_fp.to_string(),
    }))
}

/// 文件存在且权限宽于 0600 时返回告警文本（与 `mybot.llm.json` 既有判据同口径：
/// 会话文件含完整对话内容，同等敏感；判据单点在 [`crate::fssec::wide_perms`]）。
/// 不存在/取不到权限 = 空串。
pub fn perms_warning(path: &str) -> String {
    if !crate::fssec::wide_perms(path, crate::fssec::PermKind::File) {
        return String::new();
    }
    format!("会话文件 '{path}' 权限宽于 600（含完整对话内容，同等敏感），建议 chmod 600 {path}")
}

// ---------------- 写 ----------------

/// 追加式会话文件写入器。`open(append=false)` = 开新会话（截断旧文件并写会话头，
/// 调用方先经 [`perms_warning`] 提醒）；`open(append=true)` = 恢复（不写头，在既有
/// 内容后追加）。每行即刷（flush）：崩溃恢复最多丢最后一行，与审计同款崩溃一致性。
pub struct SessionFileWriter {
    file: Option<std::fs::File>,
    /// 写失败即置位并停用——静默丢历史正是本项目要避免的形态
    broken: bool,
    path: String,
}

impl SessionFileWriter {
    pub fn new() -> Self {
        Self {
            file: None,
            broken: false,
            path: String::new(),
        }
    }

    /// 打开会话文件。`append=true` 只在恢复路径用（文件已被调用方确认存在）。
    /// 新建（含截断重建）以 0600 创建——与 REPL 历史 / ICA sidecar / 审计同规，
    /// 会话文件含完整对话内容，同等敏感（2026-09-30 审计 P1：此前按 umask
    /// 落盘，常见 0644，且 `perms_warning` 只对已存在文件生效，首次会话
    /// 全程无告警）。既有文件的权限不在此改动：恢复路径的宽权限提醒由
    /// [`perms_warning`] 负责。
    pub fn open(&mut self, path: &str, append: bool) -> Result<(), String> {
        if self.file.is_some() {
            return Err(format!("会话文件已打开: {path}"));
        }
        let mut opts = OpenOptions::new();
        opts.create(true);
        if append {
            opts.append(true);
        } else {
            opts.write(true).truncate(true);
        }
        /* mode 脚手架与「无条件设置即可」的理由收在 fssec::opts_0600 单点。 */
        crate::fssec::opts_0600(&mut opts);
        let f = opts.open(path).map_err(|e| {
            format!("无法打开会话文件 '{path}'（{e}）；请检查目录是否存在、是否有写权限")
        })?;
        self.file = Some(f);
        self.path = path.to_string();
        Ok(())
    }

    /// 写会话头（只在开新会话时调）。
    pub fn write_header(&mut self, head: &SessionHead) {
        let mut line = Map::new();
        line.insert("v".into(), json!(SESSION_FILE_VERSION));
        line.insert("type".into(), json!("session_head"));
        if !head.session_id.is_empty() {
            line.insert("session".into(), json!(head.session_id));
        }
        line.insert("robot".into(), json!(head.robot));
        line.insert("tools_fp".into(), json!(head.tools_fp));
        line.insert("system_fp".into(), json!(head.system_fp));
        line.insert("created".into(), json!(audit_timestamp()));
        self.write_line(&Value::Object(line));
    }

    /// `/clear` 分界标记：落一行 `{"type":"session_clear"}`。载入时该行**丢弃此前
    /// 累积的全部消息**——否则恢复会把已被 `/clear` 遗忘的上下文复活进模型上下文，
    /// 与操作者在 REPL 里的意图相反。
    pub fn write_clear_marker(&mut self) -> bool {
        self.write_line(&json!({ "type": "session_clear" }))
    }

    /// 历史摘要记录：`content` = 摘要正文，`keep_blocks` = 此刻磁盘上摘要**没有**
    /// 覆盖的最新任务块数（载入时据此收口，见 `load_session_file`）。
    pub fn write_summary(&mut self, content: &str, keep_blocks: usize) -> bool {
        self.write_line(&json!({
            "type": "session_summary",
            "content": content,
            "keep_blocks": keep_blocks,
        }))
    }

    /// 追加一条消息（可能拆成多行）。已停用（broken）后恒 `false`，不再写。
    pub fn append_message(&mut self, m: &Message) -> bool {
        if self.file.is_none() || self.broken {
            return false;
        }
        let mut ok = true;
        for line in encode_message(m) {
            ok &= self.write_line(&line);
        }
        ok
    }

    /// 写一行（JSON + 换行 + flush）。失败置 broken 并返回 false，由调用方响亮告知
    /// 并停用——**不静默丢历史**。
    fn write_line(&mut self, v: &Value) -> bool {
        if self.file.is_none() || self.broken {
            return false;
        }
        let mut text = v.to_string();
        text.push('\n');
        let Some(f) = self.file.as_mut() else {
            return false;
        };
        if f.write_all(text.as_bytes()).is_err() || f.flush().is_err() {
            self.broken = true;
            errln!(
                "警告: 会话文件 '{}' 写入失败（磁盘满/权限？），本会话的后续对话不再落盘；\
                 机器人运行不受影响",
                self.path
            );
            return false;
        }
        true
    }
}

impl Default for SessionFileWriter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::placeholder::is_image_placeholder_notice;
    use rig_agent::completion::message::ToolResultContent;

    /// 每个用例一个独立临时目录（进程内唯一名 + 计数，避免并行测试相互踩）。
    fn tmpdir(tag: &str) -> std::path::PathBuf {
        crate::testutil::tmpdir("mybot_session", tag)
    }

    /// 简易对话序列：任务 → assistant(tool_calls) → tool → 图片消息 → 最终回答。
    /// 形状刻意与 C++ `sampleConversation` 对应（tool 消息与图片消息各自独立）。
    fn sample_conversation() -> Vec<Message> {
        vec![
            Message::user("任务一：拍照并站立"),
            Message::Assistant {
                id: None,
                content: vec![
                    AssistantContent::ToolCall(ToolCall::new(
                        ToolCallId::new_or_mint("call_0_0"),
                        ToolFunction::new("capture_image".to_string(), json!({})),
                    )),
                    AssistantContent::Reasoning(Reasoning::new("思考串")),
                ],
            },
            Message::User {
                content: vec![UserContent::tool_result(
                    "call_0_0",
                    "capture_image",
                    vec![ToolResultContent::Text(
                        "已拍摄照片（64 字节）".to_string().into(),
                    )],
                )],
            },
            Message::User {
                content: vec![
                    UserContent::text("以上工具返回的图片如下，请结合画面内容继续。"),
                    UserContent::image_base64("A".repeat(96), None, None),
                ],
            },
            Message::assistant("已站立。"),
        ]
    }

    fn fresh_writer(path: &str) -> SessionFileWriter {
        let mut w = SessionFileWriter::new();
        w.open(path, false).unwrap();
        w.write_header(&SessionHead {
            version: SESSION_FILE_VERSION,
            ..Default::default()
        });
        w
    }

    fn load(path: &str) -> (LoadedSession, Vec<String>) {
        let mut s = LoadedSession::default();
        let mut warns = Vec::new();
        load_session_file(path, &mut s, &mut warns).unwrap();
        (s, warns)
    }

    #[test]
    fn roundtrip_messages() {
        let dir = tmpdir("rt");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        {
            let mut w = SessionFileWriter::new();
            w.open(&path, false).unwrap();
            w.write_header(&SessionHead {
                version: SESSION_FILE_VERSION,
                session_id: "ab12cd34".into(),
                robot: "relay-test".into(),
                tools_fp: "toolfp".into(),
                system_fp: "sysfp".into(),
            });
            for m in sample_conversation() {
                assert!(w.append_message(&m));
            }
        }
        {
            // 追加路径：新进程/新写入器在既有内容后继续（不写头）
            let mut w = SessionFileWriter::new();
            w.open(&path, true).unwrap();
            assert!(w.append_message(&Message::user("任务二")));
        }

        let (loaded, warns) = load(&path);
        assert!(warns.is_empty(), "载入应有零告警: {warns:?}");
        assert_eq!(loaded.head.robot, "relay-test");
        assert_eq!(loaded.head.session_id, "ab12cd34");
        assert_eq!(loaded.messages.len(), 6);

        assert_eq!(loaded.messages[0], Message::user("任务一：拍照并站立"));
        let Message::Assistant { content, .. } = &loaded.messages[1] else {
            panic!("第 1 条应是 assistant");
        };
        // 工具调用保真
        let calls: Vec<&ToolCall> = content
            .iter()
            .filter_map(|c| match c {
                AssistantContent::ToolCall(tc) => Some(tc),
                _ => None,
            })
            .collect();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id.as_str(), "call_0_0");
        assert_eq!(calls[0].function.name, "capture_image");
        // 思维链经 extras 还原成 Reasoning 块（DeepSeek 恢复后不 400）
        let reasoning: Vec<&Reasoning> = content
            .iter()
            .filter_map(|c| match c {
                AssistantContent::Reasoning(r) => Some(r),
                _ => None,
            })
            .collect();
        assert_eq!(reasoning.len(), 1);
        assert_eq!(reasoning[0].first_text(), Some("思考串"));

        // tool 消息：工具名从 assistant 的 tool_calls 回查，回执文本保真
        let Message::User { content } = &loaded.messages[2] else {
            panic!("第 2 条应是 tool 结果");
        };
        let UserContent::ToolResult(r) = &content[0] else {
            panic!("内容应是工具结果");
        };
        assert_eq!(r.call.as_str(), "call_0_0");
        assert_eq!(r.name, "capture_image");
        assert_eq!(r.content[0].as_text(), Some("已拍摄照片（64 字节）"));

        // 图片消息：caption 保留 + 占位文本，图片字节不在
        let Message::User { content } = &loaded.messages[3] else {
            panic!("第 3 条应是图片后注");
        };
        let UserContent::Text(t) = &content[0] else {
            panic!("内容应是文本占位");
        };
        assert!(t.text.starts_with("以上工具返回的图片如下"));
        assert!(t.text.contains("未随会话恢复"), "实际: {}", t.text);

        assert_eq!(loaded.messages[4], Message::assistant("已站立。"));
        assert_eq!(loaded.messages[5], Message::user("任务二"));

        // 载入序列必须过协议自检（tool_call_id 无孤儿/无重复/无漏答）
        assert!(protocol_violation(&loaded.messages).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn image_bytes_never_on_disk() {
        let dir = tmpdir("img");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let mut w = fresh_writer(&path);
        for m in sample_conversation() {
            assert!(w.append_message(&m));
        }
        // 写入器需要先关闭（drop）再读
        drop(w);
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("data:"), "data URL 不得落盘");
        assert!(!raw.contains("base64"), "base64 不得落盘");
        assert!(!raw.contains(&"A".repeat(96)), "图片字节不得落盘");
        // 占位文本带总字节数（96 画面字节；image_base64 直接给的是 base64 串长度）
        assert!(raw.contains("未随会话恢复"), "占位文本应在: {raw}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_lines_skipped_and_named() {
        let dir = tmpdir("bad");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        std::fs::write(
            &path,
            "{\"v\":1,\"type\":\"session_head\",\"robot\":\"r\",\"tools_fp\":\"t\",\"system_fp\":\"s\"}\n\
             {\"role\":\"user\",\"content\":\"好的那一行\"}\n\
             {\"role\":\"user\",\"content\":\"残行\" <<CRASH\n\
             [1,2,3]\n\
             {\"role\":\"oracle\",\"content\":\"?\"}\n\
             {\"role\":\"tool\",\"content\":\"缺 tool_call_id\"}\n\
             {\"role\":\"user\",\"content\":\"好的第二行\"}\n",
        )
        .unwrap();

        let (loaded, warns) = load(&path);
        assert_eq!(loaded.messages.len(), 2);
        assert_eq!(loaded.messages[0], Message::user("好的那一行"));
        assert_eq!(loaded.messages[1], Message::user("好的第二行"));
        assert_eq!(warns.len(), 4, "四行损坏/缺 id: {warns:?}");
        for w in &warns {
            assert!(w.contains("已跳过该行"), "实际: {w}");
        }
        assert!(warns[0].contains("第 3 行"), "{}", warns[0]);
        assert!(warns[1].contains("第 4 行"), "{}", warns[1]);
        assert!(warns[2].contains("第 5 行"), "{}", warns[2]);
        assert!(warns[3].contains("第 6 行"), "{}", warns[3]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn head_required_and_version_checked() {
        let dir = tmpdir("head");
        // 无头
        {
            let p = (dir.join("nohead.jsonl")).to_string_lossy().to_string();
            std::fs::write(&p, "{\"role\":\"user\",\"content\":\"x\"}\n").unwrap();
            let mut out = LoadedSession::default();
            let mut warns = Vec::new();
            let e = load_session_file(&p, &mut out, &mut warns).unwrap_err();
            assert!(e.contains("会话头"), "实际: {e}");
        }
        // 版本不认
        {
            let p = (dir.join("v9.jsonl")).to_string_lossy().to_string();
            std::fs::write(
                &p,
                "{\"v\":9,\"type\":\"session_head\",\"robot\":\"r\",\"tools_fp\":\"t\",\"system_fp\":\"s\"}\n",
            )
            .unwrap();
            let mut out = LoadedSession::default();
            let mut warns = Vec::new();
            let e = load_session_file(&p, &mut out, &mut warns).unwrap_err();
            assert!(e.contains("版本"), "实际: {e}");
        }
        // 空文件
        {
            let p = (dir.join("empty.jsonl")).to_string_lossy().to_string();
            std::fs::write(&p, "").unwrap();
            let mut out = LoadedSession::default();
            let mut warns = Vec::new();
            let e = load_session_file(&p, &mut out, &mut warns).unwrap_err();
            assert!(e.contains("空或缺会话头"), "实际: {e}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn head_mismatch_names_field() {
        let now = SessionHead {
            version: SESSION_FILE_VERSION,
            robot: "relay-test".into(),
            tools_fp: "fp_tools_now".into(),
            system_fp: "fp_sys_now".into(),
            ..Default::default()
        };
        let mut old = now.clone();
        old.robot = "spider1".into();
        assert!(head_mismatch(&now, &old).unwrap().contains("结构脚本"));

        let mut old = now.clone();
        old.tools_fp = "fp_tools_old".into();
        assert!(head_mismatch(&now, &old).unwrap().contains("工具集"));

        let mut old = now.clone();
        old.system_fp = "fp_sys_old".into();
        assert!(head_mismatch(&now, &old).unwrap().contains("系统提示词"));

        // session_id 不参与比对（恢复就是要沿用它的）
        let mut old = now.clone();
        old.session_id = "different".into();
        assert!(head_mismatch(&now, &old).is_none());
    }

    #[test]
    fn writer_creates_session_file_with_0600() {
        use std::os::unix::fs::PermissionsExt;
        // 新会话文件与 REPL 历史 / ICA sidecar 同规：0600 创建，不随 umask 放宽
        // （2026-09-30 审计 P1；此前常见 0644 且 perms_warning 只查已存在文件）。
        let dir = tmpdir("create0600");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let mut w = SessionFileWriter::new();
        w.open(&path, false).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o777,
            0o600,
            "新会话文件应以 0600 创建（实际 {:o}）",
            mode
        );
        // 截断重建（同一 open(false) 路径）不放宽既有 0600 文件的权限
        drop(w);
        let mut w2 = SessionFileWriter::new();
        w2.open(&path, false).unwrap();
        let mode2 = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode2 & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn perms_warning_flags_wide_perms_and_600_is_quiet() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tmpdir("perms");
        let path = dir.join("s.jsonl");
        std::fs::write(&path, "x\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let p = path.to_string_lossy().to_string();
        let warn = perms_warning(&p);
        assert!(!warn.is_empty());
        assert!(warn.contains("chmod 600"), "实际: {warn}");

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(perms_warning(&p).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn clear_marker_drops_prior_history() {
        let dir = tmpdir("clear");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let mut w = fresh_writer(&path);
        for m in sample_conversation() {
            assert!(w.append_message(&m));
        }
        assert!(w.write_clear_marker());
        assert!(w.append_message(&Message::user("清空后的新任务")));
        drop(w);

        let (loaded, warns) = load(&path);
        assert!(warns.is_empty(), "{warns:?}");
        assert_eq!(loaded.messages.len(), 1);
        assert_eq!(loaded.messages[0], Message::user("清空后的新任务"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 摘要记录：载入时把此前的消息收口成最后 keep_blocks 个块，并带回摘要正文；
    /// 图片后注（磁盘上是占位文本形态）不能被当作块起点切开任务块。
    #[test]
    fn summary_record_trims_to_keep_blocks_and_restores_summary() {
        let dir = tmpdir("summary");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let mut w = fresh_writer(&path);
        for m in sample_conversation() {
            assert!(w.append_message(&m));
        }
        let second = vec![Message::user("任务二"), Message::assistant("二完成")];
        let third = vec![Message::user("任务三"), Message::assistant("三完成")];
        for m in second.iter().chain(third.iter()) {
            assert!(w.append_message(m));
        }
        // 写入进程此刻裁掉了任务一（含图片后注），留下两块
        assert!(w.write_summary("任务一：拍照并站立，已站立", 2));
        assert!(w.append_message(&Message::user("任务四")));
        drop(w);

        let (loaded, warns) = load(&path);
        assert!(warns.is_empty(), "{warns:?}");
        assert_eq!(
            loaded.summary.as_deref(),
            Some("任务一：拍照并站立，已站立")
        );
        let mut expected = second;
        expected.extend(third);
        expected.push(Message::user("任务四"));
        assert_eq!(loaded.messages, expected);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn summary_keep_zero_drops_everything_and_clear_forgets_summary() {
        let dir = tmpdir("summary0");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let mut w = fresh_writer(&path);
        assert!(w.append_message(&Message::user("任务一")));
        assert!(w.append_message(&Message::assistant("完成")));
        assert!(w.write_summary("全裁", 0));
        drop(w);
        let (loaded, warns) = load(&path);
        assert!(warns.is_empty(), "{warns:?}");
        assert!(loaded.messages.is_empty());
        assert_eq!(loaded.summary.as_deref(), Some("全裁"));

        let mut w = SessionFileWriter::new();
        w.open(&path, true).unwrap();
        assert!(w.write_clear_marker());
        drop(w);
        let (loaded, _) = load(&path);
        assert_eq!(loaded.summary, None, "/clear 连摘要一起忘掉");

        // 缺字段的摘要行：跳过并点名，不影响其余历史
        std::fs::write(
            &path,
            format!(
                "{}\n{{\"type\":\"session_summary\"}}\n{{\"role\":\"user\",\"content\":\"x\"}}\n",
                std::fs::read_to_string(&path)
                    .unwrap()
                    .lines()
                    .next()
                    .unwrap()
            ),
        )
        .unwrap();
        let (loaded, warns) = load(&path);
        assert_eq!(warns.len(), 1);
        assert!(warns[0].contains("session_summary"), "{warns:?}");
        assert_eq!(loaded.messages.len(), 1);
        assert_eq!(loaded.summary, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn image_placeholder_notice_is_recognised() {
        assert!(is_image_placeholder_notice(&image_placeholder(10)));
        assert!(is_image_placeholder_notice(&format!(
            "以上工具返回的图片如下。{}",
            image_placeholder(4096)
        )));
        assert!(!is_image_placeholder_notice(
            "任务：[图片 3 字节，未随会话恢复] 之后还有话"
        ));
        assert!(!is_image_placeholder_notice("普通任务"));
    }

    #[test]
    fn protocol_violation_flags_orphans_duplicates_and_missing() {
        // 孤儿：tool 的 id 没有任何 assistant 声明
        let orphan = vec![Message::User {
            content: vec![UserContent::tool_result(
                "ghost",
                "t",
                vec![ToolResultContent::Text("x".to_string().into())],
            )],
        }];
        assert!(protocol_violation(&orphan).unwrap().contains("孤儿"));

        // 重复：同一个 id 被回答两次
        let dup = vec![
            Message::Assistant {
                id: None,
                content: vec![AssistantContent::ToolCall(ToolCall::new(
                    ToolCallId::new_or_mint("c1"),
                    ToolFunction::new("t".to_string(), json!({})),
                ))],
            },
            Message::User {
                content: vec![UserContent::tool_result(
                    "c1",
                    "t",
                    vec![ToolResultContent::Text("x".to_string().into())],
                )],
            },
            Message::User {
                content: vec![UserContent::tool_result(
                    "c1",
                    "t",
                    vec![ToolResultContent::Text("y".to_string().into())],
                )],
            },
        ];
        assert!(protocol_violation(&dup).unwrap().contains("不止一次"));

        // 漏答：assistant 声明了但没有 tool 回执
        let missing = vec![Message::Assistant {
            id: None,
            content: vec![AssistantContent::ToolCall(ToolCall::new(
                ToolCallId::new_or_mint("c9"),
                ToolFunction::new("t".to_string(), json!({})),
            ))],
        }];
        assert!(protocol_violation(&missing)
            .unwrap()
            .contains("没有得到任何"));

        // 合法序列
        let ok = vec![
            Message::Assistant {
                id: None,
                content: vec![AssistantContent::ToolCall(ToolCall::new(
                    ToolCallId::new_or_mint("c1"),
                    ToolFunction::new("t".to_string(), json!({})),
                ))],
            },
            Message::User {
                content: vec![UserContent::tool_result(
                    "c1",
                    "t",
                    vec![ToolResultContent::Text("x".to_string().into())],
                )],
            },
        ];
        assert!(protocol_violation(&ok).is_none());
    }

    #[test]
    fn tools_fingerprint_is_order_sensitive_and_deterministic() {
        let a = tools_fingerprint(&["a".to_string(), "b".to_string()]);
        let b = tools_fingerprint(&["a".to_string(), "b".to_string()]);
        assert_eq!(a, b, "同输入同指纹");
        let c = tools_fingerprint(&["b".to_string(), "a".to_string()]);
        assert_ne!(a, c, "顺序不同则指纹不同（注册序是有意义的）");
        assert_eq!(a.len(), 16);
    }

    /// 实测：C++ 时代参考格式写的文件（content 为字符串、tool 行不带工具名）本实现
    /// 能读回——格式兼容的钉子（tools_fp/system_fp 用真实指纹以免误判为损坏）。
    #[test]
    fn reads_cpp_style_file() {
        let dir = tmpdir("cppstyle");
        let path = (dir.join("s.jsonl")).to_string_lossy().to_string();
        let head = format!(
            "{{\"v\":1,\"type\":\"session_head\",\"session\":\"sess1\",\"robot\":\"relay-test\",\
             \"tools_fp\":\"{}\",\"system_fp\":\"{}\",\"created\":\"2026-09-25T12:00:00.000+08:00\"}}\n",
            tools_fingerprint(&["tool_a".to_string()]),
            fingerprint64("sys"),
        );
        let body = "{\"role\":\"user\",\"content\":\"任务\"}\n\
                    {\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"tool_a\",\"arguments\":\"{}\"}]}\n\
                    {\"role\":\"tool\",\"content\":\"回执\",\"tool_call_id\":\"c1\"}\n\
                    {\"role\":\"assistant\",\"content\":\"完成\"}\n";
        std::fs::write(&path, format!("{head}{body}")).unwrap();
        let (loaded, warns) = load(&path);
        assert!(warns.is_empty(), "{warns:?}");
        assert_eq!(loaded.head.session_id, "sess1");
        assert_eq!(loaded.messages.len(), 4);
        assert!(protocol_violation(&loaded.messages).is_none());
        // tool 行的工具名回查成功
        let Message::User { content } = &loaded.messages[2] else {
            panic!()
        };
        let UserContent::ToolResult(r) = &content[0] else {
            panic!()
        };
        assert_eq!(r.name, "tool_a");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 批次 A（P1-2）：读取面设限——超过 `BUDGET_BYTES_MAX` 的文件在 read 之前
    /// 拒绝（稀疏文件构造，不真写盘）；不存在的文件维持既有文案。
    #[test]
    fn load_rejects_oversized_file_before_reading() {
        let dir = tmpdir("toolarge");
        let path = (dir.join("huge.jsonl")).to_string_lossy().to_string();
        let cap = crate::config::limits::BUDGET_BYTES_MAX as u64;
        let f = std::fs::File::create(&path).unwrap();
        f.set_len(cap + 1).unwrap(); // sparse：只在 metadata 上超限
        drop(f);

        let mut loaded = LoadedSession::default();
        let mut warns = Vec::new();
        let err = match load_session_file(&path, &mut loaded, &mut warns) {
            Ok(()) => panic!("超限文件必须被拒绝"),
            Err(e) => e,
        };
        assert!(
            err.contains("超过上限") && err.contains(&path),
            "实际: {err}"
        );

        let missing = (dir.join("nope.jsonl")).to_string_lossy().to_string();
        let err2 = load_session_file(&missing, &mut loaded, &mut warns).unwrap_err();
        assert!(err2.contains("无法读取会话文件"), "实际: {err2}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

//! history.rs —— 会话历史的字节预算与整块裁剪（`src/agenthistory.cpp` 的镜像）
//!
//! 裁剪只裁**已完结的旧任务块**，且最新任务块无条件保留：正在进行的对话不能裁空
//! （裁空了任务无法推进），单块超预算也不封顶。块起点在 C++ 侧的判据是
//! 「role == user 且 images 为空」——即「一条不带图片的 user 消息开启一个新任务块」
//! （带图片的 user 消息是同一任务块里的图片后注）。rig 形态等价判据：
//! `Message::User` 且内容里**既没有 ToolResult 也没有 Image**（rig 没有独立的 tool
//! 角色，工具结果装在 `User{content:[ToolResult..]}` 里）。
//!
//! 记账口径（C4，与 C++ 的 messageWeight 同源）：只估算正文/调用参数/图片/**思维链**
//! 内容的字节，不计 JSON 语法开销、role 字符串与非 ASCII 的转义膨胀——作为裁剪判据
//! 方向正确、量级够用。C++ 侧另有两点在 rig 侧天然不同：
//!   * C++ 的 messages[0] 恒为 system（不计入预算、永不裁剪）；rig 的 system 是
//!     agent 的 preamble，根本不在这份历史里，故无「跳过第 0 条」的特例；
//!   * 工具 schema 不在历史里（rig 每次请求单独带 tools），同样不计。
//!
//! 历史摘要（2026-09-25）：被裁掉的整块可以由模型压成一份摘要（summary.rs），摘要
//! **不进 messages**——它挂在系统提示词末尾（repl.rs 组装），所以块判据、回滚边界、
//! 图片注入序号都不受影响；本文件只负责保存它、把它的字节从预算里扣掉、随
//! `/clear` 一起忘掉。恢复期的块判据有一处补丁：会话文件把图片写成占位文本
//! （`session::image_placeholder`），读回后那条 user 消息不再带 Image 内容，若按
//! 「不带图片的 user 消息」判为块起点，图片后注就会把一个任务块**切成两半**——裁剪
//! 只会切在块起点，切在这里会让「任务 + 最终回答」分家。故占位文本形态的 user 消息
//! 同样不是块起点（判据由 session.rs 与占位文本同源维护）。

use rig_agent::completion::message::{
    AdditionalParams, Image, ReasoningContent, ToolResultContent, UserContent,
};
use rig_agent::completion::{AssistantContent, Message};

use crate::placeholder::is_image_placeholder_notice;
use crate::placeholder::source_len;

#[derive(Default)]
pub struct ConversationHistory {
    messages: Vec<Message>,
    /// 与 messages 对齐的增量权重，避免每次任务裁剪都重复序列化工具参数。
    weights: Vec<usize>,
    written_prefix: usize,
    /// 更早已裁出的任务块的模型摘要（正文，不含定界外壳）；`None` = 尚无。
    summary: Option<String>,
}

impl ConversationHistory {
    pub fn resumed(messages: Vec<Message>, summary: Option<String>) -> Self {
        let weights = messages.iter().map(message_weight).collect();
        Self {
            written_prefix: messages.len(),
            messages,
            weights,
            summary,
        }
    }

    pub fn snapshot(&self) -> Vec<Message> {
        self.messages.clone()
    }

    pub fn len(&self) -> usize {
        self.messages.len()
    }

    pub fn written_prefix(&self) -> usize {
        self.written_prefix
    }

    pub fn summary(&self) -> Option<&str> {
        self.summary.as_deref()
    }

    pub fn set_summary(&mut self, summary: String) {
        self.summary = Some(summary);
    }

    /// 整块裁剪；返回被裁掉的消息（按原序，只含完整任务块；空 = 没裁）。
    pub fn evict(&mut self, budget: usize, log: &mut dyn FnMut(&str)) -> Vec<Message> {
        let dropped = evict_with_weights(&self.messages, &mut self.weights, budget, log);
        if dropped == 0 {
            return Vec::new();
        }
        self.written_prefix = self.written_prefix.saturating_sub(dropped);
        self.weights.drain(0..dropped);
        self.messages.drain(0..dropped).collect()
    }

    /// 已落盘消息里的任务块数——会话文件 `session_summary` 记录的 `keep_blocks`：
    /// 恢复时据此把磁盘上「摘要已覆盖」的旧块收掉，只留这么多个最新块。未落盘的
    /// 消息（失败任务的完整轮）不算：恢复读到摘要记录那一刻，磁盘上还没有它们。
    pub fn persisted_blocks(&self) -> usize {
        block_starts(&self.messages[..self.written_prefix]).len()
    }

    pub fn replace(&mut self, messages: Vec<Message>) {
        self.weights = messages.iter().map(message_weight).collect();
        self.messages = messages;
    }

    /// 借出全部消息（只读）——收尾观察点（录制等）用，避免 `snapshot` 的整份克隆。
    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    /// 追加一段新消息（任务正常收尾路径）：权重只算新增的，不重算已有历史。
    /// `replace` 的全量重算在带图片的长会话里是每任务一次 O(历史) 的 JSON
    /// 序列化（工具调用参数要过 `serde_json` 量长度），正常路径不该付。
    pub fn append(&mut self, messages: Vec<Message>) {
        self.weights.extend(messages.iter().map(message_weight));
        self.messages.extend(messages);
    }

    pub fn persist(&mut self, mut append: impl FnMut(&Message) -> bool) {
        for message in &self.messages[self.written_prefix..] {
            if !append(message) {
                break;
            }
            self.written_prefix += 1;
        }
    }

    pub fn clear(&mut self) {
        self.messages.clear();
        self.weights.clear();
        self.written_prefix = 0;
        self.summary = None;
    }
}

/// 任务块起点：不带工具结果、不带图片、也不是恢复期图片占位形态的 user 消息。
pub fn is_block_start(m: &Message) -> bool {
    match m {
        Message::User { content } => !content.iter().any(|c| match c {
            UserContent::ToolResult(_) | UserContent::Image(_) => true,
            UserContent::Text(t) => is_image_placeholder_notice(&t.text),
            _ => false,
        }),
        _ => false,
    }
}

/// 全部任务块起点的下标（升序）。
pub fn block_starts(history: &[Message]) -> Vec<usize> {
    history
        .iter()
        .enumerate()
        .filter(|(_, m)| is_block_start(m))
        .map(|(i, _)| i)
        .collect()
}

/// 估算一条消息的线上体积（下界）。
pub fn message_weight(m: &Message) -> usize {
    match m {
        Message::System { content } => content.len(),
        Message::User { content } => content.iter().map(user_content_weight).sum(),
        Message::Assistant { id, content } => {
            let mut n = id.as_ref().map_or(0, |s| s.len());
            for item in content {
                n += match item {
                    AssistantContent::Text(t) => t.text.len() + params_len(&t.additional_params),
                    AssistantContent::ToolCall(c) => {
                        c.id.as_str().len()
                            + c.function.name.len()
                            + serde_json::to_string(&c.function.arguments).map_or(0, |s| s.len())
                    }
                    // 思维链必须计入：DeepSeek 的 reasoning_content 随历史逐轮回传，
                    // 它和正文一样占请求体（C++ 的 extras 就是这一项）。
                    AssistantContent::Reasoning(r) => r
                        .content
                        .iter()
                        .map(|c| match c {
                            ReasoningContent::Text { text, signature } => {
                                text.len() + signature.as_ref().map_or(0, |s| s.len())
                            }
                            ReasoningContent::Encrypted(s) => s.len(),
                            ReasoningContent::Redacted { data } => data.len(),
                            ReasoningContent::Summary(s) => s.len(),
                        })
                        .sum::<usize>(),
                    AssistantContent::Image(i) => image_weight(i),
                };
            }
            n
        }
    }
}

fn user_content_weight(c: &UserContent) -> usize {
    match c {
        UserContent::Text(t) => t.text.len() + params_len(&t.additional_params),
        UserContent::ToolResult(r) => {
            let mut n = r.call.as_str().len() + r.name.len();
            for item in &r.content {
                n += match item {
                    ToolResultContent::Text(t) => t.text.len() + params_len(&t.additional_params),
                    ToolResultContent::Json { value } => {
                        serde_json::to_string(value).map_or(0, |s| s.len())
                    }
                    ToolResultContent::Image(i) => image_weight(i),
                };
            }
            n
        }
        UserContent::Image(i) => image_weight(i),
        UserContent::Audio(a) => source_len(&a.data) + params_len(&a.additional_params),
        UserContent::Video(v) => source_len(&v.data) + params_len(&v.additional_params),
        UserContent::Document(d) => source_len(&d.data) + params_len(&d.additional_params),
    }
}

/// 图片体积：base64/data URL 是历史体积的主项（C++ 的 images 数组同口径）。
fn image_weight(i: &Image) -> usize {
    source_len(&i.data) + params_len(&i.additional_params)
}

fn params_len(p: &Option<AdditionalParams>) -> usize {
    p.as_ref()
        .and_then(|p| serde_json::to_string(p).ok())
        .map_or(0, |s| s.len())
}

/// 任务块整块裁剪。返回被裁掉的消息（按原序；空 = 没裁）。
///
/// 语义与 `HistoryManager::trim` 逐条一致：预算为 0 或不含任务块时不动；从最新块
/// 向旧累计，最新块无条件保留，其余「装得下就留」；被裁的整块（含其中的图片）
/// 一起消失，且裁剪前会经 `log` 如实告知操作者（C++ 侧受 verbose 闸门控制；本进程
/// 一律走 stderr——裁剪意味着更早的任务上下文不再可见，这种事实不该静默）。
/// 切口只落在块起点：一对 tool_call/tool_result、一问一答永远不会只剩一半——被裁
/// 部分整块交给摘要器，留下部分整块送给模型。
///
/// `#[cfg(test)]`：生产路径走 `ConversationHistory::evict`（增量权重，不经全量重算），
/// 这份对裸 `Vec<Message>` 的入口只有测试直用——留着它是为了白盒核对整块不变量
/// （裁掉 + 留下 = 原历史、切口落块起点）；编进二进制就是 dead code。
#[cfg(test)]
pub fn evict(history: &mut Vec<Message>, budget: usize, log: &mut dyn FnMut(&str)) -> Vec<Message> {
    let mut weights: Vec<usize> = history.iter().map(message_weight).collect();
    let dropped = evict_with_weights(history, &mut weights, budget, log);
    history.drain(0..dropped).collect()
}

/// 仅计算并返回应裁掉的消息数；调用方负责同步裁剪消息与权重。
fn evict_with_weights(
    history: &[Message],
    weights: &mut [usize],
    budget: usize,
    log: &mut dyn FnMut(&str),
) -> usize {
    if budget == 0 || history.is_empty() {
        return 0;
    }
    debug_assert_eq!(history.len(), weights.len());
    let starts = block_starts(history);
    if starts.is_empty() {
        // 防御：历史理应至少含一次任务（一条不带图片的 user 消息）
        return 0;
    }

    let mut keep = starts.len() - 1;
    let block_weight = |j: usize| {
        let start = starts[j];
        let end = starts.get(j + 1).copied().unwrap_or(history.len());
        weights[start..end].iter().sum::<usize>()
    };
    let mut acc = block_weight(keep);
    while keep > 0 && acc + block_weight(keep - 1) <= budget {
        keep -= 1;
        acc += block_weight(keep);
    }
    if keep == 0 {
        return 0; // 全部塞得下，无事可做
    }
    let dropped = starts[keep];
    log(&format!(
        "[历史] 超出字节预算，已裁掉最早的 {dropped} 条消息（含其中的图片）；\
         更早的任务上下文不再可见"
    ));
    dropped
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一段「任务块」：user 任务 + assistant(tool_calls) + tool 结果 + 图片后注。
    fn task_block(task: &str, tool_text: &str, image_bytes: usize) -> Vec<Message> {
        let mut msgs = vec![Message::user(task.to_string())];
        msgs.push(Message::Assistant {
            id: None,
            content: vec![AssistantContent::ToolCall(
                rig_agent::completion::message::ToolCall::new(
                    rig_agent::completion::message::ToolCallId::new_or_mint("call_0"),
                    rig_agent::completion::message::ToolFunction::new(
                        "capture_image".to_string(),
                        serde_json::json!({}),
                    ),
                ),
            )],
        });
        msgs.push(Message::User {
            content: vec![UserContent::tool_result(
                "call_0",
                "capture_image",
                vec![ToolResultContent::Text(tool_text.to_string().into())],
            )],
        });
        if image_bytes > 0 {
            msgs.push(Message::User {
                content: vec![
                    UserContent::text("以上工具返回的图片如下，请结合画面内容继续。"),
                    UserContent::image_base64("A".repeat(image_bytes), None, None),
                ],
            });
        }
        msgs
    }

    #[test]
    fn repeated_eviction_keeps_incremental_weights_aligned() {
        let mut history = ConversationHistory::resumed(
            [
                task_block("旧任务 1", "结果", 0),
                task_block("旧任务 2", "结果", 0),
                task_block("最新任务", "结果", 0),
            ]
            .concat(),
            None,
        );
        assert!(!history.evict(1, &mut |_| {}).is_empty());
        assert!(history.evict(1, &mut |_| {}).is_empty());
        assert_eq!(history.len(), history.snapshot().len());
    }

    #[test]
    fn appended_blocks_keep_weights_aligned_for_eviction() {
        let mut history = ConversationHistory::default();
        history.append(task_block("旧任务 1", "结果", 0));
        history.append(task_block("旧任务 2", "结果", 0));
        history.append(task_block("最新任务", "结果", 0));
        // 与 resumed 形态同口径：权重增量维护不错位，两次裁剪后收敛
        assert!(!history.evict(1, &mut |_| {}).is_empty());
        assert!(history.evict(1, &mut |_| {}).is_empty());
        assert_eq!(history.len(), history.snapshot().len());
    }

    #[test]
    fn trimming_written_history_does_not_skip_new_messages() {
        let old = task_block("旧任务", "旧结果", 1024);
        let retained = task_block("保留任务", "保留结果", 0);
        let mut initial = old.clone();
        initial.extend(retained.clone());
        let mut history = ConversationHistory::resumed(initial, None);
        assert_eq!(history.evict(1, &mut |_| {}).len(), old.len());
        assert_eq!(history.written_prefix(), retained.len());

        let new = vec![Message::user("新任务"), Message::assistant("新回答")];
        let mut completed = history.snapshot();
        completed.extend(new.clone());
        history.replace(completed);
        let mut written = Vec::new();
        history.persist(|m| {
            written.push(m.clone());
            true
        });
        assert_eq!(written, new);
        assert_eq!(history.written_prefix(), history.len());
        history.persist(|_| panic!("已落盘消息不得重复追加"));
    }

    #[test]
    fn trimming_unwritten_history_saturates_the_written_prefix() {
        let mut history = ConversationHistory::resumed(task_block("已落盘", "结果", 0), None);
        let retained = task_block("最新未落盘", "完整回执", 0);
        let mut pending = history.snapshot();
        pending.extend(task_block("较早未落盘", "完整回执", 1024));
        let expected_dropped = pending.len();
        pending.extend(retained.clone());
        history.replace(pending);
        assert_eq!(history.evict(1, &mut |_| {}).len(), expected_dropped);
        assert_eq!(history.written_prefix(), 0);
        let mut written = Vec::new();
        history.persist(|m| {
            written.push(m.clone());
            true
        });
        assert_eq!(written, retained);
    }

    #[test]
    fn completed_rounds_from_failed_task_are_written_with_next_success() {
        let old = task_block("已落盘", "结果", 0);
        let mut history = ConversationHistory::resumed(old.clone(), None);
        let completed_round = task_block("失败任务", "失败前的完整回执", 64);
        let mut boundary = history.snapshot();
        boundary.extend(completed_round.clone());
        history.replace(boundary);
        assert_eq!(history.written_prefix(), old.len());
        assert_eq!(history.evict(0, &mut |_| panic!("不应裁剪")).len(), 0);

        let next = vec![Message::user("下一任务"), Message::assistant("完成")];
        let mut completed = history.snapshot();
        completed.extend(next.clone());
        history.replace(completed);
        let mut written = Vec::new();
        history.persist(|m| {
            written.push(m.clone());
            true
        });
        let mut expected = completed_round;
        expected.extend(next);
        assert_eq!(written, expected);
    }

    #[test]
    fn failed_append_stops_without_advancing_past_the_failure() {
        let mut history = ConversationHistory::default();
        history.replace(vec![
            Message::user("任务"),
            Message::assistant("回答"),
            Message::user("下一任务"),
        ]);
        let mut attempts = 0;
        history.persist(|_| {
            attempts += 1;
            attempts == 1
        });
        assert_eq!(attempts, 2);
        assert_eq!(history.written_prefix(), 1);
        history.persist(|_| false);
        assert_eq!(history.written_prefix(), 1);
    }

    #[test]
    fn clearing_resumed_history_resets_persistence() {
        let mut history = ConversationHistory::resumed(task_block("旧任务", "结果", 0), None);
        history.persist(|_| panic!("恢复的历史不得重写"));
        history.clear();
        assert_eq!(history.len(), 0);
        assert_eq!(history.written_prefix(), 0);
        let new = vec![Message::user("新任务"), Message::assistant("新回答")];
        history.replace(new.clone());
        let mut written = Vec::new();
        history.persist(|m| {
            written.push(m.clone());
            true
        });
        assert_eq!(written, new);
    }

    #[test]
    fn newest_block_is_kept_and_old_blocks_are_dropped_whole() {
        let mut h = Vec::new();
        h.extend(task_block("任务一", &"x".repeat(100), 0));
        h.extend(task_block("任务二", &"y".repeat(100), 0));
        let newest_len = task_block("任务三", &"z".repeat(1000), 0).len();
        h.extend(task_block("任务三", &"z".repeat(1000), 0));
        assert_eq!(h.len(), 9);

        // 预算只装得下最新块：前两块整块消失（含它们各自的消息）
        let mut logs: Vec<String> = Vec::new();
        let dropped = evict(&mut h, 1001, &mut |t| logs.push(t.to_string())).len();
        assert_eq!(dropped, 6, "裁掉最早两块（3 条 x 2）");
        assert_eq!(h.len(), newest_len);
        assert_eq!(h[0], Message::user("任务三".to_string()));
        assert_eq!(logs.len(), 1, "裁剪必须如实告知一次");
        assert_eq!(
            logs[0],
            "[历史] 超出字节预算，已裁掉最早的 6 条消息（含其中的图片）；更早的任务上下文不再可见"
        );
    }

    #[test]
    fn all_blocks_fit_or_budget_zero_means_no_trim() {
        let mut h = Vec::new();
        h.extend(task_block("任务一", "短", 0));
        h.extend(task_block("任务二", "短", 0));
        let before = h.clone();
        // 0 = 不裁剪
        assert!(evict(&mut h, 0, &mut |_| panic!("不该有日志")).is_empty());
        assert_eq!(h, before);
        // 预算够大：全部塞得下
        assert!(evict(&mut h, 1 << 20, &mut |_| panic!("不该有日志")).is_empty());
        assert_eq!(h, before);
    }

    #[test]
    fn image_notice_does_not_start_a_new_block() {
        // 图片后注（user + Image）不是新任务块：它的字节能让整块一起被裁
        let mut h = Vec::new();
        let with_img = task_block("任务一", "老", 4096);
        h.extend(with_img.clone());
        h.extend(task_block("任务二", "新", 0));
        let dropped = evict(&mut h, 1, &mut |_| {}).len();
        assert_eq!(dropped, with_img.len(), "第一块连同图片后注一起消失");
        assert_eq!(h[0], Message::user("任务二".to_string()));
    }

    /// 一条消息里声明/回答的 tool_call id 集合。
    fn call_ids(msgs: &[Message]) -> (Vec<String>, Vec<String>) {
        let mut declared = Vec::new();
        let mut answered = Vec::new();
        for m in msgs {
            match m {
                Message::Assistant { content, .. } => {
                    for c in content {
                        if let AssistantContent::ToolCall(c) = c {
                            declared.push(c.id.as_str().to_string());
                        }
                    }
                }
                Message::User { content } => {
                    for c in content {
                        if let UserContent::ToolResult(r) = c {
                            answered.push(r.call.as_str().to_string());
                        }
                    }
                }
                _ => {}
            }
        }
        (declared, answered)
    }

    /// 造一段 id 互不相同的任务块（task_block 固定用 call_0，多块混在一起分不清归属）。
    fn task_block_with_id(task: &str, call_id: &str, image_bytes: usize) -> Vec<Message> {
        let mut msgs = task_block(task, "回执", image_bytes);
        if let Message::Assistant { content, .. } = &mut msgs[1] {
            content[0] = AssistantContent::ToolCall(rig_agent::completion::message::ToolCall::new(
                rig_agent::completion::message::ToolCallId::new_or_mint(call_id),
                rig_agent::completion::message::ToolFunction::new(
                    "capture_image".to_string(),
                    serde_json::json!({}),
                ),
            ));
        }
        if let Message::User { content } = &mut msgs[2] {
            content[0] = UserContent::tool_result(
                call_id,
                "capture_image",
                vec![ToolResultContent::Text("回执".to_string().into())],
            );
        }
        msgs
    }

    /// 被裁片段永远是完整任务块：不留孤儿 tool_call/tool_result、不留半对问答。
    /// 这条不变量是摘要器成立的前提——摘要只看被裁部分，留下部分只给模型，两边
    /// 都不能拿到半截上下文。
    #[test]
    fn evicted_and_remaining_are_both_whole_blocks() {
        let mut h = Vec::new();
        // 块一：任务 + 工具往返 + 图片后注 + 最终回答
        h.extend(task_block_with_id("任务一", "call_a", 512));
        h.push(Message::assistant("任务一完成"));
        // 块二：恢复期形态——图片后注是占位文本（不带 Image），不得被当成新块起点
        h.extend(task_block_with_id("任务二", "call_b", 0));
        h.push(Message::user(format!(
            "以上工具返回的图片如下，请结合画面内容继续。{}",
            crate::placeholder::image_placeholder(4096)
        )));
        h.push(Message::assistant("任务二完成"));
        // 块三：以工具回执结尾、没有最终回答（失败任务留下的完整轮）
        h.extend(task_block_with_id("任务三", "call_c", 0));
        // 块四：最新块，无条件保留
        h.extend(task_block_with_id("任务四", "call_d", 2048));
        let original = h.clone();
        let starts = block_starts(&original);
        assert_eq!(starts.len(), 4, "占位文本形态的图片后注不是块起点");

        for budget in [1usize, 300, 2100, 2600, 1 << 20] {
            let mut work = original.clone();
            let evicted = evict(&mut work, budget, &mut |_| {});
            let mut rejoined = evicted.clone();
            rejoined.extend(work.clone());
            assert_eq!(rejoined, original, "裁掉 + 留下 = 原历史（预算 {budget}）");
            assert!(
                starts.contains(&evicted.len()) || evicted.is_empty(),
                "切口必须落在块起点（预算 {budget}，切在 {}）",
                evicted.len()
            );
            assert!(
                is_block_start(&work[0]),
                "留下部分从块起点开始（预算 {budget}）"
            );
            let (decl_e, ans_e) = call_ids(&evicted);
            let (decl_r, ans_r) = call_ids(&work);
            let mut de = decl_e.clone();
            let mut ae = ans_e.clone();
            de.sort();
            ae.sort();
            assert_eq!(de, ae, "被裁部分的工具调用与回执成对（预算 {budget}）");
            let mut dr = decl_r.clone();
            let mut ar = ans_r.clone();
            dr.sort();
            ar.sort();
            assert_eq!(dr, ar, "留下部分的工具调用与回执成对（预算 {budget}）");
        }

        // 预算 1：只留最新块；前三块（含任务三这种没有回答的块）整体被裁
        let mut work = original.clone();
        let evicted = evict(&mut work, 1, &mut |_| {});
        assert_eq!(work[0], Message::user("任务四".to_string()));
        assert_eq!(evicted.len(), starts[3]);
        assert_eq!(
            evicted.last(),
            Some(&original[starts[3] - 1]),
            "任务三的回执与它的调用一同被裁"
        );
    }

    #[test]
    fn evict_on_history_keeps_summary_and_shrinks_written_prefix() {
        let old = task_block("旧任务", "旧结果", 1024);
        let retained = task_block("保留任务", "保留结果", 0);
        let mut initial = old.clone();
        initial.extend(retained.clone());
        let mut history = ConversationHistory::resumed(initial, Some("旧摘要".to_string()));
        assert_eq!(history.persisted_blocks(), 2);
        let evicted = history.evict(1, &mut |_| {});
        assert_eq!(evicted, old);
        assert_eq!(history.summary(), Some("旧摘要"));
        assert_eq!(history.persisted_blocks(), 1);
        history.set_summary("新摘要".to_string());
        history.clear();
        assert_eq!(history.summary(), None, "/clear 连摘要一起忘掉");
    }

    #[test]
    fn persisted_blocks_ignores_unwritten_messages() {
        let mut history = ConversationHistory::resumed(task_block("已落盘", "结果", 0), None);
        let mut pending = history.snapshot();
        pending.extend(task_block("未落盘", "结果", 0));
        history.replace(pending);
        assert_eq!(history.persisted_blocks(), 1);
        history.persist(|_| true);
        assert_eq!(history.persisted_blocks(), 2);
    }

    #[test]
    fn message_weight_counts_text_calls_and_images() {
        let block = task_block("任务", "工具输出文本", 1000);
        let w_user = message_weight(&block[0]);
        assert_eq!(w_user, "任务".len());
        let w_asst = message_weight(&block[1]);
        assert!(w_asst >= "capture_image".len() + "call_0".len());
        let w_tool = message_weight(&block[2]);
        assert!(w_tool >= "工具输出文本".len() + "capture_image".len());
        let w_img = message_weight(&block[3]);
        assert_eq!(
            w_img,
            "以上工具返回的图片如下，请结合画面内容继续。".len() + 1000
        );
    }
}

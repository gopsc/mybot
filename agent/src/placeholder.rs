//! 会话恢复占位文本与消息媒体体积估算——session / history / summary 共用的
//! 判据单点（2026-10-01 自 session.rs 下沉为独立叶子模块，解开
//! session ↔ history 的模块环：块起点判据与占位判据不再互相反向引用）。
//!
//! 这两族判据各自「同源维护」的理由：
//! - 占位文本族：写入期（encode_user 追加后注）与恢复期判读（块起点排除）
//!   必须是同一份文本认知，漂移的后果是恢复后的图片后注被当成新任务块
//!   起点，历史裁剪从此切错位置；
//! - 体积估算族：会话落盘的 image_bytes 记账（session）、历史估重
//!   （history::message_weight）与被裁块摘要（summary）三处若各写一份，
//!   「图片占多少」三个口径对不上，预算判据就随抄写漂移。

use rig_agent::completion::message::DocumentSourceKind;

/// 图片占位文本（写入期排除后的落盘形态；恢复后模型可见，据此知道图片不在）。
/// 与 C++ `sessionImagePlaceholder` 逐字同文本。
pub fn image_placeholder(total_image_bytes: usize) -> String {
    format!("[图片 {total_image_bytes} 字节，未随会话恢复]")
}

/// 一段 user 文本是否是恢复期的图片后注（encode_user 把占位追加在 caption 之后，
/// 所以判据是「以占位文本收尾」）。history.rs 用它把这种消息排除在块起点之外——
/// 判据与 [`image_placeholder`] 同源维护。
pub fn is_image_placeholder_notice(text: &str) -> bool {
    text.ends_with("字节，未随会话恢复]") && text.contains("[图片 ")
}

/// 媒体源的线上体积（字节）：Url/Base64/FileId/String 按字符串长度、Raw 按
/// 字节数、Unknown 记 0。session（落盘 image_bytes 记账）、history
/// （message_weight 估重）与 summary（被裁块摘要的「N 字节，已略去」）共用。
pub fn source_len(kind: &DocumentSourceKind) -> usize {
    match kind {
        DocumentSourceKind::Url(s)
        | DocumentSourceKind::Base64(s)
        | DocumentSourceKind::FileId(s)
        | DocumentSourceKind::String(s) => s.len(),
        DocumentSourceKind::Raw(b) => b.len(),
        DocumentSourceKind::Unknown => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rig_agent::completion::message::DocumentSourceKind as K;

    #[test]
    fn source_len_covers_all_variants() {
        assert_eq!(source_len(&K::Url("https://x/".into())), 10);
        assert_eq!(source_len(&K::Base64("QUJD".into())), 4);
        assert_eq!(source_len(&K::FileId("f-1".into())), 3);
        assert_eq!(source_len(&K::String("data".into())), 4);
        assert_eq!(source_len(&K::Raw(vec![0u8, 1, 2])), 3);
        assert_eq!(source_len(&K::Unknown), 0);
    }

    #[test]
    fn placeholder_notice_roundtrips() {
        let p = image_placeholder(4096);
        assert!(p.contains("4096"));
        assert!(is_image_placeholder_notice(&p));
        assert!(is_image_placeholder_notice(&format!("图片说明如下。{p}")));
        assert!(!is_image_placeholder_notice("普通任务"));
    }
}

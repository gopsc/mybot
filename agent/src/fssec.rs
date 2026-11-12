//! 敏感文件落盘判据单点——audit / session / record / session_store / config 共用的
//! 三族判据（第五轮 Phase 4 自五处手抄收敛而来）：
//! - 0600 创建 mode（六份逐字 `#[cfg(unix)]` 脚手架）；
//! - 0700 目录设权（session_store::set_mode_0700 与 record::set_dir_0700 两份，
//!   仅报错文案差一个词，经 `what` 参数逐字复现）;
//! - 「权限宽于 600/700」告警判据（mode & 0o077，四处告警**文案**刻意不同、
//!   仍留在各自模块，这里只收敛判据本体）。
//!
//! 评估过但**不**收敛的两对：write_pointer（session_store 版带 fsync、指针名
//! `current`、内容带换行；record 版无 fsync、指针名 `latest`）与 create_segment
//! （O_EXCL 占文件 vs mkdir+0700 占目录）——操作本体、报错文案、持久化语义都
//! 不同，合并需要三个文本参数加错误分类枚举，抽象面大于复制面；各自保留，
//! 判据同源处已有就地注释互指。

use std::fs::OpenOptions;
use std::path::Path;

/// 给 OpenOptions 设 0600 创建 mode。mode() 只在**创建新文件**时生效（打开既有
/// 文件时被忽略），故无条件设置即可；umask 只能进一步收紧，不会放宽。
/// 非 unix 无操作。
pub(crate) fn opts_0600(opts: &mut OpenOptions) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    #[cfg(not(unix))]
    {
        let _ = opts;
    }
}

/// 给目录设 0700。`what` 进报错文案（两个原站点逐字：「目录」/「录制目录」）。
pub(crate) fn set_dir_0700(p: &Path, what: &str) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("无法设置{what}权限 {}（{e}）", p.display()))
    }
    #[cfg(not(unix))]
    {
        let _ = (p, what);
        Ok(())
    }
}

/// 宽权限判据的对象类型。`Any` 保 config 秘密文件告警的原行为：它历史上
/// 不做 is_file 检查（路径是目录也照告警）。
pub(crate) enum PermKind {
    File,
    Dir,
    Any,
}

/// 权限是否宽于 600/700：S_IRGRP|S_IWGRP|S_IROTH|S_IWOTH = 0o077 任一置位。
/// 不存在 / 取不到权限 / 类型不符 → false（新建路径由各站点的 0600/0700 兜住）。
pub(crate) fn wide_perms(path: &str, kind: PermKind) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let Ok(st) = std::fs::metadata(path) else {
            return false;
        };
        match kind {
            PermKind::File if !st.is_file() => return false,
            PermKind::Dir if !st.is_dir() => return false,
            PermKind::Any => {}
            _ => {}
        }
        st.mode() & 0o077 != 0
    }
    #[cfg(not(unix))]
    {
        let _ = (path, kind);
        false
    }
}

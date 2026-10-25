//! 测试助手单点：tmpdir——各测试模块的临时根目录助手。第五轮 Phase 3 自
//! record / runtime / session / session_store / repl 五份手抄收敛而来。
//!
//! 目录名 = 前缀 + tag + 进程号 + 全局计数器：并行测试互不撞名，且跨运行残留
//! 不会串进本次（remove_dir_all 先清同名残留）。前缀由各模块自带（保持原有
//! 命名的可 grep 性），策略取原五份两种做法（先清后建 / 计数器唯一）的超集。
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(crate) fn tmpdir(prefix: &str, tag: &str) -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("{prefix}_{tag}_{}_{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

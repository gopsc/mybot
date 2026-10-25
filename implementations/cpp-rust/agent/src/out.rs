//! out.rs —— 面向操作者的 stdout/stderr 检查式写出
//!
//! 为什么不用 `println!`/`eprintln!`：Rust 运行时把 SIGPIPE 置为 ignore，
//! 管道断裂（`| head`、`| grep -m1`）或重定向到 `/dev/full` 时 write 返回
//! EPIPE/ENOSPC，而这两个宏对写失败**直接 panic**（退出码 101）——审计收尾
//! （session end 行）与正常退出码随之丢失。C++ 侧 printf 失败只设 errno、
//! 进程照常走完收尾；本模块把两侧写出口径拉齐（2026-09-24 审计 H2）。
//!
//! 失败策略：
//!   * stdout 失败 → stderr 告警**一次**（经 libc::write，自身绝不 panic），
//!     进程继续——输出丢了可以接受，审计 end 行丢了不可接受。
//!   * stderr 失败 → 静默吞掉（stdout 是模型输出与交互界面的保留通道，
//!     不能往里混告警；stderr 坏了也没有别处可说）。
//!   * 两者的返回值都忽略：写界面不是关键路径，调用点不需要分叉处理。

use std::fmt::Arguments;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

static STDOUT_WARNED: AtomicBool = AtomicBool::new(false);

/// stdout 写失败的一次性告警（直写 fd 2，不经 `eprintln!`——那会引入第二个
/// panic 面）。告警文本含换行；`write` 失败（stderr 也坏）就放弃，无副作用。
fn warn_stdout_broken(e: std::io::Error) {
    if STDOUT_WARNED.swap(true, Ordering::Relaxed) {
        return;
    }
    let msg = format!(
        "[mybot-agent] 警告: stdout 写入失败（{e}）；后续输出可能丢失，\
         进程继续运行以完成审计收尾\n"
    );
    // SAFETY: 对 fd 2 的单次 write 是 async-signal-safe 级别的原语，无并发问题。
    unsafe {
        libc::write(2, msg.as_ptr().cast(), msg.len());
    }
}

/// 检查式 `println!`：写一行到 `w`，失败告警（stdout 时）并返回 false，绝不 panic。
fn write_line_to<W: Write>(w: &mut W, args: Arguments<'_>, stdout: bool) -> bool {
    match writeln!(w, "{args}") {
        Ok(()) => true,
        Err(e) => {
            if stdout {
                warn_stdout_broken(e);
            }
            false
        }
    }
}

/// 检查式 `print!` + flush：REPL 提示符这类无换行写出必须立刻可见。
fn write_text_to<W: Write>(w: &mut W, args: Arguments<'_>, stdout: bool) -> bool {
    let r = write!(w, "{args}").and_then(|()| w.flush());
    match r {
        Ok(()) => true,
        Err(e) => {
            if stdout {
                warn_stdout_broken(e);
            }
            false
        }
    }
}

/// `println!` 的检查式等价（stdout）。写失败不 panic，见模块头。
pub fn stdout_line(args: Arguments<'_>) {
    let mut out = std::io::stdout().lock();
    write_line_to(&mut out, args, true);
}

/// `print!` + flush 的检查式等价（stdout）。
pub fn stdout_text(args: Arguments<'_>) {
    let mut out = std::io::stdout().lock();
    write_text_to(&mut out, args, true);
}

/// `eprintln!` 的检查式等价（stderr）。失败静默（见模块头的不对称说明）。
pub fn stderr_line(args: Arguments<'_>) {
    let mut err = std::io::stderr().lock();
    write_line_to(&mut err, args, false);
}

/// `eprint!` + flush 的检查式等价（stderr，无换行）——审计的 stderr sink
/// 自带换行，逐字落行用这个。
pub fn stderr_text(s: &str) {
    let mut err = std::io::stderr().lock();
    write_text_to(&mut err, format_args!("{s}"), false);
}

macro_rules! outln {
    ($($arg:tt)*) => { $crate::out::stdout_line(format_args!($($arg)*)) };
}
macro_rules! out {
    ($($arg:tt)*) => { $crate::out::stdout_text(format_args!($($arg)*)) };
}
macro_rules! errln {
    ($($arg:tt)*) => { $crate::out::stderr_line(format_args!($($arg)*)) };
}
pub(crate) use errln;
pub(crate) use out;
pub(crate) use outln;

#[cfg(test)]
mod tests {
    use super::*;

    /// 恒失败 writer（EPIPE / ENOSPC 两个真实 errno 形态）。
    struct Broken(i32);
    impl Write for Broken {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::from_raw_os_error(self.0))
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::from_raw_os_error(self.0))
        }
    }

    /// H2 的判据：管道断裂 / 磁盘满时写出返回 false 而**不 panic**
    /// （`println!` 在同输入下 panic、退出码 101、审计 end 行丢失）。
    #[test]
    fn broken_writer_never_panics() {
        for errno in [libc::EPIPE, libc::ENOSPC] {
            let mut w = Broken(errno);
            assert!(!write_line_to(&mut w, format_args!("hello {errno}"), false));
            assert!(!write_text_to(&mut w, format_args!("again {errno}"), false));
            // 告警一次后继续可用：第二次失败同样安静返回
            assert!(!write_line_to(&mut w, format_args!(""), false));
        }
    }

    /// 成功路径逐字写出（含换行）。
    #[test]
    fn ok_writer_emits_text_verbatim() {
        let mut buf: Vec<u8> = Vec::new();
        assert!(write_line_to(
            &mut buf,
            format_args!("模型输出 {}", 42),
            false
        ));
        assert_eq!(String::from_utf8(buf).unwrap(), "模型输出 42\n");
        let mut buf2: Vec<u8> = Vec::new();
        assert!(write_text_to(&mut buf2, format_args!("提示符> "), false));
        assert_eq!(String::from_utf8(buf2).unwrap(), "提示符> ");
        // 空格式串（outln!("") 的形态）不炸
        let mut buf3: Vec<u8> = Vec::new();
        assert!(write_line_to(&mut buf3, format_args!(""), false));
        assert_eq!(buf3, b"\n");
    }
}

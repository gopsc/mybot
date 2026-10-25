//! SIGINT/SIGTERM 的优雅停止与强杀升级（2026-09-29 B2 拆自 main.rs，语义
//! 逐字保持）。

use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::hook::HookState;
use crate::out::errln;

/// D4：SIGINT/SIGTERM 处理器——首次只置停止标志（钩子在轮循环开头与逐条派发之前
/// 都会看它），让在飞的模型调用与后续派发停下来、会话走正常收尾；
/// **第二次升级为强杀**（还原缺省处置并重新触发信号——与 C++ `onStopSignal` 同款，
/// 连退出码都交给信号本身），因为优雅路径本身也可能被卡住（驱动阻塞在不可中断的
/// 系统调用里等）。
///
/// 在飞请求的处置：`model.rs` 的 `guard`（阻塞面与流式首帧）和 `Observed`（流式余流）
/// 都对停止标志定时轮询，Ctrl-C 之后在途请求**立即被丢弃**、本轮以「请求被中断」
/// 收场——与旧 C++ agent 用取消哨兵掐断 libcurl 请求的效果同款（延迟 ≤ 一个轮询周期）。
pub fn install_signal_handlers(state: Arc<HookState>) {
    tokio::spawn(async move {
        let mut sigint = signal_stream(libc::SIGINT);
        let mut sigterm = signal_stream(libc::SIGTERM);
        loop {
            tokio::select! {
                r = recv(&mut sigint) => if !r { break },
                r = recv(&mut sigterm) => if !r { break },
            }
            if state.stop.swap(true, Ordering::SeqCst) {
                errln!("[mybot-agent] 再次收到停止信号，立即退出（跳过清理）");
                // SAFETY: signal/raise 都是 async-signal-safe 且此处不在信号处理器内；
                // 还原缺省处置后重新触发，让进程按信号语义终止（与 C++ 同款）。
                unsafe {
                    libc::signal(libc::SIGINT, libc::SIG_DFL);
                    libc::signal(libc::SIGTERM, libc::SIG_DFL);
                }
                std::process::exit(130);
            }
            errln!(
                "[mybot-agent] 收到停止信号：不再发起新的模型调用与工具下发，本轮以「执行被中断」收场\
                 （再按一次立即退出）"
            );
        }
    });
}

type SignalStream = Option<tokio::signal::unix::Signal>;

fn signal_stream(sig: libc::c_int) -> SignalStream {
    use tokio::signal::unix::{signal, SignalKind};
    let kind = if sig == libc::SIGINT {
        SignalKind::interrupt()
    } else {
        SignalKind::terminate()
    };
    match signal(kind) {
        Ok(s) => Some(s),
        Err(e) => {
            // 装不上不是致命的：取消仍可由二次信号（默认处置）或 stdin EOF 收场
            errln!("[mybot-agent] 警告: 无法安装信号处理器（{e}）；Ctrl-C 将沿用缺省处置");
            None
        }
    }
}

async fn recv(s: &mut SignalStream) -> bool {
    match s {
        Some(s) => s.recv().await.is_some(),
        // 装不上处理器时这一路永不就绪（另一路仍然有效）
        None => {
            std::future::pending::<()>().await;
            false
        }
    }
}

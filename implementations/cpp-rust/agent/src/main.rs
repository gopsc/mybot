//! mybot-agent —— bot4cj 的 Rust agent（rig 驱动；批次 B 骨架）
//!
//! 对上：直接面对操作者（交互 REPL 或一次性 `--task`）。
//! 对下：mybot 后端的帧通道（AF_UNIX，`mybot --mcp-backend` 建的 socket），
//! 工具全在那一侧执行——本进程不碰硬件、不含 Lua、不链接 C++。
//!
//! 装配顺序（每一步失败都在**做任何事之前**退出，不给「看起来在跑」的假象）：
//!   CLI → 配置（config）→ 提示词包（prompt）→ `--check-config` 提前返回
//!   → 连后端 → `tool.list`（动态工具）→ `context.get`（提示词素材）
//!   → 系统提示词 → 会话落点（session_store，缺省按机器人续接）→ 审计打开 +
//!   start 行 → rig 客户端装配 → 跑 REPL / --task。
//!
//! 退出码（与 C++ agent 模式同口径）：0 正常、1 运行期失败、2 配置/参数错误。
//! stdout 只有模型输出与交互界面；日志、告警、重试一律 stderr。
//!
//! ## 错误习语四轨（27.5 评估留档）
//!
//! 仓内同时存在四种错误表示：`anyhow::Result`、`Result<_, String>`（~73 处）、
//! rig `CompletionError`、`(String, i32)`（`startup.rs:29-50`）。评估后判**不改**：
//!
//! • 统一成单一习语是大 churn（48+ 处改动），语义零收益——四种都能正确传递错误信息，
//!   选择哪种取决于上下文（`anyhow` 适合带堆栈的应用错误、`String` 适合 FFI 边界、
//!   `CompletionError` 是 rig 框架契约、`(String, i32)` 是退出码配对）。
//! • 生产路径已核实无 `unwrap()`/`panic!`/`unreachable!`，仅 `bridge.rs:132`、
//!   `main.rs:274` 两处守卫不变量 `expect()`——这是刻意设计（不变量破裂时必须立即终止，
//!   不是可恢复错误）。
//! • 未来若新增模块，按上下文选习语即可，不必强求统一。

mod audit;
mod bridge;
mod budget;
mod config;
mod frame;
mod fssec;
mod history;
mod hook;
mod httpfetch;
mod ica;
mod linein;
mod model;
mod out;
mod placeholder;
mod prompt;
mod protocol;
mod provider;
mod record;
mod repl;
mod runtime;
mod session;
mod session_runtime;
mod session_store;
mod signals;
mod startup;
mod summary;
#[cfg(test)]
mod testutil;
mod toolspec;

use std::sync::Arc;

use crate::bridge::Bridge;
use crate::budget::TaskBudget;
use crate::config::Config;
use crate::config::SessionPathSource;
use crate::hook::HookState;
use crate::out::{errln, out, outln};
use crate::prompt::PromptMaterial;
use crate::repl::Session;
use crate::session::SessionHead;
use crate::session_store::{SessionMode, SessionPlan};
use crate::signals::install_signal_handlers;

#[tokio::main]
async fn main() {
    harden_against_inspection();
    std::process::exit(run().await);
}

/// 进程自护（2026-09-25）：`prctl(PR_SET_DUMPABLE, 0)`。
///
/// 本进程内存里有模型 API key（`config.rs` 自环境变量或配置文件读入，`provider.rs`
/// 放进请求头）。docs/agent.md 安全一节此前如实写着「同 UID 不构成隔离：进程若能
/// ptrace Rust agent，就能从内存里把密钥捞出来」——non-dumpable 让内核把这条路收窄：
/// 同 UID 非特权进程的 `PTRACE_ATTACH` 与读 `/proc/<pid>/mem`、`environ` 被拒，崩溃
/// 不落 core。边界如实：root / 持 `CAP_SYS_PTRACE` 者不受影响，`/proc/<pid>/cmdline`
/// 依旧全局可读（所以两端都没有命令行传密钥的入口）。
///
/// 放在 tokio 运行时**之前**、`run()` 之前：密钥在 `config::build` 里读入，之后再设
/// 已经晚了。`BOT4CJ_ALLOW_PTRACE=1` 是给 gdb attach / strace -p 的显式逃生口，
/// stderr 明写「已放开」；prctl 失败只告警不退出（操作者必须知道防线缺位，但不该
/// 让 agent 因此起不起来）。与 C++ 宿主 `src/main.cpp` 的 `hardenAgainstInspection`
/// 同口径。
fn harden_against_inspection() {
    if std::env::var("BOT4CJ_ALLOW_PTRACE").is_ok_and(|v| v == "1") {
        errln!(
            "[mybot-agent] 注意: BOT4CJ_ALLOW_PTRACE=1，本进程保持可被同 UID ptrace / core dump\
             （仅调试用；模型密钥可自内存读出）"
        );
        return;
    }
    // SAFETY: prctl(PR_SET_DUMPABLE, 0) 只改本进程的一个内核标志，不碰任何内存；
    // 多余的三个参数按手册要求传 0。
    let rc = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if rc != 0 {
        errln!(
            "[mybot-agent] 警告: prctl(PR_SET_DUMPABLE, 0) 失败（{}）；同 UID 进程可 ptrace 本进程 / 崩溃会落 core",
            std::io::Error::last_os_error()
        );
    }
}

/// 本次会话的落点计划。
///
/// - `Cli` / `Config` 来源：就用 `session_file` 那个路径（批次 D 的行为逐字不变：
///   不给 `--resume` 就是截断新建）。
/// - `Default` 来源：`$MYBOT_HOME/robots/<机器人>/sessions/`，由当前段指针决定
///   新建还是续写（见 [`session_store`]）。
///
/// 返回 `None` = 本次不落盘：只有「缺省来源 + 无家目录」这一种情形
/// （显式路径来源总有落点）。
fn plan_session(cfg: &Config, robot_name: &str) -> Result<Option<SessionPlan>, String> {
    match cfg.session_path_source {
        SessionPathSource::Cli | SessionPathSource::Config => Ok(Some(SessionPlan {
            path: cfg.session_file.clone(),
            mode: if cfg.resume {
                SessionMode::Continue
            } else {
                SessionMode::New
            },
            append: cfg.resume,
            layout: None,
            warning: None,
        })),
        SessionPathSource::Default => {
            if !cfg.state_dir_ok {
                return Ok(None);
            }
            session_store::plan_default_session(
                &cfg.state_dir,
                robot_name,
                cfg.new_session,
                now_sec(),
            )
            .map(Some)
        }
    }
}

/// UTC 秒：段名的时间源。取不到系统时间就退 0——同秒冲突由
/// `session_store::create_segment` 的 O_EXCL + 后缀兜住，不因此中止。
fn now_sec() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 状态目录来源的人话名（与 [`config::summarize`] 同口径）。
fn state_dir_source_name(cfg: &Config) -> &'static str {
    match cfg.state_dir_source {
        "env" => "环境变量 MYBOT_HOME",
        "home" => "家目录",
        _ => "不可用",
    }
}

/// `--resume` 恢复出来的会话三件套（历史消息 / 历史摘要 / 原 session id）。
#[derive(Debug)]
struct Resumed {
    history: Vec<rig_agent::completion::Message>,
    summary: Option<String>,
    session_id: String,
}

/// run() 中段的会话装配产物（[`prepare_session`] 的返回值）：落点计划 + 恢复出来的
/// 会话三件套（未续接则 `resume` 为 `None`）。`plan` 为 `None` = 本次不落盘。
struct SessionPrep {
    plan: Option<SessionPlan>,
    resume: Option<Resumed>,
}

/// 会话恢复的接缝本体（2026-10-01 抽出、2026-10-03 去掉 `try_resume` 薄壳：
/// 现在显式路径与缺省按机器人两条路都直接调它）：只依赖一个会话文件路径，
/// 可离线单测——Bridge 对临时 listener 构造即得，无需真后端/真 LLM。
///
/// 三道判据，放在系统提示词定稿之后、任何审计写之前（早一步还没有 preamble
/// 可比，晚一步就核不出「提示词变没变」）——这条时序契约由调用点（run）持有，
/// 本函数只做判据本身：
///   ① 逐行解析（load_session_file 内部完成，坏行跳过并点名）；
///   ② 指纹核对（结构脚本名 / 工具集指纹 / 系统提示词指纹三者一致）；
///   ③ 协议自洽（tool_call_id 无孤儿/无重复/无漏答——服务端会 400 的序列
///      宁可当场拒绝）。
/// 任一不过即 Err（人话原因）。调用方的分派：显式 `--resume` → 退出 2；
/// 缺省按机器人续接 → 告警一次并新开一段（见 run）。
/// ICA sidecar 恢复也在本函数（会话文件核对通过后才轮到它）。
async fn resume_from(
    session_file: &str,
    bridge: &Bridge,
    tool_names: &[String],
    preamble: &str,
    material: &PromptMaterial,
) -> Result<Resumed, String> {
    let mut loaded = session::LoadedSession::default();
    let mut warnings = Vec::new();
    match session::load_session_file(session_file, &mut loaded, &mut warnings) {
        Ok(()) => {
            for w in &warnings {
                errln!("[mybot-agent] {w}");
            }
            let expected = SessionHead {
                version: session::SESSION_FILE_VERSION,
                session_id: String::new(),
                robot: material.robot_name.clone(),
                tools_fp: session::tools_fingerprint(tool_names),
                system_fp: crate::audit::fingerprint64(preamble),
            };
            if let Some(reason) = session::head_mismatch(&expected, &loaded.head) {
                return Err(format!("会话恢复失败: {reason}"));
            }
            if let Some(reason) = session::protocol_violation(&loaded.messages) {
                return Err(format!(
                    "会话文件 '{}' 的历史不满足工具调用协议自洽（{reason}），\
                     拒绝恢复（这份历史送去模型服务端会被 400）",
                    session_file
                ));
            }
            errln!(
                "[mybot-agent] 已恢复会话：{} 条历史消息{}（来自 {}）",
                loaded.messages.len(),
                loaded
                    .summary
                    .as_ref()
                    .map(|s| format!("，含历史摘要 {} 字节", s.len()))
                    .unwrap_or_default(),
                session_file
            );
        }
        Err(e) => return Err(e),
    }
    bridge
        .ica
        .restore(session_file)
        .map_err(|e| format!("ICA 会话恢复失败: {e}"))?;
    Ok(Resumed {
        history: loaded.messages,
        summary: loaded.summary,
        session_id: loaded.head.session_id,
    })
}

/// 会话落点解析 + 续接（run() 的中段，2026-10-04 拆出；与 [`assemble_backend`]
/// 同款「收敛出口」手法）。原 run() 这一段有 3 个 `return config_error(&e)`，全是
/// 退出码 2 的配置类错误，拆出后统一成 `Err(消息)`，由 run() 一条出口报 2。
///
/// 机器人名（`material.robot_name`）到这里才有，故缺省落点只能此刻拼（见
/// [`plan_session`]）——这也是这一段并不到 `config::build` 里的原因。
///
/// **副作用**：把解析出的落点写回 `cfg.session_file`——下游（repl 里 ICA 账本落盘、
/// `/clear` 分界）都读它，缺省来源下不写回就是空串（账本会静默不落盘），故 cfg 取
/// `&mut`。stderr 的告警行与落点行逐字保持、时序不变（先权限告警，续接失败再告警
/// 一次，最后落点行）。
async fn prepare_session(
    cfg: &mut Config,
    bridge: &Bridge,
    tool_names: &[String],
    preamble: &str,
    material: &PromptMaterial,
) -> Result<SessionPrep, String> {
    // ---- 会话落点：显式路径照旧，缺省走 $MYBOT_HOME/robots/<机器人>/sessions/ ----
    let mut plan = plan_session(cfg, &material.robot_name)?;
    if let Some(p) = plan.as_ref() {
        let w = session::perms_warning(&p.path);
        if !w.is_empty() {
            errln!("[mybot-agent] {w}");
        }
    }

    // ---- 会话续接（判据与时序契约见 resume_from 的注释）----
    // 两条路的分派：显式 `--resume` 失败即 Err（run 报退出码 2）；缺省按机器人续接
    // 失败则告警一次 + 新开一段（提示词/工具集变了、段文件损坏都不该拦住机器人跑起来）。
    let mut resume = None;
    if let Some(p) = plan.as_ref() {
        if p.mode == SessionMode::Continue {
            match resume_from(&p.path, bridge, tool_names, preamble, material).await {
                Ok(r) => resume = Some(r),
                Err(e) if cfg.resume => return Err(e),
                Err(e) => {
                    errln!(
                        "[mybot-agent] 警告: 会话续接失败（{e}），已新开一段，旧段原样保留: {}",
                        p.path
                    );
                    let old = plan.take().expect("上面刚判过 Some");
                    plan = Some(session_store::degrade_to_new_segment(&old, now_sec())?);
                }
            }
        }
    }
    // 下游（repl 里 ICA 账本落盘、`/clear` 分界）都读 `cfg.session_file`——把解析
    // 结果写回去，否则缺省来源下那些地方拿到的是空串（账本会静默不落盘）。
    match plan.as_ref() {
        Some(p) => {
            cfg.session_file = p.path.clone();
            if let Some(w) = p.warning.as_ref() {
                errln!("[mybot-agent] 警告: {w}");
            }
            errln!(
                "[mybot-agent] 会话落点: {}（{}；状态目录来源 {}）",
                p.path,
                if p.mode == SessionMode::Continue {
                    "续接上一次"
                } else {
                    "新建"
                },
                state_dir_source_name(cfg)
            );
        }
        None => errln!(
            "[mybot-agent] 会话持久化未开启（无家目录：MYBOT_HOME 与 HOME 都未设置；\
             可用 MYBOT_HOME 指定状态目录）"
        ),
    }
    Ok(SessionPrep { plan, resume })
}

async fn run() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cli = match config::parse_args(&args) {
        Ok(c) => c,
        Err(e) => return config_error(&e),
    };
    if cli.help {
        out!("{}", config::usage());
        return 0;
    }
    if cli.version {
        outln!("mybot-agent {}", env!("CARGO_PKG_VERSION"));
        return 0;
    }
    let mut cfg = match config::build(&cli) {
        Ok(c) => c,
        Err(e) => return config_error(&e),
    };
    if let Err(e) = startup::load_prompt_pack(&mut cfg, &cli) {
        return config_error(&e);
    }
    if cli.check_config {
        out!("{}", config::summarize(&cfg));
        return 0;
    }
    if !cfg.config_warning.is_empty() {
        errln!("[mybot-agent] {}", cfg.config_warning);
    }
    if !cfg.thinking.is_empty() {
        // 如实告知：不静默丢（C++ 的驱动会把它翻译成各自的思维链开关；rig 没有
        // 对等的 provider 中立开关，本进程不猜形状）。
        errln!(
            "[mybot-agent] 提示: 配置里的 thinking={} 在本进程不生效（rig 无对等开关）；\
             需要思维链请用网关/模型侧的缺省设置",
            cfg.thinking
        );
    }

    // ---- 循环层共享状态 + 取消信号 ----
    // 先装信号处理器（连接后端可能要等上电，Ctrl-C 在这一段也该有效）
    let state = Arc::new(HookState::new(
        cfg.max_task_seconds,
        cfg.max_calls_per_round,
        TaskBudget::new(
            cfg.max_task_tool_result_bytes as usize,
            cfg.max_task_image_bytes as usize,
            cfg.max_task_seconds,
        ),
    ));
    install_signal_handlers(Arc::clone(&state));

    // ---- 后端：连接 → 读超时装配 → 首帧认证（可选） → 工具表 → 提示词素材 ----
    let assembly = match startup::assemble_backend(&cfg, &state).await {
        Ok(a) => a,
        Err((msg, code)) => {
            errln!("错误: {msg}");
            return code;
        }
    };
    let startup::BackendAssembly {
        bridge,
        specs,
        tool_names,
        material,
        preamble,
    } = assembly;

    // ---- 会话落点 + 续接（拆解见 prepare_session；错误统一走退出码 2）----
    let prep = match prepare_session(&mut cfg, &bridge, &tool_names, &preamble, &material).await {
        Ok(p) => p,
        Err(e) => return config_error(&e),
    };
    let SessionPrep { plan, resume } = prep;
    let (resume_history, resume_summary, resume_session_id, resumed) = match resume {
        Some(r) => (r.history, r.summary, r.session_id, true),
        None => (Vec::new(), None, String::new(), false),
    };

    let audit = match runtime::open_audit(&cfg.audit_log, &resume_session_id) {
        Ok(a) => a,
        Err(e) => {
            errln!("错误: {e}");
            return 2;
        }
    };

    let session_writer = match runtime::open_session_writer(
        plan.as_ref(),
        audit.as_ref(),
        &material,
        &tool_names,
        &preamble,
    ) {
        Ok(w) => w,
        Err(e) => {
            errln!("错误: {e}");
            return 2;
        }
    };

    // ---- 录制模式（--record / --record-dir）：完整上下文采集（含图片本体），
    //      微调数据用 scripts/record_export.py 导出。此刻机器人名/会话落点/审计
    //      session id 都已就位，是装配链上最早能开的点。----
    let resume_len = resume_history.len();
    let mut recorder = match record::open_from_config(
        &cfg,
        &material,
        &tool_names,
        &specs,
        &preamble,
        audit.as_ref().map(|a| a.session_id()).unwrap_or(""),
        resumed,
        now_sec(),
    ) {
        Ok(r) => r,
        Err(e) => return config_error(&e),
    };
    if resumed {
        // 续接：恢复进来的前缀不重复落事件（由会话文件承载，meta 记了路径）
        if let Some(r) = recorder.as_mut() {
            r.note_resumed(resume_len, &cfg.session_file);
        }
    }
    if let Some(r) = recorder.as_ref() {
        errln!(
            "[mybot-agent] 录制落点: {}（含完整上下文与图片；训练集导出: scripts/record_export.py）",
            r.dir()
        );
    }

    let session_parts =
        match session_runtime::build_session_parts(session_runtime::SessionRuntimeInput {
            cfg,
            specs,
            bridge,
            state,
            preamble,
            tool_names,
            material,
            audit,
            writer: session_writer,
            record: recorder,
            history: resume_history,
            summary: resume_summary,
            resumed,
        }) {
            Ok(parts) => parts,
            Err(e) => {
                errln!("错误: {e:#}");
                return 2;
            }
        };
    let backend = &session_parts.assembly.backend;
    errln!(
        "[mybot-agent] 驱动 {} / 模型 {} / 接入点 {} / 工具 {} 个 / 后端 {}",
        backend.driver.as_str(),
        session_parts.assembly.cfg.model,
        backend.effective_url,
        session_parts.assembly.tool_names.len(),
        session_parts.assembly.cfg.socket
    );

    let task = cli.task.clone();
    let mut session = Session::new(session_parts.assembly);
    session_runtime::run_session(&mut session, &task).await
}

/// 参数/配置错误的统一出口：stderr 报告 + 退出码 2（与 C++ agent 模式同口径）。
fn config_error(msg: &str) -> i32 {
    errln!("错误: {msg}");
    2
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::budget::TaskBudget;
    use crate::frame::BackendClient;
    use crate::hook::HookState;
    use crate::prompt::PromptMaterial;
    use crate::session::{self, SessionHead};
    use std::os::unix::net::UnixListener as StdListener;
    use std::time::Duration;

    /// 与 bridge.rs 测试同款的离线构造：临时 listener + 立即接受的 BackendClient。
    /// try_resume 路径不发起任何帧调用（ICA 未启用时零行为），连接只需存在。
    async fn offline_bridge(tag: &str) -> Bridge {
        let dir = std::env::temp_dir().join(format!("mybot_resume_{}_{}", tag, std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("b.sock");
        let listener = StdListener::bind(&path).unwrap();
        let client =
            BackendClient::connect_timeout(&path.to_string_lossy(), Duration::from_secs(5))
                .await
                .unwrap();
        let _accepted = listener.accept().unwrap(); // 保持对端存活
        std::mem::forget(listener); // 对端保持存活即可,监听器不必关闭
        Bridge::new(
            client,
            crate::bridge::ConnParams {
                path: String::new(),
                token: None,
                connect_timeout: Duration::from_secs(1),
                read_timeout: Duration::from_secs(1),
            },
            std::sync::Arc::new(HookState::new(60, 0, TaskBudget::new(0, 0, 0))),
        )
    }

    fn material() -> PromptMaterial {
        PromptMaterial {
            robot_name: "relay-test".into(),
            ..Default::default()
        }
    }

    fn write_session(path: &std::path::Path, head: &SessionHead) {
        use std::io::Write;
        let mut w = session::SessionFileWriter::new();
        w.open(path.to_string_lossy().as_ref(), false).unwrap();
        w.write_header(head);
        let _ = std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .unwrap()
            .write(b"");
    }

    #[tokio::test]
    async fn resume_rejects_missing_and_mismatched_sessions() {
        let bridge = offline_bridge("missing").await;
        let dir = std::env::temp_dir().join(format!("mybot_resume_files_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // 文件不存在：错误如实冒出（fail-closed，不静默当新会话）
        let missing = dir.join("none.jsonl");
        let err = resume_from(
            missing.to_string_lossy().as_ref(),
            &bridge,
            &[],
            "p",
            &material(),
        )
        .await
        .unwrap_err();
        assert!(
            err.contains(&missing.to_string_lossy().to_string()),
            "{err}"
        );

        // 头不符（robot 名对不上）：点名「会话恢复失败」
        let session = dir.join("s.jsonl");
        write_session(
            &session,
            &SessionHead {
                version: session::SESSION_FILE_VERSION,
                session_id: String::new(),
                robot: "another-robot".into(),
                tools_fp: String::new(),
                system_fp: String::new(),
            },
        );
        let err = resume_from(
            session.to_string_lossy().as_ref(),
            &bridge,
            &[],
            "p",
            &material(),
        )
        .await
        .unwrap_err();
        assert!(err.contains("会话恢复失败"), "{err}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}

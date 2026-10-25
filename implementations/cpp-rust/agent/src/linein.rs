//! linein.rs —— REPL 行输入：终端上走 rustyline（行编辑 / 历史 / 命令补全），
//! 非终端（管道、重定向）保持裸逐行读取。
//!
//! 为什么分两条路而不是一律 rustyline：管道面是 E2E 与脚本化调用的既定契约
//! （提示符原样写 stdout、一行一任务、EOF 即退出），rustyline 的非 TTY 回退虽然
//! 语义相近，但那是别人的实现细节，不该让它决定本进程对管道的行为。终端面
//! 才是它的用武之地：方向键、Ctrl-A/E/W、↑↓ 历史、`/命令` Tab 补全。
//!
//! 历史文件（仅终端面）：`BOT4CJ_AGENT_HISTORY` 指定路径，`none` 关闭；未设则
//! `$XDG_STATE_HOME/mybot-agent/history`，再退到 `$HOME/.local/state/mybot-agent/history`。
//! 任务文本可能含现场信息（地址、口令、路径），目录 0700、文件 0600 建立；已存在
//! 的文件若对同组/其他用户可读就告警（与密钥文件同口径），不擅自改权限。
//!
//! Ctrl-C 在提示符处：rustyline 进 raw 模式后终端不再发 SIGINT，本层收到
//! `Interrupted`——按 shell 惯例**清掉当前行**继续，不退出（退出是 /exit 或 Ctrl-D）。
//! 模型轮进行中终端已还原，SIGINT 照常走 main.rs 的处理器，两条路互不干扰。

use std::path::PathBuf;

use rustyline::completion::{Completer, Pair};
use rustyline::error::ReadlineError;
use rustyline::highlight::Highlighter;
use rustyline::hint::Hinter;
use rustyline::history::DefaultHistory;
use rustyline::validate::Validator;
use rustyline::{CompletionType, Config, Context, Editor, Helper};
use tokio::io::AsyncBufReadExt;

use crate::out::{errln, out};

/// REPL 内置命令（补全用；帮助文本在 repl.rs）。
const SLASH_COMMANDS: &[&str] = &[
    "/hardware",
    "/scripts",
    "/sql",
    "/status",
    "/clear",
    "/help",
    "/exit",
    "/quit",
];

/// 历史条数上限：够翻一个工作日的任务，又不至于让文件无界增长。
const MAX_HISTORY_ENTRIES: usize = 1000;

pub enum LineRead {
    Line(String),
    /// 提示符处 Ctrl-C：当前行已丢弃，调用方继续下一轮。
    Interrupted,
    Eof,
    Error(String),
}

/// 只补 `/命令`（行首斜杠、尚未出现空白）；任务文本不补——那是自然语言，没有候选集。
struct SlashCompleter;

impl Completer for SlashCompleter {
    type Candidate = Pair;

    fn complete(
        &self,
        line: &str,
        pos: usize,
        _ctx: &Context<'_>,
    ) -> rustyline::Result<(usize, Vec<Pair>)> {
        let head = &line[..pos];
        if !head.starts_with('/') || head.contains(char::is_whitespace) {
            return Ok((pos, Vec::new()));
        }
        let cands = SLASH_COMMANDS
            .iter()
            .filter(|c| c.starts_with(head))
            .map(|c| Pair {
                display: (*c).to_string(),
                replacement: format!("{c} "),
            })
            .collect();
        Ok((0, cands))
    }
}

impl Hinter for SlashCompleter {
    type Hint = String;
}
impl Highlighter for SlashCompleter {}
impl Validator for SlashCompleter {}
impl Helper for SlashCompleter {}

type TermEditor = Editor<SlashCompleter, DefaultHistory>;

enum Mode {
    /// 终端面：Editor 在 `read_line` 期间被移进阻塞线程，故用 Option 占位。
    Term {
        editor: Option<TermEditor>,
        history_path: Option<PathBuf>,
    },
    Plain(tokio::io::Lines<tokio::io::BufReader<tokio::io::Stdin>>),
}

pub struct LineInput {
    mode: Mode,
}

impl LineInput {
    /// stdin 与 stdout 都是终端才启用行编辑；任一不是就走裸逐行（提示符仍由调用方
    /// 写 stdout，与此前行为逐字节一致）。rustyline 初始化失败同样退回裸读并告警——
    /// 行编辑是舒适性，不是 REPL 能否工作的前提。
    pub fn new() -> Self {
        use std::io::IsTerminal;
        if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
            return Self::plain();
        }
        let cfg = Config::builder()
            .auto_add_history(false)
            .history_ignore_space(true)
            .completion_type(CompletionType::List)
            .history_ignore_dups(true)
            .and_then(|b| b.max_history_size(MAX_HISTORY_ENTRIES))
            .map(|b| b.build())
            .and_then(Editor::with_config);
        let mut editor: TermEditor = match cfg {
            Ok(e) => e,
            Err(e) => {
                errln!("[mybot-agent] 警告: 行编辑初始化失败（{e}）；退回裸行输入");
                return Self::plain();
            }
        };
        editor.set_helper(Some(SlashCompleter));
        let history_path = resolve_history_path();
        if let Some(p) = &history_path {
            match editor.load_history(p) {
                Ok(()) => {}
                Err(ReadlineError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => errln!(
                    "[mybot-agent] 警告: 读取 REPL 历史失败（{}）: {e}；本会话不带旧历史",
                    p.display()
                ),
            }
        }
        Self {
            mode: Mode::Term {
                editor: Some(editor),
                history_path,
            },
        }
    }

    fn plain() -> Self {
        Self {
            mode: Mode::Plain(tokio::io::BufReader::new(tokio::io::stdin()).lines()),
        }
    }

    /// 终端面写提示符由 rustyline 负责；裸面由本函数写（`out!` 检查式，立即 flush）。
    pub async fn read_line(&mut self, prompt: String) -> LineRead {
        match &mut self.mode {
            Mode::Plain(lines) => {
                out!("{prompt}");
                match lines.next_line().await {
                    Ok(Some(l)) => LineRead::Line(l),
                    Ok(None) => LineRead::Eof,
                    Err(e) => LineRead::Error(e.to_string()),
                }
            }
            Mode::Term { editor, .. } => {
                let Some(mut ed) = editor.take() else {
                    return LineRead::Error("行编辑器状态丢失".to_string());
                };
                let joined = tokio::task::spawn_blocking(move || {
                    let r = ed.readline(&prompt);
                    (ed, r)
                })
                .await;
                match joined {
                    Ok((ed, r)) => {
                        *editor = Some(ed);
                        match r {
                            Ok(l) => LineRead::Line(l),
                            Err(ReadlineError::Interrupted) => LineRead::Interrupted,
                            Err(ReadlineError::Eof) => LineRead::Eof,
                            Err(e) => LineRead::Error(e.to_string()),
                        }
                    }
                    Err(e) => LineRead::Error(format!("行输入线程异常结束: {e}")),
                }
            }
        }
    }

    /// 记入会话历史（终端面；裸面无操作）。空行与 `/exit` 一类不由调用方传入。
    pub fn remember(&mut self, line: &str) {
        if let Mode::Term {
            editor: Some(ed), ..
        } = &mut self.mode
        {
            let _ = ed.add_history_entry(line);
        }
    }

    /// 落盘历史（REPL 退出时一次）。失败只告警：历史丢了不影响这次会话的结果。
    pub fn save_history(&mut self) {
        let Mode::Term {
            editor: Some(ed),
            history_path: Some(p),
        } = &mut self.mode
        else {
            return;
        };
        if let Err(e) = prepare_history_file(p) {
            errln!(
                "[mybot-agent] 警告: 无法建立 REPL 历史文件（{}）: {e}；本会话历史未保存",
                p.display()
            );
            return;
        }
        if let Err(e) = ed.save_history(p) {
            errln!(
                "[mybot-agent] 警告: 保存 REPL 历史失败（{}）: {e}",
                p.display()
            );
        }
    }
}

/// `BOT4CJ_AGENT_HISTORY`：`none` 关闭、非空为路径；未设按 XDG 退到 `$HOME`；
/// 两者皆无则关闭并告知（不静默）。
fn resolve_history_path() -> Option<PathBuf> {
    if let Ok(v) = std::env::var("BOT4CJ_AGENT_HISTORY") {
        let v = v.trim();
        if v.is_empty() || v == "none" {
            return None;
        }
        return Some(PathBuf::from(v));
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|s| !s.is_empty())
                .map(|h| PathBuf::from(h).join(".local").join("state"))
        });
    match base {
        Some(b) => Some(b.join("mybot-agent").join("history")),
        None => {
            errln!("[mybot-agent] 注意: 未设 XDG_STATE_HOME / HOME，REPL 历史仅保留在本会话内");
            None
        }
    }
}

/// 目录 0700、文件 0600 建立；已存在且对同组/其他用户可读时告警（不改权限——
/// 那是操作者的文件，改了要说；这里只说）。
fn prepare_history_file(p: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    if let Some(dir) = p.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)?;
        }
    }
    match std::fs::metadata(p) {
        Ok(meta) => {
            if meta.permissions().mode() & 0o077 != 0 {
                errln!(
                    "[mybot-agent] 提醒: REPL 历史文件 {} 对同组/其他用户可读（建议 chmod 600）",
                    p.display()
                );
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(p)?;
        }
        Err(e) => return Err(e),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn complete(line: &str) -> (usize, Vec<String>) {
        let h = DefaultHistory::new();
        let ctx = Context::new(&h);
        let (start, cands) = SlashCompleter
            .complete(line, line.len(), &ctx)
            .expect("complete");
        (start, cands.into_iter().map(|p| p.replacement).collect())
    }

    #[test]
    fn slash_completion_prefix_only() {
        let (start, c) = complete("/s");
        assert_eq!(start, 0);
        assert_eq!(c, vec!["/scripts ", "/sql ", "/status "]);
        let (_, c) = complete("/ex");
        assert_eq!(c, vec!["/exit "]);
        let (_, c) = complete("/");
        assert_eq!(c.len(), SLASH_COMMANDS.len());
    }

    #[test]
    fn no_completion_for_tasks_or_after_space() {
        assert!(complete("让机器人站立").1.is_empty());
        assert!(complete("/sql SELECT").1.is_empty());
        assert!(complete("").1.is_empty());
    }

    #[test]
    fn history_file_created_0600_and_dir_0700() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("mybot-linein-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p = dir.join("sub").join("history");
        prepare_history_file(&p).expect("prepare");
        let fmode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        let dmode = std::fs::metadata(p.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(fmode, 0o600);
        assert_eq!(dmode, 0o700);
        // 第二次：已存在，不报错、不改权限
        prepare_history_file(&p).expect("prepare again");
        assert_eq!(
            std::fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn history_path_env_override_and_none() {
        // 进程内环境变量：单测串行访问同一变量，用互斥避免并发用例互踩
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap();
        std::env::set_var("BOT4CJ_AGENT_HISTORY", "none");
        assert!(resolve_history_path().is_none());
        std::env::set_var("BOT4CJ_AGENT_HISTORY", "/tmp/x/hist");
        assert_eq!(resolve_history_path(), Some(PathBuf::from("/tmp/x/hist")));
        std::env::remove_var("BOT4CJ_AGENT_HISTORY");
        std::env::set_var("XDG_STATE_HOME", "/tmp/xdg");
        assert_eq!(
            resolve_history_path(),
            Some(PathBuf::from("/tmp/xdg/mybot-agent/history"))
        );
        std::env::remove_var("XDG_STATE_HOME");
    }
}

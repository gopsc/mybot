//! Agent 会话运行时装配：provider 与 SessionAssembly。

use std::sync::Arc;

use crate::bridge::Bridge;
use crate::config::Config;
use crate::hook::HookState;
use crate::out::errln;
use crate::prompt::PromptMaterial;
use crate::provider;
use crate::repl::{self, ResumeContext, Session, SessionAssembly};
use crate::session::SessionFileWriter;
use crate::toolspec::ToolSpec;

pub struct SessionParts {
    pub assembly: SessionAssembly,
}

pub async fn run_session(session: &mut Session, task: &str) -> i32 {
    if task.is_empty() {
        let rc = repl::run_repl(session).await;
        session.write_session_end("end", "");
        rc
    } else {
        match repl::run_task_once(session, task).await {
            Ok(()) => {
                session.write_session_end("end", "");
                0
            }
            Err(e) => {
                errln!("错误: {e}");
                session.write_session_end("error", &e);
                1
            }
        }
    }
}

pub struct SessionRuntimeInput {
    pub cfg: Config,
    pub specs: Vec<ToolSpec>,
    pub bridge: Arc<Bridge>,
    pub state: Arc<HookState>,
    pub preamble: String,
    pub tool_names: Vec<String>,
    pub material: PromptMaterial,
    pub audit: Option<crate::audit::AuditLog>,
    pub writer: Option<SessionFileWriter>,
    /// 录制模式（`--record` / `--record-dir`；`None` = 未开启）
    pub record: Option<crate::record::RecordStore>,
    pub history: Vec<rig_agent::completion::Message>,
    pub summary: Option<String>,
    pub resumed: bool,
}

pub fn build_session_parts(input: SessionRuntimeInput) -> Result<SessionParts, anyhow::Error> {
    let backend = provider::build(
        &input.cfg,
        input.specs,
        &input.bridge,
        Arc::clone(&input.state),
        &input.preamble,
    )?;
    let assembly = SessionAssembly {
        cfg: input.cfg,
        backend,
        bridge: input.bridge,
        state: input.state,
        tool_names: input.tool_names,
        material: input.material,
        audit: input.audit,
        writer: input.writer,
        record: input.record,
        resume: ResumeContext {
            history: input.history,
            summary: input.summary,
            resumed: input.resumed,
        },
    };
    Ok(SessionParts { assembly })
}

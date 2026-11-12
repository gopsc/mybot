//! Agent 运行时装配：审计日志与会话文件写入器。

use crate::audit::AuditLog;
use crate::session::{self, SessionFileWriter, SessionHead};
use crate::session_store::{SessionMode, SessionPlan};

pub fn open_audit(path: &str, resumed_session_id: &str) -> Result<Option<AuditLog>, String> {
    if path.is_empty() {
        return Ok(None);
    }
    let mut audit = AuditLog::open(path).map_err(|e| e.to_string())?;
    audit.adopt_session_id(resumed_session_id);
    Ok(Some(audit))
}

pub fn open_session_writer(
    plan: Option<&SessionPlan>,
    audit: Option<&AuditLog>,
    material: &crate::prompt::PromptMaterial,
    tool_names: &[String],
    preamble: &str,
) -> Result<Option<SessionFileWriter>, String> {
    let Some(plan) = plan else {
        return Ok(None);
    };

    let mut writer = SessionFileWriter::new();
    writer.open(&plan.path, plan.append)?;
    if plan.mode == SessionMode::New {
        let session_id = audit
            .map(|a| a.session_id().to_string())
            .unwrap_or_default();
        writer.write_header(&SessionHead {
            version: session::SESSION_FILE_VERSION,
            session_id,
            robot: material.robot_name.clone(),
            tools_fp: session::tools_fingerprint(tool_names),
            system_fp: crate::audit::fingerprint64(preamble),
        });
    }
    Ok(Some(writer))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::PromptMaterial;
    use crate::session::load_session_file;
    use crate::session::LoadedSession;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        crate::testutil::tmpdir("mybot_runtime", tag)
    }

    fn test_material() -> PromptMaterial {
        PromptMaterial {
            robot_name: "test_robot".to_string(),
            structure_path: "/tmp/struct.sql".to_string(),
            scripts_dir: "/tmp/scripts".to_string(),
            allow_shell: false,
            allow_hot_sql: false,
            structure_excerpt: "excerpt".to_string(),
            hardware_list: "hw".to_string(),
            scripts_list: "scripts".to_string(),
            readable_vars: String::new(),
        }
    }

    #[test]
    fn open_session_writer_returns_none_when_plan_is_none() {
        let material = test_material();
        let result = open_session_writer(None, None, &material, &[], "preamble").unwrap();
        assert!(result.is_none(), "plan 为 None 时应返回 None");
    }

    #[test]
    fn open_session_writer_writes_header_in_new_mode() {
        let dir = tmpdir("new_mode");
        let path = dir.join("session.jsonl");
        let path_str = path.to_string_lossy().to_string();

        let plan = SessionPlan {
            path: path_str.clone(),
            mode: SessionMode::New,
            append: false,
            layout: None,
            warning: None,
        };

        let audit_dir = dir.join("audit.jsonl");
        let mut audit = AuditLog::open(&audit_dir.to_string_lossy()).unwrap();
        audit.adopt_session_id("test_session_123");

        let material = test_material();
        let tools = vec!["tool_a".to_string(), "tool_b".to_string()];
        let preamble = "test preamble";

        let writer = open_session_writer(Some(&plan), Some(&audit), &material, &tools, preamble)
            .unwrap()
            .expect("应返回 Some(writer)");
        drop(writer);

        let mut loaded = LoadedSession::default();
        let mut warns = Vec::new();
        load_session_file(&path_str, &mut loaded, &mut warns).unwrap();
        assert!(warns.is_empty(), "载入应有零告警: {warns:?}");

        assert_eq!(loaded.head.version, session::SESSION_FILE_VERSION);
        assert_eq!(loaded.head.session_id, "test_session_123");
        assert_eq!(loaded.head.robot, "test_robot");
        assert_eq!(
            loaded.head.tools_fp,
            session::tools_fingerprint(&tools),
            "工具集指纹应按注册序计算"
        );
        assert_eq!(
            loaded.head.system_fp,
            crate::audit::fingerprint64(preamble),
            "系统提示词指纹应与 preamble 对应"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_session_writer_skips_header_in_continue_mode() {
        let dir = tmpdir("continue_mode");
        let path = dir.join("session.jsonl");
        let path_str = path.to_string_lossy().to_string();

        std::fs::write(&path, "existing content\n").unwrap();

        let plan = SessionPlan {
            path: path_str.clone(),
            mode: SessionMode::Continue,
            append: true,
            layout: None,
            warning: None,
        };

        let material = test_material();
        let writer = open_session_writer(Some(&plan), None, &material, &[], "preamble")
            .unwrap()
            .expect("应返回 Some(writer)");
        drop(writer);

        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            content, "existing content\n",
            "Continue 模式不应写会话头，只追加"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_session_writer_uses_empty_session_id_when_audit_is_none() {
        let dir = tmpdir("no_audit");
        let path = dir.join("session.jsonl");
        let path_str = path.to_string_lossy().to_string();

        let plan = SessionPlan {
            path: path_str.clone(),
            mode: SessionMode::New,
            append: false,
            layout: None,
            warning: None,
        };

        let material = test_material();
        let writer = open_session_writer(Some(&plan), None, &material, &[], "preamble")
            .unwrap()
            .expect("应返回 Some(writer)");
        drop(writer);

        let mut loaded = LoadedSession::default();
        let mut warns = Vec::new();
        load_session_file(&path_str, &mut loaded, &mut warns).unwrap();
        assert_eq!(
            loaded.head.session_id, "",
            "audit 为 None 时 session_id 应为空"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}

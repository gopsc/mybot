//! config/file.rs —— 配置文件层：白名单 + 类型/区间解析 + 密钥文件读取
//! （2026-09-29 B3 拆自 config.rs；语义与报错文案逐字保持）。
//!
//! 字段登记的单一事实源是 [`parsed_fields`] 宏表：字段名清单与 want_* 解析
//! 序列都从它展开。原先新增一个字段要同步改四处（KNOWN_FIELDS / FileConfig /
//! want_* 序列 / build 默认值），现在收敛为「一张表 + 两处结构体声明」——
//! FileConfig 与 Config 的字面量初始化由编译器强制补齐，漏改即编译失败。

use std::fs;

use serde_json::Value;

use super::limits;

/// 配置文件读取上限（与 C++ `kMaxConfigBytes` 逐值对齐）。
pub const K_MAX_CONFIG_BYTES: u64 = 64 << 10;
/// 密钥文件读取上限（与 C++ `kMaxKeyFileBytes` 逐值对齐）。
pub const K_MAX_KEY_FILE_BYTES: u64 = 64 << 10;

/// Rust 侧解析字段的单一登记点（B3）：每行
/// `(FileConfig 字段, JSON 名, 解析方式)`，经 [`emit_names`] 展开成字段名
/// 清单 [`PARSED_FIELD_NAMES`]（与 [`KNOWN_UNPARSED_FIELDS`] 拼成完整白名单）
/// ——原先「新增字段忘了登记 KNOWN_FIELDS」这个唯一不被编译器强制的同步点
/// 就此消除。want_* 解析序列保持手写（macro_rules 的卫生规则无法把表内
/// 字段名可靠地接到调用点的结构体字段上），表 ↔ 序列的一致性由测试
/// `parsed_field_table_matches_want_sequence` 钉住；行内次序 = 解析次序 =
/// 多字段非法时的报错优先级（既有契约，勿重排）。
/// thinking 三态与 temperature/top_p 的开闭区间是特殊判据，留在
/// load_config_file 的手工段。
macro_rules! parsed_fields {
    ($apply:ident) => {
        $apply! {
            (driver, "driver", str),
            (var, "var", str),
            (endpoint, "endpoint", str),
            (model, "model", str),
            (api_key, "api_key", str),
            (api_key_file, "api_key_file", str),
            (timeout_sec, "timeout", int, limits::TIMEOUT_MIN_SEC, limits::TIMEOUT_MAX_SEC),
            (max_tokens, "max_tokens", int, limits::MAX_TOKENS_MIN, limits::MAX_TOKENS_MAX),
            (max_turns, "max_turns", int, limits::MAX_TURNS_MIN, limits::MAX_TURNS_MAX),
            (max_task_seconds, "max_task_seconds", int, limits::TASK_TIMEOUT_MIN_SEC, limits::TASK_TIMEOUT_MAX_SEC),
            (max_history_bytes, "max_history_bytes", int, 0, limits::BUDGET_BYTES_MAX),
            (max_task_tool_result_bytes, "max_task_tool_result_bytes", int, 0, limits::BUDGET_BYTES_MAX),
            (max_task_image_bytes, "max_task_image_bytes", int, 0, limits::BUDGET_BYTES_MAX),
            (max_calls_per_round, "max_calls_per_round", int, limits::MAX_CALLS_PER_ROUND_MIN, limits::MAX_CALLS_PER_ROUND_MAX),
            (max_retries, "max_retries", int, limits::MAX_RETRIES_MIN, limits::MAX_RETRIES_MAX),
            (retry_backoff_ms, "retry_backoff_ms", int, limits::RETRY_BACKOFF_MS_MIN, limits::RETRY_BACKOFF_MS_MAX),
            (temperature, "temperature", num),
            (top_p, "top_p", num),
            (reasoning_effort, "reasoning_effort", str),
            (prompt_files, "prompt_files", str_array),
            (audit_log, "audit_log", str),
            (session_file, "session_file", str),
            (stream, "stream", bool),
            (history_summary, "history_summary", bool),
            (max_summary_bytes, "max_summary_bytes", int, limits::SUMMARY_BYTES_MIN, limits::SUMMARY_BYTES_MAX),
        }
    };
}

/// 单行展开器：字段名。
macro_rules! name_row {
    (($field:ident, $json:literal $(, $rest:expr)*)) => {
        $json
    };
}

macro_rules! emit_names {
    ( $( $row:tt ),* $(,)? ) => {
        &[ $( name_row!($row) ),* ]
    };
}

/// 单行展开器：(字段名, 对该种类必然错的 JSON 值)——一致性测试用。
#[cfg(test)]
macro_rules! bad_row {
    (($field:ident, $json:literal, str $(, $rest:expr)*)) => {
        ($json, "[1]")
    };
    (($field:ident, $json:literal, int $(, $rest:expr)*)) => {
        ($json, "\"x\"")
    };
    (($field:ident, $json:literal, num $(, $rest:expr)*)) => {
        ($json, "\"x\"")
    };
    (($field:ident, $json:literal, bool $(, $rest:expr)*)) => {
        ($json, "\"x\"")
    };
    (($field:ident, $json:literal, str_array $(, $rest:expr)*)) => {
        ($json, "1")
    };
}

#[cfg(test)]
macro_rules! emit_bad {
    ( $( $row:tt ),* $(,)? ) => {
        &[ $( bad_row!($row) ),* ]
    };
}

/// Rust 解析的字段名（由宏表展开；与 C++ `loadConfigRoot` 的 kKnown 子集）。
const PARSED_FIELD_NAMES: &[&str] = parsed_fields!(emit_names);

/// 只登记、不在本进程解析的已知字段：C++ 后端专属（能力/摄像头/超时，见
/// config 模块头注的「能力类字段」说明）+ thinking（三态判据在
/// load_config_file 手工段解析，名字仍须白名单放行）。
const KNOWN_UNPARSED_FIELDS: &[&str] = &[
    "thinking",
    "scripts_dir",
    "allow_shell",
    "allow_hot_sql",
    "camera_var",
    "camera_device",
    "camera_src",
    "camera_src_dir",
    "allow_camera",
    "agent_policy",
    "read_vars",
    "fs_root",
    "allow_write_file",
    "run_command_timeout_sec",
    "run_command_max_timeout_sec",
    "action_script_timeout_sec",
];

/// 配置文件里本进程真正消费的字段（其余已知字段只登记不解析，见模块头注）。
#[derive(Debug, Default)]
pub(super) struct FileConfig {
    pub(super) driver: Option<String>,
    pub(super) var: Option<String>,
    pub(super) endpoint: Option<String>,
    pub(super) model: Option<String>,
    pub(super) api_key: Option<String>,
    pub(super) api_key_file: Option<String>,
    pub(super) timeout_sec: Option<i64>,
    pub(super) max_tokens: Option<i64>,
    pub(super) max_turns: Option<i64>,
    pub(super) max_task_seconds: Option<i64>,
    pub(super) max_history_bytes: Option<i64>,
    pub(super) max_task_tool_result_bytes: Option<i64>,
    pub(super) max_task_image_bytes: Option<i64>,
    pub(super) max_calls_per_round: Option<i64>,
    pub(super) max_retries: Option<i64>,
    pub(super) retry_backoff_ms: Option<i64>,
    pub(super) temperature: Option<f64>,
    pub(super) top_p: Option<f64>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) thinking: Option<String>,
    pub(super) stream: Option<bool>,
    pub(super) history_summary: Option<bool>,
    pub(super) max_summary_bytes: Option<i64>,
    pub(super) prompt_files: Option<Vec<String>>,
    pub(super) audit_log: Option<String>,
    /// 只用于写入（见 `Config::session_file_from_cli` 的判据）。
    pub(super) session_file: Option<String>,
}

fn type_error(path: &str, key: &str, want: &str) -> String {
    format!("配置文件 {path} 的字段 '{key}' 需要{want}")
}

fn range_error(path: &str, key: &str, lo: f64, hi: f64, got: &str) -> String {
    format!("配置文件 {path} 的字段 '{key}' 需要在 [{lo}, {hi}] 范围内，实际是 {got}")
}

/// 字符串字段（空串按「未配置」处理，与 C++ `wantString` 同口径）。
fn want_string(root: &Value, path: &str, key: &str) -> Result<Option<String>, String> {
    match root.get(key) {
        None => Ok(None),
        Some(Value::String(s)) => Ok((!s.is_empty()).then(|| s.clone())),
        Some(_) => Err(type_error(path, key, "字符串")),
    }
}

/// 整数字段：区间 + 取整（非整数拒），与 C++ `wantInt` 同判据。
fn want_int(root: &Value, path: &str, key: &str, lo: i64, hi: i64) -> Result<Option<i64>, String> {
    let v = match root.get(key) {
        None => return Ok(None),
        Some(v) => v,
    };
    let n = match v {
        Value::Number(n) => n,
        _ => return Err(type_error(path, key, "数字")),
    };
    let f = n.as_f64().ok_or_else(|| type_error(path, key, "数字"))?;
    if !f.is_finite() || f < lo as f64 || f > hi as f64 {
        return Err(range_error(path, key, lo as f64, hi as f64, &f.to_string()));
    }
    if f.fract() != 0.0 {
        return Err(type_error(path, key, "整数"));
    }
    Ok(Some(f as i64))
}

/// 布尔字段（只认 JSON 布尔；"yes"/1 之类一律拒）。
fn want_bool(root: &Value, path: &str, key: &str) -> Result<Option<bool>, String> {
    match root.get(key) {
        None => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(type_error(path, key, "布尔值")),
    }
}

/// 浮点字段（区间判在调用方，因为 temperature/top_p 的开闭区间不同）。
fn want_number(root: &Value, path: &str, key: &str) -> Result<Option<f64>, String> {
    let v = match root.get(key) {
        None => return Ok(None),
        Some(v) => v,
    };
    match v {
        Value::Number(n) => n
            .as_f64()
            .ok_or_else(|| type_error(path, key, "数字"))
            .map(Some),
        _ => Err(type_error(path, key, "数字")),
    }
}

/// 字符串数组字段（空数组按「未配置」；元素非字符串拒绝）。
fn want_string_array(root: &Value, path: &str, key: &str) -> Result<Option<Vec<String>>, String> {
    let v = match root.get(key) {
        None => return Ok(None),
        Some(v) => v,
    };
    let arr = match v {
        Value::Array(a) => a,
        _ => return Err(type_error(path, key, "字符串数组")),
    };
    let mut out = Vec::new();
    for item in arr {
        match item {
            Value::String(s) => {
                if !s.is_empty() {
                    out.push(s.clone());
                }
            }
            _ => return Err(format!("配置文件 {path} 的字段 '{key}' 的元素需要字符串")),
        }
    }
    Ok((!out.is_empty()).then_some(out))
}

/// 读取并解析配置文件（顶层对象 + 未知字段拒绝 + 类型/区间校验）。
/// 常规字段经宏表展开（单一登记点），thinking 三态与 temperature/top_p
/// 开闭区间是特殊判据、留在手工段。
pub(super) fn load_config_file(path: &str) -> Result<FileConfig, String> {
    let text = read_whole_file_limited(path, K_MAX_CONFIG_BYTES, "配置文件")?;
    if text.trim().is_empty() {
        return Err(format!("配置文件为空: {path}"));
    }
    let root: Value =
        serde_json::from_str(&text).map_err(|e| format!("配置文件 {path} 不是合法 JSON: {e}"))?;
    let obj = match &root {
        Value::Object(o) => o,
        _ => return Err(format!("配置文件 {path} 的顶层必须是 JSON 对象")),
    };
    for k in obj.keys() {
        if !PARSED_FIELD_NAMES.contains(&k.as_str()) && !KNOWN_UNPARSED_FIELDS.contains(&k.as_str())
        {
            return Err(format!("配置文件 {path} 含未知字段 '{k}'（拼写错误？）"));
        }
    }

    // want_* 序列与宏表的一致性由 tests::parsed_field_table_matches_want_sequence
    // 钉住（次序即报错优先级，与 parsed_fields 表内次序一致，勿重排）。
    let mut f = FileConfig {
        driver: want_string(&root, path, "driver")?,
        var: want_string(&root, path, "var")?,
        endpoint: want_string(&root, path, "endpoint")?,
        model: want_string(&root, path, "model")?,
        api_key: want_string(&root, path, "api_key")?,
        api_key_file: want_string(&root, path, "api_key_file")?,
        timeout_sec: want_int(
            &root,
            path,
            "timeout",
            limits::TIMEOUT_MIN_SEC,
            limits::TIMEOUT_MAX_SEC,
        )?,
        max_tokens: want_int(
            &root,
            path,
            "max_tokens",
            limits::MAX_TOKENS_MIN,
            limits::MAX_TOKENS_MAX,
        )?,
        max_turns: want_int(
            &root,
            path,
            "max_turns",
            limits::MAX_TURNS_MIN,
            limits::MAX_TURNS_MAX,
        )?,
        max_task_seconds: want_int(
            &root,
            path,
            "max_task_seconds",
            limits::TASK_TIMEOUT_MIN_SEC,
            limits::TASK_TIMEOUT_MAX_SEC,
        )?,
        // 上下文字节预算（0 = 不限；上限 llm_limits 单点）
        max_history_bytes: want_int(
            &root,
            path,
            "max_history_bytes",
            0,
            limits::BUDGET_BYTES_MAX,
        )?,
        max_task_tool_result_bytes: want_int(
            &root,
            path,
            "max_task_tool_result_bytes",
            0,
            limits::BUDGET_BYTES_MAX,
        )?,
        max_task_image_bytes: want_int(
            &root,
            path,
            "max_task_image_bytes",
            0,
            limits::BUDGET_BYTES_MAX,
        )?,
        max_calls_per_round: want_int(
            &root,
            path,
            "max_calls_per_round",
            limits::MAX_CALLS_PER_ROUND_MIN,
            limits::MAX_CALLS_PER_ROUND_MAX,
        )?,
        max_retries: want_int(
            &root,
            path,
            "max_retries",
            limits::MAX_RETRIES_MIN,
            limits::MAX_RETRIES_MAX,
        )?,
        retry_backoff_ms: want_int(
            &root,
            path,
            "retry_backoff_ms",
            limits::RETRY_BACKOFF_MS_MIN,
            limits::RETRY_BACKOFF_MS_MAX,
        )?,
        temperature: want_number(&root, path, "temperature")?,
        top_p: want_number(&root, path, "top_p")?,
        reasoning_effort: want_string(&root, path, "reasoning_effort")?,
        prompt_files: want_string_array(&root, path, "prompt_files")?,
        audit_log: want_string(&root, path, "audit_log")?,
        session_file: want_string(&root, path, "session_file")?,
        thinking: None,
        stream: want_bool(&root, path, "stream")?,
        history_summary: want_bool(&root, path, "history_summary")?,
        max_summary_bytes: want_int(
            &root,
            path,
            "max_summary_bytes",
            limits::SUMMARY_BYTES_MIN,
            limits::SUMMARY_BYTES_MAX,
        )?,
    };
    if let Some(t) = f.temperature {
        if !(0.0..=2.0).contains(&t) {
            return Err(format!(
                "配置文件 {path} 的字段 'temperature' 需要在 [0, 2] 范围内"
            ));
        }
    }
    if let Some(p) = f.top_p {
        if p <= 0.0 || p > 1.0 {
            return Err(format!(
                "配置文件 {path} 的字段 'top_p' 需要在 (0, 1] 范围内"
            ));
        }
    }
    // thinking 三态：字符串 enabled/disabled，或布尔（与 C++ parseConfigStrings 同判据）
    if let Some(v) = root.get("thinking") {
        f.thinking = match v {
            Value::String(s) => Some(s.clone()),
            Value::Bool(b) => Some(if *b { "enabled" } else { "disabled" }.to_string()),
            _ => {
                return Err(type_error(
                    path,
                    "thinking",
                    "字符串（enabled/disabled）或布尔值",
                ));
            }
        };
    }
    Ok(f)
}

/// `~` 展开：只处理 `~` 与 `~/`（不做 `~user`，那要查 passwd）。
pub(super) fn expand_home(path: &str) -> String {
    use super::env_var;
    if !path.starts_with('~') || (path.len() > 1 && !path.starts_with("~/")) {
        return path.to_string();
    }
    match env_var("HOME") {
        Some(home) => format!("{home}{}", &path[1..]),
        None => path.to_string(),
    }
}

/// 读整个文件，超过 `cap` 即报错（**不静默截断**——截断过的内容进模型上下文
/// 比缺文件更难查，与 C++ `readWholeFileLimited` 同口径）。
pub(super) fn read_whole_file_limited(path: &str, cap: u64, what: &str) -> Result<String, String> {
    let meta = fs::metadata(path).map_err(|e| format!("无法读取{what} '{path}': {e}"))?;
    if meta.len() > cap {
        return Err(format!(
            "{what} '{path}' 有 {} 字节，超过上限 {cap} 字节；请缩减内容后重试",
            meta.len()
        ));
    }
    fs::read(path)
        .map_err(|e| format!("无法读取{what} '{path}': {e}"))
        .map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// 读取密钥文件（`~` 展开、首尾 trim、64 KiB 上限、空文件拒绝）。
pub(super) fn read_api_key_file(path: &str) -> Result<String, String> {
    let real = expand_home(path);
    let text = read_whole_file_limited(&real, K_MAX_KEY_FILE_BYTES, "密钥文件")?;
    let key = text.trim();
    if key.is_empty() {
        return Err(format!("密钥文件为空: {real}"));
    }
    Ok(key.to_string())
}

/// 密钥字符集判据（C++ `validateApiKeyChars` 同判据）：含控制字符即拒绝
/// ——换行会被拼进 `Authorization` 头，等于把后面的内容变成额外请求头。
pub(super) fn validate_api_key_chars(key: &str) -> Result<(), String> {
    for (i, b) in key.bytes().enumerate() {
        if b < 0x20 || b == 0x7f {
            return Err(format!(
                "含控制字符 0x{b:02x}（第 {} 个字节）：密钥必须是**单行**文本，\
                 换行会被原样拼进 Authorization 头，等于把后面的内容变成额外请求头；\
                 请检查密钥文件是否混入了多行内容或 CRLF 行尾",
                i + 1
            ));
        }
    }
    Ok(())
}

/// 组内/其他用户可读时给出提示（C++ `secretFilePermissionWarning` 同口径；
/// 判据单点在 [`crate::fssec::wide_perms`]，`Any` 保住本站历史上不做 is_file
/// 检查的行为）。
pub(super) fn secret_file_permission_warning(path: &str) -> String {
    if crate::fssec::wide_perms(&expand_home(path), crate::fssec::PermKind::Any) {
        return format!(
            "提示: {} 对同组/其他用户可读（建议 chmod 600），它保存着 API key",
            expand_home(path)
        );
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 表 ↔ want_* 序列的一致性（B3）：宏表是字段名清单的单一事实源，
    /// 解析序列是手写的（macro_rules 卫生规则接不到调用点字段），这里
    /// 双向钉住：表里每个名字都必须被真实解析——给它一个对该种类必然
    /// 错的值，解析层必须点名该字段（被静默忽略 = 名字登记了却没接上
    /// want_*）。反向（want_* 解析了表外名字）由未知字段拒绝天然挡住
    /// （拼错名的既有用例已覆盖）。
    #[test]
    fn parsed_field_table_matches_want_sequence() {
        const BAD_TYPED: &[(&str, &str)] = parsed_fields!(emit_bad);
        let dir = std::env::temp_dir().join(format!("mybot_cfg_tbl_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cfg.json");
        let p = path.to_string_lossy().to_string();
        for (name, bad) in BAD_TYPED {
            std::fs::write(&path, format!("{{\"{name}\":{bad}}}")).unwrap();
            let e = load_config_file(&p).unwrap_err();
            assert!(
                e.contains(name),
                "字段 {name} 的错类型值 {bad} 应被解析层点名，实际: {e}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 正路径：各字段真的被读进 FileConfig（与 parsed_field_table_matches_want_sequence
    /// 的错路径互补——那边验证「错值被点名」，这边验证「对值被采纳」）。
    #[test]
    fn load_config_file_positive_path_reads_all_fields() {
        let dir = std::env::temp_dir().join(format!("mybot_cfg_pos_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cfg.json");
        let p = path.to_string_lossy().to_string();

        let valid_json = r#"{
            "driver": "openai",
            "var": "OPENAI_API_KEY",
            "endpoint": "https://api.openai.com/v1",
            "model": "gpt-4",
            "api_key": "sk-test",
            "api_key_file": "/tmp/key",
            "timeout": 30,
            "max_tokens": 4096,
            "max_turns": 10,
            "temperature": 0.7,
            "top_p": 0.9,
            "thinking": "adaptive",
            "stream": true,
            "audit_log": "/tmp/audit.jsonl",
            "session_file": "/tmp/session.jsonl"
        }"#;

        std::fs::write(&path, valid_json).unwrap();
        let cfg = load_config_file(&p).expect("正路径应成功");

        assert_eq!(cfg.driver, Some("openai".to_string()));
        assert_eq!(cfg.var, Some("OPENAI_API_KEY".to_string()));
        assert_eq!(cfg.endpoint, Some("https://api.openai.com/v1".to_string()));
        assert_eq!(cfg.model, Some("gpt-4".to_string()));
        assert_eq!(cfg.api_key, Some("sk-test".to_string()));
        assert_eq!(cfg.api_key_file, Some("/tmp/key".to_string()));
        assert_eq!(cfg.timeout_sec, Some(30));
        assert_eq!(cfg.max_tokens, Some(4096));
        assert_eq!(cfg.max_turns, Some(10));
        assert_eq!(cfg.temperature, Some(0.7));
        assert_eq!(cfg.top_p, Some(0.9));
        assert_eq!(cfg.thinking, Some("adaptive".to_string()));
        assert_eq!(cfg.stream, Some(true));
        assert_eq!(cfg.audit_log, Some("/tmp/audit.jsonl".to_string()));
        assert_eq!(cfg.session_file, Some("/tmp/session.jsonl".to_string()));

        let _ = std::fs::remove_dir_all(&dir);
    }
}

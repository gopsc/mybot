//! audit.rs —— 审计轨迹（`src/agentaudit.cpp` 的镜像）
//!
//! 落盘形态：JSON Lines（每行一个对象，追加写）。公共字段 `ts/session/kind`，
//! 按 `kind` 分派：`session`（会话边界：用哪个驱动/模型/接入点跑的、怎么结束的）
//! 与 `model`（模型轮次：耗时/token 用量/尝试次数）。
//!
//! **工具行（kind=tool）基本不在这里写**：后端工具的调用全经后端帧往返，后端
//! `mybot --mcp-backend` 自己就落工具行（含 exit_code / image_fp / summary）。
//! 两侧共用一个 AF_UNIX socket，会话行/模型行由本侧写、工具行由后端写——
//! 分工与方案 F3 的拓扑一致（`docs/agent.md` 的审计小节）。**例外**：不经后端的
//! 本侧本地工具（Phase 6 的 `http_fetch`）后端看不见，其工具行由本侧
//! [`AuditLog::write_tool`] 落，字段与后端工具行同名同义。（`ica_*` 是纯内存账本、
//! 无外部副作用，沿用既有做法不落工具行。）
//!
//! **绝不写密钥**：会话行只写 `api_key_source` 枚举名（与 `--check-config`
//! 摘要同口径：只报来源不报值）；接入点先经 `sanitize_endpoint` 去掉 query 与
//! userinfo（有些网关把凭据放 URL 里，审计是 append-only 的落盘文件）。
//!
//! 如实偏差（记录在案）：serde_json 的 Map 缺省按键名字母序序列化，故本侧行内
//! 键序与 C++ 的插入序不同（`{"api_key_source":..,"driver":..,"kind":"session",..}`）。
//! JSON 对象的键序不是语义，字段名与类型逐一对齐，消费方的 `grep '"kind":"session"'`
//! 一类判据不受影响。

use std::fs::OpenOptions;
use std::io::Write;

use serde_json::{json, Map, Value};

use crate::out::errln;

/// 会话开始记录之前惰性补写：与 C++ 同口径，`sessionStartWritten` 由调用方
/// （`AuditLog`）自己管——`write_model` 前若还没写过 start 就先补一条。
pub struct AuditLog {
    path: String,
    session_id: String,
    to_stderr: bool,
    file: Option<std::fs::File>,
    warn_broken: bool,
    start_written: bool,
}

/// `kind="session"` 行（会话边界）。
#[derive(Default)]
pub struct SessionEntry {
    /// start / end / error（空 → start）
    pub status: String,
    pub driver: String,
    pub model: String,
    pub endpoint: String,
    pub api_key_source: String,
    pub resumed: bool,
    pub error: String,
    pub ms: i64,
}

/// `kind="model"` 行（模型轮次）。
#[derive(Default)]
pub struct ModelEntry {
    /// 轮次（<0 不写）
    pub turn: i64,
    pub ok: bool,
    pub status: String,
    pub error: String,
    pub ms: i64,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub attempts: u64,
    /// provider 给的用量：**只记不推算**（缺则无字段）
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
}

/// `kind="tool"` 行（**仅本侧本地工具**；后端工具的工具行由后端落，见模块头）。
#[derive(Default)]
pub struct ToolEntry {
    pub turn: i64,
    pub tool: String,
    pub args: Value,
    pub ok: bool,
    pub error: String,
    pub ms: i64,
    pub bytes: u64,
    pub summary: String,
}

impl AuditLog {
    /// 打开审计日志。`path == "-"` → 写 stderr（前台调试用；与 C++ 同口径）。
    pub fn open(path: &str) -> Result<Self, String> {
        if path.is_empty() {
            return Err("审计日志路径为空".to_string());
        }
        let session_id = new_session_id();
        let (to_stderr, file) = if path == "-" {
            (true, None)
        } else {
            // 新建以 0600 建立（与 REPL 历史 / ICA sidecar / 会话文件同规）；
            // 既有文件权限宽于 0600 时响亮提醒一次（打开只发生一次，不会刷屏）。
            // 2026-10-01 审计批次 A（P1-1）：此前随 umask 常落 0644——model 行的
            // error 字段可能带回显片段，日志本身按敏感文件对待。
            #[cfg(unix)]
            let wide = wide_perms_warning(path);
            let mut opts = OpenOptions::new();
            opts.create(true).append(true);
            crate::fssec::opts_0600(&mut opts);
            let f = opts.open(path).map_err(|e| {
                format!(
                    "无法打开审计日志文件 '{path}'（{e}）；请检查目录是否存在、\
                         是否有写权限，或在配置错误阶段先修正路径"
                )
            })?;
            #[cfg(unix)]
            if !wide.is_empty() {
                errln!("{wide}");
            }
            (false, Some(f))
        };
        Ok(Self {
            path: path.to_string(),
            session_id,
            to_stderr,
            file,
            warn_broken: false,
            start_written: false,
        })
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// 采纳一个既有 session id（批次 D：`--resume` 沿用被恢复会话的原 id，
    /// 使恢复前后的行能对上同一段对话）。**必须**在首行 `start` 写出前调用
    /// （`start_written` 尚为 false 时调用方保证这一点）；空 id 不采纳
    /// （沿用 `open()` 生成的那个，恢复的会话文件里没有记 session id 的老会话）。
    pub fn adopt_session_id(&mut self, id: &str) {
        if !id.is_empty() {
            self.session_id = id.to_string();
        }
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    /// 会话边界行。首条 start 之后不再重复标 start（C++ 的 `sessionStartWritten_`）。
    pub fn write_session(&mut self, e: &SessionEntry) {
        let status: &str = if e.status.is_empty() {
            "start"
        } else {
            e.status.as_str()
        };
        if status == "start" {
            self.start_written = true;
        }
        let mut line = base_line(&self.session_id, "session");
        line.insert("status".into(), json!(status));
        if !e.driver.is_empty() {
            line.insert("driver".into(), json!(e.driver));
        }
        if !e.model.is_empty() {
            line.insert("model".into(), json!(e.model));
        }
        if !e.endpoint.is_empty() {
            line.insert("endpoint".into(), json!(sanitize_endpoint(&e.endpoint)));
        }
        if !e.api_key_source.is_empty() {
            line.insert("api_key_source".into(), json!(e.api_key_source));
        }
        if e.resumed {
            line.insert("resumed".into(), json!(true));
        }
        if !e.error.is_empty() {
            line.insert("error".into(), json!(e.error));
        }
        if e.ms > 0 {
            line.insert("ms".into(), json!(e.ms));
        }
        self.emit(line);
    }

    /// 模型轮次行。写之前若还没写过会话头，先惰性补一条 start——一次在模型调用
    /// 阶段就失败的会话，日志里**也会有** start 与那条 model 记录。
    pub fn write_model(&mut self, e: &ModelEntry) {
        if !self.start_written {
            // 惰性补 start：调用方没显式写头时的兜底（与 C++ writeModelRecord 同）
            self.write_session(&SessionEntry {
                status: "start".to_string(),
                ..Default::default()
            });
        }
        let mut line = base_line(&self.session_id, "model");
        if e.turn >= 0 {
            line.insert("turn".into(), json!(e.turn));
        }
        line.insert("ok".into(), json!(e.ok));
        if !e.status.is_empty() {
            line.insert("status".into(), json!(e.status));
        }
        if !e.error.is_empty() {
            line.insert("error".into(), json!(e.error));
        }
        line.insert("ms".into(), json!(e.ms));
        if e.req_bytes > 0 {
            line.insert("req_bytes".into(), json!(e.req_bytes));
        }
        if e.resp_bytes > 0 {
            line.insert("resp_bytes".into(), json!(e.resp_bytes));
        }
        if e.attempts > 0 {
            line.insert("attempts".into(), json!(e.attempts));
        }
        if let Some(v) = e.prompt_tokens {
            line.insert("prompt_tokens".into(), json!(v));
        }
        if let Some(v) = e.completion_tokens {
            line.insert("completion_tokens".into(), json!(v));
        }
        self.emit(line);
    }

    /// 本侧本地工具（http_fetch）的 `kind=tool` 行。字段名与次序对齐 C++
    /// `writeToolFields`（turn/tool/args/ok/error/ms/bytes/summary），消费方无需区分
    /// 是哪一侧写的。args 由调用方先脱敏（这里不碰内容）。
    pub fn write_tool(&mut self, e: &ToolEntry) {
        if !self.start_written {
            self.write_session(&SessionEntry {
                status: "start".to_string(),
                ..Default::default()
            });
        }
        let mut line = base_line(&self.session_id, "tool");
        line.insert("turn".into(), json!(e.turn));
        line.insert("tool".into(), json!(e.tool));
        if e.args.is_object() {
            line.insert("args".into(), e.args.clone());
        }
        line.insert("ok".into(), json!(e.ok));
        if !e.error.is_empty() {
            line.insert("error".into(), json!(e.error));
        }
        line.insert("ms".into(), json!(e.ms));
        line.insert("bytes".into(), json!(e.bytes));
        if !e.summary.is_empty() {
            line.insert("summary".into(), json!(e.summary));
        }
        self.emit(line);
    }

    /// 落一行。写失败**只响亮告警一次**（审计「看起来在记、其实没记」比没有更糟），
    /// 不返回错——审计失败不该打断机器人正在执行的动作。
    fn emit(&mut self, line: Map<String, Value>) {
        let mut text = Value::Object(line).to_string();
        text.push('\n');
        if self.to_stderr {
            // 检查式写出（out.rs）：stderr 坏了也不 panic（2026-09-24 审计 H2 同族）
            crate::out::stderr_text(&text);
            return;
        }
        let Some(f) = self.file.as_mut() else { return };
        // 每行 write+flush 是刻意的崩溃一致性（进程被 -9 时崩溃前的行已在盘上；
        // BufWriter 的批量落盘会让「审计记录了却在崩溃中整段丢失」）。写发生在
        // 异步上下文里但只是一次小页写出，不值得 spawn_blocking 的间接成本。
        if (f.write_all(text.as_bytes()).is_err() || f.flush().is_err()) && !self.warn_broken {
            self.warn_broken = true;
            errln!(
                "警告: 审计日志写入失败（磁盘满/权限？），本次会话的后续记录可能丢失；\
                 工具执行不受影响"
            );
        }
    }
}

/// 公共字段：ts / session / kind（kind 显式写，不搞「缺省即 tool」的隐式约定）。
fn base_line(session_id: &str, kind: &str) -> Map<String, Value> {
    let mut line = Map::new();
    line.insert("ts".into(), json!(audit_timestamp()));
    line.insert("session".into(), json!(session_id));
    line.insert("kind".into(), json!(kind));
    line
}

/// 会话 id：时间 + pid 的 64 位 FNV 指纹取 8 位 hex——只用于把同一会话的行对上号，
/// 不要求不可预测。
fn new_session_id() -> String {
    let (sec, nsec) = now_timespec();
    let seed = (sec as u64)
        .wrapping_mul(1_000_000_000)
        .wrapping_add(nsec as u64)
        .wrapping_add((std::process::id() as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15));
    fingerprint64(&seed.to_string())[..8].to_string()
}

/// 既有审计日志文件权限宽于 0600 时的告警文本（判据单点在 [`crate::fssec::wide_perms`]，
/// 与 `session::perms_warning` 同口径）。不存在/取不到权限/非 unix → 空串（新建路径由
/// `open` 的 `mode(0o600)` 兜住，不会走到这里）。
#[cfg(unix)]
fn wide_perms_warning(path: &str) -> String {
    if !crate::fssec::wide_perms(path, crate::fssec::PermKind::File) {
        return String::new();
    }
    format!(
        "警告: 审计日志文件 '{path}' 权限宽于 600（model 行的 error 字段可能带回显片段，\
         同等敏感），建议 chmod 600 {path}"
    )
}

/// FNV-1a 64 位 → 16 位小写 hex（算法标准参数）。
pub fn fingerprint64(s: &str) -> String {
    fingerprint64_bytes(s.as_bytes())
}

/// FNV-1a 64 位字节版（算法参数与 [`fingerprint64`] 相同，输入是任意字节——
/// 图片二进制不保证是合法 UTF-8，不能走 str 版；record.rs 的图片指纹用它）。
pub fn fingerprint64_bytes(b: &[u8]) -> String {
    const FNV_PRIME: u64 = 1_099_511_628_211;
    const FNV_BASIS: u64 = 14_695_981_039_346_656_037;
    let mut h = FNV_BASIS;
    for x in b {
        h ^= *x as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    format!("{h:016x}")
}

/// 本地时间戳 `YYYY-MM-DDTHH:MM:SS.mmm±HH:MM`（与 C++ `auditTimestamp` 逐字段同构）。
pub fn audit_timestamp() -> String {
    let (sec, nsec) = now_timespec();
    let mut tmv: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r 只写 tmv，两者指针均有效；不需要跨线程的时区全局态句柄。
    unsafe { libc::localtime_r(&sec, &mut tmv) };
    let off = tmv.tm_gmtoff;
    let (sign, abs) = if off >= 0 { ('+', off) } else { ('-', -off) };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}{}{:02}:{:02}",
        tmv.tm_year + 1900,
        tmv.tm_mon + 1,
        tmv.tm_mday,
        tmv.tm_hour,
        tmv.tm_min,
        tmv.tm_sec,
        nsec / 1_000_000,
        sign,
        abs / 3600,
        (abs % 3600) / 60
    )
}

/// 接入点进审计前去掉 query / fragment 与 userinfo。
///
/// 有些网关把凭据放在 URL 里（`https://user:tok@host/v1/...?key=...`），而审计是
/// append-only 的落盘文件——把整条 URL 抄进去等于把密钥写进日志。只保留
/// `scheme://host/path`（口径与后端 maskSecretsInText 同源：不该出门的东西不进日志）。
pub fn sanitize_endpoint(url: &str) -> String {
    let mut out = url.to_string();
    if let Some(q) = out.find(['?', '#']) {
        out.truncate(q);
    }
    if let Some(scheme) = out.find("://") {
        let host_start = scheme + 3;
        let end = match out[host_start..].find('/') {
            Some(i) => host_start + i,
            None => out.len(),
        };
        if let Some(at) = out[..end].rfind('@') {
            if at >= host_start {
                out.replace_range(host_start..=at, "");
            }
        }
    }
    out
}

/// 当前时间（秒 + 纳秒）。`as i64` 在 32 位目标上是必要的（那些平台上
/// `time_t`/`c_long` 是 i32），故显式放行该 lint 而不是删掉转换。
#[allow(clippy::unnecessary_cast)]
fn now_timespec() -> (i64, i64) {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime 只写 ts（指针有效），CLOCK_REALTIME 恒可用。
    unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts) };
    (ts.tv_sec as i64, ts.tv_nsec as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_is_deterministic_and_discriminating() {
        let a = fingerprint64("data:image/jpeg;base64,AAAA");
        let b = fingerprint64("data:image/jpeg;base64,AAAA");
        let c = fingerprint64("data:image/jpeg;base64,AAAB");
        assert_eq!(a, b, "同输入同指纹（对账靠它）");
        assert_ne!(a, c, "不同输入不同指纹");
        assert_eq!(a.len(), 16, "64 bit → 16 hex 字符");
        // 与 C++ 同算法：空串的 FNV-1a 64 基线指纹是常量
        assert_eq!(fingerprint64(""), "cbf29ce484222325");
    }

    #[test]
    fn timestamp_is_local_with_offset() {
        let ts = audit_timestamp();
        // YYYY-MM-DDTHH:MM:SS.mmm±HH:MM = 29 字符
        assert_eq!(ts.len(), 29, "实际: {ts}");
        assert_eq!(&ts[10..11], "T");
        assert_eq!(&ts[19..20], ".");
        assert!(ts.as_bytes()[23] == b'+' || ts.as_bytes()[23] == b'-');
        assert_eq!(&ts[26..27], ":");
        assert!(ts[0..4].chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn sanitize_endpoint_strips_query_and_userinfo() {
        assert_eq!(
            sanitize_endpoint("https://user:tok@host/v1/chat?key=SECRET#frag"),
            "https://host/v1/chat"
        );
        assert_eq!(
            sanitize_endpoint("http://127.0.0.1:9/v1"),
            "http://127.0.0.1:9/v1"
        );
        // 无 scheme / 无 userinfo：原样（只去 query）
        assert_eq!(sanitize_endpoint("127.0.0.1:9/v1?x=1"), "127.0.0.1:9/v1");
        assert_eq!(sanitize_endpoint(""), "");
    }

    #[test]
    fn session_and_model_rows_land_as_json_lines() {
        let dir = std::env::temp_dir().join(format!("mybot_audit_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audit.jsonl");
        let p = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);

        let mut log = AuditLog::open(&p).unwrap();
        log.write_session(&SessionEntry {
            status: "start".to_string(),
            driver: "LlmOpenAI".to_string(),
            model: "gpt-x".to_string(),
            endpoint: "https://u:p@host/v1/chat/completions?k=SECRET".to_string(),
            api_key_source: "env".to_string(),
            ..Default::default()
        });
        // 先写 model：不再重复补 start（start 只写一次）
        log.write_model(&ModelEntry {
            turn: 0,
            ok: true,
            status: "ok".to_string(),
            ms: 12,
            prompt_tokens: Some(1234),
            completion_tokens: Some(56),
            ..Default::default()
        });
        log.write_session(&SessionEntry {
            status: "end".to_string(),
            ..Default::default()
        });
        drop(log);

        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3, "三条记录：start + model + end\n{text}");
        for l in &lines {
            let v: Value = serde_json::from_str(l).unwrap();
            assert!(v["ts"].is_string() && v["session"].is_string() && v["kind"].is_string());
        }
        let start: Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(start["kind"], "session");
        assert_eq!(start["status"], "start");
        assert_eq!(start["driver"], "LlmOpenAI");
        // 接入点里的凭据不进日志（去 query + userinfo）
        assert_eq!(start["endpoint"], "https://host/v1/chat/completions");
        assert!(!text.contains("SECRET"), "凭据不得落盘: {text}");
        assert!(!text.contains("u:p@"), "userinfo 不得落盘: {text}");
        let model: Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(model["kind"], "model");
        assert_eq!(model["prompt_tokens"], 1234);
        assert_eq!(model["completion_tokens"], 56);
        assert_eq!(lines[2].matches("\"status\":\"start\"").count(), 0);
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn model_row_writes_lazy_session_start() {
        let dir = std::env::temp_dir().join(format!("mybot_audit_lazy_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audit.jsonl");
        let p = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);

        let mut log = AuditLog::open(&p).unwrap();
        log.write_model(&ModelEntry {
            turn: 0,
            ok: false,
            status: "error".to_string(),
            error: "connection refused".to_string(),
            ms: 3,
            ..Default::default()
        });
        drop(log);
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2, "惰性补 start + model\n{text}");
        assert!(lines[0].contains("\"kind\":\"session\""));
        assert!(lines[0].contains("\"status\":\"start\""));
        assert!(lines[1].contains("\"kind\":\"model\""));
        assert!(lines[1].contains("\"error\":\"connection refused\""));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn bad_path_fails_before_any_tool_runs() {
        // 坏路径必须在**上电前**失败（审计「看起来在记、其实没记」比没有更糟）
        let e = match AuditLog::open("/nonexistent-dir-xyz/audit.jsonl") {
            Ok(_) => panic!("坏路径必须失败"),
            Err(e) => e,
        };
        assert!(e.contains("无法打开审计日志文件"), "实际: {e}");
        assert!(AuditLog::open("").is_err());
    }

    /// 批次 D：`--resume` 采纳被恢复会话的原 session id——恢复前后的行能对上
    /// 同一段对话；空 id（老会话文件没记）不覆盖新生成的那个。
    #[test]
    fn adopt_session_id_overrides_generated_one_unless_empty() {
        let dir = std::env::temp_dir().join(format!("mybot_audit_adopt_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audit.jsonl");
        let p = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);

        let mut log = AuditLog::open(&p).unwrap();
        log.adopt_session_id("resumed-session-9");
        assert_eq!(log.session_id(), "resumed-session-9");
        log.write_session(&SessionEntry {
            status: "start".to_string(),
            resumed: true,
            ..Default::default()
        });
        drop(log);
        let text = std::fs::read_to_string(&path).unwrap();
        let v: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(v["session"], "resumed-session-9");
        assert_eq!(v["resumed"], true);

        // 空 id 不覆盖
        let mut log2 = AuditLog::open(&p).unwrap();
        let before = log2.session_id().to_string();
        log2.adopt_session_id("");
        assert_eq!(log2.session_id(), before);

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    /// 批次 A（P1-1）：新建审计文件以 0600 建立（不随 umask 落 0644），
    /// 既有宽权限文件由 `wide_perms_warning` 提醒（判据与 session::perms_warning 同口径）。
    #[test]
    fn audit_file_is_created_0600_and_wide_perms_flagged() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("mybot_audit_perm_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("audit.jsonl");
        let p = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);

        // 新建：0600（mode() 只对创建生效，umask 只能进一步收紧）
        let log = AuditLog::open(&p).unwrap();
        drop(log);
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "审计日志应以 0600 建立");

        // 既有 0600 文件：不告警
        assert!(wide_perms_warning(&p).is_empty());
        // 既有宽权限文件：告警点名路径与修法
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let w = wide_perms_warning(&p);
        assert!(w.contains("chmod 600") && w.contains(&p), "实际: {w}");
        // 不存在 / 非文件：不告警（新建路径由 mode(0o600) 兜住）
        let missing = dir.join("nope.jsonl").to_string_lossy().to_string();
        assert!(wide_perms_warning(&missing).is_empty());

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }
}

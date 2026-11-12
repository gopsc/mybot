//! 状态目录（`$MYBOT_HOME`，缺省 `$HOME/.mybot`）下的会话布局。
//!
//! [`crate::session`] 管**行格式**（会话头 + 一消息一行，跨版本存量契约）；
//! 本模块管**目录与指针布局**——「每个机器人的对话历史存在哪、这次是续写还是
//! 新开一段」。分开的理由：前者是对外格式契约，后者是本机私有摆放约定，
//! 改一个不该牵动另一个。
//!
//! 布局（`<state>/robots/<机器人>/sessions/`）：
//!
//! ```text
//! 20261003T101530Z.jsonl          段文件（会话内容本体）
//! 20261003T101530Z.jsonl.ica.json ICA sidecar（由段路径派生，见 ica::persist）
//! latest                          当前段指针（普通文件，内容 = 段文件名）
//! ```
//!
//! 三条设计约定：
//!
//!   * **指针是普通文件不是符号链接**：读到的就是目标名、可校验；悬空时能如实
//!     报出「指针指向 X 但 X 不存在」。更重要的是 ICA sidecar 由
//!     `format!("{session_file}.ica.json")` 派生——必须先把指针**解析成真实段
//!     路径**再当 `session_file`，否则 sidecar 会分裂成 `latest.ica.json`。
//!   * **指针内容走白名单**：`^[0-9]{8}T[0-9]{6}Z(-[0-9]+)*\.jsonl$`，绝不接受
//!     含 `/` 或 `..` 的内容——指针是本进程要拼进路径的磁盘数据，当成不可信输入。
//!   * **全部是参数注入的纯函数**（不读进程环境变量）：`cargo test` 默认并行，
//!     进程级 env 在并行下不安全（见 `config` 模块 ENV_LOCK 的教训），故 state_dir
//!     由调用方传入。
//!
//! 为什么要「当前段指针」而不是固定文件名：一次对话可能横跨多次进程重启
//! （这正是本功能的意义），但**段**仍应保持「一段一文件」——重启续写同一段，
//! 判据不通过（提示词/工具集变了、文件损坏）就新开一段，旧段原样保留可复盘。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::audit::fingerprint64;
use crate::config::is_safe_ident;

/// 段文件后缀。
const SEGMENT_EXT: &str = ".jsonl";
/// 当前段指针的文件名。
pub const POINTER_NAME: &str = "latest";
/// 归一后的机器人目录名上限（含哈希后缀在内）。
const ROBOT_DIR_MAX: usize = 64;

/// 本次会话是「续写既有段」还是「新开一段」。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionMode {
    New,
    Continue,
}

/// 缺省布局（按机器人分目录）专有的路径；显式 `--session-file` 来源没有它。
/// 指针路径由 [`POINTER_NAME`] 从 `dir` 派生，不另存一份。
#[derive(Debug, Clone)]
pub struct DefaultLayout {
    /// `<state>/robots/<机器人>/sessions`
    pub dir: String,
}

/// 一次会话落点的完整计划（由 [`plan_default_session`] 或显式路径装配）。
#[derive(Debug, Clone)]
pub struct SessionPlan {
    /// 实际落盘的段文件路径（绝对路径）。
    pub path: String,
    pub mode: SessionMode,
    /// 交给 [`crate::session::SessionFileWriter::open`] 的 append 参数。
    /// 缺省布局下**新段也为 true**：段文件已由本模块以 O_EXCL 建好，
    /// 再截断一次没有意义。
    pub append: bool,
    /// 仅缺省布局有值。
    pub layout: Option<DefaultLayout>,
    /// 需要向 stderr 告警一次的内容（当前段指针损坏时给出）。
    pub warning: Option<String>,
}

/// 指针读取结果：三种状态要分开——「还没有会话」（首次运行，静默新建）与
/// 「有指针但不可用」（要告警）是两回事，混在一起会让人以为每次启动都在报错。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PointerState {
    /// 指针文件不存在 = 这个机器人还没有过会话。
    Absent,
    /// 指针有效且目标段文件存在。
    Valid(String),
    /// 指针在但内容非法、或指向的段文件已不在。
    Broken(String),
}

/// 机器人展示名 → 目录名。
///
/// 展示名来自后端 `context.get` 的 `robotName`（结构脚本名去目录去 `.sql`），
/// 可能含空格、Unicode、点，甚至是空串——不能直接当路径分量。
/// 安全标识符原样使用（常见情形：`spider_sim` 路径保持干净）；需要改写时按
/// `[A-Za-z0-9_-]` 过滤 + 折叠下划线 + 数字开头补前缀 + 截断，并**追加原始名的
/// 短哈希**。只在发生改写时加哈希，故「改写名」与「本来就合法的名」不会撞，
/// 两个不同的非法名也不会撞（哈希不同），无需任何持久映射表。
pub fn robot_dir_name(robot_name: &str) -> String {
    if is_safe_ident(robot_name) && robot_name.len() <= ROBOT_DIR_MAX {
        return robot_name.to_string();
    }
    let mut out = String::new();
    let mut last_us = false;
    for c in robot_name.chars() {
        let keep = c.is_ascii_alphanumeric() || c == '_' || c == '-';
        let c = if keep { c } else { '_' };
        if c == '_' {
            if last_us {
                continue;
            }
            last_us = true;
        } else {
            last_us = false;
        }
        out.push(c);
    }
    if out.is_empty() {
        out.push_str("robot");
    }
    if out.starts_with(|c: char| c.is_ascii_digit()) {
        out.insert(0, '_');
    }
    // 给哈希留出 `_` + 16 位 hex 的位置
    let hash = fingerprint64(robot_name);
    let room = ROBOT_DIR_MAX.saturating_sub(hash.len() + 1);
    if out.len() > room {
        out.truncate(room);
    }
    format!("{out}_{hash}")
}

/// 段文件名（UTC，无冒号、可字典序排序）：`%Y%m%dT%H%M%SZ`。
pub fn segment_name(now_sec: i64) -> String {
    let t: libc::time_t = now_sec;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: gmtime_r 只写 tm（本函数独占），t 的指针有效。
    unsafe { libc::gmtime_r(&t, &mut tm) };
    format!(
        "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// 段文件名白名单：`<14 位 UTC 时间戳>Z` + 可选 `-<数字>` 后缀 + `.jsonl`。
/// 指针内容是本进程要拼进路径的磁盘数据，凡不匹配一律当不可用（防目录穿越）。
pub fn is_valid_segment_name(s: &str) -> bool {
    let Some(stem) = s.strip_suffix(SEGMENT_EXT) else {
        return false;
    };
    let mut parts = stem.split('-');
    let Some(head) = parts.next() else {
        return false;
    };
    let b = head.as_bytes();
    // 8 位日期 + 'T' + 6 位时间 + 'Z'
    if b.len() != 16 || b[8] != b'T' || b[15] != b'Z' {
        return false;
    }
    let digits_ok =
        b[..8].iter().all(u8::is_ascii_digit) && b[9..15].iter().all(u8::is_ascii_digit);
    digits_ok && parts.all(|p| !p.is_empty() && p.bytes().all(|c| c.is_ascii_digit()))
}

/// 读当前段指针。`dir` = `.../sessions`。
pub fn read_pointer(dir: &str) -> PointerState {
    let ptr = format!("{dir}/{POINTER_NAME}");
    let text = match fs::read_to_string(&ptr) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return PointerState::Absent,
        Err(e) => return PointerState::Broken(format!("无法读取当前段指针 {ptr}（{e}）")),
    };
    let name = text.trim();
    if !is_valid_segment_name(name) {
        return PointerState::Broken(format!(
            "当前段指针 {ptr} 的内容不是合法段名（拒绝含 '/' 或 '..' 的内容）"
        ));
    }
    let path = format!("{dir}/{name}");
    if !Path::new(&path).is_file() {
        return PointerState::Broken(format!("当前段指针 {ptr} 指向 {name}，但该段文件已不在"));
    }
    PointerState::Valid(name.to_string())
}

/// 原子写当前段指针（同目录 temp + fsync + rename，0600）。
pub fn write_pointer(dir: &str, name: &str) -> Result<(), String> {
    if !is_valid_segment_name(name) {
        return Err(format!("拒绝把非法段名写进当前段指针: {name}"));
    }
    let ptr = format!("{dir}/{POINTER_NAME}");
    let tmp = format!("{dir}/.{POINTER_NAME}.{}.tmp", std::process::id());
    let mut opts = OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    crate::fssec::opts_0600(&mut opts);
    let mut f = opts
        .open(&tmp)
        .map_err(|e| format!("无法写当前段指针 {tmp}（{e}）"))?;
    let body = format!("{name}\n");
    if let Err(e) = f.write_all(body.as_bytes()).and_then(|_| f.sync_all()) {
        drop(f);
        let _ = fs::remove_file(&tmp);
        return Err(format!("写入当前段指针失败（{e}）"));
    }
    drop(f);
    fs::rename(&tmp, &ptr).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("无法把当前段指针落到 {ptr}（{e}）")
    })
}

/// 建目录，**只对本次新建的层级**设 0700（既有目录不擅自改权限——里面可能有
/// 别人的东西，本进程不是它的主人）。
pub fn ensure_dir_0700(path: &str) -> Result<(), String> {
    let p = Path::new(path);
    if p.is_dir() {
        return Ok(());
    }
    let mut cur = PathBuf::new();
    for comp in p.components() {
        cur.push(comp);
        if cur.is_dir() {
            continue;
        }
        fs::create_dir(&cur).map_err(|e| format!("无法创建目录 {}（{e}）", cur.display()))?;
        crate::fssec::set_dir_0700(&cur, "目录")?;
    }
    Ok(())
}

/// 在当前段目录下**原子**占一个新段文件（O_EXCL）。同名退 `-<pid>`，再冲突加序号。
/// 返回 (完整路径, 段文件名)。
fn create_segment(dir: &str, now_sec: i64) -> Result<(String, String), String> {
    let base = segment_name(now_sec);
    for attempt in 0..16u32 {
        let name = match attempt {
            0 => format!("{base}{SEGMENT_EXT}"),
            1 => format!("{base}-{}{SEGMENT_EXT}", std::process::id()),
            n => format!("{base}-{}-{n}{SEGMENT_EXT}", std::process::id()),
        };
        let path = format!("{dir}/{name}");
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        crate::fssec::opts_0600(&mut opts);
        match opts.open(&path) {
            Ok(_) => return Ok((path, name)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("无法创建会话段 {path}（{e}）")),
        }
    }
    Err(format!(
        "无法在同秒内为 {base} 找到可用段名（同名冲突过多）"
    ))
}

/// 缺省布局的计划：建目录 → 读当前段指针 → 续写或新开一段。
///
/// `new_session=true`（`--new-session`）时不看指针，直接开新段并改指。
pub fn plan_default_session(
    state_dir: &str,
    robot_name: &str,
    new_session: bool,
    now_sec: i64,
) -> Result<SessionPlan, String> {
    let dir = format!("{state_dir}/robots/{}/sessions", robot_dir_name(robot_name));
    ensure_dir_0700(&dir)?;
    let mut warning = None;
    if !new_session {
        match read_pointer(&dir) {
            PointerState::Valid(name) => {
                return Ok(SessionPlan {
                    path: format!("{dir}/{name}"),
                    mode: SessionMode::Continue,
                    append: true,
                    layout: Some(DefaultLayout { dir }),
                    warning: None,
                });
            }
            // 首次运行：这个机器人还没有过会话，不是错误，静默新建。
            PointerState::Absent => {}
            PointerState::Broken(why) => warning = Some(why),
        }
    }
    let (path, name) = create_segment(&dir, now_sec)?;
    if let Err(e) = write_pointer(&dir, &name) {
        // 指针写不进去不影响本段可用（只是下次认不出它是「当前段」），响亮告知。
        warning = Some(match warning {
            Some(w) => format!("{w}；{e}"),
            None => e,
        });
    }
    Ok(SessionPlan {
        path,
        mode: SessionMode::New,
        append: true,
        layout: Some(DefaultLayout { dir }),
        warning,
    })
}

/// 续接失败后的降级：在同一机器人目录下开新段并改指，**旧段原样保留**。
pub fn degrade_to_new_segment(plan: &SessionPlan, now_sec: i64) -> Result<SessionPlan, String> {
    let layout = plan
        .layout
        .as_ref()
        .ok_or("降级只适用于缺省布局（显式 --session-file 路径没有当前段概念）")?;
    let (path, name) = create_segment(&layout.dir, now_sec)?;
    let warning = write_pointer(&layout.dir, &name).err();
    Ok(SessionPlan {
        path,
        mode: SessionMode::New,
        append: true,
        layout: Some(layout.clone()),
        warning,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn tmpdir(tag: &str) -> PathBuf {
        crate::testutil::tmpdir("mybot-store", tag)
    }

    #[test]
    fn robot_dir_name_keeps_safe_names_verbatim() {
        assert_eq!(robot_dir_name("spider_sim"), "spider_sim");
        assert_eq!(robot_dir_name("_x1"), "_x1");
    }

    #[test]
    fn robot_dir_name_rewrites_and_disambiguates() {
        let a = robot_dir_name("my robot");
        let b = robot_dir_name("my@robot");
        let c = robot_dir_name("my_robot");
        assert!(a.starts_with("my_robot_"), "实际: {a}");
        assert!(a
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'));
        // 两个不同的非法名不会撞；非法名也不会撞上本来就合法的名字
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_ne!(b, c);
        // 空名/前导数字有兜底
        assert!(robot_dir_name("").starts_with("robot_"));
        assert!(robot_dir_name("9bot").starts_with("_9bot_"));
        // 稳定性：同名同结果
        assert_eq!(robot_dir_name("my robot"), a);
        // 超长截断后仍在长度上限内
        let long = "x".repeat(500);
        assert!(robot_dir_name(&long).len() <= ROBOT_DIR_MAX);
    }

    #[test]
    fn segment_name_is_valid_and_sortable() {
        let n = segment_name(1_759_490_530);
        assert_eq!(n, "20251003T112210Z");
        assert!(is_valid_segment_name(&format!("{n}.jsonl")));
        assert!(is_valid_segment_name(&format!("{n}-123.jsonl")));
        assert!(is_valid_segment_name(&format!("{n}-123-4.jsonl")));
    }

    #[test]
    fn segment_name_whitelist_rejects_traversal() {
        for bad in [
            "../x.jsonl",
            "a/b.jsonl",
            "..",
            "",
            "latest",
            "20251003T103010.jsonl",    // 缺 Z
            "20251003T1030Z.jsonl",     // 时间位不足
            "20251003T103010Z",         // 缺后缀
            "20251003T103010Z-x.jsonl", // 后缀不是数字
            "20251003T103010Z-.jsonl",  // 空后缀
        ] {
            assert!(!is_valid_segment_name(bad), "不该通过: {bad:?}");
        }
    }

    #[test]
    fn pointer_roundtrip_and_states() {
        let dir = tmpdir("ptr");
        let d = dir.to_string_lossy().to_string();
        assert_eq!(read_pointer(&d), PointerState::Absent);

        let name = format!("{}.jsonl", segment_name(1_759_490_530));
        let seg = format!("{d}/{name}");
        fs::write(&seg, "").unwrap();
        write_pointer(&d, &name).unwrap();
        assert_eq!(read_pointer(&d), PointerState::Valid(name.clone()));
        // 临时文件不残留
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "残留: {leftovers:?}");
        // 指针内容非法 / 目标缺失
        fs::write(format!("{d}/{POINTER_NAME}"), "../etc/passwd\n").unwrap();
        assert!(matches!(read_pointer(&d), PointerState::Broken(_)));
        fs::remove_file(&seg).unwrap();
        write_pointer(&d, &name).unwrap();
        assert!(matches!(read_pointer(&d), PointerState::Broken(_)));
        // 拒绝把非法段名写进指针
        assert!(write_pointer(&d, "../x.jsonl").is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ensure_dir_0700_creates_each_level_tight() {
        let dir = tmpdir("mkdir");
        let deep = dir.join("a/b/c");
        ensure_dir_0700(&deep.to_string_lossy()).unwrap();
        for p in [dir.join("a"), dir.join("a/b"), deep.clone()] {
            let mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{} 实际 {:o}", p.display(), mode);
        }
        // 幂等：已存在不报错
        ensure_dir_0700(&deep.to_string_lossy()).unwrap();
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn plan_first_run_is_silent_new() {
        let home = tmpdir("plan-new");
        let h = home.to_string_lossy().to_string();
        let plan = plan_default_session(&h, "spider_sim", false, 1_759_490_530).unwrap();
        assert_eq!(plan.mode, SessionMode::New);
        assert!(
            plan.warning.is_none(),
            "首次运行不该告警: {:?}",
            plan.warning
        );
        assert_eq!(
            plan.path,
            format!("{h}/robots/spider_sim/sessions/20251003T112210Z.jsonl")
        );
        assert!(Path::new(&plan.path).is_file());
        // 段目录 0700、段文件 0600
        let layout = plan.layout.as_ref().unwrap();
        assert_eq!(
            fs::metadata(&layout.dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&plan.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // 第二次计划 = 续写同一段
        let again = plan_default_session(&h, "spider_sim", false, 1_759_490_600).unwrap();
        assert_eq!(again.mode, SessionMode::Continue);
        assert_eq!(again.path, plan.path);
        // --new-session 不看指针：新段 + 指针改指
        let fresh = plan_default_session(&h, "spider_sim", true, 1_759_490_700).unwrap();
        assert_eq!(fresh.mode, SessionMode::New);
        assert_ne!(fresh.path, plan.path);
        assert_eq!(
            read_pointer(&layout.dir),
            PointerState::Valid(fresh.path.rsplit('/').next().unwrap().to_string())
        );
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn plan_warns_and_rotates_on_broken_pointer() {
        let home = tmpdir("plan-broken");
        let h = home.to_string_lossy().to_string();
        let first = plan_default_session(&h, "r", false, 1_759_490_530).unwrap();
        let layout = first.layout.clone().unwrap();
        // 把当前段头改坏（模拟文件损坏）——指针还在，故这次要告警而不是静默
        fs::write(&first.path, "{\"role\":\"user\",\"content\":\"x\"}\n").unwrap();
        let second = plan_default_session(&h, "r", false, 1_759_490_600).unwrap();
        assert_eq!(
            second.mode,
            SessionMode::Continue,
            "损坏与否由恢复判据决定，计划层仍续写"
        );
        // 指针本身非法才算「不可用」
        fs::write(format!("{}/{POINTER_NAME}", layout.dir), "..\n").unwrap();
        let third = plan_default_session(&h, "r", false, 1_759_490_700).unwrap();
        assert_eq!(third.mode, SessionMode::New);
        assert!(third.warning.is_some());
        // 降级：旧段保留，新段另开，指针改指
        let degraded = degrade_to_new_segment(&third, 1_759_490_800).unwrap();
        assert_eq!(degraded.mode, SessionMode::New);
        assert_ne!(degraded.path, third.path);
        assert!(Path::new(&third.path).is_file(), "旧段必须保留");
        assert_eq!(
            read_pointer(&layout.dir),
            PointerState::Valid(degraded.path.rsplit('/').next().unwrap().to_string())
        );
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn same_second_segments_do_not_collide() {
        let home = tmpdir("plan-collide");
        let h = home.to_string_lossy().to_string();
        let a = plan_default_session(&h, "r", true, 1_759_490_530).unwrap();
        let b = plan_default_session(&h, "r", true, 1_759_490_530).unwrap();
        assert_ne!(a.path, b.path);
        assert!(is_valid_segment_name(a.path.rsplit('/').next().unwrap()));
        assert!(is_valid_segment_name(b.path.rsplit('/').next().unwrap()));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn degrade_requires_default_layout() {
        let explicit = SessionPlan {
            path: "/tmp/x.jsonl".into(),
            mode: SessionMode::New,
            append: false,
            layout: None,
            warning: None,
        };
        assert!(degrade_to_new_segment(&explicit, 0).is_err());
    }
}

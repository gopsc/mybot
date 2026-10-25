//! prompt.rs —— 系统提示词：后端 `context.get` 素材 + 提示词包
//!
//! 两件事，各自镜像 C++ 侧一个单点：
//!   1. **提示词包**（promptpack.cpp 的 Rust 移植）：目录收集 `*.md` 按文件名自然
//!      排序、单文件 1 MiB 上限、单份不加标题/多份以 `## 文件名` 分节、全空报错；
//!      以及 H2 根约束——**配置文件来源**的路径必须落在 CWD ∪ `BOT4CJ_PROMPT_DIR`
//!      之内（命令行 `--prompt-file` 是操作者本人授意，不受限）。
//!   2. **系统提示词组装**（agentprompt.cpp 的 `buildAgentSystemPrompt`）：素材来自
//!      后端 `context.get`（那里已按 `quoteUntrusted` 定界，见 `mcpbackend.cpp`），
//!      本进程只负责拼接、条件句与 64 KiB 总量判据。
//!
//! 「同一份磁盘内容，两条进上下文的通道必须有同一定界强度」：定界在后端做一次，
//! 这里**只搬运不去动它**（不裁剪、不反转义），否则强弱就从拼接处开始漂移。

use std::path::{Path, PathBuf};

/// 单个提示词文件上限（1 MiB）。提示词组装迁 Rust 前的 C++ `kMaxPromptFileBytes`
/// 迁入值；C++ 侧已无此常量，权威在此。
pub const K_MAX_PROMPT_FILE_BYTES: u64 = 1 << 20;
/// 系统提示词总量上限（F2-9，fail-closed：超限拒绝启动 agent 会话）。原 C++
/// `kMaxSystemPromptBytes` 的迁入值；C++ 侧镜像常量已删（2026-10-10），权威在此。
pub const K_MAX_SYSTEM_PROMPT_BYTES: usize = 64 << 10;
/// C++ `kInvalidUtf8Marker` 的同文本（消毒时点名被折叠掉的非法字节数）。
const INVALID_UTF8_MARKER: &str = "[! invalid UTF-8 bytes omitted";

/// UTF-8 消毒（C++ `sanitizeUtf8` 同判据）：非法序列折叠成**一个** U+FFFD，
/// 连续多字节非法串附上计数标记，合法前缀逐字节不变。
///
/// 为什么必须有：提示词里的内容进系统提示词、随首个请求发往网关，带一个非法
/// 字节就会被严格网关 400 拒掉；截断（如结构脚本摘录的 16 KiB 上限）落在多字节
/// 序列中间同样会留下半截序列，一并在这里处理。
pub fn sanitize_utf8(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    let mut rest = bytes;
    loop {
        match std::str::from_utf8(rest) {
            Ok(s) => {
                out.push_str(s);
                return out;
            }
            Err(e) => {
                let valid = e.valid_up_to();
                // 安全：valid_up_to 之前的字节已由 from_utf8 证明是合法 UTF-8
                out.push_str(std::str::from_utf8(&rest[..valid]).unwrap_or(""));
                // 连续非法字节折叠成**一个** U+FFFD + 计数（C++ sanitizeUtf8 同判据：
                // 64 个连续坏字节最多产出「1 个 U+FFFD + 一句说明」，而不是 64 个替换符）
                let mut pos = valid;
                let mut bad = 0usize;
                while pos < rest.len() {
                    match std::str::from_utf8(&rest[pos..]) {
                        Ok(_) => break, // 后面是合法文本，折叠到此为止
                        Err(e2) if e2.valid_up_to() > 0 => break,
                        Err(e2) => {
                            let n = e2.error_len().unwrap_or(rest.len() - pos).max(1);
                            bad += n;
                            pos += n;
                        }
                    }
                }
                out.push('\u{FFFD}');
                if bad > 1 {
                    out.push_str(&format!("{INVALID_UTF8_MARKER}{bad} bytes]"));
                }
                rest = &rest[pos..];
            }
        }
    }
}

/// 读一个提示词文件（字节级读入后消毒；超限**响亮拒绝**，不静默截断）。
fn read_prompt_file(path: &Path) -> Result<String, String> {
    let meta = std::fs::metadata(path)
        .map_err(|e| format!("无法读取提示词文件 '{}': {e}", path.display()))?;
    if meta.len() > K_MAX_PROMPT_FILE_BYTES {
        return Err(format!(
            "提示词文件 '{}' 有 {} 字节，超过上限 {K_MAX_PROMPT_FILE_BYTES} 字节；请缩减内容后重试",
            path.display(),
            meta.len()
        ));
    }
    let bytes =
        std::fs::read(path).map_err(|e| format!("无法读取提示词文件 '{}': {e}", path.display()))?;
    Ok(sanitize_utf8(&bytes))
}

/// 文件名自然排序里的数字段比较（去前导零后先比长度再比字典序，避免溢出）。
fn cmp_digit_run(a: &str, b: &str) -> std::cmp::Ordering {
    let a = a.trim_start_matches('0');
    let b = b.trim_start_matches('0');
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

/// 文件名自然排序：`2-x.md` 排在 `10-x.md` 之前（字典序会把 10 排在 2 前面）。
pub fn natural_name_less(a: &str, b: &str) -> bool {
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    let (mut i, mut j) = (0usize, 0usize);
    while i < ab.len() && j < bb.len() {
        if ab[i].is_ascii_digit() && bb[j].is_ascii_digit() {
            let (ai, bi) = (i, j);
            while i < ab.len() && ab[i].is_ascii_digit() {
                i += 1;
            }
            while j < bb.len() && bb[j].is_ascii_digit() {
                j += 1;
            }
            match cmp_digit_run(&a[ai..i], &b[bi..j]) {
                std::cmp::Ordering::Equal => {}
                other => return other == std::cmp::Ordering::Less,
            }
        } else {
            if ab[i] != bb[j] {
                return ab[i] < bb[j];
            }
            i += 1;
            j += 1;
        }
    }
    (ab.len() - i) < (bb.len() - j)
}

/// 展开全部输入为有序文件列表：目录收集 `*.md`（按文件名自然排序），
/// 显式文件保持传入顺序。
fn expand_prompt_paths(inputs: &[String]) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    for input in inputs {
        let p = PathBuf::from(input);
        if p.is_dir() {
            let mut mds: Vec<PathBuf> = std::fs::read_dir(&p)
                .map_err(|e| format!("无法读取提示词目录 {input}: {e}"))?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|q| q.is_file() && q.extension().is_some_and(|x| x == "md"))
                .collect();
            if mds.is_empty() {
                return Err(format!("目录中没有 .md 提示词文件: {input}"));
            }
            mds.sort_by(|x, y| {
                let (xf, yf) = (
                    x.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                    y.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                );
                if natural_name_less(&xf, &yf) {
                    std::cmp::Ordering::Less
                } else if natural_name_less(&yf, &xf) {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Equal
                }
            });
            files.extend(mds);
        } else if p.exists() {
            files.push(p);
        } else {
            return Err(format!("提示词路径不存在: {input}"));
        }
    }
    Ok(files)
}

/// 加载提示词包成品文本（空输入 = 空包，不算错误）。
pub fn load_prompt_pack(inputs: &[String]) -> Result<String, String> {
    if inputs.is_empty() {
        return Ok(String::new());
    }
    let files = expand_prompt_paths(inputs)?;
    let mut sections: Vec<(String, String)> = Vec::new(); // {文件名, 内容}
    for p in &files {
        let content = read_prompt_file(p)?.trim().to_string();
        if !content.is_empty() {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            sections.push((sanitize_utf8(name.as_bytes()), content));
        }
    }
    if sections.is_empty() {
        return Err("提示词内容为空".to_string());
    }
    // 单文件保持原样、不加标题（robot_agent 既有语义）
    if sections.len() == 1 {
        return Ok(sections.remove(0).1);
    }
    let mut pack = String::new();
    for (i, (name, body)) in sections.iter().enumerate() {
        if i > 0 {
            pack.push_str("\n\n");
        }
        pack.push_str(&format!("## {name}\n\n{body}"));
    }
    Ok(pack)
}

/// `BOT4CJ_PROMPT_DIR`：冒号分隔的允许根目录（空项忽略）。
pub fn prompt_roots_from_env() -> Vec<String> {
    let Ok(v) = std::env::var("BOT4CJ_PROMPT_DIR") else {
        return Vec::new();
    };
    v.split(':')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// 解析一个「根」：canonical 展开软链；失败则退一步取绝对路径（解析到最深的
/// 已存在父目录不可用时，至少不回落成 "."）。
fn resolve_root(root: &str) -> Option<PathBuf> {
    if let Ok(p) = std::fs::canonicalize(root) {
        if p.is_absolute() {
            return Some(p);
        }
    }
    let p = std::path::absolute(root).ok()?;
    p.is_absolute().then_some(p)
}

fn path_under(real: &Path, root: &Path) -> bool {
    let mut r = root.components();
    let mut p = real.components();
    loop {
        match r.next() {
            None => return true,
            Some(rc) => match p.next() {
                Some(pc) if pc == rc => {}
                _ => return false,
            },
        }
    }
}

/// H2 根约束：**配置文件来源**的提示词路径必须落在允许的根之内。
///
/// 判据与理由：提示词内容会进系统提示词、随首个请求发往**同一份配置可控的**
/// endpoint；若允许任意路径，一份落在工作目录的配置文件就成了一条「读任意文件
/// 并外发」的链路（`/proc/self/environ` 这类伪文件读得到，里面就有密钥）。
/// 逐段比较而不是字符串前缀——`/srv/prompts-evil` 的字符串前缀正是 `/srv/prompts`。
pub fn prompt_paths_within_roots(inputs: &[String], roots: &[String]) -> Result<(), String> {
    if inputs.is_empty() {
        return Ok(());
    }
    let real_roots: Vec<PathBuf> = roots.iter().filter_map(|r| resolve_root(r)).collect();
    if real_roots.is_empty() {
        // fail-closed：一个根都解析不出来时放行等于没有判据
        return Err(
            "无法确定提示词白名单根目录（当前工作目录与 BOT4CJ_PROMPT_DIR 都解析失败）："
                .to_string()
                + "配置文件来源的 prompt_files 需要至少一个可用的根",
        );
    }
    for input in inputs {
        let p = Path::new(input);
        if !p.exists() {
            continue; // 由加载期报「不存在」
        }
        let Ok(real) = std::fs::canonicalize(p) else {
            continue; // 打不开等同样交加载期
        };
        if real_roots.iter().any(|root| path_under(&real, root)) {
            continue;
        }
        let allowed = real_roots
            .iter()
            .map(|r| r.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(format!(
            "配置文件来源的提示词路径 '{input}' 落在允许的根之外（允许: {allowed}）：\
             提示词内容会进系统提示词、随首个请求发往**同一份配置可控的** endpoint，\
             若允许任意路径，一份落在工作目录的配置文件就成了一条「读任意文件并外发」的链路\
             （/proc/self/environ 这类伪文件读得到，里面就有密钥）。配置文件来源的路径\
             只能指向工作目录之内；确实要读该路径请改用命令行 --prompt-file（操作者本人授意），\
             或把它加进环境变量 BOT4CJ_PROMPT_DIR（冒号分隔）"
        ));
    }
    Ok(())
}

/// 后端 `context.get` 的素材（system prompt 的全部机器人侧输入）。
#[derive(Debug, Clone, Default)]
pub struct PromptMaterial {
    pub robot_name: String,
    pub structure_path: String,
    pub scripts_dir: String,
    pub allow_shell: bool,
    pub allow_hot_sql: bool,
    /// 已定界的块（后端 `quoteUntrusted` 的成品，**原样搬运**）。
    pub structure_excerpt: String,
    pub hardware_list: String,
    pub scripts_list: String,
    /// 内联短清单（非引用块），空 = 不列该条
    pub readable_vars: String,
}

impl PromptMaterial {
    /// 从 `context.get` 的 `Context` 解析。字段类型由 `protocol::Context` 的 serde 定义保证，
    /// 此处只做结构转换。
    pub fn from_context(ctx: &crate::protocol::Context) -> Result<Self, String> {
        Ok(Self {
            robot_name: ctx.robot_name.clone(),
            structure_path: ctx.structure_path.clone(),
            scripts_dir: ctx.scripts_dir.clone(),
            allow_shell: ctx.allow_shell,
            allow_hot_sql: ctx.allow_hot_sql,
            structure_excerpt: ctx.structure_excerpt.clone(),
            hardware_list: ctx.hardware_list.clone(),
            scripts_list: ctx.scripts_list.clone(),
            readable_vars: ctx.readable_vars.clone(),
        })
    }
}

/// 组装系统提示词（镜像 `buildAgentSystemPrompt` 的段落与条件句）。
/// 超过 64 KiB 即报错并**点名各来源字节数**（不静默截断）。
pub fn build_system_prompt(
    driver: &str,
    llm_var: &str,
    prompt_pack: &str,
    m: &PromptMaterial,
) -> Result<String, String> {
    let mut p = String::new();
    p += "你是机器人控制智能体（agent），通过工具控制一台真实机器人。\n";
    p += &format!(
        "机器人结构脚本：{}。硬件已加载并上电常驻（动作脚本执行完不会断电），\
         因此你可以在一次任务里连续执行多个动作脚本。\n",
        m.structure_path
    );
    p += &format!(
        "模型接入由协议驱动 `{driver}`（变量 `{llm_var}` 的位置）提供；\
         接入点、密钥与模型来自配置文件或命令行。\n\n"
    );

    p += "## 机器人结构（接线图）\n";
    let n_sql = m.structure_excerpt.len();
    if m.structure_excerpt.is_empty() {
        p += "(结构脚本不可读)\n";
    } else {
        p += &m.structure_excerpt;
    }

    p += "## 硬件变量\n";
    let n_hw = m.hardware_list.len();
    p += &m.hardware_list;

    p += &format!("## 可用动作脚本（目录 {}）\n", m.scripts_dir);
    let n_scripts = m.scripts_list.len();
    p += &m.scripts_list;

    p += "## 工作方式\n";
    p += "- 需要机器人行动时用 run_action_script 执行动作脚本，脚本名必须来自上面的清单。\n";
    p += "- 动作脚本的回执里会附带**驱动返回表**（器件读数，如传感器数值），\
          据此判断硬件当前状态，不要凭空假设读数。\n";
    p += "- 不清楚有哪些脚本或硬件时，先用 list_action_scripts / list_hardware 查询。\n";
    p += "- 需要核对某个结构表的定义或数据时，用 query_sql（SELECT * FROM 表名;），\
          它只读查询、不会改变任何状态；只看个别行时可加等值条件\
          （SELECT * FROM 表名 WHERE 列 = 值 [AND 列2 = 值2];，精确文本匹配）。\n";
    p += "- 一次只执行一个动作脚本，看清返回结果后再决定下一步。\n";
    p += "- 脚本报错时先读清原因（脚本名错、硬件未接、参数越界），不要盲目重复同一条。\n";
    if m.allow_shell {
        p += "- run_command 适合查看系统状态、日志与设备节点；驱动硬件请用 run_action_script。\n";
    }
    if m.allow_hot_sql {
        p += "- 需要给机器人**增加**硬件时用 apply_sql：CREATE TABLE 建表 + INSERT INTO 插行，\
              新器件立即上电；驱动脚本必须已存在于 modules/ 下（表名即模块名），\
              错则整批回滚、不留半成品。对照/查询请用 query_sql。\n";
        p += "- 需要**摘掉**某个器件时用 apply_sql 的 DELETE FROM 表 WHERE 列 = 值\
              （多条件用 AND；不写 WHERE 会删掉整张表）：器件会**当场断电**，这是\
              **不可逆**的操作，回执里此前的读数与状态都要当作已失效。被别的器件引用着的\
              变量会被拒绝并点名引用方。删除前先用 query_sql 确认 WHERE 会命中哪些行，\
              并**只删你确实要移除的那个**（宁可多查一次，也不要删错）。\n";
    }
    // 清单为空就一个字都不写——提示词里承诺一个不存在的工具，模型会反复尝试并浪费轮次
    if !m.readable_vars.is_empty() {
        p += &format!(
            "- 需要读数（传感器当前值、器件状态）时用 read_variables：可读变量为 {}。\
             它只读、不改变任何状态；清单之外的变量读不到，不要尝试。\n\
             - 需要**等某个读数满足条件**（超过阈值、发生变化）时用 wait_variable，\
             一次调用轮询到满足或超时——不要用多轮 read_variables 手工轮询。\
             超时是结果不是失败，按回执里的最后读数决定下一步。\n",
            m.readable_vars
        );
    }
    p += "- 用中文回答，结论简洁并说明依据。\n";

    if !prompt_pack.is_empty() {
        p += "\n\n";
        p += prompt_pack;
    }

    if p.len() > K_MAX_SYSTEM_PROMPT_BYTES {
        return Err(format!(
            "系统提示词超过 {K_MAX_SYSTEM_PROMPT_BYTES} 字节上限（实测 {} 字节）：\
             结构脚本头 {n_sql} / 硬件变量 {n_hw} / 动作脚本清单 {n_scripts} / 提示词包 {}。\
             请缩减 --prompt-file、--scripts-dir 下的脚本数量或结构脚本注释后重试",
            p.len(),
            prompt_pack.len()
        ));
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_replaces_invalid_runs() {
        assert_eq!(sanitize_utf8("正常文本".as_bytes()), "正常文本");
        // 单个非法字节 → 一个 U+FFFD，无计数标记
        assert_eq!(sanitize_utf8(b"a\xffb"), "a\u{FFFD}b");
        // 连续非法字节折叠成一个 U+FFFD + 计数标记
        let s = sanitize_utf8(b"a\xff\xfe\xfdb");
        assert!(s.starts_with("a\u{FFFD}"), "实际: {s}");
        assert!(s.contains("invalid UTF-8 bytes omitted"), "actual: {s}");
        assert!(s.ends_with('b'));
    }

    #[test]
    fn natural_sort_puts_2_before_10() {
        let mut names = vec!["10-b.md", "2-a.md", "1-z.md"];
        names.sort_by(|a, b| {
            if natural_name_less(a, b) {
                std::cmp::Ordering::Less
            } else if natural_name_less(b, a) {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        });
        assert_eq!(names, vec!["1-z.md", "2-a.md", "10-b.md"]);
        // 前导零按数值比较（02 == 2）：两个方向都为 false → 判定相等，
        // 由排序的稳定性保持原顺序（而不是字典序的 '0' < '2'）
        assert!(!natural_name_less("02-x.md", "2-x.md"));
        assert!(!natural_name_less("2-x.md", "02-x.md"));
        assert!(natural_name_less("2-x.md", "10-x.md"));
    }

    #[test]
    fn path_under_is_component_wise_not_prefix() {
        let root = Path::new("/srv/prompts");
        assert!(path_under(Path::new("/srv/prompts/a.md"), root));
        assert!(path_under(Path::new("/srv/prompts"), root));
        // 字符串前缀陷阱：/srv/prompts-evil 不是 /srv/prompts 的子路径
        assert!(!path_under(Path::new("/srv/prompts-evil/a.md"), root));
        assert!(!path_under(Path::new("/srv"), root));
    }

    #[test]
    fn system_prompt_conditions_follow_material_flags() {
        let m = PromptMaterial {
            robot_name: "relay-test".into(),
            structure_path: "robots/relay-test.sql".into(),
            scripts_dir: "scripts".into(),
            allow_shell: false,
            allow_hot_sql: false,
            structure_excerpt: "结构脚本 X 摘录：\n> line\n".into(),
            hardware_list: "硬件变量清单：\n> relay1\n".into(),
            scripts_list: "动作脚本清单：\n> relay-test.mt\n".into(),
            readable_vars: String::new(),
        };
        let p = build_system_prompt("LlmOpenAI", "llm0", "", &m).unwrap();
        assert!(p.contains("机器人结构脚本：robots/relay-test.sql"));
        assert!(p.contains("## 硬件变量"));
        // 定界块**原样**进提示词（不反转义、不裁剪）
        assert!(p.contains("> relay1"));
        // 未开的能力不写条件句（不承诺不存在的工具）
        assert!(!p.contains("run_command"));
        assert!(!p.contains("apply_sql"));
        assert!(!p.contains("read_variables"));
        assert!(!p.contains("wait_variable"));

        let m2 = PromptMaterial {
            allow_shell: true,
            allow_hot_sql: true,
            readable_vars: "light0, light1".into(),
            ..m.clone()
        };
        let p2 = build_system_prompt("LlmDeepSeek", "llm0", "包内容", &m2).unwrap();
        assert!(p2.contains("run_command"));
        assert!(p2.contains("apply_sql"));
        assert!(p2.contains("可读变量为 light0, light1"));
        assert!(p2.contains("wait_variable"));
        assert!(p2.ends_with("包内容"));
    }

    #[test]
    fn oversized_system_prompt_is_rejected_with_source_breakdown() {
        let m = PromptMaterial {
            structure_excerpt: "x".repeat(70 << 10),
            ..Default::default()
        };
        let err = build_system_prompt("LlmOpenAI", "llm0", "", &m).unwrap_err();
        assert!(err.contains("系统提示词超过"), "实际: {err}");
        assert!(err.contains("结构脚本头"), "实际: {err}");
    }

    #[test]
    fn context_material_requires_all_fields() {
        let ok_json = serde_json::json!({
            "robotName": "r", "structurePath": "p", "scriptsDir": "s",
            "allowShell": false, "allowHotSql": false, "hardwareCount": 2,
            "structureExcerpt": "a", "hardwareList": "b", "scriptsList": "c",
            "readableVars": ""
        });
        let ok: crate::protocol::Context = serde_json::from_value(ok_json).unwrap();
        assert!(PromptMaterial::from_context(&ok).is_ok());

        let bad_json = serde_json::json!({
            "robotName": "r", "structurePath": "p", "scriptsDir": "s",
            "allowShell": false, "allowHotSql": false, "hardwareCount": 2,
            "structureExcerpt": "a", "scriptsList": "c", "readableVars": ""
        });
        let err = serde_json::from_value::<crate::protocol::Context>(bad_json).unwrap_err();
        assert!(err.to_string().contains("hardwareList"), "实际: {err}");
    }
}

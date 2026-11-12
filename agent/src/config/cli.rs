//! config/cli.rs —— 命令行层：Cli 结构 + argv 解析 + 用法文本
//! （2026-09-29 B3 拆自 config.rs；语义与报错文案逐字保持）。

/// 命令行原文（**只解析、不校验**；校验与合流在 [`super::build`]）。
#[derive(Debug, Default)]
pub struct Cli {
    pub socket: String,
    pub llm_config: String,
    pub llm_driver: String,
    pub llm_var: String,
    pub llm_endpoint: String,
    pub llm_model: String,
    pub llm_timeout: String,
    pub llm_max_tokens: String,
    pub llm_max_turns: String,
    pub llm_task_timeout: String,
    /// `--llm-no-stream`：模型输出退回整段阻塞模式（缺省流式）。
    pub llm_no_stream: bool,
    pub prompt_files: Vec<String>,
    pub audit_log: String,
    /// 会话持久化落盘路径（批次 D）：只有**命令行给出**的路径才能用于 `--resume`
    /// 读取；配置文件的 `session_file` 只能用于写入（见 [`super::build`] 的判据）。
    pub session_file: String,
    pub resume: bool,
    /// `--new-session`：不走缺省布局的「续接上一次」，强制新开一段对话。
    pub new_session: bool,
    pub task: String,
    /// `--allow-host`（可重复）：http_fetch 的出站白名单；空 = 不提供该工具。
    /// **只有命令行入口**——放宽能力的字段，配置文件不能给（同 C++ `--fs-root`）。
    pub allow_hosts: Vec<String>,
    pub http_fetch_timeout: String,
    pub http_fetch_max_bytes: String,
    /// `--record`：开启录制（缺省布局 `$MYBOT_HOME/robots/<机器人>/recordings`）。
    /// **只有命令行入口**——录制把完整上下文与图片写到磁盘，敏感面扩大只认
    /// 操作者亲手给的命令行（判据同 `--allow-host`）。
    pub record: bool,
    /// `--record-dir <目录>`：显式录制根（与 `--record` 互斥）。
    pub record_dir: String,
    pub record_max_bytes: String,
    pub check_config: bool,
    pub help: bool,
    pub version: bool,
}

/// 解析 argv（不含程序名）。未知选项 → Err（调用方按退出码 2 处理）。
pub fn parse_args(args: &[String]) -> Result<Cli, String> {
    let mut cli = Cli::default();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        // 取下一个位置参数作为该选项的值；缺值立刻报错（不猜、不回落）。
        let mut take = |name: &str| -> Result<String, String> {
            i += 1;
            match args.get(i) {
                Some(v) => Ok(v.clone()),
                None => Err(format!("选项 {name} 需要一个值")),
            }
        };
        match a {
            "--socket" => cli.socket = take("--socket")?,
            "--llm-config" => cli.llm_config = take("--llm-config")?,
            "--llm-driver" => cli.llm_driver = take("--llm-driver")?,
            "--llm-var" => cli.llm_var = take("--llm-var")?,
            "--llm-endpoint" => cli.llm_endpoint = take("--llm-endpoint")?,
            "--llm-model" => cli.llm_model = take("--llm-model")?,
            "--llm-timeout" => cli.llm_timeout = take("--llm-timeout")?,
            "--llm-max-tokens" => cli.llm_max_tokens = take("--llm-max-tokens")?,
            "--llm-max-turns" => cli.llm_max_turns = take("--llm-max-turns")?,
            "--llm-task-timeout" => cli.llm_task_timeout = take("--llm-task-timeout")?,
            "--llm-no-stream" => cli.llm_no_stream = true,
            "--prompt-file" => {
                let v = take("--prompt-file")?;
                cli.prompt_files.push(v);
            }
            "--audit-log" => cli.audit_log = take("--audit-log")?,
            "--session-file" => cli.session_file = take("--session-file")?,
            "--resume" => cli.resume = true,
            "--new-session" => cli.new_session = true,
            "--task" => cli.task = take("--task")?,
            "--allow-host" => {
                let v = take("--allow-host")?;
                cli.allow_hosts.push(v);
            }
            "--http-fetch-timeout" => cli.http_fetch_timeout = take("--http-fetch-timeout")?,
            "--http-fetch-max-bytes" => cli.http_fetch_max_bytes = take("--http-fetch-max-bytes")?,
            "--record" => cli.record = true,
            "--record-dir" => cli.record_dir = take("--record-dir")?,
            "--record-max-bytes" => cli.record_max_bytes = take("--record-max-bytes")?,
            "--check-config" => cli.check_config = true,
            "--help" | "-h" => cli.help = true,
            "--version" | "-V" => cli.version = true,
            _ => {
                return Err(format!(
                    "未知选项 '{a}'（用 --help 看用法；配置文件拼错字段名同样会被拒绝）"
                ));
            }
        }
        i += 1;
    }
    Ok(cli)
}

/// 用法文本（`--help`）。
pub fn usage() -> String {
    let mut s = String::new();
    s += "mybot-agent —— bot4cj 的 Rust agent（rig 驱动；对下经 AF_UNIX 帧通道调用\n";
    s += "                `mybot --mcp-backend` 的工具层）\n\n";
    s += "用法: mybot-agent --socket <路径> [选项] [--task \"<任务>\"]\n\n";
    s += "必填:\n";
    s += "  --socket <路径>        后端 AF_UNIX socket（mybot --mcp-backend --mcp-socket 建的那条）\n";
    s += "  --llm-endpoint <URL>   模型接入点（完整 URL，如 http://127.0.0.1:8080/v1/chat/completions）\n";
    s += "  --llm-model <名>       模型名（rig 需要显式模型串，无内置缺省）\n";
    s += "  API key                环境变量 BOT4CJ_LLM_KEY（也兼容 ROBOT_AGENT_API_KEY /\n";
    s += "                         DEEPSEEK_API_KEY），或配置文件 api_key / api_key_file\n";
    s += "                         （**没有** --llm-key 选项：argv 对同用户进程可读）\n\n";
    s += "LLM 层（命令行 > 环境变量 > 配置文件 > 内置缺省）:\n";
    s += "  --llm-config <路径|none>  配置文件；none = 本次不读（缺省查找 ./mybot.llm.json、\n";
    s += "                            ./mybot.llm.conf.json、$HOME/.config/mybot/llm.json）\n";
    s += "  --llm-driver <表名>       协议驱动表名：LlmOpenAI | LlmDeepSeek | LlmAnthropic\n";
    s += "  --llm-var <名>            驱动变量名（仅用于提示词与提示符展示）\n";
    s += "  --llm-timeout <秒>        单次模型调用超时（1..600，缺省 180）\n";
    s += "  --llm-max-tokens <n>      单次响应上限（1..200000，缺省 4096）\n";
    s += "  --llm-max-turns <n>       模型调用预算（1..100，缺省 8）\n";
    s += "  --llm-task-timeout <秒>   单任务墙钟预算（0..86400，0 = 不限，缺省 900）\n";
    s += "  --llm-no-stream           模型输出退回整段阻塞模式（缺省流式：逐 delta 打到 stdout；\n";
    s += "                            也可用配置文件的 stream 字段，布尔）\n\n";
    s += "出站 HTTP（http_fetch 工具，缺省不提供；只有命令行入口，配置文件不能开）:\n";
    s += "  --allow-host <主机[:端口]>  放行一个出站主机并注册 http_fetch（可重复；精确匹配，\n";
    s += "                            无通配；不写端口只放行 http/https 缺省端口；只发 GET、\n";
    s += "                            不跟随重定向、不走系统代理）\n";
    s += "  --http-fetch-timeout <秒>    单次请求超时（1..120，缺省 10）\n";
    s += "  --http-fetch-max-bytes <n>   响应体上限（1..1048576，缺省 65536）\n\n";
    s += "录制（完整上下文采集，微调数据用 scripts/record_export.py 导出；缺省关闭；\n";
    s += "只有命令行入口，配置文件不能开）:\n";
    s += "  --record                 开启录制，段落在 $MYBOT_HOME/robots/<机器人>/recordings/\n";
    s += "                           （$MYBOT_HOME 缺省 $HOME/.mybot）；每个录制段一个目录：\n";
    s += "                           meta.json + system.txt + events.jsonl + images/（图片本体）\n";
    s += "  --record-dir <目录>       显式录制根（与 --record 互斥；不依赖状态目录）\n";
    s += "  --record-max-bytes <n>    录制图片仓总量上限（0..68719476736，0 = 不限，缺省 0）；\n";
    s += "                           超限响亮降级为仅元数据（文本事件不受限）\n\n";
    s += "其它:\n";
    s += "  --prompt-file <路径>   提示词包（文件或目录；可重复；命令行给出即整体覆盖配置文件列表）\n";
    s += "  --audit-log <路径|->   审计轨迹（JSON Lines；\"-\" = stderr；缺省关闭）\n";
    s += "  --session-file <路径>  会话持久化落到这个文件（JSON Lines；也可用配置文件\n";
    s += "                         的 session_file 字段，但该来源只能写入，不能 --resume）\n";
    s += "  --resume               续写 --session-file 指向的既有会话（该路径必须来自命令行，\n";
    s += "                         且文件必须已存在；三道判据全过才恢复，见 docs/agent.md）\n";
    s += "  --new-session          不续接上一次对话，强制新开一段（只影响缺省落点）\n";
    s += "  会话缺省落点：         不给 --session-file 时，对话历史落在\n";
    s += "                         $MYBOT_HOME/robots/<机器人>/sessions/<UTC 时间戳>.jsonl\n";
    s += "                         （$MYBOT_HOME 缺省 $HOME/.mybot），并**默认续接**上一次\n";
    s += "                         那一段；续接不上（提示词/工具集变了、文件损坏）时告警一次\n";
    s += "                         并自动新开一段，旧段原样保留。\n";
    s += "  --task \"<任务>\"        一次性执行后退出（不给则进交互 REPL）\n";
    s += "  --check-config         只校验并打印配置摘要后退出（0 = 通过）\n";
    s += "  --help / --version\n";
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **测试侧独立登记的一份选项名册**：与 `parse_args` 的 match 臂、与 `usage()`
    /// 的文本是三处事实源。任一处增删而另两处没跟上，下面两条守门就会红——
    /// 这正是「加了选项忘了写文档」和「文档写了选项却没实现」两类漂移的落点。
    const VALUE_OPTIONS: &[&str] = &[
        "--socket",
        "--llm-config",
        "--llm-driver",
        "--llm-var",
        "--llm-endpoint",
        "--llm-model",
        "--llm-timeout",
        "--llm-max-tokens",
        "--llm-max-turns",
        "--llm-task-timeout",
        "--prompt-file",
        "--audit-log",
        "--session-file",
        "--task",
        "--allow-host",
        "--http-fetch-timeout",
        "--http-fetch-max-bytes",
        "--record-dir",
        "--record-max-bytes",
    ];
    const FLAG_OPTIONS: &[&str] = &[
        "--llm-no-stream",
        "--resume",
        "--new-session",
        "--record",
        "--check-config",
        "--help",
        "--version",
    ];
    /// 短别名（`--help` / `--version` 的同义写法）。
    const SHORT_ALIASES: &[&str] = &["-h", "-V"];

    fn all_options() -> Vec<&'static str> {
        VALUE_OPTIONS
            .iter()
            .chain(FLAG_OPTIONS.iter())
            .copied()
            .collect()
    }

    /// 每个带值选项都把值落到**自己那一个字段**上：给每个选项喂一个由选项名
    /// 派生的独特值，再逐字段核对。这样「`--llm-max-turn` 的臂写成了
    /// `cli.llm_max_tokens`」这类复制粘贴串线会立刻暴露（两个字段各拿到对方的值）。
    #[test]
    fn every_option_lands_in_its_own_field() {
        let mut argv: Vec<String> = Vec::new();
        for o in VALUE_OPTIONS {
            argv.push((*o).to_string());
            argv.push(o.trim_start_matches('-').to_string());
        }
        // 可重复选项再来一次，验证累积而非覆盖
        argv.push("--prompt-file".into());
        argv.push("second.md".into());
        argv.push("--allow-host".into());
        argv.push("b.example".into());
        for f in FLAG_OPTIONS {
            argv.push((*f).to_string());
        }
        let cli = parse_args(&argv).unwrap();
        assert_eq!(cli.socket, "socket");
        assert_eq!(cli.llm_config, "llm-config");
        assert_eq!(cli.llm_driver, "llm-driver");
        assert_eq!(cli.llm_var, "llm-var");
        assert_eq!(cli.llm_endpoint, "llm-endpoint");
        assert_eq!(cli.llm_model, "llm-model");
        assert_eq!(cli.llm_timeout, "llm-timeout");
        assert_eq!(cli.llm_max_tokens, "llm-max-tokens");
        assert_eq!(cli.llm_max_turns, "llm-max-turns");
        assert_eq!(cli.llm_task_timeout, "llm-task-timeout");
        assert_eq!(cli.prompt_files, vec!["prompt-file", "second.md"]);
        assert_eq!(cli.audit_log, "audit-log");
        assert_eq!(cli.session_file, "session-file");
        assert_eq!(cli.task, "task");
        assert_eq!(cli.allow_hosts, vec!["allow-host", "b.example"]);
        assert_eq!(cli.http_fetch_timeout, "http-fetch-timeout");
        assert_eq!(cli.http_fetch_max_bytes, "http-fetch-max-bytes");
        assert_eq!(cli.record_dir, "record-dir");
        assert_eq!(cli.record_max_bytes, "record-max-bytes");
        assert!(cli.llm_no_stream && cli.resume && cli.new_session && cli.record);
        assert!(cli.check_config);
        assert!(cli.help && cli.version);
    }

    /// 短别名与长选项等价（只置标志、不吃值）。
    #[test]
    fn short_aliases_set_the_same_flags() {
        let h = parse_args(&["-h".to_string()]).unwrap();
        assert!(h.help && !h.version);
        let v = parse_args(&["-V".to_string()]).unwrap();
        assert!(v.version && !v.help);
        assert_eq!(SHORT_ALIASES.len(), 2);
    }

    /// 双向守门：名册里的每个选项都要在 `--help` 里出现（漏文档 = 用户发现不了）；
    /// `--help` 里出现的每个 `--xxx` 也都要被 `parse_args` 认得（文档承诺了却没
    /// 实现 = 用户照着抄就吃「未知选项」退出码 2）。
    #[test]
    fn usage_and_parse_args_agree_on_the_option_set() {
        let text = usage();
        let known = all_options();
        for o in &known {
            assert!(
                text.contains(*o),
                "--help 未记录选项 {o}（补文档，或从名册里删掉）"
            );
        }
        // 用法文本里合法出现、但**不是本进程选项**的三个串：
        //   --mcp-backend / --mcp-socket 是后端 mybot 自己的命令行（解释 --socket 时引用）；
        //   --llm-key    是**刻意不存在**的选项——文本明说「没有 --llm-key」，
        //                因为 argv 对同用户进程可读，密钥不给命令行入口。
        const NOT_OUR_OPTIONS: &[&str] = &["--mcp-backend", "--mcp-socket", "--llm-key"];
        for tok in text
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '-')
            .filter(|t| t.starts_with("--"))
        {
            if known.contains(&tok) || NOT_OUR_OPTIONS.contains(&tok) {
                continue;
            }
            panic!("--help 记录了 parse_args 不认的选项 {tok}（实现它，或从用法文本里去掉）");
        }
    }

    /// 缺值报错必须**点名是哪个选项**：用户面对一长串 argv，只说「需要一个值」
    /// 等于没说。逐个带值选项验证。
    #[test]
    fn a_missing_value_names_the_option() {
        for o in VALUE_OPTIONS {
            let err = parse_args(&[(*o).to_string()]).unwrap_err();
            assert!(err.contains(*o), "{o} 缺值时报错没点名: {err}");
            assert!(err.contains("需要一个值"), "{o}: {err}");
        }
    }

    /// 未知选项与拼错字段名同罪：报错要把「用 --help」和「配置文件拼错字段名
    /// 同样会被拒绝」都说到（后者是这条报错最容易漏读的一半）。
    #[test]
    fn unknown_option_points_at_help_and_at_config_typos() {
        let err = parse_args(&["--llm-max-turn".to_string()]).unwrap_err();
        assert!(err.contains("未知选项 '--llm-max-turn'"), "{err}");
        assert!(err.contains("--help"), "{err}");
        assert!(err.contains("配置文件拼错字段名"), "{err}");
    }
}

//! 配置摘要渲染（`--check-config` 输出；拆自 config/mod.rs，2026-10-01）。
//!
//! **只渲染、不判定**（校验单点在 mod.rs 的 build），密钥**只报来源不报值**
//! （与 C++ `summarizeAgentConfig` 同契约）。

use super::{Config, SessionPathSource};

/// 配置摘要（`--check-config`）：**只渲染、不判定**（校验单点在 [`build`]），
/// 密钥**只报来源不报值**（与 C++ `summarizeAgentConfig` 同契约）。
pub fn summarize(cfg: &Config) -> String {
    let or_none = |s: &str, fallback: &str| {
        if s.is_empty() {
            fallback.to_string()
        } else {
            s.to_string()
        }
    };
    let key_source = match cfg.api_key_source {
        "env" => "环境变量",
        "config_inline" => "配置文件 api_key 字段",
        "config_file" => "配置文件 api_key_file",
        _ => "未解析到",
    };
    let mut s = String::new();
    s += "配置校验通过：\n";
    s += &format!(
        "  配置文件    : {}\n",
        or_none(&cfg.config_path, "(未使用)")
    );
    s += &format!("  后端 socket : {}\n", cfg.socket);
    s += &format!("  协议驱动    : {}（变量 {}）\n", cfg.driver, cfg.llm_var);
    s += &format!("  模型        : {}\n", cfg.model);
    s += &format!("  接入点      : {}\n", cfg.endpoint);
    s += &format!(
        "  采样        : max_tokens={} temperature={} top_p={} timeout={}s\n",
        cfg.max_tokens, cfg.temperature, cfg.top_p, cfg.timeout_sec
    );
    s += &format!(
        "  轮次预算    : max_turns={}（rig 的模型调用预算，含重试）\n",
        cfg.max_turns
    );
    s += &format!(
        "  输出模式    : {}\n",
        if cfg.stream {
            "流式（逐 delta 打到 stdout）"
        } else {
            "阻塞（整段输出；--llm-no-stream 或配置文件 stream=false）"
        }
    );
    s += &format!("  API key     : {}（值不显示）\n", key_source);
    s += &format!(
        "  提示词包    : {} 项，{} 字节\n",
        cfg.prompt_files.len(),
        cfg.prompt_pack.len()
    );
    s += &format!(
        "  墙钟预算    : {}（单任务）\n",
        if cfg.max_task_seconds == 0 {
            "不限".to_string()
        } else {
            format!("{} 秒", cfg.max_task_seconds)
        }
    );
    // 字节预算与重试（批次 C 起生效；只渲染、不判定）
    let bytes = |n: i64| {
        if n == 0 {
            "不限".to_string()
        } else {
            format!("{n} 字节")
        }
    };
    s += &format!(
        "  历史/任务预算: 历史 {} / 任务文本 {} / 任务图片 {}（单轮调用上限 {} 条）\n",
        bytes(cfg.max_history_bytes),
        bytes(cfg.max_task_tool_result_bytes),
        bytes(cfg.max_task_image_bytes),
        if cfg.max_calls_per_round == 0 {
            "不限".to_string()
        } else {
            cfg.max_calls_per_round.to_string()
        }
    );
    s += &format!(
        "  历史摘要    : {}\n",
        if cfg.max_history_bytes == 0 {
            "不适用（历史不裁剪）".to_string()
        } else if cfg.history_summary {
            format!(
                "开（被裁任务块压成摘要，正文上限 {} 字节）",
                cfg.max_summary_bytes
            )
        } else {
            "关（history_summary=false：被裁任务块直接丢弃）".to_string()
        }
    );
    s += &format!(
        "  网络重试    : 尝试 {} 次（含首次），退避基础 {}ms（指数增长，单次钳到 60s）\n",
        cfg.max_retries, cfg.retry_backoff_ms
    );
    s += &format!("  审计轨迹    : {}\n", or_none(&cfg.audit_log, "(未开启)"));
    s += &format!(
        "  录制        : {}\n",
        if !cfg.record_enabled {
            "(未开启：--record / --record-dir)".to_string()
        } else {
            let cap = if cfg.record_max_image_bytes == 0 {
                "图片不限量".to_string()
            } else {
                format!("图片上限 {} 字节", cfg.record_max_image_bytes)
            };
            if !cfg.record_dir.is_empty() {
                format!("{}（显式根；{cap}）", cfg.record_dir)
            } else {
                format!("$MYBOT_HOME/robots/<机器人>/recordings/（缺省布局；{cap}）")
            }
        }
    );
    s += &format!(
        "  出站 HTTP   : {}\n",
        if cfg.allow_hosts.is_empty() {
            "(未开启：无 http_fetch 工具)".to_string()
        } else {
            format!(
                "http_fetch 放行 {}（超时 {}s，响应体上限 {} 字节）",
                cfg.allow_hosts
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", "),
                cfg.http_fetch_timeout_sec,
                cfg.http_fetch_max_bytes
            )
        }
    );
    // 状态目录与落点：`--check-config` 在连后端之前返回，此刻还拿不到机器人名，
    // 故只报**根与模式**，不臆造具体落点（具体落点由启动时的 stderr 行给出）。
    let dir_source = match cfg.state_dir_source {
        "env" => "环境变量 MYBOT_HOME",
        "home" => "家目录",
        _ => "不可用",
    };
    s += &format!(
        "  状态目录    : {}{}\n",
        or_none(&cfg.state_dir, "(不可用)"),
        if cfg.state_dir_ok {
            format!("（来源 {dir_source}）")
        } else {
            String::new()
        }
    );
    s += &format!(
        "  会话持久化  : {}\n",
        match cfg.session_path_source {
            SessionPathSource::Cli if cfg.resume => format!("{}（--resume）", cfg.session_file),
            SessionPathSource::Cli => cfg.session_file.clone(),
            SessionPathSource::Config =>
                format!("{}（配置文件来源，只写不可读）", cfg.session_file),
            SessionPathSource::Default if !cfg.state_dir_ok =>
                "(未开启：无家目录，可用 MYBOT_HOME 指定)".to_string(),
            SessionPathSource::Default if cfg.new_session =>
                format!("{}（--new-session：强制新开一段）", cfg.state_dir),
            SessionPathSource::Default => format!("{}（缺省按机器人续接上一次）", cfg.state_dir),
        }
    );
    if !cfg.config_warning.is_empty() {
        s += &format!("  配置告警    : {}\n", cfg.config_warning);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{build, Cli, ENV_LOCK};

    const SECRET: &str = "sk-SUMMARIZE-DO-NOT-PRINT-1a2b3c";

    /// 造一份生效配置：走真 `build`（密钥经环境变量给），再清掉环境变量。
    /// 单测默认多线程，与其它动密钥链 env 的用例经 `config::ENV_LOCK` 互斥。
    fn sample() -> Config {
        let _env = ENV_LOCK.lock().unwrap();
        for k in ["BOT4CJ_LLM_KEY", "ROBOT_AGENT_API_KEY", "DEEPSEEK_API_KEY"] {
            std::env::remove_var(k);
        }
        std::env::set_var("BOT4CJ_LLM_KEY", SECRET);
        let cli = Cli {
            socket: "/tmp/x.sock".into(),
            llm_config: "none".into(),
            llm_endpoint: "http://127.0.0.1:9/v1/chat/completions".into(),
            llm_model: "m".into(),
            ..Cli::default()
        };
        let cfg = build(&cli).unwrap();
        std::env::remove_var("BOT4CJ_LLM_KEY");
        cfg
    }

    /// `--check-config` 的摘要**只报密钥来源、绝不报值**——这条与 C++
    /// `summarizeAgentConfig` 同契约，且是 `Secret` 包装之外唯一没被
    /// `config_debug_and_display_never_leak_the_api_key` 覆盖的渲染面。
    /// 反向验证（2026-10-04）：把 `key_source` 那一行换成
    /// `cfg.api_key.expose()` 后本用例立即转红（四种来源全泄），还原复绿。
    #[test]
    fn summarize_reports_key_source_but_never_the_key_value() {
        let mut cfg = sample();
        for source in ["env", "config_inline", "config_file", "unresolved"] {
            cfg.api_key_source = source;
            let s = summarize(&cfg);
            assert!(
                !s.contains(SECRET) && !s.contains("SUMMARIZE-DO-NOT-PRINT"),
                "来源 {source} 的摘要泄密: {s}"
            );
            assert!(s.contains("值不显示"), "应声明「值不显示」: {s}");
        }
        // 来源名确实被渲染（只报来源）
        cfg.api_key_source = "config_file";
        assert!(summarize(&cfg).contains("api_key_file"));
    }

    /// 会话持久化那一栏有六个分支（来源 × --resume × state_dir_ok × --new-session），
    /// 逐条钉住渲染文本——它们直接决定用户能否看懂「这次对话落到哪、能不能续接」。
    #[test]
    fn summarize_renders_every_session_path_branch() {
        let mut cfg = sample();
        cfg.state_dir = "/home/u/.mybot".into();
        cfg.state_dir_ok = true;

        // 1) Cli + --resume
        cfg.session_path_source = SessionPathSource::Cli;
        cfg.session_file = "/tmp/s.jsonl".into();
        cfg.resume = true;
        assert!(summarize(&cfg).contains("/tmp/s.jsonl（--resume）"));

        // 2) Cli 无 --resume
        cfg.resume = false;
        let s = summarize(&cfg);
        assert!(
            s.contains("/tmp/s.jsonl") && !s.contains("（--resume）"),
            "{s}"
        );

        // 3) 配置文件来源：只写不可读
        cfg.session_path_source = SessionPathSource::Config;
        assert!(summarize(&cfg).contains("配置文件来源，只写不可读"));

        // 4) 缺省来源但无家目录：未开启
        cfg.session_path_source = SessionPathSource::Default;
        cfg.state_dir_ok = false;
        assert!(summarize(&cfg).contains("未开启：无家目录"));

        // 5) 缺省来源 + --new-session
        cfg.state_dir_ok = true;
        cfg.new_session = true;
        assert!(summarize(&cfg).contains("--new-session：强制新开一段"));

        // 6) 缺省来源、续接上一次
        cfg.new_session = false;
        assert!(summarize(&cfg).contains("缺省按机器人续接上一次"));
    }

    /// 三处字节预算与墙钟预算的 `0` 都渲染成「不限」而非「0 字节 / 0 秒」——
    /// 0 在这套配置里是「关闭该项限制」的哨兵值，摘要不能把它说成一个具体上限。
    #[test]
    fn summarize_renders_zero_budgets_as_unlimited() {
        let mut cfg = sample();
        cfg.max_task_seconds = 0;
        cfg.max_history_bytes = 0;
        cfg.max_task_tool_result_bytes = 0;
        cfg.max_task_image_bytes = 0;
        cfg.max_calls_per_round = 0;
        let s = summarize(&cfg);
        assert!(s.contains("墙钟预算    : 不限"), "{s}");
        assert!(
            s.contains("历史 不限 / 任务文本 不限 / 任务图片 不限"),
            "{s}"
        );
        assert!(s.contains("单轮调用上限 不限"), "{s}");
        // max_history_bytes == 0 时历史摘要栏走「不适用」分支，不谈开关
        assert!(s.contains("历史摘要    : 不适用（历史不裁剪）"), "{s}");
    }

    /// 非零预算按原值渲染单位，且历史摘要栏在开/关两态各自说清被裁块的去向。
    #[test]
    fn summarize_renders_nonzero_budgets_and_history_summary_states() {
        let mut cfg = sample();
        cfg.max_history_bytes = 4 << 20;
        cfg.max_summary_bytes = 8192;
        cfg.history_summary = true;
        assert!(summarize(&cfg).contains("开（被裁任务块压成摘要，正文上限 8192 字节）"));
        cfg.history_summary = false;
        assert!(summarize(&cfg).contains("关（history_summary=false：被裁任务块直接丢弃）"));
    }

    /// 摘要头一行固定为「配置校验通过」——它是 `--check-config` 退出码 0 的
    /// 人类可读对应物；顺带钉住 config_warning 非空时才多出一栏。
    #[test]
    fn summarize_leads_with_pass_and_shows_warning_only_when_present() {
        let mut cfg = sample();
        cfg.config_warning = String::new();
        let s = summarize(&cfg);
        assert!(s.starts_with("配置校验通过：\n"), "{s}");
        assert!(!s.contains("配置告警"), "{s}");
        cfg.config_warning = "密钥文件权限过松".into();
        assert!(summarize(&cfg).contains("配置告警    : 密钥文件权限过松"));
    }
}

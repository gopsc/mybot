//! provider.rs —— rig 客户端装配（协议驱动表名 → provider 客户端）
//!
//! C++ 侧把 `--llm-driver` 当 `modules/<表名>.lua` 加载（任意自定义驱动），Rust 侧
//! 只能吃 rig 内置的三族协议——**如实偏差**：表名不认识就明确报错，不静默换协议。
//!
//! 接入点语义（关键）：C++ 的 `--llm-endpoint` 是**完整请求 URL**
//! （`wire.perform(r.endpoint, ...)` 直接 POST 过去，如
//! `http://127.0.0.1:8080/v1/chat/completions`），rig 要的是 base_url 且自己拼
//! 固定路径。故：
//!   * OpenAI 兼容族（LlmOpenAI / LlmDeepSeek）：剥掉尾部 `/chat/completions`
//!     （rig 的 `completion_path` 恒为 `/chat/completions`）；
//!   * Anthropic：实际请求与摘要共用 rig 的 URL 规范化；客户端仍接收原始 endpoint。
//!
//! 密钥：只经 `.api_key()` 进请求头（Bearer / x-api-key），**从不进 argv、不进日志**
//! （与 C++ 同口径；配置文件与 `--check-config` 只报来源）。

use std::sync::Arc;

use anyhow::{Context, Result};
use rig_agent::{Agent, AgentBuilder};
use rig_core::client::{CompletionClient, DebugExt, Provider};
use rig_core::providers::openai::completion::OpenAICompatibleProvider;
use rig_core::providers::{anthropic, deepseek, openai};
use serde_json::json;

use crate::bridge::{self, Bridge};
use crate::config::Config;
use crate::hook::{HookState, SessionHook};
use crate::model::{BudgetModel, RawStream};
use crate::toolspec::ToolSpec;

#[derive(Debug, Clone, Copy)]
struct DeepSeekChat;

impl Provider for DeepSeekChat {
    type Builder = deepseek::DeepSeekExtBuilder;
    const VERIFY_PATH: &'static str = deepseek::DeepSeekExt::VERIFY_PATH;
}

impl DebugExt for DeepSeekChat {}

impl OpenAICompatibleProvider for DeepSeekChat {
    const PROVIDER_NAME: &'static str = "deepseek";
    const EMITS_COMPLETE_SINGLE_CHUNK_TOOL_CALLS: bool = true;
    const SUPPORTS_RESPONSE_FORMAT: bool = false;
    type StreamingUsage = deepseek::Usage;
    // rig 0.42 的 DeepSeek 响应误要求 tool.index 和非 null content；共用标准解析器。
    type Response = openai::completion::CompletionResponse;

    fn finalize_request_body(
        &self,
        body: &mut serde_json::Value,
    ) -> Result<(), rig_core::completion::CompletionError> {
        deepseek::DeepSeekExt.finalize_request_body(body)
    }
}

/// rig 内置的三族协议（对应 C++ `modules/` 里的三张表）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Driver {
    OpenAi,
    DeepSeek,
    Anthropic,
}

impl Driver {
    /// 表名 → 协议族。不在三张内置表里的（含自定义 Lua 驱动）明确报错。
    pub fn from_table(table: &str) -> Result<Self, String> {
        match table {
            "LlmOpenAI" => Ok(Driver::OpenAi),
            "LlmDeepSeek" => Ok(Driver::DeepSeek),
            "LlmAnthropic" => Ok(Driver::Anthropic),
            other => Err(format!(
                "不支持的协议驱动表名 '{other}'：Rust agent 内置 LlmOpenAI（OpenAI 兼容）、\
                 LlmDeepSeek、LlmAnthropic 三族；modules/<表名>.lua 那类自定义 Lua 驱动\
                 只在 C++ agent 可用（--llm-driver 或配置文件的 driver 字段）"
            )),
        }
    }

    /// rig 在 base_url 之外固定拼接的请求路径。
    pub fn request_path(self) -> &'static str {
        match self {
            Driver::OpenAi | Driver::DeepSeek => "/chat/completions",
            Driver::Anthropic => "/v1/messages",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Driver::OpenAi => "LlmOpenAI",
            Driver::DeepSeek => "LlmDeepSeek",
            Driver::Anthropic => "LlmAnthropic",
        }
    }
}

/// 完整接入点 → rig 的 base_url（见模块头的折算规则）。
pub fn base_url_from_endpoint(endpoint: &str, driver: Driver) -> String {
    let trimmed = endpoint.trim_end_matches('/');
    if driver == Driver::Anthropic {
        return anthropic::client::normalize_anthropic_base_url(trimmed);
    }
    trimmed
        .strip_suffix("/chat/completions")
        .unwrap_or(trimmed)
        .to_string()
}

/// 装配产物：agent（可反复跑轮次）+ 事实（驱动、实际请求 URL）。
pub struct Backend {
    pub agent: Agent,
    pub driver: Driver,
    /// 实际请求 URL（base_url + 驱动固定路径）：`--check-config` 与启动提示用，
    /// 免得「接入点写错了路径」到第一次调用才暴露。
    pub effective_url: String,
    /// 模型输出走流式面（逐 delta）还是阻塞面（整段）。
    pub stream: bool,
    /// 定稿的系统提示词：每轮若有历史摘要，repl.rs 以它为底拼出本轮的 preamble。
    pub preamble: String,
}

/// 按配置装配 agent（工具表来自后端 `tool.list`，系统提示词来自 `prompt`）。
///
/// `state` 是循环层共享状态：既进模型装饰器（图片注入/超时/重试）与钩子
/// （墙钟/单轮上限/回滚边界），也进桥（任务内预算降级）。
pub fn build(
    cfg: &Config,
    specs: Vec<ToolSpec>,
    bridge: &Arc<Bridge>,
    state: Arc<HookState>,
    preamble: &str,
) -> Result<Backend> {
    let driver = Driver::from_table(&cfg.driver).map_err(anyhow::Error::msg)?;
    let base = base_url_from_endpoint(&cfg.endpoint, driver);
    let tools = specs
        .into_iter()
        .map(|spec| bridge::dynamic_tool(spec, bridge))
        .collect::<Vec<_>>();

    // 三族各装配一个客户端；模型串与采样参数走同一套 assemble。
    let agent = match driver {
        Driver::OpenAi => {
            let client = openai::CompletionsClient::builder()
                .api_key(cfg.api_key.expose().to_string())
                .base_url(&base)
                .build()
                .context("装配 OpenAI 兼容客户端（LlmOpenAI）")?;
            assemble(
                client.completion_model(&cfg.model),
                cfg,
                state,
                tools,
                preamble,
            )
        }
        Driver::DeepSeek => {
            let client = deepseek::Client::builder()
                .api_key(cfg.api_key.expose().to_string())
                .base_url(&base)
                .build()
                .context("装配 DeepSeek 客户端（LlmDeepSeek）")?;
            assemble(
                openai::completion::GenericCompletionModel::new(
                    client.with_ext(DeepSeekChat),
                    &cfg.model,
                ),
                cfg,
                state,
                tools,
                preamble,
            )
        }
        Driver::Anthropic => {
            let client = anthropic::Client::builder()
                .api_key(cfg.api_key.expose().to_string())
                .base_url(&cfg.endpoint)
                .build()
                .context("装配 Anthropic 客户端（LlmAnthropic）")?;
            assemble(
                client.completion_model(&cfg.model),
                cfg,
                state,
                tools,
                preamble,
            )
        }
    };

    Ok(Backend {
        agent,
        driver,
        effective_url: format!("{base}{}", driver.request_path()),
        stream: cfg.stream,
        preamble: preamble.to_string(),
    })
}

/// 单点装配：模型装饰器（图片注入/超时/重试）+ 系统提示词 + 采样 + 轮次预算 +
/// 循环层钩子（墙钟两判定点/单轮上限/回滚边界）+ 动态工具。
fn assemble<M>(
    model: M,
    cfg: &Config,
    state: Arc<HookState>,
    tools: Vec<rig_agent::tool::DynamicTool>,
    preamble: &str,
) -> Agent
where
    M: rig_core::completion::CompletionModel + RawStream + Send + Sync + 'static,
{
    // 附加参数（rig 会把它们平铺进请求体，与 C++ 驱动发的位置一致）：
    //   * top_p 恒发；
    //   * reasoning_effort 有值就**原样透传**——本进程不校验语义、不改写，
    //     网关/模型不认识时由那一侧决定忽略或报错（C++ 的驱动同样是原样发）。
    let mut extra = serde_json::Map::new();
    extra.insert("top_p".to_string(), json!(cfg.top_p));
    if !cfg.reasoning_effort.is_empty() {
        extra.insert("reasoning_effort".to_string(), json!(cfg.reasoning_effort));
    }
    // 模型装饰器：图片后注 + 单次调用超时 + 网络重试（U-1）。重试在装饰器内部完成，
    // 不占 rig 的模型调用预算（default_max_turns 仍按模型调用计）。
    let model = BudgetModel::new(
        model,
        Arc::clone(&state),
        cfg.timeout_sec,
        cfg.max_retries,
        cfg.retry_backoff_ms,
    );
    AgentBuilder::new(model)
        .preamble(preamble)
        .temperature(cfg.temperature)
        .max_tokens(cfg.max_tokens as u64)
        // 如实偏差：C++ 的 max_turns 是「工具轮次」，rig 的 max_turns 是**模型调用
        // 预算**。同一份配置在两侧含义更接近「上限」的一侧收紧，已记档。
        .default_max_turns(cfg.max_turns as usize)
        .additional_params(serde_json::Value::Object(extra))
        // 循环层钩子：墙钟两判定点、单轮调用上限、失败回滚边界（见 hook.rs）
        .add_hook(SessionHook::new(state))
        .dynamic_tools(tools)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deepseek_accepts_standard_tool_responses_and_retains_reasoning() {
        use rig_core::completion::{AssistantContent, NormalizeCompletionResponse};
        for content in [serde_json::Value::Null, json!("调用工具。")] {
            let wire = json!({
                "id": "test", "model": "deepseek-reasoner",
                "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                    "role": "assistant", "content": content, "reasoning_content": "先读取状态。",
                    "tool_calls": [{"id": "call_1", "type": "function", "function": {
                        "name": "read_variables", "arguments": "{}"
                    }}]
                }}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 3, "total_tokens": 14}
            });
            let response: <DeepSeekChat as OpenAICompatibleProvider>::Response =
                serde_json::from_value(wire).unwrap();
            let normalized = response.normalize(DeepSeekChat::PROVIDER_NAME).unwrap();
            assert!(normalized
                .choice
                .iter()
                .any(|c| matches!(c, AssistantContent::Reasoning(_))));
            assert!(normalized.choice.iter().any(|c| matches!(c, AssistantContent::ToolCall(t) if t.function.name == "read_variables")));
            assert_eq!(normalized.usage.input_tokens, 11);
            assert_eq!(normalized.usage.output_tokens, 3);
        }
    }

    #[test]
    fn deepseek_keeps_native_request_shaping() {
        let mut body = json!({"messages": [
            {"role": "system", "content": [{"type": "text", "text": "规则"}]},
            {"role": "assistant", "reasoning_content": "推理", "tool_calls": []}
        ]});
        DeepSeekChat.finalize_request_body(&mut body).unwrap();
        assert_eq!(body["messages"][0]["content"], "规则");
        assert_eq!(body["messages"][1]["content"], "");
        assert_eq!(body["messages"][1]["reasoning_content"], "推理");
    }

    #[test]
    fn driver_from_table_maps_builtin_tables() {
        assert_eq!(Driver::from_table("LlmOpenAI").unwrap(), Driver::OpenAi);
        assert_eq!(Driver::from_table("LlmDeepSeek").unwrap(), Driver::DeepSeek);
        assert_eq!(
            Driver::from_table("LlmAnthropic").unwrap(),
            Driver::Anthropic
        );
        // 自定义 Lua 驱动：明确报错（不静默换协议）
        let e = Driver::from_table("MyCustomLlm").unwrap_err();
        assert!(e.contains("不支持的协议驱动表名"), "实际: {e}");
        assert!(e.contains("LlmOpenAI"));
        assert!(Driver::from_table("").is_err());
    }

    #[test]
    fn base_url_strips_chat_completions_for_openai_family() {
        for d in [Driver::OpenAi, Driver::DeepSeek] {
            assert_eq!(
                base_url_from_endpoint("http://127.0.0.1:8080/v1/chat/completions", d),
                "http://127.0.0.1:8080/v1"
            );
            // 带尾斜杠 / 已是 base 形态：都能落到同一个请求 URL
            assert_eq!(
                base_url_from_endpoint("http://h/v1/chat/completions/", d),
                "http://h/v1"
            );
            assert_eq!(base_url_from_endpoint("http://h/v1", d), "http://h/v1");
            // 非标准路径原样当 base（rig 仍会拼 /chat/completions，故如实报实际 URL）
            assert_eq!(
                base_url_from_endpoint("http://h/proxy", d),
                "http://h/proxy"
            );
        }
    }

    #[test]
    fn anthropic_endpoint_uses_rig_normalization() {
        for suffix in ["", "/", "/v1", "/messages", "/v1/messages", "/v1/messages/"] {
            assert_eq!(
                base_url_from_endpoint(&format!("http://h{suffix}"), Driver::Anthropic),
                "http://h"
            );
        }
        assert_eq!(
            base_url_from_endpoint("http://h/proxy/v1/messages", Driver::Anthropic),
            "http://h/proxy"
        );
    }

    #[test]
    fn effective_url_is_base_plus_driver_path() {
        // 折算 → 还原：C++ 接入点与 rig 实际请求 URL 必须一致（否则同一份配置
        // 两个进程打到不同路径）
        for (ep, d) in [
            ("http://127.0.0.1:8080/v1/chat/completions", Driver::OpenAi),
            (
                "http://127.0.0.1:8080/v1/chat/completions",
                Driver::DeepSeek,
            ),
        ] {
            let base = base_url_from_endpoint(ep, d);
            assert_eq!(format!("{base}{}", d.request_path()), ep);
        }
        // Anthropic：rig 规范化后的 base + /v1/messages 等价于原接入点
        let base =
            base_url_from_endpoint("https://api.anthropic.com/v1/messages", Driver::Anthropic);
        assert_eq!(
            format!("{base}{}", Driver::Anthropic.request_path()),
            "https://api.anthropic.com/v1/messages"
        );
    }
}

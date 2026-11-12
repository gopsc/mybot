//! Agent 启动阶段：后端连接、工具发现、上下文装配与提示词加载。

use std::sync::Arc;
use std::time::Duration;

use crate::bridge::{Bridge, ConnParams};
use crate::config::{self, Config};
use crate::frame::{BackendClient, HARD_READ_CEILING};
use crate::hook::HookState;
use crate::httpfetch::HttpFetchTool;
use crate::ica;
use crate::prompt::PromptMaterial;
use crate::toolspec::ToolSpec;

pub const CONNECT_TIMEOUT_SEC: u64 = 120;
pub const RECONNECT_TIMEOUT_SEC: u64 = 30;

pub struct BackendAssembly {
    pub bridge: Arc<Bridge>,
    pub specs: Vec<ToolSpec>,
    pub tool_names: Vec<String>,
    pub material: PromptMaterial,
    pub preamble: String,
}

/// 后端连接与提示词素材装配。
///
/// 连接与传输失败返回退出码 1；提示词素材或系统提示词错误返回退出码 2。
pub async fn assemble_backend(
    cfg: &Config,
    state: &Arc<HookState>,
) -> Result<BackendAssembly, (String, i32)> {
    // 先于连后端构造：本地工具的装配失败属配置/环境错误，不该先碰后端再退出。
    let http_fetch = HttpFetchTool::new(
        cfg.allow_hosts.clone(),
        Duration::from_secs(cfg.http_fetch_timeout_sec as u64),
        cfg.http_fetch_max_bytes as usize,
    )
    .map_err(|e| (e, 2))?;
    let mut client =
        BackendClient::connect_timeout(&cfg.socket, Duration::from_secs(CONNECT_TIMEOUT_SEC))
            .await
            .map_err(|e| (format!("无法连接后端 socket: {e}"), 1))?;

    let read_timeout = if cfg.max_task_seconds > 0 {
        Duration::from_secs(cfg.max_task_seconds as u64)
    } else {
        HARD_READ_CEILING
    };
    client.set_read_timeout(read_timeout);

    let mcp_token = std::env::var("BOT4CJ_MCP_TOKEN")
        .ok()
        .filter(|t| !t.is_empty());
    if let Some(token) = &mcp_token {
        client
            .authenticate(token)
            .await
            .map_err(|e| (e.to_string(), 1))?;
    }

    let conn_params = ConnParams {
        path: cfg.socket.clone(),
        token: mcp_token,
        connect_timeout: Duration::from_secs(RECONNECT_TIMEOUT_SEC),
        read_timeout,
    };
    let bridge =
        Arc::new(Bridge::new(client, conn_params, Arc::clone(state)).with_http_fetch(http_fetch));
    let specs = bridge
        .list_tools()
        .await
        .map_err(|e| (format!("取后端工具表失败: {e}"), 1))?;
    let tool_names: Vec<String> = specs.iter().map(|s| s.name.clone()).collect();
    let data = bridge
        .context_get()
        .await
        .map_err(|e| (format!("取后端上下文失败: {e}"), 1))?;
    let material = PromptMaterial::from_context(&data).map_err(|e| (e.to_string(), 2))?;
    let mut preamble =
        crate::prompt::build_system_prompt(&cfg.driver, &cfg.llm_var, &cfg.prompt_pack, &material)
            .map_err(|e| (e.to_string(), 2))?;
    if bridge.ica.enabled() {
        preamble.push_str(ica::preamble_section());
        if preamble.len() > 65_536 {
            return Err(("开启 ICA 后系统提示词超过 65536 字节上限".to_string(), 2));
        }
    }
    Ok(BackendAssembly {
        bridge,
        specs,
        tool_names,
        material,
        preamble,
    })
}

/// 加载提示词包，并限制配置文件来源的路径只能位于允许的根目录内。
pub fn load_prompt_pack(cfg: &mut Config, cli: &config::Cli) -> Result<(), String> {
    if cfg.prompt_files.is_empty() {
        return Ok(());
    }
    if cli.prompt_files.is_empty() {
        let mut roots = vec![".".to_string()];
        roots.extend(crate::prompt::prompt_roots_from_env());
        crate::prompt::prompt_paths_within_roots(&cfg.prompt_files, &roots)?;
    }
    cfg.prompt_pack = crate::prompt::load_prompt_pack(&cfg.prompt_files)?;
    Ok(())
}

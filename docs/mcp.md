# MCP

[MCP（Model Context Protocol）](https://modelcontextprotocol.io) 是模型客户端与工具服务之间的标准协议。本仓库有两个方向：

| 方向 | 入口 | 说明 |
| --- | --- | --- |
| pymybot 作为 MCP 服务端 | `pymybot mcp` | 把同一个机器人会话暴露给 Claude Desktop、Cursor、IDE 或其他 MCP 客户端 |
| Agent 作为 MCP 客户端 | `pymybot agent --mcp-config FILE` | 让内置 Agent 调用外部 MCP 服务提供的工具 |

两端默认都按最小权限工作：服务端只读，客户端逐次审批。它们是可选依赖，不影响
CLI、GUI 和既有 `serve` 协议。

```sh
pip install -e ".[mcp]"          # 仅 MCP 服务端
pip install -e ".[agent,mcp]"    # Agent + MCP 客户端
```

## 1. `pymybot mcp` — 标准 MCP stdio 服务端

```sh
pymybot mcp \
  --robot robots/relay-test.sql \
  --scripts-dir scripts
```

stdout 只承载 MCP JSON-RPC；诊断、Lua 输出和警告全部走 stderr。客户端断开 stdin
后进程退出；启动失败只写 stderr 并以非零码退出，不会向协议通道写 CLI JSON。

### 工具

| 工具 | 作用 | 激活硬件 |
| --- | --- | --- |
| `get_status` | 读取加载/激活/故障状态和最近一次回执 | 否 |
| `list_hardware` | 列出声明的硬件，不激活驱动 | 否 |
| `list_action_scripts` | 列出可信脚本根内的 `.mt` 相对路径 | 否 |
| `read_action_script` | 读取一个 `.mt` 原文，不执行 | 否 |
| `query_sql` | `SHOW TABLES` / `SELECT *`，只读 | 否 |
| `run_action_script` | 执行已有 `.mt`，需要 `--allow-execution` | 是 |
| `read_variables` | 读取 `--read-var` 白名单变量 | 是 |
| `capture_image` | 从 `--camera-var` 白名单相机抓图，返回 MCP 图片内容 | 是 |
| `deactivate` | 释放空闲机器人；不是急停，也不清除故障锁存 | 否 |

所有工具返回同一信封：

```json
{"ok":true,"executed":false,"state":"completed","data":{}}
```

`state` 为 `completed`、`not_executed` 或 `unknown`。`unknown` 表示动作可能已经发生，
**不要重试**；需要操作者先检查机器人。回执同时作为 `structuredContent` 和文本
`content` 返回，图片以 MCP `image` 内容返回。

### 资源

| URI | 内容 |
| --- | --- |
| `mybot://scripts/<path>` | 可信脚本根内的 `.mt` 原文 |
| `mybot://skills/<skill>/<file>` | 操作者技能目录中的 Markdown 参考 |

资源只用于阅读，不授予执行权限。

### 权限

| 开关 | 默认 | 效果 |
| --- | --- | --- |
| — | 只读 | 静态工具可用；执行类工具返回 `not_executed` |
| `--allow-execution` | 关 | 允许动作脚本、变量读取和抓图（仍需各自的变量白名单） |
| `--allow-hardware` | 关 | 打开物理总线、非回环 HTTP 和 Shell 驱动；要求同时给出 `--allow-execution` |
| `--read-var NAME` | 空 | 允许 `read_variables` 读取该变量；可重复 |
| `--camera-var NAME` | 空 | 允许从该 `Camera` 变量抓图；可重复 |
| `--var NAME=VALUE` / `--var-env NAME=ENVVAR` | 空 | 激活前的结构 `Alias`/`Vars` 覆盖与动作绑定 |

`--allow-hardware` 是能力开关，不是安全认证。Lua 驱动是可信代码；Shell 驱动不是沙箱。

### 客户端配置

Claude Desktop（`claude_desktop_config.json`）或 Cursor（`.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "mybot": {
      "command": "pymybot",
      "args": [
        "mcp",
        "--robot", "/abs/path/robots/relay-test.sql",
        "--scripts-dir", "/abs/path/scripts",
        "--allow-execution",
        "--read-var", "relay0"
      ]
    }
  }
}
```

Source checkout 中可用 `python -m pymybot` 代替 `pymybot`，并用绝对路径避免
客户端工作目录不同。一个服务进程只控制一个结构文件；多机器人请启动多个条目。

### 限制

- 仅 stdio；不提供 HTTP/SSE 监听，远程访问需要自行加传输层代理。
- 不提供会话转录；`--no-session-log` 不适用于 `mcp`。
- 协作者无法中断阻塞中的原生驱动调用；`deactivate` 也只释放空闲会话。
- 取消请求由 MCP 客户端关闭连接实现，服务端随后清理已激活的驱动。

## 2. Agent 调用外部 MCP 服务

```sh
pymybot --no-gui agent \
  --robot robots/relay-test.sql \
  --scripts-dir scripts \
  --model deepseek:deepseek-chat \
  --mcp-config ./mcp.json \
  --task "先用外部检索工具查资料，再列出机器人硬件"
```

`--mcp-config` 使用与 Claude Desktop、Claude Code、Cursor 相同的 `mcpServers`
结构，只支持本地 stdio 服务：

```json
{
  "mcpServers": {
    "search": {
      "command": "uvx",
      "args": ["mcp-server-fetch"],
      "env": {"API_TOKEN": "${SEARCH_TOKEN}"},
      "cwd": "."
    }
  }
}
```

- 只支持 `command` + `args`；出现 `url` 或 `headers` 会被拒绝（远程 MCP 不在当前威胁模型内）。
- `${VAR}` / `${VAR:-default}` 从环境展开；未定义即报错。
- 服务名 1–32 个字符（字母、数字、`-`、`_`），工具名会加上 `<server>_` 前缀。
- `env` 与宿主环境合并后传给子进程；`cwd` 相对配置文件解析。
- 配置在创建模型前加载；配置错误不会发出任何模型请求。

### 审批与回执

外部工具默认逐次审批，控制台或 GUI 弹窗显示 `<server>_<tool>` 和完整参数；拒绝后
本次调用不会执行。`--allow-mcp-tools` 可预批准本次会话，但仍需 `--mcp-config`。

- 返回给模型的结果按 64 KiB / 单字符串 32 KiB / 单图 2 MiB 限界；
- 传输或服务端异常返回 `state: "unknown"`，不自动重试；
- 工具名、参数和结果写入会话转录（`tool_call`/`tool_result`），密钥不会从环境读取进转录。

### `serve` 与 GUI

`agent.ask` 新增三个可选参数：

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `mcpConfig` | string | 服务端的 `mcpServers` JSON 路径 |
| `allowMcpTools` | boolean | 预批准外部 MCP 工具调用 |
| `historyTurns` | integer | 保留的完整对话轮数（1–20，默认 6） |

GUI 的 **设置 → MCP 配置** 和左侧 **MCP 配置（mcpServers JSON）** 字段可指定路径；
未填写时不启用外部 MCP。

## 安全边界

| 边界 | 规则 |
| --- | --- |
| 模型 → 外部 MCP | 每次调用审批，除非操作者显式预批准；结果只作为不可信数据回给模型 |
| 外部 MCP → 宿主 | stdio 服务以宿主用户权限运行，**不是沙箱**；只加载审阅过的配置 |
| MCP 客户端 → pymybot | 只读默认；执行与物理硬件开关分离；变量/相机白名单独立 |
| 回执 | 派发后异常一律 `unknown`，不声称回滚；超限结果被截断而不是整包送入模型 |

完整威胁模型见 [security.md](security.md)。

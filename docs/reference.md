# 命令行与环境变量参考

> 本文收录 bot4cj 运行时的全部可调接口：CLI 参数、动作输入源、安全约束与环境变量。[README](../README.md) 中只保留快速开始。

## 环境要求

| 组件 | 说明 | 状态 |
| --- | --- | --- |
| Linux | HAL 经 ffi 直调 glibc（open/ioctl/read/write/usleep） | ✅ 必需 |
| CMake ≥ 3.16、C++17 编译器 | g++ / clang++ | ✅ 必需 |
| LuaJIT 2.1（`libluajit-5.1-dev`） | 驱动与 HAL 全部在 LuaJIT 上 | ✅ 必需 |
| Python 3 | `scripts/tcp_e2e.sh` 的 TCP 客户端与假模型服务需要（缺则守门自动跳过） | ⭕ 可选 |
| libcurl（`libcurl.so`） | **仅 agent 模式**：`modules/lib/llm_http.lua` 经 ffi 加载它发 HTTPS 请求；无需开发包头文件 | ⭕ 可选（缺则 agent 驱动 build 报错，机器人不上电） |
| `/dev/i2c-*` | 真机总线 | ⭕ 可选（无总线时全流程可用内存仿真跑） |

## 命令行参数

程序名为 `mybot`。缺省无参数时打印帮助。参数支持 `--key=value` 与 `--key value` 两种写法（`src/cliargs.cpp:parseArgs`）；未知或拼错的 `--key` 一律报错并以退出码 **2** 结束（不再静默忽略），`--help` 始终优先。

| 参数 | 说明 |
| --- | --- |
| `--robot <path>` | **必选**，机器人结构脚本 `.sql` 路径；打不开或解析失败会给出人话提示并退出 1 |
| `--help` | 打印帮助手册 |
| `--tcp <port>` | TCP 模式：监听端口接受**一次成功连接**并读取对端下发的 `.mt`（EOF 或空闲超时按输入结束；单连接一次性批量下发，非流式长驻）。与 `--agent` 同给时为**远程 REPL**：对端每行一条任务，模型输出与工具回显回写同一条连接（无连接总时长预算、`--tcp-idle` 缺省 600s、对端断开即远程取消——详见 [agent.md](agent.md#远程对话-agent---tcp)） |
| `--tcp-host <addr>` | TCP 监听地址，缺省 `127.0.0.1`；跨机监听（如 `0.0.0.0`）**必须**同时提供 `--tcp-token`，否则拒绝启动 |
| `--tcp-token <tok>` | TCP 口令：跨机监听必填；对端须先发一行 `"<tok>\n"` 再发脚本。也可用环境变量 `BOT4CJ_TCP_TOKEN` 传递（多用户机器上推荐，理由见下） |
| `--tcp-idle <sec>` | TCP 空闲超时，缺省 30s，合法范围 1-86400（超时按输入结束处理） |
| `--tcp-max-auth-attempts <N>` | TCP 口令连续失败上限，缺省 5，合法范围 1-1000（连败到此数即放弃等待，防无限爆破） |
| `--tcp-total-timeout <sec>` | TCP 连接总时长预算下限，缺省 600，合法范围 1-86400；生效值取该下限与 `--tcp-idle` ×20 的较大者 |
| `--input <path>` | 从文件读取动作脚本 |
| （缺省） | 从 stdin 管道读取 |
| `--daemon-grace-ms <ms>` | 守护线程弃管后的二段停机宽限上限，缺省 30000，合法范围 0-300000；仅结构脚本含 `@Daemon` 时生效，与 `--agent`/`--tcp`/`--input` 任一模式无关 |
| `--agent` | **agent 模式**：机器人结构脚本加载后硬件常驻内存，由大模型工具循环决定执行哪些动作脚本（与上面的动作输入源互斥，详细见 [agent.md](agent.md)） |
| `--task <文本>` | agent 模式一次性任务，跑完即退出；缺省则进交互 REPL |
| `--llm-config <路径>` | agent 配置文件（JSON）：接入点、API key、模型、采样与 agent 参数。缺省自动查找 `./mybot.llm.json` 等；显式传 `none` 表示本次不读配置文件（CI/复现问题用，详见 [agent.md](agent.md)） |
| `--llm-driver <表名>` | agent 的**协议驱动**表名 = `modules/<表名>.lua`（内置 `LlmOpenAI`、`LlmDeepSeek`；缺省 `LlmOpenAI`） |
| `--llm-var <变量名>` | 承载驱动变量的名字（缺省 `llm0`）；结构脚本已声明同名变量则直接用，否则自动注入 |
| `--llm-endpoint <URL>` | agent 模型接入点（覆盖配置文件；不给则用配置或驱动缺省） |
| `--llm-model <名称>` | agent 模型名（覆盖配置文件；不给则用配置或驱动缺省） |
| `--llm-max-turns <N>` | 单次任务最大模型轮数，范围 1-100（缺省 8） |
| `--llm-max-tokens <N>` | 单次生成最大 token 数，范围 1-200000（缺省 4096） |
| `--llm-timeout <秒>` | 单次模型调用超时，范围 1-600（缺省 180） |
| `--llm-task-timeout <秒>` | 单个任务的墙钟预算，范围 0-86400（缺省 900；`0` = 不限）。与 `--llm-timeout` 是不同维度：agent 模式全程硬件带电常驻，这条给「一个任务最多带电多久」设闸。超限即如实失败（报错点名预算秒数），**已执行的动作不回退**；若预算在一轮中间耗尽，剩余工具调用不派发、但每条各留一条「未派发」回执以维持 `tool_calls` ⇔ `tool` 一一对应。配置文件等价键：`max_task_seconds` |
| `--scripts-dir <目录>` | agent 动作脚本根目录，也是 `run_action_script` 的路径沙箱边界（缺省 `scripts`） |
| `--prompt-file <路径>` | 提示词包：可重复传入（文件或目录），内容按文件名自然排序拼接后追加进系统提示词（详见 [agent.md](agent.md)）。命令行给的路径**不受根目录约束**（操作者本人授意）；**配置文件**里的 `prompt_files` 则只能指向当前工作目录或 `BOT4CJ_PROMPT_DIR` 列的目录之内——提示词内容会随请求发往同一份配置可控的 endpoint，不设限就成了一条「读任意文件并外发」的链路（H2，见 [agent.md](agent.md) 安全说明第 11 条） |
| `--agent-shell` | **显式开启**智能体的 `run_command`（任意 shell 执行）；**缺省不提供**该工具。API key 非来自环境变量时启动会打印告警。命令**回执**（stdout/stderr）在回传模型前遮蔽 `KEY=VALUE` 等敏感值（G1，与审计同一单点） |
| `--agent-hot-sql` | **显式开启**智能体的 `apply_sql`（结构 SQL 带电生效：`CREATE TABLE`/`INSERT INTO` 立即装配并上电，失败整批回滚；**`DELETE FROM` 当场断电摘除匹配行——物理不可逆**，故被引用着的变量会被拒绝，详见 [dsl.md](dsl.md)）；**缺省不提供**该工具。**只能命令行给**：它让模型的一次回复直接改变带电结构，配置文件写 `allow_hot_sql` 会被拒绝加载并退出 2（与 `allow_shell` 同判据）。只读的 `query_sql` 不受影响 |
| `--read-var <变量名>` | 声明一个**可读**硬件变量（可重复；注册 `read_variables` 工具，让智能体主动读器件当前值）。**缺省不提供**该工具：执行器（`Servo`/`Relay` 等）与传感器同属 `kind=lua`，靠种类分不出，故由操作者显式列名；只有已注册且种类为 `lua`/`daemon` 的名字生效（`daemon` 读的是已发布的采样快照，无 I2C 流量）。**只能命令行给**：配置文件写 `read_vars` 会被拒绝加载并退出 2（与 `allow_shell` 同判据） |
| `--agent-policy <路径>` | 策略钩子（严格 JSON）：声明哪些工具的每次调用要先过**外部确认程序**（stdin 收工具名与遮蔽后的参数 JSON，退出 0 = 放行；超时按 `on_timeout`，缺省 `deny`）；缺省**不启用**。也可用配置文件 `agent_policy` 字段（详见 [agent.md](agent.md)） |
| `--camera-var <变量名>` | 承载摄像头驱动（`modules/Camera.lua`）的变量名（缺省 `cam0`）；结构脚本已声明则直接用 |
| `--camera-device <路径>` | 摄像头设备（缺省 `/dev/video0`，需支持 MJPEG；驱动只放行 `/dev/videoN`） |
| `--camera-src <图片>` | 模拟图片来源：不接摄像头也能跑通「拍照 → 进上下文」。**命令行**给的 src 以其所在目录为白名单根；**配置文件**给的 `camera_src` 不推导根（H1：`dirname(src)` 当然包含 `src`，用它当根等于判据恒真、白名单形同不存在），需配 `--camera-src-dir` 或 `BOT4CJ_CAMERA_SRC_DIR`，否则驱动默认拒绝 |
| `--camera-src-dir <目录>` | `capture_image` 模拟图片的**白名单根目录**，优先级高于上面的推导。**只能命令行给**：它放宽读权限，配置文件写 `camera_src_dir` 会被拒绝加载并退出 2（与 `allow_shell` 同判据） |
| `--no-camera` | 不向智能体提供 `capture_image` |
| `--check-config` | 只校验配置并打印摘要，随后以 **0** 退出：**不装载结构脚本、不上电、不发起任何网络请求**。用于「配置文件写错了但不想真起一次会话」（接了硬件也不必反复上下电）。配置本身仍由 `buildAgentConfig` 单点校验，失败退出 **2**；会**打开但不写入**审计日志文件（顺带验证其可写） |
| `--audit-log <路径>` | 审计轨迹（JSON Lines 追加写）：每次工具调用一条记录（时间戳/轮次/工具/参数/成败/耗时/退出码）；图片只记体积与指纹，命令原文里的 `KEY=VALUE` 敏感值先遮蔽，`apply_sql` 等工具另记结构化生效摘要（`summary`）；`-` 表示写 stderr；缺省**不记录**。也可用配置文件 `audit_log` 字段（详见 [agent.md](agent.md)） |
| `--session-file <路径>` | 会话持久化（JSON Lines 追加写）：每个任务块**完结**时落盘该块的全部消息（含工具调用与回执），第 1 行是会话头（结构脚本名 / 工具集指纹 / 系统提示词指纹）。**图片字节不落盘**（以 `[图片 N 字节，未随会话恢复]` 占位），system 提示词不落盘（恢复时由当前进程重建并按指纹核对）。失败/中断的半截工具序列永不落盘，故文件里每个前缀都可独立恢复。也可用配置文件 `session_file` 字段（**只用于写入**——恢复是输入通道，见 `--resume`）。文件含完整对话内容，建议 `chmod 600`（权限过松时启动告警） |
| `--resume` | 恢复 `--session-file` 指定的既有会话后继续：路径**必须来自命令行**（配置文件里的 `session_file` 不能授权一次读取），文件必须已存在。载入时逐行解析（损坏行跳过并点名行号，不整份作废），再核对会话头指纹（结构脚本 / 工具集 / 系统提示词三者一致）与工具调用协议自洽（`tool_call_id` 无孤儿、无重复、无漏答），任一不符即**拒绝恢复并说明差异**（退出码 2）。恢复的历史按不可信输入对待，仍受 `max_history_bytes` 预算裁剪；审计沿用原会话 id 并在 start 记录里标 `"resumed": true`（详见 [agent.md](agent.md)） |
| `--webshell-port <端口>` | Web SSH 模式监听端口（1–65535），缺省 7682；与 `--robot`/`--agent`/`--mcp-backend` 互斥（同给即退出码 2） |
| `--webshell-host <地址>` | Web SSH 模式绑定地址，缺省 `127.0.0.1`；绑定**非回环**地址时必须同时给 `--webshell-token`，否则拒绝启动（退出码 2） |
| `--webshell-token <值>` | Web SSH 访问令牌（query 参数 `?token=` 校验，经 RFC 6455 WebSocket 升级前的 HTTP 请求头比对；`/ws/term` 与首页共用同一校验，令牌错误返回 401）。绑定非回环地址时**强制**要求，回环绑定可不给（缺省不限制）；WebSocket 帧层有独立的拒绝式解码（未掩码/RSV/非法 opcode/控制帧超 125/消息超 64KiB 一律拒绝） |

agent 专属选项出现在非 agent 模式下、或 `--agent` 与 `--tcp`/`--input` 同时给出，一律报错并以退出码 **2** 结束。

**TCP 模式的安全设计**（上面几条参数背后的原因）：

- 口令校验失败只关闭该连接、回到 accept 等待，**连续失败**（缺省 5 次，可用 `--tcp-max-auth-attempts` 调整）才退出——既防单次连接 DoS，也防无限爆破
- 口令校验为**恒时比较**（防时序侧信道，审计 M1）
- argv 会出现在 `/proc/*/cmdline`、对本机所有用户可读——多用户机器上传 TCP 口令请用环境变量而非命令行（API key 同理：宿主**不提供**命令行传密钥的选项，只从环境变量或配置文件取）
- 连接另有**总时长预算**（缺省下限 600s，可用 `--tcp-total-timeout` 调整；生效值取该下限与 `--tcp-idle` ×20 的较大者）从连接建立起算：慢滴发送（每 <idle 秒发 1 字节）不能无限期挂住进程
- **本通道明文无加密**（口令与脚本正文都走明文 socket，TLS 未实现）：仅限**可信内网/本机**使用；跨信任域请自行加隧道，或改用文件/标准输入源

**agent 取值优先级**：命令行 > 环境变量 > 配置文件 > 驱动内置缺省。接入点、密钥、模型等都可写进
配置文件（模板 `mybot.llm.json.example`），字段表与查找顺序见 [agent.md](agent.md)。

**中断语义（SAN-7，2026-09-22 据实测改写——此前本节与代码相反）**

Ctrl-C（SIGINT/SIGTERM）**首次**即完成一次优雅中断，全程走正常清理链；**第二次**
才是逃生口（按缺省处置强杀）。首次按下之后依次发生：

1. **置停止标志**（`stopRequested()`，async-signal-safe）——按行派发的动作脚本在
   **行与行之间**看到它即停派发；
2. **创建取消哨兵**文件（`/tmp/mybot-cancel-<pid>`）——在飞的**模型调用**因此可被
   及时打断：`llm_http.lua` 的 libcurl 进度回调（约 1 秒一次）发现哨兵即中止请求，
   报错点名「请求已取消（宿主收到停止信号）」，而**不是**等满 `--llm-timeout`
   （最长 600s）或按第二次强杀。"卡在网络上"（网关无响应、断网）由此被覆盖。
   *（哨兵是跨层通道：驱动沙箱拿不到宿主内存，文件是零新依赖的通道；`/tmp` 不可写
   时静默跳过、退化为旧行为——这是有意的降级，不是缺陷。）*
3. **动作脚本执行预算窗口内**（`action_script_timeout_sec`）：窗口内的指令计数钩子
   同时检查停止标志，跑飞的 Lua 驱动循环也能被首次 Ctrl-C 打断（PL-2）。
4. **退出前走清理链**：`runRobotAndCleanup` 无论成败都调 `deactivate()`
   （守护 join → 驱动 destroy → 硬件去初始化），随后进程按退出码 1 退出。

**实测证据**（`scripts/agent_e2e.sh` 场景 8 与 13）：服务端睡 5s，1.2s 时发首次
SIGINT → 约 1s 内中止、报错点名「请求已取消」、哨兵文件已清理；另外用
`test/cpp/LifetimeProbe.lua` 探针实测：**`deactivate()` 确实执行且只执行一次**
（marker 文件恰好 1 字节 `D`）。所以"中断之后硬件是安全的"这句话有可断言的判据，
不是靠读代码相信。

**第二次（连按）仍然是逃生口，但请把它当逃生口而非常规操作**：优雅路径本身若被
卡住（`/tmp` 不可写导致哨兵失效、驱动阻塞在不可中断的系统调用里、守护拒绝退场），
第二次按下按缺省处置强杀，**跳过清理**，执行器可能停在最后指令位置。
它存在的理由是"总能停下来"，不是"推荐这么停"。另有一层兜底：`~RobotStruct` 会在
对象销毁时补一次断电，所以「漏掉 `deactivate()` 的退出路径」不会把硬件留在带电状态
（强杀除外，那不走析构）。

## 动作输入源

`src/actionsource.cpp` 工厂按 **TCP > 文件 > stdin** 的优先级三选一：

```bash
# 1) TCP 模式：监听端口接受一次连接并读取 .mt（EOF/空闲超时结束）
./build/mybot --robot=robots/relay-test.sql --tcp 19240

# 2) 文件输入：不依赖管道
./build/mybot --robot=robots/relay-test.sql --input scripts/relay-test.mt

# 3) 缺省：stdin 管道
cat scripts/relay-test.mt | ./build/mybot --robot=robots/relay-test.sql
```

## 安全约束

- 动作脚本只能**引入新的参数键**，不得覆盖结构脚本的元数据列（`fd` / `address` / `max` / `min` / `offset` 等），也不得占用触发器引用名（`trigger` 列指向的名字，触发器结果子表按该名并入调用参数）
- 单次输入上限 **8 MiB**：动作脚本（`.mt`）与结构脚本（`.sql`）统一适用，超限即拒绝并指明输入类别（`action script` / `structure script exceeds the byte limit`）
- `result` / `message` / `mode` 三个键名由框架保留，`.mt` 不得用作参数列（`MtVars_Lua::rejectReservedKeys`）
- 驱动沙箱会禁用 shell 与任意文件读写，但这是**防误用护栏而非安全边界**——接入 `--tcp` 外部数据源时需另行建立信任边界（详见 [hal.md](hal.md)）

### 沙箱威胁模型（N-9，显式声明）

`modules/` 下的驱动与 `@Daemon` chunk 按**可信输入**对待，沙箱的边界是
「驱动作者边界」而非「网络攻击边界」：

- 驱动可经 `require("ffi")` 调 `ffi.C`/`ffi.load` 触达任意 native 符号，
  `os.execute` 中和与文件 I/O 白名单在 ffi 面前形同虚设——这是设计取舍
  （驱动本来就持有真实总线的读写能力，I2C/SPI 事务本身即不可逆向沙箱化）
- 结构脚本与动作脚本落盘前只是数据；**驱动文件（`modules/**/*.lua`）是
  任意原生代码执行的入口**，其信任级别等同运行 mybot 的用户
- `--tcp` 模式下外部对端只能提交**动作脚本**（受 C-1/metadata/rejectReservedKeys
  多层防线约束），不能注入驱动；但动作脚本可触达驱动已暴露的任意 call 路径——
  驱动作者须自行保证参数校验（如 SCSCL 的烧号须结构期 `allow_burn` 授权）
- 若需对抗恶意输入源，应在进程外建立隔离（专用用户、容器、网络命名空间），
  库内 Lua 沙箱对此无能为力

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `BOT4CJ_MODULE_PATH` | 驱动模块目录（默认 `./modules`），`<矩阵名>.lua`、`lib/`、`@Daemon` 的 chunk 都按它解析；支持 `:` 分隔多路径按序查找。宿主建沙箱时按该列表**逐段探测 `lib/mpath.lua`** 并注入 `__mpath`，驱动与 `lib/` 的后续解析都走它——多路径对全部 59 个模块成立（2026-09-20 重构阶段 2 之前只有宿主侧成立，驱动侧 `:match("[^:]+")` 只取首段）。边界：**脱离宿主**直跑（`luajit test/*.lua`、`scripts/scscl_scan.lua`）没有 `__mpath`，此时回退单根语义，请把含 `lib/` 的根放首位 |
| `BOT4CJ_DEBUG` | 设为 `1` 开启 call/build/destroy 的参数表、结果表、逐键值转储；缺省静默 |
| `BOT4CJ_TCP_TOKEN` | TCP 口令（等价 `--tcp-token`，优先级低于命令行）。argv 会出现在 `/proc/<pid>/cmdline`，多用户机器上推荐用本变量传口令 |
| `BOT4CJ_LLM_KEY` | agent 模式的 API key。回退顺序：`ROBOT_AGENT_API_KEY` → `DEEPSEEK_API_KEY`。由 **Lua 驱动自己读取**（不进宿主的参数表，也不进 `BOT4CJ_DEBUG` 转储）；该变量名含 `key`，会被 `run_command` 的环境清洗剔除，不会泄漏给子进程 |
| `BOT4CJ_LLM_CONFIG` | agent 配置文件路径（优先级低于 `--llm-config`、高于缺省查找）；设为 `none` 表示不读配置文件 |
| `BOT4CJ_LLM_ENDPOINT` / `BOT4CJ_LLM_MODEL` | agent 接入点 / 模型名（覆盖配置文件，低于命令行） |
| `BOT4CJ_LLM_REASONING_EFFORT` | DeepSeek 驱动用：思考强度（`low`/`high`/`max`）。也可经配置文件或驱动参数 `reasoning_effort` 传入，优先级为 参数 > 环境变量 |
| `BOT4CJ_HAL_BACKEND` | HAL 后端模块名：`modules/lib/hal_backend_<名>.lua`（缺省 `glibc`）。加载期逐项断言契约函数齐全，缺函数 fail-fast——移植到别的 libc/平台时替换整个后端 |
| `BOT4CJ_CAMERA_SRC_DIR` | 摄像头仿真来源的**放行目录**（冒号分隔）：`--camera-src` 之外的路径必须落在这里面，否则驱动拒绝读该文件（缺省禁用任何目录外读取） |
| `BOT4CJ_PROMPT_DIR` | 提示词包的**放行目录**（冒号分隔，H2）：**配置文件** `prompt_files` 里的路径必须落在当前工作目录或这里列出的目录之内（命令行 `--prompt-file` 不受限）。配置文件写不了本变量，故它只能由启动者设——现场把提示词包放在工作目录之外时用它显式放行 |
| `BOT4CJ_TEST_VIDEO` | 仅守门用：真机摄像头用例（`test_camera_v4l2.lua`）的设备路径，指定且存在时该用例不再按跳过计（见 [testing.md](testing.md)） |
| `BOT4CJ_HTTP_PROBE` | 仅守门/排障用：设为 `1` 时 `lib/llm_http.lua` 每次模型请求向 stderr 打一行 `[http-probe] sessions=<已建会话数> handle=<句柄>`。agent E2E 用它断言「多轮调用复用同一份会话」（AG-20）。缺省不打——正常运行不该多这行噪声 |
| `BOT4CJ_LLM_CANCEL_FILE` | 仅宿主内部用：模型调用可取消（AG-27）的哨兵文件路径，由宿主在收到 SIGINT/SIGTERM 时创建、`lib/llm_http.lua` 的 libcurl 进度回调轮询到即中止请求（报「请求已取消」）。正常使用**不需要也不应该**手工设置它；变量名含 `key` 之外无敏感内容，仍会被 `run_command` 环境清洗剔除 |

（仓颉原版另有 `BOT4CJ_NO_GC` 长脚本开关，用于规避仓颉运行时并发 GC 缺陷——本 C++ 移植版无仓颉运行时、不存在该缺陷，未实现此变量。）

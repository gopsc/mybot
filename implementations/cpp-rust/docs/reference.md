# 命令行与环境变量参考

> 本文收录 bot4cj 运行时的全部可调接口：CLI 参数、动作输入源、安全约束与环境变量。[README](../README.md) 中只保留快速开始。

## 环境要求

| 组件 | 说明 | 状态 |
| --- | --- | --- |
| Linux | 缺省 glibc HAL 后端经 ffi 直调 glibc（open/ioctl/read/write/usleep）；musl 验证范围见 [faq.md](faq.md) 与 [hal.md](hal.md) | ✅ 必需 |
| CMake ≥ 3.16、C++17 编译器 | g++ / clang++ | ✅ 必需 |
| LuaJIT 2.1（`libluajit-5.1-dev`） | 驱动与 HAL 全部在 LuaJIT 上 | ✅ 必需 |
| Python 3 | `scripts/tcp_e2e.sh` 的 TCP 客户端与假模型服务需要（缺则守门自动跳过） | ⭕ 可选 |
| `/dev/i2c-*` | 真机总线 | ⭕ 可选（无总线时全流程可用内存仿真跑） |

## 命令行参数

程序名为 `mybot`。缺省无参数时打印帮助。参数支持 `--key=value` 与 `--key value` 两种写法（`src/cliargs.cpp:parseArgs`）；未知或拼错的 `--key` 一律报错并以退出码 **2** 结束（不再静默忽略），`--help` 始终优先。

| 参数 | 说明 |
| --- | --- |
| `--robot <path>` | **必选**，机器人结构脚本 `.sql` 路径；打不开或解析失败会给出人话提示并退出 1 |
| `--help` | 打印帮助手册 |
| `--tcp <port>` | TCP 模式：监听端口接受**一次成功连接**并读取对端下发的 `.mt`（EOF 或空闲超时按输入结束；单连接一次性批量下发，非流式长驻） |
| `--tcp-host <addr>` | TCP 监听地址，缺省 `127.0.0.1`；跨机监听（如 `0.0.0.0`）**必须**同时提供 `--tcp-token`，否则拒绝启动 |
| `--tcp-token <tok>` | TCP 口令：跨机监听必填；对端须先发一行 `"<tok>\n"` 再发脚本。也可用环境变量 `BOT4CJ_TCP_TOKEN` 传递（多用户机器上推荐，理由见下） |
| `--tcp-idle <sec>` | TCP 空闲超时，缺省 30s，合法范围 1-86400（超时按输入结束处理） |
| `--tcp-max-auth-attempts <N>` | TCP 口令连续失败上限，缺省 5，合法范围 1-1000（连败到此数即放弃等待，防无限爆破） |
| `--tcp-total-timeout <sec>` | TCP 连接总时长预算下限，缺省 600，合法范围 1-86400；生效值取该下限与 `--tcp-idle` ×20 的较大者 |
| `--input <path>` | 从文件读取动作脚本 |
| （缺省） | 从 stdin 管道读取 |
| `--daemon-grace-ms <ms>` | 守护线程弃管后的二段停机宽限上限，缺省 30000，合法范围 0-300000；仅结构脚本含 `@Daemon` 时生效，与 `--tcp`/`--input`/`--mcp-backend` 任一模式无关 |
| `--mcp-backend` | **agent 工具后端**：把 agent 工具层经本地 AF_UNIX socket 暴露给 Rust agent（`mybot-agent`，经 `--socket` 连接；模型循环已迁 Rust，见 [agent.md](agent.md)）。独立模式：不跑模型循环、不发起模型调用，硬件常驻内存；与 `--tcp`/`--input` 互斥，需要 `--robot` 与 `--mcp-socket` |
| `--mcp-socket <路径>` | AF_UNIX socket 路径（`mybot-agent` 的 `--socket` 连这里）。父目录建议 0700、socket 文件 0600；对端经内核 SO_PEERCRED 校验 uid/gid（不可伪造） |
| `--mcp-call-budget <N>` | 每连接工具调用上限（跑飞护栏；0/空 = 不限，缺省不限；上限 1000000）。后端不假设调用方是谁，故自行再强制一层预算 |
| `--mcp-wall-clock <秒>` | 每连接墙钟预算（0/空 = 不限，缺省不限；上限 86400）。单次物理调用的 script/command 超时始终在工具层生效 |
| `--mcp-idle-timeout <秒>` | 每连接空闲（无帧）超时（0/空 = 不限，缺省不限；上限 86400）。让「连上后一声不吭」的哑连接按时让出唯一的 accept 槽；墙钟预算同样在空闲期收口（到点断连，对端可重连） |
| `--on-disconnect <脚本>` | **断连安全动作**：连接结束（对端关闭 / agent 崩溃 / 空闲或墙钟超时 / 协议违规——任何原因）后，后端自行执行的动作脚本（`--scripts-dir` 之下的相对路径，如 `zero.mt`）。缺省不执行——此时硬件停在**最后一个姿态**带电常驻。脚本在上电前预检（越界 / 不存在 / 为空即退出 2，判据与 `run_action_script` 同源）；**不经策略确认**（它是操作者预设的安全动作，不是模型请求）；执行失败只记日志与审计（`kind=session, status=disconnect_action`），后端继续 accept。SIGINT/SIGTERM 停机不触发（走 `deactivate()` 断电清理链）。**只能命令行给**（它决定断连后硬件做什么，与 `--agent-shell` 同判据） |

> **已移除（2026-09-24）**：`--agent` 与模型循环类选项（`--task`、`--llm-*`、`--prompt-file`、`--session-file`、`--resume`）。agent 循环已迁 Rust（`agent/` 目录，`mybot-agent`）：C++ 宿主侧以 `--mcp-backend` 提供工具后端，模型侧参数由 `mybot-agent` 自己的选项面承载（`./agent/target/release/mybot-agent --help`，构建：`bash scripts/build_agent.sh`）。本程序对上述残留用法显式拒绝（退出 2）并给出替代指引。

以下为 C++ `--mcp-backend` 的工具与配置选项：

| 参数 | 说明 |
| --- | --- |
| `--scripts-dir <目录>` | agent 动作脚本根目录，也是 `run_action_script` 的路径沙箱边界（缺省 `scripts`） |
| `--agent-shell` | **显式开启**智能体的 `run_command`（任意 shell 执行）；**缺省不提供**，开启须有覆盖该工具的 policy。命令**回执**（stdout/stderr）在回传模型前遮蔽 `KEY=VALUE` 等敏感值（G1，与审计同一单点）；遮蔽不构成同 uid 进程间的密钥隔离 |
| `--agent-hot-sql` | **显式开启**智能体的 `apply_sql`（结构 SQL 带电生效：`CREATE TABLE`/`INSERT INTO` 立即装配并上电，失败整批回滚；**`DELETE FROM` 当场断电摘除匹配行——物理不可逆**，故被引用着的变量会被拒绝，详见 [dsl.md](dsl.md)）；**缺省不提供**该工具。只能由后端命令行授权，且须有覆盖 `apply_sql` 的 policy；配置文件不能自行开启。只读的 `query_sql` 不受影响 |
| `--read-var <变量名>` | 声明一个**可读**硬件变量（可重复；注册 `read_variables` 与 `wait_variable` 工具，让智能体主动读器件当前值、或轮询等某个读数满足条件）。**缺省不提供**这两个工具：执行器（`Servo`/`Relay` 等）与传感器同属 `kind=lua`，靠种类分不出，故由操作者显式列名；只有已注册且种类为 `lua`/`daemon` 的名字生效（`daemon` 读的是已发布的采样快照，无 I2C 流量）。**只能命令行给**：配置文件写 `read_vars` 会被拒绝加载并退出 2（与 `allow_shell` 同判据） |
| `--fs-root <目录>` | **list_dir / read_file 的只读根目录**（Phase 4，2026-10-07）：注册这两个只读文件工具，访问范围限定在该目录之下（`agent_sandbox.hpp` 的 `resolveUnderRoot`：词法 + canonical 根包含性，符号链接逃逸一律拒绝）。与机器人硬件/shell 无关——单纯是"给模型看某几个文件"的窄接口。**缺省不提供**这两个工具。**只能命令行给**：它决定"能读哪个目录"，配置文件写 `fs_root` 会被拒绝加载并退出 2（与 `read_vars` 同判据）；启动时校验该目录必须真实存在，否则退出 2（配置错误不碰真机） |
| `--agent-write-file` | **显式开启** `write_file`（Phase 5，2026-10-08）：在 `--fs-root` 根之内创建/覆盖一个文本文件（先写同目录临时文件再原子落地——新建用 `link`、覆盖用 `rename`，均不留半截内容；目标是符号链接一律拒绝）。目标已存在时**默认拒绝覆盖**，须显式传 `overwrite:true`（覆盖不可逆）；大小上限 64 KiB、不接受含 NUL 的内容；父目录须已存在（不自动创建）；落地文件权限 **0600**（不随 umask 放宽，别的用户/进程读不到）。**依赖 `--fs-root`**：给了本开关却没给 `--fs-root` 在上电前即报错退出 2。危险性与 `run_command`/`apply_sql` 同级：**只能命令行给**，配置文件写 `allow_write_file` 会被拒绝加载；`--mcp-backend` 下开它**强制**要求 policy 且 `require_confirm` 包含 `write_file` |
| `--agent-policy <路径>` | 策略钩子（严格 JSON）：声明哪些工具的每次调用要先过**外部确认程序**（stdin 收工具名与遮蔽后的参数 JSON，退出 0 = 放行；超时按 `on_timeout`，缺省 `deny`）；缺省**不启用**。也可用配置文件 `agent_policy` 字段（详见 [agent.md](agent.md)） |
| `--camera-var <变量名>` | 承载摄像头驱动（`modules/Camera.lua`）的变量名（缺省 `cam0`）；结构脚本已声明则直接用 |
| `--camera-device <路径>` | 摄像头设备（缺省 `/dev/video0`，需支持 MJPEG；驱动只放行 `/dev/videoN`） |
| `--camera-src <图片>` | 模拟图片来源：不接摄像头也能跑通「拍照 → 进上下文」。**命令行**给的 src 以其所在目录为白名单根；**配置文件**给的 `camera_src` 不推导根（H1：`dirname(src)` 当然包含 `src`，用它当根等于判据恒真、白名单形同不存在），需配 `--camera-src-dir` 或 `BOT4CJ_CAMERA_SRC_DIR`，否则驱动默认拒绝 |
| `--camera-src-dir <目录>` | `capture_image` 模拟图片的**白名单根目录**，优先级高于上面的推导。**只能命令行给**：它放宽读权限，配置文件写 `camera_src_dir` 会被拒绝加载并退出 2（与 `allow_shell` 同判据） |
| `--no-camera` | 不向智能体提供 `capture_image` |
| `--check-config` | （与 `--mcp-backend` 联用）只校验配置并打印摘要，随后以 **0** 退出：**不装载结构脚本、不上电、不发起任何网络请求**。用于「配置文件写错了但不想真起后端」（接了硬件也不必反复上下电）。配置本身仍由 `buildAgentConfig` 单点校验，失败退出 **2**；会**打开但不写入**审计日志文件（顺带验证其可写）。agent 侧的配置校验用 `mybot-agent --check-config` |
| `--audit-log <路径>` | 审计轨迹（JSON Lines 追加写）：每次工具调用一条记录（时间戳/轮次/工具/参数/成败/耗时/退出码）；图片只记体积与指纹，命令原文里的 `KEY=VALUE` 敏感值先遮蔽，`apply_sql` 等工具另记结构化生效摘要（`summary`）；`-` 表示写 stderr；缺省**不记录**。也可用配置文件 `audit_log` 字段（详见 [agent.md](agent.md)） |
| `--webshell-port <端口>` | Web SSH 模式监听端口（1–65535；**给本选项即启用 Web SSH 服务**，无缺省端口——不给则不启动）。与 `--robot`/`--agent`/`--mcp-backend` 互斥（同给即退出码 2） |
| `--webshell-host <地址>` | Web SSH 模式绑定地址，缺省 `127.0.0.1`；绑定**非回环**地址时必须同时给 `--webshell-token`，否则拒绝启动（退出码 2） |
| `--webshell-token <值>` | Web SSH 访问令牌（query 参数 `?token=` 校验，经 RFC 6455 WebSocket 升级前的 HTTP 请求头比对；`/ws/term` 与首页共用同一校验，令牌错误返回 401）。绑定非回环地址时**强制**要求，回环绑定可不给（缺省不限制）；WebSocket 帧层有独立的拒绝式解码（未掩码/RSV/非法 opcode/控制帧超 125/消息超 64KiB 一律拒绝） |

**选项归属与拒绝规则**：脚本目录、摄像头、`--read-var`、`--fs-root`、`--agent-write-file`、危险开关和 `--agent-policy`
属于 C++ 后端；上述后端选项不带 `--mcp-backend` 会退出 **2**，后端与 `--tcp` / `--input` 互斥。
`--agent` 已移除；`--task` / `--prompt-file` / `--llm-*`（包括 `--llm-config`）/
`--session-file` / `--resume` 只属于 Rust，C++ 中即使带 `--mcp-backend` 也拒绝并退出 **2**。
Rust 不接受后端能力开关；两端同名的 `--audit-log` / `--check-config` 各自作用于本进程，
不能替代另一端的配置或校验。C++ 显式配置文件入口仅 `BOT4CJ_LLM_CONFIG`。
后端开 `--agent-shell` / `--agent-hot-sql` / `--agent-write-file` 时强制有 policy，且 `require_confirm`
分别包含 `run_command` / `apply_sql` / `write_file`，否则上电前拒绝启动。

**TCP 模式的安全设计**（上面几条参数背后的原因）：

- 口令校验失败只关闭该连接、回到 accept 等待，**连续失败**（缺省 5 次，可用 `--tcp-max-auth-attempts` 调整）才退出——既防单次连接 DoS，也防无限爆破
- 口令校验为**恒时比较**（防时序侧信道，审计 M1）
- argv 会出现在 `/proc/*/cmdline`、对本机所有用户可读——多用户机器上传 TCP 口令请用环境变量而非命令行（API key 同理：宿主**不提供**命令行传密钥的选项，只从环境变量或配置文件取）
- 连接另有**总时长预算**（缺省下限 600s，可用 `--tcp-total-timeout` 调整；生效值取该下限与 `--tcp-idle` ×20 的较大者）从连接建立起算：慢滴发送（每 <idle 秒发 1 字节）不能无限期挂住进程
- **本通道明文无加密**（口令与脚本正文都走明文 socket，TLS 未实现）：仅限**可信内网/本机**使用；跨信任域请自行加隧道，或改用文件/标准输入源

**agent 取值优先级**：对支持相应入口的字段，命令行 > 环境变量 > 配置文件 > 内置缺省。
Rust 的 endpoint、model 与 API key 必须提供。两端可使用同一份 JSON，但各自消费所属字段；
Rust 对后端能力字段只登记、不解析或授权，不能替代后端校验。
模板为 `mybot.llm.json.example`，字段表与双端查找顺序见 [agent.md](agent.md)。

**中断语义（两进程）**

Ctrl-C / SIGINT / SIGTERM 只作用于收到信号的进程，首次置停止标志，**不是立即停止一切**：

1. **Rust `mybot-agent`**（`agent/src/main.rs` / `model.rs` / `hook.rs`）：在检查点停止
   后续模型调用、重试和工具派发。在飞模型请求没有信号级取消，须等返回或
   `--llm-timeout` 超时（缺省 180s，范围 1–600s）；退避中的停止检查也要等本次退避结束。
   REPL 正常收尾写 session end、退出 0；一次性 `--task` 若返回中断错误，则写 session error、退出 1。
2. **C++ 工具后端**（`src/main.cpp` / `mcpbackend.cpp`）：`stopRequested()` 使服务循环退出，
   然后经 `runRobotAndCleanup` 调 `deactivate()`（守护 join → 驱动 destroy → 硬件去初始化）。
   动作脚本在行间停派发；`action_script_timeout_sec` 预算窗口内的 Lua 指令计数钩子
   也检查停止标志，但**打不断阻塞的 FFI 系统调用，已下发的物理动作不能收回**。
3. **停止 agent 不等于后端断电**：Rust 退出/断连后，后端仍可等待下一条连接；
   需要停机断电时须向后端发停止信号，并等待其清理完成。

**沿革（SAN-7 / P2a）**：旧 C++ `--agent` 曾创建 `/tmp/mybot-cancel-<pid>`，
由 Lua/libcurl 进度回调取消请求；原场景的约 1s 取消与哨兵清理断言只描述旧链路。
该宿主机制已移除，不能用来推断 Rust 在飞请求的取消时延。现役两进程回归见
`scripts/agent_e2e.sh` 与 `scripts/mcp_e2e.sh`，编号以 [testing.md](testing.md) 为准。

**第二次信号是逃生口，不是常规操作**：Rust 立即退出 130；C++ 恢复缺省信号处置并重新触发。
两者都跳过正常清理，不能保证硬件安全停下。驱动阻塞或守护拒绝退场时尤其要注意。
`~RobotStruct` 仅在正常对象销毁时补断电；强制退出不走析构，不能依赖它兜底。

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
| `BOT4CJ_MODULE_PATH` | 驱动模块目录（默认 `./modules`），`<矩阵名>.lua`、`lib/`、`@Daemon` 的 chunk 都按它解析；支持 `:` 分隔多路径按序查找。宿主建沙箱时按该列表**逐段探测 `lib/mpath.lua`** 并注入 `__mpath`，驱动与 `lib/` 的后续解析都走它——多路径对全部 60 个模块成立（2026-09-20 重构阶段 2 之前只有宿主侧成立，驱动侧 `:match("[^:]+")` 只取首段）。边界：**脱离宿主**直跑（`luajit test/*.lua`、`scripts/scscl_scan.lua`）没有 `__mpath`，此时回退单根语义，请把含 `lib/` 的根放首位 |
| `BOT4CJ_DEBUG` | 设为 `1` 开启 call/build/destroy 的参数表、结果表、逐键值转储；缺省静默 |
| `BOT4CJ_TCP_TOKEN` | TCP 口令（等价 `--tcp-token`，优先级低于命令行）。argv 会出现在 `/proc/<pid>/cmdline`，多用户机器上推荐用本变量传口令 |
| `BOT4CJ_MCP_TOKEN` | MCP 后端首帧共享密钥（2026-09-29，审计 P2-1）。**两个进程读同一个变量**：后端（`mybot --mcp-backend`）在宿主环境抹零前捕获，agent（`mybot-agent`）连接后第一帧发 `{"_route":"auth","token":...}`。非空时密钥不匹配/不发认证帧的连接一律拒绝并断连（审计记 `auth_failed`）；未设置则退回「仅 SO_PEERCRED」的旧行为——同 UID 进程（含模型驱动的 `run_command` 子进程）可直连 socket 绕过 agent 侧预算，建议开后端模式时设置。设置但为空/超 256 字节 = 配置错误拒绝启动。名字含 `token`，被 `run_command` 的环境清洗自动剔除——子进程拿不到它 |
| `BOT4CJ_LLM_KEY` | 由 **Rust `mybot-agent`** 读取并用于 provider 请求头；回退顺序：`ROBOT_AGENT_API_KEY` → `DEEPSEEK_API_KEY` → 配置文件 `api_key` / `api_key_file`。不经后端工具参数或 `BOT4CJ_DEBUG` 转储；后端若继承了该变量，`run_command` 的环境清洗会剔除它。两进程启动第一件事都是 `prctl(PR_SET_DUMPABLE, 0)`（见 `BOT4CJ_ALLOW_PTRACE`），同 uid 进程读不到 `/proc/<pid>/environ`、`mem`，也不能 `ptrace` 附着——但 root / `CAP_SYS_PTRACE` 不受此限 |
| `BOT4CJ_ALLOW_PTRACE` | 设为 `1` 时 **`mybot` 与 `mybot-agent` 都不再**在启动时 `prctl(PR_SET_DUMPABLE, 0)`，进程保持可被同 UID `ptrace`（gdb/strace attach）、崩溃落 core、`/proc/<pid>/environ` 与 `mem` 对同 UID 可读；两进程各自向 stderr 打一行「注意」。**仅调试用**——密钥、TCP 口令都可自内存读出。缺省（不设）为不可 dump；`prctl` 失败只告警不拒启。sanitizer 构建（`-DMYBOT_SANITIZE=...`）**编译期跳过**这一步（LeakSanitizer 需要 ptrace 自身），不看本变量 |
| `BOT4CJ_LLM_CONFIG` | 两端各自读取的配置文件路径。Rust 优先级为 `--llm-config` > 本变量 > 缺省查找；C++ 后端显式指定路径只能用本变量，不接受 `--llm-config`。`none` 禁用对应进程的配置文件读取；须分别传给两进程 |
| `BOT4CJ_AGENT_HISTORY` | **Rust `mybot-agent`** 交互 REPL 的历史文件路径（仅 stdin+stdout 都是终端时启用）；`none` 关闭落盘（历史只留本会话）。未设则 `$XDG_STATE_HOME/mybot-agent/history`，再退到 `~/.local/state/mybot-agent/history`。目录 0700 / 文件 0600 建立；已存在文件对同组/其他用户可读会提醒。管道面不读不写该文件 |
| `BOT4CJ_LLM_ENDPOINT` / `BOT4CJ_LLM_MODEL` | Rust agent 接入点 / 模型名（覆盖配置文件，低于命令行；两项均无内置缺省） |
| `BOT4CJ_HAL_BACKEND` | HAL 后端模块名：`modules/lib/hal_backend_<名>.lua`（缺省 `glibc`）。加载期逐项断言契约函数齐全，缺函数 fail-fast——移植到别的 libc/平台时替换整个后端 |
| `BOT4CJ_CAMERA_SRC_DIR` | 摄像头仿真来源的**放行目录**（冒号分隔）：`--camera-src` 之外的路径必须落在这里面，否则驱动拒绝读该文件（缺省禁用任何目录外读取） |
| `BOT4CJ_PROMPT_DIR` | 提示词包的**放行目录**（冒号分隔，H2）：**配置文件** `prompt_files` 里的路径必须落在当前工作目录或这里列出的目录之内（命令行 `--prompt-file` 不受限）。配置文件写不了本变量，故它只能由启动者设——现场把提示词包放在工作目录之外时用它显式放行 |
| `BOT4CJ_TEST_VIDEO` | 仅守门用：真机摄像头用例（`test_camera_v4l2.lua`）的设备路径，指定且存在时该用例不再按跳过计（见 [testing.md](testing.md)） |
| `BOT4CJ_TRACE_FDS` | 仅守门用：`mybot_tests` 专用测试钩子（生产二进制不含），见 [testing.md](testing.md) |
| `BOT4CJ_ICA` | Rust agent 侧设为 `1` 开启实验性 ICA 证据账本（8 个 `ica_*` 本地工具 + sidecar 落盘），边界见 [ica.md](ica.md) |
| `SHELL` | Web SSH 模式下 PTY 里 exec 的交互 shell（`src/webterm.cpp` 取 `$SHELL`，空/未设回落 `/bin/sh`）；仅 Web SSH 进程用到 |
| `MYBOT_HOME` | 状态目录根（本机持久数据：agent 的对话历史、sim 的地图）。取值链：`MYBOT_HOME` 非空 → 用它；否则 `$HOME/.mybot`；两者都取不到 → 状态目录不可用（agent 不落盘对话历史并如实说明，sim 拒绝解析相对场景名）。**本行是这条规则的单点**，它有三处实现（跨两套构建系统 + 一个 shell 脚本，刻意不做代码生成）：Rust `agent/src/config/mod.rs` 的 `derive_state_dir`、C++ `sim/src/sim_paths.cpp` 的 `mybotHome`、shell `scripts/sim_agent_demo.sh`；缺省目录名 `.mybot` 的三处一致由 `test/run_all_selftest.sh` 钉住。目录下的布局：会话历史见 [agent.md](agent.md)，地图播种见 [sim.md](sim.md) |
| `MYBOT_SIM_SOCK` | 仿真器**命令桥**的 AF_UNIX 路径（缺省 `/tmp/mybot-sim.sock`）。sim 侧取值序 argv[1] > 本变量 > 缺省（`sim/src/main.cpp`），驱动侧 `modules/Sim.lua` 读同一个变量——两端不用各自配置。**多机器人**时每只一套：robot 0 用原路径逐字不变，robot i>0 在 `.sock` 前插 `-<i>`（`deriveRobotPath`）。线上协议与动作码 0–10 见 [sim.md](sim.md) |
| `MYBOT_SIM_CAPTURE_SOCK` | 仿真器**拍照桥**路径（缺省 `/tmp/mybot-sim-capture.sock`），sim 侧 argv[2] > 本变量 > 缺省。`modules/Camera.lua` 只在本变量**非空**且本次调用没给文件 `src` 时才向仿真器取帧（未设＝不启用这条来源） |
| `MYBOT_SIM_SENSOR_SOCK` | 仿真器**测距桥**路径（缺省 `/tmp/mybot-sim-sensor.sock`），sim 侧 argv[3] > 本变量 > 缺省；`modules/Sim.lua` 的 `range` 函数走它一问一答（发 `range\n`，收 `OK <mm>` 或 `ERR <reason>`） |
| `MYBOT_SIM_IMU_SOCK` | 仿真器 **IMU 桥**路径（缺省 `/tmp/mybot-sim-imu.sock`，2026-10-16），sim 侧 argv[5] > 本变量 > 缺省；`modules/Sim.lua` 的 `imu` 函数与 `lib/sim_sensor_daemon.lua`（`kind=imu`）走它一问一答（发 `imu\n`，收 `OK <yaw_deg> <gyro_z> <acc_fwd> <vy> <airborne>` 或 `ERR <reason>`） |
| `MYBOT_SIM_ODOM_SOCK` | 仿真器**里程计桥**路径（缺省 `/tmp/mybot-sim-odom.sock`，2026-10-16），sim 侧 argv[6] > 本变量 > 缺省；`modules/Sim.lua` 的 `odom` 函数与 `lib/sim_sensor_daemon.lua`（`kind=odom`）走它一问一答（发 `odom\n`，收 `OK <x> <z> <theta_deg> <v> <odo>` 或 `ERR <reason>`） |
| `MYBOT_SIM_SCENE` | sim 启动时的场景落点：argv[4] > 本变量 > 缺省裸名 `default`。**含 `/` 的值当显式路径直接用**；裸名解析为 `$MYBOT_HOME/maps/<名>.scene`，且**还须能找到同名模板**做首次播种——模板目录是编译期宏 `MYBOT_SIM_SCENES_DIR`（`sim/CMakeLists.txt` 指到源码树 `sim/scenes`），未命中再回退 exe 相对 `../scenes/`。两处都没有该模板时 sim 打一行 `未找到模板 …` 并**静默退回内置默认场景**，此时场景路径为空、退出即保存不写盘；要绕开模板查找就传绝对路径。各桥 socket 与本变量的组合跑法见 [sim.md](sim.md) |

（仓颉原版另有 `BOT4CJ_NO_GC` 长脚本开关，用于规避仓颉运行时并发 GC 缺陷——本 C++ 移植版无仓颉运行时、不存在该缺陷，未实现此变量。）

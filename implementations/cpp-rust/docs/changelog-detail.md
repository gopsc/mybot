# 更新日志

> 从 [README](../README.md) 迁出，按主题分组记录版本演进要点，组内大致按时间倒序。
> 每条只留「改了什么、对使用者意味着什么」——设计论证、实现落点、守门明细（用例名单、
> 反向验证过程、当时的测试计数快照）不在此复述，以 docs/ 各文档、`bash test/run_all.sh`
> 与 `./build/mybot_tests` 的实时输出（`docs/development.md` 单一事实源约定）为准。
> 本文件压缩前的完整版本见 git 历史；提案文档（原 `docs/proposals/` 与 `.tmp/*` 计划
> 文件）已移出仓库，历史版本见 git（截至 `46f90d8`）。

## v1.x（C++ 移植版）

### 2026-09-29 三项安全收口：MCP 首帧共享密钥 / 停机灭火 / 信任前提体检

- **MCP 首帧共享密钥 `BOT4CJ_MCP_TOKEN`（审计 P2-1）**：设了它，`SO_PEERCRED` 之上每条连接
  还须先过 `{"_route":"auth","token":...}` 认证帧（常数时间比对，失败断连 + 审计
  `auth_failed`）。此前 `mcpbackend.hpp` 自陈的同 UID 直连绕过 agent 预算的残留风险从此
  有了可选项：密钥名含 token，被 `run_command` 的环境清洗自动剔除，模型驱动的 shell 拿不到。
  设置但为空/超 256 字节拒绝启动（不静默退回无认证）。C++ 与 Rust 两侧读同一环境变量，
  旧版不配对会在报错里点名（unknown route ↔ auth required）。
  回归：`test_mcpbackend` 三态单测、`mcp_e2e.sh` M6、`agent_e2e.sh` R17（两进程正反面）。
- **停机灭火协议（审计 P2-3）**：守护共享槽新增 `quiesce` 位（offset 592，槽 592→600B），
  `DaemonRunner` 停机序列重排为「等待（不弃管）→ 宽限 → 仍未退场才**先灭火再弃管**」。
  灭火后该守护经 HAL 的一切真实总线传输（i2c/spi/uart）在进内核前被拒——「弃管守护触
  总线」的竞态窗口从无界收敛到在途单次传输。与 `stop` 分离是刻意的：宽限内退场的守护
  还要跑 `daemon_cleanup` 去初始化，传输必须放行。回归：`test_hal_quiesce.lua`、
  `test_daemon.cpp` finishTeardown 两态、既有 `daemon_grace_ms` 文案锚点不变。
- **信任前提体检（审计 P2-2）**：驱动/守护 chunk/白名单 dofile 三个加载点在加载前体检
  文件权限，**组或其他人可写即响亮告警**（`auditTrustedFilePath`，每路径一次）——ffi 全
  能力文件的「可信域」前提被削弱时操作者必须看得见。`os.getenv`/`io.read` 有意保留不动：
  ffi 面前 Lua 级白名单是化装。另：`__mpath` 注入失败（找不到/加载坏）从静默 fail-open
  改为响亮告警（多段路径时），单段场景保持安静（测试夹具常态）。

### 2026-09-25 删除 Lua 协议驱动轨道（#8）

- **对使用者意味着什么**：`modules/LlmOpenAI.lua` / `LlmDeepSeek.lua` / `LlmAnthropic.lua`
  及配套 `lib/llm_http.lua`、`lib/llm_wire_*.lua` 整条 Lua 模型调用轨道删除（11 个文件：
  3 驱动 + 4 库 + 2 离线用例 + 1 常量自检 + 1 泄漏抑制文件）。模型调用唯一路径是 Rust
  `mybot-agent`（rig 直连，reqwest + rustls）；`LlmOpenAI`/`LlmDeepSeek`/`LlmAnthropic`
  三个名字现在只是 `--llm-driver` 的**协议族名**（`agent/src/provider.rs` 内建），不再是
  可装载的驱动表名。仓库不再有 libcurl 依赖：apt 行、CI 安装包、`test_curl_consts` 目标
  与 `asan.supp`（libcurl → libcrypto 的 LSan 残留抑制）一并移除。`test/run_all.sh` 的
  agent-all Lua 段此后**有意跑 0 个文件**（过滤器与 SAN-2 花名册机制保留，将来若再出现
  `test_llm_*.lua` 会被自动纳入自证）。
- **动机**：C++ agent 轨道清退后，Lua 协议驱动只剩「供 `.mt` 脚本/`@Daemon` 直接调用」
  一个下游；四份协议实现（三族 wire 整形 + libcurl ffi）的回归只能离线守整形规则，
  而模型侧行为已由 Rust 侧 R12/R13 全量覆盖——重叠维护不再值当。
- **保留**：`mybot.llm.json` 双端解析与 R5m 互钉（模型侧字段归 Rust，共享面 C++ 仍校验）、
  `utf8.lua`（与 C++ 侧同表向量互钉的通用库）、`agent_e2e.sh` 的历史场景索引与审计里的
  驱动名字段（R12/R13 仍按三族名验证现役 Rust 语义）。

### 2026-09-25 capture_image 可请求采集尺寸（width/height）

- **对使用者意味着什么**：智能体拍照片可以按需请求分辨率——需要看清细节时加大，
  图片逼近 2 MiB 历史预算时改小（此前「图像过大」的报错只能提示「降低分辨率」，
  却没有降低分辨率的工具入口）。`width`/`height` 为可选整数（16..8192，须同时给出），
  缺省仍是 640x480；换尺寸会重开设备重协商 `VIDIOC_S_FMT`，比同尺寸连拍贵。
- **如实语义**：设备常把请求就近调到支持档位（请求 300x200 得 320x240），回执报
  **实际**尺寸并说明「被设备就近调档」；仿真来源（`--camera-src`）不缩放图片，
  请求尺寸在回执里明说「无效」。驱动按**请求值**（而非协商值）判是否重开，避免
  同请求每次调用都因调档差异而白重开。
- **落点**：`modules/Camera.lua`（尺寸解析/校验 + 重开判据）、`src/agentimage.cpp`
  （schema 两个可选参数、界值单点、回执文案）、`test_camera.lua` 与
  `test_agenttools.cpp`（15 + 4 条新用例，S_FMT 桩验证「变尺寸重开/同尺寸不重开/
  调档值比对」）。参数错误（只给一个、越界、非整数）在触碰硬件之前按 paramError
  口径拒绝。

### 2026-09-25 CI 六条软门禁全部转硬（TSan / clang / clang-tidy / coverage / musl / agent）

- **对使用者意味着什么**：推送到任何分支，十条 job 全部必须绿；此前 `allow_failure`
  的六条不再能「红着合并」。转硬依据如实写在 `.gitlab-ci.yml` 文件头：原条件「CI 上
  连续 2 轮全绿」从仓库内部不可观测，改以同版本工具链的本地预跑为判据（LLVM 14.0.6、
  alpine 3.20、rustc 1.98.1、TSan 5 轮）。
- **预跑揪出并修掉的真问题**：
  - musl：`hal_backend_glibc.lua` 的 `version()` 契约是「非 glibc 返 nil」，实际在取
    `gnu_get_libc_version` 符号那步抛 `Symbol not found`（pcall 只包了 cdef），拖垮
    `test_uart` / `test_uart_baud` / `test_hal_backend_swap`；两个 UART 用例的独立推导
    同样直取符号，改为 pcall 并按非 glibc 期望旧编号表。`docs/faq.md`「非 glibc 未验证」
    改为「musl（alpine 3.20 x86_64）已实证」。
  - clang-tidy：新功能引入 3 条（`main.cpp` 的 `getenv`/`strerror` 未走 `util.hpp`
    单点、`agenttools.cpp` 一处 string 链式拼接），改走 `getEnvVar`/`errnoText`/`concatMsg`。
  - Rust：2 条 clippy `manual_async_fn`（`model.rs` 的 `RawStream` 两个 impl 改 `async fn`）
    + 5 个文件的 rustfmt 差异。
- **`gate:musl` 扩容**：从「三常量自检 + 能编则跑 mybot_tests」扩为「常量自检 →
  mybot_tests → 整段 `test/run_all.sh`」（alpine 加装 bash/coreutils/python3；Rust 段
  因镜像无产物按 SKIP 计）。`gate:clang-tidy` 的计数行同时数 `error:`（此前
  `--warnings-as-errors` 下永远报「告警总数 0」）。`gate:coverage` 的「硬」不设阈值，
  判采集链路完整（AG-11 结论不变）；本地基线 78.10%（5842/7480）。

### 2026-09-25 Rust agent 会话历史压缩：被裁任务块压成摘要挂进系统提示词

- **长会话不再「忘光」**：`max_history_bytes` 裁掉最早的任务块时，被裁块交给同一个模型
  压成一段摘要（与已有摘要合并），挂在系统提示词末尾的「更早对话的摘要」一节。摘要不进
  `messages`，块判据、失败回滚、图片后注序号一律不受影响；预算先扣掉摘要一节再裁。
- **切口只落在任务块起点**：一对 `tool_call`/`tool_result`、一问一答永远不会只剩一半
  ——被裁部分整块送摘要、留下部分整块送模型（单测钉死不变量）。恢复期把图片占位文本
  形态的后注也排除在块起点之外，否则「任务 + 最终回答」会被切开。
- **送去摘要的是数据不是指令**：转录只含文本（图片/思维链只留字节数），每条 4 KiB、
  总量 128 KiB 封顶，逐行 `> ` 定界并声明；摘要挂回提示词时再定界一次。
- **配置**：`history_summary`（缺省 `true`）、`max_summary_bytes`（256-1 MiB，缺省 8192，
  超出在字符边界截断并告警）；C++ 后端只登记不解析。`--check-config` 新增「历史摘要」行。
- **随会话文件恢复**：新记录 `session_summary`（`content` + `keep_blocks`），恢复时收口成
  最后 K 个块并带回摘要，就绪行报「含历史摘要 M 字节」；`/clear` 连摘要一起忘掉；摘要
  失败什么都不写（自愈）。
- **审计**：摘要请求单独成行 `kind=model, status=summary|summary_error`，不带 `turn`。
- 守门：`history.rs` / `summary.rs` / `session.rs` / `config.rs` 单测；`scripts/agent_e2e.sh`
  R11c（三任务 + `--resume` 接力，夹具 `summarize` 模式对摘要请求形态设 400 判据），
  R11b 显式 `history_summary=false` 作反向判据。

### 2026-09-25 wait_variable 工具：智能体能「等事件」了

- **新工具** `wait_variable(name, key, condition, value, timeout_sec, poll_ms)`：后端按
  `poll_ms`（缺省 200，50..5000）轮询 `--read-var` 清单内某个变量的返回表键，直到
  `gt/ge/lt/le/eq/ne/changed` 条件成立或 `timeout_sec`（缺省 30，上限 =
  `action_script_timeout_sec`）到期，一次调用给一个结论。此前模型要等「水位到 30」
  「守护计数推进」只能一轮一轮调 `read_variables`，每轮一次模型往返。
- **与 `read_variables` 同门控同副作用面**：同一 `--read-var` 解析集合、同样只走
  `playQuiet`；缺省不注册。**超时是结果不是失败**（`ok=true`，回执写明超时与最后读数，
  键不存在时列出样本现有键）；参数问题（非法条件、缺 `value`、越界、变量不在清单、键在
  而不是数值撞上排序条件）在触碰硬件前拦成 `paramError`。等待期间每 ≤100 ms 看一次停止
  标志，Ctrl-C 不会坐满超时。`summary` 给审计 `satisfied=… elapsed_ms=… samples=…`。
- 系统提示词在可读清单非空时同时引导 `wait_variable`；`--check-config` 摘要行改为
  `read/wait_variable`。

### 2026-09-25 Rust agent 交互 REPL 行编辑 / 历史 / 命令补全（rustyline）

- **终端上的 REPL 有了行编辑**：方向键、Ctrl-A/E/W/U、↑↓ 翻历史、Ctrl-R 搜索、`/命令`
  Tab 补全；提示符处 Ctrl-C 清当前行不退出（退出仍是 `/exit` / Ctrl-D），模型轮内
  Ctrl-C 的取消语义不变。此前是裸 `BufReader::lines()`，方向键只会打出转义序列。
- **历史跨会话保留**：`$XDG_STATE_HOME/mybot-agent/history`（退到
  `~/.local/state/…`），目录 0700 / 文件 0600，上限 1000 条；`BOT4CJ_AGENT_HISTORY=<路径|none>`
  改位置或关闭。已存在文件权限过宽会提醒，不擅自改。
- **管道面不变**：stdin 或 stdout 任一不是终端就走原来的裸逐行读——提示符写 stdout、
  一行一任务、EOF 退出，E2E 与脚本化调用的契约逐字节保留，也不碰历史文件。
- 新增直接依赖 `rustyline 18`（关缺省 feature，只开 `with-file-history`）。

### 2026-09-25 两进程启动即 `PR_SET_DUMPABLE=0`，同 UID 不能 ptrace / 读内存

- **`mybot` 与 `mybot-agent` 进入 `main` 第一步**（先于解析 argv）调
  `prctl(PR_SET_DUMPABLE, 0)`：同 UID 其他进程不能 `ptrace` 附着，`/proc/<pid>/environ`、
  `mem` 变为 root 属主不可读，崩溃不落 core——运行中进程内存里的模型密钥 / TCP 口令
  不再对同用户 shell 敞开。root / `CAP_SYS_PTRACE` 不受影响，`cmdline` 仍全机可读，落盘
  的密钥文件与此无关（docs/agent.md 安全说明第 3 条如实列出边界）。
- **调试逃生口** `BOT4CJ_ALLOW_PTRACE=1`：两进程都跳过这一步并各向 stderr 打一行「注意」。
  `prctl` 失败只告警不拒启。
- **sanitizer 构建编译期跳过**：`-DMYBOT_SANITIZE=...` 现在同时定义 `MYBOT_SANITIZE_BUILD`，
  `hardenAgainstInspection()` 据此直接返回——LeakSanitizer 的 StopTheWorld 靠 fork 出的
  tracer ptrace 回附父进程，不可 dump 会让 `gate:sanitizer` 结构性失效。

### 2026-09-25 后端断连安全动作 `--on-disconnect`

- **新选项** `mybot --mcp-backend --on-disconnect <脚本>`：连接结束（对端关闭 / agent 崩溃
  被杀 / 空闲或墙钟超时 / 协议违规——任何原因）后，后端自行执行 `--scripts-dir` 之下
  的动作脚本（如 `zero.mt`），把硬件带到操作者预设的安全姿态。缺省不执行，行为与此前
  一致（硬件停在最后一个姿态带电常驻）——docs/agent.md 已知限制「Rust 失败不会自动给
  后端断电」由此有了操作者可配的兜底。
- **上电前预检**：脚本越界 / 不存在 / 为空即退出 2，判据与 `run_action_script` 同源
  （`loadActionScriptFile` / `runActionScriptFile` 自工具里抽成公开函数，工具与断连
  动作共用一份）。`--check-config` 摘要新增「断连安全动作」行。
- **不经策略确认**：它是操作者配置、不是模型请求，`require_confirm` 不拦它。执行失败
  只记日志与审计（`kind=session, status=disconnect_action, summary=<脚本>`，失败带
  `error`；session 记录的 `summary` 为加法字段），后端继续 accept。SIGINT/SIGTERM 停机
  不触发（走 `deactivate()`）。命令行独占，非 `--mcp-backend` 下给出即拒绝。

### 2026-09-25 Rust agent 模型输出改流式（缺省），Ctrl-C 即时丢弃在途请求

- **流式输出成为缺省**：`mybot-agent` 请求带 `stream:true`，模型正文按 SSE delta
  逐段打到 stdout（每段即刻 flush，管道下游同步可见），工具轮之间换行分隔；
  `--llm-no-stream` 或配置文件新字段 `"stream": false`（布尔，两端识别，仅 Rust 消费）
  退回原先的整段阻塞输出。`/status` 与 `--check-config` 摘要新增「输出模式」行。
- **重试 / 超时 / 审计口径不因面而异**：首帧之前的非 2xx、连接失败、首帧超时按与阻塞面
  同一张表分类重试；`--llm-timeout` 在流式下封顶首帧与之后的帧间空闲；审计 model 行
  与 token 用量由流适配器在流收尾时落，两种面的最终回答逐字节一致。
- **如实偏差**（详见 docs/agent.md「流式与阻塞的如实偏差」）：流式面会打出工具轮里的
  中间文本；思维链 delta 不打印；首帧之后断流不重试、已打出的文本不撤回；流式 429 拿
  不到 `Retry-After`，退避只按本地指数。
- **取消收紧**：Ctrl-C 之后两个面都**立即丢弃在途模型请求**（此前阻塞面要等服务端
  返回或 `--llm-timeout` 到期），退避等待同样即时中止；此前记档的「在飞请求由
  `--llm-timeout` 封顶」偏差就此关闭。
- **假模型服务** `scripts/fake_llm_server.py` 按请求体 `stream` 字段输出 OpenAI /
  Anthropic 两种 SSE 形态，`FAKE_LLM_FRAME_DELAY_MS` 控制帧间隔；`agent_e2e.sh` 新增
  R15（读端计时证明逐 delta 到达、`--llm-no-stream` 整段到齐、两面 stdout 一致、配置
  与摘要互钉），R8b 改为断言在飞请求被丢弃且进程在信号后 5s 内退出。

### 2026-09-25 软门禁转硬本地预跑：clang / clang-tidy / musl 存量清障归零

- **背景**：CI 六条软门禁各带转硬条件（最迟 2026-10-31），其中 clang / clang-tidy /
  musl 三条此前如实标注「开发机无相应工具链，未经本地预跑」。本次在开发机**免 root**
  补齐预跑环境（LLVM 14.0.6 官方预编译包；musl 走 proot + alpine 3.20 minirootfs——
  本地 musl-gcc 包装系统 libgcc 的路走不通），三条门禁的本地预跑全部通过。
- **真 bug 修复 2 处**：`test_util.cpp` 内嵌 NUL 用例的断言消息把「字面量 + int」当
  拼接用（指针算术），改 `std::to_string`；`test/cpp/harness.hpp` 的 `out()` 无参调用
  改走 `fputs`（fmt 非 string literal，`-Wformat-security`；fmt 含 `%` 时原实现按
  格式符解析）。
- **musl 可移植**：`test_actionsource.cpp` 补 `<sys/time.h>`（timeval 在 glibc 间接
  可见、musl 不然）——alpine 下 `mybot_tests` 从编译不过到全绿。
- **clang-tidy 存量 85 条逐条处置归零**：文案拼接收敛到 `util.hpp` 新单点
  `concatMsg()`；13 条 `strerror` 收敛到线程安全单点 `errnoText()`（`strerror_r`，
  老 glibc 的静态缓冲是真竞态）；多余拷贝改 `const&`；`getenv`/`setenv`/`readdir`
  单线程窗口定点 NOLINT 注明理由；其余零散处置，`Padding` 两条按先例写入
  `.clang-tidy` 豁免。
- **死代码**：删 `sqlparse.cpp` 的 `kDialectStatements`（改逐语句文案时只删用法留了
  常量，注释声称的「单一事实源」已失真）。
- **CI 注释对齐**：三条门禁的「未经本地预跑」声明改为本地预跑结论；`allow_failure`
  一律不动——转硬条件里的「连续 2 轮 pipeline」证据仍须 CI 侧产生。

### 2026-09-25 批次 D 落地：Rust agent 会话持久化（`--session-file` / `--resume`），C++ 参考清退

- **新模块 `agent/src/session.rs`**：会话文件读写原语（编解码、三道恢复判据、权限
  告警）与 `--session-file <路径>` / `--resume` 的 CLI/配置接线，语义对齐 C++ 参考
  实现与 `docs/agent.md`「会话持久化」规格节。
- **行格式与 C++ 参考逐字节兼容**（JSON Lines：首行会话头、其后一消息一行），故 C++
  时代落下的会话文件仍可被 `--resume` 读回——格式是跨版本的外部契约，不随实现语言
  迁移漂移。
- **一处有意偏离 C++ 参考（已记档，非 bug）**：带图片的 user 消息落盘时保留原有的
  文本说明（caption）+ 追加占位行（C++ 参考把整条 `content` 换成占位文本）——恢复后
  模型仍能看到那句说明；图片字节本身仍然不落盘。
- **恢复三道判据**（任一不过即拒绝并退出 2）：① 逐行解析（损坏行跳过并点名行号，
  首行必须是合法会话头）；② 指纹核对（结构脚本名 / 工具集指纹 / 系统提示词指纹）；
  ③ 协议自洽（`tool_call_id` 无孤儿/无重复/无漏答）。
- **落盘点** = `repl.rs` 一轮任务成功 materialize 之后按「上次已落盘长度」追加新消息：
  失败任务里已完整跑完的轮次留在内存历史里、随下一次成功任务一起落盘；`/clear` 向
  文件写 `session_clear` 分界标记。审计联动：`--resume` 采纳被恢复会话的原 session id，
  并在 `start` 行标 `resumed: true`（加法字段，老消费方不受影响）。
- **C++ 侧清退**：`src/agenthistory.{hpp,cpp}`、`test/cpp/test_sessionfile.cpp`、
  CMakeLists 三处登记与失去唯一调用方的 `agentproto.hpp::ChatMessage` 一并删除
  （`ToolCall`/`ToolSpec`/`parseToolArguments` 仍在 MCP 帧协议活跃使用，保留）。
  **不动**：C++ 宿主侧（`--mcp-backend`）对这两个选项的既有拒绝与帮助文案——本机制
  完全在 `mybot-agent` 一侧。
- **E2E**：`agent_e2e.sh` 新增 R11 两进程接力（进程一落盘并完整跑完工具循环，重启
  假模型服务后进程二 `--resume`，验证「首个请求就带着完整历史」）+ 2 条免服务负路径
  （换 `--robot` 指纹不符 / `--resume` 缺 `--session-file`，都在连接端点前退出 2）。
- **批次字母口径**：批次 D 至此完整落地，功能面正式收敛为「C++ 只管硬件与工具执行，
  Rust 只管模型循环与会话记忆」。

### 2026-09-25 决策：agent over TCP（原批次 E）不做，设计存档下架

- **决策**：远程 REPL 形态（mybot-agent 监听 TCP、对端逐行下发任务）**不再规划**。
  远程场景回归既有路径：ssh 到机器人侧本地运行 `mybot-agent`（stdin 交互），动作
  脚本的远程投递走 `--tcp` 动作源（安全口径不变：回环缺省、跨机必须 `--tcp-token`）。
- **下架范围（纯文档/注释，零行为变更）**：`docs/agent.md` 的「远程对话」设计存档节
  收敛为决策存根；README 相关节删除；testing/守门「仍未覆盖」清单摘除。
  `test/run_all.sh` 的三条 `agent_tcp_*` 负路径钉子**保留**——它们钉的是
  「`--agent` 已移除」「`--mcp-backend` 与 `--tcp` 互斥」的拒绝行为，与远程 REPL 无关。
- 批次 D 不受影响；批次字母 E 随本决策作废，不再复用。

### 2026-09-24 重构四连：C++ 侧死代码清退 + 活代码收敛 + Rust 修复 + 文档对齐

- **C++ 死代码清退（分档）**：REPL 迁 Rust 后「仅测试可达」的孪生实现按「Rust 是否
  已有对等实现」分档删除（`agentbudget.*`、`agentdriver.*`、`agentproto` 的
  ChatTransport 一族、`buildAgentSystemPrompt`、`runSqlCommand`、actionsource 的
  TcpAgentSession 等），净 **-2331 行**。session-file 读写原语与 `test_sessionfile.cpp`
  暂留作 Rust 批次 D 参考（后随批次 D 清退）。
- **`--agent` 入口快速失败**：cliargs 校验层直接拒绝（退出 2 + 两进程替代用法指引），
  不再先做 LLM 驱动注入/哨兵装配/TCP accept 才打到桩。模型循环类选项
  （`--task`/`--llm-*`/`--prompt-file`/`--session-file`/`--resume`）一律拒绝并指路
  `mybot-agent`；主帮助补齐此前完全缺失的 `--mcp-backend` 段。
- **C++ 活代码收敛**：SQL 渲染错误通道类型化（`SqlOutcome{ok,text}`，废除「错误: 」
  字符串前缀当错误码的往返）；UTF-8 校验/FdGuard/ASCII 小写化/整词切词四组重复实现
  收敛到 util.hpp 单点；`buildAgentConfig` 由 242 行内联拆为具名步骤函数（判据/文案
  不变）。
- **Rust agent 修复**：交互 REPL 的「思考中…」动画重写——写出改 `libc::write` 直写
  fd 2（原裸 `eprint!` 对 EPIPE/ENOSPC 直接 panic）；SAN-9 请求体估算字节改按段求和，
  消除每轮一次 O(历史) 的序列化峰值；`PromptMaterial` 失败退出码 1→2 对齐
  「配置错误=2」。
- **R8b 场景修复（测试 bug）**：SIGINT 原打给管道末端的 `timeout` 包装进程（GNU
  timeout 不转发），信号被吞；改打 `pgrep -P` 找到的 mybot-agent 本体。
- **文档对齐**：docs/agent.md 顶部改为两进程拓扑横幅，README 全部 agent 示例改两进程
  形态；`Cargo.toml`/`hook.rs`/`agent_e2e.sh` 的 `.tmp/*` 失效引用改指 git 历史；
  8MiB 帧上限双侧常量注释互相点名（改一必须改二）。

### 2026-09-24 收尾：HEAD 恢复可编译 + agent 守门按归属分流

- **修一个不能编译的 HEAD**：上一次删除 `src/agentloop.{hpp,cpp}` 时留下对不完整类型
  取成员的 `summarizeSessionStatus` 与两个桩，`agentmode.cpp` 所在的两个目标全断，且
  已推到公开分支。按「生产零调用者」判据删除，活码（`summarizeAgentConfig` /
  `makeToolContext`）保留。
- **补回一处被连带删掉的判据**：`historyProtocolViolation`（「assistant.tool_calls
  与 tool.tool_call_id 一一对应」的可执行判据，SAN-1）唯一实现随删除消失，而 Rust 侧
  没有对等实现——已逐字归位 `agenthistory.{hpp,cpp}`。教训：删一个「表面」时，判据与
  注释里的依赖者不会跟着报错。
- **agent 守门按归属分流**（原 22 个 C++ 场景在桩上全线红）：属**后端工具面**的 6 条
  迁入 `scripts/mcp_e2e.sh`（纯标准库 Python 帧客户端直连 AF_UNIX 后端，不经模型、
  判据更硬：`apply_sql` 带电生效、热删除真摘变量、门控对照、策略拒绝零副作用）；属
  **循环层**的归 `agent_e2e.sh` 的 R 段（该文件成为 Rust 单一模式）。`--session-file`/
  `--resume` 两进程接力等如实记为仍未覆盖（批次 D 落）。
- 注释与数字归位：十余处指向已删 agentloop 的注释改为指名真实归属；README 的单测
  文件计数按实测更正。

### 2026-09-24 审计高危修复两连：掩蔽引号绕过（H1）/ Rust stdout 写失败 panic（H2）

- **H1（掩蔽绕过）**：`maskSecretsInText` 把引号一律当值终止符，值**以引号开头**时
  掩蔽区为空——`export KEY="sk-x"` 输出 `KEY=***"sk-x"`，引号后的密钥留在明文。泄漏
  双通道：审计 `args_raw` 落盘（append-only 不可撤回）与 `run_command` 回执进模型
  上下文前的净化是同一函数。修复：新增 `maskedValueEnd` 共用于三个形态——引号值连同
  定界引号**整体**遮蔽，未闭合遮到串尾（宁可多遮不可漏遮），引号段与裸段可拼接。
- **H2（stdout panic）**：Rust 运行时把 SIGPIPE 置 ignore，`println!`/`eprintln!` 对
  写失败（断管道 EPIPE、`>/dev/full` ENOSPC）直接 panic（退出码 101），`--task` 输出
  后的审计 session end 行随之丢失——C++ 的 printf 失败只设 errno 不崩溃，这是迁移
  引入的回归面。新增 `agent/src/out.rs` 把全仓 46 处 stdout/stderr 写点收敛为检查式
  宏：stdout 写失败经 `libc::write` 直写 stderr 告警**一次**，stderr 失败静默（stdout
  是模型输出与交互界面的保留通道）。

### 2026-09-24 Rust agent 循环层语义对齐 C++（rig 迁移·批次 C）

- **新增四个模块**（`agent/src/`）：`budget.rs`（任务内文本/图片预算）、`history.rs`
  （会话历史按整块裁剪，最新块无条件保留）、`hook.rs`（墙钟两判定点、单轮调用上限、
  失败回滚边界、取消标志、图片批次物化）、`model.rs`（图片后注 + 单次调用超时 +
  网络重试）。
- **循环语义对齐**：任务开始前裁剪旧历史并清零任务内预算 → 轮循环开头判「取消 / 墙钟
  耗尽」→ 逐条派发前再判墙钟 → 超过 `max_calls_per_round` 的调用**不派发**（模型看到
  「未派发」回执）→ 成功才把新消息并入历史，失败回滚到钩子记下的边界（半截
  tool_calls 序列不落盘）。
- **图片后注**：说明 + 图片追加到**含工具结果的那条 user 消息末尾**（OpenAI 协议不
  允许工具结果带图片），与 C++ 的独立 user 消息同序；注入只作用于**发出去的请求**，
  任务结束后按记录的位置物化回会话历史。
- **网络重试 / 取消 / 配置面**：`max_retries`（0 合法）+ 本地指数退避，退避取「本地 vs
  服务端 Retry-After」较大值；SIGINT/SIGTERM 首次只置停止标志，第二次强杀；
  `max_history_bytes` 等 6 个限额字段落地解析与区间校验（0 仍是「不限」/「不重试」的
  显式语义）。
- **审计**：model 行改为**逐次模型调用**一条，补 `req_bytes` / `resp_bytes` /
  `attempts`（>1 = 发生过重试）。
- **语义如实偏差（记录在案）**：① 单轮上限的呈现位置（C++ 剔除超限调用并把说明追加
  进 assistant 文本，rig 侧挂在工具回执上）；② `req_bytes` 口径（同为下界，非逐字节
  相同）；③ 重试分类（C++ 用 curl 退出码表，rig 用 HTTP 状态码 + 连接类错误）；④
  取消时效（rig 的在飞请求由 `--llm-timeout` 封顶）。

### 2026-09-24 agent 本体迁移到 Rust（rig）：`mybot-agent` 骨架落地（批次 B）

- **目录与产物**：`mcp-sidecar/` → `agent/`，包名/二进制 **`mybot-agent`**；MCP stdio
  协议层删除——agent 直连 `mybot --mcp-backend` 的 AF_UNIX 帧（4B BE）。
- **模块**：`main`（CLI/编排/退出码）、`config`（配置链：命令行 > 环境变量 > 配置
  文件 > 缺省，未知字段仍拒绝）、`provider`（rig 驱动按协议构造）、`bridge`（工具表
  →rig 工具、帧调用→工具回执）、`prompt`、`repl`、`audit`（session/model 行；**工具
  行仍归后端**，agent 不重复记）。
- `/hardware`、`/scripts`、`/sql` 一律经工具层（本进程不持有硬件）；后端没给工具时
  **明确点名缺的开关**（如 `--agent-hot-sql`），不假装执行过。图片注入、历史裁剪、
  会话持久化、取消等尚未搬（批次 C/D 落）。
- **E2E 与守门接线**：`agent_e2e.sh` 加 `--rust`（R1 工具循环 / R2 提示词包 / R3 审计
  分工 / R4 REPL + 能力门控 / R5 `--check-config` 正负路径）；`run_all.sh` 新增
  agent-rust-e2e 段；`mcp_e2e.sh` 删 MCP stdio 段，原判据改由直连帧的独立 Python 客户端
  接住（两份实现各自跑绿不证明字节兼容，第三方尺子才证明）；CI `gate:sidecar` →
  **`gate:agent`**。
- **夹具适配**：`fake_llm_server.py` 的 OpenAI 形态应答补 `id`/`model` 外壳（rig 0.42
  定为必填，真网关也都带；C++ 驱动只取 `choices` 故不受影响）。

### 2026-09-24 守门修复三连：curl POST 顺序 / 审计 exit_code / destroy 契约调和

- **`llm_http.lua` POST 选项顺序**：`CURLOPT_POSTFIELDSIZE` 必须写在
  `CURLOPT_COPYPOSTFIELDS` **之前**——curl 以「设 COPY 时的 postfieldsize」决定拷贝
  字节，后设的 size 会把它打回未定长态，实测 POST 退化为读流语义，**所有模型调用
  失败**（agent E2E 全线红）。
- **审计 `exit_code` 字段消失**：run_command 回执整体经 quoteUntrusted 定界后，
  `exit_code=` 行带前缀且不再位于文本开头，「必须是前缀」的解析假设失效——工具执行
  照常、审计行却静默丢失退出码。改为逐行扫描，数值约束不变。
- **PCA9685/UART destroy 契约调和**：arg_table 守卫放回 destroy（非表入参返 ERR，
  不抛错、不静默成功），UART 的 fd 释放**先行**（无泄漏要求保住）；表内资源缺失/
  写失败仍按既有语义静默 OK。

### 2026-09-24 帧后端新增只读路由 `context.get`（rig agent 迁移·批次 A）

- `--mcp-backend` 帧协议的第四条路由，**只读**——为 Rust agent 提供系统提示词素材：
  `robotName`/`structurePath`/`scriptsDir`/`allowShell`/`allowHotSql`/`hardwareCount`
  与三段**已定界**磁盘内容（结构脚本 16 KiB 摘录、硬件清单、脚本清单）+ 内联
  `readableVars`。
- **单一事实源**：素材读法与 `buildAgentSystemPrompt` 完全同款——消毒、截断、
  `quoteUntrusted` 定界都在 C++ 单点，Rust agent 只拼装不定界（「同一份磁盘内容，
  两条进上下文的通道必须有同一定界强度」）。`hardwareCount`/`hardwareList` 每次现取
  注册表，热插拔后不漂移。
- **口径**：与 `tool.list` 同判据——不走 `DispatchGate`、不占每连接预算；未绑定
  cfg/robot 的手搓后端响亮回错误。

### 2026-09-23 只读查询：`SHOW TABLES`

- 方言第七条语句，**只读**、不受 `--agent-hot-sql` 门控：在 `query_sql` 与 REPL
  `/sql` 里列出当前结构的全部表名与数据行数。agent 模式下宿主会自动注入
  `LlmOpenAI`/`Camera` 等表，它们不在结构脚本摘录里——`SHOW TABLES` 是「当前到底有
  哪些表」的唯一权威答案。
- 不带 `WHERE`/`LIKE`（要筛行用 `SELECT * FROM 表 WHERE ...`）；误写的尾随词元由
  词元级报错兜住。

### 2026-09-23 热更新：`UPDATE 表 SET 列 = 值 [, ...] [WHERE ...]`

- 方言第六条语句，在 REPL `/sql` 与 agent 的 `apply_sql`（`--agent-hot-sql` 门控）里
  按**断电重建**改写命中行——执行语义 = 「DELETE 命中行（物理断电摘除）+ INSERT
  改后行（重新装配上电）」，改后行取 `inherited()` 解析值物化；`name` 列可改（= 换名
  重建）；无 WHERE = 改全表。`isUnsupportedStatement` 随之整体移除（清单清空）。
- **先删后建执行序**：含 UPDATE 的批次把物理删除提前到插入之前（注册表重名即抛，
  同名重建必须先摘旧件）。失败窗口如实：新件装配失败 ⇒ 已摘旧件不复原，错误点名
  丢失的变量。
- **引用完整性预检扩面**为「提交后合并视图」；被引用（controller/trigger/$/表达式）
  的变量拒改，与热删除同一条防线。
- **批内独占**：UPDATE 与该表的其它行级语句双向不得同批，本批次新建的表上也不可用。
- 生效摘要（G2）报「已热更新 N 行（断电重建）」，删除/新增计数照报。

### 2026-09-23 整表撤下：`DROP TABLE ...`

- 在 REPL `/sql` 与 agent 的 `apply_sql`（`--agent-hot-sql` 门控）里把上电常驻机器人
  的**整张表**当场撤下：表内全部硬件变量逆序 `destroy()` 断电 → 撤注册 → 擦结构行 →
  把表壳连同元数据提供者、守护登记一起摘除。**空表（只有列头）可撤**。
- **不带 WHERE**（标准 DDL 语义），误写在**解析期**被词元级报错拒绝、活体一字未动。
  要按条件删部分行用 `DELETE`。
- **实现顺序是死的**：先走与 DELETE 完全相同的逐行擦除机器（断电/撤注册/引用完整性
  防线全部复用），再摘表壳——MetaProvider 按「矩阵地址 + 行号」定位，先摘表壳会让
  其后所有表的目标错位。
- **新增不变式：MetaProvider 重锚定**——矩阵容器中间 `erase` 会让其后元素引用失效，
  撤表后按表名（唯一且稳定）把存活提供者重锚定回新地址。
- 批次内 DROP 必须是该表的唯一动作；`CREATE` 后同批 `DROP` 同名表有专门路径；
  `Action` 瞬态表拒绝 DROP。DROP 之后可**同名重建**。`drop` 成为关键字（带引号仍是
  合法 NAME）。

### 2026-09-23 守门检查点同步：`parse_cases` 95 → 96

- `test/run_all_selftest.sh` 的条数检查点在此前新增解析用例时漏改，使 pre-push 守门
  自检恒红；本批同步到实际条数。纯守门簿记，无行为变化。

### 2026-09-23 第三个协议驱动 LlmAnthropic（批次 3）

- **`LlmAnthropic`**（`--llm-driver LlmAnthropic`）：Anthropic Messages 协议驱动。
  价值不在「多支持一家厂商」，而在**验证规范化协议抽象是否真的成立**：它与 OpenAI 系
  形状差异最大，本批落地以**宿主零改**（`git diff --stat src/` 为空）兑现「换模型 =
  换 lua 文件」对所有协议成立。
- 四处形状差异全部收敛在 `lib/llm_wire_anthropic.lua`：① `system` 抽到顶层字段；
  ② 工具调用表达为 `tool_use` 块、`input` 是对象（驱动解码，非法 JSON 响亮拒绝）；
  ③ 工具结果并进一条 user 消息的 `tool_result` 块（附严格交替自检）；④ 鉴权用
  `x-api-key` + `anthropic-version` 头。
- **两处 provider 约束 fail-closed**：`temperature` 只接受 [0, 1]（越界响亮拒绝，
  不静默钳制）；`max_tokens` 必填。
- 响应侧同样抹平：text 段拼接、`tool_use` 转规范化 `tool_calls`、非文本非工具块丢弃
  但**计数入审计**、`usage` 映射到审计认得的字段、`stop_reason` 进 `extras`。
- API key 读取链追加 `ANTHROPIC_API_KEY`。

### 2026-09-23 agent over TCP（`--agent --tcp`，批次 2）【已于 2026-09-25 决策下架】

- 远程 REPL：对端每行一条任务，模型输出与工具回显按既有 REPL 格式回写同一条连接；
  `--task --tcp`、`--agent --tcp --input` 仍被拒。
- 安全口径逐条继承动作源 TCP：缺省只监听回环、跨机必须 `--tcp-token`（或
  `BOT4CJ_TCP_TOKEN`）、口令失败上限相同；取消哨兵、任务墙钟、策略钩子、审计在远程
  形态照常生效。
- **超时口径**：远程 REPL **不套用连接总时长预算**（那是给一次性脚本投递设的），只
  保留空闲超时（缺省 600s，只在等新任务行时计时）。
- **远程取消**：客户端 Ctrl-C / 断开连接 = 与本地 SIGINT 完全相同（置停止标志 + 创建
  取消哨兵，在飞的模型调用立即中止，随后优雅收尾）。
- 接受连接在硬件上电之前（没有对端时不让执行器带电空转）；REPL 的 `log` 流仍走
  stderr 不并入连接（宿主自己的诊断不污染对端看到的回答）。

### 2026-09-23 会话持久化与恢复（`--session-file` / `--resume`，批次 1）【C++ 参考实现，语义已随批次 D 迁 Rust】

- **`--session-file`（写入）**：每个任务块完结后把新增消息逐行追加进 JSON Lines 会话
  文件（首行会话头：结构脚本名 / 工具集指纹 / 系统提示词指纹）。机器人在重启后不再
  「忘掉刚才聊了什么」——此前唯一出路是重启进程，而重启会丢掉硬件常驻状态，现场代价
  不小。文件含完整对话内容，权限宽于 `600` 时启动告警。
- **`--resume`（恢复）**：**路径必须来自命令行**——恢复是把磁盘内容读进模型上下文，
  配置文件不能授权一次读取（与 `camera_src_dir` / `read_vars` 同判据）。三道判据全过
  才恢复，任一不符即退出 2 并点名差异：逐行解析、指纹核对、工具调用协议自洽（恢复
  的历史按不可信输入对待）。
- **图片与 system 提示词不进文件**：图片字节以占位落盘（体积与隐私两个方向都要求
  字节不出现在磁盘上）；system 提示词恢复时由当前进程重建，再按指纹核对。
- **`/clear` 联动**：向会话文件写 `session_clear` 分界标记，恢复时丢弃此前全部消息
  ——否则「忘掉对话」会在下次恢复时复活。
- **审计 schema 加法演进**：`kind="session"` 的 `start` 记录新增 `"resumed": true` 并
  沿用原 session id——既有字段名、顺序、语义一个不动，老消费方逐字节不变。

### 2026-09-23 热删除：`DELETE FROM ... [WHERE ...]`（含 AND 多条件）

- 方言新增语句：在 REPL `/sql` 与 agent 的 `apply_sql`（`--agent-hot-sql` 门控）里把
  上电常驻的器件**带电摘掉**——逆序 `destroy()` 断电 → 摘元数据/守护登记 → 擦结构行
  → 撤注册。无条件写法删空该表。结构脚本 `.sql` 里写 DELETE 仍在解析期报错（机器人
  未上电，没有可变的结构）。
- **`AND` 成为关键字**；WHERE 条件列表解析收敛到 `Parser::nextConditionList` 单点，
  SELECT 与 DELETE 共用。`OR`/比较运算符/`IN` 仍不在方言内。
- **原子性口径：逻辑原子、物理不可逆**。`destroy()` 是物理断电，删了没有回滚可言
  （回滚 ≠ 复活器件），故防线放在**事前判全**：目标表、命中行、引用完整性、全结构
  判据全部在动第一个器件之前跑完；过关后物理 `destroy` 失败则立即中止并如实报
  「已删除 N 个（名单）、M 个未删除」，不假装回滚。
- **引用完整性**：被 `controller`/`trigger`（含编号列）、`$name`、`$(...)` 引用着的
  变量**拒绝删除**，报错逐条点名引用位置——这些引用在框架内部是终身缓存的裸指针，
  热删除第一次打破「pool_ 只增不减」的不变式，必须把「不留悬垂」重新建立为构造保证。
  「引用方与被引用者一起删」合法。
- 删除按行号倒序执行（销毁序 = 声明序倒序是总线 fd 的资源不变式）；条件命不中任何行
  时**报错而非静默成功**；删除后 `flowRefs_` 摘名（删掉再热插同名变量仍是合法恢复
  路径）。

### 2026-09-23 SELECT 支持基本 WHERE 等值条件（`=`）

- `SELECT * FROM 表 WHERE 列 = 值;`：单条件等值、精确文本匹配（比对 `inherited` 显示
  值，数值按文本比），`query_sql` 工具与 REPL `/sql` 同一生效。AND/OR、比较运算符、
  多条件不在方言内；0 行命中显式报「0 行匹配」，模型不会把「没有行」误读成渲染故障。
- 词法器 `=` 成为第五个分隔词元（紧贴写法 `col=value` 靠挂起标志切分）；匹配单点是
  `mt::matchRows`，为将来 DELETE/UPDATE 选行复用。

### 2026-09-23 文档勘误：工具表 / 场景数 / 不存在的 --agent-verbose / 单测基线

- 纯文档修正：agent 工具表补齐 `query_sql` / `apply_sql` / `read_variables` 三行并标
  出各自开关；`--agent-verbose` / `--verbose` 从来不是本项目的选项，引用改为如实描述；
  E2E 场景数统一为实数；单测基线 `659 / 0` 为误记（「通过」是用例数），已就地更正。

### 2026-09-23 回读通道（A）：--read-var 与 read_variables 工具

- **模型此前无法「主动读」**：新增 `read_variables` 工具（无参数，一次读全部可读
  变量）——此前除摄像头外，模型对硬件状态全盲，按读数闭环类任务做不了。
- **可读集合必须由人列名**：agent **无法靠种类区分传感器与执行器**（`Servo`/`Relay`
  与传感器同属 `kind=lua`，对它们调 `play()` 会真驱动硬件）。故 `--read-var <名>`
  （可重复）缺省**不提供**该工具；配置文件写 `read_vars` 一律拒绝加载并退出 2（放宽
  读权限的字段只能命令行给）；执行时只放行已注册且种类为 `lua`/`daemon` 的名字，其余
  跳过并在启动时点名。
- 回执 8 KiB 上限、截断标注、UTF-8 消毒、「数据不是指令」定界。边界如实声明：读
  传感器也可能有副作用，这是一次派发，照走任务预算与审计。

### 2026-09-23 回读通道（D）：动作脚本回执带上驱动读数

- `run_action_script` 的回执此前只有一句「已执行」，器件读到的值走 stderr 回显——
  **操作者看得见、模型看不见**。现在执行窗口内挂一条同线程回收通道，回显追加进该次
  工具回执，随 `tool` 消息进模型上下文；上限 8 KiB、超限截断并显式标注、截断后 UTF-8
  消毒、「数据不是指令」定界。窗口外一切照旧。
- 配套：系统提示词与工具描述都告诉模型「回执里带读数，据此核对硬件状态，不要凭空
  假设」。

### 2026-09-23 tool_call id 的会话内唯一性（SAN-12）

- 合成 id `call_<turn>_<i>` 的 `turn` 每个任务都从 0 重数 ⇒ 第二个任务与第一个撞车，
  历史里同一 id 被回答两次，服务端 400 且那段历史已越过回滚边界——此后每个任务都以
  同一个 400 失败，只有 `/clear` 或重启能恢复。provider 在同一次响应里返回重复 id
  也是同一个口子。
- 现在：写历史前按「会话内全局唯一」改写 id（漏 id 时合成基线不变）——**没有任何
  调用被丢弃或跳过**（改写的只是不透明的 id，模型意图分毫未动）。改写成因打一行
  stderr 告警，不受 verbose 闸门约束。

### 2026-09-23 配置文件来源的提示词路径加根约束（H2）

- `prompt_files` 此前是「读任意文件」的原语：提示词包内容随首个模型请求发往 endpoint，
  而 endpoint 同样由配置文件决定——一份落在 CWD 的 `./mybot.llm.json` 写
  `{"endpoint":"<攻击者>","prompt_files":["/proc/self/environ"]}` 就能把操作者环境块
  （含重新注入的 `BOT4CJ_LLM_KEY`）整块外发。与 `camera_src` 同族（「配置文件不该
  授予读权限」），同判据收口。
- 现在：**命令行** `--prompt-file` 不受限（操作者本人授意）；**配置文件来源**的每一项
  必须落在 CWD 或 `BOT4CJ_PROMPT_DIR` 显式列出的目录内（`realpath` 判定，`..` 与软链
  逃逸都拦），越界在**上电之前**报错退出 2。

### 2026-09-23 agent 第三轮定点收口（G1/G2/G3）

- **G1（高）**：`run_command` 回执在**进模型上下文之前**过一次 `maskSecretsInText`
  ——子进程自己打印到 stdout/stderr 的 `KEY=value`（如模型执行 `env`）此前原样回传，
  可经同一配置可控的 endpoint 外发；发生替换时追加「已净化」提示。仍是文本级防线，
  与既有两道同档。
- **G2**：`apply_sql` 工具行新增 `summary` 字段记结构化生效信息（新增几张表/几个变量/
  几行）——只做加法，既有 schema 逐字节不变。
- **G3**：一次性任务非标准异常退出（Lua 错误的实际形态）也补写 `status=error` 的会话
  结束记录——原先 `catch(...)` 直接 return，审计里连一条 session 记录都没有。

### 2026-09-22 第七轮审计修复批次·第二批（H1 + 三条 P1 + P2 批）

- **`capture_image` 的模拟图片白名单恒真（H1，高）**：`src_root` 由 `camera_src` 的
  所在目录推出——src 的所在目录当然包含 src，判据恒真，白名单形同不存在。可达链
  **不需要 `--agent-shell`**：CWD 里的 `./mybot.llm.json` 写 `"camera_src":"/etc/shadow"`
  就能把该文件读进模型上下文再外发，而注释此前明确声称「任意路径读被拒」。修复三条
  口径：① 新增 `--camera-src-dir` 显式根（**命令行独占**，配置文件写一律拒绝）；②
  没有显式根时只有命令行的 `--camera-src` 才用其所在目录当根（保住快速上手）；③
  配置文件来源的 `camera_src` 一律不推导，都没有即默认拒绝。
- **`SINGLE_CONSUMER` 判据三条静默旁路（P1）**：缺列此前被当成「不参与判据」，而守护
  侧对 proto/path 都有缺省、多器件清单在 `devices` 列里宿主从不解析——五种声明者的
  「直连 + 守护」双消费可让器件地址相位互踩、**双方都报 OK**，漏标没有任何运行期
  症状。现在缺列按守护侧同一规则补全后登记、`devices` 列逐个 spec 解析、`driver` 列
  与 `devices` 列互斥；缺省值两侧读同一 Lua 源比对（这类漂移没有运行期症状）。
- **`@Include` 归并只数输入、不数产物（P1）**：产物侧此前零限，几十字节的脚本能把
  终态撑到数百 MB——树莓派 OOM 是 SIGKILL 语义，`deactivate()` 整体被跳过。现在
  `mtmerge::mergeTwo`（两两归并单点）在写任何一行之前判行数/单元格预算，取值给真实
  用量留两个数量级以上余量。
- **P2 批（六处）**：内嵌 NUL 击穿「全串消费」判据（`90\0junk` 报 OK/90，尾随垃圾
  静默丢弃——`parseLongStrict`/`parseFiniteDouble`/工具参数入口各加前置判据）；
  `DAEMON_CONFIG` 的矩阵占位符 `-` 不再原样下发（`sign='-'` 让符号扩展静默失效）；
  `loadfile` 的错误返回值不再被沙箱包装吞掉；守护多值脚本的槽容量改读注入单点
  （写死 32 的后果是两侧各自漂移、尾部字段永不出值且无报错）；build 期响应停止标志
  （多驱动上电期间第一次 Ctrl-C 此前毫无可见效果，而第二次是强杀、已 build 的器件
  原地带电）；两处注释/文案与实现不符修正。
- **守门自身：产物陈旧不再静默**：`test/run_all.sh` 开头比对编译期输入与产物 mtime，
  陈旧即退出 2——此前改完源码直接跑守门，跑的是上一轮二进制，汇总照样给出像样的
  「N 通过」。这类假绿比缺产物更危险。
- **本批未做（如实留痕）**：弃管守护的「写能力掐断」仍未落地——tick 卡在不可中断的
  总线事务里被弃管后，该线程醒来仍可能再写器件一次，进程退出瞬间器件可能重新带电。

### 2026-09-21 第七轮审计修复批次（AG-27 + A1–A8：协议形状、墙钟预算、假红门禁）

- **A1（高）**：超限工具调用的截断说明此前写成**额外一条** tool 消息并复用最后一条
  已派发调用的 `tool_call_id` ⇒ 历史 N 条 tool_calls 对 N+1 条 tool 消息、一个 id 出现
  两次，且落在不可回滚的历史里——下一轮起**每条任务都以同一请求体拿 400**。改为把
  说明**并入该轮 assistant 文本**，历史形状恒为 N⇔N。触发不需要攻击者：缺省
  `maxCallsPerRound` 16，一句「把这 20 个脚本依次跑一遍」就会命中。
- **A2**：补齐单轮上限的钉子用例（形状合规、说明到达模型且措辞不谎报、`0` = 不限），
  并新增与 Lua 侧同判据的 C++ 助手 `pairingViolation`（数量/顺序/id 重复/多一条）。
- **A1b（出站一致性自检）**：`llm_wire_openai.check_tool_pairing` 在**发包前**校验
  `tool_calls` ⇔ `tool` 一一对应，不通过即 `error` → 折成 ERR 契约，宿主给出点名
  「第几条消息、期望几条、实际几条」的报错，不把不配对的报文发出去换含混 400。
- **A3**：脚本清单把「消毒名」当「寻址名」——文件名含非法字节时首注释静默消失、清单
  交给模型的名字在磁盘上不存在，模型照抄必失败。现在 raw（寻址）与 shown（展示）分开
  保存并显式标注。
- **A4（单任务墙钟预算）**：体积与条数上限管的都是「往上下文里灌多少」，没有一条管
  时间——agent 模式全程带电常驻，最坏一个任务能让执行器带电十几小时。新增
  `--llm-task-timeout` / 配置 `max_task_seconds`（缺省 **900s**，0 = 不限）。判定点
  两处、语义不同：轮循环开头按「达到预算」如实失败；一轮**中间**耗尽时剩余调用不
  派发、但每条各留一条「未派发」回执（少一条就是服务端 400）。实际超限量最多是
  「一次模型调用 + 一条工具」。
- **A5（低）**：agent 会话路径只接 `std::exception`——本机 LuaJIT 用 C++ 异常实现
  `luaD_throw`，从没有 Lua CFRAME 的 C++ 帧抛出的错误**不是** `std::exception`，会把
  「单轮失败」升级成「整个 REPL 结束」且已执行的动作被回滚出历史。四处各补
  `catch (...)`。
- **A6（低）**：fd 自报探针加编译期开关 `MYBOT_TEST_TRACE_FDS`——生产二进制里不再有
  「按环境变量向任意路径追加写」的能力。
- **A7（低）**：provider 回传的 `id`/`name` 加长度上限（`proto_limits`），超限整条
  响应拒绝 fail-closed——id 不能截断（截断破坏与 `tool_calls` 的配对）。
- **AG-27（树莓派假红）**：守门长期 261/1 的那条失败根因不在产品代码——用例
  `ffi.load("curl")` 与 `llm_http` 的候选名在本机解析成**两个不同 libcurl 文件**，用
  B 实例读 A 实例的句柄等于按另一套结构体布局解引用。修法：用例一律经 `M.libname()`
  拿**同一份**实例，并补阳性对照。红门禁长期没人修的代价：它从此不再具备判别力。
- **A8 三处瑕疵**：死语句；两处「`--agent-shell` 或 `allow_shell=true`」文案与实现
  不符（配置文件已不能开 shell）；deepseek 驱动死参。

### 2026-09-22 响应形变矩阵（SAN-11，纯测试 + 契约成文）

- 新增 `test/test_llm_wire_contract.lua`：表驱动形变矩阵覆盖两个内置驱动的全部响应
  形态（choices/message/content/tool_calls 的缺失、非表、畸形、合法与畸形混合；HTTP
  层六种形态），每行标结局：**点名报错 / 降级但记账 / 照常处理**。宿主侧对应矩阵在
  `test_agentproto.cpp`。此前 PL-3/PL-6 都是线上撞到才补一个、没有矩阵——下一个形变
  还要等线上撞。
- 契约成文：`docs/agent.md` 补完整响应契约表与维护约定——**遇到新的 provider 形变先
  往矩阵里加一行**。一处归一化：`content` 为数字/布尔时归一成空串（原样透传会让宿主
  的判据读成「没有文本」，报错完全不指向真因）。

### 2026-09-22 REPL 新增 `/status`（SAN-10）

- 现场最常见的三个问题——「为什么它忘了之前说的？」「为什么拍照没进来？」「刚才失败
  了几次、花了多久？」——都要翻 stderr 全文才能回答；答案其实都在内存里，只是没有
  出口。`/status` 读已存在的状态渲染成一览：模型/接入点/超时/轮次上限、会话轮数与
  耗时、工具调用数与失败数、最近 token 用量、任务块数与历史字节（含是否裁过）、任务
  内预算用量、审计落点与 session id、硬件变量数、脚本目录。
- **三条如实口径**（不显示假数字）：预算 0 显示「不限（已用 …）」、历史未裁剪显示
  「未触发裁剪」、审计未开显示「(未开启)」。`/status` **绝不触发模型调用**。

### 2026-09-22 审计轨迹补上会话边界与模型轮次（SAN-9，加法演进）

- 审计此前**只记工具调用**：模型说了什么、花了多久、这一轮有没有真的发出请求完全
  不可查；一次在模型调用阶段失败的会话在日志里**一条记录都没有**——而那恰恰是最需要
  复盘的时候。新增 `kind` 字段（显式写在每行）：`session`（会话头/尾；**绝不写密钥**
  ，只写来源枚举名）、`model`（每轮一条，失败也记）、`tool`（既有形态逐字不变）。
- **接入点脱敏**（顺带堵一个真实泄漏面）：`endpoint` 落盘前剥掉 query 与 userinfo
  ——部分网关把凭据放在 URL 里，而审计是 append-only 的落盘文件。
- token 只记 provider 给的数（usage 由驱动原样透传），不做推算或计费估算。

### 2026-09-22 参数错误不再说成「执行失败」，丢弃的调用如实报数（SAN-8）

- `AgentToolResult` 增 `paramError` 标志（判据是**异常类型** `IllegalArgumentException`
  ，不是文案匹配）：参数校验失败的回执改为「工具参数错误: …」且 `executed=false`——
  模型漏传参数时不再收到「动作脚本执行失败（状态可能停在半途）」的谎报，实际什么
  都没跑。
- 丢弃缺 `function.name` 的工具调用后**如实报数**（宿主丢弃数 + 驱动自报计数），不再
  谎称「模型既没有返回文本也没有工具调用」——模型确实返回了工具调用。

### 2026-09-22 中断语义与代码对齐（SAN-7）

- 三处旧文案写着「模型调用期间（最长 600s）**不可中断**，此时再按一次 Ctrl-C 即立即
  强杀」——与取消哨兵落地后的实际行为相反，且是**会导致物理后果的操作建议**：运维照
  它多按一次 Ctrl-C，就跳过 `deactivate()` 把执行器留在带电状态。
- 修法：`docs/reference.md` 的信号一节重写为**唯一权威描述**（首次 SIGINT 四步；第二
  次是**逃生口而非常规操作**），docs/agent.md 只留指向；处理器注释同步。
- 新增 E2E 判据：首次 SIGINT 之后断言退出码**恰好 1**（被信号打死 130、段错误 139、
  早退 0 都不是 1，证明走的是正常清理链），取消哨兵不残留。

### 2026-09-22 驱动不再合成 tool_call id，并补齐响应形态判据（SAN-6）

- **行为变更**：协议驱动不再自己编 `call_<i>`，id 缺失时透传空串由宿主填——驱动的
  合成 id 每轮从 1 重来，会遮蔽宿主按会话内唯一设计的合成方案，历史里同一 id 被回答
  两次（同一条消息内也会撞）。
- `choices`/`message` 非表 → **点名返回**（不再抛裸 Lua 内部报错逃出驱动「返 ERR 表、
  绝不抛」的契约）；`tool_calls` 的**元素**非表 → 跳过并计数
  （`extras.dropped_bad_tool_calls`），与 PL-3 同口径——丢弃但如实记账。一处修，
  两个驱动受益（DeepSeek 复用同一份 `parse_response`）。

### 2026-09-22 动作执行回显改走 stderr（SAN-5）

- `MtVars_Lua::callImpl` 的三处 `std::cout` 改 `std::cerr`——回显是诊断输出，`--task`
  的 stdout 此前混进分隔线与驱动结果表，**不能安全接管道/重定向**（`| jq`、写文件、
  被脚本消费全部受影响）。回显没有消失（终端上两股都是屏幕）。
- 如实声明的残余：Lua 驱动自己 `print()` 的进度行仍走 stdout——stdout 契约收窄为
  **「宿主不往里写东西」**而不是「里面只有模型回答」。

### 2026-09-22 预算降级不再把「没执行」说成「副作用已发生」（SAN-4，安全口径）

- `TaskBudget::admit` 此前对**所有**工具结果一视同仁，超限时无条件追加「工具本身已
  执行完毕（副作用已发生）」——而策略拒绝、未知工具、参数错误这三类**从未被派发**。
  对物理机器人，谎报状态是安全相关的错误：模型可能据此认为命令已经跑过而不再重试。
- 修法：`AgentToolResult` 增 `bool executed`（缺省 true），三条「没派发」的路径显式
  置 false 且**不做降级**（这类文本本身就是要给模型的事实）；工具**内部**失败仍是
  true——脚本跑到一半报错时机器人可能停在半途，那种警告必须保留（方向相反的谎报
  同样不可接受）。
- 记账不变：`executed=false` 的结果**仍计入额度**——否则「反复被拒」成了往历史里无界
  灌文本的免费通道。

### 2026-09-22 `agent-all` 真的覆盖 agent 全表面了（SAN-2，守门假绿修复）

- `test/run_all.sh` 的 `agent-all` 映射指向一个**从未存在**的文件模式，「agent 全
  表面」入口的 **Lua 段静默跑了 0 个文件**（Lua 循环对「命中 0 个文件」是合法状态）。
  真正的协议面 `test_llm_drivers.lua` 一条都没执行——改协议驱动三个文件跑 `agent-all`
  会全绿。
- 修法：过滤器改 `llm`，自证从「映射的形状」升级为「被映射到的文件」——roster 里每个
  文件必须存在且真的会被跑到，反向漏登记即红。

### 2026-09-22 重试真的认识真实错误了（SAN-3，含 429/5xx 与 Retry-After）

- **行为变更**：重试判据此前三条匹配人话子串，而生产路径产出的错误（curl 英文散文、
  `HTTP 503`）**一个都不匹配**——`max_retries` 事实上不生效，429/5xx/真实超时/连接被拒
  各只发 1 次请求；`Retry-After` 完全不可达（响应头在 libcurl 里被丢掉），本地退避与
  真实限流窗口毫无关系。
- 修法（结构化判据优先，字符串只作回落）：`llm_http` 挂头回调解析 `Retry-After`；
  非 200 分支给出 `http_status`/`retriable`/`retry_after_ms`——**429 与 5xx 可重试，
  其余 4xx 不可**（两者此前长得一模一样：要么限流不重试，要么把 401 也重试烧配额）；
  宿主 `classifyDriverError()` 纯函数判类；退避取「服务端 Retry-After vs 本地指数
  退避」较大值，钳到 [1s, 5min]（坏网关回天文数字不能把 agent 挂死一天）。

### 2026-09-22 单轮截断不再复用 `tool_call_id`（SAN-1，阻塞级缺陷修复）

- **行为变更**：一轮工具调用超上限时，多余的此前被折叠成一条 tool 消息挂在**最后一条
  已派发**调用的 id 上 ⇒ 历史**两条同 id** ⇒ 服务端 400 `answered more than once`。
  该轮派发已完成、回滚边界已越过——此后**每个新任务都重发同一段历史、拿同一个 400**，
  只有 `/clear` 或重启能恢复。
- 修复：截断说明写进该轮 `assistant.content`，历史**不再新增任何 tool 消息**（这是
  唯一既不违反协议、又不与 `tool_call_id` 一一对应绑定的位置）；截断事件**写日志**
  （此前这个安全相关的事实只到达模型，stderr 与审计一个字没有——这正是缺陷能潜伏的
  成因）。
- 新增可执行判据 `historyProtocolViolation()`：`tool_call_id` 无孤儿/无重复/无漏答，
  把注释里的约定变成可执行判据。

### 2026-09-22 动作脚本执行预算（PL-2）

- **行为变更**：`run_action_script` 是工具集里**唯一没有任何上界**的执行路径且默认
  开启；挂死只可能来自 Lua 驱动自己的 `call()`，一旦发生会话永久卡住。现在窗口内给
  每个 Lua 驱动状态挂**指令计数钩子**并**关掉 JIT**，超期（`action_script_timeout_sec`
  ：配置文件 0-3600、缺省 180、0 = 显式关闭）即以 Lua 错误中止本轮脚本；`stopRequested()`
  纳入判据，Ctrl-C 在窗口内也能中断失控驱动（此前只能强杀，而强杀跳过 `deactivate`、
  把执行器留在带电状态）。
- **「必须先关 JIT」是实测结论**：LuaJIT 的 count 钩子只在解释器派发路径触发，热点
  循环编译成 trace 后钩子永不触发。窗口内解释执行约 3.4× 慢，但绝对值与脚本自身耗时
  （硬件延时主导）相比可忽略；窗口只覆盖一次 `run()`，窗口外一切照旧。
- **边界（写进 docs/agent.md 已知限制）**：驱动阻塞在 `read()`/`ioctl()`/`usleep()`
  里时 VM 不派发指令，钩子没有执行机会——这一条无解。

### 2026-09-22 网关数组形态 content 归一化（PL-3）

- 新版 OpenAI 协议允许 `content` 为数组形态，部分兼容网关也这么返回；宿主只认字符串
  ⇒ 文本为空、整轮以「既没有返回文本也没有工具调用」告终，**报错完全不指向真因**。
- 现由驱动在 `parse_response` 归一化：text 段按序拼接，非 text 段丢弃但计数记进
  `extras`（「模型给了别的内容而宿主没看见」必须在审计里可见）。DeepSeek 复用同一份
  实现，一处修复覆盖两个驱动。

### 2026-09-22 `--check-config` 配置校验模式（PL-1）

- agent 专属：校验通过后打印配置摘要并以 **0** 退出，**不装载结构脚本、不上电、不
  发起任何网络请求**——配置文件写错不再要「真起一次 agent 会话」才报错（接了硬件还得
  反复上下电）。E2E 用「结构脚本可读但不是合法 SQL」对照钉住「它真的什么都不跑」。
- 摘要只渲染、不校验（判据单点仍在 `buildAgentConfig`，再造一套只会漂移）；endpoint
  未配置时明写「未配置，首次调用将失败」；API key 只报来源，值绝不出现；失败路径一律
  rc=2（漏 `--robot` 也算——否则打印帮助退出 0，CI 会读成「配置没问题」）。

### 2026-09-22 两处名不副实的测试钉子修正（PL-4）

- 无行为变更，改的是「用例看起来在守、其实没守」：① 「`--help` 优先于校验」的用例只
  调 `parseArgs` 而测不到 `main` 的顺序——判定抽成可链接的 `cliargs::preflightCli`；
  ② 2 MiB 图片上限的夹具尺寸由**被测常量**推导，常量改错时夹具跟着走——补
  `static_assert` 字面量钉子 + 字面量边界用例。

### 2026-09-22 文档/注释残留四处修正 + 工具 schema 深度加锚点（PL-5）

- 纯文档/注释：`LlmOpenAI.lua` 头注释自相矛盾（以事实为准）；`pthread.lua` 回退基准
  停留在旧槽布局（数字错了就失去比对意义）；非 agent 模式的拒绝文案漏列 camera 四项。
- 「工具 schema 最深处为 6 层」此前是人工统计、无锚点——给参数加一层嵌套不会有人
  发现。新增钉子用例锚定层数与余量。

### 2026-09-22 响应整形：tool_calls 形态非法时报点名原因（PL-6）

- 网关把 `tool_calls` 返回成字符串/数字/布尔时，此前抛的是裸 Lua 内部报错（
  `bad argument #1 to 'ipairs'`）——不点名字段、不给报文片段，与同一函数对缺失字段的
  诚实口径不一致。现非表即点名返回「响应字段 tool_calls 形态非法（期望数组，实际
  <type>）」，正常报文一字不变。DeepSeek 复用同一份实现。

### 2026-09-22 CLI 超时/上限参数化（F-1/F-2/F-3）

- 三个写死的运行期数值改为可选 CLI 参数（不传 = 现状缺省，零变更）：`--tcp-max-auth-attempts`
  （口令失败上限，原 5）、`--tcp-total-timeout`（连接总时长预算下限，原 600s）、
  `--daemon-grace-ms`（守护弃管宽限上限，原 30000ms；全局选项——任何声明了 `@Daemon`
  的结构脚本都可能触发，在 `robot.active()` 之前完成校验）。
- 三者都不属于 agent 配置面（daemon/TCP 是全局能力），故不进 `mybot.llm.json`；区间
  常量单点在 `util.hpp`，`--help`/校验共用避免判据漂移。

### 2026-09-22 agent 重构阶段 C6 + C7（提示词素材单次读取 / 小路径收口）

- **C6**：预检读到的结构脚本头与脚本清单两段成品被系统提示词复用——原先各读一次，
  两次读之间文件变动会让「预检口径」与「提示词口径」分叉。缓存只覆盖会话开场的系统
  提示词；`/scripts` 与工具的清单查询仍实时遍历（本该看到最新状态）。
- **C7**：`escapeLogMarkers` 挪到 util.hpp 文本处理单点；`call_capped` 死分支删除并
  补上可达路径的首个用例。行为保持型。

### 2026-09-22 agent 重构阶段 C5（重试日志可注入）

- 传输层的重试日志原先硬编码 `std::cerr`——离线用例抓不到它，宿主也没得选。
  `AgentDriverConfig` 新增 `std::ostream* log`（空 = stderr，即改动前行为）；stdout
  只放模型回答；不改审计 JSONL schema。

### 2026-09-22 agent 重构阶段 B4（五个运行期数值配置文件化）

- 原先写死在下游结构体里的五个数值可由**配置文件**覆盖（仅配置文件——不加 CLI 选项
  ：它们都是「一次定好、长期不变」的部署参数）：`max_calls_per_round`（1-1024，**拒绝
  0**——0 是「一轮不限量下发动作」的旧语义，对物理机器人没有正当用法）、`max_retries`
  （0-6）、`retry_backoff_ms`（0-10000）、`run_command_timeout_sec`（1-600）、
  `run_command_max_timeout_sec`（1-3600 且 ≥ 上一个）。
- `max_retries: 0` 的语义修对（该字段是「含首次的尝试次数」，0 = 只发一次不重试）；
  退避单次封顶 60s（放宽参数后 `backoff << attempt` 会长到小时级）；跨字段关系按生效
  值判（`run_command` 工具描述里那组「默认/最大」也改读生效值，原先配置一改就对模型
  说谎）。

### 2026-09-22 agent 重构阶段 A1 + A2（子进程骨架单点化 / 确认程序一致性）

- **真缺陷修复（F1）**：`run_command` 与 `--agent-policy` 确认程序各写了一份
  「fork + exec + 超时 + 进程组终止」且已漂移——确认路径超时后打的是**无超时**
  `waitpid`，SIGKILL 无效（D 态/权限）时 **agent 会话永久挂死**。现在
  `agent_subprocess` 新增 `runChild(ChildSpec)` 单点，差异全部经选项表达；确认路径
  随之获得有界回收（超时放弃并响亮告警）与 fd 吊销。
- **A2（显式决策，不是顺手统一）**：确认程序的**环境保持继承缺省**——它是操作者自己
  写的可信程序，合法的审批/通知脚本可能依赖自有 `…_TOKEN` 类变量，套用子进程密钥
  清洗会**静默砸掉**它们。
- **顺带修掉的真缺陷（EPIPE 待决信号）**：往确认程序 stdin 写 payload 遇 EPIPE 时
  内核产生的 SIGPIPE 在解除掩码那一刻按默认处置**杀掉整个 agent 进程**。修复：恢复
  掩码前用 `sigtimedwait` 零超时消费掉「自己制造的那条」。

### 2026-09-22 agent 重构阶段 B3（图片传输层降副本）

- 拍照场景峰值内存实测大幅下降（1.2 MB 图 49 → 28.5 MB）：图片字节以 `{"__bot_img": N}`
  游标穿过宿主 Json 与 Lua 边界（字节本体不再进请求 Json），wire 组包期才落值——
  同 payload 的全程副本从 ~7 份降到 3 份。通道未注册/取值报错一律 fail-closed 报错，
  不发半截报文。
- 顺带修掉两个隐性的量级放大点：`Camera.lua` 的 base64 不再把 ~2N 个单字符字符串塞进
  Lua 表（1.2 MB 图就是 ~160 万表项）；`json.lua` 编码对无需转义的串加零分配快路径。

### 2026-09-22 agent 重构阶段 C3（REPL 循环可离线单测）

- REPL 循环从 `runAgentMode` 拆出 `runAgentRepl`，I/O 全经参数注入，循环/命令/错误
  恢复可离线驱动（此前只能靠 E2E 兜底）；行为零变化。

### 2026-09-22 agent 重构阶段 C4（历史预算口径诚实化）

- 历史字节预算的记账**不含** system 提示词与工具 schema，单条估重不计 role 字符串、
  JSON 语法开销与非 ASCII 的 `\uXXXX` 转义膨胀（CJK 约 2×），是线上字数的**下界**
  ——原注释只披露了其中一类偏差。注释修正，实现零改动。

### 2026-09-22 agent 重构阶段 C1（REPL /clear）

- 上下文被一次错误结论污染后，此前唯一出路是重启进程——重启会释放硬件、执行器停在
  归零位，现场代价不小。新增 `/clear`：只裁会话历史（保留 system 提示词），机器人
  保持上电。

### 2026-09-22 agent 重构阶段 B2（LlmOpenAI 不再内置缺省接入点）【破坏性】

- 此前 CLI/配置/环境链都没配 endpoint 时会**静默回退**到内置缺省网关——「什么都没配
  就跑起来」的会话把含结构脚本、硬件清单、摄像头画面的上下文发往该网关。
- **新语义（fail-closed）**：endpoint 未配置时**第一次模型调用即失败**，ERR 点名三种
  配置途径（`--llm-endpoint` / `BOT4CJ_LLM_ENDPOINT` / 配置文件 `endpoint`），不发出
  任何报文。`LlmDeepSeek` 保留缺省（厂商官方 API 域），首次回退仍打 stderr 注记。

### 2026-09-22 agent 重构阶段 B1（上下文字节预算配置文件化）

- 三个上下文字节预算此前是编译期常量（docs 自认「只能改源码缺省」），现场调不了。
  配置文件新增 `max_history_bytes`（缺省 4 MiB）、`max_task_tool_result_bytes`（2 MiB）、
  `max_task_image_bytes`（4 MiB）；单位字节，`0` = 不限，上限 64 MiB；严格解析，
  未知字段照旧整档拒绝。

### 2026-09-22 agent 重构阶段 A2 + C2（系统提示词拆分 / 工具结果定界对齐）

- **A2**：系统提示词构建拆出 `agentprompt.{hpp,cpp}` 单点承载（结构脚本头读取、
  「数据不是指令」定界、总量上限）；行为逐字不变。
- **C2**：`list_action_scripts` 的工具结果与系统提示词三段共用同一个 `quoteUntrusted`
  ——此前同一份磁盘首行注释，在系统提示词里被包裹成「数据不是指令」、在工具结果里
  却是裸文本，两条通道定界强度不一致。

### 2026-09-22 agent 重构阶段 A1（AgentSession 拆分，行为逐字不变）

- 全仓注释最密、最容易改错的 `agentloop.cpp`（四套职责互相交织）拆出三个独立单元：
  `agenthistory`（历史所有权/字节估算/整块裁剪）、`agentbudget`（任务内预算）、
  `agentdispatch`（派发漏斗固定顺序单点「策略确认 → 执行 → 审计」）；对外 API 不变，
  存量用例零修改。

### 2026-09-21 文档正确性与可读性复核（README / docs / 架构页）

- 逐条复核入口文档、参考文档与三张架构页：模块计数改为可复算口径（「59 = 47 器件/
  执行器/系统接口 + 3 总线 + 9 框架与模型驱动」）；架构页的行数、lib 清单、守门快照
  按实测重写；「三份脚本设计与用法完全不变」补限定——移植过程修掉过几处**旧行为本身
  有问题**的地方。复核过确认无误的条目留痕以免重复核对。

### 2026-09-21 第三轮审计修复批次（AG-19/AG-20/AG-22：图像内存、连接复用、作用域守门）

- **`capture_image` 的整串拷贝与「先编码再拒绝」（AG-19，高）**：宿主里唯一搬运 MiB 级
  字符串的地方，此前对同一串 base64 拷 5-6 份，而体积判据又在**拿到 base64 之后**——
  「一张注定被拒的图」要先被编码、跨 Lua 边界才丢掉。现在判据调用点零拷贝、体积判据
  改两道且第一道在编码之前（10 MiB 图实测峰值 219 → 163 MiB）。单张图峰值仍是原图
  数十倍属传输层架构问题，已在 docs/agent.md 已知限制写明实测数字。
- **HTTP 连接每轮重建（AG-20，高）**：`llm_http.post` 每次请求都新建 curl 句柄——
  会话池化的理由（省掉每轮重新握手）在**任何生产路径上都没生效**：每轮重做
  DNS/TCP/TLS，历史里那张 base64 图每轮重新编码上传。现在整颗驱动共用一份**池化
  会话**；连接层失败自愈换新句柄、HTTP 非 200 不重建（那是应用层答复，连接是好的）；
  `Session:recreate` 必须排在 `curl_easy_reset` + `cb:free()` **之后**（顺序写错实测
  直接 SIGSEGV）。守门还逼出两个自身缺陷，均已修：池化后 `destroy` 不关池泄漏、失败
  请求自动重建句柄线性泄漏——净结果 **ASan 构建下 agent 路径零泄漏**。
- **`agent:` 作用域表漏登记（AG-22）**：守门改成**派生式比对**——注册表里所有用例名
  前缀要么在作用域表、要么带理由登记，漏登记一整族即红（旧守门结构上不可能发现
  漏登记）。
- **任务内预算的记账与终态（AG-21 + AG-4′）**：降级说明自己计入预算（否则「反复超限」
  可以往历史里持续灌说明文本）；图片额度用尽后如实告诉模型「再调用也不会成功，请改用
  文字结论」（旧文案让模型反复重试到轮次上限，全白烧）；降级说明与「画面已加入你的
  上下文」的成功断言不再自相矛盾。
- **门禁的 agent 过滤器口径（AG-23）**：一个 raw 过滤器要在四类分段上用**不同形态**
  匹配，此前没做区分——两条推荐命令**各只覆盖一半表面**（Lua 段命中 0 个文件、或
  跳过 agent E2E）。收敛为 `test/run_all.sh` 顶部单点映射，并新增覆盖全表面的入口
  `bash test/run_all.sh agent-all`。
- AG-24：RLIMIT_NOFILE 偏低时裸 `return` 的用例改显式 `TH_SKIP`——**跳过必须显式**，
  不能混进通过位。AG-25：两条 agent 记忆行为补覆盖（第 2 轮失败时第 1 轮已完整回传的
  回执必须留在历史；最终回答的 `extras` 必须随 assistant 消息留历史，否则 DeepSeek
  400）。

### 2026-09-21 第二轮审计修复批次（AG-11：覆盖率口径 + fork/exec 盲区）

- **结论：不加行覆盖阈值**——实测该指标既漏链路又有结构性盲区，设阈值只会把测试压力
  挤到测得到的区域。
- **fork/exec 区块在 gcov 报告里恒为 0%**，且不是「没测」而是「测了测不到」——计数在
  进程退出时落盘，而这两个函数永远以 `execve` 结束。AG-3 的标志错误正在这个盲区里藏
  了很久。解法是让子进程**自己报告**走了哪条路径（`BOT4CJ_TRACE_FDS` 轨迹），父进程
  读轨迹断言。
- 覆盖率口径修正（陈旧 `.gcda` 混数据、`mybot` 未插桩、两份 `.gcno` 互相覆盖）后，
  同一份源码 77.90% → 79.96%——e2e/TCP/Lua 链路第一次真正进入统计。

### 2026-09-21 第二轮审计修复批次（AG-4/AG-8/AG-18）

- **任务内聚合体积预算（AG-4）**：`maxHistoryBytes` 只管已完结的旧任务块，**正在进行的
  任务**没有任何体积上限——一旦网关以 413/400 拒绝，那块历史既不在回滚范围也不能被裁
  ，REPL 从此每条任务都以同一请求体失败。现在文本与图片分别计账（2 MiB / 4 MiB，
  0 = 不限），超限的那次结果**不进历史**、换成说明回给模型——为什么是「换掉」而不是
  「截断」：截断会让模型看到半截内容却以为完整（比没有更危险）。
- **提示词体积检查前移（AG-8）**：不依赖硬件的三段在 `buildAgentConfig` 就查，超限在
  **上电之前**失败（**破坏性**：退出码 1 → 2，报错文案对应更新）。
- **相机抓帧的边角语义（AG-18）**：`poll` 的 errno 不再一律报「等待帧超时」（EINTR 与
  句柄失效被说成「摄像头卡住」）；`V4L2_BUF_FLAG_ERROR`（内核明说本帧不可信）置位即
  整帧丢弃；buffer 越界两类成因分别点名且无论哪条路径都把缓冲还回队列。

### 2026-09-21 第二轮审计修复批次（AG-9/AG-13 余部）

- **`capture_image` 的 MIME 改由内容决定（AG-9）**：宿主此前恒拼 `image/jpeg` 标签，
  传一张 PNG 就得到「JPEG 标签 + PNG 字节」，严格网关直接 400。现在按**魔数**判定
  jpeg/png/gif/webp（不认识的格式响亮拒绝），宿主再做一次自洽交叉校验后才发出
  （**破坏性**：非图片文件从「照发」变为 build 阶段拒绝）。
- **文档与实现对齐**：图片消息契约改为宿主直接产出 content 数组（照旧文档写第三方
  驱动会永远收不到图片）；被拒选项清单补齐 camera 四项；随包提示词删掉「配置
  `allow_shell: true`」这种**会被拒绝**的开启方式。

### 2026-09-21 第二轮审计修复批次·测试骨架（AG-5）

- **零断言即失败**：一条断言都没跑就结束的用例此前照样记 `[PASS]`——「环境不满足就
  return」的守卫整条静默通过、什么都没验证却占了通过位。现在零断言**判失败**并要求
  显式 `TH_SKIP("原因")`；断言之后再跳过属语义矛盾，判失败。
- **骨架自证**（新守门分段）：用已知形态喂给骨架断言判定符合预期——它守的是**所有
  其它守门都依赖的那把尺子**：尺子失真时全部用例照样全绿，没有别的机制会发现。写
  自证时暴露并修掉三个骨架自身缺陷（跳过会抹掉真实失败位、失败不记账、全跳过误报为
  过滤器拼错）。

### 2026-09-21 第二轮审计修复批次·续（AG-6/AG-10/AG-13②/AG-17）

- `run_command` 超时的「**整组**终止」补有效断言（同组孙进程必须一起死；改成只杀直接
  子进程判据即红）。放弃回收不再静默（宽限内收不回子进程时 stderr 告警点名 pid 与
  「会保持僵尸」的后果——常驻 agent 自己还活着，init 不会接手）。
- DeepSeek 缺省端点也有 stderr 注记（「数据流向哪里」最该让操作者看见的链路反而
  静默回退）。`thinking = false`（布尔）能关思考模式了（此前只认字符串，与该函数
  自己的注释矛盾；且关闭时不再回传 `reasoning_content`）。

### 2026-09-21 第二轮审计修复批次（AG-1/AG-2/AG-3/AG-14/AG-15/AG-16，agent 子系统）

- **非法 UTF-8 不再进请求体（AG-1，高）**：任一坏字节（`cat` 到二进制、Latin-1 文件名
  、脚本首注释）都会让严格网关直接 400，而那条消息已落在**不可回滚**的历史里——
  REPL 会话从此每次以同一字节偏移失败。宿主侧在「数据进入模型上下文」的三个边界消毒
  （RFC 3629 判据，坏字节替换 U+FFFD）+ 发包前 Lua 侧兜底。**归因修正**：报文由
  `json.lua` 编码，不在宿主 `Json::toString()` 路径上——修复落点据此确定。
- **假网关补齐真机规则（AG-7）**：非法 UTF-8 → 400、`reasoning_content` 有状态要求、
  `tool_call_id` 严格一一配对——假网关此前比真网关宽松，缺陷在离线守门里结构上
  不可见。
- **`Camera.lua` 抓帧重试覆盖全局 `err`（AG-2，高）**：一个局部变量名把驱动 ERR 构造器
  覆盖掉，此后**同一 lua_State 里所有驱动**的错误构造全部崩坏，真实诊断 100% 不可达。
  改用局部变量 + 入口前置校验（fail-closed）。
- **`close_range` 标志修正（AG-3）**：`CLOSE_RANGE_CLOEXEC` 写错成 `1U` → 内核 EINVAL
  → 快速路径**从未执行**（每次白跑约 40ms 退化循环），注释却写着「一次系统调用」；
  硬上限兜底如实上报（不再伪装成「正常结束但退出码 -1」）。
- **API key 拒绝控制字符（AG-14）**：多行密钥会把换行后的内容变成**额外的请求头**发给
  网关（libcurl 对 slist 里的 CR/LF 不做拒绝）。宿主侧与驱动侧两条路一起收口。
- **必填字段显式断言（AG-15）**：`json.lua` 里「字段为 nil 即报错」的分支是**死代码**
  （Lua 表不可能有「键在、值为 nil」的项），必填缺失此前被静默丢掉、真机只回一个含混
  400。改由组装处点名断言（字段名 + 第几条消息）。
- **句柄收尾不留悬垂回调（AG-16）**：`llm_http` 按「**先 reset 再 free**」收尾——把
  「同句柄 perform 两次 / 加重试」这类重构从潜在的内存安全问题变成句柄自身的不变量
  （实测触发即 SIGSEGV）。

### 2026-09-21 F5 正确性批次（Json 零拷贝 / SQL 行列号 / UART 共享告警 / Lua 保护帧）

- `Json::find(key)` 零拷贝访问（热路径免整值拷贝）；SQL 词法报错带 1 起行列号，
  **未闭合引号跨越 EOF 从静默放行改为报错**（**破坏性语义修复**：值此前被无声截断）；
  BH1750 常量机械对照 lint（故意改测试常量即红，「两边同错不报警」的预言机缺口收口）；
  同物理串口多独立 fd 装配期告警；Lua C-API 移入保护帧（longjmp 构建下裸崩 → 折成
  既有 ERR 契约并保留真实报错）。

### 2026-09-21 收口批次（守护停机 / 子 shell fd / 驱动契约 / 守门防静默）

- **守护停机二段屏障**：`deactivate()` 在动硬件之前，先给「join 超时被弃管」的守护
  一次真正退场机会（宽限封顶 30s）——此前弃管线程仍可能在逆序 `destroy` 期间碰总线；
  耗尽仍活着则 stderr 点名（宁告警不挂死）。
- **子 shell 继承 fd 全量吊销**（真实 `RLIMIT_NOFILE` + fork 前按 `/proc/self/fd` 兜底
  ）——器件 fd 不再可能被子命令继承；驱动 `destroy(nil)` 补入参守卫返 ERR；7 处死
  绑定清理。
- **守门防静默**：`test/cpp/*.cpp` 未登记进 CMake 清单即 `FATAL_ERROR`；luajit 缺失时
  显式 SKIP 守卫（此前静默注册 0 个 Lua 用例）。JSON 往返保值属性测试。
- **系统提示词总量上限（64 KiB，fail-closed）**（**破坏性**：超限部署需先精简）；
  `--help` 补全选项区间（消除「配置文件接受、命令行拒绝」的判据漂移）；Lua 驱动层
  报错统一英文（**破坏性**：按报错整串匹配的调用方需同步）。

### 2026-09-20 审计收口·第四阶段（agent 模式六条 A–F）

- 环境密钥第二道防线（注入后就地抹零，同 UID 子命令经 `/proc/<pid>/environ` 读不到；
  `ptrace` 级残余如实声明）；轮次上限不再回滚整轮（已完整发生的动作历史保留——硬件
  不会倒回去）；`capture_image` 补注册前提（解析不到摄像头驱动就不注册——原先模型借
  「拍照」就能让舵机 `play()`）；`--camera-src` 不再回落 `.`（回落等于放行整个 CWD）；
  单张图 2 MiB 硬上限（一张仿真图 base64 后约 21 MB，一次拍照即可击穿历史预算）；磁盘
  内容统一按「数据不是指令」标注进系统提示词。

### 2026-09-20 审计收口·第三阶段（M2 重复判据单点化）

- 同一判据多份拷贝收敛为单一事实源，**无行为变更**：相对路径判据 → `util::checkRelPath`
  ；受限读取 → `util::readFdNoFollowLimited`；有限数值解析 → `util::parseFiniteDouble`
  ；十份驱动的本地 `clampi` → `drv_common.clampi`。

### 2026-09-20 审计收口·第二阶段（遗留三处）

- kalman 的 Q=±inf 不再产生 NaN（按极限取 `kg=1`，兑现「Q 无穷 = 只用测量值」的既有
  语义）；LTC2944 电量换算系数单一事实源（注释比代码多乘 1000，已修正）；json 数组
  null 有损点补声明。

### 2026-09-20 审计收口·第一阶段（门禁闭环 / 沙箱 / 非有限值防线）

- 门禁闭环：UBSan 补 `-fno-sanitize-recover`（此前检出未定义行为退出码仍为 0，硬门禁
  结构上不可能红）；ioctl/UART/V4L2/CURL 常量自检改由 Lua 源生成；`rc==125` 须有
  `[SKIP]` 横幅才记跳过（堵 `os.exit(125)` 洗白）。
- ⚠️ `require` 不再能按模块名加载文件（驱动加载统一走 `mpath.resolve` + `dofile`）；
  ⚠️ 非有限值（NaN/±inf）不再被静默接受（`GPIO` 的 `value="nan"` 不再把线驱动到高
  电平、`wait`/`timeout` 传 NaN 不再无界挂死等）。
- 守护字段数超槽宽加载期报错；守护退出路径 `pcall` 包裹 `destroy`；文档失实收口。

### 2026-09-20 评估批次（安全缺省翻转 / C2 同族收口 / 门禁硬化）

- ⚠️ **破坏性**：`run_command` 缺省不再提供，须 `--agent-shell` 显式开启（同日收紧：
  配置文件这条路也已关闭，只能由命令行开启）。
- ⚠️ **破坏性**：移除 `--llm-key`——命令行密钥经 `/proc/<pid>/cmdline` 暴露；密钥只走
  环境变量链或配置文件。
- ⚠️ SQL 词法层把括号当分隔符（`VALUES(1,2)` 紧凑写法此前报词法错）。
- C2 同族收口：`Ema`/`Kalman`/`BH1750`/`GPIO` 的 NaN 入参统一回落缺省，不再「发布
  NaN 却报 OK」；SPI/UART 参数校验下沉 `bus_contract` 单点（消除「真机静默 floor、
  仿真拒绝」的同参数两种结局）。
- CI 门禁硬化：clang-tidy 退出码修正（此前取管道末端恒 0）、三条软门禁设可判定转硬
  条件、新增 `gate:coverage` 与 `gate:musl`；「帮助 ↔ docs 选项表」改逐文档判据。

### 2026-09-20 审计修复批次（C1–C11）

- ⚠️ **崩溃修复**：Lua 驱动一次返回多个值时宿主段错误（`lua_next` 错栈槽）。
- ⚠️ INSERT 按列名落位：列序≠建表序此前**静默错列**且绕过 Number 校验；列名未知/
  重复/漏列解析期报错。
- NaN 不再穿透数值校验（`i2c_write_reg(fd, reg, NaN)` 此前返回成功但写 0x00）；矩阵
  单元格报错截断 + 转义；MAX30102 FIFO_CONFIG 位域按数据手册修正；Camera 打开失败
  统一释放 fd/mmap。
- 守门自纠四条：错误过滤器假绿、零用例 C++ 二进制判失败、退出码改 0/1（旧版 256 个
  失败回绕成 0）、孤儿夹具检测改整字段匹配。

### 2026-09-20 重构批次（CLI 可测化 / 卫生收口）

- CLI 迁 `src/cliargs.*`（`--help` 输出逐字节不变），新增「帮助 ↔ docs 选项表双向
  一致」守门；守门自检 `test/run_all_selftest.sh` 起步。
- ⚠️ `run_command` 环境清洗改**整词匹配** + 复合密钥名表（`KEYSTONE` 等无关变量不再被
  误剔，真密钥仍剔除）；词法报错文案格式微调。纵深防线与卫生收口若干。

### 2026-09-20 重构批次（会话作用域 / 模块路径 / I/O 语义）

- ⚠️ **破坏性**：动作脚本内联 `@Alias`/`@Vars` 作用域收敛到「本次执行」——此前进程级
  ，会永久遮蔽结构定义并跨脚本残留；跨脚本共享别名须写入结构脚本。
- 多路径模块加载对模块侧成立（宿主注入 `__mpath`）；`run_command` 的 EINTR 当重试、
  TCP 未认证对端不再能杀进程（只有凭据不匹配计入爆破上限）、超限文件报「超过字节
  上限」（不再伪装成语法错误）；协议驱动入 `arg_table` 契约 + 全模块 sweep；CI 构建
  带 `-DMYBOT_WERROR=ON`。

### agent 模式（`--agent`）【历史：2026-09-24 移除，现为两进程拓扑（`mybot --mcp-backend` + `mybot-agent`），见 2026-09-24/25 各条】

- 模式本体：LLM 工具循环为主执行流程，硬件常驻内存，会话结束才 `deactivate()`；
  `--task` 一次性任务，缺省交互 REPL。
- 工具集：`list_action_scripts` / `run_action_script`（路径沙箱 + 8 MiB 上限）/
  `list_hardware`（只读）/ `capture_image`（V4L2 + MJPEG，路径白名单）/ `run_command`
  （超时进程组终止 + 环境清洗，**缺省不提供**）——工具集在两进程拓扑下仍由 C++ 后端
  承载，并陆续扩了 `query_sql`/`apply_sql`/`read_variables`。
- 模型调用是一颗 Lua 协议驱动（`LlmOpenAI` / `LlmDeepSeek`，后补 `LlmAnthropic`）：
  换模型 = 换一个 Lua 文件，宿主零链接期依赖。
- 配置文件 `--llm-config`：优先级 命令行 > 环境变量 > 配置文件 > 驱动缺省，严格校验
  非法即退出 2（配置是数据不是代码）；提示词包 `--prompt-file`。

### 语言与 DSL

- **`$(...)` 表达式**：`@Vars`/元数据列/`@Action` 单元格三处可用（四则运算 + 括号，
  深度/运算符双上限）；文本操作数分派为拼接（别名入式），落点扩到 `@Action` 全部
  单元格；不引入裸 `+` 语法。
- **`@Action` 设备列 `@Alias`**：模板设备列经别名改绑复用片段；手写重复列由静默覆盖
  改报错。
- **`@Include` v2**：嵌套 + `*.once.mt` include-once + 主从覆盖（更靠近主脚本的定义
  获胜）；v1 内联归并复用 `mtmerge_core`，未知矩阵由静默忽略改报错。
- **controller/trigger 多列扇出**：一行多目标；controller 一个 ERR 即停止，trigger 按
  序前置调用。
- **`@Vars`** 命名数值变量（元数据列 `$<name>` 与参数位替换两种消费）；`Number` 列
  解析期校验；词法器引号内字面量与 8 MiB 上限；mtmerge 归并 `@Alias`/`@Vars`。

### 执行引擎与安全

- **守护槽地址注入改 `lightuserdata`**：「地址被 double 化后 ≥2^53 丢位」整类风险在
  语言层面消除。
- **TCP 加固**：非回环强制口令 + 恒时比较 + 空闲/总预算超时；口令可经
  `BOT4CJ_TCP_TOKEN` 传递。
- **动作脚本路径沙箱**：`O_NOFOLLOW` 打开，软链条目不进工具清单（目录外文件首注释
  不再回显进模型上下文）。
- **浮点窄化前判有限性与值域**（float-cast UB 响亮拒绝）；`$` 引用校验前移到任何
  `build` 之前；`destroy` 元数据恢复引用列（修复十余款器件静默丢失去初始化）。
- **派发热路径优化**：列头只解析一次、表达式 AST 按列缓存；沙箱拒绝 NUL 键值、未知
  `--key` 退出 2。
- **沙箱残余如实声明**（`load`/预编译字节码/`ffi`）：威胁模型内驱动可信，列为有意
  取舍；`os.tmpname` 并入中和。
- **异常体系归口** `IllegalArgumentException`；报错文案分语言惯例成文于
  [development.md](development.md)。

### 驱动与总线

- **26 个器件驱动 51 处内联类型检查迁 `arg_table`** + lint 防线（`proto=virt` 注入
  前置不再被绕过；Camera 有意豁免）。
- **多路径布局定位逐段探测**（`HAL`/`virtbus`/`drv_common`），配套非缺省布局冒烟用例。
- **PCA9685 退出 SLEEP 按 datasheet**（写 `AI|RESTART`）；**UART** 波特率改 `B*` 常量
  （旧版从未生效）、termios 快照恢复。
- **新增 `SCSCL` 总线舵机驱动**（飞特 FT-SCS 协议；`set_id` 站号烧写须结构期
  `allow_burn` 授权）。
- **virtbus/驱动加固**：读族校验对齐 HAL、先实例化再 attach、`guard_build` 全总线接入
  、`sensor_daemon` 浮点防线、`bitcompat` 符号扩展原语。

### 工程化与守门

- **大文件拆分**：`robot.cpp` 按类拆四个 TU（只剩 114 行编排门面）；`run_command`
  子进程机器独立 `agent_subprocess.*`；`ActionPlan::build` 抽为白盒可测单点。
- **结构重构**：`CliOptions` 类型化、`HwRegistry` 三容器、守护状态机收敛 `DaemonRunner`
  、`RobotStruct` 拆 Loader/Factory/Runner、守护槽所有权改 `shared_ptr`。
- **守门基建**：HAL 常量编译期自检、CI 三硬门禁 + 五软门禁、`test_curl_consts` 落地、
  `run_san.sh --asan-only`、agent CLI 负路径守门补齐。
- **重复代码九类收敛单点**（`isSafeIdent`/`makeErrResult` 等；三类经评估刻意不收敛并
  注明）；巨函数拆分十项。
- **覆盖补齐**：守护并发压测 + TSan、TCP 异常注入七场景、fd 泄漏检测、离线 ABI 回归
  ；文档全量通读排版。

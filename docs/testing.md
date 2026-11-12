# 回归测试手册

> 本文是 `test/run_all.sh` 全量回归编排脚本的说明。[README](../README.md) 中只保留命令入口。
> 完整门禁还覆盖 `test/run_all_selftest.sh`、构建配置和 CI job。
> CI（`.gitlab-ci.yml`，F-22）在每次推送后自动跑 Release 全量守门 + ASan/UBSan 单跑
> （`run_san.sh --asan-only`：Release 全量已由 `gate:release` 跑过，不重复），
> 构建步带 `-DMYBOT_WERROR=ON`（README 声称的「零告警」由此成为门禁而非约定）；
> 与本地 pre-push 钩子同一条守门。
>
> 十条 job 全部为硬门禁（2026-09-25 起；此前 6 条为 `allow_failure` 软门禁），逐条与 `.gitlab-ci.yml` 一一对应：

| job | 类型 | 内容 |
| --- | ---- | ---- |
| `build:release` | 硬 | `-DMYBOT_WERROR=ON` 构建（零告警即门禁） |
| `gate:release` | 硬 | `bash test/run_all_selftest.sh`（守门自检 14 段：用例是否真被收集/编译 + 七组零编译跨源一致性校验，见下「跨源一致性校验」）→ `bash test/run_all.sh`（Release 全量守门） |
| `gate:sanitizer` | 硬 | ASan/UBSan 构建 + `bash test/run_san.sh --asan-only`；UBSan 以 `-fno-sanitize-recover=undefined` 编译（**检出即终止**，见下） |
| `gate:agent-e2e` | 硬 | `rust:1-slim-bookworm` 继承 `build:release` 后端产物并构建 Rust release；直接运行 `scripts/agent_e2e.sh` 与 `scripts/ica_e2e.sh`（两条都跑完再判红，一个红不掩盖另一个红），缺产物/依赖或超时即失败，`agent-e2e.log`/`ica-e2e.log` 始终留档；不受其它 jobs 的 Rust 可选跳过影响。CI 里唯一带 Rust 工具链的一道，故两条 Rust 侧端到端都归它 |
| `gate:tsan` | 硬 | TSan 构建 + 三条守护并发 C++ 用例，`halt_on_error=1`（TSan 报告即影响退出码） |
| `gate:clang` | 硬 | clang 构建 + C++ 单测烟雾 |
| `gate:clang-tidy` | 硬 | `src/` 静态分析；退出码取 clang-tidy 自身，`clang-tidy.log` 随 artifacts（`when: always`）留档 |
| `gate:coverage` | 硬 | `bash test/run_coverage.sh`（`--coverage` 构建 + 跑 `mybot_tests`；`COV_WITH_GATE=1` 时另跑一遍全套守门），报告随 artifacts 留档。「硬」判的是采集链路本身，**不设行覆盖阈值**（理由见下节） |
| `gate:musl` | 硬 | alpine 3.20/musl 下：三个常量自检 → `mybot_tests` → 整段 `test/run_all.sh`（`BOT`/`BOT_TESTS` 指到 `build-musl/`；Rust agent 段因镜像无 Rust 产物按 SKIP 计，汇总可见） |
| `gate:agent` | 硬 | Rust agent（`agent/`，包名 `mybot-agent`；原 MCP sidecar，rig 迁移批次 B 更名）：`cargo build --release`/`test`/`clippy -D warnings`/`fmt --check`（均 `--locked`，`rust:1-slim`）。与 `gate:agent-e2e` 独立，不给既有 C++ jobs 加 Rust。⚠ ASan/UBSan/TSan 只插桩 C++，**对 agent 是盲的**——agent 安全靠 Rust 所有权 + clippy/test，不是 sanitizer |

### 覆盖率数字的口径与已知盲区（2026-09-21 AG-11 实测）

**先看口径再看数字**，否则极易误判：

- **它只反映该脚本实际跑过的东西**。缺省模式只跑 `mybot_tests`（C++ 单测），`mybot` 二进制的
  e2e/TCP/Lua 链路不计入；要计入请设 `COV_WITH_GATE=1`。实测差距为零不是因为 e2e 没价值，
  而是因为以前 `mybot` **根本没被插桩**（脚本只构建 `mybot_tests`）。现在两个 target 都构建。
- **fork/exec 子侧代码恒为 0%，且这不是「没测」而是「测了测不到」**：gcov 计数在进程退出时
  落盘，而 `agent_subprocess.cpp` 的 `execChild` / `revokeInheritedFds` 永远以 `execve`
  结束——exec 用新映像的计数页覆盖当前进程，子侧执行记录不可能被写出。实测这两个函数
  `0% blocks executed`，而相关测试全部通过。
  这个盲区不是无关紧要的一角：AG-3（`CLOSE_RANGE_CLOEXEC` 标志写成 `1U`、快速路径从未执行、
  每次 `run_command` 白付数十毫秒）正是在这里藏了很久——该区块对所有读者显示 0%，所有人都
  当它是「有意不测的部分」。
  该区块的保证改由**行为断言**承担：子进程在 fork 后、exec 前把「走了哪条路径」写进
  `BOT4CJ_TRACE_FDS` 指定的文件，父进程断言轨迹（见 `test_agenttools.cpp` 的
  `agenttools_child_side_fd_revocation_reports_its_path`）。把标志改回错误值，该用例立刻红。
  探针本身是**两道开关**（A6）：编译期 `MYBOT_TEST_TRACE_FDS`（CMakeLists 只给
  `mybot_tests` 定义；`MYBOT_CORE_SOURCES` 被两个目标各自编译一份，所以真能做到
  生产二进制里没有这条代码路径）+ 运行期 `BOT4CJ_TRACE_FDS` 指定路径。此前只有后一道，
  等于生产 `mybot` 也带着「按环境变量向任意路径追加写」的测试钩子。
  **不要试图用行覆盖去覆盖它**。
- **因此不设 `COV_MIN_LINES` 硬阈值**：一个既漏掉 `mybot` 链路、又有结构性 0% 区块的指标，
  设阈值只会把测试压力挤到「测得到」的区域——缺陷正好往盲区躲。

> **转硬依据（2026-09-25，如实）**：六条软门禁原写的转硬条件是「CI 基线镜像上连续 2 轮
> pipeline 全绿」，但开发机无 docker、也看不到托管方的 pipeline 记录——这条证据从仓库
> 内部不可观测，等下去只会让它们永久留在软态。改以**同版本工具链的本地预跑**为判据：
> clang / clang-tidy 用 LLVM 14.0.6（bookworm 同版本）、musl 用 proot + alpine 3.20
> minirootfs（镜像同源同版本）、TSan 名单三用例连跑 5 轮、Rust 四检 rustc 1.98.1、
> 覆盖率 `COV_WITH_GATE=1` 全程 rc=0。预跑揪出并修掉的真问题：clang-tidy 新增 3 条
> （`getenv`/`strerror` 未走 `util.hpp` 单点、一处 string 链式拼接）、Rust 2 条 clippy
> `manual_async_fn` + rustfmt 差异、**musl 下 `hal_backend_glibc.lua` 的 `version()`
> 取 `gnu_get_libc_version` 符号时抛错**（契约是非 glibc 返 nil；拖垮三个 UART/HAL
> 用例）。各 job 注释写明了「环境性变红」的辨认特征（TSan 的 VMA range、proot 下
> `PR_SET_DUMPABLE` 失败）。这些 job **不进入** `run_all.sh` 的记账——守门汇总口径不变。

### `gate:coverage` 原转硬条件两条的处置（2026-09-22 核实，2026-09-25 转硬）

该 job 的转硬条件在 AG-11 后曾改写为两条；2026-09-25 转硬时①因不可观测而放弃（改为「采集链路任一步失败即红、不设阈值」），②已满足：

| 条件 | 现状 | 证据 |
| --- | --- | --- |
| ① 覆盖数据随 artifacts 连续入库可追溯（口径与脚本版本对应） | **放弃作为转硬条件**——要看托管方连续 pipeline 的 artifacts 留存，从仓库内部不可观测；artifacts 仍留档 4 周供对比 | — |
| ② 盲区（fork/exec 子侧）确由**行为断言**覆盖 | ✅ **已满足并已反向验证** | 用例 `agenttools_child_side_fd_revocation_reports_its_path`（`test/cpp/test_agenttools.cpp`）存在，且随 `run_all.sh` 的 `cpp-unit` 段在 `gate:release` 里执行；**把 `src/agent_subprocess.cpp` 的 `kCloseRangeCloexec` 改回出错的 `1U`，该用例转红（2 条断言失败）**，恢复 `1U << 2` 后绿 |

**本地实测基线（`COV_WITH_GATE=1 bash test/run_coverage.sh`）**：2026-09-22 为 **80.27%（4394/5474）**，
2026-09-25 为 **78.10%（5842/7480）**（分母涨 2006 行：MCP 后端、wait_variable、断连动作等）。留这个数只为**未来对比**，不作为阈值——
理由见上一节（该指标既漏 `mybot` 链路又有结构性 0% 区块，设阈值会把测试压力挤到
测得到的区域）。要看趋势就前后两次数对比，不要拿它当及格线。

## 用法

```bash
bash test/run_all.sh          # 全部离线守门（分段见下，顺序与条数以脚本为准）
bash test/run_all.sh pca9685  # 文件名过滤
bash test/run_all.sh tcp      # 只跑 TCP 动作源
bash test/run_all.sh agent-all # agent 全表面（过滤口径见下面的方框说明）
```

全部守门在无 `/dev/i2c` 的开发机上即可运行。

> **按名字过滤时注意分段过滤器形态不同**：Lua 段比 `test_*.lua` 文件名子串、
> C++ 段比 `scope:` 作用域语法、加固段按分段门、端到端按段名——所以裸 `agent`
> 与 `agent:` **各只覆盖一半表面**（前者漏掉 15 条 `agentconfig_`/`agentmode_` 与
> agent 负路径，后者跳过 agent E2E）。要「agent 全跑」用 `agent-all`；
> 映射单点在 `test/run_all.sh` 顶部，并有一条自证防它悄悄退化。
>
> **自证的口径（SAN-2，2026-09-22）**：`agent-all` 的 Lua 那一格曾是
> `filter_lua="agent"`（注释称 `test_agent*.lua`），而**该文件模式从未存在**——
> 于是 Lua 段实跑 0 个文件，而循环对「命中 0」是合法状态、既不报错也不计入汇总
> （实测汇总 11 条、Lua 段 0 条）。后来那一格是 `"llm"`（`test_llm_*.lua`：
> 协议驱动报文整形与响应映射，即 PL-3/PL-6 落过缺陷的那一层），自证改为
> **按 `agent_lua_roster` 核对真实文件**：① roster 里的文件必须存在且会被跑到；
> ② `test/test_llm_*.lua` 下每个文件都必须登记（漏登记即红）。
> 2026-09-25 #8 删除 Lua 协议驱动轨道后，该过滤器**有意命中 0 个文件**——机制
> 保留（roster 现为空表、反向核对仍生效），将来若再出现 `test_llm_*.lua` 会被
> 自动纳入自证，而不是悄悄跑 0 个文件还报绿。
> 旧自证检查的是**映射的形状**，新自证检查的是**被映射到的文件**。
>
> `agent-all` 的 Lua 段经 `agent_lua_roster` **精确清单**纳入 `test_camera.lua`
> （`capture_image` 依赖的摄像头协议面：仿真取帧、base64、错误路径）——2026-10-01
> 起改 `modules/Camera.lua` 或图像链路，`run_all.sh agent-all` 会拦住。真机的
> `test_camera_v4l2.lua`（需 /dev/video*）**不在**清单内：子串过滤器分不开两文件，
> 精确清单只点名仿真用例；真机 ABI 回归仍由全量跑/真机上显式跑。摄像头链路的
> 端到端覆盖在 `scripts/agent_e2e.sh` 的 R9（OpenAI `image_url`）与 R13（Anthropic
> base64 图片块及恢复占位）。

### ctest 逐用例入口（可选）

`run_all.sh` 是权威编排；CMake 同时把每个 `test/test_*.lua` 与 C++ 单测注册成了独立
ctest 用例，便于定位单条失败、享受逐用例超时（时长单点 `test/lib/params.sh` 的
`TEST_TIMEOUT`，与 `run_all.sh` 同源），不必整段重跑：

```bash
cd build && ctest --output-on-failure        # 全部注册用例
cd build && ctest -R lua_test_pca9685        # 按名字过滤（Lua 用例前缀 lua_）
cd build && ctest -R 'lua_|cpp_unit'         # 只跑 Lua 段 + C++ 单测
```

注册项来自 `CMakeLists.txt`：每个 `test/test_*.lua` 一条，统一经
`test/lib/device_gate.sh` 包装——读文件内 `-- requires: <dev>` 标记，本机无
`/dev/<dev>*` 时以 125 退出，由 `SKIP_RETURN_CODE 125` 记为跳过（2026-09-20 阶段 5.2
之前 ctest 侧按**文件名**特判 `test_jit_warmup.lua`，同样带 `video` 标记的
`test_camera_v4l2.lua` 被裸注册，无摄像头机器上报 Failed 而非 Skipped；现在两条入口
共用同一个标记解析）。外加 `cpp_unit` / `const_ioctl` / `const_uart` / `const_v4l2`。
只跑 ctest
**不覆盖** `run_all.sh` 的端到端、TCP、agent 与守门完整性分段——提交前仍以
`bash test/run_all.sh` 为准。

## 守门日志怎么读（中途态 vs 失败）

`bash test/run_all.sh` 的输出是**流式**的：`[PASS]/[FAIL]` 逐条打印，末尾才有
`[DONE]` 与 `汇总:` 行。因此人工或 CI 中途读到的日志天然可能**还没有汇总**——
那不是失败，也不是通过。

- **权威判据**：末尾的 `汇总: N 通过, M 失败, K 跳过`，以及紧随其后的
  `守门结果: rc=0/1`（rc 行显式打印，日志尾部被截断时也能判读）。
- **中途态**：被 Ctrl-C / CI 取消时打印
  `守门被中断：汇总未产生（中途态，非失败）`，并以退出码 130 结束。
- **退出码**：`0` 全绿；`1` 有失败用例（或过滤器零匹配的假绿防线）；`2` 表示
  运行时缺编译产物等前置条件（见「守门完整性」）。

## 守门分段明细

> 分段顺序与用例条数以 `test/run_all.sh` 为准（本节只讲每段职责，不维护条数）。

1. **Lua 离线单测**（`test/test_*.lua`，LuaJIT 运行；断言统一经 `test/lib/tester.lua` 出 `[PASS]`/`[FAIL]` 与 `[DONE]` 完成标记；真机用例经 `test/lib/device_gate.sh` 按 `-- requires:` 标记自动跳过）
   - 其中 `test_driver_contract.lua` 是**驱动入口契约 sweep**（2026-09-20 阶段 4.5）：逐个真的加载全部 `modules/*.lua`，断言 ① 可加载（模块路径引导写错即刻红，不必等 E2E）、② `build`/`call`/`destroy` 三入口齐全、③ 非表入参返回 ERR 契约表而非抛 Lua error。豁免只有两个且都注明理由：`bitcompat`（纯 Lua 库）与 `Camera`（头注声明不挂 `arg_table`）
2. **lint 段**（2026-09-20 阶段 2 收尾防线）：`grep` 断言驱动入口一律走 `arg_table`，且模块路径引导一律走 `__mpath`（见 [reference.md](reference.md) 的 `BOT4CJ_MODULE_PATH`）——都是「约定靠不住、用一行 grep 钉住」的便宜防线
3. **virt 端到端**（`robots/test/*_virt.sql` 走内存仿真总线 `virtbus`，断言 `:f` 浮点透传与守护持续发布——条数见 `e2e_cases`，明细见 [virtbus.md](virtbus.md)「守护无硬件端到端」一节）
4. **无硬件契约回归**（守护/别名/转发/引用路径）：
   - 负值契约：INSERT 拼错表、别名重复、`$` 引用标量、动作参数覆盖结构元数据必须**清晰报错**而非裸崩
   - 含 `PCA9685`/`MCP4725`/`SCSCL` 的**非守护** `@Action` 写路径正/负六条——虚拟总线已不再只服务守护路径，UART 直写路径经 `BUS="uart"` 模型附着 + 跨状态机 fd 采纳
5. **@Merge 展开**（运行端动作脚本归并，归并内核由 test_mtmerge.cpp 白盒单测覆盖；旧名 @Include，2026-10-12 改名，@Include 现为 C 式内容拷贝）
6. **TCP 动作源回环**（复用 `scripts/tcp_e2e.sh`，随机端口，缺 python3 自动跳过）
7. **TCP 异常注入**（复用 `scripts/tcp_adversarial.sh` 场景矩阵：半包/断连/空闲挂死/垃圾帧/口令负路径，每场景独立服务端 + 看门狗）
8. **agent 端到端三段**（本地假模型服务 `scripts/fake_llm_server.py`，均无需硬件与真实 key）：
   - `scripts/agent_e2e.sh`——拓扑是**两个进程**：`mybot-agent`（Rust，rig 驱动）↔ `mybot --mcp-backend`（AF_UNIX 帧）。R1 工具循环（三条回执真的从后端回来、动作脚本在**常驻**机器人上被执行、后端侧 Lua 驱动见证）、R2 提示词包进系统提示词、R3 审计轨迹（agent 落 session/model 行、后端工具的工具行归后端）、R4 REPL + 能力门控（缺 `--agent-shell` 时 `run_command` 不在工具表）、R5 `--check-config` 正负路径、R5m 配置镜像（同一份 `mybot.llm.json` 经两侧现役同名 env `BOT4CJ_LLM_CONFIG` 喂双端 `--check-config` 互钉共享面：配置通道、审计落点、`--audit-log` 的 CLI>file 层序、未知字段的双端拒绝与 audit_log 类型错的双端拒绝；批次 A（2026-10-01）后 C++ 后端对模型侧字段只经白名单不解析——字节预算摘要行随 R5m 互钉一并退役，类型错镜像改用 audit_log 这类双消费字段，模型侧坏值在 C++ 侧正确放行、由 Rust 独占校验）、R6 单轮调用上限截断（SAN-1）、R7/R7b 限流 429 重试与恒 503 如实失败（SAN-3）、R8/R8b 单次超时与 SIGINT 取消（R8b：在飞请求被即时丢弃、进程在信号后 5s 内优雅退出 0、0 条慢响应）、R9 图片后注（工具回执进 tool 消息、图片走紧随的 user 消息）、R10 stdout 写失败不 panic 且审计收尾不丢（H2）、**R11 `--session-file`/`--resume` 两进程接力**（批次 D，2026-09-25 落地：进程一落盘 + 完整跑完工具循环，重启假模型服务后进程二 `--resume` 启动，首个请求带着进程一的完整历史，审计 `start` 行 `resumed:true` 且沿用同一 session id；两条免服务负路径——换 `--robot` 令指纹不符退出 2、缺命令行 `--session-file` 的 `--resume` 退出 2）、R11b 历史整块裁剪后的落盘与恢复（`history_summary=false`，兼作摘要的反向判据：无摘要请求、无 `session_summary` 记录、系统提示词无摘要一节）、**R11c 历史摘要**（2026-09-25：`max_history_bytes=1` 下三个任务，任务 3 前裁掉块 1 → 夹具 `summarize` 模式识别「会话历史压缩器」请求（不得带工具、必须有定界转录，否则 400）并答出被裁任务名 → 主请求 system 末尾带摘要且只覆盖被裁任务；审计恰一条 `status=summary` 不带 `turn` 的 model 行；会话文件落 `session_summary(keep_blocks=1)`；进程二 `--resume` 收口成 6 条消息并带回摘要，任务 4 前再裁再摘要，新摘要承接旧摘要）。在 `test/run_all.sh` 中缺 `mybot-agent` 产物按 **SKIP** 计（Rust 是可选产物）；直接运行本脚本或 `gate:agent-e2e` 时，两侧产物缺任何一个均判失败。
   - `scripts/mcp_e2e.sh`——C++ 后端 + **纯标准库 Python 帧客户端**直连 socket，独立第三实现对齐线协议字节；socket 父目录 0700 / 文件 0600、能力门控（`run_command`/`apply_sql`/`read_variables` 随开关进出 `tool.list`，正反两趟）、未知工具回执点名且 `executed=false`、`apply_sql` 带电生效与热删除真的摘掉变量、`read_variables` 带回驱动返回表的键、`wait_variable` 同门控进出工具表 + 首采样满足 + 非法条件 `paramError`、策略拒绝时 `run_command` 零副作用、fd 卫生（子 shell 不继承后端 socket fd）、审计含失败工具、SIGTERM 优雅停机。
   - `scripts/ica_e2e.sh`——ICA 证据账本（`BOT4CJ_ICA=1` 的实验特性，见 [ica.md](ica.md)）的两进程离线校验：未准备的动作被拒 → 先只读观察 → 登记行动候选 → 执行一次 → 比较回执，并断言后端审计里 `run_action_script` 恰好一条。2026-10-04 起接进本段（此前只有 ica.md 提到、无任何守门调用它，改坏了不会有人知道）；产物依赖与 SKIP 口径同 `agent_e2e.sh`。2026-10-06 起 CI 的
`gate:agent-e2e` 也直接跑它：本段在产物缺失/陈旧时按 **SKIP** 计而汇总仍是 rc=0，
`gate:release`/`gate:musl` 的镜像里又没有 cargo，那条洞只有 CI 这道唯一带 Rust
工具链的 job 能补（本机侧由 pre-push 的新鲜度硬门挡，见 [development.md](development.md)
「守门钩子（pre-push）」第 3 条）。
脚本自身无条件把 `MYBOT_HOME` 指向它的临时目录，故不会往真实 `~/.mybot` 写会话历史。
   - **R12 DeepSeek**：标准非流式工具响应、Bearer 鉴权、逐轮 `reasoning_content` 原样回传，重启 agent 后首个请求保留完整工具与推理历史。按现役 Rust 语义验证，不承诺配置 `thinking` 生效。
   - **R13 Anthropic**：`/v1/messages` 与 `x-api-key`/`anthropic-version`、顶层 system、`input_schema`、成对的 `tool_use`/`tool_result`、图片按原始 JPEG 字节发送 base64 source、usage 进入审计；恢复后保留工具历史但图片只留占位，不重发旧画面。假服务会拒绝串错协议或不配对的工具块。
   - **R15 流式输出**（2026-09-25）：假服务按 `FAKE_LLM_FRAME_DELAY_MS=150` 逐帧发 SSE，stdout 经计时读端（记录首末字节间隔与 `read` 次数）证明缺省面逐 delta 到达（间隔 ≥ 0.5s、≥ 3 次 read）、思维链不进 stdout、请求体带 `stream:true`；`--llm-no-stream` 整段一次到齐（间隔 < 0.1s）且请求体不带 `stream:true`；两面 stdout 正文 `cmp` 逐字节一致；配置文件 `stream:false` 与缺省流式都在 `--check-config` 摘要「输出模式」行如实呈现。
   - **R14 无硬件闭环**：复用 `robots/test/mcp4725_virt.sql` 与 `scripts/test/mcp4725_virt.mt`，实际执行 `read_variables → run_action_script → read_variables`；假模型解析 DAC 回读，确认 `0 → 2048` 才给完成回答。反例改为写 25%（1024）：三次工具都执行成功，但回读不符必须让任务失败，不能凭调用次数谎报闭环完成。无需 shell 或真实 I2C。
   - **R16 终端面行编辑**（2026-09-25，rustyline）：其余场景都是管道面，本场景用 Python `pty` 把 stdin/stdout 都变成终端——`/he` Tab 补成 `/help`、提示符处 Ctrl-C 清行不退出、↑ 召回上一条、历史落到 `BOT4CJ_AGENT_HISTORY` 指定路径且文件 0600 / 目录 0700；模型轮进行中 Ctrl-C 仍走 SIGINT 取消路径（slow 剧本，优雅退出 0）；反证本次运行的管道面场景没有写缺省历史文件。
   - **R19 `http_fetch` 出站白名单**（Phase 6，2026-10-08）：脚本另起一个本地 HTTP 服务当「白名单里的受控 API」（离线可复现，不打公网），夹具 `httpfetch` 模式按 `FAKE_LLM_FETCH_URLS` 逐轮下发五次调用——正文（`> ` 定界 + 「数据不是指令」）、超 `--http-fetch-max-bytes` 拒绝、非文本类型拒读、302 只报 `Location` 不跟随、同一服务换主机名 `localhost` 被白名单拒绝；**服务端记下的到达请求恰为前四条**（重定向目标与被拒主机都没发出）是比回执文本更硬的判据。agent 审计每次调用一条 `kind=tool` 行、`args.url` 去查询串（查询串里的假密钥不落盘）、`ok` 与 `summary=status=<码>` 逐条如实。R19b：不给 `--allow-host` 时线上工具定义里没有 `http_fetch`；R19c：`--allow-host` 写成带 scheme/路径的 URL 即配置错误退出 2。`.no_proxy()` 是否生效由 Rust 单测 `system_proxy_env_is_ignored` 钉住（E2E 不设代理环境：rig 的模型客户端同样会读它）。
   - **R20 录制模式与训练集导出**（2026-10-09，`--record`/`--record-dir`）：主场用 `--record-dir` 显式根 + camera 剧本（拍照进上下文），断言录制段四件套（meta/system/events/images）与 0700/0600 权限、事件时序（`session_start` 打头 → `task_begin`/`model_call`(turn 0-based)/`msg`(图片只落引用，base64 不进 JSONL)/`task_end`/`session_end`）、meta 密钥纪律（只记来源枚举）与工具 schema 快照、**图片本体与源 JPEG 逐字节一致**；随后跑 `scripts/record_export.py` 断言**导出回路**——raw 方言的样本结构（任务原文/tool_calls 与回执配对/图片引用）、openai 方言 data URL 与源图逐字节一致且图片 user 消息在 tool 消息之后（provider 同序）、sharegpt 方言的 `<tool_call>`/`<tool_response>`/`<image>` 约定与 stats.json。R20b：`--record` 缺省布局 + 两进程续接（录制根从「录制落点」日志定位——机器人目录名经安全归一带指纹后缀，不能硬拼）→ 两个录制段、`latest` 指针改指、`resumed_from` 链回前段、`resume` 事件声明前缀条数；session 粒度导出把两段按链拼成一条轨迹且**会话文件前缀联结**进样本（第一任务原文来自会话文件）。R20c：`--record-max-bytes 1` 图片仓响亮降级为 `stored:false` 元数据、任务照常完成。R20d：`--record` 与 `--record-dir` 同给退出 2；`--check-config` 摘要含录制栏。水位/去重/权限另由 `record.rs` 单测钉住。
   - 以上只验证本地协议与虚拟器件，不代表真实云端模型或真实硬件验收；协议族差异（OpenAI 兼容 / DeepSeek / Anthropic）由 R12/R13 在 Rust 侧收口。agent over TCP 远程 REPL 已评估**不做**（2026-09-25）。
9. **@Merge 相位语义**（`@Action` 两两归并时相位 0/±1 对齐、负相位丢行告警、前导 `-` 的设备在运行端被跳过）
10. **输入边界加固**，覆盖：
   - `--tcp-host` 非法地址退出码 1、未知 `--key` 退出码 2、动作脚本/结构脚本超 8 MiB 上限
   - `@Daemon` 驱动误配无 `build` 时的回滚路径
   - `mode` 键不得改写 controller 派发目标；驱动 `call()` 漏写 `return` 不得被当成成功；驱动返回自引用表须清晰报错而非宿主栈溢出
   - C++ 无条件拒绝已移除的 `--agent`/模型侧选项；后端专属选项误用于其它模式同样退出 2。Rust 的配置错误、缺 API key、提示词超 64 KiB 由 Rust 单测及 E2E 预检覆盖
11. **守护 tick 故障注入**（总线持续 NACK → 驱动 ERR → 守护不发布、`count` 停滞，主流程仍正常 join）
12. **进程级 fd 探针**（长动作 + 守护采样期间轮询 `/proc/<pid>/fd`，稳态 fd 数须有界平稳）
13. **信号/退出路径**（F-08：播放中 SIGTERM → rc=0 + 停派发行 + 守护 `joined, total publishes=`；`--tcp` 等待连接中 SIGTERM → rc=1 + 明确中断报错——覆盖 `main.cpp` 的 sigaction 与 `robot.cpp` 的停机分支）
14. **fixture 孤儿检测**（F3/N-32，无过滤器全量跑时执行）：`robots/test/*.sql` 与 `scripts/test/*.mt` 中未被任何用例表引用的夹具判失败；判据是**整字段精确匹配**（`e2e_cases` 的用例名、`parse_cases` 的两列文件名、`scripts/*.sh`、`CMakeLists.txt`），不是子串——2026-09-20 审计 C11 修正：子串判据下每个真机夹具 `bme280.mt` 都是已登记仿真用例 `bme280_virt` 的子串，26 对真机夹具（52 个文件）因此被误判成「已登记」而从不执行、检测器却报「无孤儿」。实机夹具（需 `/dev/i2c-*`、`/dev/spidev*`、`/dev/gpiochip*`、`/dev/pwmchip*`、`/dev/serial*`）在脚本的 `orphan_whitelist` 显式声明
15. **系统常量自检**（F-24 + A2，无过滤器全量跑时执行）：三个 C 自检二进制把 **Lua 源里**硬编码的编号与系统头做编译期断言比对，漂移在构建期即失败，执行期再跑一遍作双保险。事实源是 Lua，**不是 C 里的手抄副本**：配置期 `test/gen_const_check.cmake` 从 `modules/lib/hal_backend_glibc.lua`（consts 表，方案 A 下沉后的唯一事实源）、`modules/lib/hal/uart.lua`（两套波特率映射表）、`modules/Camera.lua` **纯文本抽取**常量生成 `const_lua.h`，每项做**双边断言**——`Lua 抽取值 == 手抄预期值`（抽取生效 + Lua 未漂移）且 `预期值 == 系统头`（内核/架构未漂移）。抽不到任何必需常量即 `FATAL_ERROR`（静默生成空头会让断言退化成自证）。`test_ioctl_nums`（SPI/GPIO/I2C ioctl + 结构尺寸）、`test_uart_consts`（termios 布局 + 两套波特率表 + 打开标志）、`test_v4l2_consts`（V4L2 ioctl + Camera.lua 的 ABI 尺寸表）三者均无外部依赖（原第四个 `test_curl_consts` 随 Lua 协议驱动轨道删除，2026-09-25 #8）
16. **C++ 层单测**（`test/cpp/`，`mybot_tests` 目标，零第三方框架），覆盖：
    - 基础设施：JSON 值语义、JSON 文本解析、Lua↔Json 边界与转换深度上限、util 全局助手（安全标识符判据 `isSafeIdent`、深度护栏 `DepthLimitGuard`、CLI 切分 `cli::parseKeyValue`、越界文案模板 `rangeErrorText`）
    - 解析管线：`.mt` 矩阵状态机（含块嵌套 children 树、叶子不可嵌套、深度上限、EOF 未闭合响亮报错）、SQL 词法/语法、元数据收集与 `$` 引用环检测、@Merge 归并核心白盒、@Include 内容拷贝与子块内位置局部归并白盒
    - 守护：never-spawn/abandon 分支
    - 会话变量作用域（2026-09-20 阶段 1）：动作脚本内联 `@Alias` 不跨 `run()` 残留、不遮蔽结构变量、报错脚本不改写注册表、200 轮重复执行后结构名字索引不增长
    - I/O 与错误语义（2026-09-20 阶段 4）：`retryEintr` 只在 EINTR 重试、整文件读取超限报「字节上限」而非「不是合法 JSON」、TCP 口令三态（空闲超时/对端关闭不算鉴权失败，只有凭据错才计数）、表达式语法错误截断回显
    - agent 后端：配置文件解析与后端字段合并、能力门控、工具派发与路径沙箱、任务预算与回执；模型装配、工具循环上限与回滚、历史裁剪、会话编解码与推理内容保留由 `agent/src/` 的 Rust 单测负责
    - UTF-8 边界（2026-09-21 AG-1）：`util` 的合法/非法判据与消毒（过长编码、代理区、> U+10FFFF、截断尾部、连续坏字节折叠）、`run_command` 输出与动作脚本首注释的消毒终点、API key 控制字符判据

    另有两条纯 Lua 用例：`test/test_json_lua.lua`（Lua 侧 JSON 编解码）、`test/test_utf8.lua`（UTF-8 判据与消毒。它与 C++ 侧 `utf8_*` 用例**同表向量**——两边判据必须一致，改动任一侧都要两边过）

17. **测试骨架自证**（`test/cpp/harness_selftest.cpp`，`harness_selftest` 目标，独立于 `mybot_tests`）：用一份**独立的 th 状态**把已知形态喂给骨架，断言它给出的判定符合预期——零断言必判失败、`TH_SKIP` 记跳过不算失败、断言后跳过判失败、正常通过/失败仍被认出、过滤器零命中返回 -1。独立二进制的理由：这些「例句」用例故意含失败形态，混进 `mybot_tests` 会让主守门出现永久失败项。它守的是**所有其它守门都依赖的那把尺子**——尺子失真时全部用例照样全绿，没有别的机制会发现。由 `run_all.sh` 的 `harness-selftest` 段执行

## 守门完整性

编译产物（`mybot` / `mybot_tests` / `harness_selftest`）缺失时，对应分段**判失败**而不是静默跳过——否则「不构建」也能报出「0 失败」，而实际只有 Lua 段在跑。仅三类环境软依赖按跳过处理：

- 真机用例（本机无 `/dev/i2c-*` / `/dev/video*` 等）：统一经 `test/lib/device_gate.sh` 读文件内 `-- requires: <dev>` 标记判定，`run_all.sh` 与 ctest 共用同一实现；`video` 类用例可用 `BOT4CJ_TEST_VIDEO=<设备路径>` 指向别的设备（跳过门与测试体都认这个变量，路径不存在则按跳过计）
- TCP / agent 端到端缺 `python3`
- `run_all.sh` 的 Rust agent 段缺 `agent/target/release/mybot-agent`（独立可选产物）；专门的 `gate:agent-e2e` 不允许此跳过。Rust agent 全程 reqwest + rustls（静态链接），本机 libcurl 有无都不影响该段——2026-09-25 #8 起仓库已无 libcurl 依赖

产物**陈旧**在起跑前就拒绝（`run_all.sh` 比 mtime，旧于编译期输入即 `exit 2`；逃生口 `BOT_ALLOW_STALE=1`）。取材面**按产物分配**，且每条都要**减去属于别的目标的文件**：`mybot` 吃 `src/` 减 `src/main.cpp` 本身就是入口；`mybot_tests` 吃 `src/` + `test/cpp/` 减 `src/main.cpp`（它的入口是 `test/cpp/main.cpp`）、`test/cpp/harness_selftest.cpp`（独立骨架自证）；`harness_selftest` 只吃 `test/cpp/harness_selftest.cpp` 与 `harness.hpp`。归属的权威出处是构建系统自己的记账（`build/compile_commands.json` 里 `-o CMakeFiles/<target>.dir/<src>.o`）。`CMakeLists.txt` **不在任何一份取材面里**：它是构建描述而不是编译期输入，「描述变了要不要重链」由 cmake/make 自己算——把它当输入就等于要求「产物比构建描述新」，而 make 对输入未变的目标只回一句 `Built target` 不重链，于是门恒红。共用一份最大集合、或不减归属，都会犯同一个错，两种坏法：给 `mybot` 算上 `test/cpp/`，则「只改一条用例」会让它永远判陈旧，而 cmake 根本不会为此重链 `mybot`——**重建也修不好**，唯一出路是 `BOT_ALLOW_STALE=1`，一道天天狼来了的门教会大家的正是怎么绕过它（2026-10-06 实测踩到三回：先是 `test/cpp/`，修掉后 `CMakeLists.txt` 挡掉了 `run_san.sh` 的整个第二跑，再修又暴露出 `harness_selftest.cpp` 同类）；反过来漏掉 `harness_selftest`（同日之前的状态）则让骨架自证拿旧二进制报「8 通过」，正是这道判据要堵的无痕假绿。排除名单与 CMakeLists 的目标归属是同一份事实，故 `run_all_selftest.sh` 第 7 段双向钉住：归属变了（比如新增一个独立目标）要红，名单单独漂（多一条 = 漏判真陈旧、少一条 = 门恒红）也要红——次数一并钉，因为同一条排除在两个分支里各写一次是有讲究的（`src/main.cpp` 对 `mybot` 恰恰是入口源，排了就漏判）。test_*_consts 未纳入（它们的 bin 变量在 `run_all.sh` 更后面才定义）。Rust 侧的同族判据是 `test/lib/agent_stale.sh`，取材面与处置分层见 [development.md](development.md)「守门钩子（pre-push）」第 3 条。

反过来，有三个脚本**没有任何自动调用点**（`run_all.sh` / 十条 CI job / pre-push 都不执行它们），它们坏了不会有任何守门变红，只能靠人跑：

- `scripts/build_sim.sh` —— `sim/` 是独立 CMake 工程，不在任何 CI job 的构建范围内；它产出的 `sim_tests`（442 例）也因此只在开发者手动跑时执行（计数见下「四处套件的计数口径」）
- `scripts/sim_agent_demo.sh` —— sim + backend + agent 三层链路的**手动冒烟**：要显示器（GLFW/OpenGL）、要真模型凭据 `mybot.llm.json`、要先 `build_sim.sh`。这意味着 **GL 可视化壳没有自动覆盖**，改完请自己跑一次并把结果写进提交信息（详见 [sim.md](sim.md)「端到端链路」）
- `scripts/build_agent.sh` —— CI 的 `gate:agent` / `gate:agent-e2e` 各自 `cargo build`，本机则靠它产出 `mybot-agent`；产物陈旧/缺失的后果见 [development.md](development.md)「守门钩子（pre-push）」第 3 条

四条反假绿约束（2026-09-20 审计 C8–C10 补齐三条，2026-09-21 AG-5 补第四条）：

- **过滤器拼错必须失败**：任何分段都受 `$filter` 守卫；全部未命中时末尾的空匹配防线以退出码 1 拒绝（C8：controller/trigger 观察面此前缺守卫，`run_all.sh zzz_typo` 会以「3 通过, 0 失败」退出 0）。这条约束**成立的前提是「每个分段都受管辖」**，而它已经悄悄失效过一次：2026-09-21 AG-5 加的 `harness-selftest` 段无条件跑完记 1 通过，于是 `zzz_typo` 又以「1 通过, 0 失败」退出 0，直到 2026-10-06 才被发现。段门补回后，`run_all_selftest.sh` 第 7 段用**实跑**钉住它——拿一个不可能命中的过滤器执行一次 `run_all.sh`，退出码非 0 才算过；将来任何分段再变成无条件 `record_pass`，这条实跑钉照样抓得到（同段那条 grep 钉只能抓 `harness-selftest` 这一处）。产物陈旧时 `run_all.sh` 以 2 退出，实跑钉仍成立但那一轮没真正走到防线那行，故两条互补、都不可省
- **零用例的 C++ 二进制判失败**：无过滤器时若 `mybot_tests` 报「无匹配用例」（未注册任何用例/桩二进制/产物被换），cpp-unit 段判失败而非静默 SKIP；带过滤器时才是合法跳过（C9）
- **`mybot_tests` 退出码为 0/1**，不是失败用例数——退出状态只有 8 位，256 个失败会回绕成 0，使 `ctest -R cpp_unit` 报 100% passed（C10）。`run_all.sh` 另有 `[FAIL]` grep 兜底，两条入口口径一致
- **零断言即失败（AG-5）**：`harness.hpp` 记录每用例执行的断言数，**一条都没跑就结束**的用例判失败，而不是记 `[PASS]`。旧行为下「环境不满足就 `return`」的守卫整条静默通过——它什么都没验证却占了通过位，是最难发现的一类假绿。环境确实不满足时请显式表态：

  ```cpp
  if (ec) { TH_SKIP("该文件系统不支持创建符号链接，无法验证 O_NOFOLLOW 策略"); }
  ```

  `TH_SKIP` 记 `[SKIP]` 并计入跳过数（必须带原因）；**断言之后**再 `TH_SKIP` 属于语义矛盾，判失败。这条判据本身由 `harness_selftest` 自证（见下），不是靠人记得。

汇总行如实体报 `N 通过, N 失败, N 跳过` 并列出未执行清单。

- 只想跑 Lua 段：`ALLOW_SKIP=1 bash test/run_all.sh`
- 显式指定的 `BOT=` / `BOT_TESTS=` 指向不存在的文件时一律判失败，`ALLOW_SKIP` 也不放行

## 跨源一致性校验（零编译）

同一条事实在仓里手写两份以上的地方，各配一道**不依赖任何构建产物**的校验，全部由
`test/run_all_selftest.sh` 执行——CI 的 `gate:release` 把它排在 `run_all.sh` **之前**，
pre-push 钩子也调它。为什么必须零编译：`sim/` 是独立 CMake 工程、**不在任何 CI job 的
构建范围内**（理由见 `sim/CMakeLists.txt` 顶部注释），所以 `sim/tests` 里的同款校验
（`testActionTable` / `testSharedConstants`）只有开发者手动 `bash scripts/build_sim.sh`
时才会触发；主干这几道是**独立实现**、不共享代码——共享实现等于共享同一个错误，两侧
一起改错就一起绿。

> 这条「不共享代码」说的是**跨语言对**：Python 守门与 `sim/tests/` 的 C++ 同款校验各自
> 独立实现，好交叉印证「脚本本身没写错」。Python 守门**之间**的机械部分（去注释、平衡
> 括号块、按仓内相对路径读数）与协议出处路径清单收敛在 `scripts/lib/protocol_sources.py`
> 一处共用，各脚本各留两行 `read` 包装以沿用「脚本名: 找不到 <路径>」的文案；各脚本的
> **判据与比对逻辑**仍留在各自文件里、不下沉——底座改动只可能影响「怎么读源码」，不会
> 让两侧一起改错。此次接入是纯重构，四个检查器的输出与接入前逐字节一致。

`run_all_selftest.sh` 现有 14 段：1–7 是守门自身的可信度（脚本语法、`test/cpp/*.cpp`
是否登记进 `CMakeLists.txt`、`test/*.lua` 是否匹配两侧 glob、`count_calls` 的「N 条用例」
文案是否真数得到调用点、两张用例表的结构与两套计数互证（条数**派生**、不再手写）、
TSan 名单单点（**双向**核对：名单里每条都在用例文件里命中，且用例文件里每条 `TH_TEST`
都被名单覆盖——「零匹配返回 1」只堵住名单写错名字，堵不住名单少一条）、
四个守门单点——`test/lib/params.sh` 的守门常量、`test/lib/agent_stale.sh` 的
mybot-agent 新鲜度取材面、`run_all.sh` 里 `harness_selftest` 的路径派生与产物陈旧
判据的循环覆盖、以及该判据**排除名单**与 `CMakeLists.txt` 目标归属的双向核对，
外加**实跑**一次拼错过滤器核对空匹配防线（C8）真的会红——那是本自检
唯一执行 `run_all.sh` 的地方，0.1s 级，理由见上「四条反假绿约束」第一条），
8–14 是跨源比对：

8. **仿真器跨构建契约**（`scripts/check_sim_contract.py`）四组：`.mt` 数字动作码表
   （`sim/src/action_table.cpp` 的 `kActions[]` vs `modules/Sim.lua` 的
   `CODES`/`PARAM_CODES`/`PARAM2_CODES`/`CODE_MAX`）、五条缺省 socket 路径（`sim_config.h`
   vs `modules/Sim.lua`）、一问一答桥的请求关键字（`sim/src/{sensor,capture,imu,odom}.cpp` vs
   `modules/Sim.lua` 的 `range()`/`imu()`/`odom()`、`src/agentimage.cpp`、
   `modules/Camera.lua` 的 `capture_live()`）、默认场景的 11 个箱（`world.cpp` 的内置回落 vs
   `sim/scenes/default.scene`）。缺 `python3` 时**判失败**而非跳过——这段没有别的兜底。
9. **状态目录缺省名**：「`MYBOT_HOME` 非空 → `$HOME/.mybot` → 不可用」有三处实现
   （Rust `agent/src/config/mod.rs`、C++ `sim/src/sim_paths.cpp`、shell
   `scripts/sim_agent_demo.sh`），跨两套构建系统、刻意不做代码生成。逐处钉两件事：读
   `MYBOT_HOME` 的形态还在，且拼出的缺省后缀仍是 `/.mybot`。规则单点是
   [reference.md](reference.md) 的 `MYBOT_HOME` 行。
10. **文档与仓库实况**（`scripts/check_doc_paths.py`）七组：README 与 `docs/*.md` 里的
    仓内路径引用逐个实测存在（markdown 链接按文档目录解析、反引号跨度按仓库根解析；
    历史记录与教程占位名在脚本的 `KNOWN_ABSENT` 里逐条登记理由，登记过又存在的条目
    同样判失败）；`docs/drivers.md` 各节点名的模块集合与 `ls modules/*.lua` **双向**
    相等；drivers.md 开头「计数口径」那行的分项（48+3+8=59、lib 28）与各节实际条目数、
    与磁盘文件数三者自洽；每篇 `docs/*.md` 都被 README 或 `docs/README.md` 链到；
    `DELETED_FILES` 里登记的**已删且刻意不重建**的文件名，在全仓任何文本文件里再出现
    即判失败（取材面比第一组宽得多：源码注释、脚本、CI、冻结 html 都扫，按带扩展名的
    字面量匹配；名单里的文件若又存在了同样判失败）；本页「四处套件的计数口径」那张表
    与表下两条式子里的每个数字都**从仓库实况派生后比对**（口径见该节）；第七组把同一套
    判据扩到 **README**（「项目结构」与「测试规模」两节里 14 处计数逐个派生比对）。
    第五组是一次真实漏网的产物：2026-10-04 删掉冻结变更账本后，仓内还留着 11 处指向它的
    引用，第一组一处都看不见——8 处不在它的取材面，3 处虽在 `docs/*.md` 里但是裸词而非
    链接或路径跨度；明细与「为什么不把第一组扩到 html」记在脚本头注。第六组的存在理由
    是同一类：那张表原本只是「某天的快照」，没人回头看，加一条用例它就悄悄过期，而读者
    拿它当基线核对守门输出。**第七组是一次真实漂移的产物**（2026-10-08 审计 P2）：README
    的数字自称「快照，改完用这几条命令复核，别手改数字」，纯人工无门，结果八处一起烂
    （87/38 实为 88/42、650 实为 689、148 实为 153、23 个共享库实为 28、14 篇文档实为
    13、工具表 9 行实为 12）——而 README 是新人第一入口，误导面比深入文档更大。
    第七组另有**一条反向判据**：`run_all.sh` 汇总行的守门用例数与 `sim_tests` 的断言数
    是「跑一遍才知道」的运行时数，静态派生不出来，故 README 里**不许写死**它们，命中
    裸数字即判红并提示改成指针（与第六组对 `sim_tests` 406 只钉「N 个 TU」+ 要求标
    「运行时数」是同一取舍，README 这侧更严：直接不写）。三组的锚点若被改得找不到，
    脚本 **exit 而非跳过**——静默少比一个数比报错危险。
11. **模型配置字段白名单双端同集合**（`scripts/check_llm_field_whitelist.py`）：C++
    `src/llmconfig.cpp` 的 `kKnown` vs Rust `agent/src/config/file.rs` 的
    `PARSED_FIELD_NAMES`（`parsed_fields!` 宏表展开）+ `KNOWN_UNPARSED_FIELDS`。两端读
    **同一份** `mybot.llm.json`，任一侧漏登记一个字段，那一侧就把操作者的合法配置判成
    「未知字段」拒读；两侧单测各验自己那份，谁也发现不了对侧漏改。脚本另钉三条：两份
    Rust 名单互不重叠、各名单内部无重复、抽取自检（块里任何形状的字符串字面量数 ==
    抽到的名字数，防「两侧都读空 → 相等」的假绿）。
12. **有状态 LLM 协议判据双端同集合**（`scripts/check_stateful_protocol.py`）：Rust
    `agent/src/session.rs` 的 `protocol_violation`（`--resume` 恢复会话前最后一道判据）
    vs Python `scripts/fake_llm_server.py` 的 `protocol_error`（让假模型服务与真网关
    一样严）。两份各有一套单测——Rust 的 `protocol_violation_flags_orphans_duplicates_and_missing`、
    `agent_e2e.sh` 末尾对真实请求的变异——但没有一道守门比对**判据集本身**：夹具少一条
    判据时，产线会拒的历史在离线守门里照常全绿。脚本钉四件事：产线判据点条数 == 登记
    规则数（加/删判据必须同步用例表，反向验证过：临时加一条 `return Some(format!(...))`
    即失败）、每条规则的判据锚点仍在、用例表逐条喂给 `protocol_error`（`runpy` 加载，
    不起服务）且拒因必须含该规则的特征片段、产线每条规则都至少有一条用例。**C++ 侧不
    参与**（宿主不解析模型历史，判据由 agent 一侧守）；两条夹具独有规则（DeepSeek 的
    `reasoning_content`、`tool_call_id` 类型）在表里逐条登记理由，差异是记录在案的。
13. **LLM wire 契约里本仓手写的那部分**（`scripts/check_llm_wire.py`）：模型调用自
    2026-09-25 起是 **Rust 直连**（C++ 宿主与 Lua 沙箱都不参与网络，`modules/Llm*.lua`
    已不存在），故只钉 **Rust provider ↔ Python 夹具 ↔ E2E 脚本**这条链。报文字段本身
    大多**不在本仓**——请求体（`top_p`/`reasoning_effort`/`temperature`/`max_tokens`/
    `stream`）、SSE 帧名（`chat.completion.chunk`/`[DONE]`/`message_start`/`content_block_*`/
    `message_delta`/`message_stop`）、响应字段（`choices`/`tool_calls`/`usage.prompt_tokens`…）、
    鉴权头名（`Authorization`/`x-api-key`/`anthropic-version`）都由 vendored 的 **rig**
    crate 拥有，`agent/src` 里搜不到这些字面量，对它们做「从本仓源码文本互钉」在本仓
    不可能；唯一本仓手写的响应字段是 `reasoning_content`（已由第 12 段钉住）。于是脚本
    只钉本仓确实手写了两份以上的两件事：**协议族 → 请求路径**（`agent/src/provider.rs`
    的 `Driver::request_path()` 必须能解释夹具两条 `self.path != "..."` 断言，且各 E2E
    脚本的 `--llm-endpoint` 路径都以某条 `request_path` 结尾）、**协议族表名**
    （`Driver::from_table` 与 `Driver::as_str` 同集合，且脚本里每个 `--llm-driver` 都是
    已知表名——写错族名如 `LlmDeepseek` 在 Rust 侧要等第一次调用才报错）；另有成对断言：
    同一命令里 `--llm-driver X --llm-endpoint Y` 并存时，Y 的路径必须以 X 的
    `request_path` 结尾（族名与路径不许错配）。反向验证过三条：改坏 provider 表名 /
    改坏夹具 path 断言 / 制造族名-路径错配，均 `exit 1`。**C++/Lua 不参与**（不再实现
    LLM 网络）、**rig 独占字段**（请求体/SSE 帧名/响应字段/鉴权头名）在脚本头逐条登记为
    如实差异。
14. **后端工具注册表 ↔ 两张文档工具表同集合**（`scripts/check_agent_tool_table.py`）：
    代码侧四个 TU（`src/agenttools.cpp`/`src/agenttools_wait.cpp`/`src/agenttools_fs.cpp`/
    `src/agentimage.cpp`）里
    每个 `return AgentTool{"<name>", ...}` 的工具名，必须与 [agent.md](agent.md)
    「给智能体的工具」一节表格第一列、**以及 `README.md`「Agent 工具系统」一节**的表格
    第一列，各自**双向**同集合。工具表是手工
    维护的（无自动生成，与 docs/sim.md「跨构建系统不做代码生成」同一取舍），此前只有
    ICA 本地工具那一半有自钉（`agent/src/ica/specs.rs` 的 `all.len() == 8`），后端工具
    这一半一直是空的——加/删/改名一个工具只要忘了同步文档表，只能靠评审发现。比对的是
    「代码里一共定义了哪些工具」而非「某次运行实际门控放行了哪些」（与表格第三列各写
    门控条件的既有体例一致）。
    **为什么两张表都要比**（2026-10-08 审计 P2）：本段最初只钉 agent.md，于是 README 的
    工具表可以静默少三行（`list_dir`/`read_file`/`write_file`）而全线绿灯——README 是新人
    第一入口，少三个工具的误导面比深入文档更大。两张表用同一个抽取式与小节锚点，
    加第三张表只要在 `DOC_SOURCES` 里添一行。

### 四处套件的计数口径

| 套件 | 怎么跑 | 计数（2026-10-13 快照） |
| --- | --- | --- |
| `mybot_tests` | `bash test/run_all.sh` 的 cpp-unit 段 | 808 通过 / 0 失败 |
| `harness_selftest` | `bash test/run_all.sh` 的 harness-selftest 段 | 8 通过 / 0 失败 |
| `sim_tests` | `bash scripts/build_sim.sh` 后 `./sim/build/sim_tests`（**不在 CI**） | 442 通过（**运行时数**）/ 0 失败（8 个 TU） |
| Rust agent | `cd agent && cargo test --release` | 188 passed |

除 `sim_tests` 的 442 外，表里每个数字都由 `scripts/check_doc_paths.py` 的第六组
**从仓库实况派生后比对**（进 `test/run_all_selftest.sh`）——加/删用例而忘了改这张表，
守门会红，不再依赖人记得回来更新快照。派生口径就是下面两条式子。

两个容易对不上的数字，出处写在这里省得每次重推：

- `mybot_tests` 的 808 **不等于** `test/cpp/` 里 `TH_TEST(` 的出现次数（822）。差值有
  出处：822 − 1 处宏定义（`test/cpp/harness.hpp`）− 13 个属于 `harness_selftest`
  （独立可执行文件）= 808。拿这个式子复核，别把两个数字硬对齐。
- `harness_selftest` 那个文件里有 13 个 `TH_TEST`，二进制只报 8 通过：另外 5 个 `meta_*`
  是**故意含失败形态的例句**，只作被测对象（由自证用例内部的 `judge(filter)` →
  `runAllOutcome(filter, quiet=true)` 调到），不进缺省全量跑——否则主输出里会混进一串
  预期失败的 `[FAIL]` 行。

`sim_tests` 的 442 是这张表里**唯一没有静态派生**的数：sim 侧的记账单位是**断言**而不是
用例（`sim/tests/harness.h` 的 `g_total` 只由 `check()` 写），而 `check(` 的调用点只有
328 处——差额来自循环与条件分支里的多次断言，跑一遍才知道确切数。加上 `sim/` 不在任何
CI job 的构建范围（见上「没有任何自动调用点」），这个数只能靠人手动跑
`./sim/build/sim_tests` 后回填。同一行里的「8 个 TU」**是**派生的
（`sim/CMakeLists.txt` 的 `add_executable(sim_tests …)` 源文件清单）。

## sanitizer 与单测二进制

构建开关随仓库分发（`CMakeLists.txt` 的 `MYBOT_SANITIZE`，F-23），避免各人手工拼
`CXX_FLAGS` 造成两套构建不一致：

```bash
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DMYBOT_SANITIZE=address,undefined && cmake --build build-asan
bash test/run_san.sh              # 双跑：Release 全量 + ASan/UBSan 全量，两跑都过才算过
bash test/run_san.sh --asan-only  # 只跑 sanitizer 跑（CI 的 gate:sanitizer 用法：
                                  # Release 全量交给 gate:release，不重复跑一遍）
```

（2026-09-25 #8 前 `run_san.sh` 会导出 `LSAN_OPTIONS=suppressions=<仓库根>/asan.supp`：
agent 模式加载 Lua 协议驱动时经 ffi 拉起 libcurl → libcrypto，后者留下一批进程级
`CRYPTO_malloc` 初始化残留。该驱动轨道与 `asan.supp` 已一并删除——现役 Rust agent
用 rustls、不碰 OpenSSL，Lua 侧仅 `asound.lua`（ALSA）一条 ffi 依赖，无 libcrypto 路径。）

线程竞争用同一开关换 TSan：`-DMYBOT_SANITIZE=thread -B build-tsan`。注意 LuaJIT 是
未插桩外部库，FFI 侧的槽访问不在 TSan 视野内——TSan 覆盖的是 C++ 侧并发路径
（守护槽指针、信号标志、生命周期分支）。本机实测（树莓派 5 / 内核 6.18 aarch64）：
TSan 运行时以 `FATAL: ThreadSanitizer: unsupported VMA range (Found 47 - Supported
39, 42 and 48)` 退出——进程 VMA 布局不在 TSan 支持范围，属**环境限制**（`setarch -R`
无效；需 root 调低 `vm.mmap_rnd_bits` 后重试），换内核/宿主再跑。x86_64 开发机
（g++ 15.3，2026-09-25）无此限制：`test/lib/tsan_cases.txt` 三用例连跑 5 轮零报告，
`gate:tsan` 据此转硬；CI 上若恰以该 FATAL 变红，是 runner 内核问题而非竞态。

单独跑 sanitizer 段（例如只看 virt E2E）：

```bash
BOT=./build-asan/mybot BOT_TESTS=./build-asan/mybot_tests bash test/run_all.sh _virt
```

单独跑 C++ 单测（可用用例名过滤）：

```bash
./build/mybot_tests [用例名过滤]
```

## 第四轮重构守门增强（2026-10-06/10-07）

第四轮重构（Phase 23–29）在守门侧补了一批机械防线，防止「用例静默消失 / 数字悄悄漂移」：

### pre-push 的 mybot-agent 新鲜度硬门

pre-push 钩子在守门**之前**新增第 3 道关：`agent/target/release/mybot-agent` 缺失、或早于
`agent/src`/`agent/Cargo.toml`/`agent/Cargo.lock` 里的任一文件 ⇒ 中止推送并打印重建命令
`bash scripts/build_agent.sh --release`。

**为什么判红而不是 SKIP**：守门入口（`run_all.sh`）对同一状况判 SKIP（mybot-agent 是可选产物、
本机可能没装 cargo），而 SKIP 计入汇总后 rc 仍是 0：`agent-rust-e2e` 与 `ica-e2e` 两段整段
消失，汇总与真绿无法区分。CI 也补不上（`gate:release`/`gate:musl` 镜像里没有 cargo）。分层口径：
**本机装了 cargo 就能自己修，故判红**；没装 cargo 时不拦，只提示交 `gate:agent-e2e` 兜底。
逃生口 `BOT_ALLOW_STALE=1` 与守门入口共用同一语义（明确知道要跑旧产物时显式声明）。

取材面按产物分配，判据单点 `test/lib/agent_stale.sh`（与 `run_all.sh` 的 `agent-rust-e2e` 段
共用）：`mybot-agent` 吃 `agent/src` + `agent/Cargo.toml` + `agent/Cargo.lock`。与守门入口的
陈旧判据**同实现**——两处都调 `agent_stale_file` 函数，返回第一个比产物新的源文件路径（空串
表示产物新鲜）。

### CI 的 `gate:agent-e2e` 直接跑 `ica_e2e.sh`

2026-10-04 起 `ica_e2e.sh` 接进 `run_all.sh` 的 `ica-e2e` 段（此前只有 `ica.md` 提到、无任何
守门调用它，改坏了不会有人知道）。2026-10-06 起 CI 的 `gate:agent-e2e` 也直接跑它：本段在产物
缺失/陈旧时按 **SKIP** 计而汇总仍是 rc=0，`gate:release`/`gate:musl` 的镜像里又没有 cargo，
那条洞只有 CI 这道唯一带 Rust 工具链的 job 能补。

### `parse_cases` 的双引号约定

`test/run_all.sh` 的 `parse_cases` 函数（无硬件契约回归段）读入的用例表里，文件名一律用**双引号**
包裹（`"robots/test/xxx.sql" "scripts/test/xxx.mt"`），不用单引号也不裸写。理由：守门自检
（`run_all_selftest.sh` 第 4 段）按双引号正则抽取文件名后与磁盘实测比对，单引号或裸写会绕过抽取
而悄悄漏检。新增用例时照抄既有格式即可。

### 已删文件黑名单（`DELETED_FILES`）

`scripts/check_doc_paths.py` 的检查 5 维护一张「已删除且**刻意不重建**的文件」名单（当前只有
一份冻结的变更账本）：任何取材面里再出现指向它的引用即判失败。取材面比检查 1 宽（源码注释 /
脚本 / CI / 冻结 html 都算），因为死引用的成因恰恰是「引用它的地方不在任何守门的取材面里」。
匹配用**基名**：带扩展名的路径与 markdown 链接里的相对形态一并覆盖。

2026-10-04 冻结变更账本（提交 9480de3）后，仓内残留 11 处死引用已全部改成
提交号或中性说法。已知残留（刻意不追）：无扩展名的裸词不匹配；`docs/architecture_analysis.html:386`
一处裸词是 2026-09-25 冻结快照正文，改它等于篡改快照。

### TSan 名单的反向验证

`test/lib/tsan_cases.txt` 列出 `gate:tsan` 跑的三条守护并发用例。`run_all_selftest.sh` 第 5 段
**双向**核对：① 名单里的每个文件必须存在于 `test/cpp/` 且登记进 `CMakeLists.txt` 的 `mybot_tests`
源清单；② `CMakeLists.txt` 里带 `tsan` 标签的用例（`TH_TEST` 名字含 `tsan`）必须全部出现在名单里
——漏登记或名单过期都判红。防止「加了一条 TSan 用例但忘了接进名单」或「名单里留着已删用例」两种
静默漂移。

### 套件计数的派生公式

`docs/testing.md` 的「四处套件的计数口径」表里，除 `sim_tests` 的 406（运行时数）外，每个数字都由
`scripts/check_doc_paths.py` 的第六组从仓库实况派生后比对：

- `mybot_tests` = `test/cpp/` 里 `TH_TEST(` 出现次数 − 1 处宏定义（`test/cpp/harness.hpp`）−
  `harness_selftest` 的 `TH_TEST` 数
- `harness_selftest` = 该文件的 `TH_TEST` 数 − `meta_*` 例句数（故意含失败形态，不进缺省全量跑）
- `sim_tests` 的 TU 数 = `sim/CMakeLists.txt` 的 `add_executable(sim_tests …)` 源文件清单里
  `.cpp` 文件的个数
- Rust agent = `agent/src/` 下 `#[test]` + `#[tokio::test]` 的出现次数

加/删用例而忘了改这张表，守门会红，不再依赖人记得回来更新快照。

## 新增回归

`robots/test/<用例>.sql` + `scripts/test/<用例>.mt`，按守门契约接入 `test/run_all.sh` 的 e2e 列表或无硬件契约列表（含负值契约）。流程详见 [development.md](development.md)。

**漏登记会被抓**：`fixture-orphans` 段（F3/N-32）对「夹具文件存在但没人引用」判失败——新增夹具必须接进用例表；若是实机夹具（离线跑不了），把它加进该段的 `orphan_whitelist` 显式声明。

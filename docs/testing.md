# 回归测试手册

> 本文是 `test/run_all.sh` 全量回归编排脚本的说明。[README](../README.md) 中只保留命令入口。
> 完整门禁还覆盖 `test/run_all_selftest.sh`、构建配置和 CI job。
>
> **2026-11 状态**：本分支是 controller-only 版本，已移除 agent/MCP、Web SSH、sim 与 TCP 动作源。本文中带这些名字的分段、脚本与计数属于历史内容；当前可执行入口以 `./build/mybot_tests`、Lua 单测和按名过滤的 `test/run_all.sh <filter>` 为准。
> CI（`.gitlab-ci.yml`，F-22）在每次推送后自动跑 Release 全量守门 + ASan/UBSan 单跑
> （`run_san.sh --asan-only`：Release 全量已由 `gate:release` 跑过，不重复），
> 构建步带 `-DMYBOT_WERROR=ON`（README 声称的「零告警」由此成为门禁而非约定）；
> 与本地 pre-push 钩子同一条守门。
>
> 八条 job 全部为硬门禁（2026-09-25 起；此前 6 条为 `allow_failure` 软门禁），逐条与 `.gitlab-ci.yml` 一一对应：

| job | 类型 | 内容 |
| --- | ---- | ---- |
| `build:release` | 硬 | `-DMYBOT_WERROR=ON` 构建（零告警即门禁） |
| `gate:release` | 硬 | `bash test/run_all_selftest.sh`（守门自检 7 段：脚本语法、用例是否真被收集/编译、计数与过滤器防线）→ `bash test/run_all.sh`（Release 全量守门） |
| `gate:sanitizer` | 硬 | ASan/UBSan 构建 + `bash test/run_san.sh --asan-only`；UBSan 以 `-fno-sanitize-recover=undefined` 编译（**检出即终止**，见下） |
| `gate:tsan` | 硬 | TSan 构建 + 三条守护并发 C++ 用例，`halt_on_error=1`（TSan 报告即影响退出码） |
| `gate:clang` | 硬 | clang 构建 + C++ 单测烟雾 |
| `gate:clang-tidy` | 硬 | `src/` 静态分析；退出码取 clang-tidy 自身，`clang-tidy.log` 随 artifacts（`when: always`）留档 |
| `gate:coverage` | 硬 | `bash test/run_coverage.sh`（`--coverage` 构建 + 跑 `mybot_tests`；`COV_WITH_GATE=1` 时另跑一遍全套守门），报告随 artifacts 留档。「硬」判的是采集链路本身，**不设行覆盖阈值**（理由见下节） |
| `gate:musl` | 硬 | alpine 3.20/musl 下：两个常量自检 → `mybot_tests` → 整段 `test/run_all.sh`（`BOT`/`BOT_TESTS` 指到 `build-musl/`） |

### 覆盖率数字的口径与已知盲区（2026-09-21 AG-11 实测）

**先看口径再看数字**，否则极易误判：

- **它只反映该脚本实际跑过的东西**。缺省模式只跑 `mybot_tests`（C++ 单测），`mybot` 二进制的
  e2e/Lua 链路不计入；要计入请设 `COV_WITH_GATE=1`。实测差距为零不是因为 e2e 没价值，
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
bash test/run_all.sh hardening # 只跑输入边界/加固段
```

全部守门在无 `/dev/i2c` 的开发机上即可运行；缺设备用例按 `[SKIP]` 计。

> **按名字过滤时注意分段形态不同**：Lua 段比 `test_*.lua` 文件名子串，
> C++ 段交给 `harness` 按作用域语法匹配，加固段按分段门执行。controller-only
> 起不再有 TCP 动作源/MCP/agent 的端到端过滤入口。

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
之前 ctest 侧按**文件名**特判 `test_jit_warmup.lua`，同类真机用例被裸注册，
无设备机器上报 Failed 而非 Skipped；现在两条入口共用同一个标记解析）。外加
`cpp_unit` / `const_ioctl` / `const_uart`。
只跑 ctest
**不覆盖** `run_all.sh` 的端到端与守门完整性分段——提交前仍以
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
> 第 6–8 项（TCP 动作源/异常注入、agent 端到端）属于已移除能力的历史说明，当前
> controller-only 脚本不再执行它们。

1. **Lua 离线单测**（`test/test_*.lua`，LuaJIT 运行；断言统一经 `test/lib/tester.lua` 出 `[PASS]`/`[FAIL]` 与 `[DONE]` 完成标记；真机用例经 `test/lib/device_gate.sh` 按 `-- requires:` 标记自动跳过）
   - 其中 `test_driver_contract.lua` 是**驱动入口契约 sweep**（2026-09-20 阶段 4.5）：逐个真的加载全部 `modules/*.lua`，断言 ① 可加载（模块路径引导写错即刻红，不必等 E2E）、② `build`/`call`/`destroy` 三入口齐全、③ 非表入参返回 ERR 契约表而非抛 Lua error。豁免只有 `bitcompat`（纯 Lua 库）
2. **lint 段**（2026-09-20 阶段 2 收尾防线）：`grep` 断言驱动入口一律走 `arg_table`，且模块路径引导一律走 `__mpath`（见 [reference.md](reference.md) 的 `BOT4CJ_MODULE_PATH`）——都是「约定靠不住、用一行 grep 钉住」的便宜防线
3. **virt 端到端**（`robots/test/*_virt.sql` 走内存仿真总线 `virtbus`，断言 `:f` 浮点透传与守护持续发布——条数见 `e2e_cases`，明细见 [virtbus.md](virtbus.md)「守护无硬件端到端」一节）
4. **无硬件契约回归**（守护/别名/转发/引用路径）：
   - 负值契约：INSERT 拼错表、别名重复、`$` 引用标量、动作参数覆盖结构元数据必须**清晰报错**而非裸崩
   - 含 `PCA9685`/`MCP4725`/`SCSCL` 的**非守护** `@Action` 写路径正/负六条——虚拟总线已不再只服务守护路径，UART 直写路径经 `BUS="uart"` 模型附着 + 跨状态机 fd 采纳
5. **@Merge 展开**（运行端动作脚本归并，归并内核由 test_mtmerge.cpp 白盒单测覆盖；旧名 @Include，2026-10-12 改名，@Include 现为 C 式内容拷贝）
6. **@Merge 相位语义**（`@Action` 两两归并时相位 0/±1 对齐、负相位丢行告警、前导 `-` 的设备在运行端被跳过）
7. **输入边界加固**，覆盖：
   - 未知 `--key` 退出码 2、动作脚本/结构脚本超 8 MiB 上限
   - `@Daemon` 驱动误配无 `build` 时的回滚路径
   - `mode` 键不得改写 controller 派发目标；驱动 `call()` 漏写 `return` 不得被当成成功；驱动返回自引用表须清晰报错而非宿主栈溢出
8. **守护 tick 故障注入**（总线持续 NACK → 驱动 ERR → 守护不发布、`count` 停滞，主流程仍正常 join）
9. **进程级 fd 探针**（长动作 + 守护采样期间轮询 `/proc/<pid>/fd`，稳态 fd 数须有界平稳）
10. **信号/退出路径**（F-08：播放中 SIGTERM → rc=0 + 停派发行 + 守护 `joined, total publishes=`——覆盖 `main.cpp` 的 sigaction 与 `robot.cpp` 的停机分支）
11. **fixture 孤儿检测**（F3/N-32，无过滤器全量跑时执行）：`robots/test/*.sql` 与 `scripts/test/*.mt` 中未被任何用例表引用的夹具判失败；判据是**整字段精确匹配**（`e2e_cases` 的用例名、`parse_cases` 的两列文件名、`scripts/*.sh`、`CMakeLists.txt`），不是子串——2026-09-20 审计 C11 修正：子串判据下每个真机夹具 `bme280.mt` 都是已登记仿真用例 `bme280_virt` 的子串，26 对真机夹具（52 个文件）因此被误判成「已登记」而从不执行、检测器却报「无孤儿」。实机夹具（需 `/dev/i2c-*`、`/dev/spidev*`、`/dev/gpiochip*`、`/dev/pwmchip*`、`/dev/serial*`）在脚本的 `orphan_whitelist` 显式声明
12. **系统常量自检**（F-24 + A2，无过滤器全量跑时执行）：两个 C 自检二进制把 **Lua 源里**硬编码的编号与系统头做编译期断言比对，漂移在构建期即失败，执行期再跑一遍作双保险。事实源是 Lua，**不是 C 里的手抄副本**：配置期 `test/gen_const_check.cmake` 从 `modules/lib/hal_backend_glibc.lua`（consts 表，方案 A 下沉后的唯一事实源）、`modules/lib/hal/uart.lua`（两套波特率映射表）提取常量生成 `const_lua.h`，每项做**双边断言**——`Lua 抽取值 == 手抄预期值`（抽取生效 + Lua 未漂移）且 `预期值 == 系统头`（内核/架构未漂移）。抽不到任何必需常量即 `FATAL_ERROR`（静默生成空头会让断言退化成自证）。`test_ioctl_nums`（SPI/GPIO/I2C ioctl + 结构尺寸）、`test_uart_consts`（termios 布局 + 两套波特率表 + 打开标志）均无外部依赖。
13. **C++ 层单测**（`test/cpp/`，`mybot_tests` 目标，零第三方框架），覆盖：
    - 基础设施：JSON 值语义、JSON 文本解析、Lua↔Json 边界与转换深度上限、util 全局助手（安全标识符判据 `isSafeIdent`、深度护栏 `DepthLimitGuard`、CLI 切分 `cli::parseKeyValue`、越界文案模板 `rangeErrorText`）
    - 解析管线：`.mt` 矩阵状态机（含块嵌套 children 树、叶子不可嵌套、深度上限、EOF 未闭合响亮报错）、SQL 词法/语法、元数据收集与 `$` 引用环检测、@Merge 归并核心白盒、@Include 内容拷贝与子块内位置局部归并白盒
    - 守护：never-spawn/abandon 分支
    - 会话变量作用域（2026-09-20 阶段 1）：动作脚本内联 `@Alias` 不跨 `run()` 残留、不遮蔽结构变量、报错脚本不改写注册表、200 轮重复执行后结构名字索引不增长
    - I/O 与错误语义（2026-09-20 阶段 4）：`retryEintr` 只在 EINTR 重试、整文件读取超限报「字节上限」而非「不是合法 JSON」、TCP 口令三态（空闲超时/对端关闭不算鉴权失败，只有凭据错才计数）、表达式语法错误截断回显
    - agent 后端：配置文件解析与后端字段合并、能力门控、工具派发与路径沙箱、任务预算与回执；模型装配、工具循环上限与回滚、历史裁剪、会话编解码与推理内容保留由 `agent/src/` 的 Rust 单测负责
    - UTF-8 边界（2026-09-21 AG-1）：`util` 的合法/非法判据与消毒（过长编码、代理区、> U+10FFFF、截断尾部、连续坏字节折叠）、`run_command` 输出与动作脚本首注释的消毒终点、API key 控制字符判据

    另有两条纯 Lua 用例：`test/test_json_lua.lua`（Lua 侧 JSON 编解码）、`test/test_utf8.lua`（UTF-8 判据与消毒。它与 C++ 侧 `utf8_*` 用例**同表向量**——两边判据必须一致，改动任一侧都要两边过）

14. **测试骨架自证**（`test/cpp/harness_selftest.cpp`，`harness_selftest` 目标，独立于 `mybot_tests`）：用一份**独立的 th 状态**把已知形态喂给骨架，断言它给出的判定符合预期——零断言必判失败、`TH_SKIP` 记跳过不算失败、断言后跳过判失败、正常通过/失败仍被认出、过滤器零命中返回 -1。独立二进制的理由：这些「例句」用例故意含失败形态，混进 `mybot_tests` 会让主守门出现永久失败项。它守的是**所有其它守门都依赖的那把尺子**——尺子失真时全部用例照样全绿，没有别的机制会发现。由 `run_all.sh` 的 `harness-selftest` 段执行

## 守门完整性

编译产物（`mybot` / `mybot_tests` / `harness_selftest`）缺失时，对应分段**判失败**而不是静默跳过——否则「不构建」也能报出「0 失败」，而实际只有 Lua 段在跑。唯一的环境软依赖是真机用例：

- 真机用例（本机无 `/dev/i2c-*` 等）：统一经 `test/lib/device_gate.sh` 读文件内 `-- requires: <dev>` 标记判定，`run_all.sh` 与 ctest 共用同一实现

产物**陈旧**在起跑前就拒绝（`run_all.sh` 比 mtime，旧于编译期输入即 `exit 2`；逃生口 `BOT_ALLOW_STALE=1`）。取材面**按产物分配**，且每条都要**减去属于别的目标的文件**：`mybot` 吃 `src/` 减 `src/main.cpp` 本身就是入口；`mybot_tests` 吃 `src/` + `test/cpp/` 减 `src/main.cpp`（它的入口是 `test/cpp/main.cpp`）、`test/cpp/harness_selftest.cpp`（独立骨架自证）；`harness_selftest` 只吃 `test/cpp/harness_selftest.cpp` 与 `harness.hpp`。归属的权威出处是构建系统自己的记账（`build/compile_commands.json` 里 `-o CMakeFiles/<target>.dir/<src>.o`）。`CMakeLists.txt` **不在任何一份取材面里**：它是构建描述而不是编译期输入，「描述变了要不要重链」由 cmake/make 自己算——把它当输入就等于要求「产物比构建描述新」，而 make 对输入未变的目标只回一句 `Built target` 不重链，于是门恒红。共用一份最大集合、或不减归属，都会犯同一个错，两种坏法：给 `mybot` 算上 `test/cpp/`，则「只改一条用例」会让它永远判陈旧，而 cmake 根本不会为此重链 `mybot`——**重建也修不好**，唯一出路是 `BOT_ALLOW_STALE=1`，一道天天狼来了的门教会大家的正是怎么绕过它（2026-10-06 实测踩到三回：先是 `test/cpp/`，修掉后 `CMakeLists.txt` 挡掉了 `run_san.sh` 的整个第二跑，再修又暴露出 `harness_selftest.cpp` 同类）；反过来漏掉 `harness_selftest`（同日之前的状态）则让骨架自证拿旧二进制报「8 通过」，正是这道判据要堵的无痕假绿。排除名单与 CMakeLists 的目标归属是同一份事实，故 `run_all_selftest.sh` 第 7 段双向钉住：归属变了（比如新增一个独立目标）要红，名单单独漂（多一条 = 漏判真陈旧、少一条 = 门恒红）也要红——次数一并钉，因为同一条排除在两个分支里各写一次是有讲究的（`src/main.cpp` 对 `mybot` 恰恰是入口源，排了就漏判）。test_*_consts 未纳入（它们的 bin 变量在 `run_all.sh` 更后面才定义）。

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

### `parse_cases` 的双引号约定

`test/run_all.sh` 的 `parse_cases` 函数（无硬件契约回归段）读入的用例表里，文件名一律用**双引号**
包裹（`"robots/test/xxx.sql" "scripts/test/xxx.mt"`），不用单引号也不裸写。理由：守门自检
（`run_all_selftest.sh` 第 4 段）按双引号正则抽取文件名后与磁盘实测比对，单引号或裸写会绕过抽取
而悄悄漏检。新增用例时照抄既有格式即可。

### TSan 名单的反向验证

`test/lib/tsan_cases.txt` 列出 `gate:tsan` 跑的三条守护并发用例。`run_all_selftest.sh` 第 5 段
**双向**核对：① 名单里的每个文件必须存在于 `test/cpp/` 且登记进 `CMakeLists.txt` 的 `mybot_tests`
源清单；② `CMakeLists.txt` 里带 `tsan` 标签的用例（`TH_TEST` 名字含 `tsan`）必须全部出现在名单里
——漏登记或名单过期都判红。防止「加了一条 TSan 用例但忘了接进名单」或「名单里留着已删用例」两种
静默漂移。


## 新增回归

`robots/test/<用例>.sql` + `scripts/test/<用例>.mt`，按守门契约接入 `test/run_all.sh` 的 e2e 列表或无硬件契约列表（含负值契约）。流程详见 [development.md](development.md)。

**漏登记会被抓**：`fixture-orphans` 段（F3/N-32）对「夹具文件存在但没人引用」判失败——新增夹具必须接进用例表；若是实机夹具（离线跑不了），把它加进该段的 `orphan_whitelist` 显式声明。

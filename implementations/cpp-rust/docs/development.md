# 开发与贡献

> 本文是贡献者指南。[README](../README.md) 中只保留入口链接。

## 起步

```bash
git clone <本仓库> && cd bot4cj
bash scripts/install-hooks.sh                 # 装 pre-push 守门钩子（一次性）
cmake -S . -B build && cmake --build build
bash test/run_all.sh                          # 离线回归（无硬件）
bash test/run_san.sh                          # 双跑：Release + sanitizer（改动并发/生命周期/内存相关时建议跑）
cat scripts/relay-test.mt | ./build/mybot --robot=robots/relay-test.sql   # 无硬件自检
```

调试单条用例时可用 ctest 逐用例入口（比整段守门快得多，但**不替代**提交前的
`run_all.sh`，见 [testing.md](testing.md#ctest-逐用例入口可选)）：

```bash
cd build && ctest --output-on-failure -R lua_test_pca9685
cd build && ctest --output-on-failure -R cpp_unit
```

## 目录约定

| 路径 | 放什么 | 注意 |
| ---- | ------ | ---- |
| `src/` | C++17 宿主（解析、注册、派发、守护、agent） | 全量 `-Wall -Wextra -Wpedantic` 零告警 |
| `modules/` | 驱动 `<矩阵名>.lua` 与库 `lib/` | 驱动契约见 [drivers.md](drivers.md) |
| `modules/lib/` | HAL、virtbus、mpath、JSON、滤波等共享库 | 纯算法库不依赖 HAL，可被 lua5.4 复用 |
| `robots/`、`scripts/` | 结构脚本与动作脚本；`test/` 子目录为回归夹具 | 夹具必须登记进用例表，否则被孤儿检测判失败 |
| `test/` | Lua 单测、`cpp/` C++ 单测、`run_all.sh` 总编排 | 编译产物缺失时对应分段判失败 |
| `docs/` | 深入文档，入口 [docs/README.md](README.md) | 改动后同步索引与链接 |

## 提交信息规范

主体提交信息质量很高（设计论证、被否决方案留档、守门数据），但历史混有过零信息提交
（`^-^`、`add "speed"`、`新的动作`），破坏提交历史可追溯性（见提交 e4aa7b1）。
据此约定**最小信息底线**（历史不回改，防新增）：

- 格式：`<type>(<scope>): <一句 why>`；scope 可省略（如 `docs: ...`）；一次提交落在
  多个域时可用 `+` 联合前缀（如 `feat(mcp)+fix(gate): ...`）
- `type` ∈ `feat` / `fix` / `docs` / `test` / `refactor` / `gate`
- subject 至少 10 字符，说清「改了什么、为什么」；正文可选，鼓励记录设计取舍与守门数据
- **变更账本即提交历史**：2026-10-04 起不再维护独立的变更账本文件（见提交 9480de3），
  每条变更的「改了什么、为什么、对使用者意味着什么」一律写在提交信息的正文里。需要追溯某特性的
  演进时，`git log --grep=<关键词>` 即完整时间线——不再有两处事实源漂移的风险
- pre-push 钩子在守门**之前**按本规范校验待推送提交的 subject，不合规即中止
  （绕过路径同守门：`git push --no-verify`；详见下节钩子说明）

## 守门钩子（pre-push）

`scripts/git-hooks/pre-push` 是版本管理的正身，`install-hooks.sh` 以**软链**方式接进 `.git/hooks/`：

- 不用 `core.hooksPath`——那会连带忽略该目录里已有的其它钩子
- 不用拷贝——避免源更新后留下过期副本

装后每次 `git push` 前自动做四件事，任一未通过即中止：

1. **提交信息校验**（快、先跑）：对 `@{push}..HEAD` 的每个非 merge 提交检查 subject
   非空、长度 ≥ 10、带类型前缀（规范见上节）。远端分支无 `@{push}` 时（如推送新分支）跳过校验
2. **守门自检**（`bash test/run_all_selftest.sh`，快，14 段）：两类机械判定——
   ① 守门自身的可信度（`bash -n` 语法、每个 `test/cpp/*.cpp` 是否登记进 `CMakeLists.txt`、
   `test/*.lua` 命名是否匹配两侧 glob、`count_calls` 的「N 条用例」文案是否真数得到调用点、
   两张用例表的结构与两套计数互证（条数**派生**、不再手写；tokenizer 见
   `test/lib/case_table.awk`）、TSan 名单**双向**核对，四个守门单点：`params.sh` 的
   守门常量、`agent_stale.sh` 的 mybot-agent 新鲜度取材面、`run_all.sh` 里
   `harness_selftest` 的路径派生与产物陈旧判据的循环覆盖、以及该判据排除名单与
   `CMakeLists.txt` 目标归属的双向核对；末尾再**实跑**一次拼错
   过滤器，核对空匹配防线（C8）真的会红）；
   ② 七组**零编译跨源一致性**校验（仿真器契约、状态目录缺省名、文档引用/计数/已删文件/
   套件计数口径、模型配置字段白名单双端同集合、有状态 LLM 协议判据双端同集合、
   LLM wire 契约、后端工具注册表与两张文档工具表；明细见 [testing.md](testing.md)「跨源一致性校验」）——
   这些是「用例静默消失 / 双事实源漏改」的唯一机械防线；它**不进入** `run_all.sh`
   的记账，守门汇总口径不变
3. **mybot-agent 产物新鲜度**（判**红**，2026-10-06 加）：`agent/target/release/mybot-agent`
   缺失、或早于 `agent/src`/`agent/Cargo.toml`/`agent/Cargo.lock` 里的任一文件 ⇒ 中止推送并
   打印重建命令 `bash scripts/build_agent.sh --release`。理由是守门入口（`run_all.sh`）对
   同一状况判 **[SKIP]**（mybot-agent 是可选产物、本机可能没装 cargo），而 SKIP 计入汇总后
   rc 仍是 0：`agent-rust-e2e` 与 `ica-e2e` 两段整段消失，汇总与真绿无法区分。CI 也补不上
   （`gate:release`/`gate:musl` 镜像里没有 cargo）。分层口径：**本机装了 cargo 就能自己修，
   故判红**；没装 cargo 时不拦，只提示交 `gate:agent-e2e` 兜底。逃生口 `BOT_ALLOW_STALE=1`
   与守门入口共用同一语义（明确知道要跑旧产物时显式声明）
4. **离线守门**：`bash test/run_all.sh`

单次绕过：`git push --no-verify`。

放行分支（fail-open，fix-plan 3-6 补记）：仓库根缺 `test/run_all.sh` 时钩子**打印提示后直接放行**（`exit 0`）——这是对「在非仓库根/精简检出里推送」场景的兜底，不是安全设计：钩子的威胁模型是**防手滑**而非防绕过（`--no-verify` 本就随时可绕）。在正常仓库根里该分支不可达；守门的强制力以 CI/复核流程为准。

## 委派与自动化（子代理 / 脚本 / 批量工具）

本仓库用自动化代理做审计与批量整理，但**代理的写权限必须显式收窄**：

- 委派时声明**只读**：不得 `rm` / `mv` / `git checkout|clean|stash|restore` / `sed -i`，
  不得在 `src/`、`modules/`、`test/`、`scripts/`、`docs/`、`robots/` 等已跟踪路径上
  创建、修改、改名或删除文件；需要实验就把目标文件**复制**到 `.tmp/` 后对副本操作。
- 委派**前后各跑一次 `git status --porcelain` 并留档**；收工时应只剩预期的未跟踪项。
  发现有 ` D`（未暂存删除）立即 `git checkout -- <路径>` 从 HEAD 恢复并核对数量。
- 背景：2026-09-20 一次并行审计中，子代理在被要求「只在 `.tmp/` 写入」的前提下删除了
  **17 个已跟踪文件**（`modules/` 下 16 个驱动 + `bitcompat.lua`）。守门**不会**识别这类
  事故类型——它只会因为缺文件而变红，成因需要人工回溯；恢复后必须重跑基线确认
  「红是事故造成的，不是存量缺陷」。

## 新增驱动

在 `modules/` 加一个 `<矩阵名>.lua`。硬件/总线驱动使用 `require_driver` 框架声明
总线类型与业务闭包（见下）；非驱动模块（`Relay`/`dummy` 等）仍用独立 `function`
定义。契约要点：

- `build`/`call`/`destroy` 必须返回带 `result` 键的表（`"OK"` 或 `"ERR"`）；返回非表或漏写 `return` 会被判契约违反并中断。非硬件的协议型模块同样适用——`call(nil)` 必须返 ERR 契约表而非抛 Lua error
- 硬件驱动使用 `require_driver("i2c"|"spi"|"uart", { name=, build=, call=, destroy= })`，框架自动处理 `arg_table` 入参校验与总线校验（`i2c_pair` / `fd≥0`）、`proto=virt` 虚拟总线注入前置，驱动闭包接收 `ctx.fd`/`ctx.addr` 直接写业务逻辑
- 非驱动模块（`Relay`/`dummy` 等）入口第一行仍需 `local ok, ek = arg_table(data)` + `if not ok then return ek end`（`drv_common`）——它同时承担入参类型校验与 `proto=virt` 虚拟总线注入前置，手写 `type(data) ~= "table"` 内联检查会绕过注入钩子（`run_all.sh` 的 lint 段会拦；Camera 是唯一豁免，见其头注）
- **模块路径引导固定写法**（多路径加载的前提）：`local mpath = __mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")`，后续 lib 一律 `dofile(mpath.resolve("lib/xxx.lua"))`。`__mpath` 由宿主建沙箱时注入（逐段探测），直接写 `(env):match("[^:]+")` 只取首段、多路径布局下会失败；`run_all.sh` 的 lint 段会拦
- `result`/`message`/`mode` 三键由框架保留（见 [dsl.md](dsl.md)）
- 建议随驱动在文件尾部内嵌 `<矩阵名>_VIRT` 仿真模型，接入 virtbus 回归（见 [virtbus.md](virtbus.md)）
- 完成后跑一次 `luajit test/test_driver_contract.lua`（驱动入口契约 sweep：可加载 + 三入口齐全 + 非表入参 ERR 契约，同时覆盖上面两条 lint 的语义面）

## 10 分钟写一个新硬件驱动（新手完整引导）

> 上文「新增驱动」给的是契约要点速查；下面是完整引导，与 `modules/Relay.lua`
> 及仓库真实驱动（EMC2101 / PCA9685 / Max17048 等）逐条核对过，新手照抄即通。
> 契约的权威定义仍以 [drivers.md](drivers.md) 为准。


### 一、驱动是什么

一个 Lua 文件 = 一类硬件。结构脚本里 `CREATE TABLE Buzzer ...`，框架按表名在 `modules/` 下找 `Buzzer.lua`（目录由 `BOT4CJ_MODULE_PATH` 指定，默认 `./modules`，冒号分隔多段逐段探测）；矩阵每一行的 `name` 列成为一个硬件变量实例（如 `relay0`、`timer-0`），结构脚本里其他列的值按列名进入驱动的 data 表。

硬件/总线驱动使用 `require_driver` 声明式框架：指定总线类型（`"i2c"` / `"spi"` / `"uart"`）和业务闭包（`build`/`call`/可选 `destroy`），框架自动生成全局 `build`/`call`/`destroy` 并处理入参校验与总线初始化。非驱动工具模块（`Relay`/`dummy`/`Kalman`/`Ema` 等）仍用传统的全局函数模式。

### 二、三段式契约

| 函数 | 触发时机 | 典型工作 |
| --- | --- | --- |
| `build(data)` | `active()` 时，按声明序 | 开总线、配置器件（I2C 驱动在这里 `i2c_pair` + 读 ID 甄别） |
| `call(data)` | @Action 每行、按列序 | 干活：转角度/读采样/延时（PCA9685/Servo/Timer/EMC2101） |
| `destroy(data)` | `deactivate()` 时，倒序 | 释放（纯软件模块返回 OK；总线驱动在这里关闭） |

**data 表怎么来**：矩阵行的各列（跳过 `name` / `controller` 列）∪ 模式标记（`mode = "build"/"call"/"destroy"`）∪ call 时再合并 @Action 该行的参数。细节三条：

1. `-` 占位符继承上一行同列；继承到首个数据行仍是 `-` 时按 `"0"` 处理（配合 `finite_of` 归一为 0）；
2. **引用机制**：某列的值如果是**别的硬件变量名**，框架先调它并把返回表字段合并进来——@Monitor 读守护的 `data.v0`、I2C 驱动拿总线的 `data.i2c` 都来自这里；驱动自己写的 `return { delay = ... }` 同样经框架合并后转发（Relay 返回 delay → controller 指定的 Timer）；
3. **返回值协议**：返回表与框架元数据合并后继续向下游转发；失败返回 `err(...)` 表，框架停止该行并报错退出。

### 三、最小模板：modules/Relay.lua 逐段（非驱动模块写法）

> **注意**：`Relay` 是非驱动工具模块，仍用独立全局函数模式。硬件/总线驱动请使用
> `require_driver` 框架（见下节 EMC2101 示例与 [drivers.md](drivers.md) 的驱动契约节）。

```lua
-- 标准前导（纯软件模块不需要 HAL，只需要 mpath/print_table/drv_common）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

function build(data)
	local ok, ek = arg_table(data)      -- 参数校验 + 虚拟硬件前置（见下）
	if not ok then return ek end
	return { result = "OK" }
end

function destroy(data)                  -- 无资源需释放时同 build
	local ok, ek = arg_table(data)
	if not ok then return ek end
	return { result = "OK" }
end

function call(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	local delay = finite_of(data.test)  -- 数值守卫：NaN/缺失/非法 → nil
	if delay == nil then delay = 0 end  -- 保留「缺失/占位符按 0」语义
	return { delay = delay }            -- 返回值合并后转发给 controller
end
```

**drv_common 关键工具**（modules/lib/drv_common.lua）：
- `require_driver(bus, spec)`：声明式驱动框架（详见 [drivers.md](drivers.md)），`arg_table` 入参校验 + 虚拟硬件前置 + 总线校验由框架统一处理，驱动闭包接收 `ctx.fd`/`ctx.addr`；
- `arg_table(data)`：非驱动模块（`Relay`/`dummy` 等）仍需手动调用；非表直接拒；`proto=virt` 时先 `virt_prepare`（虚拟硬件前置），真机路径一次比较即关闭；
- `finite_of(v)`：NaN 防护（审计 P3）——NaN 非 nil，`== nil` 兜不住，会把 NaN 当真实值转发到下游；请一律经它归一；
- `err(msg)`：失败契约，返回错误表；`clampi(v, lo, hi)`、`int_or(v, def, lo, hi)`、`num_or(v, def)` 数值归一；
- `guard_build(rollback, fn, data)`：build 失败回滚骨架。

### 四、有硬件的驱动：I2C 为例（EMC2101 同款写法）

```lua
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))                       -- 1 行前导（框架处理校验）
local bitc = dofile(mpath.resolve("bitcompat.lua"))               -- 符号扩展单点

require_driver("i2c", {
    name = "EMC2101",
    build = function(ctx, data)
        local fd = ctx.fd   -- 框架已完成 arg_table + i2c_pair
        local part = i2c_read_reg(fd, REG_PART_ID)   -- 身份甄别
        if part < 0 then return err("Failed to read ID") end
        return { result = "OK" }
    end,
    call = function(ctx, data)
        local fd = ctx.fd
        -- 业务读数逻辑
        return { result = "OK", v0 = temperature }
    end,
    -- destroy 省略 = 框架默认 no-op（无需器件收尾）
})
```

要点：
- **前导简化**：旧模式 5 行（HAL + print_table + drv_common + arg_table + i2c_pair）→ 新模式 1 行（`drv_common.lua`），`arg_table` + `i2c_pair` 样板由框架收敛；
- **`ctx.fd`/`ctx.addr`**：框架按总线类型自动校验并注入，驱动直接使用，无需手动提取；
- HAL 总线 API（`modules/lib/HAL.lua` 聚合门面，各总线域实现见 `modules/lib/hal/*.lua`）：`i2c_open(path)` / `i2c_close(fd)` / `i2c_write_reg(fd, reg, val)` / `i2c_read_multi_bytes(fd, reg, n)` / `i2c_read_bytes(fd, n)` / `i2c_write_reg16(fd, reg16, ...)`；
- 需要 set_addr 前额外校验的驱动在 build 闭包里用 `i2c_check(data)`（MS5611 OSR 档位、PCF8574 地址族），否则框架的 `i2c_pair` 已覆盖；
- 符号扩展一律走 `bitcompat.lua` 单点（`M.u16le/M.s16le/M.s16/M.s12/M.s8`，LuaJIT 内建 bit / 纯 Lua 双兼容）；不要手写补码拷贝（审计 #30 已清掉 3 处同文件遮蔽）；
- **虚拟硬件**：框架在调用驱动闭包前自动完成 `arg_table` → `virt_prepare`，测试不碰真总线。

### 五、结构脚本 + 动作脚本

结构脚本（robots/relay-test.sql）：
```sql
CREATE TABLE Timer ( name String );
INSERT INTO Timer (name) VALUES ('timer-0');
CREATE TABLE Relay ( name String, controller String, note String );
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
```

动作脚本（scripts/dummy.mt，@Action 区，分号分隔、空格分隔值、@ 结束）：
```
@Action
d1.test;
      -;
@
```
`-` 无上一行可继承时按未设置派发；`0 1 100 ...` 逐列给值。

### 六、测试与验证（10 分钟里的最后一步）

- `test/test_xxx.lua`：真实驱动 + virtbus 注入层 + 内嵌模型（驱动文件尾部 `XXX_VIRT`），断言含黄金向量；
- 运行：`luajit test/test_xxx.lua`（驱动依赖 HAL ffi，必须 LuaJIT）；纯逻辑可用 `lua5.4` 调试；
- 结构脚本回归：全仓 `robots/**/*.sql` 必须可解析（`./build/mybot --robot=robots/xxx.sql`）；
- 冒烟：`cat scripts/xxx.mt | ./build/mybot --robot=robots/xxx.sql`，看到 call 计数、退出码 0 即链路通。

### 七、新驱动 checklist（照抄即通）

1. `modules/X.lua`：硬件驱动用 `require_driver("i2c"|"spi"|"uart", { name=, build=, call= })` 声明总线与业务闭包（`destroy` 可省 = 框架默认 no-op）；非驱动模块用独立 `function build/call/destroy` + `arg_table` 开头；
2. 数值/布尔入参过 `finite_of` / `int_or` / `clampi`；符号扩展走 bitc；
3. `robots/xxx.sql` 结构脚本（含 controller 列则配引用机制）；
4. `scripts/xxx.mt` 动作脚本（@Action）；
5. `luajit test/test_xxx.lua`（virtbus 模型 + 黄金向量）全绿；
6. 全仓 .sql 回归 + mybot 冒烟通过。

对照最小模板（Relay）→ I2C 驱动（EMC2101）→ 虚拟硬件测试（test_max17048 等），10 分钟内可交付一个带测试的新驱动。

## 新增回归

`robots/test/<用例>.sql` + `scripts/test/<用例>.mt`，按守门契约接入 `test/run_all.sh` 的 e2e 列表或无硬件契约列表（含负值契约）。完整守门说明见 [testing.md](testing.md)。

## 新增 C++ 单测

在 `test/cpp/test_*.cpp` 用 `TH_TEST` / `TH_CHECK` / `TH_CHECK_THROWS_MSG` 补用例（`test/cpp/harness.hpp`，无第三方框架），并在 `CMakeLists.txt` 的 `mybot_tests` 源列表里加一行。

## 代码规范

本项目 `.cpp` 全量 `-Wall -Wextra -Wpedantic` 零告警为基线，改动请保持。
CI 的构建步带 `-DMYBOT_WERROR=ON`（把零告警变成门禁）；本地默认 OFF——未预跑的
编译器版本不应被 `-Werror` 挡住构建，想本地按 CI 口径验证就显式打开：

```bash
cmake -S . -B build -DMYBOT_WERROR=ON && cmake --build build
```

- **静态分析（clang-tidy）**：检查集见仓库根 [.clang-tidy](../.clang-tidy)
  （bugprone/performance/concurrency 高信号类别）。本地跑法：

  ```bash
  cmake -S . -B build-tidy    # 导出 build-tidy/compile_commands.json
  clang-tidy -p build-tidy src/*.cpp
  ```

  CI 的 `gate:clang-tidy` 为硬门禁（2026-09-25 起，此前 allow_failure 软门禁），与 gate:tsan
  同路径：全量输出落 `clang-tidy.log`，其非零退出码经「重定向落文件 → 记 rc → 末尾
  `[ $rc -eq 0 ]`」直接决定 job 结果（不再被管道末尾的 `tail` 吞掉；不用 `pipefail` 以求
  在 dash 下也成立），该日志同时声明为 artifacts（`when: always`）留档。存量告警已归零
  （clang-tidy 14.0.6），新增告警即 job 红：处置方式是走 `src/util_env.hpp` /
  `src/util_str.hpp` 单点（`getEnvVar` / `errnoText` / `concatMsg`）、定点 `NOLINT`
  注明理由，或按先例写入 `.clang-tidy` 豁免。

- **报错文案分语言**（有意分区，非漂移）：结构脚本装配/解析期的报错（`robot`/`sqlparse`/
  `hardware`/`daemonvar` 等，读者是 `.sql`/`.mt` 脚本作者）用**英文**——这类报错常被
  截断/转码后进日志或 CI 输出，ASCII 最稳；agent 与运行期操作者可见的报错
  （`mcpbackend`/`agentmode`/`agenttools` 等，读者是与机器人对话的人）用**中文**。
  两区都收口到同一异常体系（`IllegalArgumentException` 为根，运行期硬件失败用
  `std::runtime_error`），不要新增 `std::invalid_argument` 等散装类型。
  **Lua 驱动层同此分区**：驱动 `err()` 的报错串用**英文**（读者是脚本作者），
  注释一律中文；存量中文 `err()` 按驱动逐个改英文，新驱动按本条执行。
  库层（`HAL`/`nn`/`sensor_daemon`/`utf8` 等）的诊断与 `print` 输出已统一为**英文**，
  与驱动层 `err()` 策略对齐；`utf8.lua` 的 MARKER 与 C++ `kInvalidUtf8Marker`、
  Rust `INVALID_UTF8_MARKER` 三侧保持同字面。

## 文档约定

- **入口两级**：[README](../README.md) 只留「快速开始 + 入口链接」，机制细节写进 `docs/`；
  新增 `docs/*.md` 必须同时登记到 [docs/README.md](README.md)。
- **单一事实源**：文档里的**条数/枚举措辞**尽量指向脚本或目录本身（如「以 `test/run_all.sh` 为准」
  「以 `modules/` 目录为准」），避免代码演进后文档数字漂移——数字只在确需给读者量级时写死，
  并在同句给出权威来源。
- **代码路径要跟着重构走**：文件被拆分/改名时同步更新引用（历史上 `src/luaend.cpp`
  拆成 `luabridge.cpp` + `luasandbox.cpp`，文档因此滞后过）。
- **命令要能直接跑**：文档里的命令按仓库根为 CWD 书写，且必须是当前真实可用的形式
  （如 `--llm-config none`）。改脚本时回头核对文档。

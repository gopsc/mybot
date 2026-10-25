# Windows 上 faulthandler 与 LuaJIT 冲突导致的间歇性崩溃

记录日期：2026-10-18
影响平台：Windows（x64）；Linux / macOS 不受影响
状态：已修复（`pymybot/cli.py`、`tests/conftest.py`）

## 现象

在 Windows 上运行 `python -m pytest`，结果不稳定：有时 `714 passed`，有时进程直接以
`Segmentation fault`（退出码 139）结束，没有测试汇总。即使测试全部通过，输出里也夹着几十段
类似下面的栈转储：

```
Windows fatal exception: code 0xe24c4a02

Current thread 0x00002b4c (most recent call first):
  File ".../pymybot/runtime.py", line 184 in load
  File ".../pymybot/hardware.py", line 254 in build
  ...
```

崩溃时还会出现 `Windows fatal exception: access violation`，多发生在 Daemon 相关测试
（`tests/test_robot.py`、`tests/test_daemon.py`），此时有多个 Daemon 工作线程同时运行 Lua。

CLI 本身在用户开启 faulthandler（`python -X faulthandler` 或环境变量 `PYTHONFAULTHANDLER=1`）
时也会受影响：stderr 出现误报栈转储，严重时进程崩溃，stdout 拿不到约定的那一条 JSON。

## 根因

两个各自正常的机制叠加出了问题：

1. **LuaJIT 在 Windows x64 上用 SEH 实现 Lua 错误。** 每一次 `error()`——包括驱动返回错误、
   超时预算钩子中止执行、Daemon 停止时的中断——都会以结构化异常抛出，异常码固定为
   `0xE24C4A02`（中间两个字节 `4C 4A` 即 ASCII `"LJ"`）。这是 LuaJIT 正常的错误展开路径，随后会被 lupa 捕获并
   转换为 Python 异常，并不是崩溃。

2. **CPython 的 faulthandler 在 Windows 上注册了向量化异常处理器**，凡是最高位为 1 的异常码都
   视为致命错误并转储 traceback；它只把 MSVC C++ 异常（`0xE06D7363`）和 COM 异常
   （`0xE0434352`）列入白名单，不认识 LuaJIT 的 `0xE24C4A02`。

于是每个 Lua 错误都会触发一次"致命错误"转储。转储时 faulthandler 在不持有 GIL 的情况下遍历
**所有线程**的 Python 栈帧；单线程时只是噪音，但当 Daemon 线程正在并发执行、修改栈帧时，遍历会
读到正在变化的数据，引发 access violation，把整个进程带崩。

pytest 默认启用 faulthandler 插件，所以测试套件首当其冲。

LuaJIT 的 SEH 展开方式无法从 pymybot 侧改变，CPython 的白名单也不在本项目控制范围内，因此修复
思路是：**在 Windows 上不让 faulthandler 接管运行 LuaJIT 的进程。**

## 为什么正常运行也会抛出 Lua 错误

关键点：faulthandler 的向量化异常处理器看到的是**首次机会（first-chance）异常**，即异常刚抛出、
还没轮到任何 `pcall` 处理的时刻。所以被 `pcall` 接住、对业务完全无害的 Lua 错误，同样会被当作
"致命错误"转储。多数转储并非驱动真的出错，而是"先试一下、失败就走回退"的探测逻辑。

通过给 `LuaState._loader`、`_hal_call`、`_check` 打桩，记录每次 SEH 对应的触发点，来源可归为四类。

### 1. 模块路径在 Windows 上按 `:` 切分（主要来源，跨平台 bug）

以下代码用 `gmatch("[^:]+")` 切分 `BOT4CJ_MODULE_PATH`，这是 Unix 的分隔约定：

| 位置 | 用途 | pymybot 下是否执行 |
| --- | --- | --- |
| `modules/lib/drv_common.lua:82` | 探测 `lib/virtbus.lua` | 是 |
| `modules/lib/drv_common.lua:246` | 探测 `lib/bus_contract.lua` | 是（`__BOT4CJ_BUS_CONTRACT` 未设置时） |
| `modules/lib/virtbus.lua:148` | 探测 `lib/bus_contract.lua` | 是（同上） |
| `modules/lib/drv_common.lua:360` | 探测 `lib/mpath.lua` | 否，仅 `__mpath` 为 nil 时 |
| `modules/lib/mpath.lua:16` | `mpath.paths` 解析搜索路径 | 否，pymybot 注入了自己的 `__mpath` |
| 各驱动/库开头 `(__mpath or dofile(...:match("[^:]+") ...))` | 加载 mpath | 否，`__mpath` 短路 |

而 pymybot（`pymybot/runtime.py` 的 `_getenv`）用 `os.pathsep` 拼接该变量，在 Windows 上是 `;`，
且盘符本身含 `:`。于是 `C:\...\work\modules;C:\...\mybot\modules` 被切成如下假路径：

```
C/lib/bus_contract.lua
\Users\qingshuhong\...\work\modules;C/lib/bus_contract.lua
```

`dofile` 找不到文件 → loader 返回失败 → bootstrap 的 `dofile` 调用 `error()` → 被 `pcall` 接住。
**每次 activate 加载驱动都会走一遍**，这是正常场景中 SEH 的最大来源。

附带后果：该探测在 Windows 上看起来从未成功，`drv_common` 一直使用其内置的兜底 `finite_of`。
兜底实现与 `bus_contract.finite_of` 判据逐字相同，因此目前结果正确（未专门验证），但 Windows
与 Linux 实际走的是两条不同的代码路径。

### 2. sensor_daemon 探测虚拟器件模型文件

`modules/lib/sensor_daemon.lua:143` 在 `proto=virt` 时先 `pcall(dofile, "lib/virtbus/<驱动名小写>.lua")`。
仓库中该目录只有 `regmap.lua`，所以几乎总是失败，随后回退到驱动文件内嵌的 `<驱动名>_VIRT` 工厂。
这是设计上的"独立模型文件优先、内嵌模型兜底"，每启动一个虚拟 Daemon 产生 1 次。

### 3. Python 回调异常被 lupa 转成 Lua 错误

Lua 调用的 Python 函数里抛出的异常会被 lupa 转换为 Lua 错误，同样走 SEH：

- **HAL 拒绝物理硬件**：未加 `--allow-hardware` 时，`_hal_call` 对 `i2c_open` 等抛出 `DriverError`。
- **预算/停止钩子**：每 500 条指令触发一次的 `debug.sethook` 计数钩子调用 `_check()`，超时或
  Daemon 收到停止信号时抛出 `BudgetExceeded`，用来打断正在执行的 Lua 代码。

这一类本就是"用异常传递控制信号"，属于正常机制。

### 4. 驱动与库中真实的 `error()`

kalman、ema、json、pthread 以及 drv_common 的参数校验中都有显式 `error()`。测试套件会刻意覆盖
这些错误路径，因此跑 pytest 时这一类最多。

### 实测计数（faulthandler 开启，直接调用 Robot API）

| 场景 | SEH 次数 | 来源 |
| --- | --- | --- |
| relay demo | 2 | 第 1 类（activate） |
| UART `loop://` | 2 | 第 1 类 |
| 3 个变量的 dummy 结构 | 4 | 第 1 类 |
| 1 个虚拟 Daemon | 1 | 第 2 类 |
| 2 个 Daemon + sample | 1，随即崩溃（rc=3221225477，即 0xC0000005） | 第 2 类 |
| 物理 I2C 被拒绝 | 1 | 第 3 类 |
| `build()` 内 `error("boom")` | 1 | 第 4 类 |
| 死循环触发超时 | 5 | 4 次第 1 类 + 1 次第 3 类 |

"2 个 Daemon"一行最能说明问题：仅一次被正常接住的探测失败，恰逢其他线程在跑，faulthandler
无 GIL 遍历线程栈就把进程带崩了。

关闭 faulthandler（本文的修复）消除的是"正常错误被当成崩溃"；第 1 类路径切分问题是独立的 bug，
修复它可以减少 Windows 上的无谓异常并让两个平台走同一路径，但无法替代本修复——第 2～4 类错误
是设计使然，不会消失。

## 验证根因的对照实验

| 场景 | faulthandler 开启 | faulthandler 关闭 |
| --- | --- | --- |
| `pytest -x tests/test_robot.py tests/test_daemon.py` 重复 15 次 | 12/15 段错误 | 0/15 |
| CLI 双 Daemon `sample`，stderr 走管道，重复 20 次 | 7/20 无 JSON 结果，20/20 有误报转储 | 0/20，0/20 |

补充观察：同样的 CLI 场景把 stderr 重定向到 `/dev/null` 时崩溃率为 0/20。原因是转储写入较慢
的管道会拉长 faulthandler 遍历其他线程的时间窗口，竞争更容易命中——这也佐证了崩溃来自转储
过程本身。

## 修复

### CLI：`pymybot/cli.py`

新增 `disable_windows_faulthandler()`，在 `main()` 入口调用：

```python
def disable_windows_faulthandler():
    if sys.platform == "win32" and faulthandler.is_enabled():
        faulthandler.disable()
        print("pymybot: faulthandler disabled on Windows (LuaJIT SEH errors are not crashes)",
              file=sys.stderr)
```

- 仅在 Windows 且 faulthandler 已被用户开启时生效，否则什么都不做。
- 关闭时在 stderr 留一行说明，不影响 stdout 的单条 JSON 约定。
- console script `pymybot` 和 `python -m pymybot` 都经过 `main()`，两种入口都覆盖。

### 测试套件：`tests/conftest.py`

```python
@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    if sys.platform == "win32":
        import faulthandler
        faulthandler.disable()
```

pytest 的 faulthandler 插件在自己的 `pytest_configure` 里调用 `faulthandler.enable()`；
`trylast=True` 保证本钩子在它之后执行，从而在 Windows 上关闭。插件在 `pytest_unconfigure`
里的 `disable()` 与关闭 dup 文件描述符的清理逻辑对已关闭状态是安全的。

Linux / macOS 上 LuaJIT 使用 DWARF 展开而非信号，faulthandler 不会误报，因此保留，便于在 CI
上排查卡死或真实段错误。

### 回归测试：`tests/test_cli.py::test_faulthandler_cannot_break_json_on_lua_errors`

以 `python -X faulthandler -m pymybot sample ...` 启动 CLI，使用一个 `build()` 内直接
`error("boom")` 的驱动，断言：

- 退出码为 1，stdout 恰好一行 JSON，`ok` 为 `false` 且错误信息包含 `boom`；
- stderr 中不出现 `Windows fatal exception`。

该测试用单线程场景做确定性检测：修复前每次都会出现误报转储（测试失败），不依赖多线程竞争
的概率。非 Windows 平台上断言天然成立。

## 修复后的验证

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| `pytest -x tests/test_robot.py tests/test_daemon.py` × 15（默认命令） | 12/15 段错误 | 0/15，无转储 |
| `pytest` 全量 × 6（默认命令） | 间歇段错误 | 6/6 均 `715 passed, 3 skipped`，转储 0 |
| CLI `-X faulthandler` 双 Daemon `sample`，管道 × 20 | 7/20 无 JSON | 0/20，转储 0/20 |
| `PYTHONFAULTHANDLER=1` 运行 CLI | 可能崩溃 | stderr 一行提示，结果正常 |

验证环境：Windows，Python 3.12.10，lupa 2.8（LuaJIT 2.1）。3 个 skip 为 Windows 无软链权限的
既有预期跳过，与本问题无关。

## 取舍与注意事项

- **代价**：Windows 上若 Python 层发生真实段错误，将看不到 faulthandler 的 traceback。考虑到
  在本项目中它几乎每次都误报且自身会引发崩溃，这一取舍是合理的。需要排查真实崩溃时，可用
  WinDbg / procdump 等原生调试工具代替。
- **测试中直接调用 `cli.main()`**：`main()` 关闭 faulthandler 会影响调用方进程。测试套件在
  Windows 上已由 conftest 预先关闭，因此是空操作；把 `main()` 嵌入其他 Python 程序时需知晓
  这一副作用。
- **不要用 `-p no:faulthandler` 写进 `pyproject.toml` 代替 conftest 方案**：那会在所有平台上
  关闭它，丢掉 Linux CI 的诊断能力。
- **Windows CI**：`.gitlab-ci.yml` 目前未包含 Windows runner；接入后无需额外参数，conftest 会自动
  处理。

## 复现方法（用于确认问题或回归）

撤销上述两处修复后，在 Windows 上执行：

```sh
# 测试套件：多次运行，观察段错误
for i in $(seq 1 15); do .venv/Scripts/python -m pytest -q -x tests/test_robot.py tests/test_daemon.py >/dev/null 2>&1 || echo "run $i: rc=$?"; done

# 单个确定性信号：回归测试会失败并显示 0xe24c4a02 转储
.venv/Scripts/python -m pytest -q tests/test_cli.py -k faulthandler
```

## 相关但未处理的问题

**模块路径按 `:` 切分**：已修复（2026-10-18），见下文「后续：模块路径探测修复」。

**Windows 管道下 stdout 为 GBK**：已修复（2026-10-19），见下文「后续：输出流固定 UTF-8」。

## 后续：模块路径探测修复（2026-10-18）

### 实际触发点

逐个核对后，pymybot 下真正走到错误切分的只有两处（`HAL.lua` 已用 setfenv 把
`virt_prepare` 与 virtbus 内部的探测拦截掉，且旧拦截正则 `/lib/...` 恰好能匹配切出来的
`C/lib/...`）：

- `drv_common.lua` 加载时的 `bus_contract` 探测：驱动文件头先 `dofile` drv_common，此时
  HAL 还没加载、`__BOT4CJ_BUS_CONTRACT` 为 nil，于是按 `:` 切分探测 → 失败 → 走兜底 `finite_of`。
- `sensor_daemon.lua` 直接 `pcall(dofile, mpath.resolve("lib/virtbus.lua"))`，不经 HAL 拦截，
  virtbus 文件头的 `bus_contract` 探测按 `:` 切分。

### 修法

- `drv_common.lua` 新增局部 `probe_lib(rel, load)`：宿主注入了 `__mpath` 时用
  `__mpath.resolve(rel)`，否则保留原逐段切分（脱离宿主直跑的场景）。`virt_prepare` 与
  `bus_contract` 探测都改用它；`virt_prepare` 把自身环境里的 `dofile` 传入，HAL 的 setfenv
  拦截因此依旧生效。
- `virtbus.lua` 的 `bus_contract` 探测同规改写。
- `HAL.lua` 两处拦截正则由 `/lib/...` 改为 `[/\\]lib[/\\]...`：`__mpath.resolve` 在 Windows 上
  返回反斜杠路径，不改的话拦截不命中、会重复编译一次库文件（virtbus / bus_contract 有全局
  重入守卫，实例身份不受影响，已用撤销对照确认）。

bot4cj 的 C++ 宿主（`src/luasandbox.cpp`）同样注入真 `mpath` 表作为 `__mpath`，因此改动在
Linux 上行为不变，可原样回流上游。各驱动文件头 `(__mpath or dofile(...match("[^:]+")...))` 与
`drv_common` 的 mpath 引导都被 `__mpath` 短路，未改。

### 回归测试

`tests/test_robot.py::test_library_probes_survive_drive_letters_and_colons`：记录
`LuaState._loader` 的所有失败路径，激活含 Timer/Relay、UART `loop://`、虚拟 I2C + 驱动、
虚拟 Daemon 的结构并跑动作；断言除 `lib/virtbus/<驱动>.lua`（第 2 类，设计如此）外没有失败
加载。非 Windows 平台把自定义模块根命名为 `drivers:extra`，同样能复现旧问题，所以 Linux CI
也守得住。修复前在 Windows 上失败（`C/lib/bus_contract.lua` 等 4 条），修复后全量
`716 passed, 3 skipped`。

## 后续：输出流固定 UTF-8（2026-10-19）

### 现象与影响

Windows 上 stdout/stderr 接管道时，Python 用 ANSI 代码页（中文系统为 GBK）编码。实测
`apply-sql` 的结果"已生效：…"以 GBK 字节到达下游，按 UTF-8 解码报
`UnicodeDecodeError: ... byte 0xd2`。更严重的一种情况：结果里含代码页之外的字符（如驱动元数据
或回读值里的 emoji），stdout 的 `print` 直接抛 `UnicodeEncodeError`，一条 JSON 都输出不了，
违反单条 JSON 约定。

### 修法（`pymybot/cli.py` 的 `utf8_streams()`）

`main()` 入口把 stdout 与 stderr 都 `reconfigure(encoding="utf-8")`，stdout 用 `strict`，stderr
保留 Python 默认的 `backslashreplace`。已经是 UTF-8 的流不处理（如 Windows 控制台、pytest
capsys）。

为什么 stderr 也改：只改 stdout 的话，两路编码不一致，调用方没法统一解码（实测
`subprocess.run(..., text=True)` 照样会坏，比如 Windows 上 `absent.sql` 的中文系统报错）。统一为
UTF-8 与 Python UTF-8 模式一致（PEP 686 起 3.15 默认开启），也就是此前 `PYTHONUTF8=1` 绕过法的效果。
代价：仍按 GBK 解码 stderr 的旧工具会看到乱码，按 UTF-8 解码即可。与 faulthandler 一样，把
`main()` 嵌入其他程序时会改动调用方进程的 `sys.stdout`/`sys.stderr` 编码。

### 测试

- `tests/test_cli.py::test_output_streams_are_utf8_whatever_the_locale`：以 `PYTHONIOENCODING=gbk`
  启动子进程（任何平台都能复现），按字节捕获，断言 `apply-sql` 结果、含 `✅` 的 `hardware`
  元数据都能按 UTF-8 解析，且 `run` 时 Relay 打到 stderr 的 `note=✅` 按 UTF-8 原样可见。
- 测试里原先用 `text=True`（按本地编码解码）调用 CLI 的三处，改为 `encoding="utf-8"`，与新约定一致。
- 撤掉修复对照：新测试与 `test_help_errors_and_module_entrypoint` 都失败；修复后全量
  `717 passed, 3 skipped`。

# HAL：基层硬件抽象

> 本文介绍 bot4cj 硬件抽象层 `modules/lib/HAL.lua` 的实现原理、接口契约与驱动沙箱。[README](../README.md) 只留入口链接，实现细节以本文为准。

## 概述

总线怎么"开口说话"封装在 `modules/lib/HAL.lua`，所有驱动共用，**仅支持 LuaJIT**：

- ffi 直调 glibc，原生性能零 fork；fd 为真实内核句柄，跨 Lua 状态机有效
- 系统调用统一走 `HAL.sys.*` 间接层，离线单测（`test_hal_ffi.lua`/`test_uart.lua`/`test_pwm.lua`/`test_gpio.lua`）注入 mock 即可验证调用序列与缓冲区内容，不触硬件；
  间接层已**后端接口化**（2026-09-20）：`BOT4CJ_HAL_BACKEND` 选择后端（缺省
  `glibc`，模块 `modules/lib/hal_backend_<名>.lua`），接口契约（函数集与返回码语义）
  见该文件头注，缺函数加载期 fail-fast；`test_hal_backend_swap.lua` 以整表替换
  stub 跑通完整 i2c 事务锚定契约完备性。换后端 = 新增一个文件，总线函数与驱动零改动
- **平台差异单点** `HAL.platform`（`modules/lib/HAL.lua`）：设备根路径常量集中一处——
  `pwm_sysfs_root` = `/sys/class/pwm`、`gpio_prefix` = `/dev/gpiochip`；GPIO / PWM
  各节只取表值、不散落字面量，移植或上仿真桩改这一处（总线设备路径白名单同为单点，
  在 `bus_contract.lua`）
- 参数先归一化（字节 0~255、非负整数）再进 ioctl/缓冲区，设备路径走白名单正则；非法参数打印诊断并显式失败，不静默钳制
- 结构体尺寸与 ioctl 常量经 `test_ioctl_nums.c` / `test_uart_consts.c` 与系统头文件实证；尺寸断言在加载期执行（spi_ioc_transfer=32、i2c_msg=16、gpiohandle_request=364、termios=60），ABI 漂移立即失败

**文件布局（26.2 按域拆分）**：`modules/lib/HAL.lua` 是**聚合门面**——只留加载期接线
（LuaJIT/ffi 环境检查、重入口守卫、后端派发、常量重导出、`bus_contract` 接线、
`milli_sleep`、停机灭火判定 `bus_quiesced`），五个总线域各一文件：

| 文件 | 域 | 段内私有 helper |
| ---- | -- | -------------- |
| `modules/lib/hal/i2c.lua` | I2C（含 16 位寄存器指针器件） | `i2c_rdwr`、`be_merge` |
| `modules/lib/hal/spi.lua` | SPI（spidev ioctl） | `spi_xfer` |
| `modules/lib/hal/gpio.lua` | GPIO（gpiod uAPI v1） | — |
| `modules/lib/hal/uart.lua` | UART（termios raw 8N1） | `UART_B_CONST*`、`glibc_uses_hz_baud` |
| `modules/lib/hal/pwm.lua` | PWM（Linux sysfs） | `pwm_id`、`pwm_chip_path`、`pwm_attr_path`、`sysfs_write`、`errno_hint` |

域文件是门面的**分块**、不是可独立加载的模块（单独 `dofile` 会 assert 报错）：
`loadfile` 出来的子块看不到门面文件的 `local`，故共享上下文（`HAL` 表、`ffi`、
`bus`、后端常量表 `_c`、三个归一化器、`bus_quiesced`、`O_RDWR`）由门面经 `ctx`
表显式传入，域文件正文因此得以逐字搬迁。域之间零相互引用，加载顺序只要求在
门面接线之后。定位方式与 `bus_contract` / 后端加载段同规（`BOT4CJ_MODULE_PATH`
各段逐段探测 + 仓库缺省布局兜底），故多路径布局下的行为与拆分前一致。
对驱动而言**接口零变化**：仍是 `dofile(mpath.resolve("lib/HAL.lua"))`，
38 个总线全局函数与 `HAL.*` 全部字段照旧由该门面导出。

## 各总线要点

| 总线 | 关键实现 |
| ---- | -------- |
| I2C | `I2C_RDWR` ioctl **原子事务**：读的「写指针 + 读」合并为单次内核传输，消除并发访问同一器件时的寄存器指针竞态；地址由每条 i2c_msg 携带，不再需要 `I2C_SLAVE`（没有 EBUSY 问题）。16 位指针器件（VL53Lx ToF 族）同样合并为单事务 |
| SPI | spidev ioctl；mode/bits/speed 经 ioctl 持久化在 fd，`delay_us` 无 per-fd 持久化途径、由驱动在每次传输显式传入（`spi_write*`/`spi_read*`/`spi_xfer_full` 尾参） |
| GPIO | 内核 gpiod uAPI v1（`/dev/gpiochipN` ioctl，deprecated 但全内核支持）；offset 必须为非负整数（小数会被 uint32 静默截断成另一个线号，显式拒绝） |
| UART | termios raw 8N1 + 非阻塞（VMIN=0/VTIME=1）；另有多条易踩坑约束，见下方要点 |
| PWM | sysfs（`/sys/class/pwm/pwmchipN/pwmM`，ffi 直写、不经 io 库）；写序固定 duty=0 → period → duty_cycle（否则降频被 EINVAL 拒绝）；export 前置校验 npwm 范围，errno 给人话提示 |

UART 的易踩坑约束：

- open 时快照原始 termios，close 先恢复再关闭——板载 UART 的配置跨 close 保留在 tty 上
- 波特率必须传 glibc `B*` 常量（`UART_B_CONST` 映射）：缺失/非法即失败，数值 Hz 会被 EINVAL 静默忽略
- 读取按 1ms 步进轮询，`timeout_ms` 超 `UART_READ_MAX_MS`（60000）显式失败

**合并读长度上限**：`i2c_read` / `i2c_read_multi` / `i2c_read_reg16` / `spi_read_multi` 的大端合并值受 2^53 精度限制，n 有效范围 **1~6**，越界显式失败（静默钳制会被调用方的拆字节数学放大成错误数据）；更长块读取用字节表族 `i2c_read_bytes` / `i2c_read_multi_bytes`（n 钳 1~16，表长对调用方可见）或 `spi_xfer_full`（全双工帧，返回等长字节表）。

## 返回契约（驱动按此判定成败）

| 约定 | 函数 |
| ---- | ---- |
| `true` / `false` | `i2c_set_addr`、`i2c_write_reg`、`gpio_set_value`、`pwm_export`/`pwm_enable`/`pwm_set_polarity`/`pwm_unexport`（`pwm_config` 成功返回 `true, period_ns, duty_ns`） |
| `0` / `-1` | `i2c_write_multi`、`i2c_write_reg16`、`spi_setup`、`spi_write`、`spi_write3`、`spi_write_multi`、`uart_close`、`uart_flush` |
| 值 / `-1` | `i2c_read_reg`、`i2c_read_multi`、`i2c_read_reg16`、`i2c_read`、`spi_read`、`spi_read_multi`、`gpio_get_value`、`uart_open`（fd）、`gpio_request_line`（fd） |
| 表 / `nil` | `i2c_read_multi_bytes`、`i2c_read_bytes`、`spi_xfer_full`、`uart_read`（空表 = 超时无数据；`nil` = 读错误或参数非法） |
| 无返回值 | `i2c_close`、`spi_close`、`gpio_free_line`、`milli_sleep`；`uart_write` 返回写入字节数或 `-1` |

完整语义以 `modules/lib/HAL.lua` 与 `modules/lib/hal/*.lua` 各函数注释为准。`virtbus.lua` 逐函数复刻上述契约（含失败返回值），供无硬件 E2E 使用。

## 驱动沙箱

加载驱动**前**先中和 `os.execute`/`io.popen`（shell）、`os.exit`、`io.open`/`io.lines`/`io.input`/`io.output`/`os.remove`/`os.rename`（任意文件读写）、`os.tmpname`（可预测临时路径，符号链接竞争面；全仓驱动无一使用）——沙箱态统一由 `src/luasandbox.cpp` 的 `openSandboxedState()` 建立（`luaL_newstate` + `luaL_openlibs` + `sandbox_lua`；N-17 由原 `luaend.cpp` 拆出），`luavar.cpp` / `daemonvar.cpp` 都取它，调用方随后 `luaL_loadfile` + `lua_pcall`。这是**防误用护栏，不是安全边界**——驱动可经 `require("ffi")` 直调任意 libc，脚本均为可信输入；接入 `--tcp` 外部数据源时需另行建立信任边界。

**信任边界（S1）**：`ffi.C` 即整个 libc——`ffi.C.system("...")`、`ffi.C.open(path, 0)` 一行即可绕过上述全部中和，`ffi.cast` 更可任意地址读写。因此**驱动脚本必须视为完全信任的代码**，沙箱仅防误写。

**信任前提体检（BQ-2，2026-09-29 审计 P2-2 收口）**：既然「驱动文件可信」是沙箱唯一的前提，前提被削弱就必须看得见——三个 C++ 加载点（`luavar.cpp` 的驱动加载、`daemonvar.cpp` 的守护 chunk 加载、`luasandbox.cpp` 的白名单 dofile/loadfile）在加载前经 `util_file.hpp` 的 `auditTrustedFilePath` 体检：文件**组或其他人可写**（mode 含 `0022`）即响亮告警一次（不阻断——umask 002 的共享组开发属操作者自担，但必须看见）。告警意味着任何本机用户都能改写「等效于宿主进程本身」的代码。`os.getenv` / `io.read` / `io.write` 等 Lua 级入口**有意保留**不动：ffi 面前包一层 Lua 白名单只防误用不防恶意（`ffi.C.getenv` 一样直达），化了装反而误导；运行时开关类变量（`BOT4CJ_DEBUG` / `BOT4CJ_CAMERA_SRC_DIR` 等）本就是它们的正当用途。

**总线并发边界与停机灭火（BQ-1，2026-09-29 审计 P2-3 收口）**：主线程驱动与守护线程对同一 `/dev/i2c-*` 的**单次传输**由内核 adapter 锁串行；不同器件的传输交错（各自带从地址）不构成破坏，**同一器件被两线程并发访问不是受支持的配置**——唯一的既定场景是停机序列：弃管守护与硬件销毁并发。对此的收口是**灭火协议**：守护共享槽新增 `quiesce` 位（`daemonvar.hpp`，offset 592；与 `stop` 分离——`stop` 是「请退出」，宽限内退场的守护还要跑 `daemon_cleanup` 做去初始化，传输必须放行；`quiesce` 是「物理隔离」，只给确定要与硬件销毁并发的那批）。`DaemonRunner` 停机序列重排为「requestStopAndWait 等待（不弃管）→ finishTeardown 宽限 → 仍未退场才灭火弃管」，灭火后该守护 lua_State 里 HAL 的一切真实总线传输（`i2c_rdwr` / `spi_xfer` / `uart_read/write`，持槽锁读）在进内核前被拒绝；`open/close` 不受约束（退出路径要能关 fd）。竞态窗口从「无界」收敛到「灭火时刻的在途单次传输」；已进入 D 态 ioctl 的那一笔是用户态无法收回的残余。virt 仿真路径不受 `quiesce` 约束（无物理副作用）。回归：`test/test_hal_quiesce.lua`（mock 三族传输 + 零内核调用断言）、`test/cpp/test_daemon.cpp` 的 `finishTeardown` 两态用例。

- 当前威胁模型下成立：驱动/chunk 文件名只取自本地 `.sql`/`.mt` 表名，远程 TCP 下发的动作数据无法注入 Lua 加载路径
- 两个失效条件（引入任何一条前须先补回归测试钉死）：`BOT4CJ_MODULE_PATH` 指向不可信目录；未来新增远程选择驱动文件的入口
- 另注：白名单前缀匹配不解析 symlink

**dofile/loadfile 白名单（M3）**：`dofile`/`loadfile` 未被禁用而是**白名单化**——仅允许加载 `BOT4CJ_MODULE_PATH`（缺省 `./modules`，`:` 分段）内的路径，且路径不得含 `..`（目录穿越拒绝），越界加载明确报错（`sandbox: dofile/loadfile only allowed inside the module path ...`）。驱动/`@Daemon` chunk 按模块路径经 `mpath.resolve` 解析，正常使用不受影响；实现见 `src/luasandbox.cpp`（N-17 由原 `luaend.cpp` 拆出，Json↔Lua 桥接见 `src/luabridge.cpp`）。

**`require` 收口（A3，2026-09-20 审计）**：`require` **不经过**上面被包装的全局函数——它走 `package.loaders`，其中的 Lua 文件搜索器在 C 层直接 `luaL_loadfile`（实测 `require("evil_mod")` 能从模块树外加载）。现已：
- **保留** preload 搜索器——`require("ffi")` / `require("bit")` 是全仓驱动仅有的两个真实 `require`，都经它提供（LuaJIT 把 `ffi` 注册为 preload；`bit` 在 `package.loaded`），与文件系统无关；宿主另把 `mpath` 注册进 `package.preload`；
- **替换** Lua 文件搜索器与 C 搜索器为「返回说明性错误串」的桩，`package.loadlib` 置 `nil`，`package.path`/`cpath` 清空——于是任何按模块名加载文件的尝试都会失败，并给出 `sandbox: require() may only load preloaded/built-in modules ...`。

驱动要用文件就必须走 `mpath.resolve` + `dofile`（同一套白名单判据）。注意本条收口的是**声明与实现的一致性**，不改变下面「沙箱不是安全边界」的结论。

# 命令行与环境变量参考

> 本文收录当前 controller-only 版本的全部可调接口：CLI 参数、动作输入源、安全约束与环境变量。[README](../README.md) 中只保留快速开始。

## 环境要求

| 组件 | 说明 | 状态 |
| --- | --- | --- |
| Linux | 宿主 HAL 直接使用 Linux ioctl/sysfs；非 Linux 平台未支持 | ✅ 必需 |
| CMake ≥ 3.16、C++17 编译器 | g++ / clang++ | ✅ 必需 |
| LuaJIT 2.1（`libluajit-5.1-dev`） | 驱动与独立 Lua 回归 | ✅ 必需 |
| SQLite3、libcurl、libftdi1、libusb | 结构 SQL、HTTP、FTDI | ✅ 必需 |
| Python 3 | 仓库里的文档/协议校验脚本；不参与 `mybot` 运行期 | ⭕ 可选 |
| `/dev/i2c-*`、`/dev/spidev*`、`/dev/gpiochip*`、`/sys/class/pwm` | 真机总线/执行器 | ⭕ 可选 |

## 命令行参数

程序名为 `mybot`。参数支持 `--key=value` 与 `--key value` 两种写法（`src/cliargs.cpp`）；未知或拼错的 `--key` 一律报错并以退出码 **2** 结束（不静默忽略）。

| 参数 | 说明 |
| --- | --- |
| `--robot <path>` | **必选**，机器人结构脚本 `.sql` 路径。无参数直接运行 `mybot` 时打印帮助并退出 0；**给了其它参数却缺 `--robot` 时退出 2**。打不开或解析失败退出 1 |
| `--input <path>` | 从文件读取动作脚本 `.mt`；不给则读 stdin |
| `--timeout <sec>` | 动作脚本墙钟预算，`>0` 且 `<=3600`，缺省 180 |
| `--daemon-grace-ms <ms>` | 守护线程弃管后的二段停机宽限上限，`0..300000`，缺省 30000 |
| `--var NAME=VALUE` | 会话别名注入（可重复）；`NAME` 须为安全标识符，重复定义退出 2 |
| `--var-env NAME=ENVVAR` | 从环境变量读取会话别名（可重复）；变量未设置退出 2 |
| `--help, -h` | 打印帮助并退出 0 |

`--var` / `--var-env` 注入的别名只在本次 `run()` 内有效，出口（含异常路径）整体回滚；它们绑定在脚本内联 `@Alias`/`@Vars` 之后，调用方显式实参覆盖脚本内同名默认值。被结构引用为 controller/trigger 的名字不允许被注入覆盖。

退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功，或打印帮助 |
| `1` | 运行错误：结构脚本打不开/解析失败、硬件 build/call/destroy 失败、动作脚本执行失败等 |
| `2` | 用法错误：未知参数、缺 `--robot`、选项取值越界、`--var*` 形态错误等 |
| 信号退出 | 第二次 SIGINT/SIGTERM 为强杀逃生口：恢复默认处置并重新触发，不保证硬件清理 |

## 动作输入源

`src/actionsource.cpp` 按 **文件 > stdin** 二选一：

```bash
# 1) 文件输入
./build/mybot --robot=robots/relay-test.sql --input scripts/relay-test.mt

# 2) 缺省：stdin 管道
cat scripts/relay-test.mt | ./build/mybot --robot=robots/relay-test.sql
```

TCP 动作源、MCP/agent、Web SSH 与 sim 相关入口已从本分支移除；当前只支持文件/stdin 两种输入。

## 安全约束

- 动作脚本只能**引入新的参数键**，不得覆盖结构脚本的元数据列（`fd` / `address` / `max` / `min` / `offset` 等），也不得占用触发器引用名
- 单次输入上限 **8 MiB**：动作脚本（`.mt`）与结构脚本（`.sql`）统一适用，超限即拒绝并指明输入类别
- `result` / `message` / `mode` 三个键名由框架保留，`.mt` 不得用作参数列（`MtVars_Lua::rejectReservedKeys`）
- 物理 I2C/SPI/UART、非回环 HTTP/TCP、Shell 与 FTDI 默认允许；驱动沙箱禁用 shell 与任意文件读写，但这是**防误用护栏而非安全边界**——驱动可经 `require("ffi")` 直调 libc
- 驱动文件（`modules/**/*.lua`）是任意原生代码执行入口，信任级别等同运行 `mybot` 的用户。需要对抗恶意输入源时，应在进程外隔离（专用用户、容器、网络命名空间）

### 沙箱威胁模型

`modules/` 下的驱动与 `@Daemon` chunk 按**可信输入**对待，沙箱的边界是「驱动作者边界」而非「网络攻击边界」：

- 驱动可经 `require("ffi")` 调 `ffi.C`/`ffi.load` 触达任意 native 符号；`os.execute` 中和与文件 I/O 白名单在 ffi 面前形同虚设
- 结构脚本与动作脚本落盘前只是数据；**驱动文件是任意原生代码执行的入口**
- 若需对抗恶意输入源，应在进程外建立隔离；库内 Lua 沙箱对此无能为力

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `BOT4CJ_MODULE_PATH` | 驱动模块目录（默认优先 `./modules`，不存在则用安装布局的 `<prefix>/share/mybot/modules`），`<矩阵名>.lua`、`lib/`、`@Daemon` chunk 都按它解析；支持 `:` 分隔多路径按序查找。宿主建沙箱时逐段探测 `lib/mpath.lua` 并注入 `__mpath`；脱离宿主直跑 `luajit test/*.lua` 时没有 `__mpath`，回退单根语义，请把含 `lib/` 的根放首位 |
| `BOT4CJ_DEBUG` | 设为 `1` 开启 call/build/destroy 的参数表、结果表与逐键值转储；缺省静默 |
| `BOT4CJ_ALLOW_PTRACE` | 设为 `1` 时 `mybot` 启动不再执行 `prctl(PR_SET_DUMPABLE, 0)`，进程保持可被同 UID `ptrace`/core dump；仅调试用。sanitizer 构建编译期跳过这一步 |
| `BOT4CJ_HAL_BACKEND` | **仅独立 LuaJIT 回退路径**：`modules/lib/hal_backend_<名>.lua`（缺省 `glibc`）。宿主运行期走 C++ HAL，不读本变量 |
| `BOT4CJ_PWM_SYSFS_ROOT` | 宿主 C++ HAL 的 PWM sysfs 根目录，缺省 `/sys/class/pwm`；用于测试、容器或非标准挂载 |
| `BOT4CJ_CAMERA_SRC_DIR` | 摄像头仿真来源的放行目录（冒号分隔）：结构脚本给 `Camera` 驱动传 `src` 时，路径必须落在这里面，否则驱动拒绝读取 |
| `BOT4CJ_TEST_VIDEO` | 仅守门用：真机摄像头用例（`test_camera_v4l2.lua`）的设备路径，指定且存在时该用例不再按跳过计 |
| `BOT4CJ_TRACE_FDS` | 仅守门用：`mybot_tests` 专用测试钩子（生产二进制不含） |

## 中断语义（单进程）

Ctrl-C / SIGINT / SIGTERM 首次到达时只置停止标志，主流程走正常清理链：

1. 动作派发在行间检查停止标志，守护线程在两拍之间检查 `stop`；
2. `runRobotAndCleanup` 调 `deactivate()`：守护停机 → 驱动逆序 `destroy` → HAL 关闭遗留句柄；
3. 第二次信号恢复默认处置并重新触发，立即退出，**跳过清理，不能保证硬件安全停下**；驱动阻塞或守护拒绝退场时尤其要注意。

## 已移除能力

本分支不再提供 `--tcp*`、`--mcp-*`、`--agent*`、`--webshell-*`、sim/LLM 相关选项与环境变量。`docs/agent.md`、`docs/sim.md`、`docs/webssh.md`、`docs/ica.md` 及架构页保留为历史存档，不能作为当前控制器行为依据。

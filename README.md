# mybot C++ 控制器

Linux 上的 C++17 机器人控制器。结构 SQL 声明硬件，LuaJIT 驱动实现设备，MT 动作脚本描述时序。当前仓库是 Python `mybot` 的 C++ 重写版，**只保留控制器**：MCP、agent、Web SSH 和 Rust agent 已移除。

## 依赖

```sh
sudo apt install cmake g++ ninja-build luajit libluajit-5.1-dev \
                 libsqlite3-dev libcurl4-openssl-dev
```

- LuaJIT 2.1：驱动运行时
- SQLite3：结构 SQL 的解析/执行库
- libcurl：HTTP 驱动
- CLI11：命令行解析（已 vendored 在 `third_party/cli11`）

## 构建与测试

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
ctest --test-dir build --output-on-failure
./build/mybot --help
```

当前基线：**574 个 C++ 单测通过**；ctest 除 `lua_test_camera_v4l2.lua`（需要 `/dev/video0`）外全部通过。

## 快速开始

```sh
# 静态校验（不激活硬件）
./build/mybot --robot=robots/test/ads1015_virt.sql \
              --input=scripts/test/ads1015_virt.mt

# 纯软件示例
./build/mybot --robot=robots/relay-test.sql \
              --input=scripts/relay-test.mt

# 动作脚本也可以从 stdin 读
cat scripts/relay-test.mt | ./build/mybot --robot=robots/relay-test.sql

# TCP 动作源
./build/mybot --robot=robots/relay-test.sql --tcp 19240
```

`--robot`/`--input` 是相对当前目录的路径；模块根默认 `./modules`，可用 `BOT4CJ_MODULE_PATH`（`:` 分隔）或环境变量覆盖。

## CLI

```text
mybot --robot <结构脚本.sql> [--input <动作脚本.mt>] [选项]
mybot --robot <结构脚本.sql> --tcp <端口> [选项]
cat action.mt | mybot --robot <结构脚本.sql> [选项]
```

| 选项 | 说明 |
| --- | --- |
| `--robot <path>` | 结构脚本 `.sql`（必选） |
| `--input <path>` | 动作脚本 `.mt`；不给则读 stdin |
| `--allow-hardware` | 允许物理设备、非回环网络与宿主 Shell |
| `--timeout <sec>` | 动作脚本墙钟预算（>0 且 <=3600，缺省 180） |
| `--daemon-grace-ms <ms>` | 守护线程停机宽限（0..300000，缺省 30000） |
| `--tcp <port>` | TCP 动作源端口 |
| `--tcp-host <addr>` | TCP 监听地址（缺省 `127.0.0.1`） |
| `--tcp-token <tok>` | TCP 口令；非回环监听必填 |
| `--tcp-idle <sec>` | TCP 空闲超时（1..86400，缺省 30） |
| `--tcp-max-auth-attempts <N>` | TCP 口令连续失败上限（1..1000，缺省 5） |
| `--tcp-total-timeout <sec>` | TCP 连接总时长预算下限（1..86400，缺省 600） |
| `--var NAME=VALUE` | 会话别名注入（可重复） |
| `--var-env NAME=ENVVAR` | 从环境变量读取会话别名（可重复） |
| `--help, -h` | 帮助 |

所有诊断写 stderr；退出码 `0` 成功、`1` 运行错误、`2` 用法错误。

## 安全边界

| 能力 | 默认 | 打开方式 |
| --- | --- | --- |
| 物理 I2C/SPI/UART、非回环 HTTP/TCP、Shell | 关闭 | `--allow-hardware` |
| `proto=virt`、`virt-*`、`loop://`、回环 HTTP/TCP | 可用 | 无需开关 |

- 物理设备访问在 C++ HAL 的 `i2c_open`/`spi_open`/`uart_open`/`tcp_open`/`http_open`/`shell_open` 处统一门控。
- Lua 驱动仍是可信进程内代码，不是沙箱；`ffi` 仍然可用。
- 动作派发后的异常代表“结果未知”，不会自动重试或声称回滚。

## 架构

```text
Structure SQL (SQLite3 + DSL 归一化) → MatrixObject 表
        │
        ├── Lua 驱动（LuaJIT，modules/*.lua）
        └── 原生 C++ 驱动（Time/TCP/HTTP/Shell/Dev_enum/I2C_scan/LoopbackProbe）
        │
        └── C++ HAL（I2C/SPI/UART/TCP/HTTP/Shell）
```

- `src/sql_engine.cpp`：SQLite3 结构 SQL 加载器；`$var`、`$(expr)`、`-` 由归一化层保留为文本。
- `src/sqlparse.cpp`：旧 SQL4cj 解析器，仍服务热 SQL。
- `src/hal.cpp`：C++ HAL 与权限门。
- `src/luavar.cpp` / `src/luasandbox.cpp`：LuaJIT 驱动、`__hal_call` 注入、沙箱。
- `src/native_*.cpp` / `src/driver_*.cpp`：原生 C++ 驱动接口与实现。
- `src/action_runner.cpp`：MT 派发、`@if`/`@while`、`@Alias`/`@Vars` 块级作用域。
- `src/matrix.cpp`：MT 字符文法（含带引号单元格与 `@Action` compound body）。

## 当前范围与后续

已支持：

- 结构 SQL 的 SQLite3 解析/加载
- LuaJIT 驱动与 C++ HAL 桥
- `@Action` 内的 `@Alias`/`@Vars` 块级词法作用域
- `@if`/`@while` 嵌套与 compound `@Action`
- 新式 `@Reflex(name)` 命名反射（参数作用域隔离、可在 `@Action` 中按 `反射名.形参` 调用）
- `@Struct(name)` JSON 声明：字段/数组下标选择（`$(cfg.field)`、`$(cfg.items[0])`）与结构字段捕获
- MT 带引号单元格（引号内空格、`;`、`#` 不分格）
- 原生 Time/LoopbackProbe/Shell/HTTP/TCP/Dev_enum/I2C_scan 驱动

尚未移植：

- FTDI `ftdi://` I2C/SPI（当前只支持 `/dev/i2c-*`、`/dev/spidev*`、串口）
- 当前 Python 的子命令 `check/sample/query/apply-sql/assets/new/discover/doctor`
  （本项目按设计保留旧扁平 CLI）

## 目录

```text
src/                 C++ 控制器
modules/             Lua/原生驱动资产
robots/              结构 SQL
scripts/             动作脚本与开发脚本
test/cpp/            C++ 单测
test/                Lua 驱动回归
third_party/cli11/   vendored CLI11
docs/                历史文档（部分仍描述已移除的 agent/MCP）
```

## 许可证

[MIT](LICENSE)

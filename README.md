# pymybot

跨平台的 Python 机器人控制器：用 Lupa（LuaJIT）加载 Lua 硬件驱动，用 sqlparse 解析受限 SQL 结构文件，用 MT 动作脚本驱动设备。

兼容 bot4cj 的「模块 → 结构 → 动作」三层脚本模型，但不依赖原 C++ 运行器、TCP 服务或 MCP。

## 两种使用模式

pymybot 提供两种独立的使用方式，可按需选择或组合：

- **机器人智能体**：PydanticAI 驱动的交互式 AI 助手，通过自然语言控制机器人
- **机器人控制器**：直接执行 CLI 命令，无需模型依赖，适合自动化脚本和 CI/CD

---

## 机器人智能体

智能体模式使用 PydanticAI 将自然语言任务转换为机器人操作。支持 openai / openai-chat / anthropic / deepseek 四种模型提供商，密钥只经环境变量传入。

### 快速开始

**1. 安装智能体依赖**

```sh
python -m venv .venv
.venv/bin/pip install -e ".[agent,test]"
```

**2. 配置模型与密钥**

```sh
# 选择模型（四选一）
export MYBOT_MODEL="deepseek:deepseek-chat"
# export MYBOT_MODEL="openai:gpt-4o"
# export MYBOT_MODEL="openai-chat:gpt-4o"
# export MYBOT_MODEL="anthropic:claude-sonnet-4-5"

# 对应厂商的 API Key
export DEEPSEEK_API_KEY="sk-..."
# export OPENAI_API_KEY="sk-..."
# export ANTHROPIC_API_KEY="sk-ant-..."
```

**3. 运行智能体**

```sh
# 一次性任务
.venv/bin/python -m pymybot --robot robots/relay-test.sql \
  --task "列出硬件和可用动作脚本"

# 交互会话（/exit 退出）
.venv/bin/python -m pymybot --robot robots/relay-test.sql
```

不带子命令的 `--robot` 入口默认进智能体模式，也可显式写 `agent` 子命令。`--no-agent` 可让 agent 入口绕过模型直接执行脚本（需配合 `--input`）。

### 工具集与能力

第一版智能体提供 4 个默认工具：

- `list_hardware`：列出声明的硬件及元数据
- `list_action_scripts`：列出可用 `.mt` 动作脚本
- `query_sql`：查询结构文件（`SHOW TABLES;` 或 `SELECT * FROM 表;`）
- `run_action_script`：执行动作脚本；脚本内捕获的图片以二进制附件返回，回执用 `image_index` 标注对应关系，单次动作最多附带 16 张，超出部分在回执中标记为 `image_omitted`

通过重复 `--read-var NAME` 开放指定变量读取，通过重复 `--camera-var NAME` 开放一个或多个 Camera 变量的图片输入。

**参考技能**：`skills/` 目录下的每个技能是一个目录（`SKILL.md` + 可选 markdown 参考资料），
属操作者信任内容。存在技能时，智能体获得 `list_skills` / `read_skill(name, file)` 两个只读工具，
技能名与摘要进入系统提示词，正文按需查阅（如内置的 `pymybot-scripting` 三层脚本开发参考）。
`--skills-dir DIR` 显式指定信任根（不存在即报错）；缺省依次取打包资产 `assets/skills` 或源码 `skills/`。

`run_action_script` 仅执行 `--scripts-dir`（默认内置 scripts）下已有的相对 `.mt` 路径。默认不开启文件和 shell 工具，也不能热更新 SQL。文件图片仍需 `--camera-src-dir`，来源由 Camera 的结构配置决定。

**文件与 shell 工具（显式启用）**：

- `--workspace-dir DIR`：开放 `list_files(path=".")`、`read_file(path, offset=1, limit=200)`、`write_file(path, content, overwrite=False)`、`edit_file(path, old_string, new_string, replace_all=False)`。
- 文件路径必须相对工作目录，拒绝路径穿越、符号链接和非普通文件；UTF-8 文本最大 1 MiB。列目录不递归，读取按行分页；创建文件需要父目录已存在，覆盖需显式 `overwrite=True`，精确编辑默认要求唯一匹配。文件读取内容可能发送给模型，请选择不含凭据的目录。
- `--enable-shell`：在已指定工作目录时开放 `shell(command, cwd=".")`，支持平台 shell 语法（POSIX 为 `/bin/sh -c`，Windows 为 `cmd.exe /c`，后者只接受单行命令），返回退出码、标准输出、标准错误、截断标记及使用的解释器路径；非零退出码表示失败但不代表未执行。
- `--allow-shell`：预授权宿主 shell 命令（需先 `--enable-shell`），跳过每次执行的确认提示；命令继承宿主用户权限和环境，请谨慎使用。
- 文件创建/编辑和 shell 执行分别请求确认；`--allow-file-writes`、`--allow-shell` 分别预授权，`--allow-actions` 不授权这两类操作。非交互模式未预授权时拒绝调用。

```sh
# 交互使用文件和 shell 工具，每次写入/执行都确认
.venv/bin/python -m pymybot --robot robots/relay-test.sql \
  --workspace-dir . --enable-shell

# 非交互只读文件任务，不启用 shell 或预授权写入
.venv/bin/python -m pymybot --robot robots/relay-test.sql \
  --workspace-dir . --task "读取并解释 scripts 目录中的动作脚本"
```

**Shell 不是沙箱**：工作目录只决定初始 cwd，不能阻止命令访问目录外文件、网络、环境变量或物理设备，`--allow-hardware` 也不能约束 shell。命令继承宿主用户权限和环境；只在可信环境启用，不支持后台任务。超时/取消会终止进程并尝试清理子进程，但不是操作系统隔离，也不撤销已发生的副作用。文件写入若修改脚本、驱动或技能，会影响后续执行的信任边界；修改 SQL 文件不会重载当前 Robot，需重启会话。

### 安全机制

**独立安全开关**：

| 开关 | 作用 | 默认 |
| --- | --- | --- |
| `--allow-actions` | 预授权脚本执行/变量读取/拍照 | 否 |
| `--allow-hardware` | 开放 Robot/HAL 的物理设备访问（不能限制 shell） | 否 |
| `--allow-file-writes` | 预授权工作目录文件创建/编辑 | 否 |
| `--allow-shell` | 预授权宿主 shell 命令 | 否 |

脚本执行、读取和拍照都会请求确认，因为激活和读取也可能写硬件。非交互任务不能弹出确认，默认拒绝这些调用；操作者可显式 `--allow-actions` 预先授权该会话中的这些工具。

**不要对不可信脚本预授权。**

### 预算控制

| 参数 | 作用 | 默认 |
| --- | --- | --- |
| `--max-requests N` | 每任务模型请求上限 | 8 |
| `--max-tool-calls N` | 每任务工具调用上限 | 16 |
| `--timeout SECONDS` | 每任务墙钟预算 | 180 |

Robot 创建、工具调用和销毁在同一专用线程串行执行；动作已开始后的异常锁存为结果不明，拒绝后续工具派发，不自动重试或声称回滚。取消/超时停止模型及新派发，但无法强杀阻塞的原生 I/O；清理需等待已下发调用退出，不是物理急停。

交互历史按完整轮次裁剪（最多 6 轮、4 MiB），避免孤立工具回执。最终 JSON 的 `tool_events` 仅记录工具名与执行状态，不保存参数、密钥或图片。此版不提供跨进程常驻后端、会话落盘恢复、ICA 或持久化审计日志；agent 退出时会清理同进程 Robot，不能自动恢复未完成动作。

### 流式输出

回合进行期间，模型回复文本以增量实时写入 stderr，每次工具调用开始/结束各输出一行进度（`→ 工具名(参数摘要)` / `⇦ 工具名 状态`）；工具参数经转义并截断显示，防止终端控制序列注入。stdout 契约不变：整个回合结束后仍只输出一行最终 JSON，程序化调用方不受影响。超时/取消看护在流式期间保持不变（50ms 协作检查）。

### 端点配置

`--base-url`（或 `MYBOT_BASE_URL`）支持自定义端点，要求 HTTPS；本地回环服务允许 HTTP。地址中禁止凭据、查询参数和 fragment。兼容端点也需要配置 API Key 环境变量，本地无认证服务可使用非秘密占位值。

可用 `--api-key-env NAME` 指定其他环境变量存储 API Key，命令行不直接接收密钥。

各模型的工具调用和视觉能力不保证相同，需在部署时验证；默认 SDK 自动重试关闭。

---

## 机器人控制器

控制器模式直接执行 CLI 命令，不需要模型配置或 agent 依赖。适合自动化脚本、CI/CD 流水线和无交互环境。

### 快速开始

**1. 安装基础依赖**

```sh
python -m venv .venv
.venv/bin/pip install -e ".[test]"
```

**2. 验证安装**

```sh
.venv/bin/python -c "from lupa.luajit21 import LuaRuntime; import sqlparse, serial, pyftdi, PIL"
.venv/bin/python -m pytest
```

**3. 运行示例**

```sh
# 静态检查
.venv/bin/python -m pymybot check --robot robots/relay-test.sql --input scripts/relay-test.mt

# 执行动作（虚拟总线，不接触硬件）
.venv/bin/python -m pymybot run --robot robots/relay-test.sql --input scripts/relay-test.mt --timeout 10
```

输出：

```json
{"ok":true,"command":"run","outputs":[{"slept":1,"result":"OK"}]}
```

### CLI 命令

| 命令 | 是否激活驱动 | 说明 |
| --- | --- | --- |
| `check --robot SQL [--input MT]` | 否 | 静态检查 SQL、模块存在性、引用及 MT/Include 语法 |
| `hardware --robot SQL` | 否 | 列出声明的硬件及元数据 |
| `scripts [--scripts-dir DIR]` | 否 | 列出 `.mt` 脚本 |
| `query --robot SQL --sql "..."` | 否 | `SHOW TABLES;` 或 `SELECT * FROM 表 [WHERE ...];` |
| `run --robot SQL --input MT` | 是 | 激活、执行动作、清理 |
| `sample --robot SQL --name VAR` | 是 | 激活并读取命名变量，支持 `--count` / `--interval-ms` |
| `apply-sql --robot SQL --sql "..."` | 是 | 对临时激活的会话应用受限 SQL，不改磁盘文件 |

`--sql` 采用严格语法：每条语句都必须以 `;` 结尾，单条语句也不例外，否则报 `SQL: unexpected end of script`。

通用选项：`--module-path DIR`（可重复，显式指定时须同时包含 `modules`）、`--camera-src-dir DIR`、`--timeout SECONDS`、`--var NAME=VALUE`、`--allow-hardware`。

退出码：0 成功，1 运行错误，2 用法错误，130 被中断。

### 三层脚本模型

pymybot 使用「模块 → 结构 → 动作」三层脚本：

#### 结构文件（SQL）

每张普通表对应 `modules/<表名>.lua`，每个 INSERT 行创建一个变量。`$变量` 引用先前声明的总线，`-` 继承上一行同列。

```sql
CREATE TABLE UART (name String, path String, baud Number);
INSERT INTO UART (name, path, baud) VALUES ('bus', 'loop://', 115200);
CREATE TABLE LoopbackProbe (name String, UART String);
INSERT INTO LoopbackProbe (name, UART) VALUES ('echo', '$bus');
```

#### 动作脚本（MT）

`@Action` 起始、单独 `@` 结束；表头为 `变量.参数`，每数据行是一帧。

```mt
@Action
echo.value;
         0;
       127;
@
```

支持 `@Alias`、`@Vars`、`@if(...)`、`@while(...)`、`$(表达式)`、`capture` 捕获结果和 Include 片段复用。

#### 驱动模块（Lua）

```lua
local mpath = assert(__mpath)
dofile(mpath.resolve("lib/drv_common.lua"))

require_driver("uart", {
    name = "LoopbackProbe",
    build = function(ctx, data) return {result = "OK"} end,
    call = function(ctx, data)
        if uart_write(ctx.fd, {tonumber(data.value)}) ~= 1 then return err("short write") end
        local reply = uart_read(ctx.fd, 1, 200)
        if reply == nil or #reply ~= 1 then return err("read failed") end
        return {result = "OK", rx = reply[1]}
    end,
})
```

`build` / `call` / `destroy` 返回非空表，推荐 `{result="OK", ...}` 或 `err("原因")`；可选 `read(data)` 提供快照。

### 在项目外目录使用

`--robot` / `--input` 可以指向任意位置的文件，例如把驱动、结构和动作放在 `~/robots/<任务>/{modules,robots,scripts}`。显式 `--module-path` 会替换默认搜索路径，因此必须同时给出自定义目录和基础目录：

```sh
cd ~/robots/<任务>
pymybot run --robot robots/<任务>.sql --input scripts/<任务>.mt \
  --module-path modules --module-path /path/to/pymybot/modules --timeout 10
```

也可以用环境变量 `BOT4CJ_MODULE_PATH`（按系统路径分隔符连接多个目录）代替重复的 `--module-path`。`@Include` 只能引用动作脚本所在目录内的文件，`--camera-src-dir` 只允许读取该目录内的图片。

---

## 通用部分

### 特性

- **双模式入口**：智能体模式（PydanticAI）与控制器模式（直接 CLI）独立可选
- **三层脚本**：`modules/*.lua` 驱动、`robots/*.sql` 结构、`scripts/*.mt` 动作，一一对应
- **默认安全**：静态命令不激活驱动；`run` / `sample` / `apply-sql` 默认只允许虚拟总线、串口回环或图片文件，必须显式 `--allow-hardware` 才打开物理设备
- **跨平台 HAL**：UART 走 pyserial，I2C/SPI 走 pyftdi（MPSSE），Camera 采集走 PyAV（可选）、图片编解码走 Pillow；Linux 可选 smbus2/spidev
- **无硬件验证**：内置虚拟总线（`virtbus`）、寄存器映射模型、串口 `loop://` 回环，支持 NACK / 超时 / 短读等故障注入
- **后台采样**：Daemon 表基于 Python 线程和独立 Lua 状态做周期采样，支持单设备、多设备同总线和聚合
- **预置芯片驱动**：自带 45 个真实器件驱动（自 C++/Rust 版迁移，I2C/SPI/UART 三族），多数内嵌虚拟器件模型，无硬件即可端到端验证；未迁移的 GPIO / PWM / Speaker / Sim 及 V4L2 Camera 见下文说明

### 目录结构

```
pymybot/                  Python 包：CLI、SQL 解析、动作执行、HAL、Daemon、智能体
modules/                  Lua 基础资源与公共库
  I2C.lua SPI.lua UART.lua Camera.lua     四种基础总线/设备资源
  Timer.lua Relay.lua dummy.lua           纯软件模块（Relay 仅转发参数，非物理继电器）
  Ema.lua Kalman.lua Monitor.lua          滤波与监视
  bitcompat.lua                           LuaJIT 5.1 位运算兼容层
  lib/drv_common.lua lib/HAL.lua          驱动框架与 HAL 桥接
  lib/bus_contract.lua                    总线参数与引用契约
  lib/sensor_daemon*.lua sensor_aggregate.lua  采样 chunk
  lib/virtbus.lua lib/virtbus/regmap.lua  虚拟总线与寄存器模型
  <芯片驱动>.lua                          45 个真实器件驱动（见下）
robots/                   SQL 结构文件（示例：relay-test.sql）
scripts/                  MT 动作脚本（示例：relay-test.mt）
skills/                   智能体参考技能（SKILL.md + references；示例：pymybot-scripting）
docs/                     补充文档（如 Windows faulthandler 说明）
tests/                    pytest 测试（fixtures/virt/ 为逐驱动无硬件端到端夹具）
```

#### 预置芯片驱动（45 个，自 C++/Rust 版 mybot 迁移）

| 总线 | 数量 | 驱动 |
| --- | --- | --- |
| I2C | 36 | ADS1015、ADS1115、ADXL345、AMG8833、APDS9900、AS3935、AS7262、BH1745、BH1750、BME280、BME688、BMI270、BMM150、CHT8305、EMC2101、INA219、INA226、INA3221、LCD1206、LPS22HB、LSM6DSV、LTC2944、MAX17043、MAX17048、MAX30102、MCP3421、MCP4725、MLX90393、MPU6050、MS5611、PCA9685、PCF8574、SGP30、SHT3X、VL53L0X、VL53L4CD |
| SPI | 4 | AD9833、ADS1256、MT6826S、TPL0501 |
| UART | 3 | MHZ19、SCSCL、SDS011 |
| 控制器链 | 2 | Servo（经 controller 引用舵机控制板）、H03ARR（电机驱动） |

其中 43 个内嵌 `<驱动>_VIRT` 虚拟器件模型：结构脚本声明 `proto='virt'` 即可在无硬件下跑真实驱动的 build/call/destroy 全链路，`tests/fixtures/virt/` 为其中 40 个提供逐驱动端到端夹具（SQL + 动作脚本，与 C++ 版测试同源）。依赖原生 GPIO/PWM/ALSA/V4L2 或仿真器后端的 GPIO、PWM、Speaker、Sim 及旧版 Camera 驱动未迁移——可移植 HAL 不提供这些后端，相关调用会响亮报错而非静默降级。

### 安装

要求 Python 3.11+。

```sh
python -m venv .venv
# Linux/macOS
.venv/bin/pip install -e ".[test]"
# Windows
.venv\Scripts\pip install -e ".[test]"
```

Linux 上需要原生 `/dev/i2c-*` / `/dev/spidev*` 时追加 `.[linux]`；需要从物理摄像头采集时追加 `.[camera]`（PyAV，自带 FFmpeg，约 30 MB）。只用文件图片源不需要它。安装后可用 `pymybot` 命令或 `python -m pymybot`。

启用智能体时，在虚拟环境内安装 `python -m pip install -e ".[agent,test]"`。仅直接执行可继续使用基础安装，不需要 PydanticAI、模型 API Key 或模型网络请求。智能体依赖锁定为已验证接口版本；缺少依赖时明确报错，不静默降级。

验证依赖：

```sh
.venv/bin/python -c "from lupa.luajit21 import LuaRuntime; import sqlparse, serial, pyftdi, PIL"
.venv/bin/python -m pytest
```

### 平台说明

- UART：pyserial；Windows 使用确认过的 `COMn`，`loop://` 为无硬件回环
- I2C/SPI：pyftdi；需要支持 MPSSE 的 FTDI 适配器和 libusb 驱动，地址形如 `ftdi://ftdi:232h/1`，SPI 可带 `?cs=0`
- `/dev/i2c-*`、`/dev/spidev*`：仅 Linux，依赖可选 smbus2/spidev
- Camera：物理设备经 PyAV（`.[camera]`）采集，Windows 走 DirectShow（设备序号按枚举顺序映射）、Linux 走 V4L2（序号或 `/dev/videoN`）、macOS 走 AVFoundation（需 macOS 14+，固定 30 fps）；`width`/`height` 必须是摄像头支持的模式，否则打开失败而不是静默改用其他分辨率；文件输入由 Pillow 完整解码校验，必须指定 `--camera-src-dir`
- 不提供 GPIO/PWM/Speaker 原生后端；相应外设通过受支持总线编写协议实现
- Lua 指令预算和可取消等待不能中断阻塞的原生库调用；进程退出不等于执行器物理急停
- Windows：LuaJIT 以 SEH 异常（`0xE24C4A02`）抛出每个 Lua 错误，CPython faulthandler 会误判为崩溃并可能导致进程段错误，因此 CLI 在 Windows 上会关闭 `-X faulthandler` / `PYTHONFAULTHANDLER`（stderr 提示一行），测试套件同样在 Windows 上关闭 pytest 的 faulthandler
- 输出编码：stdout（JSON）与 stderr（诊断）固定为 UTF-8，不随控制台或管道的本地代码页（如 Windows 中文系统的 GBK）变化；调用方应按 UTF-8 解码两路输出

### 安全边界

- 只执行已审阅且可信的 Lua。Lupa 使用 LuaJIT 2.1，FFI 可用；路径与属性限制不是恶意代码隔离
- `active` / `build` / `destroy` 以及 `sample` 都可能写硬件：初始化会配置器件，`read` 可能回退到驱动 `call`
- 不把真实路径静默替换为虚拟路径，不把合成数据报告为真实测量；虚拟和真机使用分别命名的 SQL
- 结构文件、动作脚本和 SQL 文本上限 8 MiB，结果体同样受限

### 构建

```sh
.venv/bin/pip install build
.venv/bin/python -m build
```

`build_support.py` 会把 `modules/` `robots/` `scripts/` 复制到包内 `pymybot/assets/`，安装后无需源目录即可运行。

### 许可

[MIT](LICENSE)

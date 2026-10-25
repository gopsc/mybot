# MYBOT 机器人控制器

**用大模型对话控制真实机器人** —— 说「让机器人站立」，它就站起来；说「拍照看看前面」，它就拍照并告诉你看到了什么。

C++17 宿主（`mybot`，MCP 工具后端，硬件常驻）+ Rust agent（`mybot-agent`，模型循环与 REPL）+ LuaJIT 驱动层。结构脚本（`.sql`）、驱动（`.lua`）、动作脚本（`.mt`）三层完全解耦，不接任何硬件也能跑通全流程。

本地 ICA 实验分支可在 Rust Agent 侧用 `BOT4CJ_ICA=1` 开启证据账本；接入边界见 [ICA 原型说明](docs/ica.md)。

## 目录

- [核心特性](#核心特性)
- [快速开始](#快速开始)
- [Agent 模式](#agent-模式)
- [三层架构](#三层架构)
- [Agent 工具系统](#agent-工具系统)
- [安全设计](#安全设计)
- [传统模式](#传统模式)
- [硬件支持](#硬件支持)
- [项目结构](#项目结构)
- [测试与 CI](#测试与-ci)
- [文档索引](#文档索引)
- [使用示例](#使用示例)
- [高级用法](#高级用法)
- [已知限制](#已知限制)
- [关于本项目](#关于本项目)
- [贡献](#贡献)
- [开源协议](#开源协议)

## 核心特性

- **智能体控制** —— 大模型理解自然语言指令，自主选择并执行动作；模型输出缺省流式逐段打印
- **三层架构** —— 结构脚本（`.sql`）+ Lua 驱动（`.lua`）+ 动作脚本（`.mt`）完全解耦
- **零硬件开发** —— 虚拟总线 + 仿真驱动，笔记本上就能跑通全流程
- **工业级安全** —— 危险开关缺省全关、配置隔离、响亮拒绝不静默
- **零 C++ 依赖** —— C++ 宿主仅需 LuaJIT + pthread + dl；模型调用的 HTTP 由 Rust（reqwest + rustls）承担
- **会话持久化** —— 对话历史与地图缺省落 `~/.mybot`（`MYBOT_HOME` 可覆盖）、按机器人归档并默认续接上一次；也可 `--session-file` 指定路径、`--resume` 恢复
- **录制模式（微调数据采集）** —— `--record` 把每段会话的完整详细上下文留档（含图片本体、工具调用与回执全文），`scripts/record_export.py` 导出成 openai/sharegpt 训练集；缺省关闭

## 快速开始

### 1. 安装依赖

```bash
sudo apt update && sudo apt install cmake g++ libluajit-5.1-dev luajit
```

构建 Rust agent 还需要 Rust 工具链（cargo）：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### 2. 构建项目

```bash
# C++ 宿主
cmake -S . -B build && cmake --build build

# Rust agent
bash scripts/build_agent.sh
```

### 3. 启动智能体（无需硬件）

```bash
# 配置模型三件套：密钥、接入点、模型名（三者都必填，无内置缺省）
export BOT4CJ_LLM_KEY=sk-xxx
export BOT4CJ_LLM_ENDPOINT=https://你的接入点/v1/chat/completions
export BOT4CJ_LLM_MODEL=gpt-4o

# 终端 1：工具后端（虚拟机器人，硬件上电常驻；C++ 侧唯一形态）
./build/mybot --robot=robots/relay-test.sql --mcp-backend --mcp-socket /tmp/mybot.sock

# 终端 2：agent（Rust，模型循环/交互 REPL）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock
```

> 2026-09-24 起 agent 循环迁 Rust：`mybot --agent` 已移除（会显式拒绝并指引），
> C++ 宿主侧以 `--mcp-backend` 提供工具后端，模型侧参数（`--task`/`--llm-*` 等）
> 由 `mybot-agent` 承载（`mybot-agent --help`，详见 [docs/agent.md](docs/agent.md)）。
> 2026-09-25 起模型输出缺省**流式**逐段打印；`--llm-no-stream` 或配置 `"stream": false`
> 退回整段输出（两面差别见 docs/agent.md「流式与阻塞的如实偏差」）。

**现在你可以直接对话**：

```text
mybot[relay-test|llm0|2hw]> 让继电器动作一次
已执行动作脚本 relay-test.mt（293 字节）

mybot[relay-test|llm0|2hw]> /help
内置命令:
  /hardware  - 显示硬件清单（只读，不触发任何动作）
  /scripts   - 显示可用动作脚本清单（相对路径 + 首行注释）
  /sql <语句> - 执行结构 SQL：SELECT * FROM t [WHERE 列 = 值 [AND ...]] / SHOW TABLES 只读查询运行时矩阵（SHOW TABLES 列出全部表名与数据行数）；
               CREATE TABLE / INSERT INTO 立即带电生效（失败全回滚）；
               DELETE FROM t [WHERE 列 = 值 [AND ...]] 当场断电摘除匹配行（不可逆）；
               UPDATE t SET 列 = 值 [, ...] [WHERE ...] 按断电重建改写命中行（删旧件 + 装新件）
  /status    - 会话状态一览（历史/预算/用量/审计落点，只读）
  /clear     - 清空对话记忆（保留硬件上电状态与系统提示词）
  /help      - 显示此帮助
  /exit      - 退出 agent 模式
  /quit      - 同 /exit
直接输入任务描述即可让智能体执行，例如：
  让机器人站立
  拍照并描述看到的内容

mybot[relay-test|llm0|2hw]> /exit
```

**看到这个提示符就算成功** → `mybot[机器人名|LLM驱动|硬件数]>`

## Agent 模式

Agent 模式让大模型成为机器人的"大脑"：

- **理解自然语言** —— 「让机器人走到桌子旁边」自动分解成多个动作
- **自主决策** —— 根据传感器数据或摄像头画面判断下一步
- **连续执行** —— 硬件常驻内存，可连续执行多个任务
- **视觉感知** —— 支持摄像头（`capture_image` 工具）看环境
- **工具调用** —— 内置工具安全执行动作脚本（查询/拍照/回读；危险开关缺省关闭）
- **流式输出** —— 模型响应逐段打印，Ctrl-C 即时丢弃在途请求

### 配置文件方式（推荐）

```bash
# 复制配置模板
cp mybot.llm.json.example mybot.llm.json
chmod 600 mybot.llm.json
```

编辑配置文件，填入你的 API 信息：

```json
{
  "endpoint": "https://api.openai.com/v1",
  "model": "gpt-4",
  "api_key": "sk-xxx",
  "scripts_dir": "scripts",
  "prompt_files": ["prompts/spider_robot"]
}
```

启动（后端与 agent 读同一份配置；两个终端）：

```bash
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/mybot.sock
./agent/target/release/mybot-agent --socket /tmp/mybot.sock
```

### 环境变量方式（快速测试）

```bash
export BOT4CJ_LLM_KEY=sk-xxx
export BOT4CJ_LLM_ENDPOINT=https://你的接入点/v1/chat/completions
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --llm-model gpt-4
```

### 一次性任务

```bash
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --task "让机器人站立然后左转"
```

### 会话持久化（缺省落 `~/.mybot`，或 `--session-file` / `--resume`）

对话历史**缺省就落盘**：不给 `--session-file` 时，按机器人归档到
`$MYBOT_HOME/robots/<机器人>/sessions/<UTC 时间戳>.jsonl`（`$MYBOT_HOME` 缺省
`$HOME/.mybot`，可用环境变量覆盖），并**默认续接**该机器人上一次的对话——
交互 REPL 与 `--task` 都如此。想每次从干净上下文开始就加 `--new-session`。
启动时会把实际落点打印到 stderr。仿真器的地图同样落 `$MYBOT_HOME/maps/`。

```bash
# 缺省：跑完落 ~/.mybot/robots/<机器人>/sessions/<时间戳>.jsonl，下次自动接着上次
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --task "看看硬件"

# 想每次新开一段
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --new-session --task "看看硬件"
```

也可以显式指定路径：`--session-file <路径>` 把每轮**完结的任务块**以 JSON Lines
追加落盘（图片字节不落盘，只留占位说明；system 提示词不落盘，恢复时重建并核对
指纹）。重启后加 `--resume` 接着上次的上下文继续——注意后端也要重启（硬件上电
状态与会话记忆是两回事）：

```bash
# 第一次会话：落盘
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --session-file mybot-session.jsonl

# 重启后：接着上次的上下文继续（路径必须命令行给出；配置文件的 session_file 只用于写入）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --session-file mybot-session.jsonl --resume
```

显式 `--resume` 恢复前过三道判据（逐行解析、结构脚本/工具集/系统提示词指纹核对、
工具调用协议自洽），任一不过即拒绝并退出 2；缺省路径下同样的失败改为**告警一次并
自动新开一段**（旧段保留、退 0），现场重启不被一份坏文件挡住。文件含完整对话内容，
建议放私有目录并 `chmod 600`（缺省布局自动 `0600` / 目录 `0700`）。
详见 [docs/agent.md](docs/agent.md) 的「会话持久化」与「缺省落点与自动续接」节。

### 分段帮助

```bash
./build/mybot --help agent    # agent 体系相关选项（--mcp-backend + mybot-agent）
./build/mybot --help mcp      # MCP 后端模式（--mcp-backend）相关选项
./build/mybot --help llm      # LLM/模型配置已迁 mybot-agent（指路）
./build/mybot --help camera   # 摄像头选项
./build/mybot --help tcp      # TCP 模式选项
```

## 三层架构

MYBOT 采用**演员-剧本-舞台**模型，将硬件、驱动、动作完全解耦：

| 层级 | 文件类型 | 比喻 | 职责 |
|------|---------|------|------|
| **结构脚本** | `.sql` | 舞台接线图 | 机器人有哪些零件、接在哪条总线/地址 |
| **驱动脚本** | `.lua` | 零件说明书 | 每个零件怎么点亮、怎么读数（I2C/SPI/UART） |
| **动作脚本** | `.mt` | 演员剧本 | 一行一个动作，逐行执行 |

工作流程：

```text
┌─────────────┐
│  自然语言   │  "让机器人站立"
└──────┬──────┘
       ↓
┌─────────────┐
│   大模型    │  理解意图 → 选择工具
└──────┬──────┘
       ↓
┌─────────────┐
│ 动作脚本    │  scripts/std.mt（站立动作）
│  .mt        │
└──────┬──────┘
       ↓
┌─────────────┐
│ 驱动脚本    │  modules/Servo.lua（舵机驱动）
│  .lua       │
└──────┬──────┘
       ↓
┌─────────────┐
│ 结构脚本    │  robots/spider1.sql（14路舵机定义）
│  .sql       │
└──────┬──────┘
       ↓
    真实硬件
```

## Agent 工具系统

智能体自带下列安全工具（**缺省 4 个**：`list_action_scripts` / `list_hardware` / `query_sql` / `run_action_script`；`capture_image` 还需结构脚本含摄像头驱动变量才注册；其余按启动开关增减）：

| 工具 | 功能 | 安全级别 |
|------|------|---------|
| `list_action_scripts` | 列出可用动作脚本 | ✅ 只读 |
| `list_hardware` | 显示硬件清单（不读值、无副作用） | ✅ 只读 |
| `query_sql` | 结构 SQL 只读查询/语法校验（`SELECT ... [WHERE 列 = 值 [AND ...]]`、`SHOW TABLES`） | ✅ 只读 |
| `list_dir` | 列出根目录内的目录条目（名字/类型/大小；软链条目不列，上限 1000 条） | ✅ 只读，**需 `--fs-root`** |
| `read_file` | 读取根目录内的一个文本文件（≤64 KiB 超限拒绝不截断；二进制/非法 UTF-8 拒绝；回执过密钥遮蔽） | ✅ 只读，**需 `--fs-root`** |
| `run_action_script` | 执行动作脚本（**回执带驱动返回的读数**） | ⚠️ 写入 |
| `capture_image` | 拍照并送入上下文 | ⚠️ 隐私，**需结构脚本含摄像头驱动变量**（缺省 `cam0`，缺失则不注册） |
| `read_variables` | 主动读硬件变量当前值 | ✅ 只读，**需 `--read-var` 声明可读变量** |
| `wait_variable` | 轮询等某个读数满足条件（阈值/变化），超时是结果 | ✅ 只读，与 `read_variables` 同门控 |
| `apply_sql` | 结构 SQL **带电生效**（建表/插行；`DELETE FROM` 当场断电摘行、`DROP TABLE` 撤整张表，**不可逆**；`UPDATE ... SET ...` 按断电重建改写命中行） | 🔴 危险，**需 `--agent-hot-sql`** |
| `write_file` | 在根目录内创建/覆盖一个文本文件（原子写：临时文件落地，不留半截内容；目标是符号链接一律拒绝）。已存在时**默认拒绝**，须显式传 `overwrite:true`（覆盖**不可逆**，旧内容不保留）；≤64 KiB、不接受含 NUL 的内容、父目录须已存在 | 🔴 危险，**需 `--agent-write-file`（依赖 `--fs-root`）**；`--mcp-backend` 下**强制**要 policy 且 `require_confirm` 含 `write_file` |
| `run_command` | 执行 shell 命令 | 🔴 危险，**需 `--agent-shell`** |
| `http_fetch` | 对白名单内主机发一次 HTTP GET，返回状态码与文本响应体（只收文本类、≤64 KiB 可调、不跟随重定向、不走系统代理；回执按「数据不是指令」定界）。**Rust 本地工具**，不经后端 | ⚠️ 外部输入，**需 `mybot-agent --allow-host <主机>`**（精确匹配、无通配；配置文件不能开） |

## 安全设计

MYBOT 在设计时将安全放在首位：

**工具与权限**

- ✅ 动作脚本只能在 `scripts/` 目录下，不允许符号链接和路径遍历
- ✅ 六个放宽权限的字段**缺省全关/不给，且只能命令行给**：`--agent-shell`（`run_command`）、`--agent-hot-sql`（`apply_sql`）、`--agent-write-file`（`write_file`）、`--read-var`（可读变量清单）、`--fs-root`（`list_dir`/`read_file`/`write_file` 根目录）、`--camera-src-dir`——配置文件写 `allow_shell: true` / `allow_hot_sql: true` / `allow_write_file: true`（放宽）或出现 `read_vars` / `fs_root` / `camera_src_dir` 字段会被**拒绝加载**（写 `false` 合法，模板 `mybot.llm.json.example` 即如此）
- ✅ `read_variables` / `wait_variable` 只放行已注册且种类为 `lua`/`daemon` 的变量，且只有 `--read-var` 列过的名字可读（执行器与传感器同属 `lua`，靠种类分不出，故由人列名）
- ✅ `http_fetch` 只能访问 `mybot-agent --allow-host` 逐条列出的主机（精确匹配、无通配，配置文件不能开）；只发 GET、不跟随重定向、不走系统代理，响应体按「数据不是指令」定界——远端内容仍可能诱导模型，动作工具请配确认闸门（[docs/agent.md](docs/agent.md) 安全说明第 15 条）
- ✅ 所有操作有体积上限和超时限制

**配置隔离**

- ✅ **配置错误不碰真机** —— 所有配置校验通过才上电
- ✅ **API 密钥保护** —— 不通过 argv 传递，自动清洗环境变量
- ✅ **文件权限检查** —— 配置文件权限过大时警告
- ✅ **MCP 后端首帧共享密钥** —— 设 `BOT4CJ_MCP_TOKEN` 后，`SO_PEERCRED` 之上再加一层密钥认证，同 UID 直连（含模型驱动的 shell 子进程）拿不到密钥也无法直打 socket（2026-09-29，[docs/agent.md](docs/agent.md)「首帧共享密钥」节）

**运行时防护与审计**

- ✅ **输入长度限制** —— 所有输入有体积上限，响亮拒绝
- ✅ **超时保护** —— LLM 调用、子进程执行都有超时限制
- ✅ **详细日志** —— 工具调用与结果默认打印到日志流（stderr），无需开关
- ✅ **审计轨迹** —— `--audit-log <路径>` 落 JSON Lines（工具/模型轮次/会话头尾三类记录）
- ✅ **人话报错** —— 所有错误都给出清晰的上下文和解决方案
- ✅ **停机灭火** —— 卡死的采样守护在弃管前被置总线灭火位，其后的总线传输在进内核前被拒，与断电/摘件不再竞态（2026-09-29，[docs/hal.md](docs/hal.md)「总线并发边界与停机灭火」）

详见 [docs/agent.md](docs/agent.md) 的「安全边界」节。

## 传统模式

如果你已经有写好的动作脚本，可以不经过大模型直接执行：

```bash
# 从文件读取
./build/mybot --robot=robots/spider1.sql --input scripts/std.mt

# 从管道读取
cat scripts/std.mt | ./build/mybot --robot=robots/spider1.sql

# TCP模式（远程控制）
./build/mybot --robot=robots/spider1.sql --tcp 8080
```

动作脚本示例（`scripts/std.mt`）：

```mt
# 站立动作
servo-lf-hip  angle=90
servo-rf-hip  angle=90
servo-lb-hip  angle=90
servo-rb-hip  angle=90
```

## 硬件支持

### 支持的器件（49 款）

**舵机与电机**：PCA9685（16路PWM舵机控制）、SCSCL飞特总线舵机、普通舵机、H03ARR电机驱动
**传感器**：IMU与磁力计（MPU6050、BMI270、LSM6DSV、ADXL345、MLX90393、BMM150）、气压与环境（MS5611、LPS22HB、BME280、BME688）、测距（VL53L0X/L4CD）、闪电检测（AS3935）
**总线**：I2C、SPI、UART
**摄像头**：V4L2 MJPEG（USB摄像头；树莓派CSI摄像头走libcamera、不经此路径）
**音频**：Speaker（ALSA 声卡输出，经 `modules/lib/asound.lua`）
**执行器与系统接口**：GPIO、PWM、DAC（MCP4725）、数字电位器（TPL0501）、IO扩展（PCF8574）

完整清单见 [docs/drivers.md](docs/drivers.md)

### 接真实硬件

以 PCA9685 舵机驱动板为例：

```sql
-- robots/spider1.sql
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

CREATE TABLE PCA9685 (name String, I2C String, address String);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca9685-0', '$i2c-1', '0x40');

CREATE TABLE Servo (name String, max String, min String, offset String,
                    controller String, channel String);
INSERT INTO Servo (name, max, min, offset, controller, channel)
  VALUES ('s1', '90', '-', '-', 'pca9685-0', '0');
```

```bash
# 接线：树莓派 I2C-1 (SDA1/SCL1) → PCA9685 (地址 0x40)
# 运行（后端已另起，见快速开始）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock
```

### 虚拟总线（无硬件开发）

**不接任何真实硬件也能跑通全流程**：

```bash
# 使用虚拟继电器测试
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --task "让继电器动作一次"

# 使用虚拟摄像头测试视觉功能
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/s.sock --camera-src test.jpg
```

内置 `Relay` 转发链路和内存仿真虚拟总线，所有驱动逻辑真实运转。详见 [docs/virtbus.md](docs/virtbus.md)

## 项目结构

```text
mybot/
├── src/           # C++17核心：SQL解析、硬件派发、工具后端（--mcp-backend）
├── agent/         # Rust agent（mybot-agent）：模型循环（REPL/--task）、预算、会话持久化
├── modules/       # Lua驱动生态（60个模块 + 29个共享库）
│   ├── Servo.lua        # 舵机驱动
│   ├── PCA9685.lua      # 16路PWM驱动板
│   ├── Camera.lua       # 摄像头（V4L2）
│   ├── Speaker.lua      # 音频输出（ALSA）
│   ├── Sim.lua          # 仿真器客户端（命令/测距两条 AF_UNIX socket；拍照桥在 Camera.lua）
│   └── lib/             # HAL、virtbus、JSON、滤波器、asound 等共享库
├── robots/        # 结构脚本（11个机器人定义）
│   ├── spider1.sql      # 14路舵机蜘蛛
│   ├── relay-test.sql   # 虚拟继电器（无硬件）
│   └── test.sql         # 测试夹具
├── scripts/       # 动作脚本库（51个动作脚本）
│   ├── std.mt           # 站立
│   ├── left-turn.mt     # 左转
│   └── jump.mt          # 跳跃
├── sim/           # C++17/OpenGL 仿真器（独立 CMake 工程，不在主构建里）
│   ├── src/             # 引擎、命令/拍照/测距三桥、渲染、场景读写
│   ├── scenes/          # 模板场景（播种到 $MYBOT_HOME/maps/）
│   └── tests/           # sim_tests（8 个 TU；断言计数见 docs/testing.md）
├── prompts/       # Agent提示词包
├── examples/      # 最小可跑示例（examples/minimal：结构脚本 + 动作脚本 + dummy 驱动）
├── test/          # 三层测试（89 Lua + 50 C++ + E2E）
└── docs/          # 深入文档（16篇Markdown + design/ 设计论证 + 架构分析网页与两张全景图，清单以 docs/README.md 为准）
```

上面括号内的计数**受守门钉住**：`scripts/check_doc_paths.py` 第 7 组从仓库实况派生后
逐个比对，加/删文件却忘了改这里会判红（`bash test/run_all_selftest.sh`）。派生口径就是
这几条命令：
`ls modules/*.lua | wc -l`、`find modules/lib -name '*.lua' | wc -l`、
`ls robots/*.sql | wc -l`、`ls scripts/*.mt | wc -l`、`ls test/*.lua | wc -l`、
`ls test/cpp/test_*.cpp | wc -l`、`ls docs/*.md | wc -l`（含 `docs/README.md`）。
`sim/` 侧的 **TU 数**同样受检（派生自 `sim/CMakeLists.txt` 的 `add_executable(sim_tests …)`
源清单）；但 `./sim/build/sim_tests` 末行的**通过数**是运行时数，静态派生不出来（sim 侧
记账单位是断言不是用例，差额来自循环与条件分支），故本页不写死它——见 `docs/testing.md`。

## 测试与 CI

### 快速测试

```bash
# 完整回归测试（无需硬件）
bash test/run_all.sh

# 双跑：Release + ASan/UBSan
bash test/run_san.sh

# 只测Agent相关
bash test/run_all.sh agent-all
```

测试规模（下列数字**受守门钉住**：`scripts/check_doc_paths.py` 第 6/7 组从源码派生后
比对，加/删用例却忘了改这里会判红。两个「跑一遍才知道」的运行时数——`run_all.sh`
汇总行的守门用例数、`sim_tests` 的断言数——**故意不写死在本页**，只给指针，因为
静态门派生不出来、写死必漂移）：

- 808 个 C++ 单测（`test/cpp/`，零第三方框架，与被测程序共用同一套源文件）
- 89 个 Lua 测试文件 + 50 个 C++ 单测文件 + 完整 E2E 场景（双进程、多协议、虚拟 DAC 闭环）
- 守门用例数以 `bash test/run_all.sh` 末尾的汇总行为准（Lua 单测 + C++ 段 + 各 e2e 脚本）；
  跳过项只应剩 `test_jit_warmup.lua`——真机 ABI 回归，需 `/dev/i2c-*`
- 另有三处不计入上面两个数字的独立套件：`./build/harness_selftest` 8 条（测测试框架自身，
  同文件里另有 5 个 `meta_*` 例句只作被测对象、不进缺省全量跑）、`./sim/build/sim_tests`
  （`sim/` 是独立 CMake 工程，TU 数见上、断言计数见 `docs/testing.md`）、Rust agent
  `cargo test --release` 188 条

### CI 门禁（GitLab CI，`.gitlab-ci.yml`）

**全部为硬门禁**（每次推送必过，2026-09-25 起）：零告警构建（`-Werror`）、Release 全量守门、ASan/UBSan、TSan（守护并发用例）、clang 构建 + clang-tidy 静态分析（存量归零）、覆盖率采集（不设阈值，判采集链路）、musl libc 兼容性（alpine 下跑整段守门）、Rust agent 四检（build/test/clippy/fmt）与两进程 agent E2E

详见 [docs/testing.md](docs/testing.md)

## 文档索引

| 文档 | 内容 |
|------|------|
| [Agent 模式完整指南](docs/agent.md) | CLI 选项、工具系统、安全边界、提示词包、会话持久化 |
| [安全设计论证](docs/design/security-rationale.md) | 安全设计的完整论证、攻击场景与防线推导 |
| [命令行与环境变量参考](docs/reference.md) | 所有 CLI 参数、`BOT4CJ_*` 环境变量、安全约束 |
| [DSL 语言参考](docs/dsl.md) | 结构脚本、动作脚本完整语法 |
| [驱动清单](docs/drivers.md) | 60 个模块分类速查、驱动契约 |
| [HAL 硬件抽象层](docs/hal.md) | FFI 直调 glibc、I2C 原子事务、沙箱 |
| [@Daemon 守护线程](docs/daemon.md) | 后台采样、滤波器链路 |
| [虚拟总线](docs/virtbus.md) | 无硬件验证驱动链路、器件模型库 |
| [仿真器](docs/sim.md) | `sim/` 三条桥的协议、场景与地图持久化、放置解算口径 |
| [测试手册](docs/testing.md) | 守门分段、ctest、sanitizer、覆盖率 |
| [开发指南](docs/development.md) | 贡献流程、新增驱动、单测 |
| [FAQ](docs/faq.md) | 已知限制、排障问答 |
| [ICA 证据账本原型](docs/ica.md) | Rust agent 实验特性（BOT4CJ_ICA=1）的事实边界 |
| [Web SSH 语义契约](docs/webssh.md) | wsproto / webterm / webshell 行为不变式 |
| [更新日志](docs/changelog.md) | 版本演进与变更记录 |
| [架构分析与路线图（网页）](docs/architecture_analysis.html) | C++17 版全景分析，配两张架构图（**2026-09-25 快照，已冻结**：不含 sim/ 迁入、多机器人、`~/.mybot` 持久化、领域门面拆分） |
| [分层架构全景图（SVG）](docs/architecture_layers.svg) | L1–L7 分层 + 主数据流 + 守护并发引用（同上，2026-09-25 快照） |
| [play 数据流时序图（SVG）](docs/architecture_dataflow.svg) | 四阶段调用链 + @Daemon 并发分支（同上，2026-09-25 快照） |

完整索引与按角色选读见 [docs/README.md](docs/README.md)。

## 使用示例

### 示例 1：自然语言控制

```text
mybot[spider1|llm0|14hw]> 让机器人做一个站立动作
[工具] run_action_script
  script_name: std.mt
[结果] 已执行动作脚本 std.mt（231 字节）

机器人已完成站立动作，14个舵机已就位。

mybot[spider1|llm0|14hw]> 现在左转
[工具] run_action_script
  script_name: left-turn.mt
[结果] 已执行动作脚本 left-turn.mt（1025 字节）

已执行左转动作。

mybot[spider1|llm0|14hw]> /exit
```

### 示例 2：带视觉的决策

```bash
./agent/target/release/mybot-agent --socket /tmp/mybot.sock --llm-model gpt-4o
```

```text
mybot[spider1|llm0|14hw]> 拍照看看前面有什么
[工具] capture_image
[结果] 已拍摄照片（1920x1080 JPEG）

我看到前面是一个空旷的地面，没有障碍物。建议可以安全前进。

mybot[spider1|llm0|14hw]> 那就前进吧
[工具] run_action_script
  script_name: forward.mt
...
```

### 示例 3：一次性任务

```bash
# 终端 1：工具后端
./build/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/s.sock

# 终端 2：agent 一次性任务（--task 是 mybot-agent 的选项；后端不跑模型循环）
./agent/target/release/mybot-agent --socket /tmp/s.sock \
  --task "依次执行站立、左转、右转、然后回到初始姿势"
```

## 高级用法

### 换模型/换厂商

```bash
# 使用DeepSeek（思考模式）；模型侧参数都在 mybot-agent（后端另起，见快速开始）
export DEEPSEEK_API_KEY=sk-xxx
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --llm-driver LlmDeepSeek --llm-model deepseek-chat

# 使用本地Ollama
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --llm-endpoint http://localhost:11434/v1 \
  --llm-model llama3.2 --llm-config none
```

### 自定义提示词

```bash
# 编写提示词包
mkdir -p prompts/my_robot
echo "你是一个谨慎的机器人..." > prompts/my_robot/01-identity.md

# 加载提示词（--prompt-file 是 mybot-agent 的选项）
./agent/target/release/mybot-agent --socket /tmp/mybot.sock \
  --prompt-file prompts/my_robot
```

### TCP 远程控制

```bash
# 监听8080端口（需口令）
./build/mybot --robot=robots/spider1.sql --tcp 8080 \
  --tcp-host 0.0.0.0 --tcp-token secret123

# 客户端发送
(echo "secret123"; cat scripts/std.mt) | nc server_ip 8080
```

### Sanitizer 调试

```bash
# 构建asan版本
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DMYBOT_SANITIZE=address,undefined
cmake --build build-asan

# 运行
./build-asan/mybot --robot=robots/spider1.sql --mcp-backend --mcp-socket /tmp/s.sock
```

## 已知限制

- 仅支持 Linux + LuaJIT
- 守护线程有一线程一 Lua 状态的开销
- 部分器件只支持单消费者

完整限制与解决方案见 [docs/faq.md](docs/faq.md)

## 关于本项目

### 版本历史

本仓库是 **bot4cj（仓颉语言版）的 C++17 全量移植**：

- 三层脚本设计与用法不变
- 底层运行时：仓颉运行时 → 原生 C++（`std::thread` + LuaJIT C API）
- 构建系统：`cjpm` → `cmake`
- 修复原版问题：作用域收敛、SQL 校验加强

> 「用法不变」≠「逐字节兼容」：移植时修复了若干旧版问题（详见 [docs/faq.md](docs/faq.md)）

### 技术规格

- **实现**：C++17 宿主（零第三方 C++ 依赖）+ Rust agent（`agent/`，rig 0.42 钉版，cargo 独立构建）
- **构建**：CMake ≥ 3.16（宿主）；cargo（agent）
- **编译器**：g++ 12+ / clang 14+
- **平台**：Linux (aarch64 / x86_64)，树莓派实测可用
- **运行期**：LuaJIT（`asound.lua` 经 ffi 需要 libasound.so.2，仅配置 Speaker 时）

### 项目亮点

- **驱动热插拔** —— 新增器件不改 C++，只写 Lua 驱动
- **动作可复用** —— 动作脚本独立于机器人结构
- **结构可迁移** —— 同一结构脚本换驱动板零修改
- **多模型支持** —— 内置 OpenAI / DeepSeek / Anthropic 三族协议（Rust agent 直连，不经 Lua 驱动）

## 贡献

欢迎贡献代码、驱动、文档！

```bash
# 安装pre-push钩子
bash scripts/install-hooks.sh

# 开发时运行测试（全绿即可提交）
bash test/run_all.sh
```

- 新增器件驱动：参考 [docs/development.md](docs/development.md) 的「新增驱动」节
- 新增测试用例：`test/cpp/test_*.cpp` 或 `test/test_*.lua`
- 文档改进：`docs/` 目录

详见 [docs/development.md](docs/development.md)

## 开源协议

本项目基于 **MIT 协议**开源（见 [LICENSE](LICENSE)）

---

**立即开始** → `bash scripts/build_agent.sh` 后两个终端：`./build/mybot --robot=robots/relay-test.sql --mcp-backend --mcp-socket /tmp/mybot.sock` 与 `./agent/target/release/mybot-agent --socket /tmp/mybot.sock`

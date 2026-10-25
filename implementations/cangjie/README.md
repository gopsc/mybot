# bot4cj - 基于仓颉的通用机器人控制程序

> **共建理念**：能写文档的写文档，能写代码的写代码，一起共建仓颉生态！

bot4cj 是用仓颉语言编写的**机器人硬件控制器**。可以把它想成一个"播放器"：给机器人一份动作剧本，它就照着"演"出来。

它的核心思路是把**结构、驱动、动作**三件事分开写，各用一种脚本：

| 脚本 | 像什么 | 负责什么 |
| ---- | ------ | -------- |
| 结构脚本 `.sql` | 舞台的**接线图** | 机器人身上有哪些零件、接在哪条总线/哪个地址、谁听谁的 |
| 驱动脚本 `.lua` | 零件的**说明书** | 每个零件怎么点亮、怎么读数（I2C / SPI / UART 都藏在这一层，用快而简单的 LuaJIT 编写） |
| 动作脚本 `.mt` | 演员的**剧本** | 一行就是一个时间点的动作，逐行播放就是一段表演 |

程序把三份脚本拼起来，就能从电脑上用一行命令指挥机器人站立、走路、转向。

[实机演示地址](http://152.136.227.85:8080/videos/robot-show.mp4)

视频由 PC 端与机器人实拍两部分组成，如果播放卡顿可以右键下载后观看。

## 📋 项目信息

- **项目版本**：v0.3.3（`cjpm.toml`）
- **维护状态**：🟢 积极维护中
- **主要负责人**：qingss0（Flowers_Unamed 团队）
- **开发人员**：[qingss0](https://gitcode.com/qingss0)
- **仓颉版本**：支持仓颉语言 1.1.3（stdx 1.1.3）

## 🧭 三份脚本如何配合

```text
结构脚本 .sql → 定义零件清单（舵机、传感器…）
                  │ 每个零件配一份说明书（自动加载）
驱动脚本 .lua → 教计算机读写这个零件
                  ↑ 按剧本逐行调用
动作脚本 .mt  → 第 1 行做什么 → 第 2 行做什么 → …
```

**不接任何硬件也能跑通全流程**：程序内置了"假零件"（传感器桩替身、Relay 转发链路），装好环境就能在开发机上看到整条链路真实运转——下面「快速开始」的第一条命令干的就是这件事。

## 🚀 快速开始

### 安装依赖

首先安装 LuaJIT 开发库（仓颉侧的绑定为独立包 [luajit4cj](https://gitcode.com/qingss0/luajit4cj)）：

```bash
sudo apt update && sudo apt install libluajit-5.1-dev
```

### 构建

```bash
export CANGJIE_STDX_PATH=/path/to/cangjie-stdx   # cjpm.toml 按目标架构读取
bash _set.sh                                     # 等价于 cjpm update + cjpm build
```

### 第一条命令：无硬件跑通 Relay → Timer

`relay-test` 是一台"玩具电梯"，**不需要接任何硬件**：`Relay` 把 `test` 参数转成 `delay`，经 controller 机制转发给 `Timer` 延时 200ms，用来确认环境装好了、程序能跑了。**新手只要跑通这一条就算入门**：

```bash
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

看到 `Relay: test=200 note=hello-relay -> delay=200` 且正常退出，环境就没问题了。想看每一步的参数与结果转储，可以打开调试开关再跑一遍：

```bash
export BOT4CJ_DEBUG=1
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

### 进阶：无硬件测试（可选）

跑通上面那条后，可以在开发机（不接硬件）上把测试跑得更全，分两层：

**Lua 驱动层（桩替身）**：`bash test/run_all.sh` 一键跑全部 Lua 离线测试（需系统装有 `luajit`，可用环境变量 `LUACMD` 指定别的解释器；真机 i2c 用例自动跳过；`test/` 下所有 `test_*.lua` 都会被自动收集）。也可以单跑某个无硬件样例：

```bash
luajit test/test_relay_nohw.lua      # Relay：纯软件驱动，连 HAL/ffi 都不碰
# 该用例不依赖 HAL，用 lua5.4 也能跑
```

**仓颉程序层**：`relay-test` 之上，`@Daemon` 守护线程也备好了无硬件测试命令，见下文「@Daemon 守护线程」小节末尾的「无硬件跑 Daemon」——每条命令退出码 0 即通过。

### 接第一块 PCA9685

- 接线：树莓派 `i2c-1`（SDA1/SCL1）→ PCA9685，地址 `0x40`
- 参照 `robots/spider1.sql` 写自己的结构脚本：I2C 表 → PCA9685 表 → Servo 表（Servo 的 controller 列指向 `pca9685-0`，channel 对应接线通道）
- 跑站立动作：

```bash
cat scripts/std.mt | bash _run.sh --robot=robots/spider1.sql
```

脚本语法细节见下文「机器人结构脚本」「动作脚本」两节；报错信息会指出是哪张表、哪一行、哪一列的问题，按提示修正即可。

## 📱 运行示例

项目中包含的动作脚本都在 `scripts/` 文件夹下，适配 `robots/spider1.sql` 的 14 路舵机结构（通道分配见该文件注释）：

```text
# PCA9685 通道分配（参照 robots/spider1.sql）
s1   rb0  右后腿·髋      ch6     s9   cam0 云台水平  ch0
s2   rb1  右后腿·大腿    ch5     s10  cam1 云台垂直  ch1
s3   lb0  左后腿·髋     ch14     s11  rb2  右后腿·膝  ch4
s4   lb1  左后腿·大腿   ch15     s12  lb2  左后腿·膝  ch7
s5   lf0  左前腿·髋      ch8     s13  lf2  左前腿·膝 ch13
s6   lf1  左前腿·大腿    ch9     s14  rf2  右前腿·膝 ch10
s7   rf0  右前腿·髋     ch11     spk  Timer 仅负责延时
s8   rf1  右前腿·大腿   ch12
```

除基础的站立 `std.mt` 外，`scripts/` 里还有转向、倾斜、举手、躺下、原地跳等动作脚本：

```bash
cat scripts/left-turn.mt | bash _run.sh --robot=robots/spider1.sql   # 左转
cat scripts/tilt-r.mt    | bash _run.sh --robot=robots/spider1.sql   # 右倾
cat scripts/one-shake.mt | bash _run.sh --robot=robots/spider1.sql   # 单腿姿势
```

机器人结构由 `--robot` 指定，动作脚本来源可三选一（`src/ActionSource.cj` 工厂，优先级从高到低）：

```bash
# 1) TCP 长驻模式：监听端口等待客户端下发 .mt（适合上位机/远程持续喂动作）
bash _run.sh --robot=robots/relay-test.sql --tcp 19240

# 2) 文件输入：不依赖管道，直接指定动作脚本（Windows 无管道也能跑）
bash _run.sh --robot=robots/relay-test.sql --input scripts/relay-test.mt

# 3) 缺省：stdin 管道（前两节示例的写法）
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

TCP 源直接以字节流（`InputStream.read(Array<Byte>)`）交给核心的 StringReader 解析，
客户端关闭连接（EOF，read 返 0）即结束本次 run；断连异常同样按 EOF 收尾而非 abort。
`scripts/tcp_e2e.sh [port]` 提供 Python 客户端 → TCP → 服务端的回环端到端自检。

## 🔧 环境要求

### 支持的版本

**已验证的开发环境：**

| 组件          | 版本信息 | 状态    |
| ------------- | -------- | ------- |
| 仓颉语言      | v1.1.3   | ✅ 支持 |
| 仓颉 stdx     | v1.1.3   | ✅ 支持 |
| LuaJIT        | 5.1（libluajit-5.1-dev）| ✅ 必需 |
| Linux glibc   | 发行版自带 | ✅ 必需 |

**依赖包：**

| 依赖包 | 用途 |
| ------ | ---- |
| [luajit4cj](https://gitcode.com/qingss0/luajit4cj) | LuaJIT 的仓颉绑定，Lua C API 一律经其调用 |
| [pthread4cj](https://gitcode.com/qingss0/pthread4cj) | 守护线程共享内存槽的互斥锁封装 |
| [SQL4cj](https://gitcode.com/qingss0/SQL4cj) | 机器人结构脚本（.sql）的解析 |
| mt2、ctype4cj | 矩阵与基础工具支持 |

### 平台兼容性

| 平台                     | 支持状态      | 备注                                             |
| ------------------------ | ------------- | ------------------------------------------------ |
| Linux（aarch64 / x86_64）| ✅ 完全支持   | 主要平台，树莓派实测稳定                         |
| Windows                  | ❌ 暂不支持   | 新版 HAL 加载 Linux glibc，Windows 通常没有     |
| macOS                    | ❌ 暂不支持   | 计划支持                                         |

由于底层的系统接口调用（I2C/SPI 总线、UART）被下沉到了脚本端，程序本身很容易跨平台编译运行。

## 📚 核心概念与 DSL

前文的比喻换成正式说法：结构脚本 `.sql` 以 SQL 方言声明机器人硬件结构与调用链，驱动脚本 `.lua` 在 LuaJIT 里实现每个硬件变量的底层驱动，动作脚本 `.mt` 以行列式 DSL 编排机器人的动作。下面逐一展开。

### 机器人结构脚本（.sql）

结构脚本是 `.sql` 文件，由 SQL4cj 解析，支持 `--` 单行注释与块注释（旧版 `.mt` 结构矩阵与 `.bot` 格式已废弃）。内容就是一组 `CREATE TABLE / INSERT INTO`：每张表对应一类硬件（表名即矩阵名，决定加载哪个驱动），每行 INSERT 就是一个具体的硬件实例：

```sql
/* 定义 I2C 总线 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* 定义 PCA9685 舵机控制器，挂在 i2c-1 的 0x40 地址 */
CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca9685-0', '$i2c-1', '0x40');

/* 定义舵机：max 限幅（负值表示方向反向）、offset 中位漂移，"-" 继承上一行 */
CREATE TABLE Servo (
	name       String,
	max        String,
	min        String,
	offset     String,
	controller String,
	channel    String
);
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s1, 90, -, -, 'pca9685-0', 0);	-- 左下水平关节
```

> 说明：`-` 是占位符，表示继承上一行同列的值（如 s2 之后的 controller 继承 s1 的 `pca9685-0`）；`I2C` 列以 `$i2c-1` 引用上方定义的总线硬件变量（0.3.2 起引用列须 `$` 前缀，裸名一律按字面值），框架把总线 `call()` 返回的 `fd` 合并进本变量的元数据；注释整行 INSERT 即可下线一个硬件实例。

### 硬件变量矩阵一览

**先看结论**：这张表是"零件仓库清单"——用不到的器件直接跳过，等真接了某个传感器再回来对号入座。目前框架内置 53 个硬件驱动，按总线/能力分类如下（每个驱动就是一个 `modules/<矩阵名>.lua`）：

| 类别 | 硬件变量 | 说明 |
| ---- | -------- | ---- |
| 舵机/输出 | `PCA9685`、`Servo`、`Timer`、`MCP4725`、`AD9833`、`TPL0501`、`PCF8574`、`GPIO`、`PWM` | 舵机控制器、DAC、DDS 波形、数字电位器、IO 扩展、GPIO、硬件 PWM |
| IMU/姿态 | `MPU6050`、`BMI270`、`LSM6DSV`、`ADXL345`、`MLX90393`、`BMM150` | 六轴/三轴加速度计、磁力计、罗盘 |
| 气压/环境 | `MS5611`、`LPS22HB`、`BME280`、`BME688`、`SHT3X`、`CHT8305`、`AMG8833`、`AS7262`、`APDS9900`、`BH1745` | 气压计、温湿度、热像、光谱、环境光、颜色 |
| 测距 | `VL53L0X`、`VL53L4CD`、`AS3935` | ToF 激光测距、闪电事件传感器 |
| ADC/电源 | `ADS1015`、`ADS1115`、`ADS1256`、`MCP3421`、`INA219`、`INA226`、`INA3221`、`MAX17043`、`MAX17048`、`LTC2944`、`EMC2101` | 高速 ADC、电流/功率监测计、库仑计、电量计、风扇控制器 |
| 气体/其他 | `SGP30`、`SDS011`、`MHZ19`、`MAX30102`、`MT6826S` | 空气质量、PM2.5、CO2、血氧 PPG、磁编码器 |
| 框架 | `I2C`、`SPI`、`UART`、`Relay`、`dummy`、`Kalman`、`Ema`、`Monitor` | 总线、转发测试、滤波器、数据消费示例 |

### 硬件 PWM（`PWM`）

`PWM` 走 Linux 标准 sysfs 接口（`/sys/class/pwm/pwmchipN/pwmM`），波形由 SoC 的 PWM 控制器产生，Lua 侧只写 `period` / `duty_cycle` / `enable` 三个属性——不掉 CPU、不抖动。

> **为什么不做软件 PWM**：在 `call()` 里循环翻转会阻塞整套动作的播放；放到 `@Daemon` 里用 ffi `usleep` 自旋又会占住 schd-worker 不放、耗尽 worker 池（见下文「@Daemon 守护线程」）。所以本框架只支持硬件 PWM。

```sql
CREATE TABLE PWM (
	name      String,
	chip      String,
	channel   String,
	frequency String,
	duty      String,
	invert    String
);
INSERT INTO PWM (name, chip, channel, frequency, duty, invert)
  VALUES ('pwm0', '0', '1', '20000', '0', '-');
```

- `channel` 是**硬件通道号**（`0` = PWM0，`1` = PWM1），**不是 GPIO 引脚号**——填引脚号会直接报越界
- `frequency` 载波频率 Hz（缺省 1000）：电机 10k~20kHz，LED 1k 上下
- `duty` 占空比 0~100；给了才在 build 期使能输出，不给则保持关闭、等第一帧再输出（与 `GPIO` 的 `init` 语义一致）
- `invert` 填 `1` 输出反相（低电平有效的驱动板）
- 动作脚本里写 `pwm0.duty`；也可以写 `pwm0.value`（`value` 是 `duty` 的别名）

从哪个物理脚输出由**设备树**决定（sysfs 没有"选引脚"属性）：在 `/boot/firmware/config.txt` 配 `dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4` 并重启，树莓派常用组合为 PWM0 → GPIO12/18、PWM1 → GPIO13/19，用 `raspi-gpio get <pin>` 确认复用生效（应显示 `ALT0`/`ALT5`）。注意：

- ⚠️ `export` 成功**不等于**有物理输出——overlay 没配脚时 `period`/`duty` 照样写得进去，但引脚仍是普通 GPIO
- 同一引脚不能既被 `GPIO` 用 gpiod 请求、又被配成 PWM（复用互斥）；`export` 默认仅 root 可写，普通用户需 udev 授权或以 `sudo -E` 运行

### 动作脚本（.mt）

动作脚本用一张表格描述一帧一帧的动作：表头是「硬件变量.参数」（相当于台词名），每一行就是一帧，程序逐行往下"播放"：

```mt
# 行动矩阵为硬件变量输入参数
@Action
s1.A  s2.A  s3.A  s4.A  s5.A  s6.A  s7.A  s8.A  spk.F  spk.delay;	# column name
  45     -    45     -    45     -    45     -     10        200;	# stand
  90     -     -     -     -     -     -     -      -         20;	# left-behind
@
```

- 动作脚本也可以内联定义 `@Alias` 别名矩阵（如把 `s1.A` 写成 `s1.angle`），无需写进结构脚本
- 结构脚本与动作脚本两侧都可以定义别名，同名时动作脚本的定义覆盖结构脚本（会打印覆盖日志）
- 同一动作脚本内重复定义同名别名会报错

### controller 引用机制（通用）

可以理解成**"转交任务"**：某个硬件变量收到指令后，自己先干一份活，再把结果转交给另一个硬件变量。这不是 `Servo` 的专利——任何硬件矩阵都可以声明一个 `controller` 列，把自己的调用**转发**给另一个硬件变量：

1. 先运行自己的 Lua 驱动（`modules/<矩阵名>.lua` 的 `call`）
2. 框架再把「该行元数据（跳过 `name`/`controller` 列）∪ 自己 Lua 的返回表」发送给 `controller` 指定的硬件变量
3. `controller` 的值支持 `-` 占位符继承上一行
4. 被引用的 controller 必须在结构脚本中先于引用它的矩阵定义

可运行示例（`Relay` 把参数转成 `delay` 后交给 `Timer` 延时）：

```sql
CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
```

#### 引用列（`$` 前缀）

除 `controller` 列外，元数据列还可以**按值引用**另一个硬件变量：值以 `$` 开头（如 `$imu0`）即为引用列，被引用变量的 `read()` 快照字段会实时合并进本变量的元数据；**不带 `$` 的裸名一律按字面值**（0.3.1 及之前按"值恰好是已定义硬件变量名"隐式判定引用，已废弃）。`$` 指向未定义的硬件变量会在 build 期显式报错：

```sql
CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');   -- 引用守护 imu0（$ 前缀必填）
```

### 基层硬件抽象层（HAL）

总线怎么"开口说话"（打开设备、读写寄存器的底层动作）都封装在 `modules/lib/HAL.lua`，所有驱动共用这一份，**仅支持 LuaJIT**：

- `ffi` 直调 glibc（open/ioctl/read/write/usleep），原生性能零 fork；fd 为真实内核句柄，跨 Lua 状态机天然有效
- **I2C 经 `I2C_RDWR` ioctl 原子事务**：读寄存器的「写指针 + 读」合并为单次内核传输，消除守护线程与主线程并发访问同一器件时的寄存器指针竞态；地址由每条 i2c_msg 携带，不再需要 `I2C_SLAVE` ioctl（也没有地址被内核驱动占用的 EBUSY 问题）
- 驱动模块顶部 `dofile` 加载 HAL，函数名与原 cfunc 完全一致；Lua 5.3+ 位运算经 `bitcompat.lua` 双兼容
- `modules/lib/` 还收纳 `kalman.lua`（一维卡尔曼滤波器）等公共库，不依赖 HAL 的模块仍可用 `luajit`/`lua5.4` 独立调试

### @Daemon 守护线程

有些传感器需要**一刻不停地读**（比如 IMU 姿态）。这活儿靠 `@Daemon` 声明的**后台小工**来做：宿主用**仓颉 `spawn` 原语**起一个守护线程，在后台循环采样，主线程随时去取最新值：

```sql
CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'lib/daemon_probe.lua');
```

> chunk 寻址与普通 Lua 硬件模块一致：相对路径以 `BOT4CJ_MODULE_PATH`（默认 `./modules`）为基准、不依赖进程 CWD，写全路径/绝对路径也兼容（多路径查找规则见下文「环境变量」）。

并发模型的关键点：

- **必须用 `spawn`**，不能用 pthread4cj 裸线程：foreign pthread 没有仓颉运行时线程态，在其上跑 @C 代码必崩（PoC 实测 3/3 SIGSEGV）；spawn 是仓颉的 M:N 绿色线程，运行时已附着，安全
- 守护线程持有**独立 lua_State**（`jit.off`），与主线程状态机 1:1 隔离，规避 LuaJIT VM 非线程安全
- **让出式节拍**：拍间用仓颉 `sleep(Duration)` 让出 worker；切忌在 chunk 内用 ffi `usleep` 自旋循环（会阻塞 worker 不放，守护线程数 ≥ worker 数时池耗尽是死锁）
- **IPC 经共享内存槽**：守护侧 Lua `P.publish(slot, {...})` 写值，主线程侧 `play()` 加锁读值，同一 pthread_mutex 防撕裂
- `@Daemon` 矩阵除 `name`/`chunk` 外的列会序列化为 `DAEMON_CONFIG` 串注入 chunk

**万能采样 chunk（零 per-sensor 代码）**：`lib/sensor_daemon.lua` 服务任意 build/call/destroy 型驱动，无需为每个传感器写 Lua：

```sql
CREATE TABLE Daemon (
	name String, chunk String, driver String, proto String,
	path String, addr String, interval String, fields String, sign String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2c',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');
```

`fields` 用 `|` 分隔以避开 SQL 值分隔符逗号；`sign=16` 表示对提取值做 16 位补码符号扩展。字段可带 `:模式` 后缀逐字段覆盖：`:f`/`:float` 原样透传浮点（如 MPU6050 的 `TEMP` °C，避免被 `sign=16` 取整破坏），`:s16` 强制 16 位补码；无后缀跟随全局 `sign`。

**滤波器硬件变量**：每个滤波器 = `lib/<filter>.lua` 库（统一 `.new()` + `:filter(x)` 接口）+ `<Filter>.lua` 驱动。驱动引用守护/传感器，call 逐拍滤波，输出既作 `out` 也别名 `v0`，成为「虚拟传感器」。现有滤波器：

- **Kalman**（一维卡尔曼）：配置 `Q`/`R`（系统/测量噪声协方差）
- **Ema**（指数移动平均）：配置 `alpha`∈(0,1]（越小越平滑）、可选 `init`

三级引用链示例（守护采样 → 滤波 → 消费）：`imu0 → kf0 → mon0` 全靠既有引用机制自动串联（播放 mon0 会递归播放 kf0、imu0）。

> 注意：守护线程 setup（开总线 + 配置传感器）需数毫秒；若动作序列极短（几行瞬时 play），可能在守护首次采样前就 free() 停止（表现为 publishes=0）。真实机器人动作序列为秒级，无此问题；测试时用 Timer 延时列拉长主线程时间窗。

#### 无硬件跑 Daemon（可选自检）

想看守护机制本身转起来，不必上真传感器——两个纯软件"模拟传感器"就够了：`lib/daemon_probe.lua`（内存槽发布计数/正弦）与 `lib/daemon_tid.lua`（gettid + 计数），扎到的仍是同一份 `Daemon.cj` 槽分配/加锁代码。`cjpm build` 后逐条跑，退出码 0 即通过：

```bash
cat scripts/test/daemon.mt      | bash _run.sh --robot=robots/test/daemon.sql     # 单守护并发压测（主线程负载 × 计数守护）
cat scripts/test/multidaemon.mt | bash _run.sh --robot=robots/test/multidaemon.sql # 4 守护并发诊断（各持独立 lua_State）
cat scripts/test/monitor.mt     | bash _run.sh --robot=robots/test/monitor.sql    # 守护采样 → Monitor 引用消费闭环
```

对比：`scripts/test/mpu_daemon.mt` 挂在真实 `MPU6050`（`/dev/i2c-1`, 0x68）上，那一条才需要真机。

#### 虚拟总线（I2C/SPI，无真机验证驱动链路）

`lib/virtbus.lua` 提供纯内存的虚拟总线：`inject()` 后替换 HAL 的全部全局 `i2c_*`/`spi_*` 函数，真实驱动无需真机与 `/dev/i2c-*`、`/dev/spidev*` 即可完整跑通 build/call/destroy，每次事务记入 `txlog` 供断言，并可注入 NACK 等负路径（与真机"设备不在总线"行为一致）。配套 `lib/virtbus/` 器件模型库收录 28 个协议级模型（regmap 通用底座及 MPU6050、BME280、BH1750、ADS1256、AD9833、TPL0501、VL53L0X、VL53L4CD、MCP4725、SHT3X、MCP3421、MS5611、SGP30、INA219、ADS1115、AS7262、MAX30102、AMG8833、PCF8574、LTC2944、CHT8305、ADS1015、INA226、INA3221、MAX17043、ADXL345、LPS22HB）。

`@Daemon` 的 `proto` 列填 `virt` 可做**守护无硬件端到端**：真实驱动 build/call、共享槽 publish、`@Ema/@Kalman` 滤波、`@Monitor` 引用消费整条链路全部走内存仿真（守护启动打印 `VIRTUAL HARDWARE` 横幅，仿真数据禁止用于生产环境）。现有 23 个 E2E 用例，例如：

```bash
cat scripts/test/mpu_virt.mt    | bash _run.sh --robot=robots/test/mpu_virt.sql
cat scripts/test/bme280_virt.mt | bash _run.sh --robot=robots/test/bme280_virt.sql
# 其余 21 例（ads1256/vl53l0x/vl53l4cd/sht3x/mcp3421/ms5611/sgp30/ina219/ads1115/as7262/max30102/amg8833/pcf8574/ltc2944/cht8305/ads1015/ina226/ina3221/max17043/adxl345/lps22hb）见 docs/virtbus.md
```

API 契约、模型回调、txlog 格式、SPI 语义、器件模型明细与全部回归用例，见 **[docs/virtbus.md](docs/virtbus.md)**（相关回归与仓颉级 E2E 均由 `run_all.sh` 自动纳入）。

### 环境变量

| 变量 | 说明 |
| --- | --- |
| `BOT4CJ_MODULE_PATH` | 驱动模块目录（默认 `./modules`），框架加载 `<矩阵名>.lua`、驱动 dofile `lib/` 与 `@Daemon` 的 chunk 均按其解析；支持 `:` 分隔多个路径（如 `./modules:./extra_modules`）按序查找，**共享库目录放第一段**（issue #19） |
| `BOT4CJ_DEBUG` | 设为 `1` 开启 call/build/destroy 的参数表、结果表、逐键值、lua status 详细转储；缺省静默，错误信息与生命周期摘要不受影响 |
| `BOT4CJ_NO_GC` | 设为 `1` 关闭仓颉 GC（导出 `cjEnableGC=0`），**长动作脚本模式**：并发 GC 缺陷（见已知限制）在高分配速率下会概率性崩溃/挂死，关 GC 后实测 5000 行脚本 6/6 稳定通过且耗时约减半；千行级脚本 RSS <100MB，进程退出由 OS 回收内存。**仅限一次性执行**，`--tcp` 长驻模式禁用（内存会无限增长直至 OOM） |

安全说明：框架加载 Lua 驱动后会中和 `os.execute` / `io.popen`（shell）、`os.exit`（进程退出）、`io.open` / `io.lines` / `io.input` / `io.output` / `os.remove` / `os.rename`（任意文件读写）；`os.getenv`、`dofile`、`require`（HAL 依赖 ffi）保留。**该沙箱是防误用护栏，不是安全边界**——Lua 驱动可经 `require("ffi")` 直调任意 libc，且结构/驱动/动作脚本均为可信输入；现已支持 TCP 动作输入（`--tcp`），接入外部网络数据源时需另行建立信任边界（输入校验或白名单 API）。

## 💡 进阶示例：守护采样 → 滤波 → 消费闭环

用 `@Daemon` 起守护线程采样 IMU，接 Kalman 滤波，再用 `Monitor` 消费并转发执行器，形成闭环：

```sql
CREATE TABLE Daemon (name String, chunk String);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'lib/sensor_daemon.lua');   -- 采样

CREATE TABLE Kalman (name String, Q String, R String, src String, field String);
INSERT INTO Kalman (name, Q, R, src, field) VALUES ('kf0', '20', '200', '$imu0', 'v0');  -- 卡尔曼

CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$kf0');   -- 消费滤波值
```

`modules/Monitor.lua` 即此类示例：`call()` 里 `data.v0` 拿到实时采样值，决策后可经 controller 列转发执行器。

## ⚠️ 已知限制

### 当前版本限制

- **仅支持 Linux**：HAL 通过 `ffi` 直调 glibc，Windows 平台没有现成的 glibc，暂不支持（旧版曾支持，0.3.0 起移除）
- **仅支持 LuaJIT**：总线驱动依赖 `ffi`，需 `luajit` 解释器；不依赖 HAL 的模块可用 `lua5.4` 独立调试
- **守护线程的开销**：每个守护持有独立 lua_State，拍间必须让出式 sleep，否则会耗尽 worker 池
- **一器件一消费者**：页式寄存器序列的器件（如 VL53L0X）与握手式间接访问器件（如 AS7262）只支持单消费者
- **超长动作脚本 + controller 转发路径存在概率性崩溃/挂死（仓颉运行时并发 GC 缺陷）**：
  gdb 实证（v0.3.3 复盘）为仓颉 1.1.3 并发复制 GC 在高分配速率下的并发缺陷——主线程可卡死
  在 GC 读屏障内自旋（CPU 100%）、读到未转发旧引用（SIGSEGV）或容器状态被并发搬移破坏
  （`ConcurrentModificationException`）。controller 转发路径因分配速率翻倍而优先暴露：
  ≤800 行 0% 失败，1000~5000 行默认配置失败率约 17%（v0.3.3 logD 条件求值修复后，
  修复前约 50%+），与堆大小基本无关（调堆**不能**解决）。正常步态脚本（数十行）不受影响；
  需要跑长脚本时设 `BOT4CJ_NO_GC=1`（详见环境变量表）。runtime 层根除需仓颉运行时修复

### 待实现功能

- [x] **TCP 传输动作**：已落地 ActionSource 三源动作输入（stdin / 文件 / `--tcp` 长驻，见上文「运行示例」）
- [x] **神经网络前向推理（纯 Lua 基准）**：[`modules/lib/nn.lua`](modules/lib/nn.lua) 提供无 nn4cj 依赖的全连接 MLP 前向引擎（默认 `{41,80,80,40,17}` 四层、LeakyReLU/Sigmoid、`.mt` 权重存取）；将推理输出接回仓颉动作链路（历史 nn4cj/`MtVars_NN` 路径）仍待重新接入
- [ ] **更多操作系统适配**：鸿蒙终端、macOS、开源鸿蒙机器人
- [ ] **驱动生态扩充**：按模板新增一个 Lua 文件即可即插即用，欢迎社区贡献

## 🔧 开发与贡献

### 本地开发

```bash
# 克隆仓库
git clone https://gitcode.com/qingss0/bot4cj.git
cd bot4cj

# 安装依赖并构建
bash _set.sh

# 运行离线测试（桩替身不触硬件）
bash test/run_all.sh

# 运行示例（无硬件自检链路）
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

### 贡献指南

我们欢迎所有形式的贡献！

- **🐛 报告 Bug**：[提交 Issue](https://gitcode.com/qingss0/bot4cj/issues)
- **💡 功能建议**：[功能请求](https://gitcode.com/qingss0/bot4cj/issues)
- **📝 完善文档**：改进 README、添加示例、翻译文档
- **🔧 代码贡献**：新增驱动、修复 Bug、优化性能
- **🧪 测试验证**：在不同总线上测试、补充离线用例

> 💡 **记住**：能写文档的写文档，能写代码的写代码，一起共建生态！

### 开发者

- **主要维护者**：[@qingss0](https://gitcode.com/qingss0)
- **团队**：Flowers_Unamed（BadHope）

## 📋 更新日志

### v0.3.3（2026-09）

- ✅ 新增硬件 PWM 驱动 `PWM`：走 Linux sysfs（`/sys/class/pwm`），可配频率与占空比。软件 bit-bang PWM 在本框架不可行（会阻塞动作播放或耗尽 worker 池），故仅支持硬件 PWM
- ✅ 修复 `.gitignore` 残留的 `cjpm.lock`（0.3.2 已把锁文件入库，忽略项与之矛盾）
- ✅ 修正 `_run.sh` 堆大小注释与默认值不符（注释写 512MB，实际 128MB）
- ✅ 定性长脚本崩溃根因（仓颉运行时并发 GC 缺陷，gdb 实证）并落地规避：新增 `BOT4CJ_NO_GC=1` 长脚本模式，热路径 `logD` 改条件求值（默认配置失败率约 50% → 17%，长脚本模式 0%）
- ✅ 修复 BME280 驱动 build 恒 ERR：湿度校准块 7 字节读超 HAL 合并读上限 6 字节，改走字节表版 `i2c_read_multi_bytes`；新增 `test/test_bme280.lua` 离线桩测试 33 用例（旧代码在桩下复现恒 ERR，防回归）

历史版本要点：v0.3.2 引用列改 `$` 前缀显式标记；v0.3.1 HAL 读函数越界显式失败；v0.3.0 引入 `@Daemon` 守护线程、滤波器与大批驱动；v0.2.0 HAL 进入 LuaJIT ffi 时代；更早版本完成 SQL 结构脚本迁移与 Lua 状态机嵌入。完整历史见 [CHANGELOG.md](CHANGELOG.md)。

## 📄 开源协议

本项目基于 [MIT](LICENSE) 协议开源（Copyright (c) 2025 卿松），请自由地享受和参与开源。

## 📸 效果展示

### 运行视频

> 🎥 [查看完整演示视频](http://152.136.227.85:8080/videos/robot-show.mp4)

演示视频由 PC 端与机器人实拍两部分组成，展示了平面蜘蛛机器人按动作脚本完成站立、转向、倾斜、举手等动作。

## 🙋 常见问题

### Q: 报错提示看不懂怎么办？

A: 结构脚本的报错信息会明确指出是哪张表、哪一行、哪一列的问题；动作脚本报错会说明是哪个硬件变量与参数。按提示修正即可，也可以在 [Issues](https://gitcode.com/qingss0/bot4cj/issues) 中反馈。

### Q: @Daemon 守护线程为什么卡死？

A: 最常见的原因是拍间用 ffi `usleep` 自旋，占用 schd-worker 不放，导致 worker 池耗尽。请让守护采样 chunk 只定义全局 `daemon_tick`，拍间由仓颉 `sleep(Duration)` 让出。

### Q: 守护线程 publishes=0？

A: 动作序列极短（几行瞬时 play）时，守护可能在首次采样前就被 free() 停止。真实动作序列为秒级没有问题；测试时用 Timer 延时列拉长主线程时间窗。

### Q: I2C 设备报 EBUSY？

A: HAL 已改用 `I2C_RDWR` 原子事务，地址由每条 i2c_msg 携带，不再需要 `I2C_SLAVE` ioctl，一般不会再遇到内核驱动占用地址导致的 EBUSY。

### Q: 为什么不支持 Windows？

A: 新版 HAL 加载 Linux 的 glibc（open/ioctl/read/write/usleep），Windows 通常没有；动作脚本经管道输入，Windows 的 cmd/PowerShell 也没有原生的管道重定向。旧版曾支持 Windows，后续计划推出 TCP 传输与多平台适配。

### Q: 不接硬件也能开发吗？

A: 可以。`bash test/run_all.sh` 用桩替身跑全部 Lua 离线测试；`relay-test` 链路（Relay → Timer）不需要任何硬件，先跑通它即可验证安装与环境是否正确。

---

## 📞 联系我们

- 🐛 **问题反馈**：[GitCode Issues](https://gitcode.com/qingss0/bot4cj/issues)
- 🏠 **代码仓库**：[gitcode.com/qingss0/bot4cj](https://gitcode.com/qingss0/bot4cj)
- 📹 **演示视频**：[实机演示地址](http://152.136.227.85:8080/videos/robot-show.mp4)

**一起建设仓颉生态！** 🚀

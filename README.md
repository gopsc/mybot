# bot4cj

bot4cj是基于仓颉的**机器人硬件控制器**，它是一个**可扩展的结构**，目标是用一门简单快速的脚本语言写**应用层硬件驱动**，将**机器人结构**、**机器人动作**用DSL解耦出来。通过管道向程序传递动作脚本的内容，就可以驱动机器人做出动作。




## 依赖库
这个项目依赖一些仓颉语言的软件包，以及 LuaJIT（仓颉绑定为独立包 [luajit4cj](https://gitcode.com/qingss0/luajit4cj)）


**你需要安装 LuaJIT 开发库**

```bash
sudo apt update && sudo apt install libluajit-5.1-dev
```


## 5 分钟上手

### 1. 构建

```bash
export CANGJIE_STDX_PATH=/path/to/cangjie-stdx   # cjpm.toml 按目标架构读取
bash _set.sh        # 等价于 cjpm update + cjpm build
```

### 2. 无硬件跑通第一条链路（Relay → Timer）

`relay-test` 不接任何硬件：Relay 把 `test` 参数转成 `delay`，经 controller 机制转发给
Timer 延时 200ms，用来验证安装是否成功：

```bash
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

看到 `Relay: test=200 note=hello-relay -> delay=200` 且正常退出，即链路跑通。
想看每一步的参数/结果转储：

```bash
export BOT4CJ_VERBOSE=1
cat scripts/relay-test.mt | bash _run.sh --robot=robots/relay-test.sql
```

### 3. 接第一块 PCA9685

- 接线：树莓派 i2c-1（SDA1/SCL1）→ PCA9685，地址 0x40
- 参照 `robots/spider1.sql` 写自己的结构脚本：I2C 表 → PCA9685 表 → Servo 表
  （Servo 的 controller 列指向 `pca9685-0`，channel 对应接线通道）
- 跑站立动作：

```bash
cat scripts/std.mt | bash _run.sh --robot=robots/spider1.sql
```

脚本语法细节见下文「机器人结构语法」「动作脚本」两节；报错信息会指出是哪张表、
哪一行、哪一列的问题，按提示修正即可。


## 项目介绍
机器人软件通常被称为“专用软件”，想要得到一个机器人软件通常比一个普通的软件更为困难，这是因为这个世界上的机器人五花八门，所以它们的软件往往都是独特的，所以我想写一种用于描述机器人硬件和动作的通用的脚本。

`bot4cj` 基于仓颉编程语言，提供了便捷的硬件控制能力，目前支持pca9685，我通常使用树莓派作为宿主机。






## 基层硬件抽象层（HAL）

I2C/SPI 总线操作由 `modules/lib/HAL.lua` 实现（issue #14：不再依赖仓颉注册的 cfunc），
**仅支持 LuaJIT**：

- `ffi` 直调 glibc（open/ioctl/read/write/usleep），原生性能零 fork；
  fd 为真实内核句柄，跨 Lua 状态机天然有效；SPI 经 spidev ioctl（`SPI_IOC_MESSAGE` 单次传输，CS 保持低）
- **I2C 经 `I2C_RDWR` ioctl 原子事务**：读寄存器的「写指针 + 读」合并为单次内核传输，
  消除守护线程与主线程并发访问**同一器件**时的寄存器指针竞态；地址由每条 i2c_msg 携带，
  不再需要 `I2C_SLAVE` ioctl（也就没有地址被内核驱动占用的 EBUSY 问题）
- 驱动模块顶部 `dofile` 加载 HAL，函数名与原 cfunc 完全一致；Lua 5.3+ 位运算经 `bitcompat.lua`
  双兼容（LuaJIT 用内建 bit 库，纯 5.4 用算术回退）
- `modules/lib/` 收纳非驱动的库模块：`HAL.lua`（总线抽象）与 `kalman.lua`
  （一维卡尔曼滤波器，自 src/math/kalman.cj 移植，返回表风格，供驱动 dofile 后 `Kalman.new(Q,R)` / `kf:filter(dat)` 使用）
- 不依赖 HAL 的模块（Servo/dummy/Relay/kalman 等）仍可用 `luajit`/`lua5.4` 独立调试；
  总线驱动需 `luajit`（单测见 `test/test_hal_ffi.lua`、`test/test_kalman.lua`）

SPI 传输延时（delay_usecs）无 per-fd 持久化 ioctl，由传输函数的可选 `delay_us` 尾参逐次携带
（配置写在 @SPI 矩阵的 delay 列，SPI.lua 的 `call()` 随 fd 返回，经元数据引用流入设备驱动，参考 ADS1256.lua）。


## 守护线程（@Daemon）

后台持续采样（如 IMU）用 `@Daemon` 矩阵声明，宿主用 **Cangjie `spawn` 原语**起守护线程：

```sql
CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'modules/lib/daemon_probe.lua');
```

**并发模型（关键）**：
- 守护线程由 `spawn { ... }` 创建（返回 `Future`，`future.get()` 即 join）——**不能用 pthread4cj 裸线程**：foreign pthread 无 Cangjie 运行时线程态，在其上跑 @C 代码必崩（PoC 实测 3/3 SIGSEGV）；spawn 是 Cangjie 的 M:N 绿色线程（跑在 `schd-worker` 池上），运行时已附着，安全
- 守护线程持有**独立 lua_State**（`jit.off`），与主线程状态机 1:1 隔离——规避 LuaJIT VM 非线程安全
- **逐拍驱动 + 让出式节拍**：daemon_body 先 pcall 采样 chunk 一次完成 setup（chunk 定义全局 `daemon_tick` 单次采样函数），随后循环 `getglobal(daemon_tick)+pcall` 逐拍采样，**拍间用 Cangjie `sleep(Duration)`**——它会让出绿色线程、释放 schd-worker；切忌在 chunk 内用 ffi `usleep` 自旋循环，那会阻塞 worker 不放，守护数 ≥ worker 数（核数-1）时 worker 池耗尽、连主线程的 Timer sleep 都会死锁。用让出式 sleep 后实测 **8 守护（远超 4 核机的 3 worker）+ Timer 全部并发运行、干净退出**
- **IPC 经共享内存槽** `daemon_slot_t`（`modules/lib/pthread.lua` 定义布局：mutex+count+nvals+values[16]+stop）：守护侧 Lua `P.publish(slot, {...})` 写值，主线程侧 `play()` 加锁读值，双方用同一 pthread_mutex 防撕裂
- @Daemon 矩阵的 `interval` 列 = 采样间隔 ms（daemon_body 逐拍 Cangjie sleep 用，缺省 5）；关闭时 deactive **先统一给所有守护置 stop 再逐个 join**（防逐个 stop+join 时饿死者拿不到 worker 的死锁）

**采样 chunk 契约**（运行在守护线程的独立状态机；被 pcall 一次做 setup，并定义全局 `daemon_tick`）：
```lua
if jit then jit.off() end
local P = dofile(.../lib/pthread.lua)
dofile(.../lib/HAL.lua)              -- 采样要用 HAL
local slot = P.slot_attach(DAEMON_SLOT_ADDR)   -- 宿主注入的槽地址全局
-- ... setup：开总线、配置传感器（本 chunk 被 pcall 一次）...
function daemon_tick()               -- daemon_body 逐拍调用（单次采样），拍间由 Cangjie sleep 让出
    local ax, ay, az = 采样()         -- 经 HAL 读传感器
    P.publish(slot, { ax, ay, az })
end
```

采样 chunk 运行在守护线程的独立状态机里（示例见下方「万能采样 chunk」）。@Daemon 矩阵除 name/chunk 外的列会被序列化为 `DAEMON_CONFIG` 串注入 chunk，由 chunk 解析。

**启动时序注意**：守护线程 setup（开总线 + 配置传感器）需数毫秒；若动作序列极短（几行瞬时 play），可能在守护首次采样前就 free() 停止（表现为 publishes=0）。真实机器人动作序列为秒级，无此问题；测试时用 Timer 延时列拉长主线程时间窗。

**万能采样 chunk（零 per-sensor 代码）**：`modules/lib/sensor_daemon.lua` 服务任意 build/call/destroy 型驱动——@Daemon 矩阵配置 driver/proto/path/addr/interval/fields/sign（其余任意键透传给驱动 call 作附加参数，如 channel/pga），无需为每个传感器写 Lua：

```sql
CREATE TABLE Daemon (
	name String, chunk String, driver String, proto String,
	path String, addr String, interval String, fields String, sign String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('imu0', 'modules/lib/sensor_daemon.lua', 'MPU6050', 'i2c',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z', '16');
```

（fields 用 `|` 分隔以避开 SQL 值分隔符逗号；sign=16 表示对提取值做 16 位补码符号扩展）

**数据消费（闭环）**：守护 `play()` 把采样值以标量键 `v0..vN`（外加 count/nvals/status）返回。别的硬件变量只要在矩阵里用一列**引用守护变量名**，即经 `_getMetadata` 引用机制拿到这些值（标量键能过 call_lua，JsonArray 不能，故用 v0..vN）。`modules/Monitor.lua` 是示例：@Monitor 的 src 列填守护名，call() 里 `data.v0` 即实时采样值，决策后可经 controller 列转发执行器，形成「守护采样 → 引用消费 → 决策 → 转发执行」闭环。

**滤波器硬件变量**：每个滤波器 = `lib/<filter>.lua` 库（统一 `.new()` + `:filter(x)` 接口，lua5.4/luajit 双兼容）+ `<Filter>.lua` 驱动（@矩阵名对应）。驱动的 src 列引用守护/传感器，call 逐拍滤波，输出既作 `out` 也别名 `v0`（成为「虚拟传感器」，下游按 v0 统一消费）；滤波器实例存驱动模块级 local，**状态跨 call 保持**。现有滤波器：

- **Kalman**（`lib/kalman.lua` + `Kalman.lua`）：一维卡尔曼，配置 `Q`/`R`（系统/测量噪声协方差）
- **Ema**（`lib/ema.lua` + `Ema.lua`）：指数移动平均（一阶低通），配置 `alpha`∈(0,1]（越小越平滑）、可选 `init`

三级引用链示例（守护采样 → 滤波 → 消费）：

```sql
CREATE TABLE Daemon (name String, chunk String);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'modules/lib/sensor_daemon.lua');  -- 采样
CREATE TABLE Kalman (name String, Q String, R String, src String, field String);
INSERT INTO Kalman (name, Q, R, src, field) VALUES ('kf0', '20', '200', 'imu0', 'v0');  -- 卡尔曼
-- 或 EMA：CREATE TABLE Ema (name String, alpha String, src String, field String);
--        INSERT INTO Ema (name, alpha, src, field) VALUES ('ef0', '0.3', 'imu0', 'v0');
CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', 'kf0');  -- 消费滤波值
```

引用链 `imu0 → kf0 → mon0` 全靠既有引用机制自动串联（播放 mon0 会递归播放 kf0、imu0）。也可直接在 @Action 里以 `kf0.in`/`ef0.in` 列喂待滤值（无需 src）。注意：滤波变量每被 play 一次推进一拍，多消费者引用同一滤波器会重复推进。


## 环境变量

| 变量 | 说明 |
| --- | --- |
| `BOT4CJ_MODULE_PATH` | 驱动模块目录（默认 `./modules`），框架加载 `<矩阵名>.lua` 与驱动 dofile `lib/` 均按其解析 |
| `BOT4CJ_VERBOSE` | 设置后恢复框架与驱动层的逐次调用调试输出（参数/结果转储）；缺省静默，错误信息始终打印 |

安全说明：框架加载 Lua 驱动后会中和 `os.execute` / `io.popen`（shell）、`os.exit`（进程退出）、`io.open` / `io.lines` / `os.remove` / `os.rename`（任意文件读写）；`os.getenv`、`dofile`、`require`（HAL 依赖 ffi）保留。


## 解析器

树莓派通过I2C接口连接pca9685后使用如下方法使用：

```bash
cat scripts/std.mt | bash _run.sh --robot=robots/spider1.sql	# 蜘蛛机器人站立脚本
```

动作脚本从管道输入，机器人结构从--robot




## 动作脚本

项目中包含的动作脚本在scripts文件夹下面，这些动作脚本的适配机器人结构如下

```textplain
# PCA9685
1号舵机(s1)		=>	左下水平关节
2号舵机(s2)		=>	左下垂直关节
3号舵机(s3)	 	=>	右下水平关节
4号舵机(s4)		=>	右下垂直关节
5号舵机(s5)		=>	右上水平关节
6号舵机(s6)		=>	右上垂直关节
7号舵机(s7)		=>	左上水平关节
8号舵机(s8)		=>	左上垂直关节
9号舵机(s9)		=>	云台1
10号舵机(s10) 	=>	云台2
扬声器(spk)		=>  仅负责延时
```

### 机器人结构语法

robot机器人结构示例（新版结构脚本为 .sql 文件，由 SQL4cj 解析，支持 `--` 单行注释与块注释；旧版 .mt 结构矩阵已废弃）：

```sql
/* 在 @Action 矩阵中，硬件变量的参数可以使用别名 */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES (A, angle);
INSERT INTO Alias (name, alias) VALUES (F, frequency);


/* 定义I2C硬件 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-0', '/dev/i2c-0');
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');


/* 定义pca9685硬件 */
CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca9685-0', 'i2c-1', '0x40');


/* 定义mpu6050硬件（持续采样建议改用上文 @Daemon 守护，见「万能采样 chunk」） */
CREATE TABLE MPU6050 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO MPU6050 (name, I2C, address) VALUES ('mpu6050-0', 'i2c-1', '0x69');
-- INSERT INTO MPU6050 (name, I2C, address) VALUES ('mpu6050-1', 'i2c-1', '0x68');
-- INSERT INTO MPU6050 (name, I2C, address) VALUES ('mpu6050-2', 'i2c-0', '0x68');
-- INSERT INTO MPU6050 (name, I2C, address) VALUES ('mpu6050-3', 'i2c-0', '0x69');


/* 定义扬声器位：旧版 @Speaker 矩阵已移除，现在仅用 Timer 负责延时 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('spk');


/* 定义舵机硬件：max 限幅（负值表示方向反向）、offset 中位漂移，"-" 继承上一行 */
CREATE TABLE Servo (
	name       String,
	max        String,
	min        String,
	offset     String,
	controller String,
	channel    String
);
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s1,  90, -, -, 'pca9685-0', 0);	-- 左下水平关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s2, 180, -, -,          -, 1);	-- 左下垂直关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s3, -90, -, -,          -, 2);	-- 右下水平关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s4,-180, -, -,          -, 3);	-- 右下垂直关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s5,  90, -, -,          -, 4);	-- 右上水平关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s6, 180, -, -,          -, 5);	-- 右上垂直关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s7, -90, -, -,          -, 6);	-- 左上水平关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s8,-180, -, -,          -, 7);	-- 左上垂直关节
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s9, 180, -, -,          -, 8);	-- 云台1
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES (s10,180, -, -,          -, 9);	-- 云台2
```

> 说明：`-` 是占位符，表示继承上一行同列的值（如 s2-s10 的 controller 继承 s1 的 `pca9685-0`）；
> 注释整行 INSERT 即可下线一个硬件实例（如上被注释的 mpu6050-1 ~ mpu6050-3）。

### controller 引用（通用）

除 `Servo` 外，任何硬件矩阵都可以声明一个 `controller` 列，把该硬件变量的调用转发给另一个硬件变量：

- 先运行自己的 Lua 驱动（`modules/<矩阵名>.lua` 的 `call`）
- 框架再把「该行元数据（跳过 `name`/`controller` 列） ∪ 自己 Lua 的返回表」发送给 `controller` 指定的硬件变量
- `controller` 的值支持 `-` 占位符继承上一行
- 被引用的 controller 必须在结构脚本中先于引用它的矩阵定义

可运行示例（`Relay` 把参数转成 `delay` 后交给 `Timer` 延时）：

```sql
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'hello-relay');
```

```bash
cat scripts/relay-test.mt | ./bot --robot=robots/relay-test.sql
```

action机器人动作脚本实例：

```
# 行动矩阵为硬件变量输入参数
@Action
s1.A  s2.A  s3.A  s4.A  s5.A  s6.A  s7.A  s8.A  s9.A  s10.A  spk.F  spk.delay;	# column name
  45     -    45     -    45     -    45     -    90     90     10        200;	# stand
  90     -     -     -     -     -     -     -     -      -      -         20;	# left-behind

  45     -     -     -     -     -     -     -     -      -      0        500;	# stand
   -     -    90     -     -     -    45     -     -      -      -         20;	# right-behind

   -     -    45     -     -     -     -     -     -      -    200        500;	# stand
   -     -     -     -    90     -     -     -     -      -      0         20;	# right-front

   -     -     -     -    45     -     -     -     -      -      -        500;	# stand
   -     -     -     -     -     -    90     -     -      -      -         20;	# left-front

   -     -     -     -     -     -    45     -     -      -      -        500;	# stand
   -     -     -     -     -     -     -     -     -      -      -         20;	# stand
@

```

动作脚本中也可以内联定义 `@Alias`（别名矩阵），无需写进结构脚本：

```mt
# 与 @Action 写在同一个 .mt 文件中
@Alias
name  alias;
   A  angle;
   F  frequency;
@

@Action
s1.A  spk.F;
   45    10;
@
```

- 结构脚本（.sql）与动作脚本（.mt）两侧都可以定义别名
- 同名时**动作脚本的定义覆盖结构脚本**（会打印覆盖日志）
- 同一动作脚本内重复定义同名别名会报错

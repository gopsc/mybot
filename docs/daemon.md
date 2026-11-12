# @Daemon 守护线程（后台采样）

> 本文介绍 `@Daemon` 守护线程的并发模型、万能采样 chunk 与滤波器链路。[README](../README.md) 只留入口链接，机制细节以本文为准。

## 概述

有些传感器要**一刻不停地读**（如 IMU）。`@Daemon` 用 C++ `std::thread` 起一个后台线程循环采样，主线程随取随读：

```sql
CREATE TABLE Daemon (name String, chunk String);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'lib/daemon_probe.lua');
```

## 并发模型关键点

- 每个守护 = 独立线程 + **独立 Lua 状态**，规避 LuaJIT VM 非线程安全
- 共享内存槽 + pthread 互斥锁：守护侧 `P.publish(slot,{...})` 写，主线程侧 `play()` 加锁读
- 共享槽（ABI v2，2026-10-16）：96B 头 `mutex[64]` / `count` / `nvals` / `values`（**指针**，指向随槽分配的采样数组）/ `capacity`（本槽容量，分配后不可变）/ `stop@84` / `status@88` / `quiesce@92`（BQ-1 停机灭火位，2026-09-29）；采样数组按 @Daemon 的 `maxvals` 列分配（缺省 64）——65+ 字段不再是架构上限，一行配置放行（C++ 侧 `src/daemonvar.hpp` 的 `static_assert` 与 Lua 侧 `pthread.lua` 的 `assert_layout` 双侧互锁，布局漂移在守护启动时即暴露）
- chunk 先跑一次完成 setup 并定义全局 `daemon_tick`，之后逐拍 `pcall`；**拍间用线程 sleep 让出**，切忌在 chunk 内 ffi `usleep` 自旋（阻塞调度不放）
- `@Daemon` 除 `name`/`chunk` 外的列序列化为 `DAEMON_CONFIG` 串注入 chunk
- **停机顺序（断电屏障）**：`deactivate()` 先对全体守护置 `stop`，再**统一等到退场**
  （全体共享一个 deadline = 各守护 `joinTimeout` 的最大值，避免最坏退出延迟随守护数线性增长），
  之后才逆序 `destroy()` 硬件。防的是「执行器已断电、某个在途 tick 又写它一次」——
  最后一次写随机胜出，进程退出时器件可能重新带电。
  `stop` 只在两拍之间被看见，所以屏障最坏要等一整拍。
  超时弃管的守护在弃管前被置总线灭火位（quiesce）：其后的总线传输在进内核前被 HAL
  拒绝，只有弃管瞬间已在途的一次调用可能再碰一下总线。弃管告警会如实说明：
  `not exited within <N>ms, abandoning slot and quiescing its bus access (HAL will refuse further transfers; an in-flight call may still touch the bus once)`，
  退出前另有统一计数告警（`abandonedDaemonCount`）。

## 万能采样 chunk（零 per-sensor 代码）

`lib/sensor_daemon.lua` 服务任意 build/call/destroy 型驱动：

```sql
CREATE TABLE Daemon (
	name String, chunk String, driver String, proto String,
	path String, addr String, interval String, fields String, sign String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2c',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');
```

`fields` 用 `|` 分隔以避开 SQL 逗号；`sign=16` 表示 16 位补码符号扩展；逐字段后缀可覆盖（`:f` 原样透传浮点，`:s16` 强制补码）。

## 槽容量（maxvals 列）与多守护聚合器（sources 列）

两项都属路线图阶段 2「多传感器聚合」（2026-10-16）：

**`maxvals` 列** —— 每守护声明槽容量，整数 1..1024（缺省 64）。`fields` 的数量校验按**本行** `maxvals` 判（加载期拒绝，报错点名行内值与硬上限）；采样数组按它分配。多路传感器拼进一个槽从此是一行配置，不再是编译期上限。

**`sources` 列 + `lib/sensor_aggregate.lua`** —— 一路守护聚合多路 peer 守护的最新快照到**同一个槽**：

```sql
CREATE TABLE Daemon (name String, chunk String, sources String, interval String, maxvals String);
INSERT INTO Daemon (name, chunk, sources, interval, maxvals)
  VALUES ('agg0', 'lib/sensor_aggregate.lua', 'imu0|baro0', '20', '16');
```

- peer 必须在**更早的行**声明（与 `$` 引用 / controller 的先声明后引用同族；于是环在结构上不可能，链式聚合 `agg1(agg0(x))` 合法）。引用自己、重名、空令牌、未知名都在**结构脚本加载期**拒绝（`src/daemonconf.cpp` 的 `resolveDaemonSources`）
- 宿主把各 peer 槽以 `DAEMON_PEER_SLOTS` 表注入聚合守护的 Lua 状态；聚合器不碰任何总线，逐拍读 peer 最新快照、按 `sources` 声明序拼接成**一次 publish**——消费方（`@Ema`/`@Monitor`）一个 `$agg0` 引用拿到统一视图（v 下标 = sources 序 × 各 peer 字段序），跨源时差收敛到聚合 interval
- peer 槽由聚合守护以强引用保活：peer 被热删除后其槽不会提前释放（无 use-after-free），但聚合器检测到 peer 的 `stop` 位即**永久失败**（status=-11）——绝不静默发布陈旧快照或缺一段后悄悄移位的 v 序；peer setup 失败同理（status=-10）。拼接总数超本槽 `maxvals` 也在首拍判为配置错误（status=-2）
- 「任一 peer 尚未首发」是瞬时状态：整拍不发布、限频日志点名 peer，与单守护「等首帧」语义一致

## 仿真器采样 chunk（`lib/sim_sensor_daemon.lua`）

把 mybot-sim 的 IMU/里程计桥（[sim.md](sim.md)）采样进共享槽：`kind=imu` 发布
`yaw_deg|gyro_z|acc_fwd|vy|airborne` 5 字段，`kind=odom` 发布 `x|z|theta_deg|v|odo`
5 字段。复用 `modules/Sim.lua` 的 `imu()`/`odom()` 客户端，协议单点不在 chunk 里。

- **不碰硬件总线**：数据源是仿真器进程，没有 fd 要开；槽协议仍走 `lib/pthread.lua`。
- **仿真器缺席不是永久失败**：客户端每次 call 惰性重连（仿真器后起即接上），缺席按
  **逐拍错误**处理（count 停滞 + 限频日志），不写 status 失败码——与「驱动加载失败」
  这类永不自愈的失败区分。唯一永久失败是 `kind` 配置错误（status=-2）。
- 与 `sources` 聚合连用即「仿真多路观测拼进一个槽」：`imu0|odom0` 聚合 10 值一个
  `$agg` 引用拿全（全栈示例 [robots/spider_sim_nav.sql](../robots/spider_sim_nav.sql)；
  守门 e2e 见 `test/run_all.sh` 的 sim_nav 段，仿真器由 `test/lib/sim_responder.lua`
  应答桩顶替——GL 壳在 CI/无显示环境不可构建）。

## 滤波器硬件变量（虚拟传感器）

每个滤波器 = `lib/<filter>.lua` 库（`.new()` + `:filter(x)`）+ `<Filter>.lua` 驱动：

- `Kalman`：一维卡尔曼，配 `Q`/`R`
- `Ema`：指数移动平均，配 `alpha`∈(0,1]

三级引用链 `imu0 → kf0 → mon0` 靠既有引用机制自动串联（播放 mon0 会递归播放 kf0、imu0）。

## 守护无硬件端到端

`@Daemon` 的 `proto` 列填 `virt` 即可做**守护无硬件端到端**：真实驱动 build/call、共享槽 publish、`@Ema/@Kalman` 滤波、`@Monitor` 消费全链路走内存仿真（启动打印 `VIRTUAL HARDWARE` 横幅，仿真数据禁止用于生产）。

## 进阶示例：守护采样 → 滤波 → 消费闭环

```sql
CREATE TABLE Daemon (name String, chunk String);
INSERT INTO Daemon (name, chunk) VALUES ('imu0', 'lib/sensor_daemon.lua');   -- 采样

CREATE TABLE Kalman (name String, Q String, R String, src String, field String);
INSERT INTO Kalman (name, Q, R, src, field) VALUES ('kf0', '20', '200', '$imu0', 'v0');

CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$kf0');   -- 消费滤波值
```

`modules/Monitor.lua` 即此类示例：`call()` 里 `data.v0` 拿到实时采样值，决策后可经 controller 转发执行器。

## 配置 schema 加载期校验

`@Daemon` 的框架列在**结构脚本加载期**（`src/daemonconf.cpp` 的工厂，与 `interval` 校验同处）即校验，非法值当场报错并点名守护名/列/表/行号——不等守护线程 setup 才失败，也不静默降级：

- `proto`：只接受 `i2c`（缺省）/ `spi` / `uart` / `virt`。拼错（如 `i2`）此前会静默落进 i2c 分支去开总线；
- `fields`：`<名>[:<模式>]`，模式 ∈ 缺省（跟随 `sign`）/ `f` / `float` / `s16`；空项（`A||B`、首尾分隔符）与未知模式（`TEMP:xyz`）此前分别被静默丢弃、静默当浮点透传；
- `sign`：必须是整数（如 `16`）；非数值此前被 `tonumber` 折成 nil，符号扩展静默失效。
- `maxvals`：本行槽容量，整数 1..1024（缺省 64；`fields` 数量按它校验）。
- `sources`：peer 守护名清单（`|` 或 `,` 分隔）；空令牌、自引用、重名、未知名（含
  声明在自己之后的）都在加载期拒绝，见上文「多守护聚合器」。
- `kind`：`lib/sim_sensor_daemon.lua` 的采样种类（`imu` | `odom`，2026-10-16）；
  拼错在加载期拒绝（放行只有守护 setup 的 status -2 一个间接症状）。
- **任意列的字符集**：值里不得含 `NUL` 或 `;`（审计 P4）。`DAEMON_CONFIG` 是
  `k=v;k=v` 串、经 `lua_pushstring` 注入（C 字符串语义），Lua 侧按 `;` 切列、
  每列再按**第一个** `=` 分割键值（`sensor_daemon.lua`）——NUL 会把它**其后所有列**（含 `proto`/`sign`）
  在 Lua 侧静默抹掉，而上面几条 schema 校验跑在逐列原始串上全部通过，
  即「校验看到的」与「守护拿到的」不是同一份配置；`;` 则截断该值，且若其后片段
  形如 `key=` 还会**注入/覆盖**守护理解的键。放过之后运行期只剩
  `no daemon value` 这类间接症状，故一律加载期报错。
  `=` 是**允许**的（键的模式不含 `=`、值的模式可含 `=`，`extra=a=b` 能原样往返）。
  词法器契约夹具 `robots/test/sqlquote.sql` 因此把带 `;` 的字面值放在普通硬件表里，
  而不是 `@Daemon` 列——词法路径与表名无关，覆盖不减。

矩阵空占位符 `-` 一律视作「未提供」。其余任意键是驱动的 build 参数（`channel`/`pga`/`rshunt`/`osr`…），框架不拦截。

## setup 失败的响亮契约

守护 setup 失败（驱动缺失/加载失败、开总线失败等）是**永久性**失败，**绝不伪装成采样值**：

- 失败码（-9 缺 driver、-8 驱动加载失败、-1 开总线失败、-3 spi setup 失败、-2 build 失败；聚合 chunk 另有 -10 peer setup 失败、-11 peer 已停止、-12 sources 未注入）写进槽的 `status` 字段（`P.set_status`），不是发进 v0 的一个负样本——否则下游 `$` 引用无从甄别，配置错误会被当温度做闭环，只有 `count` 停滞这种间接迹象；
- 宿主侧读路径见 `status ≠ 0` 即抛错（`daemon setup failed (slot status -8); no samples are published`），动作链响亮中止；失败码与原因以守护日志为准；
- 与「尚未出首帧」区分：那是**瞬时**状态，由消费方（`@Monitor`/`@Ema`/`@Kalman`）按 ERR 契约自行表达，不在读路径抛。

## 注意事项

守护 setup 需数毫秒；动作序列极短时可能守护尚未首发就被停止（publishes=0）。真实动作序列为秒级没问题；测试用 Timer 延时列拉长主线程时间窗。

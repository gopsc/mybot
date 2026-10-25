/*
 * AS7262 无硬件端到端（proto=virt，首个「硬件仅 3 寄存器 + 虚拟寄存器
 * 间接窗口 + TX/RX 就绪握手」I2C 器件）：sensor_daemon 不打开真机 I2C，
 * 而是挂内存仿真模型 modules/lib/virtbus/as7262.lua。I2C 总线上器件只
 * 暴露 STATUS 0x00（bit1=TX_VALID、bit0=RX_VALID）、写口 0x01、读口
 * 0x02；DEVICE_TYPE/CONTROL/INT_T/六通道等虚拟寄存器（0x00~0x13）全部
 * 经 SparkFun 同款握手访问（读=等TX空→写口发地址→等RX→读读口；
 * 写=等TX空→写口发 地址|0x80→再等TX空→写口发数据）。模型零延迟握手，
 * 守护跑的是【真实】AS7262.lua 完整 build（读 CONTROL→RST 位后真实
 * milli_sleep 1000ms，守护不打桩→甄别 0x3E→写 INT_T→RMW 配 GAIN/
 * BANK=2 连续全通道）与 call（轮询 CONTROL bit1=DATA_RDY→读六通道
 * 16 位计数 MSB 偶地址+温度补码→RMW 清 DATA_RDY）。
 *
 * 模型每拍 virt_tick 造六通道确定性正弦计数（V 9000±3000、B/G/Y/O/R
 * 各自基线幅值，32 拍周期：V n0=9000、n8 峰 12000、n24 谷 6000；温度
 * 25±4°C）并预武装（直接置 DATA_RDY 并把样本锁入数据寄存器）——守护
 * 不推进虚拟时钟，call 首读 CONTROL 即就绪、零真实睡眠，一拍对应一个
 * virt_tick；未武装路径走真实转换门 INT_T×5.6ms（单测边界覆盖）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=V 通道计数做 α=0.2 一阶滤波（:f 浮点透传，禁止取整补码）
 *   → Monitor 引用消费。mon0 直连守护 as7（raw 六通道计数 + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1~v5 = B/G/Y/O/R 原始计数（无符号 0~65535，全字段 :f 原样透传，
 *   切不可走 sign=16 补码——≥32768 的计数会被误转负数）。
 *
 * Daemon 额外列 gain/integ 自动透传 build 参数（sensor_daemon 的 known
 * 表只排除框架键）：GAIN=16x、integ=50（连续全通道一轮约 280ms，预武装
 * 路径 call 零睡眠不受限）。
 *
 * 配合 as7262_virt.mt：首行 1200ms 预热等守护 setup（必须容纳 build 的
 * RST 真实睡眠 1000ms），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（武装后 call 零睡眠，远快于 50ms 拍点，count 增长）。
 * 用法：cat scripts/test/as7262_virt.mt | bash _run.sh --robot=robots/test/as7262_virt.sql
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	addr     String,
	interval String,
	fields   String,
	sign     String,
	gain     String,
	integ    String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, gain, integ)
  VALUES ('as7', 'lib/sensor_daemon.lua', 'AS7262', 'virt',
          '/dev/i2c-1', '0x49', '20', 'V:f|B:f|G:f|Y:f|O:f|R:f', '16', '16', '50');

/* 一阶低通滤波器：只滤 v0=V 通道计数（:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$as7', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$as7');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

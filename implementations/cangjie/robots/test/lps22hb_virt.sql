/*
 * LPS22HB 无硬件端到端（proto=virt，「8 位寄存器指针 + 5 字节小端 burst +
 * 地址 bit7 自动增量 + 三个自清零命令位 + 单次转换门」I2C 气压计——ST
 * MEMS，SA0 选 0x5D/0x5C）：sensor_daemon 不打开真机 I2C，而是挂内存
 * 仿真模型 modules/lib/virtbus/lps22hb.lua。模型复刻协议——
 * WHO_AM_I(0x0F)=0xB1 只读（0xBD=LPS25HB 代际拦截）、CTRL_REG2(0x11)
 * bit2 SWRESET 自清零（build 写 0x04 后 1ms 轮询至 0，耗尽 20ms 也不致命）、
 * CTRL_REG1(0x10) 写 0x02（BDU+ODR=000 单次/power-down）；call 先读
 * CTRL_REG2 再 RMW 置 bit0 ONE_SHOT（保高位）、轮询 bit0 自清（转换
 * 完成），最后 i2c_read_multi(0xA8,5)——指针 0xA8=0x28|0x80，bit7=1
 * 地址连续自增——读出【小端】气压 24 位（XL,L,H）+ 温度 16 位（L,H）。
 * 全软件换算 P=raw/4096 hPa、T=raw/100 °C 在真实 LPS22HB.lua 驱动内。
 *
 * 模型每拍 virt_tick 造确定性同相正弦（32 拍周期）：P 1013.25±5hPa
 * （1008.25~1018.25，海平面常压）、T 22±2°C（20~24）。build 前预武装
 * virt_tick(0)：SWRESET 即时完成且不消费武装，build 7 事务零真实睡眠；
 * 每拍 tick 后 call 的 ONE_SHOT 也即时完成（8 事务零睡眠），门限只在
 * 脱守护单测里由 milli_sleep→advance 推虚拟时钟验证。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=P 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 ba0（raw 两字段 + count）；
 *   monf 引用 ebp（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=T 浮点不滤波。
 *
 * wait 列透传驱动 build（非守护框架键，原样进 params）：单次转换超时
 * 预算 ms，显式给缺省 50，验证器件专用参数经守护到驱动的全链路。
 *
 * 配合 lps22hb_virt.mt：200ms 预热等守护 setup（武装路径 build/call 均
 * 零睡眠，余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=50ms（武装 call 零睡眠，count 持续增长）。
 * 用法：cat scripts/test/lps22hb_virt.mt | bash _run.sh --robot=robots/test/lps22hb_virt.sql
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
	wait     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, wait)
  VALUES ('ba0', 'lib/sensor_daemon.lua', 'LPS22HB', 'virt',
          '/dev/i2c-1', '0x5D', '50', 'P:f|T:f', '16', '50');

/* 一阶低通滤波器：只滤 v0=P（:f 浮点透传，禁止取整）；
 * T 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ebp', '0.2', '$ba0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ebp（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ba0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ebp');

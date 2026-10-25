/*
 * PCF8574 无硬件端到端（proto=virt，无寄存器图 · 单字节 P 口写 + 无指针
 * 纯读器件）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/pcf8574.lua。守护跑的是【真实】PCF8574.lua 完整
 * build（地址族校验 → i2c_set_addr → 一次纯读 ACK 在位甄别 → 写 1 字节
 * 初始锁存 0xFF，无 milli_sleep）与 call（不传 out = 纯读引脚 1 字节，
 * 模块级 cfg_latch 保持 build 的 0xFF）。
 *
 * 模型每拍 virt_tick 把外部拉低掩码置为 walking 低电平位（8 拍周期轮询
 * P0~P7，模拟按键）：引脚读值 = latch 0xFF & ~掩码 → 254/253/251/247/
 * 239/223/191/127 随拍变化（守护 count 通用断言有 ≥2 个不同值）；OUT
 * 是输出锁存，守护不发 out 列故恒为 255。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=PINS 做 α=0.2 一阶滤波（:f 浮点透传，整型引脚码变成
 *     带小数的混合值，浮点断言锚 monf 行 out）
 *   → Monitor 引用消费。mon0 直连守护 io0（raw PINS/OUT）；monf 引用
 *   eavg（滤波后引脚码，验证 Ema→Monitor 闭环）。
 *
 * 配合 pcf8574_virt.mt：首行 200ms 预热等守护 setup（build 无真实睡眠，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（纯读 call 零睡眠）。
 * 用法：cat scripts/test/pcf8574_virt.mt | bash _run.sh --robot=robots/test/pcf8574_virt.sql
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
	sign     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('io0', 'lib/sensor_daemon.lua', 'PCF8574', 'virt',
          '/dev/i2c-1', '0x20', '20',
          'PINS:f|OUT:f', '16');

/* 一阶低通滤波器：只滤 v0=PINS 引脚码通道（:f 浮点透传） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$io0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$io0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

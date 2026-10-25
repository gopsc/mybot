/*
 * CHT8305 无硬件端到端（proto=virt，「8 位字寄存器指针 + 无指针纯读 +
 * 每通道转换门 + 双 ROM ID 甄别」I2C 虚拟器件——申矽凌微 SensyLink
 * CHT8305C，AD0 选 0x40~0x43，悬空 0x40）：sensor_daemon 不打开真机
 * I2C，而是挂内存仿真模型 CHT8305_VIRT（内嵌于 modules/CHT8305.lua 尾部，
 * 2026-09-15 迁入，守护经回退路径装载）。模型复刻
 * 指针式字寄存器协议——6 指针稀疏地图（0x00 T/0x01 H 只读测量字、
 * 0x02 配置、0x03 告警限、0xFE MID=0x5959、0xFF DID=0x8305，其余整笔
 * NACK）、纯指针写恰 1 字节、字写 {ptr,MSB,LSB} 大端、纯读 i2c_read
 * 不带指针（区别 i2c_read_multi）；守护跑的是【真实】CHT8305.lua 的
 * 完整 build（{0x02,0x80} 半字软复位（高字节 bit7=bit15）→sleep 10ms
 * →MID/DID 双 ROM 自检）与 call（T 指针→14ms 转换等待→纯读，H 同，
 * 共 28ms 真实睡眠；T=raw×165/65535−40、H=raw×100/65535 全在驱动）。
 *
 * 模型每拍 virt_tick 造确定性【反相】正弦（32 拍周期：T 25±5°C
 * 20~30、H 50∓10%RH 60~40，温峰湿谷）并预武装——守护不驱动虚拟时钟，
 * 测量指针写即就绪；武装跨 build 内软复位保留（build 前 tick 一次，
 * 复位不断流），驱动自身 milli_sleep 在守护线程照真实睡眠。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=T 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 th0（raw 两字段 + count）；
 *   monf 引用 eavg（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=H 浮点不滤波。
 *
 * 配合 cht8305_virt.mt：200ms 预热等守护 setup（build 真实睡眠 10ms，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护
 * interval=50ms（call 内含 2×14ms 转换真实等待=28ms，节拍再短会溢出）。
 * 用法：cat scripts/test/cht8305_virt.mt | ./build/mybot --robot=robots/test/cht8305_virt.sql
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
  VALUES ('th0', 'lib/sensor_daemon.lua', 'CHT8305', 'virt',
          '/dev/i2c-1', '0x40', '50', 'T:f|H:f', '16');

/* 一阶低通滤波器：只滤 v0=T（:f 浮点透传，禁止取整）；
 * H 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$th0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$th0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

/*
 * MCP3421 无硬件端到端（proto=virt，首个「单字节配置写 + 数据流纯读、
 * 读回帧自带配置回显/RDY 就绪位」的命令式 I2C 虚拟器件）：sensor_daemon
 * 不打开真机 I2C，而是挂内存仿真模型 modules/lib/virtbus/mcp3421.lua。
 * 模型复刻协议——无寄存器指针：写恒 1 字节配置（[7]RDY [4]O/C
 * [3:2]分辨率 [1:0]PGA），读恒无指针纯读，末字节配置回显 bit7 RDY
 * 兼作就绪握手（0=新数据）；12bit 档 3 字节帧（16 位字顶部重复符号位
 * +回显）。守护跑的是【真实】MCP3421.lua 的完整 build（写配置→纯读
 * 回显比对低 6 位兼在位探测）与 call（轮询 RDY 5ms 步进→补码解码→
 * voltage=raw*2.048/2^(res-1)/pga）。
 *
 * 选 12bit/×1/连续档：转换门仅 5ms（18bit 档要 267ms）；模型每拍
 * virt_tick 在 ±1.5V 空间造确定性正弦（32 拍周期，12bit/×1 即
 * ±1500 LSB、1mV/LSB）并预武装——守护不驱动虚拟时钟，首读 RDY=0
 * 立即返回，连续模式 call 无触发写、零真实睡眠。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=voltage 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 adc0（raw voltage + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *
 * 配合 mcp3421_virt.mt：300ms 预热等守护 setup（build 无睡眠），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 用法：cat scripts/test/mcp3421_virt.mt | bash _run.sh --robot=robots/test/mcp3421_virt.sql
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
	res      String,
	pga      String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, res, pga)
  VALUES ('adc0', 'lib/sensor_daemon.lua', 'MCP3421', 'virt',
          '/dev/i2c-1', '0x68', '50', 'voltage:f', '-', '12', '1');

/* 一阶低通滤波器：只滤 v0=voltage（:f 浮点透传，禁止取整，差分电压有负值） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$adc0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$adc0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

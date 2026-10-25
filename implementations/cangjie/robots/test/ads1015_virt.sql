/*
 * ADS1015 无硬件端到端（proto=virt，ADS1115 的 12 位快速孪生——同一
 * 「字寻址 16 位寄存器 + oneshot 转换门/OS 就绪握手」范式：寄存器号
 * 0x00~0x03 各代表一个 16 位字，不能套字节地址 regmap）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/ads1015.lua。模型复刻协议——0x00 CONVERSION 为
 * 12 位有符号码【左对齐】存放（低 4 位恒 0，有效码 -2048~2047，驱动
 * 算术右移 4 位）、0x01 CONFIG（[15]OS [14:12]MUX [11:9]PGA [8]MODE
 * [7:5]DR）、0x02/0x03 阈值；OS 位读写语义相反（写 1 单次模式启动
 * 转换，读时转换中=0/空闲=1，模型读回 bit15 按转换状态动态合成），
 * 转换门=1000/SPS（默认 DR 位 100 在 ADS1015 是 1600SPS=0.625ms；
 * 同字 0x4583 在 ADS1115 是 128SPS，超时预算 100 次轮询对 200 次）。
 * 守护跑的是【真实】ADS1015.lua 的完整 build（写 CONFIG 0x4583 →
 * 2B 回读，零睡眠）与 call（读 CONFIG 保 PGA/DR → 写 OS=1 启动 →
 * 1ms 步进轮询 OS 位 → 读 CONVERSION，V=raw12*FS/2048 全软件换算）。
 *
 * 模型每拍 virt_tick 在 AIN0 单端空间造确定性正弦（1.65 ± 0.25V =
 * 1.40~1.90V，PGA=2 ±2.048V 量程内，32 拍周期：n0=1.65V、n8 峰 1.90V、
 * n24 谷 1.40V）并预武装——下一次 OS=1 启动写立即完成（首读 OS 即 1、
 * 结果已装载），驱动 1ms 轮询零真实睡眠；未武装路径走真实转换门
 * （单测八档 ε 边界覆盖）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=voltage 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 ad0（raw voltage + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *
 * Daemon 额外列 pga/dr/channel 自动透传 build 参数（sensor_daemon 的
 * known 表只排除框架键）：PGA=2 ±2.048V、DR=4 1600SPS、AIN0 缺省。
 *
 * 配合 ads1015_virt.mt：200ms 预热等守护 setup（build 零睡眠），随后
 * 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=20ms（武装后
 * call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/ads1015_virt.mt | bash _run.sh --robot=robots/test/ads1015_virt.sql
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
	pga      String,
	dr       String,
	channel  String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, pga, dr, channel)
  VALUES ('ad0', 'lib/sensor_daemon.lua', 'ADS1015', 'virt',
          '/dev/i2c-1', '0x48', '20', 'voltage:f', '16', '2', '4', '0');

/* 一阶低通滤波器：只滤 v0=voltage（:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$ad0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ad0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

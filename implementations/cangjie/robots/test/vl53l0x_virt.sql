/*
 * VL53L0X 无硬件端到端测试（proto=virt，首个 8 位寄存器指针 + 0xFF 分页的
 * I2C 虚拟器件）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/vl53l0x.lua。模型按（页, 寄存器）双键存储，复刻
 * DataInit 舞步、page6/7 SPAD 握手、SYSRANGE 连续模式与 data-ready/清中断
 * 时序；守护跑的是【真实】VL53L0X.lua 的完整 build（约 90 条 tuning 写、
 * 两轮参考校准）与 call（0x13 就绪轮询、12 字节结果块、ST 状态码映射）。
 *
 * 模型每拍 virt_tick 在距离空间造确定性正弦（100~1100mm，32 拍周期，
 * 状态恒有效/2.0SPAD/25 信号/6 环境），预武装后首次轮询即就绪。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=DIST_MM 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 tof0（raw 四字段 + count）；
 *   monf 引用 ed（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=STATUS / v2=VALID 为整型码，v3=SIGNAL_MCPS 浮点，均不滤波。
 *
 * 配合 vl53l0x_virt.mt：300ms 预热等守护 setup（build 无 sleep，参考校准
 * 首次轮询即就绪），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（call 含真实就绪轮询，模型转换延时 5ms）。
 * 用法：cat scripts/test/vl53l0x_virt.mt | bash _run.sh --robot=robots/test/vl53l0x_virt.sql
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
  VALUES ('tof0', 'lib/sensor_daemon.lua', 'VL53L0X', 'virt',
          '/dev/i2c-1', '0x29', '20', 'DIST_MM:f|STATUS|VALID|SIGNAL_MCPS:f', '16');

/* 一阶低通滤波器：只滤 v0=DIST_MM(mm)（:f 浮点透传，禁止取整）；
 * STATUS/VALID 为整型码、SIGNAL 本拍恒定，mon0 直连守护即可观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ed', '0.2', '$tof0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ed（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$tof0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ed');

/*
 * SGP30 无硬件端到端（proto=virt，16 位命令字 + 每字 CRC-8、且命令带
 * 读写数据载荷的命令式 I2C 虚拟器件）：sensor_daemon 不打开真机 I2C，
 * 而是挂内存仿真模型 modules/lib/virtbus/sgp30.lua。模型复刻命令式协议——
 * Measure_test 0x2032（≤220ms，3 字节 0xD400+CRC，build 兼在位探测）、
 * Init_air_quality 0x2003（前 15s 启动相固定 400/0）、Measure_air_quality
 * 0x2008（≤12ms，6 字节 CO2eq+crc | TVOC+crc，CRC-8 poly 0x31/init
 * 0xFF 模型真算）；守护跑的是【真实】SGP30.lua 的完整 build（自检 →
 * Init，真实睡眠 222+12ms）与 call（测量命令 → 14ms 真实等待 → 无指针
 * 纯读 6 字节 → 双 CRC 校验，CRC_OK 降级不中断）。基线持久化与湿度
 * 补偿在守护原始串路径不可用（驱动注释明示），本用例不配 baseline。
 *
 * 模型每拍 virt_tick 在 IAQ 空间造确定性正弦（CO2eq 400~700ppm、
 * TVOC 40~200ppb，32 拍周期），warm=已度过 15s 启动相、预武装——守护
 * 不驱动虚拟时钟，命令下发即就绪；驱动自身 milli_sleep 在守护里是
 * 真实睡眠（build 234ms / call 14ms）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=CO2EQ 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 sgp0（raw 三字段 + count）；
 *   monf 引用 ec（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=TVOC 浮点不滤波；v2=CRC_OK 整型（模型 CRC 真算，恒 1）。
 *
 * 配合 sgp30_virt.mt：400ms 预热等守护 setup（自检 222ms 真实睡眠），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=50ms
 *（call 内含 14ms 测量真实等待）。
 * 用法：cat scripts/test/sgp30_virt.mt | bash _run.sh --robot=robots/test/sgp30_virt.sql
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
  VALUES ('sgp0', 'lib/sensor_daemon.lua', 'SGP30', 'virt',
          '/dev/i2c-1', '0x58', '50', 'CO2EQ:f|TVOC:f|CRC_OK', '16');

/* 一阶低通滤波器：只滤 v0=CO2EQ（:f 浮点透传，禁止取整）；
 * TVOC 直连守护观察即可，CRC_OK 为整型码不滤波。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ec', '0.2', '$sgp0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ec（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$sgp0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ec');

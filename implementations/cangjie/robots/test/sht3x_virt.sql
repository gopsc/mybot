/*
 * SHT3X 无硬件端到端（proto=virt，首个 16 位命令字 + CRC-8 命令式 I2C
 * 虚拟器件）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/sht3x.lua。模型复刻命令式协议——软复位 0x30A2、
 * 读状态 0xF32D（3 字节 status+CRC，bit4 复位检测）、单次高重复性
 * 轮询测量 0x2400（转换未完成纯读 NACK）、6 字节帧 T_MSB T_LSB CRC |
 * RH_MSB RH_LSB CRC（CRC-8 poly 0x31/init 0xFF 模型真算）；守护跑的是
 * 【真实】SHT3X.lua 的完整 build（软复位+状态 CRC/bit1 校验）与 call
 *（命令→16ms 等待→纯读→双 CRC 校验→T/RH 线性换算，CRC_OK 降级不中断）。
 *
 * 模型每拍 virt_tick 在温湿度空间造确定性正弦（T 20~30°C、RH 30~70%，
 * 32 拍周期）并预武装——守护不驱动虚拟时钟，命令下发即就绪；驱动自身
 * 的 milli_sleep(2+1ms build / 16ms call) 在守护里是真实睡眠。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=T 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 sht0（raw 三字段 + count）；
 *   monf 引用 et（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=RH 浮点不滤波；v2=CRC_OK 整型（模型 CRC 真算，恒 1）。
 *
 * 配合 sht3x_virt.mt：300ms 预热等守护 setup（软复位真实睡眠仅 3ms），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=50ms
 *（call 内含 16ms 转换真实等待，20ms 节拍会溢出）。
 * 用法：cat scripts/test/sht3x_virt.mt | bash _run.sh --robot=robots/test/sht3x_virt.sql
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
  VALUES ('sht0', 'lib/sensor_daemon.lua', 'SHT3X', 'virt',
          '/dev/i2c-1', '0x44', '50', 'T:f|RH:f|CRC_OK', '16');

/* 一阶低通滤波器：只滤 v0=T（:f 浮点透传，禁止取整）；
 * RH 直连守护观察即可，CRC_OK 为整型码不滤波。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('et', '0.2', '$sht0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 et（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$sht0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$et');

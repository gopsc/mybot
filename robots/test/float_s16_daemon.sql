/*
 * sensor_daemon 浮点防线 E2E：fields 列的 TEMP 是驱动换算好的摄氏度浮点，
 * 却未加 :f 后缀、跟随全局 sign=16 走 s16 补码——conv 会把 23.56 截成 23
 * 静默发布假值。守护必须拒绝发布该字段（tick 错误点名，count 停滞），
 * 日志锚点："would be truncated to integer"。
 * 配合 float_s16_daemon.mt；proto=virt 无硬件依赖，TEMP 恒为浮点。
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
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign) VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10', 'TEMP', '16');

/* Monitor 挂到 imu0 上：read() 快照字段合并进元数据 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');

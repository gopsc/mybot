/*
 * MPU6050 六轴 + 温度守护采样测试：sensor_daemon 万能采样，
 * interval=10ms，fields 七字段，sign=16（六轴原始值为有符号 16 位）。
 * TEMP 是驱动换算好的摄氏度浮点，用逐字段后缀 :f 原样透传，
 * 不跟随全局 sign=16 做整数补码（否则小数被取整破坏）。
 * Monitor（mon0）引用消费：把 imu0 的 v0..v6/count 打出来并回传 level/out，
 * 验证「守护采样 → 引用消费」链路。
 * 配合 mpu_daemon.mt
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
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign) VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2c', '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');

/* Monitor 挂到 imu0 上：src 列以 $ 前缀引用守护，read() 快照字段（v0..vN）合并进元数据 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');
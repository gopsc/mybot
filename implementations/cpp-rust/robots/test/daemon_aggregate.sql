/*
 * 多守护聚合 E2E（sources 列，2026-10-16 路线图阶段 2）：
 * 两路异型 virt 传感器（imu0 七字段 + baro0 三字段，不同 interval）经
 * agg0（lib/sensor_aggregate.lua）拼进同一槽（maxvals=16），mon0 以 $agg0
 * 引用消费——快照应含 10 个拼接值（7+3），v 序 = sources 声明序。
 * 不用的列一律 '-'（矩阵空占位符 = 未提供）。
 * 配合 daemon_aggregate.mt（先预热等首发，再逐拍消费）。
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
	sources  String,
	maxvals  String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, sources, maxvals)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10',
          'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16', '-', '-');
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, sources, maxvals)
  VALUES ('baro0', 'lib/sensor_daemon.lua', 'BME280', 'virt', '/dev/i2c-1', '0x76', '50',
          'T:f|P:f|H:f', '-', '-', '-');
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, sources, maxvals)
  VALUES ('agg0', 'lib/sensor_aggregate.lua', '-', '-', '-', '-', '20', '-', '-', 'imu0|baro0', '16');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$agg0');

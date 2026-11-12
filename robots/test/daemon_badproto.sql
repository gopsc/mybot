/*
 * 守护配置 schema 加载期校验（E2 / N-27 尾）：proto 列拼错（'i2' 而非 'i2c'）
 * 必须在**结构脚本加载期**报错，不能静默按 i2c 去开总线（旧行为：未知 proto
 * 落进 else 分支当作 i2c，用户看到的是一条成功打开的 I2C 链路 + 空数据）。
 *
 * 期望：退出码 1，信息含 "not a supported bus"，并点名守护名/列/表/行号。
 * 配合 daemon_schema.mt（占位，结构期即失败）
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
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2', '/dev/i2c-1', '0x68', '10', 'ACCEL_X');

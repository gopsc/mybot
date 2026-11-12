/*
 * 守护配置 schema 加载期校验（E2）：fields 列出现空项（重复分隔符 '||'）必须在
 * **结构脚本加载期**报错——旧行为是 string.gmatch 静默跳过空项（'A||B' 与 'A|B'
 * 等价），字段就这么少了一个而无人知晓。
 *
 * 期望：退出码 1，信息含 "empty field name"。
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
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10',
          'ACCEL_X||TEMP');

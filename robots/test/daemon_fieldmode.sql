/*
 * 守护配置 schema 加载期校验（E2）：fields 列的字段模式拼错（':xyz'）必须在
 * **结构脚本加载期**报错——旧行为是打一行日志后当浮点透传（mode="f"），
 * 语义被悄悄改写，且日志只出现在守护线程的 stderr 里、与配置错误脱节。
 *
 * 期望：退出码 1，信息含 "unknown field mode ':xyz'"。
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
          'ACCEL_X|TEMP:xyz');

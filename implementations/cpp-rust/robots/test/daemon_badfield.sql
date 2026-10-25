/*
 * 负值契约（审计 #5）：@Daemon 的 fields 列写了驱动返回表中不存在的字段名时，
 * 守护必须清晰报错并停止发布，而不是静默发布 0。
 *
 * 防线之前：字段提取走 conv()，其首行 `tonumber(v) or 0` 把缺失键折成 0，
 * 而驱动本身返回 result=OK → 走成功分支 → 零日志、count 正常自增，
 * 下游 Ema/Kalman/Monitor 于是拿「假 0」做闭环决策，且与真实 0 读数不可区分。
 *
 * 期望：退出码 0（Timer 链路正常），但日志点名缺失字段，且守护不发布
 * （无 "joined, total publishes=" 之外的 v* 采样值）。
 * 用法：cat scripts/test/daemon_badfield.mt | ./build/mybot --robot=robots/test/daemon_badfield.sql
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
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_NOPE');

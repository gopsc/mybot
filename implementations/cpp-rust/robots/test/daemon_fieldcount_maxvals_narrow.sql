/*
 * maxvals 列（ABI v2，2026-10-16）：fields 数量按**本行** maxvals 校验。
 * 本夹具：maxvals=32 + 40 个字段 → 加载期拒绝，信息含
 * "exceeds the shared-slot capacity of 32"——证明判据真的取了行内值
 * （若仍用编译期缺省 64，40 字段会误放行，本夹具即失去意义）。
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
	maxvals  String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, maxvals)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10',
          'F01|F02|F03|F04|F05|F06|F07|F08|F09|F10|F11|F12|F13|F14|F15|F16|F17|F18|F19|F20|F21|F22|F23|F24|F25|F26|F27|F28|F29|F30|F31|F32|F33|F34|F35|F36|F37|F38|F39|F40',
          '32');

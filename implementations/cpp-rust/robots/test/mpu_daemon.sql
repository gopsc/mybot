/*
 * MPU6050 六轴 + 温度守护采样测试：sensor_daemon 万能采样，
 * interval=10ms，fields 七字段，sign=16（六轴原始值为有符号 16 位）。
 * TEMP 是驱动换算好的摄氏度浮点，用逐字段后缀 :f 原样透传，
 * 不跟随全局 sign=16 做整数补码（否则小数被取整破坏）。
 * Monitor（mon0）引用消费：把 imu0 的 v0..v6/count 打出来并回传 level/out，
 * 验证「守护采样 → 引用消费」链路。
 * 配合 mpu_daemon.mt
 *
 * proto=virt（N-27 起）：本用例只验链路，不依赖主机是否有 /dev/i2c-1——
 * 原先写 proto=i2c 时，无真机的主机上守护 setup 会失败，而用例仍以 rc=0
 * 通过（失败码被当 v0 采样值发布）；有真机的主机上则真去打开总线。两者都
 * 不是本用例想测的。改 virt 后结果与主机环境无关，确定性。守护 setup 失败
 * 的响亮契约另由 daemon_setup_fail.sql 覆盖。
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
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign) VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');

/* Monitor 挂到 imu0 上：src 列以 $ 前缀引用守护，read() 快照字段（v0..vN）合并进元数据 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');
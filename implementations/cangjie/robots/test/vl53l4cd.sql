/*
 * VL53L4CD ToF 激光测距测试（配套 vl53l4cd.mt）
 * 直连变量（tof0）单次读 + 万能守护（tof-d0）连续采样双路径
 * 量程 ~1mm~1.2m，18° 窄视场；地址固定 0x29，一条总线单只
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* VL53L4CD：地址固定 0x29；budget = 单次测量 timing budget ms（10~200，缺省 50）；
 * inter = 测量间隔 ms（0 = 连续缺省，>budget = 自主低功耗）；
 * timeout = data-ready 等待超时 ms（缺省 1000）。
 * STATUS=0/VALID=1 的样本才有效；强阳光直射或全黑目标会缩程或丢数据 */
CREATE TABLE VL53L4CD (
	name    String,
	I2C     String,
	address String,
	budget  String,
	inter   String,
	timeout String
);
INSERT INTO VL53L4CD (name, I2C, address, budget, inter, timeout)
  VALUES ('tof0', '$i2c-1', '0x29', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：间隔 >= budget（缺省 50ms）；数值字段直读，
 * 消费侧按 VALID=1 过滤无效样本 */
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
  VALUES ('tof-d0', 'lib/sensor_daemon.lua', 'VL53L4CD', 'i2c', '/dev/i2c-1', '0x29', '60', 'DIST_MM|STATUS|VALID|SIGNAL_KCPS');

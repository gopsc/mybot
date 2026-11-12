/*
 * VL53L0X ToF 激光测距测试（配套 vl53l0x.mt）
 * 直连变量（tof0）单次读 + 万能守护（tof-d0）连续采样双路径
 * 量程 ~30mm~2m（长距模式），25° 视场；地址固定 0x29，一条总线单只
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* VL53L0X：地址固定 0x29；sig = final range 信号率门限 MCPS（缺省 0.25，
 * 越小越能收到弱反射）；long = 长距模式（1 生效，门限缺省改 0.1）；
 * timeout = data-ready 等待超时 ms（缺省 500，单帧约 33ms）。
 * STATUS=0/VALID=1 的样本才有效；DIST_MM>=8190 视为越界 */
CREATE TABLE VL53L0X (
	name    String,
	I2C     String,
	address String,
	sig     String,
	long    String,
	timeout String
);
INSERT INTO VL53L0X (name, I2C, address, sig, long, timeout)
  VALUES ('tof0', '$i2c-1', '0x29', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：间隔 >= 单帧 33ms（此处 60ms）；数值字段直读，
 * 消费侧按 VALID=1 过滤无效样本 */
/* proto=virt（审计 1.3）：本驱动在模块源里声明了 SINGLE_CONSUMER（一次访问跨多个
 * 总线事务、器件侧留有相位或锁存），而上面的直连变量已经是一个真器件消费者；
 * 守护再走 i2c 就是第二个，装配期判据（src/hw_factory.cpp 的 checkSingleConsumer）
 * 会直接拒绝加载。改 virt 后守护走内嵌 *_VIRT 模型：双路径覆盖都保留、真器件只剩
 * 一个消费者，且守护侧结果与主机有没有 /dev/i2c-1 无关（同 mpu_daemon.sql 的理由）。
 * 负值契约见 robots/test/single_consumer.sql。 */
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
  VALUES ('tof-d0', 'lib/sensor_daemon.lua', 'VL53L0X', 'virt', '/dev/i2c-1', '0x29', '60', 'DIST_MM|STATUS|VALID|SIGNAL_MCPS');

/*
 * MAX17043 锂电池电量计测试（配套 max17043.mt）
 * 直连变量（fuel-0）单次读 + 万能守护（fuel-d0）连续采样双路径
 * 地址芯片固定 0x36（无地址引脚，一条总线只能挂一颗）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* MAX17043：需真电池才有意义，空载时 VCELL 趋近 0、SOC 无意义 */
CREATE TABLE MAX17043 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO MAX17043 (name, I2C, address) VALUES ('fuel-0', '$i2c-1', '0x36');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：fields=VCELL|SOC（浮点，勿配 sign）；电量变化慢，1s 间隔足够 */
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
  VALUES ('fuel-d0', 'lib/sensor_daemon.lua', 'MAX17043', 'i2c', '/dev/i2c-1', '0x36', '1000', 'VCELL|SOC');

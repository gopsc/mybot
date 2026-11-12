/*
 * SHT3X 温湿度采集测试（配套 sht3x.mt）
 * 直连变量（sht3x-0）单次测量 + 万能守护（sht-d0）连续采样双路径
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* SHT3X：0x44 = ADDR 引脚接地，接高则为 0x45 */
CREATE TABLE SHT3X (
	name    String,
	I2C     String,
	address String
);
INSERT INTO SHT3X (name, I2C, address) VALUES ('sht3x-0', '$i2c-1', '0x44');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：fields=T|RH（换算后浮点，不配 sign——sign 是给原始补码整数用的） */
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
  VALUES ('sht-d0', 'lib/sensor_daemon.lua', 'SHT3X', 'i2c', '/dev/i2c-1', '0x44', '100', 'T|RH');

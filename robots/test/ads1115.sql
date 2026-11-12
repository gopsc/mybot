/*
 * ADS1115 单端采集测试（配套 ads1115.mt）
 * pga/dr 显式配置：占位符归 0 会使驱动缺省档位失效（±6.144V/8SPS）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* pga=2（±2.048V）dr=4（128SPS）channel=0 单端通道 */
CREATE TABLE ADS1115 (
	name    String,
	I2C     String,
	address String,
	pga     String,
	dr      String,
	channel String
);
INSERT INTO ADS1115 (name, I2C, address, pga, dr, channel) VALUES ('adc0', '$i2c-1', '0x48', '2', '4', '0');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：driver/proto/path/addr/interval/fields 由 sensor_daemon.lua 解释 */
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
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields) VALUES ('adc-d0', 'lib/sensor_daemon.lua', 'ADS1115', 'i2c', '/dev/i2c-1', '0x48', '50', 'raw|voltage');

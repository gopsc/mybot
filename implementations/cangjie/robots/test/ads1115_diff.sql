/*
 * ADS1115 差分采样测试（配套 ads1115_diff.mt，结构与单端版相同）
 * 差分对由动作脚本 @Action 的 pos/neg 列指定，与 channel 不可混用同一 @Action
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

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

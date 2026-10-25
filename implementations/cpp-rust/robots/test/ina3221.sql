/*
 * INA3221 三通道电流/电压采集测试（配套 ina3221.mt）
 * 直连变量（ina3221-0）单次读 + 万能守护（ina-d0）连续采样双路径
 * rshuntN 显式配置：'-' 占位符归一为 0 会使电流除零（与 ADS1115 pga/dr 同理）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* INA3221：0x40~0x43（A1/A0 引脚），缺省 0x40；rshunt 缺省 10mΩ（CJMCU 模块板载值） */
CREATE TABLE INA3221 (
	name    String,
	I2C     String,
	address String,
	avg     String,
	rshunt1 String,
	rshunt2 String,
	rshunt3 String
);
INSERT INTO INA3221 (name, I2C, address, avg, rshunt1, rshunt2, rshunt3)
  VALUES ('ina3221-0', '$i2c-1', '0x40', '16', '0.01', '0.01', '0.01');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：六字段（浮点，勿配 sign）；间隔 >= 一个转换循环（3ch x 2.2ms x avg） */
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
  VALUES ('ina-d0', 'lib/sensor_daemon.lua', 'INA3221', 'i2c', '/dev/i2c-1', '0x40', '150', 'V1|I1|V2|I2|V3|I3');

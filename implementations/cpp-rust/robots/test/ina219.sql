/*
 * INA219 单通道电流/功率采集测试（配套 ina219.mt）
 * 直连变量（ina219-0）单次读 + 万能守护（ina-d0）连续采样双路径
 * rshunt 显式配置：'-' 占位符归一为 0 会使电流除零（与 ADS1115 pga/dr 同理）
 * CJMCU-219 模块板载 R100 = 0.1Ω；量程 ±320mV -> 约 ±3.2A，动力电慎用
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* INA219：0x40~0x4F（A0/A1 引脚），缺省 0x40 */
CREATE TABLE INA219 (
	name    String,
	I2C     String,
	address String,
	rshunt  String,
	avg     String
);
INSERT INTO INA219 (name, I2C, address, rshunt, avg)
  VALUES ('ina219-0', '$i2c-1', '0x40', '0.1', '16');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：三字段（浮点，勿配 sign）；间隔 >= 一个转换循环（2 x 532µs x avg） */
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
  VALUES ('ina-d0', 'lib/sensor_daemon.lua', 'INA219', 'i2c', '/dev/i2c-1', '0x40', '50', 'V|I|P');

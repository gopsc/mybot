/*
 * INA226 单通道电流/功率采集测试（配套 ina226.mt）
 * 直连变量（ina226-0）单次读 + 万能守护（ina-d0）连续采样双路径
 * 分流量程固定 ±81.92mV：CJMCU-226 板载 R100 = 0.1Ω 约 ±0.82A，
 * 动力电监测建议换小阻值外置分流（10mΩ -> ±8.19A）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* INA226：0x40~0x4F（A0/A1 各接 GND/VS/SCL/SDA），缺省 0x40；
 * ct 列 = 单次转换时间 µs（140/204/332/588/1100/2116/4156/8244，非法值降档） */
CREATE TABLE INA226 (
	name    String,
	I2C     String,
	address String,
	rshunt  String,
	avg     String,
	ct      String
);
INSERT INTO INA226 (name, I2C, address, rshunt, avg, ct)
  VALUES ('ina226-0', '$i2c-1', '0x40', '0.1', '16', '1100');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：三字段（浮点，勿配 sign）；间隔 >= 一个转换循环（2 x 1.1ms x 16 = 35.2ms） */
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
  VALUES ('ina-d0', 'lib/sensor_daemon.lua', 'INA226', 'i2c', '/dev/i2c-1', '0x40', '50', 'V|I|P');

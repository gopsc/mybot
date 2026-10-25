/*
 * LTC2944 多节电池电量计测试（配套 ltc2944.mt）
 * 直连变量（gauge-0）单次读 + 万能守护（gauge-d0）连续采样双路径
 * rsense 显式配置：'-' 归一为 0 会使电流除零（与 ADS1115 pga/dr 同理）
 * 电荷量程与 rsense 成正比：50mΩ -> 约 22.3mAh（M=4096），大容量电池组换小阻值
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* LTC2944：地址芯片固定 0x64；prescaler M 越大电荷量程越大（1~4096） */
CREATE TABLE LTC2944 (
	name      String,
	I2C       String,
	address   String,
	rsense    String,
	prescaler String
);
INSERT INTO LTC2944 (name, I2C, address, rsense, prescaler)
  VALUES ('gauge-0', '$i2c-1', '0x64', '0.05', '4096');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：四字段（浮点，勿配 sign）；电荷连续累计，1s 间隔足够 */
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
  VALUES ('gauge-d0', 'lib/sensor_daemon.lua', 'LTC2944', 'i2c', '/dev/i2c-1', '0x64', '1000', 'CHARGE|V|I|T');

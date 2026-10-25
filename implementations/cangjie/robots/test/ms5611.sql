/*
 * MS5611 高分辨率气压计测试（配套 ms5611.mt）
 * 直连变量（baro0）单次读 + 万能守护（baro-d0）连续采样双路径
 * 地址 0x77（CSB=GND）/0x76（CSB=VDD）；OSR4096 一次 call 约 20ms
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* MS5611：osr = 过采样率 256/512/1024/2048/4096（非法值降档，缺省 4096）；
 * p0 = 参考海平面气压 hPa（缺省 1013.25，按当地气象值校准 ALT_M 更准）。
 * build 读 8 字 PROM 并做 CRC-4 自检，CRC 不符即报错（兼在位甄别）。
 * 遮光海绵勿撕除：芯片裸露受光会引入气压噪声 */
CREATE TABLE MS5611 (
	name    String,
	I2C     String,
	address String,
	osr     String,
	p0      String
);
INSERT INTO MS5611 (name, I2C, address, osr, p0)
  VALUES ('baro0', '$i2c-1', '0x77', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：间隔 >= 25ms（OSR4096 两段转换约 20ms + 余量） */
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
  VALUES ('baro-d0', 'lib/sensor_daemon.lua', 'MS5611', 'i2c', '/dev/i2c-1', '0x77', '30', 'P_HPA|T_C|ALT_M');

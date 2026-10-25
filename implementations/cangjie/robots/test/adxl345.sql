/*
 * ADXL345 三轴加速度计测试（配套 adxl345.mt）
 * 直连变量（acc0）单次读 + 万能守护（acc-d0）连续采样双路径
 * 无 blob：build 即 DEVID 甄别 + FULL_RES/量程 + 速率 + 测量模式
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* ADXL345：0x53/0x1D（ALT ADDRESS 引脚，模块缺省 0x53）。
 * range=±g(2/4/8/16) odr=Hz(12.5~3200)，'-' 全按缺省（±8g/100Hz）；
 * FULL_RES 恒开：灵敏度恒定 256 LSB/g，量程只改削顶电平 */
CREATE TABLE ADXL345 (
	name    String,
	I2C     String,
	address String,
	range   String,
	odr     String
);
INSERT INTO ADXL345 (name, I2C, address, range, odr)
  VALUES ('acc0', '$i2c-1', '0x53', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：三字段（原始码，16 位补码语义 -> sign='16' 展开负值），
 * interval=20ms（odr=100Hz 跑满） */
CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	addr     String,
	interval String,
	fields   String,
	sign     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('acc-d0', 'lib/sensor_daemon.lua', 'ADXL345', 'i2c', '/dev/i2c-1', '0x53', '20',
          'ACCEL_X|ACCEL_Y|ACCEL_Z', '16');

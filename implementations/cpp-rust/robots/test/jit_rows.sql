/*
 * LuaJIT JIT 编译触发测试配套结构（阈值 56 行）
 * 70 行动作经 Servo→PCA9685，每行 4 次 I2C_RDWR ioctl；
 * 0x40 无器件时 NACK 静默失败仍计次（配套 jit_rows.mt）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca9685-0', '$i2c-1', '0x40');

CREATE TABLE Servo (
	name       String,
	max        String,
	min        String,
	offset     String,
	controller String,
	channel    String
);
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES ('s1', '90', '-', '0', 'pca9685-0', '6');

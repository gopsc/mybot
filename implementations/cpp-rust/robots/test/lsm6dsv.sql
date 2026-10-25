/*
 * LSM6DSV16X 六轴 IMU 测试（配套 lsm6dsv.mt）
 * 直连变量（imu0）单次读 + 万能守护（imu-d0）连续采样双路径
 * 无 blob：build 即 WHO_AM_I 甄别 + 软复位自清 + BDU + ODR/量程 配置
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* LSM6DSV16X：0x6A/0x6B（SA0 引脚，与 MPU6050/BMI270 的 0x68/0x69 错开）。
 * range=±g(2/4/8/16) gyro_range=±dps(125~4000) odr=Hz(7.5~7680，取最近档)，
 * '-' 全按缺省（±8g/±500dps/120Hz）；仅支持 LSM6DSV16X（WHO_AM_I 0x70） */
CREATE TABLE LSM6DSV (
	name       String,
	I2C        String,
	address    String,
	range      String,
	gyro_range String,
	odr        String
);
INSERT INTO LSM6DSV (name, I2C, address, range, gyro_range, odr)
  VALUES ('imu0', '$i2c-1', '0x6A', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：六字段（原始码，16 位补码语义 -> sign='16' 展开负值），
 * odr=120Hz 时 interval 取 10ms 即可跑满采样率 */
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
  VALUES ('imu-d0', 'lib/sensor_daemon.lua', 'LSM6DSV', 'i2c', '/dev/i2c-1', '0x6A', '10',
          'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z', '16');

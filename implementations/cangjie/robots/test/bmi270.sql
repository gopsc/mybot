/*
 * BMI270 六轴 IMU 测试（配套 bmi270.mt）
 * 直连变量（imu0）单次读 + 万能守护（imu-d0）连续采样双路径
 * build 会软复位 -> 上传配置 blob（fifo 328B 约 0.1s / full 8KB 约 1s）->
 * 开 acc+gyr 并等 100ms 陀螺仪启动，无器件时 halt-on-error 干净中止
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* BMI270：0x68/0x69（SDO 引脚，与 MPU6050 同址）。
 * range=±g(2/4/8/16) gyro_range=±dps(125~2000) odr=Hz(25~1600)，'-' 全按缺省
 * cfg='-' 即 fifo blob（328B）；个别硅版陀螺仪不出数时填 'full' 换 8KB 全量配置 */
CREATE TABLE BMI270 (
	name       String,
	I2C        String,
	address    String,
	range      String,
	gyro_range String,
	odr        String,
	cfg        String
);
INSERT INTO BMI270 (name, I2C, address, range, gyro_range, odr, cfg)
  VALUES ('imu0', '$i2c-1', '0x68', '-', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：六字段（原始码，16 位补码语义 -> sign='16' 展开负值），
 * odr=100Hz 时 interval 取 10ms 即可跑满采样率；10ms 亦远大于 HAL 单次事务开销 */
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
  VALUES ('imu-d0', 'lib/sensor_daemon.lua', 'BMI270', 'i2c', '/dev/i2c-1', '0x68', '10',
          'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z', '16');

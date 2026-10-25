/*
 * BMM150 三轴地磁传感器测试（配套 bmm150.mt）
 * 直连变量（mag0）单次读 + 万能守护（mag-d0）连续采样双路径
 * 上电序列特殊：复位后芯片在 suspend 挂起态，build 先写 Power Control
 * 再等 3ms 才能访问 CHIP_ID 与 trim 寄存器
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* BMM150：0x10/0x11/0x12/0x13（CSB/SDO 引脚四组合，模块常见 0x10/0x11）。
 * preset = lowpower/regular/enhanced/highaccuracy（ODR 10/10/10/20Hz，
 * 重复次数递增精度递增），'-' 缺省 regular */
CREATE TABLE BMM150 (
	name    String,
	I2C     String,
	address String,
	preset  String
);
INSERT INTO BMM150 (name, I2C, address, preset)
  VALUES ('mag0', '$i2c-1', '0x10', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：三字段 X/Y/Z（补偿后微特斯拉浮点，勿配 sign）；
 * regular preset ODR=10Hz -> interval 200ms 足够；
 * 轴溢出（环境磁场超量程）时该轴发布 0，用直连路径细分 */
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
  VALUES ('mag-d0', 'lib/sensor_daemon.lua', 'BMM150', 'i2c', '/dev/i2c-1', '0x10', '200',
          'X|Y|Z');

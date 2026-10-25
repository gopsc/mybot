/*
 * 蜘蛛机器人结构脚本（spider.sql 变体：Timer 名为 spk，其余结构相同）
 * 由 SQL4cj 解析：支持 -- 单行注释与斜杠星号块注释（1.0.3 起）
 * 用法：cat scripts/std.mt | bash _run.sh --robot=robots/spider1.sql
 */

/* 别名表：动作脚本(.mt)中可用别名指代硬件参数名 */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES (A, angle);
INSERT INTO Alias (name, alias) VALUES (F, frequency);

/* GPIO-19：BCM19（物理 35 脚）推挽输出，高电平有效，上电 0 */
CREATE TABLE GPIO (
	name      String,
	chip      String,
	offset    String,
	direction String,
	active    String,
	init      String
);
-- INSERT INTO GPIO (name, chip, offset, direction, active, init)
--   VALUES ('GPIO-19', '/dev/gpiochip0', '19', 'out', 'high', '0');


/* I2C 总线：name 引用名 → /dev/i2c-N 设备路径 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* PCA9685：16 路 PWM 舵机控制器，挂在 i2c-1 总线 0x40 地址 */
CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO PCA9685 (name, I2C, address) VALUES ('pca9685-0', '$i2c-1', '0x40');

/* Timer：spk 仅负责延时的时基矩阵（扬声器位） */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('spk');

/*
 * 舵机表：14 路
 *   max        限幅上限（取绝对值，负值表示舵机方向反向）
 *   min        限幅下限（取绝对值，"-" 按 0 处理）
 *   offset     中位漂移（先加 offset 再限幅）
 *   controller 挂载的 PWM 控制器名
 *   channel    PCA9685 输出通道
 * 腿标记：rb=右后 lb=左后 lf=左前 rf=右前；关节 0=髋 1=大腿 2=膝
 */
CREATE TABLE Servo (
	name 		String,
	max  		String,
	min  		String,
	offset		String,
	controller	String,
	channel		String
);
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s1,    90,   -, -5,  'pca9685-0', 6);		-- rb0 右后腿·髋
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s2,  -180,   -,  0,  'pca9685-0', 5);		-- rb1 右后腿·大腿
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s3,   -90,   -,  0,  'pca9685-0', 14);	-- lb0 左后腿·髋
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s4,   180,   -,  25, 'pca9685-0', 15);	-- lb1 左后腿·大腿
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s5,    90,   -,  0,  'pca9685-0', 8);		-- lf0 左前腿·髋
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s6,  -180,   -,  0,  'pca9685-0', 9);		-- lf1 左前腿·大腿
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s7,   -90,   -,  0,  'pca9685-0', 11);	-- rf0 右前腿·髋
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s8,   180,   -,  0,  'pca9685-0', 12);	-- rf1 右前腿·大腿
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s9,   180,   -,  0,  'pca9685-0', 0);		-- cam0 云台水平
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s10,  180,   -,  0,  'pca9685-0', 1);		-- cam1 云台垂直
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s11,   90,   -,  0,  'pca9685-0', 4);		-- rb2 右后腿·膝
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s12,   90,   -,  0,  'pca9685-0', 7);		-- lb2 左后腿·膝
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s13, -180,   -,  55, 'pca9685-0', 13);	-- lf2 左前腿·膝
INSERT INTO Servo (name, max, min, offset, controller, channel)  VALUES  (s14,  180,   -,  0,  'pca9685-0', 10);	-- rf2 右前腿·膝


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
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2c',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');

/* 七个一阶低通滤波器：src 以 $ 引用守护，field 指定各自滤的快照字段；
 * alpha/src 用 "-" 继承上一行 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eax',  '0.2', '$imu0', 'v0');
INSERT INTO Ema (name, alpha, src, field) VALUES ('eay',  '-',   '-',      'v1');
INSERT INTO Ema (name, alpha, src, field) VALUES ('eaz',  '-',   '-',      'v2');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egx',  '-',   '-',      'v3');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egy',  '-',   '-',      'v4');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egz',  '-',   '-',      'v5');
INSERT INTO Ema (name, alpha, src, field) VALUES ('etmp', '-',   '-',      'v6');

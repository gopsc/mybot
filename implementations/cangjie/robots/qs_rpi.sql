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
INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('S3', '/dev/gpiochip0', '26', 'out', 'high', '0');

INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('S4', '/dev/gpiochip0', '20', 'out', 'high', '0');

INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('S7', '/dev/gpiochip0', '5', 'out', 'high', '0');

INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('S8', '/dev/gpiochip0', '6', 'out', 'high', '0');

CREATE TABLE PWM (
	name      String,
	chip      String,
	channel   String,
	frequency String,
	duty      String,
	invert    String
);
INSERT INTO PWM (name, chip, channel, frequency, duty, invert)
  VALUES ('pwm0', '0', '0', '20000', '0', '-');

INSERT INTO PWM (name, chip, channel, frequency, duty, invert)
  VALUES ('pwm1', '0', '1', '20000', '0', '-');


/* I2C 总线：name 引用名 → /dev/i2c-N 设备路径 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* Timer：spk 仅负责延时的时基矩阵（扬声器位） */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('spk');

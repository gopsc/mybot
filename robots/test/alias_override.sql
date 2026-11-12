/*
 * 用例2配套结构：别名覆盖测试——此处定义 A->angle，
 * 动作脚本重定义 A->test；若覆盖生效 Servo.lua 收不到 angle 会报 ERR
 * （配套 alias_override.mt）
 */
CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES ('A', 'angle');

CREATE TABLE dummy (
	name String
);
INSERT INTO dummy (name) VALUES ('dummy-0');

CREATE TABLE Servo (
	name       String,
	max        String,
	min        String,
	offset     String,
	controller String,
	channel    String
);
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES ('s1', '90', '-', '0', 'dummy-0', '6');

/*
 * 用例1配套结构：别名内联测试——本文件不含 Alias 表，
 * 别名 A 全部来自动作脚本内联的 @Alias（配套 alias_inline.mt）
 */
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

/*
 * 用例3配套结构：同一动作脚本重复定义别名 A 应抛错
 * 配合 alias_dup.mt 运行，预期非 0 退出
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

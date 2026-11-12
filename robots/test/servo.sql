/*
 * Servo 纯逻辑测试：控制器为 dummy，不触真实硬件，
 * 验证 offset 漂移、|min|/|max| 限幅与负 max 反向（配套 servo.mt）
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
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES ('s1', '90', '-', '-5', 'dummy-0', '6');
INSERT INTO Servo (name, max, min, offset, controller, channel) VALUES ('s2', '-180', '-', '0', '-', '5');

/*
 * controller 多列正例：relay-mc 挂两个 controller（dummy-0 → timer-b）。
 * 扇出广播：两个 controller 收到同一份「元数据 ∪ 返回表」payload（不接力），
 * 当前零件返回值为最后一个 controller（timer-b 的 slept）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-b');

CREATE TABLE dummy (
	name String
);
INSERT INTO dummy (name) VALUES ('dummy-0');

CREATE TABLE Relay (
	name        String,
	controller  String,
	controller2 String,
	note        String,
	test        String
);
INSERT INTO Relay (name, controller, controller2, note, test) VALUES ('relay-mc', 'dummy-0', 'timer-b', 'mc', '300');

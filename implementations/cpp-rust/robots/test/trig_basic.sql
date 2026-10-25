/*
 * trigger 前置调用正例：relay-sink 派发前框架先空参调用 relay-src，
 * 返回表以触发器名字为键并入调用参数，再走 controller 转发给 Timer。
 * relay-src 从不出现在 @Action——它的 Relay 打印出现即证明 trigger 机制发生。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	trigger    String,
	note       String,
	test       String
);
INSERT INTO Relay (name, controller, trigger, note, test) VALUES ('relay-src', '-', '-', 'src', '300');
INSERT INTO Relay (name, controller, trigger, note, test) VALUES ('relay-sink', 'timer-0', 'relay-src', 'sink', '-');

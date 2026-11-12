/*
 * controller 多列负值（fail-fast）：第一个 controller（timer-bad，payload 无
 * delay 必报 ERR）出错即停止——第二个 controller（relay-witness）不再被转发。
 * Relay.call 无条件打印，note=witness 出现即说明 fail-fast 失效（第 5 字段禁之）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-bad');

CREATE TABLE Relay (
	name        String,
	controller  String,
	controller2 String,
	note        String
);
INSERT INTO Relay (name, controller, controller2, note) VALUES ('relay-witness', '-', '-', 'witness');

CREATE TABLE dummy (
	name        String,
	controller  String,
	controller2 String
);
INSERT INTO dummy (name, controller, controller2) VALUES ('x0', 'timer-bad', 'relay-witness');

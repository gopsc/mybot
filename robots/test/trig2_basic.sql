/*
 * trigger 多列正例：relay-sink 挂两个触发器（relay-src1 → relay-src2）。
 * 按列声明序前置调用，返回表各自以触发器名字为键并入调用参数。
 * 两个触发源从不出现在 @Action——打印出现即证明多列前置调用发生。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name        String,
	controller  String,
	trigger     String,
	trigger2    String,
	note        String,
	test        String
);
INSERT INTO Relay (name, controller, trigger, trigger2, note, test) VALUES ('relay-src1', '-', '-', '-', 's1', '300');
INSERT INTO Relay (name, controller, trigger, trigger2, note, test) VALUES ('relay-src2', '-', '-', '-', 's2', '301');
INSERT INTO Relay (name, controller, trigger, trigger2, note, test) VALUES ('relay-sink', 'timer-0', 'relay-src1', 'relay-src2', 'sink', '-');

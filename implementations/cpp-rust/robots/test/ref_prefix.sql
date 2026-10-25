/*
 * 引用列 $ 前缀回归测试：note 列的值 'timer-0' 与硬件变量名同名，
 * 应按字面值传递（0.3.1 及之前会被隐式误判为引用列，note 字段丢失）。
 * 配合 ref_prefix.mt：期望输出 Relay: test=200 note=timer-0 -> delay=200
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', 'timer-0');

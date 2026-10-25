/*
 * $(...) 表达式回归（负值）：元数据列表达式引用未定义标识符 → 装配期（任何
 * 驱动 build 之前）清晰报错、退出非 0。
 * 用法：cat scripts/test/expr_undefined.mt | ./build/mybot --robot=robots/test/expr_undefined.sql
 * 期望退出码非 0，输出含 "ghost"
 */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('v1', 1);

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', '$(ghost+1)');

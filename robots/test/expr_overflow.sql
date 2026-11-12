/*
 * $(...) 表达式回归（负值）：元数据列表达式中间结果溢出为 inf → 求值期清晰
 * 报错、退出非 0（有限值防线：inf/nan 不得经 JsonFloat/lua_pushnumber 流入
 * 驱动参数，TCP 模式下可由远程动作脚本触发）。
 * 用法：cat scripts/test/expr_overflow.mt | ./build/mybot --robot=robots/test/expr_overflow.sql
 * 期望退出码非 0，输出含 "non-finite"
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
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', '$(v1*1e308*1e308)');

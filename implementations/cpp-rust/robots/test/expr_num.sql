/*
 * $(...) 表达式回归（正值），三处都覆盖：
 *   Vars 内表达式     v3 = $(v1+v2+10) = 25（惰性，支持引用其它 Vars）
 *   SQL 元数据列表达式 Relay.note = $(v1*v2) = 50
 *   @Action 单元格表达式 $(v3*2) = 50（见 expr_num.mt）
 * 用法：cat scripts/test/expr_num.mt | ./build/mybot --robot=robots/test/expr_num.sql
 */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('v1', 10);
INSERT INTO Vars (name, value) VALUES ('v2', 5);
INSERT INTO Vars (name, value) VALUES ('v3', '$(v1+v2+10)');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', '$(v1*v2)');

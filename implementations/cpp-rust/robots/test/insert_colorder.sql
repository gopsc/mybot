/*
 * C3 回归（2026-09-20 审计）：INSERT 的列名清单与建表声明序**不一致**时，
 * 值必须按列名落位到声明序。
 * 修复前：值按 INSERT 自带列序逐位 appendRow ——
 *   INSERT INTO Timer (delay, name) VALUES (50, 'timer-0')
 * 会把 50 写进 name、'timer-0' 写进 delay：声明 Number 的 delay 拿到字符串
 * （number_bad.sql 承诺的解析期校验被整条绕过），且 Relay.controller 指向的
 * 'timer-0' 解析不到，报「not defined yet」。
 * 用法：cat scripts/test/number_type.mt | ./build/mybot --robot=robots/test/insert_colorder.sql
 * 期望退出码 0，输出含 note=hello-number。
 */
CREATE TABLE Timer (
	name  String,
	delay Number
);
INSERT INTO Timer (delay, name) VALUES (50, 'timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
-- 第二张表同样反序，覆盖「多表都反序」的组合
INSERT INTO Relay (note, name, controller) VALUES ('hello-number', 'relay0', 'timer-0');

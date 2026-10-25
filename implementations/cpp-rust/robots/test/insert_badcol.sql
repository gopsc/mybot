/*
 * C3 回归（2026-09-20 审计，负值）：INSERT 写了表中不存在的列名必须**解析期**报错。
 * 修复前：columnName 只参与 Number 校验，未知列被静默顺序落位并挤掉后续列，
 * 于是拼错列名 = 数据整体错位且无任何报错。
 * 用法：cat scripts/test/insert_badcol.mt | ./build/mybot --robot=robots/test/insert_badcol.sql
 * 期望退出码 1，输出含 "no such column"。
 */
CREATE TABLE Timer (
	name  String,
	delay Number
);
INSERT INTO Timer (nome) VALUES ('timer-0');

/*
 * @Vars 负值契约：Vars 表缺少 value 列 → 装配期清晰报错并退出非 0。
 * 用法：cat scripts/test/vars_bad.mt | ./build/mybot --robot=robots/test/vars_bad.sql
 */
CREATE TABLE Vars (
	name String
);
INSERT INTO Vars (name) VALUES ('greeting');

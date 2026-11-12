/*
 * @Vars 仅支持 Number 回归（正值）：结构脚本 Vars（name/value，value 为数值）
 * 作为 $ 数值常量填充 Relay.note；@Action 正常跑通。
 * 用法：cat scripts/test/vars_num.mt | ./build/mybot --robot=robots/test/vars_num.sql
 */
CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES ('spd', 200);

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('relay0', 'timer-0', '$spd');

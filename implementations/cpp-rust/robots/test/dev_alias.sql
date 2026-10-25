/*
 * @Action 设备列别名解析夹具（2026-09-19 设计评估）
 * 两台 Relay 供「设备绑定」观察：note 列区分归属——播放落在谁身上，
 * 输出就带谁的 note。relay-a 是片段/别名的缺省绑定，relay-b 供主脚本改绑。
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
INSERT INTO Relay (name, controller, note) VALUES ('relay-a', 'timer-0', 'from-a');
INSERT INTO Relay (name, controller, note) VALUES ('relay-b', 'timer-0', 'from-b');

/*
 * $(...) 类型分派表达式夹具（2026-09-20 设计评估：别名入式与文本拼接）
 * 观察面：两台 Relay 以 note 列区分归属（from-1/from-2）——列头设备位
 * $(pfx+n) 拼出 relay-1/relay-2，播放落在谁身上输出就带谁的 note；
 * dummy 驱动的 echo 参数原样回传（结果 JSON 打印到 stdout），供「数据格
 * 拼接产出文本参数」观察（echo 不是元数据键，不触 C-1 同名拒绝）。
 * a1/a2 供参数位拼接（$(a1+a2) → test）。
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
INSERT INTO Relay (name, controller, note) VALUES ('relay-1', 'timer-0', 'from-1');
INSERT INTO Relay (name, controller, note) VALUES ('relay-2', 'timer-0', 'from-2');

CREATE TABLE dummy (
	name String
);
INSERT INTO dummy (name) VALUES ('dum-1');

CREATE TABLE Alias (
	name  String,
	alias String
);
INSERT INTO Alias (name, alias) VALUES ('pfx', 'relay-');
INSERT INTO Alias (name, alias) VALUES ('g', 'hello-');
INSERT INTO Alias (name, alias) VALUES ('a1', 'te');
INSERT INTO Alias (name, alias) VALUES ('a2', 'st');

CREATE TABLE Vars (
	name  String,
	value Number
);
INSERT INTO Vars (name, value) VALUES (n, 2);

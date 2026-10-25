/*
 * Monitor 闭环测试：daemon_probe 采样(sim0) → Monitor 引用读取 v0(mon0)
 * 配合 monitor.mt
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name  String,
	chunk String,
	interval String
);
INSERT INTO Daemon (name, chunk, interval) VALUES ('sim0', 'lib/daemon_probe.lua', '1');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$sim0');

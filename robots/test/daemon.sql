/*
 * 守护并发压测配套结构：dummy(dm 列=主线程 Lua 负载) +
 * daemon_probe 守护(d0 列=读守护计数)，配合 daemon.mt 的 200 行动作
 */
CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('d0', 'lib/daemon_probe.lua');

CREATE TABLE dummy (
	name String,
	pp1  String
);
INSERT INTO dummy (name, pp1) VALUES ('dm', '-');

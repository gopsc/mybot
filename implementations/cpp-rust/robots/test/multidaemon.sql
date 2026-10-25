/*
 * 多守护并发诊断：daemon_tid × 4（d0-d3 各持独立 lua_State）
 * 配合 multidaemon.mt
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('d0', 'lib/daemon_tid.lua');
INSERT INTO Daemon (name, chunk) VALUES ('d1', 'lib/daemon_tid.lua');
INSERT INTO Daemon (name, chunk) VALUES ('d2', 'lib/daemon_tid.lua');
INSERT INTO Daemon (name, chunk) VALUES ('d3', 'lib/daemon_tid.lua');

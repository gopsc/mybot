/*
 * Kalman 滤波测试：daemon_probe 采样(sim0) → Kalman 滤波(kf0, Q=20 R=200)
 * → Monitor 引用(mon0)，配合 filter.mt
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

CREATE TABLE Kalman (
	name  String,
	Q     String,
	R     String,
	src   String,
	field String
);
INSERT INTO Kalman (name, Q, R, src, field) VALUES ('kf0', '20', '200', '$sim0', 'v0');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$kf0');

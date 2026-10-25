/*
 * kind 列（2026-10-16，sim_sensor_daemon 的框架列）：拼错必须在结构脚本加载期
 * 拒绝——放行的话要等守护线程起拍才看到 chunk 的 setup 失败码，报错只有
 * status -2 一个间接症状（与 proto/fields 的加载期校验同一动机）。
 * 期望：退出码 1，信息含 "column 'kind' value 'immu'"。
 * 配合 daemon_schema.mt（占位，结构期即失败）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	kind     String,
	interval String
);
INSERT INTO Daemon (name, chunk, kind, interval)
  VALUES ('d0', 'lib/sim_sensor_daemon.lua', 'immu', '10');

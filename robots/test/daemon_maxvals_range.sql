/*
 * maxvals 列（ABI v2）：容量是槽分配的输入，越界值（> 硬上限 1024）必须在
 * 结构脚本加载期拒绝——静默回落缺省会让 fields 校验看到一个与槽实际容量
 * 不一致的数。期望：退出码 1，信息含 "column 'maxvals' value '99999'"。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	interval String,
	maxvals  String
);
INSERT INTO Daemon (name, chunk, interval, maxvals)
  VALUES ('d0', 'lib/daemon_probe.lua', '10', '99999');

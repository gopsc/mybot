/*
 * $ 引用指向未定义变量负值契约（F-05）：
 * 引用解析本是惰性的（首次 collect 时）——旧实现会先跑完前面驱动
 * （含守护 build/spawn，真机上即已发生的硬件事务）才在 Monitor 的
 * build 中途报错；修复后在装配完成后、任何 build 之前统一校验，
 * 报错不碰硬件。
 * 用法：cat scripts/test/ref_undefined.mt | ./build/mybot --robot=robots/test/ref_undefined.sql
 * 期望退出码 1，输出含 "but it is not defined"，且不含 "spawned"（无 build 发生）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('d0', 'lib/daemon_probe.lua');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$nope');

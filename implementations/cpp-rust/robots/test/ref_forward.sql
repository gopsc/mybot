/*
 * $ 前向引用正向契约（F-05）+ destroy 静态元数据（F-04）：
 * 全部 $ 引用都指向声明在后的变量（Monitor→Ema→Daemon→Timer 逆序引用）。
 * - F-05：装配完成后统一校验存在性 → 前向引用合法（此前校验是惰性的，
 *   配置错误要等 build 跑到一半才暴露）；
 * - F-04：destroy 按声明倒序执行，mon0 出栈时 ema0 的 Lua 状态已释放——
 *   旧实现 freeImpl 解析 $ 引用会读已释放变量并抛错，直接跳过 mon0 的
 *   destroy（Deactive warning）；修复后 destroy 只取字面列。
 * 用法：cat scripts/test/ref_forward.mt | ./build/mybot --robot=robots/test/ref_forward.sql
 * 期望退出码 0，输出含 "joined, total publishes="，不含 "Deactive warning"。
 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ema0');

CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ema0', '0.3', '$sim0', 'v0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	interval String
);
INSERT INTO Daemon (name, chunk, interval) VALUES ('sim0', 'lib/daemon_probe.lua', '1');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/*
 * 守护 setup 失败必须响亮（N-27 负值契约）：
 * driver 指向一个不存在的驱动 → 守护侧 fail(-8)，失败码写进槽的独立 status
 * 字段（不再伪装成 v0 采样值）；宿主侧读路径见 status ≠ 0 即按 ERR 报错，
 * 且 $ 引用处在正常路径上也把 ERR 上抛（不再把 {result="ERR", message=…}
 * 当普通字段合进参数，让调用方只看到「no daemon value (v0 missing)」这类
 * 间接症状）。
 *
 * 期望：退出码 1，错误信息含 "slot status -8"（错误码以槽字段身份出现，
 * 而不是作为一个负的采样值 v0）。
 * 配合 daemon_setup_fail.mt
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	addr     String,
	interval String,
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields) VALUES ('imu0', 'lib/sensor_daemon.lua', 'NoSuchDriver', 'i2c', '/dev/i2c-99', '0x68', '10', 'X');

/* Monitor 挂到 imu0 上：src 以 $ 前缀引用守护，read() 走守护读路径 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');

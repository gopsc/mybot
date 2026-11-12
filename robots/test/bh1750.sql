/*
 * BH1750 环境光守护采样测试：sensor_daemon 万能采样（守护自开 /dev/i2c-1），
 * mode=H（连续 1lx/LSB）一帧约 120ms，interval=120 与采样帧同步；
 * fields=LUX（浮点，勿配 sign）。Monitor（mon0）引用消费打印 LUX。
 * 地址：ADDR=Low -> 0x23，ADDR=High -> 0x5C；挂错/接线问题守护发布错误码。
 * 无总线/无器件时守护发布占位错误码（-1 开总线失败），链路仍完整跑通；
 * 真机下 count 递增、v0 为 LUX 实测 lux 值。配合 bh1750.mt
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
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
  VALUES ('light0', 'lib/sensor_daemon.lua', 'BH1750', 'i2c', '/dev/i2c-1', '0x23', '120', 'LUX');

/* Monitor 挂到 light0 上：src 列以 $ 前缀引用守护，read() 快照字段（v0/count）合并进元数据 */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$light0');
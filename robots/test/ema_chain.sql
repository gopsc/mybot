/*
 * EMA 滤波链测试：daemon_probe 采样(sim0) → Ema 滤波(ema0, alpha=0.3)
 * → Monitor 引用(mon0)，配合 ema_chain.mt
 */
CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (name String, chunk String, interval String);
INSERT INTO Daemon (name, chunk, interval) VALUES ('sim0', 'lib/daemon_probe.lua', '1');

CREATE TABLE Ema (name String, alpha String, src String, field String);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ema0', '0.3', '$sim0', 'v0');

CREATE TABLE Monitor (name String, src String);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ema0');

/*
 * 多器件合并采样守护 E2E（proto=virt，无硬件）：
 * sensor_daemon_multi 用【一个】守护线程 + 一个 Lua 状态 + 一个总线 fd 轮询
 * 同一 i2c-1 上的两只 BH1750（ADDR 引脚分接 0x23 / 0x5C），逐拍把两器件
 * 样本拼进同一次 publish（原子快照）——对照 multidaemon.sql 的 4 守护 4 线程
 * 形态，本夹具验证「1 线程 N 器件」的合并路径。
 *
 * 链路：
 *   守护线程（独立 lua_State，devices='BH1750@0x23@LUX|BH1750@0x5C@LUX'）
 *   → 共享槽（快照 v0=器件1 LUX，v1=器件2 LUX）
 *   → Monitor 消费（mon0 直连守护，打印 v0/v1 快照与 count）。
 *
 * BH1750_VIRT 内嵌于 modules/BH1750.lua 尾部（模型文件缺失 → 回退路径装载，
 * 顺带覆盖多器件版的 drv_preloaded 回退分支）；缺省 count 造确定性合成值。
 * LUX 为浮点物理量，:f 透传（勿配 sign=16，浮点配 s16 会被拒绝发布）。
 *
 * 配合 daemon_multi.mt：200ms 预热等守护 setup（双驱动 fenv 加载 + 双模型
 * 挂载），随后 8 拍 ×50ms pump 消费。interval=20ms。
 * 用法：cat scripts/test/daemon_multi.mt | ./build/mybot --robot=robots/test/daemon_multi.sql
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	proto    String,
	path     String,
	interval String,
	devices  String
);
INSERT INTO Daemon (name, chunk, proto, path, interval, devices)
  VALUES ('lux0', 'lib/sensor_daemon_multi.lua', 'virt',
          '/dev/i2c-1', '20', 'BH1750@0x23@LUX:f|BH1750@0x5C@LUX:f');

CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$lux0');

/*
 * BMM150 无硬件端到端（proto=virt，首个「POR 挂起态电源门 + 三段工厂
 * trim NVM + XY/Z 异构 13/15 位数据块」I2C 器件）：sensor_daemon 不打开
 * 真机 I2C，而是挂内存仿真模型 BMM150_VIRT（内嵌于 modules/BMM150.lua
 * 尾部，2026-09-15 迁入，守护经回退路径装载）。守护跑的
 * 是【真实】BMM150.lua 完整 build（写 0x4B POWER_ON 后真实 milli_sleep
 * 3ms STARTUP→读 CHIP_ID=0x32→读 0x5D/0x62/0x68 三段 16B trim NVM→
 * 写 REP_XY/REP_Z/OP_MODE 配置 regular preset）与 call（从 0x42 起单笔
 * 8B burst：X/Y 13 位、Z 15 位、RHALL 14 位小端位域解码，逐轴走 Bosch
 * C reference 的 compensate_x/y/z 整数管线，输出 X/Y/Z 三轴地磁 µT；
 * 溢出哨兵 -4096/-16384 对应轴置 nil）。
 *
 * 模型每拍 virt_tick 直接把一拍确定性地磁原始码表装入 0x42 数据块
 * （32 拍周期：X≈30±20µT、Y≈-12±15µT、Z≈-42±18µT 正弦，RHALL 恒 512；
 * 码表离线用驱动同款 Bosch 管线反解，逐拍命中目标 µT）——normal 模式
 * 连续出数无 DRDY 握手，守护不推进任何虚拟时钟，build 前的 virt_tick(0)
 * 即预武装，build 睡醒 call 恒有数据、零额外等待；一拍对应一个 virt_tick，
 * X/Y/Z 随拍变化（守护 count 通用断言有 ≥2 个不同值）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v1=Y 轴做 α=0.2 一阶滤波（:f 浮点透传）
 *   → Monitor 引用消费。mon0 直连守护 cam0（raw X/Y/Z µT）；monf 引用
 *   eavg（滤波后 Y，验证 Ema→Monitor 闭环）。
 *   三字段均为磁场 µT（全字段 :f 标记浮点，但 Bosch 补偿管线收尾 idiv /16
 *   使 raw 值恒为整数；monf 的 Ema α 混合 out 必为带小数浮点），sign 列仅
 *   占位 '16'。
 *   preset 为驱动额外配置列，经守护 params 透传（regular=REP_XY 4/REP_Z 7/
 *   ODR 10Hz）。
 *
 * 配合 bmm150_virt.mt：首行 200ms 预热等守护 setup（容纳 build 的真实
 * STARTUP 睡眠 3ms，余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个
 * Monitor。守护 interval=20ms（tick 预武装后 call 零睡眠）。
 * 用法：cat scripts/test/bmm150_virt.mt | ./build/mybot --robot=robots/test/bmm150_virt.sql
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
	fields   String,
	sign     String,
	preset   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, preset)
  VALUES ('cam0', 'lib/sensor_daemon.lua', 'BMM150', 'virt',
          '/dev/i2c-1', '0x10', '20',
          'X:f|Y:f|Z:f', '16', 'regular');

/* 一阶低通滤波器：只滤 v1=Y 轴（:f 浮点透传） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$cam0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$cam0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

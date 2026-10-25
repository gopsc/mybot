/*
 * VL53L4CD 无硬件端到端（proto=virt，首个 16 位寄存器指针 ptr16 I2C
 * 虚拟器件）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/vl53l4cd.lua。模型在 regmap ptr16 底座上复刻
 * 软复位（0x0000=0x00/0x01）、91 字节默认配置流（0x002D 地址自增）、
 * VHV 预热/连续启动（0x0087=0x40/0x21）、0x0030 bit4 极性 + 0x0031
 * bit0 data-ready 链与清中断时序；守护跑的是【真实】VL53L4CD.lua 的
 * 完整 build（SetRangeTiming 预算编码、首测量自检）与 call（六寄存器
 * 独立原子读、ST 状态映射、SPAD=0 守卫）。
 *
 * 模型每拍 virt_tick 在距离空间造确定性正弦（100~1100mm，32 拍周期，
 * 状态恒有效/2 SPAD/800 信号/400 环境/sigma 2.0mm），运行态预武装，
 * 守护 call 首次轮询即就绪（不依赖 milli_sleep 推进虚拟时钟）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=DIST_MM 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 tof0（raw 四字段 + count）；
 *   monf 引用 ed（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=STATUS / v2=VALID 为整型码，v3=SIGNAL_KCPS 浮点，均不滤波。
 *
 * 配合 vl53l4cd_virt.mt：300ms 预热等守护 setup（build 仅软复位
 * 1+5ms 真实睡眠，轮询首次即就绪），随后 16 拍 ×50ms pump 滤波并消费
 * 两个 Monitor。守护 interval=20ms。
 * 用法：cat scripts/test/vl53l4cd_virt.mt | bash _run.sh --robot=robots/test/vl53l4cd_virt.sql
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
	sign     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('tof0', 'lib/sensor_daemon.lua', 'VL53L4CD', 'virt',
          '/dev/i2c-1', '0x29', '20', 'DIST_MM:f|STATUS|VALID|SIGNAL_KCPS:f', '16');

/* 一阶低通滤波器：只滤 v0=DIST_MM(mm)（:f 浮点透传，禁止取整）；
 * STATUS/VALID 为整型码、SIGNAL 本拍恒定，mon0 直连守护即可观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ed', '0.2', '$tof0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ed（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$tof0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ed');

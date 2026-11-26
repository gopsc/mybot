/*
 * MH-Z19B 无硬件端到端（proto=virt，NDIR CO₂ 传感器，UART 9600 8N1）：
 *   sensor_daemon 不打开真机串口，而是挂内存仿真模型——MHZ19_VIRT，内嵌于
 *   modules/MHZ19.lua 尾部（2026-09-15 迁入，工厂表 BUS="uart"，守护据此走
 *   attach_uart + uart_open 虚拟注入路径；path=/dev/serial0、baud=9600，
 *   UART 字节流模型：on_write 应答帧入 per-path 输入环、uart_read 即时 drain）。
 *
 * 模型只存协议事实层：FF 01 86 请求帧解析（含校验和验证）、FF 86 应答帧
 * 组装（HI/LO ppm 拆分 + TEMP 原始字节）；守护跑的是【真实】MHZ19.lua：
 * flush→发帧→多轮聚合扫描帧头与校验和→CO₂=HI*256+LO、TEMP=字节-40 全部真实。
 *
 * 链路：
 *   守护线程（独立 lua_State，/dev/serial0@9600）→ 共享槽
 *   → Ema 对 v0=CO2 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 co20（CO2/TEMP/S + count）；
 *   monf 引用 ev（滤波后浓度，验证 Ema→Monitor 闭环）。
 *
 * CO2 是整数 ppm（:f 透传无小数），浮点断言锚定 monf 行 Ema 的 α 混合
 * 输出 out（必为带小数浮点）。v1=TEMP(°C 近似)、v2=S(状态字节) 直连观察。
 *
 * 配合 mhz19_virt.mt：200ms 预热等守护 open+首发（真实驱动 build/call 均
 * 零睡眠），随后 16 拍 ×50ms pump Ema 并消费两个 Monitor。守护 interval=20ms。
 * virt_tick 为 32 拍一周爬坡（400 + m*128 ppm，一拍消费间隔内约推进 2~3 点）。
 * 用法：cat scripts/test/mhz19_virt.mt | ./build/mybot --robot=robots/test/mhz19_virt.sql
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
	baud     String,
	interval String,
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, baud, interval, fields)
  VALUES ('co20', 'lib/sensor_daemon.lua', 'MHZ19', 'virt',
          '/dev/serial0', '9600', '20', 'CO2:f|TEMP|S');

/* 一阶低通滤波器：只滤 v0=CO2(ppm)（:f 浮点透传，禁止取整）；
 * TEMP/S 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$co20', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$co20');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

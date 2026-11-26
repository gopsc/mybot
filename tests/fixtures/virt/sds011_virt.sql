/*
 * SDS011 无硬件端到端（proto=virt，激光 PM2.5/PM10 颗粒物传感器，UART 9600 8N1）：
 *   sensor_daemon 不打开真机串口，而是挂内存仿真模型
 *   SDS011_VIRT，内嵌于 modules/SDS011.lua 尾部（2026-09-15 迁入，
 *   工厂表 BUS="uart"，守护据此走
 *   attach_uart + uart_open 虚拟注入路径；path=/dev/serial0、baud=9600，
 *   UART 字节流模型：on_write 应答帧入 per-path 输入环、uart_read 即时 drain）。
 *
 * 模型只存协议事实层：19 字节请求帧解析（AA B4 CMD D0*12 FF FF CS AB，
 * CS = Σb3..b17 mod 256）、10 字节应答帧组装（AA C5 b3..b6 ID CS AB，
 * CS = Σb3..b8 mod 256）；守护跑的是【真实】SDS011.lua：build 切被动模式 +
 * 读固件版本、call 发查询帧 → flush → 多轮扫描帧头与校验和 →
 * PM = 小端 16 位 / 10 全部真实。
 *
 * 链路：
 *   守护线程（独立 lua_State，/dev/serial0@9600）→ 共享槽
 *   → Ema 对 v0=PM25 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 pm0（PM25/PM10 + count）；
 *   monf 引用 ev（滤波后浓度，验证 Ema→Monitor 闭环）。
 *
 * PM 是浮点 µg/m³（:f 透传）：virt_tick 波形 105/163 + 8*(n%5) 保证 raw 码
 * mod 10 恒非 0，守护 raw 行 v0/v1 必带一位小数——断言直接锚 mon0 的 "v0"，
 * 同时证明 :f 未被取整。v1=PM10(µg/m³) 同拍观察。
 *
 * 配合 sds011_virt.mt：200ms 预热等守护 open + build（切被动 + 读版本共
 * 2 命令 4 事务，真实驱动 build/call 均零睡眠），随后 16 拍 ×50ms pump Ema
 * 并消费两个 Monitor。守护 interval=20ms（真机测量周期约 1s，真机须 >=1s；
 * 虚拟模型每拍 virt_tick 造新值，无重复值问题）。
 * 用法：cat scripts/test/sds011_virt.mt | ./build/mybot --robot=robots/test/sds011_virt.sql
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
  VALUES ('pm0', 'lib/sensor_daemon.lua', 'SDS011', 'virt',
          '/dev/serial0', '9600', '20', 'PM25:f|PM10:f');

/* 一阶低通滤波器：只滤 v0=PM25(µg/m³)（:f 浮点透传，禁止取整）；
 * PM10 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$pm0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$pm0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

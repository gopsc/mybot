/*
 * MT6826S 无硬件端到端（proto=virt，15 位磁编码器，SPI Mode3）：
 *   sensor_daemon 不打开真机 SPI，而是挂内存仿真模型
 *   MT6826S_VIRT，内嵌于 modules/MT6826S.lua 尾部（2026-09-15 迁入，
 *   工厂表 BUS="spi"，守护据此走
 *   attach_spi + spi_open/spi_setup 虚拟注入路径，无 addr 列；mode=3/
 *   bits=8/speed=1MHz 按手册 8.6.2）。
 *
 * 模型只实现 24 位全双工读帧（cmd4+addr12+data8，MISO 数据在末字节）、
 * 角度四寄存器快照（0x003 h/0x004 l<<1/0x005 STATUS/0x006 CRC-8 poly0x07）
 * 与固定位；守护跑的是【真实】MT6826S.lua：在位固定位自检、逐寄存器四帧
 * 读快照、CRC-8 校验失败整轮重试、raw*360/32768 角度换算与 zero 取模全部
 * 真实。全双工帧走 HAL 新增全局原语 spi_xfer_full（virtbus 同帧注入 MISO）。
 *
 * 链路：
 *   守护线程（独立 lua_State，SPI Mode3/8bit/1MHz）→ 共享槽
 *   → Ema 对 v0=ANGLE 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 enc0（ANGLE/RAW/STATUS/CRC_OK +
 *   count）；monf 引用 ev（滤波后角度，验证 Ema→Monitor 闭环）。
 *
 * zero 列透传驱动 build（非守护框架键，原样进 params）：'-' 与非法值在
 * 驱动侧归缺省 0；v1=RAW 15 位整数码、v2=STATUS、v3=CRC_OK 直连观察。
 *
 * 配合 mt6826s_virt.mt：200ms 预热等 build（真实驱动零睡眠，余量充裕），
 * 随后 16 拍 ×50ms pump Ema 并消费两个 Monitor。守护 interval=20ms。
 * 用法：cat scripts/test/mt6826s_virt.mt | ./build/mybot --robot=robots/test/mt6826s_virt.sql
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
	mode     String,
	bits     String,
	speed    String,
	interval String,
	fields   String,
	zero     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, mode, bits, speed, interval, fields, zero)
  VALUES ('enc0', 'lib/sensor_daemon.lua', 'MT6826S', 'virt',
          '/dev/spidev0.0', '3', '8', '1000000', '20',
          'ANGLE:f|RAW|STATUS|CRC_OK', '-');

/* 一阶低通滤波器：只滤 v0=ANGLE(°)（:f 浮点透传，禁止取整）；
 * RAW/STATUS/CRC_OK 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$enc0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$enc0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

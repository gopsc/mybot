/*
 * ADS1256 无硬件端到端测试（proto=virt，首个 SPI 虚拟器件）：
 *   sensor_daemon 不打开真机 SPI，而是挂内存仿真模型
 *   modules/lib/virtbus/ads1256.lua（模型模块表 BUS="spi"，守护据此走
 *   attach_spi + spi_open/spi_setup 虚拟注入路径，而非 I2C 的 attach/addr）。
 *
 * 模型只实现 SPI 命令状态机（RESET/WREG/RDATAC/24bit 样本帧）与确定性合成
 * 波形 virt_tick（PGA×1 量程下中心 1.25V、幅度 1.0V、32 拍周期正弦）；
 * 守护跑的是【真实】ADS1256.lua：build 的 8 帧命令序列、call 的换通道/
 * SYNC/WAKEUP/RDATAC、24bit 补码与 voltage=raw*2*2.5/2^23/PGA 换算全部真实。
 *
 * 链路：
 *   守护线程（独立 lua_State，SPI Mode1/8bit/1.92MHz）→ 共享槽
 *   → Ema 对 v1=voltage 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 env0（raw 两字段 + count）；
 *   monf 引用 ev（滤波后 v1 + level，验证 Ema→Monitor 闭环）。
 *
 * 配合 ads1256_virt.mt：300ms 预热等 build（含 60ms 自校准等待），
 * 随后 16 拍 ×50ms pump 两路 Ema 并消费两个 Monitor。守护 interval=20ms。
 * 用法：cat scripts/test/ads1256_virt.mt | bash _run.sh --robot=robots/test/ads1256_virt.sql
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
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, mode, bits, speed, interval, fields)
  VALUES ('env0', 'lib/sensor_daemon.lua', 'ADS1256', 'virt',
          '/dev/spidev0.0', '1', '8', '1920000', '20', 'raw|voltage:f');

/* 一阶低通滤波器：只滤 v1=voltage(V)（:f 浮点透传，禁止取整）；
 * v0=raw 整型码无需滤波，mon0 直连守护即可观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$env0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$env0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

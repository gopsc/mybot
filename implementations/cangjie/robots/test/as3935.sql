/*
 * AS3935 闪电传感器测试（配套 as3935.mt）
 * 直连变量（as3935-0）读事件 + 万能守护（as-d0）低频轮询双路径
 * 事件型器件：call 返回最近锁存事件（none/noise/disturber/lightning）
 * 地址 0x03 在 I2C 保留区，i2cdetect 默认扫不到——勿误判模块损坏
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* AS3935：0x01~0x03（A0/A1 引脚电平），缺省 0x03；
 * indoor = '1' 室内/'0' 室外；nf = 噪声底 0~7（电机旁需调高）；
 * wdth/srej = 看门狗/尖峰抑制；min_lig = 确认闪电 strikes（1/5/9/16）；
 * mask_dist = '1' 屏蔽干扰源事件；tun_cap = 天线调谐电容 pF（0~120，8pF 步进）。
 * 电机/舵机是强干扰源：天线远离动力线，误报频繁先 mask_dist='1' 验证链路 */
CREATE TABLE AS3935 (
	name      String,
	I2C       String,
	address   String,
	indoor    String,
	nf        String,
	wdth      String,
	srej      String,
	min_lig   String,
	mask_dist String,
	tun_cap   String
);
INSERT INTO AS3935 (name, I2C, address, indoor, nf, wdth, srej, min_lig, mask_dist, tun_cap)
  VALUES ('as3935-0', '$i2c-1', '0x03', '-', '-', '-', '-', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：事件轮询 250ms（事件锁存，低频足够）；
 * fields 取数值字段：CODE=3 即闪电，DIST_KM 有效值 1~40（-1 无效），ENERGY 相对能量 */
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
  VALUES ('as-d0', 'lib/sensor_daemon.lua', 'AS3935', 'i2c', '/dev/i2c-1', '0x03', '250', 'CODE|DIST_KM|ENERGY');

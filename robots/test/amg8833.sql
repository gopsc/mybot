/*
 * AMG8833 8x8 红外热像阵列测试（配套 amg8833.mt）
 * 直连变量（cam0）单次读 + 万能守护（cam-d0）连续采样双路径
 * 输出为聚合标量（MAXT/MINT/AVGT/MAXR/MAXC/THERM）——64 像素原始数据
 * 流不过框架桥（call_lua 标量限制 + 守护槽 16 值上限），热像图需上位机
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* AMG8833：0x69/0x68（AD_SELECT 引脚，'-' 缺省 0x69）；
 * fps 列 1=1Hz，'-' 缺省 10Hz（interval 应 >= 帧周期） */
CREATE TABLE AMG8833 (
	name    String,
	I2C     String,
	address String,
	fps     String
);
INSERT INTO AMG8833 (name, I2C, address, fps)
  VALUES ('cam0', '$i2c-1', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：五字段聚合（MAXT/MINT/AVGT/THERM 浮点，MAXR/MAXC 整数，
 * 均勿配 sign）；interval 200ms 配 10Hz 帧率 */
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
  VALUES ('cam-d0', 'lib/sensor_daemon.lua', 'AMG8833', 'i2c', '/dev/i2c-1', '0x69', '200',
          'MAXT|AVGT|MAXR|MAXC|THERM');

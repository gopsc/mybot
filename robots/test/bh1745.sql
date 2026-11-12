/*
 * BH1745NUC 四通道颜色传感器测试（配套 bh1745.mt）
 * 直连变量（colour0）单次读 + 万能守护（clr-d0）连续采样双路径
 * 无 blob：build 即软复位 + 双 ID 甄别 + 测量时间/增益配置
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* BH1745：0x38/0x39（ADRSEL 引脚）。
 * mt=测量时间 ms(160/320/640/1280/2560/5120)，gain=ADC 增益(1/2/16)，
 * '-' 全按缺省（160ms/x1）；强光下高增益会饱和（0xFFFF 顶格） */
CREATE TABLE BH1745 (
	name    String,
	I2C     String,
	address String,
	mt      String,
	gain    String
);
INSERT INTO BH1745 (name, I2C, address, mt, gain)
  VALUES ('colour0', '$i2c-1', '0x38', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：四字段 R/G/B/C（16 位无符号原始计数，勿配 sign）；
 * interval 必须 >= 测量时间（缺省 160ms -> 200ms），否则重复同帧数据 */
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
  VALUES ('clr-d0', 'lib/sensor_daemon.lua', 'BH1745', 'i2c', '/dev/i2c-1', '0x38', '200',
          'R|G|B|C');

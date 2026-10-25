/*
 * MLX90393 三轴磁力计测试（配套 mlx90393.mt）
 * 直连变量（mlx0）单次读 + 万能守护（mlx-d0）连续采样双路径
 * 典型应用：罗盘航向（需硬铁/软铁校准）、磁铁位置感知
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* MLX90393：0x0C~0x0F（A0/A1 引脚电平组合），缺省 0x0C；
 * gain = GAIN_SEL 0~7（0=5x 最高增益，7=0.2x 最低增益，缺省 0）；
 * timeout = 单次测量就绪轮询超时 ms（缺省 50）。
 * 真机数据异常时的核对清单见 modules/MLX90393.lua 头注释
 * （轴序 OFF 表 / 灵敏度 / SM_DONE 位 / T 换算 / RES 假设） */
CREATE TABLE MLX90393 (
	name    String,
	I2C     String,
	address String,
	gain    String,
	timeout String
);
INSERT INTO MLX90393 (name, I2C, address, gain, timeout)
  VALUES ('mlx0', '$i2c-1', '0x0C', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：字段浮点发布（驱动内已补码还原，勿配 sign）；
 * 间隔 >= 单次测量耗时（缺省 OSR/FILT 下转换 + 轮询约 2~10ms） */
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
  VALUES ('mlx-d0', 'lib/sensor_daemon.lua', 'MLX90393', 'i2c', '/dev/i2c-1', '0x0C', '20', 'X|Y|Z|T');

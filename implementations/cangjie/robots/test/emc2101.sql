/*
 * EMC2101 智能风扇控制器测试（配套 emc2101.mt）
 * 直连变量（fan0）双路径：call 无参 = 采样，call 带 duty = 设手动占空比
 * LUT 自主模式示例：lut 列填 '40:0,50:30,60:60,70:100（build 编好后
 * 芯片脱离 CPU 自闭环，不占框架节拍）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* EMC2101：0x4C（模块地址可跳线，i2cdetect 确认）；PART_ID 兼容 0x16/0x28
 * duty=手动初始占空比 %（0=停转）；lut='-' 关闭片上查找表（手动模式） */
CREATE TABLE EMC2101 (
	name    String,
	I2C     String,
	address String,
	duty    String,
	lut     String
);
INSERT INTO EMC2101 (name, I2C, address, duty, lut)
  VALUES ('fan0', '$i2c-1', '0x4C', '40', '-');
-- 片上自主温控示例（二选一，替换上一条 INSERT）：
-- INSERT INTO EMC2101 (name, I2C, address, duty, lut)
--   VALUES ('fan0', '$i2c-1', '0x4C', '-', '40:0,50:30,60:60,70:100');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：三字段（TEMP_IN 整数 / TEMP_EXT 浮点 / RPM 浮点），
 * 勿配 sign——未配 sign 时浮点原样透传；二极管故障时 TEMP_EXT 发布 0，
 * 用直连路径读 STATUS 位（0x04=二极管故障）细分 */
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
  VALUES ('fan-d0', 'lib/sensor_daemon.lua', 'EMC2101', 'i2c', '/dev/i2c-1', '0x4C', '200',
          'TEMP_IN|TEMP_EXT|RPM');

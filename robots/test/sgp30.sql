/*
 * SGP30 空气质量测试（配套 sgp30.mt）
 * 直连变量（sgp30-0）单次读 + 万能守护（sgp-d0）连续采样双路径
 * SGP30 要求采样间隔 >= 1s，否则内部基线算法失效——两路节拍均按 1s 配
 * baseline 列 = 基线持久化文件路径：build 恢复 + call 每小时存盘 + destroy 存盘；
 * 守护路径下基线持久化可用（驱动自己写文件），湿度补偿不可用（引用机制不走守护）
 * 湿度补偿（可选）：先起 SHT3X 守护（fields=T|RH），再把 sht 列填守护名、
 * t_field/rh_field 填 v0/v1（直连路径每次 play 注入实时快照）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* SGP30：地址固定 0x58；baseline 列填 '-' 关闭持久化（或给路径开启） */
CREATE TABLE SGP30 (
	name     String,
	I2C      String,
	address  String,
	baseline String,
	sht      String,
	t_field  String,
	rh_field String
);
INSERT INTO SGP30 (name, I2C, address, baseline, sht, t_field, rh_field)
  VALUES ('sgp30-0', '$i2c-1', '0x58', '-', '-', '-', '-');
-- 开启持久化 + 湿度补偿示例（需同文件先定义 sht-d0 守护）：
-- INSERT INTO SGP30 (name, I2C, address, baseline, sht, t_field, rh_field)
--   VALUES ('sgp30-0', '$i2c-1', '0x58', '/tmp/sgp30-baseline.bin', 'sht-d0', 'v0', 'v1');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：两字段 CO2EQ(ppm)/TVOC(ppb)；间隔 1000ms = SGP30 采样下限。
 * Daemon 的 baseline 列直接透传给驱动（守护路径的基线持久化入口） */
CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	addr     String,
	interval String,
	fields   String,
	baseline String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, baseline)
  VALUES ('sgp-d0', 'lib/sensor_daemon.lua', 'SGP30', 'i2c', '/dev/i2c-1', '0x58', '1000', 'CO2EQ|TVOC', '-');

/*
 * MCP4725 12 位 I2C DAC 测试（配套 mcp4725.mt）
 * 模拟量输出执行器：call 带参设置（percent/volt/level，eep=1 持久化），
 * 无参读回（DAC/EEPROM 双值 + 掉电位）
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* MCP4725：0x62/0x63（A0 引脚，'-' 缺省 0x62）；
 * vref = 参考电压 V（=VDD，volt 列换算用，'-' 缺省 5.0） */
CREATE TABLE MCP4725 (
	name    String,
	I2C     String,
	address String,
	vref    String
);
INSERT INTO MCP4725 (name, I2C, address, vref)
  VALUES ('dac0', '$i2c-1', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：读回路径两字段 level（DAC 码）/eeprom（EEPROM 码），
 * 整数透传；interval 200ms 足够（读回为 5 字节单事务） */
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
  VALUES ('dac-d0', 'lib/sensor_daemon.lua', 'MCP4725', 'i2c', '/dev/i2c-1', '0x62', '200',
          'level|eeprom');

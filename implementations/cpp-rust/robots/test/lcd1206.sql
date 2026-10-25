/*
 * LCD1206 字符液晶测试结构脚本（HD44780 + PCF8574 I2C 背包）
 * 用法：cat scripts/test/lcd1206.mt | ./build/mybot --robot=robots/test/lcd1206.sql
 */

/* Timer：时基，用于行间延时 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

/* LCD1206：16x2 字符液晶，I2C 地址 0x27 */
CREATE TABLE LCD1206 (
	name    String,
	I2C     String,
	address String,
	cols    String,
	rows    String
);
INSERT INTO LCD1206 (name, I2C, address, cols, rows)
	VALUES ('lcd0', 'i2c-1', '0x27', '16', '2');

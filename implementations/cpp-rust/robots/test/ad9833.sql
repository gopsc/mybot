/*
 * AD9833 DDS 波形发生器测试（配套 ad9833.mt）
 * 信号源/激励输出设备：call 带 freq 键运行中改频（B28 原子加载无毛刺），
 * 带 mute 键静音/放行；wave 为字符串只能由结构脚本列/build 配置
 */
CREATE TABLE SPI (
	name     String,
	path     String,
	spi_mode String,
	bits     String,
	speed    String,
	delay    String
);
/* AD9833 要求 SPI 模式 2（CPOL=0/CPHA=1），bits=8，1MHz 起步（上限 14MHz） */
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi-0', '/dev/spidev0.0', '2', '8', '1000000', '0');

/* AD9833：freq=输出频率 Hz（0.1~12.5MHz），wave=sine/triangle/square，
 * phase=0~360°；'-' 均按缺省（1kHz/sine/0°） */
CREATE TABLE AD9833 (
	name  String,
	SPI   String,
	freq  String,
	wave  String,
	phase String
);
INSERT INTO AD9833 (name, SPI, freq, wave, phase)
  VALUES ('sig0', '$spi-0', '1000', 'sine', '0');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

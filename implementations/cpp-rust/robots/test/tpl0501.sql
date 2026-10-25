/*
 * TPL0501 数字电位器测试（配套 tpl0501.mt）
 * 输出型器件：无守护采样环节，仅直连调节
 * rtotal 显式配置：100000 = TPL0501-100（100kΩ），10k 型填 10000
 */
CREATE TABLE SPI (
	name     String,
	path     String,
	spi_mode String,
	bits     String,
	speed    String,
	delay    String
);
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi-0', '/dev/spidev0.0', '0', '8', '1000000', '0');

/* TPL0501：写-only，上电抽头为中点 127（非 0），抽头掉电不保存 */
CREATE TABLE TPL0501 (
	name    String,
	SPI     String,
	rtotal  String
);
INSERT INTO TPL0501 (name, SPI, rtotal) VALUES ('dpot-0', '$spi-0', '100000');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

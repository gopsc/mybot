/* FTDI SPI 回环示例（真机）：
 *   mybot --robot=robots/ftdi-spi.sql --input=scripts/ftdi-spi.mt
 *
 * 把适配器 MOSI 与 MISO 短接，probe0 发送的字节应原样读回。
 * FTDI 走 GPIO 位操作，速度不会达到 spidev 的水平；SPI 目前只支持 8 位字。
 */
CREATE TABLE SPI (
	name String,
	path String,
	spi_mode Number,
	bits Number,
	speed Number,
	delay Number
);
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi0', 'ftdi://ftdi:232h/1?cs=0', 0, 8, 1000000, 0);

CREATE TABLE SpiProbe (name String, SPI String);
INSERT INTO SpiProbe (name, SPI) VALUES ('probe0', '$spi0');

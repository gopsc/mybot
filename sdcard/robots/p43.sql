CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-f', '/dev/i2c-fake');

CREATE TABLE PCA9685 (name String, I2C String, address String, channel String);
INSERT INTO PCA9685 (name, I2C, address, channel)
  VALUES ('pca-0', '$i2c-f', '0x40', '0');

CREATE TABLE ADS1015 (name String, I2C String, address String, channel String);
INSERT INTO ADS1015 (name, I2C, address, channel)
  VALUES ('ads-0', '$i2c-f', '0x48', '0');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE SPI (name String, path String, spi_mode String, bits String,
                   speed String, delay String);
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi-f', '/dev/spidev-fake', '2', '8', '1000000', '0');

CREATE TABLE AD9833 (name String, SPI String, freq String, wave String, phase String);
INSERT INTO AD9833 (name, SPI, freq, wave, phase)
  VALUES ('sig0', '$spi-f', '1000', 'sine', '0');

CREATE TABLE UART (name String, path String, baud String);
INSERT INTO UART (name, path, baud)
  VALUES ('uart-f', '/dev/tty-fake', '115200');

CREATE TABLE UartCheck (name String, UART String);
INSERT INTO UartCheck (name, UART) VALUES ('uc', '$uart-f');

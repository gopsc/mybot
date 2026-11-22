/* P3-C: AD9833 on fake SPI (no hardware) */
CREATE TABLE SPI (
    name String, path String, spi_mode String, bits String,
    speed String, delay String
);
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi-f', '/dev/spidev-fake', '2', '8', '1000000', '0');

CREATE TABLE AD9833 (
    name String, SPI String, freq String, wave String, phase String
);
INSERT INTO AD9833 (name, SPI, freq, wave, phase)
  VALUES ('sig0', '$spi-f', '1000', 'sine', '0');

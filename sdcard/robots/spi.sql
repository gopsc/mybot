/* P3-C: AD9833 on real SPI1 (SCK GP10/MOSI GP11/MISO GP12/CS GP13) */
CREATE TABLE SPI (
    name String, path String, spi_mode String, bits String,
    speed String, delay String
);
INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
  VALUES ('spi-1', '/dev/spidev1.0', '2', '8', '1000000', '0');

CREATE TABLE AD9833 (
    name String, SPI String, freq String, wave String, phase String
);
INSERT INTO AD9833 (name, SPI, freq, wave, phase)
  VALUES ('sig0', '$spi-1', '1000', 'sine', '0');

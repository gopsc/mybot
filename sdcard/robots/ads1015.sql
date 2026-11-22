/* P3-B: ADS1015 on real I2C0 (SDA GP6, SCL GP7, address 0x48) */
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-0', '/dev/i2c-0');

CREATE TABLE ADS1015 (
    name    String,
    I2C     String,
    address String,
    channel String
);
INSERT INTO ADS1015 (name, I2C, address, channel)
  VALUES ('ads-0', '$i2c-0', '0x48', '0');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

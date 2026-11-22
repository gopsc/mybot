/* P3-B: PCA9685 on real I2C0 (SDA GP6, SCL GP7, address 0x40) */
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-0', '/dev/i2c-0');

CREATE TABLE PCA9685 (
    name    String,
    I2C     String,
    address String,
    channel String
);
INSERT INTO PCA9685 (name, I2C, address, channel)
  VALUES ('pca-0', '$i2c-0', '0x40', '0');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

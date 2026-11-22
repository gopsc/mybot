/* P3-B: PCA9685 smoke on fake I2C (no hardware; validates driver path) */
CREATE TABLE I2C (name String, path String);
INSERT INTO I2C (name, path) VALUES ('i2c-f', '/dev/i2c-fake');

CREATE TABLE PCA9685 (
    name    String,
    I2C     String,
    address String,
    channel String
);
INSERT INTO PCA9685 (name, I2C, address, channel)
  VALUES ('pca-0', '$i2c-f', '0x40', '0');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

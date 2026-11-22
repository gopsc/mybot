/* P3: real I2C bus self-check */
CREATE TABLE I2C (
    name String,
    path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-0', '/dev/i2c-0');

CREATE TABLE P3Check (
    name String,
    I2C  String
);
INSERT INTO P3Check (name, I2C) VALUES ('p3', '$i2c-0');

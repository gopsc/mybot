/* P2-B: $ref + @Alias + @Vars + fake I2C bus */
CREATE TABLE I2C (
    name String,
    path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-v', '/dev/i2c-fake');

CREATE TABLE Vars (
    name  String,
    value Number
);
INSERT INTO Vars (name, value) VALUES ('spd', 200);

CREATE TABLE RefCheck (
    name    String,
    I2C     String,
    address String,
    note    String
);
INSERT INTO RefCheck (name, I2C, address, note)
  VALUES ('rc0', '$i2c-v', '0x40', '$spd');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

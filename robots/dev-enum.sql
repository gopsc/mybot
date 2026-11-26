/*
 * 设备枚举示例
 *
 * 声明一个 Dev_enum 变量，枚举主机上的 I2C / SPI / UART 设备。
 * 纯只读操作，不需要 --allow-hardware。
 */

CREATE TABLE Dev_enum (
    name String
);

INSERT INTO Dev_enum (name) VALUES ('enum0');

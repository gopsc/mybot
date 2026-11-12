/* FTDI I2C 扫描示例（真机，需要 --allow-hardware）：
 *   mybot --robot=robots/ftdi-i2c.sql --input=scripts/ftdi-i2c.mt --allow-hardware
 *
 * 把路径换成你的适配器 URL：ftdi://ftdi:232h/1、ftdi://0x0403:0x6014/1、
 * 或 ftdi://<序列号>/1。I2C 需要总线上有上拉电阻。
 */
CREATE TABLE I2C_scan (name String, path String);
INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'ftdi://ftdi:232h/1');

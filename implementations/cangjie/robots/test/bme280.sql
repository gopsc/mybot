/*
 * BME280 温湿度气压传感器直调测试（非守护）：I2C 总线 i2c-1 挂 bme280-0，
 * I2C 列以 $ 引用总线（build/call 时实时注入 fd）；address 列 SDO 接地=0x76、
 * 接 VCC=0x77。配合 bme280.mt：三次 call 间隔 1.2s（x1 过采样建议
 * 两次 call 间隔 > 1s），每行输出 {result, T(°C), P(Pa), H(%RH)}。
 * 无器件时 build 芯片 ID 校验失败（Failed to read chip id），halt-on-error
 * 干净中断退出并倒序回收；真机下输出三行 T/P/H 实测值。
 */

/* I2C 总线：树莓派 GPIO 引出的 bus 1 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/*
 * BME280：温湿度气压三合一传感器（I2C，地址 0x76/0x77）
 *   I2C      挂载的总线（$ 引用列：build/call 时实时注入总线的 fd）
 *   address  器件地址，SDO 接地=0x76、接 VCC=0x77
 */
CREATE TABLE BME280 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO BME280 (name, I2C, address) VALUES ('bme280-0', '$i2c-1', '0x76');
-- SDO 接 VCC 的接法：
-- INSERT INTO BME280 (name, I2C, address) VALUES ('bme280-0', '$i2c-1', '0x77');

/* Timer：动作节拍（软定时器，delay 单位毫秒） */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

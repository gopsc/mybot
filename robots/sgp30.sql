/* SGP30 空气质量传感器直连示例（I2C 0x58）
 *
 * 运行：
 *   ./build/mybot --robot=robots/sgp30.sql --input=scripts/sgp30.mt
 *
 * 接线：SGP30 VCC/GND/SCL/SDA 接树莓派 I2C-1（GPIO2/GPIO3），地址固定 0x58。
 * 上电后前 15 秒读数固定 CO2eq=400 / TVOC=0，属正常启动相。
 * 采样间隔不得小于 1 秒（内部基线算法要求）。
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

CREATE TABLE SGP30 (
	name     String,
	I2C      String,
	address  String,
	baseline String,
	sht      String,
	t_field  String,
	rh_field String
);
INSERT INTO SGP30 (name, I2C, address, baseline, sht, t_field, rh_field)
  VALUES ('sgp30-0', '$i2c-1', '0x58', '-', '-', '-', '-');

CREATE TABLE Timer (name String);
INSERT INTO Timer (name) VALUES ('t0');

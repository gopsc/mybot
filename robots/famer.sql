/*
 * 灌溉器机器人————基于树莓派，
 * 利用ADS1115接土壤湿度传感器进行采样，gpio接电磁阀控制水流
 */


/*
 * 控制电磁阀的gpio对象
 */
CREATE TABLE GPIO (
	name      String,
	chip      String,
	offset    String,
	direction String,
	active    String,
	init      String
);

/* 推挽输出，高电平有效，上电 0 */
INSERT INTO GPIO (name, chip, offset, direction, active, init)
  VALUES ('p26', '/dev/gpiochip0', '26', 'out', 'high', '0');


CREATE TABLE I2C (
	name String,
	path String
);

/* 用于连接ADS1115的I2C总线 */
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/*
 * ADS1115：16 位 4 通道 ADC（I2C），土壤湿度探头接 AIN0 单端输入
 *   地址：ADDR 引脚接 GND=0x48（接 VDD=0x49、SDA=0x4A、SCL=0x4B）
 *   pga / dr / channel 三列必须显式写值：结构脚本的 '-' 占位符经元数据归一为
 *   "0"，写 '-' 会被驱动当成显式档位 pga=0（±6.144V）/ dr=0（8SPS），量程与
 *   速率双双跑偏（同 scripts/test/ads1115.mt 头注、docs/drivers.md 越界语义）
 *     pga     0~5 → ±6.144 / ±4.096 / ±2.048 / ±1.024 / ±0.512 / ±0.256 V
 *     dr      0~7 → 8 / 16 / 32 / 64 / 128 / 250 / 475 / 860 SPS
 *     channel 0~3 → AIN0~AIN3（单端；差分改走 @Action 的 pos/neg 列，
 *                   支持 0-1 / 0-3 / 1-3 / 2-3，与 channel 不可混用同一 @Action）
 *   取 pga=1（±4.096V）：3.3V 供电的电容式探头输出可到 3V 上下，±2.048V 档会
 *   削顶导致"永远偏湿"；若探头输出不超过 2V，改 pga=2 可换一倍分辨率
 *   （LSB 62.5µV）。AIN1~AIN3 备用，多探头用 @Action 的 adc0.channel 切换，
 *   无需新增器件行。
 */
CREATE TABLE ADS1115 (
	name    String,
	I2C     String,
	address String,
	pga     String,
	dr      String,
	channel String
);

/* 土壤湿度采样：adc0 挂 i2c-1 @0x48，AIN0 单端，±6.144V / 8SPS */
--INSERT INTO ADS1115 (name, I2C, address, pga, dr, channel)
 -- VALUES ('adc0', '$i2c-1', '0x48', '0', '0', '0');

CREATE TABLE LCD1206 (
    name    String,
    I2C     String,
    address String,
    cols    String,   -- 缺省 16
    rows    String    -- 缺省 2
);

/* 用于显示的LCD屏幕 */
INSERT INTO LCD1206 (name, I2C, address, cols, rows) VALUES ('lcd0', '$i2c-1', '0x27', "16", "2");

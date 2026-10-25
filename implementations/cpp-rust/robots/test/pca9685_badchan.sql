/*
 * PCA9685 通道越界负值契约（配套 scripts/test/pca9685_badchan.mt，预期非 0 退出）
 *
 * PCA9685 只有 16 路输出：channel=17 会算出 LED0_ON_L + 4*17 = 0x4A 之外的
 * 寄存器区间。驱动必须在下发总线之前就守卫住——写进保留区在真机上不报错
 * （器件照 ACK），却会静默驱动到不存在的通道上。
 *
 * 本用例同时是「非守护 virt 路径不是空断言」的证明：仿真链路会如实把驱动的
 * ERR 上抛为退出码 1，而不是因为模型 ACK 了一切就报绿。
 */
CREATE TABLE I2C (
	name  String,
	path  String,
	proto String
);
INSERT INTO I2C (name, path, proto) VALUES ('i2c-v', '/dev/i2c-99', 'virt');

CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String,
	channel String,
	proto   String
);
INSERT INTO PCA9685 (name, I2C, address, channel, proto)
  VALUES ('pca-0', '$i2c-v', '0x40', '17', 'virt');

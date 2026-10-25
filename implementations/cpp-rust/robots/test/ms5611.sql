/*
 * MS5611 高分辨率气压计测试（配套 ms5611.mt）
 * 直连变量（baro0）单次读 + 万能守护（baro-d0）连续采样双路径
 * 地址 0x77（CSB=GND）/0x76（CSB=VDD）；OSR4096 一次 call 约 20ms
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* MS5611：osr = 过采样率 256/512/1024/2048/4096（超档值降档；<256 或非数字
 * 显式报错，缺省 4096）；
 * p0 = 参考海平面气压 hPa（缺省 1013.25，按当地气象值校准 ALT_M 更准）。
 * build 读 8 字 PROM 并做 CRC-4 自检，CRC 不符即报错（兼在位甄别）。
 * 遮光海绵勿撕除：芯片裸露受光会引入气压噪声 */
CREATE TABLE MS5611 (
	name    String,
	I2C     String,
	address String,
	osr     String,
	p0      String
);
INSERT INTO MS5611 (name, I2C, address, osr, p0)
  VALUES ('baro0', '$i2c-1', '0x77', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：间隔 >= 25ms（OSR4096 两段转换约 20ms + 余量） */
/* proto=virt（审计 1.3）：本驱动在模块源里声明了 SINGLE_CONSUMER（一次访问跨多个
 * 总线事务、器件侧留有相位或锁存），而上面的直连变量已经是一个真器件消费者；
 * 守护再走 i2c 就是第二个，装配期判据（src/hw_factory.cpp 的 checkSingleConsumer）
 * 会直接拒绝加载。改 virt 后守护走内嵌 *_VIRT 模型：双路径覆盖都保留、真器件只剩
 * 一个消费者，且守护侧结果与主机有没有 /dev/i2c-1 无关（同 mpu_daemon.sql 的理由）。
 * 负值契约见 robots/test/single_consumer.sql。 */
CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	path     String,
	addr     String,
	interval String,
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
  VALUES ('baro-d0', 'lib/sensor_daemon.lua', 'MS5611', 'virt', '/dev/i2c-1', '0x77', '30', 'P_HPA|T_C|ALT_M');

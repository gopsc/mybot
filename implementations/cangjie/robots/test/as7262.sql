/*
 * AS7262 六通道光谱传感器测试（配套 as7262.mt）
 * 直连变量（spec0）单次读 + 万能守护（spec-d0）连续采样双路径
 * 六通道 V/B/G/Y/O/R（450/500/550/570/600/645nm），地址 0x49
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

/* AS7262：gain = 增益倍数 1/3.7/16/64（就近吸附，缺省 64x，强光易饱和）；
 * integ = 积分时间寄存器值 0~255（每单位 2.8ms，连续全通道一轮 = 2 x 该值
 * x 2.8ms，缺省 50 -> 约 280ms/轮）；timeout = 就绪等待超时 ms（缺省自动）。
 * 间接寄存器访问有芯片侧握手状态，禁止多消费者并发读同一器件 */
CREATE TABLE AS7262 (
	name    String,
	I2C     String,
	address String,
	gain    String,
	integ   String,
	timeout String
);
INSERT INTO AS7262 (name, I2C, address, gain, integ, timeout)
  VALUES ('spec0', '$i2c-1', '0x49', '-', '-', '-');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/* 万能采样守护：间隔 >= 一轮积分时间（缺省配置约 280ms）；
 * 消费侧看原始计数是否顶格 0xFFFF 判断饱和 */
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
  VALUES ('spec-d0', 'lib/sensor_daemon.lua', 'AS7262', 'i2c', '/dev/i2c-1', '0x49', '300', 'V|B|G|Y|O|R');

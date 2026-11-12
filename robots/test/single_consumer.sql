/*
 * 单消费者判据负值契约（审计 1.3，配套 daemon_schema.mt）
 *
 * AS7262 在模块源里声明了 SINGLE_CONSUMER：它的间接寄存器访问把地址相位放在
 * **器件侧**，一次虚拟寄存器读写跨 3~4 个独立 I2C 事务（poll HW_STATUS →
 * 写 HW_WRITE=vaddr → poll → 读 HW_READ）。第二个消费者插进来就会改掉相位，
 * 双方各自读到对方的寄存器且都看不出被踩。
 *
 * 本夹具故意声明两个消费者：直连变量 spec0 与守护 spec-d0，同为
 * /dev/i2c-1 @ 0x49。期望：**装配期**报错退出 1 并点名双方——报错发生在
 * 任何资源申请之前（Lua 状态 / 共享槽 / 总线句柄都还没建），故与主机有没有
 * 真器件无关，确定性可守门。
 *
 * 对照组（本判据**不该**打中的形态）：HAL 的每次 I2C 访问是单次 I2C_RDWR 原子
 * 事务（指针写 + 数据读合并），所以未声明该标记的器件允许「直连 + 守护」双消费者
 * ——robots/test/ 下 20 个夹具（ads1115 / adxl345 / vl53l0x / ms5611 …）正是
 * 刻意这么写的，.mt 里同时点名两者以覆盖并发采样窗口。
 *
 * 判据实现：src/hw_factory.cpp 的 checkSingleConsumer；键 = (总线设备路径, 归一化地址)。
 */
CREATE TABLE I2C (
	name String,
	path String
);
INSERT INTO I2C (name, path) VALUES ('i2c-1', '/dev/i2c-1');

CREATE TABLE AS7262 (
	name    String,
	I2C     String,
	address String
);
INSERT INTO AS7262 (name, I2C, address) VALUES ('spec0', '$i2c-1', '0x49');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

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
  VALUES ('spec-d0', 'lib/sensor_daemon.lua', 'AS7262', 'i2c', '/dev/i2c-1', '0x49', '300', 'V|B');

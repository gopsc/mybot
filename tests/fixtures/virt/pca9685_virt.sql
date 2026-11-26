/*
 * PCA9685 舵机驱动板 · 无硬件端到端（proto=virt，@Action 直写路径）
 *
 * 首条「非守护」型 virt 用例：此前虚拟总线只在 sensor_daemon.lua 里注入，
 * 所以 37 条 virt E2E 全是守护采样（读路径），而舵机/DAC 这类被 @Action
 * 直接驱动的写路径无从仿真。现由 modules/lib/drv_common.lua 的入口前置
 * 逐状态机注入：总线行（I2C）注入后自己的 i2c_open 即虚拟 open 并下发 fd，
 * 器件行采纳该 fd 并挂上内嵌模型 PCA9685_VIRT（modules/PCA9685.lua 尾部）。
 *
 * 跑的是【真实】PCA9685.lua：MODE1 重启、PRESCALE=50Hz、AI 自增合帧、
 * LED0 基址与 4 字节通道步长、channel 越界守卫，全部由模型逐事务校验。
 * 写族入参校验已对齐 HAL，故 result=OK 意味着真机会接受同样的帧。
 *
 * 用法：cat scripts/test/pca9685_virt.mt | ./build/mybot --robot=robots/test/pca9685_virt.sql
 */
CREATE TABLE I2C (
	name  String,
	path  String,
	proto String
);
/* 故意用不存在但格式合法的总线号：virt 态下 virtbus 只按模式白名单校验，照常仿真；
 * 而一旦 virt 前置回归，真实 i2c_open 会失败并响亮报错——绝不让「无硬件测试」在
 * 插了舵机的树莓派上真的写总线（横幅断言只是事后才发现）。 */
INSERT INTO I2C (name, path, proto) VALUES ('i2c-v', '/dev/i2c-99', 'virt');

/* channel 是结构元数据（寄存器地址需要整数），角度才是动作参数 */
CREATE TABLE PCA9685 (
	name    String,
	I2C     String,
	address String,
	channel String,
	proto   String
);
INSERT INTO PCA9685 (name, I2C, address, channel, proto)
  VALUES ('pca-0', '$i2c-v', '0x40', '0', 'virt');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

/*
 * MPU6050 无硬件端到端测试（proto=virt）：
 *   sensor_daemon 不打开真机 I2C，而是挂内存仿真模型——MPU6050_VIRT，内嵌于
 *   modules/MPU6050.lua 尾部（2026-09-15 迁入，守护经回退路径装载），
 *   模型每拍 virt_tick 造确定性合成波形
 *   （accel 三轴正弦 ±20000 LSB、gyro 余弦 ±10000 LSB、温度约 41°C 慢漂）。
 *   守护启动会打印 VIRTUAL HARDWARE 警告横幅。
 *
 * 链路与真机 mpu_filter 完全同构：
 *   守护线程（独立 lua_State）→ 共享槽（32 通道 double + mutex）
 *   → 七个 Ema 滤波变量（α=0.2，field=v0..v6）→ Monitor 引用消费。
 *   mon0 直接引用守护 imu0（raw 七字段 + count，验证守护→Monitor）；
 *   monf 引用 eax（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *
 * 配合 mpu_virt.mt：200ms 预热等守护 setup（含驱动 build 的 100ms sleep），
 * 随后 20 拍 ×50ms pump 七路滤波并消费两个 Monitor。
 * 用法：cat scripts/test/mpu_virt.mt | ./build/mybot --robot=robots/test/mpu_virt.sql
 */
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
	fields   String,
	sign     String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');

/* 七个一阶低通滤波器（与 mpu_filter.sql 同构）：src 以 $ 引用守护 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eax',  '0.2', '$imu0', 'v0');
INSERT INTO Ema (name, alpha, src, field) VALUES ('eay',  '-',   '-',      'v1');
INSERT INTO Ema (name, alpha, src, field) VALUES ('eaz',  '-',   '-',      'v2');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egx',  '-',   '-',      'v3');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egy',  '-',   '-',      'v4');
INSERT INTO Ema (name, alpha, src, field) VALUES ('egz',  '-',   '-',      'v5');
INSERT INTO Ema (name, alpha, src, field) VALUES ('etmp', '-',   '-',      'v6');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eax（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$imu0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eax');

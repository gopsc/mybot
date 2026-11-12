/*
 * MPU6050 六轴 + 温度 EMA 滤波测试（真机）：
 *   sensor_daemon 万能采样 imu0（interval=10ms，fields 七字段，sign=16；
 *   TEMP 为摄氏度浮点，用 :f 后缀原样透传）
 *   → 七个 Ema 滤波变量各滤一路（α=0.2，field=v0..v6）
 * 配合 mpu_filter.mt：每拍显式 pump 七个滤波变量（引用读是无副作用快照，
 * 不 pump 不推进滤波状态），顶层逐路直出 {"v0"=滤波值, "raw"=原始值}。
 *
 * 通道映射（与 Daemon.fields 顺序一致）：
 *   eax→v0 ACCEL_X  eay→v1 ACCEL_Y  eaz→v2 ACCEL_Z
 *   egx→v3 GYRO_X   egy→v4 GYRO_Y   egz→v5 GYRO_Z
 *   etmp→v6 TEMP（片上温度 °C）
 *
 * 调参：α∈(0,1]，越小越平滑、滞后越大（按消费节拍 50ms≈20Hz 计）。
 * 想换卡尔曼：把 Ema 表改成 Kalman 表、列改为 Q/R（如 '20'/'200'，
 * Q 越大越信任测量），驱动接口同构，.mt 无需改列名之外的内容。
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
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'i2c',
          '/dev/i2c-1', '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f', '16');

/* 七个一阶低通滤波器：src 以 $ 引用守护，field 指定各自滤的快照字段；
 * alpha/src 用 "-" 继承上一行 */
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

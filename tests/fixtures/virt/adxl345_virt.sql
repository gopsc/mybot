/*
 * ADXL345 无硬件端到端（proto=virt，8 位指针 + 6 字节小端 burst IMU）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * ADXL345_VIRT（内嵌于 modules/ADXL345.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻协议——DEVID(0x00)=0xE5 只读、
 * DATA_FORMAT(0x31) build 先读回再 RMW（保高 4 位、置 FULL_RES bit3 与
 * 量程码）、BW_RATE(0x2C) 低 4 位速率码（缺省 0x0A=100Hz）、POWER_CTL
 * (0x2D) 写 0x08 进测量态；数据区 0x32 起 6 字节【小端】补码
 * （X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,Z_MSB，与 MPU6050 大端相反），call 一次
 * i2c_read_multi(0x32,6) 读三轴。守护跑真实 ADXL345.lua build（set + 2 笔
 * 读指针/读回 + 3 笔配置写共 8 事务、等两个测量周期 22ms）与 call（set +
 * 写 0x32 指针 + 6B burst 共 3 事务、零睡眠）。FULL_RES 下灵敏度全量程
 * 恒定 256 LSB/g（3.9mg/LSB），驱动不做符号扩展，原始无符号码交 sign='16'
 * 在守护侧展开为有符号整数。
 *
 * 模型每拍 virt_tick 造确定性三轴正弦（32 拍周期，互差 120°）：X/Y 为
 * ±0.30g 小幅晃动（±77 码），Z 为 1g 重力 + ±0.05g 起伏（245~262 码，
 * 全程为正），均远在 ±2g 削顶（±512 码）内——n0: X=0/Y=67/Z=245，
 * n8 峰 X=77/Y=-38/Z=250，n24 谷 X=-77/Z=262。build 前预武装
 * virt_tick(0)，22ms 等待远小于预热窗口。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=ACCEL_X 做 α=0.2 一阶滤波（整数码混合后 out 必为带小数
 *     浮点，run_all 以此锚定 EMA 确实推进）→ Monitor 引用消费。
 *   mon0 直连守护 ac0（raw 三字段均为 sign='16' 展开后的有符号整数 +
 *   count）；monf 引用 eax（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=ACCEL_Y / v2=ACCEL_Z 直连守护观察，不滤波。
 *
 * range/odr 两列透传驱动 build（非守护框架键，原样进 params）：显式给
 * 缺省 ±8g / 100Hz，验证取档参数经守护到驱动的全链路。
 *
 * 配合 adxl345_virt.mt：200ms 预热等守护 setup（build 睡 22ms，余量
 * 充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护
 * interval=20ms（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/adxl345_virt.mt | ./build/mybot --robot=robots/test/adxl345_virt.sql
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
	sign     String,
	range    String,
	odr      String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, range, odr)
  VALUES ('ac0', 'lib/sensor_daemon.lua', 'ADXL345', 'virt',
          '/dev/i2c-1', '0x53', '20', 'ACCEL_X|ACCEL_Y|ACCEL_Z', '16', '8', '100');

/* 一阶低通滤波器：只滤 v0=ACCEL_X（整数 s16 码，α 混合后 out 为浮点）；
 * v1/v2 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eax', '0.2', '$ac0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eax（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ac0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eax');

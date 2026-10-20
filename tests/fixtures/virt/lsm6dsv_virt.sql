/*
 * LSM6DSV16X 无硬件端到端（proto=virt，ST 六轴 IMU，I2C 0x6A/0x6B、
 * WHO_AM_I 0x0F=0x70）：sensor_daemon 不打开真机 I2C，而是挂内存仿真
 * 模型 LSM6DSV_VIRT（内嵌于 modules/LSM6DSV.lua 尾部，2026-09-15 迁入，
 * 守护经回退路径装载）。模型复刻 8 位字节指针 +
 * 【CTRL3 软复位/IF_INC 门】+ 双 6 字节小端连续测量窗——0x0F
 * WHO_AM_I=0x70、0x12 CTRL3（bit0 sw_reset 写即自清、bit2 IF_INC
 * 控制 burst 是否自增、bit6 BDU、bit7 BOOT 自清）、0x10/0x11
 * CTRL1/2（ODR 低 4 位）、0x15 CTRL6（fs_g 低 4 位，±4000dps=0xC
 * 不连续码）、0x17 CTRL8（fs_xl 低 2 位；0x18 是 CTRL9 不是量程
 * 寄存器——真机驱动旧版曾写错地址，本链路走修复后的 0x17）。
 * 测量窗陀螺在前 OUTX_L_G=0x22 起 6B、加计 OUTX_L_A=0x28 起 6B，
 * 各轴 LSB 在前【小端】，连续模式常驻。
 *
 * 守护跑【真实】LSM6DSV.lua build（set + WHO 甄别 + CTRL3 软复位
 * 首拍轮询即自清 + 置 BDU|IF_INC 0x44 + CTRL1/2 ODR + CTRL6/CTRL8
 * 读改写量程，真实 milli_sleep 10+100=110ms）与 call（set + 0x22
 * 指针 6B gyr burst + 0x28 指针 6B acc burst，零睡眠，驱动不做物理
 * 换算，六字段交 sign='16' 展开为有符号整数）。
 *
 * 无转换门：模型 virt_tick 装码即数据常驻（build 前守护自动
 * virt_tick(0) 亦无副作用，真实 build 实睡 110ms，200ms 预热余量
 * 充裕）；daemon_tick 每拍先 virt_tick(n) 再 call。32 拍确定性离线
 * 码钉（独立灵敏度常数反解固化，模型不含正算公式）：ACCEL
 * X 100~500 / Y -350~-50 / Z 3998~4198（≈1g 重力，±8g 档
 * 4098 LSB/g）；GYRO X ±500 / Y ±400 / Z ±300。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=ACCEL_X 做 α=0.2 一阶滤波（整数码混合后 out 必为带
 *     小数浮点，run_all 以此锚定 EMA 推进）→ Monitor 引用消费。
 *   mon0 直连守护 im0（raw 六字段均为 sign='16' 展开后的有符号整数 +
 *   count）；monf 引用 ei（滤波后 v0，验证 Ema→Monitor 闭环）。
 *   v1..v5 直连守护观察，不滤波。
 *
 * range/gyro_range/odr 三列透传驱动 build（非守护框架键，原样进
 * params）：显式给缺省 ±8g / ±500dps / 120Hz，验证取档参数经守护
 * 到驱动的全链路；'-' 与非法值在驱动侧归缺省。
 *
 * 配合 lsm6dsv_virt.mt：200ms 预热等守护 setup（build 实睡 110ms），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=50ms
 *（call 零睡眠），32 拍码钉循环多轮。
 * 用法：cat scripts/test/lsm6dsv_virt.mt | ./build/mybot --robot=robots/test/lsm6dsv_virt.sql
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name       String,
	chunk      String,
	driver     String,
	proto      String,
	path       String,
	addr       String,
	interval   String,
	fields     String,
	sign       String,
	range      String,
	gyro_range String,
	odr        String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign,
                    range, gyro_range, odr)
  VALUES ('im0', 'lib/sensor_daemon.lua', 'LSM6DSV', 'virt',
          '/dev/i2c-1', '0x6A', '50',
          'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z', '16',
          '8', '500', '120');

/* 一阶低通滤波器：只滤 v0=ACCEL_X（整数 s16 码，α 混合后 out 为浮点）；
 * v1..v5 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ei', '0.2', '$im0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ei */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$im0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ei');

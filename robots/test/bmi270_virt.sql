/*
 * BMI270 无硬件端到端（proto=virt，Bosch 六轴 IMU，I2C 0x68/0x69、
 * CHIP_ID=0x24）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * BMI270_VIRT（内嵌于 modules/BMI270.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻 8 位字节指针 + 【配置 blob
 * 上传状态机】——0x7E/0xB6 软复位、0x00 CHIP_ID=0x24、0x21
 * INTERNAL_STATUS 状态码（0 idle/1 init_ok/2 init_err）、0x7C PWR_CONF
 * AUX/adv_power、0x7D PWR_CTRL、blob 三段上传（INIT_CTRL 0x59 清缓冲
 * → 每 8 字节一对帧：0x5B INIT_ADDR 低 4 位写 word%16、整字另字节写
 * floor(word/16)；0x5E INIT_DATA 8 字节——模型在此设【地址陷阱】：burst
 * 帧全部字节落 blob 窗口，不普通自增、不进 regs 影子）→ INIT_CTRL=1
 * 启动加载门（fifo 328B/full 8192B 合法长度，150ms 门；长度不符即
 * init_err）；0x40/0x42 CONF（ODR 高 4 位）、0x41/0x43 RANGE。测量区
 * 0x0C..0x17 六轴各 6 字节【小端 LSB 在前】连续读。
 *
 * 守护跑【真实】BMI270.lua build（set + 软复位 + PWR_CONF/PWR_CTRL +
 * blob 41 对帧上传 fifo 328B + INIT_CTRL=1 + 真实 milli_sleep 轮询
 * INTERNAL_STATUS + CONF/RANGE 读改写 + 上电 100ms 等陀螺仪起转）与
 * call（set + 0x0C 指针 6B acc burst + 0x12 指针 6B gyr burst，零
 * 睡眠，驱动不做物理换算，六字段交 sign='16' 展开为有符号整数）。
 *
 * 有加载门器件：模型 virt_tick 装码即【预武装】——build 前守护自动
 * virt_tick(0)，预武装后首拍轮询即 init_ok（build 仅睡 114ms，200ms
 * 预热余量充裕）；daemon_tick 每拍先 virt_tick(n) 再 call。32 拍
 * 确定性离线码钉（独立公式反解固化，模型不含换算公式）：ACCEL
 * X 100~500 / Y -350~-50 / Z 3996~4196（≈1g 重力，±8g 档
 * 4096 LSB/g）；GYRO X ±500 / Y ±400 / Z ±300。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=ACCEL_X 做 α=0.2 一阶滤波（整数码混合后 out 必为带
 *     小数浮点，run_all 以此锚定 EMA 推进）→ Monitor 引用消费。
 *   mon0 直连守护 im0（raw 六字段均为 sign='16' 展开后的有符号整数 +
 *   count）；monf 引用 ei（滤波后 v0，验证 Ema→Monitor 闭环）。
 *   v1..v5 直连守护观察，不滤波。
 *
 * range/gyro_range/odr/cfg 四列透传驱动 build（非守护框架键，原样进
 * params）：显式给缺省 ±8g / ±500dps / 100Hz / fifo blob，验证取档
 * 参数经守护到驱动的全链路；'-' 与非法值在驱动侧归缺省。
 *
 * 配合 bmi270_virt.mt：200ms 预热等守护 setup，随后 16 拍 ×50ms pump
 * 滤波并消费两个 Monitor。守护 interval=50ms（call 零睡眠），32 拍
 * 码钉循环多轮。
 * 用法：cat scripts/test/bmi270_virt.mt | ./build/mybot --robot=robots/test/bmi270_virt.sql
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
	odr        String,
	cfg        String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign,
                    range, gyro_range, odr, cfg)
  VALUES ('im0', 'lib/sensor_daemon.lua', 'BMI270', 'virt',
          '/dev/i2c-1', '0x68', '50',
          'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z', '16',
          '8', '500', '100', 'fifo');

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

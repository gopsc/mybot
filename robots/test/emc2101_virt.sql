/*
 * EMC2101 无硬件端到端（proto=virt，Microchip/SMSC 智能风扇控制器：
 * PWM 输出 + 内外双温度/TACH 转速测量反馈混合器件）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * EMC2101_VIRT（内嵌于 modules/EMC2101.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻 8 位字节指针协议——
 * 0x4A FAN_CONFIG（bit5=PROG 硬件门，POR=0x20 手动/可编程态；
 * PROG=0 时 0x4C 与 LUT 只读，LUT 激活片上温控闭环）、0x4C
 * FAN_SETTING（6 位占空比，100% 满码=2×max(1,PWM_F)）、0x4D
 * PWM_F（低 5 位，POR=0x17=23 → full_lsb=46）、0x50~0x5F LUT
 * 8×(7 位温度,6 位占空比)（POR 全 [0x7F,0x3F] 兜底）、0xFD/0xFE
 * 双 Part ID 0x16（-R 版 0x28）+MFG 0x5D 甄别。
 * 守护跑【真实】EMC2101.lua build（set + 0xFD/0xFE 双 ID 读 +
 * 0x4D PWM_F 读现算 full_lsb + lut_disable 读-改-写 + 0x4C 初始
 * 占空比 = set+6w+4r 共 11 事务；全程无 milli_sleep）与 call 采样
 * （set + 0x02/0x00/0x01/0x10/0x46/0x47 六组指针/r = 13 事务；
 * 外温先读 MSB 0x01 锁存 LSB 0x10，TACH 恰好相反先读 LSB 0x46
 * 锁存 MSB 0x47，§6.1 Data Read Interlock）。
 *
 * 连续测量器件无转换门：模型 virt_tick 直接装码预武装，按【32 拍
 * 确定性正弦】造数——内温 35±5°C（s8 整数）、外温 42±6°C（11 位
 * 补码 ×0.125°C，双字节 interlock）、RPM 3000±1200（恒四位数
 * 1800~4200，TACH count=5,400,000/RPM 反推小端装码），STATUS=0。
 * build 前自动 virt_tick(0) 预武装（35/42.0/3000）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v1=TEMP_EXT（浮点 °C）做 α=0.2 一阶滤波
 *     （正弦值混合后 out 必为带小数浮点，run_all 以此锚定 EMA 推进）
 *   → Monitor 引用消费。mon0 直连守护 as0（raw：TEMP_IN 整数 +
 *   TEMP_EXT:f/RPM:f 两浮点 + count）；monf 引用 ev（滤波后外温，
 *   验证 Ema→Monitor 闭环）。TEMP_IN 为整数（无 :f，值在 16 位
 *   内 sign=16 不改动）；TEMP_EXT 带 1/8°C 小数、RPM 非整数整除
 *   时带小数，必须逐字段 :f 原样透传。
 *
 * 芯片固定地址 0x4C；无额外 build 参数 = 手动模式 duty=0（风扇
 * 停转不影响温度/TACH 测量链路）。
 *
 * 配合 emc2101_virt.mt：200ms 预热等守护 setup（build 零睡眠，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（连续测量，一拍对应一次 virt_tick，
 * count 持续增长、32 拍正弦循环多轮）。
 * 用法：cat scripts/test/emc2101_virt.mt | ./build/mybot --robot=robots/test/emc2101_virt.sql
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
  VALUES ('as0', 'lib/sensor_daemon.lua', 'EMC2101', 'virt',
          '/dev/i2c-1', '0x4C', '20', 'TEMP_IN|TEMP_EXT:f|RPM:f', '16');

/* 一阶低通滤波器：只滤 v1=TEMP_EXT（外温浮点 °C，α 混合后 out 为
 * 浮点）；v0=TEMP_IN 整数/v2=RPM:f 浮点直连守护观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$as0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（外温） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$as0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

/*
 * MS5611 无硬件端到端（proto=virt，首个「单字节命令编码通道+OSR 档位」
 * +「指针读 PROM/ADC」+ PROM 出厂校准 CRC-4 的命令式 I2C 虚拟器件）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * MS5611_VIRT（内嵌于 modules/MS5611.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻协议——0x1E 软复位、
 * 0x40+2i/0x50+2i 启动 D1/D2 转换（两区间分别判、仅偶数）、
 * 0xA0+2i 指针读 8 字 PROM（2B）、0x00 指针读 24 位 ADC（3B），
 * word7 CRC-4 位域模型真算（TE/PX4 布局，参与自身运算）。守护跑的是
 * 【真实】MS5611.lua 的完整 build（软复位真实睡 3ms → 八字 PROM
 * 指针读 → CRC-4 校验兼在位甄别）与 call（D1/D2 双段转换：启动命令
 * →10ms×2 真实等待→0x00 指针读→一阶补偿，20°C 以下二阶/极低温
 * 追加项；d1*sens ~2^56 拆高/低 12 位防超 double 2^53）。
 *
 * 模型每拍 virt_tick 在气压/温度空间造确定性正弦（P 1013.25±5hPa、
 * T 22±2°C，32 拍周期，全程暖机段二阶不触发）并预武装——守护不驱动
 * 虚拟时钟，预武装使转换门不再门控；驱动自身的 milli_sleep(3ms
 * build / 10+10ms call) 在守护里是真实睡眠，interval=50ms 容纳。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=P_HPA 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 baro0（raw P/T/ALT 三字段
 *   + count）；monf 引用 ep（滤波后 v0 + level，验证 Ema→Monitor
 *   闭环）。v1=T_C、v2=ALT_M 浮点不滤波。
 *
 * Daemon 额外列 osr/p0 自动透传 build/call 参数（sensor_daemon 的
 * known 表只排除框架键）：OSR4096、p0 缺省 1013.25hPa。
 *
 * 配合 ms5611_virt.mt：300ms 预热等守护 setup，随后 16 拍 ×50ms
 * pump 滤波并消费两个 Monitor。
 * 用法：cat scripts/test/ms5611_virt.mt | ./build/mybot --robot=robots/test/ms5611_virt.sql
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
	osr      String,
	p0       String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, osr, p0)
  VALUES ('baro0', 'lib/sensor_daemon.lua', 'MS5611', 'virt',
          '/dev/i2c-1', '0x77', '50', 'P_HPA:f|T_C:f|ALT_M:f', '-', '4096', '-');

/* 一阶低通滤波器：只滤 v0=P_HPA（:f 浮点透传，禁止取整）；
 * T_C/ALT_M 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ep', '0.2', '$baro0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ep（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$baro0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ep');

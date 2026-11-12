/*
 * BH1745NUC 无硬件端到端（proto=virt，四通道 R/G/B/C 颜色传感器）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * BH1745_VIRT（内嵌于 modules/BH1745.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻协议——稀疏字节寄存器图：
 * SYSTEM_CONTROL 0x40（POR 0x0B：bit7 SW reset 自清全片复位+power down、
 * bit6 INT reset 自清仅抬 INT 脚、[5:0] Part ID ROM 0x0B 只读）、
 * MODE_CONTROL1 0x41（[2:0] 积分时间码 0..5=160/320/640/1280/2560/
 * 5120ms，码 6/7 forbidden）、MODE_CONTROL2 0x42（bit7 VALID 只读动态
 * 合成：写 MODE 寄存器或读 0x42 后清 0、周期到点置 1；bit4 RGBC_EN；
 * [1:0] 增益 0/1/2=x1/x2/x16、3 forbidden）、MODE_CONTROL3 0x44（写
 * 0x02）、0x50~0x57 RGBC 数据块【小端】（偶地址 LSB：0x50=RED_LSB、
 * 0x51=RED_MSB，G/B/Clear 同构，只读）、INTERRUPT 0x60、PERSISTENCE
 * 0x61（POR 0x01）、TH 0x62/63（POR 0xFFFF）、TL 0x64/65（POR 0）、
 * MANUFACTURER 0x92（ROM 0xE0）。双地址 0x38/0x39。
 * 守护跑【真实】BH1745.lua build（set + 软复位 {40,80} + milli_sleep(5)
 * + 双 ID 甄别两笔 i2c_read_reg + MODE1/2/3 三写 + milli_sleep(162)
 * = 9 事务，缺省档真实睡眠共 167ms）与 call（set + 0x50 指针写 + 8B
 * 小端原子读 = 3 事务、零睡眠；驱动不读 VALID）。
 *
 * 模型每拍 virt_tick 造同相确定性正弦计数（32 拍周期）：
 * R 22000±3000（19000~25000）、G 26000±3500、B 15000±2200、
 * C 42000±4000，n0 全在基线；直接装数据区并置 VALID=1 预武装——
 * build 的 MODE 写只清 VALID 不清数据，call 恒有新鲜数据零睡眠，
 * 一拍对应一个 virt_tick。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=R 通道计数做 α=0.2 一阶滤波（:f 浮点透传，禁止取整补码）
 *   → Monitor 引用消费。mon0 直连守护 cl0（raw 四通道计数 + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1~v3 = G/B/Clear 原始计数（无符号 0~65535，全字段 :f 原样透传，
 *   切不可走 sign=16 补码——≥32768 的计数会被误转负数）。
 *
 * 芯片地址 0x38（ADRSEL=L），无额外 build 参数（mt/gain 缺省：
 * 160ms / x1）。
 *
 * 配合 bh1745_virt.mt：首行 200ms 预热等守护 setup（必须容纳 build 的
 * 167ms 真实睡眠），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/bh1745_virt.mt | ./build/mybot --robot=robots/test/bh1745_virt.sql
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
  VALUES ('cl0', 'lib/sensor_daemon.lua', 'BH1745', 'virt',
          '/dev/i2c-1', '0x38', '20', 'R:f|G:f|B:f|C:f', '16');

/* 一阶低通滤波器：只滤 v0=R 通道计数（:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$cl0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$cl0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

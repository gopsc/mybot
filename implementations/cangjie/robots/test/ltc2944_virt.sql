/*
 * LTC2944 无硬件端到端（proto=virt，「8 位字节指针 + 16 位大端寄存器对、
 * 指针自增模 26 回绕」I2C 虚拟器件——寄存器文件仅 0x00~0x19 共 26 字节，
 * 越过 0x19 回 0x00 而非模 256，不能套 regmap）：sensor_daemon 不打开真机
 * I2C，而是挂内存仿真模型 modules/lib/virtbus/ltc2944.lua。模型复刻协议
 * ——write 首字节=指针其后数据逐字节落位（CONTROL(0x01) 是 8 位寄存器，
 * 正确写帧恰 {0x01,ctrl} 两字节）、read 从当前指针连续读且每字节后指针
 * 模 26 自增；四对 16 位大端测量寄存器 0x02 累计电荷（可主机写）/0x08
 * 电压/0x0E 电流（偏移二进制，中点 0x7FFF=0A）/0x14 温度。无 ID 寄存器，
 * build 的在位甄别 = 指针读 STATUS(0x00) 2 字节 ACK + CONTROL 单字节写，
 * 全程零 milli_sleep；call 依次指针读 02/08/0E/14 四对（set + 4×写指针/
 * 读，零睡眠），换算全在驱动：V=raw/65535×70.8、
 * I=(raw-0x7FFF)/0x7FFF×0.064/rsense、T=raw/65535×510−273.15、
 * CHARGE(mAh)=code×0.34e-6×1000×(M×0.05)/(rsense×4096)。
 *
 * 模型每拍 virt_tick 造确定性同相正弦（32 拍周期：V 12.0±0.4V、
 * I 0.8±0.4A @50mΩ——满量程 ±1.28A，峰值 1.2A 不削顶、T 30±5°C；
 * n0=12.0V/0.8A/30°C、n8 峰 12.4V/1.2A/35°C、n24 谷 11.6V/0.4A/25°C），
 * 累计电荷 10000+200n code 单调爬坡。build 前预武装 virt_tick(0)；
 * 连续转换结果常驻、无转换门。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v1=V 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 gauge0（raw 四字段 + count）；
 *   monf 引用 eavg（滤波后 v1 + level，验证 Ema→Monitor 闭环）。
 *   v0=CHARGE、v2=I、v3=T 浮点不滤波。
 *
 * Daemon 额外列 rsense/prescaler 自动透传 build 参数（sensor_daemon 的
 * known 表只排除框架键）：50mΩ 分流、M=4096 最大电荷量程档。
 *
 * 配合 ltc2944_virt.mt：200ms 预热等守护 setup（build 零睡眠，余量充裕），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=20ms
 *（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/ltc2944_virt.mt | bash _run.sh --robot=robots/test/ltc2944_virt.sql
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name      String,
	chunk     String,
	driver    String,
	proto     String,
	path      String,
	addr      String,
	interval  String,
	fields    String,
	sign      String,
	rsense    String,
	prescaler String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, rsense, prescaler)
  VALUES ('gauge0', 'lib/sensor_daemon.lua', 'LTC2944', 'virt',
          '/dev/i2c-1', '0x64', '20', 'CHARGE:f|V:f|I:f|T:f', '16', '0.05', '4096');

/* 一阶低通滤波器：只滤 v1=V（:f 浮点透传，禁止取整）；
 * CHARGE/I/T 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$gauge0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$gauge0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

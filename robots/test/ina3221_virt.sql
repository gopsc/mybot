/*
 * INA3221 无硬件端到端（proto=virt，INA219/INA226 同族的「字寻址 16 位
 * 寄存器」I2C 虚拟器件的三通道版——寄存器号各代表一个 16 位字，而非字节
 * 地址，不能套字节地址 regmap）：sensor_daemon 不打开真机 I2C，而是挂内存
 * 仿真模型 INA3221_VIRT（内嵌于 modules/INA3221.lua 尾部，2026-09-15 迁入，
 * 守护经回退路径装载）。模型复刻协议——CONFIG 0x00
 * 复位默认 0x7127（3 通道全使能、AVG=1、双 1.1ms、连续；全 16 位有定义
 * 无保留位，bit15=RST 软复位 0x8000 不落盘、全文件恢复默认）、三通道各一对
 * 结果寄存器（SHUNT1/BUS1=0x01/02、CH2=0x03/04、CH3=0x05/06；分流/总线
 * 同为 13 位有效左移 3 存放：分流 s13 LSB 40µV、总线 u13 LSB 8mV），真
 * ROM ID 0xFE=0x5449（'TI'）/0xFF=0x3220。写恒 {ptr,hi,lo}、读恒「写
 * ptr + 读 2 字节」返回该字 hi/lo，相邻字绝不串读。守护跑的是【真实】
 * INA3221.lua 完整 build（先 MFG/DIE 双 ID 甄别 → 软复位真实睡 10ms →
 * 写工作配置 0x7527 → 三通道完整转换循环真实睡 108ms）与 call（连读
 * 0x01~0x06 六寄存器，I=Vshunt/RshuntN 全软件换算，读后 >>3）。
 *
 * 模型每拍 virt_tick 为三条母线/负载造确定性同相正弦（32 拍周期，均按
 * 板载 10mΩ 反推分流压降）：ch1 V 12.0±0.4V、I 0.5±0.3A；ch2 V
 * 12.0±0.4V、I 1.0±0.4A；ch3 V 5.0±0.2V、I 0.3±0.15A（n0=12/0.5、
 * 12/1.0、5/0.3；n8 峰 12.4/0.8、12.4/1.4、5.2/0.448；n24 谷 11.6/0.2、
 * 11.6/0.6、4.8/0.152），build 前预武装 virt_tick(0)——连续模式结果寄存
 * 器恒有值，无转换门；驱动自身 milli_sleep 在守护里是真实睡眠（build
 * 共约 118ms / call 零睡眠）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=V1 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 im0（raw 六字段 + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=I1/v2=V2/v3=I2/v4=V3/v5=I3 浮点不滤波。
 *
 * Daemon 额外列 avg/rshunt1/rshunt2/rshunt3 自动透传 build 参数
 * （sensor_daemon 的 known 表只排除框架键）：三通道均板载 10mΩ、
 * avg16 缺省（'-'）。
 *
 * 配合 ina3221_virt.mt：200ms 预热等守护 setup（build 真实睡约 118ms），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=20ms
 *（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/ina3221_virt.mt | ./build/mybot --robot=robots/test/ina3221_virt.sql
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
	avg      String,
	rshunt1  String,
	rshunt2  String,
	rshunt3  String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, avg, rshunt1, rshunt2, rshunt3)
  VALUES ('im0', 'lib/sensor_daemon.lua', 'INA3221', 'virt',
          '/dev/i2c-1', '0x40', '20', 'V1:f|I1:f|V2:f|I2:f|V3:f|I3:f', '16',
          '-', '0.01', '0.01', '0.01');

/* 一阶低通滤波器：只滤 v0=V1（:f 浮点透传，禁止取整）；
 * 其余五字段直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$im0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$im0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

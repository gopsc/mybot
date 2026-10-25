/*
 * INA219 无硬件端到端（proto=virt，首个「字寻址 16 位寄存器」I2C 虚拟
 * 器件——寄存器号 0x00~0x05 各代表一个 16 位字，而非字节地址，不能套
 * 字节地址 regmap）：sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * modules/lib/virtbus/ina219.lua。模型复刻协议——CONFIG 0x00 复位默认
 * 0x399F（bit15=RST 软复位，0x8000 不落盘、全文件恢复默认）、SHUNT
 * 0x01（16 位有符号，LSB 10µV）、BUS 0x02（13 位左移 3，LSB 4mV，
 * 低 3 位 CNVR/OVF 标志），写恒 {ptr,hi,lo}、读恒「写 ptr + 读 2 字节」
 * 返回该字 hi/lo，相邻字绝不串读。守护跑的是【真实】INA219.lua 的完整
 * build（软复位真实睡 10ms → 配置读回 0x399F 兼芯片甄别，INA226 默认
 * 0x4127 会被拒 → 写工作配置 → avg16 转换循环真实睡 20ms）与 call
 * （读 0x01 分流 + 0x02 总线，I=Vshunt/Rshunt、P=Vbus·I 全软件换算，
 * 不写 0x05 校准；BUS>>3 低 3 位标志不影响电压）。
 *
 * 模型每拍 virt_tick 在电压/电流空间造确定性同相正弦（V 12.0±0.4V、
 * I 1.0±0.6A @R100，32 拍周期：n0=12.0V/1.0A、n8 峰 12.4V/1.6A、
 * n24 谷 11.6V/0.4A）并在 build 前预武装 virt_tick(0)——连续模式
 * 结果寄存器恒有值，无转换门；驱动自身 milli_sleep 在守护里是真实
 * 睡眠（build 共约 30ms / call 零睡眠）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=V 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 ina0（raw 三字段 + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=I、v2=P 浮点不滤波（P=V·I）。
 *
 * Daemon 额外列 rshunt/avg 自动透传 build/call 参数（sensor_daemon 的
 * known 表只排除框架键）：R100 分流、avg16 缺省（'-'）。
 *
 * 配合 ina219_virt.mt：200ms 预热等守护 setup（build 真实睡约 30ms），
 * 随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护 interval=20ms
 *（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/ina219_virt.mt | bash _run.sh --robot=robots/test/ina219_virt.sql
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
	rshunt   String,
	avg      String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, rshunt, avg)
  VALUES ('ina0', 'lib/sensor_daemon.lua', 'INA219', 'virt',
          '/dev/i2c-1', '0x40', '20', 'V:f|I:f|P:f', '16', '0.1', '-');

/* 一阶低通滤波器：只滤 v0=V（:f 浮点透传，禁止取整）；
 * I/P 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$ina0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$ina0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

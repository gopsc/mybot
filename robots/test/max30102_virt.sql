/*
 * MAX30102 无硬件端到端（proto=virt，首个「环形 FIFO + 读写指针/溢出计数
 * + rollover + 18 位样本块读」I2C 器件）：sensor_daemon 不打开真机 I2C，
 * 而是挂内存仿真模型 MAX30102_VIRT（内嵌于 modules/MAX30102.lua 尾部，
 * 2026-09-15 迁入，守护经回退路径装载）。守护跑的是【真实】
 * MAX30102.lua 完整 build（读 0xFF 甄别 PART_ID=0x15→写 MODE RESET 后
 * 真实 milli_sleep 5ms→FIFO_CFG 固定开 rollover→SPO2_CFG→LED1/2→清
 * WR/OVF/RD 三指针→写 MODE=SpO2 启动）与 call（读 WR/RD 按 (WR-RD)%32
 * 算可用数→空 FIFO 跳拍不发布→从 FIFO_DATA 0x07 流式口逐样本读 6 字节，
 * RED+IR 各 18 位 MSB 对齐三字节帧解码；满码 0x3FFFF 只置 SAT 不报错）。
 *
 * 模型每拍 virt_tick 直接向环形 FIFO 推一拍确定性 PPG 正弦计数（RED
 * 50000±18000、IR 60000±22000，32 拍周期：n0=50000/60000、n8 峰
 * 68000/82000、n24 谷 32000/38000）——守护不推进虚拟时钟（模型的自动
 * 采样周期门不被触发），每拍先 tick 后 call，FIFO 恒有 1 个新鲜样本、
 * 零真实睡眠，一拍对应一个 virt_tick；空 FIFO 拍被守护跳过不发布。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=IR 计数做 α=0.2 一阶滤波（:f 浮点透传，禁止取整补码）
 *   → Monitor 引用消费。mon0 直连守护 hr0（raw IR/RED 计数 + count/SAT）；
 *   monf 引用 eir（滤波后 v0=IR，验证 Ema→Monitor 闭环）。
 *   v0=IR、v1=RED 均为无符号 18 位计数（0~262143，全字段 :f 原样透传，
 *   切不可走 sign=16 补码）。
 *
 * Daemon 额外列 opmode/rate/n 自动透传 build 参数（sensor_daemon 的
 * known 表只排除框架键，本驱动模式列名特意用 opmode 避开守护保留的
 * mode 键）：SpO2 双通道、100sps、每 call 至多取 2 样本（每拍 tick 只
 * 预推 1 个，want=min(2,1)=1 照常发布）。
 *
 * 配合 max30102_virt.mt：首行 200ms 预热等守护 setup（仅需容纳 build 的
 * RESET 真实睡眠 5ms），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（tick 预武装后 call 零睡眠）。
 * 用法：cat scripts/test/max30102_virt.mt | ./build/mybot --robot=robots/test/max30102_virt.sql
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
	opmode   String,
	rate     String,
	n        String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, opmode, rate, n)
  VALUES ('hr0', 'lib/sensor_daemon.lua', 'MAX30102', 'virt',
          '/dev/i2c-1', '0x57', '20', 'IR:f|RED:f', '16', 'spo2', '100', '2');

/* 一阶低通滤波器：只滤 v0=IR 通道计数（:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eir', '0.2', '$hr0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eir */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$hr0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eir');

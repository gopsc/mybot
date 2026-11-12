/*
 * BH1750FVI 无硬件端到端（proto=virt，命令式二线环境光传感器——单字节
 * opcode、无寄存器指针，测量值从总线【纯读】2 字节大端 count）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型——BH1750_VIRT，内嵌于
 * modules/BH1750.lua 尾部（2026-09-15 迁入，sensor_daemon 经「模型文件缺失
 * → 回退读驱动全局工厂」路径装载）。模型复刻协议事实（与 modules/BH1750.lua
 * 驱动同源 ROHM 手册）：0x00 PowerDown / 0x01 PowerOn、0x10/0x11/0x13
 * 连续 H/H2/L、0x20/0x21/0x23 单次 H/H2/L、0x40|x 与 0x60|x MTreg 命令对，
 * 单字节写解释进 state{power,mode,once} 并留 cmds 痕；读回 2 字节 count。
 * 守护跑【真实】BH1750.lua 的完整 build（PowerOn →（缺省 mtreg 免写）→
 * 连续 H 0x10 → milli_sleep(120×69/69)=120ms 真实一帧等待 = 2 笔单字节写
 * + 120ms 睡眠）与 call（连续模式零写、仅 i2c_read(fd,2) 纯读，
 * LUX = count×1.0×69/(1.2×69) = count/1.2 全在驱动）。
 *
 * 模型每拍 virt_tick 造确定性正弦照度（32 拍周期）：count 15002±3000
 * （12002~18002）→ LUX 10001.7~15001.7。其中少数拍 count 恰为 6 的倍数
 * （如 17496→14580）发布值成整数，且守护 interval=20ms 与 mt 的 50ms pump
 * 存在混叠（Monitor 快照采到哪一拍不固定），故 E2E 的 :f 浮点断言锚 monf 行
 * Ema 的 α 混合输出 out（恒带小数），不锚 raw 某一拍。virt_tick 只改测量值、
 * 不产生命令写，故 build 前预武装与每拍驱动都不干扰在位判定与 cmds 留痕。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=LUX 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 cl0（raw 照度 + count）；
 *   monf 引用 eavg（滤波后照度 + level，验证 Ema→Monitor 闭环）。
 *
 * 芯片地址 0x23（ADDR=Low），无额外 build 参数（mode 缺省 H、once 缺省
 * 连续、mtreg 缺省 69）。
 *
 * 配合 bh1750_virt.mt：首行 200ms 预热等守护 setup（build 真实睡眠 120ms，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护
 * interval=20ms（连续模式 call 零睡眠，一拍对应一个 virt_tick）。
 * 用法：cat scripts/test/bh1750_virt.mt | ./build/mybot --robot=robots/test/bh1750_virt.sql
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
  VALUES ('cl0', 'lib/sensor_daemon.lua', 'BH1750', 'virt',
          '/dev/i2c-1', '0x23', '20', 'LUX:f', '16');

/* 一阶低通滤波器：只滤 v0=LUX（:f 浮点透传，禁止取整补码） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$cl0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$cl0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

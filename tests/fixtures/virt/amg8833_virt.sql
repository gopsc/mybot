/*
 * AMG8833 无硬件端到端（proto=virt，首个「8 位字节指针 + 128 字节像素
 * 块连续 burst 读 + 帧周期门」I2C 器件）：sensor_daemon 不打开真机 I2C，
 * 而是挂内存仿真模型 AMG8833_VIRT（内嵌于 modules/AMG8833.lua 尾部，
 * 2026-09-15 迁入，守护经回退路径装载）。守护跑的是【真实】
 * AMG8833.lua 完整 build（PCTL=normal→RST=0x3F 初始复位后真实
 * milli_sleep 5ms→关中断→FPSC 10Hz→再真实睡眠 120ms 等首帧）与 call
 * （读 0x0E 热敏 2B + 从 0x80 起 8 次 16B 块读 64 像素，12 位补码小端
 * 0.25°C/LSB 解码，聚合 MAXT/MINT/AVGT/热点行列/THERM；64 像素原始数据
 * 不过桥，只发布聚合标量）。
 *
 * 模型每拍 virt_tick 直接把一拍确定性移动热点热图装入像素寄存器（25°C
 * 背景 + 绕中心旋转热点，32 拍周期：n0 热点 [3][6] 约 45°C、n8 旋转到
 * 第 6 行，热敏电阻 30±2°C 正弦）——守护不推进虚拟时钟（模型的 10Hz
 * 帧周期门不被触发），build 前的 virt_tick(0) 即预武装，build 睡醒 call
 * 恒有数据、零额外等待；一拍对应一个 virt_tick，MAXT/AVGT/热点行列随
 * 拍变化（守护 count 通用断言有 ≥2 个不同值）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v1=AVGT 做 α=0.2 一阶滤波（:f 浮点透传）
 *   → Monitor 引用消费。mon0 直连守护 cam0（raw MAXT/AVGT/MAXR/MAXC/
 *   THERM）；monf 引用 eavg（滤波后 AVGT，验证 Ema→Monitor 闭环）。
 *   五个字段均为温度 °C/行列编号（全字段 :f 原样透传，行列整数不走过
 *   sign=16 补码——sign 列仅占位）。
 *
 * 配合 amg8833_virt.mt：首行 200ms 预热等守护 setup（容纳 build 的真实
 * 睡眠 5+120=125ms），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（tick 预武装后 call 零睡眠）。
 * 用法：cat scripts/test/amg8833_virt.mt | ./build/mybot --robot=robots/test/amg8833_virt.sql
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
  VALUES ('cam0', 'lib/sensor_daemon.lua', 'AMG8833', 'virt',
          '/dev/i2c-1', '0x69', '20',
          'MAXT:f|AVGT:f|MAXR:f|MAXC:f|THERM:f', '16');

/* 一阶低通滤波器：只滤 v1=AVGT 平均温度通道（:f 浮点透传） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('eavg', '0.2', '$cam0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 eavg */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$cam0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$eavg');

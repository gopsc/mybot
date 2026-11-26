/*
 * MAX17048 无硬件端到端（proto=virt，偶地址稀疏字地图 I2C 电量计）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * MAX17048_VIRT（内嵌于 modules/MAX17048.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻协议——寄存器指针是字节
 * 地址且全在不连续偶地址：VCELL 0x02（16 位直读【无 17043 的 <<4】，
 * LSB 78.125µV，驱动 raw×78.125µV 全软件换算，满码 5.1199V）、
 * SOC 0x04（u16 定点 1/256%，raw/256 = 百分比，芯片可报告 >100%）、
 * CRATE 0x16（s16 有符号 ×0.208%/hr，充正放负，本用例不透传）、
 * MODE 0x06（bit14 QuickStart 自清不落盘、bit13 EnSleep 照存、bit12
 * HibStat 只读写忽略）、VERSION 0x08（POR 0x0012，build 甄别家族：
 * 0x001E/F 的 17043/44 拒收并提示换驱动）、CONFIG 0x0C（POR 0x971C，
 * 全字照存）、VALRT 0x14（地址 0x14=MIN 高字节、0x15=MAX 低字节，
 * 20mV/LSB）、STATUS 0x1A（高字节低 6 位告警，POR RI=0x0100）、
 * 只写命令口 CMD 0xFE（恰写 0x5400 全片复位，字节序与 17043 相反）。
 * 写恒 {ptr,hi,lo}、读恒「写 ptr + 读 2 字节」返回该字 hi/lo，跨字
 * 按 +2 偶地址连续，相邻字绝不串读。驱动【纯只读】：守护跑真实
 * MAX17048.lua build（set_addr + 写 0x08 指针 + 读 2B VERSION + 写
 * 0x1A 指针 + 读 2B STATUS 横幅共 5 事务、零睡眠、不写任何寄存器；
 * 横幅读失败不致命）与 call（set + 读 VCELL/SOC/CRATE/STATUS 四寄存器
 * 共 9 事务、零睡眠）。
 *
 * 模型每拍 virt_tick 为一节典型锂电造确定性正弦（32 拍周期）：
 * VCELL 3.85±0.25V（3.60~4.10V 常用区间）、SOC 80±8%（72~88%）同相
 *（n0=3.85V/80%、n8 峰 4.10/88、n24 谷 3.60/72），CRATE 余弦
 * ±9.984%/hr（n0=+9.984、n16=-9.984、n8/n24≈0），build 前预武装
 * virt_tick(0)——芯片转换自由运行、结果寄存器恒有值，无转换门；
 * 驱动 build/call 均零睡眠。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=VCELL 做 α=0.2 一阶滤波（:f 浮点透传，禁止取整）
 *   → Monitor 引用消费。mon0 直连守护 fg0（raw 两字段 + count）；
 *   monf 引用 ev（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *   v1=SOC 浮点不滤波。
 *
 * 芯片地址固定 0x36（无地址引脚），无额外 build 参数。
 *
 * 配合 max17048_virt.mt：200ms 预热等守护 setup（build 零睡眠，余量
 * 充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。守护
 * interval=20ms（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/max17048_virt.mt | ./build/mybot --robot=robots/test/max17048_virt.sql
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
  VALUES ('fg0', 'lib/sensor_daemon.lua', 'MAX17048', 'virt',
          '/dev/i2c-1', '0x36', '20', 'VCELL:f|SOC:f', '16');

/* 一阶低通滤波器：只滤 v0=VCELL（:f 浮点透传，禁止取整）；
 * v1=SOC 直连守护观察即可。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$fg0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$fg0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

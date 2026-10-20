/*
 * APDS-9900 无硬件端到端（proto=virt，环境光 ALS + 近距 PROX 传感器）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * APDS9900_VIRT（内嵌于 modules/APDS9900.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻 TAOS TSL2771 命令字节协议——
 * 每笔访问首字节 bit7 COMMAND 必置、bit6:5 TYPE（00 重复字节/01 自动
 * 增量/10 重复字/11 自动增量）、bit4:0 寄存器地址；驱动只用 0x80 字节
 * 访问与 0xA0 字对自增：ENABLE 0x00（bit7:6 保留写抹 0，驱动写 0x00
 * 断电、0x07=PON|AEN|PEN 启动）、ATIME 0x01（256-reg 个 2.71875ms
 * 周期，缺省 50ms → 18 周期 → 238）、PTIME 0x02/WTIME 0x03 写 0xFF、
 * CONFIG 0x0D/PERS 0x0C 写 0、PPCOUNT 0x0E 写 8、CONTROL 0x0F 写 0x20
 * （100mA|IR 光电二极管|PGAIN×1|AGAIN×1）；ID 0x12 批次 ROM 接受
 * 0x00/0x04/0x29（模型默认 0x29，只读写丢弃）；CDATA 0x14/15（CH0
 * 全谱）、IRDATA 0x16/17（CH1 红外）、PDATA 0x18/19（近距）三个
 * 【小端】字对（偶址 LSB）只读；阈值 0x04~0x09/STATUS 0x13 等驱动
 * 不碰，模型不建模整笔 NACK。固定地址 0x39。
 * 守护跑【真实】APDS9900.lua build（set + {80,00} 断电写 + ID 指针
 * 读 {92}+r1 + 7 笔配置写 + {80,07} 启动 = set+10w+1r 共 12 事务、
 * 全程零睡眠）与 call（set + 三笔 TYPE=01 字对指针读 {B4}+r2、
 * {B6}+r2、{B8}+r2 = 7 事务、零睡眠）。
 *
 * 模型每拍 virt_tick 造同相确定性正弦计数（32 拍周期）：
 * CH0 10000±4000（6000~14000）、CH1=CH0/4（恒定 IR 占比，两线补偿
 * 后 lux 恒正）、PROX 300±200（100~500）；build 前守护自动
 * virt_tick(0) 预武装。连续转换无就绪握手，缺省 build（18 周期
 * 48.94ms/×1/df52/ga0.48）下驱动 lux≈0.51×(CH0-2.23·CH1)：
 * n0≈2257、峰≈3160、谷≈1354 lux。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=LUX 物理照度做 α=0.2 一阶滤波（:f 浮点透传）
 *   → Monitor 引用消费。mon0 直连守护 als0（raw LUX/CH0/CH1/PROX
 *   + count）；monf 引用 ev（滤波后 LUX + level，验证 Ema→Monitor
 *   闭环）。v1~v3 = CH0/CH1/PROX 无符号 16 位计数，全字段 :f 原样
 *   透传（切不可走 sign=16 补码——计数恒正但补码路径会取整丢小数）。
 *
 * 芯片固定地址 0x39，无额外 build 参数（atime/again/pdrive/pgain/
 * ppcount/df/ga 全缺省：50ms/×1/100mA/×1/8 脉冲/52/0.48）。
 *
 * 配合 apds9900_virt.mt：200ms 预热等守护 setup（build/call 零睡眠，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=20ms（call 零睡眠，远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/apds9900_virt.mt | ./build/mybot --robot=robots/test/apds9900_virt.sql
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
  VALUES ('als0', 'lib/sensor_daemon.lua', 'APDS9900', 'virt',
          '/dev/i2c-1', '0x39', '20', 'LUX:f|CH0:f|CH1:f|PROX:f', '16');

/* 一阶低通滤波器：只滤 v0=LUX 物理照度（:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$als0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name  String,
	src   String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$als0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

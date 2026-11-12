/*
 * AS3935 无硬件端到端（proto=virt，ams Franklin 事件型雷电传感器）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * AS3935_VIRT（内嵌于 modules/AS3935.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻 8 位字节指针协议——0x00
 * AFE_GAIN（POR 0x24=室内，复位后在位甄别依据）、0x01 NF_LEV/WDTH、
 * 0x02 MIN_NUM_LIG/SREJ、0x03 INT（低 4 位事件码【读后清】、bit5
 * MASK_DIST 可写配置）、0x07 S_DIST（1=头顶/2~62=km/0x3F 超量程/0
 * 未知，只读）、0x04/05/06 能量 21 位小端（MMSB 仅低 5 位，只读）、
 * 0x08 TUN_CAP/显示位；{0x3C,0x96}=软复位、{0x3D,0x96}=RCO 校准
 * （0x3A/0x3B bit6=NOK）。
 * 守护跑【真实】AS3935.lua build（set + 复位 + 在位甄别 + 7 笔读-改-写
 * + RCO 校准与显示位两笔 RMW + SRCO/TRCO 状态读 = set+23w+12r 共
 * 36 事务；真实 milli_sleep 2+2=4ms）与 call（set + 睡 2ms + 读 INT
 * = 3 事务；闪电再读距离与三字节能量共 11 事务）。
 *
 * 事件型器件无连续测量：模型 virt_tick 按【8 拍确定性脚本】逐拍定义
 * 当前锁存事件——拍 0/1/3/5=none、拍 2/6=lightning（距离 10~35km
 * 按 16 拍正弦、能量 1e5~9e5 按 8 拍正弦）、拍 4=noise、拍
 * 7=disturber；守护每拍 tick 后 call 取事件，读 INT 即清、下拍再装。
 * build 前自动 virt_tick(0) 预武装（拍 0=none，build 的 0x03 RMW
 * 读不会吃到陈旧事件）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v1=DIST_KM（整数公里，非闪电为 -1）做 α=0.2 一阶滤波
 *     （整数混合后 out 必为带小数浮点，run_all 以此锚定 EMA 推进）
 *   → Monitor 引用消费。mon0 直连守护 as0（raw CODE/DIST_KM 两整数 +
 *   ENERGY:f 浮点 + count）；monf 引用 ev（滤波后 DIST_KM + level，
 *   验证 Ema→Monitor 闭环）。CODE/DIST_KM 为整数（无 :f，值在 16 位
 *   内，sign=16 不改动）；ENERGY 是 21 位能量（可达 2^21），必须
 *   逐字段 :f 原样透传——无 :f 会被 sign=16 截断到低 16 位。
 *
 * 芯片地址 0x03（GY/SparkFun 模块常见；0x03 在 I2C 保留区，
 * i2cdetect 默认扫不到），无额外 build 参数（室内增益/缺省阈值）。
 *
 * 配合 as3935_virt.mt：200ms 预热等守护 setup（build 睡 4ms +
 * 预武装 none，余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个
 * Monitor。守护 interval=20ms（call 前真实睡 2ms 等锁存稳定，
 * 远快于 50ms 拍点，count 持续增长、8 拍事件脚本循环约两轮，
 * 四种 CODE 都会出现）。
 * 用法：cat scripts/test/as3935_virt.mt | ./build/mybot --robot=robots/test/as3935_virt.sql
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
  VALUES ('as0', 'lib/sensor_daemon.lua', 'AS3935', 'virt',
          '/dev/i2c-1', '0x03', '20', 'CODE|DIST_KM|ENERGY:f', '16');

/* 一阶低通滤波器：只滤 v1=DIST_KM（整数公里/非闪电 -1，α 混合后 out
 * 为浮点）；v0=CODE 整数/v2=ENERGY:f 21 位浮点直连守护观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$as0', 'v1');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$as0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

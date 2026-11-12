/*
 * BME688 无硬件端到端（proto=virt，Bosch 四合一温/压/湿/气体电阻
 * 环境传感器，兼容 BME680）：sensor_daemon 不打开真机 I2C，而是挂
 * 内存仿真模型 BME688_VIRT（内嵌于 modules/BME688.lua 尾部，2026-09-15
 * 迁入，守护经回退路径装载）。模型复刻 8 位字节
 * 指针 + 稀疏寄存器图协议——0xE0/0xB6 软复位、0xD0 CHIP_ID=0x61、
 * 0xF0 变体（0x01=BME688 选高量程气体路/0x00=BME680 低量程）、
 * COEFF1 0x8A×23 / COEFF2 0xE1×14 / COEFF3 0x00×5 共 42 字节
 * 出厂 NVM（H1/H2 半字节打包，range_sw_err 有符号高 4 位）、
 * 0x72/0x74/0x75 OSR+IIR、0x5A RES_HEAT0/0x64 GAS_WAIT0、
 * 0x70 heat_off/0x71 RUN_GAS+NBCONV；17 字节数据场 0x1D 起
 * （20 位 P/T + 16 位 H + 双 10 位气体路，NEW_DATA 读出即清），
 * forced 转换状态机门限 = TPH 时长 + gas_wait（默认 build 档 160ms）。
 * 守护跑【真实】BME688.lua build（set + 软复位 + 真实 milli_sleep
 * 10ms + 双 ID 读 + 三块校准 6 字节分块 burst + 七笔配置写）与
 * call（set + 读/触发 CTRL_MEAS + 5ms 步进轮询 0x1D + 17 字节场
 * 6/6/5 三块读 + Bosch float 补偿）。
 *
 * 有转换门器件：模型 virt_tick 装码即【预武装】——build 前守护
 * 自动 virt_tick(0)，daemon_tick 每拍先 virt_tick(n) 再 call，
 * 触发即 NEW_DATA=0x80，真实驱动零 milli_sleep、首轮询即出数。
 * 32 拍确定性离线码钉（独立 Bosch float 公式反解固化，模型不含
 * 补偿公式）：T 22~28°C / P 100725~101925Pa / H 35~65%RH /
 * GAS 6~18kΩ，两路气体同码、GASM_VALID+HEAT_STAB 恒 1。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=T（浮点 °C）做 α=0.2 一阶滤波（正弦值混合后 out
 *     必为带小数浮点，run_all 以此锚定 EMA 推进）
 *   → Monitor 引用消费。mon0 直连守护 as0（raw：T/P/H/GAS 四个
 *   :f 浮点 + GAS_OK 整数 + count）；monf 引用 ev（滤波后温度，
 *   验证 Ema→Monitor 闭环）。四物理量均 Bosch 公式换算的非整数
 *   浮点，必须逐字段 :f 原样透传；GAS_OK 为 0/1 整数（无 :f，
 *   sign=16 不改动）。
 *
 * 芯片固定地址 0x76；无额外 build 参数 = 默认加热器档 320C/150ms
 * /amb25（预武装零睡眠，门限不影响守护节拍）。
 *
 * 配合 bme688_virt.mt：200ms 预热等守护 setup（build 真实睡 10ms，
 * 余量充裕），随后 16 拍 ×50ms pump 滤波并消费两个 Monitor。
 * 守护 interval=50ms（预武装一拍即就绪），32 拍码钉循环多轮。
 * 用法：cat scripts/test/bme688_virt.mt | ./build/mybot --robot=robots/test/bme688_virt.sql
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
  VALUES ('as0', 'lib/sensor_daemon.lua', 'BME688', 'virt',
          '/dev/i2c-1', '0x76', '50', 'T:f|P:f|H:f|GAS:f|GAS_OK', '16');

/* 一阶低通滤波器：只滤 v0=T（浮点 °C，α 混合后 out 为浮点）；
 * v1=P/v2=H/v3=GAS 三浮点与 v4=GAS_OK 整数直连守护观察。 */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$as0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（温度） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$as0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

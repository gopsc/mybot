/*
 * MLX90393 无硬件端到端（proto=virt，Melexis Triaxis 三轴磁力计）：
 * sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 * MLX90393_VIRT（内嵌于 modules/MLX90393.lua 尾部，2026-09-15 迁入，守护经
 * 回退路径装载）。模型复刻命令式 + status-first 应答
 * 协议（datasheet 3901090393 Rev012 §15）——没有寄存器指针事务：每条
 * 命令先一笔写、再 Sr 纯读，应答首字节永远是 status（bit7 BURST/
 * bit6 WOC/bit5 SM_MODE 单次完成/bit4 ERROR/bit2 RS 复位自清/bit1:0 D
 * 附加数据=2D+2）。命令：0x00 NOP（驱动轮询用）、0x3n SM 单次、
 * 0x4n RM 读测量（zyxt：bit0=T/bit1=X/bit2=Y/bit3=Z）、0x50 RR
 * （[0x50,A<<2] -> [status,Dhi,Dlo] 3B）、0x60 WR（【4B】
 * [0x60,Dhi,Dlo,A<<2] -> status 1B）、0xD0 HR、0xF0 RT。
 * 易失内存 reg0x00 POR=0x007C（GAIN_SEL=7/HALLCONF=C），build 读-改-
 * 写只改 GAIN_SEL（缺省 0 -> reg0=0x000C，保留 HALLCONF=C）+ 回读校验。
 * RM XYZT 全帧 9B [status,Tmsb,Tlsb,Xmsb,Xlsb,Ymsb,Ylsb,Zmsb,Zlsb]，
 * 片内转换/组帧顺序 TXYZ。固定地址 0x0C。
 * 守护跑【真实】MLX90393.lua build（set + RT{F0} + HR{D0} + RR reg0
 * r3 + WR 4B + RR 回读 r3 + SM{3F} + NOP 轮询 {00}r1 + RM{4F}r9 试测
 * = set+9w+5r 共 15 事务；真实 milli_sleep 5+2+1=8ms）与 call
 * （set + {3F} + {00}r1 + {4F}r9 = 8 事务，预武装下 1ms 轮询即就绪）。
 *
 * 模型每拍 virt_tick 造确定性正弦地磁场（32 拍周期，单位 µT/°C）：
 * X=30·sin(φ)（±30，含负值）、Y=25·sin(φ+π/3)、Z=40+10·sin(φ+π/2)
 * （30~50）、T=25+5·sin(φ+π/4)（约 21.5~28.5°C）；set_sample 按当前
 * GAIN_SEL 反算原始码（gain0：XY 0.751 / Z 1.210 µT/LSB），驱动再正算
 * 回物理量，温度 u16 按 45.2LSB/°C、25°C=46244 还原。build 前守护
 * 自动 virt_tick(0) 预武装：SM 零转换门，首拍 NOP 即见 SM_MODE，
 * 守护线程不注入 milli_sleep 桩（真实 sleep 仅 1ms/拍）。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽
 *   → Ema 对 v0=X 轴磁场（µT，:f 浮点透传）做 α=0.2 一阶滤波
 *   → Monitor 引用消费。mon0 直连守护 mlx0（raw X/Y/Z/T + XR/YR/ZR
 *   有符号计数/TR 无符号/status + count）；monf 引用 ev（滤波后 X +
 *   level，验证 Ema→Monitor 闭环）。四字段全 :f 浮点原样透传
 *   （X/Y/Z µT、T °C；sign=16 列仅占位，绝不走补码取整）。
 *
 * 芯片固定地址 0x0C，无额外 build 参数（gain/timeout 全缺省：
 * GAIN_SEL=0、50ms）。
 *
 * 配合 mlx90393_virt.mt：200ms 预热等守护 setup，随后 16 拍 ×50ms
 * pump 滤波并消费两个 Monitor。守护 interval=20ms（call 仅 1ms 睡眠，
 * 远快于 50ms 拍点，count 持续增长）。
 * 用法：cat scripts/test/mlx90393_virt.mt | ./build/mybot --robot=robots/test/mlx90393_virt.sql
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
  VALUES ('mlx0', 'lib/sensor_daemon.lua', 'MLX90393', 'virt',
          '/dev/i2c-1', '0x0C', '20', 'X:f|Y:f|Z:f|T:f', '16');

/* 一阶低通滤波器：只滤 v0=X 轴磁场（µT，:f 浮点透传，禁止取整） */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('ev', '0.2', '$mlx0', 'v0');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 ev（决策 level） */
CREATE TABLE Monitor (
	name  String,
	src   String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$mlx0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$ev');

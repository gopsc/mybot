/*
 * BME280 无硬件端到端测试（proto=virt）：
 *   sensor_daemon 不打开真机 I2C，而是挂内存仿真模型
 *   modules/lib/virtbus/bme280.lua，模型每拍 virt_tick 在原始 ADC 码空间造
 *   确定性合成波形（datasheet 示例工况 T≈25.08°C / P≈100653Pa / H≈45.3%RH
 *   为中心，三通道互差 120° 正弦）。守护启动打印 VIRTUAL HARDWARE 警告横幅。
 *
 * 模型不实现补偿公式：守护跑的是【真实】BME280.lua 的附录 8.3 温压湿补偿，
 * 模型只提供 NVM 校准字节与数据区位场。
 *
 * 链路：
 *   守护线程（独立 lua_State）→ 共享槽（通道 double + mutex）
 *   → 三个 Ema 滤波变量（α=0.2，field=v0..v2，全 :f 浮点透传）
 *   → Monitor 引用消费。mon0 直连守护 env0（raw 三字段 + count）；
 *   monf 引用 et（滤波后 v0 + level，验证 Ema→Monitor 闭环）。
 *
 * 配合 bme280_virt.mt：200ms 预热等守护 setup，随后 16 拍 ×50ms pump
 * 三路滤波并消费两个 Monitor。守护 interval=20ms（call 含真实 5ms 等待）。
 * 注：三字段均带 :f 浮点透传后缀，sign=16 对它们不生效（SQL 矩阵解析不接受空串）。
 * 用法：cat scripts/test/bme280_virt.mt | bash _run.sh --robot=robots/test/bme280_virt.sql
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
  VALUES ('env0', 'lib/sensor_daemon.lua', 'BME280', 'virt',
          '/dev/i2c-1', '0x76', '20', 'T:f|P:f|H:f', '16');

/* 三个一阶低通滤波器：src 以 $ 引用守护，v0=T(°C) v1=P(Pa) v2=H(%RH) */
CREATE TABLE Ema (
	name  String,
	alpha String,
	src   String,
	field String
);
INSERT INTO Ema (name, alpha, src, field) VALUES ('et', '0.2', '$env0', 'v0');
INSERT INTO Ema (name, alpha, src, field) VALUES ('ep', '-',   '-',      'v1');
INSERT INTO Ema (name, alpha, src, field) VALUES ('eh', '-',   '-',      'v2');

/* Monitor：mon0 直连守护（raw 快照），monf 消费滤波后的 et（决策 level） */
CREATE TABLE Monitor (
	name String,
	src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$env0');
INSERT INTO Monitor (name, src) VALUES ('monf', '$et');

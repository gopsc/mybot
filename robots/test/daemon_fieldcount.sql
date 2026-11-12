/*
 * 守护配置 schema 加载期校验（审计 2026-09-20 · 中）：fields 声明的字段数
 * 超过共享槽容量（values[64]，TD-3: 32→64）必须在**结构脚本加载期**报错。
 *
 * 缺陷形态：槽宽是编译期常量 SLOT_MAXVALS，Lua 侧 P.publish 超出即静默
 * 钳制（pthread.lua）、C++ 侧 readSample 也按容量截断，而 checkDaemonFields
 * 此前不校验数量——于是超容量字段的 @Daemon 能通过全部加载期校验、正常启动、
 * count 照常自增，多余字段却永远拿不到值，事后只表现为下游「某字段缺失」
 * 这类间接症状（Monitor 只会说 no daemon value (v0 missing)）。
 *
 * 期望：退出码 1，信息含 "exceeds the shared-slot capacity"。
 * 配合 daemon_schema.mt（占位，结构期即失败）。
 *
 * TD-3 更新（2026-09-22）：SLOT_MAXVALS 从 32 增至 64，测试改为 65 个字段。
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
	fields   String
);
/* 65 个字段 = SLOT_MAXVALS(64) + 1：恰好越过边界（TD-3: 33→65） */
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
  VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1', '0x68', '10',
          'F01|F02|F03|F04|F05|F06|F07|F08|F09|F10|F11|F12|F13|F14|F15|F16|F17|F18|F19|F20|F21|F22|F23|F24|F25|F26|F27|F28|F29|F30|F31|F32|F33|F34|F35|F36|F37|F38|F39|F40|F41|F42|F43|F44|F45|F46|F47|F48|F49|F50|F51|F52|F53|F54|F55|F56|F57|F58|F59|F60|F61|F62|F63|F64|F65');

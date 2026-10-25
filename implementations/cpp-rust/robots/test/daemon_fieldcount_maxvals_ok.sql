/*
 * maxvals 列（ABI v2）：65 个字段（> 缺省容量 64）+ maxvals=128 → 加载期
 * **放行**（对照 daemon_fieldcount.sql：同样的 65 字段不给 maxvals 即拒绝）。
 * chunk 用 daemon_probe（无驱动依赖、发布 4 值）；.mt 不引用该守护——本夹具
 * 钉的是加载期数量判据按行取 maxvals，不是采样行为。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	interval String,
	fields   String,
	maxvals  String
);
INSERT INTO Daemon (name, chunk, interval, fields, maxvals)
  VALUES ('big0', 'lib/daemon_probe.lua', '10',
          'F01|F02|F03|F04|F05|F06|F07|F08|F09|F10|F11|F12|F13|F14|F15|F16|F17|F18|F19|F20|F21|F22|F23|F24|F25|F26|F27|F28|F29|F30|F31|F32|F33|F34|F35|F36|F37|F38|F39|F40|F41|F42|F43|F44|F45|F46|F47|F48|F49|F50|F51|F52|F53|F54|F55|F56|F57|F58|F59|F60|F61|F62|F63|F64|F65',
          '128');

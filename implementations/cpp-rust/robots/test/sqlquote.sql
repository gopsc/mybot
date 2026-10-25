/*
 * SQL 词法器引号内特殊字符回归（正值契约）：
 * 引号值内的 "--"、块注释起始符、";"、","、"("、")" 与空白都是字面数据
 * ——修复前词法器会把它们当注释/分隔符拆分 token，导致解析失败或数据被切碎。
 * 修复后本结构脚本应完整解析、正常建守护、退出 0。
 *
 * 两张表分工（审计 P4 之后）：词法路径与表名无关，但 @Daemon 的列值会被拼成
 * DAEMON_CONFIG（"k=v;k=v"）注入守护，其中的 ';' 会截断该值、甚至注入/覆盖
 * 守护理解的键，故 src/daemonvar.cpp 的 checkDaemonValueChars 一律拒绝。
 *   Daemon 表 → 承载 ","、"("、")"、空白、块注释起始符、"--" 这些字面值，
 *               并证明守护照常建起来（run_all.sh 断言 "joined, total publishes="）；
 *   dummy  表 → 承载带 ';' 的字面值，词法器契约覆盖不减。
 *
 * 用法：cat scripts/test/sqlquote.mt | ./build/mybot --robot=robots/test/sqlquote.sql
 * 期望退出码 0，输出含 "joined, total publishes="
 */
CREATE TABLE Daemon (
	name   String,
	chunk  String,
	extra  String,
	tag    String
);
INSERT INTO Daemon (name, chunk, extra, tag)
  VALUES ('d0', 'lib/daemon_probe.lua', 'tag,with (parens) and space', 'a/*b*/c d--e');

CREATE TABLE dummy (
	name String,
	pp1  String
);
INSERT INTO dummy (name, pp1)
  VALUES ('dm', 'semi ; inside /* blk */ and -- dash');
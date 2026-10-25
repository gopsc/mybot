/* test_robot.cpp —— 结构脚本装配（RobotStruct 的解析与派发前置校验）
 *
 * 主体只覆盖「不需要 Lua 运行时」的两段：
 *   构造函数 = readSQL（Lexer + Parser + MatrixObject 拼装）
 *   run()    = 动作矩阵读取 + @Alias 注册 + @Action 派发前的列名/设备名校验
 * 这两段的失败都发生在真机资源申请之前，报错必须精确到表名/列名/行号。
 *
 *
 * 2026-10-01 TU 拆分（行为保持）：运行期派发/HwRegistry 域 → test_robot_dispatch.cpp、
 * 生命周期与硬件独占域 → test_robot_lifecycle.cpp（需要 Lua 运行时的「析构兜底
 * 断电」用例随之迁出，证据仍由 test/cpp/LifetimeProbe.lua 落痕）、热 SQL 四域 →
 * test_robot_hotsql_plan.cpp 与 test_robot_hot{insert,delete,update}.cpp；
 * 跨域共用夹具在 robot_fixtures.hpp。
 */

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "daemonvar.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "robot_fixtures.hpp"

namespace fs = std::filesystem;
using fx::TempDir;

using rfx::cell;
using rfx::kBasicSql;
using rfx::loadMatrices;
using rfx::runTexts;
using rfx::sqlError;

namespace {

const mt::MatrixObject* matrixNamed(const std::deque<mt::MatrixObject>& ms, const std::string& n) {
	for (const auto& m : ms) {
		if (m.getName() == n) { return &m; }
	}
	return nullptr;
}

} // namespace
/* ---------------- readSQL ---------------- */

TH_TEST(robot_struct_accepts_a_well_formed_structure_script) {
	/* 含块注释、行注释、制表符缩进、列名对齐空格的真实方言写法 */
	TH_CHECK(sqlError(kBasicSql).empty());
}

TH_TEST(robot_struct_accepts_empty_script) {
	TH_CHECK(sqlError("").empty());
	TH_CHECK(sqlError("-- 只有注释\n").empty());
}

TH_TEST(robot_struct_reports_undefined_insert_target) {
	const std::string msg = sqlError(
		"CREATE TABLE Relay ( name String );\n"
		"INSERT INTO Relays ( name ) VALUES ( 'r0' );\n");
	TH_CHECK(msg.find("Relays") != std::string::npos);
	TH_CHECK(msg.find("table is not defined") != std::string::npos);
}

TH_TEST(robot_struct_reports_insert_before_create) {
	const std::string msg = sqlError("INSERT INTO Relay ( name ) VALUES ( 'r0' );\n");
	TH_CHECK(msg.find("No table created yet") != std::string::npos);
}

TH_TEST(robot_struct_propagates_syntax_errors) {
	const std::string missingType = sqlError("CREATE TABLE Relay ( name );\n");
	TH_CHECK(missingType.find("Token )") != std::string::npos);

	const std::string swapped = sqlError("CREATE RELAY TABLE T ( name String );\n");
	TH_CHECK(swapped.find("Token name 'RELAY'") != std::string::npos);

	const std::string truncated = sqlError("CREATE TABLE Relay ( name String\n");
	TH_CHECK(truncated.find("unexpected end of script") != std::string::npos);

	const std::string stray = sqlError("; CREATE TABLE Relay ( name String );\n");
	TH_CHECK(stray.find("Token ;") != std::string::npos);
}

/* ---------------- C3：INSERT 的落位必须按列名（2026-09-20 审计） ---------------- */


/* INSERT 的列名清单只决定「哪个值属于哪一列」；值必须落到建表声明序上。
 * 旧实现把值逐位 appendRow（列名仅参与 Number 校验），于是列序不一致时
 * 值被静默换列——声明 Number 的列拿到字符串，而 Number 校验看的是另一组配对。 */
TH_TEST(insert_values_land_in_the_declared_column_order) {
	auto ms = loadMatrices(
		"CREATE TABLE Timer (\n"
		"	name  String,\n"
		"	delay Number\n"
		");\n"
		"INSERT INTO Timer (delay, name) VALUES (50, 'timer-0');\n");
	const mt::MatrixObject* t = matrixNamed(ms, "Timer");
	TH_CHECK(t != nullptr);
	if (t == nullptr) { return; }
	TH_CHECK(t->rows() == 2);
	TH_CHECK(cell(*t, 1, 0) == "timer-0");	/* name 列：建表序第 0 列 */
	TH_CHECK(cell(*t, 1, 1) == "50");		/* delay 列：建表序第 1 列 */
}

/* 顺序一致时行为逐字不变（绝大多数脚本走这条路径） */
TH_TEST(insert_values_unchanged_when_column_order_matches) {
	auto ms = loadMatrices(
		"CREATE TABLE Timer (\n"
		"	name  String,\n"
		"	delay Number\n"
		");\n"
		"INSERT INTO Timer (name, delay) VALUES ('timer-0', 50);\n");
	const mt::MatrixObject* t = matrixNamed(ms, "Timer");
	TH_CHECK(t != nullptr);
	if (t == nullptr) { return; }
	TH_CHECK(cell(*t, 1, 0) == "timer-0");
	TH_CHECK(cell(*t, 1, 1) == "50");
}

/* P0 回归守门（2026-09-23 审计）：readSQL 定位表下标不得用 `root - &out[0]`
 * 指针差——容器是 std::deque，元素不保证连续（libstdc++ 每块 512/sizeof = 5 个
 * MatrixObject），第 6 张表起跨块指针差是 UB，rowOrigin[垃圾下标] 越界读写。
 * 实测 spider1.sql（6 张表）在启动解析期 100% 段错误；全部仓内夹具 ≤5 张表，
 * 恰好从未越过块边界——这正是该缺陷躲过 662 个单测的原因。
 * 本用例用 7 张表（跨两个块边界）逐表 INSERT，断言行数与内容逐一正确；
 * 内容断言在「侥幸不崩但下标静默漂移」的堆布局下同样会红。 */
TH_TEST(robot_readsql_locates_tables_across_deque_chunk_boundary) {
	std::string sql;
	for (int i = 0; i < 7; ++i) {
		sql += "CREATE TABLE T" + std::to_string(i) + " (name String, v String);\n";
	}
	for (int i = 0; i < 7; ++i) {
		/* INSERT 故意全部放在 CREATE 之后：目标表下标 5、6 落在第二块里，
		 * appendRowTracked 取 rowOrigin 下标正是在这两条上踩雷 */
		sql += "INSERT INTO T" + std::to_string(i) + " (name, v) VALUES ('n"
			+ std::to_string(i) + "', 'x');\n";
	}
	const std::deque<mt::MatrixObject> ms = loadMatrices(sql);
	TH_CHECK(ms.size() == 7);
	for (int i = 0; i < 7; ++i) {
		const mt::MatrixObject* m = matrixNamed(ms, "T" + std::to_string(i));
		TH_CHECK(m != nullptr);
		if (m == nullptr) { continue; }
		TH_CHECK(m->rows() == 2);	/* 列头 + 恰好 1 条数据行 */
		TH_CHECK(cell(*m, 1, 0) == "n" + std::to_string(i));
		TH_CHECK(cell(*m, 1, 1) == "x");
	}
}

/* 多行 INSERT 逐行按列名落位，互不影响 */
TH_TEST(insert_multiple_rows_each_land_by_column_name) {
	auto ms = loadMatrices(
		"CREATE TABLE T (\n"
		"	name String,\n"
		"	v    Number\n"
		");\n"
		"INSERT INTO T (v, name) VALUES (1, 'a');\n"
		"INSERT INTO T (name, v) VALUES ('b', 2);\n");
	const mt::MatrixObject* t = matrixNamed(ms, "T");
	TH_CHECK(t != nullptr);
	if (t == nullptr) { return; }
	TH_CHECK(t->rows() == 3);
	TH_CHECK(cell(*t, 1, 0) == "a" && cell(*t, 1, 1) == "1");
	TH_CHECK(cell(*t, 2, 0) == "b" && cell(*t, 2, 1) == "2");
}

/* 未知列名此前被静默顺序落位（并挤掉后续列），现显式报错 */
TH_TEST(insert_rejects_an_unknown_column_name) {
	const std::string msg = sqlError(
		"CREATE TABLE T ( name String );\n"
		"INSERT INTO T (nome) VALUES ('x');\n");
	TH_CHECK(msg.find("no such column") != std::string::npos);
	TH_CHECK(msg.find("nome") != std::string::npos);
}

/* 漏列此前会产生比表头短的行（错位），现显式报错 */
TH_TEST(insert_rejects_a_missing_column) {
	const std::string msg = sqlError(
		"CREATE TABLE T ( name String, v Number );\n"
		"INSERT INTO T (name) VALUES ('x');\n");
	TH_CHECK(msg.find("missing value for column") != std::string::npos);
	TH_CHECK(msg.find("v") != std::string::npos);
}

/* 同列名写两次此前是「后者静默覆盖」的位置关系，现显式报错 */
TH_TEST(insert_rejects_a_duplicated_column) {
	const std::string msg = sqlError(
		"CREATE TABLE T ( name String, v Number );\n"
		"INSERT INTO T (name, name) VALUES ('x', 'y');\n");
	TH_CHECK(msg.find("listed twice") != std::string::npos);
}

/* ---------------- run(): 动作矩阵与派发前置校验 ---------------- */

TH_TEST(run_requires_an_action_matrix) {
	const std::string msg = runTexts(kBasicSql, "@Alias\nname alias;\nx duty;\n@\n");
	TH_CHECK(msg.find("No @Action matrix found") != std::string::npos);
}

TH_TEST(run_reports_undeclared_device_in_action) {
	/* 列头写了没声明的设备名：必须点名是哪个设备、第几行 */
	const std::string msg = runTexts(kBasicSql, "@Action\nrelay9.deg;\n  200;\n@\n");
	TH_CHECK(msg.find("'relay9'") != std::string::npos);
	TH_CHECK(msg.find("not defined in your hardware declaration section") != std::string::npos);
	TH_CHECK(msg.find("row 1") != std::string::npos);
}

TH_TEST(run_rejects_action_column_without_device_dot_param) {
	const std::string msg = runTexts(kBasicSql, "@Action\nrelay0;\n  200;\n@\n");
	TH_CHECK(msg.find("expected format: <device>.<param>") != std::string::npos);
	TH_CHECK(msg.find("Action column 'relay0'") != std::string::npos);

	const std::string msg2 = runTexts(kBasicSql, "@Action\nrelay0.a.b;\n  200;\n@\n");
	TH_CHECK(msg2.find("relay0.a.b") != std::string::npos);
}

TH_TEST(run_rejects_non_numeric_action_cell) {
	const std::string msg = runTexts(kBasicSql, "@Action\nrelay0.deg;\n  abc;\n@\n");
	TH_CHECK(msg.find("cannot parse matrix cell 'abc'") != std::string::npos);
}

/* C4（2026-09-20 审计）：单元格报错必须转义 + 截断用户可控原文。
 * 修复前原样回显——20 万字节单元格实测灌 200KB 进 stderr，且 ANSI 转义
 * 直写操作者终端（表达式报错早有同一条防线，这里漏了）。 */
TH_TEST(run_truncates_a_huge_non_numeric_action_cell) {
	const std::string msg =
		runTexts(kBasicSql, "@Action\nrelay0.deg;\n  " + std::string(200000, 'A') + ";\n@\n");
	TH_CHECK(!msg.empty());
	/* 报错整体必须远小于被回显的原文（截断生效） */
	TH_CHECK(msg.size() < 4096);
	TH_CHECK(msg.find("cannot parse matrix cell") != std::string::npos);
	TH_CHECK(msg.find("...") != std::string::npos);		/* 截断标记 */
}

/* ANSI/控制字节转成可见的 \xNN，不再直写终端 */
TH_TEST(run_escapes_control_bytes_in_a_rejected_action_cell) {
	const std::string msg =
		runTexts(kBasicSql, "@Action\nrelay0.deg;\n  \x1b[31mX\x1b[0m;\n@\n");
	TH_CHECK(msg.find("cannot parse matrix cell") != std::string::npos);
	TH_CHECK(msg.find("\\x1b") != std::string::npos);
	/* 原始 ESC 字节不得出现在报错里 */
	TH_CHECK(msg.find('\x1b') == std::string::npos);
}

TH_TEST(run_reports_ragged_action_row_with_line_number) {
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.a relay0.b;\n  200;\n@\n");
	TH_CHECK(msg.find("Does Not Sync") != std::string::npos);
	TH_CHECK(msg.find("we got line: 3") != std::string::npos);
}

TH_TEST(run_registers_inline_alias_before_dispatch) {
	/* @Alias 先于 @Action 生效；这里只验「别名注册阶段不报错」，
	 * 派发仍会因设备未声明而失败——错误必须来自派发而不是别名阶段。 */
	const std::string msg = runTexts(kBasicSql,
		"@Alias\nname alias;\nspeed duty;\n@\n"
		"@Action\nrelay0.speed;\n  200;\n@\n");
	TH_CHECK(msg.find("no 'name' column") == std::string::npos);
	TH_CHECK(msg.find("Duplicate alias name") == std::string::npos);
	TH_CHECK(msg.find("'relay0'") != std::string::npos);
}

TH_TEST(run_rejects_duplicate_alias_in_one_action_script) {
	const std::string msg = runTexts(kBasicSql,
		"@Alias\nname alias;\nspeed duty;\nspeed pos;\n@\n"
		"@Action\nrelay0.speed;\n  200;\n@\n");
	TH_CHECK(msg.find("Duplicate alias name 'speed'") != std::string::npos);
}

TH_TEST(run_rejects_alias_matrix_without_columns) {
	const std::string msg = runTexts(kBasicSql, "@Alias\nfoo;\nbar;\n@\n");
	TH_CHECK(msg.find("Alias matrix 'Alias' has no 'name' column") != std::string::npos);
}

TH_TEST(run_registers_inline_vars_before_dispatch) {
	/* @Vars 先于 @Action 生效；派发因设备未声明而失败——错误必须来自派发，
	 * 而不是 Vars 注册阶段。 */
	const std::string msg = runTexts(kBasicSql,
		"@Vars\nname value;\nspd 90;\n@\n"
		"@Action\nrelay9.spd;\n  200;\n@\n");
	TH_CHECK(msg.find("no 'value' column") == std::string::npos);
	TH_CHECK(msg.find("not a valid Number") == std::string::npos);
	TH_CHECK(msg.find("Duplicate Vars name") == std::string::npos);
	TH_CHECK(msg.find("'relay9'") != std::string::npos);
}

TH_TEST(run_rejects_duplicate_vars_in_one_action_script) {
	const std::string msg = runTexts(kBasicSql,
		"@Vars\nname value;\nspd 1;\nspd 2;\n@\n"
		"@Action\nrelay0.spd;\n  200;\n@\n");
	TH_CHECK(msg.find("Duplicate Vars name 'spd'") != std::string::npos);
}

TH_TEST(run_rejects_vars_matrix_without_value_column) {
	const std::string msg = runTexts(kBasicSql, "@Vars\nname;\nspd;\n@\n");
	TH_CHECK(msg.find("Vars matrix 'Vars' has no 'value' column") != std::string::npos);
}

TH_TEST(run_rejects_non_numeric_vars_value) {
	/* @Vars 仅支持 Number：非数值在注册阶段即报错 */
	const std::string msg = runTexts(kBasicSql, "@Vars\nname value;\nspd fast;\n@\n");
	TH_CHECK(msg.find("neither a Number") != std::string::npos);
}


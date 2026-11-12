/* test_robot_hotupdate.cpp —— 热更新行（UPDATE 断电重建）
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）。判据口径与探针落痕说明
 * 见 test_robot_hotinsert.cpp 段首长注；hotSqlError/markerOf/probeSql 取自
 * robot_fixtures.hpp。
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

using fx::ModulePathGuard;
using rfx::cell;
using rfx::hotSqlError;
using rfx::markerOf;
using rfx::probeSql;
/* ==================== 热更新：UPDATE t SET ... [WHERE ...]（2026-09-23）====================
 * 语义是**断电重建**：命中行按「DELETE（物理断电摘除）+ INSERT（改后行重新装配
 * 上电）」两条既有路径执行，不是原地改值。本组与热删除组同构的三条判据：
 *   ① 生效 = 旧行真的当场断电（探针落痕）+ 新行真的带电常驻（改后值可观测）；
 *   ② 拒绝 = 活体一字未动（守门全部在预检，报错点名成因）；
 *   ③ 先删后建的失败口径 = 已摘旧行**不复原**，错误点名丢失的变量（不谎报回滚）。
 * 另有两条方言级守门（批内独占 / 结构脚本期拒绝）钉在 readSQL。
 * 物理证据链：LifetimeProbe 的 destroy 向 data.path 追加 'D'——改 path 的更新
 * 会把「旧件的断电落痕」留在旧路径、把「新件的最终断电」留在新路径，两条路径
 * 各一个 'D' 正是「断电重建」两个阶段的直接观测。 */

/* 基本：同名行改值。重名预检的 doomed 豁免、先删后建序、摘要三段式都在此钉住。 */
TH_TEST(robot_hot_update_rewrites_a_row_by_power_cycle) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-basic");
	const fs::path oldM = tmp.path() / "old";
	const fs::path newM = tmp.path() / "new";

	bot::MemoryReader sr(probeSql(oldM));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t namesBefore = robot.registry().byName().size();

	/* 多赋值（path 与 name 各一条；name 赋原值 = 不改名，只验证多赋值通道） */
	const std::string msg = robot.applySql(
		"UPDATE LifetimeProbe SET path = '" + newM.string() + "', name = 'p0'\n"
		"WHERE name = 'p0';\n");

	/* 摘要三段式：断电重建的物理事实 = 删 1 + 增 1 + 热更新 1（三个数相互对账） */
	TH_CHECK_MSG(msg.find("已热更新 1 行（断电重建）") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("新增硬件变量 1 个") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("已删除硬件变量 1 个（p0）") != std::string::npos, "实际: " + msg);
	/* 同名重建：变量仍可寻址，注册表/销毁序规模不变 */
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(robot.structures().declaresVariable("p0"));
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(robot.registry().sequence().size() == namesBefore);
	/* 矩阵行数不变（1 删 1 增），改后行的 path 已是新值 */
	const mt::MatrixObject* m = robot.structures().find( "LifetimeProbe");
	TH_CHECK(m != nullptr && m->rows() == 2);
	TH_CHECK(fx::cell(*m, 1, 1) == newM.string());
	/* 先删后建的物理证据：旧件在更新**当场**断电（旧路径立即落痕），
	 * 新件带电常驻（新路径此刻无痕） */
	TH_CHECK(markerOf(oldM) == "D");
	TH_CHECK(markerOf(newM).empty());
	robot.deactivate();
	TH_CHECK(markerOf(newM) == "D");
	TH_CHECK(markerOf(oldM) == "D");	/* 旧件只断电一次，不会被二次 destroy */
}

/* WHERE 选行与无 WHERE 全表改写：只有命中行被断电重建。 */
TH_TEST(robot_hot_update_where_selects_rows_and_no_where_rewrites_all) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-where");
	const fs::path mA = tmp.path() / "a";
	const fs::path mB = tmp.path() / "b";
	const fs::path mC = tmp.path() / "c";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mA.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + mB.string() + "');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql(
		"UPDATE LifetimeProbe SET path = '" + mC.string() + "' WHERE name = 'p1';\n");
	TH_CHECK_MSG(msg.find("已热更新 1 行") != std::string::npos, "实际: " + msg);
	/* 只有 p1 被断电重建：p1 旧件当场断电（mB 落痕），p0 的 mA 无痕 */
	TH_CHECK(markerOf(mB) == "D");
	TH_CHECK(markerOf(mA).empty());
	const mt::MatrixObject* m = robot.structures().find( "LifetimeProbe");
	TH_CHECK(m != nullptr && m->rows() == 3);	/* 列头 + p0 + 改后 p1 */
	TH_CHECK(fx::cell(*m, 1, 1) == mA.string());	/* 未命中行原样 */
	TH_CHECK(fx::cell(*m, 2, 1) == mC.string());	/* 命中行已是新值 */

	/* 无 WHERE = 全部数据行（与 DELETE「无条件删全表」同口径） */
	const std::string all = robot.applySql(
		"UPDATE LifetimeProbe SET path = '" + mC.string() + "';\n");
	TH_CHECK_MSG(all.find("已热更新 2 行") != std::string::npos, "实际: " + all);
	TH_CHECK_MSG(all.find("已删除硬件变量 2 个") != std::string::npos, "实际: " + all);
	TH_CHECK(markerOf(mA) == "D");	/* p0 这次也被断电重建（旧值路径落痕） */
	robot.deactivate();
	/* mC 的三个 'D'：第一次改写的新 p1（第二次改写时被断电）+ 退出时两个新件 */
	TH_CHECK(markerOf(mC) == "DDD");
}

/* 改名：SET name = 新名。旧名随断电摘除消失，新名可寻址。 */
TH_TEST(robot_hot_update_renames_a_row_via_set_name) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-rename");
	const fs::path m = tmp.path() / "d";

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql(
		"UPDATE LifetimeProbe SET name = 'p9' WHERE name = 'p0';\n");
	TH_CHECK_MSG(msg.find("已热更新 1 行") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(!robot.structures().declaresVariable("p0"));
	TH_CHECK(robot.registry().contains("p9"));
	const mt::MatrixObject* mm = robot.structures().find( "LifetimeProbe");
	TH_CHECK(mm != nullptr && fx::cell(*mm, 1, 0) == "p9");
	/* 改名不改 path：旧件断电落痕仍在原路径 */
	TH_CHECK(markerOf(m) == "D");
	robot.deactivate();
	TH_CHECK(markerOf(m) == "DD");	/* 新件 path 未变，退出时再落一个 D */
}

/* 0 命中是响亮报错（口径同 DELETE），不是「成功但什么都没做」。 */
TH_TEST(robot_hot_update_no_match_is_a_loud_error) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-nomatch");
	const fs::path m = tmp.path() / "d";

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t namesBefore = robot.registry().byName().size();

	const std::string err = hotSqlError(robot,
		"UPDATE LifetimeProbe SET path = 'x' WHERE name = 'nope';\n");
	TH_CHECK_MSG(err.find("no row matches, nothing was updated") != std::string::npos,
		"实际: " + err);
	/* 活体一字未动 */
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 2);
	TH_CHECK(markerOf(m).empty());
	robot.deactivate();
}

/* 被引用（controller 流列）的变量不得改写：改写 = 断电摘除，悬垂指针防线同热删除。 */
TH_TEST(robot_hot_update_refuses_a_row_still_referenced_by_a_controller) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-refctrl");
	const fs::path mp = tmp.path() / "probe";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, controller String);\n"
		"INSERT INTO dummy (name, controller) VALUES ('dm', 'p0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot,
		"UPDATE LifetimeProbe SET path = 'x' WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("热删除被拒绝") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("dummy") != std::string::npos, "报错须点名引用方所在表: " + err);
	TH_CHECK_MSG(err.find("p0") != std::string::npos, "报错须点名被引用变量: " + err);
	/* 活体一字未动 */
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(mp).empty());
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 2);
	robot.deactivate();
}

/* 改写行自己引用本批将摘除的名字（含旧名）：预检的扫描面必须覆盖**新增/改写行**
 * ——流引用与 $ 引用都是懒解析，预检不拦就是运行期的雷（先删后建下还会落进
 * 「旧件已摘、新件失败」的不可复原窗口）。 */
TH_TEST(robot_hot_update_refuses_a_rewrite_referencing_the_doomed_name) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-selfref");
	const fs::path m = tmp.path() / "d";

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();

	/* 改名 p0→p0x 的同时把 path 指向旧名 $p0：改后行引用本批将删的 p0 */
	const std::string err = hotSqlError(robot,
		"UPDATE LifetimeProbe SET name = 'p0x', path = '$p0' WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("热删除被拒绝") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("$p0") != std::string::npos, "报错须点名引用形态: " + err);
	/* 活体一字未动（改名没有发生，$ 引用没有落进结构） */
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(!robot.registry().contains("p0x"));
	TH_CHECK(markerOf(m).empty());
	robot.deactivate();
}

/* 批内独占（readSQL 守门，四个方向）：UPDATE 与该表的其它行级语句不得同批。 */
TH_TEST(robot_hot_update_batch_exclusivity_guards) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-exclusive");
	const fs::path m = tmp.path() / "d";

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t namesBefore = robot.registry().byName().size();
	const std::size_t rowsBefore = robot.structures().find( "LifetimeProbe")->rows();

	/* ① 同表先 INSERT 后 UPDATE：分解的尾块区间算式会被打乱 */
	const std::string e1 = hotSqlError(robot,
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p9', 'x');\n"
		"UPDATE LifetimeProbe SET path = 'y' WHERE name = 'p0';\n");
	TH_CHECK_MSG(e1.find("run UPDATE in a separate statement batch") != std::string::npos,
		"实际: " + e1);
	/* ② 同表先 UPDATE 后 INSERT */
	const std::string e2 = hotSqlError(robot,
		"UPDATE LifetimeProbe SET path = 'y' WHERE name = 'p0';\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p9', 'x');\n");
	TH_CHECK_MSG(e2.find("run INSERT in a separate statement batch") != std::string::npos,
		"实际: " + e2);
	/* ③ 同表双 UPDATE */
	const std::string e3 = hotSqlError(robot,
		"UPDATE LifetimeProbe SET path = 'y' WHERE name = 'p0';\n"
		"UPDATE LifetimeProbe SET path = 'z' WHERE name = 'p0';\n");
	TH_CHECK_MSG(e3.find("run UPDATE in a separate statement batch") != std::string::npos,
		"实际: " + e3);
	/* ④ 本批次新建的表：行从未装配，「改写」无从谈起 */
	const std::string e4 = hotSqlError(robot,
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"UPDATE Timer SET name = 't1' WHERE name = 't0';\n");
	TH_CHECK_MSG(e4.find("created earlier in this batch") != std::string::npos,
		"实际: " + e4);
	/* 活体一字未动：四批全部在预检被拒 */
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == rowsBefore);
	TH_CHECK(!robot.structures().declaresVariable("p9"));
	TH_CHECK(!robot.structures().declaresVariable("t0"));
	TH_CHECK(markerOf(m).empty());
	robot.deactivate();
	TH_CHECK(markerOf(m) == "D");
}

/* 方言级守门：结构脚本期拒绝（机器人尚未上电）；热插期未知表报错。 */
TH_TEST(robot_hot_update_rejects_script_time_and_unknown_table) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-badsql");
	const fs::path m = tmp.path() / "d";

	/* 启动期（结构脚本）里的 UPDATE：与 DELETE/DROP 同判据 */
	bot::MemoryReader sr2(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"UPDATE Timer SET name = 't1' WHERE name = 't0';\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot appear in a structure script",
		bot::RobotStruct(sr2));

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::string unknown = hotSqlError(robot, "UPDATE Nope SET a = 1;\n");
	TH_CHECK_MSG(unknown.find("table is not defined") != std::string::npos, "实际: " + unknown);
	robot.deactivate();
}

/* 先删后建的失败口径：预检全过、删除已执行、新件装配失败（4.3 的 $ 引用校验）
 * ⇒ 新件回滚、旧件不复原，错误**点名丢失的变量**——不谎报「校验拒绝、活体未动」，
 * 也不静默假装回滚。异常类型必须是 runtime_error：成因虽是 IllegalArgumentException
 * （$ 引用不存在），但活体已经动过，paramError 口径对它是谎报。 */
TH_TEST(robot_hot_update_delete_first_failure_names_lost_variables) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-update-lost");
	const fs::path m = tmp.path() / "d";

	bot::MemoryReader sr(probeSql(m));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t namesBefore = robot.registry().byName().size();

	/* $nosuch-var 不在 doomed 集（预检的引用扫描只对待删名），过了预检；
	 * 新行的 MetaProvider 在 4.3 validate 时才报「引用不存在」。 */
	std::string err;
	try {
		robot.applySql(
			"UPDATE LifetimeProbe SET path = '$nosuch-var' WHERE name = 'p0';\n");
	} catch (const std::exception& e) {
		err = e.what();
	}
	TH_CHECK_MSG(err.find("已断电摘除且未能重建") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("（p0）") != std::string::npos, "错误须点名丢失的变量: " + err);
	TH_CHECK_MSG(err.find("nosuch") != std::string::npos, "成因（$ 引用不存在）不得被掩盖: " + err);
	/* 如实：旧件已断电（落痕），新件未建成——p0 从注册表消失 */
	TH_CHECK(markerOf(m) == "D");
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(robot.registry().byName().size() == namesBefore - 1);
	/* 矩阵行也回到删后状态（改后行已随回滚弹出） */
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 1);
	robot.deactivate();
}


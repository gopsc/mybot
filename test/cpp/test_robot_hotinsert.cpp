/* test_robot_hotinsert.cpp —— 热插表：INSERT 既有表（结构 SQL 带电生效）
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）。本域三条判据（真装配真上电、
 * 回滚真断电一字复原、拒绝时活体一字未动）与探针落痕口径见下方段首长注。
 * 后续热删/热撤域在 test_robot_hotdelete.cpp、热更新在 test_robot_hotupdate.cpp。
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
using rfx::hotSqlError;
using rfx::markerOf;
using rfx::probeSql;
/* ==================== 热插表：结构 SQL 带电生效（2026-09-23）====================
 * RobotStruct::applySql 的端到端守门（P3 事务门面）。三条判据贯穿全组：
 *   ① 生效 = 真的装配 + 真的上电；
 *   ② 回滚 = 真的断电 + 注册表/矩阵一字复原；
 *   ③ 拒绝 = 活体一字未动（报错发生在任何资源申请之前）。
 * 断电的可观测证据仍是 LifetimeProbe.lua 的文件落痕。注意探针的 destroy 只在
 * **build 成功之后**才存在可调用的全局 destroy（luavar.cpp freeImpl：未 build 的
 * 变量全局 destroy 为 nil，跳过调用只释放状态），故「落痕数」精确等于
 * 「真正 build 过又被断电的器件数」——这正是区分「带电回滚」与「无副作用撤销」
 * 的依据，也是下面几条用例断言取值的由来。 */

/* 既有表插行：行落到结构矩阵、变量进注册表与销毁序，deactivate 时一并断电 */
TH_TEST(robot_hot_sql_insert_into_an_existing_table_goes_live) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-insert");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	TH_CHECK(robot.registry().contains("p0"));
	const std::size_t tablesBefore = robot.structures().size();
	const std::size_t namesBefore = robot.registry().byName().size();

	const std::string msg = robot.applySql(
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + marker.string() + "');\n");

	TH_CHECK(robot.registry().contains("p1"));
	TH_CHECK(robot.structures().declaresVariable("p1"));
	TH_CHECK(robot.structures().size() == tablesBefore);	/* 插行不新增表 */
	TH_CHECK(robot.registry().byName().size() == namesBefore + 1);
	TH_CHECK(robot.registry().sequence().size() == namesBefore + 1);
	TH_CHECK(msg.find("已生效：新增硬件变量 1 个") != std::string::npos);
	TH_CHECK(msg.find("既有表追加 1 行") != std::string::npos);

	/* build 不落痕、destroy 才落：热插时器件已在带上是本用例的「生效」证据 */
	TH_CHECK(markerOf(marker).empty());
	robot.deactivate();
	TH_CHECK(markerOf(marker) == "DD");	/* 两行都在销毁序里 */
}

/* 新表：整表入列 → 装配 → 上电；表数与摘要都要如实反映 */
TH_TEST(robot_hot_sql_create_table_assembles_a_new_hardware_variable) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-create");
	const fs::path marker = tmp.path() / "destroyed";

	/* 结构期只有 Timer：LifetimeProbe 完全由热插长出 */
	bot::MemoryReader sr("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t tablesBefore = robot.structures().size();

	const std::string msg = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n");

	TH_CHECK(robot.structures().size() == tablesBefore + 1);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(robot.structures().find( "LifetimeProbe") != nullptr);
	TH_CHECK(msg.find("新增表 1 张") != std::string::npos);

	robot.deactivate();
	TH_CHECK(markerOf(marker) == "D");
}

/* P0 回归守门（2026-09-23 审计，热插侧）：applySql 的影子容器 = 活体全量拷贝 +
 * 本批次 CREATE，同样走 readSQL 的表下标定位。5 张活表 + 第 1 批 CREATE 出的
 * 第 6 张表让 INSERT 目标落在 deque 第二块——旧指针差实现在此 UB/崩溃（实测
 * relay-test + 连续热插到第 6 张表即段错误）。三批依次覆盖 appendRowTracked /
 * removeRowsOf（DROP 既存表擦全部行）/ DROP 本批新建表（createdHere 整表擦除）
 * 三个修复点；marker 落痕证明跨块边界下 INSERT 行真的装配上电、DROP 真的断电。 */
TH_TEST(robot_hot_sql_stages_tables_across_deque_chunk_boundary) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-cross");
	const fs::path marker = tmp.path() / "destroyed";

	/* 结构期 5 张表（deque 第一块的容量），全部纯软件驱动、无需硬件 */
	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE Relay (name String);\n"
		"INSERT INTO Relay (name) VALUES ('relay0');\n"
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('dummy0');\n"
		"CREATE TABLE Monitor (name String);\n"
		"INSERT INTO Monitor (name) VALUES ('monitor0');\n"
		"CREATE TABLE Ema (name String);\n"
		"INSERT INTO Ema (name) VALUES ('ema0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	TH_CHECK(robot.structures().size() == 5);
	TH_CHECK(robot.registry().contains("timer-0"));
	TH_CHECK(robot.registry().contains("ema0"));

	/* 批 1：第 6 张表 + 插行（INSERT 目标下标 5 = 第二块首元素） */
	const std::string msg1 = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n");
	TH_CHECK(robot.structures().size() == 6);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(msg1.find("新增表 1 张") != std::string::npos);
	TH_CHECK(markerOf(marker).empty());	/* 已 build、未 destroy */

	/* 批 2：DROP 既存表——removeRowsOf 擦全部数据行（走表下标定位）+ 表壳摘除 */
	const std::string msg2 = robot.applySql("DROP TABLE LifetimeProbe;\n");
	TH_CHECK(robot.structures().size() == 5);
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(msg2.find("已撤下表 1 张") != std::string::npos);
	TH_CHECK(markerOf(marker) == "D");	/* p0 真的被断电 */

	/* 批 3：本批 CREATE 后再 DROP——createdHere 整表擦除路径（第三处下标定位）。
	 * 该表从未入活体，摘要不报「已撤下表」（那是活体表壳摘除的计数），但擦除
	 * 必须精确——旧垃圾下标会 erase 错表，这里 structures().size() == 5 即守门。 */
	const std::string msg3 = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"DROP TABLE LifetimeProbe;\n");
	TH_CHECK(robot.structures().size() == 5);
	TH_CHECK(!robot.structures().declaresVariable("p1"));
	TH_CHECK(msg3.find("新增硬件变量 0 个") != std::string::npos);

	robot.deactivate();
}

/* 上电中途收到停止信号：整批回滚。此处新变量尚未 build，故回滚只撤销
 * （不落痕）——正是「无副作用撤销」这一侧的证据，与下一条用例互补。 */
TH_TEST(robot_hot_sql_rolls_back_when_power_on_is_interrupted) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-stop");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t tablesBefore = robot.structures().size();
	const std::size_t namesBefore = robot.registry().byName().size();
	const std::size_t rowsBefore = robot.structures().find( "LifetimeProbe")->rows();

	bot::stopRequested().store(true);
	const std::string msg = hotSqlError(robot,
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + marker.string() + "');\n");
	bot::stopRequested().store(false);	/* 必须复位，否则污染后续用例 */

	TH_CHECK(msg.find("热插上电被中断") != std::string::npos);
	TH_CHECK(!robot.registry().contains("p1"));
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(robot.registry().sequence().size() == namesBefore);
	TH_CHECK(robot.structures().size() == tablesBefore);
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == rowsBefore);
	TH_CHECK(!robot.structures().declaresVariable("p1"));
	TH_CHECK(markerOf(marker).empty());	/* 未 build 即中止：没有器件真的带电 */
	robot.deactivate();
}

/* Action 执行失败发生在**硬件已 build 之后**：回滚必须真的把新器件断电
 * （落痕），而不是只在注册表上摘名——这正是「全成功或全回滚」的物理含义。 */
TH_TEST(robot_hot_sql_rolls_back_and_disconnects_when_the_action_fails) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-action-fail");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t tablesBefore = robot.structures().size();
	const std::size_t rowsBefore = robot.structures().find( "LifetimeProbe")->rows();

	/* 硬件全部上电之后才轮到 Action 派发：未声明的设备在这里才炸 */
	const std::string msg = hotSqlError(robot,
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + marker.string() + "');\n"
		"CREATE TABLE Action (ghost.deg Number);\n"
		"INSERT INTO Action (ghost.deg) VALUES (200);\n");

	TH_CHECK(msg.find("not defined in your hardware declaration section") != std::string::npos);
	TH_CHECK(markerOf(marker) == "D");	/* 回滚断电：p1 已 build，destroy 落痕 */
	TH_CHECK(!robot.registry().contains("p1"));
	TH_CHECK(robot.structures().size() == tablesBefore);	/* 瞬态 Action 表也不入列 */
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == rowsBefore);
	TH_CHECK(!robot.structures().declaresVariable("p1"));
	/* 活体未受损：既有 p0 照常断电（落痕与回滚那次各一次） */
	robot.deactivate();
	TH_CHECK(markerOf(marker) == "DD");
}

/* Action 表瞬态：行随硬件一起生效、执行一次即丢弃——不入结构矩阵、不注册变量。
 * 动作能引用**本批次新建**的变量，正是「Action 排在硬件装配之后」这条排序的判据。 */
TH_TEST(robot_hot_sql_action_rows_run_once_and_are_discarded) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-action-transient");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr("");	/* 空结构：整批由热插长出 */
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n"
		"CREATE TABLE Action (p0.deg Number);\n"
		"INSERT INTO Action (p0.deg) VALUES (200);\n");

	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(!robot.registry().contains("Action"));
	TH_CHECK(robot.structures().size() == 1);		/* 只有 LifetimeProbe，没有 Action 表 */
	TH_CHECK(robot.structures().find( "Action") == nullptr);
	TH_CHECK(!robot.structures().declaresVariable("Action"));
	TH_CHECK(msg.find("瞬态动作已执行 1 行（未注册，已丢弃）") != std::string::npos);

	robot.deactivate();
	TH_CHECK(markerOf(marker) == "D");
}

/* 变量重名（结构里既有 / 本批次内重复）必须在申请任何资源之前拒绝 */
TH_TEST(robot_hot_sql_rejects_a_duplicate_variable_name) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-duplicate");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t namesBefore = robot.registry().byName().size();
	const std::size_t rowsBefore = robot.structures().find( "LifetimeProbe")->rows();

	const std::string msg = hotSqlError(robot,
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n");
	TH_CHECK(msg.find("硬件变量名 'p0' 重复") != std::string::npos);
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == rowsBefore);
	TH_CHECK(markerOf(marker).empty());

	/* 批内重名同样早报（两条 INSERT 抢同一个名字） */
	const std::string msg2 = hotSqlError(robot,
		"INSERT INTO LifetimeProbe (name, path) VALUES ('q1', '" + marker.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('q1', '" + marker.string() + "');\n");
	TH_CHECK(msg2.find("硬件变量名 'q1' 重复") != std::string::npos);
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	robot.deactivate();
}

/* 安全边界：表名决定 modules/<表名>.lua 的解析路径，热插语句来自不可信输入
 * （REPL / 模型），故必须过 isSafeIdent；列名会进守护配置串，同理。 */
TH_TEST(robot_hot_sql_rejects_unsafe_table_and_column_names) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-ident");

	bot::MemoryReader sr("");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string badTable = hotSqlError(robot, "CREATE TABLE ../evil (name String);\n");
	TH_CHECK(badTable.find("表名") != std::string::npos);
	TH_CHECK(badTable.find("不是安全标识符") != std::string::npos);

	/* 列名带 '=' 的注入向量：裸写 a=b 在词法层就被 '=' 分隔符打散（Token =，
	 * 2026-09-23 WHERE 改造）；引号包裹的 'a=b' 仍是一个 NAME 词元，能走到
	 * isSafeIdent 检查——防线必须在这里接住它（'=' 能在守护配置串里造字段）。 */
	const std::string badCol =
		hotSqlError(robot, "CREATE TABLE Fresh (name String, 'a=b' String);\n");
	TH_CHECK(badCol.find("列名") != std::string::npos);
	TH_CHECK(badCol.find("不是安全标识符") != std::string::npos);

	TH_CHECK(robot.structures().empty());	/* 两次都在活体之外被拒 */
	robot.deactivate();
}

/* 不存在的驱动模块：启动期要到 build 才以 loadfile 失败暴露，热插提前折成
 * 一句点名表名的人话（判据与 createLuaVars 同一来源）。 */
TH_TEST(robot_hot_sql_rejects_a_table_without_a_driver_module) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-nomodule");

	bot::MemoryReader sr("");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = hotSqlError(robot,
		"CREATE TABLE NoSuchDriver9 (name String);\n"
		"INSERT INTO NoSuchDriver9 (name) VALUES ('x0');\n");
	TH_CHECK(msg.find("模块路径下找不到它") != std::string::npos);
	TH_CHECK(msg.find("NoSuchDriver9") != std::string::npos);
	TH_CHECK(robot.structures().empty());
	robot.deactivate();
}

/* 守护 chunk：启动期脚本可信故允许绝对路径，热插不可信——放行即等于让模型
 * 指定任意 Lua 文件当守护 chunk 加载。 */
TH_TEST(robot_hot_sql_rejects_a_daemon_chunk_outside_the_module_path) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-daemon-chunk");

	bot::MemoryReader sr("");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = hotSqlError(robot,
		"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
		"INSERT INTO Daemon (name, chunk, interval) VALUES ('d9', '/tmp/evil.lua', '10');\n");
	TH_CHECK(msg.find("相对路径") != std::string::npos);
	TH_CHECK(msg.find("/tmp/evil.lua") != std::string::npos);
	TH_CHECK(robot.structures().empty());
	robot.deactivate();
}

/* 空批次与未上电：前者是「SELECT 不该走热插」（只读查询另有出口），
 * 后者是「带电变更」这条语义的前置条件。 */
TH_TEST(robot_hot_sql_rejects_an_empty_batch_and_an_inactive_robot) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-precond");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);

	/* 未上电：结构脚本才是正确入口 */
	const std::string notActive =
		hotSqlError(robot, "INSERT INTO LifetimeProbe (name, path) VALUES ('p1', 'x');\n");
	TH_CHECK(notActive.find("需要机器人已上电常驻") != std::string::npos);
	TH_CHECK(!robot.structures().declaresVariable("p1"));

	robot.active();
	const std::string readOnly = hotSqlError(robot, "SELECT * FROM LifetimeProbe;\n");
	TH_CHECK(readOnly.find("没有任何 CREATE/INSERT/DELETE/DROP/UPDATE 变更") != std::string::npos);
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 2);
	robot.deactivate();
}

/* 容器不变式（std::deque）白盒锚定：MetaProvider 持指向 matrices_ 元素的引用，
 * vector 的 push_back 扩容会让全部旧引用悬垂。这里直接钉住「新表入列后旧元素
 * 的地址与内容一字未动」——改成 vector 会立刻红。 */
TH_TEST(robot_hot_sql_keeps_element_references_stable_across_appends) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-sql-stable");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();

	const mt::MatrixObject* probe = robot.structures().find( "LifetimeProbe");
	TH_CHECK(probe != nullptr && probe->rows() == 2);
	const std::string* header = &(*probe)(std::size_t(0), std::size_t(0));

	robot.applySql("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n");

	TH_CHECK(robot.structures().find( "LifetimeProbe") == probe);
	TH_CHECK(probe->rows() == 2);
	TH_CHECK(&(*probe)(std::size_t(0), std::size_t(0)) == header);
	TH_CHECK(*header == "name");
	robot.deactivate();
}

/* UPDATE（2026-09-23）：解析已进方言；带电生效（断电重建）由下方
 * robot_hot_update_* 组守门，此处不再保留过渡用例。 */

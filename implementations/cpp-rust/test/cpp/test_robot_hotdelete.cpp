/* test_robot_hotdelete.cpp —— 热删行与热撤表（DELETE / DROP）
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）。判据口径与探针落痕说明
 * 见 test_robot_hotinsert.cpp 段首长注；hotSqlError/markerOf/probeSql 取自
 * robot_fixtures.hpp。
 */
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
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

namespace {

/* 元数据登记表与活体结构的一致性自检（原 RobotStruct::metaProvidersMatchLiveRows，
 * 2026-10-03 阶段 4 随公开访问面门面化移出生产类，改经 structures()/metas() 两个
 * 域门面在测试侧组装）。期望集的表分派与 HwFactory::createHardVarsFrom 同集合：
 * Alias/Vars/Action/Daemon 表不产生 MetaProvider（标量走 registerScalarMatrix、守护
 * 走 MtVars_Daemon::Factory 且装配期即读全行），其余表每个数据行一个提供者。
 * multiset 比对——行号错位/摘错/漏摘都会失衡。 */
bool metaProvidersMatchLiveRows(const bot::RobotStruct& robot) {
	std::multiset<std::pair<const mt::MatrixObject*, std::int64_t>> expect;
	for (const auto& m : robot.structures().all()) {
		const std::string& t = m.getName();
		if (t == "Alias" || t == "Vars" || t == "Action" || t == "Daemon") { continue; }
		for (std::int64_t r = 1; r < static_cast<std::int64_t>(m.rows()); ++r) {
			expect.emplace(&m, r);
		}
	}
	std::multiset<std::pair<const mt::MatrixObject*, std::int64_t>> got;
	for (const auto& p : robot.metas().all()) { got.emplace(p->matrixPtr(), p->row()); }
	return expect == got;
}

} // namespace

/* ==================== 热删除：DELETE FROM t [WHERE ... AND ...] ====================
 * （2026-09-23）三条判据贯穿本组，与热插表组同构：
 *   ① 删除 = 真的逆序 destroy（LifetimeProbe 的 'D' 落痕是物理证据）；
 *   ② 一致性 = 结构矩阵、注册表（名字索引 + 销毁序）、MetaProvider/守护登记
 *      四者在同一次操作后互相自洽；
 *   ③ 拒绝 = 活体一字未动，且报错点名成因（引用完整性是这里的核心）。
 * 「不可逆」这条口径另有专门用例：物理断电没有回滚，中途失败如实报数。 */

/* 删既有行：变量从注册表与销毁序里消失，器件当场断电；此后 deactivate
 * 不得对它重复 destroy（它已不在销毁序里）——这正是「摘干净」的可观测判据。 */
TH_TEST(robot_hot_delete_removes_an_existing_row_and_powers_it_off) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-row");
	const fs::path marker = tmp.path() / "destroyed";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	TH_CHECK(robot.registry().contains("p0"));
	const std::size_t tablesBefore = robot.structures().size();

	const std::string msg = robot.applySql("DELETE FROM LifetimeProbe WHERE name = 'p0';\n");

	/* 删除当场断电：'D' 已落下，而不是等到 deactivate */
	TH_CHECK_MSG(markerOf(marker) == "D", "实际落痕: " + markerOf(marker));
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(!robot.structures().declaresVariable("p0"));
	TH_CHECK(robot.registry().byName().empty());
	TH_CHECK(robot.registry().sequence().empty());
	/* 表还在（删的是行不是表），只剩列头 */
	TH_CHECK(robot.structures().size() == tablesBefore);
	const mt::MatrixObject* m = robot.structures().find( "LifetimeProbe");
	TH_CHECK(m != nullptr && m->rows() == 1);
	/* 摘要如实报出删了谁 */
	TH_CHECK_MSG(msg.find("已删除硬件变量 1 个") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("p0") != std::string::npos, "实际: " + msg);

	/* 已摘除的变量不在销毁序里：deactivate 不得重复断电（落痕仍恰好 1 个 'D'） */
	robot.deactivate();
	TH_CHECK_MSG(markerOf(marker) == "D", "重复断电的落痕: " + markerOf(marker));
}

/* 多条件 AND：只有同时满足全部条件的行被删——AND 与 OR 的分界在热删除路径上
 * 尤其重要（删错行是物理不可逆的）。 */
TH_TEST(robot_hot_delete_and_conditions_select_exactly_one_row) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-and");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String, tag String);\n"
		"INSERT INTO LifetimeProbe (name, path, tag) VALUES ('p0', '" + m1.string() + "', 'a');\n"
		"INSERT INTO LifetimeProbe (name, path, tag) VALUES ('p1', '" + m2.string() + "', 'b');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	/* tag='a' 只有 p0；再加一条 name='p1' 让两个条件互斥 → 后者不存在这种行 */
	const std::string msg = robot.applySql(
		"DELETE FROM LifetimeProbe WHERE tag = 'a' AND name = 'p0';\n");
	TH_CHECK_MSG(msg.find("已删除硬件变量 1 个（p0）") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(robot.registry().contains("p1"));	/* 不满足全部条件的行必须留下 */
	TH_CHECK(markerOf(m1) == "D");
	TH_CHECK(markerOf(m2).empty());			/* p1 根本没被碰过 */

	/* 条件互斥（AND 语义）→ 一条都不命中 → 报错且活体不动 */
	const std::string err = hotSqlError(robot,
		"DELETE FROM LifetimeProbe WHERE tag = 'b' AND name = 'p0';\n");
	TH_CHECK_MSG(err.find("no row matches") != std::string::npos, "实际: " + err);
	TH_CHECK(robot.registry().contains("p1"));
	TH_CHECK(markerOf(m2).empty());

	robot.deactivate();
}

/* 无条件 = 删空该表（SQL 语义）：命中全部数据行，一次全删。 */
TH_TEST(robot_hot_delete_without_where_removes_every_row) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-all");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + m1.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + m2.string() + "');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql("DELETE FROM LifetimeProbe;\n");
	TH_CHECK_MSG(msg.find("已删除硬件变量 2 个") != std::string::npos, "实际: " + msg);
	TH_CHECK(robot.registry().byName().empty());
	TH_CHECK(markerOf(m1) == "D" && markerOf(m2) == "D");
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 1);	/* 只剩列头 */

	/* 空表的无条件删除：没有可删的行 → 报错而不是静默成功 */
	const std::string err = hotSqlError(robot, "DELETE FROM LifetimeProbe;\n");
	TH_CHECK_MSG(err.find("no row matches") != std::string::npos, "实际: " + err);

	robot.deactivate();
}

/* 批内先插后删：INSERT 与 DELETE 在影子容器上按语句序交错，故后一句能命中
 * 前一句刚插的行——新表最终是**空的**，一个变量都没长出来。
 * 这条守的是「删除生效」而不是「删掉了一个变量」：那些行从未装配、从未上电，
 * 撤销范围为空，但**绝不能**跟着新表一起装配出一个已被删掉的器件。 */
TH_TEST(robot_hot_delete_can_remove_a_row_inserted_in_the_same_batch) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-same-batch");
	const fs::path marker = tmp.path() / "d1";

	bot::MemoryReader sr("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t rowsBefore = robot.structures().find( "Timer")->rows();

	const std::string msg = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p9', '" + marker.string() + "');\n"
		"DELETE FROM LifetimeProbe WHERE name = 'p9';\n");

	/* 新表建了，但行被删掉 → 0 个变量、0 行数据 */
	TH_CHECK_MSG(msg.find("新增表 1 张") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("新增硬件变量 0 个") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p9"));
	const mt::MatrixObject* m = robot.structures().find( "LifetimeProbe");
	TH_CHECK_MSG(m != nullptr && m->rows() == 1, "新表应只剩列头（行被删干净）");
	/* 该表的行在装配之前就被删掉了 → 从未 build → 不留断电落痕 */
	TH_CHECK_MSG(markerOf(marker).empty(), "未装配的行不该有断电落痕: " + markerOf(marker));
	/* 无关的表一字不动 */
	TH_CHECK(robot.structures().find( "Timer")->rows() == rowsBefore);
	TH_CHECK(robot.registry().contains("t0"));

	robot.deactivate();
}

/* A-4 回归（2026-09-25 审计收口）：热删除后存活提供者的行号必须重锚定。
 * 原实现的已知边界：removeRows 保序擦除让同矩阵后续行前移，而提供者的 row()
 * 是**后续批次** deadProvider 判据的坐标——不止混批（先插入后删除）新追加行，
 * 任何同表删行（含 UPDATE 批次里未改写的既有行）都会让坐标过期，下一批删除
 * 随即摘错/漏摘 MetaProvider 条目。判据用本文件顶部的 metaProvidersMatchLiveRows
 * 自检（提供者 ↔ 数据行一一对应；行号错位/摘错/漏摘都会失衡），三批连删覆盖：
 *   批 1 删中间行（纯删，存活行前移）；批 2 混批先插后删（新行坐标以追加时
 *   值创建、随后被同批删行打乱——正是原注释点名的场景）；批 3 再删一行
 *   （若批 1/2 未重锚定，本批判据必错）。 */
TH_TEST(robot_hot_delete_rebases_surviving_provider_rows) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-rebase");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";
	const fs::path m3 = tmp.path() / "d3";
	const fs::path m4 = tmp.path() / "d4";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + m1.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + m2.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p2', '" + m3.string() + "');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	TH_CHECK(metaProvidersMatchLiveRows(robot));

	/* 批 1：删中间行 p1 → p0/p2 的提供者行号必须各前移一位 */
	robot.applySql("DELETE FROM LifetimeProbe WHERE name = 'p1';\n");
	TH_CHECK_MSG(metaProvidersMatchLiveRows(robot), "批 1 后提供者与数据行失配");
	TH_CHECK(markerOf(m2) == "D" && markerOf(m1).empty() && markerOf(m3).empty());
	TH_CHECK(robot.registry().contains("p0") && robot.registry().contains("p2"));

	/* 批 2（混批先插后删）：新行 p3 以追加行号创建提供者，同批删掉 p0 使其前移 */
	robot.applySql(
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p3', '" + m4.string() + "');\n"
		"DELETE FROM LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(metaProvidersMatchLiveRows(robot), "批 2 后提供者与数据行失配");
	TH_CHECK(markerOf(m1) == "D" && markerOf(m4).empty());
	TH_CHECK(robot.registry().contains("p2") && robot.registry().contains("p3"));

	/* 批 3：再删 p2——坐标链再走一步；结尾只剩 p3，收尾断电恰好一次 */
	robot.applySql("DELETE FROM LifetimeProbe WHERE name = 'p2';\n");
	TH_CHECK_MSG(metaProvidersMatchLiveRows(robot), "批 3 后提供者与数据行失配");
	TH_CHECK(markerOf(m3) == "D");
	TH_CHECK(robot.registry().contains("p3"));
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 2);

	robot.deactivate();
	TH_CHECK(markerOf(m4) == "D");
}

/* 引用完整性（本功能的安全核心）：存活结构里引用着待删变量时必须拒绝，
 * 且报错**点名**是哪张表哪一行的哪一列。三类引用各一条：
 *   a) 流列 controller/trigger（MtVars_Lua::ctrlPtrs_/trigPtrs_ 终身缓存裸指针）
 *   b) 元数据列的字面 $name 引用（MetaRef::target 在 seed 期锁定）
 *   c) 元数据列的 $(...) 表达式（标识符按名求值）
 * 三条都必须「活体一字未动」：器件不能掉电、结构不能少行。 */
TH_TEST(robot_hot_delete_rejects_a_variable_still_referenced_by_a_controller) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-refctrl");
	const fs::path mp = tmp.path() / "probe";
	const fs::path mt = tmp.path() / "timer";

	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, controller String);\n"
		"INSERT INTO dummy (name, controller) VALUES ('dm', 'p0');\n");
	(void)mt;
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot, "DELETE FROM LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("控制器") != std::string::npos
		|| err.find("controller") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("dummy") != std::string::npos, "报错须点名引用方所在表: " + err);
	TH_CHECK_MSG(err.find("p0") != std::string::npos, "报错须点名被引用变量: " + err);
	/* 活体一字未动 */
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(mp).empty());
	TH_CHECK(robot.structures().find( "LifetimeProbe")->rows() == 2);
	robot.deactivate();
}

TH_TEST(robot_hot_delete_rejects_a_variable_still_referenced_by_a_trigger_column) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-reftrig");
	const fs::path mp = tmp.path() / "probe";

	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, trigger2 String);\n"
		"INSERT INTO dummy (name, trigger2) VALUES ('dm', 'p0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	/* trigger2 是**编号列**：判据必须走 isFlowColumn 单点，自带一份就会漏掉它
	 * 而留下悬垂指针——这条用例专门钉那个单点。 */
	const std::string err = hotSqlError(robot, "DELETE FROM LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("p0") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("trigger2") != std::string::npos, "编号流列也必须被认出: " + err);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(mp).empty());
	robot.deactivate();
}

TH_TEST(robot_hot_delete_rejects_a_variable_referenced_by_a_dollar_ref) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-refdollar");
	const fs::path mp = tmp.path() / "probe";

	/* Monitor 的 src='$p0'：典型的跨表元数据引用（seed 期锁定 MetaRef::target） */
	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE Monitor (name String, src String);\n"
		"INSERT INTO Monitor (name, src) VALUES ('mon0', '$p0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot, "DELETE FROM LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("$p0") != std::string::npos, "报错须回显引用原文: " + err);
	TH_CHECK_MSG(err.find("Monitor") != std::string::npos, "报错须点名引用方所在表: " + err);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(mp).empty());
	robot.deactivate();
}

TH_TEST(robot_hot_delete_rejects_a_variable_referenced_by_an_expression) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-refexpr");
	const fs::path mp = tmp.path() / "probe";

	/* $(v0+1) 形式：标识符经注册表按名求值，目标消失即结构已坏 */
	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE Vars (name String, value String);\n"
		"INSERT INTO Vars (name, value) VALUES ('v0', '5');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, delay String);\n"
		"INSERT INTO dummy (name, delay) VALUES ('dm', '$(v0+1)');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot, "DELETE FROM Vars WHERE name = 'v0';\n");
	TH_CHECK_MSG(err.find("v0") != std::string::npos, "实际: " + err);
	TH_CHECK_MSG(err.find("dummy") != std::string::npos, "报错须点名引用方所在表: " + err);
	TH_CHECK(robot.registry().contains("v0"));
	robot.deactivate();
}

/* 引用方与被引用者**一起删**时不该拒绝：引用随行一起消失，不构成悬垂。
 * 这条是上面几条拒绝用例的对照组——判据是「存活行里是否还有引用」，
 * 不是「曾经有没有引用」。 */
TH_TEST(robot_hot_delete_allows_deleting_the_referrer_together_with_its_target) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-ref-together");
	const fs::path mp = tmp.path() / "probe";

	bot::MemoryReader sr(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('timer-0');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, controller String);\n"
		"INSERT INTO dummy (name, controller) VALUES ('dm', 'p0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	/* 两行同批删：先删引用方（dummy.dm）再删目标（p0），故任何时刻存活行里
	 * 都没有悬垂引用——这正是把「幸存的引用方」而不是「全部引用方」作为
	 * 判据的意义。注意顺序无关：预检查的是**删除之后**的视图。 */
	const std::string msg = robot.applySql(
		"DELETE FROM LifetimeProbe WHERE name = 'p0';\n"
		"DELETE FROM dummy WHERE name = 'dm';\n");
	TH_CHECK_MSG(msg.find("已删除硬件变量 2 个") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(!robot.registry().contains("dm"));
	TH_CHECK(robot.registry().contains("timer-0"));	/* 无关的变量一字不动 */
	TH_CHECK(robot.registry().byName().size() == 1);
	TH_CHECK(markerOf(mp) == "D");
	robot.deactivate();
}

/* 守护行删除：守护线程必须**先退场**再摘除登记槽，否则它会继续往一个已
 * 断电的采样对象上写。判据是登记槽消失（daemonHolders_ 按保留项重建），
 * 且过程不挂死（屏障等待不等满超时）。 */
TH_TEST(robot_hot_delete_removes_a_daemon_row_and_stops_its_thread) {
	ModulePathGuard guard("modules:test/cpp:modules");
	TempDir tmp("hot-delete-daemon");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(
		"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
		"INSERT INTO Daemon (name, chunk, interval) VALUES ('d0', 'LifetimeTick.lua', '10');\n"
		+ probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();
	TH_CHECK(robot.registry().contains("d0"));

	const std::string msg = robot.applySql("DELETE FROM Daemon WHERE name = 'd0';\n");
	TH_CHECK_MSG(msg.find("已删除硬件变量 1 个（d0）") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("d0"));
	/* 守护行没了，但同表的其它行（若有）与别的表一字不动 */
	TH_CHECK(robot.structures().find( "Daemon")->rows() == 1);
	TH_CHECK(robot.registry().contains("p0"));
	/* 守护退场后 `deactivate` 不得因已摘除的守护出错，也不重复断电 */
	robot.deactivate();
	TH_CHECK(markerOf(marker).find('D') != std::string::npos);
}

/* 未上电即拒：与热插表同一条前置（热删除同样是带电变更），且必须在任何
 * destroy 之前失败。 */
TH_TEST(robot_hot_delete_requires_an_active_robot) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-inactive");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	const std::string err = hotSqlError(robot, "DELETE FROM LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("需要机器人已上电常驻") != std::string::npos, "实际: " + err);
	TH_CHECK(markerOf(marker).empty());
}

/* 目标表不存在 / 结构脚本里写 DELETE：两条都要给人话，且都不碰活体。
 * 后者是 allowDelete 缺省关的守门——同一个 readSQL 服务启动路径与热插路径，
 * 缺省关保证启动路径的接受语言逐字不变。 */
TH_TEST(robot_hot_delete_rejects_unknown_table_and_script_time_delete) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-badsql");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string unknown = hotSqlError(robot, "DELETE FROM Nope WHERE name = 'x';\n");
	TH_CHECK_MSG(unknown.find("table is not defined") != std::string::npos, "实际: " + unknown);
	TH_CHECK(robot.registry().contains("p0"));
	robot.deactivate();

	/* 启动期（结构脚本）里的 DELETE：机器人还没上电，没有可变的结构 */
	bot::MemoryReader sr2(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"DELETE FROM Timer WHERE name = 't0';\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot appear in a structure script",
		bot::RobotStruct(sr2));
}

/* 同一批次里既删又插：两条路径各自生效、互不串味，摘要同时报出两侧。 */
TH_TEST(robot_hot_delete_mixes_with_insert_in_one_batch) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-delete-mixed");
	const fs::path oldM = tmp.path() / "old";
	const fs::path newM = tmp.path() / "new";

	bot::MemoryReader sr(probeSql(oldM));
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql(
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + newM.string() + "');\n"
		"DELETE FROM LifetimeProbe WHERE name = 'p0';\n");

	/* 新增与删除是**两个维度**，必须各自如实报数：同批删一插一时净增量为 0，
	 * 用「事后总数 - 批次前总数」算就会谎报「新增 0 个」。 */
	TH_CHECK_MSG(msg.find("新增硬件变量 1 个") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("既有表追加 1 行") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("已删除硬件变量 1 个（p0）") != std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(robot.registry().contains("p1"));
	TH_CHECK(markerOf(oldM) == "D");	/* 删掉的当场断电 */
	TH_CHECK(markerOf(newM).empty());	/* 新增的带电常驻，不落痕 */
	/* 表内净行数不变（删 1 插 1），且 p1 补在被删的 p0 之后 */
	const mt::MatrixObject* m = robot.structures().find( "LifetimeProbe");
	TH_CHECK(m != nullptr && m->rows() == 2);
	TH_CHECK(fx::cell(*m, 1, 0) == "p1");
	robot.deactivate();
	TH_CHECK(markerOf(newM) == "D");	/* 退出时新增的才断电 */
}

/* ==================== 整表撤下：DROP TABLE t（2026-09-23）====================
 * DROP = DELETE 的「全表行」+「摘表壳」两步。因而本组的三条判据与热删除组同构
 * （真断电 / 四视图自洽 / 拒绝时活体一字未动），另加一条**只有整表撤下才会碰到**
 * 的不变式：表壳从 matrices_（deque）上 erase 会让其后元素引用失效，存活表的
 * MetaProvider 必须被重锚定——否则后续 read/destroy 踩悬垂指针。 */

/* 撤整表：该表全部变量当场断电、注册表/销毁序清空、表壳从结构里消失；
 * 其它表一字不动。已摘除的变量不在销毁序里，deactivate 不得重复断电。 */
TH_TEST(robot_hot_drop_removes_the_whole_table_and_powers_off_all_rows) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-table");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + m1.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + m2.string() + "');\n"
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	const std::size_t tablesBefore = robot.structures().size();

	const std::string msg = robot.applySql("DROP TABLE LifetimeProbe;\n");

	/* 当场断电：两行都落下 'D'，而不是等到 deactivate */
	TH_CHECK_MSG(markerOf(m1) == "D" && markerOf(m2) == "D",
		"实际 m1=" + markerOf(m1) + " m2=" + markerOf(m2));
	/* 表壳消失、变量与名字索引清空；无关的表与变量一字不动 */
	TH_CHECK(robot.structures().size() == tablesBefore - 1);
	TH_CHECK(robot.structures().find( "LifetimeProbe") == nullptr);
	TH_CHECK(!robot.registry().contains("p0") && !robot.registry().contains("p1"));
	TH_CHECK(!robot.structures().declaresVariable("p0"));
	TH_CHECK(robot.registry().contains("t0"));
	TH_CHECK(robot.structures().find( "Timer") != nullptr);
	/* 摘要如实报出撤下的表名 */
	TH_CHECK_MSG(msg.find("已撤下表 1 张") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("LifetimeProbe") != std::string::npos, "实际: " + msg);

	/* 已摘除的变量不在销毁序里：deactivate 不得重复断电（落痕仍恰好 1 个 'D'） */
	robot.deactivate();
	TH_CHECK(markerOf(m1) == "D" && markerOf(m2) == "D");
}

/* DROP 不带 WHERE（DDL 作用于整张表）：无条件撤下全部行。空表（只有列头）
 * 撤下也是合法操作——不是「一条都没删到」，故不报错。 */
TH_TEST(robot_hot_drop_is_unconditional_and_allows_an_empty_table) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-uncond");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + m1.string() + "');\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + m2.string() + "');\n"
		/* Timer 只有列头，没有任何数据行——撤它必须照样成功 */
		"CREATE TABLE Timer (name String);\n");
	bot::RobotStruct robot(sr);
	robot.active();

	/* 空表：无条件撤下成功（不是 "no row matches" 之列） */
	const std::string emptyMsg = robot.applySql("DROP TABLE Timer;\n");
	TH_CHECK_MSG(emptyMsg.find("已撤下表 1 张") != std::string::npos, "实际: " + emptyMsg);
	TH_CHECK(robot.structures().find( "Timer") == nullptr);

	/* 有数据的表：整表两行都当场断电 */
	const std::string msg = robot.applySql("DROP TABLE LifetimeProbe;\n");
	TH_CHECK_MSG(msg.find("已撤下表 1 张") != std::string::npos, "实际: " + msg);
	TH_CHECK(robot.structures().find( "LifetimeProbe") == nullptr);
	TH_CHECK(robot.registry().byName().empty());
	TH_CHECK(markerOf(m1) == "D" && markerOf(m2) == "D");

	robot.deactivate();
}

/* WHERE 不是 DROP 的语法：误写 WHERE 在解析期就被词元级报错拒绝，
 * 活体一字未动（这是「DDL 不筛行」的守门）。 */
TH_TEST(robot_hot_drop_rejects_a_where_clause) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-where");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot, "DROP TABLE LifetimeProbe WHERE name = 'p0';\n");
	TH_CHECK_MSG(err.find("Token WHERE") != std::string::npos, "实际: " + err);
	TH_CHECK(robot.structures().find( "LifetimeProbe") != nullptr);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(marker).empty());

	robot.deactivate();
}

/* 引用完整性：撤表会带走该表全部变量，故别的表若仍引用它们必须拒绝
 * （与 DELETE 同一条防线，报错点名「哪张表哪一行的哪一列引用了它」）。 */
TH_TEST(robot_hot_drop_rejects_a_variable_still_referenced_by_another_table) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-ref");
	const fs::path mp = tmp.path() / "probe";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + mp.string() + "');\n"
		"CREATE TABLE dummy (name String, controller String);\n"
		"INSERT INTO dummy (name, controller) VALUES ('dm', 'p0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string err = hotSqlError(robot, "DROP TABLE LifetimeProbe;\n");
	TH_CHECK_MSG(err.find("热删除被拒绝") != std::string::npos, "实际: " + err);
	/* 活体一字未动：表在、变量在、器件未断电 */
	TH_CHECK(robot.structures().find( "LifetimeProbe") != nullptr);
	TH_CHECK(robot.registry().contains("p0"));
	TH_CHECK(markerOf(mp).empty());

	robot.deactivate();
}

/* **整表撤下独有的不变式**：erase 表壳会让其后元素引用失效，存活表的
 * MetaProvider 必须被重锚定——否则读取存活变量的元数据会踩悬垂指针。
 * 夹具刻意把被撤的表放在 survive 表**之前**（它后面的元素才受 erase 影响），
 * 然后读存活变量的元数据：重锚定正确则返回 result=OK，悬垂则读到错位内容或崩。
 * （悬垂的最强证据在 sanitizer 构建：gate:sanitizer / gate:tsan。） */
TH_TEST(robot_hot_drop_rebases_meta_providers_of_surviving_tables) {
	ModulePathGuard guard("modules:test/cpp:modules");
	TempDir tmp("hot-drop-rebase");
	const fs::path marker = tmp.path() / "probe";

	/* dummy 在前（将被撤）、LifetimeProbe 在后（存活，其 provider 必须重锚定） */
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('dm');\n"
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + marker.string() + "');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	robot.applySql("DROP TABLE dummy;\n");
	TH_CHECK(robot.structures().find( "dummy") == nullptr);
	TH_CHECK(robot.registry().contains("p0"));

	/* 读存活变量的元数据：走存活表（已被 rebase）的 MetaProvider */
	bot::MatrixVars_Hardware* p0 = robot.registry().find("p0");
	TH_CHECK(p0 != nullptr);
	bot::Json md = p0->read();
	TH_CHECK_MSG(md.isObj(), "存活变量读回应是结果表");
	if (md.isObj()) {
		const auto r = md.get("result");
		TH_CHECK_MSG(r.has_value() && r->getValue() == "OK",
			"存活变量读回 result 应为 OK");
	}

	robot.deactivate();
	TH_CHECK(markerOf(marker) == "D");	/* 存活表的器件照常断电 */
}

/* 同一批次内先 CREATE 再 DROP：整表从未装配、从未上电，最终什么都不长出来。 */
TH_TEST(robot_hot_drop_of_a_table_created_in_the_same_batch_leaves_nothing) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-same-batch");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string msg = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p9', '" + marker.string() + "');\n"
		"DROP TABLE LifetimeProbe;\n");

	/* 表建了又被撤：一个变量都没长出来，表壳也不在结构里。摘除发生在装配之前，
	 * 故不是「新增后再删」而是「净效果为空」——摘要里连「新增表」都不出现。 */
	TH_CHECK_MSG(msg.find("新增硬件变量 0 个") != std::string::npos, "实际: " + msg);
	TH_CHECK_MSG(msg.find("新增表") == std::string::npos, "实际: " + msg);
	TH_CHECK(!robot.registry().contains("p9"));
	TH_CHECK(robot.structures().find( "LifetimeProbe") == nullptr);
	/* 从未装配 → 从未 build → 不留断电落痕 */
	TH_CHECK_MSG(markerOf(marker).empty(), "未装配的表不该有断电落痕: " + markerOf(marker));
	TH_CHECK(robot.registry().contains("t0"));

	robot.deactivate();
}

/* 目标表不存在 / 结构脚本里写 DROP：两条都要给人话，且都不碰活体。 */
TH_TEST(robot_hot_drop_rejects_script_time_and_unknown_table) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-badsql");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();

	const std::string unknown = hotSqlError(robot, "DROP TABLE Nope;\n");
	TH_CHECK_MSG(unknown.find("table is not defined") != std::string::npos, "实际: " + unknown);
	TH_CHECK(robot.registry().contains("p0"));
	robot.deactivate();

	/* 启动期（结构脚本）里的 DROP：机器人还没上电，没有可变的结构 */
	bot::MemoryReader sr2(
		"CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n"
		"DROP TABLE Timer;\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot appear in a structure script",
		bot::RobotStruct(sr2));
}

/* 未上电即拒：与热插/热删除同一条前置，且必须在任何 destroy 之前失败。 */
TH_TEST(robot_hot_drop_requires_an_active_robot) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-inactive");
	const fs::path marker = tmp.path() / "probe";

	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	const std::string err = hotSqlError(robot, "DROP TABLE LifetimeProbe;\n");
	TH_CHECK_MSG(err.find("需要机器人已上电常驻") != std::string::npos, "实际: " + err);
	TH_CHECK(markerOf(marker).empty());
}

/* 撤表后同名重建（DROP 打开的新语义面，见 sqlparse.cpp 的说明）：撤下之后
 * CREATE 同名表应被允许（表名不再冲突），且装配出的是全新变量。 */
TH_TEST(robot_hot_drop_allows_recreating_a_table_with_the_same_name) {
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("hot-drop-recreate");
	const fs::path m1 = tmp.path() / "d1";
	const fs::path m2 = tmp.path() / "d2";

	bot::MemoryReader sr(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p0', '" + m1.string() + "');\n");
	bot::RobotStruct robot(sr);
	robot.active();

	robot.applySql("DROP TABLE LifetimeProbe;\n");
	TH_CHECK(!robot.registry().contains("p0"));
	TH_CHECK(markerOf(m1) == "D");

	/* 同名重建：表名不再冲突，新变量照常装配 */
	const std::string msg = robot.applySql(
		"CREATE TABLE LifetimeProbe (name String, path String);\n"
		"INSERT INTO LifetimeProbe (name, path) VALUES ('p1', '" + m2.string() + "');\n");
	TH_CHECK_MSG(msg.find("新增表 1 张") != std::string::npos, "实际: " + msg);
	TH_CHECK(robot.structures().find( "LifetimeProbe") != nullptr);
	TH_CHECK(robot.registry().contains("p1"));
	TH_CHECK(markerOf(m2).empty());	/* 新器件带电常驻 */

	robot.deactivate();
	TH_CHECK(markerOf(m2) == "D");
}

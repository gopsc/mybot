/* test_robot_hotsql_plan.cpp —— 热 SQL 只读计划层
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）：HotSqlPlanner 的白盒守门
 * （不构造 RobotStruct、不装配硬件）；PlanOnlyHw/HotPlanFixture/kPlanSql 随迁。
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
#include "hotsql_plan.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "robot_fixtures.hpp"

namespace fs = std::filesystem;
using fx::TempDir;

using fx::ModulePathGuard;
using rfx::cell;
using rfx::loadMatrices;
/* ==================== 热 SQL 只读计划层（不构造 RobotStruct、不装配硬件）==================== */
namespace {

/* 连 read() 也不允许：计划只能借用对象身份，不能采样/播放/上电/断电。 */
class PlanOnlyHw : public bot::MatrixVars_Hardware {
	int& calls_;
public:
	explicit PlanOnlyHw(int& calls) : calls_(calls) {}
	bot::Json play(const bot::Json&) override { ++calls_; return bot::JsonNull(); }
	bot::Json read() override { ++calls_; return bot::JsonNull(); }
	void build() override { ++calls_; }
	void destroy() override { ++calls_; }
	const char* kindName() const override { return "plan-test"; }
};

std::string matrixSnapshot(const std::deque<mt::MatrixObject>& matrices) {
	std::ostringstream out;
	for (const auto& m : matrices) { m.save(out); }
	return out.str();
}

struct HotPlanFixture {
	int hardwareCalls = 0;
	const std::deque<mt::MatrixObject> matrices;
	bot::HwRegistry registry;
	std::string beforeMatrices;
	std::map<std::string, bot::MatrixVars_Hardware*> beforeNames;
	std::vector<bot::MatrixVars_Hardware*> beforeSequence;
	bot::HwRegistry::Mark beforeMark;
	bot::MatrixVars_Hardware* session = nullptr;

	explicit HotPlanFixture(const std::string& sql) : matrices(loadMatrices(sql)) {
		for (const auto& m : matrices) {
			const auto col = m.indexOfCol(0, "name");
			if (col < 0) { continue; }
			for (std::size_t r = 1; r < m.rows(); ++r) {
				registry.add(m(r, static_cast<std::size_t>(col)),
					std::make_unique<PlanOnlyHw>(hardwareCalls));
			}
		}
		/* 非空快照，避免空 flowRefs/session 让误清注册表的实现假绿。 */
		registry.addFlowRef("__flow_sentinel");
		registry.override("__session_sentinel", std::make_unique<PlanOnlyHw>(hardwareCalls));
		session = registry.find("__session_sentinel");
		beforeMatrices = matrixSnapshot(matrices);
		beforeNames = registry.byName();
		beforeSequence = registry.sequence();
		beforeMark = registry.mark();
	}

	void checkUnchanged() const {
		TH_CHECK(matrixSnapshot(matrices) == beforeMatrices);
		TH_CHECK(registry.byName() == beforeNames);
		TH_CHECK(registry.sequence() == beforeSequence);
		TH_CHECK(registry.mark().seq == beforeMark.seq);
		TH_CHECK(registry.mark().flowRefs == beforeMark.flowRefs);
		TH_CHECK(registry.sessionSize() == 1);
		TH_CHECK(registry.find("__session_sentinel") == session);
		TH_CHECK(hardwareCalls == 0);
	}

	~HotPlanFixture() { checkUnchanged(); }
};

const char* const kPlanSql =
	"CREATE TABLE Vars (name String, value String);\n"
	"INSERT INTO Vars (name, value) VALUES ('v0', '1');\n"
	"INSERT INTO Vars (name, value) VALUES ('v1', '2');\n"
	"INSERT INTO Vars (name, value) VALUES ('v2', '3');\n";

} // namespace

TH_TEST(hot_sql_plan_insert_owns_rows_and_separates_transient_actions) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f(kPlanSql);
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	auto plan = planner.build(
		"INSERT INTO Vars (value, name) VALUES ('4', 'v3');\n"
		"CREATE TABLE Timer (name String); INSERT INTO Timer (name) VALUES ('t0');\n"
		"CREATE TABLE Action (t0.delay Number); INSERT INTO Action (t0.delay) VALUES (1);\n");
	TH_CHECK(!plan.deletions.deleteFirst && plan.deletions.dels.empty());
	TH_CHECK(plan.insertions.appends.size() == 1);
	TH_CHECK(plan.insertions.appends.at(0).first == 0);
	TH_CHECK((plan.insertions.appends.at(0).second ==
		std::vector<std::vector<std::string>>{{"v3", "4"}}));
	TH_CHECK(plan.mutations.insertedRows.at("Vars") == 1);
	TH_CHECK(plan.insertions.newTables.size() == 1);
	TH_CHECK(plan.insertions.newTables.at(0).getName() == "Timer");
	TH_CHECK(cell(plan.insertions.newTables.at(0), 1, 0) == "t0");
	TH_CHECK(plan.insertions.actionMats.size() == 1);
	TH_CHECK(cell(plan.insertions.actionMats.at(0), 1, 0) == "1");
	/* 计划持有独立值，不别名输入矩阵；也没有偷偷登记 v3/t0。 */
	plan.insertions.appends.at(0).second.at(0).at(1) = "changed";
	plan.insertions.newTables.at(0).popRows(1);
	f.checkUnchanged();
}

TH_TEST(hot_sql_plan_delete_retains_original_rows_and_hardware_identity) {
	HotPlanFixture f(kPlanSql);
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	const auto plan = planner.build(
		"DELETE FROM Vars WHERE value = '1'; DELETE FROM Vars WHERE value = '3';");
	TH_CHECK(!plan.deletions.deleteFirst);
	TH_CHECK(plan.deletions.dels.size() == 1);
	const auto& del = plan.deletions.dels.at(0);
	TH_CHECK(del.matIdx == 0 && del.table == "Vars");
	TH_CHECK((del.rows == std::vector<std::size_t>{1, 3}));
	TH_CHECK((del.names == std::vector<std::string>{"v0", "v2"}));
	TH_CHECK((del.hw == std::vector<bot::MatrixVars_Hardware*>{
		f.registry.find("v0"), f.registry.find("v2")}));
	TH_CHECK(plan.mutations.deletedRows.at("Vars") == del.rows);
	TH_CHECK(plan.mutations.deletedNames == del.names);
	TH_CHECK((plan.deletions.doomedNames == std::set<std::string>{"v0", "v2"}));
	TH_CHECK(plan.insertions.appends.empty() && plan.insertions.newTables.empty());
}

TH_TEST(hot_sql_plan_update_exempts_only_doomed_names_and_preserves_commit_checks) {
	HotPlanFixture f(kPlanSql);
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	const auto plan = planner.build("UPDATE Vars SET value = '9' WHERE name = 'v1';");
	TH_CHECK(plan.deletions.deleteFirst);
	TH_CHECK(plan.mutations.updatedRows.at("Vars") == 1);
	TH_CHECK(plan.deletions.dels.at(0).rows == std::vector<std::size_t>{2});
	TH_CHECK(plan.deletions.dels.at(0).hw.at(0) == f.registry.find("v1"));
	TH_CHECK((plan.insertions.appends.at(0).second ==
		std::vector<std::vector<std::string>>{{"v1", "9"}}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "硬件变量名 'v0' 重复",
		planner.build("UPDATE Vars SET name = 'v0' WHERE name = 'v1';"));
	/* 未知 $ 引用仍留待装配校验，不能把原先「旧件已摘」改成计划期拒绝。 */
	const auto deferred = planner.build("UPDATE Vars SET value = '$unknown' WHERE name = 'v1';");
	TH_CHECK(deferred.deletions.deleteFirst);
	TH_CHECK(deferred.insertions.appends.at(0).second.at(0).at(1) == "$unknown");
}

TH_TEST(hot_sql_plan_non_update_mixed_batch_keeps_insert_first_and_duplicate_guard) {
	HotPlanFixture f(kPlanSql);
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	const auto plan = planner.build(
		"INSERT INTO Vars (name, value) VALUES ('v3', '4'); DELETE FROM Vars WHERE name = 'v0';");
	TH_CHECK(!plan.deletions.deleteFirst);
	TH_CHECK(plan.deletions.dels.at(0).names == std::vector<std::string>{"v0"});
	TH_CHECK((plan.insertions.appends.at(0).second ==
		std::vector<std::vector<std::string>>{{"v3", "4"}}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "硬件变量名 'v0' 重复",
		planner.build("DELETE FROM Vars WHERE name = 'v0';"
			"INSERT INTO Vars (name, value) VALUES ('v0', '4');"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "硬件变量名 'v3' 重复",
		planner.build("INSERT INTO Vars (name, value) VALUES ('v3', '4');"
			"INSERT INTO Vars (name, value) VALUES ('v3', '5');"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "没有任何 CREATE/INSERT/DELETE/DROP/UPDATE 变更",
		planner.build("SELECT * FROM Vars;"));
	/* 解析已在影子上删过行后再出错，也必须保全输入。 */
	TH_CHECK_THROWS(bot::IllegalArgumentException,
		planner.build("DELETE FROM Vars WHERE name = 'v0'; CREATE TABLE Broken (name);"));
}

TH_TEST(hot_sql_plan_rejects_surviving_and_new_references_to_deleted_or_updated_names) {
	for (const auto& [column, value] : std::vector<std::pair<std::string, std::string>>{
			{"controller", "v0"}, {"trigger2", "v0"}, {"src", "$v0"}, {"delay", "$(v0+1)"}}) {
		HotPlanFixture f(std::string(kPlanSql) +
			"CREATE TABLE dummy (name String, " + column + " String);"
			"INSERT INTO dummy (name, " + column + ") VALUES ('dm', '" + value + "');");
		const bot::HotSqlPlanner planner(f.matrices, f.registry);
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "列 '" + column + "'",
			planner.build("DELETE FROM Vars WHERE name = 'v0';"));
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "热删除被拒绝",
			planner.build("UPDATE Vars SET value = '9' WHERE name = 'v0';"));
		const auto both = planner.build("DELETE FROM Vars WHERE name = 'v0'; DELETE FROM dummy;");
		TH_CHECK(both.deletions.dels.size() == 2);
	}
	HotPlanFixture f(kPlanSql);
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "热删除被拒绝",
		planner.build("UPDATE Vars SET name = 'renamed', value = '$v0' WHERE name = 'v0';"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "热删除被拒绝",
		planner.build("DELETE FROM Vars WHERE name = 'v0';"
			"INSERT INTO Vars (name, value) VALUES ('v3', '$(v0+1)');"));
}

TH_TEST(hot_sql_plan_rejects_unsafe_paths_names_and_missing_modules_without_mutation) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f("");
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "不是安全标识符",
		planner.build("CREATE TABLE ../evil (name String);"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "列名 'a=b' 不是安全标识符",
		planner.build("CREATE TABLE Fresh (name String, 'a=b' String);"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "模块路径下找不到它",
		planner.build("CREATE TABLE NoSuchDriver9 (name String);"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "表 'Vars' 已存在",
		planner.build("CREATE TABLE Vars (name String); CREATE TABLE Vars (name String);"));
	for (const std::string chunk : {"/tmp/evil.lua", "../evil.lua", "missing-plan-chunk.lua"}) {
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是模块路径下存在的相对路径",
			planner.build("CREATE TABLE Daemon (name String, chunk String);"
				"INSERT INTO Daemon (name, chunk) VALUES ('d0', '" + chunk + "');"));
		f.checkUnchanged();
	}
}

/* UPDATE 改写守护行同样要过 chunk 判据：改写行的物理事实是「擦原行 + 尾部
 * 追加改后行」，改后行计入 insertedRows 才落进「本批次新增行」校验区间
 * （script_loader.hpp 的记账注释）。钉住这座桥——若 UPDATE 只对擦除侧记账而
 * 漏了追加侧，绝对路径会绕过 INSERT 侧的同一条防线，本用例立即红。 */
TH_TEST(hot_sql_plan_update_daemon_chunk_hits_the_new_row_gate) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f("CREATE TABLE Daemon (name String, chunk String, interval String);\n"
		"INSERT INTO Daemon (name, chunk, interval)\n"
		"VALUES ('z', 'lib/sensor_daemon.lua', '10');\n");
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	for (const std::string evil : {"/tmp/evil.lua", "../evil.lua", "missing-plan-chunk.lua"}) {
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是模块路径下存在的相对路径",
			planner.build("UPDATE Daemon SET chunk = '" + evil + "' WHERE name = 'z';"));
		f.checkUnchanged();
	}
	/* 合法改写照常可计划：改写行计入 updatedRows（先删后建执行序的判据） */
	const auto plan = planner.build("UPDATE Daemon SET interval = '20' WHERE name = 'z';");
	TH_CHECK(plan.mutations.updatedRows.at("Daemon") == 1);
	TH_CHECK(plan.deletions.deleteFirst);
}

TH_TEST(hot_sql_plan_drop_and_new_table_deletion_keep_only_planned_effects) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f("CREATE TABLE Timer (name String);");
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	const auto emptyDrop = planner.build("DROP TABLE Timer;");
	TH_CHECK(emptyDrop.deletions.dels.empty());
	TH_CHECK(emptyDrop.mutations.droppedTables == std::set<std::string>{"Timer"});
	const auto newDeleted = planner.build("CREATE TABLE Vars (name String, value String);"
		"INSERT INTO Vars (name, value) VALUES ('v0', '1'); DELETE FROM Vars;");
	TH_CHECK(newDeleted.deletions.dels.empty());
	TH_CHECK(newDeleted.deletions.newTableDels.size() == 1);
	TH_CHECK(newDeleted.insertions.newTables.at(0).rows() == 1);
	const auto newDropped = planner.build("CREATE TABLE Vars (name String, value String);"
		"INSERT INTO Vars (name, value) VALUES ('v0', '1'); DELETE FROM Vars; DROP TABLE Vars;");
	TH_CHECK(newDropped.insertions.newTables.empty());
	TH_CHECK(newDropped.mutations.droppedTables == std::set<std::string>{"Vars"});
}

TH_TEST(hot_sql_plan_daemon_slots_come_from_declaration_order_without_threads) {
	HotPlanFixture f("CREATE TABLE Daemon (name String, chunk String, proto String);"
		"INSERT INTO Daemon (name, chunk, proto) VALUES ('z', 'lib/sensor_daemon.lua', 'virt');"
		"INSERT INTO Daemon (name, chunk, proto) VALUES ('a', '-', 'virt');");
	const auto plan = bot::HotSqlPlanner(f.matrices, f.registry).build("DELETE FROM Daemon WHERE name = 'a';");
	TH_CHECK(plan.deletions.daemonNameIndex.at("z") == 0);
	TH_CHECK(plan.deletions.daemonNameIndex.at("a") == 1);
	TH_CHECK(plan.deletions.dels.at(0).hw.at(0) == f.registry.find("a"));
	TH_CHECK(plan.deletions.dels.at(0).rows == std::vector<std::size_t>{2});
}

TH_TEST(hot_sql_plan_reuses_single_consumer_precheck_on_merged_structure) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f("CREATE TABLE I2C (name String, path String);"
		"INSERT INTO I2C (name, path) VALUES ('bus', '/dev/i2c-1');"
		"CREATE TABLE MS5611 (name String, I2C String, address String);"
		"INSERT INTO MS5611 (name, I2C, address) VALUES ('baro0', '$bus', '0x77');");
	const bot::HotSqlPlanner planner(f.matrices, f.registry);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "two concurrent consumers",
		planner.build("INSERT INTO MS5611 (name, I2C, address) VALUES ('baro1', '$bus', '119');"));
	const auto plan = planner.build("UPDATE MS5611 SET address = '119' WHERE name = 'baro0';");
	TH_CHECK(plan.deletions.deleteFirst); /* 合并视图必须先擦旧行，否则自己与自己冲突 */
}

TH_TEST(hot_sql_plan_rejects_shared_uart_paths_at_precheck) {
	ModulePathGuard guard("modules:test/cpp");
	HotPlanFixture f("CREATE TABLE UART (name String, path String);"
		"INSERT INTO UART (name, path) VALUES ('u0', '/dev/plan-test-uart');");
	/* P1-3：共享 UART 路径从告警升级为硬拒绝——HotSqlPlanner.build 调用
	 * precheckStructure，后者调 rejectSharedUartPaths，冲突即抛 IllegalArgumentException。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "opened independently by 2 consumers",
		bot::HotSqlPlanner(f.matrices, f.registry).build(
			"INSERT INTO UART (name, path) VALUES ('u1', '/dev/plan-test-uart');"));
}

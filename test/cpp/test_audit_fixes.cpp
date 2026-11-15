/* test_audit_fixes.cpp —— 2026-11-15 审计修复回归
 *
 * 覆盖：
 *   H1：结构表名/守护 chunk 不得越出模块根；
 *   H2：动作预算必须真正中断 Lua busy loop 与 C++ Timer 阻塞；
 *   H3：弃管守护在 RobotStruct 析构后仍可安全调用 HAL；
 *   H4：未知块/游离数据响亮拒绝；
 *   M1/M2/M3/M5/M9/M10：触发作用域、多块合并、地址归一、非有限
 *   timeout、Nns 路径/形状、sources 热删除依赖。
 *
 * 这些用例直接走生产路径（RobotStruct / SqlEngine / MtVars_Daemon / ActionRunner），
 * 不自行拼装内部状态。
 */

#include <chrono>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>

#include "fixtures.hpp"
#include "hal.hpp"
#include "harness.hpp"
#include "native_driver.hpp"
#include "robot.hpp"
#include "robot_fixtures.hpp"
#include "scriptlimit.hpp"
#include "util_except.hpp"

namespace {

/* 只装配一个 Daemon 表，用于验证 chunk 路径在 active() 装配期被拒绝。 */
std::string daemonOnlyStructure(const std::string& chunk) {
	return "CREATE TABLE Daemon (name String, chunk String);\n"
		"INSERT INTO Daemon (name, chunk) VALUES ('d0', '" + chunk + "');\n";
}

} // namespace

TH_TEST(audit_h1_rejects_table_name_path_traversal) {
	const std::string msg = rfx::sqlError(
		"CREATE TABLE \"../../../../../tmp/evil\" (name String);\n"
		"INSERT INTO \"../../../../../tmp/evil\" (name) VALUES ('x');\n");
	TH_CHECK_MSG(msg.find("safe module name") != std::string::npos, msg);
}

TH_TEST(audit_h1_rejects_absolute_daemon_chunk) {
	bot::MemoryReader reader(daemonOnlyStructure("/tmp/evil.lua"));
	bot::RobotStruct robot(reader);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "absolute path", robot.active());
}

TH_TEST(audit_h1_rejects_dotdot_daemon_chunk) {
	bot::MemoryReader reader(daemonOnlyStructure("../evil.lua"));
	bot::RobotStruct robot(reader);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "traverse outside", robot.active());
}

TH_TEST(audit_h2_budget_interrupts_lua_busy_loop) {
	fx::ModulePathGuard paths("./modules:./test/cpp");
	bot::MemoryReader reader(
		"CREATE TABLE InfiniteLoopDriver (name String);\n"
		"INSERT INTO InfiniteLoopDriver (name) VALUES ('loop0');\n");
	bot::RobotStruct robot(reader);
	robot.active();

	bot::LuaExecBudget budget;
	budget.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(120);
	budget.watchStop = true;
	robot.armExecBudget(&budget);
	bot::MemoryReader mt("@Action\nloop0.ping;\n  1;\n@\n");
	const auto started = std::chrono::steady_clock::now();
	TH_CHECK_THROWS_MSG(std::runtime_error, bot::kLuaExecBudgetMarker, robot.run(mt));
	const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - started).count();
	robot.armExecBudget(nullptr);
	robot.deactivate();
	TH_CHECK_MSG(elapsed < 3000, "budget did not interrupt the busy loop in time");
}

TH_TEST(audit_h4_rejects_unknown_action_block) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Action\n"
		"d0.echo;\n"
		"  1;\n"
		"@\n"
		"@Actoin\n"
		"d0.echo;\n"
		"  2;\n"
		"@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Unknown action block", robot.run(mt));
	robot.deactivate();
}

TH_TEST(audit_h4_rejects_top_level_stray_data) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Action\n"
		"d0.echo;\n"
		"  1;\n"
		"@\n"
		"this is stray data that should be rejected\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "top-level data", robot.run(mt));
	robot.deactivate();
}

TH_TEST(audit_h4_rejects_unknown_block_inside_if) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@if(1==1)\n"
		"@Actoin\n"
		"d0.echo;\n"
		"  2;\n"
		"@\n"
		"@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Unknown action block", robot.run(mt));
	robot.deactivate();
}

TH_TEST(audit_m1_trigger_restores_existing_alias) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Alias\n"
		"name alias;\n"
		"x foo;\n"
		"@\n"
		"@Reflex\n"
		"name d0.echo;\n"
		"act $(x);\n"
		"noarg $(x);\n"
		"@\n"
		"@Trigger\n"
		"trigger;\n"
		"act(x=bar);\n"
		"noarg();\n"
		"@\n"
		"@Action\n"
		"d0.echo;\n"
		"  $(x);\n"
		"@\n");
	robot.run(mt);	/* 第二次触发必须还能看到原来的 x=foo */
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Active);
	robot.deactivate();
}

TH_TEST(audit_m2_merges_multiple_reflex_blocks) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Reflex\n"
		"name d0.echo;\n"
		"a $(x);\n"
		"@\n"
		"@Reflex\n"
		"name d0.echo;\n"
		"b $(x);\n"
		"@\n"
		"@Trigger\n"
		"trigger;\n"
		"a(x=1);\n"
		"b(x=2);\n"
		"@\n"
		"@Action\n"
		"d0.echo;\n"
		"  1;\n"
		"@\n");
	robot.run(mt);
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Active);
	robot.deactivate();
}

TH_TEST(audit_m2_merges_multiple_trigger_blocks) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Reflex\n"
		"name d0.echo;\n"
		"a 1;\n"
		"@\n"
		"@Trigger\n"
		"trigger;\n"
		"a();\n"
		"@\n"
		"@Trigger\n"
		"trigger;\n"
		"missing();\n"
		"@\n"
		"@Action\n"
		"d0.echo;\n"
		"  1;\n"
		"@\n");
	/* 第二个 Trigger 块必须被解析到：否则 missing() 被静默忽略。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "未定义的反射", robot.run(mt));
	robot.deactivate();
}

TH_TEST(audit_m1_trigger_rejects_driver_argument) {
	bot::MemoryReader sr(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(sr);
	robot.active();
	bot::MemoryReader mt(
		"@Reflex\n"
		"name d0.echo;\n"
		"a $(x);\n"
		"@\n"
		"@Trigger\n"
		"trigger;\n"
		"a(d0=evil);\n"
		"@\n"
		"@Action\n"
		"d0.echo;\n"
		"  1;\n"
		"@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot replace", robot.run(mt));
	robot.deactivate();
}

TH_TEST(audit_m3_single_consumer_normalizes_float_and_whitespace) {
	fx::TempDir dir("audit_m3_sc");
	std::ofstream out(dir.path() / "FakeSC.lua", std::ios::binary | std::ios::trunc);
	out << "SINGLE_CONSUMER = \"test\"\n"
	       "function build(data) return { result = \"OK\" } end\n"
	       "function call(data) return { result = \"OK\" } end\n"
	       "function destroy(data) return { result = \"OK\" } end\n";
	out.close();
	fx::ModulePathGuard paths("./modules:" + dir.path().string());
	const std::string sql =
		"CREATE TABLE FakeSC (name String, I2C String, address String);\n"
		"INSERT INTO FakeSC (name, I2C, address) VALUES ('a', 'virt-i2c', '0x48');\n"
		"INSERT INTO FakeSC (name, I2C, address) VALUES ('b', 'virt-i2c', '72.0');\n";
	bot::MemoryReader reader(sql);
	bot::RobotStruct robot(reader);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "two concurrent consumers", robot.active());
}

TH_TEST(audit_low_hot_sql_size_limit) {
	bot::MemoryReader reader(
		"CREATE TABLE dummy (name String);\n"
		"INSERT INTO dummy (name) VALUES ('d0');\n");
	bot::RobotStruct robot(reader);
	robot.active();
	const std::string huge((8u << 20) + 1, ' ');
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge, "hot SQL", robot.applySql(huge));
	robot.deactivate();
}

TH_TEST(audit_m8_daemon_read_rejects_non_finite_sample) {
	fx::TempDir dir("audit_m8");
	const std::string chunk = "nan_daemon.lua";
	{
		std::ofstream out(dir.path() / chunk, std::ios::binary | std::ios::trunc);
		/* 自定义 chunk 绕过 P.publish 直接写槽：验证宿主 readSample 的
		 * 最后一道有限性防线（不是只靠 Lua 入口检查）。 */
		out << "local mpath = (__mpath or dofile((os.getenv(\"BOT4CJ_MODULE_PATH\")"
		       " or \"./modules\"):match(\"[^:]+\") .. \"/lib/mpath.lua\"))\n"
		       "local P = dofile(mpath.resolve(\"lib/pthread.lua\"))\n"
		       "local slot = P.slot_attach(DAEMON_SLOT_ADDR)\n"
		       "slot[0].values[0] = 0 / 0\n"
		       "slot[0].nvals = 1\n"
		       "slot[0].count = 1\n"
		       "function daemon_tick() end\n";
	}
	fx::ModulePathGuard paths("./modules:" + dir.path().string());
	bot::MemoryReader reader(
		"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
		"INSERT INTO Daemon (name, chunk, interval) VALUES ('d0', '"
		+ chunk + "', '10');\n");
	bot::RobotStruct robot(reader);
	robot.active();
	bot::MatrixVars_Hardware* daemon = robot.registry().find("d0");
	TH_CHECK(daemon != nullptr);
	/* start() 异步起线程；等 chunk setup 把 NaN 写进槽（setup 只有几行，
	 * 100ms 远大于调度延迟，且 daemon_tick 为空不会覆盖该值）。 */
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	TH_CHECK_THROWS_MSG(std::runtime_error, "non-finite",
		daemon->play(bot::JsonObject()));
	robot.deactivate();
}

#ifdef MYBOT_HAVE_NN4CPP
TH_TEST(audit_m9_nns_hot_absolute_path_rejected) {
	bot::MemoryReader reader(
		"CREATE TABLE Nns (name String, layers String, path String);\n");
	bot::RobotStruct robot(reader);
	robot.active();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "相对路径",
		robot.applySql("INSERT INTO Nns (name, layers, path) VALUES"
			" ('nn', '2,3,1', '/tmp/audit_m9_evil.nn');\n"));
	robot.deactivate();
}

TH_TEST(audit_m9_nns_hot_dotdot_path_rejected) {
	bot::MemoryReader reader(
		"CREATE TABLE Nns (name String, layers String, path String);\n");
	bot::RobotStruct robot(reader);
	robot.active();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "相对路径",
		robot.applySql("INSERT INTO Nns (name, layers, path) VALUES"
			" ('nn', '2,3,1', '../evil.nn');\n"));
	robot.deactivate();
}

TH_TEST(audit_m9_nns_hot_layers_unbounded_rejected) {
	bot::MemoryReader reader(
		"CREATE TABLE Nns (name String, layers String, path String);\n");
	bot::RobotStruct robot(reader);
	robot.active();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeds the limit",
		robot.applySql("INSERT INTO Nns (name, layers, path) VALUES"
			" ('nn', '1000000000,1000000000', '-');\n"));
	robot.deactivate();
}

TH_TEST(audit_m9_nns_hot_relative_path_resolves_under_model_root) {
	fx::TempDir dir("audit_m9_model");
	fx::EnvVar modelDir("BOT4CJ_MODEL_DIR", dir.path().c_str());
	bot::MemoryReader reader(
		"CREATE TABLE Nns (name String, layers String, path String);\n");
	bot::RobotStruct robot(reader);
	robot.active();
	robot.applySql("INSERT INTO Nns (name, layers, path) VALUES"
		" ('nn', '2,3,1', 'nested/model.nn');\n");
	TH_CHECK_MSG(std::filesystem::exists(dir.path() / "nested" / "model.nn"),
		"hot Nns.path was not resolved under BOT4CJ_MODEL_DIR");
	robot.deactivate();
}

TH_TEST(audit_m9_nns_startup_absolute_path_remains) {
	fx::TempDir dir("audit_m9_startup");
	const std::string path = (dir.path() / "model.nn").string();
	bot::MemoryReader reader(
		"CREATE TABLE Nns (name String, layers String, path String);\n"
		"INSERT INTO Nns (name, layers, path) VALUES ('nn', '2,3,1', '"
		+ path + "');\n");
	bot::RobotStruct robot(reader);
	robot.active();
	TH_CHECK_MSG(std::filesystem::exists(path),
		"startup absolute Nns.path compatibility was lost");
	robot.deactivate();
}
#endif // MYBOT_HAVE_NN4CPP

TH_TEST(audit_m10_hot_delete_rejects_sources_peer) {
	bot::MemoryReader reader(
		"CREATE TABLE Daemon (name String, chunk String, interval String, sources String);\n"
		"INSERT INTO Daemon (name, chunk, interval, sources) VALUES "
		"('peer0', 'lib/daemon_probe.lua', '10', '-');\n"
		"INSERT INTO Daemon (name, chunk, interval, sources) VALUES "
		"('agg0', 'lib/sensor_aggregate.lua', '10', 'peer0');\n");
	bot::RobotStruct robot(reader);
	robot.active();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "sources 引用待删守护",
		robot.applySql("DELETE FROM Daemon WHERE name = 'peer0';\n"));
	robot.deactivate();
}

TH_TEST(audit_m10_hot_delete_aggregator_and_peer_together_allowed) {
	bot::MemoryReader reader(
		"CREATE TABLE Daemon (name String, chunk String, interval String, sources String);\n"
		"INSERT INTO Daemon (name, chunk, interval, sources) VALUES "
		"('peer0', 'lib/daemon_probe.lua', '10', '-');\n"
		"INSERT INTO Daemon (name, chunk, interval, sources) VALUES "
		"('agg0', 'lib/sensor_aggregate.lua', '10', 'peer0');\n");
	bot::RobotStruct robot(reader);
	robot.active();
	/* 同批删掉聚合器与 peer：合并视图里没有存活引用方，放行。 */
	robot.applySql("DELETE FROM Daemon WHERE name = 'agg0';\n"
		"DELETE FROM Daemon WHERE name = 'peer0';\n");
	TH_CHECK(robot.lifecycleState() == bot::RobotStruct::LifecycleState::Active);
	robot.deactivate();
}

TH_TEST(audit_m5_native_drivers_reject_non_finite_timeout) {
	bot::HALManager hal;
	for (const char* bad : {"nan", "inf", "-inf", "1e400"}) {
		auto http = bot::makeHttpDriver(hal);
		bot::Json hcfg = bot::JsonObject();
		hcfg.put("base", bot::JsonString("http://127.0.0.1:1"));
		hcfg.put("timeout", bot::JsonString(bad));
		const bot::Json hres = http->build(hcfg);
		TH_CHECK_MSG(hres.find("result") != nullptr
				&& hres.find("result")->getValue() == "ERR",
			std::string("HTTP accepted non-finite timeout: ") + bad);

		auto shell = bot::makeShellDriver(hal);
		bot::Json scfg = bot::JsonObject();
		scfg.put("timeout", bot::JsonString(bad));
		const bot::Json sres = shell->build(scfg);
		TH_CHECK_MSG(sres.find("result") != nullptr
				&& sres.find("result")->getValue() == "ERR",
			std::string("Shell accepted non-finite timeout: ") + bad);
	}
}

TH_TEST(audit_h3_abandoned_daemon_can_use_hal_after_robot_destroy) {
	fx::TempDir dir("audit_h3");
	const std::string chunk = "audit_h3_cleanup.lua";
	{
		std::ofstream out(dir.path() / chunk, std::ios::binary | std::ios::trunc);
		out << "local mpath = (__mpath or dofile((os.getenv(\"BOT4CJ_MODULE_PATH\")"
		       " or \"./modules\"):match(\"[^:]+\") .. \"/lib/mpath.lua\"))\n"
		       "local HAL = dofile(mpath.resolve(\"lib/HAL.lua\"))\n"
		       "local ffi = require(\"ffi\")\n"
		       "ffi.cdef(\"int usleep(unsigned int usec);\")\n"
		       "function daemon_tick() ffi.C.usleep(2500000) end\n"
		       "function daemon_cleanup()\n"
		       "  HAL.sys.usleep(1000)\n"
		       "  state_write(\"audit_h3_marker\", {1, 2, 3})\n"
		       "end\n";
	}
	fx::ModulePathGuard paths("./modules:" + dir.path().string());
	fx::EnvVar stateDir("BOT4CJ_STATE_DIR", dir.path().c_str());
	{
		bot::MemoryReader reader(
			"CREATE TABLE Daemon (name String, chunk String, interval String);\n"
			"INSERT INTO Daemon (name, chunk, interval) VALUES ('d0', '"
			+ chunk + "', '1');\n");
		bot::RobotStruct robot(reader);
		robot.setDeactivateGraceMs(0);
		robot.active();
		/* 让守护线程先进入 daemon_tick 的 2.5s usleep；否则可能
		 * stop 在首拍之前到达，测试走不到“弃管后 cleanup”路径。 */
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
		robot.deactivate();
	}	/* RobotStruct/HAL 已析构；弃管守护线程此时仍可能在 tick 内 */
	std::this_thread::sleep_for(std::chrono::milliseconds(3200));
	std::ifstream marker(dir.path() / "audit_h3_marker", std::ios::binary);
	TH_CHECK_MSG(static_cast<bool>(marker),
		"abandoned daemon cleanup could not use HAL after RobotStruct destruction");
}

TH_TEST(audit_h2_budget_interrupts_timer_sleep) {
	bot::MemoryReader reader(rfx::kBasicSql);
	bot::RobotStruct robot(reader);
	robot.active();

	bot::LuaExecBudget budget;
	budget.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(120);
	budget.watchStop = true;
	robot.armExecBudget(&budget);
	bot::MemoryReader mt("@Action\ntimer-0.delay;\n  1000;\n@\n");
	const auto started = std::chrono::steady_clock::now();
	TH_CHECK_THROWS_MSG(std::runtime_error, bot::kLuaExecBudgetMarker, robot.run(mt));
	const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - started).count();
	robot.armExecBudget(nullptr);
	robot.deactivate();
	TH_CHECK_MSG(elapsed < 800, "Timer slept past the action budget");
}

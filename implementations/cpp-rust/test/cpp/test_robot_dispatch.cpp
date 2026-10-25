/* test_robot_dispatch.cpp —— 运行期注册表与动作派发域
 *
 * 自 test_robot.cpp 拆出（2026-10-01，行为保持）：HwRegistry 单一注册表、
 * @Action 设备列别名解析、$(...) 类型分派、@Reflex 条件反射四段；
 * 同域局部 helper（aliasHw/varsHw/captureHw/runSwallow/runCapture）随迁。
 * 2026-10-04：注册表那一段（三条 hw_registry_* 用例）迁至 test_hw_registry.cpp，
 * 与热插事务/热删除撤销/会话覆盖层的直接单测同住；dummyHw 上收为 fx::dummyHw。
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
#include "action_runner.hpp"
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
using rfx::kBasicSql;
using rfx::probeSql;
using rfx::runTexts;

/* HwRegistry 单一注册表的用例（原在本文件首段）已于 2026-10-04 迁至
 * test/cpp/test_hw_registry.cpp——注册表门面在那边与热插事务/热删除撤销的
 * 直接单测同住一处；dummyHw 随之上收为 fx::dummyHw。 */

/* ---- @Action 设备列别名解析（2026-09-19 设计评估；解析单点白盒锚定）---- */

/* 构造 @Alias 对象（一行 name/value 的别名矩阵，行 1 = 数据行） */
static std::unique_ptr<bot::MtVars_Alias> aliasHw(const std::string& name,
	const std::string& target) {
	std::string text = "@Alias\nname  alias;\n   " + name + "  " + target + ";\n@\n";
	return bot::MtVars_Alias::Factory(fx::oneMatrix(text), 1);
}

TH_TEST(action_device_alias_resolves_to_driver) {
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw(), "");
	reg.add("leg", aliasHw("leg", "dev1"), "");
	/* 别名 → 目标名；非标量真名原样；未知名原样（派发期保留行号上下文报错） */
	TH_CHECK(bot::ActionRunner::resolveActionDevice(reg, "leg") == "dev1");
	TH_CHECK(bot::ActionRunner::resolveActionDevice(reg, "dev1") == "dev1");
	TH_CHECK(bot::ActionRunner::resolveActionDevice(reg, "ghost") == "ghost");
}

TH_TEST(action_device_alias_to_missing_target_throws) {
	bot::HwRegistry reg;
	reg.add("leg", aliasHw("leg", "ghost"), "");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "resolves via @Alias to 'ghost'",
		(void)bot::ActionRunner::resolveActionDevice(reg, "leg"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not a defined hardware variable",
		(void)bot::ActionRunner::resolveActionDevice(reg, "leg"));
}

TH_TEST(action_device_alias_to_another_alias_throws) {
	/* 一层为止：别名指向别名在解析点即报错，不做链式穿透 */
	bot::HwRegistry reg;
	reg.add("leg2", aliasHw("leg2", "dev1"), "");
	reg.add("leg", aliasHw("leg", "leg2"), "");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is itself a scalar",
		(void)bot::ActionRunner::resolveActionDevice(reg, "leg"));
}

TH_TEST(action_device_vars_rejected) {
	/* @Vars 是数值常量，永远不能命名设备——显式拒绝而非落到 not defined */
	bot::HwRegistry reg;
	reg.add("v", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   v  35;\n@\n"), 1,
		[](const std::string&) { return 0.0; }), "");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is a numeric constant and cannot name a device",
		(void)bot::ActionRunner::resolveActionDevice(reg, "v"));
}

TH_TEST(action_dispatch_through_alias_device) {
	/* 派发端到端（桩驱动）：设备列 leg（别名 → dev1）的参数落到 dev1 的一次 play */
	bot::HwRegistry reg;
	bot::Json played;
	reg.add("dev1", std::make_unique<fx::LambdaHw>(
		[&played](const bot::Json& in) {
			played = in;
			auto o = bot::JsonObject();
			o.put("result", bot::JsonString("OK"));
			return o;
		}), "");
	reg.add("leg", aliasHw("leg", "dev1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nleg.test;\n  200;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(played.isObj());
	TH_CHECK(played.get("test").has_value() && played.get("test")->getFloat() == 200.0);
}

TH_TEST(action_dispatch_allows_same_device_different_params) {
	/* 同一设备两个参数列（别名列 + 真名列都解析到 dev1）合并为一次 play：
	 * 查重键是 (设备, 参数)，同设备不同参数是合法的一拍多参 */
	bot::HwRegistry reg;
	bot::Json played;
	int plays = 0;
	reg.add("dev1", std::make_unique<fx::LambdaHw>(
		[&played, &plays](const bot::Json& in) {
			played = in;
			++plays;
			auto o = bot::JsonObject();
			o.put("result", bot::JsonString("OK"));
			return o;
		}), "");
	reg.add("leg", aliasHw("leg", "dev1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nleg.test  dev1.note;\n  200      7;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(plays == 1);
	TH_CHECK(played.get("test").has_value() && played.get("test")->getFloat() == 200.0);
	TH_CHECK(played.get("note").has_value() && played.get("note")->getFloat() == 7.0);
}

TH_TEST(action_dispatch_rejects_duplicate_resolved_param) {
	/* 撞设备第二层防线：不同列头（别名 + 真名）解析出同一 (设备, 参数)
	 * ——归并期文本查重不可见，派发前必须显式报错，不得逐行静默覆盖 */
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw(), "");
	reg.add("leg", aliasHw("leg", "dev1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nleg.test  dev1.test;\n  200      300;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "already targeted by column",
		bot::ActionRunner(reg).runAction(mats));
}

/* ---- $(...) 类型分派：别名入式与文本拼接（2026-09-20 设计评估）----
 * 运算/拼接只发生在 $(...) 之内；'+' 出现文本操作数即拼接（数值真值
 * formatNumber 参与），全数值仍是算术。求值都在派发期。 */

/* 构造 @Vars 对象（字面量值；resolver 仅 $(...) 值需要，测试不用表达式值） */
static std::unique_ptr<bot::MtVars_Vars> varsHw(const std::string& name,
	const std::string& value) {
	return bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   " + name + "  " + value + ";\n@\n"), 1,
		[](const std::string&) { return 0.0; });
}

/* 捕获 play 入参的桩驱动（OK 契约），返回登记好的指针引用 */
static std::unique_ptr<bot::MatrixVars_Hardware> captureHw(bot::Json& played) {
	return std::make_unique<fx::LambdaHw>([&played](const bot::Json& in) {
		played = in;
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	});
}

TH_TEST(action_device_expr_concat_lands_on_resolved_device) {
	/* 设备位 $(pfx+n)：别名值 "relay-" + 数值真值 "2" 拼出 "relay-2"，
	 * 派发落在该名字命名的驱动上 */
	bot::HwRegistry reg;
	bot::Json played;
	reg.add("relay-2", captureHw(played), "");
	reg.add("pfx", aliasHw("pfx", "relay-"), "");
	reg.add("n", varsHw("n", "2"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\n$(pfx+n).test;\n  200;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(played.isObj());
	TH_CHECK(played.get("test").has_value() && played.get("test")->getFloat() == 200.0);
}

TH_TEST(action_device_expr_product_resolves_like_bare_name) {
	/* $(p) ≡ p：产物命中别名走与裸名相同的解析（一层为止规则的对称面）；
	 * 产物是别名名 → 再解一层到驱动（eval 已解引用一次，产物按裸名规则） */
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw(), "");
	reg.add("p", aliasHw("p", "dev1"), "");
	TH_CHECK(bot::ActionRunner::resolveActionDevice(reg, "$(p)") == "dev1");
	reg.add("x", aliasHw("x", "leg"), "");
	reg.add("leg", aliasHw("leg", "dev1"), "");
	TH_CHECK(bot::ActionRunner::resolveActionDevice(reg, "$(x)") == "dev1");
}

TH_TEST(action_device_expr_product_naming_vars_rejected) {
	/* 产物命中 @Vars → 与裸名同样的显式拒绝（数值常量不能命名设备） */
	bot::HwRegistry reg;
	reg.add("v", varsHw("v", "35"), "");
	reg.add("q", aliasHw("q", "v"), "");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is a numeric constant and cannot name a device",
		(void)bot::ActionRunner::resolveActionDevice(reg, "$(q)"));
}

TH_TEST(action_device_expr_rejects_driver_and_undefined_reference) {
	/* 表达式里引用驱动/守护名：名字是拿来做算术/拼接的，不是拿来做播放的；
	 * 未定义名沿用既有文案 */
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw(), "");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "driver/daemon variable; only @Alias/@Vars may appear in an expression",
		(void)bot::ActionRunner::resolveActionDevice(reg, "$(dev1)"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not a defined hardware variable",
		(void)bot::ActionRunner::resolveActionDevice(reg, "$(ghost)"));
}

TH_TEST(action_param_expr_product_is_param_name) {
	/* 参数位 $(...)：产物即参数名（不再解析）；裸名不命中保持原文。
	 * $(...) 内标识符是严格引用（未定义即抛）——拼接文本只能来自别名。 */
	bot::HwRegistry reg;
	reg.add("p", aliasHw("p", "note"), "");
	TH_CHECK(bot::ActionRunner::resolveActionParam(reg, "$(p)") == "note");
	reg.add("a1", aliasHw("a1", "no"), "");
	reg.add("a2", aliasHw("a2", "te"), "");
	TH_CHECK(bot::ActionRunner::resolveActionParam(reg, "$(a1+a2)") == "note");
	TH_CHECK(bot::ActionRunner::resolveActionParam(reg, "note") == "note");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not a defined hardware variable",
		(void)bot::ActionRunner::resolveActionParam(reg, "$(t+est)"));
}

TH_TEST(action_cell_text_param_via_concat) {
	/* 数据格拼接：$(g+n) 产物是文本 → 文本参数（JsonString），与 SQL 元数据
	 * 列同型；数值格不受影响 */
	bot::HwRegistry reg;
	bot::Json played;
	reg.add("dev1", captureHw(played), "");
	reg.add("g", aliasHw("g", "hello-"), "");
	reg.add("n", varsHw("n", "2"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev1.note;\n  $(g+n);\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(played.get("note").has_value() && played.get("note")->isStr());
	TH_CHECK(played.get("note")->getValue() == "hello-2");
}

TH_TEST(action_cell_numeric_expr_unchanged) {
	/* 全数值表达式仍是算术（拼接只出现在文本参与时）——既有行为钉 */
	bot::HwRegistry reg;
	bot::Json played;
	reg.add("dev1", captureHw(played), "");
	reg.add("n", varsHw("n", "2"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev1.test;\n  $(n*100);\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(played.get("test").has_value() && played.get("test")->getFloat() == 200.0);
}

TH_TEST(action_dispatch_rejects_expr_param_colliding_with_bare) {
	/* 查重键是解析后 (设备, 参数)：$(...) 拼出的参数名与裸名同键也必须抓
	 * （归并期文本查重不可见，不得逐行静默覆盖） */
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw(), "");
	reg.add("p", aliasHw("p", "note"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev1.$(p)  dev1.note;\n  200      300;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "already targeted by column",
		bot::ActionRunner(reg).runAction(mats));
}

/* ==================== 会话变量作用域（2026-09-20 重构阶段 0/1）====================
 * 缺陷实证（本组三条用例在修复前全部为红）：
 *   动作脚本内联的 @Alias/@Vars 经 HwRegistry::override 注册后**永不回收**——
 *     ① 跨 run() 残留（agent 长驻模式下无界增长，且脚本 A 的别名对脚本 B 可见）；
 *     ② 与结构变量同名时**永久遮蔽**结构定义，直到进程退出；
 *     ③ 注册发生在派发之前（RobotStruct::run 先注册后 runAction），
 *        于是一个连 @Action 都没有、以报错收场的脚本也已完成注册表改写。
 * 契约（修复后）：会话别名的作用域 = 单次 run()；run() 出口（含异常路径）完全回滚，
 * 结构视图与销毁序一字不动，byName() 结构清单不增长。
 */

/* 跑一遍动作脚本并吞掉异常：本组关心「注册表副作用」，不是派发结果
 * （没有 active() 时派发必然因设备未注册而失败，注册却已完成） */
static void runSwallow(bot::RobotStruct& robot, const std::string& mt) {
	try { bot::MemoryReader mr(mt); robot.run(mr); } catch (const std::exception&) {}
}

/* 跑一遍动作脚本并返回报错文本（无异常返回空串） */
static std::string runCapture(bot::RobotStruct& robot, const std::string& mt) {
	try {
		bot::MemoryReader mr(mt);
		robot.run(mr);
	} catch (const std::exception& e) {
		return std::string(e.what());
	}
	return std::string();
}

TH_TEST(session_alias_does_not_survive_a_run) {
	bot::MemoryReader sr(kBasicSql);
	bot::RobotStruct robot(sr);
	const std::size_t namesBefore = robot.registry().byName().size();
	TH_CHECK(!robot.registry().contains("ghost"));

	runSwallow(robot, "@Alias\nname  alias;\n ghost timer-0;\n@\n\n@Action\nghost.delay;\n 1;\n@\n");

	/* 会话结束：别名不再可见，结构名字索引一个不增 */
	TH_CHECK(!robot.registry().contains("ghost"));
	TH_CHECK(robot.registry().find("ghost") == nullptr);
	TH_CHECK(robot.registry().byName().size() == namesBefore);
}

TH_TEST(session_alias_does_not_shadow_structure_variable) {
	bot::MemoryReader sr(kBasicSql);
	bot::RobotStruct robot(sr);
	robot.active();
	auto* before = robot.registry().find("relay0");
	TH_CHECK(before != nullptr && std::string(before->kindName()) == "lua");

	/* 会话内把 relay0 别名为 timer-0（旧实现：结构定义被永久改写） */
	runSwallow(robot, "@Alias\nname  alias;\n relay0 timer-0;\n@\n");

	auto* after = robot.registry().find("relay0");
	TH_CHECK(after != nullptr);
	TH_CHECK(after == before);
	TH_CHECK(std::string(after->kindName()) == "lua");
	robot.deactivate();
}

TH_TEST(failed_action_script_does_not_mutate_registry) {
	bot::MemoryReader sr(kBasicSql);
	bot::RobotStruct robot(sr);
	const std::size_t namesBefore = robot.registry().byName().size();

	/* 有 @Alias、没有 @Action：注册先于派发，旧实现在这里已经改写了注册表 */
	std::string err = runCapture(robot, "@Alias\nname  alias;\n ghost timer-0;\n@\n");
	TH_CHECK(err.find("No @Action matrix found") != std::string::npos);

	TH_CHECK(!robot.registry().contains("ghost"));
	TH_CHECK(robot.registry().byName().size() == namesBefore);
}

TH_TEST(session_repeated_runs_do_not_grow_the_registry) {
	/* agent 长驻模式的等价形态：同一 RobotStruct 反复 run()。
	 * byName() 结构清单规模必须恒定（旧实现每个新别名名字都留一份）。 */
	bot::MemoryReader sr(kBasicSql);
	bot::RobotStruct robot(sr);
	const std::size_t namesBefore = robot.registry().byName().size();
	/* 200 轮；名字带序号，旧实现会留 200 份 */
	for (int i = 0; i < 200; ++i) {
		runSwallow(robot, "@Alias\nname  alias;\n ghost" + std::to_string(i)
			+ " timer-0;\n@\n");
	}
	TH_CHECK(robot.registry().byName().size() == namesBefore);
	TH_CHECK(!robot.registry().contains("ghost0"));
	TH_CHECK(!robot.registry().contains("ghost199"));
}

/* ---- #34 条件反射（@Reflex 动作序列 + @Trigger 触发 + 临时变量绑定）----
 * 反射动作行里的 $(临时变量) 经 makeActionExprResolver 命中触发绑定的会话
 * @Alias；不绑定即报「expression references '<名>'」——成功/失败路径用
 * 同一断言锚定绑定是否生效。kBasicSql 的 relay0 是纯数据行（非硬件变量），
 * 派发期报 not defined，恰好作为「绑定已生效、走到派发」的观察点。 */
TH_TEST(robot_reflex_without_trigger_is_lazy) {
	/* @Reflex 引用未绑定变量，无 @Trigger → 反射定义惰性存在，不执行不校验 */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink $(undef);\n@\n");
	TH_CHECK(msg.empty());
}

TH_TEST(robot_reflex_trigger_binds_temporary_and_dispatches) {
	/* 绑定 bright=1 后 $(bright) 可解析 → 走到派发（relay0 非硬件变量报错） */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink $(bright);\n@\n"
		"@Trigger\ntrigger;\nblink(bright=1);\n@\n");
	TH_CHECK(msg.find("relay0") != std::string::npos);
	TH_CHECK(msg.find("not defined") != std::string::npos);
}

TH_TEST(robot_reflex_unbound_temporary_reports) {
	/* 触发没绑定 bright → $(bright) 解析失败，报表达式未定义（不落到派发） */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink $(bright);\n@\n"
		"@Trigger\ntrigger;\nblink(angle=1);\n@\n");
	TH_CHECK(msg.find("bright") != std::string::npos);
}

TH_TEST(robot_reflex_undefined_reflex_reports) {
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink 1;\n@\n"
		"@Trigger\ntrigger;\nzzz(bright=1);\n@\n");
	TH_CHECK(msg.find("未定义的反射 'zzz'") != std::string::npos);
}

TH_TEST(robot_reflex_bad_arg_syntax_reports) {
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink 1;\n@\n"
		"@Trigger\ntrigger;\nblink(bright);\n@\n");
	TH_CHECK(msg.find("k=v") != std::string::npos);
}

TH_TEST(robot_reflex_duplicate_arg_reports) {
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Reflex\nname relay0.deg;\nblink 1;\n@\n"
		"@Trigger\ntrigger;\nblink(bright=1,bright=2);\n@\n");
	TH_CHECK(msg.find("重复绑定参数 'bright'") != std::string::npos);
}

TH_TEST(robot_reflex_trigger_without_reflex_reports) {
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n@\n"
		"@Trigger\ntrigger;\nblink(bright=1);\n@\n");
	TH_CHECK(msg.find("@Reflex") != std::string::npos);
}

TH_TEST(robot_reflex_scope_does_not_leak) {
	/* 两次触发同一 run：第一次绑 bright（动作引用它，成功走完派发）；第二次
	 * 只绑 angle → $(bright) 未绑定报错 —— 证明第一次的绑定在触发后已撤销
	 * （子作用域不泄漏），也证明触发是逐行独立的。探针驱动 p0 可真实 play。 */
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("reflex-scope");
	const fs::path marker = tmp.path() / "destroyed";
	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();	/* p0 探针上电注册：派发 play 需要真硬件变量在注册表 */
	bot::MemoryReader mr(
		"@Action\np0.probe;\n@\n"
		"@Reflex\nname p0.probe;\nblink $(bright);\n@\n"
		"@Trigger\ntrigger;\nblink(bright=1);\nblink(angle=1);\n@\n");
	try {
		robot.run(mr);
		TH_CHECK(false && "第二次触发应报未绑定 bright");
	} catch (const std::exception& e) {
		TH_CHECK(std::string(e.what()).find("bright") != std::string::npos);
	}
	robot.deactivate();
}

/* ---- #34 条件反射的工具侧入口：run(reader, injectVars) 调用时注入会话别名 ----
 * 与 @Trigger 的 `name(k=v)` 走同一条 override → 表达式解析路径，只是实参来自
 * 调用方（run_action_script 的 vars）而非脚本内的 @Trigger 行。断言锚点沿用反射
 * 那套：kBasicSql 的 relay0/relay9 是纯数据行（非硬件变量），$(名) 解析成功后
 * 走到派发才报 "<名> not defined"——故「报到哪个设备名」既证明绑定生效、又证明
 * 解析到的值。 */

TH_TEST(robot_inject_vars_binds_dollar_ref) {
	/* 注入 deg=1 → $(deg) 解析成功 → 走到派发（relay0 非硬件变量报 not defined） */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n  $(deg);\n@\n",
		{{"deg", "1"}});
	TH_CHECK(msg.find("relay0") != std::string::npos);
	TH_CHECK(msg.find("not defined") != std::string::npos);
}

TH_TEST(robot_inject_vars_unbound_reports) {
	/* 不注入 → $(deg) 无从解析，报表达式引用未定义（不落到派发） */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n  $(deg);\n@\n");
	TH_CHECK(msg.find("deg") != std::string::npos);
	TH_CHECK(msg.find("not defined") == std::string::npos);
}

TH_TEST(robot_inject_vars_override_inline_alias) {
	/* 调用方实参覆盖脚本内联 @Alias 默认值（函数实参优先于形参默认）。
	 * 内联把 who 别名指向 relay9；注入 who=relay0 应把它改绑到 relay0——
	 * 设备位 $(who) 求值产物即派发目标，故报错点名的设备直接暴露谁生效。 */
	const std::string mt =
		"@Alias\nname alias;\nwho relay9;\n@\n"
		"@Action\n$(who).deg;\n  1;\n@\n";
	const std::string inlineOnly = runTexts(kBasicSql, mt);
	TH_CHECK(inlineOnly.find("relay9") != std::string::npos);	/* 无注入：内联默认生效 */

	const std::string injected = runTexts(kBasicSql, mt, {{"who", "relay0"}});
	TH_CHECK(injected.find("relay0") != std::string::npos);		/* 注入：实参覆盖默认 */
	TH_CHECK(injected.find("relay9") == std::string::npos);
}

TH_TEST(robot_inject_vars_rejects_unsafe_name) {
	/* 键不是安全标识符（含点）→ 拒绝，不落派发 */
	const std::string msg = runTexts(kBasicSql,
		"@Action\nrelay0.deg;\n  1;\n@\n",
		{{"a.b", "1"}});
	TH_CHECK(msg.find("安全标识符") != std::string::npos);
}

TH_TEST(robot_inject_vars_scope_does_not_leak) {
	/* 同一 RobotStruct 连跑两次：第一次注入 deg（p0 探针可真实 play，$(deg) 解析
	 * 成功、run 不抛）；第二次不注入 → $(deg) 未绑定报错，证明注入随 run() 的
	 * SessionScope 回滚、绝不跨 run() 残留。 */
	ModulePathGuard guard("modules:test/cpp");
	TempDir tmp("inject-scope");
	const fs::path marker = tmp.path() / "destroyed";
	bot::MemoryReader sr(probeSql(marker));
	bot::RobotStruct robot(sr);
	robot.active();	/* p0 探针上电注册：派发 play 需要真硬件变量在注册表 */

	bot::MemoryReader mr1("@Action\np0.probe;\n  $(deg);\n@\n");
	try {
		robot.run(mr1, {{"deg", "1"}});
	} catch (const std::exception& e) {
		TH_CHECK(false && "首次注入 deg 应成功走完派发");
		(void)e;
	}

	bot::MemoryReader mr2("@Action\np0.probe;\n  $(deg);\n@\n");
	try {
		robot.run(mr2);
		TH_CHECK(false && "第二次不注入应报未绑定 deg");
	} catch (const std::exception& e) {
		TH_CHECK(std::string(e.what()).find("deg") != std::string::npos);
	}
	robot.deactivate();
}


/* test_action_while.cpp —— @while(条件) 循环块
 *
 * 覆盖：块头解析单点白盒（parseWhileBlockName，含「if 不是 while」）、循环执行
 * （捕获格推进 @Vars → 条件转假退出 / 首次即假零迭代 / 与 @Action 按书写顺序交错 /
 * Ctrl-C 经 stopRequested 及时跳出）、报错契约（非布尔条件 / 未定义标识符 / 裸 @while /
 * 未闭合）与 @Reflex 共存。夹具形态与 test_action_if.cpp 同源（LambdaHw 桩 + rfx::runTexts）。
 */
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "action_runner.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_env.hpp"		/* stopRequested（Ctrl-C 用例） */
#include "util_except.hpp"
#include "robot_fixtures.hpp"

using rfx::runTexts;

namespace {

/* stderr 捕获：循环退出/零迭代注记也是契约（对齐 test_action_if 形态） */
struct CerrCapture {
	std::ostringstream buf;
	std::streambuf* old;
	CerrCapture() : old(std::cerr.rdbuf(buf.rdbuf())) {}
	~CerrCapture() { std::cerr.rdbuf(old); }
	CerrCapture(const CerrCapture&) = delete;
	CerrCapture& operator=(const CerrCapture&) = delete;
	bool contains(const std::string& sub) const {
		return buf.str().find(sub) != std::string::npos;
	}
};

std::unique_ptr<bot::MtVars_Alias> aliasHw(const std::string& name,
	const std::string& target) {
	std::string text = "@Alias\nname  alias;\n   " + name + "  " + target + ";\n@\n";
	return bot::MtVars_Alias::Factory(fx::oneMatrix(text), 1);
}

std::unique_ptr<bot::MtVars_Vars> varsHw(const std::string& name,
	const std::string& value) {
	return bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   " + name + "  " + value + ";\n@\n"), 1,
		[](const std::string&) { return 0.0; });
}

/* 序列桩：记录每次 play 的设备名（执行顺序的可观测证据） */
std::unique_ptr<bot::MatrixVars_Hardware> traceHw(const std::string& name,
	std::vector<std::string>& trace) {
	return std::make_unique<fx::LambdaHw>([name, &trace](const bot::Json&) {
		trace.push_back(name);
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	});
}

/* 计数桩：每次 play 返回递增的 reading 字段（供捕获格推进 @Vars，驱动循环收敛） */
std::unique_ptr<bot::MatrixVars_Hardware> counterHw(const std::string& name, int& plays) {
	return std::make_unique<fx::LambdaHw>([name, &plays](const bot::Json&) {
		++plays;
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("reading", bot::JsonInt(plays));
		return o;
	});
}

/* stopRequested 是进程级全局：用例内改它必须成对复位，否则污染后续用例。 */
struct StopGuard {
	StopGuard() { bot::stopRequested().store(false); }
	~StopGuard() { bot::stopRequested().store(false); }
	StopGuard(const StopGuard&) = delete;
	StopGuard& operator=(const StopGuard&) = delete;
};

} // namespace

/* ---------------- 块头解析单点白盒 ---------------- */

TH_TEST(action_while_parse_block_name) {
	/* 命中：返回 trim 后的条件体 */
	TH_CHECK(bot::ActionRunner::parseWhileBlockName("while(k>0)") == std::optional<std::string>("k>0"));
	TH_CHECK(bot::ActionRunner::parseWhileBlockName(" while(k>0&&m<1) ") == std::optional<std::string>("k>0&&m<1"));
	/* 非 while 块：nullopt（含同前缀 "whilex(a)"，与 "if(...)"——if 不是 while） */
	TH_CHECK(!bot::ActionRunner::parseWhileBlockName("Action").has_value());
	TH_CHECK(!bot::ActionRunner::parseWhileBlockName("whilex(a)").has_value());
	TH_CHECK(!bot::ActionRunner::parseWhileBlockName("if(k>0)").has_value());
	TH_CHECK(!bot::ActionRunner::parseWhileBlockName("Trigger").has_value());
	/* 意图明显的坏形态：响亮救红，不静默当未知块丢弃 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "@while 块缺条件表达式",
		(void)bot::ActionRunner::parseWhileBlockName("while"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "未在块头内闭合",
		(void)bot::ActionRunner::parseWhileBlockName("while(k>0"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "条件为空",
		(void)bot::ActionRunner::parseWhileBlockName("while()"));
}

/* ---------------- 循环执行编排 ---------------- */

TH_TEST(action_while_loops_until_capture_flips_condition) {
	/* 核心：条件真则反复派发，块体内捕获格 $count=reading 每轮把计数写进 @Vars，
	 * 到 count<3 转假退出——共 3 轮、dev 被 play 3 次（while 而非 do-while：
	 * 首次即假则零派发）。 */
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("dev", counterHw("dev", plays), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<3)\ndev.reading;\n $count=reading;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(plays == 3);
		TH_CHECK(cerr.contains("[while] condition became false"));
		TH_CHECK(cerr.contains("3 iteration(s)"));
	}
}

TH_TEST(action_while_condition_false_first_zero_iterations) {
	/* 首次判条件即假：零派发 + 注记可见（while 语义，不是 do-while） */
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("dev", counterHw("dev", plays), "");
	reg.add("count", varsHw("count", "5"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<3)\ndev.reading;\n $count=reading;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(plays == 0);
		TH_CHECK(cerr.contains("[while] condition not met"));
		TH_CHECK(cerr.contains("'count<3'"));
		TH_CHECK(cerr.contains("0 iterations"));
	}
}

TH_TEST(action_while_interleaves_with_action_in_written_order) {
	/* 书写顺序交错：@Action → @while（两轮 b）→ @Action，trace 如实反映 */
	bot::HwRegistry reg;
	std::vector<std::string> trace;
	int bplays = 0;
	reg.add("a", traceHw("a", trace), "");
	reg.add("count", varsHw("count", "0"), "");
	/* b 用一个既计数又记序的桩：每轮 play 追加 trace 并返回递增 reading */
	reg.add("b", std::make_unique<fx::LambdaHw>([&bplays, &trace](const bot::Json&) {
		++bplays;
		trace.push_back("b");
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("reading", bot::JsonInt(bplays));
		return o;
	}), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\na.p;\n 1;\n@\n"
		"@while(count<2)\nb.reading;\n $count=reading;\n@\n"
		"@Action\na.p;\n 1;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK((trace == std::vector<std::string>{"a", "b", "b", "a"}));
}

TH_TEST(action_while_stop_requested_breaks_loop) {
	/* Ctrl-C：静态真条件（count<1000，捕获推进很慢）下，play 到第 2 次置 stop，
	 * 下一轮循环顶部的 stopRequested 检查及时跳出——不因无迭代上限而失控。 */
	StopGuard guard;
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("dev", std::make_unique<fx::LambdaHw>([&plays](const bot::Json&) {
		++plays;
		if (plays >= 2) { bot::stopRequested().store(true); }
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("reading", bot::JsonInt(plays));
		return o;
	}), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<1000)\ndev.reading;\n $count=reading;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(plays == 2);
		TH_CHECK(cerr.contains("[while] stop requested"));
	}
}

/* ---------------- 报错契约 ---------------- */

TH_TEST(action_while_bad_condition_reports_loudly) {
	/* 非布尔条件（@Vars 裸值）：无隐式真值，显式拒绝 */
	bot::HwRegistry reg;
	reg.add("leg", fx::dummyHw(), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(k)\nleg.p;\n 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是逻辑表达式",
		bot::ActionRunner(reg).runAction(mats));
	/* 文本条件同理（@Alias 裸值） */
	reg.add("mode", aliasHw("mode", "auto"), "");
	std::vector<mt::MatrixObject> mats2 = fx::manyMatrices(
		"@while(mode)\nleg.p;\n 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是逻辑表达式",
		bot::ActionRunner(reg).runAction(mats2));
	/* 未定义标识符：resolver 报错文案直达（runTexts 级未 active 的注册表即观察窗） */
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@while(ghost>0)\nrelay0.deg;\n 90;\n@\n").find("not a defined hardware variable") != std::string::npos);
	/* 裸 @while / 未闭合：块头解析单点报错（块头错先于条件求值） */
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@while\nrelay0.deg;\n 90;\n@\n").find("@while 块缺条件表达式") != std::string::npos);
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@while(k>0\nrelay0.deg;\n 90;\n@\n").find("未在块头内闭合") != std::string::npos);
}

TH_TEST(action_while_coexists_with_reflex) {
	/* @while 与 #34 @Reflex/@Trigger 共存：while 块照常循环派发，反射照常触发
	 * （run() 固定序 = runAction 先、runReflex 后，此处同序复现） */
	bot::HwRegistry reg;
	std::vector<std::string> trace;
	int aplays = 0;
	reg.add("a", std::make_unique<fx::LambdaHw>([&aplays, &trace](const bot::Json&) {
		++aplays;
		trace.push_back("a");
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("reading", bot::JsonInt(aplays));
		return o;
	}), "");
	reg.add("b", traceHw("b", trace), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<2)\na.reading;\n $count=reading;\n@\n"
		"@Reflex\nname b.p;\n blink 1;\n@\n"
		"@Trigger\ntrigger;\n blink;\n@\n");
	bot::ActionRunner runner(reg);
	runner.runAction(mats);
	runner.runReflex(mats);
	TH_CHECK((trace == std::vector<std::string>{"a", "a", "b"}));
}

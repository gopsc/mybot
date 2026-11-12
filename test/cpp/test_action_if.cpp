/* test_action_if.cpp —— @if(条件) 条件块（2026-10-10 特性）
 *
 * 覆盖四层：块头解析单点白盒（parseIfBlockName）、条件求值（@Vars 数值 /
 * @Alias 文本 == 字符串字面量）、执行编排（成立派发 / 不成立跳过 + stderr
 * 注记 / 与 @Action 按书写顺序交错）、报错契约（裸名 / 未闭合 / 非布尔
 * 条件 / 未定义标识符 / 布尔入 @Action 单元格）与 @Reflex 共存。
 * 夹具形态与 test_robot_dispatch.cpp 同源（LambdaHw 桩 + rfx::runTexts）。
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
#include "util_except.hpp"
#include "robot_fixtures.hpp"

using rfx::runTexts;

namespace {

/* stderr 捕获：条件不成立的跳过注记也是契约（对齐 test_mtinclude 形态） */
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

} // namespace

/* ---------------- 块头解析单点白盒 ---------------- */

TH_TEST(action_if_parse_block_name) {
	/* 命中：返回 trim 后的条件体（块内空格是 MatrixParser 保证不了的，
	 * 白盒仍按文本自洽处理） */
	TH_CHECK(bot::ActionRunner::parseIfBlockName("if(k>0)") == std::optional<std::string>("k>0"));
	TH_CHECK(bot::ActionRunner::parseIfBlockName(" if(k>0&&m<1) ") == std::optional<std::string>("k>0&&m<1"));
	/* 非 if 块：nullopt（含同前缀的 "ifx(a)"——它按未知块透传，照旧不执行） */
	TH_CHECK(!bot::ActionRunner::parseIfBlockName("Action").has_value());
	TH_CHECK(!bot::ActionRunner::parseIfBlockName("ifx(a)").has_value());
	TH_CHECK(!bot::ActionRunner::parseIfBlockName("Trigger").has_value());
	/* 意图明显的坏形态：响亮救红，不静默当未知块丢弃 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "@if 块缺条件表达式",
		(void)bot::ActionRunner::parseIfBlockName("if"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "未在块头内闭合",
		(void)bot::ActionRunner::parseIfBlockName("if(k>0"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "条件为空",
		(void)bot::ActionRunner::parseIfBlockName("if()"));
}

/* ---------------- 条件求值与执行编排 ---------------- */

TH_TEST(action_if_condition_met_dispatches_block) {
	/* @Vars 数值条件成立：块体当 @Action 派发（参数落到一次 play） */
	bot::HwRegistry reg;
	bot::Json played;
	reg.add("leg", std::make_unique<fx::LambdaHw>([&played](const bot::Json& in) {
		played = in;
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	}), "");
	reg.add("k", varsHw("k", "2"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k>0)\nleg.angle;\n 90;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(played.isObj());
	TH_CHECK(played.get("angle").has_value() && played.get("angle")->getFloat() == 90.0);
}

TH_TEST(action_if_condition_not_met_skips_with_note) {
	/* 条件不成立：不派发（零 play）+ stderr 注记可见（条件原文与跳过行数） */
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("leg", std::make_unique<fx::LambdaHw>([&plays](const bot::Json&) {
		++plays;
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	}), "");
	reg.add("k", varsHw("k", "2"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k<0)\nleg.angle;\n 90;\n 45;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(plays == 0);
		TH_CHECK(cerr.contains("[if] condition not met"));
		TH_CHECK(cerr.contains("'k<0'"));
		TH_CHECK(cerr.contains("skipping 2 action row(s)"));
	}
}

TH_TEST(action_if_alias_text_equality) {
	/* @Alias 文本 == 字符串字面量：成立派发；不成立跳过（同一注册表，
	 * 两次 run 各自求值） */
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("leg", std::make_unique<fx::LambdaHw>([&plays](const bot::Json&) {
		++plays;
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	}), "");
	reg.add("mode", aliasHw("mode", "auto"), "");
	std::vector<mt::MatrixObject> hit = fx::manyMatrices(
		"@if(mode==\"auto\")\nleg.angle;\n 90;\n@\n");
	bot::ActionRunner(reg).runAction(hit);
	TH_CHECK(plays == 1);
	std::vector<mt::MatrixObject> miss = fx::manyMatrices(
		"@if(mode!=\"auto\")\nleg.angle;\n 90;\n@\n");
	bot::ActionRunner(reg).runAction(miss);
	TH_CHECK(plays == 1);	/* 仍是第一次的那次 play */
}

TH_TEST(action_if_interleaves_with_action_in_written_order) {
	/* 书写顺序交错执行：if 在 Action 前则先派发 if 块，反之亦然——
	 * 「先做 A、条件满足再做 B」的直觉由展开层保序 + 本层遍历共同保证 */
	bot::HwRegistry reg;
	std::vector<std::string> trace;
	reg.add("a", traceHw("a", trace), "");
	reg.add("b", traceHw("b", trace), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k>0)\nb.p;\n 1;\n@\n"
		"@Action\na.p;\n 1;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK((trace == std::vector<std::string>{"b", "a"}));

	trace.clear();
	std::vector<mt::MatrixObject> mats2 = fx::manyMatrices(
		"@Action\na.p;\n 1;\n@\n"
		"@if(k>0)\nb.p;\n 1;\n@\n");
	bot::ActionRunner(reg).runAction(mats2);
	TH_CHECK((trace == std::vector<std::string>{"a", "b"}));
}

TH_TEST(action_if_skipped_block_still_allows_later_blocks) {
	/* 前一块条件不成立只跳过该块：后续 @Action 与后续 @if 照常执行 */
	bot::HwRegistry reg;
	std::vector<std::string> trace;
	reg.add("a", traceHw("a", trace), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k<0)\na.p;\n 1;\n@\n"
		"@Action\na.p;\n 2;\n@\n"
		"@if(k>0)\na.p;\n 3;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(cerr.contains("condition not met"));
	}
	TH_CHECK((trace == std::vector<std::string>{"a", "a"}));
}

/* ---------------- 报错契约 ---------------- */

TH_TEST(action_if_bad_condition_reports_loudly) {
	/* 非布尔条件（数值裸值）：无隐式真值，显式拒绝——白盒（runTexts 级
	 * 未 active 的注册表是空的，任何标识符都先死于 not defined） */
	bot::HwRegistry reg;
	reg.add("leg", fx::dummyHw(), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k)\nleg.p;\n 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是逻辑表达式",
		bot::ActionRunner(reg).runAction(mats));
	/* 文本条件同理（@Alias 裸值） */
	reg.add("mode", aliasHw("mode", "auto"), "");
	std::vector<mt::MatrixObject> mats2 = fx::manyMatrices(
		"@if(mode)\nleg.p;\n 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须是逻辑表达式",
		bot::ActionRunner(reg).runAction(mats2));
	/* 未定义标识符：resolver 报错文案直达（与 $(...) 同语义；runTexts 级
	 * 未 active 的注册表恰好就是「一切皆未定义」的观察窗） */
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@if(ghost>0)\nrelay0.deg;\n 90;\n@\n").find("not a defined hardware variable") != std::string::npos);
	/* 裸 @if / 未闭合：块头解析单点报错（runTexts 级即可，块头错先于
	 * 条件求值） */
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@if\nrelay0.deg;\n 90;\n@\n").find("@if 块缺条件表达式") != std::string::npos);
	TH_CHECK(runTexts(rfx::kBasicSql,
		"@if(k>0\nrelay0.deg;\n 90;\n@\n").find("未在块头内闭合") != std::string::npos);
}

TH_TEST(action_if_bool_rejected_in_action_cell) {
	/* 布尔入 @Action 单元格 / 设备列：比较/逻辑表达式属于 @if 条件 */
	bot::HwRegistry reg;
	reg.add("leg", fx::dummyHw(), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nleg.test;\n $(1>0);\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "不能产出布尔结果",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(action_if_coexists_with_reflex) {
	/* @if 与 #34 @Reflex/@Trigger 共存：if 块照常按条件派发，反射照常
	 * 触发（run() 的固定序 = runAction 先、runReflex 后，此处同序复现） */
	bot::HwRegistry reg;
	std::vector<std::string> trace;
	reg.add("a", traceHw("a", trace), "");
	reg.add("b", traceHw("b", trace), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k>0)\na.p;\n 1;\n@\n"
		"@Reflex\nname b.p;\n blink 1;\n@\n"
		"@Trigger\ntrigger;\n blink;\n@\n");
	bot::ActionRunner runner(reg);
	runner.runAction(mats);
	runner.runReflex(mats);
	TH_CHECK((trace == std::vector<std::string>{"a", "b"}));
	/* 条件翻转后反射仍独立成立（if 跳过不影响 @Trigger） */
	trace.clear();
	std::vector<mt::MatrixObject> mats2 = fx::manyMatrices(
		"@if(k<0)\na.p;\n 1;\n@\n"
		"@Reflex\nname b.p;\n blink 1;\n@\n"
		"@Trigger\ntrigger;\n blink;\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner runner2(reg);
		runner2.runAction(mats2);
		runner2.runReflex(mats2);
		TH_CHECK(cerr.contains("condition not met"));
	}
	TH_CHECK((trace == std::vector<std::string>{"b"}));
}

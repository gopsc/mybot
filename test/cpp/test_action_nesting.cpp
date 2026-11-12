/* test_action_nesting.cpp —— @块相互嵌套的执行编排（2026-10-12）
 *
 * 覆盖 ActionRunner::execSequence 的递归：@if 内含 @while、@while 内含 @if、
 * 直接行与显式子块交错按书写顺序执行、内层条件不成立只跳过内层（外层照常）、
 * Ctrl-C 经 stopRequested 逐层及时跳出。夹具形态与 test_action_while.cpp 同源
 * （LambdaHw 桩 + 捕获格推进 @Vars 驱动循环收敛）。解析层白盒见 test_matrix.cpp。
 */
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "action_runner.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_env.hpp"		/* stopRequested */
#include "util_except.hpp"
#include "robot_fixtures.hpp"

namespace {

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

std::unique_ptr<bot::MatrixVars_Hardware> varsHw(const std::string& name,
	const std::string& value) {
	return bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   " + name + "  " + value + ";\n@\n"), 1,
		[](const std::string&) { return 0.0; });
}

/* 计数桩：每次 play 递增 plays、追加 trace、返回递增 reading（供捕获格推进 @Vars）。
 * stopAt>0 时第 stopAt 次 play 置 stopRequested（Ctrl-C 用例）。 */
std::unique_ptr<bot::MatrixVars_Hardware> counterHw(const std::string& name, int& plays,
	std::vector<std::string>& trace, int stopAt = 0) {
	return std::make_unique<fx::LambdaHw>([name, &plays, &trace, stopAt](const bot::Json&) {
		++plays;
		trace.push_back(name);
		if (stopAt > 0 && plays >= stopAt) { bot::stopRequested().store(true); }
		auto o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("reading", bot::JsonInt(plays));
		return o;
	});
}

struct StopGuard {
	StopGuard() { bot::stopRequested().store(false); }
	~StopGuard() { bot::stopRequested().store(false); }
	StopGuard(const StopGuard&) = delete;
	StopGuard& operator=(const StopGuard&) = delete;
};

} // namespace

TH_TEST(action_nesting_if_inside_while) {
	/* @while 内含 @if：外层循环两轮，每轮捕获推进 count，内层 @if(count>0) 成立
	 * → leg 每轮派发一次。dev 2 次、leg 2 次。 */
	bot::HwRegistry reg;
	int devPlays = 0, legPlays = 0;
	std::vector<std::string> devTrace, legTrace;
	reg.add("dev", counterHw("dev", devPlays, devTrace), "");
	reg.add("leg", counterHw("leg", legPlays, legTrace), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<2)\ndev.reading;\n $count=reading;\n"
		"@if(count>0)\nleg.p;\n 1;\n@\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(devPlays == 2);
	TH_CHECK(legPlays == 2);
}

TH_TEST(action_nesting_while_inside_if) {
	/* @if 内含 @while：外层条件成立 → 内层循环跑到收敛（dev 3 次）。 */
	bot::HwRegistry reg;
	int devPlays = 0;
	std::vector<std::string> trace;
	reg.add("dev", counterHw("dev", devPlays, trace), "");
	reg.add("count", varsHw("count", "0"), "");
	reg.add("k", varsHw("k", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k>0)\n@while(count<3)\ndev.reading;\n $count=reading;\n@\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(devPlays == 3);
}

TH_TEST(action_nesting_outer_if_false_skips_whole_subtree) {
	/* 外层 @if 不成立：整棵子树（含内层 @while）零派发。 */
	bot::HwRegistry reg;
	int devPlays = 0;
	std::vector<std::string> trace;
	reg.add("dev", counterHw("dev", devPlays, trace), "");
	reg.add("count", varsHw("count", "0"), "");
	reg.add("k", varsHw("k", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(k>0)\n@while(count<3)\ndev.reading;\n $count=reading;\n@\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(devPlays == 0);
		TH_CHECK(cerr.contains("[if] condition not met"));
	}
}

TH_TEST(action_nesting_interleaved_children_run_in_written_order) {
	/* 控制块体：直接行(隐式@Action) → 显式@Action → 直接行(隐式@Action)，
	 * 按书写顺序 a、b、c 派发。 */
	bot::HwRegistry reg;
	int ap = 0, bp = 0, cp = 0;
	std::vector<std::string> trace;
	reg.add("a", counterHw("a", ap, trace), "");
	reg.add("b", counterHw("b", bp, trace), "");
	reg.add("c", counterHw("c", cp, trace), "");
	reg.add("t", varsHw("t", "1"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@if(t>0)\na.p;\n 1;\n@Action\nb.p;\n 1;\n@\nc.p;\n 1;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK((trace == std::vector<std::string>{"a", "b", "c"}));
}

TH_TEST(action_nesting_inner_if_false_skips_only_inner) {
	/* @while 外层照常循环，内层 @if(count>5) 恒假 → leg 零派发、dev 仍 2 次；
	 * 每轮都有 [if] 跳过注记。 */
	bot::HwRegistry reg;
	int devPlays = 0, legPlays = 0;
	std::vector<std::string> devTrace, legTrace;
	reg.add("dev", counterHw("dev", devPlays, devTrace), "");
	reg.add("leg", counterHw("leg", legPlays, legTrace), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<2)\ndev.reading;\n $count=reading;\n"
		"@if(count>5)\nleg.p;\n 1;\n@\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(devPlays == 2);
		TH_CHECK(legPlays == 0);
		TH_CHECK(cerr.contains("[if] condition not met"));
		TH_CHECK(cerr.contains("[while] condition became false"));
	}
}

TH_TEST(action_nesting_stop_requested_breaks_all_levels) {
	/* Ctrl-C：dev 第 2 次 play 置 stop。iter1 全跑（dev+leg），iter2 dev 跑后置
	 * stop → 同轮后续 @if 被 execSequence 的逐块 stop 检查跳过（leg 不再派发），
	 * 下一轮 while 顶部 stopRequested 跳出。dev 2 次、leg 1 次。 */
	StopGuard guard;
	bot::HwRegistry reg;
	int devPlays = 0, legPlays = 0;
	std::vector<std::string> devTrace, legTrace;
	reg.add("dev", counterHw("dev", devPlays, devTrace, /*stopAt=*/2), "");
	reg.add("leg", counterHw("leg", legPlays, legTrace), "");
	reg.add("count", varsHw("count", "0"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@while(count<1000)\ndev.reading;\n $count=reading;\n"
		"@if(count>0)\nleg.p;\n 1;\n@\n@\n");
	{
		CerrCapture cerr;
		bot::ActionRunner(reg).runAction(mats);
		TH_CHECK(devPlays == 2);
		TH_CHECK(legPlays == 1);
		TH_CHECK(cerr.contains("[while] stop requested"));
	}
}

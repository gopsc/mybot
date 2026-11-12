/* harness_selftest.cpp —— 测试骨架自身的守门（2026-09-21 审计 AG-5）
 *
 * 为什么需要一个独立的二进制：AG-5 的缺陷是「测试骨架把零断言的用例记 [PASS]」。
 * 修好骨架之后，**骨架本身也需要有人守**——否则日后一次重构就能悄悄退回旧行为，
 * 而所有用例依旧全绿（它们的断言本来就会过）。用一个带真断言的骨架来测骨架，
 * 是最直接的自证方式：把已知形态喂给一份**独立的** th 状态，断言它给出的
 * pass/fail/skip 判定符合预期。
 *
 * 与 mybot_tests 分开的理由：
 *   ① 需要故意写「零断言」与「半跑半跳过」的用例——留在 mybot_tests 里会让
 *      主守门计数出现永久失败项；
 *   ② 被测的 th 状态必须与主套件隔离（th 的单例是每 TU 一份，故本文件自带
 *      一份，互不干扰）。
 *
 * 用法：./build/harness_selftest [过滤器]（过滤器语义与 mybot_tests 一致）
 * 退出码：0 = 全部符合预期；1 = 骨架行为与预期不符（真失败）；-1 = 过滤器无命中。
 *
 * 新增断言形态时请同步扩这里：只要 harness.hpp 里多了一种「算一条断言」的宏，
 * 就该有一条自证用例，否则「零断言判据」会随宏的增删悄悄失真。 */
#include "harness.hpp"

#include <stdexcept>
#include <string>

namespace {

/* 过滤器前缀：本二进制自己的用例全部以此开头，内部元数据例句用别的名字，
 * 保证 `./build/harness_selftest harness_` 只跑到自证用例、不会跑到例句。 */
constexpr const char* kFilterPrefix = "harness_";

/* ---- 被喂给骨架的「例句」用例（故意保留各种形态）---- */

/* 形态 A：一条断言都不跑就结束（旧骨架会记 [PASS] 的那个形态） */
TH_TEST(meta_silent_zero_assertions) {
	const bool environment_ok = false;
	if (!environment_ok) { return; }	/* ← AG-5 的原始形态 */
	TH_CHECK(false);
}

/* 形态 A'：改成显式跳过后的同一场景（应当记 [SKIP]，不当失败） */
TH_TEST(meta_explicit_skip) {
	const bool environment_ok = false;
	if (!environment_ok) { TH_SKIP("构造该场景所需的环境不具备（自证用例，有意为之）"); }
	TH_CHECK(false);
}

/* 形态 B：先跑了断言再声明跳过（语义矛盾，应判失败） */
TH_TEST(meta_half_assert_then_skip) {
	TH_CHECK(true);			/* 已经验证过一部分 */
	TH_SKIP("半跑半跳过：应当被判失败（自证用例，有意为之）");
}

/* 形态 C：正常用例（对照，必须 [PASS] 且断言计数 > 0） */
TH_TEST(meta_normal_pass) {
	TH_CHECK(1 + 1 == 2);
	TH_CHECK_MSG(true, "TH_CHECK_MSG 也必须计入断言数");
}

/* 形态 D：正常失败（对照，必须 [FAIL]） */
TH_TEST(meta_normal_fail) {
	TH_CHECK(1 + 1 == 3);
}

/* ---- 自证用例：断言骨架对上述形态的判定 ----
 * 约定：嵌套调用一律 quiet=true（子用例的输出不该混进父用例的 [PASS]/[FAIL] 流），
 * 并同时断言「失败数」与「通过/跳过数」——只断言失败数区分不了「全跳过」与
 * 「全通过」（两者都是 0 失败）。 */
namespace {

struct Verdict {
	int rc;
	int passed;
	int failed;
	int skipped;
};

Verdict judge(const std::string& filter) {
	/* 用 runAllOutcome 直接拿这一次运行的计数：全局快照在多级嵌套下无法归属
	 * （外层运行也读同一份 lastStats，读到的是内层的账）。 */
	const th::RunOutcome o = th::runAllOutcome(filter, /*quiet=*/true);
	return Verdict{o.rc, o.passed, o.failed, o.skipped};
}

std::string show(const Verdict& v) {
	return "rc=" + std::to_string(v.rc) + " 通过=" + std::to_string(v.passed)
		+ " 失败=" + std::to_string(v.failed) + " 跳过=" + std::to_string(v.skipped);
}

} // namespace

/* 计数器语义：全部 5 种断言宏都必须计入 */
TH_TEST(harness_counts_every_assertion_macro) {
	th::currentChecks() = 0;
	th::check(true, "1", __FILE__, __LINE__);
	TH_CHECK(true);
	TH_CHECK_MSG(true, "msg");
	/* 注意：断言宏是可变参宏，**模板实参里不能有逗号**（预处理器按逗号切参数）
	 * ——std::runtime_error 无逗号可用；std::map<int,int> 这类必须先 using 起
	 * 别名。这里借用例说明这条限制，免得后人踩。 */
	using Exc = std::runtime_error;
	TH_CHECK_THROWS(Exc, throw Exc("x"));
	TH_CHECK_THROWS_MSG(Exc, "x", throw Exc("x"));
	/* 期望 6 = 上面 5 种宏各 1 条 + 这条 TH_CHECK_MSG 自己（它也计入——
	 * 断言「检查计数的断言」自身被计数，正是判据自洽的表现）。 */
	TH_CHECK_MSG(th::currentChecks() == 6,
		"5 种断言宏 + 本断言自身应计 6 条，实际 " + std::to_string(th::currentChecks()));
}

/* 零断言形态：判失败（旧骨架把它记 [PASS]，正是 AG-5） */
TH_TEST(harness_flags_zero_assertion_case) {
	const Verdict v = judge("meta_silent_zero_assertions");
	TH_CHECK_MSG(v.rc == 1 && v.failed == 1 && v.passed == 0,
		"零断言用例应判 1 失败 0 通过，实际 " + show(v));
}

/* 正常用例：仍然通过（别把判据写成误杀） */
TH_TEST(harness_passes_normal_case) {
	const Verdict v = judge("meta_normal_pass");
	TH_CHECK_MSG(v.rc == 0 && v.passed == 1 && v.failed == 0,
		"正常用例应 1 通过 0 失败，实际 " + show(v));
}

/* 真失败：必须仍被认出（自证用例不能把失败洗白） */
TH_TEST(harness_still_reports_real_failure) {
	const Verdict v = judge("meta_normal_fail");
	TH_CHECK_MSG(v.rc == 1 && v.failed == 1 && v.passed == 0,
		"真失败应判 1 失败，实际 " + show(v));
}

/* TH_SKIP：记跳过、不算失败、也不算通过 */
TH_TEST(harness_skip_is_not_a_failure) {
	const Verdict v = judge("meta_explicit_skip");
	TH_CHECK_MSG(v.rc == 0 && v.skipped == 1 && v.passed == 0 && v.failed == 0,
		"显式 TH_SKIP 应记 1 跳过且不判失败，实际 " + show(v));
}

/* 先断言后跳过：语义矛盾，必须判失败而不是洗成跳过 */
TH_TEST(harness_rejects_assert_then_skip) {
	const Verdict v = judge("meta_half_assert_then_skip");
	TH_CHECK_MSG(v.rc == 1 && v.failed == 1,
		"断言后 TH_SKIP 应判失败，实际 " + show(v));
}

/* 过滤器无命中：仍返回 -1（run_all 的空匹配防线依赖它） */
TH_TEST(harness_reports_empty_filter) {
	const Verdict v = judge("zzz_no_such_case_zzz");
	TH_CHECK_MSG(v.rc == -1, "无命中过滤器应返回 -1，实际 " + show(v));
}

/* quiet 模式不得影响判定（只吞输出）。
 * 这里两次都用 quiet：本用例自身若 loud 跑一次，它的 [PASS]/汇总行会混进
 * 自证二进制本该干净的输出里（第一版就是这样，输出里多出一串 meta_ 行）。 */
TH_TEST(harness_quiet_mode_does_not_change_verdict) {
	const th::RunOutcome a = th::runAllOutcome("meta_normal_pass", /*quiet=*/true);
	const th::RunOutcome b = th::runAllOutcome("meta_normal_pass", /*quiet=*/true);
	TH_CHECK_MSG(a.rc == 0 && b.rc == 0 && a.passed == b.passed && a.failed == b.failed,
		"quiet 判定应稳定为 1 通过 0 失败，实际 a=" + show(Verdict{a.rc, a.passed, a.failed, a.skipped})
			+ " b=" + show(Verdict{b.rc, b.passed, b.failed, b.skipped}));
}

} // namespace

int main(int argc, char** argv) {
	/* 无过滤器时只跑自证用例：元数据例句（meta_*）故意含失败形态，不能在
	 * 全量跑里执行——它们只在自证用例内部的子 runAll 里被跑到。
	 * 这也让 `./build/harness_selftest` 的退出码就是「骨架是否符合预期」。 */
	const std::string arg = argc > 1 ? argv[1] : "";
	if (arg.empty()) { return th::runAll(kFilterPrefix); }
	return th::runAll(arg);
}

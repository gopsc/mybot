/* test_mtinclude.cpp —— @Merge 展开白盒单测
 *
 * 钉住 mtinclude::expandIncludes 的全部语义分支（mtmerge_core 归并内核本身
 * 由 test_mtmerge 覆盖，这里只测展开层的编排与校验）：
 *   - fast path：无 @Merge 逐字不动；
 *   - @Action 相位归并（含首个 include 顶替缺省 @Action、phase "-" 继承）；
 *   - 嵌套片段组合（终止性 = 已展开文件表；*.once.mt 重复包含跳过、
 *     普通文件重复包含报错；环与自包含终止）；
 *   - 主从覆盖：同名 @Alias/@Vars「更靠近主脚本者获胜」（注记），
 *     片段互相之间同名仍报错；
 *   - 片段以自身目录为包含基准（库片段可搬移）；
 *   - 负路径：设备相交 / 路径词法 / 文件缺失 / 软链拒绝 / 行数与总字节
 *     预算 / 深度上限；
 *   - 未知矩阵透传。
 * 文件类用例走 fx::TempDir（进程级隔离，析构即清）。
 */

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "matrix.hpp"
#include "mtinclude.hpp"
#include "mtmerge_core.hpp"
#include "scriptlimit.hpp"	/* ScriptTooLarge（超限用例） */
#include "util_except.hpp"
#include "util_str.hpp"

namespace {

/* 在 TempDir 写一个文本文件（父目录自动创建） */
void writeFile(const fx::TempDir& dir, const std::string& name, const std::string& text) {
	const std::filesystem::path full = dir.path() / name;
	if (full.has_parent_path()) {
		std::error_code ec;
		std::filesystem::create_directories(full.parent_path(), ec);
		if (ec) { throw std::runtime_error("前置条件失败：建夹具目录 " + name); }
	}
	std::ofstream f(full, std::ios::binary);
	if (!f) { throw std::runtime_error("前置条件失败：写夹具文件 " + name); }
	f << text;
}

/* 主脚本常见形态：@Action（可选）+ @Merge 两行 */
std::vector<mt::MatrixObject> parseMain(const std::string& text) {
	return fx::manyMatrices(text);
}

/* stderr 捕获（注记也是契约：include-once 跳过与主从覆盖必须可见） */
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

} // namespace

/* ---------------- fast path ---------------- */

TH_TEST(mtinclude_no_include_is_noop) {
	std::string text = "@Alias\nname value;\nk 1;\n@\n\n@Action\na.x;\n1;\n@\n";
	auto mats = parseMain(text);
	std::vector<std::string> namesBefore;
	for (const auto& m : mats) { namesBefore.push_back(bot::trim(m.getName())); }
	mtinclude::expandIncludes(mats, ".");
	std::vector<std::string> namesAfter;
	for (const auto& m : mats) { namesAfter.push_back(bot::trim(m.getName())); }
	TH_CHECK(namesBefore == namesAfter);
	TH_CHECK(fx::cell(mats[0], 1, 0) == "k");
}

/* ---------------- @Action 相位归并 ---------------- */

TH_TEST(mtinclude_merges_action_with_phase) {
	fx::TempDir dir("inc_action");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n200;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n2;\n@\n"
		"@Merge\npath phase;\n  b.mt 1;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 1);	/* 展开产物只剩归并后的 @Action */
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(bot::trim(act.getName()) == "Action");
	TH_CHECK(act.cols() == 2);			/* a.x ∪ b.p */
	TH_CHECK(act.rows() == 4);			/* 表头 + max(2, 2+1)=3 数据行 */
	TH_CHECK(fx::cell(act, 1, 1) == "-");	/* b 滞后 1：首行未起拍 */
	TH_CHECK(fx::cell(act, 2, 1) == "100");
	TH_CHECK(fx::cell(act, 3, 1) == "200");
	TH_CHECK(fx::cell(act, 3, 0) == "-");	/* a 耗尽补 "-" */
}

/* 产物预算的**接线**（2026-09-21 第七轮审计）：判据在 mtmerge::mergeTwo 单点，
 * @Merge 展开只是它的调用方——但"调用方把异常原样冒出来、而不是先把十万行产物
 * 建出来"这件事只有这一层能钉住。修复前：一行 `b.mt 100000` 就能让终态到
 * ~1e5 行（数百 MB），树莓派上 OOM，而 OOM 是 SIGKILL 语义 ⇒ deactivate 被整体跳过。 */
TH_TEST(mtinclude_product_budget_surfaces_from_include_phase) {
	fx::TempDir dir("inc_phase_budget");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n200;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n2;\n@\n"
		"@Merge\npath phase;\n  b.mt 100000;\n@\n");
	TH_CHECK_THROWS_MSG(std::exception, "exceeding the limit of",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_phase_dash_inherits_previous_row) {
	fx::TempDir dir("inc_dash");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	writeFile(dir, "c.mt", "@Action\nc.q;\n7;\n@\n");
	/* 第二行 phase "-" 继承首行 2（矩阵 "-" 前向填充语义延伸到相位列） */
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath phase;\n  b.mt 2;\n  c.mt -;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.rows() == 4);			/* max(1, 1+2)=3 数据行 */
	TH_CHECK(fx::cell(act, 3, 2) == "7");	/* c 滞后 2 → 第 3 行才出现 */
	TH_CHECK(fx::cell(act, 1, 2) == "-");
}

TH_TEST(mtinclude_first_include_becomes_action_when_main_has_none) {
	fx::TempDir dir("inc_noacc");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	writeFile(dir, "c.mt", "@Action\nc.q;\n7;\n@\n");
	/* 主脚本没有 @Action：首个 include 顶替累加器（其相位无对齐目标，
	 * 与 mtmerge --phase 作用于第 2 个及后续输入同口径） */
	auto mats = parseMain(
		"@Merge\npath phase;\n  b.mt 5;\n  c.mt 0;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 2);
	TH_CHECK(fx::cell(act, 1, 0) == "100");	/* b 原样（相位 5 未生效） */
	TH_CHECK(fx::cell(act, 1, 1) == "7");
}

/* ---------------- @Alias / @Vars 叠加 ---------------- */

TH_TEST(mtinclude_stacks_alias_and_vars) {
	fx::TempDir dir("inc_scalar");
	writeFile(dir, "b.mt",
		"@Alias\nname value;\n  kb delay;\n@\n"
		"@Vars\nname value;\n  kv 2;\n@\n"
		"@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Alias\nname value;\n  ka x;\n@\n"
		"@Vars\nname value;\n  kv0 1;\n@\n"
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  b.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 3);	/* Alias + Vars + Action（include 的并入本体） */
	TH_CHECK(bot::trim(mats[0].getName()) == "Alias");
	TH_CHECK(fx::cell(mats[0], 1, 0) == "ka");
	TH_CHECK(fx::cell(mats[0], 2, 0) == "kb");
	TH_CHECK(bot::trim(mats[1].getName()) == "Vars");
	TH_CHECK(fx::cell(mats[1], 1, 0) == "kv0");
	TH_CHECK(fx::cell(mats[1], 2, 0) == "kv");
	TH_CHECK(fx::cell(mats[2], 1, 1) == "100");
}

TH_TEST(mtinclude_sibling_alias_collision_still_errors) {
	/* 片段互相之间同名 @Alias 仍报错（主脚本同名才是覆盖语义） */
	fx::TempDir dir("inc_dup");
	writeFile(dir, "fa.mt",
		"@Alias\nname value;\n  ka x;\n@\n"
		"@Action\na.p;\n10;\n@\n");
	writeFile(dir, "fb.mt",
		"@Alias\nname value;\n  ka other;\n@\n"
		"@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n  fa.mt;\n  fb.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "duplicate Alias name 'ka'",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

/* ---------------- 负路径：归并契约 ---------------- */

TH_TEST(mtinclude_rejects_device_overlap) {
	fx::TempDir dir("inc_overlap");
	writeFile(dir, "b.mt", "@Action\na.p;\n100;\n@\n");	/* 与主脚本同为 a */
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  b.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "device 'a' appears in both scripts",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_vars_only_fragment_contributes_scalars) {
	/* 被包含文件可以没有 @Action：纯标量片段合法（整体缺失由派发期报错） */
	fx::TempDir dir("inc_vars_only");
	writeFile(dir, "v.mt", "@Vars\nname value;\n  kv 5;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  v.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 2);	/* Vars + Action */
	TH_CHECK(bot::trim(mats[0].getName()) == "Vars");
	TH_CHECK(fx::cell(mats[0], 1, 0) == "kv");
	TH_CHECK(bot::trim(mats[1].getName()) == "Action");
	TH_CHECK(fx::cell(mats[1], 1, 0) == "1");	/* 本体动作不受影响 */
}

/* ---------------- 负路径：路径词法与文件系统 ---------------- */

TH_TEST(mtinclude_path_lexical_rules) {
	fx::TempDir dir("inc_lex");
	auto main_with = [](const std::string& p) {
		return parseMain("@Action\na.x;\n1;\n@\n@Merge\npath;\n  " + p + ";\n@\n");
	};
	auto abs_path = main_with("/etc/x.mt");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "absolute path rejected",
		mtinclude::expandIncludes(abs_path, dir.path().string()));
	auto traversal = main_with("../x.mt");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "must not traverse outside",
		mtinclude::expandIncludes(traversal, dir.path().string()));
	auto dot_seg = main_with("./x.mt");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "empty or '.' segment",
		mtinclude::expandIncludes(dot_seg, dir.path().string()));
	auto not_mt = main_with("x.lua");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "only accepts .mt",
		mtinclude::expandIncludes(not_mt, dir.path().string()));
}

TH_TEST(mtinclude_missing_file_reports_path) {
	fx::TempDir dir("inc_missing");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n@Merge\npath;\n  nope.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot open include file",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_rejects_symlink) {
	fx::TempDir dir("inc_symlink");
	writeFile(dir, "real.mt", "@Action\nb.p;\n100;\n@\n");
	std::error_code ec;
	std::filesystem::create_symlink("real.mt", dir.path() / "link.mt", ec);
	/* 本项目只支持 Linux，软链创建失败视为环境异常直接判红（上面那条断言）。
	 * 随后的 return 只是**短路**：用例已记失败，不再拿 ec 继续跑后面的断言去
	 * 制造无关噪音；这不是「假绿式早退」——AG-5 的零断言判据看的是「有没有
	 * 断言跑过」，这里已经跑过一条了。 */
	TH_CHECK(!ec);
	if (ec) { return; }
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n@Merge\npath;\n  link.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "symbolic link",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

/* ---------------- 预算防线 ---------------- */

TH_TEST(mtinclude_row_budget_rejects_before_reading) {
	/* 前 32 行指向真实存在的文件（正常读入），第 33 行故意指向缺失文件：
	 * 若计数检查不在该行 IO 之前，报错会是 "cannot open" 而非行数上限 */
	fx::TempDir dir("inc_budget33");
	for (int i = 0; i < 32; ++i) {
		writeFile(dir, "f" + std::to_string(i) + ".mt",
			"@Action\nd" + std::to_string(i) + ".x;\n" + std::to_string(i + 1) + ";\n@\n");
	}
	std::string rows;
	for (int i = 0; i < 32; ++i) { rows += "  f" + std::to_string(i) + ".mt;\n"; }
	rows += "  nope32.mt;\n";
	auto mats = parseMain("@Action\na.x;\n1;\n@\n@Merge\npath;\n" + rows + "@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeding the limit of 32",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_total_byte_budget_rejects) {
	fx::TempDir dir("inc_budget");
	/* 两个各 ~4.6MiB 的文件：单文件不超 8MiB，合计超总预算。
	 * 夹具必须是 **@Alias**（标量行）而不是 @Action：@Action 的归并产物受
	 * mtmerge::kMaxMergedRows 约束，6.8 万行会先撞上产物预算，这条用例就测不到
	 * 它要测的"字节总量"了（实测踩过）。@Alias 走 mergeScalarRows，无产物预算，
	 * 于是字节预算仍是唯一会先触发的那道限。名字加文件前缀避免同名行冲突。 */
	std::string pad(64, 'x');
	{
		std::ofstream f(dir.path() / "big1.mt", std::ios::binary);
		f << "@Alias\nname value;\n";
		for (int i = 0; i < 68000; ++i) { f << "    b1n" << i << " " << pad << ";\n"; }
		f << "@\n";
	}
	{
		std::ofstream f(dir.path() / "big2.mt", std::ios::binary);
		f << "@Alias\nname value;\n";
		for (int i = 0; i < 68000; ++i) { f << "    b2n" << i << " " << pad << ";\n"; }
		f << "@\n";
	}
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n@Merge\npath;\n  big1.mt;\n  big2.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge, "total size of included action scripts",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

/* ---------------- 列头校验与透传 ---------------- */

TH_TEST(mtinclude_include_header_rules) {
	fx::TempDir dir("inc_header");
	auto bad_col = parseMain(
		"@Action\na.x;\n1;\n@\n@Merge\npath file;\n  b.mt x;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not supported",
		mtinclude::expandIncludes(bad_col, dir.path().string()));
	auto bad_phase = parseMain(
		"@Action\na.x;\n1;\n@\n@Merge\npath phase;\n  b.mt soon;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "phase is not an integer",
		mtinclude::expandIncludes(bad_phase, dir.path().string()));
}

TH_TEST(mtinclude_unknown_matrices_pass_through) {
	fx::TempDir dir("inc_unknown");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Foo\nhead;\n  v;\n@\n"
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  b.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	/* 产物：Alias/Vars（无）→ Action → 未知 @Foo */
	bool foundFoo = false;
	for (const auto& m : mats) {
		if (bot::trim(m.getName()) == "Foo") { foundFoo = true; }
	}
	TH_CHECK(foundFoo);
	TH_CHECK(mats.size() == 2);
}

/* ---------------- 嵌套与 include-once ---------------- */

TH_TEST(mtinclude_nested_fragments_compose) {
	/* 嵌套合法：片段可再包含片段（终止性由已展开文件表保证）；
	 * 纯组合片段（无自有 @Action）合法 */
	fx::TempDir dir("inc_nest2");
	writeFile(dir, "inner.mt", "@Merge\npath;\n  b.mt;\n@\n");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  inner.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 2);
	TH_CHECK(fx::cell(act, 1, 0) == "1");
	TH_CHECK(fx::cell(act, 1, 1) == "100");
}

TH_TEST(mtinclude_once_suffix_skips_reinclusion) {
	/* *.once.mt 被再次包含 → 跳过（stderr 注记），产物只含一份贡献 */
	fx::TempDir dir("inc_once");
	writeFile(dir, "hold.once.mt", "@Action\nh.x;\n5;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  hold.once.mt;\n  hold.once.mt;\n@\n");
	CerrCapture cap;
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 2);		/* a.x ∪ h.x（第二份未并入） */
	TH_CHECK(act.rows() == 2);
	TH_CHECK(fx::cell(act, 1, 1) == "5");
	TH_CHECK(cap.contains("already included"));
}

TH_TEST(mtinclude_plain_reinclusion_errors) {
	/* 普通 .mt 重复包含仍报错（抓笔误：拼写撞上已包含文件） */
	fx::TempDir dir("inc_twice");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  b.mt;\n  b.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "more than once",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_diamond_shared_fragment) {
	/* 菱形：D→A,B；A、B 都包含 shared.once.mt——第二次触达被跳过，
	 * shared 的动作在产物中恰好出现一次 */
	fx::TempDir dir("inc_diamond");
	writeFile(dir, "shared.once.mt", "@Action\ns.x;\n300;\n@\n");
	writeFile(dir, "fa.once.mt",
		"@Merge\npath;\n  shared.once.mt;\n@\n"
		"@Action\nf1.x;\n100;\n110;\n@\n");
	writeFile(dir, "fb.once.mt",
		"@Merge\npath;\n  shared.once.mt;\n@\n"
		"@Action\nf2.x;\n200;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n  fa.once.mt;\n  fb.once.mt;\n@\n");
	CerrCapture cap;
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 3);	/* f1.x ∪ s.x ∪ f2.x */
	TH_CHECK(act.rows() == 3);	/* max(2,1,1) = 2 数据行 */
	TH_CHECK(fx::cell(act, 1, 1) == "300");
	TH_CHECK(fx::cell(act, 2, 1) == "-");	/* shared 耗尽补 "-"，无第二份 */
	TH_CHECK(fx::cell(act, 1, 2) == "200");
	TH_CHECK(cap.contains("already included"));
}

TH_TEST(mtinclude_cycle_terminates) {
	/* 互包含环（once 片段）：a→b→a——第二次触达 a 被跳过，展开终止 */
	fx::TempDir dir("inc_cycle");
	writeFile(dir, "a.once.mt",
		"@Merge\npath;\n  b.once.mt;\n@\n"
		"@Action\na.x;\n1;\n@\n");
	writeFile(dir, "b.once.mt", "@Merge\npath;\n  a.once.mt;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n  a.once.mt;\n@\n");
	CerrCapture cap;
	mtinclude::expandIncludes(mats, dir.path().string());	/* 能返回即未挂死 */
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 1);
	TH_CHECK(fx::cell(act, 1, 0) == "1");
	TH_CHECK(cap.contains("already included"));
}

/* ---------------- 主从覆盖（同名标量行） ---------------- */

TH_TEST(mtinclude_main_wins_over_fragment_vars) {
	/* 主脚本同名 @Vars 覆盖片段定义（stderr 注记），片段动作引用 $(...)
	 * 在派发期读到主脚本的值——片段参数化的值通道 */
	fx::TempDir dir("inc_mainwins");
	writeFile(dir, "f.mt",
		"@Vars\nname value;\n  k 2;\n@\n"
		"@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Vars\nname value;\n  k 1;\n@\n"
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  f.mt;\n@\n");
	CerrCapture cap;
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 2);	/* Vars + Action（片段的 k 行被丢弃） */
	TH_CHECK(bot::trim(mats[0].getName()) == "Vars");
	TH_CHECK(fx::cell(mats[0], 1, 0) == "k");
	TH_CHECK(fx::cell(mats[0], 1, 1) == "1");	/* 主脚本的值获胜 */
	TH_CHECK(bot::trim(mats[1].getName()) == "Action");
	TH_CHECK(mats[1].cols() == 2);	/* 片段动作照常并入 */
	TH_CHECK(cap.contains("closer to the main script"));
}

TH_TEST(mtinclude_sibling_var_collision_still_errors) {
	/* 片段互相之间同名 @Vars 仍报错（主从覆盖不溶解兄弟碰撞检测） */
	fx::TempDir dir("inc_sib");
	writeFile(dir, "fa.mt",
		"@Vars\nname value;\n  k 1;\n@\n"
		"@Action\na.p;\n10;\n@\n");
	writeFile(dir, "fb.mt",
		"@Vars\nname value;\n  k 2;\n@\n"
		"@Action\nb.p;\n20;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n  fa.mt;\n  fb.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "duplicate Vars name 'k'",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_upper_fragment_wins_over_lower) {
	/* 主从覆盖逐层成立：上层片段 F 覆盖其子片段 G 的同名定义 */
	fx::TempDir dir("inc_upper");
	writeFile(dir, "g.once.mt",
		"@Vars\nname value;\n  k 2;\n@\n"
		"@Action\ng.x;\n7;\n@\n");
	writeFile(dir, "f.once.mt",
		"@Vars\nname value;\n  k 1;\n@\n"
		"@Merge\npath;\n  g.once.mt;\n@\n"
		"@Action\nf.x;\n5;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n  f.once.mt;\n@\n");
	CerrCapture cap;
	mtinclude::expandIncludes(mats, dir.path().string());
	bool found = false;
	for (const auto& m : mats) {
		if (bot::trim(m.getName()) != "Vars") { continue; }
		found = true;
		TH_CHECK(fx::cell(m, 1, 1) == "1");	/* F 的值获胜 */
	}
	TH_CHECK(found);
	TH_CHECK(cap.contains("closer to the main script"));
}

TH_TEST(mtinclude_fragment_relative_base) {
	/* 片段的 @Merge 以自身所在目录为基准（库片段可整体搬移） */
	fx::TempDir dir("inc_fragrel");
	std::filesystem::create_directories(dir.path() / "sub");
	writeFile(dir, "sub/g.once.mt",
		"@Merge\npath;\n  h.once.mt;\n@\n"
		"@Action\ng.x;\n7;\n@\n");
	writeFile(dir, "sub/h.once.mt", "@Action\nh.x;\n9;\n@\n");
	auto mats = parseMain(
		"@Action\na.x;\n1;\n@\n"
		"@Merge\npath;\n  sub/g.once.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0];
	TH_CHECK(act.cols() == 3);	/* a.x ∪ g.x ∪ h.x（h 经片段相对基准解析成功） */
	TH_CHECK(fx::cell(act, 1, 2) == "9");
}

/* ---------------- @if 保序与片段拒绝（2026-10-10 @if 特性） ---------------- */

TH_TEST(mtinclude_action_anchor_preserves_written_order) {
	/* 主脚本 @Action 与 @if/未知块混排：合并 @Action 锚在主脚本第一个
	 * @Action 块的书写位置，其余块按原序透传——runAction 按书写顺序
	 * 交错执行 "Action"/"if(...)" 名块，顺序在这里保不住就没有块级
	 * 条件语义。 */
	auto mats = parseMain(
		"@Vars\nname value;\n k 1;\n@\n"
		"@if(k>0)\nleg.angle;\n 90;\n@\n"
		"@Action\nleg.angle;\n 45;\n@\n"
		"@Unknown\nx;\n 1;\n@\n");
	mtinclude::expandIncludes(mats, ".");
	std::vector<std::string> names;
	for (const auto& m : mats) { names.push_back(bot::trim(m.getName())); }
	/* Vars 在前（注册先于执行），if 锚回其书写位（Action 之前），未知块殿后 */
	TH_CHECK((names == std::vector<std::string>{"Vars", "if(k>0)", "Action", "Unknown"}));
}

TH_TEST(mtinclude_action_anchor_when_no_main_action) {
	/* 主脚本没有 @Action（动作全靠片段供给）：合并 @Action 维持旧位置
	 * （紧随 Vars、透传块之前）——书写上 if 块与「看不见的合并 Action」
	 * 无顺序直觉可言，维持现状位即可。 */
	fx::TempDir dir("inc_anchor");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@Merge\npath;\n b.mt;\n@\n"
		"@if(k>0)\nleg.angle;\n 90;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	std::vector<std::string> names;
	for (const auto& m : mats) { names.push_back(bot::trim(m.getName())); }
	TH_CHECK((names == std::vector<std::string>{"Action", "if(k>0)"}));
}

TH_TEST(mtinclude_fragment_rejects_if_block) {
	/* 片段里的 @if 响亮拒绝：片段的 @Action 按相位归并进主脚本，@if
	 * 没有自然执行位置——静默丢弃是 @Reflex 已踩过的坑，新块不重蹈。 */
	fx::TempDir dir("inc_reject_if");
	writeFile(dir, "frag.mt", "@if(k>0)\nb.p;\n 100;\n@\n");
	auto mats = parseMain("@Merge\npath;\n frag.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "@if 块不支持出现在 @Merge 片段",
		mtinclude::expandIncludes(mats, dir.path().string()));
	/* 非法形态（未闭合）同样拒下——宽松判据宁拒勿丢 */
	writeFile(dir, "bad.mt", "@if(k>0\nb.p;\n 100;\n@\n");
	auto mats2 = parseMain("@Merge\npath;\n bad.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "@if 块不支持出现在 @Merge 片段",
		mtinclude::expandIncludes(mats2, dir.path().string()));
}

/* ---------------- @Include：C 式内容拷贝（2026-10-12，顶层专属）---------------- */

TH_TEST(mtinclude_include_splices_target_content_inline) {
	/* @Include 把目标文件的顶层矩阵原样插到块的位置（不归并、不改写），
	 * 与 @Merge 的相位归并相对：这里主脚本与片段各有一个 @Action，拷贝后
	 * 两个 @Action 并存（execSequence 依序各自派发）。 */
	fx::TempDir dir("inc_splice");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@Include\npath;\n  b.mt;\n@\n@Action\na.x;\n1;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 2);
	TH_CHECK(bot::trim(mats[0].getName()) == "Action");	/* 拷贝内容在前（@Include 位置） */
	TH_CHECK(bot::trim(mats[1].getName()) == "Action");
	TH_CHECK(fx::cell(mats[0], 0, 0) == "b.p");
	TH_CHECK(fx::cell(mats[1], 0, 0) == "a.x");
}

TH_TEST(mtinclude_include_splices_recursively_fragment_relative) {
	/* 被拷贝内容里的 @Include 以【该文件自身目录】为基准递归展开（库片段可搬移）。 */
	fx::TempDir dir("inc_splice_rec");
	writeFile(dir, "sub/inner.mt", "@Action\ni.p;\n1;\n@\n");
	writeFile(dir, "mid.mt", "@Include\npath;\n  sub/inner.mt;\n@\n@Action\nm.p;\n2;\n@\n");
	auto mats = parseMain("@Include\npath;\n  mid.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 2);
	TH_CHECK(fx::cell(mats[0], 0, 0) == "i.p");	/* 递归拷贝：inner 在前 */
	TH_CHECK(fx::cell(mats[1], 0, 0) == "m.p");
}

TH_TEST(mtinclude_include_copies_control_blocks_verbatim) {
	/* 与 @Merge 片段拒绝控制块不同：@Include 是纯拷贝，可原样搬运 @if/@while
	 * 子块（含其 children）——拷贝进来的控制块由 execSequence 正常执行。 */
	fx::TempDir dir("inc_splice_ctrl");
	writeFile(dir, "c.mt", "@if(k>0)\nleg.p;\n 90;\n@\n");
	auto mats = parseMain("@Include\npath;\n  c.mt;\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 1);
	TH_CHECK(bot::trim(mats[0].getName()) == "if(k>0)");
	TH_CHECK(mats[0].hasChildren());
}

TH_TEST(mtinclude_include_rejects_phase_column) {
	/* @Include 是内容拷贝，phase 无意义：出现 phase 列响亮拒绝并指引 @Merge。 */
	fx::TempDir dir("inc_splice_phase");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@Include\npath phase;\n  b.mt 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "does not accept a 'phase'",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_include_rejects_nested_in_control_block) {
	/* @Include 只能暴露在最外层（像 C 的 #include）：出现在 @if/@while 子块内即拒。 */
	fx::TempDir dir("inc_splice_nested");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@if(k>0)\n@Include\npath;\n  b.mt;\n@\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "只能出现在最外层",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

/* ---------------- Phase C：嵌套 @Merge 位置局部归并 ---------------- */

TH_TEST(mtinclude_merge_nested_merges_into_table_below) {
	/* @if 子块内的 @Merge：把目标纯矩阵并入【同序列紧邻其下的那张叶子表】，
	 * @Merge 块被消费掉；结果仍是控制块，children 只剩归并后的 @Action。 */
	fx::TempDir dir("merge_nested_ok");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@Action\nx.p;\n1;\n@\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats.size() == 1);
	TH_CHECK(bot::trim(mats[0].getName()) == "if(k>0)");
	TH_CHECK(mats[0].children().size() == 1);
	const mt::MatrixObject& act = mats[0].children()[0];
	TH_CHECK(bot::trim(act.getName()) == "Action");
	TH_CHECK(act.cols() == 2);
	TH_CHECK(fx::cell(act, 0, 0) == "x.p");
	TH_CHECK(fx::cell(act, 0, 1) == "b.p");
	TH_CHECK(fx::cell(act, 1, 0) == "1");
	TH_CHECK(fx::cell(act, 1, 1) == "100");
}

TH_TEST(mtinclude_merge_nested_phase_lags_target) {
	/* 嵌套 @Merge 复用 mergeTwo 的相位补 '-'：phase=1 使目标整体滞后一行。 */
	fx::TempDir dir("merge_nested_phase");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@if(k>0)\n@Merge\npath phase;\n  b.mt 1;\n@\n@Action\nx.p;\n1;\n2;\n@\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	const mt::MatrixObject& act = mats[0].children()[0];
	TH_CHECK(act.rows() == 3);			/* 表头 + 2 数据行 */
	TH_CHECK(fx::cell(act, 1, 1) == "-");	/* r=1: rn=0 越界 → 补 '-' */
	TH_CHECK(fx::cell(act, 2, 1) == "100");	/* r=2: rn=1 → 目标首行 */
}

TH_TEST(mtinclude_merge_nested_recurses_into_grandchildren) {
	/* 归并 pass 递归下钻：@while > @if > (@Merge + 表) 也能就地归并。 */
	fx::TempDir dir("merge_nested_deep");
	writeFile(dir, "b.mt", "@Action\nb.p;\n7;\n@\n");
	auto mats = parseMain(
		"@while(c>0)\n@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@Action\nx.p;\n1;\n@\n@\n@\n");
	mtinclude::expandIncludes(mats, dir.path().string());
	TH_CHECK(mats[0].children().size() == 1);			/* @while → [@if] */
	const mt::MatrixObject& inner = mats[0].children()[0];
	TH_CHECK(bot::trim(inner.getName()) == "if(k>0)");
	TH_CHECK(inner.children().size() == 1);				/* @Merge 已消费 */
	TH_CHECK(fx::cell(inner.children()[0], 0, 1) == "b.p");
	TH_CHECK(fx::cell(inner.children()[0], 1, 1) == "7");
}

TH_TEST(mtinclude_merge_nested_rejects_control_block_below) {
	/* 「下表」是控制块（有 children）而非纯矩阵叶子：响亮拒绝，不静默丢弃。 */
	fx::TempDir dir("merge_nested_ctrlbelow");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain(
		"@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@while(j>0)\nx.p;\n1;\n@\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "必须紧跟一张纯矩阵表",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_merge_nested_rejects_scalar_in_target) {
	/* 目标文件携带 @Vars：嵌套归并不注册标量，响亮拒绝并指引挪到最外层。 */
	fx::TempDir dir("merge_nested_vars");
	writeFile(dir, "b.mt", "@Vars\nname v;\nk 5;\n@\n@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@Action\nx.p;\n1;\n@\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "目标只能是纯矩阵表",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_merge_nested_device_conflict_rejected) {
	/* 设备集相交仍由 mergeTwo 单点报错（嵌套与顶层同一严格风格）。 */
	fx::TempDir dir("merge_nested_conflict");
	writeFile(dir, "b.mt", "@Action\nx.p;\n100;\n@\n");	/* 与下表同设备 x */
	auto mats = parseMain("@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@Action\nx.p;\n1;\n@\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "appears in both scripts",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_merge_nested_without_table_below_rejected) {
	/* @Merge 出现在 children 序列末尾、下面没有表可并：响亮拒绝。 */
	fx::TempDir dir("merge_nested_notable");
	writeFile(dir, "b.mt", "@Action\nb.p;\n100;\n@\n");
	auto mats = parseMain("@if(k>0)\n@Merge\npath;\n  b.mt;\n@\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "没有可归并的纯矩阵表",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

TH_TEST(mtinclude_include_self_cycle_terminates_at_row_budget) {
	/* C 式拷贝允许重复包含、故不设 visited 集；自包含靠行数预算响亮终止
	 * （每层递归消耗一行 @Include，触达 kMaxIncludes 即报错，不无限递归/不 OOM）。 */
	fx::TempDir dir("inc_splice_cycle");
	writeFile(dir, "self.mt", "@Include\npath;\n  self.mt;\n@\n");
	auto mats = parseMain("@Include\npath;\n  self.mt;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeding the limit of",
		mtinclude::expandIncludes(mats, dir.path().string()));
}

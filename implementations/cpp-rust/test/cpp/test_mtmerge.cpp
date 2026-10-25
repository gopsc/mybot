/* test_mtmerge.cpp —— .mt 动作脚本归并核心白盒单测（F1/N-30）
 *
 * mtmerge 此前是唯一有独立编译目标却零白盒单测的模块：归并算法、相位补 "-"、
 * 设备集相交/列头校验只能靠 shell 黑盒间接覆盖，改一行归并逻辑要等端到端
 * 合成产物被运行端另解才暴露。核心抽到 mtmerge_core 后，这里逐条钉住语义：
 *   - 列 = A 全列（原序）∪ B 全列（原序）；行相位 p>0 滞后、p<0 提前；
 *   - 较短一方耗尽后补字面 "-"（继承链自然延伸）；
 *   - 负相位部分丢弃只告警、全部丢弃抛错（N-8：拒绝静默丢动作）；
 *   - 设备集相交、列头非 <device>.<param>、@Alias/@Vars 列头/同名行冲突均报错。
 */

#include <cstdint>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "matrix.hpp"
#include "mtmerge_core.hpp"
#include "util_except.hpp"
#include "util_str.hpp"

/* @Action 片段：两列 a.* / b.*，n 个数据行（值 = 行号） */
static mt::MatrixObject actionA(int n, const std::string& dev = "a") {
	std::string t = "@Action\n" + dev + ".x " + dev + ".y;\n";
	for (int r = 1; r <= n; ++r) {
		t += std::to_string(r * 10) + " " + std::to_string(r * 10 + 1) + ";\n";
	}
	t += "@\n";
	return fx::oneMatrix(t);
}

static mt::MatrixObject actionB(int n, const std::string& dev = "b") {
	std::string t = "@Action\n" + dev + ".p;\n";
	for (int r = 1; r <= n; ++r) { t += std::to_string(r * 100) + ";\n"; }
	t += "@\n";
	return fx::oneMatrix(t);
}

/* ---------------- mergeTwo：列拼接与相位 ---------------- */

TH_TEST(mtmerge_merge_two_concatenates_columns_and_pads_tail) {
	/* A 3 行、B 1 行、相位 0：B 耗尽后补 "-"，列序 = A 全列 ∪ B 全列 */
	mt::MatrixObject out = mtmerge::mergeTwo(actionA(3), actionB(1), 0, "a.mt", "b.mt");
	TH_CHECK(out.cols() == 3);
	TH_CHECK(fx::cell(out, 0, 0) == "a.x");
	TH_CHECK(fx::cell(out, 0, 1) == "a.y");
	TH_CHECK(fx::cell(out, 0, 2) == "b.p");
	TH_CHECK(out.rows() == 4);	/* 表头 + 3 数据行 */
	TH_CHECK(fx::cell(out, 1, 2) == "100");
	TH_CHECK(fx::cell(out, 2, 2) == "-");	/* B 已耗尽 */
	TH_CHECK(fx::cell(out, 3, 2) == "-");
	TH_CHECK(fx::cell(out, 3, 0) == "30");
}

TH_TEST(mtmerge_merge_two_positive_phase_lags_second_input) {
	/* 相位 +2：B 整体滞后 2 行，前导补 "-"，总行数 = max(2, 2+2) = 4 */
	mt::MatrixObject out = mtmerge::mergeTwo(actionA(2), actionB(2), 2, "a.mt", "b.mt");
	TH_CHECK(out.rows() == 5);
	TH_CHECK(fx::cell(out, 1, 2) == "-");
	TH_CHECK(fx::cell(out, 2, 2) == "-");
	TH_CHECK(fx::cell(out, 3, 2) == "100");
	TH_CHECK(fx::cell(out, 4, 2) == "200");
	/* A 侧后两行耗尽补 "-" */
	TH_CHECK(fx::cell(out, 3, 0) == "-");
	TH_CHECK(fx::cell(out, 4, 0) == "-");
}

TH_TEST(mtmerge_merge_two_negative_phase_advances_and_warns) {
	/* 相位 -2：B 前 2 行移出输出窗口（部分丢弃 → stderr 告警，产物仍含 B 的其余行）。
	 * next 侧行号 = r - phase = r + 2，故 r=1 取 B 的第 3 行。 */
	std::ostringstream cap;
	std::streambuf* old = std::cerr.rdbuf(cap.rdbuf());
	mt::MatrixObject out = mtmerge::mergeTwo(actionA(3), actionB(3), -2, "a.mt", "b.mt");
	std::cerr.rdbuf(old);

	TH_CHECK(out.rows() == 4);	/* max(3, 3-2) = 3 数据行 */
	TH_CHECK(fx::cell(out, 1, 2) == "300");
	TH_CHECK(fx::cell(out, 2, 2) == "-");
	TH_CHECK(fx::cell(out, 3, 2) == "-");
	const std::string warn = cap.str();
	TH_CHECK(warn.find("前 2 行被丢弃") != std::string::npos);
}

TH_TEST(mtmerge_merge_two_negative_phase_dropping_all_rows_throws) {
	/* N-8：负相位把某个输入**全部**丢弃 → 产物不含该输入任何动作，必须报错退出 2 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "drops all 2 row(s)",
		mtmerge::mergeTwo(actionA(2), actionB(2), -2, "a.mt", "b.mt"));
	/* 相位超出 B 行数同样全丢 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "drops all 2 row(s)",
		mtmerge::mergeTwo(actionA(5), actionB(2), -9, "a.mt", "b.mt"));
}

/* ---------------- checkDisjoint / 列头切分 ---------------- */

TH_TEST(mtmerge_rejects_device_present_in_both_inputs) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "device 'a' appears in both scripts",
		mtmerge::mergeTwo(actionA(1, "a"), actionB(1, "a"), 0, "a.mt", "b.mt"));
}

TH_TEST(mtmerge_rejects_multi_dot_action_column) {
	/* 列头必须恰好一个点；多点在 checkDisjoint 的切分处即报错 */
	mt::MatrixObject bad = fx::oneMatrix("@Action\na.b.c;\n1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not valid",
		mtmerge::mergeTwo(bad, actionB(1), 0, "a.mt", "b.mt"));
}

TH_TEST(mtmerge_rejects_column_without_dot) {
	mt::MatrixObject bad = fx::oneMatrix("@Action\nnopoint;\n1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not valid",
		mtmerge::mergeTwo(actionA(1), bad, 0, "a.mt", "b.mt"));
}

/* ---------------- mergeScalarRows：@Alias / @Vars 按行叠加 ---------------- */

TH_TEST(mtmerge_scalar_rows_concatenates_in_order) {
	mt::MatrixObject a = fx::oneMatrix("@Alias\nname value;\nka 1;\nkb 2;\n@\n");
	mt::MatrixObject b = fx::oneMatrix("@Alias\nname value;\nkc 3;\n@\n");
	mt::MatrixObject out = mtmerge::mergeScalarRows(a, b, "Alias", "a.mt", "b.mt");
	TH_CHECK(out.getName() == "Alias");
	TH_CHECK(out.rows() == 4);
	TH_CHECK(fx::cell(out, 1, 0) == "ka");
	TH_CHECK(fx::cell(out, 2, 0) == "kb");
	TH_CHECK(fx::cell(out, 3, 0) == "kc");
	TH_CHECK(fx::cell(out, 3, 1) == "3");
}

TH_TEST(mtmerge_scalar_rows_rejects_column_count_mismatch) {
	mt::MatrixObject a = fx::oneMatrix("@Alias\nname value;\nka 1;\n@\n");
	mt::MatrixObject b = fx::oneMatrix("@Alias\nname;\nkc;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "column count differs",
		mtmerge::mergeScalarRows(a, b, "Alias", "a.mt", "b.mt"));
}

TH_TEST(mtmerge_scalar_rows_rejects_header_mismatch) {
	mt::MatrixObject a = fx::oneMatrix("@Alias\nname value;\nka 1;\n@\n");
	mt::MatrixObject b = fx::oneMatrix("@Alias\nname alias;\nkc 3;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "header differs at column 1",
		mtmerge::mergeScalarRows(a, b, "Alias", "a.mt", "b.mt"));
}

TH_TEST(mtmerge_scalar_rows_rejects_missing_name_column) {
	/* 没有 'name' 列就无法判重（同名映射到两个不同值本是歧义） */
	mt::MatrixObject a = fx::oneMatrix("@Vars\nkey value;\nka 1;\n@\n");
	mt::MatrixObject b = fx::oneMatrix("@Vars\nkey value;\nkb 2;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "has no 'name' column",
		mtmerge::mergeScalarRows(a, b, "Vars", "a.mt", "b.mt"));
}

TH_TEST(mtmerge_scalar_rows_rejects_duplicate_name) {
	mt::MatrixObject a = fx::oneMatrix("@Alias\nname value;\nka 1;\n@\n");
	mt::MatrixObject b = fx::oneMatrix("@Alias\nname value;\nka 9;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "duplicate Alias name 'ka'",
		mtmerge::mergeScalarRows(a, b, "Alias", "a.mt", "b.mt"));
}

/* ---------------- foldNamed：同一输入内的多个同名块 ---------------- */

TH_TEST(mtmerge_fold_named_folds_multiple_blocks) {
	/* 一个 .mt 里出现两个 @Alias 块：mybot 会全部注册，mtmerge 不得只看第一个 */
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Alias\nname value;\nka 1;\n@\n"
		"@Alias\nname value;\nkb 2;\n@\n");
	auto folded = mtmerge::foldNamed(mats, "Alias", "x.mt");
	TH_CHECK(folded.has_value());
	TH_CHECK(folded->rows() == 3);
	TH_CHECK(fx::cell(*folded, 1, 0) == "ka");
	TH_CHECK(fx::cell(*folded, 2, 0) == "kb");
}

TH_TEST(mtmerge_fold_named_returns_nullopt_when_absent) {
	std::vector<mt::MatrixObject> mats = fx::manyMatrices("@Action\na.x;\n1;\n@\n");
	TH_CHECK(!mtmerge::foldNamed(mats, "Alias", "x.mt").has_value());
	TH_CHECK(!mtmerge::foldNamed(mats, "Vars", "x.mt").has_value());
}

TH_TEST(mtmerge_fold_named_rejects_duplicate_across_blocks) {
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Vars\nname value;\nka 1;\n@\n"
		"@Vars\nname value;\nka 2;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "duplicate Vars name 'ka'",
		mtmerge::foldNamed(mats, "Vars", "x.mt"));
}

/* ---------------- requireAction ---------------- */

TH_TEST(mtmerge_require_action_rejects_missing_action) {
	std::vector<mt::MatrixObject> mats = fx::manyMatrices("@Alias\nname value;\nka 1;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no @Action matrix found",
		mtmerge::requireAction(mats, "x.mt"));
}

TH_TEST(mtmerge_require_action_accepts_trimmed_name) {
	/* 矩阵名解析后可能带空白，findByName 按 trim 后比较（与运行端同一单点）。
	 * 按值取结果：GCC 的 -Wdangling-reference 启发式会对「返回引用的函数」误报，
	 * 这里本就不需要引用语义。 */
	std::vector<mt::MatrixObject> mats = fx::manyMatrices("@Action\na.x;\n1;\n@\n");
	mt::MatrixObject act = mtmerge::requireAction(mats, "x.mt");
	TH_CHECK(bot::trim(act.getName()) == "Action");
}

/* ---------------- F3-6①：归并代数律属性测试（seed 固定、探针可红） ----------------
 * 交换性经推导**不成立**且是设计事实：列序恒「左 ∪ 右」；相位有方向性
 * （next 恒滞后 phase 行）——用判别用例钉住该否定，防实现漂移成「排序列/
 * 对称相位」而无人察觉。成立的是**相位复合恒等式**：
 *   merge(merge(A,B,p1),C,p2) ≡ merge(A, merge(B,C,p2-p1), p1)  （p2 ≥ p1 ≥ 0）
 * 推导：三侧行 r 的取值均为 A_r、B_{r-p1}、C_{r-p2}（越界补 "-"），列序均
 * A,B,C，总行数 = max(rowsA, rowsB+p1, rowsC+p2)。约束 p2≥p1≥0 保证两处
 * 内层相位均非负（负相位的丢弃告警/报错会污染产物语义，不在本性质范围）。
 * 随机构造（seed 写死）批量验证 + p1=p2=0 退化真结合律。判别性：相位取错
 * 侧 / 列序漂移 / 总行数算错，任一回归都会红。 */

static mt::MatrixObject actionN(const std::string& dev, int rows, int cols, int seed) {
	std::string t = "@Action\n";
	for (int c = 0; c < cols; ++c) { t += (c ? " " : "") + std::string(dev + ".p" + std::to_string(c)); }
	t += ";\n";
	for (int r = 1; r <= rows; ++r) {
		for (int c = 0; c < cols; ++c) {
			/* 值避开 "-"：两位数即可（0x/引号/负号都不碰） */
			t += (c ? " " : "") + std::to_string((seed * 31 + r * 7 + c * 3) % 90 + 10);
		}
		t += ";\n";
	}
	t += "@\n";
	return fx::oneMatrix(t);
}

static bool sameMatrix(const mt::MatrixObject& x, const mt::MatrixObject& y) {
	if (x.getName() != y.getName() || x.rows() != y.rows() || x.cols() != y.cols()) { return false; }
	for (std::size_t r = 0; r < x.rows(); ++r) {
		for (std::size_t j = 0; j < x.cols(); ++j) {
			if (fx::cell(x, r, j) != fx::cell(y, r, j)) { return false; }
		}
	}
	return true;
}

TH_TEST(mtmerge_phase_composition_identity_property) {
	/* 相位复合恒等式：随机形状/相位（p2≥p1≥0，seed 由迭代号确定）批量验证 */
	std::string bad;
	for (int iter = 0; iter < 60 && bad.empty(); ++iter) {
		mt::MatrixObject A = actionN("a", 1 + (iter * 3) % 5, 2, iter);
		mt::MatrixObject B = actionN("b", 1 + (iter * 2) % 4, 1, iter + 100);
		mt::MatrixObject C = actionN("c", 1 + iter % 3, 2, iter + 200);
		std::int64_t p1 = iter % 4;
		std::int64_t p2 = p1 + iter % 3;	/* p2 ≥ p1 ≥ 0：内层相位 p2-p1 非负 */
		mt::MatrixObject left = mtmerge::mergeTwo(
			mtmerge::mergeTwo(A, B, p1, "a.mt", "b.mt"), C, p2, "ab.mt", "c.mt");
		mt::MatrixObject right = mtmerge::mergeTwo(
			A, mtmerge::mergeTwo(B, C, p2 - p1, "b.mt", "c.mt"), p1, "a.mt", "bc.mt");
		if (!sameMatrix(left, right)) {
			bad = "iter=" + std::to_string(iter) + " p1=" + std::to_string(p1)
				+ " p2=" + std::to_string(p2);
		}
	}
	if (!bad.empty()) { std::cerr << "相位复合恒等式破坏：" << bad << "\n"; }
	TH_CHECK(bad.empty());
}

TH_TEST(mtmerge_zero_phase_degenerates_to_associativity) {
	/* p1=p2=0：复合恒等式退化为真结合律（产物完全相等，含列序 A,B,C） */
	std::string bad;
	for (int iter = 0; iter < 20 && bad.empty(); ++iter) {
		mt::MatrixObject A = actionN("a", 1 + iter % 4, 2, iter);
		mt::MatrixObject B = actionN("b", 1 + (iter + 1) % 3, 1, iter + 50);
		mt::MatrixObject C = actionN("c", 1 + iter % 3, 2, iter + 90);
		mt::MatrixObject left = mtmerge::mergeTwo(
			mtmerge::mergeTwo(A, B, 0, "a.mt", "b.mt"), C, 0, "ab.mt", "c.mt");
		mt::MatrixObject right = mtmerge::mergeTwo(
			A, mtmerge::mergeTwo(B, C, 0, "b.mt", "c.mt"), 0, "a.mt", "bc.mt");
		if (!sameMatrix(left, right)) { bad = "iter=" + std::to_string(iter); }
	}
	if (!bad.empty()) { std::cerr << "零相位结合律破坏：" << bad << "\n"; }
	TH_CHECK(bad.empty());
}

TH_TEST(mtmerge_commutativity_intentionally_not_held) {
	/* 判别性否定：相位 +1 时 next 侧滞后——merge(A,B,1) 里 B 的首个动作在第
	 * 2 数据行，merge(B,A,1) 里 A 的首个动作在第 2 数据行，逐设备序列不同。
	 * 若未来实现「对称化」相位或排序列，本用例即红——那是语义变更，须过
	 * docs/dsl.md 与 @Merge 语义重审，不得静默发生。 */
	mt::MatrixObject l = mtmerge::mergeTwo(actionA(3), actionB(2), 1, "a.mt", "b.mt");
	mt::MatrixObject r = mtmerge::mergeTwo(actionB(2), actionA(3), 1, "b.mt", "a.mt");
	TH_CHECK(!sameMatrix(l, r));
	/* 相位 0 时逐设备序列虽相同，列序仍是「左 ∪ 右」而非排序——表头即异 */
	mt::MatrixObject l0 = mtmerge::mergeTwo(actionA(2), actionB(2), 0, "a.mt", "b.mt");
	mt::MatrixObject r0 = mtmerge::mergeTwo(actionB(2), actionA(2), 0, "b.mt", "a.mt");
	TH_CHECK(fx::cell(l0, 0, 0) == "a.x");
	TH_CHECK(fx::cell(r0, 0, 0) == "b.p");
	TH_CHECK(!sameMatrix(l0, r0));
}

/* ================= 产物预算（2026-09-21 第七轮审计） =================
 * 输入侧的三道限（@Merge 行数 ≤32、字节 ≤8 MiB、|phase| ≤100000）都在，
 * 而产物侧此前一条都没有：几十字节的脚本写一行 `@Merge path=..., phase=100000`
 * 就能把终态撑到 ~1e5 行 × 数十列（数百 MB），树莓派上 OOM——而 OOM 是 SIGKILL
 * 语义，deactivate() 整体被跳过。判据在 mergeTwo 这个单点，mtmerge 与 @Merge 共用。 */

/* 行列可控的 @Action 夹具：c 列 × r 数据行（值一律填 1，避免文本体积干扰） */
static mt::MatrixObject actionGrid(int r, int c, const std::string& dev) {
	std::string t = "@Action\n";
	for (int j = 0; j < c; ++j) {
		t += dev + ".c" + std::to_string(j);
		t += (j + 1 == c) ? ";\n" : " ";
	}
	t.reserve(t.size() + static_cast<std::size_t>(r) * (2 * c + 2));
	for (int i = 0; i < r; ++i) {
		for (int j = 0; j < c; ++j) { t += (j + 1 == c) ? "1;\n" : "1 "; }
	}
	t += "@\n";
	return fx::oneMatrix(t);
}

TH_TEST(mtmerge_product_budget_rejects_oversized_row_count) {
	/* phase 本身合法（≤ kMaxPhase），越限的是**产物行数** */
	TH_CHECK_THROWS_MSG(std::exception, "exceeding the limit of",
		mtmerge::mergeTwo(actionA(3), actionB(2), mtmerge::kMaxPhase, "a.mt", "b.mt"));
	/* 报错要点名 phase 与实测行数，否则用户只看到"太大"却不知道是哪一侧造成的 */
	try {
		mtmerge::mergeTwo(actionA(3), actionB(2), mtmerge::kMaxPhase, "a.mt", "b.mt");
		TH_CHECK(false);
	} catch (const std::exception& e) {
		const std::string w = e.what();
		TH_CHECK_MSG(w.find(std::to_string(mtmerge::kMaxMergedRows)) != std::string::npos,
			"应给出上限: " + w);
		TH_CHECK_MSG(w.find("phase") != std::string::npos, "应点名相位: " + w);
		TH_CHECK_MSG(w.find("a.mt") != std::string::npos && w.find("b.mt") != std::string::npos,
			"应点名两侧输入: " + w);
	}
}

TH_TEST(mtmerge_product_budget_rejects_oversized_cell_count) {
	/* 行数在上限之内（19999），但列宽把单元格数顶穿：走的是**第二条**判据 */
	TH_CHECK_THROWS_MSG(std::exception, "cell(s)",
		mtmerge::mergeTwo(actionGrid(19999, 2, "a"), actionGrid(3, 10, "b"), 0, "a.mt", "b.mt"));
	try {
		mtmerge::mergeTwo(actionGrid(19999, 2, "a"), actionGrid(3, 10, "b"), 0, "a.mt", "b.mt");
		TH_CHECK(false);
	} catch (const std::exception& e) {
		const std::string w = e.what();
		TH_CHECK_MSG(w.find(std::to_string(mtmerge::kMaxMergedCells)) != std::string::npos,
			"应给出单元格上限: " + w);
		TH_CHECK_MSG(w.find("rows x") != std::string::npos, "应给出实测行×列: " + w);
	}
}

TH_TEST(mtmerge_product_budget_allows_real_world_sizes) {
	/* 仓库内 195 个 .mt 的实测极值是 200 数据行 / 20 列 / 760 单元格；
	 * 这里按"两个这样的片段归并"取 200×40，必须照常通过（余量两个数量级）。 */
	mt::MatrixObject out = mtmerge::mergeTwo(actionGrid(200, 20, "a"), actionGrid(200, 20, "b"),
		0, "a.mt", "b.mt");
	TH_CHECK(out.rows() == 201);		/* 表头 + 200 数据行 */
	TH_CHECK(out.cols() == 40);
}

TH_TEST(mtmerge_product_budget_boundary_is_inclusive) {
	/* 恰好等于上限必须放行：判据是 >，不是 >=（写反会白禁一种合法规模） */
	mt::MatrixObject out = mtmerge::mergeTwo(
		actionGrid(static_cast<int>(mtmerge::kMaxMergedRows), 1, "a"), actionGrid(1, 1, "b"),
		0, "a.mt", "b.mt");
	TH_CHECK(static_cast<std::int64_t>(out.rows()) - 1 == mtmerge::kMaxMergedRows);
}

/* ---------------- 归并 ⟂ 嵌套（2026-10-12 @块嵌套）---------------- */

TH_TEST(mtmerge_merge_two_rejects_control_block_operand) {
	/* 归并操作数必须是纯矩阵叶子表：控制块（@if/@while）自身网格为空、体在
	 * children，当归并操作数会被静默丢弃——mergeTwo 单点响亮拒绝。 */
	mt::MatrixObject ctrl = fx::oneMatrix("@if(a>0)\nx.p;\n 1;\n@\n");
	TH_CHECK(ctrl.hasChildren());	/* 前置：确是控制块 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "nested sub-blocks",
		mtmerge::mergeTwo(ctrl, actionB(1), 0, "ctrl.mt", "b.mt"));
	/* 另一侧含 children 同样拒绝 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "nested sub-blocks",
		mtmerge::mergeTwo(actionA(1), ctrl, 0, "a.mt", "ctrl.mt"));
}

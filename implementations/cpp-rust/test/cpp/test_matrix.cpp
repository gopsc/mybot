/* test_matrix.cpp —— .mt 矩阵解析器（MatrixParser / MatrixObject）
 *
 * 状态机按字符推进，历史上出过三类无声故障，这里逐条钉住：
 *   C5   indexOfCol 未命中的 -1 隐式转 size_t 回绕 → 越界访问报错无指向性
 *   行号计数  注释行 / @Name 行末换行不计数 → DoesNotSync 报错误导
 *   矩阵名污染  多矩阵之间只有单个换行时，残留 nl_/nm_ 把 '@' 吞进名字
 * 另外固化 "-" 占位符的前向填充语义（首数据行不继承，保留字面值）。
 */

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "matrix.hpp"
#include "util_except.hpp"
#include "util_str.hpp"

TH_TEST(matrix_parses_name_rows_and_cols) {
	mt::MatrixObject m = fx::oneMatrix("@Timer\nname period;\nt0 100;\n@\n");
	TH_CHECK(m.hasName());
	TH_CHECK(m.getName() == "Timer");
	TH_CHECK(m.rows() == 2);
	TH_CHECK(m.cols() == 2);
	TH_CHECK(m.indexOfCol(0, "name") == 0);
	TH_CHECK(m.indexOfCol(0, "period") == 1);
	TH_CHECK(m.indexOfCol(0, "nope") == -1);
	TH_CHECK(fx::cell(m, 0, 1) == "period");
	TH_CHECK(fx::cell(m, 1, 0) == "t0");
	TH_CHECK(fx::cell(m, 1, 1) == "100");
}

TH_TEST(matrix_tabs_and_trailing_spaces_are_separators) {
	/* 制表符对齐、行尾多余空格都不应产生空单元格（.mt 常按列对齐手写） */
	mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.a\trelay0.b;\n  200   300 ;  \n@\n");
	TH_CHECK(m.cols() == 2);
	TH_CHECK(m.rows() == 2);
	TH_CHECK(fx::cell(m, 0, 0) == "relay0.a");
	TH_CHECK(fx::cell(m, 0, 1) == "relay0.b");
	TH_CHECK(fx::cell(m, 1, 0) == "200");
	TH_CHECK(fx::cell(m, 1, 1) == "300");
}

TH_TEST(matrix_comment_lines_do_not_shift_line_numbers) {
	const std::string text =
		"@Relay\n"
		"# 表头注释\n"
		"name note;\n"
		"# 数据注释\n"
		"r0 hello;\n"
		"r0;\n"
		"@\n";
	TH_CHECK_THROWS_MSG(mt::DoesNotSync, "we got line: 6", fx::oneMatrix(text));
}

TH_TEST(matrix_comment_start_flushes_pending_cell) {
	/* C-M：注释起始须先提交挂起内容——"50#c\n60" 曾被静默拼成 "5060"，
	 * 动作数值被篡改。注释等价于空白，两侧单元格必须分开（换行本就是
	 * 行内分隔符，行仍由 ';' 收口）。 */
	mt::MatrixObject m = fx::oneMatrix("@Action\na b;\n  50#c\n  60;\n@\n");
	TH_CHECK(m.rows() == 2);
	TH_CHECK(fx::cell(m, 1, 0) == "50");
	TH_CHECK(fx::cell(m, 1, 1) == "60");
	/* 名字行内注释同样不得把注释文本拼进名字（"Ti#mer" 曾变成名字 "Timer"） */
	mt::MatrixObject n = fx::oneMatrix("@Ti#mer\nname;\nt0;\n@\n");
	TH_CHECK(n.getName() == "Ti");
	TH_CHECK(n.rows() == 2);
}

TH_TEST(matrix_match_rows_equality_on_inherited_values) {
	/* WHERE 等值匹配单点（2026-09-23）：SELECT 渲染与未来的 DELETE/UPDATE
	 * 选行共用。比对 inherited 显示值（"-" 继承前向填充后），与全列渲染
	 * 看到的是同一份值；无命中返回空容器（空与缺失分腔：缺失走抛错）。 */
	mt::MatrixObject m = fx::oneMatrix("@T\nname tag;\np0 keep;\np1 -;\np2 drop;\n@\n");
	/* p1 的 '-' 继承自 p0 → inherited 显示 'keep'，与 p0 一并命中 */
	TH_CHECK(mt::matchRows(m, "tag", "keep") == std::vector<std::size_t>({1, 2}));
	TH_CHECK(mt::matchRows(m, "tag", "drop") == std::vector<std::size_t>({3}));
	TH_CHECK(mt::matchRows(m, "name", "p0") == std::vector<std::size_t>({1}));
	TH_CHECK(mt::matchRows(m, "tag", "nope").empty());
	/* 列不存在：requireCol 既有文案（带表名与列名），调用方不必预检 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "has no 'nope' column",
		mt::matchRows(m, "nope", "x"));
}

TH_TEST(matrix_match_all_requires_every_condition) {
	/* 多条件 AND（2026-09-23 热删除）：与 matchRows 一份判据、按 AND 收窄。
	 * 用 controller/channel 这种真实形态做断言，兼作「同名列不同值」的甄别。 */
	mt::MatrixObject m = fx::oneMatrix(
		"@Servo\nname controller channel;\n"
		"s1 c0 1;\n"
		"s2 c0 2;\n"
		"s3 c1 1;\n"
		"@\n");
	using C = std::vector<std::pair<std::string, std::string>>;
	/* 全条件命中：只有 s1 同时满足 c0 与 1 */
	TH_CHECK(mt::matchAll(m, C{{"controller", "c0"}, {"channel", "1"}})
		== std::vector<std::size_t>({1}));
	/* 单条件退化为 matchRows 的语义（同一事实源，不应有任何差异） */
	TH_CHECK(mt::matchAll(m, C{{"controller", "c0"}})
		== mt::matchRows(m, "controller", "c0"));
	/* 条件互相排斥 → 0 命中（不是「任一命中」——这正是 AND 与 OR 的分界） */
	TH_CHECK(mt::matchAll(m, C{{"controller", "c1"}, {"channel", "2"}}).empty());
	/* 空条件表 = 无条件：返回全部数据行（`DELETE FROM t;` 的语义来源） */
	TH_CHECK(mt::matchAll(m, C{}) == std::vector<std::size_t>({1, 2, 3}));
	/* 任一列不存在即抛，报错点名列名（含在第二个条件上的情形） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "has no 'nope' column",
		mt::matchAll(m, C{{"controller", "c0"}, {"nope", "x"}}));
}

TH_TEST(matrix_remove_rows_preserves_surviving_order) {
	/* removeRows（2026-09-23 热删除）的核心不变式：**存活行相对顺序逐字不变**。
	 * 行序即声明序，而销毁序 = 声明序倒序（总线必须晚于挂在它上面的器件关闭
	 * fd），故交换式删除（尾行填空位）会让「删一个中间器件」打乱整条拓扑序，
	 * 且症状要到销毁期才显形。本用例删中间行、断言存活行的相对次序。 */
	mt::MatrixObject m = fx::oneMatrix(
		"@T\nname v;\nr0 a;\nr1 b;\nr2 c;\nr3 d;\n@\n");
	m.removeRows({2});			/* 删 'b'（数据行号 = 矩阵行号，行 0 是列头） */
	TH_CHECK(m.rows() == 4);		/* 列头 + 3 个存活行 */
	TH_CHECK(fx::cell(m, 0, 0) == "name" && fx::cell(m, 0, 1) == "v");
	TH_CHECK(fx::cell(m, 1, 0) == "r0");
	TH_CHECK(fx::cell(m, 2, 0) == "r2");	/* 存活行依次前移，但相对序未变 */
	TH_CHECK(fx::cell(m, 3, 0) == "r3");
	/* 多行一次删（事务按行号集合一次重排，调用方无需排序/倒序）：
	 * 删 r0 与 r2 → 存活 r1、r3，次序不变 */
	mt::MatrixObject n = fx::oneMatrix(
		"@T\nname v;\nr0 a;\nr1 b;\nr2 c;\nr3 d;\n@\n");
	n.removeRows({1, 3});
	TH_CHECK(n.rows() == 3);
	TH_CHECK(fx::cell(n, 1, 0) == "r1");
	TH_CHECK(fx::cell(n, 2, 0) == "r3");
	/* 删空非头行：只剩列头 */
	mt::MatrixObject e = fx::oneMatrix("@T\nname v;\nr0 a;\nr1 b;\n@\n");
	e.removeRows({1, 2});
	TH_CHECK(e.rows() == 1);
	TH_CHECK(e.cols() == 2);
	/* 空集合是 no-op（无条件删除的边界不该走异常路径） */
	e.removeRows({});
	TH_CHECK(e.rows() == 1);
}

TH_TEST(matrix_remove_rows_rejects_misuse) {
	/* 行 0 是列头：删掉会让所有列名定位失效，必须响亮拒绝 */
	mt::MatrixObject m = fx::oneMatrix("@T\nname v;\nr0 a;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "row 0 is the column header",
		m.removeRows({0}));
	/* 越界与重复都是调用方算错：静默容忍会让「删了几行」与生效摘要对不上 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "out of range", m.removeRows({5}));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "listed twice", m.removeRows({1, 1}));
	/* 报错路径不得改动矩阵（先全量校验再重排） */
	TH_CHECK(m.rows() == 2);
	TH_CHECK(fx::cell(m, 1, 0) == "r0");
}

TH_TEST(matrix_remove_rows_invalidates_inheritance_cache) {
	/* inherited 是惰性前向填充的缓存：删行后必须作废，否则查询/派发会读到
	 * 按旧行数算的错位值（缓存不变式的静默破坏）。删掉继承的源头后，
	 * 幸存行的 '-' 不再继承任何值，应原样显示 '-'。 */
	mt::MatrixObject m = fx::oneMatrix("@T\nname tag;\np0 keep;\np1 -;\n@\n");
	TH_CHECK(fx::inh(m, 2, 1) == "keep");	/* 先预热缓存 */
	m.removeRows({1});			/* 删掉继承源头 p0 */
	TH_CHECK(m.rows() == 2);
	TH_CHECK(fx::inh(m, 1, 1) == "-");	/* 行 1 的 '-' 不再有可继承的行 */
	TH_CHECK(mt::matchRows(m, "tag", "keep").empty());
}

TH_TEST(matrix_ragged_row_reports_cell_counts) {
	/* 报错必须自带「这行几格 / 上一行几格」，否则用户只能逐列数空格 */
	TH_CHECK_THROWS_MSG(mt::DoesNotSync, "this row has 1 cell(s), but the row above has 2",
		fx::oneMatrix("@Relay\nname note;\nr0 hello;\nr0;\n@\n"));
	TH_CHECK_THROWS_MSG(mt::DoesNotSync, "this row has 3 cell(s), but the row above has 1",
		fx::oneMatrix("@Relay\nname;\nr0;\na b c;\n@\n"));
}

TH_TEST(matrix_dash_placeholder_forwards_from_previous_row) {
	mt::MatrixObject m = fx::oneMatrix(
		"@Relay\nname note;\nr0 hello;\nr1 -;\nr2 -;\n@\n");
	TH_CHECK(fx::cell(m, 2, 1) == "-");
	TH_CHECK(fx::inh(m, 1, 1) == "hello");
	TH_CHECK(fx::inh(m, 2, 1) == "hello");
	/* 连续多行 "-" 由前向填充一次成型（旧实现是逐格递归，O(n²) 且深栈） */
	TH_CHECK(fx::inh(m, 3, 1) == "hello");
	/* 非占位符原样返回 */
	TH_CHECK(fx::inh(m, 3, 0) == "r2");
}

TH_TEST(matrix_first_data_row_dash_stays_literal) {
	/* 首数据行（row<=1）无可继承，"-" 保留字面值，由调用方决定含义 */
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note;\nr0 -;\n@\n");
	TH_CHECK(fx::cell(m, 1, 1) == "-");
	TH_CHECK(fx::inh(m, 1, 1) == "-");
}

TH_TEST(matrix_inherited_bounds_and_negative_index) {
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note;\nr0 hello;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "out of bounds", fx::inh(m, 9, 0));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "out of bounds", fx::cell(m, 0, 9));
	/* C5 防线：负下标必须直说「大概是缺 name 列」，而不是回绕成天文数字下标 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "negative index", fx::cell(m, -1, 0));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "name", fx::cell(m, 1, -1));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "negative index", fx::inh(m, -1, 1));
}

TH_TEST(matrix_sequential_objects_keep_their_names) {
	/* 矩阵之间只有单个换行：第二个矩阵名不得变成 "@Action" */
	std::vector<mt::MatrixObject> all = fx::manyMatrices(
		"@Timer\nname;\nt0;\n@\n"
		"@Action\ntimer0.delay;\n  50;\n@\n");
	TH_CHECK(all.size() == 2);
	TH_CHECK(all[0].getName() == "Timer");
	TH_CHECK(all[1].getName() == "Action");
	TH_CHECK(all[1].rows() == 2);
	TH_CHECK(fx::cell(all[1], 1, 0) == "50");
}

TH_TEST(matrix_crlf_line_endings_parse_identically) {
	std::vector<mt::MatrixObject> all = fx::manyMatrices(
		"@Timer\r\nname;\r\nt0;\r\n@\r\n@Action\r\ntimer0.delay;\r\n  50;\r\n@\r\n");
	TH_CHECK(all.size() == 2);
	/* 单元格以 ';' 收尾，'\r' 落在行首空白位被吞掉，因此数据格不含 \r；
	 * @Name 行没有 ';'，但 '\r' 同样是块头名字 token 的终止符（@块嵌套起），
	 * 故名字干净不带 \r（裸 "@\r" 也因此判定为闭合而非嵌套）。消费方一律 trim，
	 * 这里仍按 trim 口径断言。 */
	TH_CHECK(bot::trim(all[0].getName()) == "Timer");
	TH_CHECK(bot::trim(all[1].getName()) == "Action");
	TH_CHECK(bot::trim(fx::cell(all[1], 0, 0)) == "timer0.delay");
	TH_CHECK(all[1].cols() == 1);
	TH_CHECK(fx::cell(all[1], 1, 0) == "50");
}

TH_TEST(matrix_blank_input_yields_no_object) {
	bot::MemoryReader empty("");
	mt::MatrixParser p1(empty);
	TH_CHECK(!p1.parse().has_value());

	bot::MemoryReader blanks("\n\n# only a comment\n");
	mt::MatrixParser p2(blanks);
	TH_CHECK(!p2.parse().has_value());
}

TH_TEST(matrix_unclosed_block_at_eof_reports_loudly) {
	/* @块嵌套（2026-10-12）：缺闭合 '@' 直到 EOF——不再静默返回半成品对象，
	 * 而是响亮报错。旧行为（截断脚本仍返回已解析行）正是「内层 @ 被当外层闭合符
	 * → 后续脚本静默截断」的根源，帧栈解析器改为在 EOF 时栈非空即抛。 */
	bot::MemoryReader r("@Timer\nname;\nt0;\n");
	mt::MatrixParser p(r);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "未闭合", p.parse());
}

TH_TEST(matrix_does_not_sync_survives_parser_rethrow) {
	/* parse() 对 MatrixParseExcept 是原样 rethrow：行号与列数信息不得被降级掉 */
	try {
		fx::oneMatrix("@Relay\nname note;\nr0 hello;\nr0;\n@\n");
		::th::reportFailure("应抛出 DoesNotSync", __FILE__, __LINE__, "实际未抛出");
	} catch (const mt::MatrixParseExcept& e) {
		const std::string msg = e.what();
		TH_CHECK(msg.find("Does Not Sync") != std::string::npos);
		TH_CHECK(msg.find("Parse failed at line") == std::string::npos);
		/* 以 std::exception 身份捕获也必须是同一个对象（派生链完整） */
	}
}

TH_TEST(matrix_read_save_roundtrip_preserves_cells) {
	const std::string src = "@Action\nrelay0.test relay1.test;\n   200        100;\n   -          50;\n@\n";
	std::vector<mt::MatrixObject> mats1;
	bot::MemoryReader in1(src);
	mt::readMatrix(in1, mats1);
	TH_CHECK(mats1.size() == 1);
	TH_CHECK(mats1[0].getName() == "Action");
	TH_CHECK(mats1[0].rows() == 3);

	std::ostringstream saved;
	mt::MatrixSaver::save(mats1, saved);

	std::vector<mt::MatrixObject> mats2;
	bot::MemoryReader in2(saved.str());
	mt::readMatrix(in2, mats2);
	TH_CHECK(mats2.size() == 1);
	TH_CHECK(mats2[0].getName() == mats1[0].getName());
	TH_CHECK(mats2[0].rows() == mats1[0].rows());
	TH_CHECK(mats2[0].cols() == mats1[0].cols());
	for (std::size_t r = 0; r < mats1[0].rows(); ++r) {
		for (std::size_t c = 0; c < mats1[0].cols(); ++c) {
			TH_CHECK(mats1[0](r, c) == mats2[0](r, c));
		}
	}
}


TH_TEST(matrix_if_block_name_roundtrip) {
	/* @if(cond) 块名（2026-10-10 特性）+ @块嵌套（2026-10-12）：名字态把
	 * "if(x>0)" 整串收进 name（括号/比较符都是普通字符，块头内无空格）。控制块
	 * 自身网格为空、体在 children——块内直接行合成为一个隐式 @Action 子块。
	 * save() 递归写出 children 后文本 round-trip 不丢；消费端
	 * （ActionRunner::execSequence）递归进入 children 派发。 */
	const std::string src = "@if(x>0)\nleg.angle;\n 90;\n@\n";
	std::vector<mt::MatrixObject> mats1;
	bot::MemoryReader in1(src);
	mt::readMatrix(in1, mats1);
	TH_CHECK(mats1.size() == 1);
	TH_CHECK(mats1[0].getName() == "if(x>0)");
	TH_CHECK(mats1[0].rows() == 0);	/* 控制块自身无网格 */
	TH_CHECK(mats1[0].hasChildren());
	TH_CHECK(mats1[0].children().size() == 1);
	TH_CHECK(mats1[0].children()[0].getName() == "Action");	/* 隐式 @Action 子块 */
	TH_CHECK(mats1[0].children()[0].rows() == 2);
	TH_CHECK(fx::cell(mats1[0].children()[0], 0, 0) == "leg.angle");

	std::ostringstream saved;
	mt::MatrixSaver::save(mats1, saved);
	std::vector<mt::MatrixObject> mats2;
	bot::MemoryReader in2(saved.str());
	mt::readMatrix(in2, mats2);
	TH_CHECK(mats2.size() == 1);
	TH_CHECK(mats2[0].getName() == "if(x>0)");
	TH_CHECK(mats2[0].rows() == 0);
	TH_CHECK(mats2[0].children().size() == 1);
	TH_CHECK(mats2[0].children()[0].rows() == 2);
}

/* ---------------- @块嵌套（2026-10-12）：帧栈解析白盒 ---------------- */

TH_TEST(matrix_nested_control_blocks_build_children_tree) {
	/* @while 内含 @if：控制块自身网格为空，体在 children——while.children=[if]，
	 * if.children=[隐式 @Action(dev.p;1)]。裸 '@' 逐层闭合最内层。 */
	mt::MatrixObject m = fx::oneMatrix(
		"@while(c>0)\n@if(k>0)\ndev.p;\n 1;\n@\n@\n");
	TH_CHECK(m.getName() == "while(c>0)");
	TH_CHECK(m.rows() == 0);
	TH_CHECK(m.children().size() == 1);
	const mt::MatrixObject& inner = m.children()[0];
	TH_CHECK(inner.getName() == "if(k>0)");
	TH_CHECK(inner.children().size() == 1);
	TH_CHECK(inner.children()[0].getName() == "Action");
	TH_CHECK(inner.children()[0].rows() == 2);
	TH_CHECK(fx::cell(inner.children()[0], 0, 0) == "dev.p");
}

TH_TEST(matrix_control_block_interleaves_rows_and_child_blocks) {
	/* 控制块体：连续直接行合成隐式 @Action，遇显式子块打断、其后的直接行再合成
	 * 下一个隐式 @Action——书写顺序如实入列（隐式Action / 显式Action / 隐式Action）。 */
	mt::MatrixObject m = fx::oneMatrix(
		"@if(a>0)\nx.p;\n 1;\n@Action\ny.q;\n 2;\n@\nz.r;\n 3;\n@\n");
	TH_CHECK(m.children().size() == 3);
	TH_CHECK(fx::cell(m.children()[0], 0, 0) == "x.p");
	TH_CHECK(fx::cell(m.children()[1], 0, 0) == "y.q");
	TH_CHECK(fx::cell(m.children()[2], 0, 0) == "z.r");
	for (const auto& c : m.children()) { TH_CHECK(c.getName() == "Action"); }
}

TH_TEST(matrix_leaf_block_cannot_nest) {
	/* 叶子块（@Action/@Alias/@Vars…）的体只能是数据行：内含 @if 响亮拒绝。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "不能嵌套",
		fx::manyMatrices("@Action\nx.p;\n 1;\n@if(k>0)\ny.q;\n 2;\n@\n@\n"));
}

TH_TEST(matrix_extra_bare_at_rejected) {
	/* 栈空时的裸 '@' = 多余闭合符：响亮拒绝（旧机静默忽略，正是内层 @ 被当外层
	 * 闭合符 → 后续静默截断的根源）。 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "多余的 '@'",
		fx::manyMatrices("@\n"));
}

TH_TEST(matrix_block_depth_capped) {
	/* 嵌套深度硬上限 kMaxBlockDepth=32：第 33 层开块响亮拒绝（--tcp 远端脚本
	 * 不能靠深嵌套撑爆帧栈/调用栈）。恰好 32 层仍合法。 */
	auto nest = [](std::size_t n) {
		std::string s;
		for (std::size_t i = 0; i < n; ++i) { s += "@if(a>0)\n"; }
		for (std::size_t i = 0; i < n; ++i) { s += "@\n"; }
		return s;
	};
	TH_CHECK(fx::oneMatrix(nest(mt::kMaxBlockDepth)).getName() == "if(a>0)");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "嵌套深度超过上限",
		fx::manyMatrices(nest(mt::kMaxBlockDepth + 1)));
}

TH_TEST(matrix_final_bare_at_without_newline_still_closes) {
	/* 脚本以裸 '@' 收尾且无尾随换行：EOF 前落定挂起的块头 token，块正常闭合，
	 * 不误报「未闭合」。 */
	mt::MatrixObject m = fx::oneMatrix("@Action\nx.p;\n 1;\n@");
	TH_CHECK(m.getName() == "Action");
	TH_CHECK(m.rows() == 2);
}

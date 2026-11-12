/* test_meta_registry.cpp —— 元数据域门面（MetaRegistry）的直接锚点
 *
 * 这个门面 2026-10-03 阶段 4 才从 RobotStruct 私有容器 metaProviders_ 析出。
 * 它身上的判据全是「热改结构时元数据怎么跟着动」——装配后统一校验 $ 引用
 * （F-05）、热插回滚的尾部截断、热删除的按「矩阵 + 行号」摘除与行号重锚定、
 * 整表撤下的两阶段重锚定。此前只经 test_robot_hotinsert/hotdelete 的集成路径
 * 覆盖：那边看到的是「删一行之后 Lua 拿到的元数据对不对」，一旦红了要在
 * SQL 解析、结构域擦除、注册表撤销、元数据重锚定四层里找；这里把四条判据
 * 直接钉在门面的公开接口上。
 *
 * MetaProvider 自身的收集语义（列跳过规则、字面列冻结、引用列实时快照、
 * destroy 期尽力而为）已由 test_hardware.cpp 的 metaprovider_* 一族覆盖，
 * 本文件不重复，只把它当作被登记的对象使用。
 */

#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "hw_registry.hpp"
#include "matrix.hpp"
#include "meta_provider.hpp"
#include "meta_registry.hpp"

namespace {

using DeadRows = std::set<std::pair<const mt::MatrixObject*, std::int64_t>>;

/* 一张只有字面列的表：n 行数据（行号 1..n），元数据固定是 {"note":"v<i>"}。
 * 不含 $ 引用，故 seed 必然通过——本文件要测的是登记表自己的判据，
 * 不是引用解析（那是 metaprovider_* 的地盘）。 */
mt::MatrixObject literalTable(const std::string& name, std::int64_t rows) {
	std::string text = "@" + name + "\nname note;\n";
	for (std::int64_t i = 0; i < rows; ++i) { text += "r" + std::to_string(i) + " v" + std::to_string(i) + ";\n"; }
	return fx::oneMatrix(text + "@\n");
}

std::shared_ptr<bot::MetaProvider> prov(const mt::MatrixObject& m, std::int64_t row,
		const bot::HwRegistry* reg) {
	return std::make_shared<bot::MetaProvider>(m, row, reg);
}

} // namespace

TH_TEST(metaregistry_add_keeps_registration_order) {
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	TH_CHECK(metas.empty());
	TH_CHECK(metas.size() == 0);

	mt::MatrixObject m = literalTable("A", 2);
	auto p1 = prov(m, 1, &reg);
	auto p2 = prov(m, 2, &reg);
	metas.add(p1);
	metas.add(p2);

	TH_CHECK(!metas.empty());
	TH_CHECK(metas.size() == 2);
	TH_CHECK(metas.all().size() == 2);
	TH_CHECK(metas.all()[0] == p1);		/* 登记序 = 装配序 */
	TH_CHECK(metas.all()[1] == p2);
}

TH_TEST(metaregistry_validate_from_only_checks_the_incremental_tail) {
	/* F-05：装配完成后、任何 build 之前统一校验 $ 引用存在性。增量路径只查
	 * [from, size)——本批次新增的既有提供者启动期已校验过，不必再撞一遍。 */
	mt::MatrixObject good = literalTable("Good", 1);
	mt::MatrixObject bad = fx::oneMatrix("@Bad\nname src;\nr0 $ghost;\n@\n");
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	metas.add(prov(bad, 1, &reg));		/* 下标 0：坏的在前 */
	metas.add(prov(good, 1, &reg));		/* 下标 1：好的在后 */

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not defined", metas.validateAll());
	/* 从 1 起：跳过坏的那个，不抛（抛了就说明增量路径没按 from 收窄） */
	metas.validateFrom(1);
	/* from 越界是空转，不是 UB——热插批次为空时调用方就是传 size() */
	metas.validateFrom(metas.size());
	metas.validateFrom(metas.size() + 5);
	TH_CHECK(metas.size() == 2);
}

TH_TEST(metaregistry_drop_rows_matches_on_matrix_and_row_pair) {
	/* 判据是「矩阵地址 + 行号」这一对，不是提供者身份、也不是单看行号：
	 * 矩阵是 StructureStore 里 deque 的元素、地址稳定，故该判据精确且不受
	 * 行数变化影响；而同一个行号在两张表上是两个不同的身份。 */
	mt::MatrixObject mA = literalTable("A", 2);
	mt::MatrixObject mB = literalTable("B", 2);
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	auto a1 = prov(mA, 1, &reg);
	auto a2 = prov(mA, 2, &reg);
	auto b1 = prov(mB, 1, &reg);
	metas.add(a1);
	metas.add(a2);
	metas.add(b1);

	metas.dropRows(DeadRows{{&mA, 1}});

	TH_CHECK(metas.size() == 2);
	TH_CHECK(metas.all()[0] == a2);
	TH_CHECK(metas.all()[1] == b1);		/* 同行号、不同矩阵 → 存活 */
	/* 登记序不被摘除打乱（存活者相对顺序不动） */
}

TH_TEST(metaregistry_shift_rows_after_reanchors_later_rows_of_one_matrix) {
	/* 结构域的 removeRows 是**保序擦除**：同矩阵内位于被删行之后的行会前移，
	 * 锚定这些行的提供者必须同步减行号——row() 是后续批次 deadProvider 判据
	 * 的坐标与惰性取行的下标，过期即摘错/漏摘。判据是**严格小于**。 */
	mt::MatrixObject mA = literalTable("A", 5);
	mt::MatrixObject mB = literalTable("B", 5);
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	auto a1 = prov(mA, 1, &reg);
	auto a4 = prov(mA, 4, &reg);
	auto a5 = prov(mA, 5, &reg);
	auto b4 = prov(mB, 4, &reg);
	metas.add(a1);
	metas.add(a4);
	metas.add(a5);
	metas.add(b4);

	metas.shiftRowsAfter(&mA, {1, 2});	/* 删掉 mA 的原始行 1 与 2 */

	TH_CHECK(a1->row() == 1);			/* 1、2 都不严格小于 1 → 不动 */
	TH_CHECK(a4->row() == 2);			/* 前移两格 */
	TH_CHECK(a5->row() == 3);
	TH_CHECK(b4->row() == 4);			/* 另一张矩阵一字不动 */
	TH_CHECK(a4->matrixPtr() == &mA);	/* 只动行号，不动矩阵锚 */
	/* row() 同时是**惰性取行的下标**：重锚定之后再 collect，读到的是新坐标
	 * 那一行（原行 4 的 "v3" 已随擦除前移到行 2 的位置），不是缓存里的旧值。 */
	TH_CHECK(a4->collect().toString() == R"({"note":"v1"})");
}

TH_TEST(metaregistry_truncate_rolls_back_only_the_batch_tail) {
	/* 热插回滚：丢弃本批次新增的登记，既有提供者一个不少。 */
	mt::MatrixObject m = literalTable("A", 4);
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	auto p1 = prov(m, 1, &reg);
	auto p2 = prov(m, 2, &reg);
	auto p3 = prov(m, 3, &reg);
	auto p4 = prov(m, 4, &reg);
	metas.add(p1);
	metas.add(p2);
	const std::size_t mark = metas.size();
	metas.add(p3);
	metas.add(p4);
	TH_CHECK(metas.size() == 4);

	metas.truncate(mark);

	TH_CHECK(metas.size() == 2);
	TH_CHECK(metas.all()[0] == p1);
	TH_CHECK(metas.all()[1] == p2);
	metas.truncate(0);
	TH_CHECK(metas.empty());
}

TH_TEST(metaregistry_rebase_by_name_follows_a_table_to_its_new_address) {
	/* 整表撤下（DROP TABLE）的两阶段重锚定：deque 整表 erase 会让其后所有元素
	 * 引用失效，而提供者的表名只能经 matrix_ 读到，故必须 ① erase **之前**抓
	 * 表名（此刻 matrix_ 仍有效）、② erase **之后**按稳定身份锚回新地址。 */
	const std::string text = "@A\nname note;\nr0 v0;\n@\n";
	mt::MatrixObject mOld = fx::oneMatrix(text);
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	auto p = prov(mOld, 1, &reg);
	metas.add(p);
	TH_CHECK(p->matrixPtr() == &mOld);
	const std::string before = p->collect().toString();

	const bot::MetaRegistry::TableNameSnapshot snapshot = metas.captureTableNames();
	TH_CHECK(snapshot.size() == 1);
	TH_CHECK(snapshot[0].first == p.get());
	TH_CHECK(snapshot[0].second == "A");

	mt::MatrixObject mNew = fx::oneMatrix(text);	/* 表搬到了新地址 */
	metas.rebaseByName(snapshot, [&](const std::string& nm) {
		return nm == "A" ? &mNew : nullptr;
	});

	TH_CHECK(p->matrixPtr() == &mNew);
	/* **不清缓存**：存活表内容逐字未变，seed 结果与行号都仍然成立 */
	TH_CHECK(p->row() == 1);
	TH_CHECK(p->collect().toString() == before);
	TH_CHECK(before == R"({"note":"v0"})");
}

TH_TEST(metaregistry_rebase_skips_names_that_no_longer_resolve) {
	/* 只有「本批次 CREATE 后 DROP」的表会查不到——那类表从未装配，且此时无元素
	 * 搬移，重锚定是空转。resolve 返回 nullptr 即跳过：不抛、也不把锚置空。 */
	mt::MatrixObject mA = literalTable("A", 1);
	mt::MatrixObject mB = literalTable("B", 1);
	bot::HwRegistry reg;
	bot::MetaRegistry metas;
	auto pA = prov(mA, 1, &reg);
	auto pB = prov(mB, 1, &reg);
	metas.add(pA);
	metas.add(pB);

	const bot::MetaRegistry::TableNameSnapshot snapshot = metas.captureTableNames();
	metas.rebaseByName(snapshot, [&](const std::string& nm) {
		return nm == "A" ? &mA : nullptr;		/* B 查不到 */
	});
	TH_CHECK(pA->matrixPtr() == &mA);
	TH_CHECK(pB->matrixPtr() == &mB);		/* 原样不动，不是被置空 */
	TH_CHECK(pB->collect().toString() == R"({"note":"v0"})");

	/* 全部查不到 / 空快照都是空转 */
	metas.rebaseByName(snapshot, [](const std::string&) { return nullptr; });
	TH_CHECK(pA->matrixPtr() == &mA);
	metas.rebaseByName({}, [](const std::string&) { return nullptr; });
	TH_CHECK(metas.size() == 2);
}

TH_TEST(metaregistry_batch_apis_are_inert_on_an_empty_registry) {
	/* 热 SQL 路径是无条件调这几条的（一个批次可能只有 CREATE、只有 DELETE，
	 * 也可能整批被拒），故空登记表必须一路空转而不是崩或抛。 */
	bot::MetaRegistry metas;
	metas.validateAll();
	metas.validateFrom(0);
	metas.dropRows(DeadRows{});
	metas.shiftRowsAfter(nullptr, {});
	metas.truncate(0);
	TH_CHECK(metas.captureTableNames().empty());
	metas.rebaseByName(metas.captureTableNames(),
		[](const std::string&) -> const mt::MatrixObject* { return nullptr; });
	TH_CHECK(metas.empty());
	TH_CHECK(metas.all().empty());
}

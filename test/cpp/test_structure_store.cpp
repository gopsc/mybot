/* test_structure_store.cpp —— 结构矩阵域门面（StructureStore）的直接锚点
 *
 * 这个门面 2026-10-03 阶段 4 才从 RobotStruct 的私有容器 matrices_ 析出，此前只经
 * test_robot* 的集成路径间接覆盖。它的头注释把「容器是 std::deque」写成**不变式**
 * 而不是风格：MetaProvider 终身持有指向表元素的裸指针（matrix_），换成 std::vector
 * 会在 append 扩容时让全部旧引用悬垂——而那种悬垂在既有集成用例里未必当场崩，只在
 * 热插表之后的某次元数据收集里变成读脏。第一条用例就是把这条不变式钉成可判定的事实
 * （比地址，不靠「没崩」）。
 *
 * 反向验证（2026-10-04）：把成员容器改成 std::vector 并不能编译——
 * ScriptLoader::readSQL 与 HotSqlPlanner 的形参同样是 std::deque，不变式由三处签名
 * 共同锁死；于是改测「保留 deque、但让 append 搬家元素」这一等价破坏，用例确实转红
 * （地址断言先响，随后内容断言读脏），还原后复绿。
 *
 * 其余用例钉门面自己的语义：装载的声明序、appendRows 交回的「首个新行号」、两条回滚
 * 路径（popRows 行级 / truncate 表级）、热删除的保序擦除、整表撤下、按名查找，以及
 * 必须在 active() 之前就能判定的 declaresVariable。
 */

#include <cstdint>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "structure_store.hpp"
#include "util_except.hpp"

namespace {

/* 两张表的结构脚本：声明序 Relay → Timer，各一行数据 */
const char* kTwoTables =
	"CREATE TABLE Relay (name String, note String);\n"
	"INSERT INTO Relay (name, note) VALUES ('relay0', 'hello');\n"
	"CREATE TABLE Timer (name String);\n"
	"INSERT INTO Timer (name) VALUES ('timer-0');\n";

bot::StructureStore loadTwoTables() {
	bot::StructureStore store;
	bot::MemoryReader reader(kTwoTables);
	store.load(reader);
	return store;
}

/* 合成一张只有 name/note 两列、一行数据的整表（append 的「合成表」入口用） */
mt::MatrixObject synthTable(const std::string& name) {
	return fx::oneMatrix("@" + name + "\nname note;\nr0 v;\n@\n");
}

} // namespace

TH_TEST(structure_append_keeps_earlier_table_addresses_valid) {
	/* 不变式：append 不得让既有表的地址失效（MetaProvider::matrix_ 依赖它）。
	 * 追加远超 vector 的扩容步长——若容器哪天退回 std::vector，这里必然搬家。 */
	bot::StructureStore store = loadTwoTables();
	const mt::MatrixObject* first = &store.at(0);
	const std::size_t before = store.size();

	for (int i = 0; i < 64; ++i) { store.append(synthTable("T" + std::to_string(i))); }

	TH_CHECK(store.size() == before + 64);
	TH_CHECK_MSG(&store.at(0) == first,
		"append 之后首表地址变了——容器不再是引用稳定的 deque？"
		"MetaProvider 的 matrix_ 会随之悬垂");
	/* 地址还在，内容也还能读（读脏的兜底观测点） */
	TH_CHECK(first->getName() == "Relay");
	TH_CHECK(fx::cell(*first, 1, 0) == "relay0");
}

TH_TEST(structure_load_keeps_declaration_order_and_names) {
	bot::StructureStore store = loadTwoTables();
	TH_CHECK(store.size() == 2);
	TH_CHECK(!store.empty());
	TH_CHECK(store.at(0).getName() == "Relay");
	TH_CHECK(store.at(1).getName() == "Timer");
	/* all() 是只读视图，不是另一份拷贝 */
	TH_CHECK(store.all().size() == store.size());
	TH_CHECK(&store.all().front() == &store.at(0));
}

TH_TEST(structure_find_matches_by_name_and_reports_absence) {
	bot::StructureStore store = loadTwoTables();
	TH_CHECK(store.find("Timer") != nullptr);
	TH_CHECK(store.find("Timer") == &store.at(1));
	TH_CHECK(store.find("Nope") == nullptr);

	const bot::StructureStore& ro = store;
	TH_CHECK(ro.find("Relay") == &ro.at(0));
	TH_CHECK(ro.find("nope") == nullptr);
}

TH_TEST(structure_append_rows_returns_first_new_row_index) {
	/* 交回的行号是**追加之前**的行数——装配方拿它做增量 build 的起点，
	 * 取晚了就会把既有行当新行重复上电。 */
	bot::StructureStore store = loadTwoTables();
	TH_CHECK(store.at(0).rows() == 2);	/* 列头 + 一行数据 */

	const std::int64_t from = store.appendRows(0, {{"relay1", "a"}, {"relay2", "b"}});

	TH_CHECK(from == 2);
	TH_CHECK(store.at(0).rows() == 4);
	TH_CHECK(fx::cell(store.at(0), 2, 0) == "relay1");
	TH_CHECK(fx::cell(store.at(0), 3, 0) == "relay2");
	/* 另一张表不受影响 */
	TH_CHECK(store.at(1).rows() == 2);
}

TH_TEST(structure_pop_rows_rolls_back_only_the_batch_tail) {
	bot::StructureStore store = loadTwoTables();
	store.appendRows(0, {{"relay1", "a"}, {"relay2", "b"}});
	TH_CHECK(store.at(0).rows() == 4);

	store.popRows(0, 2);

	TH_CHECK(store.at(0).rows() == 2);
	TH_CHECK(fx::cell(store.at(0), 1, 0) == "relay0");
	TH_CHECK(store.size() == 2);	/* 行级回滚不动表 */
}

TH_TEST(structure_remove_rows_keeps_survivor_order) {
	/* 热删除是**保序擦除**：存活行的相对顺序不变（销毁序不变式）。
	 * 删中间一行，后面的行前移，而不是留下空洞或整体重排。 */
	bot::StructureStore store = loadTwoTables();
	store.appendRows(0, {{"relay1", "a"}, {"relay2", "b"}});
	TH_CHECK(store.at(0).rows() == 4);

	store.removeRows(0, {2});	/* 原始行号 2 = relay1 */

	TH_CHECK(store.at(0).rows() == 3);
	TH_CHECK(fx::cell(store.at(0), 1, 0) == "relay0");
	TH_CHECK(fx::cell(store.at(0), 2, 0) == "relay2");
}

TH_TEST(structure_truncate_rolls_back_whole_tables) {
	bot::StructureStore store = loadTwoTables();
	const mt::MatrixObject* first = &store.at(0);
	store.append(synthTable("Extra1"));
	store.append(synthTable("Extra2"));
	TH_CHECK(store.size() == 4);

	store.truncate(2);

	TH_CHECK(store.size() == 2);
	TH_CHECK(store.find("Extra1") == nullptr);
	TH_CHECK(store.find("Extra2") == nullptr);
	TH_CHECK(&store.at(0) == first);	/* 表级回滚同样不搬动存活表 */
}

TH_TEST(structure_erase_table_drops_the_shell_and_shifts_the_rest) {
	bot::StructureStore store = loadTwoTables();
	store.eraseTable(0);	/* DROP TABLE Relay */
	TH_CHECK(store.size() == 1);
	TH_CHECK(store.find("Relay") == nullptr);
	TH_CHECK(store.at(0).getName() == "Timer");

	store.eraseTable(0);
	TH_CHECK(store.empty());
	TH_CHECK(store.size() == 0);
}

TH_TEST(structure_declares_variable_scans_name_column_before_active) {
	bot::StructureStore store = loadTwoTables();
	/* 判据是扫矩阵的 name 列，而不是查注册表——注册表要 active() 里
	 * createHardVars 才装配，而 agent 模式的驱动存在性判定必须更早可用。 */
	TH_CHECK(store.declaresVariable("relay0"));
	TH_CHECK(store.declaresVariable("timer-0"));
	TH_CHECK(!store.declaresVariable("relay9"));
	TH_CHECK(!store.declaresVariable(""));
}

TH_TEST(structure_declares_variable_skips_tables_without_a_name_column) {
	/* 没有 name 列的表（indexOfCol 返回负）整张跳过：既不当作命中，也不崩。
	 * 判据只看 name 列的**取值**——列头名与非 name 列的值都不算「声明了变量」。 */
	bot::StructureStore store;
	store.append(fx::oneMatrix("@NoName\nfoo bar;\nzzz v;\n@\n"));
	TH_CHECK(!store.declaresVariable("zzz"));
	TH_CHECK(!store.declaresVariable("foo"));

	store.append(synthTable("Named"));	/* name 列取值 r0 */
	TH_CHECK(store.declaresVariable("r0"));
	TH_CHECK(!store.declaresVariable("zzz"));
	TH_CHECK(store.size() == 2);
}

/* test_hw_registry.cpp —— 硬件变量注册表门面（HwRegistry）的直接锚点
 *
 * 这个门面是 R-2（2026-09-20 起）把「所有权 pool_ + 销毁序 seq_ + 名字索引 byName_
 * + 流引用 flowRefs_」四个并行容器收敛成的单一来源；此前只经 test_robot_dispatch
 * 的三条基础用例与 test_robot_hot* 的集成路径覆盖，而它身上最容易被改坏的两组契约
 * ——热插事务回滚（mark/rollbackTo）与热删除撤销（removeBatch）——恰好是集成用例
 * 最难定位的那类：三容器锁步增长，任何「先记下标、再逐个 erase」的写法都会在第一次
 * erase 之后错位，症状是后续某次派发按名查到已删变量。
 *
 * 本文件把这两组契约连同会话覆盖层（SessionScope/override/removeSessionOverride）
 * 与两个表达式求值器（makeVarsResolver / makeActionExprResolver）一起钉在门面的
 * 公开接口上。原 test_robot_dispatch.cpp 首段的三条 hw_registry_* 用例逐字迁来
 * （2026-10-04），dummyHw 随之上收为 fx::dummyHw 供两边共用。
 */

#include <memory>
#include <string>
#include <utility>

#include "expr.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "hw_registry.hpp"
#include "util_except.hpp"

namespace {

/* 析构计数探针。removeBatch 与 rollbackTo 的契约都包含「元素随 unique_ptr 析构
 * 逐个释放」，但 pool_ 是私有的、注册表交不出来，只能从对象是否真的被析构这一侧
 * 观测——否则「撤销了注册却漏掉所有权」这类泄漏在门面上完全看不见。 */
class DtorProbe : public bot::MatrixVars_Hardware {
	int* count_;

public:
	explicit DtorProbe(int* count) : count_(count) {}
	~DtorProbe() override { ++*count_; }
	bot::Json play(const bot::Json&) override { return bot::JsonNull(); }
	const char* kindName() const override { return "test-dtor-probe"; }
};

/* @Vars 标量（一行 name/value 的矩阵，行 1 = 数据行）。纯字面量，故省略
 * Factory 的第三个形参（标识符求值回调只有 $(...) 表达式才需要）。 */
std::unique_ptr<bot::MtVars_Vars> varsHw(const std::string& name, const std::string& value) {
	return bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   " + name + "  " + value + ";\n@\n"), 1);
}

/* @Alias 标量：别名值就是它指向的名字文本 */
std::unique_ptr<bot::MtVars_Alias> aliasHw(const std::string& name, const std::string& target) {
	return bot::MtVars_Alias::Factory(
		fx::oneMatrix("@Alias\nname alias;\n   " + name + "  " + target + ";\n@\n"), 1);
}

} // namespace

/* ---------------- 结构期注册（R-2：单一注册表）---------------- */

TH_TEST(hw_registry_add_and_find) {
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw(), " (in table 'T')");
	reg.add("b", fx::dummyHw());
	TH_CHECK(reg.contains("a"));
	TH_CHECK(reg.find("a") != nullptr);
	TH_CHECK(reg.find("missing") == nullptr);
	/* 销毁序 = 声明序，会话别名不进入 */
	TH_CHECK(reg.sequence().size() == 2);
}

TH_TEST(hw_registry_rejects_duplicate_name) {
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw(), " (in table 'T')");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Duplicate hardware variable name: 'a'",
		reg.add("a", fx::dummyHw(), " (in table 'U')"));
	/* 失败不破坏既有注册 */
	TH_CHECK(reg.sequence().size() == 1);
	TH_CHECK(reg.find("a") != nullptr);
}

TH_TEST(hw_registry_session_override_shadows_but_keeps_destroy_order) {
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw());
	bot::MatrixVars_Hardware* structureVar = reg.find("a");
	reg.override("a", fx::dummyHw());
	/* 名字索引指向别名，但结构变量仍在销毁序中 */
	TH_CHECK(reg.find("a") != nullptr);
	TH_CHECK(reg.find("a") != structureVar);
	TH_CHECK(reg.sequence().size() == 1);
	TH_CHECK(reg.sequence()[0] == structureVar);
}

/* ---------------- 热插事务：mark / rollbackTo ---------------- */

TH_TEST(hw_registry_rollback_restores_names_order_and_flow_refs) {
	/* 「全成功或全回滚」的注册表侧半边：撤销范围严格等于本批次新登记的尾部，
	 * 结构期既有条目一字不动——这是对「pool_ 只增不删」的**受控、有界**放宽。 */
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw());
	reg.addFlowRef("a");
	bot::MatrixVars_Hardware* a = reg.find("a");
	const bot::HwRegistry::Mark mark = reg.mark();

	int dtor = 0;
	reg.add("b", std::make_unique<DtorProbe>(&dtor), " (in table 'T')");
	reg.add("c", std::make_unique<DtorProbe>(&dtor));
	reg.addFlowRef("b");			/* 批次内登记的流引用 */
	TH_CHECK(reg.sequence().size() == 3);

	reg.rollbackTo(mark);

	TH_CHECK(reg.sequence().size() == 1);
	TH_CHECK(reg.sequence()[0] == a);
	TH_CHECK(reg.find("b") == nullptr);
	TH_CHECK(reg.find("c") == nullptr);
	TH_CHECK(reg.byName().size() == 1);
	TH_CHECK_MSG(dtor == 2,
		"回滚后本批次两个变量没有被析构——pool_ 的尾部截断没有真的交出所有权");
	/* 流引用快照精确还原：b 在批次内 addFlowRef 过，回滚后不得留下。
	 * 留着的话该名字永久拒绝会话别名覆盖（N-6），而它已随本批次一起撤销。 */
	bot::HwRegistry::SessionScope scope(reg);
	reg.override("b", fx::dummyHw());
	TH_CHECK(reg.find("b") != nullptr);
	TH_CHECK(reg.byName().size() == 1);	/* 会话层不进结构清单 */
}

TH_TEST(hw_registry_rollback_rejects_a_stale_mark) {
	/* 标记过期必须 fail-fast：seq 比当前销毁序还长，说明这个 mark 来自另一次
	 * 批次（或另一次已经回滚过的批次），照它 resize 会把结构期条目一起削掉。 */
	bot::HwRegistry reg;
	const bot::HwRegistry::Mark empty = reg.mark();		/* seq = 0 */
	reg.add("a", fx::dummyHw());
	const bot::HwRegistry::Mark stale = reg.mark();		/* seq = 1 */
	reg.rollbackTo(empty);				/* 全撤：seq = 0 */
	TH_CHECK(reg.sequence().empty());
	TH_CHECK(reg.find("a") == nullptr);

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "mark is stale", reg.rollbackTo(stale));
	TH_CHECK(reg.sequence().empty());
}

/* ---------------- 热删除：removeBatch ---------------- */

TH_TEST(hw_registry_remove_batch_drops_a_middle_entry_and_keeps_order) {
	/* 与 rollbackTo 的分工：那个撤「本批次新加的尾部」，这个撤「任意位置的既有
	 * 条目」。撤中间会让后续元素前移，故判据必须是**对象指针**而不是下标。 */
	bot::HwRegistry reg;
	int dtor = 0;
	reg.add("a", fx::dummyHw());
	reg.add("mid", std::make_unique<DtorProbe>(&dtor));
	reg.add("z", fx::dummyHw());
	bot::MatrixVars_Hardware* a = reg.find("a");
	bot::MatrixVars_Hardware* mid = reg.find("mid");
	bot::MatrixVars_Hardware* z = reg.find("z");

	reg.removeBatch({mid});

	TH_CHECK_MSG(dtor == 1, "被删变量没有随 pool_ 的 erase 析构——所有权漏了");
	TH_CHECK(reg.sequence().size() == 2);
	TH_CHECK(reg.sequence()[0] == a);
	TH_CHECK(reg.sequence()[1] == z);	/* 存活者相对顺序不动（销毁序不变式） */
	TH_CHECK(reg.find("mid") == nullptr);
	TH_CHECK(!reg.contains("mid"));
	TH_CHECK(reg.byName().size() == 2);
}

TH_TEST(hw_registry_remove_batch_validates_every_pointer_before_modifying) {
	/* 这条方法的存在理由：校验与修改分离，不存在「改了一半发现指针不认识」的
	 * 中间态。混进一个未注册指针必须整批拒绝，且注册表一字未动。 */
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw());
	reg.add("b", fx::dummyHw());
	bot::MatrixVars_Hardware* a = reg.find("a");
	bot::MatrixVars_Hardware* b = reg.find("b");
	fx::LambdaHw stranger([](const bot::Json&) { return bot::JsonNull(); });

	reg.removeBatch({});			/* 空集合是空操作（早退，不做无谓重排） */
	TH_CHECK(reg.sequence().size() == 2);

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "a pointer is not registered",
		reg.removeBatch({a, &stranger}));

	TH_CHECK(reg.sequence().size() == 2);
	TH_CHECK(reg.sequence()[0] == a);
	TH_CHECK(reg.sequence()[1] == b);
	TH_CHECK(reg.find("a") == a);
	TH_CHECK(reg.byName().size() == 2);
}

TH_TEST(hw_registry_remove_batch_clears_flow_refs_of_removed_names) {
	/* 留着会**过度拒绝**：该名字此后已不是任何变量的引用目标，而 flowRefs_ 的
	 * 语义是「被 controller/trigger 引用」——不摘掉的话，「删掉再热插同名变量」
	 * 之后该名字永久拒绝会话别名覆盖（N-6），挡的却是一个不存在的引用。 */
	bot::HwRegistry reg;
	reg.add("pump", fx::dummyHw());
	reg.addFlowRef("pump");
	bot::MatrixVars_Hardware* pump = reg.find("pump");
	{
		bot::HwRegistry::SessionScope scope(reg);
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
			"action script alias must not override", reg.override("pump", fx::dummyHw()));
	}

	reg.removeBatch({pump});
	TH_CHECK(reg.sequence().empty());

	/* 同名再热插回来：流引用已摘除，会话覆盖重新可用 */
	reg.add("pump", fx::dummyHw());
	bot::HwRegistry::SessionScope scope(reg);
	reg.override("pump", fx::dummyHw());
	TH_CHECK(reg.sessionSize() == 1);
}

/* ---------------- 会话覆盖层（阶段 1）---------------- */

TH_TEST(hw_registry_session_scope_bounds_overrides_to_one_run) {
	/* 不变量：会话层非空 ⟺ 正在一次 run() 之内。旧实现直接改写 byName_，
	 * 长驻（agent REPL）反复 run() 会无界堆积永不回收的旧别名。 */
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw());
	bot::MatrixVars_Hardware* a = reg.find("a");
	TH_CHECK(reg.sessionSize() == 0);

	/* 构造即清空是防御性的：上一轮异常路径可能留下没回收的覆盖 */
	reg.override("stale", fx::dummyHw());
	TH_CHECK(reg.sessionSize() == 1);
	{
		bot::HwRegistry::SessionScope scope(reg);
		TH_CHECK_MSG(reg.sessionSize() == 0,
			"SessionScope 构造没有清空会话层——异常残留会跨 run() 泄漏");
		reg.override("a", fx::dummyHw());
		reg.override("tmp", fx::dummyHw());
		TH_CHECK(reg.sessionSize() == 2);
		TH_CHECK(reg.find("a") != a);
		/* 结构清单是「描述」用途，不因会话而增长 */
		TH_CHECK(reg.byName().size() == 1);
		TH_CHECK(reg.sequence().size() == 1);
		TH_CHECK(reg.sequence()[0] == a);
	}
	TH_CHECK(reg.sessionSize() == 0);
	TH_CHECK(reg.find("a") == a);		/* 结构定义不再被永久遮蔽 */
	TH_CHECK(!reg.contains("stale"));
	TH_CHECK(!reg.contains("tmp"));
}

TH_TEST(hw_registry_remove_session_override_is_per_entry) {
	/* #34 @Trigger：每次触发绑定的临时别名逐个移除，不依赖整个 SessionScope
	 * （run() 级）提前结束——反射触发是 run() 内部的多次子作用域。 */
	bot::HwRegistry reg;
	reg.add("a", fx::dummyHw());
	bot::MatrixVars_Hardware* a = reg.find("a");
	bot::HwRegistry::SessionScope scope(reg);
	reg.override("t1", fx::dummyHw());
	reg.override("t2", fx::dummyHw());
	TH_CHECK(reg.sessionSize() == 2);

	reg.removeSessionOverride("t1");
	TH_CHECK(reg.sessionSize() == 1);
	TH_CHECK(!reg.contains("t1"));
	TH_CHECK(reg.contains("t2"));

	/* 名字不在会话层时静默（防御性：异常路径可能已部分回滚）——
	 * 尤其不得顺手摘掉同名的结构变量 */
	reg.removeSessionOverride("t1");
	reg.removeSessionOverride("never-added");
	reg.removeSessionOverride("a");
	TH_CHECK(reg.sessionSize() == 1);
	TH_CHECK(reg.find("a") == a);
}

/* ---------------- 表达式标识符求值器（N-15 单点）---------------- */

TH_TEST(hw_registry_vars_resolver_accepts_only_numeric_vars) {
	/* 三个调用面（元数据 $(...)、@Vars 装配、动作表达式列）共用这一份，
	 * 故两条错误文案本身就是契约。 */
	bot::HwRegistry reg;
	reg.add("v", varsHw("v", "35"));
	reg.add("leg", aliasHw("leg", "dev1"));
	reg.add("dev", fx::dummyHw());
	const auto resolve = reg.makeVarsResolver();

	TH_CHECK(resolve("v") == 35.0);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"which is not an @Vars; only numeric @Vars may appear in an expression",
		resolve("dev"));
	/* @Alias 是文本，同样不收——这条求值面是 vars-only */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "which is not an @Vars", resolve("leg"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"but it is not a defined hardware variable", resolve("ghost"));
}

TH_TEST(hw_registry_action_expr_resolver_also_accepts_alias_text) {
	/* @Action 求值面（数据格/列头）比 makeVarsResolver 宽一格：@Alias → 文本，
	 * 因为那里的名字是拿来做算术**或拼接**的。驱动/守护名照样抛错——表达式里
	 * 没有驱动的一席之地。 */
	bot::HwRegistry reg;
	reg.add("dev1", fx::dummyHw());
	reg.add("leg", aliasHw("leg", "dev1"));
	reg.add("v", varsHw("v", "2e3"));
	const auto resolve = reg.makeActionExprResolver();

	const bot::ExprValue text = resolve("leg");
	TH_CHECK(text.isText());
	TH_CHECK(text.text == "dev1");

	const bot::ExprValue num = resolve("v");
	TH_CHECK(num.isNum());
	TH_CHECK(num.num == 2000.0);		/* "2e3" 的真值 */
	TH_CHECK(num.rendered() == "2000");	/* formatNumber：整数不带小数点/指数 */

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"which is a driver/daemon variable; only @Alias/@Vars may appear in an expression",
		resolve("dev1"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException,
		"but it is not a defined hardware variable", resolve("ghost"));
}

TH_TEST(hw_registry_resolvers_see_session_layer_only_inside_a_run) {
	/* find() 会话层优先：run() 之内别名可见（@Action 设备位/参数位解析靠它），
	 * run() 之外会话层必为空，行为与结构视图完全一致。 */
	bot::HwRegistry reg;
	reg.add("v", varsHw("v", "1"));
	const auto resolve = reg.makeVarsResolver();
	TH_CHECK(resolve("v") == 1.0);
	{
		bot::HwRegistry::SessionScope scope(reg);
		reg.override("v", varsHw("v", "7"));
		TH_CHECK(resolve("v") == 7.0);
	}
	TH_CHECK(resolve("v") == 1.0);
}

/* hw_registry.cpp —— HwRegistry：硬件变量注册表（拆自 robot.cpp 阶段 R-1）
 * 所有权（pool_）+ 销毁序（seq_）+ 名字索引（byName_）+ 流引用（flowRefs_）
 * 的单一来源，与解析/装配/派发解耦。 */

#include "hw_registry.hpp"

/* 本 TU 只装配标量变量（@Vars），显式引入 */
#include "luavar.hpp"

#include <algorithm>
#include <string_view>
#include <utility>

namespace bot {

/* 文案单点的定义处（声明与理由见 hw_registry.hpp） */
std::string duplicateHwNameMsg(const std::string& name, const std::string& source) {
	return "Duplicate hardware variable name: '" + name + "'" + source;
}

/* ---- HwRegistry：结构期注册（重名即抛）---- */
void HwRegistry::add(const std::string& name, std::unique_ptr<MatrixVars_Hardware> hw,
		const std::string& source) {
	if (byName_.count(name)) {
		throw IllegalArgumentException(duplicateHwNameMsg(name, source));
	}
	/* R-2 遗留缺口：三个容器的写入顺序原为 byName_ → seq_ → pool_，一旦后两次
	 * push_back 抛 bad_alloc，byName_ 已指向 hw 持有的对象，而 hw 随栈展开析构
	 * ——注册表留下悬垂指针，后续 find/派发即 UB。
	 * 收口：先 reserve 两个 vector（此后其指针元素 push_back 不再分配），再把所有权
	 * 落到 pool_，最后登记非所有权索引。唯一可能失败的 map 节点分配排在 pool_ 已
	 * 提交之后，失败时回滚 pool_ ——对象随 unique_ptr 析构，不留半个条目。 */
	pool_.reserve(pool_.size() + 1);
	seq_.reserve(seq_.size() + 1);
	pool_.push_back(std::move(hw));
	MatrixVars_Hardware* p = pool_.back().get();
	try {
		byName_.emplace(name, p);
	} catch (...) {
		pool_.pop_back();
		throw;
	}
	seq_.push_back(p);		/* reserve 之后无分配，不抛 */
}

/* ---- HwRegistry：热插事务回滚（受控放宽见头文件 Mark 注释）---- */
void HwRegistry::rollbackTo(const Mark& m) {
	/* 不变量：pool_ 与 seq_ 锁步等长（add 里同序 push、失败路径成对回滚） */
	if (m.seq > seq_.size() || seq_.size() != pool_.size()) {
		throw IllegalArgumentException("HwRegistry::rollbackTo: mark is stale (seq="
			+ std::to_string(m.seq) + ", registry seq=" + std::to_string(seq_.size())
			+ ", pool=" + std::to_string(pool_.size()) + ")");
	}
	/* 1) 摘名字索引：按尾部指针集合过滤（byName_ 是名字 → 指针的只读视图，
	 *    没有反向索引，故这里只能扫一遍；条目数是结构规模，热插批次无感）。 */
	std::set<const MatrixVars_Hardware*> doomed(seq_.begin() + static_cast<std::ptrdiff_t>(m.seq),
		seq_.end());
	for (auto it = byName_.begin(); it != byName_.end();) {
		if (doomed.count(it->second) != 0) { it = byName_.erase(it); } else { ++it; }
	}
	/* 2) 弹出销毁序与所有权（元素析构；调用方已先行 destroy() 断电） */
	seq_.resize(m.seq);
	pool_.resize(m.seq);
	/* 3) 流引用精确还原：批次内 addFlowRef 过的新名字不得留下——否则该名字
	 *    永久拒绝会话别名覆盖（N-6），而它已随本批次一起撤销。 */
	flowRefs_ = m.flowRefs;
}

/* ---- HwRegistry：热删除撤销注册（契约见头文件声明处）---- */
void HwRegistry::removeBatch(const std::set<MatrixVars_Hardware*>& doomed) {
	if (doomed.empty()) { return; }

	/* 1) 先全量验存在性：pool_ 与 seq_ 锁步等长（add 的同序 push），故查一边
	 *    即可；byName_ 与 flowRefs_ 是派生视图，缺失不算错（例如被删的变量
	 *    恰好没被任何 controller/trigger 列引用，flowRefs_ 里本就没有它）。
	 *    不变量在修改之前就立住——不存在「erase 到一半发现指针不认识」的
	 *    中间态，故「指针集合与注册表早已脱节」是 fail-fast 而非静默半成功。 */
	for (MatrixVars_Hardware* p : doomed) {
		if (std::find(seq_.begin(), seq_.end(), p) == seq_.end()) {
			throw IllegalArgumentException("HwRegistry::removeBatch: a pointer is not"
				" registered (registry has " + std::to_string(seq_.size())
				+ " variable(s)); the deletion plan is stale");
		}
	}

	/* 2) 名字索引是 map<名字, 指针>、没有反向索引：先按指针集合把 doomed 的
	 *    名字收出来（顺带摘掉索引），再一趟重排 seq_/pool_。 */
	std::set<std::string> doomedNames;
	for (auto it = byName_.begin(); it != byName_.end();) {
		if (doomed.count(it->second) != 0) {
			doomedNames.insert(it->first);
			it = byName_.erase(it);
		} else {
			++it;
		}
	}

	auto isDoomed = [&doomed](MatrixVars_Hardware* p) { return doomed.count(p) != 0; };
	/* reserve 先做一次，让下面的 erase-remove 重排不再分配：本方法在「器件已
	 * 断电」之后调用，此刻 bad_alloc 会把调用方留在半撤销状态。 */
	seq_.reserve(seq_.size());
	pool_.reserve(pool_.size());
	/* 两个容器的存活谓词必须都按**对象指针**判定，不能按 unique_ptr 的地址
	 * ——后者会随重排漂移（pool_[i] 是对 unique_ptr 的引用，元素前移后其地址
	 * 就变了）。元素在 pool_ 的 erase 处随 unique_ptr 析构逐个释放。 */
	seq_.erase(std::remove_if(seq_.begin(), seq_.end(), isDoomed), seq_.end());
	pool_.erase(std::remove_if(pool_.begin(), pool_.end(),
		[&](const std::unique_ptr<MatrixVars_Hardware>& h) { return isDoomed(h.get()); }),
		pool_.end());

	/* 3) 流引用：被删名字一并摘掉。留下会**过度拒绝**——该名字此后已不是任何
	 *    变量的引用目标，而 flowRefs_ 的语义是「被 controller/trigger 引用」；
	 *    留着它会让「删掉再热插同名变量」之后该名字永久拒绝会话别名覆盖
	 *    （N-6 防线），挡的却是一个不存在的引用。 */
	for (const std::string& n : doomedNames) { flowRefs_.erase(n); }
}

/* ---- HwRegistry：会话期别名覆盖（阶段 1：写进会话覆盖层）----
 * 不变量：会话层非空 ⟺ 正在一次 RobotStruct::run() 之内（由 SessionScope 维护）。
 * 与结构期彻底分离的收益：
 *   ① 结构定义不可能被会话变量永久遮蔽——旧实现直接改写 byName_，进程退出前
 *      一直生效（实测：一个连 @Action 都没有、以报错收场的脚本也能改写注册表）；
 *   ② pool_ 只属于结构期，MetaRef::target 的裸指针不变式与 MtVars_Lua::flowTarget
 *      的指针缓存从人工约定升级为构造保证；
 *   ③ 长驻（agent REPL）反复 run() 不再无界增长——旧实现每轮都往 pool_ 堆一份
 *      永不回收的旧别名（实测 200 轮 → byName_ 多 200 个名字）。 */
void HwRegistry::override(const std::string& name, std::unique_ptr<MatrixVars_Hardware> hw) {
	/* N-6：被引用为 controller/trigger 的名字不得覆盖——否则派发按名
	 * 查到别名（MtVars_Alias），报出的 "non-table result" 与真实成因
	 * （引用目标被动作脚本覆盖）完全脱节。 */
	if (flowRefs_.count(name)) {
		throw IllegalArgumentException("action script alias must not override '"
			+ name + "': it is referenced as a controller or trigger by another hardware variable");
	}
	/* 强异常安全：map 节点分配失败时旧条目原样保留（调用前状态），
	 * 不留半个条目、也不动结构期三个容器。 */
	session_[name] = std::move(hw);
}

void HwRegistry::removeSessionOverride(const std::string& name) {
	/* #34 @Trigger 子作用域收尾：只撤会话层单条，结构期一字不动。
	 * 名字本就不在会话层时静默（防御性：异常路径可能已部分回滚）。 */
	session_.erase(name);
}

/* N-15：表达式标识符求值器单点——三个调用面（元数据 $(...)、@Vars 装配、
 * 动作表达式列）此前各自内联同一形态的 lambda。 */
namespace {
double resolveVarsNumber(const HwRegistry* reg, const std::string& name);
} // namespace

std::function<double(const std::string&)> HwRegistry::makeVarsResolver() const {
	const HwRegistry* reg = this;
	return [reg](const std::string& nm) { return resolveVarsNumber(reg, nm); };
}

/* 表达式标识符求值器（@Action 求值面）：@Vars → 数值真值（numericValue，
 * 经 formatNumber 渲染为拼接文本——"2e3" 的真值是 "2000"）、@Alias → 文本
 * （别名值）；驱动/守护名与未定义名抛错。仅 Action 路径使用（数据格/列头），
 * @Vars 值与元数据列维持 vars-only 的 makeVarsResolver。 */
std::function<ExprValue(const std::string&)> HwRegistry::makeActionExprResolver() const {
	const HwRegistry* reg = this;
	return [reg](const std::string& nm) -> ExprValue {
		MatrixVars_Hardware* hv = reg->find(nm);
		if (hv == nullptr) {
			throw IllegalArgumentException("expression references '" + nm
				+ "', but it is not a defined hardware variable");
		}
		if (!hv->isScalarText()) {
			throw IllegalArgumentException("expression references '" + nm
				+ "', which is a driver/daemon variable; only @Alias/@Vars may"
				+ " appear in an expression");
		}
		if (std::string_view(hv->kindName()) == "vars") {
			return ExprValue::makeNum(static_cast<MtVars_Vars*>(hv)->numericValue());
		}
		return ExprValue::makeText(hv->read().asString().getValue());	/* kindName 已判型 */
	};
}

/* 表达式标识符求值：查注册表，必须是 @Vars（数值），递归取数。
 * 环（A→B→A）由 MtVars_Vars::numericValue 的深度计数兜底。 */
namespace {
double resolveVarsNumber(const HwRegistry* reg, const std::string& name) {
	MatrixVars_Hardware* hv = reg->find(name);
	if (hv == nullptr) {
		throw IllegalArgumentException("expression references '" + name
			+ "', but it is not a defined hardware variable");
	}
	if (std::string_view(hv->kindName()) != "vars") {
		throw IllegalArgumentException("expression references '" + name
			+ "', which is not an @Vars; only numeric @Vars may appear in an expression");
	}
	return static_cast<MtVars_Vars*>(hv)->numericValue();	/* kindName 已判型 */

}
} // namespace

} // namespace bot

#pragma once
/* hw_registry.hpp —— 硬件变量注册表（拆自 robot.hpp，2026-09-29 A2 头文件拆分；
 * 实现在 hw_registry.cpp，拆分说明见 robot.hpp 新版头注释） */

#include <cstddef>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "hardware.hpp"

namespace bot {

/* 重名报错文案单点（2026-10-06 25.3）：HwRegistry::add 与 HwFactory::
 * precheckDuplicate 此前各拼一份同样的 "Duplicate hardware variable name: '<名>'"。
 * precheckDuplicate 的全部意义就是**提前**给出 add 将会给出的同一条错（在申请
 * Lua 状态机/共享槽之前先判重，见 hw_factory.hpp 的「资源泄漏防线」注释），于是
 * 同一次重名报哪份文案取决于哪个检查先命中——两份一漂，同一种用户错误就有了
 * 两种报错。守门只锚了 add 那份（test_hw_registry.cpp:72 断言
 * "Duplicate hardware variable name: 'a'"），factory 那份零覆盖，漂了不会红。
 * source 是调用方自带的声明来源后缀（如 " (in table 'X')"，见 add 的声明注释），
 * 形态各家本就不同（表名 / 表名+行号 / " (in @Label matrix)"），故只单点前缀、
 * 不做 source 的统一构造器。 */
std::string duplicateHwNameMsg(const std::string& name, const std::string& source = "");

/* R-2：硬件变量注册表——所有权、销毁序、名字索引的单一来源。
 * 旧实现三个并行容器（hardwareVars_/hwPool_/hwSeq_）靠 addHardwareVar
 * 手工同步；会话期别名覆盖直接改写 map，不变式被打破。
 * 实现 HwLookup 只读接口（2.1）：MtVars_Lua 等只依赖该抽象；byName()
 * 是 agent 清单的具象视图，不进接口（假实现无需维护清单）。
 *
 * 阶段 1（2026-09-20）：会话变量作用域。动作脚本内联的 @Alias/@Vars 走
 * session_ 覆盖层，生命周期严格等于一次 RobotStruct::run()——此前它们直接
 * 改写 byName_（永久遮蔽结构定义）且所有权堆在 pool_ 里永不回收（agent 长驻
 * 模式无界增长）。分层后 pool_/seq_/byName_ 三者只属于结构期，MetaRef::target
 * 的裸指针不变式从「靠约定」变成「靠构造」。 */
class HwRegistry : public HwLookup {
	std::vector<std::unique_ptr<MatrixVars_Hardware>> pool_;	/* 结构期所有权（只增不删） */
	std::vector<MatrixVars_Hardware*> seq_;			/* 销毁序：结构声明序，active/deactivate 按序 */
	std::map<std::string, MatrixVars_Hardware*> byName_;	/* 结构期名字索引 */
	/* N-6：被结构引用列（controller 出边 / trigger 入边）指向的名字集合——
	 * 会话期覆盖不得触碰，否则派发按名查到别名（MtVars_Alias），报出的
	 * "non-table result" 与真实成因（引用目标被覆盖）完全脱节。 */
	std::set<std::string> flowRefs_;
	/* 阶段 1：会话覆盖层。仅由 SessionScope 持有生命周期；不变量是
	 * 「非空 ⟺ 正在一次 run() 之内」。 */
	std::map<std::string, std::unique_ptr<MatrixVars_Hardware>> session_;

public:
	/* 结构期注册：重名即抛（source 指明声明来源，如 " (in table 'X')"） */
	void add(const std::string& name, std::unique_ptr<MatrixVars_Hardware> hw,
			const std::string& source = "");

	/* 会话期别名覆盖：写进会话覆盖层（不进入销毁序、不触碰结构视图）。
	 * 名字被引用为 controller/trigger 时拒绝覆盖（N-6）。
	 * 作用域 = 外层 SessionScope 的生命周期（RobotStruct::run 一次）。 */
	void override(const std::string& name, std::unique_ptr<MatrixVars_Hardware> hw);

	/* 会话期单条撤销（#34 @Trigger）：每次触发绑定的临时别名在触发执行完
	 * 后逐个移除，不依赖整个 SessionScope（run() 级）提前结束——反射触发
	 * 是 run() 内部的多次子作用域。名字不在会话层时静默（防御性）。 */
	void removeSessionOverride(const std::string& name);

	/* 会话作用域（阶段 1）：run() 入口构造、出口析构，异常路径同样回滚。
	 * 构造即清空（防御性：正常路径下构造时必为空），析构把会话变量连同
	 * 其所有权一起释放——结构定义与结构期所有权一字不动。 */
	class SessionScope {
		HwRegistry* reg_;
	public:
		explicit SessionScope(HwRegistry& reg) : reg_(&reg) { reg_->session_.clear(); }
		~SessionScope() { reg_->session_.clear(); }
		SessionScope(const SessionScope&) = delete;
		SessionScope& operator=(const SessionScope&) = delete;
	};

	/* 会话层规模（只读）。测试与诊断用：结构清单 byName() 不得因会话而增长。 */
	std::size_t sessionSize() const { return session_.size(); }

	/* 登记结构引用列指向的名字（controller/trigger，createLuaVars 装配期调用） */
	void addFlowRef(const std::string& name) { flowRefs_.insert(name); }

	/* ---- 热插事务标记（2026-09-23）----
	 * 唯一用途：RobotStruct::applySql 的「全成功或全回滚」。结构期三容器在
	 * add() 里锁步增长（pool_ 与 seq_ 尾部一一对应、byName_ 是名字索引），
	 * 故一个长度 + 流引用快照就足以把注册表精确还原到批次开始前。
	 * 这是对「pool_ 只增不删」这条既有不变式的**受控、有界**放宽：撤销范围
	 * 严格等于本次热插批次新登记的部分，结构期既有条目一字不动。 */
	struct Mark {
		std::size_t seq = 0;			/* 销毁序长度（pool_ 与之锁步等长） */
		std::set<std::string> flowRefs;		/* 流引用集合快照（通常极小） */
	};

	Mark mark() const { return Mark{seq_.size(), flowRefs_}; }

	/* 回滚到标记：**调用方必须先对尾部变量逆序 destroy()**（断电是物理动作，
	 * 注册表不认识硬件）。本方法只撤注册与所有权——弹出尾部条目、摘掉对应的
	 * 名字索引、恢复流引用快照；元素随 unique_ptr 析构逐个释放。 */
	void rollbackTo(const Mark& m);

	/* ---- 热删除：按指针集合撤销注册（2026-09-23）----
	 * 与 rollbackTo 的分工：rollbackTo 撤的是「本批次**新加**的尾部条目」（热插
	 * 回滚），本方法撤的是「**任意位置**的既有条目」（热删除）——都持有同一份
	 * 契约：**调用方必须先 destroy() 断电**，本方法只撤所有权与索引。
	 *
	 * 与 rollbackTo 的差别正是本方法存在的理由：pool_/seq_/byName_ 三容器在
	 * add() 里锁步增长，但**全体下标在下标 0 处对齐**这条便利只在「撤尾部」时
	 * 成立。撤中间条目会把后续元素前移，于是任何「先记下标、再逐个 erase」的
	 * 实现都会在第一次 erase 之后就错位。这里改为一趟 erase-remove：先把
	 * doomed 在**全部三个容器**里的存在性验完，再统一重排——校验与修改分离，
	 * 不存在「改了一半发现指针不认识」的中间态。
	 *
	 * 为什么用指针集合而不是名字集合：调用方的判据来自结构行（哪些行被删），
	 * 而「行 → 变量」的映射要经 name 列查表；指针集合让调用方直接用它在装配期
	 * 就已识别的对象，且天然去重（同一变量不可能注册两次）。
	 *
	 * 悬垂指针防线（本方法的存在前提，不是副作用）：被删变量的引用方在框架里
	 * 是**终身缓存的裸指针**——MtVars_Lua::ctrlPtrs_/trigPtrs_（首用缓存，
	 * 注释写着「指针终身有效」）与 MetaRef::target（seed 期锁定，注释写着
	 * 「pool_ 只增不减，生命周期安全」）。本方法只保证**注册表自身**不再交出
	 * 这些指针；「不留下指向已删变量的缓存」由调用方在预检阶段以「被引用即
	 * 拒绝删除」保证（见 RobotStruct::applySql 的删除预检）。 */
	void removeBatch(const std::set<MatrixVars_Hardware*>& doomed);

	/* N-15：表达式标识符求值器（只认 @Vars 数值；未定义/非 @Vars 即抛）——
	 * MetaProvider 的 $(...) 求值、HwFactory 装配共用 */
	std::function<double(const std::string&)> makeVarsResolver() const override;

	/* @Action 求值面（数据格/列头）的标识符求值器：@Vars → 数值真值、
	 * @Alias → 文本；驱动/守护名抛错（表达式里没有驱动的一席之地——
	 * 名字是拿来做算术/拼接的，不是拿来做播放的）。仅 Action 路径使用。 */
	std::function<ExprValue(const std::string&)> makeActionExprResolver() const override;

	MatrixVars_Hardware* find(const std::string& name) const override {
		/* 会话层优先：run() 之内别名可见（@Action 设备位/参数位解析靠它），
		 * run() 之外会话层必为空，行为与结构视图完全一致 */
		auto s = session_.find(name);
		if (s != session_.end()) { return s->second.get(); }
		auto it = byName_.find(name);
		return it == byName_.end() ? nullptr : it->second;
	}

	bool contains(const std::string& name) const override {
		return session_.count(name) > 0 || byName_.count(name) > 0;
	}

	/* 销毁序视图（build 正向 / destroy 反向）；会话别名不在其中 */
	const std::vector<MatrixVars_Hardware*>& sequence() const { return seq_; }

	/* agent 模式：只读名字索引（硬件清单）。只给 const 视图——
	 * 清单是「描述」用途，不应成为第二条改写注册表的路径。
	 * 阶段 1：**只含结构变量**——会话层生命周期严格包含在 run() 之内，
	 * 而工具调用只发生在两次 run() 之间（那时会话层必为空），故无需合并视图。 */
	const std::map<std::string, MatrixVars_Hardware*>& byName() const { return byName_; }
};

} // namespace bot

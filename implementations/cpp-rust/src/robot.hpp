#pragma once
/* robot.hpp —— 机器人编排门面（移植 bot4cj/src/RobotStruct.cj）
 * 结构脚本（SQL）→ MatrixObject 表 → 硬件变量注册表；
 * @Action 逐行重放，controller/trigger/Alias/守护 机制在此装配。
 *
 * 2026-09-29 A2 头文件拆分：本头原先声明全部 12 个类型（699 行），而实现
 * 早已按 TU 拆好——现在声明也各归各位，本头只剩 RobotStruct 门面：
 *   hw_registry.hpp     HwRegistry（注册表：所有权/销毁序/名字索引）
 *   meta_provider.hpp   MetaRef / MetaProvider（元数据引用与静态列缓存）
 *   script_loader.hpp   ScriptLoader（SQL 事件 → MatrixObject，实在 structure.cpp）
 *   hw_factory.hpp      HwFactory（矩阵表 → 硬件变量装配）
 *   action_runner.hpp   ActionPlan / ActionRunner（@Action 派发与重放）
 *   hotsql_plan.hpp     HotSqlPlan / HotSqlPlanner（热 SQL 只读计划层）
 * 只需局部类型的 TU 改包含对应窄头；RobotStruct 的消费者仍只包含本头。
 *
 * 2026-10-04 再收窄：装配机械（HwFactory / ActionRunner / HotSqlService）收进
 * 私有装配体 RobotStruct::Internals（robot_internals.hpp，只被实现单元包含），
 * 本头不再直接包含 action_runner.hpp / hw_factory.hpp / hotsql_service.hpp。 */

#include <cstdint>
#include <map>
#include <memory>
#include <string>

#include "daemon_registry.hpp"
#include "hardware.hpp"
#include "hw_registry.hpp"
#include "meta_registry.hpp"
#include "structure_store.hpp"
#include "util_cli.hpp"

namespace bot {

/* 结构脚本/动作脚本统一按字节流消费；本头只以引用接收它（构造与 run 的形参），
 * 连构造转发都不查其内容——直接前置声明，不背 util_except.hpp。 */
class Reader;

/* ---- 机器人编排门面：装配流程 + 生命周期（R-1 后只剩这些）---- */
class RobotStruct {
public:
	enum class LifecycleState { Loaded, Active, Deactivating, Inactive };

private:
	/* 结构矩阵域（2026-10-03 阶段 4）：matrix 表的所有权与读写入口。容器选型
	 * （deque，元素引用稳定）是域内不变式，见 structure_store.hpp 头注释。 */
	StructureStore structures_;
	/* 守护域（2026-10-03 阶段 4）：守护线程登记表。deactivate 先统一置 stop；
	 * shared_ptr 供守护线程持 self 保生命周期（详见 daemon_registry.hpp）。 */
	DaemonRegistry daemons_;
	HwRegistry registry_;				/* 硬件变量：所有权 + 销毁序 + 名字索引（R-2） */
	/* 元数据域（2026-10-03 阶段 4）：Lua 变量的元数据提供者登记表。active() 在
	 * build 前统一校验 $ 引用存在性；热删除/整表撤下期摘除与重锚定
	 * （详见 meta_registry.hpp）。 */
	MetaRegistry metas_;
	/* 装配机械（HwFactory / ActionRunner / HotSqlService）整体住进私有装配体
	 * （Internals，定义在 robot_internals.hpp）；三个执行器是门面的实现细节，
	 * 不占公开头。声明在四个域门面之后——Internals 持它们的引用，构造序与
	 * 拆分前逐字同序（见其定义处注释）。 */
	struct Internals;
	std::unique_ptr<Internals> internals_;
	/* @Merge/@Include 基准目录（mtinclude::expandIncludes 的相对路径根，缺省 "."）。
	 * 三个调用面按「脚本集合的根」取值：--input 文件通道=脚本所在目录、
	 * agent run_action_script=--scripts-dir、stdin/TCP 无脚本位置=缺省 CWD。
	 * run() 前设置即可，多轮执行（agent 工具）每次设置均生效。 */
	std::string actionIncludeBaseDir_ = ".";
	/* 是否已处于「断电」状态：active() 置 false，deactivate() 置 true。
	 * 析构据此判断要不要补一次断电——断电是生命周期不变式，不是调用点义务
	 * （见 ~RobotStruct 注释）。缺省 true：只解析结构、从未上电时无事可做。 */
	LifecycleState state_ = LifecycleState::Loaded;
	bool deactivated_ = true;
	/* --daemon-grace-ms（2026-09-22 F-2）：deactivate() 二段屏障宽限上限，
	 * 缺省 daemon_limits::kGraceMsDefault（原写死 kMaxGraceMs=30000）。
	 * setter 须在 active() 前调用才有意义（deactivate 才会读它），但即便
	 * 晚调用也不构成 UB——只是当次 deactivate 用旧值。 */
	int64_t deactivateGraceMs_ = daemon_limits::kGraceMsDefault;

	/* applySql 的阶段机（提交/热删除/整表撤下/生效摘要）已整体迁至热插提交服务
	 * （hotsql_service.hpp，2026-10-03 阶段 4）——本类只剩生命周期与门面装配。 */

public:
	/* 装配序与拆分前逐字同序：四个域门面（成员声明序）→ 装配机械（Internals 内部
	 * 依 factory/runner/hotSql 序构造）→ 结构脚本装载。定义在 robot_lifecycle.cpp
	 * ——那里能见到 Internals 的完整定义。 */
	explicit RobotStruct(bot::Reader& input);

	/* 兜底断电：仍未 deactivate 就补一次（幂等）。存在的理由是物理安全——
	 * 漏掉断电的代价是执行器停在最后指令位置、I2C 从设备滞留中间态。 */
	~RobotStruct();

	/* 激活所有硬件变量（两阶段构造：解析 → 创建 + build） */
	void active();

	/* 消除所有硬件变量（先统一置守护 stop 防饿死，再按声明序倒序 destroy） */
	void deactivate();

	/* 执行 @Action 矩阵（含内联 @Alias 注册）。
	 * injectVars：调用方在本次 run() 临时注入的会话别名（#34 条件反射「像函数
	 * 调用传参」的工具侧入口，见 run_action_script 的 vars）。每个键值注册为
	 * MtVars_Alias，脚本里的 $(键) 就地解析；生命周期 = 本次 run() 的
	 * SessionScope，出口（含异常路径）随作用域整体回滚，绝不跨 run() 残留。
	 * 键须为安全标识符（isSafeIdent），且不得是被结构引用的 controller/trigger
	 * 名（override 的 N-6 判据），违规即抛 IllegalArgumentException。
	 * 绑定发生在脚本内联 @Alias/@Vars 注册**之后**——调用方显式实参覆盖脚本内
	 * 同名默认值，与「函数实参优先于形参默认」一致。 */
	void run(bot::Reader& input, const std::map<std::string, std::string>& injectVars = {});

	/* ---- 热插表：结构 SQL 在上电之后真正生效（2026-09-23）----
	 * 契约：
	 *  1) sql 是**一条或一批**结构 SQL（CREATE TABLE / INSERT INTO / DELETE FROM /
	 *     DROP TABLE / UPDATE … SET … [WHERE …]；可混排），INSERT 的目标可以是
	 *     本批次新建的表，也可以是结构里既有表；
	 *  2) 前置条件 active() 已成功（机器人上电常驻）——热插是「带电变更」，
	 *     未上电时直接用结构脚本，不走这里；
	 *  3) 事务性：插入段**全成功或全回滚**。任何一步失败（校验/装配/build/动作
	 *     执行）都逆序 destroy 本批次新建的硬件、撤销注册与矩阵行，抛异常说明
	 *     成因；动作已下发的物理副作用不回退（与「已执行的动作不回退」同口径）。
	 *     DELETE/DROP 的物理断电**不可逆**（回滚 ≠ 复活器件）；UPDATE 的语义是
	 *     **断电重建**（命中行按「断电摘除 + 重新装配上电」执行），含 UPDATE 的
	 *     批次采用先删后建序——插入段失败时已摘除的旧行不复原，错误信息点名
	 *     丢失的变量。UPDATE 与该表的其它行级语句不得同批（readSQL 守门）；
	 *  4) Action 表**瞬态**（见 P6 注释）：其行不入结构矩阵、不注册变量，硬件
	 *     表全部 build 完成后执行一次随即丢弃——故动作可以引用本批次新建变量；
	 *  5) 返回一句人读的生效摘要（REPL /sql 与 agent apply_sql 共用）。 */
	std::string applySql(const std::string& sql);

	/* 设置 @Merge/@Include 的相对路径基准目录（语义见成员注释） */
	void setActionIncludeBaseDir(std::string dir) { actionIncludeBaseDir_ = std::move(dir); }

	/* 设置 deactivate() 二段屏障的宽限上限（--daemon-grace-ms，语义见成员注释） */
	void setDeactivateGraceMs(int64_t ms) { deactivateGraceMs_ = ms; }

	/* PL-2（2026-09-22）：把执行预算挂到**全部** Lua 硬件变量（budget=nullptr 解除）。
	 * 调用方用 RAII 成对调用——窗口只在 run_action_script 一次工具调用之内，
	 * 窗口外 JIT 与钩子必须复原（test_jit_warmup.lua 锁的是 JIT 路径，
	 * 不能被本机制静默废掉）。遍历 registry_.sequence()：一行 @Action 可能经
	 * controller 转发/trigger 前置走到别的 lua_State，只挂被点名那一个会漏。 */
	void armExecBudget(const LuaExecBudget* budget) {
		for (MatrixVars_Hardware* hv : registry_.sequence()) { hv->armExecBudget(budget); }
	}

	LifecycleState lifecycleState() const { return state_; }

	/* agent 模式：只读硬件注册表视图（清单/种类），供工具输出与提示词使用 */
	const HwRegistry& registry() const { return registry_; }

	/* ---- 域门面只读访问器（2026-10-03 阶段 4）----
	 * 跨域消费者一律经此处拿结构/元数据/守护三个域，不再穿透私有容器。结构与
	 * 元数据两条视图互补——structures() 看结构脚本定义（声明序），registry()
	 * 看装配结果；agent 的 /sql 查询从前者取数。写操作仍须经对应域的方法
	 * （各域门面自持不变式），此处只读。 */
	const StructureStore& structures() const { return structures_; }
	const MetaRegistry& metas() const { return metas_; }
	const DaemonRegistry& daemons() const { return daemons_; }

	/* agent 模式：结构脚本未声明某个 Lua 驱动变量时注入一个（须在 active() 之前调用）。
	 * LLM 协议驱动与摄像头驱动都走这里。
	 * 复用脚本装载同一条路径（合成 SQL 文本 → ScriptLoader::readSQL → 追加矩阵），
	 * 免得为「多一个变量」再造一套矩阵构造 API。
	 * driverTable 同时是驱动文件名（modules/<driverTable>.lua），与变量名都须是
	 * 安全标识符——否则合成出来的 SQL 会被注入出别的表。 */
	void injectLuaDriver(const std::string& driverTable, const std::string& varName);

};

} // namespace bot

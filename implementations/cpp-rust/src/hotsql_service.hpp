#pragma once
/* hotsql_service.hpp —— 热插表提交服务（2026-10-03 阶段 4 自 RobotStruct 迁出）
 *
 * 热插表（结构 SQL 带电生效）的**阶段机**整体住在这里：解析之后的提交、增量
 * 装配、上电、热删除、整表撤下与生效摘要。RobotStruct 只剩生命周期（上电/断电/
 * 运行）与门面装配——applySql 在 RobotStruct 一侧退化为「判生命周期 + 转交」。
 *
 * 跨域一律只经门面：本服务不持有任何裸容器，装配的是四个域门面
 * （StructureStore / HwRegistry / MetaRegistry / DaemonRegistry）与两个执行器
 * （HwFactory / ActionRunner）。跨域一致性（元数据摘除 ↔ 结构行擦除 ↔ 守护登记
 * ↔ 注册表撤注册）由本服务编排，域内不变式各自封装在门面里。
 *
 * 生命周期前置条件（须已 active()）由 RobotStruct::applySql 判定后才会调到
 * apply()——本服务不认识生命周期状态机。
 */

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

/* 门面头收窄（2026-10-10）：六个「只以引用出现」的域门面/类型改前置声明——
 * 本服务契约「跨域一律只经门面」，头里本就只该**命名**它们、不碰其定义。
 * 三个保留的实头是被**嵌套类型**钉住的（前向声明撑不起嵌套名）：
 *   hotsql_plan.hpp   HotSqlPlan::Deletes/Insertions/Deletion（签名按值/引用）
 *   hw_registry.hpp   HwRegistry::Mark（rollbackHotBatch 的标记形参）
 *   script_loader.hpp ScriptLoader::Mutations（各签名按引用）
 * 实现单元（hotsql_service.cpp）自行包含所需定义头。 */

#include "hotsql_plan.hpp"
#include "hw_registry.hpp"
#include "script_loader.hpp"

namespace bot {

class StructureStore;
class MetaRegistry;
class DaemonRegistry;
class HwFactory;
class ActionRunner;
class DaemonRunner;
class MatrixVars_Hardware;

class HotSqlService {
	StructureStore& structures_;
	HwRegistry& registry_;
	MetaRegistry& metas_;
	DaemonRegistry& daemons_;
	HwFactory& factory_;
	ActionRunner& runner_;

	/* ---- 热删除的物理执行（原 applySql 阶段 4.6，2026-09-23 热更新抽出）----
	 * 抽成函数供两个执行序共用：「先插入后删除」（既有批次——插入失败时删除
	 * 未执行，整批可回滚）与「先删后建」（含 UPDATE 的批次——改写行同名重建，
	 * 注册表重名即抛，必须先摘旧件再装新件）。计划必须由 apply() 在任何
	 * 插入/上电**之前**构建（hw 指针计划期取好；先建后拆下按名 find 会命中
	 * 新注册的同名变量、摘错对象）。语义与失败口径见实现处注释。 */
	struct HotDeleteOutcome {
		std::size_t deletedVars = 0;
		std::size_t deletedRows = 0;
		std::vector<std::string> deletedNames;
	};
	HotDeleteOutcome executeHotDeletes(const std::vector<HotSqlPlan::Deletion>& plans,
		const std::map<std::string, std::size_t>& daemonNameIndex, std::int64_t graceMs);

	/* ---- 热删除的一致性收尾（原 executeHotDeletes 阶段 4.6.4，2026-09-26 拆出）----
	 * 只对**已成功断电**的部分落实：① 摘除指向被删行的 MetaProvider → ①′ 重锚定
	 * 存活提供者的行号（removeRows 保序擦除会让其后行前移）→ ② 擦结构行 →
	 * ③ 按保留项重建守护登记表 → ④ registry_.removeBatch 撤注册。perTable 是
	 * 「矩阵下标 → 被删行号（原始坐标，升序）」、removed 是已断电变量指针集，
	 * 二者由调用方从销毁序清单算好传入——本方法不认 Doomed，只认这两个派生
	 * 视图与 dyingHolders。deletedRows 累加进 out。语义与顺序理由见实现处。 */
	void applyHotDeleteConsistency(
		const std::vector<std::pair<std::size_t, std::vector<std::size_t>>>& perTable,
		const std::set<MatrixVars_Hardware*>& removed,
		const std::vector<std::shared_ptr<DaemonRunner>>& dyingHolders,
		HotDeleteOutcome& out);

	/* 阶段 4 产物包：提交段的回执计数。mark.seq 不出函数——addedVars 在提交段
	 * 内部定值（「新增」必须在动手删之前记数，理由在实现处）。 */
	struct CommitOutcome {
		std::size_t addedVars = 0;
		std::size_t addedTables = 0;
		std::size_t addedRows = 0;
	};

	/* 阶段 4.7 产物包：整表撤下（DROP TABLE 空壳）的回执计数。 */
	struct DropOutcome {
		std::size_t count = 0;
		std::vector<std::string> names;
	};

	CommitOutcome commitHotBatch(const HotSqlPlan::Deletes& delPlan,
		HotSqlPlan::Insertions& insPlan, const HotDeleteOutcome& alreadyDeleted);
	DropOutcome dropTableShells(const ScriptLoader::Mutations& muts);

	/* 生效摘要（applySql 尾段，2026-10-01 拆出为纯拼装）：REPL /sql 与 agent
	 * apply_sql 共用同一句话，各计数口径见实现处。 */
	std::string summarizeHotOutcome(const CommitOutcome& committed,
		const ScriptLoader::Mutations& muts, const HotDeleteOutcome& delOutcome,
		const HotSqlPlan::Insertions& insPlan, const DropOutcome& dropped) const;

	/* ---- commitHotBatch 的两块拆出（2026-09-29 A3）----
	 * rollbackHotBatch：插入段失败的逆序断电 + 撤注册 + 恢复矩阵（原 45 行
	 * rollback lambda，语义逐字保持）；rethrowWithLostVars：先删后建批次的
	 * 失败重包装（点名已摘除且未重建的变量，理由见实现处注释）。 */
	void rollbackHotBatch(const HwRegistry::Mark& mark, std::size_t metaMark,
		std::size_t daemonMark,
		const std::vector<std::pair<std::size_t, std::size_t>>& appended,
		std::size_t addedTables);
	[[noreturn]] void rethrowWithLostVars(const HotDeleteOutcome& alreadyDeleted);

public:
	HotSqlService(StructureStore& structures, HwRegistry& registry, MetaRegistry& metas,
			DaemonRegistry& daemons, HwFactory& factory, ActionRunner& runner)
		: structures_(structures), registry_(registry), metas_(metas), daemons_(daemons),
		  factory_(factory), runner_(runner) {}

	/* 执行一批结构 SQL（契约见 RobotStruct::applySql 的公开注释）。
	 * graceMs = deactivate 二段屏障宽限上限（热删除的守护退场屏障共用同一预算，
	 * 由调用方在每次调用时传入当前值）。 */
	std::string apply(const std::string& sql, std::int64_t graceMs);
};

} // namespace bot
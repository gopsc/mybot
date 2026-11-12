#pragma once
/* hotsql_plan.hpp —— 热 SQL 只读计划层（拆自 robot.hpp，2026-09-29 A2；
 * 2026-10-01 起实现独立成 TU：hotsql_plan.cpp——计划层与 RobotStruct 的
 * 提交段不再共用 robot.cpp 的注释面，计划数据结构在此独立成头供两边引用）。 */

#include <cstddef>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "hardware.hpp"
#include "matrix.hpp"
#include "script_loader.hpp"

namespace bot {

/* ---- 热 SQL 计划数据：不持有硬件资源，提交段与只读计划层共用 ----
 * 行号/表下标与硬件指针均锚定建计划时的输入；调用方须在同一结构与注册表上
 * 立即执行一次，不得跨结构变更复用。指针只作为执行段的对象身份，不在计划期
 * 调用硬件方法；所有权始终属于注册表。 */
struct HotSqlPlan {
	struct Deletion {
		std::size_t matIdx = 0;		/* 输入矩阵下标 */
		std::string table;
		std::vector<std::size_t> rows;	/* 原始行号，升序 */
		std::vector<std::string> names;	/* 与 rows 平行：硬件变量名 */
		/* 与 names 平行：计划期从注册表取好的对象指针（pool_ 只增期间裸指针
		 * 稳定——对象在堆上，vector 扩容搬动的是 unique_ptr 不是对象本体）。 */
		std::vector<MatrixVars_Hardware*> hw;
	};

	/* 阶段 1.5 产物包：备删计划。前移到任何插入之前的理由（先删后建的两个
	 * 硬前提）在 planHotDeletes 实现处。 */
	struct Deletes {
		bool deleteFirst = false;		/* 批次含 UPDATE ⇒ 先删后建执行序 */
		std::set<std::string> doomedNames;	/* 将被摘除的变量名（阶段 2 重名预检豁免用） */
		std::vector<Deletion> dels;
		std::map<std::string, std::size_t> daemonNameIndex;	/* 守护名 → 声明序下标 */
		/* 表不在活体里 ⇒ 本批次 CREATE 出来的删除：撤销范围为空且必须为空，
		 * 但影子上的删除效果要落到待提交的新表上——对账读 newTables（阶段 2
		 * 的产物），只能延后到阶段 2.4（reconcileNewTableDels）。 */
		std::vector<std::pair<std::string, std::vector<std::size_t>>> newTableDels;
	};

	/* 阶段 2 产物包：建计划（新增行落位 + 新表 + 瞬态 Action），全部只读校验
	 * 通过后才存在；提交阶段按它增量装配。 */
	struct Insertions {
		/* (影子下标 [0, liveCount)，本批次新增行)——影子下标与输入矩阵一一对应 */
		std::vector<std::pair<std::size_t, std::vector<std::vector<std::string>>>> appends;
		std::vector<mt::MatrixObject> newTables;	/* 本批次新建的硬件表 */
		std::vector<mt::MatrixObject> actionMats;	/* 瞬态 Action（执行后即弃） */
	};

	ScriptLoader::Mutations mutations;
	Deletes deletions;
	Insertions insertions;
};

/* 解析 → 备删/插入计划 → 对账 → 合并预检。只依赖 const 结构视图和名字查询，
 * 不引用 RobotStruct、不持有 HwFactory；只读指硬件/结构只读，模块路径检测与
 * 既有告警仍会执行。装配期校验（如未知 $ 引用）仍由提交段负责，不提前改变
 * UPDATE 的失败口径。 */
class HotSqlPlanner {
	const std::deque<mt::MatrixObject>& matrices_;
	const HwLookup& registry_;

	HotSqlPlan::Deletes planHotDeletes(const ScriptLoader::Mutations& muts) const;
	HotSqlPlan::Insertions planHotInsertions(const std::deque<mt::MatrixObject>& staged,
		std::size_t liveCount, const ScriptLoader::Mutations& muts,
		const HotSqlPlan::Deletes& delPlan) const;
	static void reconcileNewTableDels(const std::deque<mt::MatrixObject>& staged,
		const HotSqlPlan::Deletes& delPlan, HotSqlPlan::Insertions& insPlan);
	void checkMergedView(const HotSqlPlan::Deletes& delPlan,
		const HotSqlPlan::Insertions& insPlan) const;

public:
	HotSqlPlanner(const std::deque<mt::MatrixObject>& matrices, const HwLookup& registry)
		: matrices_(matrices), registry_(registry) {}

	/* 成功返回即已通过原热 SQL 只读预检；无需 active() 或硬件装配。 */
	HotSqlPlan build(const std::string& sql) const;
};

} // namespace bot

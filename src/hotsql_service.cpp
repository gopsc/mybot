/* hotsql_service.cpp —— 热插表提交服务（2026-10-03 阶段 4 自 robot.cpp 迁出）
 *
 * applySql 的阶段机（0/1/1.5/2/2.4/3/4/4.6/4.7）原本住在 RobotStruct：解析层
 * 早已在 hotsql_plan.cpp，本 TU 承接其余——提交（commitHotBatch）、热删除
 * （executeHotDeletes）、一致性收尾（applyHotDeleteConsistency）、整表撤下
 * （dropTableShells）与生效摘要（summarizeHotOutcome）。实现逐字迁移，只把容器
 * 成员改为门面引用、把 deactivateGraceMs_ 改为 apply() 传入的 graceMs。
 *
 * 阶段编号的判据与理由注释随实现一并迁移（2026-09-25 拆分时的注释一字未改）。 */

#include "hotsql_service.hpp"

/* 门面定义头（2026-10-10 起由实现侧显式引入：头收窄后不再经传递依赖获得） */
#include "action_runner.hpp"
#include "daemon_registry.hpp"
#include "hardware.hpp"
#include "hw_factory.hpp"
#include "meta_registry.hpp"
#include "structure_store.hpp"

/* DaemonRunner 完整类型：skills 里本 TU 只做 shared_ptr 转手与 .get()，但
 * 保留显式引入以免将来加成员访问时踩到不完整类型。 */
#include "daemonvar.hpp"

#include <algorithm>
#include <iostream>
#include <memory>
#include <set>

#include "util_env.hpp"		/* stopRequested（热插/热删除的中断响应点） */
#include "util_except.hpp"	/* kNonStdExceptionNote（非 std 异常兜底拼接） */
#include "util_str.hpp"		/* joinNames（点名/成因列表拼接单点）、trim */

namespace bot {

namespace {

/* 热删除中途失败的报错文本拼装（拆自 executeHotDeletes，2026-09-26 批次 5）。
 * 口径：如实报「已删 N 个、M 个未删」+ 逐个点名 + 成因，并说明结构与注册表
 * 只反映已成功摘除的部分（不假装回滚——destroy 是物理断电，不可逆）。 */
std::string hotDeleteFailureMessage(std::size_t orderSize, std::size_t deletedVars,
		const std::vector<std::string>& deletedNames,
		const std::vector<std::string>& failures) {
	std::string msg = "热删除中途失败：已删除 " + std::to_string(deletedVars)
		+ " 个硬件变量";
	if (!deletedNames.empty()) {
		msg += "（";
		msg += joinNames(deletedNames);
		msg += "）";
	}
	msg += "，" + std::to_string(orderSize - deletedVars) + " 个未删除。成因：";
	msg += joinNames(failures, "; ");
	msg += "。结构与注册表只反映已成功摘除的部分，未删的行保持原状。"
		"（destroy 是物理断电，已断电的器件不会因报错而复电——修好成因后"
		"对剩余项重发 DELETE 即可。）";
	return msg;
}

} // namespace

/* ==================== 热插表：结构 SQL 带电生效（2026-09-23）====================
 * 目标：上电常驻之后，用结构 SQL（CREATE TABLE / INSERT INTO）真正长出硬件
 * 变量——装配、开 fd、上电、断电一并纳入本进程的生命周期。
 *
 * 三阶段（解析 → 校验 → 提交）之所以必须**分阶段**，是因为每个阶段的失败
 * 形态不同：解析失败必须「活体一字未动」，校验失败必须「报错而不是跑出半
 * 成品」，提交阶段才允许触碰活体（且由 rollback 兜住任何中途失败）。
 *
 * 几个关键设计（每条都对应一个「不做就静默出错」的坑）：
 *  ① 影子容器：readSQL 的 INSERT 要求目标表已在同一容器里（C3 按列名落位、
 *     漏列/未知列报错全靠它）。为让「插进结构里既有表」也走同一条解析路径，
 *     先往影子容器填「每张既有表的表名 + 列头」，再让解析器往影子上追加行。
 *  ② 同名判定：新表名与结构里既有表重名（或本批次内 CREATE 两遍）必须报错
 *     ——否则 envelope 里会出现两张同名表，findByName 只会命中第一张，
 *     后一张静默作废。
 *  ③ 提交顺序＝声明序：既有表先 appendRow（矩阵是装配的输入，顺序不能反）、
 *     再 createHardVarsFrom，最后统一 build。$ 引用校验只对本批次新增的
 *     MetaProvider 做（既有变量在启动期已校验过），批内前向引用合法。
 *  ④ Action 表瞬态（见下方 4.5）：不入结构矩阵、不注册变量，硬件全部
 *     build 完成后执行一次即丢弃——排序正是为了让动作能引用本批次新建的
 *     变量；动作已下发的物理副作用不回退（与仓库既有口径一致）。
 *  ⑤ 回滚：逆序 destroy（断电）→ 撤注册（HwRegistry::rollbackTo）→ 弹
 *     MetaProvider/守护登记 → 恢复矩阵行/表。**先断电再撤所有权**：注册表
 *     只认硬件变量，断电是物理动作，顺序反了会让器件带电却已无人认识。
 */
std::string HotSqlService::apply(const std::string& sql, std::int64_t graceMs) {
	/* ---- 阶段地图（2026-09-25 拆分：每段的判据与理由在对应阶段函数实现处）----
	 *  0   前置条件（须已上电常驻）——由 RobotStruct::applySql 判定后转交；
	 *  1   解析到影子容器（活体一字未动；readSQL 直接在影子上落删除）；
	 *  1.5 备删计划（planHotDeletes——先删后建的两条硬前提都要求它在插入之前）；
	 *  2   建计划 + 只读全量校验（planHotInsertions）；
	 *  2.4 批次新建表的删除对账（reconcileNewTableDels）；
	 *  3   合并视图判据：全结构消费判据 + 引用完整性（checkMergedView）；
	 *  4   提交 + 增量装配 + 上电（commitHotBatch——插入段任何一步失败 ⇒ 全回滚）；
	 *  4.6 热删除物理执行（executeHotDeletes，两个执行序按 deleteFirst 分派）；
	 *  4.7 整表撤下（dropTableShells）；
	 *  尾  生效摘要（REPL /sql 与 agent apply_sql 共用同一句话）。 */

	/* 阶段 1—3 只读：完整预检通过后才返回计划，以下才允许动活体。 */
	HotSqlPlan plan = HotSqlPlanner(structures_.all(), registry_).build(sql);
	const auto& muts = plan.mutations;
	const auto& delPlan = plan.deletions;
	auto& insPlan = plan.insertions;

	/* ---- 阶段 4 + 4.6：提交，删除按执行序分派 ----
	 * 执行序（2026-09-23 热更新起有两种，按批次是否含 UPDATE 分派）：
	 *  * 先插入后删除（既有次序；非 UPDATE 批次行为逐字保持）：插入段全程
	 *    可回滚，物理删除排**最后**（本函数 4.6 段）——「DELETE + INSERT 同批
	 *    且插入失败」时删除从未发生，整批回到原点；
	 *  * 先删后建（deleteFirst，批次含 UPDATE——改写行同名重建，注册表重名
	 *    即抛，必须先摘旧件再装新件）：删除的不可逆点提前到插入之前（此处），
	 *    插入段失败时新件全数回滚断电、已摘旧件**不复原**（destroy 是物理断电，
	 *    回滚 ≠ 复活器件），commitHotBatch 的 catch 块如实点名丢失的变量。收益
	 *    有二：新旧器件不再短暂并存抢同一物理器件；新行 MetaProvider 的行号在
	 *    创建时就已是终值，不会被随后的删行前移打乱。 */
	HotDeleteOutcome delOutcome;
	if (delPlan.deleteFirst) {
		delOutcome = executeHotDeletes(delPlan.dels, delPlan.daemonNameIndex, graceMs);
	}
	const CommitOutcome committed = commitHotBatch(delPlan, insPlan, delOutcome);

	/* 4.6（非 UPDATE 批次的删除）：排在这里 = 全部可回滚工作之后——插入段失败
	 * 时删除从未发生，整批回到原点（「一旦开始删，前面新增的部分都已成功」，
	 * 不存在「新器件要回滚、旧器件已删掉」的混合状态）；UPDATE 批次已在提交前
	 * 执行过，此处跳过。 */
	if (!delPlan.deleteFirst) {
		delOutcome = executeHotDeletes(delPlan.dels, delPlan.daemonNameIndex, graceMs);
	}

	/* ---- 阶段 4.7：整表撤下（DROP TABLE 空壳，不可逆）——位置约束与重锚定
	 * 的理由在实现处 ---- */
	const DropOutcome dropped = dropTableShells(muts);

	return summarizeHotOutcome(committed, muts, delOutcome, insPlan, dropped);
}

/* ---- 生效摘要（applySql 尾段，2026-10-01 拆出为纯拼装）----
 * REPL /sql 与 agent apply_sql 共用同一句话；热更新行数（G2 对账）：改写行
 * 的物理事实同时体现在「新增」与「删除」两个计数里（断电重建），本行是
 * 改写事实的独立记账——复盘时三个数能相互对上。 */
std::string HotSqlService::summarizeHotOutcome(const CommitOutcome& committed,
		const ScriptLoader::Mutations& muts, const HotDeleteOutcome& delOutcome,
		const HotSqlPlan::Insertions& insPlan, const DropOutcome& dropped) const {
	std::string msg = "已生效：新增硬件变量 " + std::to_string(committed.addedVars) + " 个";
	if (committed.addedTables > 0) { msg += "，新增表 " + std::to_string(committed.addedTables) + " 张"; }
	if (committed.addedRows > 0) { msg += "，既有表追加 " + std::to_string(committed.addedRows) + " 行"; }
	std::size_t updatedTotal = 0;
	for (const auto& [t, n] : muts.updatedRows) { (void)t; updatedTotal += n; }
	if (updatedTotal > 0) {
		msg += "，已热更新 " + std::to_string(updatedTotal) + " 行（断电重建）";
	}
	if (delOutcome.deletedVars > 0) {
		msg += "，已删除硬件变量 " + std::to_string(delOutcome.deletedVars) + " 个（";
		msg += joinNames(delOutcome.deletedNames);
		msg += "）";
		if (delOutcome.deletedRows > delOutcome.deletedVars) {
			msg += "、结构表删除 " + std::to_string(delOutcome.deletedRows) + " 行";
		}
	}
	if (!insPlan.actionMats.empty()) {
		std::size_t n = 0;
		for (const auto& m : insPlan.actionMats) { n += m.rows() > 0 ? m.rows() - 1 : 0; }
		msg += "，瞬态动作已执行 " + std::to_string(n) + " 行（未注册，已丢弃）";
	}
	if (dropped.count > 0) {
		msg += "，已撤下表 " + std::to_string(dropped.count) + " 张（";
		msg += joinNames(dropped.names);
		msg += "）";
	}
	return msg;
}

/* ==================== HotSqlPlanner：只读计划层 ====================
 * build / planHotDeletes / planHotInsertions / reconcileNewTableDels /
 * checkMergedView 的实现已整体迁至 hotsql_plan.cpp（2026-10-01 TU 拆分），
 * 阶段编号（1/1.5/2/2.4/3）的判据与理由注释随实现迁移。 */

/* ---- 阶段 4：提交 + 增量装配 + 上电（插入段任何一步失败 ⇒ 全回滚）----
 * deleteFirst 批次的物理删除已在 apply（本函数之前）执行，其结果经
 * alreadyDeleted 传入——catch 的失败口径要据它点名已丢失的变量。
 * mark 取在（可能已发生的）删除之后：先删后建下 mark.seq 即删后规模，
 * 回滚只回滚插入段——已执行的物理删除不在任何回滚范围内。 */
HotSqlService::CommitOutcome HotSqlService::commitHotBatch(
		const HotSqlPlan::Deletes& delPlan,
		HotSqlPlan::Insertions& insPlan, const HotDeleteOutcome& alreadyDeleted) {
	CommitOutcome out;
	const HwRegistry::Mark mark = registry_.mark();
	const std::size_t metaMark = metas_.size();
	const std::size_t daemonMark = daemons_.size();
	std::vector<std::pair<std::size_t, std::size_t>> appended;	/* (矩阵下标, 追加行数) */
	std::size_t addedTables = 0;

	try {
		/* 4.1 既有表：先落行（矩阵是装配的输入），再按旧行数增量装配 */
		for (const auto& [idx, rows] : insPlan.appends) {
			const std::int64_t from = structures_.appendRows(idx, rows);
			appended.emplace_back(idx, rows.size());
			factory_.createHardVarsFrom(structures_.at(idx), from);
		}
		/* 4.2 新表：整表入列后按 fromRow=1 装配 */
		for (auto& t : insPlan.newTables) {
			structures_.append(std::move(t));
			++addedTables;
			factory_.createHardVarsFrom(structures_.back(), 1);
		}
		/* 4.3 $ 引用存在性：只查本批次新增的 MetaProvider（此时批内变量已全部注册，
		 *     故批内前向引用合法；既有提供者启动期已校验） */
		metas_.validateFrom(metaMark);
		/* 4.4 上电：只 build 本批次新增的（声明序），与 active() 同查停止标志
		 *     ——多驱动逐个 build 期间可能有真机延时，Ctrl-C 必须能中止并回滚。 */
		const auto& seq = registry_.sequence();
		for (std::size_t i = mark.seq; i < seq.size(); ++i) {
			if (stopRequested()) {
				throw std::runtime_error("热插上电被中断（收到停止信号）：本批次变更正在回滚");
			}
			seq[i]->build();
		}
		/* 4.5 瞬态 Action：排在硬件之后执行（动作可引用本批次新建变量），
		 *     执行完即丢弃——不入结构矩阵、不注册。执行失败同样回滚本批次硬件
		 *     （结构回到批次前状态），但动作已下发的物理副作用不回退。 */
		if (!insPlan.actionMats.empty()) { runner_.runAction(insPlan.actionMats); }
	} catch (...) {
		try {
			rollbackHotBatch(mark, metaMark, daemonMark, appended, addedTables);
		} catch (const std::exception& e) {
			/* 回滚本身失败已超出手头能修的范畴：如实留痕，但不掩盖原错误
			 * （原错误才是调用方要看的成因）。 */
			std::cerr << "Hot SQL rollback FAILED: " << e.what() << std::endl;
		}
		/* 先删后建的失败口径（区别于既有批次的「原样上抛」）：本批次含 UPDATE
		 * 且已摘除过旧件时，活体**已经动过**——插入段失败只是「新件未建成」，
		 * 旧件不会回来（重包装的理由见 rethrowWithLostVars 注释）。 */
		if (delPlan.deleteFirst && alreadyDeleted.deletedVars > 0) {
			rethrowWithLostVars(alreadyDeleted);
		}
		throw;
	}

	/* 「新增了几个变量」必须在**动手删之前**定下来：删除会从同一份注册表里摘
	 * 条目，用「事后总数 - 批次前总数」会把两边相互抵掉（同批删一插一时净增量
	 * 为 0，摘要就会谎报「新增 0 个」）。新增是「装配阶段登记了多少」这个
	 * 绝对值（此刻的注册表规模 = deleteFirst 批次的「删后 + 插后」，与删后
	 * mark.seq 相减同样得出纯新增数），删除是另一个维度，两者各自如实报数。 */
	const std::size_t varsAfterInsert = registry_.sequence().size();
	out.addedVars = varsAfterInsert - mark.seq;
	for (const auto& [idx, n] : appended) { (void)idx; out.addedRows += n; }
	out.addedTables = addedTables;
	return out;
}

/* 插入段失败的回滚（原 commitHotBatch 内 45 行 rollback lambda，2026-09-29
 * A3 拆出；四步语义逐字保持）：
 * ① 逆序断电：destroy 逐项容错（半装配/未 build 的项也要能安全 destroy，
 *    与 deactivate 同口径），单个失败不能中断整轮回滚。
 * ② 撤注册（含流引用快照还原）→ ③ 弹登记表 → ④ 恢复矩阵。 */
void HotSqlService::rollbackHotBatch(const HwRegistry::Mark& mark, std::size_t metaMark,
		std::size_t daemonMark,
		const std::vector<std::pair<std::size_t, std::size_t>>& appended,
		std::size_t addedTables) {
	const auto& seq = registry_.sequence();
	for (std::size_t i = seq.size(); i > mark.seq; --i) {
		try {
			seq[i - 1]->destroy();
		} catch (const std::exception& e) {
			std::cerr << "Hot SQL rollback warning: " << e.what() << std::endl;
		}
	}
	registry_.rollbackTo(mark);
	metas_.truncate(metaMark);
	daemons_.truncate(daemonMark);
	for (const auto& [idx, n] : appended) { structures_.popRows(idx, n); }
	structures_.truncate(structures_.size() - addedTables);
}

/* 先删后建批次插入段失败的重包装：本批次含 UPDATE 且已摘除过旧件时，活体
 * **已经动过**——插入段失败只是「新件未建成」，旧件不会回来。把成因包装成
 * runtime_error 并点名丢失的变量：
 *  - 不谎报：模型/操作者必须知道「哪些变量已经没了」；
 *  - 类型必须是 runtime_error 而非原样上抛——若成因本身是
 *    IllegalArgumentException（如装配期重名），apply_sql 的派发漏斗
 *    会按异常类型把它归类成「校验拒绝、活体一字未动」（paramError /
 *    executed=false），对本口径是谎报：删旧件是真实发生过的副作用。 */
void HotSqlService::rethrowWithLostVars(const HotDeleteOutcome& alreadyDeleted) {
	const std::string names = joinNames(alreadyDeleted.deletedNames);
	const std::string tail = concatMsg(
		"；注意：本批次含 UPDATE，其命中旧行已断电摘除且未能重建（",
		names, "）——硬件不会自动复原，请核对状态后按需要的值重新 INSERT");
	try {
		throw;
	} catch (const std::exception& e) {
		throw std::runtime_error(concatMsg(
			std::string(e.what()), tail));
	} catch (...) {
		throw std::runtime_error(concatMsg(
			std::string(kNonStdExceptionNote), tail));
	}
}

/* ==================== 阶段 4.7：整表撤下（DROP TABLE，不可逆）====================
 * 位置在 4.6 之后：DROP 的**全部数据行**已由 4.6 走完与 DELETE 完全相同的
 * 「逆序断电 → 擦登记表 → 擦结构行 → 撤注册」路径（DROP 就是把整表行全删
 * 再加一步摘表壳），故这里只剩**空表壳**要摘。
 *
 * 为什么表壳必须最后摘：4.6.4 用「矩阵地址 + 行号」定位被删行的 MetaProvider，
 * 而矩阵地址取自 StructureStore::at(mi)——一旦先 erase 表壳，其后所有表的下标与地址
 * 都会变，4.6 的判据就全错位。故顺序是死的：先按行删（4.6），再摘壳（本节）。
 *
 * deque 中间 erase 的引用失效：MetaProvider::matrix_ 存的是指向结构矩阵
 * 元素的指针；erase 会让其后元素引用失效。**必须先把存活提供者的表名抓下来
 * 再 erase**（表名唯一且是稳定身份），erase 后按名把每个提供者重锚定回新地址
 * ——否则后续 readSample/collect 会踩悬垂指针。这也正是 matrix.hpp 把矩阵
 * 容器从 vector 换成 deque 之外、又为整表撤下专门保留 rebase 的原因。 */
HotSqlService::DropOutcome HotSqlService::dropTableShells(const ScriptLoader::Mutations& muts) {
	DropOutcome out;
	if (muts.droppedTables.empty()) { return out; }
	/* ① 抓名字（erase 之前，此时 matrix_ 仍有效） */
	const MetaRegistry::TableNameSnapshot provNames = metas_.captureTableNames();
	/* ② 定位要摘的表壳（本批次 DROP 的表名 ∩ 活体结构表）。DROP 本批次
	 *     新建的表不在活体里（readSQL 已把它从影子容器整表擦除），此处自然
	 *     找不到——那不是错误，跳过即可。 */
	std::vector<std::size_t> shellIdx;
	const auto& tables = structures_.all();
	for (std::size_t k = 0; k < tables.size(); ++k) {
		if (muts.droppedTables.count(trim(tables[k].getName())) != 0) {
			shellIdx.push_back(k);
			out.names.push_back(trim(tables[k].getName()));
		}
	}
	/* ③ 降序 erase（先删大下标，前面的下标不失效） */
	for (auto it = shellIdx.rbegin(); it != shellIdx.rend(); ++it) {
		structures_.eraseTable(*it);
		++out.count;
	}
	/* ④ 重锚定存活提供者：按名字找同名的矩阵地址。只在**确实摘过表壳**时做
	 *    ——「本批次 CREATE 后又 DROP」的新表不在活体里（shellIdx 为空），
	 *    此时没有元素被搬移，重锚定是空转。 */
	if (!shellIdx.empty()) {
		metas_.rebaseByName(provNames,
			[this](const std::string& nm) { return structures_.find(nm); });
	}
	return out;
}

/* ==================== 热删除的物理执行（原 applySql 阶段 4.6，不可逆）====================
 * 供两个执行序共用（谁先谁后由 apply 按批次是否含 UPDATE 分派，见其阶段 4
 * 注释）：非 UPDATE 批次排在全部可回滚工作之后（插入失败 ⇒ 删除从未发生）；
 * UPDATE 批次（先删后建）排在插入之前（同名重建必须先摘旧件，插入失败 ⇒
 * 旧件已摘、新件回滚，apply 的 catch 会点名丢失的变量）。
 *
 * 顺序：逆序断电 → 擦登记表 → 擦结构行 → 撤注册。每一步的理由：
 *  ① 逆声明序（表下标倒序、表内行号倒序）：销毁序 = 声明序倒序是既有资源
 *     不变式——总线变量的 fd 只在它自己的 destroy 里关闭，而挂在它上面的
 *     器件 destroy 要用同一个 fd 做去初始化，倒序保证总线最后关 fd。
 *     按行号倒序另有一条收益：被删行号之后创建的 MetaProvider 在先删后建
 *     模式下根本还不存在，在先插入后删除模式下则由 4.6.4① 的整条摘除兜住。
 *  ② 守护先行（requestStop + 屏障等待）：守护是唯一跨线程碰硬件的角色，
 *     必须在它的采样对象掉电之前退场，否则会去写一个已断电的器件
 *     （deactivate 的断电屏障是同一套理由，这里复用同样的共享预算手法）。
 *  ③ 先摘登记表再擦矩阵行：反过来会让 MetaProvider 短暂指向已不存在的行
 *     （popRows/removeRows 之后 row_ 越界即抛）。
 *  ④ 最后撤注册：registry_.removeBatch 在对象析构前撤所有权，故「名字查得到
 *     但器件已断电」的窗口不存在。
 *
 * 失败语义（与「全成功或全回滚」并列的第二套口径，如实告知而不假装回滚）：
 * 预检已在 apply 的引用完整性/全结构判据里拦下全部可预判的错误，故这里
 * 失败只可能来自物理 destroy 本身（I2C 写失败、器件不响应…）。此时立即中止
 * 后续 destroy（继续硬闯只在别的器件上叠加失败），并如实报出「已删 N 个、
 * M 个未删」——结构矩阵与注册表保持**一致**（都只反映已成功删掉的部分），
 * 不留半删状态。
 *
 * hw 指针来自计划（plans）而非按名 find：先删后建模式下执行点在插入之后，
 * 按名 find 会命中新注册的同名变量、摘错对象——计划期取好指针是正确性前提
 * （见 apply 阶段 1.5 的注释）。
 *
 * 25.4 评估后判不改（90 行）：函数体已经按设计文档的 4.6.0–4.6.4 分成五段编号
 * 编排，三段真有复杂度的部分**已经**委托给具名单点（DaemonRegistry::stopBarrier
 * 的清单入口、applyHotDeleteConsistency、hotDeleteFailureMessage），剩下的长度
 * 就是编排顺序本身——而顺序正是这里的安全性质（屏障必须在断电之前、断电必须
 * 逆序、一致性收尾只对**已成功断电**的部分落实）。唯一像样的接缝是把 4.6.0 的
 * 展平+排序（约 17 行）抽出去，代价是把局部 struct Doomed 提成文件级类型、并让
 * 排序比较器那两条「表倒序 / 表内行号倒序」的注释与消费它的循环分家，净 LOC ≈ 0。 */
HotSqlService::HotDeleteOutcome HotSqlService::executeHotDeletes(
		const std::vector<HotSqlPlan::Deletion>& plans,
		const std::map<std::string, std::size_t>& daemonNameIndex,
		std::int64_t graceMs) {
	HotDeleteOutcome out;
	if (plans.empty()) { return out; }
	/* 4.6.0 逆声明序展平成「实际销毁顺序」清单 */
	struct Doomed {
		std::size_t matIdx = 0;
		std::size_t row = 0;
		std::string name;
		MatrixVars_Hardware* hw = nullptr;
	};
	std::vector<Doomed> order;
	for (const HotSqlPlan::Deletion& p : plans) {
		for (std::size_t k = 0; k < p.rows.size(); ++k) {
			order.push_back({p.matIdx, p.rows[k], p.names[k], p.hw[k]});
		}
	}
	std::sort(order.begin(), order.end(), [](const Doomed& a, const Doomed& b) {
		if (a.matIdx != b.matIdx) { return a.matIdx > b.matIdx; }	/* 表：倒序 */
		return a.row > b.row;					/* 表内：行号倒序 */
	});

	/* 4.6.1 待删守护：从原始行号定位登记槽（必须在矩阵被改写之前取出来
	 * ——槽是「哪一行是守护」的唯一索引，行没了就找不回来了）。 */
	std::vector<std::shared_ptr<DaemonRunner>> dyingHolders;
	for (const HotSqlPlan::Deletion& p : plans) {
		if (p.table != "Daemon") { continue; }
		for (std::size_t k = 0; k < p.names.size(); ++k) {
			auto slot = daemonNameIndex.find(p.names[k]);
			if (slot == daemonNameIndex.end() || slot->second >= daemons_.size()) {
				throw IllegalArgumentException(concatMsg(
					"热删除：守护 '", p.names[k], "' 找不到对应的守护线程登记槽（内部不一致）"));
			}
			dyingHolders.push_back(daemons_.at(slot->second));
		}
	}
	/* 4.6.2 守护退场屏障：与 deactivate() 同一套安全序列，单点在守护域
	 * （DaemonRegistry::stopBarrier 的清单入口，只停将被摘件的这批）——屏障
	 * 之后才允许动硬件。 */
	DaemonRegistry::stopBarrier(dyingHolders, graceMs, "HotDelete",
		"the doomed hardware's destroy will race with them"
		" (their sampling targets are being removed)");
	if (stopRequested()) {
		throw std::runtime_error("热删除被中断（收到停止信号）：本批次的删除尚未开始");
	}

	/* 4.6.3 逆序断电（逐项容错并点名；失败即中止剩余项） */
	std::vector<std::string> failures;
	std::size_t attempted = 0;
	for (const Doomed& d : order) {
		if (stopRequested()) {
			failures.push_back("（收到停止信号，剩余 "
				+ std::to_string(order.size() - attempted) + " 个未删除）");
			break;
		}
		++attempted;
		try {
			d.hw->destroy();
		} catch (const std::exception& e) {
			failures.push_back(d.name + ": " + e.what());
			break;		/* 中止剩余项：继续硬闯只在别的器件上叠加失败 */
		}
		++out.deletedVars;
		out.deletedNames.push_back(d.name);
	}

	/* 4.6.4 结构/注册表的一致性收尾：只对**已成功断电**的部分落实。
	 * 未删成的行原样留在结构里（仍是活体的一部分，语义自洽）。 */
	if (out.deletedVars > 0) {
		std::set<MatrixVars_Hardware*> removed;
		std::vector<std::pair<std::size_t, std::vector<std::size_t>>> perTable;
		{
			std::map<std::size_t, std::vector<std::size_t>> byMat;
			for (std::size_t i = 0; i < order.size() && i < out.deletedVars; ++i) {
				byMat[order[i].matIdx].push_back(order[i].row);
				removed.insert(order[i].hw);
			}
			for (auto& [mi, rs] : byMat) { perTable.emplace_back(mi, std::move(rs)); }
		}
		applyHotDeleteConsistency(perTable, removed, dyingHolders, out);
	}

	if (!failures.empty()) {
		throw std::runtime_error(hotDeleteFailureMessage(order.size(), out.deletedVars,
			out.deletedNames, failures));
	}
	return out;
}

/* ---- 热删除的一致性收尾（原 executeHotDeletes 阶段 4.6.4，2026-09-26 批次 5 拆出）----
 * 只对**已成功断电**的部分落实「结构矩阵与注册表保持一致」；未删成的行原样留在
 * 结构里（仍是活体的一部分，语义自洽）。五步顺序是死的：
 *  ① 先摘指向被删行的 MetaProvider——判据用「矩阵 + 行号」，而行号此刻还是删除前
 *     的原始坐标，故必须先于 ①′/②（擦行会让坐标前移）。
 *  ①′ 重锚定存活提供者行号——② 的保序擦除使其后行前移，提供者 row() 必须同步。
 *  ② 擦结构行（保序，销毁序不变式不动）。
 *  ③ 守护登记表按保留项重建（不 resize：删中间项会让尾部前移）。
 *  ④ 最后撤注册：registry_.removeBatch 在对象析构前撤所有权，故「名字查得到但
 *     器件已断电」的窗口不存在。 */
void HotSqlService::applyHotDeleteConsistency(
		const std::vector<std::pair<std::size_t, std::vector<std::size_t>>>& perTable,
		const std::set<MatrixVars_Hardware*>& removed,
		const std::vector<std::shared_ptr<DaemonRunner>>& dyingHolders,
		HotDeleteOutcome& out) {
	/* ① 元数据提供者：指向被删行的整条摘除。判据是「矩阵 + 行号」而不是
	 * 引用相等——矩阵是 std::deque 的元素，地址稳定（这正是选 deque 的
	 * 原因），故该判据精确且不受行数变化影响；行号此刻还是删除前的
	 * 原始坐标，故必须先于 ①′/② 执行。 */
	std::set<std::pair<const mt::MatrixObject*, std::int64_t>> deadProvider;
	for (const auto& [mi, rs] : perTable) {
		for (std::size_t r : rs) {
			deadProvider.emplace(&structures_.at(mi), static_cast<std::int64_t>(r));
		}
	}
	metas_.dropRows(deadProvider);
	/* ①′ 存活提供者行号重锚定（2026-09-25 审计 A-4 收口）：② 的 removeRows
	 * 是保序擦除——同矩阵内行号大于被删行的行全部前移。提供者的 row()
	 * 是**后续批次** deadProvider 判据的坐标（上一步刚用过）与任何未来
	 * 惰性取行的下标，必须按「本矩阵被删行中小于本行行号的数量」同步
	 * 前移，否则下一批同表删除会摘错/漏摘提供者。原实现在这里留有已知
	 * 边界：混批（先插入后删除）新追加行的提供者以追加时行号创建，随
	 * 后的删行让其 row_ 过期——实际上不止混批，**任何**同表删行都会让
	 * 存活行的坐标过期（含先删后建的 UPDATE 批次里未改写的既有行），
	 * 本步骤一并收口。混批里追加行的 provider 已在 commitHotBatch 4.3
	 * 急切 seed（缓存以追加时坐标取到的是正确内容），此处只修坐标。 */
	for (const auto& [mi, rs] : perTable) {
		metas_.shiftRowsAfter(&structures_.at(mi), rs);
	}
	/* ② 结构行（保序擦除，销毁序不变式不动） */
	for (const auto& [mi, rs] : perTable) {
		structures_.removeRows(mi, rs);
		out.deletedRows += rs.size();
	}
	/* ③ 守护登记表：按保留项重建（不做 resize——删中间项会让尾部前移，
	 * resize 只能表达「砍掉尾巴」）。 */
	std::set<const DaemonRunner*> deadRunners;
	for (const auto& h : dyingHolders) { deadRunners.insert(h.get()); }
	daemons_.remove(deadRunners);
	/* ④ 撤注册（所有权 + 名字索引 + 流引用） */
	registry_.removeBatch(removed);
}

} // namespace bot
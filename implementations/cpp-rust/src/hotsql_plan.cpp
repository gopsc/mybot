/* hotsql_plan.cpp —— HotSqlPlanner 只读热 SQL 计划层（拆自 robot.cpp，2026-10-01）
 * 解析 → 备删/插入计划 → 对账 → 合并预检，全部只读（活体一字未动）；提交段
 * （commitHotBatch / executeHotDeletes / dropTableShells）在 hotsql_service.cpp
 * （2026-10-03 阶段 4 自 robot.cpp 迁出，robot 门面只剩生命周期与装配）。
 * 阶段编号（1/1.5/2/2.4/3）的语义与理由见各函数实现处注释。 */

#include "daemonconf.hpp"
#include "hotsql_plan.hpp"

/* 流引用列判定（controller/trigger 及编号列）——热删除的引用完整性预检要用。
 * 走单点是必须的：controller2/trigger10 这类编号列也算引用列，自带一份判据
 * 就会漏掉它们而留下悬垂指针。 */
#include "flowcolumn.hpp"

#include <set>
#include <utility>

#include "expr.hpp"		/* Expression::parse / exprBody（$(...) 引用扫描） */
#include "hw_factory.hpp"	/* HwFactory::precheckStructure（合并视图全结构判据） */
#include "util_except.hpp"	/* IllegalArgumentException / MemoryReader */
#include "util_path.hpp"	/* modulePaths / findExistingModule / checkRelPath */
#include "util_str.hpp"		/* trim / isSafeIdent / concatMsg */

namespace bot {

namespace {

/* 把列头行 + [rowBegin, rowEnd) 的数据行复制成一张独立矩阵——影子构建
 * （既有表全量复制）与瞬态 Action 提取（仅本批次新增段）共用同一份逐格
 * 拷贝；line(0) 之后逐行 b.line(原始行号)，两种场景的行号语义一致。 */
mt::MatrixObject copyRows(const mt::MatrixObject& src, std::size_t rowBegin, std::size_t rowEnd) {
	mt::MatrixBuilder b;
	b.name(src.getName());
	for (std::size_t c = 0; c < src.cols(); ++c) { b.item(src(0, c)); }
	b.line(0);
	for (std::size_t r = rowBegin; r < rowEnd; ++r) {
		for (std::size_t c = 0; c < src.cols(); ++c) { b.item(src(r, c)); }
		b.line(static_cast<std::int64_t>(r));
	}
	return b.take();
}

/* ---- 阶段 2 的两个只读校验块（拆自 planHotInsertions，2026-09-29 A3）----
 * 判定与报错文案逐字保持；抽出后 planHotInsertions 只留区间计算与建计划。 */

/* 本批次新建表（staged[si]，si ≥ liveCount）的表级校验：批内/结构内重名、
 * 表名与列名的安全标识符、驱动模块存在性。 */
void validateNewTableDecl(const std::deque<mt::MatrixObject>& staged, std::size_t si) {
	const mt::MatrixObject& st = staged[si];
	const std::string tname = trim(st.getName());
	const bool isAction = (tname == "Action");

	for (std::size_t sj = 0; sj < si; ++sj) {
		if (trim(staged[sj].getName()) == tname) {
			throw IllegalArgumentException(concatMsg(
				"热插表：表 '", tname, "' 已存在"
				"（结构里既有同名表，或本批次内重复 CREATE）"));
		}
	}
	/* 表名决定 modules/<表名>.lua 的解析路径（createLuaVars 的唯一分派依据），
	 * 而热插语句来自不可信输入（REPL / 模型）——含 '/' 或 ".." 的表名会把
	 * 模块查找指到任意文件。启动期脚本是可信文件，故只在热插这条路上拦。 */
	if (!isSafeIdent(tname)) {
		throw IllegalArgumentException(concatMsg(
			"热插表：表名 '", tname, "' 不是安全标识符"
			"（字母/数字/下划线，且以字母或下划线开头）"));
	}
	if (!isAction) {
		/* 列名进 Daemon 配置串（`列名=值;`）与元数据键：含 ';'/'=' 的列名
		 * 能在配置串里造出额外字段（等价于改写守护的 driver/proto）。
		 * Action 表列名是 <设备>.<参数>，天然含 '.'，不在此列。 */
		for (std::size_t c = 0; c < st.cols(); ++c) {
			if (!isSafeIdent(st(0, c))) {
				throw IllegalArgumentException(concatMsg(
					"热插表：表 '", tname, "' 的列名 '", st(0, c), "' 不是安全标识符"));
			}
		}
	}
	/* 驱动模块存在性：启动期这条缺失要到 build 才以 loadfile 失败暴露，
	 * 热插路径提前折成一句点名表名的人话（判据与 createLuaVars 同一来源）。 */
	if (!isAction && tname != "Alias" && tname != "Vars" && tname != "Daemon") {
		if (!findExistingModule(modulePaths(), tname + ".lua")) {
			throw IllegalArgumentException(concatMsg("热插表：表 '", tname,
				"' 需要驱动模块 modules/", tname, ".lua，模块路径下找不到它"));
		}
	}
}

/* 单条新增数据行的校验：name 列存在/非空、重名（含 doomed 豁免）、Daemon 行的
 * chunk 相对路径存在性。idxName 由调用方按表算好传入。 */
void validateHotNewRow(const HwLookup& registry, const mt::MatrixObject& st,
		const std::string& tname, bool isAction, std::size_t r, std::int64_t idxName,
		const HotSqlPlan::Deletes& delPlan, std::set<std::string>& batchNames) {
	if (!isAction) {
		if (idxName < 0) {
			throw IllegalArgumentException(concatMsg(
				"热插表：表 '", tname, "' 没有 'name' 列，无法为新增行命名硬件变量"));
		}
		const std::string v = trim(st(r, static_cast<std::size_t>(idxName)));
		if (v.empty()) {
			throw IllegalArgumentException(concatMsg(
				"热插表：表 '", tname, "' 第 ", std::to_string(r), " 行的 name 列为空"));
		}
		/* 重名判据的 doomed 豁免（先删后建模式）：UPDATE 同名重建的行
		 * 复用旧名，而旧名此刻仍挂在注册表上（本批次的物理摘除排在
		 * 插入之前执行）——不豁免会把「改写」误判成「重名」。豁免只在
		 * deleteFirst 下给：普通批次（先插入后删除）里「删 A 再插 A」
		 * 仍然拒绝，保持既有行为与报错位置逐字不变。改名（SET name）
		 * 到仍存活的名字不豁免，照常拒绝。 */
		if ((registry.contains(v)
					&& !(delPlan.deleteFirst && delPlan.doomedNames.count(v) != 0))
				|| !batchNames.insert(v).second) {
			throw IllegalArgumentException(concatMsg(
				"热插表：硬件变量名 '", v, "' 重复"
				"（结构里已有同名变量，或本批次内重复）"));
		}
	}
	if (tname == "Daemon") {
		const std::int64_t idxChunk = st.indexOfCol(0, "chunk");
		if (idxChunk < 0) {
			throw IllegalArgumentException("热插表：Daemon 表没有 'chunk' 列");
		}
		const std::string chunk = trim(st(r, static_cast<std::size_t>(idxChunk)));
		/* '-' = 继承上一行的 chunk（来自可信的既有行或本批次已校验的行），跳过。
		 * 真实值必须是模块根下存在的相对路径：resolveDaemonChunk 允许绝对路径
		 * （启动期脚本可信，不拦），而热插的语句不可信——放行即等于让模型
		 * 指定任意 Lua 文件当守护 chunk 加载。 */
		if (chunk != "-") {
			if (checkRelPath(chunk) != RelPathCheck::OK
					|| !findExistingModule(modulePaths(), chunk)) {
				throw IllegalArgumentException(concatMsg("热插表：Daemon 表 '", tname,
					"' 第 ", std::to_string(r), " 行的 chunk '", chunk,
					"' 必须是模块路径下存在的相对路径（热插不允许绝对路径/目录穿越）"));
			}
		}
	}
}

} // namespace

/* ==================== HotSqlPlanner：只读计划层 ==================== */
HotSqlPlan HotSqlPlanner::build(const std::string& sql) const {
	/* ---- 阶段 1：解析到影子容器（活体一字未动）----
	 * 影子必须**逐字复制既有表的全部行**，不能只填列头（2026-09-23 热删除）：
	 * DELETE 要在影子上做行匹配（WHERE 可以引用任何既有列的任何值），只看得到
	 * 列头就一条也匹配不上；INSERT 的「按列名落位 / 漏列报错」也需要同一条
	 * 影子路径（C3 防线）。原实现只填列头是因为当时只有 INSERT——追加行无需
	 * 看到既有行，代价是 DELETE 无法在此路径上表达。
	 * 代价：影子是既有结构的**全量拷贝**（百行级，且只在一次热插批次期间存在）。
	 * 注意：既有表的影子**已经**反映了删除（readSQL 直接在它上面擦行），
	 * 不要在建计划时再擦一遍——那会是第二次应用同一批删除，而行号已经前移过。 */
	std::deque<mt::MatrixObject> staged;
	for (const auto& m : matrices_) { staged.push_back(copyRows(m, 1, m.rows())); }
	const std::size_t liveCount = matrices_.size();

	HotSqlPlan plan;
	auto& muts = plan.mutations;
	{
		MemoryReader reader(sql);
		ScriptLoader::readSQL(reader, staged, /* allowDelete= */ true, &muts);
	}

	plan.deletions = planHotDeletes(muts);
	const auto& delPlan = plan.deletions;
	plan.insertions = planHotInsertions(staged, liveCount, muts, delPlan);
	auto& insPlan = plan.insertions;
	reconcileNewTableDels(staged, delPlan, insPlan);

	/* 空表 DROP（表壳动了、行没动）也算变更：判据必须包含 droppedTables，
	 * 否则「DROP 一张本来就没有数据行的表」会被误判成「本批次什么都没做」。 */
	if (insPlan.appends.empty() && insPlan.newTables.empty() && insPlan.actionMats.empty()
			&& delPlan.dels.empty() && muts.droppedTables.empty()) {
		throw IllegalArgumentException("热插表：本批次没有任何 CREATE/INSERT/DELETE/DROP/UPDATE 变更"
			"（SELECT 是只读查询，请用 query_sql / REPL 的 /sql）");
	}

	/* ---- 阶段 3：合并视图判据（全结构消费判据 + 引用完整性）---- */
	checkMergedView(delPlan, insPlan);
	return plan;
}

/* ---- 阶段 1.5：备删计划（纯只读；原阶段 2.5 前移，2026-09-23 热更新）----
 * 前移的原因都在「先删后建」：
 *  ① doomedNames 要供阶段 2 的新行重名预检做豁免——UPDATE 同名重建时，
 *     旧名此刻仍挂在注册表上（物理摘除发生在后面），不豁免会把「改写」
 *     误判成「重名」而拒绝；
 *  ② hw 指针必须在任何插入之前取好：先建后拆下按名 find 会命中新注册的
 *     同名变量、摘错对象。
 * 批次新建表的删除对账（popRows）依赖 newTables——那是阶段 2 的产物，
 * 只能延后（newTableDels 收集，阶段 2.4 处理）。 */
HotSqlPlan::Deletes HotSqlPlanner::planHotDeletes(const ScriptLoader::Mutations& muts) const {
	HotSqlPlan::Deletes out;
	out.deleteFirst = !muts.updatedRows.empty();
	const std::size_t liveCount = matrices_.size();
	/* 守护名 → 声明序下标：见（hotsql_service.cpp 的）executeHotDeletes 的守护退场屏障。 */
	for (std::size_t k = 0; k < matrices_.size(); ++k) {
		if (trim(matrices_[k].getName()) != "Daemon") { continue; }
		const std::int64_t idxN = matrices_[k].indexOfCol(0, "name");
		if (idxN < 0) { continue; }
		for (std::size_t r = 1; r < matrices_[k].rows(); ++r) {
			const std::string dn = trim(matrices_[k](r, static_cast<std::size_t>(idxN)));
			if (!dn.empty()) { out.daemonNameIndex[dn] = out.daemonNameIndex.size(); }
		}
	}
	for (const auto& [tname, rows] : muts.deletedRows) {
		std::size_t si = liveCount;
		for (std::size_t k = 0; k < liveCount; ++k) {
			if (trim(matrices_[k].getName()) == tname) { si = k; break; }
		}
		if (si == liveCount) {
			/* 表不在活体结构里 ⇒ 它是**本批次 CREATE 出来的**：撤销范围为空且必须
			 * 为空（这些行从未装配、从未注册、从未上电，没有硬件可摘、没有断电
			 * 可做）。但影子上的删除效果必须落到待提交的新表上，否则新表会带着
			 * 「已被删掉的行」一起装配，凭空长出一个器件。
			 *
			 * 这里**不能**按原行号再删一遍：影子（= newTables 里的那张表）已经由
			 * readSQL 擦过行，行号已前移，二次应用会越界或删错行。
			 * 删除只会命中尾部的新增行、新增行只可能追加在尾部，故「影子比
			 * 原始多出的行数」就是必须从尾部丢掉的行数——用 popRows 精确表达，
			 * 不依赖任何行号。newTables 是阶段 2 的产物，对账延后到阶段 2.4。 */
			out.newTableDels.emplace_back(tname, rows);
			continue;
		}
		HotSqlPlan::Deletion p;
		p.matIdx = si;
		p.table = tname;
		p.rows = rows;
		const std::int64_t idxName = matrices_[si].indexOfCol(0, "name");
		if (idxName < 0) {
			throw IllegalArgumentException(concatMsg(
				"热删除：表 '", tname, "' 没有 'name' 列，"
				"无法定位要摘除的硬件变量"));
		}
		for (std::size_t r : rows) {
			if (r >= matrices_[si].rows()) {
				throw IllegalArgumentException(concatMsg(
					"热删除：表 '", tname, "' 的第 ", std::to_string(r), " 行不存在（结构可能已被改动）"));
			}
			const std::string v = trim(matrices_[si](r, static_cast<std::size_t>(idxName)));
			p.names.push_back(v);
			out.doomedNames.insert(v);
			/* 计划期取好对象指针（前移的理由②）：执行期（先删后建模式下已在
			 * 插入之后）按名 find 会命中新注册的同名变量。指针判空的报错口径
			 * 与旧实现逐字一致。 */
			MatrixVars_Hardware* hw = registry_.find(v);
			if (hw == nullptr) {
				/* 表里有行但注册表里没有该变量＝结构与装配脱节（例如启动期装配
				 * 就失败过、或该行从未成功 build）。删不掉不存在的变量，如实报错
				 * 而不是假装删过。 */
				throw IllegalArgumentException(concatMsg("热删除：表 '", tname, "' 的行 '",
					v, "' 在硬件注册表里不存在（结构与该机器人的装配结果已脱节）"));
			}
			p.hw.push_back(hw);
		}
		out.dels.push_back(std::move(p));
	}
	return out;
}

/* ---- 阶段 2：建计划 + 只读全量校验（不触碰活体、不申请任何资源）----
 * 影子下标 [0, liveCount) 与 matrices_ 一一对应（影子就是按它顺序填的）。
 * 表级与逐行校验在 validateNewTableDecl / validateHotNewRow（2026-09-29 A3
 * 拆出），本函数只留区间计算与三路建计划。 */
HotSqlPlan::Insertions HotSqlPlanner::planHotInsertions(
		const std::deque<mt::MatrixObject>& staged, std::size_t liveCount,
		const ScriptLoader::Mutations& muts, const HotSqlPlan::Deletes& delPlan) const {
	HotSqlPlan::Insertions out;
	auto rowOf = [](const mt::MatrixObject& m, std::size_t r) {
		std::vector<std::string> row;
		row.reserve(m.cols());
		for (std::size_t c = 0; c < m.cols(); ++c) { row.push_back(m(r, c)); }
		return row;
	};
	std::set<std::string> batchNames;		/* 批内变量名集合（批内重名早报） */

	for (std::size_t si = 0; si < staged.size(); ++si) {
		const bool isShadow = si < liveCount;
		const mt::MatrixObject& st = staged[si];
		const std::string tname = trim(st.getName());
		const bool isAction = (tname == "Action");

		if (!isShadow) { validateNewTableDecl(staged, si); }

		/* insCount = 本批次插入到这张表的行数（readSQL 回报的权威计数）。 */
		const std::size_t insCount = [&]() {
			auto it = muts.insertedRows.find(tname);
			return it == muts.insertedRows.end() ? std::size_t(0) : it->second;
		}();
		/* 本批次新增行的区间：**插入的行永远在尾部连续一块**（INSERT 只追加、
		 * 删除只前移它前面的行），故这块 = [st.rows() - insCount, st.rows())。
		 * 朴素做法「用解析前行数当起点」在同一批既有 INSERT 又有 DELETE 落在
		 * 这张表上时会错：删除让尾部的插入块整体前移，旧起点就越过了尾端
		 * （表现为新增行被整批漏掉，甚至行号越界）。insCount 是本批次插入行数
		 * 的权威来源，与行号无关，故不受删除影响。
		 * 非影子表（本批次新建）整张都是新增，直接取 [1, rows)。 */
		const std::size_t newFrom = isShadow
			? (st.rows() >= insCount ? st.rows() - insCount : 1) : 1;
		const std::size_t newTo = st.rows();
		/* 既有表且本批次既没插行也没删行 → 无需进入逐行校验与建计划 */
		if (isShadow && muts.deletedRows.count(tname) == 0 && insCount == 0) { continue; }

		const std::int64_t idxName = st.indexOfCol(0, "name");
		for (std::size_t r = newFrom; r < newTo; ++r) {
			validateHotNewRow(registry_, st, tname, isAction, r, idxName, delPlan,
				batchNames);
		}

		if (isAction) {
			/* Action 瞬态：保留「列头 + 本批次新增行」成一张独立矩阵（不入活体）。 */
			if (newTo > newFrom) { out.actionMats.push_back(copyRows(st, newFrom, newTo)); }
		} else if (isShadow) {
			if (newTo > newFrom) {
				std::vector<std::vector<std::string>> rows;
				for (std::size_t r = newFrom; r < newTo; ++r) { rows.push_back(rowOf(st, r)); }
				out.appends.emplace_back(si, std::move(rows));
			}
		} else {
			/* 本批次新建的表：直接取影子即可——影子已经带着本批次的插入与删除
			 * （readSQL 就在这个容器上改），故「先 CREATE 再 INSERT 再 DELETE」
			 * 的新表到这里已经是删干净的样子，不会凭空长出一个已删掉的器件。
			 * 切勿在这里再应用一次删除：行号已随擦除前移，二次应用会越界或删错行。 */
			out.newTables.push_back(st);
		}
	}
	return out;
}

/* ---- 阶段 2.4：批次新建表的删除对账（原阶段 2.5 的 newTable 分支，2026-09-23
 * 热更新随计划前移拆出）----
 * 计划本体（dels / doomedNames / hw 指针 / daemonNameIndex）已前移到阶段 1.5
 * （见其注释）；本段只处理「表不在活体里 ⇒ 本批次 CREATE 出来的」的删除——
 * 撤销范围为空且必须为空（这些行从未装配、从未注册、从未上电，没有硬件可
 * 摘、没有断电可做），但影子上的删除效果必须落到待提交的新表上，否则新表
 * 会带着「已被删掉的行」一起装配，凭空长出一个器件。
 *
 * 这里**不能**按原行号再删一遍：影子（= newTables 里的那张表）已经由
 * readSQL 擦过行，行号已前移，二次应用会越界或删错行。删除只会命中尾部的
 * 新增行、新增行只可能追加在尾部，故「影子比原始多出的行数」就是必须从
 * 尾部丢掉的行数——用 popRows 精确表达，不依赖任何行号。对账要读 newTables
 * （阶段 2 的产物），故只能排在其后。 */
void HotSqlPlanner::reconcileNewTableDels(const std::deque<mt::MatrixObject>& staged,
		const HotSqlPlan::Deletes& delPlan, HotSqlPlan::Insertions& insPlan) {
	for (const auto& [tname, rows] : delPlan.newTableDels) {
		mt::MatrixObject* nt = mt::findByName(insPlan.newTables, tname);
		if (nt == nullptr) { continue; }	/* 该新表随后又被 DROP：影子已整表擦除 */
		for (const auto& st : staged) {
			if (trim(st.getName()) != tname) { continue; }
			const std::size_t appended = st.rows() > 0 ? st.rows() - 1 : 0;
			const std::size_t keep = rows.size() >= appended ? 0 : appended - rows.size();
			if (appended > keep) { nt->popRows(appended - keep); }
			break;
		}
	}
}

/* ---- 阶段 3：全结构判据 + 引用完整性（对「提交之后的视图」，2026-09-23
 *    热更新起两道判据同在合并视图上跑；原阶段 2.6 的引用扫描并入此处）----
 * 消费判据看的是整张结构（新行可能与任意既有行抢同一器件），故必须合并
 * 视图后判定；合并视图只为这两条判据而生，随即丢弃。
 * 热删除/热更新同样要走这条：删掉一个 I2C 总线变量后，某个守护可能仍在用
 * 同一个 path 采样（守护的 path 是**字面路径**，不经 $ 引用，故下面的引用
 * 完整性检查看不见它）——checkSingleConsumer 恰好把两侧都归一成
 * (路径, 地址) 键，对变更后的视图复跑即能拦下这种物理耦合。
 *
 * 引用完整性（物理不可逆的唯一预检防线；destroy() 是物理断电，删了就没有
 * 回滚可言——回滚 ≠ 复活器件）：合并视图里若有任何行引用 doomed 变量，
 * 删除/改写会留下悬垂裸指针。这些引用在框架里是终身缓存——MtVars_Lua::
 * ctrlPtrs_/trigPtrs_（首用缓存）与 MetaRef::target（seed 期锁定），且都
 * 注释写着「指针终身有效」正是因为 pool_ 只增不减。热删除第一次打破那条
 * 不变式，故必须在这里把「不留悬垂」重新建立为构造保证。
 *   判据分三类，覆盖结构脚本里**全部**能指向另一个变量的写法：
 *     a) 流列 controller/trigger 及其编号列 —— 走 isFlowColumn 单点，
 *        故 controller2/trigger10 也算，漏了就是悬垂指针；
 *     b) 元数据列的字面 $name 引用 —— seed 期锁定 MetaRef::target 的
 *        那一类（跨表，如 Monitor 的 src='$sim0'）；
 *     c) 元数据列的 $(...) 表达式 —— 标识符经注册表按名求值，
 *        目标消失即运行期报错（不是悬垂，但同样是结构已坏）。
 * 扫描面 = 合并视图（= 提交之后的结构）：dying 行已擦除——引用方自己也被
 * 删掉时，引用随行一起消失，不构成悬垂；本批次新增/改写行**在列**（2026-09-23
 * 热更新扩面）：流引用是首用缓存的懒解析，不在装配期爆出来，INSERT/UPDATE
 * 的新行引用同批被删变量若不在预检里拦下，就是一颗运行期才炸（或更糟：
 * 静默指向错对象）的雷——对先删后建的 UPDATE 批次，那还会落在「旧件已摘、
 * 新件装配失败」的不可复原窗口里。 */
void HotSqlPlanner::checkMergedView(const HotSqlPlan::Deletes& delPlan,
		const HotSqlPlan::Insertions& insPlan) const {
	std::deque<mt::MatrixObject> merged = matrices_;
	/* 先落实删除（擦行），再追加新行——顺序与提交阶段保持一致，
	 * 否则「批内先 INSERT 到既有表、再 DELETE 掉它」的净效果会被算错。 */
	for (const HotSqlPlan::Deletion& p : delPlan.dels) { merged[p.matIdx].removeRows(p.rows); }
	for (const auto& [idx, rows] : insPlan.appends) {
		for (const auto& row : rows) { merged[idx].appendRow(row, 0); }
	}
	for (const auto& t : insPlan.newTables) { merged.push_back(t); }

	if (!delPlan.dels.empty()) {
		std::vector<std::string> refErrors;
		for (const mt::MatrixObject& m : merged) {
			if (m.rows() == 0) { continue; }
			const std::string tname = trim(m.getName());
			for (std::size_t r = 1; r < m.rows(); ++r) {
				for (std::size_t c = 0; c < m.cols(); ++c) {
					const std::string& colName = m(0, c);
					const std::string val = m.inherited(r, c);
					if (val.empty() || val == "-") { continue; }
					const std::string where = concatMsg("表 '", tname, "' 第 ",
						std::to_string(r), " 行的列 '", colName, "'");
					bool isFlow = isFlowColumn(colName);
					if (isFlow && delPlan.doomedNames.count(val) != 0) {
						refErrors.push_back(concatMsg(where, " 把 '", val,
							"' 引用为 controller/trigger"));
						continue;
					}
					if (!isFlow && val[0] == '$') {
						if (auto body = exprBody(val)) {
							std::set<std::string> vars;
							try {
								Expression::parse(*body).collectVars(vars);
							} catch (const std::exception&) {
								continue;	/* 语法坏掉的表达式由装配期既有判据报错 */
							}
							for (const std::string& nm : vars) {
								if (delPlan.doomedNames.count(nm) != 0) {
									refErrors.push_back(concatMsg(where, " 的表达式 '", val,
										"' 引用了 '", nm, "'"));
								}
							}
						} else if (delPlan.doomedNames.count(val.substr(1)) != 0) {
							refErrors.push_back(concatMsg(where, " 以 '", val, "' 引用了 '",
								val.substr(1), "'"));
						}
					}
				}
			}
		}
		if (!refErrors.empty()) {
			std::string msg = "热删除被拒绝：以下存活结构仍引用待删变量，删除会留下指向"
				"已释放器件的引用（先删引用方，或把这些行一起删）：";
			for (const std::string& e : refErrors) { msg += "\n  - " + e; }
			throw IllegalArgumentException(msg);
		}
	}

	HwFactory::precheckStructure(merged);
}

} // namespace bot

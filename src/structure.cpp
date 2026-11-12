/* structure.cpp —— 结构脚本的 SQL 事件语义（拆自 hw_factory.cpp，2026-09-25 B2）
 * ScriptLoader::readSQL 是**结构层**的 SQL4cj 事件 → MatrixObject 装配语义
 * （INSERT 按列名落位、DELETE/DROP/UPDATE 的批次互斥规则、热删除的坐标还原、
 * createdHere/touchedHere/updatedHere/droppedHere 四个批次集合的交互判据），
 * 与硬件装配（HwFactory：矩阵表 → 硬件变量）无关——原先同住 hw_factory.cpp
 * 只是拆分历史（R-1 从 robot.cpp 按类邻近归置）的惯性，独立成文件后两边各有
 * 聚焦的注释面。声明在 script_loader.hpp（2026-09-29 A2 起从 robot.hpp 拆出）；
 * 硬件装配在 hw_factory.cpp。
 *
 * 25.5 评估后**判不改文件名**（本文件只实现 ScriptLoader 一个类，名字却不叫
 * script_loader.cpp）：寄居理由三处已互相指认（本头注、script_loader.hpp 的
 * 「实现在 structure.cpp」、CMakeLists.txt 里 MYBOT_CORE_SOURCES 那条行尾注），
 * 改名买到的是「文件名 == 类名」这一点整齐，代价是全仓 6 处引用散在 6 个受版控
 * 的文件里跟着改（CMakeLists.txt:99、hw_factory.cpp:2、robot.hpp:10、
 * script_loader.hpp:3、agentview.cpp:270 各一处，加上本文件头注），并且要给
 * scripts/check_doc_paths.py 的 DELETED_FILES 加一条旧名豁免——那张名单还带反向
 * 核对（旧名一旦又存在就判名单过期），等于为一次纯改名长期背一条豁免。
 * 「头名 == 实现文件名」在本仓本就不是惯例：robot.hpp 声明的 RobotStruct 没有
 * robot.cpp，实现散在 robot_actions / robot_application / robot_driver /
 * robot_hotsql / robot_lifecycle 五个 .cpp 里；luaend.hpp 的声明实现在
 * luasandbox.cpp 与 luabridge.cpp；structure_store.hpp 也无同名 .cpp。故名字与
 * 类名不同构不构成结构残留。
 *
 * 2026-09-26 批次 5：readSQL 原为 429 行单函数（5 个 SQL 事件分支 + 三个捕获大量
 * 局部量的 lambda 同住一处）。把「跨事件共享的容器/批次集合/行号映射」与三个 helper
 * 收进 ReadSqlState，5 个事件各成其具名成员方法，readSQL 只留「建状态 → 取事件 →
 * 分派」的编排。事件体逐字照搬（原 lambda 捕获名全部变成同名成员），行为不变——
 * 由 test_robot 的 readSQL 与热 SQL 用例群钉住。 */

#include "script_loader.hpp"
#include "sqlparse.hpp"

#include <cstddef>
#include <deque>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace bot {

namespace {

/* readSQL 的跨事件共享状态 + 行号追踪 helper + 5 个 SQL 事件处理。
 * 成员名与原 readSQL 的局部量/lambda 逐字相同，故事件体可原样搬入。 */
struct ReadSqlState {
	std::deque<mt::MatrixObject>& out;
	bool allowDelete;
	ScriptLoader::Mutations* mutations;

	/* 热删除的坐标还原（见 Mutations 注释）：每表的「当前行号 → 原始行号」映射，
	 * 按容器下标对齐存放。一条 DELETE 命中后即更新本表映射，故同一表的**后续**
	 * DELETE 仍以原始坐标记录（而 matchAll 用当前坐标匹配）。初值 = 恒等映射
	 * （此刻每个当前行号都还是它自己的原始行号）。 */
	std::vector<std::vector<std::size_t>> rowOrigin;
	/* 本批次（一次 readSQL 调用）内 CREATE 出来 / DROP 掉的表名，用于整表撤下的
	 * 交互判据：DROP 本批次新建的表 = 从影子容器整表擦除（从未装配）；DROP 后
	 * 再 INSERT/DELETE/CREATE 同名表一律拒绝（避免「表壳已被撤下却又被写回」）。 */
	std::set<std::string> createdHere;
	std::set<std::string> droppedHere;
	/* 本批次被 INSERT/DELETE/UPDATE（改**行**）触碰过的表名。DROP（撤**表**）与
	 * UPDATE（改写行 = 擦原行 + 尾部追加改后行）都要求自己是本批次针对该表的
	 * **唯一**行级语句：与其它行级语句同批会打乱 applySql 靠 insertedRows 划
	 * 「新增行区间（尾部连续块）」的算法（被删掉的新增行不在尾部连续块里），且
	 * 「加了又整表撤下」本就无意义——拆成两批即可。CREATE 不算触碰：本批次新建后
	 * 又被 DROP 有专门路径（新建后被 UPDATE 则直接拒绝，见 UPDATE 分支）。 */
	std::set<std::string> touchedHere;
	/* 本批次被 UPDATE 改写过的表名（双向独占的另一半）：touchedHere 管「UPDATE
	 * 之前有没有别的行级语句」，本集合管「UPDATE 之后不再有」——改后行追加在尾部、
	 * 原始行从中间消失，之后再对同表 INSERT/DELETE 都会让坐标与区间算式失真。
	 * 拆成两批即可，守门消息都带这句指路。 */
	std::set<std::string> updatedHere;

	ReadSqlState(std::deque<mt::MatrixObject>& o, bool ad, ScriptLoader::Mutations* m)
		: out(o), allowDelete(ad), mutations(m) {}

	/* 表在容器中的下标（P0 修复，2026-09-23 审计）：out 是 std::deque，元素
	 * **不保证连续**——`root - &out[0]` 只在两者同处一个分配块时才有定义
	 * （libstdc++ 每块 512/sizeof(MatrixObject) 个元素，当前 88 字节 → 5 个），
	 * 跨块指针差是 UB：第 6 张表起产出垃圾下标，rowOrigin[垃圾下标] 即越界
	 * 读写。实测 spider1.sql（6 张表，Servo 在下标 5 吃 14 条 INSERT）启动解析
	 * 100% 段错误；热插批次让影子容器越过 5 张表同样崩。侥幸不崩时垃圾下标还
	 * 会静默污染「当前行号 → 原始行号」映射，热 DELETE 可能摘错行（不可逆）。
	 * 改按地址逐元素定位：表数是十量级，O(n) 无感知。返回 size() = 未找到
	 * （root 必来自 findByName(out,...)，理论不可达，仅供防御）。 */
	std::size_t tableIndex(const mt::MatrixObject* p) const {
		for (std::size_t i = 0; i < out.size(); ++i) {
			if (&out[i] == p) { return i; }
		}
		return out.size();
	}

	/* 把「这些数据行」从表上擦除，并维护「当前行号 → 原始行号」映射与 Mutations
	 * 记录。DELETE 与 DROP 共用这一段——DROP 就是「对全表数据行跑同一套擦除，
	 * 再额外把空表壳交给调用方摘除」（表壳摘除在 applySql，readSQL 只管数据行）。 */
	void removeRowsOf(mt::MatrixObject* root, const std::string& target,
			const std::vector<std::size_t>& hits) {
		if (hits.empty()) { return; }
		const std::size_t ti = tableIndex(root);
		/* 恒等映射的惰性初始化：只在**本容器首次改这张表**时铺一次。
		 * 注意不能假定「INSERT 路径已经铺过」——mutations 为空时 INSERT 的
		 * 追踪整段被跳过（启动期不需要），此处必须自给自足。 */
		if (rowOrigin.size() < out.size()) { rowOrigin.resize(out.size()); }
		if (rowOrigin[ti].empty()) {
			rowOrigin[ti].reserve(root->rows());
			for (std::size_t r = 0; r < root->rows(); ++r) { rowOrigin[ti].push_back(r); }
		}
		/* 先取走原始行号与变量名（都要在擦行之前读），再擦行。
		 * name 列缺失时不猜变量名——变量名的权威来源是装配期的 name 列，
		 * 缺失就是结构本身不合法，留给 hot-SQL 路径的既有判据报错。 */
		const std::int64_t idxName = root->indexOfCol(0, "name");
		std::vector<std::size_t> origins;
		origins.reserve(hits.size());
		for (std::size_t r : hits) {
			origins.push_back(rowOrigin[ti][r]);
			if (mutations != nullptr && idxName >= 0) {
				mutations->deletedNames.push_back((*root)(r, static_cast<std::size_t>(idxName)));
			}
		}
		root->removeRows(hits);
		/* 本表映射：被删的当前行号剔除（存活行号随之前移，索引自然对上） */
		std::vector<std::size_t> keptOrigins;
		keptOrigins.reserve(rowOrigin[ti].size() - hits.size());
		std::size_t hi = 0;
		for (std::size_t r = 0; r < rowOrigin[ti].size(); ++r) {
			if (hi < hits.size() && hits[hi] == r) { ++hi; continue; }
			keptOrigins.push_back(rowOrigin[ti][r]);
		}
		rowOrigin[ti] = std::move(keptOrigins);
		if (mutations != nullptr) {
			std::vector<std::size_t>& dst = mutations->deletedRows[target];
			for (std::size_t o : origins) { dst.push_back(o); }
		}
	}

	/* 带记账的尾部追加（INSERT 的 VALUES 与 UPDATE 的改后行共用，单点）：追加数据行、
	 * 维护「当前行号 → 原始行号」映射（新增行在原始坐标里也是新的一行：用当前行数
	 * 当它的原始行号——此刻它还没被任何删除前移过；删掉它时这条映射会被剔除，而
	 * 调用方拿到该原始行号后只在「本批次新增区间」里找它），并把本批次插入行数
	 * 计入 Mutations.insertedRows（UPDATE 的改后行同样计数：它就是「本批次新增行」）。 */
	void appendRowTracked(mt::MatrixObject* root, const std::string& target,
			std::vector<std::string> values) {
		root->appendRow(std::move(values), 0);
		const std::size_t oi = tableIndex(root);
		if (rowOrigin.size() < out.size()) { rowOrigin.resize(out.size()); }
		/* 惰性恒等初始化：本容器首次改动这张表时，先把**既有**行号按恒等铺一遍，
		 * 再追加新增行。不能只 push 新增行——映射会与行号脱节（既有行没有条目），
		 * 后续 DELETE 按当前行号取原始行号即越界。启动期（mutations == nullptr）
		 * 不需要映射内容，但同样必须铺：热插路径会复用同一个容器继续改。 */
		if (rowOrigin[oi].empty()) {
			rowOrigin[oi].reserve(root->rows());
			for (std::size_t r = 0; r + 1 < root->rows(); ++r) {
				rowOrigin[oi].push_back(r);	/* 既有行，不含刚追加的这行 */
			}
		}
		rowOrigin[oi].push_back(root->rows() - 1);
		if (mutations != nullptr) { ++mutations->insertedRows[target]; }
	}

	/* WHERE → 等值条件列表（DELETE 与 UPDATE 共用的同一段转化，单点）：交给
	 * mt::matchAll 做当前坐标匹配；列不存在/漏写的报错在 matchAll。 */
	static std::vector<std::pair<std::string, std::string>> condsOf(
			const sql4cj::WhereClause& where) {
		std::vector<std::pair<std::string, std::string>> conds;
		conds.reserve(where.conds.size());
		for (const auto& c : where.conds) { conds.emplace_back(c.column, c.value); }
		return conds;
	}

	/* ---- 批次守门文案单点（三族，2026-10-10 收敛）----
	 * 「表已被 DROP / 被 UPDATE 改写 / 被行级触碰」的拒绝文案各自在 2-3 个
	 * 事件里逐字同构，此前各写一份、只在语句名前缀与指路动词上不同——漂移
	 * 一处即三种语句报错不一致。stmt = 语句名前缀（"INSERT INTO" /
	 * "DELETE FROM" / "UPDATE" / "DROP TABLE"），verb = 指路动词（"INSERT" /
	 * "DELETE" / "UPDATE" / "DROP"）。onCreate 的 DROP 文案（带 recreate
	 * 指路）与 onDrop 的「dropped more than once」语义不同，留在原处。 */
	[[noreturn]] void rejectDroppedHere(const std::string& stmt, const std::string& target) {
		throw IllegalArgumentException(concatMsg(
			stmt, " '", target, "': the table was dropped earlier in this batch"));
	}
	[[noreturn]] void rejectUpdatedHere(const std::string& stmt, const std::string& verb,
			const std::string& target) {
		throw IllegalArgumentException(concatMsg(
			stmt, " '", target, "': the table was rewritten by UPDATE earlier in this batch;"
			" run ", verb,
			" in a separate statement batch"));
	}
	[[noreturn]] void rejectTouchedHere(const std::string& stmt, const std::string& verb,
			const std::string& target) {
		throw IllegalArgumentException(concatMsg(
			stmt, " '", target, "': the table was already modified by INSERT/DELETE/UPDATE in this"
			" batch; run ",
			verb, " in a separate statement batch"));
	}

	/* ---- CREATE TABLE ---- */
	void onCreate(const sql4cj::Event& eve) {
		/* R-4：SQL 事件里的 token 本就完整，直接灌入构建器，
		 * 不再逐字符 addRune 重放（仓颉流 API 的残留）。 */
		if (droppedHere.count(eve.create.tableName)) {
			throw IllegalArgumentException(concatMsg(
				"CREATE TABLE '", eve.create.tableName,
				"': the table was dropped earlier in this batch; recreate it in a"
				" separate statement batch (DROP is physically irreversible)"));
		}
		mt::MatrixBuilder b;
		b.name(eve.create.tableName);
		for (const auto& col : eve.create.tableColumns) { b.item(col.name); }
		b.line(0);
		out.push_back(b.take());
		createdHere.insert(eve.create.tableName);
	}

	/* ---- INSERT INTO ---- */
	void onInsert(const sql4cj::Event& eve) {
		if (out.empty()) { throw IllegalArgumentException("No table created yet."); }
		if (droppedHere.count(eve.insert.targetTabName)) {
			rejectDroppedHere("INSERT INTO", eve.insert.targetTabName);
		}
		/* 双向独占（updatedHere 注释）：改后行追加在尾部、被改写的原始行已从
		 * 中间消失，之后再 INSERT 同表会让 applySql 的「新增行 = 尾部连续块」
		 * 区间算式失真。拆成两批即可。 */
		if (updatedHere.count(eve.insert.targetTabName)) {
			rejectUpdatedHere("INSERT INTO", "INSERT", eve.insert.targetTabName);
		}
		/* INSERT 目标表必须已创建：按名定位，拼错/未定义即解析期报错
		 * （对照 robots/test/insert_typo.sql 的负值契约；N-10：查找
		 * 收敛到 mt::findByName 单点） */
		mt::MatrixObject* root = mt::findByName(out, eve.insert.targetTabName);
		if (root == nullptr) {
			throw IllegalArgumentException(concatMsg(
				"INSERT INTO '", eve.insert.targetTabName, "': table is not defined"));
		}
		/* C3 防线（2026-09-20 审计）：INSERT 的值必须按**列名**落位到建表
		 * 声明序，不能按 INSERT 自带的列序顺序 append。
		 * 旧实现只取 p.value 逐位 appendRow，columnName 仅参与 Number 列的
		 * 解析期校验——于是
		 *     CREATE TABLE Timer (name String, delay Number);
		 *     INSERT INTO Timer (delay, name) VALUES (50, 'timer-0');
		 * 校验看到的是「delay←50 ✓、name←'timer-0' ✓」（按 INSERT 列名配对），
		 * 存储却把 50 写进 name、'timer-0' 写进 delay：声明为 Number 的列拿到
		 * 字符串，而 number_bad.sql 那条守门承诺的「Number 列非数值必报错」
		 * 被整条绕过，失败形态是「跑得通但值不对」。
		 * 列名未知/重复/漏列一律显式报错——仓库内 138 个 .sql 的 INSERT 列序
		 * 与建表声明序逐一相同（脚本核查），故对既有脚本零行为变化。 */
		const std::int64_t ncols = static_cast<std::int64_t>(root->cols());
		for (const auto& row : eve.insert.tableRows) {
			std::vector<std::string> values(static_cast<std::size_t>(ncols));
			std::vector<char> filled(static_cast<std::size_t>(ncols), 0);
			for (const auto& p : row) {
				const std::int64_t idx = root->indexOfCol(0, p.columnName);
				if (idx < 0) {
					throw IllegalArgumentException(concatMsg(
						"INSERT INTO '", eve.insert.targetTabName, "': no such column '", p.columnName, "'"));
				}
				if (filled[static_cast<std::size_t>(idx)] != 0) {
					throw IllegalArgumentException(concatMsg(
						"INSERT INTO '", eve.insert.targetTabName, "': column '", p.columnName, "' listed twice"));
				}
				values[static_cast<std::size_t>(idx)] = p.value;
				filled[static_cast<std::size_t>(idx)] = 1;
			}
			for (std::int64_t j = 0; j < ncols; ++j) {
				if (filled[static_cast<std::size_t>(j)] == 0) {
					throw IllegalArgumentException(concatMsg(
						"INSERT INTO '", eve.insert.targetTabName, "': missing value for column '", (*root)(0, j),
						"' (every column must be given a value; use '-' to inherit)"));
				}
			}
			appendRowTracked(root, eve.insert.targetTabName, std::move(values));
		}
		/* 既存表被 INSERT 碰过 → 本批次不得再对它 DROP（见 touchedHere 注释）。
		 * 本批次新建的表不算——它整表撤下走 createdHere 路径，与行计数无关。 */
		if (!createdHere.count(eve.insert.targetTabName)) {
			touchedHere.insert(eve.insert.targetTabName);
		}
	}

	/* ---- DELETE FROM ---- */
	void onDelete(const sql4cj::Event& eve) {
		/* 启动期（结构脚本）一律关闭：机器人尚未上电，没有可变的结构。 */
		if (!allowDelete) {
			throw IllegalArgumentException(concatMsg(
				"DELETE FROM '", eve.del.targetTabName,
				"': DELETE is a live-structure statement and cannot appear in a"
				" structure script (the robot is not powered on yet). Edit the"
				" script, or run DELETE on a live robot via /sql or apply_sql."));
		}
		if (out.empty()) { throw IllegalArgumentException("No table created yet."); }
		const std::string& target = eve.del.targetTabName;
		if (droppedHere.count(target)) {
			rejectDroppedHere("DELETE FROM", target);
		}
		/* 双向独占（同 INSERT 分支的 updatedHere 守门，理由见其注释） */
		if (updatedHere.count(target)) {
			rejectUpdatedHere("DELETE FROM", "DELETE", target);
		}
		mt::MatrixObject* root = mt::findByName(out, target);
		if (root == nullptr) {
			throw IllegalArgumentException(concatMsg(
				"DELETE FROM '", target, "': table is not defined"));
		}
		/* 无条件 = 全部数据行（与 SQL 语义一致：DELETE FROM t 删空该表） */
		std::vector<std::size_t> hits;
		if (eve.del.where) {
			/* 列不存在/漏写的报错沿用 requireCol 与谓词解析的既有文案 */
			hits = mt::matchAll(*root, condsOf(*eve.del.where));
		} else {
			for (std::size_t r = 1; r < root->rows(); ++r) { hits.push_back(r); }
		}
		/* 「一条都没删到」按错误处理，而不是成功返回一句「删除 0 行」：
		 * 本路径上的 DELETE 是不可逆的物理断电操作，调用方（人/模型）拿到
		 * 「已生效」却什么都没发生时，无从判断是条件写错了还是器件本就不在
		 * ——拼错 name 的 DELETE 若静默成功，操作者会以为器件已摘除。
		 * 附带好处：本批次里只有「没删到」的 DELETE 时，不会被下游那条
		 * 「本批次没有任何变更」判据混淆成因（但即便如此，下面的变更计数
		 * 仍以防万一保留）。 */
		if (hits.empty()) {
			throw IllegalArgumentException(concatMsg(
				"DELETE FROM '", target, "': no row matches, nothing was deleted",
				(eve.del.where ? " (check the WHERE values)" : " (the table has no data row)")));
		}
		removeRowsOf(root, target, hits);
		if (!createdHere.count(target)) { touchedHere.insert(target); }
	}

	/* ---- DROP TABLE ---- */
	void onDrop(const sql4cj::Event& eve) {
		/* 与 DELETE 同为带电变更：结构脚本里出现同样拒绝（机器人尚未上电）。 */
		if (!allowDelete) {
			throw IllegalArgumentException(concatMsg(
				"DROP TABLE '", eve.drop.targetTabName,
				"': DROP is a live-structure statement and cannot appear in a"
				" structure script (the robot is not powered on yet). Edit the"
				" script, or run DROP on a live robot via /sql or apply_sql."));
		}
		const std::string& target = eve.drop.targetTabName;
		if (droppedHere.count(target)) {
			throw IllegalArgumentException(concatMsg(
				"DROP TABLE '", target, "': the table is dropped more than once in this batch"));
		}
		/* 本批次已对这张**既存**表做过 INSERT/DELETE/UPDATE → 拒绝 DROP：
		 * applySql 靠 insertedRows 划「新增行区间（尾部连续块）」，而行级改动
		 * 之后该区间算法不再成立（被删掉的新增行不在尾部连续块里）；且「先加行
		 * 再整表撤下」本就没有意义。拆成两批（先改行、再 DROP）即可。 */
		if (touchedHere.count(target)) {
			rejectTouchedHere("DROP TABLE", "DROP", target);
		}
		if (out.empty()) { throw IllegalArgumentException("No table created yet."); }

		/* Action 表是**瞬态**的（结构期由 MR 动作脚本提供、热插期执行完即丢），
		 * 其行从不装配成常驻硬件变量，故「整表撤下」在它身上没有意义
		 * （行→变量 的模型不成立）。给一句人话而不是让它落到下游的
		 * 「没有 name 列」/「注册表里不存在」这类错位报错。 */
		if (trim(target) == "Action") {
			throw IllegalArgumentException("DROP TABLE Action: the Action table is"
				" transient (its rows are replayed, never registered as hardware"
				" variables) and cannot be dropped");
		}

		/* 无条件整表撤下（无 WHERE，见 DropTableEvent 注释）。 */
		mt::MatrixObject* root = mt::findByName(out, target);
		if (root == nullptr) {
			throw IllegalArgumentException(concatMsg(
				"DROP TABLE '", target, "': table is not defined"));
		}

		if (createdHere.count(target)) {
			/* 本批次 CREATE 出来的表：从未装配、从未上电，撤销范围为空。
			 * **整表擦除**影子容器里的它（连带本批次插入的行一起消失），并把表名
			 * 传给调用方记账。表壳不复存在，故无需（也不该）走 applySql 的表壳
			 * 摘除步骤。 */
			const std::size_t k = tableIndex(root);
			out.erase(out.begin() + static_cast<std::ptrdiff_t>(k));
			if (k < rowOrigin.size()) {
				rowOrigin.erase(rowOrigin.begin() + static_cast<std::ptrdiff_t>(k));
			}
			createdHere.erase(target);
			droppedHere.insert(target);
			if (mutations != nullptr) { mutations->droppedTables.insert(target); }
			return;
		}

		/* 既存表：清空全部数据行（与 DELETE 同一条擦除机器，断电/撤注册据此
		 * 走 DelPlan），表壳保留到 applySql 的表级摘除步骤——这样影子容器与
		 * 活体矩阵**逐位对齐**，applySql 的下标不变式不被破坏。
		 * 空表（只有列头）也无条件撤下：撤一张本来就没有数据行的表是合法操作。 */
		std::vector<std::size_t> all;
		all.reserve(root->rows() > 1 ? root->rows() - 1 : 0);
		for (std::size_t r = 1; r < root->rows(); ++r) { all.push_back(r); }
		removeRowsOf(root, target, all);
		droppedHere.insert(target);
		if (mutations != nullptr) { mutations->droppedTables.insert(target); }
	}

	/* ---- UPDATE … SET … [WHERE …] ---- */
	/* 25.4 评估后判不改（106 行）：六段直线流水，有复用语义的部分**已经**各自
	 * 委托给具名单点（mt::findByName / mt::matchAll / removeRowsOf /
	 * appendRowTracked），剩下的长度是六条互不相同的用户可见报错加其决策注释。
	 * 唯二能抽的接缝是「赋值列解析→setIdx」与「物化改后行→modified」，各约 18 行，
	 * 抽出去要连注释一起搬、回来是各约 20 行的私有 helper，净 LOC ≈ 0；而末尾
	 * touchedHere/updatedHere 的**双向独占**不变量会被拆到两个函数里，读的人得
	 * 跨函数拼。要动先给这两段各留钉子用例。 */
	void onUpdate(const sql4cj::Event& eve) {
		/* 热更新（2026-09-23）：UPDATE 在影子上分解为「DELETE 命中行 +
		 * INSERT 改后行」两条既有路径——语义是**断电重建**，不是原地改值。
		 * 调用方（applySql）据 Mutations.updatedRows 切换先删后建执行序。 */
		/* 启动期（结构脚本）一律关闭：与 DELETE/DROP 同判据（机器人尚未上电） */
		if (!allowDelete) {
			throw IllegalArgumentException(concatMsg(
				"UPDATE '", eve.update.targetTabName,
				"': UPDATE is a live-structure statement and cannot appear in a"
				" structure script (the robot is not powered on yet). Edit the"
				" script, or run UPDATE on a live robot via /sql or apply_sql."));
		}
		if (out.empty()) { throw IllegalArgumentException("No table created yet."); }
		const std::string& target = eve.update.targetTabName;
		if (droppedHere.count(target)) {
			rejectDroppedHere("UPDATE", target);
		}
		/* 本批次新建的表：直接拒——它的行从未装配、从未上电，「改写」无从谈起，
		 * 且分解出的「擦原行 + 尾部追加」会打乱 applySql 对新表影子的
		 * popRows 对账（那条路径假设删除只落在尾部追加块上）。想要什么
		 * 行，直接把 INSERT 写成想要的样子即可。 */
		if (createdHere.count(target)) {
			throw IllegalArgumentException(concatMsg(
				"UPDATE '", target,
				"': the table was created earlier in this batch; write the"
				" INSERT you actually want, or run UPDATE in the next batch"));
		}
		/* 批内独占（前置半边，见 touchedHere 注释）：本批次已对该表做过任何
		 * 行级改动 → 拒绝。拆成两批即可。 */
		if (touchedHere.count(target)) {
			rejectTouchedHere("UPDATE", "UPDATE", target);
		}
		mt::MatrixObject* root = mt::findByName(out, target);
		if (root == nullptr) {
			throw IllegalArgumentException(concatMsg(
				"UPDATE '", target, "': table is not defined"));
		}
		/* 赋值列解析到列下标（对照表结构）：未知列/重复列报错——判据与文案
		 * 镜像 INSERT 的 C3 防线（列是结构事实，读的人要能一眼定位）。 */
		std::vector<std::size_t> setIdx;
		setIdx.reserve(eve.update.assignments.size());
		for (const auto& a : eve.update.assignments) {
			const std::int64_t idx = root->indexOfCol(0, a.columnName);
			if (idx < 0) {
				throw IllegalArgumentException(concatMsg(
					"UPDATE '", target, "': no such column '", a.columnName, "'"));
			}
			for (std::size_t k : setIdx) {
				if (k == static_cast<std::size_t>(idx)) {
					throw IllegalArgumentException(concatMsg(
						"UPDATE '", target, "': column '", a.columnName, "' listed twice"));
				}
			}
			setIdx.push_back(static_cast<std::size_t>(idx));
		}
		/* 命中行（WHERE 等值 AND 过滤；无条件 = 全部数据行，与 DELETE 同口径） */
		std::vector<std::size_t> hits;
		if (eve.update.where) {
			hits = mt::matchAll(*root, condsOf(*eve.update.where));
		} else {
			hits.reserve(root->rows() > 1 ? root->rows() - 1 : 0);
			for (std::size_t r = 1; r < root->rows(); ++r) { hits.push_back(r); }
		}
		/* 「一条都没命中」按错误处理（口径同 DELETE）：本路径上的 UPDATE 会
		 * 断电重建命中行，拿到「已生效」却什么都没发生时，操作者无从判断是
		 * 条件写错了还是器件本就不在。 */
		if (hits.empty()) {
			throw IllegalArgumentException(concatMsg(
				"UPDATE '", target, "': no row matches, nothing was updated",
				(eve.update.where ? " (check the WHERE values)"
						   : " (the table has no data row)")));
		}
		/* 先物化改后行，再擦原行（顺序是死的：擦行会让后续行号前移）。
		 * 取值用 inherited()（'-' 继承解析后的显示值）而不是原格子——改后行
		 * 追加在**尾部**，原样保留 '-' 会对着不同的前一行重新继承、静默变义。
		 * SET 自己写 '-' 例外：那是显式的「继承」意图，按原样保留。 */
		std::vector<std::vector<std::string>> modified;
		modified.reserve(hits.size());
		for (std::size_t r : hits) {
			std::vector<std::string> row;
			row.reserve(root->cols());
			for (std::size_t c = 0; c < root->cols(); ++c) {
				row.push_back(root->inherited(r, c));
			}
			for (std::size_t k = 0; k < setIdx.size(); ++k) {
				row[setIdx[k]] = eve.update.assignments[k].value;
			}
			modified.push_back(std::move(row));
		}
		/* 分解执行：擦命中行（原始坐标进 Mutations.deletedRows，供 DelPlan 在
		 * 活体上精确摘除）→ 改后行经 appendRowTracked 尾部追加（计入
		 * insertedRows：它就是「本批次新增行」，进 applySql 的新增区间）。 */
		removeRowsOf(root, target, hits);
		for (auto& row : modified) { appendRowTracked(root, target, std::move(row)); }
		/* touchedHere 挡住后续 INSERT/DELETE/DROP；updatedHere 挡住后续一切
		 * 行级语句（双向独占，见其注释）。 */
		touchedHere.insert(target);
		updatedHere.insert(target);
		if (mutations != nullptr) { mutations->updatedRows[target] += hits.size(); }
	}
};

} // namespace

void ScriptLoader::readSQL(bot::Reader& input, std::deque<mt::MatrixObject>& out,
		bool allowDelete, Mutations* mutations) {
	std::vector<sql4cj::Token> tokens = sql4cj::Lexer::parseAll(input);
	sql4cj::Parser parser(tokens);
	/* 跨事件共享状态与 5 个事件处理都在 ReadSqlState（见其注释）；本函数只负责
	 * 取事件并按类型分派。allowDelete 缺省 false：结构脚本装配期机器人尚未上电，
	 * DELETE/DROP/UPDATE 一律拒绝；热插路径（applySql）显式传 true。 */
	ReadSqlState st{out, allowDelete, mutations};
	for (;;) {
		sql4cj::Event eve = parser.next();
		if (eve.type == sql4cj::EventType::END) { break; }
		switch (eve.type) {
		case sql4cj::EventType::CREATE_TABLE: st.onCreate(eve); break;
		case sql4cj::EventType::INSERT_TABLE: st.onInsert(eve); break;
		case sql4cj::EventType::DELETE_TABLE: st.onDelete(eve); break;
		case sql4cj::EventType::DROP_TABLE:   st.onDrop(eve);   break;
		case sql4cj::EventType::UPDATE_TABLE: st.onUpdate(eve); break;
		default: break;
		}
	}
}

} // namespace bot

#pragma once
/* script_loader.hpp —— 结构脚本装载（拆自 robot.hpp，2026-09-29 A2；
 * 实现在 structure.cpp）。 */

#include <cstddef>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "matrix.hpp"
#include "util_except.hpp"

namespace bot {

/* ---- 脚本装载：SQL/矩阵 文本 → MatrixObject（R-1 拆自 RobotStruct）----
 * N-11：矩阵文本解析（readMatrix）已下沉 mt 层，本类只剩 SQL 事件装配。 */
class ScriptLoader {
public:
	/* 热删除改动记录（2026-09-23）：readSQL 执行 DELETE 时把「删了哪些原始行、
	 * 哪些硬件变量名」如实回报给调用方（RobotStruct::applySql）。
	 *
	 * 为什么必须回报而不是让调用方自查：DELETE 会**改变容器内行号**，而调用方
	 * 需要的是**原始坐标**下的行号——它要拿这些行号回活体矩阵 `matrices_` 上
	 * 精确摘行。readSQL 内部逐条维护「当前行号 → 原始行号」映射，是全链路里
	 * 唯一知道这个映射的地方；让 applySql 事后靠「比较行内容」反推既脆弱
	 * （内容相同的两行无法区分）又重复一遍这里的匹配逻辑。
	 *
	 * deletedRows 按容器下标对齐（与 applySql 的影子容器同序），值是该表**原始
	 * 行号**（一次 DELETE 命中多行即多条）；deletedNames 是该批次所有被删变量名
	 * （name 列取值），供生效摘要与审计对账。两者都只增不改——调用方据新增部分
	 * 判断本批次的影响面。 */
	struct Mutations {
		/* 本批次新增行的「原始坐标」哨兵。新行没有活体原始行号；用哨兵与
		 * 既有行的真实 origin 区分，DELETE 命中本批次新增行时不会被误当成
		 * 「活体第 N 行」去摘（否则会越界/错删）。 */
		static constexpr std::size_t kInsertedRowOrigin = static_cast<std::size_t>(-1);

		std::map<std::string, std::vector<std::size_t>> deletedRows;
		std::vector<std::string> deletedNames;
		/* 每表**当前影子行** → 原始行号（与影子容器当前行同序，含行 0 列头）。
		 * 只记录本批次被改过的表；未出现在 map 里的表 = 从未改动（全恒等）。
		 * 新增行值为 kInsertedRowOrigin。热插计划据此精确挑出「本批次新增行」，
		 * 不再假设新增块永远在尾部——INSERT 后再 DELETE 掉插入行时尾部假设
		 * 会越界（2026-11 修复）。 */
		std::map<std::string, std::vector<std::size_t>> rowOrigins;
		/* 每表本批次**插入的行数**（按表名；UPDATE 的改后行、INSERT 的行都计数）。
		 * 计数只作账本/摘要；精确定位哪些当前行是新增行看 rowOrigins（下方），
		 * 不能再用「当前行数 - 插入数」推尾部区间——INSERT 后再 DELETE 掉插入行
		 * 会让尾部假设失效。 */
		std::map<std::string, std::size_t> insertedRows;
		/* 每表本批次**被 UPDATE 改写的行数**（按表名，2026-09-23 热更新）。两个
		 * 用途：① applySql 据此判定「本批次含改写」→ 切换为先删后建执行序（见
		 * 其注释：先建后拆下同名重建会在注册表撞名）；② 生效摘要与审计如实报出
		 * 「已热更新 N 行（断电重建）」，而不是把同一次改写谎报成一次删除加一次
		 * 新增。改写行同时计入 deletedRows/insertedRows（物理事实如此），本字段
		 * 只是改写事实的独立记账。 */
		std::map<std::string, std::size_t> updatedRows;
		/* 本批次被 DROP 掉的**表名**（整表撤下，2026-09-23）。readSQL 已在影子容器
		 * 上把该表的全部数据行清空（并计入 deletedRows/deletedNames，故行的断电与
		 * 撤注册走与 DELETE 同一条 DelPlan 机器）；调用方据此**额外**把空表壳从活体
		 * matrices_ 上摘除，并重锚定其后 MetaProvider 的矩阵引用（deque 整表移除会
		 * 让后续元素引用失效）。表名在「本批次 CREATE 后又被 DROP」的表上也会出现
		 * ——那类表从未装配，摘除面只有影子容器。 */
		std::set<std::string> droppedTables;
	};

	/* SQL4cj → MatrixObject 结构表解析。
	 * 容器为 std::deque（2026-09-23 热插表）：结构期 matrices_ 必须是
	 * 「两端插入不失效元素引用」的容器，MetaProvider::matrix_ 的引用不变式
	 * 才能从「靠 inject 必须早于 active 的约定」升级为构造保证（见 robot.cpp）。
	 *
	 * allowDelete 缺省 **false**：同一个函数服务两条路径——结构脚本装配
	 * （RobotStruct 构造期，机器人尚未上电，删不了任何东西）与热插行级变更
	 * （applySql：DELETE / DROP / UPDATE——UPDATE 分解为「DELETE 命中行 +
	 * INSERT 改后行」，同样只在带电路径放行）。缺省关使启动路径的接受语言逐字
	 * 不变，且「结构脚本里写 DELETE/UPDATE」得到的是一句人话而不是运行期怪错；
	 * 热插调用点显式传 true。
	 * mutations 为空 = 不收集变更信息（同样只在热插路径需要）。 */
	static void readSQL(bot::Reader& input, std::deque<mt::MatrixObject>& out,
			bool allowDelete = false, Mutations* mutations = nullptr);
};

} // namespace bot

#pragma once
/* meta_provider.hpp —— 元数据引用列与静态列缓存（拆自 robot.hpp，2026-09-29 A2；
 * 实现在 meta_provider.cpp） */

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "expr.hpp"
#include "hw_registry.hpp"
#include "json.hpp"
#include "matrix.hpp"

namespace bot {

/* 元数据引用列：变量引用（var 非空）或 $(...) 表达式引用（expr 非空）。
 * 表达式在 seed 期解析（语法早报 + 标识符存在性校验），collect 期惰性求值。
 * N-5：var 引用在 seed 期（build 前，先于任何会话别名覆盖）锁定目标指针
 * target——collect/collectForDestroy 不再按名重查。否则 --tcp 会话别名
 * 覆盖后，结构变量的销毁期快照会解析到覆盖者（别名），拿到错误的 fd/addr
 * 快照做去初始化。锁定期语义：$ 引用绑定结构期变量，会话覆盖不影响它。
 * target 为非所有权指针，HwRegistry::pool_ 只增不减，生命周期安全。 */
struct MetaRef {
	std::string col;				/* 承载 $ 的列名 */
	std::string var;				/* 变量引用（expr 为空时有效） */
	MatrixVars_Hardware* target = nullptr;	/* seed 期锁定的引用目标 */
	std::shared_ptr<const Expression> expr;		/* 表达式引用 */
};

/* P8/M2：元数据静态列缓存（字面列冻结 + 引用列实时 read() 快照）。
 * name 列与结构引用列（controller/trigger）不进元数据——按保留列名跳过。 */
class MetaProvider {
	/* 锚定的矩阵：**指针而非引用**（2026-09-23 整表撤下）。矩阵元素住在
	 * matrices_（std::deque）里，整表 DROP 会 erase 掉某个元素，而 deque 的
	 * 中间 erase 会让其后所有元素引用失效（标准如此，不依赖某个实现是否原地
	 * 搬值）；引用成员绑死一次、无法重锚，故改为指针并配 rebase()。行数变化
	 * （行删除）不影响本指针——那只会前移行号；本指针只在整表移除后需要更新。 */
	const mt::MatrixObject* matrix_;
	std::int64_t row_;
	const HwRegistry* registry_;
	std::optional<std::vector<std::string>> cols_;
	std::optional<std::vector<std::string>> vals_;
	/* 引用列：变量快照按字段并入元数据；@Vars 标量/表达式则把值写到该列名下。 */
	std::optional<std::vector<MetaRef>> refs_;

	void seed();
	/* 字面列（含 "-" 继承结果）构造——运行期与销毁期两条收集路径共用 */
	Json staticPart();
	/* N-16：collect / collectForDestroy 公共内核（forDestroy=false 时
	 * 引用解析失败照常上抛；true 时逐引用尽力而为、logD 跳过） */
	Json collectRefs(bool forDestroy);

	/* 阶段 3 拆分：单个引用列的快照并入 / destroy 跳过日志单点（契约见实现处） */
	bool appendRef(Json& obj, const MetaRef& ref, bool forDestroy);
	void logDestroySkip(const std::string& what, const std::string& why);

public:
	MetaProvider(const mt::MatrixObject& matrix, std::int64_t row,
			const HwRegistry* registry)
		: matrix_(&matrix), row_(row), registry_(registry) {}

	Json collect();
	/* F-04′：字面列 + 引用列的「尽力而为」快照——destroy 阶段用。
	 * 单个引用解析失败只跳过该引用，绝不放弃整轮 destroy（理由见 robot.cpp 实现处）。 */
	Json collectForDestroy();
	/* F-05：装配完成后、build 前做引用存在性校验（seed 未通过即抛出） */
	void validate() { seed(); }

	/* 热删除（2026-09-23）：本提供者锚定的「矩阵 + 行」。RobotStruct 用它摘除
	 * 被删行的提供者——判据必须是这一对（而不是提供者自身的某个 id），因为
	 * 行列就是它在结构里的唯一身份。矩阵是 std::deque 的元素、地址稳定，
	 * 故该判据精确且不受行数变化影响。 */
	const mt::MatrixObject& matrix() const { return *matrix_; }
	std::int64_t row() const { return row_; }

	/* 整表撤下（2026-09-23）：矩阵地址（供 RobotStruct 在 erase 前后建
	 * 旧地址→新地址映射，据此重锚定存活提供者）。 */
	const mt::MatrixObject* matrixPtr() const { return matrix_; }
	/* 重锚定到矩阵的新地址（整表 DROP 后 deque 元素搬移/引用失效时调用）。
	 * **不清缓存**：存活表的内容逐字未变（只是位置变了），seed 结果（cols_/
	 * vals_/refs_）语义仍然成立；行号 row_ 也不因整表移除而变。 */
	void rebase(const mt::MatrixObject& m) { matrix_ = &m; }
	/* 行删除的行号重锚定（2026-09-25 审计 A-4 收口）：removeRows 是保序擦除，
	 * 同矩阵内位于被删行之后的行会前移，锚定这些行的提供者必须同步减行号
	 * ——row() 是**后续批次** deadProvider 判据的坐标（executeHotDeletes 的
	 * 4.6.4①），过期即摘错/漏摘提供者。**不清缓存**：seed 只在行号定值时
	 * 读一次矩阵（active/commitHotBatch 的 validate 都是急切 seed），缓存
	 * 的静态列与按名/指针锁定的引用不受行移动影响。delta 恒为负（行只会
	 * 前移），签名保持通用减法。 */
	void shiftRow(std::int64_t delta) { row_ += delta; }
};

} // namespace bot

#pragma once
/* meta_registry.hpp —— 元数据域（拆自 RobotStruct 私有容器，2026-10-03 阶段 4）
 *
 * Lua 变量的元数据提供者登记表此前以 RobotStruct::metaProviders_ 私有成员存在，
 * 装配期（HwFactory::createLuaVars）登记、active/热插期统一校验 $ 引用、热删除期
 * 摘除与行号重锚定、整表撤下期重锚定矩阵地址——跨域耦合点。本类把「元数据域」
 * 收敛成一个门面。
 *
 * 身份是不变式：每个提供者锚定「矩阵地址 + 行号」这一对（MetaProvider 的
 * matrix_/row_）。矩阵是 StructureStore 里 std::deque 的元素、地址稳定，故
 * 「矩阵 + 行号」判据精确且不受行数变化影响——本类的 dropRows/shiftRowsAfter
 * 都建立在这一对之上，调用方负责把结构域的行号坐标原样传进来。
 */

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "matrix.hpp"
#include "meta_provider.hpp"

namespace bot {

class MetaRegistry {
public:
	/* 登记一个元数据提供者（装配期唯一入口，HwFactory::createLuaVars 调用） */
	void add(std::shared_ptr<MetaProvider> provider) { providers_.push_back(std::move(provider)); }

	std::size_t size() const { return providers_.size(); }
	bool empty() const { return providers_.empty(); }

	const std::vector<std::shared_ptr<MetaProvider>>& all() const { return providers_; }

	/* F-05：装配完成后、任何 build 之前统一校验 $ 引用存在性（全部提供者）。
	 * 增量路径只查 [from, size)——本批次新增（既有提供者启动期已校验）。 */
	void validateAll() const {
		for (const auto& p : providers_) { p->validate(); }
	}
	void validateFrom(std::size_t from) const {
		for (std::size_t i = from; i < providers_.size(); ++i) { providers_[i]->validate(); }
	}

	/* 热插回滚：丢弃本批次新增的登记（尾部截断） */
	void truncate(std::size_t n) { providers_.resize(n); }

	/* 热删除：摘除指向被删行的提供者。判据是「矩阵 + 行号」而不是引用相等——
	 * 矩阵是 deque 元素、地址稳定，故该判据精确且不受行数变化影响；传入的行号
	 * 必须是**删除前的原始坐标**（行擦除会让坐标前移，故本调用须先于 shiftRowsAfter
	 * 与结构行擦除）。 */
	void dropRows(const std::set<std::pair<const mt::MatrixObject*, std::int64_t>>& dead);

	/* 热删除的行号重锚定：同一矩阵内，行号大于被删行的提供者全部前移。
	 * 结构域的 removeRows 是**保序擦除**，提供者的 row() 是后续批次 deadProvider
	 * 判据与惰性取行的下标，必须同步。removedRows 为原始行号（升序）。 */
	void shiftRowsAfter(const mt::MatrixObject* mat, const std::vector<std::size_t>& removedRows);

	/* 整表撤下（DROP TABLE）的两阶段重锚定——deque 整表 erase 会让其后所有元素
	 * 引用失效，而提供者的表名只能经 matrix_ 读到，故必须分两步：
	 *   ① 结构表 erase **之前**调 captureTableNames()——此刻 matrix_ 仍有效；
	 *   ② erase **之后**调 rebaseByName()——按稳定身份（表名）锚回新地址。
	 * 表名唯一且是稳定身份；只有「本批次 CREATE 后 DROP」的表会查不到（那类表
	 * 从未装配，且此时无元素搬移，重锚定是空转），resolve 返回 nullptr 即跳过。 */
	using TableNameSnapshot = std::vector<std::pair<MetaProvider*, std::string>>;
	TableNameSnapshot captureTableNames() const;
	void rebaseByName(const TableNameSnapshot& snapshot,
		const std::function<const mt::MatrixObject*(const std::string&)>& resolve);

private:
	std::vector<std::shared_ptr<MetaProvider>> providers_;
};

} // namespace bot
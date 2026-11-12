/* meta_registry.cpp —— 元数据域门面实现（2026-10-03 阶段 4 拆自 robot.cpp 的
 * metaProviders_ 直接操作）。桶内各方法的语义与判据理由见头文件注释。 */

#include "meta_registry.hpp"

#include <algorithm>

namespace bot {

void MetaRegistry::dropRows(
		const std::set<std::pair<const mt::MatrixObject*, std::int64_t>>& dead) {
	auto isDead = [&](const std::shared_ptr<MetaProvider>& p) {
		/* emplace 的显式构造：count({a, b}) 的括号初始化列表无法推导到 set 的
		 * value_type（pair 的转换构造函数不参与该重载）。 */
		return dead.count(std::make_pair(p->matrixPtr(), p->row())) != 0;
	};
	providers_.erase(std::remove_if(providers_.begin(), providers_.end(), isDead),
		providers_.end());
}

void MetaRegistry::shiftRowsAfter(const mt::MatrixObject* mat,
		const std::vector<std::size_t>& removedRows) {
	for (const auto& p : providers_) {
		if (p->matrixPtr() != mat) { continue; }
		std::int64_t shift = 0;
		for (std::size_t r : removedRows) {
			if (static_cast<std::int64_t>(r) < p->row()) { ++shift; }
		}
		if (shift > 0) { p->shiftRow(-shift); }
	}
}

MetaRegistry::TableNameSnapshot MetaRegistry::captureTableNames() const {
	TableNameSnapshot snapshot;
	snapshot.reserve(providers_.size());
	for (const auto& p : providers_) {
		snapshot.emplace_back(p.get(), p->matrix().getName());
	}
	return snapshot;
}

void MetaRegistry::rebaseByName(const TableNameSnapshot& snapshot,
		const std::function<const mt::MatrixObject*(const std::string&)>& resolve) {
	for (const auto& [prov, nm] : snapshot) {
		if (const mt::MatrixObject* m = resolve(nm)) { prov->rebase(*m); }
	}
}

} // namespace bot
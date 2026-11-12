#pragma once
/* flowcolumn.hpp —— controller/trigger 流引用列判定（robot 内部 TU 共享）
 * 拆自 robot.cpp 的匿名命名空间：meta_provider / hw_factory 两个编译单元
 * 都要用，inline 收敛为单一定义（不进 robot.hpp——实现细节不外泄）。 */

#include <cctype>
#include <string>

namespace bot {

/* ---- 结构引用列判定（多列支持）----
 * controller/trigger 之外放行基名+纯数字后缀的编号列（controller2/trigger10…），
 * 同一行可声明多个转发目标/触发器，执行顺序 = 列声明序（从左到右）。
 * 基名+非数字后缀（controller2x）不匹配，仍是普通元数据列。 */
inline bool flowColumnMatches(const std::string& col, const std::string& base) {
	if (col.compare(0, base.size(), base) != 0) { return false; }
	if (col.size() == base.size()) { return true; }
	for (std::size_t k = base.size(); k < col.size(); ++k) {
		if (!std::isdigit(static_cast<unsigned char>(col[k]))) { return false; }
	}
	return true;
}

inline bool isFlowColumn(const std::string& col) {
	return flowColumnMatches(col, "controller") || flowColumnMatches(col, "trigger");
}

} // namespace bot

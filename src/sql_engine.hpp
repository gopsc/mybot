#pragma once
/* sql_engine.hpp —— 基于 SQLite3 的结构 SQL 解析/执行层
 *
 * Structure SQL 的扩展语法（$var、$(expr)、- 继承）先由本层归一化为 SQLite
 * 可执行的 SQL，再交给 SQLite 解析/执行；执行结果按 CREATE 声明序读回为
 * MatrixObject 表。热 SQL 仍由现有 ScriptLoader 处理，后续可逐步迁移。
 */

#include <deque>
#include <string>

#include "matrix.hpp"

namespace bot {

class Reader;

class SqlEngine {
public:
	/* 读取完整结构脚本并返回声明序矩阵表。 */
	std::deque<mt::MatrixObject> loadStructure(Reader& input);

	/* 直接解析一段结构 SQL（测试/差分用）。 */
	std::deque<mt::MatrixObject> loadStructure(const std::string& text);
};

} // namespace bot

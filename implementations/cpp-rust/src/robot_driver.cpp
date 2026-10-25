/* robot_driver.cpp —— RobotStruct Lua 驱动变量注入 */

#include "robot.hpp"

#include <deque>
#include <utility>

#include "util_env.hpp"

namespace bot {

void RobotStruct::injectLuaDriver(const std::string& driverTable, const std::string& varName) {
	if (!isSafeIdent(driverTable) || !isSafeIdent(varName)) {
		throw IllegalArgumentException("驱动表名与变量名必须是安全标识符（字母/数字/下划线）: '"
			+ driverTable + "' / '" + varName + "'");
	}

	/* 注入只允许发生在 active() 之前；运行中的机器人必须使用 applySql，
	 * 以保证完整的校验、装配和回滚语义。 */
	if (!metas_.empty()) {
		throw IllegalArgumentException("injectLuaDriver must be called before active():"
			" use the hot-SQL path (applySql) to add tables to a running robot");
	}

	std::string sql = "CREATE TABLE " + driverTable + " (name String);\n"
		+ "INSERT INTO " + driverTable + " (name) VALUES ('" + varName + "');\n";
	MemoryReader reader(std::move(sql));
	std::deque<mt::MatrixObject> extra;
	ScriptLoader::readSQL(reader, extra);
	for (auto& m : extra) { structures_.append(std::move(m)); }
}

} // namespace bot

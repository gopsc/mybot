/* robot_hotsql.cpp —— RobotStruct 热 SQL 应用入口 */

#include "robot.hpp"
#include "robot_internals.hpp"

#include "scriptlimit.hpp"	/* kMaxScriptBytes / ScriptTooLarge */
#include "util_env.hpp"

namespace bot {

std::string RobotStruct::applySql(const std::string& sql) {
	if (state_ != LifecycleState::Active) {
		throw IllegalArgumentException("热插表需要机器人已上电常驻（active() 之后）；"
			"未上电时请把语句写进结构脚本");
	}
	/* 热 SQL 与结构脚本/动作脚本共用 8 MiB 输入上限：applySql 直接进
	 * ScriptLoader（MemoryReader 不设限），没有这道检查时空批注字符串
	 * 可绕过启动期的字节预算。 */
	if (sql.size() > kMaxScriptBytes) {
		throw ScriptTooLarge(kMaxScriptBytes, "hot SQL script");
	}
	return internals_->hotSql.apply(sql, deactivateGraceMs_);
}

} // namespace bot

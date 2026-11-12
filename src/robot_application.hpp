#pragma once

#include "cliargs.hpp"

namespace bot {
class RobotStruct;

/* 执行动作输入源并按需清理；返回进程退出码（0 成功、1 运行错误）。 */
int runRobotAndCleanup(RobotStruct& robot, const CliOptions& options);

} // namespace bot

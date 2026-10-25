#pragma once

#include "agentmode.hpp"
#include "cliargs.hpp"

namespace bot {
class RobotStruct;

int runRobotAndCleanup(RobotStruct& robot, const CliOptions& options,
	const agent::AgentModeConfig& agentCfg);
}

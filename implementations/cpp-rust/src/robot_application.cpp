#include "robot_application.hpp"

#include <iostream>
#include <memory>

#include "actionsource.hpp"
#include "agent_subprocess.hpp"
#include "daemonvar.hpp"
#include "mcpbackend.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_num.hpp"

namespace bot {
namespace {

int runActionPipeline(RobotStruct& robot, const CliOptions& options) {
	std::unique_ptr<Reader> input = openActionSource(options);
	if (!input) {
		std::cerr << "动作输入源打开失败，退出" << std::endl;
		return 1;
	}
	robot.active();
	robot.run(*input);
	return 0;
}

int runMcpBackendPipeline(RobotStruct& robot, const agent::AgentModeConfig& cfg,
		const CliOptions& options) {
	robot.active();
	agent::McpBackendOptions bopts;
	bopts.socketPath = options.mcp.mcpSocket;
	bopts.authToken = cfg.mcpAuthToken;
	if (!options.mcp.mcpCallBudget.empty()) {
		bopts.callBudget = static_cast<long>(parseLongStrict(options.mcp.mcpCallBudget).second);
	}
	if (!options.mcp.mcpWallClock.empty()) {
		bopts.wallClockBudgetSec =
			static_cast<long>(parseLongStrict(options.mcp.mcpWallClock).second);
	}
	if (!options.mcp.mcpIdleTimeout.empty()) {
		bopts.idleTimeoutSec = static_cast<int>(parseLongStrict(options.mcp.mcpIdleTimeout).second);
	}
	return agent::runMcpBackend(robot, cfg, bopts, std::cerr);
}

} // namespace

int runRobotAndCleanup(RobotStruct& robot, const CliOptions& options,
		const agent::AgentModeConfig& agentCfg) {
	int rc = 0;
	try {
		rc = options.mcp.enabled
			? runMcpBackendPipeline(robot, agentCfg, options)
			: runActionPipeline(robot, options);
	} catch (const std::exception& e) {
		std::cerr << "Aborted: " << e.what() << std::endl;
		rc = 1;
	} catch (...) {
		std::cerr << "Aborted: non-standard exception (Lua error or foreign throw)"
			<< std::endl;
		rc = 1;
	}

	robot.deactivate();
	if (int abandoned = abandonedDaemonCount(); abandoned > 0) {
		std::cerr << "Warning: " << abandoned
			<< " daemon thread(s) abandoned at shutdown (join timeout); their Lua states"
			" are released by process exit only" << std::endl;
	}
	return rc;
}

} // namespace bot

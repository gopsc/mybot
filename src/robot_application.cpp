#include "robot_application.hpp"

#include <chrono>
#include <iostream>
#include <memory>

#include "actionsource.hpp"
#include "daemonvar.hpp"
#include "luaexec.hpp"
#include "robot.hpp"

namespace bot {
namespace {

int runActionPipeline(RobotStruct& robot, const CliOptions& options) {
	std::unique_ptr<Reader> input = openActionSource(options);
	if (!input) {
		std::cerr << "动作输入源打开失败，退出" << std::endl;
		return 1;
	}
	robot.active();

	double timeoutSec = 180.0;
	if (!options.actionTimeoutSec.empty()) {
		try {
			timeoutSec = std::stod(options.actionTimeoutSec);
		} catch (const std::exception&) {
			// validateOptions 已拒绝非法值；这里只是防御性回退。
			timeoutSec = 180.0;
		}
	}
	LuaExecBudget budget;
	budget.deadline = std::chrono::steady_clock::now()
		+ std::chrono::milliseconds(static_cast<long long>(timeoutSec * 1000.0));
	budget.watchStop = true;
	robot.armExecBudget(&budget);
	try {
		robot.run(*input, options.injectVars);
	} catch (...) {
		robot.armExecBudget(nullptr);
		throw;
	}
	robot.armExecBudget(nullptr);
	return 0;
}

} // namespace

int runRobotAndCleanup(RobotStruct& robot, const CliOptions& options) {
	int rc = 0;
	try {
		rc = runActionPipeline(robot, options);
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

/* robot_actions.cpp —— RobotStruct 动作矩阵执行与会话变量作用域 */

#include "robot.hpp"
#include "robot_internals.hpp"

#include "mtinclude.hpp"

#include <set>

#include "util_env.hpp"
#include "util_str.hpp"

namespace bot {

void RobotStruct::run(bot::Reader& input, const std::map<std::string, std::string>& injectVars) {
	/* 只拒绝曾上电后又断电的 Inactive；Loaded 保留离线预演能力。 */
	if (state_ == LifecycleState::Inactive) {
		throw IllegalArgumentException("机器人已断电，不能再执行动作：请先重新 active()");
	}

	std::vector<mt::MatrixObject> actionMatrices;
	mt::readMatrix(input, actionMatrices);
	mtinclude::expandIncludes(actionMatrices, actionIncludeBaseDir_);

	/* 内联 @Alias/@Vars 只在本次 run 生效，异常路径由 RAII 回滚。 */
	HwRegistry::SessionScope sessionScope(registry_);
	std::set<std::string> session;
	for (auto& matrix : actionMatrices) {
		std::string mtName = trim(matrix.getName());
		if (mtName == "Alias") { internals_->factory.registerAliasMatrix(matrix, &session); }
		else if (mtName == "Vars") { internals_->factory.registerVarsMatrix(matrix, &session); }
	}

	/* 调用方注入的变量覆盖脚本内默认值，并受安全标识符与引用覆盖规则约束。 */
	for (const auto& kv : injectVars) {
		if (!isSafeIdent(kv.first)) {
			throw IllegalArgumentException("注入变量名不是安全标识符：'" + kv.first + "'");
		}
		registry_.override(kv.first, MtVars_Alias::Make(kv.second));
	}

	internals_->runner.runAction(actionMatrices);
	internals_->runner.runReflex(actionMatrices);
}

} // namespace bot

/* exec_budget.cpp —— 动作脚本执行预算的线程局部状态（2026-11-15 审计修复） */

#include "exec_budget.hpp"

#include <chrono>

namespace bot {

const char* const kLuaExecBudgetMarker = "动作脚本执行预算";

namespace {
/* 当前线程的预算指针。thread_local：主线程的同步动作链与守护线程各自独立；
 * 守护线程看到自己的 nullptr，因此不被动作窗口的预算误伤。 */
thread_local const LuaExecBudget* t_budget = nullptr;
} // namespace

const LuaExecBudget* luaExecBudget() { return t_budget; }

void setLuaExecBudget(const LuaExecBudget* budget) { t_budget = budget; }

long long execBudgetRemainingMs() {
	const LuaExecBudget* budget = t_budget;
	if (budget == nullptr) { return -1; }
	const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
		budget->deadline - std::chrono::steady_clock::now()).count();
	return remaining > 0 ? remaining : 0;
}

void requireExecBudget() {
	if (t_budget != nullptr && execBudgetRemainingMs() == 0) {
		throw ExecBudgetExceeded(std::string(kLuaExecBudgetMarker)
			+ "：本轮动作脚本执行超时（deadline 已到）；"
			"可能是某个 Lua 驱动或阻塞 I/O 没有返回");
	}
}

} // namespace bot

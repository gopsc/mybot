#pragma once
/* exec_budget.hpp —— 动作脚本执行预算的叶子接口（2026-11-15 审计修复）
 *
 * 原先 LuaExecBudget 与 setter 只存在于 luaexec.hpp/cpp，但执行预算实际跨越
 * 三层：Lua 指令钩子、C++ ActionRunner 行循环、HAL 阻塞调用。把类型/访问器
 * 下沉到本头，HAL 不需要反向包含 LuaJIT 头；luaexec.hpp 只保留 Lua 钩子。
 *
 * 预算的生命周期仍由调用方（runActionPipeline）持有；本头只管理当前线程的
 * 指针。守护线程看到的是自己的 nullptr，与既有语义一致。
 */

#include <chrono>
#include <stdexcept>
#include <string>

namespace bot {

/* 预算耗尽时错误文案里的标记串。Lua 钩子与 C++/HAL 路径共用同一标记，
 * 上层可据此区分“预算超时”与驱动自身报错。 */
extern const char* const kLuaExecBudgetMarker;

/* 一次执行的预算。deadline 为 steady_clock 时刻；watchStop=true 时同时响应
 * Ctrl-C（stopRequested()），使失控驱动可被中断而不是只能连按两次强杀。 */
struct LuaExecBudget {
	std::chrono::steady_clock::time_point deadline;
	bool watchStop = true;
};

/* 预算错误：HALManager::call 必须原样重抛，不能折成 -1/JsonNull——否则
 * Lua 驱动只会看到一次普通失败，无法按“预算已耗尽”中止动作链。 */
class ExecBudgetExceeded : public std::runtime_error {
public:
	explicit ExecBudgetExceeded(const std::string& message)
		: std::runtime_error(message) {}
};

/* 当前线程的预算指针（nullptr = 未武装）。thread_local：主线程同步链与
 * 守护线程各自独立。 */
const LuaExecBudget* luaExecBudget();
void setLuaExecBudget(const LuaExecBudget* budget);

/* 剩余预算毫秒数；无预算返回 -1，已耗尽/过期返回 0。 */
long long execBudgetRemainingMs();

/* 若当前线程有预算且已过期，抛 ExecBudgetExceeded；无预算时无事发生。 */
void requireExecBudget();

} // namespace bot

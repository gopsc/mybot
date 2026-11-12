/* luaexec.cpp —— Lua 执行预算（PL-2）的实现。设计动机与实测数据见 luaexec.hpp。 */

#include "luaexec.hpp"

#include <string>

extern "C" {
#include <luajit.h>
}

#include "util_env.hpp"

namespace bot {

const char* const kLuaExecBudgetMarker = "动作脚本执行预算";

namespace {

/* 当前线程的预算指针。thread_local：工具调用在主线程的同步链上，
 * 守护线程（src/daemonvar.cpp 的 std::thread）看到的是自己那份 nullptr，
 * 因而守护驱动的挂死仍走既有的弃管路径，不被这里改变语义。 */
thread_local const LuaExecBudget* t_budget = nullptr;

} // namespace

const LuaExecBudget* luaExecBudget() { return t_budget; }
void setLuaExecBudget(const LuaExecBudget* budget) { t_budget = budget; }

void luaExecCountHook(lua_State* L, lua_Debug* ar) {
	(void)ar;
	const LuaExecBudget* b = t_budget;
	if (b == nullptr) { return; }
	/* Ctrl-C 优先：它给出的是「操作者要求停」，与「跑太久」是两件事，
	 * 文案必须能分辨（两者都会中止本轮脚本，但后者提示改脚本/调预算）。 */
	if (b->watchStop && stopRequested()) {
		luaL_error(L, "%s：已被中断（Ctrl-C）", kLuaExecBudgetMarker);
	}
	if (std::chrono::steady_clock::now() >= b->deadline) {
		luaL_error(L, "%s：本轮动作脚本执行超时（deadline 已到）；"
			"脚本本身是线性的，超时通常意味着某个 Lua 驱动没有返回——"
			"请检查该驱动，或调大配置文件的 action_script_timeout_sec",
			kLuaExecBudgetMarker);
	}
}

void armLuaExecState(lua_State* L) {
	if (L == nullptr) { return; }
	/* ① 关 JIT：**这是钩子能触发的前提**。LuaJIT 的 count 钩子只在解释器
	 * 派发路径上跑；不关 JIT 的话，任何值得设超时的循环都会在约 56 次迭代后
	 * 被编译成 trace，此后钩子永不触发（实测 N=100000 触发 0 次）。 */
	luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
	/* ② 挂指令计数钩子 */
	lua_sethook(L, luaExecCountHook, LUA_MASKCOUNT, kLuaExecHookInterval);
}

void disarmLuaExecState(lua_State* L) {
	if (L == nullptr) { return; }
	lua_sethook(L, nullptr, 0, 0);
	/* 恢复 JIT。窗口外一切照旧：test/test_jit_warmup.lua 锁的是 HAL 变参 ABI
	 * 在 JIT 编译后的行为，它不经过 agent 工具，因此不受本机制影响——
	 * **实现时不要把 jit.off 挪到 openSandboxedState() 那种全局位置**。 */
	luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);
}

} // namespace bot

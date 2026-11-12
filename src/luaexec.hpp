#pragma once
/* luaexec.hpp —— Lua 执行预算（PL-2，2026-09-22）
 *
 * 问题：`run_action_script` 是**默认开启**的核心工具，却没有任何时限
 * （src/agenttools.cpp 里只有 run_command 有超时，而它默认关闭）。动作脚本
 * 本身是线性矩阵、DSL 层无循环，所以挂死只可能来自 Lua 驱动自己的 call()：
 * 死循环，或阻塞在 ffi 系统调用里。一旦发生，会话永久卡住，Ctrl-C 也无效
 * （src/action_runner.cpp 的 stopRequested() 检查只在**行与行之间**生效）。
 *
 * 机制：给驱动 lua_State 挂**指令计数钩子**，超期即以 Lua 错误中止本轮脚本；
 * 该错误经既有管道（call_lua 的 pcall → ERR 契约 → ensureOk 抛 →
 * run_action_script 的 catch）变成一段给模型的失败文案，不需要新错误通道。
 *
 * ⚠️ **必须先关 JIT，钩子才会触发**（2026-09-22 实测，见提交 f46e5fc）：
 * LuaJIT 的 count 钩子只在解释器派发路径上跑，热点循环在约 56 次迭代后就被编译
 * 成 trace，此后不再有指令派发——N=100000 的钩子实测触发 0 次。故 arm 时一并
 * `luaJIT_setmode(...ENGINE|OFF)`，disarm 时恢复。
 *
 * ⚠️ **边界（必须在文档里如实声明）**：钩子只能打断解释器里跑的 Lua 代码。
 * 驱动阻塞在 ffi 系统调用（read/ioctl/usleep）里时 VM 不派发指令，钩子没有
 * 执行机会——这一条无解。本仓库唯一能兜住「阻塞的 C 调用」的是子进程 +
 * deadline + SIGKILL（agent_subprocess 的 runChild），但动作脚本必须在宿主
 * 进程内操作已上电的硬件状态，走不了那条路。
 *
 * 代价（2026-09-22 实测，真实驱动 modules/Relay.lua）：窗口内解释执行约 3.4×
 * 慢，但绝对值是 0.11 → 0.44 µs/次驱动调用；最重的在库动作脚本约 550 次调用
 * → 窗口总代价 ~0.2 ms，而脚本自身耗时以秒计（硬件延时主导）。且 10²–10³ 次
 * 调用量级下 JIT 根本没热身（1000 次以下 jit=on 反而更慢），实际无可损失。
 */

#include <chrono>

#include "luaend.hpp"

namespace bot {

/* 预算耗尽时错误文案里的标记串。工具侧据此把「预算超时」与「驱动自身报错」
 * 分开——两者走同一条 ensureOk → runtime_error 通道，模型需要能分辨
 * 「该换个做法」还是「该重试」。 */
extern const char* const kLuaExecBudgetMarker;

/* 一次执行的预算。deadline 为 steady_clock 时刻；watchStop=true 时同时响应
 * Ctrl-C（stopRequested()），使失控驱动可被中断而不是只能连按两次强杀
 * （强杀会跳过 deactivate，把执行器留在带电状态）。 */
struct LuaExecBudget {
	std::chrono::steady_clock::time_point deadline;
	bool watchStop = true;
};

/* 当前线程的预算指针（nullptr = 未武装 → 钩子立即返回）。
 * thread_local 而非全局态：与 src/luavar.hpp 的 topDepth 同款理由——工具调用
 * 是主线程的同步链，而守护线程各自独立，天然不受 agent 窗口影响。 */
const LuaExecBudget* luaExecBudget();
void setLuaExecBudget(const LuaExecBudget* budget);

/* 给一个 Lua 状态机挂上/摘下执行预算钩子。arm 时一并关 JIT（见文件头），
 * disarm 时恢复 JIT 并摘钩子。幂等：重复 arm/disarm 安全。 */
void armLuaExecState(lua_State* L);
void disarmLuaExecState(lua_State* L);

/* 钩子本体（暴露出来供单测直接驱动）。abortOnBudget 是它的判据：
 * 预算为空 → 返回；Ctrl-C 已请求（且 watchStop）→ 报中断；超期 → 报超时。 */
void luaExecCountHook(lua_State* L, lua_Debug* ar);

/* 指令计数钩子的间隔。取小值：实测「取大值」等于关掉这个机制
 * （循环早被 JIT 编译走，不过 LuaJIT 下 JIT 已被 arm 关掉，但解释器里
 * 一段紧凑循环仍可能几万条指令才走一次；500 是实测里稳定触发的量级）。 */
inline constexpr int kLuaExecHookInterval = 500;

} // namespace bot

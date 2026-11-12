#pragma once
/* agent_subprocess_internal.hpp —— run_command 子进程机器的**模块内**接缝
 *
 * 2026-10-01 agent_subprocess.cpp 按 TU 拆分（行为保持）时建：环境清洗域 →
 * agent_envscrub.cpp、子进程侧 fd 卫生与 exec → agent_fdguard.cpp、spawn/pump/
 * reap/回执格式化留守 agent_subprocess.cpp。这里只放三个 TU 共用、但不属于
 * 对外契约的件（对外契约在 agent_subprocess.hpp：collectEnvSecrets/
 * isSensitiveEnvName/scrubEnvSecrets/runShell 等）；与 agenttools_internal.hpp
 * 同一形态。 */

#include "agent_subprocess.hpp"

namespace bot {
namespace agent {

/* 环境清洗：剔除名字含敏感词（整词）的变量（实现 agent_envscrub.cpp；
 * spawnChild 在 fork 前调用——会分配堆内存，子进程里不能碰）。 */
std::vector<char*> buildCleanEnvp();

/* fork 前父进程侧全量 CLOEXEC（实现 agent_fdguard.cpp；审计 P1 第二层防线）。 */
void markAllFdsCloexec();

/* 子进程侧路径自报探针（AG-11；traceFd < 0 或路径空时零行为）。 */
void traceChildPath(int traceFd, const char* path);

/* 子进程侧吊销继承 fd（≥3 全量；close_range 优先、opendir 退化兜底）。 */
void revokeInheritedFds(int traceFd);

/* 子进程侧执行机器：独立进程组 + 摆好 0/1/2 + 按 spec 吊销 fd + execle。
 * **不返回**：成功即 exec，任何失败 _exit(127)。fork 之后不分配堆内存。 */
[[noreturn]] void execChild(const ChildSpec& spec, int stdinR, int outR, int outW,
		int errR, int errW, char* const* envp);

} // namespace agent
} // namespace bot

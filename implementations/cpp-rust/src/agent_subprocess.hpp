#pragma once
/* agent_subprocess.hpp —— run_command 的子进程实现（拆自 agenttools.cpp）
 * 超时 / 进程组终止 / 输出截断 / 环境清洗，与五个工具的装配逻辑无耦合，
 * 独立成 TU 便于单测与复用。 */

#include <cstddef>
#include <string>
#include <sys/types.h>
#include <vector>

namespace bot {
namespace agent {

/* run_command 单流输出上限（字节）；formatRunResult 的截断文案取自该值 */
constexpr std::size_t kMaxCommandOutput = 64u * 1024;

/* 抓取当前环境里敏感变量的**原始字符串指针**。必须在 setenv 之前调用：
 * setenv(overwrite=1) 会把数组槽位换成堆上的新串，exec 时那份原串就再也找不回。 */
std::vector<char*> collectEnvSecrets();

/* 敏感环境名判据（整词切词后查表）。环境清洗（本文件）与审计日志的
 * 命令遮蔽（agentaudit，经 maskedWord 复用本判据再加 authorization/bearer
 * 两个仅遮蔽词）共用同一份，防两份名单各自漂移。
 * 入参必须是**已转小写**的名字。 */
bool isSensitiveEnvName(const std::string& lowerName);

/* 就地把这些字符串抹零。动机：/proc/<pid>/environ 对同 UID 进程可读，
 * 只清洗子进程继承的那份环境挡不住它——常驻 agent 的密钥会一直躺在那儿。
 * 残余：同 UID 若有 ptrace 权限，仍可从宿主内存读出密钥；本函数是提高门槛
 * 而非对抗边界，要硬隔离得把 agent 放进专用用户 / 容器 / 网络命名空间。 */
void scrubEnvSecrets(const std::vector<char*>& pointers);

struct RunResult {
	int exitCode = -1;
	bool timedOut = false;
	bool interrupted = false;
	/* 硬上限兜底触发（超时后 kill 仍未能让管道 EOF，例如子进程卡在 D 态）：
	 * 此时**不确定**子进程是否已死，也不能声称「已终止」——那句话会直接进模型
	 * 上下文，说错了模型就基于错误前提继续决策。旧实现走这条路径时一个标记都
	 * 不带，回执看起来像「正常结束但退出码 -1」，真实成因完全丢失。 */
	bool hardStopped = false;
	/* 截断按流独立记账：kMaxCommandOutput 是「每流」上限（总量可达 2 倍），
	 * 原实现用单一 truncated 标志，stdout 触顶会连带把 stderr 也报成截断。 */
	bool outTruncated = false;
	bool errTruncated = false;
	std::string out;
	std::string err;
};

/* 放弃回收子进程时的告警文案（AG-10 单点）。单独暴露是为了让离线用例能钉住
 * 「告警说了什么」——该路径的行为构造依赖 D 态进程，离线不可得。 */
std::string reapGiveUpWarning(int pid, int graceMs);

/* 有界回收：WNOHANG 轮询到 graceMs，仍未回收即放弃（**绝不无超时阻塞**——
 * kill 未生效（D 态 / 权限）时无超时的 waitpid 会把 agent 会话永久挂死），
 * 放弃时按 reapGiveUpWarning 响亮告警。返回是否回收到终态；waitpid 报 ECHILD
 * （确已无可回收）时立即返回 false，不占满宽限。
 * 单独暴露是为了让离线用例直接钉住这两条路径（真挂死形态需 D 态进程，离线不可得）。 */
bool reapWithGrace(pid_t pid, int& status, int graceMs = 2000);

/* ---- 统一子进程运行器（run_command 与策略确认程序共用）----
 * 为什么抽出（2026-09-22 审计 F1/F2）：两份「pipe → fork → setpgid → 超时整组
 * SIGKILL → 回收」实现曾各自演化，防线性差异（有界回收、子进程 fd 吊销、
 * 硬上限兜底）只落到了 runShell 一侧，确认路径因此留着**无超时 waitpid** 与
 * 全量 fd 继承。现在骨架单点、差异一律经 ChildSpec 显式声明，不再由调用方
 * 各自实现——「碰巧不同」不当作口径。 */
struct ChildSpec {
	std::string cmd;
	/* 环境：true = buildCleanEnvp（模型可驱动的命令绝不能继承 LLM API key）；
	 * false = 继承宿主 environ（策略确认程序是操作者可信程序，可能依赖自有
	 * *_TOKEN，清洗会静默砸掉合法脚本——理由见 docs/agent.md）。 */
	bool cleanEnv = true;
	/* stdin：true = 建管道并把 stdinPayload 写进去；false = 重定向 /dev/null
	 * （子命令不与 agent REPL 抢终端输入）。 */
	bool pipeStdin = false;
	std::string stdinPayload;
	/* stdout/stderr：true = 接管道（每流截断 kMaxCommandOutput + UTF-8 消毒）；
	 * false = 继承宿主（确认程序直接面对操作者终端）。 */
	bool captureOutput = true;
	/* 超时秒数 + 超时后回收宽限（毫秒）。回收有界是硬约束，宽限只影响等多久。 */
	int timeoutSec = 0;
	int graceMs = 2000;
	/* fd 吊销：父侧 markAllFdsCloexec + 子侧 revokeInheritedFds（防子进程拿到
	 * HAL/驱动的器件句柄，在 robot->deactivate() 之后照样 ioctl 拨硬件）。 */
	bool revokeFds = true;
	/* 轮询 stopRequested()（REPL 的 Ctrl-C → 整组终止）。确认程序不响应中断
	 * （现状语义：确认程序自己决定何时退，宿主只等它到超时）。 */
	bool watchStop = true;
	/* AG-11 探针输出 fd（-1 = 关闭）。归调用方持有，runChild 不关它。 */
	int traceFd = -1;
};

/* 一次子进程运行的中性结果；两个调用点各自折算成 RunResult / ConfirmRun。 */
struct ChildOutcome {
	bool reaped = false;		/* 回收到终态（正常退出或被信号终止） */
	bool normalExit = false;	/* reaped 且 WIFEXITED */
	int exitCode = -1;		/* normalExit 时有效 */
	int termSig = 0;		/* 被信号终止时记录 */
	bool timedOut = false;
	bool interrupted = false;
	bool hardStopped = false;
	bool outTruncated = false;
	bool errTruncated = false;
	std::string out;
	std::string err;
};

/* 跑一次子进程（骨架单点）。pipe / fork / fcntl 失败抛 std::runtime_error。 */
ChildOutcome runChild(const ChildSpec& spec);

/* 经 /bin/sh -c 执行命令；stopRequested()（util）提前触发整组终止。
 * pipe / fork 失败抛 std::runtime_error。 */
RunResult runShell(const std::string& cmd, int timeoutSec);

/* RunResult → 面向模型的文本回执（退出码/超时/中断/输出与截断标记） */
std::string formatRunResult(const RunResult& r);

} // namespace agent
} // namespace bot

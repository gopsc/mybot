/* agent_fdguard.cpp —— run_command 子进程的 fd 卫生与子侧执行域
 *
 * 2026-10-01 自 agent_subprocess.cpp 拆出（行为保持）：父进程侧全量 CLOEXEC
 * （markAllFdsCloexec，审计 P1 第二层）、子进程侧路径自报探针（AG-11）与
 * fd 吊销（revokeInheritedFds：close_range 优先、opendir 退化兜底）、以及
 * execChild 子侧执行机器。约束：fork 之后不分配堆内存（守护线程并发 fork）。 */

/* close_range 需要 _GNU_SOURCE；置于任何头文件之前（重复定义触发 -Wpedantic）。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "agent_subprocess.hpp"
#include "agent_subprocess_internal.hpp"

#include <cerrno>
#include <cstring>

#include <dirent.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace bot {
namespace agent {

/* fork 前在**父进程**把 /proc/self/fd 里全部 ≥3 的句柄打上 FD_CLOEXEC。
 * （审计 P1 修复，2026-09-21）这是 revokeInheritedFds 之外的第二层：父进程
 * 允许分配堆内存（opendir 可用），按「实际打开的 fd」枚举，天然覆盖高编号
 * 句柄，不受退化路径数值封顶的限制；子进程侧 revokeInheritedFds 继续兜住
 * 「枚举之后、exec 之前」由并发守护线程新开的句柄。设置 CLOEXEC 不影响任何
 * fd 在本进程内的继续使用（主进程自身从不 exec），HAL 句柄本就 O_CLOEXEC。
 * 无 /proc 的环境（罕见）静默跳过，交由子进程侧退化路径兜底。 */
void markAllFdsCloexec() {
	DIR* d = ::opendir("/proc/self/fd");
	if (d == nullptr) { return; }
	const int self = ::dirfd(d);
	/* NOLINT(concurrency-mt-unsafe)：readdir 的不安全判据指「同一 DIR 流被并发
	 * 遍历」；d 是本函数局部句柄，每次 spawn 各建各的，无共享 */
	while (struct dirent* e = ::readdir(d) ) {	/* NOLINT(concurrency-mt-unsafe) */
		const int fd = ::atoi(e->d_name);
		if (fd < 3 || fd == self) { continue; }
		const int flags = ::fcntl(fd, F_GETFD);
		if (flags >= 0) { ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC); }
	}
	::closedir(d);
}

/* 子进程 exec 前吊销继承来的 fd（≥3）。
 * HAL 侧已给每个器件句柄加 O_CLOEXEC，但宿主不知道来源的句柄同样会被
 * /bin/sh 继承：第三方 Lua 驱动自己 open 的 fd。
 * 子 shell 一旦拿到绑定 /dev/i2c-1 的 fd，模型驱动的命令就能直接 ioctl 拨动
 * 硬件——而且是在 robot->deactivate() 之后依然有效，「关掉机器人就安全」这条
 * 预期会落空。故在子进程侧再兜一层，不依赖调用方是否守规矩。
 * close_range(2)（Linux ≥ 5.9）一次系统调用给 [3, UINT_MAX] 全部打上
 * CLOSE_RANGE_CLOEXEC：只打标志不真关，0/1/2 已 dup2 到管道，其余留到 exec
 * 由内核关闭，语义与 O_CLOEXEC 一致。不可用时退化到逐个 close。
 * 两条路径都在 fork 之后、exec 之前，且**不分配堆内存**：本进程有守护线程会
 * 并发 fork，子进程里 malloc 可能撞上父进程持有且永不会释放的锁。
 * 该 flags **必须是 CLOSE_RANGE_CLOEXEC = 1U<<2 = 4**（2026-09-21 审计 AG-3）：
 * 它是位掩码，传未定义的位（旧实现写的 1U）内核直接 EINVAL，于是每次
 * run_command 都白跑一遍退化循环——soft limit 高的机器上约 40ms（实测
 * soft=524288），而注释却写着「一次系统调用」。安全结论不受影响（退化路径是
 * 真 close，比只打标志更强，且父进程侧 markAllFdsCloexec 独立承重），
 * 但「注释声称的路径从未执行」正是最难发现的一类缺陷。 */
/* 子进程侧路径自报（2026-09-21 审计 AG-11）。
 *
 * 为什么需要它：`revokeInheritedFds` / `execShellChild` 在 gcov 报告里**恒为 0%**，
 * 而且这不是「没测」而是「测了测不到」——gcov 计数在进程退出时落盘，而这两个函数
 * 永远以 execve 结束：exec 用新映像的计数页覆盖当前进程，子侧的执行记录不可能被
 * 写出。AG-3（CLOSE_RANGE_CLOEXEC 标志写成 1U、快速路径从未执行）在这个盲区里
 * 藏了很久，因为该区块对所有读者都显示 0%，所有人都以为「那是有意不测的部分」。
 *
 * 解法是不再试图测量它，而是让它**自己报告**选了哪条路径：在 fork 之后、exec 之前
 * 把一行文本写进父进程打开并传入的 fd。约束与 execShellChild 一致——不分配堆内存、
 * 只用栈上缓冲与 write(2)；fd 无效时静默跳过（该探针绝不能影响真实执行路径）。
 * 读取端只在测试里设置 BOT4CJ_TRACE_FDS（见 test_agenttools.cpp 的 AG-11 用例），
 * 不设时 path 为空、全程零开销。 */
/* fd 由调用方经参数传入而**不是**用静态量：宿主有守护线程会并发 fork/exec，
 * 静态量会被并发 run_command 互相踩（一个线程改、另一个线程的子进程读）。 */
void traceChildPath(int traceFd, const char* path) {
	if (traceFd < 0 || path == nullptr) { return; }
	char buf[64];
	int n = 0;
	for (const char* p = path; *p != '\0' && n < static_cast<int>(sizeof buf) - 2; ++p) {
		buf[n++] = *p;
	}
	buf[n++] = '\n';
	ssize_t ignored = ::write(traceFd, buf, static_cast<std::size_t>(n));
	(void)ignored;
}

void revokeInheritedFds(int traceFd) {
#ifdef SYS_close_range
	/* 取值来自内核 UAPI（linux/close_range.h：1U << 2）。不引头文件而写字面量，
	 * 是为了兼容没装新头文件的老发行版；该常量自 5.9 起未变，且下面有「失败即
	 * 退化」兜底——取值错也不会破功能，只会在性能上退化，正是修复前的状态。 */
	constexpr unsigned kCloseRangeCloexec = 1U << 2;
	/* 自报放在**调用之前**：无论成败都记录「尝试了快速路径」，退化路径再记一条。
	 * 两条都记才能分辨「快速路径没走」与「快速路径走了但失败」——AG-3 正是前者。 */
	traceChildPath(traceFd, "close_range-attempt");
	if (::syscall(SYS_close_range, 3U, ~0U, kCloseRangeCloexec) == 0) {
		traceChildPath(traceFd, "close_range-ok");
		return;
	}
	traceChildPath(traceFd, "close_range-failed");
#else
	traceChildPath(traceFd, "close_range-unavailable");
#endif
	/* 退化路径（内核 < 5.9 或 close_range 不可用）：按真实上限逐个关。
	 * （审计 P1 修复，2026-09-21）旧实现固定封顶 4096——soft limit 更高的
	 * 进程（容器常见 1048576）里编号 ≥4096 的继承 fd 不会被覆盖，模型驱动
	 * 的 shell 可能拿到硬件/内部 socket 句柄。现在取 RLIMIT_NOFILE 软上限；
	 * 仍保留绝对封顶 1048576：无上限 rlim（或极端配置）时这段循环最多百万
	 * 次 close 系统调用（fork/exec 一次性路径，代价可接受），超过封顶的
	 * 极端配置属残余已知缺口（且父进程侧 markAllFdsCloexec 已按实际打开
	 * 的 fd 覆盖，本循环只兜「枚举之后新开」的窗口）。 */
	long max = 1048576;
	struct rlimit rl{};
	if (::getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY
		&& static_cast<long>(rl.rlim_cur) < max) {
		max = static_cast<long>(rl.rlim_cur);
	}
	traceChildPath(traceFd, "fallback-close-loop");
	for (long fd = 3; fd < max; ++fd) { ::close(static_cast<int>(fd)); }
}

/* 子进程侧：独立进程组 + 按 spec 摆好 0/1/2 + 按 spec 吊销继承 fd。
 * **本函数不返回**：成功即 execle 成 /bin/sh，任何失败 _exit(127)。
 * 约束与既有的两道防线一致——fork 之后 **不分配堆内存**（宿主有守护线程会并发
 * fork，子进程里 malloc 可能撞上父进程持有且永不会释放的锁），只用已就绪的
 * 参数与栈上缓冲。
 * fd 收尾顺序有讲究：先把 0/1/2 指向目标，再关掉继承来的管道端，最后才
 * revokeInheritedFds——它会把 ≥3 的全部句柄打上/直接关闭，早跑会把 0/1/2
 * 之外刚 dup 好的东西也一起带走。 */
[[noreturn]] void execChild(const ChildSpec& spec, int stdinR, int outR, int outW, int errR,
		int errW, char* const* envp) {
	setpgid(0, 0);	/* 独立进程组：超时/中断可整组终止（含孙进程） */
	if (spec.pipeStdin) {
		if (::dup2(stdinR, STDIN_FILENO) < 0) { _exit(127); }
		/* 原读端已 dup 到 fd 0；显式关掉，不等 exec 时的 O_CLOEXEC——关掉之后
		 * 父进程侧写端能在子进程退出时更早看到 EPIPE。 */
		if (stdinR != STDIN_FILENO) { ::close(stdinR); }
	} else {
		/* fix-plan 3-1：stdin 重定向到 /dev/null——子命令不再与主进程（agent REPL）
		 * 抢终端输入；打开失败按 fail-closed 直接放弃执行（127）。 */
		int devnull = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
		if (devnull < 0) { _exit(127); }
		::dup2(devnull, STDIN_FILENO);
		if (devnull != STDIN_FILENO) { ::close(devnull); }
	}
	if (spec.captureOutput) {
		::dup2(outW, STDOUT_FILENO);
		::dup2(errW, STDERR_FILENO);
		::close(outR);
		::close(outW);
		::close(errR);
		::close(errW);
	}
	if (spec.revokeFds) { revokeInheritedFds(spec.traceFd); }	/* 必须在 dup2 之后 */
	::execle("/bin/sh", "sh", "-c", spec.cmd.c_str(), static_cast<char*>(nullptr), envp);
	_exit(127);
}

} // namespace agent
} // namespace bot

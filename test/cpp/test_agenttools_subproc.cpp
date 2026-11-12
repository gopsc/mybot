/* test_agenttools_subproc.cpp —— 子进程机器与动作脚本预算
 *
 * 自 test_agenttools.cpp 拆出（2026-10-01，行为保持）：整组终止（AG-6）、
 * 子进程路径自报/fd 回收（AG-11）、动作脚本预算三态，与 reap 机器；
 * runWithDeadline 反向验证夹具随迁。 */

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <sys/wait.h>
#include <system_error>
#include <vector>
#include <unistd.h>

#include "agent_subprocess.hpp"
#include "agentdispatch.hpp"
#include "agentproto.hpp"
#include "agenttools.hpp"
#include "jsonparse.hpp"
#include "luaend.hpp"
#include "luaexec.hpp"
#include "luavar.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_utf8.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "agenttools_fixtures.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;

using fx::ModulePathGuard;
using fx::TempDir;
using afx::execText;
using afx::makeRelayRobot;
using afx::readAll;
using afx::writeFile;
/* ---- AG-6：run_command 的超时 / 整组终止必须有有效断言 ----
 * 背景（2026-09-21 审计 AG-6）：唯一的超时用例只 grep「超时」文案，不看
 * exit_code、不检查进程是否真死、**没有任何孙进程用例**——于是「整组 SIGKILL
 * 失效」这种失效形态在守门里完全不可见（kill 用 -pid 是整组终止的实现前提，
 * 但没人钉住它）。
 * 下列用例把「整组终止」变成可观测断言：让**同组**孙进程持续输出，超时返回后
 * 断言宿主没有被拖到硬上限（有后代吊着管道写端才会），并断言输出已停止增长。 */

namespace {

long long fileSize(const std::string& path) {
	std::error_code ec;
	const auto n = fs::file_size(path, ec);
	return ec ? -1 : static_cast<long long>(n);
}

std::string readText(const std::string& path) {
	std::ifstream f(path);
	if (!f) { return ""; }
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

} // namespace

/* 超时 → 整组终止：孙进程必须一起死，且返回码/标记/耗时都要对得上。
 *
 * 为什么需要这条（2026-09-21 审计 AG-6）：原用例只 grep「超时」文案，不看
 * exit_code、不检查子进程是否真死、**没有任何孙进程用例**——而 kill(-pid) 的
 * 「整组」正是超时语义的实现前提，此前没有任何断言钉住它。
 *
 * 构造：子 shell 用 `( ... ) &` 起一个后台孙进程；它登记自己的 pid 后持续追加
 * 输出。`( ) &` 起的后代留在子 shell 的进程组里，**只会被整组终止覆盖**，
 * 单个 pid 的 kill 管不到它。
 *
 * 判据：输出在超时返回后必须停止增长（间隔 1s 两次测文件大小）。不用
 * kill(pid,0) 判活——僵尸对它仍返回 0，会得到假阳性（见文件末尾的说明）。 */
TH_TEST(agenttools_run_command_timeout_kills_whole_process_group) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const fx::TempDir dir("timeout_pg");
	const fs::path pidFile = dir.path() / "gc.pid";
	const fs::path outFile = dir.path() / "gc.out";
	const std::string q = dir.path().string();

	/* 孙进程：先登记 pid，再把**自己的 stdout/stderr 重定向到 /dev/null**，
	 * 然后持续往文件追加输出。
	 * 重定向这一步是本用例确定性的关键：run_command 的子 shell 死后，孙进程若
	 * 还持有继承来的管道写端，它的下一次写会撞 EPIPE → 默认 SIGPIPE 终止——
	 * 于是「孙进程是否还活着」会被这个副作用掩盖（第一版就因此只观察到
	 * hardStopped 一条判据）。重定向后它与管道无关，活着的唯一表现就是文件继续
	 * 变大，判据因此是确定的。 */
	const std::string cmd = "sh -c '(printf %s $$ > " + q + "/gc.pid; "
		"exec >/dev/null 2>&1; "
		"while :; do echo xxxxxxxxxxxxxxxx >> " + q + "/gc.out; sleep 0.02; done) &' ; sleep 30";

	const auto t0 = std::chrono::steady_clock::now();
	RunResult r = runShell(cmd, 1);
	const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();

	TH_CHECK(r.timedOut);
	TH_CHECK(r.exitCode == -1);		/* 被信号杀死 → -1，不是某个退出码 */

	/* 孙进程确实登记过（否则本用例没测到东西） */
	const std::string pidText = readText(pidFile.string());
	TH_CHECK_MSG(!pidText.empty(), "孙进程未登记 pid，用例无效");
	const pid_t gp = static_cast<pid_t>(std::strtol(pidText.c_str(), nullptr, 10));
	TH_CHECK(gp > 1);

	/* 核心断言：整组终止必须让两个流都 EOF，runShell 在 1s 超时后立即返回。
	 * 走到硬上限（超时 + 3s）说明**有后代吊着管道写端**——正是「只 kill 直接
	 * 子进程、漏掉同组孙进程」的指纹（反向验证过：把 kill(-pid) 改成 kill(pid)
	 * 后这里立刻红，且失败信息指向「整组 kill 没能让管道 EOF」）。 */
	TH_CHECK_MSG(!r.hardStopped,
		"超时路径触发了硬上限兜底（说明整组 kill 没能让管道 EOF，"
			"通常意味着有同组后代仍在运行）");

	/* 第二判据（已重定向管道，故它是确定的）：整组终止后孙进程应已消失，
	 * 文件不再变大；单 pid kill 时它会一直在写。 */
	const long long size1 = fileSize(outFile);
	TH_CHECK_MSG(size1 > 0, "孙进程未产出内容，用例无效");
	::usleep(1000 * 1000);
	const long long size2 = fileSize(outFile);
	TH_CHECK_MSG(size1 == size2,
		"孙进程 " + std::to_string(gp) + " 仍在输出（" + std::to_string(size1)
			+ " → " + std::to_string(size2) + " 字节）：超时未终止整个进程组");
	/* 远小于 sleep 30，说明确实提前中止 */
	TH_CHECK_MSG(elapsedMs < 8000, "耗时 " + std::to_string(elapsedMs) + "ms");
}

/* 超时标记与文案一致：模型看到的回执必须说明「超时，已终止」，且带退出码 */
TH_TEST(agenttools_run_command_timeout_receipt_is_actionable) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"sleep 30\",\"timeout_seconds\":1}"));
	TH_CHECK(out.find("exit_code=-1") != std::string::npos);
	TH_CHECK(out.find("超时") != std::string::npos);
	/* 正常超时不该出现硬上限那句（两者是不同的失效语义） */
	TH_CHECK(out.find("硬上限") == std::string::npos);
}

/* 已知边界（不在本文件里做断言）：若孙进程自行 setsid 脱离进程组，整组 kill
 * 按定义覆盖不到它，它会活到被 SIGPIPE 或自身超时收走。曾尝试用 setsid 用例把
 * 这条钉住，但判据不稳：它登记 pid 需要约几十毫秒，而短超时下 runShell 可能先
 * 返回——未登记就会脏失败。真实的收口手段是「不给子进程留下会自行 setsid 的
 * 脚本」+ 文档如实声明（docs/agent.md），而不是一条易碎的测试。 */

/* AG-10：放弃回收必须响亮（告警文案单点）。
 *
 * 这条路径**极难在离线环境构造**（要让子进程在 2s 宽限内收不回来，得让它处于
 * D 态，或让 SIGKILL 无效——后者要求 PID 1 / 受限进程；容器里本进程常是 PID 1
 * 但测试二进制不是，`trap "" KILL` 无效，实测构造不成立）。故不写易碎的行为
 * 用例，改为钉住「说了什么」：文案必须给出 pid、宽限时长与「会留僵尸」的后果。
 * 静默的危害是操作者不知道发生过什么，这三点正是他需要的信息。 */
TH_TEST(agenttools_reap_give_up_warning_is_informative) {
	const std::string w = reapGiveUpWarning(4242, 2000);
	TH_CHECK_MSG(w.find("4242") != std::string::npos, "告警未给出 pid：" + w);
	TH_CHECK_MSG(w.find("2000") != std::string::npos, "告警未给出宽限时长：" + w);
	TH_CHECK_MSG(w.find("僵尸") != std::string::npos, "告警未说明后果（僵尸）：" + w);
	TH_CHECK_MSG(w.find("未回收") != std::string::npos, "告警未说明发生了什么：" + w);
}

/* F1（2026-09-22 审计）：有界回收的正常路径。确认程序路径原来用**无超时**
 * waitpid 回收（kill 未生效时永久挂死 agent 会话），修复后两个调用点共用
 * reapWithGrace；这里直接钉住它的成功路径与状态折算。 */
TH_TEST(agenttools_reap_with_grace_collects_exited_child) {
	pid_t pid = fork();
	/* 子进程必须先于任何断言返回：harness 的计数/打印是进程内的，子进程若继续
	 * 往下跑，会把「pid==0」当成断言失败打出来（实测踩过：日志里混进一条
	 * 「fork 失败」，父进程其实一切正常）。 */
	if (pid == 0) {
		::usleep(50 * 1000);	/* 让父进程真正进到轮询分支 */
		_exit(7);
	}
	TH_CHECK_MSG(pid > 0, "fork 失败");
	int status = 0;
	const bool ok = reapWithGrace(pid, status, 2000);
	TH_CHECK_MSG(ok, "子进程在宽限内退出，应被回收");
	TH_CHECK(WIFEXITED(status));
	TH_CHECK_MSG(WEXITSTATUS(status) == 7, "回收到的退出码不对");
}

/* F1 的另一半：waitpid 报 ECHILD（子进程已被别的回收者收走，宿主里存在
 * SIGCHLD 处理器的场景）时必须**立即**返回 false——若在这儿把宽限耗满，
 * 「有界回收」就只是把无界等待换成了 2s 的无谓等待。 */
TH_TEST(agenttools_reap_with_grace_returns_immediately_on_echild) {
	pid_t pid = fork();
	if (pid == 0) { _exit(0); }	/* 子进程不碰 harness（见上） */
	TH_CHECK_MSG(pid > 0, "fork 失败");
	int status = 0;
	TH_CHECK_MSG(::waitpid(pid, &status, 0) == pid, "先收走子进程（模拟已被回收）");

	const auto t0 = std::chrono::steady_clock::now();
	const bool ok = reapWithGrace(pid, status, 2000);
	const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();
	TH_CHECK_MSG(!ok, "确已无可回收时应返回 false");
	TH_CHECK_MSG(ms < 500,
		"ECHILD 应立即返回，实测 " + std::to_string(ms) + "ms（宽限 2000ms）");
}

/* ---- AG-11：子进程路径自报（fork/exec 区块的行为断言）----
 * 背景：agent_subprocess.cpp 的 execChild / revokeInheritedFds 在 gcov 报告
 * 里**恒为 0%**，而且不是「没测」而是「测了测不到」——gcov 计数在进程退出时落盘，
 * 而这两个函数永远以 execve 结束（exec 用新映像的计数页覆盖当前进程）。AG-3
 * （CLOSE_RANGE_CLOEXEC 标志写成 1U、快速路径从未执行）正藏在这个盲区里藏了很久：
 * 该区块对所有读者都显示 0%，所有人都当它是「有意不测的部分」。
 *
 * 本用例不再试图测量它，而是让它**自己报告**：子进程在 fork 后、exec 前把走了哪条
 * 路径写进 BOT4CJ_TRACE_FDS 指定的文件，父进程读出来断言。这条断言**本来就能抓住
 * AG-3**：标志写错时 "close_range-ok" 永远不会出现，只会留下
 * "close_range-attempt" + "close_range-failed" + "fallback-close-loop"。 */
TH_TEST(agenttools_child_side_fd_revocation_reports_its_path) {
	const fx::TempDir dir("trace_fds");
	const fs::path trace = dir.path() / "trace.txt";

	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(::setenv("BOT4CJ_TRACE_FDS", trace.string().c_str(), 1) == 0);
	const std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"echo traced\",\"timeout_seconds\":5}"));
	::unsetenv("BOT4CJ_TRACE_FDS");	/* 别影响后续用例 */

	TH_CHECK_MSG(out.find("traced") != std::string::npos, "命令应正常执行: " + out);

	const std::string traceText = readText(trace.string());
	TH_CHECK_MSG(!traceText.empty(),
		"子进程没有写出路径自报（BOT4CJ_TRACE_FDS 未生效？）");

	/* 必然出现「尝试过快速路径」这一条 */
	TH_CHECK_MSG(traceText.find("close_range-attempt") != std::string::npos,
		"未记录快速路径尝试，实际: " + traceText);

	/* 核心断言：本机内核 ≥5.9（syscall 存在）→ 必须真的走通快速路径。
	 * 修复 AG-3 之前这里是 "close_range-failed" + "fallback-close-loop"。 */
	const bool haveCloseRange = traceText.find("close_range-unavailable") == std::string::npos;
	if (haveCloseRange) {
		TH_CHECK_MSG(traceText.find("close_range-ok") != std::string::npos,
			"快速路径未成功（标志写错？）实际轨迹: " + traceText);
		TH_CHECK_MSG(traceText.find("fallback-close-loop") == std::string::npos,
			"不该同时走退化循环，实际轨迹: " + traceText);
	}

	/* 自报是「辅助证据」，真正的安全语义由既有防泄漏用例钉住——这里再确认一次 */
	TH_CHECK(out.find("exit_code=0") != std::string::npos);
}

/* 退化路径也要可达且正确：把 close_range 的失败路径逼出来（用非法标志不可控），
 * 改为断言「两条路径互斥」——轨迹里至多出现一条终态标记。 */
TH_TEST(agenttools_child_side_trace_is_mutually_exclusive) {
	const fx::TempDir dir("trace_excl");
	const fs::path trace = dir.path() / "trace.txt";

	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	TH_CHECK(::setenv("BOT4CJ_TRACE_FDS", trace.string().c_str(), 1) == 0);
	/* 跑两次：确认追加写入、且每次都是完整的一次二选一 */
	execText(tools, "run_command", parseJson("{\"command\":\"true\",\"timeout_seconds\":5}"));
	execText(tools, "run_command", parseJson("{\"command\":\"true\",\"timeout_seconds\":5}"));
	::unsetenv("BOT4CJ_TRACE_FDS");

	const std::string t = readText(trace.string());
	std::size_t ok = 0, loop = 0, pos = 0;
	while ((pos = t.find("close_range-ok", pos)) != std::string::npos) { ++ok; pos += 1; }
	pos = 0;
	while ((pos = t.find("fallback-close-loop", pos)) != std::string::npos) { ++loop; pos += 1; }
	TH_CHECK_MSG(ok + loop >= 2, "两次 run_command 应留下至少两条终态标记，实际: " + t);
	TH_CHECK_MSG(!(ok > 0 && loop > 0),
		"两条路径不该同时出现（同一内核上二选一），实际: " + t);
}

/* ==================== PL-2（2026-09-22）：动作脚本执行预算 ====================
 * run_action_script 曾是本工具集里**唯一没有任何上界**的执行路径（有超时的
 * run_command 反而默认关闭）。脚本本身是线性矩阵、DSL 无循环，所以挂死只可能
 * 来自 Lua 驱动自己的 call()。夹具 InfiniteLoopDriver 的 call() 永不返回。
 *
 * 用例必须自己带超时（fork + alarm）——**反向验证要求它真的会挂死**：
 * 若哪天预算机制失灵，进程会卡在这里而不是报一个可以忽略的失败。
 * 用 fork 而不是线程：挂死的是子进程，父测试进程照常给出判定。 */
static bool runWithDeadline(std::function<void()> fn, int timeoutSec, int* outSignal) {
	pid_t pid = ::fork();
	if (pid < 0) { throw std::runtime_error("fork 失败"); }
	if (pid == 0) {
		::alarm(static_cast<unsigned>(timeoutSec));
		try { fn(); } catch (...) { ::_exit(3); }
		::_exit(0);
	}
	int status = 0;
	if (::waitpid(pid, &status, 0) < 0) { throw std::runtime_error("waitpid 失败"); }
	if (WIFSIGNALED(status)) {
		if (outSignal != nullptr) { *outSignal = WTERMSIG(status); }
		return false;	/* 被 alarm 杀掉 = 超时挂死 */
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* 预算生效：死循环驱动在预算内以「点名预算」的失败文案返回，进程不崩、会话不脏。 */
TH_TEST(agenttools_action_script_budget_aborts_runaway_driver) {
	TempDir tmp("budget");
	/* 结构脚本挂一个假驱动；动作脚本一行即可触发它的死循环 call() */
	fs::path sqlFile = tmp.path() / "loop.sql";
	writeFile(sqlFile,
		"CREATE TABLE InfiniteLoopDriver (name String, looping String);\n"
		"INSERT INTO InfiniteLoopDriver (name, looping) VALUES ('loop0', 'busy');\n");
	fs::path mtFile = tmp.path() / "loop.mt";
	writeFile(mtFile, "@Action\nloop0.x;\n   1;\n@\n");

	ModulePathGuard guard("./modules:test/cpp");
	int sig = 0;
	const bool finished = runWithDeadline([&] {
		MemoryReader reader(readAll(sqlFile.string()));
		RobotStruct robot(reader);
		robot.active();
		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.scriptsDir = tmp.path().string();
		ctx.scriptTimeoutSec = 1;	/* 1 秒预算，用例无需等待缺省的 180s */
		AgentToolRegistry tools = makeAgentTools(ctx);
		const AgentToolResult res = tools.execute("run_action_script", parseJson("{\"script\":\"loop.mt\"}"));
		/* 预算耗尽 → 失败文案且点名，而不是「已执行」 */
		const bool named = res.text.find(kLuaExecBudgetMarker) != std::string::npos;
		robot.deactivate();
		::_exit(named ? 0 : 4);
	}, 30, &sig);

	TH_CHECK_MSG(finished, "预算未生效：死循环驱动把进程挂死了（signal=" + std::to_string(sig) + "）");
}

/* 反向对照：budget<=0 = 明确关闭 → 同一脚本**确实**挂死（证明上一条不是在测别的东西）。
 * 这条用例本身就说明「关闭预算是危险开关」，所以它必须有超时兜住。 */
TH_TEST(agenttools_action_script_budget_off_really_hangs) {
	TempDir tmp("nobudget");
	fs::path sqlFile = tmp.path() / "loop.sql";
	writeFile(sqlFile,
		"CREATE TABLE InfiniteLoopDriver (name String, looping String);\n"
		"INSERT INTO InfiniteLoopDriver (name, looping) VALUES ('loop0', 'busy');\n");
	fs::path mtFile = tmp.path() / "loop.mt";
	writeFile(mtFile, "@Action\nloop0.x;\n   1;\n@\n");

	ModulePathGuard guard("./modules:test/cpp");
	int sig = 0;
	const bool finished = runWithDeadline([&] {
		MemoryReader reader(readAll(sqlFile.string()));
		RobotStruct robot(reader);
		robot.active();
		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.scriptsDir = tmp.path().string();
		ctx.scriptTimeoutSec = 0;	/* PL-2：0 = 不武装，退化为此前行为 */
		AgentToolRegistry tools = makeAgentTools(ctx);
		tools.execute("run_action_script", parseJson("{\"script\":\"loop.mt\"}"));
		robot.deactivate();
		::_exit(0);
	}, 3, &sig);

	TH_CHECK_MSG(!finished && sig == SIGALRM,
		"关闭预算后本用例应挂死到 alarm 触发（signal=" + std::to_string(sig) + "）");
}

/* 窗口收口：预算只在工具调用期间存在。工具返回后，同一进程内再跑一个正常脚本
 * 必须照常成功（说明钩子已摘、JIT 已恢复、thread_local 指针已清）。 */
TH_TEST(agenttools_action_script_budget_window_is_scoped) {
	TempDir tmp("scoped");
	fs::path sqlFile = tmp.path() / "ok.sql";
	writeFile(sqlFile,
		"CREATE TABLE InfiniteLoopDriver (name String, looping String);\n"
		"INSERT INTO InfiniteLoopDriver (name, looping) VALUES ('loop0', 'ok');\n");
	fs::path mtFile = tmp.path() / "ok.mt";
	writeFile(mtFile, "@Action\nloop0.x;\n   1;\n@\n");

	ModulePathGuard guard("./modules:test/cpp");
	MemoryReader reader(readAll(sqlFile.string()));
	RobotStruct robot(reader);
	robot.active();
	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.scriptsDir = tmp.path().string();
	ctx.scriptTimeoutSec = 5;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const AgentToolResult first = tools.execute("run_action_script", parseJson("{\"script\":\"ok.mt\"}"));
	TH_CHECK_MSG(first.text.find("已执行") != std::string::npos, first.text);
	/* 窗口已退出：预算指针必须已清（否则窗口外的 Lua 执行会莫名其妙被计时/中断） */
	TH_CHECK_MSG(bot::luaExecBudget() == nullptr, "工具返回后预算指针未清空");
	/* 再来一次仍然可用（钩子摘干净、JIT 复原，没有把状态机留在半残状态） */
	const AgentToolResult second = tools.execute("run_action_script", parseJson("{\"script\":\"ok.mt\"}"));
	TH_CHECK_MSG(second.text.find("已执行") != std::string::npos, second.text);
	robot.deactivate();
}

/* ============ SAN-8②：参数错误与执行失败必须分开（口径修正） ============
 * 缺陷形态（已实测）：requireString(args,"script") 原先在**执行用的 try 之内**，
 * 于是模型漏传 script 时收到「动作脚本执行失败 []: 缺少字符串参数 script」——
 * 而该工具的描述里写着「报错时机器人状态**可能停在半途**」（见工具定义）。
 * 模型据此以为可能发生了物理后果，实际什么都没跑。
 *
 * 这条用例走**派发漏斗**（DispatchGate）而不是 AgentToolRegistry::execute：
 * 真实路径上参数解析失败由 DispatchGate 折成「工具参数错误: …」，
 * 用注册表直接调会得到另一句泛化文案，测不到模型实际看到的那句。 */
TH_TEST(agenttools_run_action_script_missing_arg_is_not_reported_as_execution_failure) {
	auto robot = makeRelayRobot();

	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.scriptsDir = "scripts";
	AgentToolRegistry tools = makeAgentTools(ctx);
	DispatchGate gate(tools, nullptr, nullptr);

	/* ① 缺参数：必须是"参数错误"，且**不得**出现"执行失败"/"停在半途"口径 */
	AgentToolResult noArg = gate.run(ToolCall{"c1", "run_action_script", "{}"}, 0);
	TH_CHECK_MSG(noArg.text.find("工具参数错误") != std::string::npos,
		"缺参数应报工具参数错误，实际: " + noArg.text);
	TH_CHECK_MSG(noArg.text.find("缺少字符串参数 script") != std::string::npos,
		"应点名缺哪个参数，实际: " + noArg.text);
	TH_CHECK_MSG(noArg.text.find("执行失败") == std::string::npos,
		"参数错误不得说成执行失败，实际: " + noArg.text);
	TH_CHECK(noArg.ok == false);
	/* executed=false：没派发（SAN-4 据此不做"副作用已发生"的降级改写） */
	TH_CHECK(noArg.executed == false);

	/* ② 参数类型不符：同样走参数错误口径（requireString 抛
	 * IllegalArgumentException，注册表按**异常类型**原样上抛，DispatchGate 折成
	 * 工具参数错误） */
	AgentToolResult badType = gate.run(
		ToolCall{"c2", "run_action_script", "{\"script\":42}"}, 0);
	TH_CHECK_MSG(badType.text.find("工具参数错误") != std::string::npos,
		"类型不符应报工具参数错误，实际: " + badType.text);
	TH_CHECK(badType.executed == false);

	/* ②b vars 参数错误同样走"参数错误"口径（parseVarsObject 在 try 之外抛
	 * IllegalArgumentException）：非对象、键非安全标识符、值类型不符——都不得
	 * 被说成"执行失败/停在半途"，因为它们发生在派发之前。 */
	AgentToolResult varsNotObj = gate.run(
		ToolCall{"c2a", "run_action_script", "{\"script\":\"relay-test.mt\",\"vars\":42}"}, 0);
	TH_CHECK_MSG(varsNotObj.text.find("工具参数错误") != std::string::npos,
		"vars 非对象应报工具参数错误，实际: " + varsNotObj.text);
	TH_CHECK(varsNotObj.executed == false);

	AgentToolResult varsBadKey = gate.run(
		ToolCall{"c2b", "run_action_script",
		"{\"script\":\"relay-test.mt\",\"vars\":{\"a.b\":1}}"}, 0);
	TH_CHECK_MSG(varsBadKey.text.find("工具参数错误") != std::string::npos,
		"vars 键非安全标识符应报工具参数错误，实际: " + varsBadKey.text);
	TH_CHECK(varsBadKey.executed == false);

	AgentToolResult varsBadVal = gate.run(
		ToolCall{"c2c", "run_action_script",
		"{\"script\":\"relay-test.mt\",\"vars\":{\"ms\":true}}"}, 0);
	TH_CHECK_MSG(varsBadVal.text.find("工具参数错误") != std::string::npos,
		"vars 值类型不符应报工具参数错误，实际: " + varsBadVal.text);
	TH_CHECK(varsBadVal.executed == false);

	/* ③ 对照：**真的执行失败**（脚本不存在）仍须是"执行失败"口径，
	 * 且 executed=true——脚本可能跑到一半，机器人可能停在半途，
	 * 这个警告必须留给模型（方向相反的谎报同样不可接受）。 */
	AgentToolResult missing = gate.run(
		ToolCall{"c3", "run_action_script", "{\"script\":\"no-such.mt\"}"}, 0);
	TH_CHECK_MSG(missing.text.find("动作脚本执行失败") != std::string::npos,
		"脚本不存在应报执行失败，实际: " + missing.text);
	TH_CHECK(missing.executed == true);

	robot->deactivate();
}

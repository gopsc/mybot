#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

#include <sys/prctl.h>
#include <unistd.h>

#include "actionsource.hpp"
#include "cliargs.hpp"
#include "daemonvar.hpp"	/* abandonedDaemonCount（2.2 后不再经 robot.hpp 传导） */
#include "robot_application.hpp"
#include "robot.hpp"
#include "util_cli.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_num.hpp"

namespace bot {

/* ---- D4：SIGINT/SIGTERM 处理器——首次仅置停止标志（async-signal-safe），
 * 让主流程走正常 deactivate（驱动 destroy / 守护停机）后再退出。
 * 第二次升级为强杀：跳过清理，是逃生口，不是推荐操作。 */
extern "C" void onStopSignal(int sig) {
	bot::stopRequested().store(true);
	static volatile sig_atomic_t hits = 0;
	if (++hits >= 2) {
		::signal(sig, SIG_DFL);
		::raise(sig);
	}
}

/* ---- 进程自护：PR_SET_DUMPABLE=0 ----
 * 本进程内存里可能有敏感配置。non-dumpable 让同 UID 的非特权进程
 * ptrace / 读 /proc/<pid>/mem 被拒，崩溃也不落 core（core 里就是整份内存）。
 * BOT4CJ_ALLOW_PTRACE=1 供调试显式放开；sanitizer 构建跳过。 */
void hardenAgainstInspection() {
#ifdef MYBOT_SANITIZE_BUILD
	return;
#else
	if (auto allow = getEnvVar("BOT4CJ_ALLOW_PTRACE"); allow && *allow == "1") {
		std::cerr << "注意: BOT4CJ_ALLOW_PTRACE=1，本进程保持可被同 UID ptrace / core dump"
			"（仅调试用；口令可自内存读出）" << std::endl;
		return;
	}
	if (::prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) {
		std::cerr << "警告: prctl(PR_SET_DUMPABLE, 0) 失败（" << errnoText(errno)
			<< "）；同 UID 进程可 ptrace 本进程 / 崩溃会落 core" << std::endl;
	}
#endif
}

/* 结构脚本装载（友好报错 + 字节上限）；失败已打印，返回 nullptr */
std::unique_ptr<RobotStruct> loadStructure(const std::string& rpath) {
	std::unique_ptr<Reader> fstream;
	{
		auto f = std::make_unique<FileReader>(rpath);
		if (!f->good()) {
			std::cerr << "无法打开结构脚本 '" << rpath << "'" << std::endl;
			std::cerr << "请确认 --robot 指向存在的结构脚本，示例："
				"mybot --robot=robots/relay-test.sql --input=scripts/relay-test.mt"
				<< std::endl;
			return nullptr;
		}
		fstream = std::make_unique<LimitedReader>(
			std::move(f), kMaxScriptBytes, "structure script");
	}

	try {
		return std::make_unique<RobotStruct>(*fstream);
	} catch (const std::exception& e) {
		std::cerr << "结构脚本解析失败 '" << rpath << "': " << e.what() << std::endl;
		std::cerr << "无硬件自检链路：mybot --robot=robots/relay-test.sql "
			"--input=scripts/relay-test.mt" << std::endl;
		return nullptr;
	}
}

/* --daemon-grace-ms 解析与校验（全局选项）。空串 = 用缺省值。 */
bool applyDaemonGraceMs(const std::string& raw, RobotStruct& robot) {
	if (raw.empty()) { return true; }
	auto [state, value] = parseLongStrict(raw);
	if (state != IntParse::OK) {
		std::cerr << "选项 --daemon-grace-ms 需要一个整数，实际是 '" << raw << "'" << std::endl;
		return false;
	}
	if (value < daemon_limits::kGraceMsMin || value > daemon_limits::kGraceMsMax) {
		std::cerr << rangeErrorText("选项 --daemon-grace-ms",
			daemon_limits::kGraceMsMin, daemon_limits::kGraceMsMax, raw) << std::endl;
		return false;
	}
	robot.setDeactivateGraceMs(value);
	return true;
}

/* D4：安装 SIGINT/SIGTERM 处理器（仅置标志），Ctrl-C 走正常清理链 */
void installStopSignalHandlers() {
	struct sigaction sa{};
	sa.sa_handler = onStopSignal;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;	/* 不用 SA_RESTART：让 accept 等阻塞点被 EINTR 打断以便检查标志 */
	::sigaction(SIGINT, &sa, nullptr);
	::sigaction(SIGTERM, &sa, nullptr);
}

} // namespace bot

int main(int argc, char** argv) {
	using namespace bot;

	hardenAgainstInspection();	/* 启动期尽早收紧进程可检查性 */

	ParsedArgs args = parseArgs(argc, argv);
	if (args.help) {
		std::cout << helpText();
		return 0;
	}
	if (args.errorCode != 0) {
		std::cerr << args.error << std::endl;
		return args.errorCode;
	}

	CliOptions& options = args.opts;
	if (validateOptions(options) != 0) { return 2; }

	if (!options.robot) {
		std::cout << helpText();
		return 0;
	}

	std::unique_ptr<RobotStruct> robot = loadStructure(*options.robot);
	if (!robot) { return 1; }

	if (!applyDaemonGraceMs(options.daemonGraceMs, *robot)) { return 2; }

	/* @Merge/@Include 基准目录：--input 文件通道取脚本所在目录；
	 * stdin/TCP 无脚本位置，保持缺省 CWD。 */
	if (options.input) {
		std::string parent = std::filesystem::path(*options.input).parent_path().string();
		robot->setActionIncludeBaseDir(parent.empty() ? "." : parent);
	}

	installStopSignalHandlers();
	return runRobotAndCleanup(*robot, options);
}

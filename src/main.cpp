#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <fcntl.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

#include "actionsource.hpp"
#include "webshell.hpp"
#include "agentmode.hpp"
#include "mcpbackend.hpp"
#include "agent_subprocess.hpp"
#include "cliargs.hpp"
#include "robot.hpp"
#include "daemonvar.hpp"	/* abandonedDaemonCount（2.2 后不再经 robot.hpp 传导） */
#include "util.hpp"

namespace bot {

/* ---- P2a 取消哨兵（2026-09-22）----
 * 阻塞发生在 Lua 驱动的 libcurl 里，驱动沙箱拿不到宿主内存——stopRequested()
 * 这个原子标志传不过去。跨层通道用文件：首次 SIGINT 时处理器在这里创建哨兵，
 * llm_http.lua 的进度回调（约 1 秒一次）发现它存在即中止请求，模型调用因此
 * 能被 Ctrl-C **及时**打断（不再只能等满 --llm-timeout 或二次强杀）。
 * 路径经环境变量 BOT4CJ_LLM_CANCEL_FILE 交给驱动；处理器内只做 open/write/close
 * （均 async-signal-safe），路径缓冲在装处理器**之前**填好，处理器只读。 */
static char g_cancelSentinelPath[192] = {0};

void setupCancelSentinel() {
	/* M5 修复（2026-09-23）：旧路径 /tmp/mybot-cancel-<pid> 可被共享主机上其他本地
	 * 用户预测，信号处理器内 open 无 O_EXCL/O_NOFOLLOW 可被利用：攻击者预置符号
	 * 链接劫持写入目标，或预创建文件使取消增强失效。改用带随机后缀的私有路径
	 * （mkstemp 风格）+ O_EXCL|O_NOFOLLOW 防御符号链接/竞争。
	 * 随机后缀用 arc4random_uniform(100000) 避免碰撞（单个 /tmp 下极少超百个进程）。*/
	unsigned int suffix = 0;
#if defined(__APPLE__)
	// macOS 有 arc4random_uniform
	suffix = ::arc4random_uniform(100000);
#elif defined(__linux__)
	// Linux glibc 无 arc4random_uniform；用 getrandom(2)（crypto 级，失败回落 pid）
	unsigned int v = 0;
	if (::getrandom(&v, sizeof v, 0) == static_cast<ssize_t>(sizeof v)) {
		suffix = v % 100000;
	} else {
		suffix = static_cast<unsigned int>(::getpid() % 100000);
	}
#else
	// 回落：用 pid 低 5 位（不理想但胜于完全可预测）
	suffix = static_cast<unsigned int>(::getpid() % 100000);
#endif
	std::string path = "/tmp/mybot-cancel-" 
		+ std::to_string(static_cast<long>(::getpid()))
		+ "-" + std::to_string(suffix);
	std::snprintf(g_cancelSentinelPath, sizeof g_cancelSentinelPath, "%s", path.c_str());
	::setenv("BOT4CJ_LLM_CANCEL_FILE", path.c_str(), 1);
}

void removeCancelSentinel() {
	if (g_cancelSentinelPath[0] != '\0') { ::unlink(g_cancelSentinelPath); }
}

/* ---- D4：SIGINT/SIGTERM 处理器——首次仅置停止标志（async-signal-safe），
 * 让主流程走正常 deactivate（驱动 destroy / 守护停机）后再退出，
 * 避免 Ctrl-C 把舵机留在最后指令位置、I2C 从设备滞留中间态。
 * 第二次升级为强杀，见函数体注释。 */
extern "C" void onStopSignal(int sig) {
	bot::stopRequested().store(true);
	/* P2a：创建取消哨兵，让在飞的模型调用立即被 libcurl 进度回调中止。
	 * open/write/close 都是 async-signal-safe；路径缓冲已预先填好，此处只读。
	 * 打不开（/tmp 只读等）静默跳过：哨兵是「及时取消」的增强，失败时旧行为
	 * （等满超时或二次强杀）仍然成立。
	 * M5 修复：加 O_EXCL（防竞争）+ O_NOFOLLOW（防符号链接劫持）。*/
	if (g_cancelSentinelPath[0] != '\0') {
		int fd = ::open(g_cancelSentinelPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
		if (fd >= 0) {
			ssize_t ignored = ::write(fd, "cancel", 6);
			(void)ignored;
			::close(fd);
		}
	}
	/* 第二次即升级为强杀：本处理器是永久安装的，而**首次按下已经能优雅停下来**
	 * （置标志 + 取消哨兵 → 在飞的模型调用约 1s 内中止；动作脚本预算窗口内的
	 * 指令计数钩子同样看这个标志，见 src/luaexec.hpp），所以第二级的存在理由是
	 * 「**总能停下来**」这个兜底，而不是「常规停不下来」——优雅路径本身若被卡住
	 * （/tmp 不可写导致哨兵失效、驱动阻塞在不可中断的系统调用里、守护拒绝退场），
	 * 仍需要一条出路。但它会跳过 deactivate，把执行器留在带电状态：
	 * **是逃生口，不是推荐操作**。
	 * 还原缺省处置再重新触发本信号：signal/raise 均为 async-signal-safe。
	 * 计数用 sig_atomic_t；同类信号在处理器执行期间默认被屏蔽，无自竞争。 */
	static volatile sig_atomic_t hits = 0;
	if (++hits >= 2) {
		::signal(sig, SIG_DFL);
		::raise(sig);
	}
}

/* ---- 命令行解析 / 校验 / 帮助文本已迁 src/cliargs.*（可单测化）----
 * 此前它们定义在本文件里，而 main.cpp 不参与 mybot_tests 链接，CLI 面零单测。 */

/* 阶段 3 拆分：结构装载 / 两条流水线（选项校验已迁 cliargs） */

/* agent 配置组装 + key 注入进程环境 + 告警打印；失败已打印，返回 false。
 * 密钥只在进程环境里流转：驱动的参数表与 BOT4CJ_DEBUG 的参数转储都不该
 * 出现它，真正读它的是 Lua 驱动自己。
 * 注入前后各做一件事把「环境来源的密钥」这条路收口：setenv **之前**抓取 exec 时
 * 环境块里敏感变量的原始串，注入**之后**抹零——/proc/<pid>/environ 对同 UID 进程
 * 可读，只清洗子进程继承的那份（buildCleanEnvp）挡不住它读常驻宿主的这份。 */
bool prepareAgentConfig(const CliOptions& options, agent::AgentModeConfig& agentCfg) {
	std::string cfgErr;
	if (!agent::buildAgentConfig(options, agentCfg, cfgErr)) {
		std::cerr << "错误: " << cfgErr << std::endl;
		return false;
	}
	std::vector<char*> envSecrets = agent::collectEnvSecrets();
	if (!agentCfg.resolvedApiKey.empty()) {
		::setenv("BOT4CJ_LLM_KEY", agentCfg.resolvedApiKey.c_str(), 1);
	}
	agent::scrubEnvSecrets(envSecrets);
	if (!agentCfg.configPath.empty()) {
		std::cerr << "配置文件: " << agentCfg.configPath << std::endl;
	}
	/* 审计轨迹的落点如实告知（含 "-"=stderr）：审计是给事后复盘用的，
	 * 操作者应当知道它此刻是否在记、记到哪里。 */
	if (agentCfg.audit) {
		std::cerr << "审计日志: " << agentCfg.auditLogPath
			<< (agentCfg.auditLogPath == "-" ? "（stderr）" : "") << std::endl;
	}
	/* 策略钩子如实告知：命中 require_confirm 的工具每次调用都要过外部确认程序，
	 * 操作者应当知道「机器人会停下来等人/等审批」这件事正在生效。 */
	if (agentCfg.policy) {
		std::cerr << "策略钩子: " << agentCfg.policyPath
			<< "（命中 require_confirm 的工具调用需过外部确认程序）" << std::endl;
	}
	if (!agentCfg.configWarning.empty()) {
		std::cerr << agentCfg.configWarning << std::endl;
	}
	/* 密钥来源对 agent 的 shell 可见（命令行/配置文件/密钥文件）且
	 * run_command 启用时如实告警：同用户子进程没有权限壁垒。 */
	std::string keyWarn = agent::shellKeyExposureWarning(agentCfg);
	if (!keyWarn.empty()) { std::cerr << keyWarn << std::endl; }
	return true;
}

/* 结构脚本装载（友好报错 + 字节上限）；失败已打印，返回 nullptr */
std::unique_ptr<RobotStruct> loadStructure(const std::string& rpath) {
	/* 友好报错：结构脚本打不开 → 人话提示，不裸栈回溯 */
	std::unique_ptr<Reader> fstream;
	{
		auto f = std::make_unique<FileReader>(rpath);
		if (!f->good()) {
			std::cerr << "无法打开结构脚本 '" << rpath << "'" << std::endl;
			std::cerr << "请确认 --robot 指向存在的结构脚本，示例：cat scripts/std.mt | ./build/mybot --robot=robots/spider1.sql" << std::endl;
			return nullptr;
		}
		/* F-02：结构脚本与动作脚本共用同一字节上限——readSQL 先把全部
		 * token 驻留内存，不设限即「输入多大、进程就吃多大内存」。 */
		fstream = std::make_unique<LimitedReader>(std::move(f), kMaxScriptBytes, "structure script");
	}

	try {
		return std::make_unique<RobotStruct>(*fstream);
	} catch (const std::exception& e) {
		std::cerr << "结构脚本解析失败 '" << rpath << "': " << e.what() << std::endl;
		std::cerr << "无硬件自检链路：cat scripts/relay-test.mt | ./build/mybot --robot=robots/relay-test.sql" << std::endl;
		return nullptr;
	}
}

/* C++ Agent REPL已移除 - 请使用Rust Agent
 * 保留此函数签名以避免大范围修改，但实际功能已废弃 */
int runAgentPipeline(RobotStruct& robot, const agent::AgentModeConfig& agentCfg,
		std::istream& in, std::ostream& out, std::ostream& log) {
	(void)robot; (void)agentCfg; (void)in; (void)out; (void)log;
	std::cerr << "错误: C++ Agent 已移除\n";
	std::cerr << "请使用 Rust Agent:\n";
	std::cerr << "  ./agent/target/release/mybot-agent --socket /tmp/mybot.sock\n";
	std::cerr << "详见: docs/agent.md\n";
	return 2;
}

/* 动作流水线：先取动作脚本、后上电。返回退出码，异常上抛。 */
int runActionPipeline(RobotStruct& robot, const CliOptions& options) {
	/* 审计 H-2 防线：先取动作脚本、后上电。TCP 模式下 accept/口令/
	 * 读取阶段任何失败（无客户端连接、口令错、停止信号）都发生在
	 * 硬件 build 之前——不再出现「硬件已 build、带电空等客户端」；
	 * 三种输入源本就一次性读全，open 失败时 deactivate 也不会执行
	 * 任何 destroy 之外的驱动副作用。 */
	std::unique_ptr<Reader> input = openActionSource(options);
	if (!input) {
		std::cerr << "动作输入源打开失败，退出" << std::endl;
		return 1;
	}
	robot.active();
	robot.run(*input);
	return 0;
}

/* MCP 后端流水线（--mcp-backend，方案 F / 拓扑 F3）：上电 → 在主线程同步服务
 * 工具调用（阻塞直到停止信号 stopRequested）。**不注入 LLM 驱动、不发起任何
 * 模型调用**——工具集与能力门控由 runMcpBackend 内部的 makeToolContext +
 * makeAgentTools 决定（与 agent 模式同源，逐字节一致）。返回退出码，异常上抛
 * 由 runRobotAndCleanup 统一折成 1（并照常 deactivate）。 */
int runMcpBackendPipeline(RobotStruct& robot, const agent::AgentModeConfig& agentCfg,
		const CliOptions& options) {
	robot.active();
	agent::McpBackendOptions bopts;
	bopts.socketPath = options.mcpSocket;
	/* 每连接预算（评估 §3.2「预算再强制」）：cliargs 已校验为 [0,上限] 的整数，
	 * 空 = 不限（保持 0）。这里只做转换。注意这与**单次**物理调用的
	 * scriptTimeoutSec / commandTimeoutSec 是不同维度——后者始终在工具层生效。 */
	if (!options.mcpCallBudget.empty()) {
		bopts.callBudget = static_cast<long>(parseLongStrict(options.mcpCallBudget).second);
	}
	if (!options.mcpWallClock.empty()) {
		bopts.wallClockBudgetSec =
			static_cast<long>(parseLongStrict(options.mcpWallClock).second);
	}
	return agent::runMcpBackend(robot, agentCfg, bopts, std::cerr);
}

/* 未声明则注入 agent 模式的两颗驱动变量（LLM + 可选摄像头）。
 * 必须在 active() 之前——变量是在 active() 里 createHardVars 装配的；
 * 显式声明优先：脚本作者写了同名变量就照用，不重复注入。
 * injectLlm=false 用于 MCP 后端（--mcp-backend）：后端不发起模型调用，故只注入
 * 摄像头（capture_image 工具需要），不注入 LLM 驱动变量。
 * 失败已打印，返回 false。 */
bool injectAgentDrivers(RobotStruct& robot, const agent::AgentModeConfig& agentCfg,
		bool injectLlm) {
	if (injectLlm && !robot.declaresVariable(agentCfg.llmVar)) {
		try {
			robot.injectLuaDriver(agentCfg.driverTable, agentCfg.llmVar);
		} catch (const std::exception& e) {
			std::cerr << "错误: 无法注入 LLM 驱动变量: " << e.what() << std::endl;
			return false;
		}
	}
	/* 摄像头是可选外设：驱动 build 打不开设备也只记原因、不阻断上电，
	 * 抓拍时才如实报错。 */
	if (agentCfg.allowCamera && !robot.declaresVariable(agentCfg.cameraVar)) {
		try {
			robot.injectLuaDriver("Camera", agentCfg.cameraVar);
		} catch (const std::exception& e) {
			std::cerr << "错误: 无法注入摄像头驱动变量: " << e.what() << std::endl;
			return false;
		}
	}
	return true;
}

/* --daemon-grace-ms 解析与校验（2026-09-22 F-2）：全局选项，不限于某个
 * 输入源/模式，凡结构脚本含 @Daemon 都可能触发 deactivate() 的二段屏障。
 * 空串 = 用缺省值（daemon_limits::kGraceMsDefault），不调用 setter。
 * 失败已打印人话报错，返回 false（调用方按「配置错误不碰真机」退出 2）。 */
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

/* 跑流水线 + 无论成败都清理 + 退出前让弃管守护可见。
 * 异常两类都要接住：std::exception 与「非标准异常」——本机 LuaJIT 用 C++ 异常
 * 实现 luaD_throw（导入 _Unwind_RaiseException 而无 setjmp/longjmp），从没有
 * Lua CFRAME 的 C++ 帧抛出的 Lua 错误不是 std::exception——漏了它就直接
 * std::terminate，下面的 deactivate 被跳过，执行器停在最后指令位置。 */
int runRobotAndCleanup(RobotStruct& robot, const CliOptions& options,
		const agent::AgentModeConfig& agentCfg) {
	int rc = 0;
	try {
		if (options.mcpBackend) {
			/* MCP 后端（方案 F / 拓扑 F3）：独立模式，不争 stdin、不跑 agent loop。
			 * 同步服务阻塞主线程正是正确行为（评估 §2.3）；deactivate 照常在其后。 */
			rc = runMcpBackendPipeline(robot, agentCfg, options);
		} else if (options.agent && options.tcp) {
			/* agent over TCP（批次 2）：先监听并接受一个**已认证**连接，
			 * 再把硬件交出去——没有对端时不该让执行器带电空转（设计与
			 * 超时口径见 actionsource.hpp 的 TcpAgentSession 注释块）。
			 * 会话对象在此作用域内活着：析构（含 watcher 停止与 fd 关闭）
			 * 发生在 runAgentPipeline 返回之后、deactivate 之后。 */
			std::unique_ptr<TcpAgentSession> session = openAgentTcpSession(options);
			if (!session) { return 2; }
			rc = runAgentPipeline(robot, agentCfg, session->in(), session->out(),
				std::cerr);
		} else {
			rc = options.agent ? runAgentPipeline(robot, agentCfg, std::cin, std::cout,
					   std::cerr)
					   : runActionPipeline(robot, options);
		}
	} catch (const std::exception& e) {
		std::cerr << "Aborted: " << e.what() << std::endl;
		rc = 1;
	} catch (...) {
		std::cerr << "Aborted: non-standard exception (Lua error or foreign throw)"
			<< std::endl;
		rc = 1;
	}

	/* 无论有没有成功激活，都进行清理（对应 Cangjie finally） */
	robot.deactivate();
	/* N-7：弃管守护的 lua_State 在 exit 路径不可回收——退出前让泄漏可见 */
	if (int abandoned = abandonedDaemonCount(); abandoned > 0) {
		std::cerr << "Warning: " << abandoned << " daemon thread(s) abandoned at shutdown"
			<< " (join timeout); their Lua states are released by process exit only"
			<< std::endl;
	}
	return rc;
}

} // namespace bot

int main(int argc, char** argv) {
	using namespace bot;

	auto args = parseArgs(argc, argv);
	const CliOptions& options = args.opts;

	/* ---- 启动前哨：`--help` 优先于校验（顺序判定在 cliargs::preflightCli，
	 * 单测钉住——此前这段顺序写在 main 里，而 main 链接不进 mybot_tests，
	 * 用例只能测到 parseArgs，把顺序调换照样绿）---- */
	switch (preflightCli(args)) {
	case Preflight::Help:
		printHelp(options.helpTopic);  /* 2026-09-22: 支持分段帮助 */
		return 0;
	case Preflight::ConfigError:
		return 2;	/* 具体错误 validateOptions 已打印 */
	case Preflight::Proceed:
		break;
	}

	/* ---- Web SSH 独立服务（--webshell-port，#24 feat/web-ssh MVP）----
	 * 不依赖结构脚本/动作输入源：纯粹远程终端（浏览器 → WS → forkpty → shell）。
	 * 端口/跨机 token 校验已在 cliargs::validateOptions 收口（配置错误不碰真机）。
	 * 与机器人模式互斥：同给即拒，避免「终端里又起一台机器人」的歧义。 */
	if (options.webshell) {
		if (options.robot || options.agent || options.mcpBackend) {
			std::cerr << "参数错误：--webshell-port 与 --robot/--agent/--mcp-backend 互斥"
				"（Web SSH 是独立终端服务，不加载机器人结构脚本）" << std::endl;
			return 2;
		}
		return webshell::run(options.webshellHost, options.webshellPort, options.webshellToken);
	}

	/* ---- 结构脚本 + 动作输入源分支 ---- */
	if (options.robot) {
		std::string rpath = *options.robot;

		/* agent 配置先组装并校验（含配置文件读取与优先级合并）：
		 * 结构装载与上电都在其后，配置错误不碰真机 */
		agent::AgentModeConfig agentCfg;
		if ((options.agent || options.mcpBackend)
			&& !prepareAgentConfig(options, agentCfg)) { return 2; }

		/* PL-1：--check-config —— 配置此时已校验完毕（错误路径上面已 return 2）。
		 * 这里只打印摘要后退出 0：**不装载结构脚本、不上电、不发起任何网络请求**。
		 * 放在 loadStructure 之前是有意的——校验模式连结构都不装。 */
		if (options.checkConfig) {
			std::cout << agent::summarizeAgentConfig(agentCfg);
			return 0;
		}

		std::unique_ptr<RobotStruct> robot = loadStructure(rpath);
		if (!robot) { return 1; }

		/* --daemon-grace-ms：配置错误不碰真机——在 active() 之前校验并设置，
		 * 与 @Include 基准目录同一批「上电前收尾」步骤。 */
		if (!applyDaemonGraceMs(options.daemonGraceMs, *robot)) { return 2; }

		/* @Include 基准目录：--input 文件通道取脚本所在目录（相对路径直觉，
		 * 且与「include 名不得越出基准树」的词法规则自洽）；stdin/TCP 无脚本
		 * 位置，保持缺省 CWD。agent 模式的基准由 run_action_script 工具设为
		 * --scripts-dir（与该工具的相对路径语义一致），不在此处设置。 */
		if (options.input) {
			std::string parent = std::filesystem::path(*options.input).parent_path().string();
			robot->setActionIncludeBaseDir(parent.empty() ? "." : parent);
		}

		if ((options.agent || options.mcpBackend)
			&& !injectAgentDrivers(*robot, agentCfg, /*injectLlm=*/options.agent)) { return 2; }

		/* P2a 取消哨兵：仅 agent 模式需要（模型调用是唯一的长阻塞点）。
		 * 必须在装处理器**之前**填好路径缓冲——处理器只读它（async-signal-safe）。 */
		if (options.agent) { setupCancelSentinel(); }

		installStopSignalHandlers();
		int rc = runRobotAndCleanup(*robot, options, agentCfg);
		/* 退出前清掉哨兵（正常路径它从未被创建；取消路径下消费方也已结束）：
		 * /tmp 不留进程残骸。 */
		removeCancelSentinel();
		return rc;
	}

	/* 没有输入机器人结构脚本，打印帮助文档 */
	printHelp();
	return 0;
}

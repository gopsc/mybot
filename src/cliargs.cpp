/* cliargs.cpp —— 命令行解析 / 校验 / 帮助文本（自 main.cpp 纯搬移）
 *
 * 纯搬移声明：报错文案、退出码、打印顺序逐字不变；唯一形态变化是 print_help
 * 改为先合成字符串（helpText）再一次性输出 stdout——字节完全相同，但使
 * "--help 输出" 成为可被 C++ 单测锚定的对象（此前零守门）。
 */
#include "cliargs.hpp"

#include <algorithm>
#include <iostream>

#include "llmconfig.hpp"
#include "util.hpp"

namespace bot {

namespace {

/* 选项区间文本由 llm_limits 单点渲染（B2-4）：--help、配置解析与校验共用同一组
 * 界，避免「帮助里写一个数、校验用另一个数」这类漂移。 */
std::string rangeText(int lo, int hi) {
	return "范围 " + std::to_string(lo) + "-" + std::to_string(hi);
}

/* 重构计划 2.6：带值选项表——「agentOnly 标记 + 缺值登记 + 写入字段」
 * 此前是 19 段逐字重复的 if 链，新增选项靠复制粘贴；现在增项 = 表中加
 * 一行。布尔 flag 与「--tcp 的 flag+可选端口」形态特殊，留在表外显式处理。 */
struct OptionSpec {
	const char* name;
	void (*set)(CliOptions&, const std::string&);
	bool agentOnly;
};

constexpr OptionSpec kValueOptions[] = {
	{"robot", [](CliOptions& o, const std::string& v) { o.robot = v; }, false},
	{"tcp-host", [](CliOptions& o, const std::string& v) { o.tcpHost = v; }, false},
	{"tcp-token", [](CliOptions& o, const std::string& v) { o.tcpToken = v; }, false},
	{"tcp-idle", [](CliOptions& o, const std::string& v) { o.tcpIdle = v; }, false},
	{"tcp-max-auth-attempts", [](CliOptions& o, const std::string& v) { o.tcpMaxAuthAttempts = v; }, false},
	{"tcp-total-timeout", [](CliOptions& o, const std::string& v) { o.tcpTotalTimeout = v; }, false},
	{"webshell-port", [](CliOptions& o, const std::string& v) { o.webshell = true; o.webshellPort = v; }, false},
	{"webshell-host", [](CliOptions& o, const std::string& v) { o.webshellHost = v; }, false},
	{"webshell-token", [](CliOptions& o, const std::string& v) { o.webshellToken = v; }, false},
	{"daemon-grace-ms", [](CliOptions& o, const std::string& v) { o.daemonGraceMs = v; }, false},
	{"input", [](CliOptions& o, const std::string& v) { o.input = v; }, false},
	/* --mcp-socket：MCP 后端的 AF_UNIX 路径。非 agentOnly（它属 --mcp-backend
	 * 独立模式），backend-only 的组合校验在 validateOptions 里单点做。 */
	{"mcp-socket", [](CliOptions& o, const std::string& v) { o.mcpSocket = v; }, false},
	{"mcp-call-budget", [](CliOptions& o, const std::string& v) { o.mcpCallBudget = v; }, false},
	{"mcp-wall-clock", [](CliOptions& o, const std::string& v) { o.mcpWallClock = v; }, false},
	{"camera-var", [](CliOptions& o, const std::string& v) { o.cameraVar = v; }, true},
	{"camera-device", [](CliOptions& o, const std::string& v) { o.cameraDevice = v; }, true},
	{"camera-src", [](CliOptions& o, const std::string& v) { o.cameraSrc = v; }, true},
	{"audit-log", [](CliOptions& o, const std::string& v) { o.auditLog = v; }, true},
	{"agent-policy", [](CliOptions& o, const std::string& v) { o.agentPolicy = v; }, true},
	{"session-file", [](CliOptions& o, const std::string& v) { o.sessionFile = v; }, true},
	{"camera-src-dir", [](CliOptions& o, const std::string& v) { o.cameraSrcDir = v; }, true},
	{"task", [](CliOptions& o, const std::string& v) { o.agentTask = v; }, true},
	/* 可重复：每项一个可读变量名（发现 2 的 A 步，命令行独占） */
	{"read-var", [](CliOptions& o, const std::string& v) { o.readVars.push_back(v); }, true},
	{"scripts-dir", [](CliOptions& o, const std::string& v) { o.scriptsDir = v; }, true},
	{"prompt-file", [](CliOptions& o, const std::string& v) { o.promptFiles.push_back(v); }, true},
	{"llm-endpoint", [](CliOptions& o, const std::string& v) { o.llmEndpoint = v; }, true},
	{"llm-model", [](CliOptions& o, const std::string& v) { o.llmModel = v; }, true},
	{"llm-config", [](CliOptions& o, const std::string& v) { o.llmConfig = v; }, true},
	{"llm-driver", [](CliOptions& o, const std::string& v) { o.llmDriver = v; }, true},
	{"llm-var", [](CliOptions& o, const std::string& v) { o.llmVar = v; }, true},
	{"llm-max-turns", [](CliOptions& o, const std::string& v) { o.llmMaxTurns = v; }, true},
	{"llm-max-tokens", [](CliOptions& o, const std::string& v) { o.llmMaxTokens = v; }, true},
	{"llm-timeout", [](CliOptions& o, const std::string& v) { o.llmTimeout = v; }, true},
	{"llm-task-timeout", [](CliOptions& o, const std::string& v) { o.llmTaskTimeout = v; }, true},
};

} // namespace

ParsedArgs parseArgs(int argc, char** argv) {
	ParsedArgs out;
	for (int k = 1; k < argc; ++k) {
		std::string a = argv[k];
		if (a.rfind("--", 0) != 0) { continue; }	/* 忽略位置参数 */
		/* 审计中-3：区分「布尔型 flag」与「带值 key」——裸写（无 '=' 且
		 * 下一参数以 -- 开头或不存在）时不再回落 val="1"。旧实现 `--tcp`
		 * 单独使用会静默得到端口 1，随后 bind 失败的报错与用户意图
		 * （漏写端口号）相去甚远。切分规则在 cli::parseKeyValue 单点。 */
		cli::OptionToken tok = cli::parseKeyValue(k, argc, argv, /*strictLookahead=*/true);
		const std::string& key = tok.key;
		const std::string& val = tok.value;
		bool noValue = !tok.hasValue;
		/* ---- 布尔 flag 与特殊形态：表外显式处理 ---- */
		if (key == "help") {
			out.opts.help = true;
			/* 2026-09-22: 支持 --help <topic> 分段帮助 */
			if (!noValue) { out.opts.helpTopic = val; }
		}
		else if (key == "tcp") {
			out.opts.tcp = true;
			/* 裸 --tcp：tcp 置位但端口留空，由 openActionSource 报「缺端口号」 */
			if (!noValue) { out.opts.tcpPort = val; }
		}
		else if (key == "agent") { out.opts.agent = true; out.opts.agentOptionsUsed = true; }
		else if (key == "agent-shell") {
			out.opts.agentShell = true;
			out.opts.agentOptionsUsed = true;
		}
		else if (key == "agent-hot-sql") {
			out.opts.agentHotSql = true;
			out.opts.agentOptionsUsed = true;
		}
		else if (key == "no-camera") {
			out.opts.noCamera = true;
			out.opts.agentOptionsUsed = true;
		}
		else if (key == "resume") {
			out.opts.resume = true;
			out.opts.agentOptionsUsed = true;
		}
		else if (key == "check-config") {
			out.opts.checkConfig = true;
			out.opts.agentOptionsUsed = true;
		}
		else if (key == "mcp-backend") {
			/* 独立模式：不置 agentOptionsUsed（它不是 agent 模式，只是复用 agent
			 * 的工具上下文选项）。组合校验见 validateOptions。 */
			out.opts.mcpBackend = true;
		}
		else {
			/* ---- 带值选项：表驱动 ---- */
			const OptionSpec* spec = nullptr;
			for (const auto& item : kValueOptions) {
				if (key == item.name) { spec = &item; break; }
			}
			if (spec == nullptr) { out.unknown.push_back(key); }
			else {
				/* agentOnly 先于缺值检查置位——裸写 --camera-var 也算
				 * 「用过 agent 选项」，与既有顺序一致 */
				if (spec->agentOnly) { out.opts.agentOptionsUsed = true; }
				if (noValue) { out.missingValue.push_back(key); }
				else { spec->set(out.opts, val); }
			}
		}
	}
	return out;
}

/* PL-4（2026-09-22）：判定从 main 抽到这里，理由见 cliargs.hpp 的声明注释。
 * 顺序是契约：**先 help 后校验**——同时给 `--help` 与非法键时，用户要的是帮助，
 * 不该被一串错误清单挡住（未知键仍被 parseArgs 记录，只是这条路不消费它）。 */
Preflight preflightCli(ParsedArgs& args) {
	if (args.opts.help) { return Preflight::Help; }
	return validateOptions(args) == 0 ? Preflight::Proceed : Preflight::ConfigError;
}

/* F-20/N-4/agent 选项组合校验：违规即打印并返回退出码 2，通过返回 0 */
int validateOptions(ParsedArgs& args) {
	const CliOptions& options = args.opts;

	/* ---- F-20：未知/拼错的 --key 一律拒绝（退出码 2）----
	 * 旧行为是静默忽略：`--robott=foo` 打印帮助后 exit 0（CI 里的假成功），
	 * `--robot` 拼错还会让程序在「没给结构脚本」的路径上看似正常退出。 */
	if (!args.unknown.empty()) {
		std::sort(args.unknown.begin(), args.unknown.end());
		for (const auto& key : args.unknown) {
			std::cerr << "未知参数：--" << key << "；用 --help 查看支持的参数" << std::endl;
		}
		return 2;
	}

	/* N-4：带值键裸写（漏值）在解析层即拒绝，退出码与 unknown 一致 */
	if (!args.missingValue.empty()) {
		for (const auto& key : args.missingValue) {
			std::cerr << "选项 --" << key << " 缺少值；用法：--" << key << " <值>"
				<< "，用 --help 查看说明" << std::endl;
		}
		return 2;
	}

	/* ---- agent 模式选项校验（先于结构脚本装载与任何硬件上电）----
	 * F-20 同族口径：选项组合错必须显式拒绝并退出 2，不能静默忽略。
	 *   1) agent 专属选项出现在非 agent 模式下 → 用户意图与参数不一致；
	 *   2) --agent 与 --tcp/--input 互斥 → 两者都要求主导输入源。 */
	if (!options.agent && !options.mcpBackend && options.agentOptionsUsed) {
		/* PL-5（2026-09-22）：选项名单与 docs/agent.md 的 agent 专属选项表保持一致。
		 * 此前漏列 camera 四项——用户敲了 --no-camera 却被报「这些选项只在 agent
		 * 模式下有效」，而文案里没有他刚敲的那一个，看起来像撞上了另一个错误。 */
		std::cerr << "参数错误：--task / --llm-* / --scripts-dir / --agent-shell "
			"/ --agent-hot-sql / --read-var / --prompt-file / --camera-var / --camera-device / --camera-src "
			"/ --no-camera / --session-file / --resume / --check-config 只在 --agent 模式下有效；"
			"用 --help 查看 agent 模式说明"
			<< std::endl;
		return 2;
	}
	/* 2026-09-23（批次 2）：--agent --tcp 不再是互斥，而是**远程 REPL**
	 * （对端每行一条任务；安全口径与动作源 TCP 同款：回环缺省、跨机必须
	 * --tcp-token）。仍被拒的两种组合：
	 *   ① --agent --tcp --input：两个输入源都要主导，用户意图不一致；
	 *   ② --agent --tcp --task：一次性任务没有长驻对话的意义，套一层连接
	 *      只会让「跑完即退出」的语义变成「连上就跑完断开」，误导使用者。 */
	if (options.agent && options.input) {
		std::cerr << "参数错误：--agent 与 --input 互斥"
			"（agent 模式以智能体工具循环为主流程，不接受一次性动作输入源）"
			<< std::endl;
		return 2;
	}
	if (options.agent && options.tcp && !options.agentTask.empty()) {
		std::cerr << "参数错误：--task 与 --tcp 互斥"
			"（--task 是一次性任务，跑完即退出；远程对话请去掉 --task，"
			"由对端逐行下发任务）" << std::endl;
		return 2;
	}
	/* agent 模式没有结构脚本就无从常驻，必须显式拒绝而不是打印帮助后退出 0 */
	if (options.agentOptionsUsed && !options.robot) {
		std::cerr << "参数错误：agent 模式需要同时提供 --robot <结构脚本>" << std::endl;
		return 2;
	}

	/* ---- MCP 后端模式（--mcp-backend）组合校验（方案 F / 拓扑 F3）----
	 * 与 F-20 同口径：组合错显式拒绝退出 2，不静默忽略。后端复用 agent 的工具
	 * 上下文选项（能力门控），但**不跑 loop、不发模型调用**，故 loop/LLM 专属
	 * 选项一律拒绝（silently ignored 会误导使用者）。 */
	if (!options.mcpBackend && !options.mcpSocket.empty()) {
		std::cerr << "参数错误：--mcp-socket 只在 --mcp-backend 模式下有效" << std::endl;
		return 2;
	}
	if (!options.mcpBackend
		&& (!options.mcpCallBudget.empty() || !options.mcpWallClock.empty())) {
		std::cerr << "参数错误：--mcp-call-budget / --mcp-wall-clock 只在 --mcp-backend 模式下有效"
			<< std::endl;
		return 2;
	}
	if (options.mcpBackend) {
		if (options.agent) {
			std::cerr << "参数错误：--mcp-backend 与 --agent 互斥"
				"（后端不跑 agent 工具循环，由外部 MCP 客户端驱动每次调用）" << std::endl;
			return 2;
		}
		if (options.tcp) {
			std::cerr << "参数错误：--mcp-backend 与 --tcp 互斥"
				"（后端经 AF_UNIX socket 服务，不监听 TCP 端口）" << std::endl;
			return 2;
		}
		if (options.input) {
			std::cerr << "参数错误：--mcp-backend 与 --input 互斥"
				"（后端不接受一次性动作输入源）" << std::endl;
			return 2;
		}
		if (!options.robot) {
			std::cerr << "参数错误：--mcp-backend 需要同时提供 --robot <结构脚本>" << std::endl;
			return 2;
		}
		if (options.mcpSocket.empty()) {
			std::cerr << "参数错误：--mcp-backend 需要 --mcp-socket <AF_UNIX 路径>"
				"（sidecar 经此路径连接后端）" << std::endl;
			return 2;
		}
		/* 每连接预算数值校验（空 = 不限；配置错误不碰真机，故在此单点拒）。
		 * 上限只是防呆（跑飞护栏本就不该设成天文数字）。 */
		if (!options.mcpCallBudget.empty()) {
			auto [st, v] = parseLongStrict(options.mcpCallBudget);
			if (st != IntParse::OK || v < 0 || v > 1000000) {
				std::cerr << rangeErrorText("选项 --mcp-call-budget", 0, 1000000,
					options.mcpCallBudget) << std::endl;
				return 2;
			}
		}
		if (!options.mcpWallClock.empty()) {
			auto [st, v] = parseLongStrict(options.mcpWallClock);
			if (st != IntParse::OK || v < 0 || v > 86400) {
				std::cerr << rangeErrorText("选项 --mcp-wall-clock", 0, 86400,
					options.mcpWallClock) << std::endl;
				return 2;
			}
		}
		/* loop/LLM 专属选项：后端无对应语义，逐个点名拒绝（不静默忽略）。 */
		const char* bad = nullptr;
		if (!options.agentTask.empty()) { bad = "--task"; }
		else if (options.resume) { bad = "--resume"; }
		else if (options.checkConfig) { bad = "--check-config"; }
		else if (!options.sessionFile.empty()) { bad = "--session-file"; }
		else if (!options.promptFiles.empty()) { bad = "--prompt-file"; }
		else if (!options.llmEndpoint.empty()) { bad = "--llm-endpoint"; }
		else if (!options.llmModel.empty()) { bad = "--llm-model"; }
		else if (!options.llmConfig.empty()) { bad = "--llm-config"; }
		else if (!options.llmDriver.empty()) { bad = "--llm-driver"; }
		else if (!options.llmVar.empty()) { bad = "--llm-var"; }
		else if (!options.llmMaxTurns.empty()) { bad = "--llm-max-turns"; }
		else if (!options.llmMaxTokens.empty()) { bad = "--llm-max-tokens"; }
		else if (!options.llmTimeout.empty()) { bad = "--llm-timeout"; }
		else if (!options.llmTaskTimeout.empty()) { bad = "--llm-task-timeout"; }
		if (bad != nullptr) {
			std::cerr << "参数错误：" << bad << " 只在 --agent 模式下有效；"
				"--mcp-backend 不发起模型调用、不跑 agent 工具循环" << std::endl;
			return 2;
		}
	}

	/* ---- Web SSH（--webshell-port，#24）：端口数字 + 跨机监听必须带 token ----
	 * 校验前置（配置错误不碰真机/不监听）：端口非数字或越界即拒；监听地址非
	 * 回环（127.0.0.1/localhost）且没给 --webshell-token 时拒绝启动——空口令
	 * 暴露交互 shell 的风险比 --tcp 更大（那是单向动作流，这是终端）。 */
	if (options.webshell) {
		bool portOk = false;
		try {
			long p = std::stol(options.webshellPort);
			portOk = p >= 1 && p <= 65535;
		} catch (...) { portOk = false; }
		if (!portOk) {
			std::cerr << "参数错误：--webshell-port 需要一个 1~65535 的整数，"
				"实际是 '" << options.webshellPort << "'" << std::endl;
			return 2;
		}
		bool loopback = options.webshellHost == "127.0.0.1" || options.webshellHost == "localhost";
		if (!loopback && options.webshellToken.empty()) {
			std::cerr << "参数错误：--webshell-host 为非回环地址（" << options.webshellHost
				<< "）时必须提供 --webshell-token，否则拒绝启动（交互 shell 暴露公网）" << std::endl;
			return 2;
		}
	}
	return 0;
}

std::string helpText() {
	std::string s;
	s += "这是一个机器人动作脚本解析器。\n";
	s += "使用--robot选项指定结构脚本，然后使用管道输入动作脚本，示例：\n";
	s += "cat scripts/std.mt | ./build/mybot --robot=./robots/spider1.sql\n";
	s += "\n";
	s += "动作输入源（优先级从高到低）：\n";
	s += "  --tcp <port>       TCP 模式：监听端口接受一次成功连接，读取对端下发的 .mt\n";
	s += "                     （EOF 或 --tcp-idle 超时按输入结束处理，非流式长驻）。\n";
	s += "                     与 --agent 同给时为**远程 REPL**：对端每行一条任务，模型输出\n";
	s += "                     与工具回显回写该连接；无连接总时长预算（长会话），--tcp-idle\n";
	s += "                     缺省 600s，对端断开即远程取消（立即中止在飞的模型调用）\n";
	s += "  --tcp-host <addr>  TCP 监听地址，缺省 127.0.0.1；跨机监听（如 0.0.0.0）\n";
	s += "                     必须同时提供 --tcp-token，否则拒绝启动\n";
	s += "  --tcp-token <tok>  TCP 口令：跨机监听必填；对端须先发一行 \"<tok>\\n\" 再发脚本；\n";
	s += "                     校验失败关连接回等，连续 5 次才退出；也可用环境变量 BOT4CJ_TCP_TOKEN\n";
	s += "  --tcp-idle <sec>   TCP 空闲超时，缺省 30s（超时按输入结束处理）；\n";
	s += "                     另有连接总时长预算（600s，随该值 x20 放大）防慢滴挂住进程\n";
	s += "  --tcp-max-auth-attempts <N>  口令连续失败上限（缺省 5，"
		+ rangeText(tcp_limits::kAuthMaxFailsMin, tcp_limits::kAuthMaxFailsMax) + "）\n";
	s += "  --tcp-total-timeout <sec>    连接总时长预算下限（缺省 600，"
		+ rangeText(tcp_limits::kTotalTimeoutMin, tcp_limits::kTotalTimeoutMax)
		+ "）；生效值取该下限与 idle x20 的较大者\n";
	s += "  --input <path>     从文件读取动作脚本\n";
	s += "  （缺省）           从 stdin 管道读取\n";
	s += "  --webshell-port <port>   Web SSH 终端服务（#24）：浏览器 xterm.js →\n";
	s += "                     WebSocket(/ws/term) → forkpty 交互 shell。独立于上述输入源，\n";
	s += "                     给端口即启用；GET / 提供单页前端。缺省监听 127.0.0.1\n";
	s += "  --webshell-host <addr>  Web SSH 监听地址（缺省 127.0.0.1）；跨机监听必须\n";
	s += "                     同时提供 --webshell-token，否则拒绝启动\n";
	s += "  --webshell-token <tok>  Web SSH 口令：客户端以 ?token=<tok> 附在连接 URL 上；\n";
	s += "                     非回环监听必填\n";
	s += "  --daemon-grace-ms <ms>  守护线程弃管后的二段停机宽限上限（缺省 30000，"
		+ rangeText(daemon_limits::kGraceMsMin, daemon_limits::kGraceMsMax)
		+ "）；仅结构脚本含 @Daemon 时生效，与 --agent/--tcp/--input 任一模式无关\n";
	s += "\n";
	s += "agent 模式（与上面的动作输入源互斥）：机器人结构脚本加载后硬件常驻内存，\n";
	s += "模型调用由 Lua 协议驱动承担（不链接任何 HTTP 库，运行期只需 libcurl）。\n";
	s += "  --agent            开启 agent 模式（缺省交互 REPL；硬件全程上电常驻）\n";
	s += "  --task <文本>      一次性任务，跑完即退出；缺省则进入交互 REPL\n";
	s += "  --tcp <port>       远程 REPL：对端每行一条任务（与 --task 互斥）。缺省只监听\n";
	s += "                     127.0.0.1；跨机必须 --tcp-token。对端断开=远程取消\n";
	s += "  --llm-config <路径>  配置文件（JSON）：目标 URL、API key、模型、采样与 agent 参数\n";
	s += "                       缺省按 ./mybot.llm.json -> ./mybot.llm.conf.json ->\n";
	s += "                       $HOME/.config/mybot/llm.json 查找；传 none 表示本次不读配置文件；\n";
	s += "                       也可用环境变量 BOT4CJ_LLM_CONFIG 指定\n";
	s += "  --llm-driver <表名>  协议驱动表名 = modules/<表名>.lua\n";
	s += "                       内置：LlmOpenAI（缺省，OpenAI 兼容）、LlmDeepSeek\n";
	s += "  --llm-var <变量名>   承载驱动的变量名（缺省 llm0）；结构脚本已声明则直接用\n";
	s += "  --llm-endpoint <URL>  接入点（覆盖配置文件）\n";
	s += "  --llm-model <名称>    模型名（覆盖配置文件）\n";
	s += "  （API key）           只从环境变量 BOT4CJ_LLM_KEY（兼容 ROBOT_AGENT_API_KEY /\n";
	s += "                       DEEPSEEK_API_KEY）或配置文件的 api_key / api_key_file 取；\n";
	s += "                       不提供命令行传密钥的选项——argv 对同用户进程可读\n";
	s += "                       （/proc/<pid>/cmdline）\n";
	s += "  --llm-max-turns <N>   单次任务的最大模型轮数（缺省 8，"
		+ rangeText(llm_limits::kMaxTurnsMin, llm_limits::kMaxTurnsMax) + "）\n";
	s += "  --llm-max-tokens <N>  单次生成最大 token 数（缺省 4096，"
		+ rangeText(llm_limits::kMaxTokensMin, llm_limits::kMaxTokensMax) + "）\n";
	s += "  --llm-timeout <秒>    单次模型调用超时（缺省 180，"
		+ rangeText(llm_limits::kTimeoutMinSec, llm_limits::kTimeoutMaxSec) + "）\n";
	s += "  --llm-task-timeout <秒> 单个任务的墙钟预算（缺省 900，"
		+ rangeText(llm_limits::kTaskTimeoutMinSec, llm_limits::kTaskTimeoutMaxSec)
		+ "；0 = 不限）。agent 模式全程硬件带电常驻，\n";
	s += "                       这条给「一个任务最多带电多久」设闸；超限即如实失败，\n";
	s += "                       已执行的动作不回退（也可用配置文件 max_task_seconds）\n";
	s += "  --scripts-dir <目录>  动作脚本根目录（缺省 scripts）；智能体只能执行其下的 .mt\n";
	s += "  --prompt-file <路径>  提示词包：可重复传入（文件或目录），全部内容拼接后\n";
	s += "                       追加到系统提示词，用于注入机器人身份与行为约束；\n";
	s += "                       目录收集其中全部 .md 按文件名自然排序（编号即装载顺序），\n";
	s += "                       文件间以 \"## 文件名\" 分节；也可用配置文件 prompt_files 数组\n";
	s += "                       （示例：prompts/spider_robot/）\n";
	s += "  --agent-shell         允许智能体执行 shell 命令（注册 run_command 工具）；\n";
	s += "                       **缺省不提供**该工具（任意 shell 执行是最大的一张牌，\n";
	s += "                       要用就显式开启；理由与缓解见 docs/agent.md 安全一节）\n";
	s += "  --agent-hot-sql       允许智能体用结构 SQL 改硬件（注册 apply_sql 工具）：\n";
	s += "                       CREATE TABLE / INSERT INTO 会**立即装配并上电**（开 fd、\n";
	s += "                       进断电清理链），失败整批回滚；**缺省不提供**，配置文件\n";
	s += "                       的 allow_hot_sql 只能关不能开（只读的 query_sql 不受影响）\n";
	s += "  --read-var <变量名>    声明一个**可读**硬件变量（可重复；注册 read_variables\n";
	s += "                       工具，让智能体主动读器件当前值）。**缺省不提供**该工具：\n";
	s += "                       只有列进来的变量可读——执行器（Servo/Relay 等）也是 Lua\n";
	s += "                       驱动，靠种类分不出传感器与执行器，故由操作者显式声明；\n";
	s += "                       配置文件写 read_vars 会被拒绝加载（与 --agent-shell 同判据）\n";
	s += "  --agent-policy <路径> 策略钩子（严格 JSON）：声明哪些工具的每次调用要先过\n";
	s += "                       外部确认程序（stdin 收工具名与遮蔽后的参数 JSON，\n";
	s += "                       退出 0 = 放行）；超时按 on_timeout（缺省 deny）处理；\n";
	s += "                       缺省不启用。也可用配置文件 agent_policy 字段\n";
	s += "  --camera-var <变量名> 承载摄像头驱动的变量名（缺省 cam0）；结构脚本已声明则直接用\n";
	s += "  --camera-device <路径> 摄像头设备（缺省 /dev/video0；需支持 MJPEG）\n";
	s += "  --camera-src <图片>   模拟图片来源：不接摄像头也能跑通「拍照→进上下文」。\n";
	s += "                       命令行给的 src 以其**所在目录**为白名单根；配置文件里的\n";
	s += "                       camera_src 不推导根（防止一份落地配置把任意文件读进上下文），\n";
	s += "                       需配 --camera-src-dir 或 BOT4CJ_CAMERA_SRC_DIR，否则驱动默认拒绝\n";
	s += "  --camera-src-dir <目录> capture_image 模拟图片的白名单根目录（**只能命令行给**：\n";
	s += "                       它放宽读权限，配置文件写 camera_src_dir 会被拒绝加载）\n";
	s += "  --no-camera           不向智能体提供 capture_image 工具\n";
	s += "  --check-config        只校验配置并打印摘要后退出 0：不装载结构脚本、不上电、\n";
	s += "                       不发起任何网络请求（配置文件拼错时无需真起会话，\n";
	s += "                       接了硬件也不必反复上下电）。会**打开但不写入**审计日志文件\n";
	s += "  --audit-log <路径>    审计轨迹（JSON Lines 追加写）：每次工具调用一条记录\n";
	s += "                       （时间戳/轮次/工具/参数/成败/耗时）；图片只记体积与指纹，\n";
	s += "                       命令原文里的 KEY=VALUE 敏感值先遮蔽；\"-\" 表示写 stderr；\n";
	s += "                       缺省不记录。也可用配置文件 audit_log 字段\n";
	s += "  --session-file <路径> 会话持久化（JSON Lines 追加写）：每个任务块完结时落盘\n";
	s += "                       完整对话历史；图片以占位文本落盘（字节不落盘），system\n";
	s += "                       提示词不落盘。配置文件的 session_file 字段只用于写入；\n";
	s += "                       文件含完整对话内容，建议 chmod 600\n";
	s += "  --resume              恢复 --session-file 指定的既有会话后继续；路径必须来自\n";
	s += "                       命令行，且结构脚本/工具集/系统提示词与原会话一致\n";
	s += "                       （指纹核对），否则拒绝恢复并说明\n";
	s += "取值优先级：命令行 > 环境变量 > 配置文件 > 驱动内置缺省。\n";
	s += "REPL 内置命令：/hardware 硬件清单，/scripts 动作脚本清单，/help 帮助，/exit 退出。\n";
	s += "\n";
	s += "示例：\n";
	s += "  ./build/mybot --robot=robots/relay-test.sql --agent --task \"让继电器动作一次\"\n";
	s += "  ./build/mybot --robot=robots/spider1.sql --agent --llm-config mybot.llm.json\n";
	s += "\n";
	s += "安全约束：动作脚本只能引入新的参数键，不得覆盖结构脚本的元数据列\n";
	s += "（fd / address / max / min / offset 等）与触发器引用名（trigger 列）；\n";
	s += "结构脚本与动作脚本单次输入上限均为 8 MiB。\n";
	s += "\n";
	s += "分段帮助（2026-09-22 新增）：\n";
	s += "  --help tcp     - 只显示 TCP 模式相关选项\n";
	s += "  --help agent   - 只显示 agent 模式相关选项\n";
	s += "  --help llm     - 只显示 LLM 配置相关选项\n";
	s += "  --help camera  - 只显示摄像头相关选项\n";
	s += "  --help mcp     - 只显示 MCP 后端模式（--mcp-backend）相关选项\n";
	return s;
}

/* 分段帮助文本（2026-09-22 可用性改进）：支持快速查看特定主题 */
std::string helpText(const std::string& topic) {
	if (topic.empty()) { return helpText(); }
	std::string t = trim(topic);
	for (char& c : t) { c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); }

	std::string s;
	if (t == "tcp") {
		s += "TCP 模式（动作输入源）：\n\n";
		s += "  --tcp <port>       TCP 模式：监听端口接受一次成功连接，读取对端下发的 .mt\n";
		s += "                     （EOF 或 --tcp-idle 超时按输入结束处理，非流式长驻）\n";
		s += "  --tcp-host <addr>  TCP 监听地址，缺省 127.0.0.1；跨机监听（如 0.0.0.0）\n";
		s += "                     必须同时提供 --tcp-token，否则拒绝启动\n";
		s += "  --tcp-token <tok>  TCP 口令：跨机监听必填；对端须先发一行 \"<tok>\\n\" 再发脚本；\n";
		s += "                     校验失败关连接回等，连续 5 次才退出；也可用环境变量 BOT4CJ_TCP_TOKEN\n";
		s += "  --tcp-idle <sec>   TCP 空闲超时，缺省 30s（超时按输入结束处理）；\n";
		s += "                     另有连接总时长预算（600s，随该值 x20 放大）防慢滴挂住进程\n";
		s += "  --tcp-max-auth-attempts <N>  口令连续失败上限（缺省 5，"
			+ rangeText(tcp_limits::kAuthMaxFailsMin, tcp_limits::kAuthMaxFailsMax) + "）\n";
		s += "  --tcp-total-timeout <sec>    连接总时长预算下限（缺省 600，"
			+ rangeText(tcp_limits::kTotalTimeoutMin, tcp_limits::kTotalTimeoutMax)
			+ "）；生效值取该下限与 idle x20 的较大者\n\n";
		s += "示例：\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --tcp 8080\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --tcp 8080 --tcp-host 0.0.0.0 --tcp-token mysecret\n";
	} else if (t == "agent") {
		s += "Agent 模式（智能体控制）：\n\n";
		s += "  --agent            开启 agent 模式（缺省交互 REPL；硬件全程上电常驻）\n";
		s += "  --task <文本>      一次性任务，跑完即退出；缺省则进入交互 REPL\n";
		s += "  --scripts-dir <目录>  动作脚本根目录（缺省 scripts）；智能体只能执行其下的 .mt\n";
		s += "  --prompt-file <路径>  提示词包：可重复传入（文件或目录），全部内容拼接后\n";
		s += "                       追加到系统提示词，用于注入机器人身份与行为约束；\n";
		s += "                       目录收集其中全部 .md 按文件名自然排序（编号即装载顺序），\n";
		s += "                       文件间以 \"## 文件名\" 分节；也可用配置文件 prompt_files 数组\n";
		s += "  --agent-shell         允许智能体执行 shell 命令（注册 run_command 工具）；\n";
	s += "                       **缺省不提供**该工具（任意 shell 执行是最大的一张牌）\n";
	s += "  --agent-hot-sql       允许智能体用结构 SQL 改硬件（注册 apply_sql 工具）：\n";
	s += "                       CREATE TABLE / INSERT INTO 立即装配并上电，失败整批回滚；\n";
	s += "                       **缺省不提供**，配置文件不能开（只读 query_sql 不受影响）\n";
	s += "  --read-var <变量名>    声明一个可读硬件变量（可重复；注册 read_variables 工具）。\n";
	s += "                       **缺省不提供**：执行器也是 Lua 驱动，靠种类分不出传感器\n";
	s += "                       与执行器，故只有显式列进来的变量可读；配置文件不能开\n";
	s += "  --agent-policy <路径> 策略钩子：命中 require_confirm 的工具调用先过外部\n";
	s += "                       确认程序（stdin 收工具名与参数 JSON，退出 0 = 放行；\n";
	s += "                       超时按 on_timeout，缺省 deny）；缺省不启用\n";
	s += "  --session-file <路径> 会话持久化（JSON Lines 追加写）：每个任务块完结时\n";
	s += "                       落一行流水的完整历史；图片以占位文本落盘（字节不落盘），\n";
	s += "                       system 提示词不落盘。也可用配置文件 session_file 字段\n";
	s += "                       （只用于写入）。注意：文件含完整对话内容，建议 chmod 600\n";
	s += "  --resume              恢复 --session-file 指定的既有会话后继续；路径必须\n";
	s += "                       来自命令行，且结构脚本/工具集/系统提示词与原会话\n";
	s += "                       一致（指纹核对），否则拒绝恢复并说明\n\n";
		s += "REPL 内置命令：/hardware, /scripts, /help, /exit\n\n";
		s += "示例：\n";
		s += "  ./build/mybot --robot=robots/relay-test.sql --agent --task \"让继电器动作一次\"\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --agent\n";
	} else if (t == "llm") {
		s += "LLM 配置选项：\n\n";
		s += "  --llm-config <路径>  配置文件（JSON）：目标 URL、API key、模型、采样与 agent 参数\n";
		s += "                       缺省按 ./mybot.llm.json -> ./mybot.llm.conf.json ->\n";
		s += "                       $HOME/.config/mybot/llm.json 查找；传 none 表示本次不读配置文件\n";
		s += "  --llm-driver <表名>  协议驱动表名 = modules/<表名>.lua\n";
		s += "                       内置：LlmOpenAI（缺省，OpenAI 兼容）、LlmDeepSeek\n";
		s += "  --llm-var <变量名>   承载驱动的变量名（缺省 llm0）\n";
		s += "  --llm-endpoint <URL>  接入点（覆盖配置文件）\n";
		s += "  --llm-model <名称>    模型名（覆盖配置文件）\n";
		s += "  （API key）           只从环境变量 BOT4CJ_LLM_KEY 或配置文件的 api_key / api_key_file 取\n";
		s += "  --llm-max-turns <N>   单次任务的最大模型轮数（缺省 8，"
			+ rangeText(llm_limits::kMaxTurnsMin, llm_limits::kMaxTurnsMax) + "）\n";
		s += "  --llm-max-tokens <N>  单次生成最大 token 数（缺省 4096，"
			+ rangeText(llm_limits::kMaxTokensMin, llm_limits::kMaxTokensMax) + "）\n";
		s += "  --llm-timeout <秒>    单次模型调用超时（缺省 180，"
			+ rangeText(llm_limits::kTimeoutMinSec, llm_limits::kTimeoutMaxSec) + "）\n\n";
		s += "取值优先级：命令行 > 环境变量 > 配置文件 > 驱动内置缺省\n\n";
		s += "示例：\n";
		s += "  export BOT4CJ_LLM_KEY=sk-xxx\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --agent --llm-model gpt-4\n";
	} else if (t == "camera") {
		s += "摄像头配置选项：\n\n";
		s += "  --camera-var <变量名> 承载摄像头驱动的变量名（缺省 cam0）\n";
		s += "  --camera-device <路径> 摄像头设备（缺省 /dev/video0；需支持 MJPEG）\n";
		s += "  --camera-src <图片>   模拟图片来源：不接摄像头也能跑通「拍照→进上下文」\n";
		s += "  --no-camera           不向智能体提供 capture_image 工具\n";
		s += "  --check-config        只校验配置并打印摘要后退出 0（不装结构、不上电、不联网）\n";
		s += "  --audit-log <路径>    审计轨迹（JSON Lines 追加写；\"-\"=stderr；缺省不记录）\n";
		s += "                        也可用配置文件 audit_log 字段\n\n";
		s += "示例：\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --agent --camera-device /dev/video1\n";
		s += "  ./build/mybot --robot=robots/spider1.sql --agent --camera-src test.jpg\n";
	} else if (t == "mcp") {
		s += "MCP 后端模式（方案 F / 拓扑 F3）：\n\n";
		s += "  --mcp-backend       把 agent 工具层经本地 AF_UNIX socket 暴露给 Rust MCP\n";
		s += "                      sidecar（sidecar 对上说 MCP over stdio，对下说 pymsg 兼容帧）。\n";
		s += "                      独立模式：不跑 agent 工具循环、不发起任何模型调用——每次\n";
		s += "                      工具调用由外部 MCP 客户端驱动，后端只走既有的\n";
		s += "                      「策略确认 → 执行 → 审计」漏斗（DispatchGate::run）。\n";
		s += "                      与 --agent / --tcp / --input 互斥；需要 --robot。\n";
		s += "  --mcp-socket <路径>  AF_UNIX socket 路径（必填）。父目录建议 0700、socket 文件\n";
		s += "                      0600；对端经内核 SO_PEERCRED 校验 uid/gid（不可伪造）。\n";
		s += "  --mcp-call-budget <N>   每连接工具调用上限（跑飞护栏；0/空 = 不限，缺省不限）。\n";
		s += "                      后端不假设调用方是 agent loop，故自行再强制一层预算。\n";
		s += "  --mcp-wall-clock <秒>   每连接墙钟预算（0/空 = 不限，缺省不限；上限 86400）。\n";
		s += "                      注：单次物理调用的 script/command 超时始终在工具层生效。\n\n";
		s += "安全：后端开 --agent-shell / --agent-hot-sql 时**强制**要 --agent-policy，且其\n";
		s += "      require_confirm 必须分别包含 run_command / apply_sql（无人值守暴露危险能力\n";
		s += "      必须有外部确认闸门）；纯只读/查询/动作脚本后端不受此约束。\n\n";
		s += "复用 agent 的工具上下文/能力门控选项（决定对外宣告哪些工具）：\n";
		s += "  --agent-shell / --agent-hot-sql / --read-var / --camera-* / --no-camera /\n";
		s += "  --scripts-dir / --agent-policy / --audit-log\n";
		s += "（--task / --llm-* / --prompt-file / --session-file / --resume 只在 --agent 下有效）\n\n";
		s += "示例：\n";
		s += "  ./build/mybot --robot=robots/relay-test.sql --mcp-backend \\\n";
		s += "      --mcp-socket /run/user/1000/bot4cj/mcp.sock --audit-log -\n";
	} else {
		s += "未知主题: " + topic + "\n\n";
		s += "支持的主题：tcp, agent, llm, camera, mcp\n";
		s += "使用 --help 查看完整帮助\n";
	}
	return s;
}

void printHelp() {
	std::cout << helpText();
}

void printHelp(const std::string& topic) {
	std::cout << helpText(topic);
}

} // namespace bot

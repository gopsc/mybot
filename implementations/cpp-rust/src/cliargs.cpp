/* cliargs.cpp —— 命令行解析 / 校验 / 帮助文本（自 main.cpp 纯搬移）
 *
 * 纯搬移声明：报错文案、退出码、打印顺序逐字不变；唯一形态变化是 print_help
 * 改为先合成字符串（helpText）再一次性输出 stdout——字节完全相同，但使
 * "--help 输出" 成为可被 C++ 单测锚定的对象（此前零守门）。
 */
#include "cliargs.hpp"

#include <algorithm>
#include <iostream>

#include "util_cli.hpp"
#include "util_num.hpp"
#include "util_str.hpp"

namespace bot {

namespace {

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
	{"tcp-host", [](CliOptions& o, const std::string& v) { o.tcp.tcpHost = v; }, false},
	{"tcp-token", [](CliOptions& o, const std::string& v) { o.tcp.tcpToken = v; }, false},
	{"tcp-idle", [](CliOptions& o, const std::string& v) { o.tcp.tcpIdle = v; }, false},
	{"tcp-max-auth-attempts", [](CliOptions& o, const std::string& v) { o.tcp.tcpMaxAuthAttempts = v; }, false},
	{"tcp-total-timeout", [](CliOptions& o, const std::string& v) { o.tcp.tcpTotalTimeout = v; }, false},
	{"webshell-port", [](CliOptions& o, const std::string& v) { o.webshell = true; o.webshellPort = v; }, false},
	{"webshell-host", [](CliOptions& o, const std::string& v) { o.webshellHost = v; }, false},
	{"webshell-token", [](CliOptions& o, const std::string& v) { o.webshellToken = v; }, false},
	{"daemon-grace-ms", [](CliOptions& o, const std::string& v) { o.daemonGraceMs = v; }, false},
	{"input", [](CliOptions& o, const std::string& v) { o.input = v; }, false},
	/* --mcp-socket：MCP 后端的 AF_UNIX 路径。非 agentOnly（它属 --mcp-backend
	 * 独立模式），backend-only 的组合校验在 validateOptions 里单点做。 */
	{"mcp-socket", [](CliOptions& o, const std::string& v) { o.mcp.mcpSocket = v; }, false},
	{"mcp-call-budget", [](CliOptions& o, const std::string& v) { o.mcp.mcpCallBudget = v; }, false},
	{"mcp-wall-clock", [](CliOptions& o, const std::string& v) { o.mcp.mcpWallClock = v; }, false},
	{"mcp-idle-timeout", [](CliOptions& o, const std::string& v) { o.mcp.mcpIdleTimeout = v; }, false},
	{"on-disconnect", [](CliOptions& o, const std::string& v) { o.mcp.onDisconnect = v; }, false},
	{"camera-var", [](CliOptions& o, const std::string& v) { o.agent.cameraVar = v; }, true},
	{"camera-device", [](CliOptions& o, const std::string& v) { o.agent.cameraDevice = v; }, true},
	{"camera-src", [](CliOptions& o, const std::string& v) { o.agent.cameraSrc = v; }, true},
	{"audit-log", [](CliOptions& o, const std::string& v) { o.agent.auditLog = v; }, true},
	{"agent-policy", [](CliOptions& o, const std::string& v) { o.agent.agentPolicy = v; }, true},
	{"session-file", [](CliOptions& o, const std::string& v) { o.agent.sessionFile = v; }, true},
	{"camera-src-dir", [](CliOptions& o, const std::string& v) { o.agent.cameraSrcDir = v; }, true},
	/* Phase 4（2026-10-07）：list_dir / read_file 的只读根目录，命令行独占
	 * （同 camera-src-dir/read-var 一族，见 actionsource.hpp 的字段注释）。 */
	{"fs-root", [](CliOptions& o, const std::string& v) { o.agent.fsRoot = v; }, true},
	{"task", [](CliOptions& o, const std::string& v) { o.agent.agentTask = v; }, true},
	/* 可重复：每项一个可读变量名（发现 2 的 A 步，命令行独占） */
	{"read-var", [](CliOptions& o, const std::string& v) { o.agent.readVars.push_back(v); }, true},
	{"scripts-dir", [](CliOptions& o, const std::string& v) { o.agent.scriptsDir = v; }, true},
	{"prompt-file", [](CliOptions& o, const std::string& v) { o.agent.promptFiles.push_back(v); }, true},
	{"llm-endpoint", [](CliOptions& o, const std::string& v) { o.agent.llmEndpoint = v; }, true},
	{"llm-model", [](CliOptions& o, const std::string& v) { o.agent.llmModel = v; }, true},
	{"llm-config", [](CliOptions& o, const std::string& v) { o.agent.llmConfig = v; }, true},
	{"llm-driver", [](CliOptions& o, const std::string& v) { o.agent.llmDriver = v; }, true},
	{"llm-var", [](CliOptions& o, const std::string& v) { o.agent.llmVar = v; }, true},
	{"llm-max-turns", [](CliOptions& o, const std::string& v) { o.agent.llmMaxTurns = v; }, true},
	{"llm-max-tokens", [](CliOptions& o, const std::string& v) { o.agent.llmMaxTokens = v; }, true},
	{"llm-timeout", [](CliOptions& o, const std::string& v) { o.agent.llmTimeout = v; }, true},
	{"llm-task-timeout", [](CliOptions& o, const std::string& v) { o.agent.llmTaskTimeout = v; }, true},
};

/* ---- validateOptions 的校验块（2026-09-29 A3 拆分）----
 * 各块违规即打印并返回 2，通过返回 0；判定与文案逐字保持原样，
 * 块间顺序是既有契约（见 validateOptions 编排处的顺序说明）。 */

/* F-20：未知/拼错的 --key 一律拒绝（退出码 2）。
 * 旧行为是静默忽略：`--robott=foo` 打印帮助后 exit 0（CI 里的假成功），
 * `--robot` 拼错还会让程序在「没给结构脚本」的路径上看似正常退出。 */
int rejectUnknownKeys(ParsedArgs& args) {
	if (args.unknown.empty()) { return 0; }
	std::sort(args.unknown.begin(), args.unknown.end());
	for (const auto& key : args.unknown) {
		std::cerr << "未知参数：--" << key << "；用 --help 查看支持的参数" << std::endl;
	}
	return 2;
}

/* N-4：带值键裸写（漏值）在解析层即拒绝，退出码与 unknown 一致 */
int rejectMissingValues(const ParsedArgs& args) {
	for (const auto& key : args.missingValue) {
		std::cerr << "选项 --" << key << " 缺少值；用法：--" << key << " <值>"
			<< "，用 --help 查看说明" << std::endl;
	}
	return args.missingValue.empty() ? 0 : 2;
}

/* --agent 已移除（agent 循环迁 Rust）：在此快速失败。
 * 旧路径会先做 LLM 驱动注入、取消哨兵装配、agent-over-TCP 甚至 accept 一条
 * 连接，才在 main 的「已移除」桩上报错。F-20 同族口径：显式拒绝并退出 2，
 * 文案给出替代用法（新拓扑：mybot --mcp-backend 提供工具后端，
 * mybot-agent 跑模型循环，两者经 --mcp-socket 互联）。 */
int rejectRemovedAgent(const CliOptions& options) {
	if (!options.agent.enabled) { return 0; }
	std::cerr << "参数错误：--agent 已移除（agent 循环已迁 Rust）。替代用法：\n"
		"  1) 启动工具后端：./build/mybot --robot <结构脚本> --mcp-backend "
		"--mcp-socket /tmp/mybot.sock\n"
		"  2) 启动 agent：./agent/target/release/mybot-agent --socket /tmp/mybot.sock\n"
		"（构建 agent：bash scripts/build_agent.sh；详见 docs/agent.md）"
		<< std::endl;
	return 2;
}

/* 模型循环类选项：属于 Rust agent（mybot-agent），本程序一律拒绝。
 * 这些是 mybot-agent 自己的选项面（它另有 --help）；本程序（C++ 宿主）不跑
 * 模型循环。保留解析表条目是为了给出指路的报错，而不是「未知参数」。 */
int rejectLoopOnlyOptions(const CliOptions& options) {
	const char* loopOnly = nullptr;
	if (!options.agent.agentTask.empty()) { loopOnly = "--task"; }
	else if (options.agent.resume) { loopOnly = "--resume"; }
	else if (!options.agent.sessionFile.empty()) { loopOnly = "--session-file"; }
	else if (!options.agent.promptFiles.empty()) { loopOnly = "--prompt-file"; }
	else if (!options.agent.llmEndpoint.empty()) { loopOnly = "--llm-endpoint"; }
	else if (!options.agent.llmModel.empty()) { loopOnly = "--llm-model"; }
	else if (!options.agent.llmConfig.empty()) { loopOnly = "--llm-config"; }
	else if (!options.agent.llmDriver.empty()) { loopOnly = "--llm-driver"; }
	else if (!options.agent.llmVar.empty()) { loopOnly = "--llm-var"; }
	else if (!options.agent.llmMaxTurns.empty()) { loopOnly = "--llm-max-turns"; }
	else if (!options.agent.llmMaxTokens.empty()) { loopOnly = "--llm-max-tokens"; }
	else if (!options.agent.llmTimeout.empty()) { loopOnly = "--llm-timeout"; }
	else if (!options.agent.llmTaskTimeout.empty()) { loopOnly = "--llm-task-timeout"; }
	if (loopOnly == nullptr) { return 0; }
	std::cerr << "参数错误：" << loopOnly << " 属于 Rust agent（mybot-agent，"
		"经 --socket 连接本程序的工具后端）；C++ 宿主侧请用 --mcp-backend"
		<< std::endl;
	return 2;
}

/* 工具门控类选项：只在 --mcp-backend 模式下有效
 * （先于结构脚本装载与任何硬件上电；F-20 同族口径：显式拒绝退出 2，
 * 不静默忽略。） */
int rejectAgentOptionsOutsideBackend(const CliOptions& options) {
	if (options.mcp.enabled || !options.agent.agentOptionsUsed) { return 0; }
	/* PL-5（2026-09-22）：选项名单与 docs 的选项表保持一致——用户敲了
	 * --no-camera 却被报「选项无效」，而文案里没有他刚敲的那一个，
	 * 看起来像撞上了另一个错误。 */
	std::cerr << "参数错误：--agent-shell "
		"/ --agent-hot-sql / --agent-write-file / --agent-policy / --read-var / --scripts-dir "
		"/ --camera-var / --camera-device / --camera-src / --camera-src-dir "
		"/ --no-camera / --audit-log / --check-config / --fs-root 只在 --mcp-backend 模式下有效；"
		"用 --help 查看说明"
		<< std::endl;
	return 2;
}

/* MCP 后端选项在非 backend 模式下出现：拒绝（与 F-20 同口径，组合错
 * 显式拒绝退出 2，不静默忽略。后端复用 agent 的工具上下文选项（能力门控），
 * 但**不跑 loop、不发模型调用**，故 loop/LLM 专属选项一律拒绝
 * （silently ignored 会误导使用者）。 */
int rejectMcpOptionsOutsideBackend(const CliOptions& options) {
	if (options.mcp.enabled) { return 0; }
	if (!options.mcp.mcpSocket.empty()) {
		std::cerr << "参数错误：--mcp-socket 只在 --mcp-backend 模式下有效" << std::endl;
		return 2;
	}
	if (!options.mcp.mcpCallBudget.empty() || !options.mcp.mcpWallClock.empty()
			|| !options.mcp.mcpIdleTimeout.empty()) {
		std::cerr << "参数错误：--mcp-call-budget / --mcp-wall-clock / --mcp-idle-timeout"
			" 只在 --mcp-backend 模式下有效" << std::endl;
		return 2;
	}
	if (!options.mcp.onDisconnect.empty()) {
		std::cerr << "参数错误：--on-disconnect 只在 --mcp-backend 模式下有效"
			"（它是后端连接结束后的安全动作）" << std::endl;
		return 2;
	}
	return 0;
}

/* --mcp-backend 模式内的组合校验（方案 F / 拓扑 F3）：互斥项、必备项与
 * 每连接预算数值。空 = 不限；配置错误不碰真机，故在此单点拒；
 * 数值上限只是防呆（跑飞护栏本就不该设成天文数字）。 */
/* ---- Web SSH（--webshell-port，#24）：端口数字 + 跨机监听必须带 token ----
 * 校验前置（配置错误不碰真机/不监听）：端口非数字或越界即拒；监听地址非
 * 回环（127.0.0.1/localhost）且没给 --webshell-token 时拒绝启动——空口令
 * 暴露交互 shell 的风险比 --tcp 更大（那是单向动作流，这是终端）。 */
int rejectWebshellOptions(const CliOptions& options) {
	if (!options.webshell) { return 0; }
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
	return 0;
}

int validateMcpBackendCombos(const CliOptions& options) {
	if (!options.mcp.enabled) { return 0; }
	if (options.tcp.enabled) {
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
	if (options.mcp.mcpSocket.empty() && !options.agent.checkConfig) {
		std::cerr << "参数错误：--mcp-backend 需要 --mcp-socket <AF_UNIX 路径>"
			"（mybot-agent 经此路径连接后端）" << std::endl;
		return 2;
	}
	if (!options.mcp.mcpCallBudget.empty()
			&& !parseBoundedLong(options.mcp.mcpCallBudget,
				mcp_limits::kCallBudgetMin, mcp_limits::kCallBudgetMax)) {
		std::cerr << rangeErrorText("选项 --mcp-call-budget",
			mcp_limits::kCallBudgetMin, mcp_limits::kCallBudgetMax,
			options.mcp.mcpCallBudget) << std::endl;
		return 2;
	}
	if (!options.mcp.mcpWallClock.empty()
			&& !parseBoundedLong(options.mcp.mcpWallClock,
				mcp_limits::kBudgetSecMin, mcp_limits::kBudgetSecMax)) {
		std::cerr << rangeErrorText("选项 --mcp-wall-clock",
			mcp_limits::kBudgetSecMin, mcp_limits::kBudgetSecMax,
			options.mcp.mcpWallClock) << std::endl;
		return 2;
	}
	/* 空闲超时（A-2）：区间与墙钟同族（最长一天——空闲期不该比墙钟更宽松）。
	 * 0 = 不限（缺省），与既有预算选项同口径。 */
	if (!options.mcp.mcpIdleTimeout.empty()
			&& !parseBoundedLong(options.mcp.mcpIdleTimeout,
				mcp_limits::kBudgetSecMin, mcp_limits::kBudgetSecMax)) {
		std::cerr << rangeErrorText("选项 --mcp-idle-timeout",
			mcp_limits::kBudgetSecMin, mcp_limits::kBudgetSecMax,
			options.mcp.mcpIdleTimeout) << std::endl;
		return 2;
	}
	return 0;
}

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
			out.opts.tcp.enabled = true;
			/* 裸 --tcp：tcp 置位但端口留空，由 openActionSource 报「缺端口号」 */
			if (!noValue) { out.opts.tcp.tcpPort = val; }
		}
		else if (key == "agent") { out.opts.agent.enabled = true; out.opts.agent.agentOptionsUsed = true; }
		else if (key == "agent-shell") {
			out.opts.agent.agentShell = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "agent-hot-sql") {
			out.opts.agent.agentHotSql = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "agent-write-file") {
			/* Phase 5（2026-10-08）：与 --agent-shell/--agent-hot-sql 同形态——
			 * 表外布尔 flag（kValueOptions 只收「带值」选项）。依赖 --fs-root
			 * 非空的跨字段校验在 agentmode.cpp 的 applyGatingLayer（这里只负责
			 * 记录"给了这个开关"，不做字段间关系判断）。 */
			out.opts.agent.agentWriteFile = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "no-camera") {
			out.opts.agent.noCamera = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "resume") {
			out.opts.agent.resume = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "check-config") {
			out.opts.agent.checkConfig = true;
			out.opts.agent.agentOptionsUsed = true;
		}
		else if (key == "mcp-backend") {
			/* 独立模式：不置 agentOptionsUsed（它不是 agent 模式，只是复用 agent
			 * 的工具上下文选项）。组合校验见 validateOptions。 */
			out.opts.mcp.enabled = true;
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
				if (spec->agentOnly) { out.opts.agent.agentOptionsUsed = true; }
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

/* F-20/N-4/agent 选项组合校验：违规即打印并返回退出码 2，通过返回 0。
 * 149 行单函数拆成七个具名校验块（2026-09-29 A3），本函数只留顺序敏感的
 * 编排——块序是既有契约：解析层问题（未知/漏值）先于入口形态（--agent/
 * loop 类）先于工具门控先于 backend 组合；报错文案逐字不变。 */
int validateOptions(ParsedArgs& args) {
	if (int rc = rejectUnknownKeys(args)) { return rc; }
	if (int rc = rejectMissingValues(args)) { return rc; }
	if (int rc = rejectRemovedAgent(args.opts)) { return rc; }
	if (int rc = rejectLoopOnlyOptions(args.opts)) { return rc; }
	if (int rc = rejectAgentOptionsOutsideBackend(args.opts)) { return rc; }
	if (int rc = rejectMcpOptionsOutsideBackend(args.opts)) { return rc; }
	if (int rc = rejectWebshellOptions(args.opts)) { return rc; }
	return validateMcpBackendCombos(args.opts);
}
/* 帮助文本（helpText / helpText(topic) / printHelp / tcpOptionsHelp / rangeText
 * 与五个 topic*Help）已整体迁至 cliargs_help.cpp（2026-10-01 TU 拆分）：
 * 本 TU 只剩参数表与校验器。帮助文案是被字节级单测与 docs/reference.md
 * 黄金比对锚定的对象，独立成数据性 TU 后不再与解析逻辑互相搅动。 */
} // namespace bot

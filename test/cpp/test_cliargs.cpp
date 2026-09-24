/* test_cliargs.cpp —— CLI 解析 / 校验 / 帮助文本的直接锚点（本轮 M0-B1）
 *
 * 背景：parseArgs/validateOptions/print_help 原先定义在 main.cpp 里，而 main.cpp
 * 不参与 mybot_tests 链接，test/ 对这三个名字的引用为 0；~6 个校验分支只有
 * 2 个被黑盒覆盖，`--help` 更是 grep 零命中。搬进 src/cliargs.* 后在此白盒钉住：
 *   1) 未知键 / 带值键缺值 → 退出码 2（F-20 / N-4）
 *   2) agent 选项组合三条拒绝路径 → 退出码 2，合法动作模式 → 0
 *   3) 裸 --tcp 不回落端口（审计中-3）
 *   4) --help 优先级（main 在 validateOptions 之前返回 0）
 *   5) 帮助正文：关键区块存在 + 选项定义集合与 docs/ 的选项表双向一致
 *      （文档漂移从「靠人眼」变成「红」——B1 的黄金测试）
 *
 * 注意：负路径用例会让 validateOptions 按契约向 stderr 打印人话报错，
 * 单测输出里出现「未知参数：」「参数错误：」等行属**预期**，不是失败。
 */

#include <cctype>
#include <fstream>
#include <iterator>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "cliargs.hpp"
#include "harness.hpp"

#ifndef MYBOT_SOURCE_DIR
#define MYBOT_SOURCE_DIR "."
#endif

namespace {

/* argv 构造：parseArgs 从下标 1 开始（0 是程序名），与真实调用一致 */
struct Argv {
	std::vector<std::string> store;
	std::vector<char*> ptrs;
	explicit Argv(std::vector<std::string> a) : store(std::move(a)) {
		for (auto& s : store) { ptrs.push_back(s.data()); }
	}
	int argc() const { return static_cast<int>(ptrs.size()); }
	char** argv() { return ptrs.data(); }
};

std::string readSourceFile(const std::string& rel) {
	std::ifstream f(std::string(MYBOT_SOURCE_DIR) + "/" + rel);
	if (!f) {
		throw std::runtime_error(std::string("无法读取 ") + rel
			+ "（MYBOT_SOURCE_DIR=" MYBOT_SOURCE_DIR "）");
	}
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

/* 从文本中抽取「以 prefix 开头的一行」里的选项名（prefix 之后取 [a-z0-9-] 连续段）。
 * prefix 自带 "--" 时（帮助正文的 "  --" 定义行）结果补回前缀；prefix 不带时
 * （docs 的 "| `" 表格行）只收以 "--" 开头的名字——环境变量行/配置字段行因此被滤掉。 */
std::set<std::string> optionsWithLinePrefix(const std::string& text, const std::string& prefix) {
	const bool prefixHasDashes =
		prefix.size() >= 2 && prefix.compare(prefix.size() - 2, 2, "--") == 0;
	std::set<std::string> out;
	std::size_t pos = 0;
	while (pos < text.size()) {
		std::size_t eol = text.find('\n', pos);
		if (eol == std::string::npos) { eol = text.size(); }
		if (text.compare(pos, prefix.size(), prefix) == 0) {
			std::size_t b = pos + prefix.size();
			std::size_t e = b;
			while (e < eol && (std::isalnum(static_cast<unsigned char>(text[e])) || text[e] == '-')) { ++e; }
			if (e > b) {
				std::string name = text.substr(b, e - b);
				if (prefixHasDashes) { name = "--" + name; }
				if (name.size() > 2 && name.compare(0, 2, "--") == 0) { out.insert(name); }
			}
		}
		pos = eol + 1;
	}
	return out;
}

/* 双向集合差的第一个违例者（空串 = 无违例），便于失败信息点名具体选项 */
std::string firstMissing(const std::set<std::string>& from,
		const std::set<std::string>& have, const std::set<std::string>& allowlist) {
	for (const auto& x : from) {
		if (have.count(x) == 0 && allowlist.count(x) == 0) { return x; }
	}
	return std::string();
}

} // namespace

/* ---- 1) 未知键 / 缺值：退出码 2（F-20 / N-4）---- */

TH_TEST(cliargs_unknown_key_is_rejected_with_exit_2) {
	Argv a({"mybot", "--robot=robots/test.sql", "--bogus=1", "--robotx"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.unknown.size() == 2);
	TH_CHECK(p.unknown[0] == "bogus");
	TH_CHECK(p.unknown[1] == "robotx");
	TH_CHECK(p.opts.robot.has_value());
	TH_CHECK(bot::validateOptions(p) == 2);
}

TH_TEST(cliargs_missing_value_is_rejected_with_exit_2) {
	/* `--robot robots/test.sql` 正常取值；末尾裸写 --tcp-host 判缺值 */
	Argv a({"mybot", "--robot", "robots/test.sql", "--tcp-host"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.missingValue.size() == 1);
	TH_CHECK(p.missingValue[0] == "tcp-host");
	TH_CHECK(p.opts.robot.has_value() && *p.opts.robot == "robots/test.sql");
	TH_CHECK(bot::validateOptions(p) == 2);
}

/* ---- 2) agent 选项组合三条拒绝路径 + 合法动作模式放行 ---- */

TH_TEST(cliargs_agent_only_option_without_agent_is_rejected) {
	Argv a({"mybot", "--robot=robots/test.sql", "--task", "hi"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(!p.opts.agent);
	TH_CHECK(p.opts.agentOptionsUsed);	/* agentOnly 先于缺值检查置位 */
	TH_CHECK(p.opts.agentTask == "hi");
	TH_CHECK(bot::validateOptions(p) == 2);
}

/* 热插表（2026-09-23）：--agent-hot-sql 与 --agent-shell 同属 agent 专属开关——
 * 解析层置位，非 agent 模式下必须被拒（本仓口径：agent 专属选项不静默忽略）。 */
TH_TEST(cliargs_hot_sql_flag_is_agent_only) {
	{	/* agent 模式：放行 */
		Argv a({"mybot", "--agent", "--robot=robots/test.sql", "--agent-hot-sql"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(p.opts.agentHotSql);
		TH_CHECK(p.opts.agentOptionsUsed);
		TH_CHECK(bot::validateOptions(p) == 0);
	}
	{	/* 非 agent 模式：拒绝，退出码 2 */
		Argv a({"mybot", "--robot=robots/test.sql", "--agent-hot-sql"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(p.opts.agentHotSql);		/* 解析层照样置位 */
		TH_CHECK(!p.opts.agent);
		TH_CHECK(bot::validateOptions(p) == 2);
	}
}

/* 回读（2026-09-23，发现 2 的 A 步）：--read-var 是 agentOnly 的**可重复**带值
 * 选项——`=` 与空格两种写法都收，且非 agent 模式下必须被拒。 */
TH_TEST(cliargs_read_var_is_agent_only_and_repeatable) {
	{
		Argv a({"mybot", "--agent", "--robot=robots/test.sql",
			"--read-var=relay0", "--read-var", "timer-0"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 0);
		TH_CHECK(p.opts.readVars.size() == 2);
		TH_CHECK(p.opts.readVars.size() == 2 && p.opts.readVars[0] == "relay0"
			&& p.opts.readVars[1] == "timer-0");
		TH_CHECK(p.opts.agentOptionsUsed);
	}
	{	/* 非 agent 模式：拒绝，退出码 2 */
		Argv a({"mybot", "--robot=robots/test.sql", "--read-var=relay0"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(p.opts.readVars.size() == 1);	/* 解析层照样收 */
		TH_CHECK(!p.opts.agent);
		TH_CHECK(bot::validateOptions(p) == 2);
	}
}

/* A4：--llm-task-timeout 是 agentOnly 的带值选项——解析要落到 llmTaskTimeout，
 * 且在非 agent 模式下必须被拒（本仓口径：agent 专属选项不静默忽略）。 */
TH_TEST(cliargs_task_timeout_option_is_parsed_and_agent_only) {
	{	/* 等号写法 */
		Argv a({"mybot", "--agent", "--robot=robots/test.sql", "--llm-task-timeout=77"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK_MSG(p.opts.llmTaskTimeout == "77", "实际: '" + p.opts.llmTaskTimeout + "'");
		TH_CHECK(p.opts.agentOptionsUsed);
		TH_CHECK(bot::validateOptions(p) == 0);
	}
	{	/* 空格写法（值在下一个 argv） */
		Argv a({"mybot", "--agent", "--robot=robots/test.sql", "--llm-task-timeout", "900"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK_MSG(p.opts.llmTaskTimeout == "900", "实际: '" + p.opts.llmTaskTimeout + "'");
		TH_CHECK(p.missingValue.empty());
	}
	{	/* 0 是合法值（= 不限），不能在解析层被当成缺值 */
		Argv a({"mybot", "--agent", "--robot=robots/test.sql", "--llm-task-timeout", "0"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK_MSG(p.opts.llmTaskTimeout == "0", "实际: '" + p.opts.llmTaskTimeout + "'");
	}
	{	/* 非 agent 模式：拒绝，退出码 2 */
		Argv a({"mybot", "--robot=robots/test.sql", "--llm-task-timeout", "60"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(!p.opts.agent);
		TH_CHECK(p.opts.agentOptionsUsed);
		TH_CHECK(bot::validateOptions(p) == 2);
	}
}

TH_TEST(cliargs_agent_with_tcp_is_accepted_but_task_tcp_is_not) {
	/* 批次 2（2026-09-23）：--agent --tcp 从「互斥」改为「远程 REPL」——
	 * 对本端来说它就是 agent 模式 + 连接式输入源。 */
	Argv a({"mybot", "--agent", "--robot=robots/test.sql", "--tcp=19301"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.opts.agent && p.opts.tcp);
	TH_CHECK(bot::validateOptions(p) == 0);

	/* 仍被拒：--task 与 --tcp（一次性任务没有长驻对话的意义） */
	Argv b({"mybot", "--agent", "--robot=robots/test.sql", "--tcp=19301",
		"--task=x"});
	bot::ParsedArgs q = bot::parseArgs(b.argc(), b.argv());
	TH_CHECK(bot::validateOptions(q) == 2);

	/* 仍被拒：两个输入源都要主导（--agent --tcp --input） */
	Argv c({"mybot", "--agent", "--robot=robots/test.sql", "--tcp=19301",
		"--input=a.mt"});
	bot::ParsedArgs r = bot::parseArgs(c.argc(), c.argv());
	TH_CHECK(bot::validateOptions(r) == 2);

	/* 非 agent 模式的裸 --tcp 不受影响（动作源 TCP 照旧） */
	Argv d({"mybot", "--robot=robots/test.sql", "--tcp=19301"});
	bot::ParsedArgs t = bot::parseArgs(d.argc(), d.argv());
	TH_CHECK(bot::validateOptions(t) == 0);
}

TH_TEST(cliargs_agent_without_robot_is_rejected) {
	Argv a({"mybot", "--agent", "--llm-var", "llm0"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.opts.agentOptionsUsed && !p.opts.robot.has_value());
	TH_CHECK(bot::validateOptions(p) == 2);
}

TH_TEST(cliargs_mcp_backend_mode_validation) {
	/* 缺 --mcp-socket → 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* --mcp-socket 无 --mcp-backend → 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-socket", "/tmp/s"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* 合法后端 → 0 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 0);
	}
	/* 后端 + --agent 互斥 → 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s", "--agent"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* 后端 + --task（loop 专属）→ 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s", "--task", "hi"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* 后端 + 合法预算 → 0，且值落到 opts */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s",
			"--mcp-call-budget", "100", "--mcp-wall-clock", "600"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 0);
		TH_CHECK(p.opts.mcpCallBudget == "100");
		TH_CHECK(p.opts.mcpWallClock == "600");
	}
	/* 预算非整数 → 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s",
			"--mcp-call-budget", "abc"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* 墙钟超上限（>86400）→ 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-backend", "--mcp-socket", "/tmp/s",
			"--mcp-wall-clock", "99999"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
	/* 预算 flag 无 --mcp-backend → 2 */
	{
		Argv a({"mybot", "--robot=r.sql", "--mcp-call-budget", "10"});
		bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
		TH_CHECK(bot::validateOptions(p) == 2);
	}
}

TH_TEST(cliargs_valid_action_mode_args_pass) {
	Argv a({"mybot", "--robot=robots/test.sql"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.unknown.empty() && p.missingValue.empty());
	TH_CHECK(bot::validateOptions(p) == 0);
}

/* ---- 3) 裸 --tcp 不回落端口（审计中-3）---- */

TH_TEST(cliargs_bare_tcp_flag_keeps_port_unset) {
	Argv a({"mybot", "--tcp", "--robot=robots/test.sql"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.opts.tcp);
	TH_CHECK(p.opts.tcpPort.empty());	/* 由 openActionSource 报「缺端口号」 */
	TH_CHECK(bot::validateOptions(p) == 0);
}

TH_TEST(cliargs_tcp_with_equals_and_separate_value_forms) {
	Argv eq({"mybot", "--tcp=19301", "--robot=robots/test.sql"});
	bot::ParsedArgs p1 = bot::parseArgs(eq.argc(), eq.argv());
	TH_CHECK(p1.opts.tcp && p1.opts.tcpPort == "19301");

	Argv sep({"mybot", "--tcp", "19302", "--robot=robots/test.sql"});
	bot::ParsedArgs p2 = bot::parseArgs(sep.argc(), sep.argv());
	TH_CHECK(p2.opts.tcp && p2.opts.tcpPort == "19302");
}

/* ---- F-1/F-2/F-3（2026-09-22，原 TD-2 剩余部分）：三个新选项解析进对应字段 ----
 * 区间校验本身在 openActionSource（tcp 两项）/ main.cpp applyDaemonGraceMs
 * （daemon-grace-ms）完成，这里只钉「解析层原样透传字符串」——与既有
 * tcpPort/tcpIdle 的惯例一致，避免解析层与校验层的判据重复。 */

TH_TEST(cliargs_parses_tcp_auth_and_total_timeout_and_daemon_grace) {
	Argv a({"mybot", "--robot=robots/test.sql", "--tcp-max-auth-attempts", "10",
		"--tcp-total-timeout", "900", "--daemon-grace-ms", "5000"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.opts.tcpMaxAuthAttempts == "10");
	TH_CHECK(p.opts.tcpTotalTimeout == "900");
	TH_CHECK(p.opts.daemonGraceMs == "5000");
	/* 三者都不是 agentOnly：非 agent 模式下合法使用 */
	TH_CHECK(!p.opts.agentOptionsUsed);
	TH_CHECK(bot::validateOptions(p) == 0);
}

TH_TEST(cliargs_new_timeout_options_missing_value_is_rejected) {
	Argv a({"mybot", "--robot=robots/test.sql", "--daemon-grace-ms"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.missingValue.size() == 1 && p.missingValue[0] == "daemon-grace-ms");
	TH_CHECK(bot::validateOptions(p) == 2);
}

/* ---- PL-1（2026-09-22）：--check-config 的 CLI 面 ----
 * 三条断言对应三条真实路径：agent 模式下放行；非 agent 模式被 agent 专属选项
 * 那条拒绝；**agent 模式但漏了 --robot 也必须拒绝**——后者是这条选项最容易漏的
 * 坑：main 的既有行为是「没有 --robot → 打印帮助 + 退出 0」，若不在校验层拦住，
 * 校验模式会以 0 退出却什么都没校验，CI 会把它读成「配置没问题」。 */
TH_TEST(cliargs_check_config_is_rejected_outside_agent_mode) {
	Argv a({"mybot", "--robot=robots/relay-test.sql", "--agent", "--check-config"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.opts.checkConfig);
	TH_CHECK(p.opts.agentOptionsUsed);
	TH_CHECK(bot::preflightCli(p) == bot::Preflight::Proceed);

	Argv b({"mybot", "--robot=robots/relay-test.sql", "--check-config"});
	bot::ParsedArgs q = bot::parseArgs(b.argc(), b.argv());
	TH_CHECK(q.opts.checkConfig);		/* 解析层照样置位 */
	TH_CHECK(bot::preflightCli(q) == bot::Preflight::ConfigError);

	Argv c({"mybot", "--agent", "--check-config"});		/* 漏 --robot */
	bot::ParsedArgs s = bot::parseArgs(c.argc(), c.argv());
	TH_CHECK(bot::preflightCli(s) == bot::Preflight::ConfigError);
}

/* ---- 4) --help 优先级：先 help 后校验（顺序判定在 preflightCli）---- */

TH_TEST(cliargs_help_precedes_validation_in_main) {
	/* PL-4（2026-09-22）：这条用例此前**名不副实**：名字写着 in_main，函数体却只调
	 * parseArgs，而 main 链接不进 mybot_tests——把 main 里的 help 检查挪到校验之后
	 * 照样绿。现在顺序判定搬进了 preflightCli（可链接），这里才真的钉得住：
	 * 若把它挪到 validateOptions 之后，第一条断言转红。 */
	Argv a({"mybot", "--help", "--bogus=1"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(bot::preflightCli(p) == bot::Preflight::Help);	/* help 短路，未知键不报错 */
	TH_CHECK(p.opts.help);
	TH_CHECK(!p.unknown.empty());		/* 解析层照样记录，只是这条路不消费它 */

	/* 没有 --help 时才轮到校验：非法键在此被拒（错误由 validateOptions 打印） */
	Argv b({"mybot", "--bogus=1"});
	bot::ParsedArgs q = bot::parseArgs(b.argc(), b.argv());
	TH_CHECK(bot::preflightCli(q) == bot::Preflight::ConfigError);

	/* 正路：两个都没有 → 继续流水线 */
	Argv c({"mybot", "--robot=robots/relay-test.sql"});
	bot::ParsedArgs s = bot::parseArgs(c.argc(), c.argv());
	TH_CHECK(bot::preflightCli(s) == bot::Preflight::Proceed);
}

/* ---- 5) 帮助正文：区块 + 与 docs/ 选项表双向一致（黄金测试）---- */

TH_TEST(cliargs_help_text_covers_key_sections) {
	const std::string h = bot::helpText();
	TH_CHECK(h.find("动作输入源（优先级从高到低）：") != std::string::npos);
	TH_CHECK(h.find("agent 模式（与上面的动作输入源互斥）") != std::string::npos);
	TH_CHECK(h.find("取值优先级：命令行 > 环境变量 > 配置文件 > 驱动内置缺省。") != std::string::npos);
	TH_CHECK(h.find("示例：") != std::string::npos);
	TH_CHECK(h.find("安全约束：动作脚本只能引入新的参数键") != std::string::npos);
	TH_CHECK(h.find("结构脚本与动作脚本单次输入上限均为 8 MiB。") != std::string::npos);
}

TH_TEST(cliargs_help_option_set_matches_docs) {
	/* 帮助里的选项定义行（两空格 + "--"） */
	const std::set<std::string> defs = optionsWithLinePrefix(bot::helpText(), "  --");
	TH_CHECK(defs.count("--tcp") == 1);
	TH_CHECK(defs.count("--prompt-file") == 1);
	TH_CHECK(defs.count("--agent-shell") == 1);
	/* A4：单任务墙钟预算的命令行入口（与 --llm-timeout 不同维度） */
	TH_CHECK(defs.count("--llm-task-timeout") == 1);
	/* H1：capture_image 白名单根目录（命令行独占，配置文件写它会被拒绝加载） */
	TH_CHECK(defs.count("--camera-src-dir") == 1);
	/* 已移除的选项不得在帮助里复活（2026-09-20 评估：--llm-key 明文 argv；
	 * --agent-shell 顶掉 --agent-no-shell，故净减 1；A4/H1 各加回 1 条） */
	TH_CHECK(defs.count("--llm-key") == 0);
	TH_CHECK(defs.count("--agent-no-shell") == 0);
	/* 分段帮助（2026-09-22）把 --help <topic> 四行并入帮助正文（23），审计轨迹
	 * （--audit-log，2026-09-22）再加一项（24），策略钩子（--agent-policy，
	 * 2026-09-22）再加一项（25）。F-1/F-2/F-3（2026-09-22，原 TD-2 剩余部分）
	 * 再加三项——--tcp-max-auth-attempts / --tcp-total-timeout /
	 * --daemon-grace-ms（28）。PL-1（2026-09-22）加 --check-config（29）。第七轮审计
	 * （2026-09-22）再加两项——--llm-task-timeout（A4 单任务墙钟预算）与
	 * --camera-src-dir（H1 白名单根，命令行独占）（31）。热插表（2026-09-23）再加
	 * 一项——--agent-hot-sql（apply_sql 显式开关，配置文件不能开）（32）。回读
	 * （2026-09-23，发现 2 的 A 步）再加一项——--read-var（read_variables 的可读
	 * 清单，可重复，配置文件不能开）（33）。会话持久化（2026-09-23，批次 1）
	 * 再加两项——--session-file（会话文件，写入可进配置文件）与 --resume（恢复，
	 * 路径只认命令行）（35）。Web SSH（2026-09-24）再加三项——--webshell-port /
	 * --webshell-host / --webshell-token（38）。计数断言
	 * 是「帮助 ↔ docs 双向一致」守卫的一部分：随选项增删同步更新。 */
	TH_CHECK(defs.size() == 38);
	TH_CHECK(defs.count("--session-file") == 1);
	TH_CHECK(defs.count("--resume") == 1);
	TH_CHECK(defs.count("--webshell-port") == 1);
	TH_CHECK(defs.count("--webshell-host") == 1);
	TH_CHECK(defs.count("--webshell-token") == 1);
	TH_CHECK(defs.count("--help") == 1);
	TH_CHECK(defs.count("--audit-log") == 1);
	TH_CHECK(defs.count("--agent-policy") == 1);
	TH_CHECK(defs.count("--tcp-max-auth-attempts") == 1);
	TH_CHECK(defs.count("--tcp-total-timeout") == 1);
	TH_CHECK(defs.count("--daemon-grace-ms") == 1);
	TH_CHECK(defs.count("--check-config") == 1);

	/* docs 侧：reference.md（CLI 参考）与 agent.md（agent 专属选项表）的选项表行 */
	const std::set<std::string> ref =
		optionsWithLinePrefix(readSourceFile("docs/reference.md"), "| `");
	std::set<std::string> docs = ref;
	for (const auto& o : optionsWithLinePrefix(readSourceFile("docs/agent.md"), "| `")) {
		docs.insert(o);
	}
	TH_CHECK(docs.size() >= 24);

	/* 方向一（逐文档，2026-09-20 评估收口）：帮助里的**每个**选项都必须在
	 * reference.md 有记录。此前只查「并集」，于是 reference.md 缺 --prompt-file
	 * 被 agent.md 的同名行掩盖——而 reference.md 自称收录全部可调接口。
	 * agent.md 是 agent 专属子集，不要求它覆盖全部。 */
	const std::string undocumented = firstMissing(defs, ref, {});
	TH_CHECK_MSG(undocumented.empty(),
		"帮助里的选项在 docs/reference.md 无记录（该文档自称收录全部可调接口）: " + undocumented);

	/* 方向二：docs 记录的选项都必须在帮助里有定义行——例外仅 --help（帮助自身的
	 * 开关，由惯例与错误提示覆盖）与 --robot（帮助首段与示例里已给出用法）。 */
	const std::string undef = firstMissing(docs, defs, {"--help", "--robot"});
	TH_CHECK_MSG(undef.empty(), "docs 记录了但帮助缺定义行的选项: " + undef);
}

TH_TEST(cliargs_removed_options_are_unknown_keys) {
	/* --llm-key / --agent-no-shell 已从选项表移除（2026-09-20 评估）：
	 * 残留用法必须显式报错（退出码 2），不得静默忽略成「没传」。 */
	Argv a({"mybot", "--robot=robots/test.sql", "--agent", "--llm-key=sk-x"});
	bot::ParsedArgs p = bot::parseArgs(a.argc(), a.argv());
	TH_CHECK(p.unknown.size() == 1 && p.unknown[0] == "llm-key");
	TH_CHECK(bot::validateOptions(p) == 2);

	Argv b({"mybot", "--robot=robots/test.sql", "--agent", "--agent-no-shell"});
	bot::ParsedArgs q = bot::parseArgs(b.argc(), b.argv());
	TH_CHECK(q.unknown.size() == 1 && q.unknown[0] == "agent-no-shell");
	TH_CHECK(bot::validateOptions(q) == 2);
}

/* 环境变量完整性（2026-09-20 评估）：reference.md 的环境变量表自称「全部」，
 * 但此前漏了 BOT4CJ_HAL_BACKEND / BOT4CJ_CAMERA_SRC_DIR / BOT4CJ_TEST_VIDEO。
 * 这里把该声明变成机械判据：源码/脚本里出现的 BOT4CJ_* 环境变量名必须在
 * reference.md 有记录。内嵌 Lua 重入口守卫用的是 `__BOT4CJ_*` 前缀的全局
 * （不是环境变量），扫描时按「前面不是下划线」排除掉。 */
TH_TEST(cliargs_env_vars_documented_in_reference) {
	static const char* kFiles[] = {
		"src/agentmode.cpp", "src/agenttools.cpp", "src/actionsource.cpp",
		"src/luasandbox.cpp", "src/main.cpp", "src/llmconfig.cpp",
		"modules/lib/HAL.lua", "modules/lib/virtbus.lua", "modules/Camera.lua",
		"test/lib/device_gate.sh", "scripts/agent_e2e.sh",
	};
	const std::string doc = readSourceFile("docs/reference.md");
	std::set<std::string> found;
	for (const char* rel : kFiles) {
		std::string text;
		try { text = readSourceFile(rel); } catch (const std::exception&) { continue; }
		for (std::size_t i = 0; i + 7 < text.size(); ++i) {
			if (text.compare(i, 7, "BOT4CJ_") != 0) { continue; }
			if (i > 0 && text[i - 1] == '_') { continue; }	/* __BOT4CJ_* = 守卫全局 */
			std::size_t e = i + 7;
			while (e < text.size()
					&& (std::isupper(static_cast<unsigned char>(text[e]))
						|| std::isdigit(static_cast<unsigned char>(text[e]))
						|| text[e] == '_')) {
				++e;
			}
			if (e > i + 7) { found.insert(text.substr(i, e - i)); }
		}
	}
	/* 已知被扫描到的集合至少含这 5 个（防扫描本身失效变成空集假绿） */
	TH_CHECK(found.size() >= 5);
	std::string missing;
	for (const auto& v : found) {
		if (doc.find(v) == std::string::npos) { missing += " " + v; }
	}
	TH_CHECK_MSG(missing.empty(),
		"docs/reference.md 环境变量表缺失（该文档自称收录全部）:" + missing);
}

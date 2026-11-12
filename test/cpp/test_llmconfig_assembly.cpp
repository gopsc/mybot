/* test_llmconfig_assembly.cpp —— buildAgentConfig：优先级合并与工具门控
 *
 * 2026-10-04 自 test_llmconfig.cpp 按域拆出（行为保持，断言逐字搬迁）：
 * 命令行/环境变量/配置文件/内置缺省四层合并、安全缺省翻转（allow_shell/
 * allow_hot_sql 只能命令行开）、--mcp-backend 危险能力的策略门控、
 * --llm-config 查找链（none/环境变量/命令行优先级）。
 * 共用的 writeFile/NoKeyEnv/baseOptions 见 test_llmconfig.cpp 同名匿名
 * 命名空间件（各 TU 自留一份，不升级为跨 TU 契约）。
 */
#include "fixtures.hpp"
#include "harness.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <system_error>

#include "agentmode.hpp"
#include "agenttools.hpp"
#include "llmconfig.hpp"
#include "robot.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;
using fx::TempDir;
using fx::EnvVar;

namespace {

void writeFile(const fs::path& p, const std::string& content, fs::perms mode) {
	std::ofstream f(p, std::ios::binary);
	f << content;
	f.close();
	std::error_code ec;
	fs::permissions(p, mode, ec);
}

/* 清空整条密钥链，让「密钥来自哪里」在用例里是确定的 */
struct NoKeyEnv {
	EnvVar a{"BOT4CJ_LLM_KEY", nullptr};
	EnvVar b{"ROBOT_AGENT_API_KEY", nullptr};
	EnvVar c{"DEEPSEEK_API_KEY", nullptr};
	EnvVar d{"BOT4CJ_LLM_CONFIG", nullptr};
	EnvVar e{"BOT4CJ_LLM_ENDPOINT", nullptr};
	EnvVar f{"BOT4CJ_LLM_MODEL", nullptr};
};

CliOptions baseOptions(const std::string& configPath) {
	CliOptions o;
	o.agent.enabled = true;
	o.robot = std::string("./robots/relay-test.sql");
	o.agent.llmConfig = configPath;
	return o;
}

} // namespace

/* ================= buildAgentConfig：优先级与合并 ================= */

TH_TEST(agentconfig_backend_tool_budgets_reach_execution_context) {
	NoKeyEnv nokey;
	TempDir tmp("backend-budgets");
	const fs::path cfg = tmp.path() / "config.json";
	EnvVar configEnv("BOT4CJ_LLM_CONFIG", cfg.c_str());
	CliOptions opts;
	opts.mcp.enabled = true;
	opts.agent.noCamera = true;
	MemoryReader input("");
	RobotStruct robot(input);
	for (const int scriptSeconds : {7, 0}) {
		writeFile(cfg, "{\"run_command_timeout_sec\":3,\"run_command_max_timeout_sec\":5,"
			"\"action_script_timeout_sec\":" + std::to_string(scriptSeconds) + "}",
			fs::perms::owner_all);
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(opts, out, err), err);
		std::ostringstream log;
		const auto ctx = makeToolContext(out, robot, log);
		TH_CHECK(ctx.commandTimeoutSec == 3);
		TH_CHECK(ctx.maxCommandTimeoutSec == 5);
		TH_CHECK(ctx.scriptTimeoutSec == scriptSeconds);
	}
}

TH_TEST(agentconfig_backend_tool_budgets_validate_effective_values) {
	NoKeyEnv nokey;
	TempDir tmp("backend-budget-invalid");
	const fs::path cfg = tmp.path() / "config.json";
	EnvVar configEnv("BOT4CJ_LLM_CONFIG", cfg.c_str());
	CliOptions opts;
	opts.mcp.enabled = true;
	for (const char* body : {
		R"({"run_command_max_timeout_sec":5})",
		R"({"run_command_timeout_sec":20,"run_command_max_timeout_sec":10})",
	}) {
		writeFile(cfg, body, fs::perms::owner_all);
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(opts, out, err));
		TH_CHECK_MSG(err.find("run_command_max_timeout_sec") != std::string::npos, err);
	}
}

TH_TEST(agentconfig_backend_tool_budgets_keep_defaults) {
	NoKeyEnv nokey;
	EnvVar configEnv("BOT4CJ_LLM_CONFIG", "none");
	CliOptions opts;
	opts.mcp.enabled = true;
	opts.agent.noCamera = true;
	AgentModeConfig out;
	std::string err;
	TH_CHECK_MSG(buildAgentConfig(opts, out, err), err);
	MemoryReader input("");
	RobotStruct robot(input);
	std::ostringstream log;
	const auto ctx = makeToolContext(out, robot, log);
	TH_CHECK(ctx.commandTimeoutSec == 10);
	TH_CHECK(ctx.maxCommandTimeoutSec == 60);
	TH_CHECK(ctx.scriptTimeoutSec == 180);
}

TH_TEST(agentconfig_run_command_timeout_cap_below_default_is_rejected) {
	/* 跨字段关系按**生效值**判：只配上限（5 < 缺省 10）也要被挡下——否则模型
	 * 不传 timeout_seconds 时按缺省请求 10s 会越过操作者声明的 5s 上限 */
	NoKeyEnv nokey;
	TempDir tmp("runtime-cross");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"api_key":"k","run_command_max_timeout_sec":5})", fs::perms::owner_all);
	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(baseOptions(cfg.string()), out, err));
	TH_CHECK_MSG(err.find("run_command_max_timeout_sec") != std::string::npos, err);

	/* 成对调小时合法（这才是正当用法：不重试 + 短超时的离线场景） */
	fs::path ok = tmp.path() / "ok.json";
	writeFile(ok, R"({"api_key":"k","run_command_timeout_sec":3,"run_command_max_timeout_sec":5})",
		fs::perms::owner_all);
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK_MSG(buildAgentConfig(baseOptions(ok.string()), out2, err2), err2);
	TH_CHECK(out2.commandTimeoutSec == 3);
	TH_CHECK(out2.maxCommandTimeoutSec == 5);
}

/* 安全缺省翻转（2026-09-20 评估 C12）+ 审计 4.1 收紧：run_command 缺省**不注册**，
 * 且开启是**命令行独占**的显式选择（--agent-shell）；配置文件的 allow_shell
 * 只能关不能开，写 true 直接拒绝加载——「一个落地配置文件就能开出主机 shell」不成立。 */
TH_TEST(agentconfig_shell_is_off_by_default_and_on_by_explicit_flag) {
	NoKeyEnv nokey;
	TempDir tmp("shell");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({})", fs::perms::owner_all);

	/* 1) 缺省：不注册 run_command */
	AgentModeConfig out;
	std::string err;
	TH_CHECK(buildAgentConfig(baseOptions(cfg.string()), out, err));
	TH_CHECK(!out.allowShell);

	/* 2) --agent-shell：注册 run_command */
	CliOptions o = baseOptions(cfg.string());
	o.agent.agentShell = true;
	AgentModeConfig out2;
	TH_CHECK(buildAgentConfig(o, out2, err));
	TH_CHECK(out2.allowShell);

	/* 3) 审计 4.1 收紧：配置文件**不能**开 shell（只能关）。
	 * 缺省查找会读 CWD 的 ./mybot.llm.json，所以「配置能开」实际等于
	 * 「一个未经审查的落地文件就能把主机 shell 交给模型」，而同一个文件还能改
	 * endpoint 把上下文外发——「文件存在」不构成授权。报错必须指名 allow_shell
	 * 与 --agent-shell，否则用户只看到"配置加载失败"，不知道该删哪个字段。 */
	fs::path cfg2 = tmp.path() / "shell.json";
	writeFile(cfg2, R"({"allow_shell":true})", fs::perms::owner_all);
	AgentModeConfig out3;
	std::string err3;
	TH_CHECK(!buildAgentConfig(baseOptions(cfg2.string()), out3, err3));
	TH_CHECK(err3.find("allow_shell") != std::string::npos);
	TH_CHECK(err3.find("--agent-shell") != std::string::npos);

	/* 4) 命令行已授权时，配置里同向写 true 不该报错（授权来自命令行） */
	CliOptions o2 = baseOptions(cfg2.string());
	o2.agent.agentShell = true;
	AgentModeConfig out4;
	std::string err4;
	TH_CHECK(buildAgentConfig(o2, out4, err4));
	TH_CHECK(out4.allowShell);
}

/* 热插表（2026-09-23）：apply_sql 与 run_command 同一条门控链——缺省不注册，
 * 开启是**命令行独占**的显式选择（--agent-hot-sql），配置文件的 allow_hot_sql
 * 只能关不能开。判据同上一条：apply_sql 会按模型给的 SQL 立即装配新硬件并给它
 * 上电（开真机 fd、进断电清理链），而缺省查找会读 CWD 的 ./mybot.llm.json，
 * 「文件存在」不构成授权。 */
TH_TEST(agentconfig_hot_sql_is_off_by_default_and_on_by_explicit_flag) {
	NoKeyEnv nokey;
	TempDir tmp("hotsql");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"api_key":"k"})", fs::perms::owner_all);

	/* 1) 缺省：不注册 apply_sql */
	{
		AgentModeConfig out;
		std::string err;
		TH_CHECK(buildAgentConfig(baseOptions(cfg.string()), out, err));
		TH_CHECK(!out.allowHotSql);
	}
	/* 2) --agent-hot-sql：注册 */
	{
		CliOptions o = baseOptions(cfg.string());
		o.agent.agentHotSql = true;
		AgentModeConfig out;
		std::string err;
		TH_CHECK(buildAgentConfig(o, out, err));
		TH_CHECK(out.allowHotSql);
	}
	/* 3) 配置文件写 true → 拒绝加载，报错必须点名字段与正确入口 */
	{
		fs::path bad = tmp.path() / "hot.json";
		writeFile(bad, R"({"api_key":"k","allow_hot_sql":true})", fs::perms::owner_all);
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(baseOptions(bad.string()), out, err));
		TH_CHECK_MSG(err.find("allow_hot_sql") != std::string::npos, "报错应点名字段: " + err);
		TH_CHECK_MSG(err.find("--agent-hot-sql") != std::string::npos, "报错应给出正确入口: " + err);
	}
	/* 4) 命令行已授权时，配置里同向写 true 不该报错（授权来自命令行）；
	 *    写 false 是「只能收紧」，缺省即 false，同样放行 */
	{
		fs::path bad = tmp.path() / "hot.json";
		CliOptions o = baseOptions(bad.string());
		o.agent.agentHotSql = true;
		AgentModeConfig out;
		std::string err;
		TH_CHECK(buildAgentConfig(o, out, err));
		TH_CHECK(out.allowHotSql);

		fs::path off = tmp.path() / "off.json";
		writeFile(off, R"({"api_key":"k","allow_hot_sql":false})", fs::perms::owner_all);
		AgentModeConfig out2;
		std::string err2;
		TH_CHECK_MSG(buildAgentConfig(baseOptions(off.string()), out2, err2), err2);
		TH_CHECK(!out2.allowHotSql);
	}
}

TH_TEST(agentconfig_mcp_backend_requires_policy_for_dangerous_caps) {
	/* M5（评估 §3.2，用户定「折中」）：--mcp-backend 开了危险能力就必须有策略钩子、
	 * 且 require_confirm 命中相应工具；纯只读/动作脚本后端不受约束。
	 * 后端跳过密钥解析（不调模型），故无需 API key。 */
	TempDir tmp("mcppolicy");
	fs::path gateBoth = tmp.path() / "both.json";
	writeFile(gateBoth,
		R"({"require_confirm":["run_command","apply_sql"],"confirm_command":"/bin/true"})",
		fs::perms::owner_all);
	fs::path gateShellOnly = tmp.path() / "shellonly.json";
	writeFile(gateShellOnly,
		R"({"require_confirm":["run_command"],"confirm_command":"/bin/true"})",
		fs::perms::owner_all);

	auto backendOpts = []() {
		CliOptions o;
		o.mcp.enabled = true;	/* 注意：不是 agent 模式 */
		o.robot = std::string("./robots/relay-test.sql");
		o.agent.llmConfig = "none";	/* 不查 CWD 配置 */
		o.mcp.mcpSocket = "/tmp/mcp-backend-test.sock";
		return o;
	};

	/* ① 后端 + --agent-shell，无策略 → 拒，且报错点名 run_command */
	{
		CliOptions o = backendOpts();
		o.agent.agentShell = true;
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(o, out, err));
		TH_CHECK(err.find("run_command") != std::string::npos);
	}
	/* ② 后端 + --agent-shell + 策略命中 run_command → 放行 */
	{
		CliOptions o = backendOpts();
		o.agent.agentShell = true;
		o.agent.agentPolicy = gateBoth.string();
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
	}
	/* ③ 折中：后端未开危险能力（纯只读/动作脚本），无策略 → 放行 */
	{
		CliOptions o = backendOpts();
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
	}
	/* ④ 后端 + --agent-hot-sql，策略只命中 run_command（漏 apply_sql）→ 拒，点名 apply_sql */
	{
		CliOptions o = backendOpts();
		o.agent.agentHotSql = true;
		o.agent.agentPolicy = gateShellOnly.string();
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(o, out, err));
		TH_CHECK(err.find("apply_sql") != std::string::npos);
	}
}

TH_TEST(agentconfig_missing_explicit_config_is_an_error) {
	NoKeyEnv nokey;
	AgentModeConfig out;
	std::string err;
	/* 显式给了路径却读不到：必须报错，不能静默回落到缺省（否则用户以为配置生效了） */
	TH_CHECK(!buildAgentConfig(baseOptions("/no/such/mybot.llm.json"), out, err));
	TH_CHECK(err.find("无法打开") != std::string::npos);
}

TH_TEST(agentconfig_none_disables_config_lookup) {
	/* 缺省查找会看 CWD 里的 ./mybot.llm.json；CI/守门与「换台机器跑同一条命令」
	 * 都需要确定性，故必须有显式关闭开关（实测：开发者个人配置会悄悄改变测试
	 * 结果）。证明「确实没读文件」的硬证据：文件里写后端**仍消费**的活字段
	 * （scripts_dir / run_command_timeout_sec），none 时它们必须保持内置缺省。 */
	TempDir tmp("none");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"scripts_dir":"from-file","run_command_timeout_sec":33})",
		fs::perms::owner_all);

	/* A) 命令行 --llm-config=none：文件里的活字段一个都不该生效 */
	{
		AgentModeConfig a;
		std::string e;
		TH_CHECK_MSG(buildAgentConfig(baseOptions("none"), a, e), e);
		TH_CHECK(a.configPath.empty());
		TH_CHECK(a.scriptsDir == "scripts");		/* 内置缺省，非 from-file */
		TH_CHECK(a.commandTimeoutSec == 10);		/* 内置缺省，非 33 */
	}
	/* B) 环境变量 BOT4CJ_LLM_CONFIG=none 同样生效（此处不给 --llm-config，
	 *    本该走缺省查找读到 CWD 的 ./mybot.llm.json） */
	{
		EnvVar envCfg{"BOT4CJ_LLM_CONFIG", "none"};
		AgentModeConfig a;
		std::string e;
		TH_CHECK_MSG(buildAgentConfig(baseOptions(""), a, e), e);
		TH_CHECK(a.configPath.empty());
		TH_CHECK(a.scriptsDir == "scripts");
		TH_CHECK(a.commandTimeoutSec == 10);
	}
}

TH_TEST(agentconfig_config_path_from_env) {
	TempDir tmp("envcfg");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"scripts_dir":"env-scripts"})", fs::perms::owner_all);

	NoKeyEnv nokey;
	EnvVar envCfg{"BOT4CJ_LLM_CONFIG", cfg.string().c_str()};

	CliOptions o = baseOptions("");	/* 不给 --llm-config，走环境变量 */
	AgentModeConfig out;
	std::string err;
	TH_CHECK(buildAgentConfig(o, out, err));
	TH_CHECK(out.configPath == cfg.string());
	/* 活字段生效 = 文件确被读取（不只是记了个路径） */
	TH_CHECK(out.scriptsDir == "env-scripts");

	/* --llm-config 压过环境变量 */
	TempDir tmp2("envcfg2");
	fs::path cfg2 = tmp2.path() / "llm2.json";
	writeFile(cfg2, R"({"scripts_dir":"cli-scripts"})", fs::perms::owner_all);
	AgentModeConfig out2;
	TH_CHECK(buildAgentConfig(baseOptions(cfg2.string()), out2, err));
	TH_CHECK(out2.configPath == cfg2.string());
	TH_CHECK(out2.scriptsDir == "cli-scripts");
}

/* 回读清单只能命令行给（发现 2 的 A 步）：配置文件写 read_vars 一律拒绝加载，
 * 并**指名**正确的入口——与 allow_shell / camera_src_dir 同判据。 */
TH_TEST(agentconfig_read_vars_from_config_is_rejected) {
	NoKeyEnv nokey;
	EnvVar envKey{"BOT4CJ_LLM_KEY", "env-key"};
	TempDir tmp("readvars");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"read_vars":["relay0","timer-0"]})", fs::perms::owner_all);

	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(baseOptions(cfg.string()), out, err));
	TH_CHECK(err.find("read_vars") != std::string::npos);
	TH_CHECK(err.find("--read-var") != std::string::npos);
	/* 附带判据：即使命令行也给了 --read-var，配置里的 read_vars 仍被拒——
	 * 这条字段的口径是「配置文件只能收紧不能放宽」（与 camera_src_dir 一致，
	 * 不采用 --agent-shell 那种「命令行已授权就放行」的合并语义）。 */
	writeFile(cfg, R"({"read_vars":["relay0"]})", fs::perms::owner_all);
	CliOptions o = baseOptions(cfg.string());
	o.agent.readVars.push_back("timer-0");
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK(!buildAgentConfig(o, out2, err2));
	TH_CHECK(err2.find("read_vars") != std::string::npos);
}

/* Phase 4（2026-10-07）：list_dir / read_file 的只读根目录——命令行独占，同
 * read_vars/camera_src_dir 判据：配置文件写 fs_root 一律拒绝加载并指名入口。 */
TH_TEST(agentconfig_fs_root_from_config_is_rejected) {
	NoKeyEnv nokey;
	TempDir tmp("fsroot-config");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"fs_root":"/tmp"})", fs::perms::owner_all);

	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(baseOptions(cfg.string()), out, err));
	TH_CHECK(err.find("fs_root") != std::string::npos);
	TH_CHECK(err.find("--fs-root") != std::string::npos);

	/* 即使命令行也给了 --fs-root，配置里的 fs_root 仍被拒（只能收紧不能放宽） */
	CliOptions o = baseOptions(cfg.string());
	o.agent.fsRoot = tmp.path().string();
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK(!buildAgentConfig(o, out2, err2));
	TH_CHECK(err2.find("fs_root") != std::string::npos);
}

/* --fs-root 在上电前预检存在性（同 --on-disconnect 口径）：拼错目录名要在配置期
 * 就失败，而不是等模型第一次调 list_dir 才发现。 */
TH_TEST(agentconfig_fs_root_requires_existing_directory) {
	NoKeyEnv nokey;
	TempDir tmp("fsroot-missing");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({})", fs::perms::owner_all);

	CliOptions o = baseOptions(cfg.string());
	o.agent.fsRoot = (tmp.path() / "no-such-dir").string();
	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(o, out, err));
	TH_CHECK_MSG(err.find("--fs-root") != std::string::npos, err);

	/* 存在但不是目录（是个文件）同样拒绝 */
	fs::path notADir = tmp.path() / "plain.txt";
	writeFile(notADir, "x", fs::perms::owner_all);
	CliOptions o2 = baseOptions(cfg.string());
	o2.agent.fsRoot = notADir.string();
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK(!buildAgentConfig(o2, out2, err2));
	TH_CHECK_MSG(err2.find("--fs-root") != std::string::npos, err2);
}

/* 合法根目录：buildAgentConfig 通过、makeToolContext 把它原样传进 AgentToolContext
 * （沙箱判据单点在 resolveUnderRoot，这里只钉"配置层把值传到了工具层"）。 */
TH_TEST(agentconfig_fs_root_valid_directory_reaches_tool_context) {
	NoKeyEnv nokey;
	TempDir tmp("fsroot-ok");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({})", fs::perms::owner_all);

	CliOptions o = baseOptions(cfg.string());
	o.agent.fsRoot = tmp.path().string();
	AgentModeConfig out;
	std::string err;
	TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
	TH_CHECK(out.fsRoot == tmp.path().string());

	MemoryReader input("");
	RobotStruct robot(input);
	std::ostringstream log;
	const auto ctx = makeToolContext(out, robot, log);
	TH_CHECK(ctx.fsRoot == tmp.path().string());

	/* 缺省（未给 --fs-root）：fsRoot 为空 */
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK_MSG(buildAgentConfig(baseOptions(cfg.string()), out2, err2), err2);
	TH_CHECK(out2.fsRoot.empty());
}

/* ================= Phase 5（2026-10-08）：write_file ================= */

/* 配置文件写 allow_write_file：未给命令行开关时一律拒绝加载（只能收紧不能放宽，
 * 与 allow_shell 同判据）。命令行已授权时配置里同向写 true 不报错（授权来自
 * 命令行）——与 agentconfig_shell_... 的 case ④ 逐字同款。 */
TH_TEST(agentconfig_write_file_from_config_is_rejected) {
	NoKeyEnv nokey;
	TempDir tmp("writefile-config");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({"allow_write_file":true})", fs::perms::owner_all);

	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(baseOptions(cfg.string()), out, err));
	TH_CHECK(err.find("allow_write_file") != std::string::npos);
	TH_CHECK(err.find("--agent-write-file") != std::string::npos);

	/* 命令行已授权（--agent-write-file + --fs-root）时，配置里同向写 true 放行 */
	CliOptions o = baseOptions(cfg.string());
	o.agent.agentWriteFile = true;
	o.agent.fsRoot = tmp.path().string();
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK_MSG(buildAgentConfig(o, out2, err2), err2);
	TH_CHECK(out2.allowWriteFile == true);
}

/* 跨字段依赖：--agent-write-file 没有 --fs-root → 配置错误，上电前拒绝，
 * 错误点名这条依赖关系（不是某个孤立字段非法）。 */
TH_TEST(agentconfig_write_file_requires_fs_root) {
	NoKeyEnv nokey;
	TempDir tmp("writefile-nofsroot");
	fs::path cfg = tmp.path() / "llm.json";
	writeFile(cfg, R"({})", fs::perms::owner_all);

	CliOptions o = baseOptions(cfg.string());
	o.agent.agentWriteFile = true;	/* 故意不给 --fs-root */
	AgentModeConfig out;
	std::string err;
	TH_CHECK(!buildAgentConfig(o, out, err));
	TH_CHECK_MSG(err.find("--agent-write-file") != std::string::npos
		&& err.find("--fs-root") != std::string::npos, err);
}

/* --mcp-backend 下的策略强制（M5 同族，第三个危险能力）：
 * ① 开 --agent-write-file 却无策略 → 拒，点名 write_file；
 * ② 策略覆盖 write_file → 放行；
 * ③ 策略只覆盖 run_command（漏 write_file）→ 仍拒，点名 write_file。 */
TH_TEST(agentconfig_write_file_backend_requires_policy) {
	TempDir tmp("writefile-policy");
	fs::path root = tmp.path() / "root";
	fs::create_directories(root);
	fs::path gateWrite = tmp.path() / "write.json";
	writeFile(gateWrite,
		R"({"require_confirm":["write_file"],"confirm_command":"/bin/true"})",
		fs::perms::owner_all);
	fs::path gateShellOnly = tmp.path() / "shellonly.json";
	writeFile(gateShellOnly,
		R"({"require_confirm":["run_command"],"confirm_command":"/bin/true"})",
		fs::perms::owner_all);

	auto backendOpts = [&]() {
		CliOptions o;
		o.mcp.enabled = true;
		o.robot = std::string("./robots/relay-test.sql");
		o.agent.llmConfig = "none";
		o.mcp.mcpSocket = "/tmp/mcp-backend-writefile-test.sock";
		o.agent.fsRoot = root.string();
		o.agent.agentWriteFile = true;
		return o;
	};

	/* ① 无策略 → 拒，点名 write_file */
	{
		CliOptions o = backendOpts();
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(o, out, err));
		TH_CHECK(err.find("write_file") != std::string::npos);
	}
	/* ② 策略命中 write_file → 放行 */
	{
		CliOptions o = backendOpts();
		o.agent.agentPolicy = gateWrite.string();
		AgentModeConfig out;
		std::string err;
		TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
	}
	/* ③ 策略漏了 write_file（只覆盖 run_command）→ 仍拒 */
	{
		CliOptions o = backendOpts();
		o.agent.agentPolicy = gateShellOnly.string();
		AgentModeConfig out;
		std::string err;
		TH_CHECK(!buildAgentConfig(o, out, err));
		TH_CHECK(err.find("write_file") != std::string::npos);
	}
}

/* 合法组合：--fs-root + --agent-write-file + 命中的策略 → 通过，makeToolContext
 * 正确传递 allowWriteFile，且 write_file 真的出现在工具表里。 */
TH_TEST(agentconfig_write_file_valid_combo_reaches_tool_context) {
	TempDir tmp("writefile-ok");
	fs::path root = tmp.path() / "root";
	fs::create_directories(root);
	fs::path gate = tmp.path() / "policy.json";
	writeFile(gate,
		R"({"require_confirm":["write_file"],"confirm_command":"/bin/true"})",
		fs::perms::owner_all);

	CliOptions o;
	o.mcp.enabled = true;
	o.robot = std::string("./robots/relay-test.sql");
	o.agent.llmConfig = "none";
	o.mcp.mcpSocket = "/tmp/mcp-backend-writefile-ok.sock";
	o.agent.fsRoot = root.string();
	o.agent.agentWriteFile = true;
	o.agent.agentPolicy = gate.string();

	AgentModeConfig out;
	std::string err;
	TH_CHECK_MSG(buildAgentConfig(o, out, err), err);
	TH_CHECK(out.allowWriteFile == true);

	MemoryReader input("");
	RobotStruct robot(input);
	std::ostringstream log;
	const auto ctx = makeToolContext(out, robot, log);
	TH_CHECK(ctx.allowWriteFile == true);
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(tools.contains("write_file"));

	/* 对照：不给 --agent-write-file 时（即使给了 --fs-root），allowWriteFile 为假 */
	CliOptions o2;
	o2.mcp.enabled = true;
	o2.robot = std::string("./robots/relay-test.sql");
	o2.agent.llmConfig = "none";
	o2.mcp.mcpSocket = "/tmp/mcp-backend-writefile-off.sock";
	o2.agent.fsRoot = root.string();
	AgentModeConfig out2;
	std::string err2;
	TH_CHECK_MSG(buildAgentConfig(o2, out2, err2), err2);
	TH_CHECK(out2.allowWriteFile == false);
}

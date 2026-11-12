/* test_agenttools_runcommand.cpp —— run_command 工具面
 *
 * 自 test_agenttools.cpp 拆出（2026-10-01，行为保持）：schema 生效值（B4）、
 * 基本执行/密钥遮蔽/环境清洗/fd 卫生/超时截断/参数校验/停止信号，以及
 * 工具输出的 UTF-8 消毒（AG-1）。 */

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
#include "agentview.hpp"	/* describeActionScripts 归位后经此引用（2026-10-10） */
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

using fx::TempDir;
using afx::execText;
using afx::makeRelayRobot;
TH_TEST(agenttools_run_command_schema_reports_effective_timeouts) {
	/* B4：run_command 的 schema 描述里那两个数字取自**生效值**（配置文件可调），
	 * 不是写死的「默认 10，最大 60」——写死会在配置改过之后对模型说谎，
	 * 而模型是照着描述去传 timeout_seconds 的。 */
	AgentToolContext ctx;
	ctx.robot = nullptr;
	ctx.allowShell = true;
	ctx.commandTimeoutSec = 25;
	ctx.maxCommandTimeoutSec = 300;
	AgentToolRegistry tools = makeAgentTools(ctx);
	std::string desc;
	for (const ToolSpec& s : tools.specs()) {
		if (s.name == "run_command") { desc = s.parameters.toString(); }
	}
	TH_CHECK_MSG(!desc.empty(), "allowShell=true 时 run_command 应已注册");
	TH_CHECK_MSG(desc.find("默认 25") != std::string::npos, desc);
	TH_CHECK_MSG(desc.find("最大 300") != std::string::npos, desc);
	TH_CHECK_MSG(desc.find("默认 10") == std::string::npos, desc);
	TH_CHECK(desc.find("最大 60") == std::string::npos);
}


TH_TEST(agenttools_run_command_basic) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"echo hello-agent\"}"));
	TH_CHECK(out.find("exit_code=0") != std::string::npos);
	TH_CHECK(out.find("hello-agent") != std::string::npos);

	std::string fails = execText(tools, "run_command",
		parseJson("{\"command\":\"exit 3\"}"));
	TH_CHECK(fails.find("exit_code=3") != std::string::npos);

	/* G2 结构化直传（2026-10-10）：exitCode 不再从回执文本反解——成功与
	 * 非零退出各自如实（给模型的文本回执与此前逐字节相同）。 */
	const AgentToolResult r0 = tools.execute("run_command",
		parseJson("{\"command\":\"echo hello-agent\"}"));
	TH_CHECK(r0.exitCode == std::optional<long long>(0));
	const AgentToolResult r3 = tools.execute("run_command",
		parseJson("{\"command\":\"exit 3\"}"));
	TH_CHECK(r3.exitCode == std::optional<long long>(3));

	std::string noCmd = execText(tools, "run_command", parseJson("{}"));
	TH_CHECK(noCmd.find("失败") != std::string::npos);
}

/* G1（2026-09-23）：run_command 的**回执**（stdout/stderr）在进模型上下文前
 * 必须过一次 maskSecretsInText——子进程环境已清洗，但命令自己打印的 KEY=val
 * 仍会原样透传；密钥经回执带回上下文再外发是本次审计记录的唯一泄漏面。
 * 语义：①敏感值不可见（被 *** 替换）；②有替换时追加净化提示；③无敏感值时
 * 输出逐字节不变（不产生噪音，命令真实输出不被误伤）。 */
TH_TEST(agenttools_run_command_receipt_masks_secrets) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 命令把 KEY=val 形态写进 stdout——模型执行 env / cat 配置文件的等价形态 */
	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"echo 'BOT4CJ_LLM_KEY=sk-leakthis'\",\"timeout_seconds\":10}"));
	TH_CHECK(out.find("sk-leakthis") == std::string::npos);
	TH_CHECK(out.find("=***") != std::string::npos);
	TH_CHECK(out.find("疑似敏感内容") != std::string::npos);

	/* 无敏感值时输出不被改写（普通命令不产生噪音） */
	std::string clean = execText(tools, "run_command",
		parseJson("{\"command\":\"echo harmless-output\",\"timeout_seconds\":10}"));
	TH_CHECK(clean.find("harmless-output") != std::string::npos);
	TH_CHECK(clean.find("已替换") == std::string::npos);
}

/* 2026-10-08 审计 P1 续：回执里的 **JSON 引号键**形态密钥也必须遮蔽。
 * 这是 G1 自 2026-09-23 起的既有盲区——maskSecretsInText 的标识符扫描在遇到
 * 键名前导的 `"` 时进不了识别分支，于是 `cat mybot.llm.json` 这类**最典型的
 * 读密钥命令**从未被真正遮蔽（过去只用 shell `KEY=val` 形态测过）。 */
TH_TEST(agenttools_run_command_receipt_masks_json_quoted_secrets) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 命令打印 JSON 形态的配置：`"api_key": "sk-..."`（真实文件排版） */
	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"printf '{\\\"api_key\\\": \\\"sk-jsonleak\\\"}'\""
			",\"timeout_seconds\":10}"));
	TH_CHECK(out.find("sk-jsonleak") == std::string::npos);
	TH_CHECK(out.find("\"api_key\": ***") != std::string::npos);
	TH_CHECK(out.find("疑似敏感内容") != std::string::npos);
}

TH_TEST(agenttools_run_command_cleans_env) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 名字含 key/token/secret… 的环境变量必须被剔除：模型可被外部输入诱导
	 * 执行任意命令，绝不能让它读到 LLM API key */
	::setenv("BOT4CJ_TEST_SECRET_KEY", "leakme", 1);
	::setenv("BOT4CJ_TEST_PLAIN", "visible", 1);

	std::string out = execText(tools, "run_command", parseJson(
		"{\"command\":\"if printenv BOT4CJ_TEST_SECRET_KEY >/dev/null; then echo LEAKED; "
		"else echo CLEAN; fi; printenv BOT4CJ_TEST_PLAIN || echo MISSING\"}"));
	TH_CHECK(out.find("LEAKED") == std::string::npos);
	TH_CHECK(out.find("CLEAN") != std::string::npos);
	TH_CHECK(out.find("visible") != std::string::npos);

	::unsetenv("BOT4CJ_TEST_SECRET_KEY");
	::unsetenv("BOT4CJ_TEST_PLAIN");
}

/* N9 收口：清洗按**整词**判定——子串匹配既误伤 KEYSTONE/MONKEY，语义也不精确。
 * 本用例双向钉住：复合密钥名（无分隔符的 APIKEY/PGPASSWORD）仍被剔除，
 * 含敏感词子串但与密钥无关的名字（KEYSTONE/MONKEY）必须放行。 */
TH_TEST(agenttools_run_command_env_filter_is_word_wise) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const char* kDropped[] = {"BOT4CJ_TEST_APIKEY", "PGPASSWORD", "AWS_SECRET_ACCESS_KEY"};
	const char* kKept[] = {"KEYSTONE", "MONKEY", "HOCKEY", "TOKENIZER"};
	for (const char* v : kDropped) { ::setenv(v, "x", 1); }
	for (const char* v : kKept) { ::setenv(v, "x", 1); }

	std::string out = execText(tools, "run_command", parseJson(
		"{\"command\":\"for v in BOT4CJ_TEST_APIKEY PGPASSWORD AWS_SECRET_ACCESS_KEY "
		"KEYSTONE MONKEY HOCKEY TOKENIZER; do if printenv \\\"$v\\\" >/dev/null; "
		"then echo \\\"KEPT:$v\\\"; else echo \\\"DROPPED:$v\\\"; fi; done\"}"));

	for (const char* v : kDropped) {
		const std::string want = std::string("DROPPED:") + v;
		TH_CHECK_MSG(out.find(want) != std::string::npos,
			"应被剔除却进了子进程: " + std::string(v) + "（输出: " + out + "）");
	}
	for (const char* v : kKept) {
		const std::string want = std::string("KEPT:") + v;
		TH_CHECK_MSG(out.find(want) != std::string::npos,
			"被误剔的非密钥变量: " + std::string(v) + "（输出: " + out + "）");
	}

	for (const char* v : kDropped) { ::unsetenv(v); }
	for (const char* v : kKept) { ::unsetenv(v); }
}

/* 审计 A 的宿主侧防线：/proc/<pid>/environ 对同 UID 进程可读，只清洗子进程继承的
 * 那份挡不住常驻 agent 自己——main 在注入密钥前后配对调用 collectEnvSecrets /
 * scrubEnvSecrets 把环境块里的原串抹零。判据与 buildCleanEnvp 同源（本用例顺带
 * 钉住这一点）：敏感名被抹空，KEYSTONE/MONKEY 这类含子串的无关名一律不动。 */
TH_TEST(agenttools_env_secret_scrub_hits_only_sensitive_names) {
	::setenv("BOT4CJ_TEST_SCRUB_KEY", "secret-value", 1);
	::setenv("BOT4CJ_TEST_SCRUB_PLAIN", "visible-value", 1);
	::setenv("BOT4CJ_TEST_SCRUB_KEYSTONE", "keep-me", 1);

	scrubEnvSecrets(collectEnvSecrets());

	/* 抹的是整条 "NAME=VALUE"（连名字一起），glibc getenv 按 "NAME=" 前缀匹配，
	 * 于是该变量在环境里直接消失——这才是我们要的终态：既读不到值，也不留名。 */
	const char* secret = ::getenv("BOT4CJ_TEST_SCRUB_KEY");
	TH_CHECK_MSG(secret == nullptr || secret[0] == '\0',
		std::string("敏感变量未被抹除: ") + (secret == nullptr ? "(null)" : secret));
	TH_CHECK(std::string(::getenv("BOT4CJ_TEST_SCRUB_PLAIN")) == "visible-value");
	TH_CHECK(std::string(::getenv("BOT4CJ_TEST_SCRUB_KEYSTONE")) == "keep-me");

	::unsetenv("BOT4CJ_TEST_SCRUB_KEY");
	::unsetenv("BOT4CJ_TEST_SCRUB_PLAIN");
	::unsetenv("BOT4CJ_TEST_SCRUB_KEYSTONE");
}

/* main 的注入链（collect → setenv → scrub）依赖一条 glibc 语义：setenv(overwrite=1)
 * 把数组槽位换成堆上的新串，于是原串不再被引用、可以安全抹掉。这条不变式一旦不成
 * 立，表现就是「agent 起来后每次请求都 401」——密钥被抹了个干净。故单独钉住。 */
TH_TEST(agenttools_scrub_after_reinject_leaves_value_readable) {
	::setenv("BOT4CJ_TEST_LLM_KEY", "exec-side-value", 1);
	std::vector<char*> secrets = collectEnvSecrets();
	::setenv("BOT4CJ_TEST_LLM_KEY", "injected-value", 1);
	scrubEnvSecrets(secrets);

	TH_CHECK_MSG(std::string(::getenv("BOT4CJ_TEST_LLM_KEY")) == "injected-value",
		"抹除把注入后的密钥一起弄丢了：驱动将再也取不到 key");
	bool zeroed = false;
	for (char* p : secrets) {
		if (p != nullptr && p[0] == '\0') { zeroed = true; }
	}
	TH_CHECK(zeroed);

	::unsetenv("BOT4CJ_TEST_LLM_KEY");
}

/* B0-5：注入顺序不变式——MetaProvider 持有的 matrix_ 是对 matrices_ 元素的引用，
 * active() 之后再 push_back 会让这些引用悬垂（重分配）。旧实现只靠「注入必须在
 * active() 之前」的约定维系，本用例把守卫钉住：active() 之后注入必须响亮报错。 */
TH_TEST(agenttools_inject_after_active_is_rejected) {
	auto robot = makeRelayRobot();
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "must be called before active()",
		robot->injectLuaDriver("Timer", "t9"));
	robot->deactivate();
}

TH_TEST(agenttools_run_command_stdin_is_devnull) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* fix-plan 3-1：子命令 stdin 必须指向 /dev/null——`cat` 无参读 stdin，
	 * 重定向前会一直等到超时（并与 REPL 抢输入）；重定向后立即 EOF 正常退出。 */
	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"cat\",\"timeout_seconds\":2}"));
	TH_CHECK(out.find("exit_code=0") != std::string::npos);
	TH_CHECK(out.find("超时") == std::string::npos);
}

TH_TEST(agenttools_run_command_does_not_inherit_parent_fds) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 模拟 HAL 打开的器件句柄：故意**不带** O_CLOEXEC（HAL 侧的 O_CLOEXEC 是
	 * 另一半防线，覆盖不到第三方 Lua 驱动自己 open 的 fd）。
	 * 子 shell 若能看见它，模型驱动的命令就能直接 ioctl 这个 fd 拨动硬件——
	 * 而且是在 deactivate 之后依然有效，"关掉机器人就安全"这条预期会落空。
	 * 判据取 /proc/self/fd/<n> 的存在性：不依赖具体设备节点，开发机可跑。 */
	int dev = ::open("/dev/null", O_RDONLY);
	TH_CHECK(dev > 2);
	const std::string cmd = "test -e /proc/self/fd/" + std::to_string(dev)
		+ " && echo LEAKED || echo CLEAN";
	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"" + cmd + "\",\"timeout_seconds\":5}"));
	::close(dev);

	TH_CHECK(out.find("exit_code=0") != std::string::npos);
	TH_CHECK(out.find("CLEAN") != std::string::npos);
	TH_CHECK(out.find("LEAKED") == std::string::npos);
}

/* 审计 P1 修复（2026-09-21）：高编号 fd（≥4096）同样不得被子 shell 继承。
 * 旧实现子进程侧退化路径封顶 4096，且父进程侧无全量 CLOEXEC 吊销——把句柄
 * dup 到 4096 以上即可复现泄漏。判据与上一用例同款（/proc/self/fd 存在性）。
 * 环境 soft limit 不允许 ≥4096 的 fd 时（裸机常见 1024）无从构造，按环境
 * 能力跳过判据（仍跑 run_command 保证路径可达）。 */
TH_TEST(agenttools_run_command_does_not_inherit_high_numbered_fds) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	int dev = ::open("/dev/null", O_RDONLY);
	int hi = ::fcntl(dev, F_DUPFD, 4200);	/* ≥4096：旧退化路径封顶之外 */
	if (dev > 2) { ::close(dev); }
	/* AG-24（第三轮审计）：这里原来是裸 `return;` —— 先执行的 TH_CHECK 已经计过数，
	 * 于是 AG-5 的「零断言即失败」防线不会触发，本用例在 soft limit 偏低的机器上
	 * 报 [PASS]，而它真正的判据（高编号 fd 不泄漏）一次都没跑。必须显式表态。
	 * harness 规则：TH_SKIP 之前不得执行任何断言——open/fcntl 是环境探测（判据），
	 * 真正的断言（dev > 2 / CLEAN / 无 LEAKED）全部放在 SKIP 之后，低 limit 机器
	 * 才能干净地 [SKIP] 而非 [FAIL]。 */
	if (hi < 0) { TH_SKIP("RLIMIT_NOFILE 过低，无法构造 ≥4200 的 fd"); }
	TH_CHECK(dev > 2);
	const std::string cmd = "test -e /proc/self/fd/" + std::to_string(hi)
		+ " && echo LEAKED || echo CLEAN";
	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"" + cmd + "\",\"timeout_seconds\":5}"));
	::close(hi);

	TH_CHECK(out.find("exit_code=0") != std::string::npos);
	TH_CHECK(out.find("CLEAN") != std::string::npos);
	TH_CHECK(out.find("LEAKED") == std::string::npos);
}

TH_TEST(agenttools_run_command_timeout_and_truncate) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 超时：整进程组终止，不能挂住 agent 会话 */
	std::string slow = execText(tools, "run_command",
		parseJson("{\"command\":\"sleep 5\",\"timeout_seconds\":1}"));
	TH_CHECK(slow.find("超时") != std::string::npos);

	/* 输出截断：单个流上限 64KB */
	std::string big = execText(tools, "run_command",
		parseJson("{\"command\":\"yes a | head -c 200000\"}"));
	TH_CHECK(big.find("已截断") != std::string::npos);
}

TH_TEST(agenttools_run_command_truncation_is_per_stream) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 上限是「每流」64KB，不是两流共享：只有触顶的那条流才应报截断。
	 * 原先用单一 truncated 标志，任一流触顶会把另一流也标成截断。 */
	std::string outOnly = execText(tools, "run_command",
		parseJson("{\"command\":\"yes a | head -c 200000\"}"));
	TH_CHECK(outOnly.find("[stdout 超过") != std::string::npos);
	TH_CHECK(outOnly.find("[stderr 超过") == std::string::npos);

	std::string errOnly = execText(tools, "run_command",
		parseJson("{\"command\":\"yes a | head -c 200000 1>&2\"}"));
	TH_CHECK(errOnly.find("[stderr 超过") != std::string::npos);
	TH_CHECK(errOnly.find("[stdout 超过") == std::string::npos);

	/* 两流都触顶：两条提示并存 */
	std::string both = execText(tools, "run_command",
		parseJson("{\"command\":\"yes a | head -c 200000; yes b | head -c 200000 1>&2\"}"));
	TH_CHECK(both.find("[stdout 超过") != std::string::npos);
	TH_CHECK(both.find("[stderr 超过") != std::string::npos);
}

TH_TEST(agenttools_run_command_rejects_out_of_range_timeout) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* P1-1 防线：模型可控的 timeout_seconds 若是 1e30 这类大浮点，直接
	 * static_cast<int> 是 float-cast-overflow UB（UBSan 实证）。必须折成
	 * 工具失败文本，且绝不能真去执行命令。 */
	std::string huge = execText(tools, "run_command",
		parseJson("{\"command\":\"echo SHOULD_NOT_RUN\",\"timeout_seconds\":1e30}"));
	TH_CHECK(huge.find("失败") != std::string::npos);
	TH_CHECK(huge.find("SHOULD_NOT_RUN") == std::string::npos);

	/* 负值不越界，按既有语义夹到下限 1 秒后照常执行 */
	std::string negative = execText(tools, "run_command",
		parseJson("{\"command\":\"echo ok-negative\",\"timeout_seconds\":-5}"));
	TH_CHECK(negative.find("exit_code=0") != std::string::npos);

	/* 区间内的小数正常取整（2.9 → 2） */
	std::string frac = execText(tools, "run_command",
		parseJson("{\"command\":\"echo ok-frac\",\"timeout_seconds\":2.9}"));
	TH_CHECK(frac.find("exit_code=0") != std::string::npos);
}

/* NUL 防线（2026-09-21 第七轮审计）：JSON 的 \u0000 会被解析成真正的 NUL 字节，
 * 而 run_command 下游一律走 c_str() ⇒ "echo X\u0000rm -rf /" 只会执行 "echo X"
 * ——**静默截断**，模型与操作者都看不出命令被改过（回执里的 exit_code 还是前缀
 * 那条的）。script 参数早有 checkRelPath 的 NUL 判据，两个工具入口不该一有一无，
 * 故判据收在 requireString 这个单点。 */
TH_TEST(agenttools_run_command_rejects_embedded_nul) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);
	const std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"echo SHOULD_NOT_RUN\\u0000echo ALSO_NOT_RUN\"}"));
	TH_CHECK_MSG(out.find("NUL") != std::string::npos, "应点名 NUL，实际: " + out);
	TH_CHECK_MSG(out.find("SHOULD_NOT_RUN") == std::string::npos,
		"NUL 之前的前缀也不得被执行: " + out);
	TH_CHECK_MSG(out.find("exit_code") == std::string::npos,
		"不该产生任何子进程回执: " + out);
}

TH_TEST(agenttools_run_command_rejects_wrong_typed_timeout) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 类型写错必须报错而非静默用缺省值：静默会让模型误以为参数已生效。
	 * 字符串/布尔/对象/数组四种错误类型都不能真去执行命令。 */
	for (const char* bad : {"\"10\"", "true", "{}", "[]"}) {
		std::string json = std::string("{\"command\":\"echo SHOULD_NOT_RUN\",\"timeout_seconds\":")
			+ bad + "}";
		std::string out = execText(tools, "run_command", parseJson(json));
		TH_CHECK(out.find("类型不符") != std::string::npos);
		TH_CHECK(out.find("SHOULD_NOT_RUN") == std::string::npos);
	}

	/* 键缺失与显式 null 都算「未提供」：走缺省超时，照常执行 */
	std::string absent = execText(tools, "run_command",
		parseJson("{\"command\":\"echo ok-absent\"}"));
	TH_CHECK(absent.find("exit_code=0") != std::string::npos);

	std::string nulled = execText(tools, "run_command",
		parseJson("{\"command\":\"echo ok-null\",\"timeout_seconds\":null}"));
	TH_CHECK(nulled.find("exit_code=0") != std::string::npos);
}

TH_TEST(agenttools_run_command_interrupts_on_stop_signal) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 停止信号（SIGINT/SIGTERM 置位全局标志）应整组终止子进程并如实标注「被中断」，
	 * 而不是等满 timeout——该分支此前无用例覆盖（0.6 改动其成因记录语义）。 */
	struct StopFlagGuard {
		StopFlagGuard() { stopRequested() = true; }
		~StopFlagGuard() { stopRequested() = false; }	/* 全局标志，勿污染后续用例 */
	} guard;

	std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"sleep 5\",\"timeout_seconds\":30}"));
	TH_CHECK(out.find("被中断") != std::string::npos);
}

/* ---- UTF-8 消毒：工具输出进模型上下文前必须合法（2026-09-21 审计 AG-1）----
 * 这是 AG-1 的**复现输入**：`printf 'A\377B'` 的 stdout 里带一个 0xFF。
 * 修复前该字节原样进请求体 → 严格网关 400 → 而那条 tool 消息属于已完整结束的
 * 轮次，回滚边界（complete）与 HistoryManager::trim 都碰不到它 → REPL 里之后每条任务
 * 都以同一字节偏移失败。
 * 断言分三层：整体合法、坏字节被替换、合法 ASCII 前后缀保真。 */
TH_TEST(agenttools_run_command_output_is_sanitized_to_valid_utf8) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"printf 'A\\\\377B'\",\"timeout_seconds\":5}"));

	TH_CHECK(isValidUtf8(out));
	/* 坏字节已被替换成 U+FFFD，且两侧的 A / B 原样保留 */
	TH_CHECK(out.find("A\xef\xbf\xbd" "B") != std::string::npos);
	TH_CHECK(out.find("exit_code=0") != std::string::npos);
	/* 单个坏字节不加计数说明（折叠说明留给连续坏字节） */
	TH_CHECK(out.find(kInvalidUtf8Marker) == std::string::npos);
}

/* 连续坏字节：折叠成一个替换符 + 计数说明，且产物仍然合法、体积不膨胀 */
TH_TEST(agenttools_run_command_collapses_invalid_byte_runs) {
	AgentToolContext ctx;
	ctx.allowShell = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	/* 200 个 0xFF：若逐个替换会膨胀成 600 字节的替换符串 */
	const std::string out = execText(tools, "run_command",
		parseJson("{\"command\":\"head -c 200 /dev/zero | tr '\\\\0' '\\\\377'\","
			  "\"timeout_seconds\":5}"));

	TH_CHECK(isValidUtf8(out));
	TH_CHECK(out.find(kInvalidUtf8Marker) != std::string::npos);
	/* 折叠说明里点名了字节数 */
	TH_CHECK(out.find("200 bytes]") != std::string::npos);
}

/* 磁盘内容同样要消毒：动作脚本首行注释进系统提示词（AG-1 的 system 消息来源）。
 * 不消毒时**第一次**请求就 400，会话根本起不来。 */
TH_TEST(agenttools_script_first_comment_is_sanitized) {
	fx::TempDir dir("utf8_scripts");
	const fs::path root = dir.path() / "scripts";
	fs::create_directories(root);
	{
		/* 首行注释里塞一个非法字节（用二进制写，避免源码字面量歧义） */
		std::ofstream f(root / "poison.mt", std::ios::binary);
		f << "# POISON-" << static_cast<char>(0xff) << "-MARKER 说明\n@Action dummy\n";
	}
	const std::string listing = describeActionScripts(root.string());
	TH_CHECK(isValidUtf8(listing));
	TH_CHECK(listing.find("POISON-") != std::string::npos);
	TH_CHECK(listing.find("-MARKER") != std::string::npos);
}

/* test_agenttools_wait.cpp —— wait_variable「等事件」原语
 *
 * 自 test_agenttools.cpp 拆出（2026-10-01，行为保持），镜像 src/agenttools_wait.cpp
 * 的域边界；CounterRig 计数器夹具随迁。 */

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
using afx::makeRelayRobot;
/* ---- wait_variable（2026-09-25）：感知-决策闭环的"等事件"原语 ----
 * 夹具 AgentCounterDriver：每次 call() count+1、label 随之变、text 恒为非数值。 */
namespace {

struct CounterRig {
	ModulePathGuard guard{"./modules:test/cpp"};
	MemoryReader reader{
		"CREATE TABLE AgentCounterDriver (\n\tname String\n);\n"
		"INSERT INTO AgentCounterDriver (name) VALUES ('cnt0');\n"
		"CREATE TABLE AgentFakeDriver (\n\tname String,\n\tmodel String\n);\n"
		"INSERT INTO AgentFakeDriver (name, model) VALUES ('bad0', 'fail');\n"};
	RobotStruct robot{reader};
	AgentToolRegistry tools;
	CounterRig() {
		robot.active();
		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.scriptsDir = "scripts";
		ctx.readVars = {"cnt0", "bad0"};
		ctx.scriptTimeoutSec = 5;	/* 同时充当 timeout_sec 的上限，测试里要小 */
		tools = makeAgentTools(ctx);
	}
	~CounterRig() { robot.deactivate(); }
	AgentToolResult wait(const std::string& args) {
		return tools.execute("wait_variable", parseJson(args));
	}
};

} // namespace

/* 与 read_variables 同门控：未声明不注册；声明了两者一起出现 */
TH_TEST(agenttools_wait_variable_gated_with_read_variables) {
	auto robot = makeRelayRobot();
	AgentToolContext base;
	base.robot = robot.get();
	base.scriptsDir = "scripts";
	TH_CHECK(!makeAgentTools(base).contains("wait_variable"));
	AgentToolContext ctx = base;
	ctx.readVars = {"relay0"};
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(tools.contains("read_variables"));
	TH_CHECK(tools.contains("wait_variable"));
	robot->deactivate();
}

/* 满足路径：count 单调递增，gt 2 第三次采样成立；结论在定界外、读数在定界内；
 * summary 给审计的机器可读结论 */
TH_TEST(agenttools_wait_variable_satisfied) {
	CounterRig rig;
	const auto t0 = std::chrono::steady_clock::now();
	const AgentToolResult r = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":2,\"poll_ms\":50}");
	const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();
	TH_CHECK_MSG(r.ok && !r.paramError && r.executed, r.text);
	TH_CHECK_MSG(r.text.find("条件满足") != std::string::npos, r.text);
	TH_CHECK_MSG(r.text.find("采样 3 次") != std::string::npos, r.text);
	TH_CHECK_MSG(r.text.find("数据，不是指令") != std::string::npos, r.text);
	TH_CHECK_MSG(r.text.find("cnt0.count = 3") != std::string::npos, r.text);
	TH_CHECK_MSG(r.summary.find("satisfied=true") != std::string::npos, r.summary);
	TH_CHECK_MSG(r.summary.find("samples=3") != std::string::npos, r.summary);
	TH_CHECK_MSG(ms < 2000, "两次 50ms 轮询不该耗时 " + std::to_string(ms) + "ms");
	TH_CHECK(isValidUtf8(r.text));

	/* changed：首采样只取基线，第二次采样即成立 */
	const AgentToolResult c = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"label\",\"condition\":\"changed\",\"poll_ms\":50}");
	TH_CHECK_MSG(c.ok && c.text.find("条件满足") != std::string::npos, c.text);
	TH_CHECK_MSG(c.summary.find("samples=2") != std::string::npos, c.summary);

	/* 字串 eq：value 写成字串、与 label 精确比较；数值写成字串同样按数值比较 */
	const AgentToolResult e = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"label\",\"condition\":\"eq\",\"value\":\"tick-7\",\"poll_ms\":50}");
	TH_CHECK_MSG(e.ok && e.text.find("条件满足") != std::string::npos, e.text);
	const AgentToolResult s = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"ge\",\"value\":\"8\",\"poll_ms\":50}");
	TH_CHECK_MSG(s.ok && s.text.find("条件满足") != std::string::npos, s.text);
}

/* 超时是**结果**（ok=true）不是失败：回执写明超时与最后读数；键不存在时列出样本现有键 */
TH_TEST(agenttools_wait_variable_timeout_is_a_result) {
	CounterRig rig;
	const AgentToolResult r = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"lt\",\"value\":0,"
		"\"timeout_sec\":1,\"poll_ms\":200}");
	TH_CHECK_MSG(r.ok && !r.paramError, r.text);
	TH_CHECK_MSG(r.text.find("超时未满足（1 s") != std::string::npos, r.text);
	TH_CHECK_MSG(r.text.find("cnt0.count = ") != std::string::npos, r.text);
	TH_CHECK_MSG(r.summary.find("satisfied=false") != std::string::npos, r.summary);

	const AgentToolResult k = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"nope\",\"condition\":\"changed\",\"timeout_sec\":1,\"poll_ms\":500}");
	TH_CHECK_MSG(k.ok && k.text.find("超时未满足") != std::string::npos, k.text);
	TH_CHECK_MSG(k.text.find("键不存在") != std::string::npos, k.text);
	TH_CHECK_MSG(k.text.find("count") != std::string::npos && k.text.find("label") != std::string::npos,
		"须列出样本现有键名供模型自我修正: " + k.text);
}

/* 参数问题在触碰硬件之前拦下（paramError → 派发漏斗按「没执行」口径） */
TH_TEST(agenttools_wait_variable_param_errors) {
	CounterRig rig;
	auto bad = [&](const std::string& args, const std::string& needle) {
		const AgentToolResult r = rig.wait(args);
		TH_CHECK_MSG(!r.ok && r.paramError, args + " → " + r.text);
		TH_CHECK_MSG(r.error.find(needle) != std::string::npos, args + " → " + r.error);
	};
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"between\",\"value\":1}", "condition");
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\"}", "value");
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":\"many\"}", "数值");
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":1,\"timeout_sec\":0}",
		"timeout_sec");
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":1,\"timeout_sec\":6}",
		"1..5");	/* 上限 = scriptTimeoutSec */
	bad("{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":1,\"poll_ms\":10}",
		"poll_ms");
	bad("{\"name\":\"relay0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":1}", "可读清单");
	/* 键在而不是数值：排序条件是永久性类型不匹配，首采样即报，不烧超时 */
	bad("{\"name\":\"cnt0\",\"key\":\"text\",\"condition\":\"gt\",\"value\":1,\"timeout_sec\":5}",
		"不是数值");

	/* 首采样读失败 → 快速失败（执行问题而非参数问题） */
	const AgentToolResult f = rig.wait(
		"{\"name\":\"bad0\",\"key\":\"count\",\"condition\":\"gt\",\"value\":1,\"timeout_sec\":5}");
	TH_CHECK_MSG(!f.ok && !f.paramError, f.text);
}

/* 停止信号：等待中看见 stopRequested 即放弃（不坐满超时），折成工具失败 */
TH_TEST(agenttools_wait_variable_stops_on_signal) {
	CounterRig rig;
	stopRequested().store(true);
	const auto t0 = std::chrono::steady_clock::now();
	const AgentToolResult r = rig.wait(
		"{\"name\":\"cnt0\",\"key\":\"count\",\"condition\":\"lt\",\"value\":0,\"timeout_sec\":5}");
	const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();
	stopRequested().store(false);
	TH_CHECK_MSG(!r.ok, r.text);
	TH_CHECK_MSG(r.error.find("停止信号") != std::string::npos, r.error);
	TH_CHECK_MSG(ms < 1000, "收到停止信号后不该等 " + std::to_string(ms) + "ms");
}

/* 回执渲染单点：定界 + 截断标注 + 截断后消毒（刀口可能落在多字节序列中间） */

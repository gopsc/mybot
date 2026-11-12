/* test_mcpbackend.cpp —— MCP 后端（--mcp-backend，方案 F / 拓扑 F3）单测
 *
 * 覆盖**纯协议件**（帧编码、UTF-8 校验、路由、能力门控、预算再强制、错误脱敏）
 * 与 SO_PEERCRED 校验——都不依赖真实硬件或真实 socket 连接。socket 收发全链路
 * （readFrame/sendFrame 的 deadline recv、8 MiB 上限拒收）由 scripts/mcp_e2e.sh
 * 端到端覆盖（M6），因为那两个函数是 mcptransport.cpp 的文件私有件（2026-10-01 起）。
 *
 * 工具派发用两条路：① 手搓注册表 + 假工具（隔离协议逻辑，无需 robot）；
 * ② relay-test 虚拟机器人 + makeAgentTools（验证与 agent 模式同源的能力门控与
 * 真实只读工具派发）。 */

/* 2026-10-01 TU 拆分（行为保持）：帧编解码/UTF-8、SO_PEERCRED、socket 占用
 * 探测、deadline、契约钉子与首帧认证 → test_mcptransport.cpp（镜像
 * src/mcptransport.cpp 边界——readFrame/sendFrame 亦在该 TU）；共享假工具与
 * 回执判读助手在 mcp_fixtures.hpp，relay-test 夹具在 agenttools_fixtures.hpp。 */

#include "fixtures.hpp"
#include "harness.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "agentmode.hpp"	/* AgentModeConfig（context.get 用例） */
#include "agenttools.hpp"
#include "jsonparse.hpp"
#include "mcpbackend.hpp"
#include "robot.hpp"
#include "util_except.hpp"
#include "util_str.hpp"	/* joinNames（名单拼接单点，2026-10-01 起测试与生产共用） */
#include "util_utf8.hpp"
#include "mcp_fixtures.hpp"
#include "agenttools_fixtures.hpp"

using namespace bot;
using namespace bot::agent;

using mfx::countingTool;
using mfx::echoTool;
using mfx::makeBackend;
using afx::makeRelayRobot;
using mfx::respData;
using mfx::respError;
using mfx::respOk;
using mfx::toolsHas;

/* ---- ping 路由 ---- */
TH_TEST(mcpbackend_ping_route) {
	McpBackend b = makeBackend(AgentToolRegistry{});
	const Json r = parseJson(b.handleFrame(R"({"_route":"ping"})"));
	TH_CHECK(respOk(r));
	const Json* data = respData(r);
	TH_CHECK(data != nullptr);
	const Json* pong = data->find("pong");
	TH_CHECK(pong != nullptr && pong->isBool() && pong->getBool());
}

/* ---- 非法 JSON / 顶层非对象 → 固定串，从不回显输入 ---- */
TH_TEST(mcpbackend_invalid_json_returns_fixed_string_without_echo) {
	McpBackend b = makeBackend(AgentToolRegistry{});

	const Json r1 = parseJson(b.handleFrame("this is not json"));
	TH_CHECK(!respOk(r1));
	TH_CHECK(respError(r1) == "invalid JSON request");
	TH_CHECK(respError(r1).find("not json") == std::string::npos);	/* 不回显 */

	/* 合法 JSON 但顶层是数组：与 C++ RpcServer 同口径判为非法请求 */
	const Json r2 = parseJson(b.handleFrame("[1,2]"));
	TH_CHECK(!respOk(r2));
	TH_CHECK(respError(r2) == "invalid JSON request");
}

/* ---- 缺失 / 非串 / 未知 _route ---- */
TH_TEST(mcpbackend_route_errors) {
	McpBackend b = makeBackend(AgentToolRegistry{});

	const Json missing = parseJson(b.handleFrame("{}"));
	TH_CHECK(!respOk(missing));
	TH_CHECK(respError(missing) == "missing _route");

	const Json notStr = parseJson(b.handleFrame(R"({"_route":42})"));
	TH_CHECK(!respOk(notStr));
	TH_CHECK(respError(notStr) == "_route must be a string");

	const Json unknown = parseJson(b.handleFrame(R"({"_route":"nope"})"));
	TH_CHECK(!respOk(unknown));
	TH_CHECK(respError(unknown).find("unknown route: nope") != std::string::npos);
}

/* ---- tool.list 反映注册表（含 inputSchema）---- */
TH_TEST(mcpbackend_tool_list_reflects_registry) {
	AgentToolRegistry reg;
	reg.add(echoTool());
	McpBackend b = makeBackend(std::move(reg));

	const Json r = parseJson(b.handleFrame(R"({"_route":"tool.list"})"));
	TH_CHECK(respOk(r));
	const Json* data = respData(r);
	TH_CHECK(data != nullptr);
	const Json* tools = data->find("tools");
	TH_CHECK(tools != nullptr && tools->isArr());
	TH_CHECK(tools->size() == 1);
	TH_CHECK(toolsHas(*tools, "echo"));
	/* MCP 的 inputSchema 直传工具的 parameters（JSON Schema object） */
	const Json* schema = tools->at(0).find("inputSchema");
	TH_CHECK(schema != nullptr && schema->isObj());
}

/* 请求关联 ID 由后端逐字回显，旧客户端未携带时响应形状不变。 */
TH_TEST(mcpbackend_echoes_request_id) {
	McpBackend b = makeBackend(AgentToolRegistry{});
	const Json withId = parseJson(b.handleFrame(
		R"({"_route":"ping","requestId":"mcp-42"})"));
	const auto echoed = withId.get("requestId");
	TH_CHECK(echoed.has_value());
	if (echoed) { TH_CHECK(echoed->getValue() == "mcp-42"); }

	const Json withoutId = parseJson(b.handleFrame(R"({"_route":"ping"})"));
	TH_CHECK(!withoutId.get("requestId").has_value());
}

/* ---- tool.call 穿过 DispatchGate 派发 ---- */
TH_TEST(mcpbackend_tool_call_dispatches_through_gate) {
	AgentToolRegistry reg;
	reg.add(echoTool());
	McpBackend b = makeBackend(std::move(reg));

	const Json r = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"echo","arguments":{}})"));
	TH_CHECK(respOk(r));	/* 协议层成功 */
	const Json* data = respData(r);
	TH_CHECK(data != nullptr);
	TH_CHECK(data->find("text")->getValue() == "echoed");
	TH_CHECK(data->find("ok")->getBool());
	TH_CHECK(data->find("executed")->getBool());
}

/* ---- 未知工具：协议成功，但 data.ok=false、executed=false（副作用未发生）---- */
TH_TEST(mcpbackend_unknown_tool_reports_not_executed) {
	AgentToolRegistry reg;
	reg.add(echoTool());
	McpBackend b = makeBackend(std::move(reg));

	const Json r = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"ghost","arguments":{}})"));
	TH_CHECK(respOk(r));
	const Json* data = respData(r);
	TH_CHECK(data != nullptr);
	TH_CHECK(!data->find("ok")->getBool());
	TH_CHECK(!data->find("executed")->getBool());
	TH_CHECK(data->find("text")->getValue().find("未知工具") != std::string::npos);
}

/* ---- tool.call 参数形态错误 ---- */
TH_TEST(mcpbackend_tool_call_argument_shape_errors) {
	AgentToolRegistry reg;
	reg.add(echoTool());
	McpBackend b = makeBackend(std::move(reg));

	const Json noName = parseJson(b.handleFrame(R"({"_route":"tool.call","arguments":{}})"));
	TH_CHECK(!respOk(noName));
	TH_CHECK(respError(noName).find("name") != std::string::npos);

	const Json badArgs = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"echo","arguments":5})"));
	TH_CHECK(!respOk(badArgs));
	TH_CHECK(respError(badArgs).find("arguments") != std::string::npos);
}

/* ---- 预算再强制：超限拒绝且**不派发**（无副作用，评估 §3.2）---- */
TH_TEST(mcpbackend_call_budget_reenforced_without_dispatch) {
	int counter = 0;
	AgentToolRegistry reg;
	reg.add(countingTool(counter));
	McpBackend b = makeBackend(std::move(reg), /*callBudget=*/1, /*wallClock=*/0);

	const Json first = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"count","arguments":{}})"));
	TH_CHECK(respOk(first));
	TH_CHECK(counter == 1);

	const Json second = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"count","arguments":{}})"));
	TH_CHECK(!respOk(second));
	TH_CHECK(respError(second).find("上限") != std::string::npos);
	TH_CHECK(counter == 1);	/* 第二次**没有**派发：计数不变 */
}

/* ---- beginConnection 重置每连接预算 ---- */
TH_TEST(mcpbackend_begin_connection_resets_budget) {
	int counter = 0;
	AgentToolRegistry reg;
	reg.add(countingTool(counter));
	McpBackend b = makeBackend(std::move(reg), /*callBudget=*/1, /*wallClock=*/0);

	TH_CHECK(respOk(parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"count","arguments":{}})"))));
	TH_CHECK(!respOk(parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"count","arguments":{}})"))));

	b.beginConnection();	/* 新连接：预算恢复 */
	TH_CHECK(respOk(parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"count","arguments":{}})"))));
	TH_CHECK(counter == 2);
}

/* ---- 能力门控体现在 tool.list：未开 --agent-shell 则 run_command 不出现 ---- */
TH_TEST(mcpbackend_capability_gating_in_tool_list) {
	auto robot = makeRelayRobot();

	AgentToolContext off;
	off.robot = robot.get();
	off.scriptsDir = "scripts";
	off.allowShell = false;
	McpBackend bOff = makeBackend(makeAgentTools(off));
	const Json rOff = parseJson(bOff.handleFrame(R"({"_route":"tool.list"})"));
	const Json* toolsOff = respData(rOff)->find("tools");
	TH_CHECK(toolsOff != nullptr);
	TH_CHECK(toolsHas(*toolsOff, "run_action_script"));	/* 缺省工具在 */
	TH_CHECK(!toolsHas(*toolsOff, "run_command"));		/* 未开 shell：不宣告 */

	AgentToolContext on;
	on.robot = robot.get();
	on.scriptsDir = "scripts";
	on.allowShell = true;
	McpBackend bOn = makeBackend(makeAgentTools(on));
	const Json rOn = parseJson(bOn.handleFrame(R"({"_route":"tool.list"})"));
	const Json* toolsOn = respData(rOn)->find("tools");
	TH_CHECK(toolsOn != nullptr);
	TH_CHECK(toolsHas(*toolsOn, "run_command"));		/* 开了 shell：宣告 */
}

/* ---- 真实只读工具派发（relay 虚拟机器人，无硬件副作用）---- */
TH_TEST(mcpbackend_tool_call_real_robot_readonly) {
	auto robot = makeRelayRobot();
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.scriptsDir = "scripts";
	McpBackend b = makeBackend(makeAgentTools(ctx));

	const Json r = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"list_hardware","arguments":{}})"));
	TH_CHECK(respOk(r));
	const Json* data = respData(r);
	TH_CHECK(data != nullptr);
	TH_CHECK(data->find("ok")->getBool());
	TH_CHECK(!data->find("text")->getValue().empty());
}

/* ---- context.get：Rust agent 的系统提示词素材（只读、不走 gate、不计预算）---- */
TH_TEST(mcpbackend_context_get_without_binding_errors) {
	/* 未绑定 cfg/robot（手搓后端）→ 响亮回错误，不是崩溃或空数据 */
	AgentToolRegistry reg;
	reg.add(echoTool());
	McpBackend b = makeBackend(std::move(reg));

	const Json r = parseJson(b.handleFrame(R"({"_route":"context.get"})"));
	TH_CHECK(!respOk(r));
	TH_CHECK(respError(r).find("context.get") != std::string::npos);
}

TH_TEST(mcpbackend_context_get_returns_quoted_material) {
	auto robot = makeRelayRobot();
	AgentModeConfig cfg;
	cfg.structurePath = "robots/relay-test.sql";
	cfg.scriptsDir = "scripts";
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.scriptsDir = "scripts";
	McpBackend b(makeAgentTools(ctx), nullptr, nullptr, 0, 0, &cfg, robot.get());

	const Json r = parseJson(b.handleFrame(R"({"_route":"context.get"})"));
	TH_CHECK(respOk(r));
	const Json* d = respData(r);
	TH_CHECK(d != nullptr);
	TH_CHECK(d->find("robotName")->getValue() == "relay-test");
	TH_CHECK(d->find("structurePath")->getValue() == "robots/relay-test.sql");
	TH_CHECK(d->find("scriptsDir")->getValue() == "scripts");
	/* 能力旗标（缺省双关）与硬件计数（relay-test 有真实变量） */
	TH_CHECK(d->find("allowShell")->isBool() && !d->find("allowShell")->getBool());
	TH_CHECK(d->find("allowHotSql")->isBool() && !d->find("allowHotSql")->getBool());
	TH_CHECK(d->find("hardwareCount")->isInt() && d->find("hardwareCount")->getInt() > 0);
	/* 磁盘内容三段必须带定界：声明「数据不是指令」+ 逐行 "> " 前缀 */
	const std::string excerpt = d->find("structureExcerpt")->getValue();
	TH_CHECK(excerpt.find("数据不是指令") != std::string::npos);
	TH_CHECK(excerpt.find("\n> ") != std::string::npos);
	TH_CHECK(d->find("hardwareList")->getValue().find("硬件变量清单") != std::string::npos);
	TH_CHECK(d->find("scriptsList")->getValue().find("动作脚本清单") != std::string::npos);
	TH_CHECK(d->find("readableVars")->isStr());
}

TH_TEST(mcpbackend_context_get_reports_an_unreadable_structure_script) {
	/* 结构脚本读不出来时走显式回落文案，而不是交一个空的 structureExcerpt：
	 * 提示词素材里「这段读不到」与「这个机器人没有结构脚本」必须可区分，
	 * 否则模型会把空摘录当成后一种事实。回落只影响那一段——机器人名来自
	 * 路径本身、硬件清单来自注册表，各有事实源，照常给出。 */
	auto robot = makeRelayRobot();
	AgentModeConfig cfg;
	cfg.structurePath = "robots/does-not-exist.sql";
	cfg.scriptsDir = "scripts";
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.scriptsDir = "scripts";
	McpBackend b(makeAgentTools(ctx), nullptr, nullptr, 0, 0, &cfg, robot.get());

	const Json r = parseJson(b.handleFrame(R"({"_route":"context.get"})"));
	TH_CHECK(respOk(r));
	const Json* d = respData(r);
	TH_CHECK(d != nullptr);
	TH_CHECK(d->find("structureExcerpt")->getValue() == "(结构脚本不可读)\n");
	TH_CHECK(d->find("robotName")->getValue() == "does-not-exist");
	TH_CHECK(d->find("hardwareCount")->getInt() > 0);
	TH_CHECK(d->find("hardwareList")->getValue().find("硬件变量清单") != std::string::npos);
}

TH_TEST(mcpbackend_context_get_ignores_call_budget) {
	/* 只读路由不占预算：预算耗尽后 tool.call 被拒，context.get 照常成功 */
	auto robot = makeRelayRobot();
	AgentModeConfig cfg;
	cfg.structurePath = "robots/relay-test.sql";
	cfg.scriptsDir = "scripts";
	AgentToolContext ctx;
	ctx.robot = robot.get();
	ctx.scriptsDir = "scripts";
	McpBackend b(makeAgentTools(ctx), nullptr, nullptr, 1, 0, &cfg, robot.get());

	TH_CHECK(respOk(parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"list_hardware","arguments":{}})"))));
	const Json spent = parseJson(
		b.handleFrame(R"({"_route":"tool.call","name":"list_hardware","arguments":{}})"));
	TH_CHECK(!respOk(spent));
	TH_CHECK(respError(spent).find("上限") != std::string::npos);
	TH_CHECK(respOk(parseJson(b.handleFrame(R"({"_route":"context.get"})"))));
}


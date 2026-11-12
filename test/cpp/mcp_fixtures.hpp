#pragma once
/* mcp_fixtures.hpp —— test_mcpbackend* 系列单测共用的协议观测助手
 *
 * 2026-10-01 test_mcpbackend.cpp 按 TU 拆分（镜像 src/mcptransport.cpp 的
 * 域边界）时，路由与传输两半共用的假工具/回执判读助手随迁于此——与
 * fixtures.hpp / robot_fixtures.hpp 同一形态。relay-test 机器人复用
 * afx::makeRelayRobot（agenttools_fixtures.hpp，同款夹具单点）。
 */

#include <memory>
#include <string>

#include "agenttools.hpp"
#include "jsonparse.hpp"
#include "mcpbackend.hpp"

namespace mfx {

/* 一个只回固定文本的假工具（隔离协议逻辑，不碰硬件） */
inline bot::agent::AgentTool echoTool() {
	bot::agent::AgentTool t;
	t.name = "echo";
	t.description = "回显工具（测试用）";
	t.parameters = bot::JsonObject();
	t.execute = [](const bot::Json&) -> bot::agent::AgentToolResult { return bot::agent::AgentToolResult{"echoed", ""}; };
	return t;
}

/* 记录派发次数的假工具（验证预算超限时**不**派发） */
inline bot::agent::AgentTool countingTool(int& counter) {
	bot::agent::AgentTool t;
	t.name = "count";
	t.description = "计数工具（测试用）";
	t.parameters = bot::JsonObject();
	t.execute = [&counter](const bot::Json&) -> bot::agent::AgentToolResult {
		++counter;
		return bot::agent::AgentToolResult{"counted", ""};
	};
	return t;
}

inline bool respOk(const bot::Json& r) {
	const bot::Json* s = r.find("success");
	return s != nullptr && s->isBool() && s->getBool();
}

inline std::string respError(const bot::Json& r) {
	const bot::Json* e = r.find("error");
	return (e != nullptr && e->isStr()) ? e->getValue() : std::string();
}

inline const bot::Json* respData(const bot::Json& r) { return r.find("data"); }

inline bool toolsHas(const bot::Json& toolsArr, const std::string& name) {
	for (std::size_t i = 0; i < toolsArr.size(); ++i) {
		const bot::Json* n = toolsArr.at(i).find("name");
		if (n != nullptr && n->isStr() && n->getValue() == name) { return true; }
	}
	return false;
}

inline bot::agent::McpBackend makeBackend(bot::agent::AgentToolRegistry reg, long callBudget = 0, long wallClock = 0) {
	return bot::agent::McpBackend(std::move(reg), nullptr, nullptr, callBudget, wallClock);
}

} // namespace mfx

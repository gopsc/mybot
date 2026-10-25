#pragma once
/* agentproto.hpp —— agent 工具后端与 Rust agent 之间的规范化数据结构（C++ 侧）
 *
 * 沿革：这里曾有宿主 ⇄ Lua 协议驱动的整条规范化协议（ChatTransport /
 * buildDriverRequest / parseDriverResponse）——模型调用由 modules/Llm*.lua 承担。
 * agent 循环迁 Rust 后（agent/src，模型调用直连 provider），传输层随
 * agentdriver 一起删除；本文件保留的是仍然存活的两侧共享结构：
 *   * ToolCall / parseToolArguments —— MCP 后端帧协议的工具调用面
 *     （mcpbackend 组装 → DispatchGate 派发 → agenttools 执行）；
 *   * ToolSpec —— 工具声明（AgentToolRegistry::specs），MCP 后端 tool.list 用。
 * 批次 D（2026-09-25）后：会话文件读写原语（原 ChatMessage / agenthistory.cpp
 * 的 SessionFileWriter / loadSessionFile）随 C++ 侧语义参考一并清退——Rust 侧
 * agent/src/session.rs 是唯一实现，不再有 C++ 孪生。 */

#include <string>
#include <utility>
#include <vector>

#include "json.hpp"

namespace bot {
namespace agent {

/* 一次工具调用。arguments 保留模型给出的原始 JSON 字符串（不在此处解析：
 * 解析失败要作为「工具参数错误」回传给模型，而不是在协议层打断整轮对话）。 */
struct ToolCall {
	std::string id;
	std::string requestId;
	std::string name;
	std::string arguments;

	ToolCall() = default;
	ToolCall(std::string i, std::string n, std::string a)
		: id(std::move(i)), name(std::move(n)), arguments(std::move(a)) {}
	ToolCall(std::string i, std::string request, std::string n, std::string a)
		: id(std::move(i)), requestId(std::move(request)), name(std::move(n)),
		  arguments(std::move(a)) {}
};

/* 暴露给模型的工具声明（parameters 为 JSON Schema object）。
 * AgentToolRegistry::specs 产出，MCP 后端的 tool.list 用。 */
struct ToolSpec {
	std::string name;
	std::string description;
	Json parameters;
};

/* 解析 tool_call.arguments（模型给的 JSON 字符串）。
 * 空串 → 空对象；非对象或非法 JSON → 抛 IllegalArgumentException
 * （由派发漏斗折成参数错误回传模型，不打断会话）。 */
Json parseToolArguments(const std::string& arguments);

} // namespace agent
} // namespace bot

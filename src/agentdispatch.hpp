#pragma once
/* agentdispatch.hpp —— 工具派发漏斗：策略确认 → 执行 → 审计（重构 A1）
 *
 * 从 AgentSession::dispatchOneCall 拆出的固定顺序单点：宿主里「一次工具调用
 * 如何被放行、执行、记账」只在这里发生；编排（轮次、回滚、历史写入）原先在
 * agentloop，随 C++ Agent REPL 移除后已在 Rust agent 侧（agent/src 的
 * model/history/hook）。三条不变量都钉在这个顺序上：
 *
 *   1. 策略确认在执行**之前**：被拒的工具一个副作用都不能有（与任务内预算的
 *      「执行后降级」相反——那边副作用已发生只能如实说明，这边还没发生所以
 *      拦得住）；
 *   2. 参数解析失败折成文本回执，不打断本轮（「工具参数错误: ...」）；
 *   3. 审计在执行**之后**无论成败都记一条：「模型想做什么但没做成」同样是
 *      审计信息；图片只记字节数与指纹，命令原文先遮蔽敏感值（maskToolArgs
 *      单点，与确认程序的输入同一份）。
 *
 * 不认识轮次与历史：那是上层编排（现在在 Rust agent）的事；任务内预算在
 * C++ 侧归 agentbudget，Rust 侧有其孪生实现 agent/src/budget.rs。
 */

#include <memory>
#include <string>

#include "agentaudit.hpp"
#include "agentpolicy.hpp"
#include "agentproto.hpp"
#include "agenttools.hpp"

namespace bot {
namespace agent {

class DispatchGate {
public:
	DispatchGate(const AgentToolRegistry& tools,
		std::shared_ptr<const AgentPolicy> policy,
		std::shared_ptr<AuditLog> audit)
		: tools_(tools), policy_(std::move(policy)), audit_(std::move(audit)) {}

	/* 派发一次调用：解析参数 →（命中 require_confirm 时）过外部确认程序 →
	 * 执行 → 写审计。返回回传模型的工具结果（未知工具/异常也已折成文本）。 */
	AgentToolResult run(const ToolCall& call, int turn);

private:
	const AgentToolRegistry& tools_;
	std::shared_ptr<const AgentPolicy> policy_;
	std::shared_ptr<AuditLog> audit_;
};

} // namespace agent
} // namespace bot

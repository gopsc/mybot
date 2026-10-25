#pragma once
/* agentpolicy.hpp —— agent 工具调用的策略钩子（--agent-policy，P3）
 *
 * 动机（原 docs/proposals/audit-approval-cancel.md P3，2026-09-23 移至 .tmp/）：
 * 审批是**部署策略**，
 * 不该做成内置交互式逐次确认（会毁掉 agent「多轮自主推进」的价值，还容易被
 * `--yes` 架空）。本模块把判断权交给使用者声明的外部确认程序：
 *
 *   策略文件（严格 JSON，与 llm 配置同一解析器口径）声明哪些工具需要确认：
 *   {
 *     "require_confirm": ["run_command"],
 *     "confirm_command": "/usr/local/bin/notify-and-approve",  // 退出 0 = 放行
 *     "confirm_timeout_sec": 30,
 *     "on_timeout": "deny"          // deny（缺省）| allow
 *   }
 *
 *   需要确认时，宿主把 {"tool": ..., "args": {...遮蔽后...}} 写给外部程序的
 *   stdin，按其退出码放行/拒绝；超时按 on_timeout 处理（缺省 deny，与全仓
 *   fail-closed 一致）。
 *
 * 设计约束：
 *   * 默认不启用（--agent-policy 不给 = 现状语义，全部放行），零行为变更；
 *   * 审批形态（终端 y/n、手机推送、工单系统）随部署而变，本项目不猜——
 *     外部程序天然可做到「人在环」，且不扩大驱动沙箱可见面；
 *   * 参数交给外部程序前先遮蔽（maskToolArgs，与审计日志同一单点）：
 *     确认程序往往被打日志、截图或转发，密钥不能跟着 args 一起出门；
 *   * 本策略钩子**不是**隔离边界（与它保护的工具同权限，确认程序可被同一
 *     用户绕过）；真正的隔离仍是专用用户 / 容器 / 网络命名空间。
 *   * 但在 **--mcp-backend**（方案 F / 拓扑 F3）下它的定位变了：后端把工具暴露给
 *     任意外部 MCP 客户端、硬件全程带电，故 buildAgentConfig **强制**——开了
 *     --agent-shell / --agent-hot-sql 就必须有策略钩子、且 require_confirm 命中
 *     run_command / apply_sql，否则拒绝启动（见那里第 11b 步）。此时它是危险工具
 *     的**唯一逐次确认闸门**（仍是「确认」不是「隔离」：同 uid 进程可绕过，
 *     残留风险见 mcpbackend.hpp 与 docs/agent.md）。
 */

#include <memory>
#include <string>
#include <vector>

#include "json.hpp"

namespace bot {
namespace agent {

/* 一次确认的裁决。reason 在拒绝/异常时是人话说明（会原样出现在工具回执与
 * 审计日志的 error 里），放行时为空。 */
struct PolicyDecision {
	bool allowed = false;
	std::string reason;
};

class AgentPolicy {
public:
	AgentPolicy() = default;

	/* 从严格 JSON 文件加载。失败返回 nullptr 并把带字段名的人话报错写进 err：
	 * 文件不可读、不是合法 JSON、未知字段、类型/区间不符、
	 * require_confirm 非空但 confirm_command 缺失等。 */
	static std::shared_ptr<const AgentPolicy> load(const std::string& path, std::string& err);

	/* 该工具的每次调用是否需要过确认程序 */
	bool requiresConfirm(const std::string& tool) const;

	/* 走一次外部确认程序。tool 未命中 require_confirm 时直接放行（零开销），
	 * 因此派发点可以无条件调用。 */
	PolicyDecision confirm(const std::string& tool, const Json& args) const;

	const std::vector<std::string>& requireConfirm() const { return requireConfirm_; }
	const std::string& confirmCommand() const { return confirmCommand_; }
	int timeoutSec() const { return timeoutSec_; }
	bool timeoutDeny() const { return timeoutDeny_; }

private:
	std::vector<std::string> requireConfirm_;
	std::string confirmCommand_;
	int timeoutSec_ = 30;
	bool timeoutDeny_ = true;	/* on_timeout：true=deny（缺省），false=allow */
};

/* 工具参数交给外部世界（审计日志 / 确认程序 stdin）前的遮蔽单点：目前只有
 * run_command 的 command 字段按 KEY=VALUE 形态遮蔽敏感值（判据单点
 * maskSecretsInText）。遮蔽不改变值时原样返回（不重写 Json 节点）。 */
Json maskToolArgs(const std::string& tool, const Json& args);

} // namespace agent
} // namespace bot

/* mcpbackend.cpp —— MCP 后端的路由类实现（见 mcpbackend.hpp 的设计说明）
 *
 * McpBackend：请求路由（tool.list / tool.call / context.get）、每连接预算、
 * 审计与回执脱敏——纯逻辑（Json/文本 → Json/文本），不碰 socket，便于单测。
 * 2026-10-01 TU 拆分（行为保持）：帧编解码与纯协议件 → mcptransport.cpp、
 * 连接服务/断连安全动作/accept 主循环 → mcplisten.cpp（本文件头注的 socket
 * 服务与审计加固说明随之迁移，见 mcplisten.cpp / mcptransport.cpp 头注）。
 */
#include "context_service.hpp"
#include "mcpbackend.hpp"
#include "mcp_protocol.hpp"

#include <chrono>
#include <string>
#include <utility>

#include "agentmode.hpp"	/* AgentModeConfig / makeToolContext / structureDisplayName */
#include "agentprompt.hpp"	/* structureScriptHead / quoteUntrusted（context.get 素材） */
#include "jsonparse.hpp"	/* parseJson */
#include "robot.hpp"		/* RobotStruct 完整定义（context.get 的 registry()） */
#include "util_cli.hpp"		/* AuthFailGate（认证爆破失败门单点） */
#include "util_env.hpp"
#include "util_file.hpp"
#include "util_str.hpp"		/* safeEquals 恒时比较（凭据比对安全单点） */
#include "util_utf8.hpp"		/* stopRequested / isValidUtf8 */

namespace bot {
namespace agent {

using Clock = std::chrono::steady_clock;

/* ---- McpBackend ---- */

McpBackend::McpBackend(AgentToolRegistry tools,
		std::shared_ptr<const AgentPolicy> policy,
		std::shared_ptr<AuditLog> audit,
		long callBudget, long wallClockBudgetSec,
		const AgentModeConfig* cfg, RobotStruct* robot)
	: tools_(std::move(tools)),
	  policy_(std::move(policy)),
	  audit_(std::move(audit)),
	  gate_(tools_, policy_, audit_),
	  cfg_(cfg),
	  robot_(robot),
	  callBudget_(callBudget),
	  wallClockBudgetSec_(wallClockBudgetSec),
	  connStart_(Clock::now()) {}

void McpBackend::beginConnection() {
	calls_ = 0;
	turn_ = 0;
	connStart_ = Clock::now();
}

Clock::time_point McpBackend::idleDeadline(int idleTimeoutSec) const {
	Clock::time_point deadline = Clock::time_point::max();
	if (wallClockBudgetSec_ > 0) {
		const Clock::time_point wall = connStart_
			+ std::chrono::seconds(wallClockBudgetSec_);
		if (wall < deadline) { deadline = wall; }
	}
	if (idleTimeoutSec > 0) {
		const Clock::time_point idle = Clock::now() + std::chrono::seconds(idleTimeoutSec);
		if (idle < deadline) { deadline = idle; }
	}
	return deadline;
}

Json McpBackend::okReply(Json data) const {
	Json o = JsonObject();
	o.put(mcp_protocol::kSuccess, JsonBool(true));
	o.put(mcp_protocol::kData, std::move(data));
	return o;
}

Json McpBackend::errReply(const std::string& msg) const {
	Json o = JsonObject();
	o.put(mcp_protocol::kSuccess, JsonBool(false));
	o.put(mcp_protocol::kError, JsonString(msg));
	return o;
}

bool McpBackend::budgetExceeded(std::string& reason) const {
	if (callBudget_ > 0 && calls_ >= callBudget_) {
		reason = "已达到每连接工具调用上限（" + std::to_string(callBudget_)
			+ " 次）；后端不假设调用方是 agent loop，故自行强制预算。"
			  "请重连或调高上限。";
		return true;
	}
	if (wallClockBudgetSec_ > 0) {
		const long elapsed = std::chrono::duration_cast<std::chrono::seconds>(
			Clock::now() - connStart_).count();
		if (elapsed >= wallClockBudgetSec_) {
			reason = "已超过每连接墙钟预算（" + std::to_string(wallClockBudgetSec_)
				+ " 秒）；请重连。";
			return true;
		}
	}
	return false;
}

Json McpBackend::routeToolList() {
	Json arr = JsonArray();
	for (const ToolSpec& t : tools_.specs()) {
		Json o = JsonObject();
		o.put(mcp_protocol::kName, JsonString(t.name));
		o.put(mcp_protocol::kDescription, JsonString(t.description));
		/* parameters 本就是 JSON Schema object，直接当 MCP 的 inputSchema。 */
		o.put(mcp_protocol::kInputSchema, t.parameters);
		arr.add(o);
	}
	Json data = JsonObject();
	data.put(mcp_protocol::kTools, arr);
	return okReply(std::move(data));
}

Json McpBackend::routeToolCall(const Json& req) {
	/* 预算再强制在**派发之前**：被拒的调用没有副作用（评估 §3.2）。 */
	std::string reason;
	if (budgetExceeded(reason)) { return errReply(reason); }

	const Json* nameJ = req.find(mcp_protocol::kName);
	if (nameJ == nullptr || !nameJ->isStr()) {
		return errReply("tool.call 需要字符串字段 name");
	}
	std::string argsStr = "{}";
	if (const Json* argsJ = req.find(mcp_protocol::kArguments); argsJ != nullptr) {
		if (!argsJ->isObj()) { return errReply("tool.call 的 arguments 必须是 JSON 对象"); }
		argsStr = argsJ->toString();
	}

	ToolCall call;
	call.id.clear();		/* MCP call_tool 无需 id；DispatchGate 不消费它 */
	if (const Json* id = req.find(mcp_protocol::kRequestId); id != nullptr && id->isStr()) {
		call.requestId = id->getValue();
	}
	call.name = nameJ->getValue();
	call.arguments = std::move(argsStr);

	++calls_;
	/* 唯一漏斗：策略确认 → 执行 → 审计。未知工具/参数错/异常都由 gate 折成
	 * 文本回执并记审计（评估 §3.4「所有 MCP 调用必穿 DispatchGate::run」）。 */
	/* tool.call 回执按跨进程协议字段表序列化。 */
	AgentToolResult res = gate_.run(call, turn_++);

	Json data = JsonObject();
	data.put(mcp_protocol::kText, JsonString(res.text));
	/* 挪走而不是再拷：imageDataUrl 可达 2MiB，回执帧序列化时节点里还要留一份。 */
	data.put(mcp_protocol::kImageDataUrl, JsonString(std::move(res.imageDataUrl)));
	data.put(mcp_protocol::kOk, JsonBool(res.ok));
	data.put(mcp_protocol::kError, JsonString(res.error));
	data.put(mcp_protocol::kExecuted, JsonBool(res.executed));
	data.put(mcp_protocol::kParamError, JsonBool(res.paramError));
	data.put(mcp_protocol::kSummary, JsonString(res.summary));
	return okReply(std::move(data));
}

Json McpBackend::routeContextGet() {
	if (cfg_ == nullptr || robot_ == nullptr) {
		return errReply("context.get 不可用：后端未绑定配置与机器人上下文");
	}
	return okReply(buildContextData(*cfg_, *robot_));
}

Json McpBackend::handleRequest(const Json& req) {
	try {
		if (!req.isObj()) {
			/* 顶层非对象（如 [1,2]）：与 C++ RpcServer 同口径判为非法请求，
			 * 且**绝不回显输入**（评估 §7.4）。 */
			return errReply("invalid JSON request");
		}
		const Json* route = req.find(mcp_protocol::kRoute);
		if (route == nullptr) { return errReply("missing _route"); }
		if (!route->isStr()) { return errReply("_route must be a string"); }
		const std::string r = route->getValue();
		if (r == mcp_protocol::kPing) {
			Json d = JsonObject();
			d.put("pong", JsonBool(true));
			return okReply(std::move(d));
		}
		if (r == mcp_protocol::kToolList) { return routeToolList(); }
		if (r == mcp_protocol::kToolCall) { return routeToolCall(req); }
		if (r == mcp_protocol::kContextGet) { return routeContextGet(); }
		return errReply("unknown route: " + r);
	} catch (const std::exception& e) {
		return errReply(sanitizeError(e.what()));
	} catch (...) {
		/* LuaJIT 用 C++ 异常实现 luaD_throw，非 std::exception 也要接住，绝不
		 * 让异常穿出 handler（判据锚点与边界清单：util_except.hpp 的
		 * kNonStdExceptionNote 注释块；本站点文案经 sanitize 刻意定容）。 */
		return errReply("internal error");
	}
}

std::string McpBackend::handleFrame(const std::string& payload) {
	Json req;
	try {
		req = parseJson(payload);	/* 8 MiB / 64 层上限由 parseJson 强制 */
	} catch (const std::exception&) {
		return errReply("invalid JSON request").toString();
	}
	Json response = handleRequest(req);
	/* 请求 ID 只作为跨进程关联元数据回显，不参与业务路由与预算判定。
	 * 缺失或非字符串时不回显，保持旧客户端的响应形状。 */
	if (req.isObj()) {
		const Json* requestId = req.find(mcp_protocol::kRequestId);
		if (requestId != nullptr && requestId->isStr()) {
			response.put(mcp_protocol::kRequestId, JsonString(requestId->getValue()));
		}
	}
	return response.toString();
}

void McpBackend::writeSessionRecord(const char* status) const {
	if (!audit_ || !audit_->enabled()) { return; }
	AuditEntry e;
	e.kind = "session";
	e.status = status;
	/* 会话行只带 status（模型侧字段已随 agent 循环迁 Rust 退场，2026-10-01
	 * 批次 A；后端本就不发起模型调用）。 */
	audit_->write(e);
}

/* MCP-1（审计 P2-1）：认证失败落审计——「有进程在试探这条 socket」是事后复盘
 * 必须看得见的信号；token 与失败详情都不进审计（信息量最小化，日志侧已有）。 */
void McpBackend::recordAuthRejected() const {
	if (!audit_ || !audit_->enabled()) { return; }
	AuditEntry e;
	e.kind = "session";
	e.status = "auth_failed";
	audit_->write(e);
}

} // namespace agent
} // namespace bot

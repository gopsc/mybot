#include "agentdispatch.hpp"

#include "util_except.hpp"	/* kNonStdExceptionNote（A5 判据锚点） */

#include <chrono>
#include <utility>

namespace bot {
namespace agent {

/* 25.4 评估后判不改（93 行）：派发漏斗是**安全判据的直线流程**，不是复杂控制流
 * ——解析参数 → 策略确认 → 执行 → 归一 paramError → 两层 catch → 计时 → 审计，
 * 一段接一段没有回边。判据锚点（SAN-8②、SAN-4、A5、M1）就地贴在各自那段上，
 * 拆开只会让它们分散到不同函数里。关键约束是 argsOk：它存在的唯一理由就是让
 * catch(...) 能区分「抛出发生在参数解析阶段（副作用必然未发生）」与「抛出来自
 * 确认程序或工具本体（Lua 可能已经驱动了硬件）」，从而给出正确的 executed——
 * 把 try 体抽成 helper 就得把这个标志再穿回来，比现在更难读。 */
AgentToolResult DispatchGate::run(const ToolCall& call, int turn) {
	AgentToolResult result;
	Json parsedArgs;
	bool argsOk = false;
	const auto t0 = std::chrono::steady_clock::now();
	/* 拒绝的形态：被拒的调用没有副作用，回执说明「没执行、为什么」，
	 * 工具循环照常推进——模型知道后可以改道或提醒操作者。 */
	bool denied = false;
	try {
		parsedArgs = parseToolArguments(call.arguments);
		argsOk = true;
		if (policy_ && policy_->requiresConfirm(call.name)) {
			const PolicyDecision d = policy_->confirm(call.name, parsedArgs);
			if (!d.allowed) {
				denied = true;
				result = AgentToolResult{
					std::string("本次工具调用未执行：被策略拦截（--agent-policy，")
						+ d.reason + "）。请改用无需确认的工具，"
						  "或告知操作者调整策略后重试。",
					"", false, "policy_denied: " + d.reason,
					/* executed= */ false};
			}
		}
		if (!denied) { result = tools_.execute(call.name, parsedArgs); }
		/* SAN-8②：工具层按异常类型标出的参数问题——改口径并标明"没派发"。
		 * 派发漏斗是**唯一**给模型的回执出口，口径在这里统一。 */
		if (result.paramError) {
			result.text = "工具参数错误: " + result.error;
			result.executed = false;
		}
	} catch (const std::exception& e) {
		/* 参数解析失败 = 这一次调用**从未到达工具**，副作用必然未发生（SAN-4） */
		result = AgentToolResult{std::string("工具参数错误: ") + e.what(), "", false, e.what(),
			/* executed= */ false};
	} catch (...) {
		/* A5：本机 LuaJIT 用 C++ 异常实现 luaD_throw，从没有 Lua CFRAME 的 C++
		 * 帧抛出的 Lua 错误**不是** std::exception（判据锚点与四处边界清单：
		 * util_except.hpp 的 kNonStdExceptionNote 注释块——跨站点行号引用会腐烂，
		 * 按名指锚）。
		 * 只接 std::exception 的话这类抛出会穿透到上层的 catch(...)，把
		 * 整个会话结束掉——而「REPL 单轮失败不结束会话」是循环层的承诺
		 * （原先由 C++ runAgentMode 守，现由 Rust agent 的轮循环守）。
		 * 这里折成 tool 回传而不是让它上抛：那是唯一保持「本轮 tool 消息与
		 * assistant.tool_calls 一一对应」的选择（复核判据即
		 * historyProtocolViolation），也让模型看到「这一步没拿到数据」而不是「什么都没
		 * 发生」。审计照常记这条：ok=false，模型想做什么没做成同样是审计信息。
		 *
		 * executed 按 SAN-4 的口径分两种，不能一律填 false：argsOk 为假说明抛出
		 * 发生在参数解析阶段（调用从未到达工具，副作用必然未发生）；为真则抛出
		 * 来自确认程序或工具本体——Lua 动作脚本可能已经驱动了硬件才抛，此时
		 * 声称「没执行」就是谎报（那正是 SAN-4 要修的形态）。 */
		result = argsOk
			? AgentToolResult{std::string("工具执行抛出") + kNonStdExceptionNote
					+ "，本轮结果不可用；副作用可能已发生。"
					"请先确认硬件状态，再换一种做法或改用其他工具",
					"", false, "non-std exception", /* executed= */ true}
			: AgentToolResult{std::string("工具参数错误: 非标准异常")
					+ "（参数未能解析，本次调用未派发）",
					"", false, "non-std exception", /* executed= */ false};
	}

	const long long elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now() - t0).count();

	/* ---- 审计轨迹：参数错误也记——「模型想做什么但没做成」同样是审计
	 * 信息（被策略拒绝的调用也走这条：ok=false + error=policy_denied）。
	 * 图片只记字节数与指纹，不落 base64；命令原文遮蔽敏感值（maskToolArgs
	 * 单点，与确认程序的输入同一份）。 ---- */
	if (audit_) {
		AuditEntry e;
		e.turn = turn;
		e.requestId = call.requestId;
		e.tool = call.name;
		if (argsOk && parsedArgs.isObj()) {
			e.args = maskToolArgs(call.name, parsedArgs);
		}
		/* M1（2026-09-23 安全审计）：argsRaw 也需遮蔽密钥。解析失败时 args 为空，
		 * 只有 argsRaw 进审计文件；若模型发送含密钥的坏 JSON，密钥会以原文落盘。
		 * 修复：无论解析成功与否，argsRaw 都过 maskSecretsInText（与 args 的
		 * maskToolArgs 同一防护强度，纵深防御）。 */
		e.argsRaw = maskSecretsInText(call.arguments);
		e.ok = result.ok;
		e.error = result.error;
		e.ms = elapsedMs;
		e.bytes = result.text.size();
		e.imageBytes = result.imageDataUrl.size();
		if (!result.imageDataUrl.empty()) { e.imageFp = fingerprint64(result.imageDataUrl); }
		/* G2 结构化直传（2026-10-10）：此前只对 run_command 从回执文本反解
		 * exit_code=——现在工具里给了 exitCode 就记谁的（恒只有 run_command）。 */
		e.exitCode = result.exitCode;
		/* G2：工具自报的生效摘要（apply_sql 等）原样进审计，供复盘对账 */
		e.summary = result.summary;
		audit_->write(e);
	}
	return result;
}

} // namespace agent
} // namespace bot

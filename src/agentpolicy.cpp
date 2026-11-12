/* agentpolicy.cpp —— 策略钩子实现（见 agentpolicy.hpp 的设计约束） */

#include "agentpolicy.hpp"

#include <set>

#include "agent_subprocess.hpp"
#include "agentaudit.hpp"
#include "jsonconfig.hpp"

namespace bot {
namespace agent {

namespace {

constexpr std::size_t kPolicyFileMaxBytes = 64u * 1024;
/* 确认程序超时区间（秒）：下限 1 防 0/负值把确认变成「永远等不到」或「立刻
 * 判死」，上限 86400 与 --tcp-idle 同族（部署方可能接人工工单，确认程序
 * 里睡一天等审批也是合法用法，但更长得先想想是不是配错了单位）。 */
constexpr int kConfirmTimeoutMin = 1;
constexpr int kConfirmTimeoutMax = 86400;

/* 本类文件的读取口径：报错名词/动词逐字沿用旧文案；空文件**不**独立报错，
 * 落到「不是合法 JSON」（与 llm 配置的空文件口径不同，属旧有的既定行为）。 */
const jsonconfig::ConfigKind kPolicyKind = {"策略文件", "应为", false, kPolicyFileMaxBytes};

std::string typeError(const std::string& path, const std::string& key, const char* want) {
	return jsonconfig::typeError(kPolicyKind, path, key, want);
}

/* 外部确认程序的一次运行结果 */
struct ConfirmRun {
	bool ok = false;		/* 正常退出（拿到退出码） */
	bool timedOut = false;		/* 超时（已整组 SIGKILL 并回收） */
	std::string failReason;		/* ok=false 且非超时：pipe/fork/写失败等 */
	int exitCode = -1;
	int termSig = 0;		/* 被信号终止时记录 */
};

/* 跑一次外部确认程序：payload 写它的 stdin（经 /bin/sh -c），在 timeoutSec 内
 * 等它退出，超时整组 SIGKILL 并**有界**回收。
 *
 * 实现走 agent_subprocess 的统一骨架（runChild）：这条路径与 run_command 的
 * runShell 曾各写一份 fork/exec/超时/终止，防线性差异（有界回收、子进程 fd
 * 吊销）只落到了 runShell 一侧——旧实现在超时分支打的是无超时 waitpid（还被
 * retryEintr 包着，连 Ctrl-C 都打断不了），kill 未生效时 agent 会话永久挂死
 * （2026-09-22 审计 F1）。现在两处共用一个骨架，差异只经选项表达。
 *
 * 下面这些选项取值**是本路径的语义声明**，不要按「顺手统一」改写：
 *   * cleanEnv=false：确认程序是操作者自己写的可信程序，合法的确认脚本完全
 *     可能依赖自有 *_TOKEN 类环境变量，套用子进程环境清洗会**静默砸掉**它们。
 *     这条决策有钉子用例（test_agentpolicy.cpp 断言它能看见 BOT4CJ_LLM_KEY）
 *     与 docs/agent.md 的声明；要改先改那两处。
 *   * captureOutput=false：确认程序直接面对操作者（终端交互/中文提示），
 *     宿主不截它的输出。
 *   * watchStop=false：确认程序何时退出由它自己决定，宿主只等它到超时——
 *     Ctrl-C 不去打断确认（沿用原语义）。
 *   * revokeFds=true：子进程不得继承宿主 ≥3 的句柄（HAL/驱动的器件句柄在
 *     deactivate() 之后照样能 ioctl 拨硬件）。 */
ConfirmRun runConfirmProgram(const std::string& cmd, const std::string& payload,
		int timeoutSec) {
	ChildSpec spec;
	spec.cmd = cmd;
	spec.cleanEnv = false;		/* 见上：操作者可信程序，保留其自有环境 */
	spec.pipeStdin = true;
	spec.stdinPayload = payload;
	spec.captureOutput = false;	/* 输出直接进宿主终端 */
	spec.timeoutSec = timeoutSec;
	spec.graceMs = 2000;		/* 与 runShell 同款：回收有界 */
	spec.revokeFds = true;		/* 与 runShell 同款：不留继承句柄 */
	spec.watchStop = false;		/* 确认不响应 REPL 中断 */

	ChildOutcome co;
	try {
		co = runChild(spec);
	} catch (const std::exception& e) {
		/* pipe/fork 失败：策略钩子的失败要变成「拒绝」而不是异常（派发点按
		 * PolicyDecision 分流，对齐全仓 fail-closed 口径），成因原样带上。 */
		ConfirmRun bad;
		bad.failReason = e.what();
		return bad;
	}

	ConfirmRun out;
	if (co.timedOut) { out.timedOut = true; return out; }
	if (co.normalExit) { out.ok = true; out.exitCode = co.exitCode; return out; }
	if (co.termSig != 0) { out.ok = true; out.termSig = co.termSig; return out; }
	/* 两条不可判定的成因共用一条如实报告：①宽限内没回收（kill 未生效，如 D 态
	 * ——离线不可构造，故只钉告警文案）；②waitpid 给了非退出/非信号的状态
	 * （实际不可达，但 dev 分支不宜静默吞掉）。 */
	out.failReason = "确认程序退出状态无法判定（未回收或状态未知）";
	return out;
}

} // namespace

Json maskToolArgs(const std::string& tool, const Json& args) {
	if (tool != "run_command" || !args.isObj()) { return args; }
	const Json* cmd = args.find("command");
	if (cmd == nullptr || !cmd->isStr()) { return args; }
	const std::string masked = maskSecretsInText(cmd->s);
	if (masked == cmd->s) { return args; }	/* 没变化就不重写，保持原节点 */
	Json out = args;
	out.put("command", JsonString(masked));
	return out;
}

std::shared_ptr<const AgentPolicy> AgentPolicy::load(const std::string& path,
		std::string& err) {
	/* 读取/解析/顶层形态/未知字段拒绝的骨架与 llm 配置共用 jsonconfig 单点，
	 * 差异（名词、空文件口径）经 kPolicyKind 表达。 */
	static const std::set<std::string> kKnown = {
		"require_confirm", "confirm_command", "confirm_timeout_sec", "on_timeout",
	};
	Json root;
	if (!jsonconfig::loadRoot(kPolicyKind, path, kKnown, root, err)) {
		return nullptr;
	}

	auto policy = std::make_shared<AgentPolicy>();
	if (const Json* rc = root.find("require_confirm")) {
		if (!rc->isArr()) {
			err = typeError(path, "require_confirm", "字符串数组");
			return nullptr;
		}
		for (const Json& t : rc->arr) {
			if (!t.isStr() || t.getValue().empty()) {
				err = typeError(path, "require_confirm", "非空字符串数组（元素不得为空/非字符串）");
				return nullptr;
			}
			policy->requireConfirm_.push_back(t.getValue());
		}
	}
	if (const Json* cc = root.find("confirm_command")) {
		if (!cc->isStr() || cc->getValue().empty()) {
			err = typeError(path, "confirm_command", "非空字符串");
			return nullptr;
		}
		policy->confirmCommand_ = cc->getValue();
	}
	if (!policy->requireConfirm_.empty() && policy->confirmCommand_.empty()) {
		err = "策略文件 " + path + " 声明了 require_confirm 但缺 confirm_command："
			"需要确认却没有确认程序，等于每次调用都被拒——请补上该字段，"
			"或删掉 require_confirm（不启用确认）";
		return nullptr;
	}
	if (policy->requireConfirm_.empty() && !policy->confirmCommand_.empty()) {
		err = "策略文件 " + path + " 声明了 confirm_command 但 require_confirm 为空/缺失："
			"没有工具会走到确认，请补 require_confirm 数组";
		return nullptr;
	}
	if (const Json* ct = root.find("confirm_timeout_sec")) {
		if (!ct->isInt()) {
			err = typeError(path, "confirm_timeout_sec", "整数（秒）");
			return nullptr;
		}
		const long long v = ct->getInt();
		if (v < kConfirmTimeoutMin || v > kConfirmTimeoutMax) {
			err = "策略文件 " + path + " 的 confirm_timeout_sec 超出区间 ["
				+ std::to_string(kConfirmTimeoutMin) + ", "
				+ std::to_string(kConfirmTimeoutMax) + "]（实测 "
				+ std::to_string(v) + "）";
			return nullptr;
		}
		policy->timeoutSec_ = static_cast<int>(v);
	}
	if (const Json* ot = root.find("on_timeout")) {
		if (!ot->isStr() || (ot->getValue() != "deny" && ot->getValue() != "allow")) {
			err = typeError(path, "on_timeout", "\"deny\" 或 \"allow\"");
			return nullptr;
		}
		policy->timeoutDeny_ = (ot->getValue() == "deny");
	}
	return policy;
}

bool AgentPolicy::requiresConfirm(const std::string& tool) const {
	for (const auto& t : requireConfirm_) {
		if (t == tool) { return true; }
	}
	return false;
}

PolicyDecision AgentPolicy::confirm(const std::string& tool, const Json& args) const {
	if (!requiresConfirm(tool)) { return PolicyDecision{true, ""}; }

	/* 交给外部程序的参数先遮蔽：确认程序的输出/截图/转发不受本仓控制 */
	Json payload = JsonObject();
	payload.put("tool", JsonString(tool));
	payload.put("args", maskToolArgs(tool, args));

	const ConfirmRun r = runConfirmProgram(confirmCommand_, payload.toString(), timeoutSec_);
	if (r.timedOut) {
		const std::string why = "确认程序超时（>" + std::to_string(timeoutSec_) + "s）";
		if (timeoutDeny_) {
			return PolicyDecision{false, why + "，按 on_timeout=deny 拒绝"};
		}
		return PolicyDecision{true, why + "，按 on_timeout=allow 放行"};
	}
	if (!r.ok) {
		return PolicyDecision{false, "确认程序调用失败: " + r.failReason};
	}
	if (r.termSig != 0) {
		return PolicyDecision{false, "确认程序被信号 " + std::to_string(r.termSig) + " 终止，拒绝"};
	}
	if (r.exitCode != 0) {
		return PolicyDecision{false, "确认程序拒绝（退出码 " + std::to_string(r.exitCode) + "）"};
	}
	return PolicyDecision{true, ""};
}

} // namespace agent
} // namespace bot

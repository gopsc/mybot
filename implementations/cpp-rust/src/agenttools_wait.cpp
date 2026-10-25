/* agenttools_wait.cpp —— wait_variable 工具：感知-决策闭环的轮询机器
 * （拆自 agenttools.cpp，2026-10-01 TU 拆分；判据、文案与轮询语义逐字保持，
 * 装配入口 makeWaitVariableTool 经 agenttools_internal.hpp 供 makeAgentTools
 * 按门控挂载）。 */

#include "agentview.hpp"
#include "agenttools_internal.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <optional>
#include <thread>
#include <utility>

#include "util_env.hpp"		/* stopRequested */
#include "util_except.hpp"
#include "util_str.hpp"		/* concatMsg */

#include "robot.hpp"		/* RobotStruct 完整定义（ctx.robot->registry().find） */

namespace bot {
namespace agent {

/* ---- wait_variable（2026-09-25，感知-决策闭环）----
 * read_variables 只能读"此刻"；模型要等一个事件（水位到 30、门磁变化、守护
 * 计数推进）只能反复调它——每次都是一整轮模型往返（token、延迟、轮次预算）。
 * 本工具把"轮询直到条件成立或超时"下沉到后端，一次调用一个结论。
 *   * 与 read_variables **同一门控**（--read-var 声明集合、同一 resolvableReadVars
 *     解析）：等待的每次采样都是 playQuiet，副作用面与读一致。
 *   * 超时**是结果不是失败**（ok=true）：模型据此决定下一步，不该被当成工具坏了。
 *   * 等待期间后端主线程被占（单连接锁步协议本就如此，与 run_action_script 同），
 *     上限由 action_script_timeout_sec 封顶（<=0 时退化为 kWaitFallbackCapSec）；
 *     每个睡眠切片都看 stopRequested()——Ctrl-C 后端不会在这里坐满超时。
 *   * 键缺失**首采样不判错**：daemon 出首帧之前没有 v0 键，这是瞬时状态；
 *     超时回执列出样本现有键名，键名拼错的代价是一次超时而不是一次误判。
 *     但"键在而不是数值"对 gt/ge/lt/le 是永久性的类型不匹配，首采样即报参数错。 */
namespace {

enum class WaitCond { Gt, Ge, Lt, Le, Eq, Ne, Changed };

constexpr int kWaitFallbackCapSec = 3600;
constexpr int kWaitDefaultTimeoutSec = 30;
constexpr int kWaitDefaultPollMs = 200;
constexpr int kWaitMinPollMs = 50;
constexpr int kWaitMaxPollMs = 5000;

WaitCond parseWaitCond(const std::string& s) {
	if (s == "gt") { return WaitCond::Gt; }
	if (s == "ge") { return WaitCond::Ge; }
	if (s == "lt") { return WaitCond::Lt; }
	if (s == "le") { return WaitCond::Le; }
	if (s == "eq") { return WaitCond::Eq; }
	if (s == "ne") { return WaitCond::Ne; }
	if (s == "changed") { return WaitCond::Changed; }
	throw IllegalArgumentException("参数 condition 取值不合法：" + s
		+ "（可选 gt / ge / lt / le / eq / ne / changed）");
}

bool isOrderingCond(WaitCond c) {
	return c == WaitCond::Gt || c == WaitCond::Ge || c == WaitCond::Lt || c == WaitCond::Le;
}

/* 数值视图：Int/Float 直接取；Str 若**整串**是有限十进制数也认——驱动常把读数
 * 以字串回传（"23.5"），模型也常把 value 写成字串。其余 → 无数值视图。 */
std::optional<double> numericView(const Json& v) {
	if (v.isInt()) { return static_cast<double>(v.getInt()); }
	if (v.isFloat()) { return v.getFloat(); }
	if (v.isStr() && !v.s.empty()) {
		char* end = nullptr;
		errno = 0;
		const double d = std::strtod(v.s.c_str(), &end);
		if (errno == 0 && end == v.s.c_str() + v.s.size() && std::isfinite(d)) { return d; }
	}
	return std::nullopt;
}

std::string scalarText(const Json& v) { return v.isStr() ? v.s : v.toString(); }

/* 单次判定。@p baseline 是首采样的字串形态（仅 changed 用）。非数值撞上
 * 排序条件返回 false（首采样已把这种情况拦成参数错，后续采样按"不满足"看）。 */
bool waitCondHolds(WaitCond c, const Json& cur, const Json& want, const std::string& baseline) {
	if (c == WaitCond::Changed) { return cur.toString() != baseline; }
	const std::optional<double> a = numericView(cur);
	const std::optional<double> b = numericView(want);
	if (c == WaitCond::Eq || c == WaitCond::Ne) {
		const bool eq = (a && b) ? (*a == *b) : (scalarText(cur) == scalarText(want));
		return c == WaitCond::Eq ? eq : !eq;
	}
	if (!a || !b) { return false; }
	switch (c) {
	case WaitCond::Gt: return *a > *b;
	case WaitCond::Ge: return *a >= *b;
	case WaitCond::Lt: return *a < *b;
	case WaitCond::Le: return *a <= *b;
	default: return false;
	}
}

std::string keysOf(const Json& obj) {
	std::string out;
	for (const auto& [k, v] : obj.items()) {
		(void)v;
		if (!out.empty()) { out += ", "; }
		out += k;
	}
	return out.empty() ? "（无）" : out;
}

Json valueParam(const std::string& desc) {
	Json p = JsonObject();
	Json types = JsonArray();
	types.add(JsonString("number"));
	types.add(JsonString("string"));
	p.put("type", types);
	p.put("description", JsonString(desc));
	return p;
}

/* wait_variable 已校验的参数包（拆自 execute lambda，2026-09-26 批次 5）。
 * hw 是按 name 从注册表解析到的硬件变量指针（调用期内常驻，生命周期由 robot 保证）。 */
struct WaitParams {
	std::string name;
	std::string key;
	std::string condText;
	WaitCond cond = WaitCond::Eq;
	Json want = JsonNull();
	int timeoutSec = 0;
	int pollMs = 0;
	MatrixVars_Hardware* hw = nullptr;
};

/* 轮询结果（供回执拼装）：是否满足、采样次数、耗时、最后一次样本与读取错误。 */
struct WaitOutcome {
	bool satisfied = false;
	int samples = 0;
	long long elapsedMs = 0;
	Json lastSample = JsonNull();
	std::string lastError;
};

/* 参数解析与校验：全部在第一次触碰硬件之前完成，错即抛（上层折成 paramError）。 */
WaitParams parseWaitParams(const AgentToolContext& ctx, int capSec, int defaultSec,
		const Json& args) {
	WaitParams p;
	p.name = requireString(args, "name");
	p.key = requireString(args, "key");
	p.condText = requireString(args, "condition");
	p.cond = parseWaitCond(p.condText);
	if (p.cond != WaitCond::Changed) {
		auto v = args.get("value");
		if (!v || v->isNull()) {
			throw IllegalArgumentException("条件 " + p.condText + " 需要参数 value");
		}
		if (!(v->isInt() || v->isFloat() || v->isStr())) {
			throw IllegalArgumentException("参数 value 类型不符：需要数值或字串");
		}
		if (isOrderingCond(p.cond) && !numericView(*v)) {
			throw IllegalArgumentException("条件 " + p.condText + " 需要数值 value，实际 "
				+ v->toString());
		}
		p.want = *v;
	}
	p.timeoutSec = optionalInt(args, "timeout_sec", defaultSec);
	if (p.timeoutSec < 1 || p.timeoutSec > capSec) {
		throw IllegalArgumentException("参数 timeout_sec 须在 1.." + std::to_string(capSec)
			+ " 之间，实际 " + std::to_string(p.timeoutSec));
	}
	p.pollMs = optionalInt(args, "poll_ms", kWaitDefaultPollMs);
	if (p.pollMs < kWaitMinPollMs || p.pollMs > kWaitMaxPollMs) {
		throw IllegalArgumentException("参数 poll_ms 须在 " + std::to_string(kWaitMinPollMs)
			+ ".." + std::to_string(kWaitMaxPollMs) + " 之间，实际 "
			+ std::to_string(p.pollMs));
	}
	if (ctx.robot == nullptr) { throw std::runtime_error("没有常驻机器人实例"); }
	const std::vector<std::string> readable = resolvableReadVars(ctx.readVars, *ctx.robot);
	if (std::find(readable.begin(), readable.end(), p.name) == readable.end()) {
		throw IllegalArgumentException("变量 " + p.name + " 不在可读清单内（--read-var）");
	}
	p.hw = ctx.robot->registry().find(p.name);
	if (p.hw == nullptr) { throw std::runtime_error("变量 " + p.name + " 已不存在"); }
	return p;
}

/* 回执：结论在定界外（是本工具的判定），读数在定界内（来自驱动）。 */
AgentToolResult buildWaitReceipt(const WaitParams& p, const WaitOutcome& o) {
	const std::string label = p.name + "." + p.key + " " + p.condText
		+ (p.cond == WaitCond::Changed ? "" : " " + scalarText(p.want));
	std::string head = "wait_variable " + label + "：";
	if (o.satisfied) {
		head += "条件满足（等待 " + std::to_string(o.elapsedMs) + " ms，采样 "
			+ std::to_string(o.samples) + " 次）\n";
	} else {
		head += "超时未满足（" + std::to_string(p.timeoutSec) + " s，采样 "
			+ std::to_string(o.samples) + " 次）\n";
	}
	std::string body;
	const Json* cur = o.lastSample.isObj() ? o.lastSample.find(p.key) : nullptr;
	if (cur != nullptr) {
		body += "  " + p.name + "." + p.key + " = " + cur->toString() + "\n";
	} else {
		body += "  " + p.name + "." + p.key + " = (键不存在；样本现有键: " + keysOf(o.lastSample)
			+ ")\n";
	}
	body += "  " + p.name + " = " + o.lastSample.toString() + "\n";
	if (!o.lastError.empty()) { body += "  最后一次读取失败: " + o.lastError + "\n"; }
	const std::string summary = std::string("satisfied=") + (o.satisfied ? "true" : "false")
		+ " elapsed_ms=" + std::to_string(o.elapsedMs)
		+ " samples=" + std::to_string(o.samples);
	return {head + formatReadResult(body), "", true, "", true, false, summary};
}

/* 编排：解析参数 → 只读轮询直到条件满足/超时/被中断 → 拼回执。 */
AgentToolResult runWaitVariable(const AgentToolContext& ctx, int capSec, int defaultSec,
		const Json& args) {
	using Clock = std::chrono::steady_clock;
	const WaitParams p = parseWaitParams(ctx, capSec, defaultSec, args);

	/* ---- 轮询 ---- */
	const Clock::time_point t0 = Clock::now();
	const Clock::time_point deadline = t0 + std::chrono::seconds(p.timeoutSec);
	std::string baseline;
	bool haveBaseline = false;
	WaitOutcome o;
	auto interrupted = [] {
		throw std::runtime_error("执行被中断（收到停止信号），已放弃等待");
	};
	while (true) {
		if (stopRequested().load()) { interrupted(); }
		++o.samples;
		try {
			o.lastSample = p.hw->playQuiet(JsonObject());
			o.lastError.clear();
		} catch (const std::exception& e) {
			/* 首采样就读不到 → 快速失败（大概率是永久故障）；之后的读失败
			 * 按瞬时抖动看，记下继续等，超时回执如实带上。 */
			if (o.samples == 1) { throw; }
			o.lastError = e.what();
		}
		const Json* cur = o.lastSample.isObj() ? o.lastSample.find(p.key) : nullptr;
		if (cur != nullptr && !haveBaseline) {
			/* 键**首次出现**的那次采样：类型永久不匹配即刻报参数错；
			 * changed 的基线也取这里（键缺失的采样不能当基线） */
			if (isOrderingCond(p.cond) && !numericView(*cur)) {
				throw IllegalArgumentException(concatMsg("键 ", p.key, " 的当前值不是数值（",
					cur->toString(), "），条件 ", p.condText, " 无法比较"));
			}
			baseline = cur->toString();
			haveBaseline = true;
			if (p.cond != WaitCond::Changed) {
				o.satisfied = waitCondHolds(p.cond, *cur, p.want, baseline);
			}
		} else if (cur != nullptr) {
			o.satisfied = waitCondHolds(p.cond, *cur, p.want, baseline);
		}
		if (o.satisfied) { break; }
		const Clock::time_point now = Clock::now();
		if (now >= deadline) { break; }
		/* 睡眠切片 ≤100ms：停止信号最多迟 100ms 被看见 */
		Clock::time_point until = now + std::chrono::milliseconds(p.pollMs);
		if (until > deadline) { until = deadline; }
		for (Clock::time_point t = Clock::now(); t < until; t = Clock::now()) {
			if (stopRequested().load()) { interrupted(); }
			std::this_thread::sleep_for(std::min<Clock::duration>(
				until - t, std::chrono::milliseconds(100)));
		}
	}
	o.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
		Clock::now() - t0).count();
	return buildWaitReceipt(p, o);
}

} // namespace

AgentTool makeWaitVariableTool(const AgentToolContext& ctx) {
	const int capSec = ctx.scriptTimeoutSec > 0 ? ctx.scriptTimeoutSec : kWaitFallbackCapSec;
	const int defaultSec = std::min(kWaitDefaultTimeoutSec, capSec);
	return AgentTool{
		"wait_variable",
		"等待某个硬件变量的某个键满足条件（只读轮询，直到满足或超时）。"
		"比反复调 read_variables 省轮次：如「等 LUX 大于 300」「等 v0 变化」。"
		"变量须在 --read-var 清单内；键名不确定时先用 read_variables 看一眼返回表。"
		"超时不算失败，回执会说明超时与最后一次读数，由你决定下一步。",
		toolSchema({{"name", stringParam("硬件变量名（--read-var 清单之内）")},
			    {"key", stringParam("返回表中要观察的键，如 LUX、v0、count")},
			    {"condition", stringParam("条件：gt / ge / lt / le / eq / ne / changed"
				"（changed = 与开始等待时的值不同，无需 value）")},
			    {"value", valueParam("比较目标（数值或字串；condition=changed 时忽略）")},
			    {"timeout_sec", intParam("最长等待秒数，默认 " + std::to_string(defaultSec)
				+ "，上限 " + std::to_string(capSec))},
			    {"poll_ms", intParam("采样间隔毫秒，默认 "
				+ std::to_string(kWaitDefaultPollMs) + "（"
				+ std::to_string(kWaitMinPollMs) + ".."
				+ std::to_string(kWaitMaxPollMs) + "）")}},
			{"name", "key", "condition"}),
		[ctx, capSec, defaultSec](const Json& args) -> AgentToolResult {
			return runWaitVariable(ctx, capSec, defaultSec, args);
		}};
}

} // namespace agent
} // namespace bot

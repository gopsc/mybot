#pragma once
/* util_cli.hpp —— 命令行基础设施：--key=value/--key value/裸 --key 的切分单点，
 * 与 daemon/TCP/MCP 选项的参数化区间常量（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <string>

namespace bot {

/* ---- CLI 超时/上限参数化区间（2026-09-22 F-1/F-2/F-3，原 TD-2 剩余部分）----
 * 三个此前硬编码的运行期数值改为可选 CLI 参数（同款「不传 = 现状缺省值」
 * 零变更契约）。与 llm_limits（llmconfig.hpp）同一惯例：区间常量单点，
 * --help / 校验共用，避免「帮助写一个数、校验用另一个数」的漂移。这三个
 * 值不属于 agent 配置面（daemon/TCP 是全局能力，不限 --agent），故不进
 * llmconfig 的 LlmFileConfig，走普通 CLI 选项。 */
namespace daemon_limits {
/* RobotStruct::deactivate 的二段屏障宽限上限（原写死 kMaxGraceMs=30000）。
 * 下限 0：允许「不给弃管守护额外宽限」（宁可提前进入 destroy 竞态窗口，
 * 也要缩短停机时间——特殊场景下操作者可自行承担）。上限 300000（5 分钟）：
 * 弃管本就是「join 超时已经用尽」的兜底，再长的等待收益不大且会拖慢停机。 */
inline constexpr int kGraceMsMin = 0;
inline constexpr int kGraceMsMax = 300000;
inline constexpr int kGraceMsDefault = 30000;
} // namespace daemon_limits

namespace tcp_limits {
/* --tcp-max-auth-attempts：口令连续失败上限（原写死 kTcpAuthMaxFails=5）。
 * 下限 1：0 会让第一次失败就退出，与「重试」语义矛盾，不如干脆不设口令；
 * 上限 1000：远超任何合理部署，但不放开「无限」——无限重试等于放弃这条
 * 防爆破的护栏，与 max_calls_per_round 等「能力只能收紧」的口径不同源
 * （这里没有安全下界要保护，纯粹是「离谱数值大概率是打错」的常识上限）。 */
inline constexpr int kAuthMaxFailsMin = 1;
inline constexpr int kAuthMaxFailsMax = 1000;
inline constexpr int kAuthMaxFailsDefault = 5;
/* --tcp-total-timeout：连接总时长预算下限（原写死 tcpTotalBudgetSec 里的
 * 600）。生效值语义不变：max(该下限, idleSec*20)。下限 1：允许收紧到
 * 「基本不给慢滴对端机会」；上限 86400（24 小时）与 --tcp-idle 的既有上限
 * 同数量级，超过它的部署诉求应该用文件/TCP 之外的通道，而不是把连接
 * 挂一整天。 */
inline constexpr int kTotalTimeoutMin = 1;
inline constexpr int kTotalTimeoutMax = 86400;
inline constexpr int kTotalTimeoutDefault = 600;
} // namespace tcp_limits

namespace mcp_limits {
/* --mcp-backend 的三个每连接预算（2026-10-06 25.3 收单点）。此前上下限写死在
 * cliargs.cpp 的校验里，且每个数**各写两遍**（parseBoundedLong 与紧随其后的
 * rangeErrorText），帮助文本再手抄一遍「上限 86400」——同一个 86400 在 C++ 侧
 * 共 8 份（cliargs.cpp 4 + cliargs_help.cpp 4）。这正是本文件头注与
 * cliargs_help.cpp 头注都声明要防的「帮助写一个数、校验用另一个数」：tcp_limits
 * 与 daemon_limits 已按惯例把区间常量单点化并由 --help 与校验共用，mcp 这三个
 * 选项是漏网的（且没有任何守门比对两个帮助面，抄漏一边只会各说各话）。
 * 下限一律 0 = 不限（缺省不传即不限），与既有预算选项同口径。 */
inline constexpr int kCallBudgetMin = 0;
inline constexpr int kCallBudgetMax = 1000000;
/* --mcp-wall-clock 与 --mcp-idle-timeout 共用同一区间：cliargs.cpp 原注释
 * 「区间与墙钟同族（最长一天——空闲期不该比墙钟更宽松）」。上限与
 * tcp_limits::kTotalTimeoutMax 同为 86400（24 小时）。 */
inline constexpr int kBudgetSecMin = 0;
inline constexpr int kBudgetSecMax = 86400;
} // namespace mcp_limits

/* ---- 认证爆破失败门（安全判据单点；2026-09-30 审计 P1，2026-10-01 跨通道共用）----
 * 「连上并给出凭据但认证不通过」连续 N 次即停止服务的记账器。MCP 首帧
 * 认证（mcpbackend 的 acceptLoop）与 TCP 口令（actionsource 的
 * acceptAuthenticatedClient）共用同一结构与同一语义：
 *   - 只数「给出凭据但认证不通过」的失败（TCP 侧 NoCredential / MCP 侧
 *     哑对端——连上不发帧/超时/断连——都不计数）；
 *   - 认证**通过**才归零：「连了就断」刷不掉别人的失败窗口；
 *   - 连续到上限 recordRejected() 返回 true：调用方停止服务（fail-closed）。
 * 上限缺省同 tcp_limits::kAuthMaxFailsDefault；TCP 侧可经
 * --tcp-max-auth-attempts 覆盖（构造参数），MCP 侧固定用缺省。 */
struct AuthFailGate {
	explicit AuthFailGate(int maxIn = tcp_limits::kAuthMaxFailsDefault) : max(maxIn) {}
	int max;
	int fails = 0;
	bool recordRejected() { return ++fails >= max; }
	void recordPassed() { fails = 0; }
};

namespace cli {

/* 单个 argv 选项 token 的解析结果。hasValue=false 表示裸 flag——值语义
 * 由调用方裁决（布尔 flag 置位 / 缺值报错），本层不掺和。 */
struct OptionToken {
	std::string key;
	std::string value;
	bool hasValue = false;
};

/* --key=value / --key value / 裸 --key 的切分单点（main.cpp 与 mtmerge.cpp
 * 此前各写一份）。调用方保证 argv[k] 以 "--" 开头：
 * - '=' 内联值优先，key 不含 '='；
 * - 无 '=' 时看 argv[k+1]：strictLookahead=true（mybot CLI，审计中-3）要求
 *   下一参数不以 "--" 开头才算值——裸 --tcp 不得把后续 flag 吞成端口；
 *   false（mtmerge takeVal 原语义）只要存在即消费。消费与否同步推进 k。 */
inline OptionToken parseKeyValue(int& k, int argc, char** argv, bool strictLookahead) {
	OptionToken tok;
	std::string a = argv[k];
	tok.key = a.substr(2);
	auto eq = tok.key.find('=');
	if (eq != std::string::npos) {
		tok.value = tok.key.substr(eq + 1);
		tok.key = tok.key.substr(0, eq);
		tok.hasValue = true;
	} else if (k + 1 < argc
			&& (!strictLookahead || std::string(argv[k + 1]).rfind("--", 0) != 0)) {
		tok.value = argv[++k];
		tok.hasValue = true;
	}
	return tok;
}

} // namespace cli

} // namespace bot

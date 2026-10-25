#pragma once
/* mcpbackend.hpp —— MCP 后端（--mcp-backend，方案 F / 拓扑 F3）
 *
 * 把 agent 工具层经一条本地 AF_UNIX socket 暴露给 Rust MCP sidecar：sidecar 对上
 * 说 MCP（stdio），对下说这里的**pymsg 兼容帧**（4 字节 BE 长度 + UTF-8 JSON）。
 * 后端**不跑 agent 工具循环、不发起任何模型调用**——每次工具调用都由外部 MCP
 * 客户端驱动，后端只负责把调用穿过既有的唯一漏斗 DispatchGate::run
 * （策略确认 → 执行 → 审计），于是审计连续性与能力门控与 agent 模式逐字节一致。
 *
 * 线程归属（评估 §2.3）：runMcpBackend 在**调用者的线程（main 的主线程）**上同步
 * 服务，单连接、lock-step、严格串行——这正是 libmsg MsgServer(workers=0) 的性质，
 * 于是 callEchoSink / topDepth / luaExecBudget 三个 thread_local 天然正确，硬件
 * 调用自动串行（物理安全要的语义）。后端自己实现帧服务而不链接 libmsg：MsgServer
 * 硬编码 AF_INET（MsgServer.hpp:157-167）且全库无 SO_PEERCRED，加 UDS 要改共享头。
 *
 * 认证（评估 §3.1，用户定为「仅 SO_PEERCRED」）：socket 落 0700 目录、文件 0600，
 * accept 后用内核 SO_PEERCRED 校验对端 uid/gid == 本进程，不匹配即断连。
 * 2026-09-29 起叠加**首帧共享密钥**（审计 P2-1 落地，MCP-1）：BOT4CJ_MCP_TOKEN
 * 非空时每条连接的第一帧必须是 {"_route":"auth","token":...}，常数时间比对，
 * 失败即断连 + 审计（见 mcpCheckAuthFrame / serveConnection）。
 *
 * ⚠ 残留风险（评估 §3.2 的尖锐推论，必须**响亮**告知、不得藏）：
 *   SO_PEERCRED 只挡**别的用户**，挡不住**同 uid** 的进程——而模型驱动的
 *   run_command shell 恰恰与后端同 uid。理论上它若发现 socket 路径，就能直连后端、
 *   绕过 agent loop 的 maxCallsPerRound/maxTaskSeconds 这些物理安全上限（因为这些
 *   上限是在 loop 里强制的，直打 socket 就跳过了 loop）。已就位的缓解：
 *     ① listening fd 是 CLOEXEC（markAllFdsCloexec 在 fork 前枚举 /proc/self/fd 覆盖），
 *        run_command 子进程**不继承**它（但仍可自己 connect 到路径——CLOEXEC 挡不住）；
 *     ② 0700 目录 + 不可预测路径提高发现成本；
 *     ③ 每连接预算再强制（--mcp-call-budget/--mcp-wall-clock）限制跑飞；
 *     ④ 后端开 run_command/apply_sql 时**强制** --agent-policy 逐次外部确认（buildAgentConfig 11b）；
 *     ⑤ 首帧共享密钥 BOT4CJ_MCP_TOKEN（MCP-1 已实现，本注释下方「认证」段）：不设
 *        密钥的连接一律拒绝。密钥只进宿主内存与 Rust agent 进程——名字含
 *        token，被 isSensitiveEnvName 自动从 run_command 子进程环境剔除并抹零，
 *        且宿主的 PR_SET_DUMPABLE=0 收窄 /proc/<pid>/environ 的同 UID 读取
 *        （评估 §3.1 的「免费隔离」协同点，原为「将来加回」的建议）。
 *   未设 BOT4CJ_MCP_TOKEN 时回到「仅 SO_PEERCRED」的旧行为——残留风险同前，
 *   操作者应自行权衡（后端模式下**尽量不要开 --agent-shell**；若必须开，把后端
 *   跑在专用用户 / 容器里，或设置 BOT4CJ_MCP_TOKEN）。
 *
 * 2026-10-01 声明析出（行为保持）：帧传输与纯协议件（帧常量/编解码/deadline
 * 收发/SO_PEERCRED/占用探测/首帧认证/回执脱敏）→ mcptransport.hpp；socket
 * 服务域实现（serveConnection/断连安全动作/acceptLoop）→ mcplisten.cpp；
 * 本头只剩路由类 McpBackend、服务选项与服务入口。
 */

#include <chrono>
#include <cstddef>
#include <memory>
#include <ostream>
#include <string>

#include "mcptransport.hpp"
#include "agentaudit.hpp"
#include "agentdispatch.hpp"
#include "agentpolicy.hpp"
#include "agenttools.hpp"
#include "json.hpp"

namespace bot {

class RobotStruct;

namespace agent {

struct AgentModeConfig;	/* 定义在 agentmode.hpp；此处只按引用/常量引用用 */

struct McpBackendOptions {
	std::string socketPath;		/* AF_UNIX 路径（必填；长度受 sun_path 限制） */
	/* 每连接的工具调用上限（评估 §3.2 的「预算再强制」）：<=0 = 不限。
	 * 后端**不得假设调用方是 agent loop**，故自己再强制一遍——超限时拒绝派发
	 * 并如实回报（被拒的调用无副作用）。 */
	long callBudget = 0;
	long wallClockBudgetSec = 0;	/* 每连接墙钟预算（秒）；<=0 = 不限 */
	/* 每连接**空闲**（无帧）超时（秒，A-2，2026-09-25 审计）；<=0 = 不限。
	 * 缺省不限是刻意的：这是长生命周期控制通道，REPL 两次工具调用之间
	 * （人在思考、模型长推理）可能空闲很久。它针对的是「连上后一声不吭的
	 * 对端」——单连接串行模型下这种连接会一直占住唯一的 accept 槽，阻塞
	 * 正常客户端重连；显式给值即可让哑连接按时让位（断连不算错误，对端
	 * 可重连）。墙钟预算同样在空闲期收口（见 McpBackend::idleDeadline）。 */
	int idleTimeoutSec = 0;
	bool requirePeerCred = true;	/* accept 后 SO_PEERCRED 校验 uid/gid（单测可关） */
	int recvTimeoutSec = 10;	/* deadline recv 空闲超时（防 Slowloris，评估 §7.1） */
	/* 首帧共享密钥（MCP-1，审计 P2-1）：非空 = 每条连接必须先过 {"_route":"auth",
	 * "token":...} 才进入正常帧循环；空 = 不启用（仅 SO_PEERCRED 的旧行为）。
	 * 由 agentmode.cpp 的 captureMcpAuthToken 从 BOT4CJ_MCP_TOKEN 捕获后经
	 * main.cpp 的 runMcpBackendPipeline 填入（env 在宿主抹零前捕获）。 */
	std::string authToken;
};

/* ---- 首帧认证失败门（2026-09-30 审计 P1）----
 * 此前同 UID 对端可无限次重连试探 token，每次成本仅一个连接周期，与 TCP
 * 通道的 5 次爆破上限不对称。判据结构与 TCP 口令共用单点 AuthFailGate
 * （util_cli.hpp，2026-10-01 收敛），本侧固定缺省上限 5：
 *   - 只数「连上并给出首帧但认证不通过」的失败（mismatch 与 NotAuthFrame 都算
 *     ——试探者不能靠改发业务帧绕开计数）；
 *   - 认证**通过**才归零：哑对端（连上不发帧/超时/违规断连）不动计数——
 *     「连了就断」刷不掉别人的失败窗口，也刷不出自己的清白；
 *   - 连续到上限 recordRejected() 返回 true：acceptLoop 停止服务（fail-closed，
 *     走正常停机断电链），操作者重启后端恢复、必要时换 token。 */

/* 后端会话状态 + 路由。持有工具注册表、派发漏斗（DispatchGate）与每连接预算。
 * handleRequest / handleFrame 是纯逻辑（Json/文本 → Json/文本），不碰 socket，
 * 便于单测；socket 收发在 runMcpBackend 里。 */
class McpBackend {
public:
	/* cfg/robot 为**可空对**（要么都给、要么都空）：给了则 context.get 路由可用
	 * （Rust agent 以它为系统提示词素材的唯一来源，实时取材——热插拔后 hardware
	 * 反映当前注册表）；都空时 context.get 回错误（单测的手搓后端即此形态）。
	 * 生命周期：cfg 与 robot 都由 runMcpBackend 的调用链持有，跨越整个服务期。 */
	McpBackend(AgentToolRegistry tools,
			std::shared_ptr<const AgentPolicy> policy,
			std::shared_ptr<AuditLog> audit,
			long callBudget, long wallClockBudgetSec,
			const AgentModeConfig* cfg = nullptr, RobotStruct* robot = nullptr);

	/* gate_ 持有对本对象**自己的** tools_ 成员的引用，故 McpBackend 绝不可拷贝/
	 * 移动（移动会让 gate_ 的引用悬垂到被移走的旧对象）。就地构造；从工厂函数
	 * 按值返回时依赖 C++17 保证的复制消除（guaranteed copy elision），不触发移动。 */
	McpBackend(const McpBackend&) = delete;
	McpBackend& operator=(const McpBackend&) = delete;
	McpBackend(McpBackend&&) = delete;
	McpBackend& operator=(McpBackend&&) = delete;

	/* 每接受一条新连接调用一次：重置每连接的调用计数与墙钟起点。 */
	void beginConnection();

	/* 空闲等待的截止时刻（A-2，2026-09-25 审计）：取「墙钟预算的连接终点」
	 * （connStart_ + wallClockBudgetSec_，设了才算）与「此刻 + idleTimeoutSec」
	 * （>0 才算）两者中更早者；都不设则返回 steady_clock 最大值——空闲不限，
	 * 既有长生命周期语义。帧循环的空闲段据此收口：哑对端到点断连（可重连），
	 * 墙钟预算也因此真正覆盖空闲期（此前只在 routeToolCall 检查，空闲连接
	 * 永远撞不上）。单调时钟：不受系统时间被 NTP 拨动影响。 */
	std::chrono::steady_clock::time_point idleDeadline(int idleTimeoutSec) const;

	/* 路由一个**已解析**的请求对象 → 响应对象（{"success":...}）。不抛：任何
	 * 异常都折成 {"success":false,"error":...}（评估 §7.6「handler 异常 ⇒ 错误
	 * 回复，绝不崩溃」的不变式）。 */
	Json handleRequest(const Json& req);

	/* 处理一帧载荷文本：parseJson → handleRequest → toString。非法 JSON 或顶层
	 * 非对象 → 固定串 "invalid JSON request"（**从不回显输入**，与三份 libmsg
	 * 实现同口径，评估 §7.4）。 */
	std::string handleFrame(const std::string& payload);

	/* 整服务端**一** session（用户定）：在 accept 循环外写 start，停机时写 end。
	 * 会话行只带 status（模型侧字段已迁 Rust 退场，后端不调模型）；audit 未开启时 no-op。 */
	void writeSessionRecord(const char* status) const;

	/* MCP-1：首帧认证失败落审计（kind=session, status=auth_failed；无 token 泄漏）。 */
	void recordAuthRejected() const;

	const AgentToolRegistry& tools() const { return tools_; }

private:
	Json routeToolList();
	Json routeToolCall(const Json& req);
	/* 只读素材路由（rig agent 的系统提示词来源）：与 tool.list 同口径——不走
	 * DispatchGate、不计每连接预算（不发硬件指令、无副作用、无密钥）。 */
	Json routeContextGet();
	Json okReply(Json data) const;		/* {"success":true,"data":...} */
	Json errReply(const std::string& msg) const;	/* {"success":false,"error":...} */
	bool budgetExceeded(std::string& reason) const;

	/* 声明顺序即初始化顺序：gate_ 引用 tools_，故 tools_ 必须在 gate_ 之前。 */
	AgentToolRegistry tools_;
	std::shared_ptr<const AgentPolicy> policy_;
	std::shared_ptr<AuditLog> audit_;
	DispatchGate gate_;
	const AgentModeConfig* cfg_ = nullptr;	/* context.get 素材（可空，见构造器注） */
	RobotStruct* robot_ = nullptr;	/* 同上；非 const：describeHardware 取可变引用 */
	long callBudget_;
	long wallClockBudgetSec_;
	long calls_ = 0;		/* 本连接已派发的 tool.call 数 */
	int turn_ = 0;		/* 传给 DispatchGate::run 的轮次（审计用，逐次自增） */
	std::chrono::steady_clock::time_point connStart_;
};

/* 在主线程同步服务：绑定 AF_UNIX（0700 目录 / 0600 文件）→ accept 单连接 →
 * SO_PEERCRED 校验 → 帧循环（deadline recv + 8 MiB 上限 + 严格 UTF-8）→ 回帧。
 * 对端断开后回到 accept 等下一条（sidecar 可重连）；收到停止信号（stopRequested）
 * 优雅退出。返回进程退出码（0 正常 / 1 运行时错误 / 2 配置错误）。
 * 前提：robot 已 active()（工具作用于常驻机器人实例）。 */
int runMcpBackend(RobotStruct& robot, const AgentModeConfig& cfg,
		const McpBackendOptions& opts, std::ostream& log);

} // namespace agent
} // namespace bot

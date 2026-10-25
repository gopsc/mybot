#pragma once
/* mcplisten.hpp —— socket 服务域的可测接缝（实现在 mcplisten.cpp）
 *
 * 2026-10-10 析出：serveConnection/ConnAuth/ConnOutcome 此前是 mcplisten.cpp
 * 匿名命名空间静态件，白盒单测触不到（test_mcptransport 的 AuthFailGate 用例
 * 头注记录过这个缺口，当时只测了判据结构）。本头把连接服务与三个判据件交给
 * test_mcplisten.cpp 锚定——serveConnection 可用 socketpair + 对端线程全链路
 * 驱动（与 Rust 侧 agent/src/frame.rs 的 authenticate 测试同款形态）；acceptLoop /
 * runMcpBackend 仍是 TU 内编排，不经本头（不构成第二条消费面）。
 * 路由类契约见 mcpbackend.hpp，帧传输件见 mcptransport.hpp。 */

#include <optional>
#include <ostream>
#include <string>

#include "mcpbackend.hpp"	/* McpBackend / McpBackendOptions */

namespace bot {
namespace agent {

/* serveConnection 的认证记账结果（AuthFailGate 的输入，2026-09-30 审计 P1）：
 *   Failed——给出了首帧但认证不通过（连续失败计数 +1）；
 *   Passed——认证通过（业务循环无论怎么结束都算，连续失败计数归零）；
 *   Neutral——没走到认证判定（哑对端/无 token 模式），计数不动。 */
enum class ConnAuth { Neutral, Passed, Failed };

/* serveConnection 的连接结局（2026-10-01 审计 P2 前只有 ConnAuth，断连安全动作
 * 无条件执行——语义缺口见 acceptLoop 的门）。两个判据服务两件事，必须分开记：
 *   auth——AuthFailGate 爆破计数口径（见上）；
 *   admitted——是否真正进入过业务循环：无 token 模式恒 true；token 模式认证
 *     通过才 true。断连安全动作只对 admitted 连接执行——探连（连上就断/
 *     认证帧未到）与认证失败从未被服务，不该拥有触发硬件动作的通道。 */
struct ConnOutcome {
	ConnAuth auth = ConnAuth::Neutral;
	bool admitted = false;
};

/* 服务单条连接：帧循环直到对端关闭 / 协议违规 / 空闲超时 / 停止信号。
 * 空闲 deadline 逐帧重取（--mcp-idle-timeout 是「从现在起再等这么久」，
 * 墙钟预算是从连接起的绝对终点——两者由 idleDeadline 合成）。
 * MCP-1（审计 P2-1）：authToken 非空时第一帧是认证帧——通过才进入正常循环，
 * 不通过回执后断连（对端可修正重连）。失败的认证要落审计（kind=session，
 * status=auth_failed）：它是「有进程在试探这条 socket」的信号，事后复盘
 * 必须看得见；token 本身绝不进日志/审计/回执。 */
ConnOutcome serveConnection(int fd, McpBackend& backend, const McpBackendOptions& opts,
		std::ostream& log);

/* runMcpBackend 的路径预检（前两道判据，纯文本检查可离线锚定）：空路径/
 * 超长（sun_path 上限是内核 ABI，不是可配置项）→ 退出码 2 并写 log；
 * 合法 → nullopt 继续。 */
std::optional<int> preflightSocketPath(const std::string& socketPath, std::ostream& log);

/* 监听 socket 的父目录备置（prepareListenSocket 的第一段）：缺失则以 0700 建
 * （单级）；已存在但权限过松（group/other 可读）→ 告警不阻断（0700 目录是
 * SO_PEERCRED 之外的第二道同机隔离，见 mcpbackend.hpp 认证段）。返回 false =
 * 创建失败（配置类错误，调用方以退出码 2 收场）。 */
bool prepareSocketParentDir(const std::string& socketPath, std::ostream& log);

/* 断连安全动作的门（2026-10-01 审计 P2）：只对 admitted（进入过业务循环）的
 * 连接执行；未 admitted 且配置了脚本 → 显式跳过留痕；未配置脚本 → 无事。
 * 探连/认证失败从未被服务，不该拥有触发硬件动作的通道——此前无条件执行，
 * 同 UID 对端反复 connect+close 可以反复驱动执行器到"安全姿态"。 */
enum class DisconnectAction { Run, SkipNotAdmitted, NotConfigured };
DisconnectAction disconnectActionGate(bool admitted, const std::string& onDisconnectScript);

} // namespace agent
} // namespace bot

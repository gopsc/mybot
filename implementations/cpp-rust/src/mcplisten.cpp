/* mcplisten.cpp —— MCP 后端的 socket 服务域（见 mcpbackend.hpp 的设计说明）
 *
 * 2026-10-01 自 mcpbackend.cpp 拆出（行为保持）：serveConnection 连接服务、
 * runDisconnectAction 断连安全动作（--on-disconnect）、ListenSocket 与路径
 * 占用探测的绑定段、acceptLoop 与 runMcpBackend 主循环。帧编解码与纯协议件
 * 在 mcptransport.cpp，路由类 McpBackend 留守 mcpbackend.cpp——本文件只经
 * mcpbackend.hpp 的公开面驱动它。socket 建立沿用 actionsource.cpp 动作源 TCP
 * 的先例（FdGuard + poll + 停止信号响应），只是 AF_INET 换 AF_UNIX 并加
 * SO_PEERCRED。
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE	/* struct ucred / SO_PEERCRED / accept4 / SOCK_CLOEXEC */
#endif

#include "mcplisten.hpp"
#include "mcpbackend.hpp"

#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <chrono>
#include <filesystem>
#include <ostream>	/* std::ostream& 形参：此前靠 util_env.hpp 传导 */
#include <string>
#include <utility>
#include <vector>

#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include "agentmode.hpp"	/* AgentModeConfig / makeToolContext（工具层与 agent 模式同源装配） */
#include "robot.hpp"		/* RobotStruct 完整定义（runMcpBackend 入参，生命周期由 main 持有） */
#include "util_cli.hpp"		/* AuthFailGate（认证爆破失败门单点） */
#include "util_env.hpp"		/* errnoText（bind/listen/poll 失败文案） */
#include "util_file.hpp"		/* FdGuard（监听/连接 fd 的 RAII 收管） */
#include "util_utf8.hpp"		/* stopRequested */

namespace fs = std::filesystem;

namespace bot {
namespace agent {
namespace {

/* 帧传输件（writeBe32/readBe32/sanitizeError/recvAllDeadline/readFrame/
 * sendFrame）与纯协议件（mcpEncodeFrame/mcpCheckAuthFrame/mcpCheckPeerCred/
 * mcpProbeSocketPath）已整体迁至 mcptransport.cpp（2026-10-01 TU 拆分），
 * 跨 TU 接缝见 mcpbackend.hpp 的「帧传输接缝」。 */

using Clock = std::chrono::steady_clock;

} // namespace

/* ---- 连接服务（ConnAuth/ConnOutcome/serveConnection 的契约与可测接缝在
 * mcplisten.hpp，2026-10-10 析出；此处实现）---- */
ConnOutcome serveConnection(int fd, McpBackend& backend, const McpBackendOptions& opts,
		std::ostream& log) {
	bool admitted = opts.authToken.empty();
	if (!opts.authToken.empty()) {
		std::string payload;
		const FrameResult fr = readFrame(fd, payload, opts.recvTimeoutSec,
			backend.idleDeadline(opts.idleTimeoutSec), log);
		if (fr != FrameResult::Ok) {
			/* 对端连上后连认证帧都没发就消失/超时——按违规口径断连即可，
			 * 空闲超时的既有文案已覆盖「哑对端让位」的语义。 */
			if (fr == FrameResult::IdleTimeout) {
				log << kMcpLogPrefix << "认证帧未到，空闲超时/墙钟预算耗尽，断开连接\n";
			} else if (fr == FrameResult::Violation) {
				log << kMcpLogPrefix << "认证帧违规，断开连接\n";
			}
			return ConnOutcome{ConnAuth::Neutral, false};
		}
		const McpAuthOutcome a = mcpCheckAuthFrame(opts.authToken, payload);
		if (a == McpAuthOutcome::Ok) {
			/* lock-step：认证帧也要回执（Rust 侧 authenticate 在等这一帧）；
			 * 回帧构造单点在 mcptransport（与判据 mcpCheckAuthFrame 同族） */
			if (!sendFrame(fd, mcpAuthOkFrame(), kMcpSendTimeoutSec)) {
				log << kMcpLogPrefix << "认证回帧发送失败，断开连接\n";
				return ConnOutcome{ConnAuth::Neutral, false};
			}
			log << kMcpLogPrefix << "首帧认证通过\n";
			admitted = true;
		} else {
			/* 回执不回显 token、不区分「错密钥」与「没带密钥」——对试探者
			 * 两者给同一句话，信息量最小化（文案单点在 mcpAuthRejectFrame）。 */
			(void)sendFrame(fd, mcpAuthRejectFrame(), kMcpSendTimeoutSec);
			log << kMcpLogPrefix << "首帧认证失败（" << (a == McpAuthOutcome::NotAuthFrame
				? "第一帧不是 auth 帧" : "共享密钥不匹配")
				<< "），断开连接\n";
			backend.recordAuthRejected();
			return ConnOutcome{ConnAuth::Failed, false};
		}
	}
	const ConnAuth result = opts.authToken.empty() ? ConnAuth::Neutral : ConnAuth::Passed;
	while (!stopRequested()) {
		std::string payload;
		const FrameResult fr = readFrame(fd, payload, opts.recvTimeoutSec,
			backend.idleDeadline(opts.idleTimeoutSec), log);
		if (fr == FrameResult::PeerClosed) { return ConnOutcome{result, admitted}; }
		if (fr == FrameResult::IdleTimeout) {
			log << kMcpLogPrefix << "空闲超时/每连接墙钟预算耗尽，断开连接（对端可重连）\n";
			return ConnOutcome{result, admitted};
		}
		if (fr == FrameResult::Violation) {
			log << kMcpLogPrefix << "协议违规，断开连接\n";
			return ConnOutcome{result, admitted};
		}
		const std::string resp = backend.handleFrame(payload);
		if (!sendFrame(fd, resp, kMcpSendTimeoutSec)) {
			log << kMcpLogPrefix << "回帧发送失败，断开连接\n";
			return ConnOutcome{result, admitted};
		}
	}
	return ConnOutcome{result, admitted};
}

/* ---- socket 服务 ---- */

/* ---- 断连安全动作（2026-09-25，--on-disconnect）----
 * 连接结束（任何原因：对端关闭/崩溃/空闲或墙钟超时/协议违规/发送失败）后，
 * 后端自己把硬件带到操作者预设的安全姿态。此前 agent 进程一死，硬件就停在
 * **最后一个姿态**带电常驻（docs/agent.md 已知限制）。
 *   * 不走 DispatchGate：这不是模型的请求，是操作者的配置；策略确认钩子
 *     （require_confirm）是给"模型想做什么"设的闸门，安全动作等它反而危险；
 *   * 执行判据与 run_action_script 同源（runActionScriptFile：沙箱/体积/预算）；
 *   * 失败**不能**让后端退出——退出即摘电清理，反倒是另一种"安全"，但会把
 *     操作者的重连机会一起带走；故只记日志 + 审计（kind=session，
 *     status=disconnect_action，error 字段即失败原因），继续 accept；
 *   * 停机（stopRequested）不触发：SIGINT/SIGTERM 路径由 deactivate() 的
 *     断电清理链负责，再跑一个动作脚本只会拖慢停机。 */
static void runDisconnectAction(const AgentToolContext& tctx, const std::string& script,
		const std::shared_ptr<AuditLog>& audit, std::ostream& log) {
	if (script.empty() || stopRequested()) { return; }
	log << kMcpLogPrefix << "连接结束，执行断连安全动作 " << script << "\n";
	AuditEntry e;
	e.kind = "session";
	e.status = "disconnect_action";
	e.summary = script;
	const Clock::time_point t0 = Clock::now();
	try {
		std::string echo;
		const std::size_t bytes = runActionScriptFile(tctx, script, echo);
		log << kMcpLogPrefix << "断连安全动作完成（" << bytes << " 字节）\n";
	} catch (const std::exception& ex) {
		e.error = ex.what();
		log << kMcpLogPrefix << "断连安全动作失败: " << ex.what() << "（后端继续服务）\n";
	} catch (...) {
		e.error = "unknown exception";
		log << kMcpLogPrefix << "断连安全动作失败: 未知异常（后端继续服务）\n";
	}
	e.ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
	if (e.ms <= 0) { e.ms = 1; }	/* ms>0 才落字段；0 会让"跑过"这件事在审计里消失 */
	if (audit && audit->enabled()) { audit->write(e); }
}

/* ---- 断连安全动作的门（契约见 mcplisten.hpp；2026-10-10 自 acceptLoop
 * 内联析出供白盒锚定）----
 * 此前无条件执行——同 UID 对端反复 connect+close（或反复发错密钥）可以反复
 * 驱动执行器到"安全姿态"，连败 5 次还会借停机断电链把后端打停；认证门
 * （MCP-1/AuthFailGate）只盖住了工具派发路径，没盖住断连路径。 */
DisconnectAction disconnectActionGate(bool admitted, const std::string& onDisconnectScript) {
	if (onDisconnectScript.empty()) { return DisconnectAction::NotConfigured; }
	return admitted ? DisconnectAction::Run : DisconnectAction::SkipNotAdmitted;
}

/* ---- 监听 socket 的父目录备置（契约见 mcplisten.hpp；2026-10-10 自
 * prepareListenSocket 首段析出供白盒锚定）----
 * 父目录是 SO_PEERCRED 之外的第二道同机隔离：缺失则以 0700 建（单级）；
 * 已存在但权限过松则告警（不静默）——0700 建议写进日志而非替操作者收紧。 */
bool prepareSocketParentDir(const std::string& socketPath, std::ostream& log) {
	const fs::path sp(socketPath);
	fs::path parent = sp.parent_path();
	if (parent.empty()) { parent = "."; }
	std::error_code ec;
	if (!fs::exists(parent, ec)) {
		if (::mkdir(parent.c_str(), 0700) != 0 && errno != EEXIST) {
			log << "错误: 无法创建 socket 父目录 '" << parent.string() << "': "
				<< errnoText(errno) << "\n";
			return false;
		}
	} else {
		struct stat st{};
		if (::stat(parent.c_str(), &st) == 0 && (st.st_mode & 0077) != 0) {
			log << "警告: socket 父目录 '" << parent.string()
				<< "' 权限过松（建议 0700）；同机其他用户可能连上后端\n";
		}
	}
	return true;
}

namespace {

/* AF_UNIX 监听套接字的准备结果（拆自 runMcpBackend，2026-09-26 批次 5）：
 * fd 为已 bind+listen 的套接字（get() < 0 = 失败），rc 为失败时的进程退出码
 * （0 = 成功；配置类错误 2、系统调用类错误 1，与 runMcpBackend 原口径一致）。 */
struct ListenSocket {
	FdGuard fd;
	int rc = 0;
};

/* 准备 AF_UNIX 监听套接字：父目录创建/权限体检（单点 prepareSocketParentDir）→
 * 启动前探测（A-1）→ socket/bind/chmod 0600/listen。成功返回已监听的 fd（rc=0）；
 * 失败把原因写进 log 并返回相应退出码，fd 为空。 */
ListenSocket prepareListenSocket(const std::string& socketPath, std::ostream& log) {
	if (!prepareSocketParentDir(socketPath, log)) {
		return ListenSocket{FdGuard(), 2};
	}

	/* 启动前探测（A-1，2026-09-25 审计）：不再无条件 unlink——误配同一路径的
	 * 第二个后端会静默偷走 socket 文件、让先启动者永远不可达。三态处置：
	 * 活实例/无法判定 → 响亮拒绝（fail-closed，换路径或先停占用者）；
	 * 陈旧残留（上次实例没清理）→ 安全 unlink 后绑定；非 socket 文件 →
	 * 不替操作者删陌生文件。 */
	std::string probeWhy;
	switch (mcpProbeSocketPath(socketPath, probeWhy)) {
	case McpSocketProbe::PathBusy:
		log << "错误: socket 路径 '" << socketPath << "' 已被占用（" << probeWhy
			<< "）。两个后端共用一条路径会让后启动者静默偷走 socket、先启动者"
			"继续监听却永远不可达。请给本实例换 --mcp-socket，或先停掉占用者。\n";
		return ListenSocket{FdGuard(), 2};
	case McpSocketProbe::PathUnusable:
		log << "错误: socket 路径 '" << socketPath << "' 不可用（" << probeWhy
			<< "）；不会自动删除它，请手工处理后重试。\n";
		return ListenSocket{FdGuard(), 2};
	case McpSocketProbe::PathFree:
		break;
	}
	::unlink(socketPath.c_str());	/* 陈旧 socket（探测确认无人监听）：清掉再绑定 */

	FdGuard listenFd(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
	if (listenFd.get() < 0) {
		log << "错误: 无法创建 AF_UNIX 套接字: " << errnoText(errno) << "\n";
		return ListenSocket{FdGuard(), 1};
	}
	sockaddr_un addr{};
	addr.sun_family = AF_UNIX;
	std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socketPath.c_str());
	if (::bind(listenFd.get(), reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
		log << "错误: 绑定 '" << socketPath << "' 失败: " << errnoText(errno) << "\n";
		return ListenSocket{FdGuard(), 1};
	}
	/* 0600 收紧失败要告警（不阻断）：目录 0700 已挡住其他用户，但静默缺位
	 * 会让「以为收紧了」与「实际靠 umask」漂移。 */
	if (::chmod(socketPath.c_str(), 0600) != 0) {
		log << "警告: socket 文件 chmod 0600 失败（" << errnoText(errno)
			<< "）；文件权限取决于当前 umask，建议检查 " << socketPath << "\n";
	}
	if (::listen(listenFd.get(), 1) < 0) {
		log << "错误: 监听失败: " << errnoText(errno) << "\n";
		::unlink(socketPath.c_str());
		return ListenSocket{FdGuard(), 1};
	}
	return ListenSocket{std::move(listenFd), 0};
}

/* accept 循环（拆自 runMcpBackend，2026-09-26 批次 5）：poll 等连接（带超时以便
 * 轮询 stopRequested）→ accept4 → SO_PEERCRED 校验 → serveConnection 服务 →
 * 关连接 → 断连安全动作（仅 admitted 连接）。单连接串行。慢读端防挂由写侧的
 * sendFrame deadline 承担（2026-10-01 批次 A / P1-3：SO_SNDTIMEO 移除——
 * 其 setsockopt 失败只告警的路径上防线是静默缺位的）。
 * 返回退出码（0 = 收到停止信号正常退出，1 = poll/accept 出错）。 */
int acceptLoop(FdGuard& listenFd, McpBackend& backend, const AgentToolContext& tctx,
		const AgentModeConfig& cfg, const McpBackendOptions& opts, std::ostream& log) {
	int rc = 0;
	/* 首帧认证连续失败门（2026-09-30 审计 P1）：此前同 UID 对端可无限次重连
	 * 试探 token（每次成本仅一个连接周期），与 TCP 口令通道的 5 次爆破上限
	 * 不对称。语义见 AuthFailGate；到顶 = 停止服务（fail-closed，走正常
	 * 停机断电链），操作者重启后端恢复。 */
	AuthFailGate authGate;
	while (!stopRequested()) {
		/* 这段 poll 与 mcptransport.cpp 的 recvAllDeadline / readFrame 同型而策略
		 * 不同，25.2 评估后判不抽公共 helper，理由见 recvAllDeadline 的头注。
		 * 本处两条差异是刻意的，别「顺手统一」：
		 *   - EINTR → continue 回到 while 条件重查 stopRequested()，这是
		 *     installStopSignalHandlers 不装 SA_RESTART 的用意，不要包 retryEintr；
		 *   - **不查** POLLERR|POLLNVAL（另两处查）：监听 fd 上真出了这两样，
		 *     紧随的 accept4 会失败并走同一条 log + rc=1 + break，处置等价、只是
		 *     文案报在 accept 而不是 poll 上；补一道检查只多一份要同步的分支。 */
		struct pollfd p{};
		p.fd = listenFd.get();
		p.events = POLLIN;
		const int r = ::poll(&p, 1, kMcpPollIntervalMs);
		if (r < 0) {
			if (errno == EINTR) { continue; }
			log << kMcpLogPrefix << "poll 失败: " << errnoText(errno) << "\n";
			rc = 1;
			break;
		}
		if (r == 0) { continue; }	/* 超时：回去检查 stopRequested */
		const int client = ::accept4(listenFd.get(), nullptr, nullptr, SOCK_CLOEXEC);
		if (client < 0) {
			if (errno == EINTR) { continue; }
			log << kMcpLogPrefix << "accept 失败: " << errnoText(errno) << "\n";
			rc = 1;
			break;
		}
		FdGuard clientFd(client);
		if (opts.requirePeerCred && !mcpCheckPeerCred(clientFd.get(), log)) {
			continue;	/* 关掉这条，回去等下一个（可能是扫描/误连） */
		}

		backend.beginConnection();
		log << kMcpLogPrefix << "sidecar 已连接，开始服务\n";
		const ConnOutcome oc = serveConnection(clientFd.get(), backend, opts, log);
		/* 先关连接再跑安全动作：对端若还挂着（半关闭），不该看见动作期间的
		 * 任何回帧；且动作脚本可能跑几秒，不占着 fd。 */
		clientFd.close();
		/* 断连安全动作的门（disconnectActionGate，2026-10-01 审计 P2）：只对
		 * 「进入过业务循环」的连接执行，跳过要留痕——这是安全相关的可观测
		 * 行为，不该静默。admitted 语义见 ConnOutcome。 */
		switch (disconnectActionGate(oc.admitted, cfg.onDisconnectScript)) {
		case DisconnectAction::Run:
			runDisconnectAction(tctx, cfg.onDisconnectScript, cfg.audit, log);
			break;
		case DisconnectAction::SkipNotAdmitted:
			log << kMcpLogPrefix << "连接未通过认证，跳过断连安全动作 " << cfg.onDisconnectScript
				<< "\n";
			break;
		case DisconnectAction::NotConfigured:
			break;
		}
		if (oc.auth == ConnAuth::Passed) {
			authGate.recordPassed();
		} else if (oc.auth == ConnAuth::Failed) {
			if (authGate.recordRejected()) {
				log << kMcpLogPrefix << "首帧认证连续 " << authGate.max
					<< " 次失败，停止服务（可能为爆破；重启后端恢复，"
					"必要时更换 BOT4CJ_MCP_TOKEN）\n";
				rc = 1;
				break;
			}
			log << kMcpLogPrefix << "认证失败（连续 " << authGate.fails << "/"
				<< authGate.max << "），回到 accept 等待\n";
			continue;
		}
		log << kMcpLogPrefix << "连接结束，回到 accept 等待\n";
	}
	return rc;
}

} // namespace

/* ---- runMcpBackend 的路径预检（契约见 mcplisten.hpp；2026-10-10 自
 * runMcpBackend 首两道判据析出供白盒锚定）----
 * 放在一切装配之前：配置类错误不必等到 bind 才发现。 */
std::optional<int> preflightSocketPath(const std::string& socketPath, std::ostream& log) {
	if (socketPath.empty()) {
		log << "错误: --mcp-backend 需要 --mcp-socket <AF_UNIX 路径>\n";
		return 2;
	}
	if (socketPath.size() >= sizeof(sockaddr_un::sun_path)) {
		log << "错误: --mcp-socket 路径过长（" << socketPath.size() << " 字节，上限 "
			<< (sizeof(sockaddr_un::sun_path) - 1) << "）\n";
		return 2;
	}
	return std::nullopt;
}

int runMcpBackend(RobotStruct& robot, const AgentModeConfig& cfg,
		const McpBackendOptions& opts, std::ostream& log) {
	if (const std::optional<int> rc = preflightSocketPath(opts.socketPath, log)) {
		return *rc;
	}

	/* 工具层：与 agent 模式共用 makeToolContext + makeAgentTools，能力门控
	 * （--agent-shell / --agent-hot-sql / --read-var / camera）逐字节一致，
	 * 于是 tool.list 天然只宣告已放行的工具（评估 §3.1）。 */
	AgentToolContext tctx = makeToolContext(cfg, robot, log);
	AgentToolRegistry tools = makeAgentTools(tctx);
	McpBackend backend(std::move(tools), cfg.policy, cfg.audit,
		opts.callBudget, opts.wallClockBudgetSec, &cfg, &robot);

	/* 监听套接字准备（父目录 / A-1 探测 / bind / chmod / listen）单点在
	 * prepareListenSocket；失败已写 log，这里只传导退出码。 */
	ListenSocket ls = prepareListenSocket(opts.socketPath, log);
	if (ls.rc != 0) { return ls.rc; }

	backend.writeSessionRecord("start");
	log << "MCP 后端监听 " << opts.socketPath
		<< "（单连接串行；SO_PEERCRED 校验 uid/gid"
		<< (opts.authToken.empty()
			? "；未设 BOT4CJ_MCP_TOKEN，同 UID 直连仅靠 loop 预算兜底"
			: "；首帧共享密钥已启用（BOT4CJ_MCP_TOKEN）")
		<< "；等待 sidecar 连接）\n";

	const int rc = acceptLoop(ls.fd, backend, tctx, cfg, opts, log);

	backend.writeSessionRecord("end");
	::unlink(opts.socketPath.c_str());
	log << kMcpLogPrefix << "已停机\n";
	return rc;
}

} // namespace agent
} // namespace bot

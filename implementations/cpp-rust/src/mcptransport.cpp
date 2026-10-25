/* mcptransport.cpp —— MCP 后端的帧传输与纯协议件（拆自 mcpbackend.cpp，2026-10-01）
 * 内容：4 字节 BE 长度前缀帧的编解码与 deadline 收发（防 Slowloris）、
 * 首帧共享密钥校验、SO_PEERCRED 对端校验、启动前 socket 路径占用探测。
 * mcpbackend.cpp 留连接编排（serveConnection/acceptLoop/runMcpBackend）与
 * McpBackend 路由；跨 TU 接缝（FrameResult/readFrame/sendFrame/常量）在
 * mcpbackend.hpp。 */

#include "mcptransport.hpp"

#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include "jsonparse.hpp"	/* parseJson */
#include "mcp_protocol.hpp"	/* kRoute / kAuth / kToken（跨进程字段名单点） */
#include "util_env.hpp"		/* stopRequested / errnoText */
#include "util_file.hpp"	/* FdGuard */
#include "util_str.hpp"		/* safeEquals（凭据比对安全单点） */
#include "util_utf8.hpp"	/* isValidUtf8 */

namespace bot {
namespace agent {

namespace {

/* 启动探测的 connect 等待上限（A-1）：AF_UNIX 正常路径用不满它，只挡
 * 「既不接也不拒」的异常对端把启动挂死。 */
constexpr int kProbeWaitMs = 500;

using Clock = std::chrono::steady_clock;

void writeBe32(char* out, std::uint32_t v) {
	out[0] = static_cast<char>((v >> 24) & 0xFFu);
	out[1] = static_cast<char>((v >> 16) & 0xFFu);
	out[2] = static_cast<char>((v >> 8) & 0xFFu);
	out[3] = static_cast<char>(v & 0xFFu);
}

std::uint32_t readBe32(const char* in) {
	return (static_cast<std::uint32_t>(static_cast<unsigned char>(in[0])) << 24)
		| (static_cast<std::uint32_t>(static_cast<unsigned char>(in[1])) << 16)
		| (static_cast<std::uint32_t>(static_cast<unsigned char>(in[2])) << 8)
		| (static_cast<std::uint32_t>(static_cast<unsigned char>(in[3])));
}

/* deadline 模式收满 n 字节：帧头与载荷共享同一绝对 deadline（防 Slowloris）。
 * 返回 true=收满；false=超时/错误/对端关闭（关闭时置 eof）。
 *
 * 25.2 评估后**判不改**：本函数与 readFrame 的空闲等首字节、mcplisten.cpp
 * acceptLoop 的等连接，三处都是「pollfd + POLLIN + ::poll + r<0/EINTR + r==0 +
 * POLLERR|POLLNVAL」的同型六行，看着像三胞胎，实测是三套不同策略，抽一个
 * `pollReadable(fd, timeoutMs)`（EINTR 在 helper 内 continue、不外泄）会同时砸掉
 * 两条已有防线：
 *   ① 本函数的超时是**绝对 deadline 推导**的 remainMs，每轮重算；helper 吞掉
 *      EINTR 后拿同一个 timeoutMs 再 poll 一遍，总等待可越过 deadline（EINTR 来
 *      得越早越界），Slowloris 的预算就从「一条帧一个 deadline」松成「一次中断
 *      翻一倍」。另两处用的是固定 tick（kMcpPollIntervalMs），没有 deadline 可传
 *      ——要兼容就得两种签名，那已经不是单点了。
 *   ② 另两处的 EINTR → continue 会**回到循环顶重查 stopRequested()**，这正是
 *      main.cpp 的 installStopSignalHandlers 明确不装 SA_RESTART 的目的（「让
 *      accept 等阻塞点被 EINTR 打断以便检查标志」）；helper 把 EINTR 吞在里面，
 *      等于把停止响应从「信号到达即返回」拖回「等满 200ms tick」，no-SA_RESTART
 *      那半个设计白做。同型事故本仓已有留档：agentpolicy.cpp 头注记的审计 F1
 *      ——无超时 waitpid 被 retryEintr 包着，「连 Ctrl-C 都打断不了」，kill 未
 *      生效时 agent 会话永久挂死。util_file.hpp 的 retryEintr 是「EINTR 可以安全
 *      吞掉」那些调用点的单点，poll 这三处恰恰不在其列。
 *   ③ POLLERR|POLLNVAL 三处处置不同（本函数与 readFrame 判失败，acceptLoop
 *      根本不查、径直落到 accept4 由它报错），helper 要如实上报就得再多一个
 *      状态，调用方的映射代码把省下的行数原样吃回去（实测净 LOC ≈ 0）。
 * 结论：这三处的共性只是六行 POSIX 样板，差异全在语义上；样板不值得为它引入
 * 一个必须编码三套映射的状态机。要动先给三条策略各自留钉子用例。 */
bool recvAllDeadline(int fd, char* buf, std::size_t n, Clock::time_point deadline, bool& eof) {
	std::size_t got = 0;
	while (got < n) {
		const auto now = Clock::now();
		if (now >= deadline) { return false; }
		const long remainMs = std::chrono::duration_cast<std::chrono::milliseconds>(
			deadline - now).count();
		struct pollfd p{};
		p.fd = fd;
		p.events = POLLIN;
		const int r = ::poll(&p, 1, remainMs > 0 ? static_cast<int>(remainMs) : 0);
		if (r < 0) {
			if (errno == EINTR) { continue; }
			return false;
		}
		if (r == 0) { return false; }	/* 超时 */
		if ((p.revents & (POLLERR | POLLNVAL)) != 0) { return false; }
		const ssize_t k = ::recv(fd, buf + got, n - got, 0);
		if (k == 0) { eof = true; return false; }	/* 对端关闭 */
		if (k < 0) {
			if (errno == EINTR) { continue; }
			return false;
		}
		got += static_cast<std::size_t>(k);
	}
	return true;
}

/* deadline 模式发满 n 字节（2026-10-01 批次 A / P1-3）。
 * 此前 sendFrame 无 deadline，靠 acceptLoop 挂的 SO_SNDTIMEO 兜底——而
 * setsockopt 失败只告警，该路径上慢读端可无限挂住单线程后端（Rust 侧同类
 * 修复见 0333f1a：写侧纳入与读侧同预算）。这里用 MSG_DONTWAIT + 短拍休眠 +
 * 进程内绝对 deadline：**不用 poll(POLLOUT)**——AF_UNIX 在对端接收缓冲已满时
 * 仍报告可写（POLLOUT 不反映缓冲余量，实测 poll 恒就绪而 send 永久阻塞），
 * 而 MSG_DONTWAIT 的 EAGAIN 才是「缓冲满」的可靠信号；休眠粒度取
 * kMcpPollIntervalMs（与全仓的停止响应粒度同一量级）。
 * 返回 true=发满；false=超时/错误/对端关闭。 */
bool sendAllDeadline(int fd, const char* buf, std::size_t n, Clock::time_point deadline) {
	std::size_t sent = 0;
	while (sent < n) {
		const auto now = Clock::now();
		if (now >= deadline) { return false; }
		const ssize_t k = ::send(fd, buf + sent, n - sent, MSG_NOSIGNAL | MSG_DONTWAIT);
		if (k > 0) {
			sent += static_cast<std::size_t>(k);
			continue;
		}
		if (k < 0 && errno == EAGAIN) {
			/* 缓冲满：睡一小拍再试（deadline 在循环顶收口）。 */
			const long remainMs = std::chrono::duration_cast<std::chrono::milliseconds>(
				deadline - Clock::now()).count();
			const long nap = remainMs < kMcpPollIntervalMs ? remainMs : kMcpPollIntervalMs;
			::usleep(static_cast<useconds_t>(nap > 0 ? nap : 0) * 1000);
			continue;
		}
		if (k < 0 && errno == EINTR) { continue; }
		return false;	/* 其余错误 / 对端关闭 */
	}
	return true;
}

} // namespace

/* ---- 纯协议件 ---- */

std::string mcpEncodeFrame(const std::string& payload) {
	std::string frame(kMcpHeaderSize + payload.size(), '\0');
	writeBe32(&frame[0], static_cast<std::uint32_t>(payload.size()));
	if (!payload.empty()) {
		std::memcpy(&frame[kMcpHeaderSize], payload.data(), payload.size());
	}
	return frame;
}

/* 错误串脱敏：把「以 / 开头的非空白串」（绝对路径形态）替换为 <redacted>，
 * 与 libmsg RpcServer 的 _sanitize_error 同意图（评估 §7.4 第 5 条）。完整异常
 * 另进后端日志/审计，返回客户端的只有脱敏串。 */
std::string sanitizeError(const std::string& in) {
	std::string out;
	out.reserve(in.size());
	std::size_t i = 0;
	while (i < in.size()) {
		if (in[i] == '/') {
			std::size_t j = i + 1;
			while (j < in.size()
				&& std::isspace(static_cast<unsigned char>(in[j])) == 0) { ++j; }
			out += "<redacted>";
			i = j;
		} else {
			out += in[i];
			++i;
		}
	}
	return out;
}

/* 读一帧。两段式：
 *   ① 空闲等首字节：长生命周期控制通道，两次工具调用之间可能长时间空闲，
 *      缺省不设 deadline——但 idleDeadline（--mcp-idle-timeout 与每连接墙钟
 *      预算的较早者，见 McpBackend::idleDeadline）给了值就到点断连（A-2，
 *      2026-09-25 审计：哑对端不能永远占住单连接串行模型下唯一的 accept 槽）；
 *      周期性 poll 以便响应停止信号；
 *   ② 一旦帧开始（首字节到达），帧头与载荷共享 recvTimeoutSec 的绝对 deadline，
 *      这正是 Slowloris 的修复点（评估 §7.1）。 */
FrameResult readFrame(int fd, std::string& payload, int recvTimeoutSec,
		Clock::time_point idleDeadline, std::ostream& log) {
	for (;;) {
		if (stopRequested()) { return FrameResult::PeerClosed; }
		if (Clock::now() >= idleDeadline) { return FrameResult::IdleTimeout; }
		/* 这段 poll 与 recvAllDeadline、mcplisten.cpp acceptLoop 同型而策略不同，
		 * 25.2 评估后判不抽公共 helper，理由见 recvAllDeadline 的头注。此处
		 * EINTR → continue 会回到循环顶重查 stopRequested()，正是 main.cpp 的 installStopSignalHandlers
		 * 不装 SA_RESTART 的用意，不要「顺手」包 util_file.hpp 的 retryEintr。 */
		struct pollfd p{};
		p.fd = fd;
		p.events = POLLIN;
		const int r = ::poll(&p, 1, kMcpPollIntervalMs);
		if (r < 0) {
			if (errno == EINTR) { continue; }
			return FrameResult::Violation;
		}
		if (r == 0) { continue; }	/* 空闲，继续等（deadline 在循环顶收口） */
		if ((p.revents & (POLLERR | POLLNVAL)) != 0) { return FrameResult::Violation; }
		break;	/* 可读（或 HUP/RDHUP → 下面 recv 得 0 → PeerClosed） */
	}

	const Clock::time_point deadline = Clock::now() + std::chrono::seconds(recvTimeoutSec);
	char hdr[kMcpHeaderSize] = {0};
	bool eof = false;
	if (!recvAllDeadline(fd, hdr, kMcpHeaderSize, deadline, eof)) {
		return eof ? FrameResult::PeerClosed : FrameResult::Violation;
	}
	const std::uint32_t len = readBe32(hdr);
	/* 上限在**分配载荷缓冲之前**检查（评估 §7.1）；u32 直接比较，无溢出暴露面。 */
	if (static_cast<std::size_t>(len) > kMcpMaxFrameBytes) {
		log << kMcpLogPrefix << "帧载荷 " << len << " 字节超过上限 " << kMcpMaxFrameBytes
			<< "，断开连接\n";
		return FrameResult::Violation;
	}
	payload.assign(static_cast<std::size_t>(len), '\0');
	if (len > 0
		&& !recvAllDeadline(fd, &payload[0], static_cast<std::size_t>(len), deadline, eof)) {
		return eof ? FrameResult::PeerClosed : FrameResult::Violation;
	}
	if (!isValidUtf8(payload)) {
		log << kMcpLogPrefix << "帧载荷不是合法 UTF-8，断开连接\n";
		return FrameResult::Violation;
	}
	return FrameResult::Ok;
}

bool sendFrame(int fd, const std::string& payload, int sendTimeoutSec) {
	const std::string frame = mcpEncodeFrame(payload);
	/* 帧头与载荷共享同一绝对 deadline（与读侧 recvAllDeadline 对称） */
	const Clock::time_point deadline = Clock::now() + std::chrono::seconds(sendTimeoutSec);
	return sendAllDeadline(fd, frame.data(), frame.size(), deadline);
}

/* ---- 25.6 评估后**判不抽鉴权叶子**（计划的可砍项：把本文件的 mcpCheckAuthFrame /
 * mcpCheckPeerCred 与 actionsource.cpp 的 checkTcpToken 收进一个 auth 叶子）。计划要求
 * 「先确认不与第三轮『安全判据单点化』的既有单点冲突」；实测结论要更正这句措辞——
 * 不是冲突，是**已被既有单点覆盖**，第四层叶子是冗余的：
 * ① 两条通道真正共享的判据只有两条，第三轮都已单点化：恒时比对 safeEquals
 *    （util_str.hpp；本函数与 actionsource.cpp 的 checkTcpToken 共用）与爆破计数
 *    AuthFailGate（util_cli.hpp；mcplisten.cpp 的 acceptLoop 与 actionsource.cpp
 *    的 acceptAuthenticatedClient 共用）。三个待析函数体内不再有一行相同逻辑：
 *    这里是 JSON 路由字段解析，checkTcpToken 是逐字节 recv 到 '\n' 的 errno
 *    三态，mcpCheckPeerCred 是 getsockopt(SO_PEERCRED) 的 uid/gid 比对（根本
 *    不是口令）。放进同一个文件只是按话题同居，删不掉任何重复行。
 * ② 可测性收益早已到手：三者都是公开声明 + socketpair 白盒单测
 *    （test_mcptransport.cpp / test_actionsource.cpp），mcptransport.hpp 里就
 *    写着「暴露为公开函数便于白盒单测」。析叶子买不到新的可测性。
 * ③ 两个三态枚举不同构，合并即改行为：McpAuthOutcome::NotAuthFrame 在
 *    serveConnection 里**计入** recordAuthRejected()/ConnAuth::Failed（对端发了
 *    合法帧、只是不是 auth 帧），而 TcpAuthStatus::NoCredential **不计**（对端
 *    没给凭据）。这条不对称正是 AuthFailGate 头注写的口径，不是待收敛的漂移。
 * ④ 耦合面本已收窄：mcptransport.hpp 只有 2 个 includer（本文件、
 *    mcpbackend.hpp），消费者 mcplisten.cpp 同时要传输件（readFrame/sendFrame/
 *    kMcpMaxFrameBytes）与鉴权件，另立一个鉴权叶子头后它两个都得 include。本文件
 *    头注的 charter「帧传输与纯协议件」下的四个子话题（传输 / 鉴权 / 路径探测 /
 *    回执脱敏）共享 errnoText、log 与帧常量，2026-10-01 那次拆分已把它做成叶子；
 *    把叶子再按子话题切三刀只增头文件与 CMakeLists 条目，不减依赖。
 * actionsource.cpp 侧同判（短指针在 checkTcpToken 的头注）。 */

/* ---- 首帧共享密钥校验（MCP-1，审计 P2-1）----
 * 恒时比对收敛到 util_str.hpp 的 safeEquals 单点（2026-10-01）：此处取
 * 严格版语义——长度差异折叠进累计差，全长走完才判，回应时间不泄露已
 * 匹配前缀的信息。TCP 口令侧（actionsource）同一单点。 */
McpAuthOutcome mcpCheckAuthFrame(const std::string& expected, const std::string& payload) {
	Json req;
	try {
		req = parseJson(payload);
	} catch (const std::exception&) {
		return McpAuthOutcome::Failed;
	}
	if (!req.isObj()) { return McpAuthOutcome::Failed; }
	const Json* route = req.find(mcp_protocol::kRoute);
	if (route == nullptr || !route->isStr()
			|| route->getValue() != mcp_protocol::kAuth) {
		return McpAuthOutcome::NotAuthFrame;
	}
	const Json* token = req.find(mcp_protocol::kToken);
	if (token == nullptr || !token->isStr()) { return McpAuthOutcome::Failed; }
	return safeEquals(expected, token->getValue())
		? McpAuthOutcome::Ok : McpAuthOutcome::Failed;
}

/* ---- 首帧认证回执（契约见 mcptransport.hpp 声明处）----
 * Json 对象按插入序序列化、无空白，产物与既有字面量逐字节相同（此前
 * mcplisten.cpp 手写的两条串，2026-10-10 收敛单点）。 */
std::string mcpAuthOkFrame() {
	Json d = JsonObject();
	d.put(mcp_protocol::kAuth, JsonBool(true));
	Json o = JsonObject();
	o.put(mcp_protocol::kSuccess, JsonBool(true));
	o.put(mcp_protocol::kData, std::move(d));
	return o.toString();
}

std::string mcpAuthRejectFrame() {
	/* 报错文案内嵌 auth 帧的形态示例（_route/token 是字段名展示，不是回执字段）：
	 * 经 escapeString 转义后与原字面量逐字节一致。 */
	const std::string hint = std::string("auth required: first frame must be {\"")
		+ mcp_protocol::kRoute + "\":\"" + mcp_protocol::kAuth + "\",\""
		+ mcp_protocol::kToken + "\":...}";
	Json o = JsonObject();
	o.put(mcp_protocol::kSuccess, JsonBool(false));
	o.put(mcp_protocol::kError, JsonString(hint));
	return o.toString();
}

bool mcpCheckPeerCred(int fd, std::ostream& log) {
	struct ucred cred{};
	socklen_t len = sizeof(cred);
	if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
		log << kMcpLogPrefix << "SO_PEERCRED 读取失败（" << errnoText(errno)
			<< "），拒绝连接\n";
		return false;
	}
	const uid_t uid = ::getuid();
	const gid_t gid = ::getgid();
	if (cred.uid != uid || cred.gid != gid) {
		log << kMcpLogPrefix << "对端 uid/gid(" << cred.uid << "/" << cred.gid
			<< ") 与本进程(" << uid << "/" << gid << ") 不符，拒绝连接\n";
		return false;
	}
	return true;
}

McpSocketProbe mcpProbeSocketPath(const std::string& path, std::string& why) {
	struct stat st{};
	if (::lstat(path.c_str(), &st) != 0) {
		if (errno == ENOENT) { return McpSocketProbe::PathFree; }	/* 路径还没人用 */
		why = std::string("lstat 失败: ") + errnoText(errno);
		return McpSocketProbe::PathUnusable;
	}
	if (!S_ISSOCK(st.st_mode)) {
		why = "路径已存在但不是 socket 文件（可能是普通文件/目录——不替操作者删除）";
		return McpSocketProbe::PathUnusable;
	}

	/* 存在 socket 文件：connect 一次区分「活监听」与「陈旧残留」。
	 * 非阻塞 + 短 poll：AF_UNIX 的 connect 通常立刻完成，但活实例的积压满
	 * （listen(1) 且槽位被哑连接占着）时阻塞 connect 会无限等——探测自己
	 * 不能被它挂死。 */
	FdGuard probe(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0));
	if (probe.get() < 0) {
		why = std::string("探测 socket 创建失败: ") + errnoText(errno);
		return McpSocketProbe::PathUnusable;
	}
	sockaddr_un addr{};
	addr.sun_family = AF_UNIX;
	std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());
	const int c = ::connect(probe.get(), reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
	if (c == 0) {
		why = "已有另一个实例在监听（connect 直接成功）";
		return McpSocketProbe::PathBusy;
	}
	if (errno == ECONNREFUSED) {
		return McpSocketProbe::PathFree;	/* 陈旧残留：上次实例没清理，可安全覆盖 */
	}
	if (errno == ENOENT) {
		/* lstat 与 connect 之间被人清掉：与不存在同等对待 */
		return McpSocketProbe::PathFree;
	}
	if (errno == EINPROGRESS || errno == EAGAIN) {
		/* EAGAIN（Linux 对积压满的 uds 非阻塞 connect）= 活实例但暂时接不进；
		 * EINPROGRESS 走 poll 短等确认。两者都**按忙处理**：宁可拒绝启动，
		 * 不抢一个可能在用的路径（fail-closed）。 */
		if (errno == EAGAIN) {
			why = "已有实例在监听（对端积压满，connect 返回 EAGAIN）";
			return McpSocketProbe::PathBusy;
		}
		struct pollfd p{};
		p.fd = probe.get();
		p.events = POLLOUT;
		int r = ::poll(&p, 1, kProbeWaitMs);
		if (r < 0 && errno == EINTR) { r = 0; }
		if (r == 0) {
			why = "探测超时（路径上有 socket 但既不接也不拒——按活实例处理）";
			return McpSocketProbe::PathBusy;
		}
		int soErr = 0;
		socklen_t sl = sizeof(soErr);
		if (r > 0 && ::getsockopt(probe.get(), SOL_SOCKET, SO_ERROR, &soErr, &sl) == 0) {
			if (soErr == 0) {
				why = "已有另一个实例在监听（connect 完成）";
				return McpSocketProbe::PathBusy;
			}
			if (soErr == ECONNREFUSED) { return McpSocketProbe::PathFree; }
			why = std::string("connect 异步失败: ") + errnoText(soErr);
			return McpSocketProbe::PathUnusable;
		}
		why = std::string("connect 结果无法判定: ") + errnoText(errno);
		return McpSocketProbe::PathUnusable;
	}
	why = std::string("connect 失败: ") + errnoText(errno);
	return McpSocketProbe::PathUnusable;
}

} // namespace agent
} // namespace bot

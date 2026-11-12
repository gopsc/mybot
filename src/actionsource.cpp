#include "actionsource.hpp"
#include "util_cli.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_file.hpp"
#include "util_num.hpp"
#include "util_str.hpp"	/* getEnvVar / errnoText */

#include <arpa/inet.h>
#include <poll.h>
#include <cerrno>
#include <cstddef>
#include <fcntl.h>
#include <iostream>
#include <netinet/in.h>
#include <streambuf>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace bot {

/* ---- 动作脚本字节上限（kMaxScriptBytes）----
 * 上限常量与理由见 scriptlimit.hpp（动作/结构脚本共用；RSS 实测见该处注释）。 */

/* ---- TCP 空闲超时缺省值（秒）：连上后不再发字节的对端不能永久挂住进程 ---- */
static constexpr int kTcpIdleSecDefault = 30;

/* ---- TCP 口令连续失败上限（C-M1）：口令失败不再直接终止进程——任意对端
 * 先 connect 一次即可让一次运行崩溃退出（单次性 DoS + 硬件走一遍
 * deactivate）。改为关连接回 accept 等待，连败到上限才放弃（防无限爆破）。
 * 2026-09-22 F-1：缺省值挪到 util::tcp_limits::kAuthMaxFailsDefault 单点，
 * 可经 --tcp-max-auth-attempts 覆盖；本处旧常量名保留作缺省值别名，
 * acceptAuthenticatedClient 改吃调用方传入的生效值。 */

/* ---- 连接总时长预算（C-M2，秒）：SO_RCVTIMEO 只约束单次 recv，慢滴对端
 * 每 <idle 秒发 1 字节即可击穿空闲超时、把进程挂到天级。从连接建立起算
 * wall-clock 上限：真实脚本 KB 级、秒级传完；缺省 600s 已覆盖极慢链路，随
 * --tcp-idle 放大（用户显式调长超时视为有意容忍慢链路），下限可经
 * --tcp-total-timeout 调整（2026-09-22 F-3；生效值取该下限与 idle×20 的
 * 较大者——「总预算」语义不变，只是下限从写死 600 变为可配）。 */
static int tcpTotalBudgetSec(int idleSec, int totalTimeoutFloorSec) {
	int budget = idleSec * 20;
	if (budget < totalTimeoutFloorSec) { budget = totalTimeoutFloorSec; }
	return budget;
}


/* ---- TcpStreamReader::read：区分 EOF / 超时 / 信号 / 链路错误 ----
 * 内部 64KiB 缓冲（审计 M2）：缓冲区空时一次 recv 尽量填满，之后逐字节
 * 从缓冲出队；8MiB 上限的脚本从 ~800 万次系统调用降到 ~130 次。
 * 错误/超时/信号语义与旧逐字节版完全一致。 */
int TcpStreamReader::read() {
	if (fd_ < 0) { return -1; }
	if (pos_ < buf_.size()) { return static_cast<unsigned char>(buf_[pos_++]); }
	/* C-M2：总时长预算超限——慢滴对端每次 recv 都在 idle 窗口内到达，
	 * 空闲超时永不触发；wall-clock 上限是唯一的硬性防线 */
	if (std::chrono::steady_clock::now() > deadline_) {
		if (!overBudget_) {
			overBudget_ = true;
			std::cerr << "TCP 动作源超出连接总时长预算，按输入结束处理"
				<< "（脚本可能被截断；慢滴发送不能无限期挂住进程）" << std::endl;
		}
		return -1;
	}
	buf_.resize(kBufCap);
	while (true) {
		ssize_t n = ::recv(fd_, buf_.data(), buf_.size(), 0);
		if (n > 0) { pos_ = 0; buf_.resize(static_cast<std::size_t>(n)); return static_cast<unsigned char>(buf_[pos_++]); }
		if (n == 0) { buf_.clear(); return -1; }	/* 对端正常关闭写端 → EOF */
		buf_.clear();
		if (errno == EINTR) {
			/* 信号打断：停止标志置位则按 EOF 收尾，让 deactivate 正常走完 */
			if (stopRequested()) { return -1; }
			continue;
		}
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			if (!timedOut_) {
				timedOut_ = true;
				std::cerr << "TCP 动作源空闲超过 " << idleSec_
					<< "s，按输入结束处理（对端已连接但未继续发送）" << std::endl;
			}
			return -1;
		}
		std::cerr << "TCP 动作源读错误：" << errnoText(errno)
			<< "，按输入结束处理（脚本可能被截断）" << std::endl;
		return -1;
	}
}

/* 25.6 评估后判不把本函数与 MCP 侧的 mcpCheckAuthFrame / mcpCheckPeerCred 收进
 * 同一个 auth 叶子：两条通道真正共享的判据——恒时比对 safeEquals、爆破计数
 * AuthFailGate——第三轮已各自单点化，三个函数体内不再有一行可收敛的重复逻辑；
 * 三态枚举也与 MCP 侧不同构（NoCredential **不**计数 / NotAuthFrame 计数），
 * 合并即改行为。四条实测理由见 mcptransport.cpp 里 mcpCheckAuthFrame 的头注。 */
/* ---- 可选口令校验：对端必须先送一行 "<token>\n" 才允许下发动作脚本 ----
 * 口令为空时跳过（不破坏既有单连接直发脚本的用法）。
 * 比较走 util_str.hpp 的 safeEquals 恒时实现（审计 M1）。
 * 三态契约见 actionsource.hpp（阶段 4.3：NoCredential 不得计为鉴权失败）。 */
TcpAuthStatus checkTcpToken(int client, const std::string& token) {
	std::string line;
	char c;
	while (line.size() <= token.size() + 1) {
		ssize_t n = ::recv(client, &c, 1, 0);
		if (n < 0) {
			/* 阶段 4.3 修复：只有「收到凭据但不匹配/超长」才算鉴权失败。
			 * 空闲超时（SO_RCVTIMEO→EAGAIN）、被信号打断（EINTR）与其它读错误
			 * 都属「对端没给凭据」——旧实现把它们一并计为口令失败，于是任意
			 * 未认证对端连上 5 次、每次不发字节即可终止进程，且诊断误报为爆破。 */
			if (errno == EINTR) {
				std::cerr << "TCP 口令校验：等待凭据行被信号打断，关闭该连接" << std::endl;
			} else if (errno == EAGAIN || errno == EWOULDBLOCK) {
				std::cerr << "TCP 口令校验：对端在空闲超时内未提供凭据行，关闭该连接" << std::endl;
			} else {
				std::cerr << "TCP 口令校验：接收凭据行失败（" << errnoText(errno)
					<< "），关闭该连接" << std::endl;
			}
			return TcpAuthStatus::NoCredential;
		}
		if (n == 0) {
			std::cerr << "TCP 口令校验：对端在提供凭据行前关闭了连接" << std::endl;
			return TcpAuthStatus::NoCredential;
		}
		if (c == '\n') { break; }
		line += c;
	}
	if (line.size() > token.size() + 1) {
		/* 审计 #6：凭据行超长，显式 fail-closed 拒绝。复核结论：line 是
		 * std::string 累积、safeEquals 带长度比较，超长行本就因长度不等
		 * 被拒，不存在截断放行；此处提前拦截只为给出明确诊断（而非笼统
		 * 的「凭据不匹配」），并让 +1 的循环上限语义自解释。 */
		std::cerr << "TCP 口令校验失败：凭据行超长（fail-closed，不截断比较）" << std::endl;
		return TcpAuthStatus::Rejected;
	}
	if (!safeEquals(line, token)) {
		std::cerr << "TCP 口令校验失败：凭据不匹配，拒绝接收动作脚本" << std::endl;
		return TcpAuthStatus::Rejected;
	}
	std::cerr << "TCP 口令校验通过" << std::endl;
	return TcpAuthStatus::Ok;
}

/* ---- TCP 动作源（阶段 3 拆分）：校验地址 → 监听 → 鉴权 accept → 读脚本 ---- */

/* --tcp-host 校验：点分十进制 IPv4 */
static bool parseIpv4Host(const std::string& host, in_addr& addr) {
	if (::inet_pton(AF_INET, host.c_str(), &addr) != 1) {
		std::cerr << "--tcp-host 地址无效：" << host << "（需点分十进制 IPv4）" << std::endl;
		return false;
	}
	return true;
}

/* 监听套接字：socket + REUSEADDR + H-2 非回环强制口令 + bind + listen */
static FdGuard setupListenSocket(long long port, const std::string& host,
		const in_addr& addr, const std::string& token) {
	/* 监听 fd 交给守卫：此后所有出口（throw / return）都自动关闭，不再
	 * 依赖逐条手工 ::close。 */
	FdGuard listenFd(::socket(AF_INET, SOCK_STREAM, 0));
	if (listenFd.get() < 0) {
		throw std::runtime_error("无法创建 TCP 套接字");
	}
	int one = 1;
	::setsockopt(listenFd.get(), SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	/* 审计 H-2 防线：非回环监听必须设口令（缺省即拒绝 bind，不再仅告警）。
	 * 动作脚本会直接驱动真实硬件，未鉴权暴露到网络等价于把舵机交给任何
	 * 可达本端口的对端。回环 127.0.0.1 不受限。 */
	if (addr.s_addr != htonl(INADDR_LOOPBACK) && token.empty()) {
		throw std::runtime_error("监听地址 " + host + " 非回环且未设 --tcp-token："
			"动作脚本会直接驱动真实硬件，跨机监听必须显式提供口令"
			"（仅本机调试请用缺省回环地址 127.0.0.1）");
	}

	sockaddr_in sa{};
	sa.sin_family = AF_INET;
	sa.sin_addr = addr;
	sa.sin_port = htons(static_cast<uint16_t>(port));

	if (::bind(listenFd.get(), reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) < 0) {
		throw std::runtime_error("TCP 监听端口绑定失败");
	}
	/* D5：listen 返回值检查 */
	if (::listen(listenFd.get(), 1) < 0) {
		throw std::runtime_error("TCP 监听失败");
	}
	return listenFd;
}

/* accept 循环：EINTR/停止信号响应（D5/D4）+ 对端日志 + 空闲超时（审计 #9）
 * + 口令失败预算（C-M1：关连接回 accept，连续失败才放弃）。
 * authMaxFails：连续失败上限的生效值（2026-09-22 F-1，缺省
 * tcp_limits::kAuthMaxFailsDefault，可经 --tcp-max-auth-attempts 覆盖）。
 * 记账走 AuthFailGate（util_cli.hpp 单点，与 MCP 首帧认证同一判据结构）。 */
static FdGuard acceptAuthenticatedClient(int listenFd, const std::string& token, int idleSec,
		int authMaxFails) {
	FdGuard clientFd;		/* 每轮重置；本轮失败时由 close() 关闭 */
	AuthFailGate gate(authMaxFails);
	while (true) {
		int client = ::accept(listenFd, nullptr, nullptr);
		if (client < 0) {
			if (errno == EINTR) {
				if (stopRequested()) {
					throw std::runtime_error("TCP 等待客户端连接被停止信号中断");
				}
				continue;
			}
			throw std::runtime_error("TCP 接受客户端失败");
		}
		clientFd.reset(client);

		sockaddr_in peer{};
		socklen_t plen = sizeof(peer);
		char ip[INET_ADDRSTRLEN] = "?";
		if (::getpeername(clientFd.get(), reinterpret_cast<sockaddr*>(&peer), &plen) == 0) {
			::inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
		}
		std::cerr << "TCP 客户端已连接：" << ip << ":" << ntohs(peer.sin_port) << std::endl;

		/* 空闲超时同时覆盖口令校验与脚本读取两段，避免「连上不发」挂死进程。
		 * 审计 #9：设置失败必须显式失败——该选项正是空闲 DoS 的防线，静默
		 * 失效等于防线整体消失。 */
		timeval tv{};
		tv.tv_sec = idleSec;
		if (::setsockopt(clientFd.get(), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
			throw std::runtime_error(std::string("设置 TCP 接收空闲超时失败：")
				+ errnoText(errno));
		}

		if (!token.empty()) {
			TcpAuthStatus st = checkTcpToken(clientFd.get(), token);
			if (st != TcpAuthStatus::Ok) {
				clientFd.close();	/* 关连接，回 accept 等待下一个 */
				/* 阶段 4.3：只有「凭据错」才计入爆破上限；「没给凭据」
				 * （空闲超时/关闭/中断）不计数，否则未认证对端可用
				 * 5 次空连接终止进程。 */
				if (st == TcpAuthStatus::NoCredential) {
					std::cerr << "关闭该连接，继续等待下一个客户端（未提供凭据，不计入爆破计数）"
						<< std::endl;
					continue;
				}
				if (gate.recordRejected()) {
					throw std::runtime_error("TCP 口令连续 " + std::to_string(gate.fails)
						+ " 次校验失败，停止等待（可能为扫描/爆破）");
				}
				std::cerr << "关闭该连接，继续等待下一个客户端（剩余尝试 "
					<< (gate.max - gate.fails) << " 次）" << std::endl;
				continue;
			}
		}
		break;
	}
	return clientFd;
}

/* ---- TCP 动作源：监听 → 接受一个客户端连接 → 可选口令 → 逐字节读脚本 ----
 * authMaxFails/totalTimeoutFloorSec：F-1/F-3 生效值（缺省见 tcp_limits）。 */
static std::unique_ptr<Reader> openTcpActionSource(long long port, const std::string& host,
		const std::string& token, int idleSec, int authMaxFails, int totalTimeoutFloorSec) {
	in_addr addr{};
	if (!parseIpv4Host(host, addr)) { return nullptr; }

	std::cerr << "TCP 动作源：监听 " << host << ":" << port << "，等待客户端连接..." << std::endl;

	FdGuard listenFd = setupListenSocket(port, host, addr, token);
	FdGuard clientFd = acceptAuthenticatedClient(listenFd.get(), token, idleSec, authMaxFails);

	/* C-M2：总时长预算从连接建立起算（含口令校验段；口令行长度有上限且
	 * 每次 recv 受 idle 超时约束，主防线覆盖无界的脚本读取段） */
	const auto deadline = std::chrono::steady_clock::now()
		+ std::chrono::seconds(tcpTotalBudgetSec(idleSec, totalTimeoutFloorSec));

	/* 先以 get() 构造（此刻仍由守卫持有），构造成功后才交还所有权：
	 * 若构造或分配抛异常，守卫负责关闭客户端 fd，不再泄漏（原实现此处
	 * 把裸 client 交给 make_unique，分配失败即泄漏）。 */
	auto reader = std::make_unique<TcpStreamReader>(clientFd.get(), idleSec, deadline);
	clientFd.release();
	return reader;
}

/* ---- openActionSource 的通道拆分（2026-09-29 A3）：TCP 与文件各成函数，
 * 校验失败打印并返回 nullptr；stdin 分支三行留在原地。 ---- */

/* TCP 通道：五个选项的校验（端口/监听地址/空闲超时/口令/失败上限/总时长
 * 预算）与 openTcpActionSource 的装配。各校验的报错文案逐字保持。 */
static std::unique_ptr<Reader> openTcpSource(const CliOptions& options) {
	/* 审计中-3：裸 --tcp（漏写端口号）在此明确报错，而非静默按端口 1
	 * 走到 bind 特权端口失败、给出与用户意图相去甚远的错误 */
	if (options.tcp.tcpPort.empty()) {
		std::cerr << "--tcp 需要端口号，例如 --tcp 9000（合法范围 1-65535）" << std::endl;
		return nullptr;
	}
	const auto port = parseBoundedLong(options.tcp.tcpPort, 1, 65535);
	if (!port) {
		std::cerr << "--tcp 端口号无效：" << options.tcp.tcpPort
			<< "（合法范围 1-65535）" << std::endl;
		return nullptr;
	}
	std::string host = options.tcp.tcpHost;
	if (host.empty()) { host = "127.0.0.1"; }	/* 缺省只监听回环，对外暴露需显式指定 */

	int idleSec = kTcpIdleSecDefault;
	const std::string& idleStr = options.tcp.tcpIdle;
	if (!idleStr.empty()) {
		const auto idle = parseBoundedLong(idleStr, 1, 86400);
		if (!idle) {
			std::cerr << "--tcp-idle 无效：" << idleStr << "（合法范围 1-86400 秒）" << std::endl;
			return nullptr;
		}
		idleSec = static_cast<int>(*idle);
	}

	/* C-L4：口令可经环境变量传递——--tcp-token 出现在 /proc/<pid>/cmdline，
	 * 多用户机器上凭据对同机其他用户可见；环境变量只在进程环境里。 */
	std::string token = options.tcp.tcpToken;
	if (token.empty()) {
		if (auto envToken = getEnvVar("BOT4CJ_TCP_TOKEN")) { token = *envToken; }
	}

	/* F-1：口令连续失败上限（缺省 tcp_limits::kAuthMaxFailsDefault=5） */
	int authMaxFails = tcp_limits::kAuthMaxFailsDefault;
	const std::string& authStr = options.tcp.tcpMaxAuthAttempts;
	if (!authStr.empty()) {
		const auto auth = parseBoundedLong(authStr,
			tcp_limits::kAuthMaxFailsMin, tcp_limits::kAuthMaxFailsMax);
		if (!auth) {
			std::cerr << rangeErrorText("--tcp-max-auth-attempts",
				tcp_limits::kAuthMaxFailsMin, tcp_limits::kAuthMaxFailsMax, authStr)
				<< std::endl;
			return nullptr;
		}
		authMaxFails = static_cast<int>(*auth);
	}

	/* F-3：连接总时长预算下限（缺省 tcp_limits::kTotalTimeoutDefault=600） */
	int totalTimeoutFloorSec = tcp_limits::kTotalTimeoutDefault;
	const std::string& totalStr = options.tcp.tcpTotalTimeout;
	if (!totalStr.empty()) {
		const auto total = parseBoundedLong(totalStr,
			tcp_limits::kTotalTimeoutMin, tcp_limits::kTotalTimeoutMax);
		if (!total) {
			std::cerr << rangeErrorText("--tcp-total-timeout",
				tcp_limits::kTotalTimeoutMin, tcp_limits::kTotalTimeoutMax, totalStr)
				<< std::endl;
			return nullptr;
		}
		totalTimeoutFloorSec = static_cast<int>(*total);
	}

	return openTcpActionSource(*port, host, token, idleSec,
		authMaxFails, totalTimeoutFloorSec);
}

/* 文件通道：--input 指定的 .mt 文件，打不开打印并返回 nullptr。 */
static std::unique_ptr<Reader> openFileSource(const CliOptions& options) {
	const std::string& path = *options.input;
	auto f = std::make_unique<FileReader>(path);
	if (!f->good()) {
		std::cerr << "无法打开动作脚本文件 '" << path << "'" << std::endl;
		return nullptr;
	}
	std::cerr << "从文件读取动作脚本：" << path << std::endl;
	return f;
}

/* ---- 打开动作输入源：tcp 优先 > 文件 > 标准输入 ---- */
std::unique_ptr<Reader> openActionSource(const CliOptions& options) {
	std::unique_ptr<Reader> raw;

	/* 1) TCP 通道（校验与装配在 openTcpSource） */
	if (options.tcp.enabled) {
		raw = openTcpSource(options);
	}
	/* 2) 文件通道（openFileSource） */
	else if (options.input) {
		raw = openFileSource(options);
	}
	/* 3) 标准输入（管道 cat scripts/xxx.mt | ./build/mybot）
	 * 分块读 + 超限即抛（readAllLimited 单点，与 mtmerge 文件输入共用）：
	 * 整体 istreambuf_iterator 读法会在限流之前就把全部输入吃进内存，
	 * 上限形同虚设。超限从「打印后放弃」改为抛 ScriptTooLarge——与文件
	 * 通道（LimitedReader 同一异常）统一为同一用户可见契约。 */
	else {
		raw = std::make_unique<MemoryReader>(readAllLimited(std::cin, kMaxScriptBytes));
	}

	if (!raw) { return nullptr; }
	return std::make_unique<LimitedReader>(std::move(raw), kMaxScriptBytes);
}

} // namespace bot

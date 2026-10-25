/* test_mcplisten.cpp —— MCP 后端 socket 服务域（mcplisten.cpp）单测
 *
 * 2026-10-10 首个直接单测：mcplisten.cpp 此前是唯一没有同名测试的 src TU——
 * serveConnection/acceptLoop 是匿名命名空间静态件，白盒触不到（test_mcptransport
 * 的 AuthFailGate 用例头注记录过该缺口，当时只测了判据结构）。本批把连接服务与
 * 三个判据件析出到 mcplisten.hpp（可测接缝，见其头注），此处锚定：
 *   - serveConnection 全链路（socketpair + 对端线程，与 Rust 侧 agent/src/
 *     frame.rs 的 authenticate 测试同款形态）：无 token 业务循环、首帧认证
 *     通过/不通过/非 auth 帧、认证期协议违规与空闲超时；
 *   - preflightSocketPath / disconnectActionGate / prepareSocketParentDir 判据件。
 * acceptLoop / runMcpBackend 仍是 TU 内编排（依赖真实 robot 装配与 accept 循环），
 * 由 scripts/mcp_e2e.sh 端到端覆盖。
 *
 * 用例名前缀沿用 MCP 后端全族的 mcpbackend_（test_mcptransport.cpp 同款：
 * 前缀按用户可见的功能面进 harness.hpp 的 agent 作用域表，不按 src 文件名）。 */

#include "fixtures.hpp"
#include "harness.hpp"

#include <chrono>
#include <filesystem>
#include <functional>
#include <sstream>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "mcplisten.hpp"
#include "mcptransport.hpp"
#include "util_file.hpp"	/* FdGuard */
#include "mcp_fixtures.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;
using mfx::makeBackend;

namespace {

/* 对端发一帧：复用生产帧件（编码口径不二写），5s 发送 deadline 足测试用 */
void peerSend(int fd, const std::string& payload) {
	(void)sendFrame(fd, payload, 5);
}

/* 对端收一帧：Ok 才返回 true（payload 出参给主线程断言内容） */
bool peerRecv(int fd, std::string& payload) {
	std::ostringstream sink;
	return readFrame(fd, payload, 5,
		std::chrono::steady_clock::now() + std::chrono::seconds(5), sink)
		== FrameResult::Ok;
}

/* socketpair 一端跑 serveConnection，另一端交 peerScript 驱动。join 先于
 * FdGuard 析构（对端 fd 在线程结束后才关，线程内收发不悬垂）；对端写进的
 * 捕获串在 join 之后才读——无数据竞争，TSan 面干净。 */
ConnOutcome runServeSession(McpBackend& backend, const McpBackendOptions& opts,
		const std::function<void(int)>& peerScript, std::ostringstream& log) {
	int sv[2] = {-1, -1};
	TH_CHECK(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0);
	if (sv[0] < 0) { return ConnOutcome{}; }
	FdGuard serverFd(sv[0]);
	FdGuard peerFd(sv[1]);
	std::thread peer([&peerScript, fd = peerFd.get()] { peerScript(fd); });
	const ConnOutcome oc = serveConnection(serverFd.get(), backend, opts, log);
	peer.join();
	return oc;
}

} // namespace

/* ---------------- serveConnection：无 token 模式 ---------------- */

TH_TEST(mcpbackend_serve_no_token_admits_and_answers) {
	/* authToken 空 = 仅 SO_PEERCRED 的旧模式：直接进业务循环（admitted 恒真），
	 * ping 有问必答，对端关闭即 PeerClosed 收场。 */
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	std::ostringstream log;
	std::string reply;
	const ConnOutcome oc = runServeSession(backend, opts, [&](int fd) {
		peerSend(fd, R"({"_route":"ping"})");
		if (!peerRecv(fd, reply)) { return; }
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Neutral);
	TH_CHECK(oc.admitted);
	TH_CHECK(reply.find("pong") != std::string::npos);
}

/* ---------------- serveConnection：首帧认证三态 ---------------- */

TH_TEST(mcpbackend_serve_token_ok_admits_then_business) {
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	opts.authToken = "s3cret";
	std::ostringstream log;
	std::string authReply, bizReply;
	const ConnOutcome oc = runServeSession(backend, opts, [&](int fd) {
		peerSend(fd, R"({"_route":"auth","token":"s3cret"})");
		if (!peerRecv(fd, authReply)) { return; }
		peerSend(fd, R"({"_route":"ping"})");
		if (!peerRecv(fd, bizReply)) { return; }
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Passed);
	TH_CHECK(oc.admitted);
	TH_CHECK(authReply == mcpAuthOkFrame());	/* lock-step 回帧，字节锚定 */
	TH_CHECK(bizReply.find("pong") != std::string::npos);
	TH_CHECK(log.str().find("首帧认证通过") != std::string::npos);
}

TH_TEST(mcpbackend_serve_token_mismatch_rejects) {
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	opts.authToken = "s3cret";
	std::ostringstream log;
	std::string reply;
	const ConnOutcome oc = runServeSession(backend, opts, [&](int fd) {
		peerSend(fd, R"({"_route":"auth","token":"wrong"})");
		if (!peerRecv(fd, reply)) { return; }
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Failed);	/* AuthFailGate 记账口径：给过首帧但不通过 */
	TH_CHECK(!oc.admitted);			/* 未进业务循环 → 不拥有断连动作通道 */
	TH_CHECK(reply == mcpAuthRejectFrame());
	TH_CHECK(log.str().find("首帧认证失败") != std::string::npos);
	TH_CHECK(log.str().find("共享密钥不匹配") != std::string::npos);
}

TH_TEST(mcpbackend_serve_non_auth_first_frame_is_failed_not_neutral) {
	/* 旧客户端直发业务帧：与哑对端（Neutral）必须分开——试探者不能靠改发
	 * 业务帧绕开爆破计数（AuthFailGate 口径）。 */
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	opts.authToken = "s3cret";
	std::ostringstream log;
	const ConnOutcome oc = runServeSession(backend, opts, [](int fd) {
		peerSend(fd, R"({"_route":"tool.list"})");
		std::string reply;
		(void)peerRecv(fd, reply);
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Failed);
	TH_CHECK(!oc.admitted);
	TH_CHECK(log.str().find("第一帧不是 auth 帧") != std::string::npos);
}

/* ---------------- serveConnection：认证期的 Neutral 两路 ---------------- */

TH_TEST(mcpbackend_serve_violation_during_auth_is_neutral) {
	/* 认证帧载荷带非法 UTF-8：协议违规断连，从未走到认证判定 → Neutral，
	 * 爆破计数不动（「连了就断」刷不掉别人的失败窗口）。 */
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	opts.authToken = "s3cret";
	std::ostringstream log;
	const ConnOutcome oc = runServeSession(backend, opts, [](int fd) {
		peerSend(fd, std::string("{\"x\":\"\xFF\"}"));
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Neutral);
	TH_CHECK(!oc.admitted);
	TH_CHECK(log.str().find("认证帧违规") != std::string::npos);
}

TH_TEST(mcpbackend_serve_auth_frame_idle_timeout_is_neutral) {
	/* 认证帧迟迟不来（idleTimeoutSec=1）：哑对端让位，Neutral——计数不动。 */
	McpBackend backend = makeBackend(AgentToolRegistry{});
	McpBackendOptions opts;
	opts.authToken = "s3cret";
	opts.idleTimeoutSec = 1;
	std::ostringstream log;
	const ConnOutcome oc = runServeSession(backend, opts, [](int fd) {
		std::this_thread::sleep_for(std::chrono::milliseconds(1500));
		::shutdown(fd, SHUT_RDWR);
	}, log);
	TH_CHECK(oc.auth == ConnAuth::Neutral);
	TH_CHECK(!oc.admitted);
	TH_CHECK(log.str().find("认证帧未到") != std::string::npos);
}

/* ---------------- 判据件 ---------------- */

TH_TEST(mcpbackend_socket_path_preflight) {
	std::ostringstream log;
	TH_CHECK(preflightSocketPath("", log) == std::optional<int>(2));
	TH_CHECK(log.str().find("--mcp-socket") != std::string::npos);
	log.str("");
	/* sun_path 上限是内核 ABI（Linux 108 字节，含结尾 NUL 位）：恰 108 字节即拒，
	 * 边界由 preflight 自报（len >= sizeof(sun_path)） */
	const std::string tooLong(sizeof(sockaddr_un::sun_path), 'a');
	TH_CHECK(tooLong.size() == 108);
	TH_CHECK(preflightSocketPath(tooLong, log) == std::optional<int>(2));
	TH_CHECK(log.str().find("路径过长") != std::string::npos);
	log.str("");
	/* 边界内侧一格 + 常规路径：放行 */
	const std::string maxOk(sizeof(sockaddr_un::sun_path) - 1, 'a');
	TH_CHECK(!preflightSocketPath(maxOk, log).has_value());
	TH_CHECK(!preflightSocketPath("/tmp/mybot-mcp.sock", log).has_value());
}

TH_TEST(mcpbackend_disconnect_action_gate) {
	/* 审计 P2 的门：探连/认证失败从未被服务，不该拥有触发硬件动作的通道；
	 * 未配置脚本时无三态之分。 */
	TH_CHECK(disconnectActionGate(true, "safe.mt") == DisconnectAction::Run);
	TH_CHECK(disconnectActionGate(false, "safe.mt") == DisconnectAction::SkipNotAdmitted);
	TH_CHECK(disconnectActionGate(true, "") == DisconnectAction::NotConfigured);
	TH_CHECK(disconnectActionGate(false, "") == DisconnectAction::NotConfigured);
}

TH_TEST(mcpbackend_prepare_socket_parent_dir) {
	fx::TempDir root("mcplisten");
	/* 缺失 → 以 0700 建（单级） */
	std::ostringstream log;
	const std::string sock = (root.path() / "sub" / "s.sock").string();
	TH_CHECK(prepareSocketParentDir(sock, log));
	struct stat st{};
	TH_CHECK(::stat((root.path() / "sub").c_str(), &st) == 0);
	TH_CHECK((st.st_mode & 0777) == 0700);
	/* 已存在且 0700 → 安静通过 */
	log.str("");
	TH_CHECK(prepareSocketParentDir(sock, log));
	TH_CHECK(log.str().find("警告") == std::string::npos);
	/* 已存在但 0755 → 告警不阻断（替操作者收紧不如把建议写进日志） */
	TH_CHECK(::chmod((root.path() / "sub").c_str(), 0755) == 0);
	log.str("");
	TH_CHECK(prepareSocketParentDir(sock, log));
	TH_CHECK(log.str().find("权限过松") != std::string::npos);
}

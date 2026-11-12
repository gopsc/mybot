/* test_webshell.cpp —— Web SSH 服务泵单测（#24 MVP）
 * 用 socketpair 造伪客户端，走完整「握手 → 101 → 双向桥」。
 * 客户端帧按 RFC 6455 掩码（服务端强制要求）。 */
#include "harness.hpp"

#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include "webshell.hpp"
#include "wsproto.hpp"

namespace {

/* 构造一条掩码 text 客户端帧 */
std::string maskedText(const std::string& payload) {
	static const uint8_t mk[4] = {0x11, 0x22, 0x33, 0x44};
	std::string f;
	f += (char)0x81;
	if (payload.size() < 126) {
		f += (char)(0x80 | payload.size());
	} else {
		f += (char)(0x80 | 126);
		f += (char)(payload.size() >> 8);
		f += (char)(payload.size() & 0xFF);
	}
	f.append((const char*)mk, 4);
	for (size_t i = 0; i < payload.size(); ++i) f += (char)(payload[i] ^ mk[i & 3]);
	return f;
}

/* 收完一帧（FIN=1），返回帧头后的载荷（自动解析长度；不做分片）。
 * 用 poll 实现超时：对端无输出时返回空串而非永久阻塞（测试可诊断）。 */
std::string recvFrame(int fd, int* opcodeOut = nullptr, int timeoutMs = 3000) {
	auto waitReadable = [&](int ms) -> bool {
		struct pollfd p = {fd, POLLIN, 0};
		int pr = poll(&p, 1, ms);
		return pr > 0 && (p.revents & POLLIN);
	};
	uint8_t hdr[2];
	int got = 0;
	while (got < 2) {
		if (!waitReadable(timeoutMs)) return "";
		ssize_t n = recv(fd, hdr + got, 2 - got, 0);
		if (n <= 0) return "";
		got += (int)n;
	}
	if (opcodeOut) *opcodeOut = hdr[0] & 0x0F;
	size_t len = hdr[1] & 0x7F;
	if (len == 126) {
		if (!waitReadable(timeoutMs)) return "";
		uint8_t e[2];
		if (recv(fd, e, 2, 0) != 2) return "";
		len = ((size_t)e[0] << 8) | e[1];
	} else if (len == 127) {
		if (!waitReadable(timeoutMs)) return "";
		uint8_t e[8];
		if (recv(fd, e, 8, 0) != 8) return "";
		len = 0;
		for (int i = 0; i < 8; ++i) len = (len << 8) | e[i];
	}
	std::string body(len, '\0');
	size_t off = 0;
	while (off < len) {
		if (!waitReadable(timeoutMs)) break;
		ssize_t n = recv(fd, &body[off], len - off, 0);
		if (n <= 0) break;
		off += (size_t)n;
	}
	return body;
}

/* 发握手请求，返回服务端响应头全文（到 \r\n\r\n） */
std::string doHandshake(int fd, const std::string& token) {
	std::string req =
		"GET /ws/term" + (token.empty() ? "" : "?token=" + token) + " HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Upgrade: websocket\r\n"
		"Connection: Upgrade\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"\r\n";
	send(fd, req.data(), req.size(), MSG_NOSIGNAL);
	std::string resp;
	char buf[1024];
	while (resp.find("\r\n\r\n") == std::string::npos) {
		ssize_t n = recv(fd, buf, sizeof(buf), 0);
		if (n <= 0) break;
		resp.append(buf, (size_t)n);
	}
	return resp;
}

} /* namespace */

TH_TEST(webshell_handshake_upgrades) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	std::string resp = doHandshake(sv[1], "");
	TH_CHECK(resp.find("HTTP/1.1 101") == 0);
	TH_CHECK(resp.find("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != std::string::npos);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_rejects_wrong_token) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, "correct"); }, sv[0]);
	std::string resp = doHandshake(sv[1], "wrong");
	TH_CHECK(resp.find("HTTP/1.1 401") == 0);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_accepts_correct_token) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, "secret"); }, sv[0]);
	std::string resp = doHandshake(sv[1], "secret");
	TH_CHECK(resp.find("HTTP/1.1 101") == 0);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_serves_index_page) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	const char* req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
	send(sv[1], req, strlen(req), 0);
	std::string resp;
	char buf[2048];
	ssize_t n;
	while ((n = recv(sv[1], buf, sizeof(buf), 0)) > 0) {
		resp.append(buf, (size_t)n);
		if (resp.size() > 65536) break;
	}
	TH_CHECK(resp.find("HTTP/1.1 200") == 0);
	TH_CHECK(resp.find("xterm") != std::string::npos);
	TH_CHECK(resp.find("/ws/term") != std::string::npos);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_terminal_roundtrip) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	std::string resp = doHandshake(sv[1], "");
	TH_CHECK(resp.find("HTTP/1.1 101") == 0);

	/* 发命令，等 shell 回显 */
	std::string cmd = maskedText("echo ws-bridge-77\n");
	send(sv[1], cmd.data(), cmd.size(), MSG_NOSIGNAL);

	std::string acc;
	int op = -1;
	for (int i = 0; i < 3000 && acc.find("ws-bridge-77") == std::string::npos; ++i) {
		std::string body = recvFrame(sv[1], &op, 10);
		if (!body.empty()) acc += body;
		usleep(1000);
	}
	TH_CHECK(acc.find("ws-bridge-77") != std::string::npos);
	TH_CHECK(op == bot::ws::OP_TEXT || op == bot::ws::OP_BINARY);

	/* 收尾：exit */
	send(sv[1], maskedText("exit\n").data(), 6, MSG_NOSIGNAL);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_ping_gets_pong) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	std::string resp = doHandshake(sv[1], "");
	TH_CHECK(resp.find("HTTP/1.1 101") == 0);

	/* 构造掩码 ping 帧（opcode 9） */
	std::string ping;
	ping += (char)0x89; ping += (char)0x82;
	ping += (char)0x11; ping += (char)0x22; ping += (char)0x33; ping += (char)0x44;
	ping += (char)('h' ^ 0x11); ping += (char)('i' ^ 0x22);
	send(sv[1], ping.data(), ping.size(), MSG_NOSIGNAL);

	/* pong 与服务端转发的 pty 输出（shell prompt text 帧）存在到达顺序竞态：
	 * 循环收帧直到命中 pong（跳过 text/binary 帧），最多 20 帧 * 3s 超时 */
	int op = -1;
	std::string body;
	for (int i = 0; i < 20 && op != bot::ws::OP_PONG; ++i) {
		body = recvFrame(sv[1], &op);
	}
	TH_CHECK(op == bot::ws::OP_PONG);
	TH_CHECK(body == "hi");

	close(sv[1]);
	t.join();
	close(sv[0]);
}

TH_TEST(webshell_resize_frame_accepted) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	std::string resp = doHandshake(sv[1], "");
	TH_CHECK(resp.find("HTTP/1.1 101") == 0);
	/* resize 帧不应导致会话中断，随后命令仍可达 */
	std::string rz = maskedText("{\"op\":\"resize\",\"rows\":24,\"cols\":80}");
	send(sv[1], rz.data(), rz.size(), MSG_NOSIGNAL);
	std::string cmd = maskedText("echo after-resize\n");
	send(sv[1], cmd.data(), cmd.size(), MSG_NOSIGNAL);
	std::string acc;
	for (int i = 0; i < 3000 && acc.find("after-resize") == std::string::npos; ++i) {
		std::string body = recvFrame(sv[1]);
		if (!body.empty()) acc += body;
		usleep(1000);
	}
	TH_CHECK(acc.find("after-resize") != std::string::npos);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

/* 回归（复活复查 2026-10-03）：带 ?token=… 打开首页必须 200。
 * 此前路由未剥离 query，/ 落 404——非回环部署（强制 token）下页面打不开。 */
TH_TEST(webshell_serves_index_with_query_string) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { TH_SKIP("socketpair 不可用"); return; }
	std::thread t([](int s) { bot::webshell::handleConnection(s, ""); }, sv[0]);
	const char* req = "GET /?token=abc123 HTTP/1.1\r\nHost: localhost\r\n\r\n";
	send(sv[1], req, strlen(req), 0);
	std::string resp;
	char buf[2048];
	ssize_t n;
	while ((n = recv(sv[1], buf, sizeof(buf), 0)) > 0) {
		resp.append(buf, (size_t)n);
		if (resp.size() > 65536) break;
	}
	TH_CHECK(resp.find("HTTP/1.1 200") == 0);
	TH_CHECK(resp.find("xterm") != std::string::npos);
	TH_CHECK(resp.find("/ws/term") != std::string::npos);
	close(sv[1]);
	t.join();
	close(sv[0]);
}

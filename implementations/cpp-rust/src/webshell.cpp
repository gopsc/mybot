/* webshell.cpp —— Web SSH 服务主体实现（契约见 webshell.hpp） */

#include "webshell.hpp"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <string>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "webterm.hpp"
#include "wsproto.hpp"

namespace bot {
namespace webshell {

namespace {

/* 前端单页（xterm.js CDN + WS 客户端）。token 从页面 URL query 透传。
 * 代码注入面：token 只进字符串字面量（JSON.stringify 输出），不拼 HTML。 */
const char* kIndexHtml = R"HTML(<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>bot4cj Web SSH</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css">
<style>html,body{height:100%;margin:0;background:#111}#term{height:100%;padding:8px}</style>
</head><body><div id="term"></div>
<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
<script>
const q = new URLSearchParams(location.search);
const token = q.get("token") || "";
const proto = location.protocol === "https:" ? "wss:" : "ws:";
const wsUrl = proto + "//" + location.host + "/ws/term" + (token ? "?token=" + encodeURIComponent(token) : "");
const term = new Terminal({cursorBlink:true});
term.open(document.getElementById("term"));
const ws = new WebSocket(wsUrl);
ws.onopen = () => { term.onData(d => ws.send(d)); term.onResize(() => {
  ws.send(JSON.stringify({op:"resize",rows:term.rows,cols:term.cols}));
}); ws.send(JSON.stringify({op:"resize",rows:term.rows,cols:term.cols})); };
ws.onmessage = ev => { if (typeof ev.data === "string") term.write(ev.data); };
ws.onclose = () => { term.write("\r\n\x1b[31m[connection closed]\x1b[0m\r\n"); };
</script></body></html>)HTML";

constexpr size_t kMaxHandshakeBytes = 16 * 1024;        /* 握手请求头上限 */

/* 握手阶段读超时秒数（issue #41）：每连接一线程且无连接上限，无超时的
 * 半截请求（slow-loris 变体）可按 N 条连接钉死 N 线程 + fd。10s 对正常
 * 客户端完成 TLS 后的明文小头余量充足；升级成功后立即清除——WS 泵的
 * 空闲是合法状态（终端挂机数小时不发送），不能波及。 */
constexpr int kHandshakeTimeoutSec = 10;

/* 读取直到 \r\n\r\n（或达到上限）。返回 0 成功 / -1 失败 */
int readHeaders(int sock, std::string& out) {
        char buf[1024];
        while (out.size() < kMaxHandshakeBytes) {
                if (out.find("\r\n\r\n") != std::string::npos) return 0;
                ssize_t n = recv(sock, buf, sizeof(buf), 0);
                if (n <= 0) return -1;
                out.append(buf, (size_t)n);
        }
        return -1;
}

bool sendAll(int sock, const std::string& data) {
        size_t off = 0;
        while (off < data.size()) {
                /* MSG_NOSIGNAL：对端已关闭时 send 返回 EPIPE 而非 SIGPIPE 杀进程
                 * （SIGPIPE 默认动作是终止，会话泵测试与长连接下都会被误杀） */
                ssize_t n = send(sock, data.data() + off, data.size() - off, MSG_NOSIGNAL);
                if (n <= 0) return false;
                off += (size_t)n;
        }
        return true;
}

/* 解析 resize 控制消息：{"op":"resize","rows":N,"cols":M} → true 并填值。
 * 严格解析（拒绝而非容错）：非法 JSON/缺字段 → false（该帧按普通输入写入）。 */
bool tryResize(const std::string& msg, unsigned& rows, unsigned& cols) {
        if (msg.find("\"op\"") == std::string::npos || msg.find("resize") == std::string::npos) return false;
        auto num = [&](const char* key, unsigned& out) {
                std::string k = "\""; k += key; k += "\"";
                size_t p = msg.find(k);
                if (p == std::string::npos) return false;
                p = msg.find(':', p + k.size());
                if (p == std::string::npos) return false;
                size_t b = p + 1;
                while (b < msg.size() && (msg[b] == ' ' || msg[b] == '\t')) ++b;
                size_t e = b;
                while (e < msg.size() && msg[e] >= '0' && msg[e] <= '9') ++e;
                if (e == b || e - b > 6) return false;
                unsigned v = 0;
                for (size_t i = b; i < e; ++i) v = v * 10 + (unsigned)(msg[i] - '0');
                if (v < 1 || v > 200) return false;
                out = v;
                return true;
        };
        return num("rows", rows) && num("cols", cols);
}

} /* namespace */

void handleConnection(int sock, const std::string& token) {
        /* ---- 0. 握手读超时（issue #41）----
         * 只作用于头部读取阶段：半截请求 10s 后 recv 返回 -1/EAGAIN，
         * readHeaders 的 n<=0 分支即关闭连接。头部读完立刻清除——
         * 之后 WS 会话的空闲（终端挂机）不是异常。 */
        {
                struct timeval tv{};
                tv.tv_sec = kHandshakeTimeoutSec;
                ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        }

        /* ---- 1. 读握手 ---- */
        std::string headers;
        if (readHeaders(sock, headers) != 0) { close(sock); return; }

        /* 头部已完整：解除握手读超时，后续 WS 泵/页面响应不再受它约束 */
        {
                struct timeval tv{};
                tv.tv_sec = 0;
                tv.tv_usec = 0;
                ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        }

        /* ---- 2. 普通 GET / → 单页前端（不升级） ----
         * 判定：请求行是 GET 且**完全没有** Upgrade 头（两种大小写都查）。
         * 注意不是「任一大小写缺失」——那样会把合法 WS 升级请求误判成页面请求。 */
        bool hasUpgrade = headers.find("Upgrade:") != std::string::npos ||
                          headers.find("upgrade:") != std::string::npos;
        if (headers.compare(0, 4, "GET ") == 0 && !hasUpgrade) {
                std::string path = headers.substr(4, headers.find(' ', 4) == std::string::npos ? 0 : headers.find(' ', 4) - 4);
                if (path.empty() || path[0] != '/') { path = "/"; }
                /* 路由只取路径部分：?token=… 是给页面里 WS 客户端透传的口令，
                 * 不属于路由。此前未剥离 query，带 token 打开首页会误落 404——
                 * 而非回环部署（强制 token）下首页等于永远打不开。 */
                std::string::size_type qpos = path.find('?');
                if (qpos != std::string::npos) { path.resize(qpos); }
                if (path == "/" || path.rfind("/index.html", 0) == 0) {
                        std::string resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                                           "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
                        sendAll(sock, resp);
                        sendAll(sock, kIndexHtml);
                        close(sock);
                        return;
                }
                sendAll(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found");
                close(sock);
                return;
        }

        /* ---- 3. WebSocket 握手 + token 校验 ---- */
        auto hr = ws::parseHandshake(headers);
        if (!hr.ok) {
                sendAll(sock, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                close(sock);
                return;
        }
        if (!token.empty() && hr.token != token) {
                sendAll(sock, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                close(sock);
                return;
        }
        if (!sendAll(sock, ws::upgradeResponse(hr.reason))) { close(sock); return; }

        /* ---- 4. PTY 会话泵 ---- */
        webterm::Session session;
        if (session.masterFd() < 0) {
                sendAll(sock, ws::encodeFrame(ws::OP_CLOSE, "\x03\xee"));       /* 1006 异常关闭 */
                close(sock);
                return;
        }

        ws::Decoder dec;
        std::string ptyOut;
        bool open = true;
        std::string closePayload;       /* 空 = 正常/对端关闭；协议错误时填 1002 */
        while (open) {
                struct pollfd pf[2];
                /* sock 同时监听 POLLHUP/POLLERR：对端 close 时 poll 若无 POLLIN
                 * 数据但只有 HUP 事件，不监听就永不醒 → 线程永久阻塞、join 挂死 */
                pf[0] = {sock, POLLIN | POLLHUP, 0};
                pf[1] = {session.masterFd(), POLLIN | POLLHUP, 0};
                int pr = poll(pf, 2, -1);
                if (pr < 0) break;

                if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
                        char buf[8192];
                        ssize_t n = recv(sock, buf, sizeof(buf), 0);
                        if (n <= 0) break;                              /* 对端关闭 */
                        auto err = dec.feed((const uint8_t*)buf, (size_t)n);
                        if (err != ws::DecodeError::None && err != ws::DecodeError::NeedMore) {
                                closePayload = "\x03\xea";      /* 1002 协议错误：拒绝式解码命中 */
                                break;
                        }
                        for (const auto& f : dec.messages()) {
                                switch (f.opcode) {
                                case ws::OP_TEXT:
                                case ws::OP_BINARY: {
                                        unsigned rows = 0, cols = 0;
                                        if (tryResize(f.payload, rows, cols)) {
                                                session.resize(rows, cols);
                                        } else if (session.write(f.payload) < 0) {
                                                open = false;
                                        }
                                        break;
                                }
                                case ws::OP_PING:
                                        if (!sendAll(sock, ws::encodeFrame(ws::OP_PONG, f.payload))) { open = false; }
                                        break;
                                case ws::OP_CLOSE:
                                        open = false;
                                        break;
                                default:
                                        break;
                                }
                                if (!open) break;
                        }
                }

                if (pf[1].revents & (POLLIN | POLLHUP)) {
                        ptyOut.clear();
                        bool more = session.drain(ptyOut, 65536);
                        if (!ptyOut.empty() && !sendAll(sock, ws::encodeFrame(ws::OP_TEXT, ptyOut))) { open = false; }
                        if (!more || !session.alive()) { open = false; }        /* shell 退出 */
                }
        }

        /* 正常/异常收尾：正常 close 或对端关闭时无载荷 close；因协议/帧错误
         * 退出时带 1002（协议错误）码，便于客户端区分「服务端主动拒绝」与
         * 「连接被对端关闭」。见 pump 内 break 前的注释。 */
        sendAll(sock, ws::encodeFrame(ws::OP_CLOSE, closePayload));
        session.closeSession();
        close(sock);
}

int run(const std::string& host, const std::string& portStr, const std::string& token) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { std::perror("webshell: socket"); return 1; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)std::stoul(portStr));
        if (host.empty() || host == "127.0.0.1" || host == "localhost") {
                addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        } else if (host == "0.0.0.0") {
                addr.sin_addr.s_addr = htonl(INADDR_ANY);
        } else {
                if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
                        std::fprintf(stderr, "webshell: 无法解析监听地址 %s\n", host.c_str());
                        close(fd);
                        return 1;
                }
        }
        if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
                std::perror("webshell: bind");
                close(fd);
                return 1;
        }
        if (listen(fd, 16) != 0) {
                std::perror("webshell: listen");
                close(fd);
                return 1;
        }
        std::fprintf(stderr, "Web SSH listening on %s:%s (token %s)\n",
                host.c_str(), portStr.c_str(), token.empty() ? "off" : "on");

        /* 每连接一线程，会话自持生命周期；detach 免于维护线程池 */
        while (true) {
                int cfd = accept(fd, nullptr, nullptr);
                if (cfd < 0) {
                        /* 一切 accept 失败（含 EINTR）都不构成退场条件
                         * （issue #42）：本模式未装任何信号处理器
                         * （installStopSignalHandlers 仅 robot 分支调用），
                         * 今日 EINTR 不可达；未来谁给本进程装了 handler，
                         * 也不该让一次无害信号静默带走整个服务。优雅停机
                         * 若将来需要，应显式设计（停收新连 + 排空现存会话），
                         * 而不是蹭 EINTR break（旧行为：服务静默 return 0）。 */
                        continue;
                }
                std::thread([cfd, token]() { handleConnection(cfd, token); }).detach();
        }
        close(fd);
        return 0;
}

} /* namespace webshell */
} /* namespace bot */

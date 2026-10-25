#pragma once
/* webshell.hpp —— Web SSH 服务主体（#24，feat/web-ssh MVP）
 *
 * 拓扑：浏览器 xterm.js → WebSocket(/ws/term) → handleConnection 泵 → forkpty → shell。
 *   - GET /            → 单页前端（xterm.js CDN + WS 客户端，内嵌 HTML 字符串）
 *   - GET /ws/term?token=… → 101 升级 → 文本帧双向桥接
 *
 * 会话泵（handleConnection）：
 *   WS text 帧 → session.write（shell 输入）；"{\"op\":\"resize\",...}" → TIOCSWINSZ
 *   pty 输出 → text 帧回发；ping → pong；close 帧 / shell 退出 → 结束并关闭
 *
 * 安全（与 wsproto 契约配套）：
 *   - token 校验在握手层（?token=），非回环监听强制非空（cliargs 校验）；
 *   - 每连接独立 Session 与 socket，无共享可变状态（线程隔离天然成立）；
 *   - 帧/消息上限由 ws::Decoder（64 KiB）单点拒绝。
 *
 * run() 为阻塞入口（main 调用）；handleConnection 独立可测（socketpair 直测泵）。
 */

#include <string>

namespace bot {
namespace webshell {

/* 监听 host:port 并服务直到进程收到终止信号。返回 0 = 正常被信号终止，
 * 非 0 = 启动失败（已向 stderr 说明原因）。 */
int run(const std::string& host, const std::string& portStr, const std::string& token);

/* 处理一条已 accept 的连接（sock 已连接）。握手失败/校验失败会写 4xx 后关闭。
 * 可测：socketpair 传入一个伪客户端即可完整走通握手 + 双向泵。 */
void handleConnection(int sock, const std::string& token);

} /* namespace webshell */
} /* namespace bot */

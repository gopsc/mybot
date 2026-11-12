#pragma once
/* webterm.hpp —— Web SSH 的 PTY 会话桥（#24，feat/web-ssh MVP）
 *
 * 职责：把一条 WebSocket 连接对接到一个伪终端（PTY）上的交互 shell。
 *   WS 文本帧 → 写入 pty master；pty master 输出 → 封装成文本帧返回。
 *   resize 帧（应用层约定 { "op":"resize","rows":N,"cols":M }）→ TIOCSWINSZ。
 *
 * 实现：forkpty(3)（<pty.h>，-lutil）——内核分配 pty 对，子进程在子会话
 * 中 exec 交互 shell（$SHELL 或 /bin/sh）。纯 POSIX，无第三方依赖。
 *
 * 生命周期契约：
 *   - 构造即起会话；析构/closeSession() 关闭 master 并回收子进程；
 *   - alive() 用 waitpid(WNOHANG) 观察：shell 退出 → 会话结束，调用方应发
 *     close 帧并关闭连接；
 *   - 输出为原始字节流（不做 UTF-8/终端转义处理，交由前端 xterm.js）。
 *
 * 安全：token 校验发生在握手层（main），**绝不进入本会话环境**；子进程
 * 不继承宿主敏感环境变量之外的任何 Web SSH 专用状态。
 */

#include <cstddef>
#include <string>

namespace bot {
namespace webterm {

class Session {
public:
        Session();                              /* forkpty + exec shell */
        ~Session();

        Session(const Session&) = delete;
        Session& operator=(const Session&) = delete;

        /* 写入 shell（WS 文本帧载荷）。返回实际写入字节数；-1 = 会话已死。 */
        ssize_t write(const std::string& data);
        /* 非阻塞排空 pty 输出到 out（尽力而为，上限 cap 字节）。
         * 返回是否仍有数据待读（true = 可能还有输出）。 */
        bool drain(std::string& out, size_t cap);
        /* 调整窗口尺寸（TIOCSWINSZ） */
        bool resize(unsigned rows, unsigned cols);
        /* shell 是否存活（waitpid WNOHANG，内部收尸）。
         * 收尸时同时关闭 pty master：防「收尸后 closeSession 提前返回」
         * 造成的 fd/pty 泄漏（调用方随后再关也不会重复关闭）。 */
        bool alive();
        /* 主动关闭：关 master + kill 子进程 + 收尸 */
        void closeSession();

        int masterFd() const { return master_; }

private:
        int master_ = -1;
        int child_ = -1;
        bool closed_ = false;

        void closeMaster();                     /* 关闭并复位 master fd（幂等） */
};

} /* namespace webterm */
} /* namespace bot */

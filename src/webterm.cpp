/* webterm.cpp —— Web SSH PTY 会话桥实现（契约见 webterm.hpp） */

#include "webterm.hpp"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace bot {
namespace webterm {

Session::Session() {
	int master = -1;
	pid_t pid = forkpty(&master, nullptr, nullptr, nullptr);
	if (pid < 0) return;			/* 失败态：master_ 保持 -1，调用方判活 */
	master_ = master;
	/* 非阻塞：drain 的连续 read 循环在数据读空后若再读会阻塞（blocking
	 * master + 已消费全部 poll 可见数据的窗口），会话泵轮询因此卡死。 */
	int fl = fcntl(master_, F_GETFL);
	if (fl >= 0) fcntl(master_, F_SETFL, fl | O_NONBLOCK);
	if (pid == 0) {
		/* 子进程：exec 交互 shell。清空 SIGPIPE 避免 shell 管道破裂自杀。 */
		signal(SIGPIPE, SIG_DFL);
		/* exec 前关闭全部非 stdio fd：forkpty 子进程会继承调用方进程的
		 * 一切打开 fd（WebSocket socket、日志、总线句柄等）。若保留，Web SSH
		 * 场景下浏览器关闭连接后 shell 仍持有该 socket 引用 → 对端 EOF 永不
		 * 到达 → 服务端 poll 永不醒，连接泄漏（实测复现：socketpair 测试端
		 * close 后另一端 poll 无事件）。shell 只需 stdio（pty slave）。 */
		for (int fd = 3; fd < 65536; ++fd) {
			if (fcntl(fd, F_GETFD) >= 0) close(fd);
		}
		const char* shell = getenv("SHELL");
		if (!shell || !*shell) shell = "/bin/sh";
		execlp(shell, shell, nullptr);
		_exit(127);
	}
	child_ = (int)pid;
}

Session::~Session() { closeSession(); }

ssize_t Session::write(const std::string& data) {
	if (master_ < 0) return -1;
	ssize_t n = ::write(master_, data.data(), data.size());
	if (n < 0 && errno == EIO) return -1;	/* 子进程已死 */
	return n;
}

bool Session::drain(std::string& out, size_t cap) {
	if (master_ < 0) return false;
	struct pollfd pfd = {master_, POLLIN | POLLHUP, 0};
	int pr = poll(&pfd, 1, 0);
	if (pr < 0) return false;
	if (!(pfd.revents & (POLLIN | POLLHUP))) return false;

	char buf[4096];
	size_t total = 0;
	while (total < cap) {
		/* 非阻塞读（O_NONBLOCK 已在构造时设置）：读空即 EAGAIN 退出循环 */
		ssize_t n = ::read(master_, buf, sizeof(buf) < (cap - total) ? sizeof(buf) : (cap - total));
		if (n > 0) {
			out.append(buf, (size_t)n);
			total += (size_t)n;
			if (total >= cap) break;
			continue;
		}
		if (n == 0) break;			/* EOF（shell 退出） */
		if (errno == EAGAIN || errno == EWOULDBLOCK) break;
		if (errno == EIO) break;	/* 子进程死 */
		break;
	}
	return !(pfd.revents & POLLHUP);
}

bool Session::resize(unsigned rows, unsigned cols) {
	if (master_ < 0) return false;
	struct winsize ws;
	memset(&ws, 0, sizeof(ws));
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;
	return ioctl(master_, TIOCSWINSZ, &ws) == 0;
}

bool Session::alive() {
	if (master_ < 0 || child_ < 0) return false;
	if (closed_) return false;
	int st = 0;
	pid_t r = waitpid(child_, &st, WNOHANG);
	if (r == child_) { closed_ = true; return false; }	/* 已收尸 */
	if (r < 0) { closed_ = true; return false; }
	return true;
}

void Session::closeSession() {
	if (closed_) return;
	closed_ = true;
	if (master_ >= 0) {
		::close(master_);
		master_ = -1;
	}
	if (child_ > 0) {
		::kill(child_, SIGHUP);			/* 先挂断，让 shell 自行退出 */
		int st = 0;
		waitpid(child_, &st, WNOHANG);	/* 尽力收尸，不阻塞 */
		child_ = -1;
	}
}

} /* namespace webterm */
} /* namespace bot */

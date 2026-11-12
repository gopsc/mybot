#include "unix_line_server.h"

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "sim_config.h"

namespace {

// sun_path 是定长数组，超长会被静默截断成另一个路径，必须显式拒绝
constexpr std::size_t kMaxPathLen = sizeof(sockaddr_un::sun_path) - 1;

bool setNonBlocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return false;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

}  // namespace

UnixLineServer::UnixLineServer(const std::string& socketPath, const char* logTag,
                               std::size_t maxBufferBytes)
    : path_(socketPath), logTag_(logTag), maxBufferBytes_(maxBufferBytes) {
    if (path_.size() > kMaxPathLen) {
        std::fprintf(stderr, "%s: socket path too long (max %zu bytes): %s\n", logTag_,
                     kMaxPathLen, path_.c_str());
        return;
    }

    listenFd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd_ < 0) {
        std::fprintf(stderr, "%s: socket() failed: %s\n", logTag_, std::strerror(errno));
        return;
    }

    ::unlink(path_.c_str());  // 上次异常退出留下的 inode 会导致 EADDRINUSE

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path_.c_str(), path_.size());

    if (::bind(listenFd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        std::fprintf(stderr, "%s: bind(%s) failed: %s\n", logTag_, path_.c_str(),
                     std::strerror(errno));
        ::close(listenFd_);
        listenFd_ = -1;
        return;
    }

    if (::listen(listenFd_, 4) != 0) {
        std::fprintf(stderr, "%s: listen() failed: %s\n", logTag_, std::strerror(errno));
        ::close(listenFd_);
        listenFd_ = -1;
        ::unlink(path_.c_str());
        return;
    }

    if (!setNonBlocking(listenFd_)) {
        std::fprintf(stderr, "%s: cannot set listen socket non-blocking: %s\n", logTag_,
                     std::strerror(errno));
    }
}

UnixLineServer::~UnixLineServer() {
    // 基类析构里不再回调派生类的 onClientGone（派生部分已销毁），fd 与 inode
    // 由这里直接收尾
    if (clientFd_ >= 0) {
        ::close(clientFd_);
        clientFd_ = -1;
    }
    if (listenFd_ >= 0) {
        ::close(listenFd_);
        listenFd_ = -1;
    }
    if (!path_.empty()) {
        ::unlink(path_.c_str());
    }
}

void UnixLineServer::dropClient() {
    if (clientFd_ >= 0) {
        ::close(clientFd_);
        clientFd_ = -1;
    }
    buffer_.clear();
    clientEof_ = false;
    onClientGone();
}

void UnixLineServer::acceptPending() {
    if (listenFd_ < 0) {
        return;
    }
    for (;;) {
        const int fd = ::accept(listenFd_, nullptr, nullptr);
        if (fd < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                std::fprintf(stderr, "%s: accept() failed: %s\n", logTag_, std::strerror(errno));
            }
            return;
        }
        setNonBlocking(fd);  // recv 侧必须非阻塞，否则无请求时卡死渲染循环
        // 新连接顶掉旧的：对端每次请求都可能重连，旧 fd 多半是上次残骸
        dropClient();
        clientFd_ = fd;
    }
}

void UnixLineServer::readPending() {
    if (clientFd_ < 0) {
        return;
    }
    for (;;) {
        char chunk[256];
        const ssize_t n = ::recv(clientFd_, chunk, sizeof(chunk), 0);
        if (n > 0) {
            buffer_.append(chunk, static_cast<std::size_t>(n));
            if (buffer_.size() > maxBufferBytes_) {
                std::fprintf(stderr, "%s: client exceeded %zu bytes without newline, dropping\n",
                             logTag_, maxBufferBytes_);
                dropClient();
                return;
            }
            continue;
        }
        if (n == 0) {
            // 对端关了写端（发完命令就断开的常见模式）：标记 EOF，等 buffer 派发
            // 完再断开，否则请求还没被处理就被清空了。半关连接仍可写，答复照发。
            clientEof_ = true;
            return;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            std::fprintf(stderr, "%s: recv() failed: %s\n", logTag_, std::strerror(errno));
            dropClient();
        }
        return;
    }
}

void UnixLineServer::poll() {
    // 上一帧派发完 buffer 后标记了 EOF，这帧开头再断开，给主循环一帧时间发答复
    if (clientEof_) {
        dropClient();
    }

    acceptPending();

    if (clientFd_ < 0) {
        return;
    }
    readPending();

    std::size_t start = 0;
    for (std::size_t i = 0; i < buffer_.size(); ++i) {
        if (buffer_[i] != '\n') {
            continue;
        }
        handleLine(buffer_.substr(start, i - start));
        start = i + 1;
    }
    buffer_.erase(0, start);
}

bool UnixLineServer::sendAll(const void* data, std::size_t len) {
    if (clientFd_ < 0) {
        return false;
    }
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(SimConfig::kSendDeadlineMs);
    const unsigned char* ptr = static_cast<const unsigned char*>(data);
    std::size_t off = 0;
    while (off < len) {
        // MSG_NOSIGNAL：对端已关时 send 触发 SIGPIPE 会直接杀掉仿真器进程
        const ssize_t n = ::send(clientFd_, ptr + off, len - off, MSG_NOSIGNAL);
        if (n > 0) {
            off += static_cast<std::size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (std::chrono::steady_clock::now() >= deadline) {
                std::fprintf(stderr, "%s: send timed out after %d ms, dropping client\n",
                             logTag_, SimConfig::kSendDeadlineMs);
                dropClient();
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        std::fprintf(stderr, "%s: send() failed: %s\n", logTag_, std::strerror(errno));
        dropClient();
        return false;
    }
    return true;
}

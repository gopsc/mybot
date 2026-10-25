#include "harness.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstring>

// 契约与注释在 harness.h（本仓惯例：声明处写文档，实现处不重述）。函数体自
// sim/tests/main.cpp 的匿名 namespace 逐字搬迁，两处例外：① 计数器从「文件级全局」
// 变成「本 TU 定义、harness.h 里 extern 声明」——这正是拆成多 TU 后必须由单点持有的
// 原因；② writeTextFile 原在场景域那一段里，因引擎域也用而上提到这里。

namespace SimTests {

int g_total = 0;
int g_failed = 0;

void check(bool cond, const char* what) {
    ++g_total;
    if (!cond) {
        ++g_failed;
        std::fprintf(stderr, "[FAIL] %s\n", what);
    }
}

bool near(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

int connectTo(const std::string& path) {
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

void say(int fd, const char* line) {
    (void)::send(fd, line, std::strlen(line), MSG_NOSIGNAL);
}

std::string recvLine(int fd) {
    std::string line;
    char ch;
    while (line.size() < 255) {
        const ssize_t n = ::recv(fd, &ch, 1, 0);
        if (n <= 0) {
            break;
        }
        if (ch == '\n') {
            break;
        }
        line += ch;
    }
    return line;
}

bool recvExact(int fd, void* buf, std::size_t len) {
    auto* p = static_cast<char*>(buf);
    std::size_t off = 0;
    while (off < len) {
        const ssize_t n = ::recv(fd, p + off, len - off, 0);
        if (n <= 0) {
            return false;
        }
        off += static_cast<std::size_t>(n);
    }
    return true;
}

std::string testSockPath(const char* tag) {
    return "/tmp/mybot-sim-tests-" + std::to_string(::getpid()) + "-" + tag + ".sock";
}

void writeTextFile(const std::string& path, const char* content) {
    FILE* f = std::fopen(path.c_str(), "w");
    if (f) {
        std::fputs(content, f);
        std::fclose(f);
    }
}

}  // namespace SimTests

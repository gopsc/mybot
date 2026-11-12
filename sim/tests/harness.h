#pragma once

#include <cstddef>
#include <string>

// sim_tests 的共享底座：断言记账 + AF_UNIX 测试客户端助手。
//
// 为什么需要它：这些用例原本全挤在单个 main.cpp 的一个匿名 namespace 里，记账计数器
// 是文件级全局。按域拆成多个 TU 后（2026-10-04，第三轮重构 Phase 21），计数器必须由
// harness.cpp 单点持有——否则每个 TU 各数各的，汇总行只报最后链接那个文件的账，
// 「381 通过」会静默缩水而退出码照样是 0。
//
// 拆分约定：
//   * 每个测试 TU 把内容整体放进 namespace SimTests。域内私有的助手（oneBox /
//     writeTextFile / slurp / engineScenePath / PingBridge 之类）因此不会与其他域撞名，
//     套件函数也正好落在 suites.h 声明的同一命名空间里——定义与声明对不上就编译不过，
//     这是刻意留的一致性钉子。
//   * g_total / g_failed 只有 check() 写，main() 只读它们出汇总行。
//   * 执行顺序单点在 main.cpp 的名册（拆前拆后逐字一致）；suites.h 只按域分组声明，
//     不代表调用顺序。
namespace SimTests {

extern int g_total;
extern int g_failed;

// 记一条断言：失败打 [FAIL] 到 stderr，不中断（后续断言照跑）。
void check(bool cond, const char* what);

bool near(float a, float b, float eps);

// 连到指定路径的 AF_UNIX 测试客户端；失败返回 -1。fd 保持阻塞语义。
int connectTo(const std::string& path);

void say(int fd, const char* line);

// 阻塞收一行（到 \n，不含）
std::string recvLine(int fd);

bool recvExact(int fd, void* buf, std::size_t len);

// 带 pid 的测试监听路径：与开发会话里可能开着的真仿真器互不干扰。
std::string testSockPath(const char* tag);

// 落一个文本文件。原先是场景域的文件内助手，但引擎域也要现造场景文件，故一并归到
// 共享底座（拆分后跨 TU 的助手只有这一个）。
void writeTextFile(const std::string& path, const char* content);

}  // namespace SimTests

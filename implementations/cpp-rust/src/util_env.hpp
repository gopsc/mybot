#pragma once
/* util_env.hpp —— 进程环境与运行期状态：环境变量读取、errno 文案、信号停止标志
 * （自 util.hpp 拆出，2026-09-26 批次 3）。
 *
 * 调试开关 DebugSwitch 与惰性日志 logD 已析出到 debug_log.hpp（2026-10-06，纯搬迁）：
 * logD 往 std::cerr 写，它让本头的**每个** includer 都裹挟 <iostream>，而真正调 logD
 * 的只有 6 个 TU。析出理由与实测数据见 debug_log.hpp 的头注。
 * 需要 logD 的 TU 请**直接** #include "debug_log.hpp"，不要再靠本头传导。 */

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>

namespace bot {

inline std::optional<std::string> getEnvVar(const std::string& name) {
	/* 读环境变量：本进程只在启动期（起线程之前）调 setenv（main.cpp 的
	 * BOT4CJ_LLM_KEY 注入），此后 environ 不再变形 */
	const char* v = std::getenv(name.c_str());	/* NOLINT(concurrency-mt-unsafe)：启动期单线程读 */
	return v == nullptr ? std::nullopt : std::optional<std::string>(std::string(v));
}

/* errno → 人话文案（线程安全单点）。std::strerror 按 POSIX 判 mt-unsafe（glibc
 * 2.32 前返回静态缓冲指针），而调用方横跨连接线程/守护线程，故统一走
 * strerror_r：glibc 下 _GNU_SOURCE 已定义（g++ 缺省），是 GNU 变体返回 char*；
 * musl（alpine）只有 XSI 变体返回 int、写用户缓冲。文案与 strerror 逐字一致。 */
inline std::string errnoText(int err) {
	char buf[128];
	buf[0] = '\0';
#if defined(__GLIBC__)
	const char* s = ::strerror_r(err, buf, sizeof buf);	/* NOLINT(concurrency-mt-unsafe)：GNU 变体线程安全 */
	return std::string(s != nullptr ? s : buf);
#else
	if (::strerror_r(err, buf, sizeof buf) != 0) {
		return "Unknown error " + std::to_string(err);
	}
	return std::string(buf);
#endif
}

/* D4：信号停止标志——SIGINT/SIGTERM 处理器置位，主流程与阻塞点（TCP accept）
 * 检查后放弃阻塞，让 deactivate 清理链（destroy / 守护停机）正常走完再退出。
 * C-L1：命名空间级常量初始化（无 __cxa_guard 守卫），信号处理器内访问
 * async-signal-safe——函数局部 static 的首次初始化守卫若被同线程信号打断，
 * 守卫重入可致 abort。保留访问器以稳定调用点。 */
inline std::atomic<bool> g_stopRequested{false};
inline std::atomic<bool>& stopRequested() {
	return g_stopRequested;
}

} // namespace bot

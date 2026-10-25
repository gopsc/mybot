#pragma once
/* debug_log.hpp —— BOT4CJ_DEBUG 调试开关与惰性日志（限流原语之外的叶子头）
 *
 * 2026-10-06 自 util_env.hpp 析出（行为保持，纯搬迁）：这两样是**同一个关注点**
 * （「调试期把 call/build/destroy 打出来」），而 util_env.hpp 的其余内容（环境变量
 * 读取、errno 文案、信号停止标志）是进程环境域。析出的动机是 <iostream>：logD 往
 * std::cerr 写，此前让 util_env.hpp 的**每个** includer 都裹挟整个 iostream——实测
 * 39 个 includer（38 个可编译 TU + util_path.hpp）里 38/38 全部裹挟，而真正调 logD
 * 的只有 6 个 TU（31 处调用点）。析出后 <iostream> 与 <functional> 跟着 logD 走，
 * util_env.hpp 只留 <atomic>/<cstdlib>/<cstring>/<optional>/<string>。
 * 先例：scriptlimit.hpp（c2ca71c）自 actionsource.hpp 析出。
 *
 * DebugSwitch 全仓**只被 logD 消费**（外部零调用点），两者同生共死，故放在一个头里
 * 而不是各拆一半。 */

#include <functional>
#include <iostream>
#include <string>

#include "util_env.hpp"		/* getEnvVar（BOT4CJ_DEBUG 的读取单点） */

namespace bot {

/* BOT4CJ_DEBUG = 1 时开启 call/build/destroy 详细信息转储 */
class DebugSwitch {
public:
	static bool enabled() {
		static bool en = [] {
			auto v = getEnvVar("BOT4CJ_DEBUG");
			return v.has_value() && *v == "1";
		}();
		return en;
	}
};

/* 惰性调试日志：仅 debug 模式才求值消息体（对应 Cangjie logD(() -> String)） */
inline void logD(const std::function<std::string()>& msg) {
	if (DebugSwitch::enabled()) { std::cerr << msg() << std::endl; }
}

} // namespace bot

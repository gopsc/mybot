#pragma once
/* util_except.hpp —— 异常类型、递归/深度守卫、字节流 Reader（自 util.hpp 拆出，
 * 2026-09-26 批次 3）。这些是全库最基础、几乎所有 TU 都要的类型，故独立成头。 */

#include <cstddef>
#include <functional>
#include <stdexcept>
#include <string>
#include <utility>

namespace bot {

/* 对应 Cangjie IllegalArgumentException */
class IllegalArgumentException : public std::runtime_error {
public:
	explicit IllegalArgumentException(const std::string& m) : std::runtime_error(m) {}
};

/* ---- 非标准异常的判据锚点（A5，2026-09-25 收敛四处手抄注释）----
 * 本机 LuaJIT 用 C++ 异常实现 luaD_throw（导入 _Unwind_RaiseException 而非
 * setjmp/longjmp），从没有 Lua CFRAME 的 C++ 帧抛出的 Lua 错误**不是**
 * std::exception——只接 std::exception 的层会让它一路穿透到 std::terminate，
 * 或把「单轮失败」升级成「整个会话结束」。因此凡「异常不得穿出」的边界都
 * 必须补一层 catch(...)，按各自口径折成回执/日志。现役五个边界：
 *   main 的 runRobotAndCleanup（顶层；rc=1，deactivate 必达）
 *   DispatchGate::run（executed 按 argsOk 分口径，见其站点注释）
 *   AgentToolRegistry::execute（折成工具回执，ok=false）
 *   McpBackend::handleRequest（对外经 sanitize 定容，刻意不回显成因）
 *   DaemonRunner::body（2026-10-01 审计 P2：detached 线程穿出即 terminate，
 *     折成 -1 + 响亮日志，promise 照常 set 让 join 路径走完）
 * 另 robot.cpp 的 commitHotBatch catch（先删后建失败口径）把下述词根拼进
 * 回执——那是第五个接住点，语义同源。
 * 文案词根单点 kNonStdExceptionNote：用户可见文本以它为词根（main 顶层是
 * 英文日志风格、mcpbackend 刻意定容，两处是例外；词形不同但判据同源）。
 * 改措辞/加边界先来这里，别再在各站点抄注释——跨站点行号引用（如
 * "main.cpp:173-176"）就是这么腐烂的。 */
inline constexpr const char* kNonStdExceptionNote = "非标准异常（Lua 错误或外来抛出）";

/* 递归深度 RAII 计数（N-15，收敛此前 hardware/robot 各自的局部 Guard 结构体）：
 * 构造 ++depth，析构 --depth（异常安全）。上限检查与报错文案由调用方决定，
 * 本类只保证「计数与回退不脱节」。求值环（@Vars 互引、$ 引用列回环）在
 * 结构上是无限递归，只能靠计数兜底。 */
class RecursionGuard {
	int& depth_;
public:
	explicit RecursionGuard(int& depth) : depth_(depth) { ++depth_; }
	~RecursionGuard() { --depth_; }
	RecursionGuard(const RecursionGuard&) = delete;
	RecursionGuard& operator=(const RecursionGuard&) = delete;
};

/* 深度上限防线：把「超限检查 + 计数」合并为一个 RAII。RecursionGuard（N-15）
 * 只收敛了计数一半——上限检查仍由调用方手写，检查与计数分离地各写一份，
 * 次序/比较符漂移即 off-by-one。构造时超限即抛 onExceed()，未超限则 ++，
 * 析构 --（异常安全）。
 * limit 传 nullptr = 只计数不设限：用于「自身不判环、但其计数是嵌套调用
 * 防线输入」的路径（MetaProvider 的 destroy 收集——它嵌套触发被引用方的
 * 非销毁收集，外层深度正是内层超限判定的输入）。
 * 上限值与报错文案语义各异（@Vars 表达式环、$ 引用环），仍由调用方给。 */
class DepthLimitGuard {
	int& depth_;
public:
	DepthLimitGuard(int& depth, const int* limit, const std::function<std::string()>& onExceed)
		: depth_(depth) {
		if (limit != nullptr && depth_ >= *limit) { throw IllegalArgumentException(onExceed()); }
		++depth_;
	}
	~DepthLimitGuard() { --depth_; }
	DepthLimitGuard(const DepthLimitGuard&) = delete;
	DepthLimitGuard& operator=(const DepthLimitGuard&) = delete;
};

/* 字节流抽象：结构/动作脚本统一按字符消费 */
class Reader {
public:
	virtual ~Reader() = default;
	virtual int read() = 0;	/* -1 = EOF，否则 0..255 */
};

/* 内存驻留读取器（stdin 整体读入 / 测试） */
class MemoryReader : public Reader {
	std::string data_;
	std::size_t pos_ = 0;
public:
	explicit MemoryReader(std::string data) : data_(std::move(data)) {}
	int read() override {
		return pos_ < data_.size() ? static_cast<unsigned char>(data_[pos_++]) : -1;
	}
};

} // namespace bot

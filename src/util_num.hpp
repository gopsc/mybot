#pragma once
/* util_num.hpp —— 数值解析/格式化单点：严格整数解析、越界报错尾段、有限浮点解析、
 * 数值字面量判定、double→整数値域判据、数值→文本（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <string>
#include <utility>

#include "util_str.hpp"	/* isNumericLiteral 用 trim */

namespace bot {

/* 严格整数解析的失败形态：调用方按场景给出人话报错（本项目错误信息惯例） */
enum class IntParse { OK, NOT_INT, OVERFLOW };

/* strtoll + ERANGE + 全串消费；负号等细节语义由调用方按场景裁决。
 * **内嵌 NUL 一律判非法**（2026-09-21 第七轮审计）：strtoll 走 c_str()，在第一个
 * NUL 处停下，而那个 NUL 正是 `*end`——于是"全串消费"判据被满足，尾随垃圾被
 * **静默丢弃**（`90\0junk` 报 OK/90）。NUL 进得来：.mt 词法不把 NUL 当分隔符，
 * .sql 引号态字面追加（见 sqlparse.cpp 与 daemonvar.cpp 的自述）。同族判据见
 * checkRelPath 的 RelPathCheck::NUL 与 luabridge.cpp 的 rejectEmbeddedNul。 */
inline std::pair<IntParse, long long> parseLongStrict(const std::string& s) {
	if (s.find('\0') != std::string::npos) { return {IntParse::NOT_INT, 0}; }
	char* end = nullptr;
	errno = 0;
	long long v = std::strtoll(s.c_str(), &end, 10);
	if (end == s.c_str() || *end != '\0') { return {IntParse::NOT_INT, 0}; }
	if (errno != 0) { return {IntParse::OVERFLOW, 0}; }
	return {IntParse::OK, v};
}

/* 整数选项越界报错的公共尾段。主体描述（「选项 --x」/「配置文件 f 的字段 'k'」）
 * 由调用方给，范围区间与实际值的呈现在此单点——CLI（cliargs 的 --mcp-* 预算、
 * main 的 --daemon-grace-ms）与配置文件（llmconfig wantInt）两条解析路径此前
 * 各自拼一份，措辞漂移会让按文案匹配的守门用例两头维护。 */
inline std::string rangeErrorText(const std::string& subject, long long lo, long long hi,
		const std::string& actual) {
	return subject + " 需要在 [" + std::to_string(lo) + ", " + std::to_string(hi)
		+ "] 范围内，实际是 " + actual;
}

/* 带范围校验的严格整数解析（2026-09-29 A4.2 单点）：非整数或越 [lo, hi]
 * 界返回 nullopt，边界含端点。只收敛「OK 判定 + 双边界钳制」这个谓词——
 * 此前各站点手写 `st != IntParse::OK || v < lo || v > hi`，抄漏一侧边界
 * 即防线缺口。报错文案仍由调用方按各自口径组（rangeErrorText / 自定义
 * 格式，逐字保持）；需要区分「非整数」与「越界」两种报错的站点
 * （--daemon-grace-ms、--phase）继续直接用 parseLongStrict。 */
inline std::optional<long long> parseBoundedLong(const std::string& text,
		long long lo, long long hi) {
	auto [st, v] = parseLongStrict(text);
	if (st != IntParse::OK || v < lo || v > hi) { return std::nullopt; }
	return v;
}

/* ---- 有限数值解析（M2/B2-2 单点，2026-09-20）----
 * strtod 全串消费 + 拒绝非有限值：four 处此前是同一判据的四份拷贝——
 *   hardware.cpp::parseMtDouble（矩阵单元格）、hardware.cpp Vars 字面量分支、
 *   expr.cpp::parseNumber、jsonparse.cpp 的 Float 分支；
 * 外加本文件下方的 isNumericLiteral（trim 后同判据）。醒目二分：strtod 静默
 * 返 0 + end 全消费是「没吃到数」与「读到 nan/inf 却当成功」的含糊——
 * 判据漂移意味着同一语义下 4 处消息口径各表其是，收敛到此。
 * 返回三态：INVALID=没消费干净/空串；NONFINITE=消费了但 nan/inf。
 * **只回状态**——报错文案与消息取舍留在各调用方（grep 守门锚定原文）。 */
enum class ParseFiniteStatus { OK, INVALID, NONFINITE };
inline ParseFiniteStatus parseFiniteDouble(const std::string& s, double& out) {
	/* 内嵌 NUL 一律判 INVALID：理由与 parseLongStrict 同款——strtod 在第一个 NUL
	 * 处停下而 `*end` 恰为该 NUL，"全串消费"判据会被满足，尾随垃圾静默丢弃。 */
	if (s.find('\0') != std::string::npos) { return ParseFiniteStatus::INVALID; }
	char* end = nullptr;
	out = std::strtod(s.c_str(), &end);
	if (end == s.c_str() || *end != '\0') { return ParseFiniteStatus::INVALID; }
	return std::isfinite(out) ? ParseFiniteStatus::OK : ParseFiniteStatus::NONFINITE;
}

/* 数值字面量判定：strtod 全串消费 + 有限值（拒绝空值/nan/inf）。与动作矩阵
 * 单元格的数值语义一致（parseMtDouble）。供「仅校验、不转换」的两处复用：
 * 结构脚本 Number 列、@Vars 的 value（值仍按文本驻留）。 */
inline bool isNumericLiteral(const std::string& s) {
	std::string v = trim(s);
	double d = 0.0;
	return parseFiniteDouble(v, d) == ParseFiniteStatus::OK;
}

/* ---- double → 整数转换的值域判据（M2/B2-2 余部，2026-09-21）----
 * 同一判据此前两份手写（luabridge 的键/值两条路径、agenttools 的工具参数），
 * 浮点边界恰是最容易抄错的一类常量：
 *   - int64：上界必须取 2^63 而**不是** LLONG_MAX——后者的 double 表示向上
 *     舍入为 2^63，用 `<=` 比较会放行溢出值；故这里是半开区间 [−2^63, 2^63)。
 *   - int：两个端点都能被 double 精确表示，直接取实际端点、闭区间。
 * 判据本身（含有限性）收敛到两个谓词；越界后怎么办（走浮点分支还是报错）
 * 仍由调用方决定，文案不动。 */
inline bool doubleFitsInt64(double d) {
	constexpr double kLo = -9223372036854775808.0;	/* -2^63 */
	constexpr double kHi = 9223372036854775808.0;	/* 2^63（半开区间上界） */
	return std::isfinite(d) && d >= kLo && d < kHi;
}

inline bool doubleFitsInt(double d) {
	constexpr double kLo = static_cast<double>(std::numeric_limits<int>::min());
	constexpr double kHi = static_cast<double>(std::numeric_limits<int>::max());
	return std::isfinite(d) && d >= kLo && d <= kHi;
}

/* 数值 → 文本：%.15g（整数不带小数点、去掉多余零），供 @Vars 表达式结果
 * 回写文本。程序不调用 setlocale，小数点恒为 '.'。 */
inline std::string formatNumber(double v) {
	char buf[64];
	std::snprintf(buf, sizeof(buf), "%.15g", v);
	return std::string(buf);
}

} // namespace bot

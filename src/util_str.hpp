#pragma once
/* util_str.hpp —— 字符串工具单点：拼接、恒时比较、安全标识符判定、ASCII 小写、
 * 整词切词、trim、报错回显转义、日志标记转义（自 util.hpp 拆出，2026-09-26 批次 3）。 */

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace bot {

/* 多段文案拼接单点：等价 `a + b + c` 链但不产生中间临时串（clang-tidy
 * performance-inefficient-string-concatenation 的收敛点，错误/定位文案构造
 * 一律走这里）。参数须能被 std::string::operator+= 接受（字面量/string/char）；
 * 数值段先过 std::to_string。 */
template <typename... Parts>
inline std::string concatMsg(Parts&&... parts) {
	std::string s;
	((void)(s += std::forward<Parts>(parts)), ...);
	return s;
}

/* ---- 恒时字符串比较（安全判据单点；审计 M1 + MCP-1/P2-1）----
 * std::string 的 == / != 短路：首个不匹配字节即返回，比较耗时与「匹配到
 * 哪一位」相关——暴露在外的凭据比对（--tcp 0.0.0.0 口令、MCP 首帧共享
 * 密钥）可被计时侧信道逐字节猜令牌。此前 TCP 口令与 MCP token 各有一份
 * 实现、强度不同（前者长度不等早退，后者长度差折叠进累计差）——安全
 * 判据必须单点且取严格者（2026-10-01 收敛）：
 * 长度差异折叠进累计差（先给 diff 喂长度差，再按较长一方的全长逐位异或
 * 累计），全长走完才判——回应时间既不泄露已匹配前缀，也不泄露长度比对
 * 结果。调用方注释若提「长度不等提前返回」，以此处为准。 */
inline bool safeEquals(const std::string& a, const std::string& b) {
	/* 上限对齐：token 上限 256（captureMcpAuthToken），短串不会溢出 */
	const std::size_t n = std::max(a.size(), b.size());
	unsigned diff = static_cast<unsigned>(a.size() ^ b.size());
	for (std::size_t i = 0; i < n; ++i) {
		const unsigned ca = i < a.size() ? static_cast<unsigned char>(a[i]) : 0u;
		const unsigned cb = i < b.size() ? static_cast<unsigned char>(b[i]) : 0u;
		diff |= ca ^ cb;
	}
	return diff == 0;
}

/* ---- 安全标识符判定（安全判据必须单点）----
 * 注入的驱动表名/变量名会被拼进合成 SQL，且表名还被当成
 * modules/<表名>.lua 去解析——放行引号/分号等价于让命令行参数改写
 * 结构脚本。此前 agentmode 的 CLI 预检与 RobotStruct::injectLuaDriver
 * 的注入防线各自手写同一判据（一度逐字相同）：判据漂移（只放宽一处）
 * 就是防线不一致，故收敛到本单点。 */
inline bool isSafeIdent(const std::string& s) {
	if (s.empty()) { return false; }
	unsigned char first = static_cast<unsigned char>(s[0]);
	if (!(std::isalpha(first) || s[0] == '_')) { return false; }
	for (char c : s) {
		unsigned char u = static_cast<unsigned char>(c);
		if (!(std::isalnum(u) || c == '_')) { return false; }
	}
	return true;
}

/* ---- ASCII 小写化（单点：agentaudit/agent_subprocess/agentmode/cliargs
 * 此前各写一份循环；只动 A-Z，非 ASCII 字节原样保留——与各处的
 * 「名字先小写再查表」判据配套，绝不能引入 locale 相关的宽小写）。 */
inline std::string toLowerAscii(const std::string& s) {
	std::string out(s);
	for (char& c : out) { c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); }
	return out;
}

/* ---- 整词切词判定（单点）----
 * 名字按非字母数字分段（api-key → {api, key}；keystone → {keystone}），
 * 任一段命中 pred 即真。此前 agentaudit 的 isMaskedName 与
 * agent_subprocess 的 isSensitiveEnvName 各写一份同构循环——两者是
 * 「命令回执遮蔽」与「环境清洗/宿主抹除」两条防线的判据，切词法漂移
 * 就是一个遮了另一个没遮。 */
template <typename Pred>
bool anyWordOf(const std::string& name, Pred pred) {
	std::size_t i = 0;
	while (i < name.size()) {
		if (!std::isalnum(static_cast<unsigned char>(name[i]))) { ++i; continue; }
		std::size_t j = i;
		while (j < name.size() && std::isalnum(static_cast<unsigned char>(name[j]))) { ++j; }
		if (pred(name.substr(i, j - i))) { return true; }
		i = j;
	}
	return false;
}

inline std::string trim(const std::string& s) {
	std::size_t b = 0, e = s.size();
	while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
	while (e > b && (s[e-1] == ' ' || s[e-1] == '\t' || s[e-1] == '\r' || s[e-1] == '\n')) --e;
	return s.substr(b, e - b);
}

/* ---- 名字列表拼接（单点，2026-10-01）----
 * 「（a, b, c）」式点名在热插摘要 / 热删除失败成因 / --read-var 跳过提示
 * 等多处手写同构循环（for + i>0 补分隔符）——分隔符口径漂移就是文案
 * 不一致。默认 ", "；热删除成因列表用 "; "。 */
inline std::string joinNames(const std::vector<std::string>& names, const char* sep = ", ") {
	std::string out;
	for (std::size_t i = 0; i < names.size(); ++i) {
		if (i > 0) { out += sep; }
		out += names[i];
	}
	return out;
}

/* ---- 报错回显：用户可控原文的转义 + 截断（单点）----
 * 2026-09-20 审计 C4：把用户可控字节原样拼进 stderr 有两个问题——
 *   ① 体积：一条报错可把「脚本 8 MiB 上限」量级的字节灌进日志（实测矩阵单元格
 *      20 万字节 → stderr 200KB；`--tcp` 远端脚本可达）；
 *   ② 控制字符直写操作者终端：ANSI 转义可改色、移光标、伪造输出。
 * 表达式报错（expr.cpp）此前已按 80 字符截断，但矩阵单元格报错
 * （hardware.cpp 的 parseMtDouble）漏了同一条防线 —— 同一类缺陷、同一份承诺、
 * 两条路径只有一条落地。收敛到本单点后两条路径共用同一判据与文案形态。
 * 不可打印字节（<0x20 或 0x7f）转成 \xNN 可见形式，再按**输入**长度截断并补
 * 省略标记：截断口径与旧的 `substr(0,80) + "..."` 逐字一致，只多出转义。 */
inline constexpr std::size_t kMaxEchoChars = 80;

inline std::string echoSource(const std::string& s) {
	const std::size_t n = s.size() < kMaxEchoChars ? s.size() : kMaxEchoChars;
	std::string out;
	out.reserve(n);
	static const char kHex[] = "0123456789abcdef";
	for (std::size_t i = 0; i < n; ++i) {
		const unsigned char c = static_cast<unsigned char>(s[i]);
		if (c < 0x20 || c == 0x7f) {
			out += "\\x";
			out += kHex[c >> 4];
			out += kHex[c & 0x0f];
		} else {
			out += static_cast<char>(c);
		}
	}
	if (s.size() > kMaxEchoChars) { out += "..."; }
	return out;
}

/* ---- 日志标记转义（2026-09-22 安全改进；C7 自 agentloop 匿名命名空间挪出）----
 * 工具的返回文本会整块进 verbose 日志，而它可能含 `[FAIL]` / `[PASS]` 这类
 * 行首标记——下游按行解析日志的东西（测试汇总、CI 日志抓取）会把工具输出当成
 * 真的判定行读走。这里只转义**行首**的 `[`，其余位置的方括号原样保留（JSON
 * 数组、`a[0]` 之类的正常内容不该被改写）。 */
inline std::string escapeLogMarkers(const std::string& s) {
	std::string out;
	bool atLineStart = true;
	for (std::size_t i = 0; i < s.size(); ++i) {
		char c = s[i];
		if (atLineStart && c == '[') {
			out += "\\[";	/* 转义行首方括号 */
		} else {
			out += c;
		}
		atLineStart = (c == '\n');
	}
	return out;
}

} // namespace bot

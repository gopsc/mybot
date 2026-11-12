#pragma once
/* util_utf8.hpp —— UTF-8 合法性判据 + 消毒（自 util.hpp 拆出，2026-09-26 批次 3）
 * 单点判据按 RFC 3629；只有要把磁盘/子进程字节送进模型上下文或 JSON 的 TU 才需要它。 */

#include <cstddef>
#include <string>

namespace bot {

/* ---- UTF-8 合法性判据 + 消毒（2026-09-21 审计 AG-1 单点）----
 * 为什么必须做：JSON 的字符串**只允许合法 UTF-8**，而请求体里的 `0x80-0xFF`
 * 由两端的编码器原样透传（C++ 侧 Json::toString 与 Lua 侧 modules/lib/json.lua
 * 的 encode_string 都只转义 <0x20、引号与反斜杠，这是「合法多字节 UTF-8 原样
 * 透传」所必需的）。于是**只要有任何一处把非法字节放进消息文本**，请求体就是
 * 一段非法 UTF-8，严格校验的网关（Python/Node 技术栈的绝大多数）直接
 * HTTP 400，而那条消息已经落在历史里、不再属于可回滚的尾部——REPL 会话从此
 * 每次都以同一个字节偏移失败。
 * 非法字节的真实来源不是攻击，是日常：`run_command` 的 stdout/stderr（cat 到
 * 二进制文件、Latin-1 文件名的 ls、非 UTF-8 locale 的日志）、动作脚本首行注释、
 * 结构脚本头。实测（2026-09-21）三条来源都能让第一次请求就 400。
 *
 * 判据按 RFC 3629：拒绝过长编码（C0/C1 开头）、拒绝 UTF-16 代理区
 * （ED A0..BF）、拒绝 > U+10FFFF（F4 90.. 与 F5..FF）。比对严格网关的解码器
 * 更紧：这些序列在 Python/Node 的严格解码下同样非法。 */
struct Utf8Step {
	unsigned len;	/* 合法序列的字节数；0 = 非法 */
	unsigned cp;	/* 已解码码点（仅 len>0 有意义） */
};

inline Utf8Step utf8DecodeAt(const std::string& s, std::size_t i) {
	const unsigned char c0 = static_cast<unsigned char>(s[i]);
	if (c0 < 0x80) { return {1, c0}; }

	/* 首字节 → 续字节数与解码出的**首段**值（用最小合法首字节取值） */
	unsigned need = 0;
	unsigned cp = 0;
	if (c0 >= 0xc2 && c0 <= 0xdf) {
		need = 1;
		cp = c0 & 0x1fu;
	} else if (c0 >= 0xe0 && c0 <= 0xef) {
		need = 2;
		cp = c0 & 0x0fu;
	} else if (c0 >= 0xf0 && c0 <= 0xf4) {
		need = 3;
		cp = c0 & 0x07u;
	} else {
		return {0, 0};	/* 0x80-0xC1（孤立续字节/过长编码首字节）、0xF5-0xFF */
	}
	if (i + need >= s.size()) { return {0, 0}; }	/* 续字节越过末尾：序列被截断 */

	for (unsigned k = 1; k <= need; ++k) {
		const unsigned char c = static_cast<unsigned char>(s[i + k]);
		if ((c & 0xc0u) != 0x80u) { return {0, 0}; }	/* 续字节必须是 10xxxxxx */
		cp = (cp << 6) | (c & 0x3fu);
	}
	/* 过长编码：解码值必须落在该长度对应的最小码点之上 */
	if (need == 2 && cp < 0x800u) { return {0, 0}; }
	if (need == 3 && cp < 0x10000u) { return {0, 0}; }
	if (cp >= 0xd800u && cp <= 0xdfffu) { return {0, 0}; }	/* UTF-16 代理区 */
	if (cp > 0x10ffffu) { return {0, 0}; }
	return {need + 1, cp};
}

inline bool isValidUtf8(const std::string& s) {
	for (std::size_t i = 0; i < s.size();) {
		const Utf8Step st = utf8DecodeAt(s, i);
		if (st.len == 0) { return false; }
		i += st.len;
	}
	return true;
}

inline constexpr const char* kInvalidUtf8Marker = "[! invalid UTF-8 bytes omitted";

/* 消毒：把非法序列替换成 U+FFFD（EF BF BD），保持合法前缀逐字节不变。
 * 连续非法字节折叠成**一个** U+FFFD 并计数——64 个连续坏字节最多产出
 * 「1 个 U+FFFD + 一句说明」，而不是 64 个替换符。折叠是安全的：消毒只发生在
 * 「数据进入模型上下文」的边界，那些字节本就是无法解读的噪声，不是要保真的内容。
 * 热路径（run_command 输出）也必须过这一关：漏一处就等于没做。 */
inline std::string sanitizeUtf8(const std::string& s) {
	std::string out;
	out.reserve(s.size());
	std::size_t i = 0;
	while (i < s.size()) {
		const Utf8Step st = utf8DecodeAt(s, i);
		if (st.len > 0) {
			out.append(s, i, st.len);
			i += st.len;
			continue;
		}
		std::size_t run = 0;
		while (i < s.size() && utf8DecodeAt(s, i).len == 0) {
			++i;
			++run;
		}
		out += "\xef\xbf\xbd";
		if (run > 1) {
			out += kInvalidUtf8Marker;
			out += std::to_string(run);
			out += " bytes]";
		}
	}
	return out;
}

} // namespace bot

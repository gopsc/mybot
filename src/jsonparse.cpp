#include "jsonparse.hpp"

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>

#include "util_except.hpp"
#include "util_num.hpp"

namespace bot {

namespace {

/* 递归下降解析器。状态只有「输入 + 游标」，失败一律抛
 * IllegalArgumentException（带偏移）——调用方对「模型返回了坏 JSON」
 * 的统一处理就是把它折成可读报错，不需要区分失败子类。 */
class Parser {
	const std::string& s_;
	std::size_t pos_ = 0;

	[[noreturn]] void fail(const std::string& what) const {
		throw IllegalArgumentException("JSON parse error at offset " + std::to_string(pos_)
			+ ": " + what);
	}

	bool eof() const { return pos_ >= s_.size(); }

	void skipWs() {
		while (pos_ < s_.size()) {
			char c = s_[pos_];
			if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { ++pos_; }
			else { break; }
		}
	}

	char peek() const { return pos_ < s_.size() ? s_[pos_] : '\0'; }

	bool consume(char c) {
		if (peek() == c) { ++pos_; return true; }
		return false;
	}

	void expect(char c) {
		if (!consume(c)) { fail(std::string("expected '") + c + "'"); }
	}

	bool consumeLiteral(const char* lit) {
		std::size_t n = std::strlen(lit);
		if (s_.compare(pos_, n, lit) == 0) { pos_ += n; return true; }
		return false;
	}

	static bool isDigit(char c) { return c >= '0' && c <= '9'; }

	/* \uXXXX 的 4 位十六进制 */
	std::uint32_t parseHex4() {
		std::uint32_t v = 0;
		for (int k = 0; k < 4; ++k) {
			if (eof()) { fail("truncated \\u escape"); }
			char c = s_[pos_++];
			std::uint32_t d;
			if (c >= '0' && c <= '9') { d = static_cast<std::uint32_t>(c - '0'); }
			else if (c >= 'a' && c <= 'f') { d = static_cast<std::uint32_t>(c - 'a' + 10); }
			else if (c >= 'A' && c <= 'F') { d = static_cast<std::uint32_t>(c - 'A' + 10); }
			else { fail("invalid hex digit in \\u escape"); }
			v = (v << 4) | d;
		}
		return v;
	}

	static void encodeUtf8(std::uint32_t cp, std::string& out) {
		if (cp <= 0x7F) {
			out.push_back(static_cast<char>(cp));
		} else if (cp <= 0x7FF) {
			out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else if (cp <= 0xFFFF) {
			out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else {
			out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		}
	}

	std::string parseString() {
		expect('"');
		std::string out;
		for (;;) {
			if (eof()) { fail("unterminated string"); }
			unsigned char c = static_cast<unsigned char>(s_[pos_++]);
			if (c == '"') { return out; }
			if (c == '\\') {
				if (eof()) { fail("unterminated escape"); }
				char e = s_[pos_++];
				switch (e) {
				case '"': out.push_back('"'); break;
				case '\\': out.push_back('\\'); break;
				case '/': out.push_back('/'); break;
				case 'b': out.push_back('\b'); break;
				case 'f': out.push_back('\f'); break;
				case 'n': out.push_back('\n'); break;
				case 'r': out.push_back('\r'); break;
				case 't': out.push_back('\t'); break;
				case 'u': {
					std::uint32_t cp = parseHex4();
					if (cp >= 0xD800 && cp <= 0xDBFF) {
						/* 高代理：必须紧跟低代理，否则是坏码点 */
						if (!consume('\\')) { fail("lone high surrogate"); }
						if (!consume('u')) { fail("lone high surrogate"); }
						std::uint32_t lo = parseHex4();
						if (lo < 0xDC00 || lo > 0xDFFF) { fail("invalid low surrogate"); }
						cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
					} else if (cp >= 0xDC00 && cp <= 0xDFFF) {
						fail("lone low surrogate");
					}
					encodeUtf8(cp, out);
					break;
				}
				default: fail("invalid escape");
				}
				continue;
			}
			/* JSON 规定控制字符必须转义：原样出现的 <0x20 一律拒绝
			 * （否则解析成功、下游拿到夹带换行的字段，问题被推迟到更远处） */
			if (c < 0x20) { fail("unescaped control character in string"); }
			out.push_back(static_cast<char>(c));
		}
	}

	Json parseNumber() {
		std::size_t start = pos_;
		consume('-');
		if (eof()) { fail("invalid number"); }
		if (peek() == '0') {
			++pos_;
		} else if (isDigit(peek())) {
			while (isDigit(peek())) { ++pos_; }
		} else {
			fail("invalid number");
		}
		bool isFloat = false;
		if (peek() == '.') {
			isFloat = true;
			++pos_;
			if (!isDigit(peek())) { fail("invalid fraction"); }
			while (isDigit(peek())) { ++pos_; }
		}
		if (peek() == 'e' || peek() == 'E') {
			isFloat = true;
			++pos_;
			if (peek() == '+' || peek() == '-') { ++pos_; }
			if (!isDigit(peek())) { fail("invalid exponent"); }
			while (isDigit(peek())) { ++pos_; }
		}
		std::string text = s_.substr(start, pos_ - start);
		if (!isFloat) {
			errno = 0;
			char* end = nullptr;
			long long v = std::strtoll(text.c_str(), &end, 10);
			if (errno == 0 && end != nullptr && *end == '\0') { return JsonInt(v); }
			/* 整数溢出：回落 Float，比整串响应失败更有用（调用方只读小整数） */
		}
		/* M2/B2-2：判据收敛到 parseFiniteDouble；ERANGE（上溢到下溢的越界）
		 * 单独保留——JSON 数字越界的报错口径原就独立于「没消费干净/非有限」。 */
		errno = 0;
		double d = 0.0;
		ParseFiniteStatus st = parseFiniteDouble(text, d);
		if (errno == ERANGE
				|| st == ParseFiniteStatus::INVALID || st == ParseFiniteStatus::NONFINITE) {
			fail("number out of range");
		}
		return JsonFloat(d);
	}

	Json parseObject(int depth) {
		expect('{');
		Json obj = JsonObject();
		skipWs();
		if (consume('}')) { return obj; }
		for (;;) {
			skipWs();
			if (peek() != '"') { fail("expected object key string"); }
			std::string key = parseString();
			skipWs();
			expect(':');
			skipWs();
			/* 同名键：后者覆盖（Json::put 语义），与多数 JSON 实现一致 */
			obj.put(key, parseValue(depth + 1));
			skipWs();
			if (consume(',')) { continue; }
			expect('}');
			return obj;
		}
	}

	Json parseArray(int depth) {
		expect('[');
		Json arr = JsonArray();
		skipWs();
		if (consume(']')) { return arr; }
		for (;;) {
			skipWs();
			arr.add(parseValue(depth + 1));
			skipWs();
			if (consume(',')) { continue; }
			expect(']');
			return arr;
		}
	}

public:
	explicit Parser(const std::string& s) : s_(s) {}

	Json parseValue(int depth = 0) {
		if (depth > kJsonMaxDepth) { fail("nesting too deep"); }
		skipWs();
		if (eof()) { fail("unexpected end of input"); }
		char c = peek();
		switch (c) {
		case '{': return parseObject(depth);
		case '[': return parseArray(depth);
		case '"': return JsonString(parseString());
		case 't':
			if (consumeLiteral("true")) { return JsonBool(true); }
			fail("invalid literal");
		case 'f':
			if (consumeLiteral("false")) { return JsonBool(false); }
			fail("invalid literal");
		case 'n':
			if (consumeLiteral("null")) { return JsonNull(); }
			fail("invalid literal");
		default:
			if (c == '-' || isDigit(c)) { return parseNumber(); }
			fail("unexpected character");
		}
	}

	void finish() {
		skipWs();
		if (!eof()) { fail("trailing characters after top-level value"); }
	}
};

} // namespace

Json parseJson(const std::string& text) {
	if (text.size() > kJsonMaxBytes) {
		throw IllegalArgumentException("JSON input exceeds the byte limit of "
			+ std::to_string(kJsonMaxBytes) + ".");
	}
	Parser p(text);
	Json v = p.parseValue();
	p.finish();
	return v;
}

} // namespace bot

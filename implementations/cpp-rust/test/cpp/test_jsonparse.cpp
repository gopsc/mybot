#include "harness.hpp"

#include <cstdint>
#include <cstdio>
#include <string>

#include "jsonparse.hpp"
#include "util_except.hpp"

using namespace bot;

TH_TEST(jsonparse_scalars) {
	TH_CHECK(parseJson("null").isNull());
	TH_CHECK(parseJson(" true ").isBool());
	TH_CHECK(parseJson("true").getBool());
	TH_CHECK(!parseJson("false").getBool());
	TH_CHECK(parseJson("42").isInt());
	TH_CHECK(parseJson("42").getInt() == 42);
	TH_CHECK(parseJson("-7").getInt() == -7);
	TH_CHECK(parseJson("9223372036854775807").isInt());
	TH_CHECK(parseJson("0").isInt());
	TH_CHECK(parseJson("3.5").isFloat());
	TH_CHECK(parseJson("3.5").getFloat() == 3.5);
	TH_CHECK(parseJson("1e3").getFloat() == 1000.0);
	TH_CHECK(parseJson("1.5E-2").getFloat() == 0.015);
	TH_CHECK(parseJson("\"hi\"").isStr());
	TH_CHECK(parseJson("\"hi\"").getValue() == "hi");
}

TH_TEST(jsonparse_containers) {
	Json v = parseJson("{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{\"d\":2.5}}");
	TH_CHECK(v.isObj());
	TH_CHECK(v.objSize() == 3);
	TH_CHECK(v.get("a")->getInt() == 1);
	TH_CHECK(v.get("b")->isArr());
	TH_CHECK(v.get("b")->size() == 3);
	TH_CHECK(v.get("b")->at(0).getBool());
	TH_CHECK(v.get("b")->at(1).isNull());
	TH_CHECK(v.get("b")->at(2).getValue() == "x");
	TH_CHECK(v.get("c")->get("d")->getFloat() == 2.5);
	/* 字段序保持输入序（与 Json 的 put/items 语义一致） */
	TH_CHECK(v.items()[0].first == "a");
	TH_CHECK(v.items()[2].first == "c");
	/* 空容器 */
	TH_CHECK(parseJson("{}").isObj() && parseJson("{}").objSize() == 0);
	TH_CHECK(parseJson("[]").isArr() && parseJson("[]").size() == 0);
}

TH_TEST(jsonparse_string_escapes) {
	TH_CHECK(parseJson("\"a\\nb\\t\\\"c\\\\d\\/\"").getValue() == "a\nb\t\"c\\d/");
	TH_CHECK(parseJson("\"\\u0041\"").getValue() == "A");
	/* BMP 码点 → UTF-8 */
	TH_CHECK(parseJson("\"\\u4e2d\"").getValue() == "\u4e2d");
	/* 代理对 → 4 字节 UTF-8（U+1F600） */
	TH_CHECK(parseJson("\"\\ud83d\\ude00\"").getValue() == "\U0001F600");
	/* 原样 UTF-8 透传 */
	TH_CHECK(parseJson("\"\u673a\u5668\u4eba\"").getValue() == "\u673a\u5668\u4eba");
}

TH_TEST(jsonparse_rejects_malformed) {
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "offset", parseJson(""));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "trailing", parseJson("{\"a\":1}garbage"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "unterminated string", parseJson("\"abc"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "invalid escape", parseJson("\"a\\qb\""));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "lone high surrogate",
		parseJson("\"\\ud83d\""));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "lone low surrogate",
		parseJson("\"\\ude00\""));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "control character",
		parseJson("\"a\nb\""));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "trailing", parseJson("01"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "unexpected", parseJson("+1"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "unexpected", parseJson(".5"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "invalid fraction", parseJson("1."));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "unexpected", parseJson("NaN"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "expected object key", parseJson("{1:2}"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "expected ':'", parseJson("{\"a\" 1}"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "expected ']'", parseJson("[1 2]"));
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "unexpected end", parseJson("{\"a\":"));
}

TH_TEST(jsonparse_number_overflow_falls_back_to_float) {
	/* 超出 int64 的整数字面量：回落 Float 而不是让整串响应失败
	 * （调用方只读小整数，报错反而是更差的选择） */
	Json v = parseJson("12345678901234567890123");
	TH_CHECK(v.isFloat());
	TH_CHECK(v.getFloat() > 1e22);
}

TH_TEST(jsonparse_depth_limit) {
	std::string deep;
	for (int i = 0; i < 70; ++i) { deep += "["; }
	for (int i = 0; i < 70; ++i) { deep += "]"; }
	TH_CHECK_THROWS_MSG(IllegalArgumentException, "nesting too deep", parseJson(deep));

	/* 上限之下照常可解 */
	std::string ok;
	for (int i = 0; i < 40; ++i) { ok += "["; }
	ok += "1";
	for (int i = 0; i < 40; ++i) { ok += "]"; }
	TH_CHECK(parseJson(ok).isArr());
}

TH_TEST(jsonparse_rejects_over_max_bytes) {
	/* 上限在解析前检查：8MiB+1 的输入即拒，不产生解析开销 */
	std::string big(bot::kJsonMaxBytes + 1, ' ');
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeds the byte limit",
		bot::parseJson(big));
}


/* ======================================================================
 * 属性测试：JSON 往返稳定性（F3-6，2026-09-21）
 *
 * 固定种子的伪随机生成器造结构化 JSON 文本 → parseJson → toString → 再 parse，
 * 断言①再解析得到的**值与原来结构相等**（逐类型逐字段比，不用文本代理），
 * ②两次编码逐字相同（编码幂等）。价值不在覆盖某条分支，而在同时压住
 * 解析器与序列化器：任一侧在某形态上漂移（转义、数字格式、对象键序、嵌套、
 * 空容器、数组内 null），稳定性立刻被打破——这是单元用例各自为政时最容易漏的
 * 那一类漂移。生成器自实现（零第三方依赖）、种子写死（失败可复现）、轮数固定
 * （守门时长可控）。
 * ====================================================================== */
namespace {

/* 线性同余（Knuth MMIX 常数），只用高位——足够造形态多样且可复现的输入 */
struct PropRng {
	std::uint64_t s;
	explicit PropRng(std::uint64_t seed) : s(seed) {}
	std::uint32_t next() {
		s = s * 6364136223846793005ULL + 1442695040888963407ULL;
		return static_cast<std::uint32_t>(s >> 33);
	}
	std::uint32_t below(std::uint32_t n) { return next() % n; }
	bool chance(std::uint32_t pct) { return below(100) < pct; }
};

/* 字符串片段：覆盖转义族与 UTF-8 原字节（toString 允许原样输出多字节） */
void genString(PropRng& rng, std::string& out) {
	static const char* const kFrag[] = {
		"a", "Z9", " ", "\\\"", "\\\\", "\\n", "\\t", "\\r",
		"\\u00e9", "é", "/", "\\/", "\\b", "\\f",
	};
	out += '"';
	const std::uint32_t n = 1 + rng.below(6);
	for (std::uint32_t i = 0; i < n; ++i) { out += kFrag[rng.below(sizeof(kFrag) / sizeof(kFrag[0]))]; }
	out += '"';
}

void genValue(PropRng& rng, std::string& out, int depth) {
	/* 到第 4 层后只出叶子：既压嵌套，又不让文本体积指数膨胀 */
	const std::uint32_t pick = rng.below(depth >= 4 ? 7 : 10);
	switch (pick) {
	case 0: out += "null"; return;
	case 1: out += rng.chance(50) ? "true" : "false"; return;
	case 2: out += std::to_string(static_cast<long long>(rng.below(2000000)) - 1000000); return;
	case 3: {
		char buf[32];
		std::snprintf(buf, sizeof(buf), "%u.%u", rng.below(1000), rng.below(1000));
		out += buf; return;
	}
	case 4: {
		char buf[32];
		std::snprintf(buf, sizeof(buf), "%ue%d", 1 + static_cast<int>(rng.below(9)),
			static_cast<int>(rng.below(12)) - 6);
		out += buf; return;
	}
	case 5: {
		/* 高精度小数（17 位有效数字）：专压「编码丢精度」这一类漂移——
		 * 短小数即使编码精度被调低也照样自洽，只有长尾数字才暴露得出 */
		char buf[64];
		std::snprintf(buf, sizeof(buf), "%llu.%016llu",
			static_cast<unsigned long long>(rng.below(1000)),
			static_cast<unsigned long long>(rng.next()) * 1000000ULL
				+ static_cast<unsigned long long>(rng.below(1000000)));
		out += buf;
		return;
	}
	case 6: genString(rng, out); return;
	case 7: case 8: {				/* 数组（元素可为 null：toString 支持） */
		out += '[';
		const std::uint32_t n = rng.below(4);
		for (std::uint32_t i = 0; i < n; ++i) { if (i) { out += ','; } genValue(rng, out, depth + 1); }
		out += ']';
		return;
	}
	default: {						/* 对象（键按序号唯一，避免重复键语义） */
		out += '{';
		const std::uint32_t n = rng.below(4);
		for (std::uint32_t i = 0; i < n; ++i) {
			if (i) { out += ','; }
			out += "\"k" + std::to_string(i) + "\":";
			genValue(rng, out, depth + 1);
		}
		out += '}';
		return;
	}
	}
}

/* 结构化相等：逐类型逐字段比，不用 toString 代理——文本稳定不等于**值**没变
 * （精度变粗的实现照样自洽，却会静默丢数据）。数值只在同类型间比：
 * Int 与 Float 视为不同（`1` 与 `1.0` 的往返形态本就不同）。 */
bool sameJson(const Json& a, const Json& b) {
	if (a.isNull() || b.isNull()) { return a.isNull() && b.isNull(); }
	if (a.isBool() || b.isBool()) { return a.isBool() && b.isBool() && a.getBool() == b.getBool(); }
	if (a.isInt() || b.isInt()) { return a.isInt() && b.isInt() && a.getInt() == b.getInt(); }
	if (a.isFloat() || b.isFloat()) {
		return a.isFloat() && b.isFloat() && a.getFloat() == b.getFloat();
	}
	if (a.isStr() || b.isStr()) {
		return a.isStr() && b.isStr() && a.getValue() == b.getValue();
	}
	if (a.isArr() || b.isArr()) {
		if (!a.isArr() || !b.isArr() || a.size() != b.size()) { return false; }
		for (std::size_t i = 0; i < a.size(); ++i) {
			if (!sameJson(a.at(i), b.at(i))) { return false; }
		}
		return true;
	}
	if (a.objSize() != b.objSize()) { return false; }
	for (std::size_t i = 0; i < a.items().size(); ++i) {
		if (a.items()[i].first != b.items()[i].first
			|| !sameJson(a.items()[i].second, b.items()[i].second)) {
			return false;
		}
	}
	return true;
}

} // namespace

TH_TEST(jsonparse_roundtrip_property_preserves_value) {
	PropRng rng(20260921ULL);	/* 种子写死：失败可复现 */
	const int kRounds = 300;
	int checked = 0;
	for (int i = 0; i < kRounds; ++i) {
		std::string text;
		genValue(rng, text, 0);
		Json a = JsonNull();
		try {
			a = parseJson(text);
		} catch (const std::exception& e) {
			TH_CHECK_MSG(false, "生成的文本必须可解析: " + text + " -> " + e.what());
			return;
		}
		const std::string once = a.toString();
		Json b = JsonNull();
		try {
			b = parseJson(once);
		} catch (const std::exception& e) {
			TH_CHECK_MSG(false, "编码结果必须可再解析: " + once + " -> " + e.what());
			return;
		}
		if (!sameJson(a, b)) {
			TH_CHECK_MSG(false, "往返丢值: " + text + " -> " + once + " -> " + b.toString());
			return;
		}
		if (once != b.toString()) {		/* 编码本身也应稳定（幂等） */
			TH_CHECK_MSG(false, "编码不幂等: " + text + " -> " + once + " -> " + b.toString());
			return;
		}
		++checked;
	}
	TH_CHECK_MSG(checked == kRounds, "完成轮数 " + std::to_string(checked));
}

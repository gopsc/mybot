/* test_util.cpp —— util_*.hpp 全局助手的直接锚点（重构计划 1）
 *
 * 此前 util.hpp 的函数只靠调用方间接覆盖。本轮重复收敛（阶段 1）落进来的
 * 几个助手是全局判据/防线，值得有直接单测钉住契约：
 *   1) isSafeIdent：注入名防线（合成 SQL + modules/<表名>.lua 解析）的判据单点
 *   2) DepthLimitGuard：超限抛且不计数、未超限计数对称、nullptr 只计数
 *   3) rangeErrorText：越界文案模板（CLI 与配置文件两路共用）
 *   4) cli::parseKeyValue：--k=v / --k v / 裸 --k 切分与 strictLookahead 两语义
 *   5) readFileCapped：受限读取单点的策略语义（Reject 超限即失败 / Truncate 截断
 *      正常返回）与软链判据（followSymlinks 开关决定是否带 O_NOFOLLOW）
 */

#include <algorithm>
#include <fstream>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "util_cli.hpp"
#include "util_except.hpp"
#include "util_file.hpp"
#include "util_num.hpp"
#include "util_str.hpp"
#include "util_utf8.hpp"

namespace {

void writeText(const std::filesystem::path& p, const std::string& text) {
	std::ofstream f(p, std::ios::binary);
	f << text;
}

} // namespace

/* ---- isSafeIdent：agentmode 预检与 RobotStruct::injectLuaDriver 共用 ---- */

TH_TEST(utils_is_safe_ident_accepts_plain_identifiers) {
	TH_CHECK(bot::isSafeIdent("LlmOpenAI"));
	TH_CHECK(bot::isSafeIdent("llm0"));
	TH_CHECK(bot::isSafeIdent("_private"));
	TH_CHECK(bot::isSafeIdent("a"));		/* 单字符 */
	TH_CHECK(bot::isSafeIdent("a_1"));
}

TH_TEST(utils_is_safe_ident_rejects_injection_shapes) {
	TH_CHECK(!bot::isSafeIdent(""));			/* 空 */
	TH_CHECK(!bot::isSafeIdent("1abc"));		/* 首字符数字 */
	TH_CHECK(!bot::isSafeIdent("a-b"));		/* 连字符 */
	TH_CHECK(!bot::isSafeIdent("a b"));		/* 空格 */
	TH_CHECK(!bot::isSafeIdent("Llm; DROP"));	/* 合成 SQL 注入形态 */
	TH_CHECK(!bot::isSafeIdent("x'y"));		/* 引号 */
	TH_CHECK(!bot::isSafeIdent("a.b"));		/* 点（表名按 modules/<表名>.lua 解析） */
}

/* ---- DepthLimitGuard：检查+计数合一（1-B2）---- */

TH_TEST(utils_depth_limit_guard_counts_symmetrically_under_limit) {
	int depth = 0;
	constexpr int kLimit = 2;
	{
		bot::DepthLimitGuard g(depth, &kLimit, [] { return std::string(); });
		TH_CHECK(depth == 1);
		{
			bot::DepthLimitGuard g2(depth, &kLimit, [] { return std::string(); });
			TH_CHECK(depth == 2);
		}
		TH_CHECK(depth == 1);	/* 析构对称 */
	}
	TH_CHECK(depth == 0);
}

TH_TEST(utils_depth_limit_guard_throws_without_counting_at_limit) {
	int depth = 0;
	constexpr int kLimit = 2;
	depth = kLimit;		/* 已达上限：再进一层即判环 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "circular chain", [&] {
		bot::DepthLimitGuard g(depth, &kLimit,
			[] { return std::string("circular chain detected (limit 2)"); });
		(void)g;
	}());
	TH_CHECK(depth == kLimit);	/* 抛前未 ++（构造失败不跑析构，计数不脏） */
	/* limit = nullptr：只计数不设限（destroy 收集路径语义） */
	{
		bot::DepthLimitGuard g(depth, nullptr, [] { return std::string(); });
		TH_CHECK(depth == kLimit + 1);
	}
	TH_CHECK(depth == kLimit);
}

/* ---- rangeErrorText：越界文案模板（1-B3）---- */

TH_TEST(utils_range_error_text_formats_subject_and_range) {
	TH_CHECK(bot::rangeErrorText("选项 --llm-timeout", 1, 600, "900")
		== "选项 --llm-timeout 需要在 [1, 600] 范围内，实际是 900");
	TH_CHECK(bot::rangeErrorText("配置文件 c 的字段 'timeout'", 1, 600, "1e+300")
		== "配置文件 c 的字段 'timeout' 需要在 [1, 600] 范围内，实际是 1e+300");
}

/* ---- cli::parseKeyValue：argv 选项切分单点（第 10 项）---- */

TH_TEST(utils_cli_parse_key_value_inline_form) {
	char a0[] = "--key=value";
	char* argv[] = {a0};
	int k = 0;
	auto tok = bot::cli::parseKeyValue(k, 1, argv, true);
	TH_CHECK(tok.key == "key");
	TH_CHECK(tok.value == "value");
	TH_CHECK(tok.hasValue);
	TH_CHECK(k == 0);		/* 内联值不消费下一参数 */
}

TH_TEST(utils_cli_parse_key_value_consumes_next_arg) {
	char a0[] = "--out";
	char a1[] = "merged.mt";
	char* argv[] = {a0, a1};
	int k = 0;
	auto tok = bot::cli::parseKeyValue(k, 2, argv, true);
	TH_CHECK(tok.key == "out");
	TH_CHECK(tok.value == "merged.mt");
	TH_CHECK(tok.hasValue);
	TH_CHECK(k == 1);		/* 消费了下一参数 */
}

TH_TEST(utils_cli_parse_key_value_strict_lookahead_rejects_flag_as_value) {
	char a0[] = "--tcp";
	char a1[] = "--tcp-host";
	char* argv[] = {a0, a1};
	/* strict（mybot CLI，审计中-3）：下一参数以 -- 开头不算值 */
	int k = 0;
	auto tok = bot::cli::parseKeyValue(k, 2, argv, true);
	TH_CHECK(tok.key == "tcp");
	TH_CHECK(!tok.hasValue);
	TH_CHECK(k == 0);		/* 不吞 flag */
	/* lenient（mtmerge takeVal 原语义）：只要存在即消费 */
	int k2 = 0;
	auto tok2 = bot::cli::parseKeyValue(k2, 2, argv, false);
	TH_CHECK(tok2.hasValue);
	TH_CHECK(tok2.value == "--tcp-host");
	TH_CHECK(k2 == 1);
}

TH_TEST(utils_cli_parse_key_value_bare_flag_at_end) {
	char a0[] = "--agent";
	char* argv[] = {a0};
	int k = 0;
	auto tok = bot::cli::parseKeyValue(k, 1, argv, true);
	TH_CHECK(tok.key == "agent");
	TH_CHECK(!tok.hasValue);
	TH_CHECK(tok.value.empty());
	TH_CHECK(k == 0);
}

/* ==================== EINTR 重试单点（2026-09-20 重构阶段 0/4.2）====================
 * main.cpp 安装信号处理器时明确不用 SA_RESTART，故 EINTR 是本项目的常态。
 * 契约：retryEintr 只在 errno==EINTR 且返回 -1 时重试，其余结果（含其它 errno
 * 的 -1、0、正值）原样返回，且重试不吞掉调用次数。 */
TH_TEST(retry_eintr_retries_only_on_eintr) {
	int calls = 0;
	int r = bot::retryEintr([&]() -> int {
		++calls;
		if (calls < 3) { errno = EINTR; return -1; }
		return 7;
	});
	TH_CHECK(r == 7);
	TH_CHECK(calls == 3);
}

TH_TEST(retry_eintr_passes_through_other_errors) {
	int calls = 0;
	int r = bot::retryEintr([&]() -> int {
		++calls;
		errno = EAGAIN;
		return -1;
	});
	TH_CHECK(r == -1);
	TH_CHECK(calls == 1);
	TH_CHECK(errno == EAGAIN);
}

TH_TEST(retry_eintr_passes_through_zero_and_positive) {
	int calls = 0;
	TH_CHECK(bot::retryEintr([&]() -> long { ++calls; return 0; }) == 0);
	TH_CHECK(bot::retryEintr([&]() -> long { ++calls; return 42; }) == 42);
	TH_CHECK(calls == 2);
}

/* ---------------- C4：报错回显的转义 + 截断（echoSource 单点） ---------------- */

TH_TEST(echo_source_keeps_a_short_printable_string_verbatim) {
	TH_CHECK(bot::echoSource("abc") == "abc");
	TH_CHECK(bot::echoSource("") == "");
}

TH_TEST(echo_source_truncates_at_the_cap_with_an_ellipsis) {
	const std::string s(bot::kMaxEchoChars + 10, 'A');
	const std::string out = bot::echoSource(s);
	TH_CHECK(out.size() == bot::kMaxEchoChars + 3);
	TH_CHECK(out.compare(0, bot::kMaxEchoChars, std::string(bot::kMaxEchoChars, 'A')) == 0);
	TH_CHECK(out.compare(bot::kMaxEchoChars, 3, "...") == 0);
	/* 恰好到上限时不加省略标记（与旧 substr 口径一致） */
	TH_CHECK(bot::echoSource(std::string(bot::kMaxEchoChars, 'A')).size() == bot::kMaxEchoChars);
}

TH_TEST(echo_source_escapes_control_bytes_instead_of_writing_them) {
	/* ANSI 转义序列不得原样进入 stderr（终端注入面） */
	const std::string esc = "\x1b[31mred\x1b[0m";
	const std::string out = bot::echoSource(esc);
	TH_CHECK(out.find('\x1b') == std::string::npos);
	TH_CHECK(out.find("\\x1b[31mred\\x1b[0m") != std::string::npos);

	/* 其它控制字节与 DEL 同样转义；可打印内容逐字保留 */
	const std::string mixed("a\0b\tc\x7f", 6);
	TH_CHECK(bot::echoSource(mixed) == "a\\x00b\\x09c\\x7f");
}

/* ---- readFileCapped：受限读取单点（B2-3 余部）----
 * 四份实现收敛成一份后，超限语义由 CapPolicy 显式声明。这里钉住两种策略的
 * 分界（Reject 探测 1 字节即失败 / Truncate 读满即停且正常返回）与软链判据
 * （followSymlinks 决定是否带 O_NOFOLLOW）——它们正是原 readHead 与
 * readWholeFileLimited 的行为差异所在。 */
TH_TEST(read_file_capped_reject_fails_only_beyond_cap) {
	fx::TempDir dir("capread");
	const std::filesystem::path exact = dir.path() / "exact.bin";
	const std::filesystem::path over = dir.path() / "over.bin";
	writeText(exact, "1234");
	writeText(over, "12345");

	std::string out;
	TH_CHECK(bot::readFileCapped(exact.string(), 4, bot::CapPolicy::Reject, out)
		== bot::CapReadStatus::OK);
	TH_CHECK(out == "1234");

	/* 恰好 cap 成功、cap+1 失败：边界在「多出的那 1 字节」上 */
	TH_CHECK(bot::readFileCapped(over.string(), 4, bot::CapPolicy::Reject, out)
		== bot::CapReadStatus::TOO_LARGE);
}

TH_TEST(read_file_capped_truncate_stops_at_cap_without_error) {
	fx::TempDir dir("capread_trunc");
	const std::filesystem::path over = dir.path() / "over.bin";
	writeText(over, "1234567890");

	std::string out;
	TH_CHECK(bot::readFileCapped(over.string(), 4, bot::CapPolicy::Truncate, out)
		== bot::CapReadStatus::OK);
	TH_CHECK(out == "1234");	/* 截断是刻意的：提示词预算语义 */
}

TH_TEST(read_file_capped_missing_file_is_open_failed) {
	fx::TempDir dir("capread_missing");
	std::string out;
	TH_CHECK(bot::readFileCapped((dir.path() / "nope.bin").string(), 16,
			bot::CapPolicy::Reject, out) == bot::CapReadStatus::OPEN_FAILED);
	TH_CHECK(out.empty());
}

TH_TEST(read_file_capped_symlink_policy_is_explicit) {
	fx::TempDir dir("capread_link");
	const std::filesystem::path target = dir.path() / "target.bin";
	const std::filesystem::path link = dir.path() / "link.bin";
	writeText(target, "abcdef");
	std::error_code ec;
	std::filesystem::create_symlink(target, link, ec);
	/* 软链创建失败 = 文件系统不支持（tmpfs 挂载参数、某些容器 overlay 等）。
	 * 这里**必须**显式表态（AG-5）：此前是 `if (ec) { return; }`——一条断言都没跑
	 * 就结束，harness 按「无失败」记 [PASS]，于是「软链策略是否真的生效」在守门
	 * 里从来没有人验证过。现在 harness 把零断言判失败，环境不满足就走 TH_SKIP
	 * 并给出原因（守门日志能回答「为什么这条没跑」）。 */
	if (ec) { TH_SKIP("该文件系统不支持创建符号链接，无法验证 O_NOFOLLOW 策略"); }

	std::string out;
	/* 缺省（不跟随）：O_NOFOLLOW 拒绝软链——配置/密钥/提示词包路径的防线 */
	TH_CHECK(bot::readFileCapped(link.string(), 16, bot::CapPolicy::Reject, out)
		== bot::CapReadStatus::OPEN_FAILED);
	/* 显式跟随：结构脚本头摘录沿用的旧语义（路径来自 CLI） */
	TH_CHECK(bot::readFileCapped(link.string(), 16, bot::CapPolicy::Reject, out, true)
		== bot::CapReadStatus::OK);
	TH_CHECK(out == "abcdef");
}

/* 薄封装的报错锚点：Reject 的两句文案（grep 守门与测试都锚定它们） */
TH_TEST(read_whole_file_limited_keeps_both_error_messages) {
	fx::TempDir dir("capread_msg");
	const std::filesystem::path over = dir.path() / "over.bin";
	writeText(over, "12345");
	std::string out, err;
	TH_CHECK(!bot::readWholeFileLimited(over.string(), 4, out, err, "提示词文件"));
	TH_CHECK(err.find("超过字节上限 4") != std::string::npos);
	TH_CHECK(!bot::readWholeFileLimited((dir.path() / "nope.bin").string(), 4, out, err));
	TH_CHECK(err.find("无法打开") == 0);
}

/* ---- UTF-8 判据与消毒（2026-09-21 审计 AG-1）----
 * 这组用例钉的是「什么算非法」这条边界：它比「转义控制字符」更容易写错，
 * 且错了不会本地报错——只会在严格网关那里变成 400（实测就是如此）。 */
namespace {

/* 用显式字节构造串：源码里的 \xff 之类字面量在不同编译器/字面量类型下
 * 语义不同，测试必须逐字节确定。 */
std::string bytes(std::initializer_list<unsigned> bs) {
	std::string s;
	for (unsigned b : bs) { s.push_back(static_cast<char>(b)); }
	return s;
}

} // namespace

TH_TEST(utf8_accepts_ascii_and_boundary_sequences) {
	TH_CHECK(bot::isValidUtf8(""));
	TH_CHECK(bot::isValidUtf8("plain ascii"));
	TH_CHECK(bot::isValidUtf8(bytes({0x00, 0x7f})));		/* 控制字符合法 */
	TH_CHECK(bot::isValidUtf8(bytes({0xc2, 0x80})));	/* U+0080 最短二字节 */
	TH_CHECK(bot::isValidUtf8(bytes({0xdf, 0xbf})));	/* U+07FF */
	TH_CHECK(bot::isValidUtf8(bytes({0xe0, 0xa0, 0x80})));	/* U+0800 最短三字节 */
	TH_CHECK(bot::isValidUtf8(bytes({0xef, 0xbf, 0xbd})));	/* U+FFFD */
	TH_CHECK(bot::isValidUtf8(bytes({0xf0, 0x90, 0x80, 0x80})));	/* U+10000 */
	TH_CHECK(bot::isValidUtf8(bytes({0xf4, 0x8f, 0xbf, 0xbf})));	/* U+10FFFF 上限 */
	TH_CHECK(bot::isValidUtf8("舵机温度"));			/* 真多字节 */
}

TH_TEST(utf8_rejects_every_illegal_class) {
	/* 原始坏字节（AG-1 的复现输入） */
	TH_CHECK(!bot::isValidUtf8(bytes({0xff})));
	TH_CHECK(!bot::isValidUtf8(bytes({0x80})));
	/* 孤立续字节 */
	TH_CHECK(!bot::isValidUtf8(bytes({0x41, 0x80, 0x42})));
	/* 过长编码：C0/C1 开头，以及三/四字节里编码了过小的码点 */
	TH_CHECK(!bot::isValidUtf8(bytes({0xc0, 0xaf})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xc1, 0xbf})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xe0, 0x80, 0xaf})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xf0, 0x80, 0x80, 0xaf})));
	/* UTF-16 代理区（严格解码器一律拒绝） */
	TH_CHECK(!bot::isValidUtf8(bytes({0xed, 0xa0, 0x80})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xed, 0xbf, 0xbf})));
	/* > U+10FFFF */
	TH_CHECK(!bot::isValidUtf8(bytes({0xf4, 0x90, 0x80, 0x80})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xf5, 0x80, 0x80, 0x80})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xfe})));
	/* 序列被截断（含「截断正好落在多字节中间」——cap 截断会真实产生这种输入） */
	TH_CHECK(!bot::isValidUtf8(bytes({0xe4, 0xb8})));
	TH_CHECK(!bot::isValidUtf8(bytes({0xf0, 0x9f, 0x98})));
}

TH_TEST(utf8_sanitize_replaces_illegal_bytes_and_preserves_valid_prefix) {
	const std::string bad = bytes({0x41, 0xff, 0x42});	/* "A\xffB" = AG-1 的复现输入 */
	const std::string fixed = bot::sanitizeUtf8(bad);
	TH_CHECK(fixed == bytes({0x41, 0xef, 0xbf, 0xbd, 0x42}));
	TH_CHECK(bot::isValidUtf8(fixed));

	/* 合法内容逐字节不变（含真多字节与 NUL） */
	const std::string good = std::string("舵机") + bytes({0x00, 0x7f});
	TH_CHECK(bot::sanitizeUtf8(good) == good);
}

TH_TEST(utf8_sanitize_folds_consecutive_illegal_runs) {
	/* 连续坏字节折叠成一个 U+FFFD + 计数说明，而不是 N 个替换符 */
	std::string run;
	for (int i = 0; i < 5; ++i) { run.push_back(static_cast<char>(0xff)); }
	const std::string fixed = bot::sanitizeUtf8(bytes({0x41}) + run + bytes({0x42}));
	TH_CHECK(bot::isValidUtf8(fixed));
	TH_CHECK(fixed.find("[! invalid UTF-8 bytes omitted5 bytes]") != std::string::npos);
	/* 折叠后仍以 A/B 收尾，坏字节只占一个替换符 */
	TH_CHECK(fixed.compare(0, 1, "A") == 0);
	TH_CHECK(fixed.back() == 'B');

	/* 单个坏字节不加计数说明（避免噪音） */
	TH_CHECK(bot::sanitizeUtf8(bytes({0xff})) == bytes({0xef, 0xbf, 0xbd}));
}

TH_TEST(utf8_sanitize_output_is_always_valid_and_idempotent) {
	/* 混合：合法多字节 + 各类非法序列 + ASCII */
	std::string mixed = std::string("舵")
		+ bytes({0xff, 0xff, 0x80})
		+ std::string("机")
		+ bytes({0xe0, 0x80, 0xaf})
		+ std::string("温");
	TH_CHECK(!bot::isValidUtf8(mixed));
	const std::string once = bot::sanitizeUtf8(mixed);
	TH_CHECK(bot::isValidUtf8(once));
	TH_CHECK(bot::sanitizeUtf8(once) == once);	/* 幂等 */
	/* 合法多字节内容原样保留（首尾各验一次；别拿 .back() 与多字节首字节比——
	 * 那比的是同一个字符的最后一字节 vs 第一字节，必然不等） */
	TH_CHECK(once.compare(0, 3, "舵") == 0);
	TH_CHECK(once.size() >= 3 && once.compare(once.size() - 3, 3, "温") == 0);
}

TH_TEST(utf8_sanitize_handles_truncated_tail_from_output_cap) {
	/* 64KB 上限正好切在多字节序列中间：消毒后必须合法（否则网关 400） */
	std::string s = std::string(10, 'a') + bytes({0xe4, 0xb8});	/* 半个「中」 */
	TH_CHECK(!bot::isValidUtf8(s));
	TH_CHECK(bot::isValidUtf8(bot::sanitizeUtf8(s)));
}

/* C7（F6-1）：日志标记转义原先在 agentloop 匿名命名空间，只能经 verbose 日志
 * 间接覆盖——下游解析器真正关心的是「行首标记」，这条语义值得直接钉住。 */
TH_TEST(utils_escape_log_markers_only_touches_line_start_brackets) {
	/* 行首（含多行文本的每个行首）的 '[' 被转义，"\\[" 因此不可能被日志解析器
	 * 当成判定行读走 */
	TH_CHECK(bot::escapeLogMarkers("[FAIL] 假失败") == "\\[FAIL] 假失败");
	TH_CHECK(bot::escapeLogMarkers("工具返回：\n[PASS] x\n[FAIL] y")
		== "工具返回：\n\\[PASS] x\n\\[FAIL] y");

	/* 非行首的方括号原样保留：JSON 数组、下标、正常内容不该被改写 */
	TH_CHECK(bot::escapeLogMarkers("{\"a\":[1,2]}") == "{\"a\":[1,2]}");
	TH_CHECK(bot::escapeLogMarkers("arr[0] 越界") == "arr[0] 越界");
	TH_CHECK(bot::escapeLogMarkers("  [缩进后的方括号不转义]") == "  [缩进后的方括号不转义]");

	/* 空串与无方括号文本逐字不变 */
	TH_CHECK(bot::escapeLogMarkers("").empty());
	TH_CHECK(bot::escapeLogMarkers("没有标记") == "没有标记");
}

/* ---- 内嵌 NUL 击穿"全串消费"判据（2026-09-21 第七轮审计）----
 * strtoll/strtod 走 c_str()，在第一个 NUL 处停下，而那个 NUL 恰好就是 `*end` ⇒
 * `*end != '\0'` 判据被满足、尾随垃圾被**静默丢弃**：`90\0junk` 报 OK/90。
 * NUL 进得来：.mt 词法不把 NUL 当分隔符，.sql 引号态字面追加。
 * 同族判据：checkRelPath 的 RelPathCheck::NUL、luabridge 的 rejectEmbeddedNul、
 * agent 工具参数入口的 requireString。 */
TH_TEST(utils_numeric_parsers_reject_embedded_nul) {
	/* 整数：修复前是 OK/90 */
	{
		const std::string s = std::string("90") + '\0' + "junk";
		auto [st, v] = bot::parseLongStrict(s);
		TH_CHECK_MSG(st == bot::IntParse::NOT_INT,
			"内嵌 NUL 必须判非法，实际状态码 " + std::to_string(static_cast<int>(st)));
		TH_CHECK(v == 0);
	}
	/* 浮点：修复前是 OK/1.5 */
	{
		const std::string s = std::string("1.5") + '\0' + "e3";
		double out = 0.0;
		TH_CHECK_MSG(bot::parseFiniteDouble(s, out) == bot::ParseFiniteStatus::INVALID,
			"内嵌 NUL 必须判 INVALID");
	}
	/* isNumericLiteral 走同一单点，故同样拒绝（结构脚本 Number 列 / @Vars 的 value） */
	TH_CHECK(!bot::isNumericLiteral(std::string("12") + '\0' + "34"));

	/* 正向对照：干净输入照常解析（判据没有变成"一律拒绝"） */
	{
		auto [st, v] = bot::parseLongStrict("90");
		TH_CHECK(st == bot::IntParse::OK);
		TH_CHECK(v == 90);
	}
	{
		double out = 0.0;
		TH_CHECK(bot::parseFiniteDouble("1.5", out) == bot::ParseFiniteStatus::OK);
		TH_CHECK(out == 1.5);
	}
	/* 尾随垃圾（不含 NUL）仍按原语义拒绝——这条钉住"新增判据没有放宽旧判据" */
	TH_CHECK(bot::parseLongStrict("90junk").first == bot::IntParse::NOT_INT);
}

/* ---- parseBoundedLong：解析 + 双边界钳制单点（2026-09-29 A4.2）----
 * 钉住三件事：边界含端点、两侧越界都拒、非整数拒。手写站点抄漏一侧
 * 边界即防线缺口，此处是谓词的单一事实源。 */
TH_TEST(utils_parse_bounded_long_enforces_both_bounds_inclusive) {
	TH_CHECK(bot::parseBoundedLong("8080", 1, 65535).value_or(-1) == 8080);
	TH_CHECK(bot::parseBoundedLong("1", 1, 65535).value_or(-1) == 1);	/* 下界含端点 */
	TH_CHECK(bot::parseBoundedLong("65535", 1, 65535).value_or(-1) == 65535);	/* 上界含端点 */
	TH_CHECK(!bot::parseBoundedLong("0", 1, 65535).has_value());	/* 低于下界 */
	TH_CHECK(!bot::parseBoundedLong("65536", 1, 65535).has_value());	/* 越上界 */
	TH_CHECK(!bot::parseBoundedLong("abc", 1, 65535).has_value());	/* 非整数 */
	TH_CHECK(!bot::parseBoundedLong("90junk", 1, 65535).has_value());	/* 尾随垃圾 */
	TH_CHECK(!bot::parseBoundedLong("-5", 0, 100).has_value());	/* 负值越过 [0,…] 下界 */
}

/* ---- AG-11 / AG-22：`agent:` 作用域过滤器的完备性（必须放在**主套件**里）----
 * 起因：docs/agent.md 推荐的 `./build/mybot_tests agent` 是子串匹配，只命中用例名
 * 里含 "agent" 的那部分——promptpack / llmconfig / cliargs 这些同属 agent 配置面的
 * 用例全都不命中（实测 86/436，而注释写着「proto / driver / tools / loop / config」）。
 * 现在加了显式作用域表（harness.hpp 的 scopeTable）。
 *
 * **第三轮审计 AG-22**：原守门只断言「表里每个成员都有命中」+「总数 ≥100」，
 * 于是它结构上不可能发现**漏登记**——实测 `agentconfig_` / `agentmode_` 两族共 15 条
 * 用例（test_llmconfig.cpp 的配置优先级、allow_shell 缺省、提示词拼装与注入包裹）
 * 一条都不在 `agent:` 里，而守门照绿、docs 还宣称覆盖了 config 面。
 * 现在改成**派生式比对**：把注册表里所有用例名前缀反向列出来，每一个要么在作用域表
 * 里、要么在下面的「非 agent 面」roster 里带理由登记。新增一整族用例却没表态即红。
 *
 * 覆盖边界的如实说明（这条判据不是万能的）：roster 的键是**前缀**，所以
 * 「给已登记族新增用例」自动随族走（会进作用域）；而「新增一个前缀却忘了表态」
 * 才由本用例拦下。文件级归属无法从注册表推出（Case 只有名字），故不假装能测。
 * 本用例必须在 mybot_tests 里而不是 harness_selftest 里：骨架自证二进制只注册了
 * 它自己那几个例句用例，看不到主套件，作用域完备性在那里无从判断。 */
namespace {

/* 非 agent 面的用例名前缀 roster：每个前缀都要带「它为什么不属于 agent 面」。
 * 这是审计留痕，不是形式主义——下一个想加前缀的人必须在这里写一句理由，
 * 而写理由的过程正是「我是不是漏登记了」的自检点。 */
struct NonAgentPrefix {
	const char* prefix;
	const char* why;
};

constexpr NonAgentPrefix kNonAgentPrefixes[] = {
	{"action", "动作输入源/动作重放（管道模式）"},
	{"alias", "结构期 @Alias 语义"},
	{"call", "驱动 call 契约（硬件层）"},
	{"capture", "@Action 单元格捕获 `$var=field`（动作重放层，非 agent 专属）"},
	{"controller", "结构脚本 controller 引用"},
	/* cross_（跨语言常量互钉 test_cross_lang_limits）已随 2026-10-01 批次 A
	 * （P1-5）删除：C++ 不再镜像任何 Rust 常量，唯一事实源是 Rust config.rs。 */
	{"daemon", "守护线程"},
	{"deactivate", "硬件生命周期（非 agent 专属）"},
	{"destructor", "硬件析构语义"},
	{"echo", "驱动回显夹具"},
	{"empty", "空输入边界"},
	{"ensureOk", "错误契约折成异常的判据"},
	{"expr", "$(...) 表达式"},
	{"failed", "失败路径（硬件层）"},
	{"flat", "矩阵扁平化"},
	{"hardware", "硬件变量注册表"},
	{"harness", "测试骨架自身"},
	{"hot", "热 SQL 只读计划（硬件结构层，非 agent 专属）"},
	{"hw", "硬件装配"},
	{"insert", "SQL INSERT（矩阵层）"},
	{"json", "宿主 Json 值层"},
	{"jsonparse", "宿主 JSON 解析"},
	{"lexer", "SQL 词法"},
	{"limited", "受限读取"},
	{"lua", "Lua 桥/沙箱"},
	{"matrix", "矩阵解析"},
	{"metaprovider", "元数据提供者"},
	{"metaregistry", "元数据域（MetaRegistry 门面）"},
	{"mtinclude", "@Merge 归并 / @Include 拷贝"},
	{"mtmerge", "mtmerge 归并"},
	{"nested", "嵌套表边界"},
	{"open", "输入源打开路径"},
	{"oversized", "超限输入"},
	{"parse", "解析器通用用例"},
	{"parseMtDouble", "矩阵数值解析"},
	{"parser", "SQL 解析器"},
	{"play", "play/playQuiet 派发"},
	{"read", "Reader 语义"},
	{"registry", "注册表生命周期"},
	{"retry", "EINTR 重试"},
	{"robot", "RobotStruct 编排"},
	{"run", "run() 语义"},
	{"safe", "安全标识符判据"},
	{"sandbox", "驱动沙箱"},
	{"session", "会话作用域"},
	{"single", "单消费者判据"},
	{"structure", "结构矩阵域（StructureStore 门面）"},
	{"tcp", "TCP 输入源"},
	{"the", "例句/杂项"},
	{"token", "SQL token"},
	{"too", "超限/过长输入"},
	{"trigger", "结构脚本 trigger 引用"},
	{"utils", "util 通用助手"},
	{"utf8", "UTF-8 判据与消毒"},
	{"vars", "结构期 @Vars 语义"},
	{"webterm", "Web SSH PTY 会话原语（网络/终端层，非 agent 面）"},
	{"webshell", "Web SSH 连接编排（网络/终端层，非 agent 面）"},
	{"ws", "RFC 6455 WebSocket 协议原语（网络层，非 agent 面）"},
};

} // namespace

TH_TEST(harness_scope_agent_lists_every_member_with_cases) {
	std::size_t n = 0;
	const th::ScopeEntry* table = th::scopeTable(n);
	TH_CHECK_MSG(n > 0, "作用域表为空");

	std::size_t members = 0;
	for (std::size_t i = 0; i < n; ++i) {
		const std::string prefix = table[i].name;
		std::size_t hits = 0;
		for (const auto& c : th::cases()) {
			if (c.name.rfind(prefix, 0) == 0) { ++hits; }
		}
		++members;
		TH_CHECK_MSG(hits > 0, std::string("作用域成员 '") + prefix
			+ "' 没有命中任何用例（拼错了？还是测试文件被重命名了？）");
	}

	/* ---- 派生式完备性：注册表里出现的每个前缀都必须表过态 ---- */
	std::vector<std::string> prefixes;
	for (const auto& c : th::cases()) {
		const std::size_t us = c.name.find('_');
		const std::string p = c.name.substr(0, us == std::string::npos ? c.name.size() : us);
		if (std::find(prefixes.begin(), prefixes.end(), p) == prefixes.end()) {
			prefixes.push_back(p);
		}
	}
	std::sort(prefixes.begin(), prefixes.end());
	TH_CHECK_MSG(prefixes.size() >= 40,
		"前缀数 " + std::to_string(prefixes.size()) + " 偏少——注册表读取是否正常？");

	for (const std::string& p : prefixes) {
		std::size_t scopedHits = 0;
		for (const auto& c : th::cases()) {
			if (c.name.rfind(p + "_", 0) == 0 && th::caseInScope(c.name, "agent")) {
				++scopedHits;
			}
		}
		if (scopedHits > 0) { continue; }	/* 属于 agent 面（表的成员） */
		bool rostered = false;
		for (const NonAgentPrefix& r : kNonAgentPrefixes) {
			if (p == r.prefix) { rostered = true; break; }
		}
		TH_CHECK_MSG(rostered, "用例名前缀 '" + p
			+ "_' 既不在 agent 作用域表里，也不在 test_util.cpp 的非 agent roster 里。"
			  "若它属于 agent 面 → 在 harness.hpp 的 scopeTable 补一行；"
			  "若不属于 → 在 kNonAgentPrefixes 补一行并写明理由（AG-22 就是漏了这一表态）");
	}

	/* roster 的反向检查：登记了却不存在的理由条目是陈旧留痕，允许删 */
	for (const NonAgentPrefix& r : kNonAgentPrefixes) {
		bool exists = std::find(prefixes.begin(), prefixes.end(), r.prefix) != prefixes.end();
		TH_CHECK_MSG(exists, std::string("非 agent roster 里的 '") + r.prefix
			+ "_' 已无任何用例（陈旧条目，可删）");
	}

	/* 作用域整体命中数：明显多于旧的子串语义（子串 'agent' 只命中 80 余例）。
	 * 这条防的是「表在、匹配没生效」这类静默失效。 */
	std::size_t scoped = 0;
	for (const auto& c : th::cases()) {
		if (th::caseInScope(c.name, "agent")) { ++scoped; }
	}
	TH_CHECK_MSG(scoped >= members && scoped >= 120,
		"agent: 作用域命中 " + std::to_string(scoped) + " 例（成员数 "
			+ std::to_string(members) + "），明显偏少——过滤是否失效？"
			"（AG-22 修复后为 130：原 108 + agentconfig_/agentmode_ 15 + 本轮新用例 7）");
}


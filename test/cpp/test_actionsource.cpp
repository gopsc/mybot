/* test_actionsource.cpp —— 动作输入源的信任边界与字节上限
 *
 * --input / stdin 两条通道共用同一个字节上限包装器。这里钉住：
 *   LimitedReader  第 cap+1 个字节即抛，EOF 不计入配额，未超限时字节原样透传
 *   异常类型       ScriptTooLarge 属 MatrixParseExcept 家族，
 *                  调用方按「脚本解析期错误」统一处理即可拿到原文报错；
 *                  kind 标签区分「动作脚本 / 结构脚本」两类输入（F-02）
 *   文件通道       不存在/打不开时返回 nullptr
 */

#include <cstddef>
#include <memory>
#include <string>

#include "actionsource.hpp"
#include "cliargs.hpp"
#include "harness.hpp"
#include "matrix.hpp"
#include "util_except.hpp"
#include "util_str.hpp"

TH_TEST(limited_reader_passes_bytes_under_the_cap) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abc"));
	bot::LimitedReader lim(std::move(inner), 3);
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK(lim.read() == 'c');
	TH_CHECK(lim.read() == -1);
	TH_CHECK(lim.read() == -1);
}

TH_TEST(limited_reader_throws_one_byte_past_the_cap) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abcde"));
	bot::LimitedReader lim(std::move(inner), 3);
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK(lim.read() == 'c');
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge, "exceeds the byte limit of 3", lim.read());
	TH_CHECK_THROWS(bot::ScriptTooLarge, lim.read());
}

TH_TEST(limited_reader_kind_label_distinguishes_script_kinds) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader("abcd"));
	bot::LimitedReader lim(std::move(inner), 2, "structure script");
	TH_CHECK(lim.read() == 'a');
	TH_CHECK(lim.read() == 'b');
	TH_CHECK_THROWS_MSG(bot::ScriptTooLarge,
		"structure script exceeds the byte limit of 2", lim.read());
}

TH_TEST(limited_reader_eof_does_not_consume_quota) {
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader(""));
	bot::LimitedReader lim(std::move(inner), 1);
	for (int k = 0; k < 100; ++k) { TH_CHECK(lim.read() == -1); }
}

TH_TEST(action_script_too_large_is_a_domain_error) {
	bot::ScriptTooLarge e(8);
	const bot::IllegalArgumentException& base = e;
	TH_CHECK(std::string(base.what()).find("exceeds the byte limit of 8") != std::string::npos);
	const std::exception& std_e = base;
	TH_CHECK(std::string(std_e.what()) == std::string(e.what()));
}

TH_TEST(too_large_survives_matrix_parser_without_downgrade) {
	const std::string script = "@Action\nrelay0.deg;\n  200;\n  200;\n  200;\n@\n";
	std::unique_ptr<bot::Reader> inner(new bot::MemoryReader(script));
	bot::LimitedReader lim(std::move(inner), 20);
	mt::MatrixParser parser(lim);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "exceeds the byte limit of 20", parser.parse());
}

TH_TEST(open_action_source_rejects_missing_input_file) {
	bot::CliOptions opts;
	opts.input = "./definitely-not-here-9f3a1c.mt";
	TH_CHECK(bot::openActionSource(opts) == nullptr);
}

TH_TEST(cli_no_arguments_requests_help) {
	char arg0[] = "mybot";
	char* argv[] = {arg0};
	bot::ParsedArgs parsed = bot::parseArgs(1, argv);
	TH_CHECK(parsed.help);
	TH_CHECK(parsed.errorCode == 0);
}

TH_TEST(cli_help_flag_works_without_robot) {
	char arg0[] = "mybot";
	char arg1[] = "--help";
	char* argv[] = {arg0, arg1};
	bot::ParsedArgs parsed = bot::parseArgs(2, argv);
	TH_CHECK(parsed.help);
}

TH_TEST(cli_missing_robot_is_a_usage_error) {
	char arg0[] = "mybot";
	char arg1[] = "--input";
	char arg2[] = "scripts/relay-test.mt";
	char* argv[] = {arg0, arg1, arg2};
	bot::ParsedArgs parsed = bot::parseArgs(3, argv);
	TH_CHECK(parsed.errorCode == 2);
	TH_CHECK(!parsed.help);
}

TH_TEST(cli_robot_is_parsed) {
	char arg0[] = "mybot";
	char arg1[] = "--robot=robots/relay-test.sql";
	char* argv[] = {arg0, arg1};
	bot::ParsedArgs parsed = bot::parseArgs(2, argv);
	TH_CHECK(parsed.errorCode == 0);
	TH_CHECK(parsed.opts.robot.has_value());
	TH_CHECK(*parsed.opts.robot == "robots/relay-test.sql");
}

TH_TEST(safe_equals_matches_identical_strings) {
	TH_CHECK(bot::safeEquals("", ""));
	TH_CHECK(bot::safeEquals("token", "token"));
	TH_CHECK(bot::safeEquals(std::string("a\0b", 3), std::string("a\0b", 3)));
}

TH_TEST(safe_equals_rejects_mismatched_content) {
	TH_CHECK(!bot::safeEquals("token", "Xoken"));
	TH_CHECK(!bot::safeEquals("token", "tokeX"));
	TH_CHECK(!bot::safeEquals("token", "tokEn"));
}

TH_TEST(safe_equals_rejects_length_difference) {
	TH_CHECK(!bot::safeEquals("token", "tokenx"));
	TH_CHECK(!bot::safeEquals("token", "toke"));
	TH_CHECK(!bot::safeEquals("", "x"));
}

/* test_action_print.cpp —— @Action 单元格打印标记 `?`（设备返回表）
 *
 * 覆盖：单独 `?` 不向设备传参、该设备本行仍 play 一次、play 后打印完整
 * 返回表并带列头/行号归因；与普通参数列同设备时只传真实参数；同设备多个
 * `?` 列只打印一次；`-` 继承 `?` 后继续打印。
 * 夹具形态与 test_action_capture.cpp 同源（LambdaHw 桩 + HwRegistry 白盒）。
 */
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "action_runner.hpp"
#include "hardware.hpp"
#include "matrix.hpp"

namespace {

/* stderr 捕获：`?` 的输出是契约（列头 + 行号 + 返回表 JSON） */
struct CerrCapture {
	std::ostringstream buf;
	std::streambuf* old;
	CerrCapture() : old(std::cerr.rdbuf(buf.rdbuf())) {}
	~CerrCapture() { std::cerr.rdbuf(old); }
	CerrCapture(const CerrCapture&) = delete;
	CerrCapture& operator=(const CerrCapture&) = delete;
	std::string str() const { return buf.str(); }
	bool contains(const std::string& sub) const {
		return buf.str().find(sub) != std::string::npos;
	}
};

std::size_t occurrences(const std::string& haystack, const std::string& needle) {
	std::size_t n = 0;
	for (std::size_t pos = 0; (pos = haystack.find(needle, pos)) != std::string::npos;
			pos += needle.size()) {
		++n;
	}
	return n;
}

std::unique_ptr<bot::MatrixVars_Hardware> resultHw(
		int* plays, bot::Json* lastIn) {
	return std::make_unique<fx::LambdaHw>([plays, lastIn](const bot::Json& in) {
		if (plays != nullptr) { ++*plays; }
		if (lastIn != nullptr) { *lastIn = in; }
		bot::Json o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		o.put("value", bot::JsonInt(42));
		return o;
	});
}

} // namespace

TH_TEST(print_marker_prints_device_result_without_parameter) {
	bot::HwRegistry reg;
	int plays = 0;
	bot::Json lastIn;
	reg.add("dev", resultHw(&plays, &lastIn), "");

	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.s;\n ?;\n@\n");
	CerrCapture cap;
	bot::ActionRunner(reg).runAction(mats);

	TH_CHECK(plays == 1);
	TH_CHECK(lastIn.isObj() && lastIn.objSize() == 0);
	TH_CHECK(cap.contains("[?] dev.s (row 1): "));
	TH_CHECK(cap.contains("\"result\":\"OK\""));
	TH_CHECK(cap.contains("\"value\":42"));
	TH_CHECK(occurrences(cap.str(), "[?]") == 1);
}

TH_TEST(print_marker_keeps_real_params_and_prints_once) {
	bot::HwRegistry reg;
	int plays = 0;
	bot::Json lastIn;
	reg.add("dev", resultHw(&plays, &lastIn), "");

	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.s dev.t;\n ?     7;\n@\n");
	CerrCapture cap;
	bot::ActionRunner(reg).runAction(mats);

	TH_CHECK(plays == 1);
	TH_CHECK(lastIn.isObj() && lastIn.objSize() == 1);
	TH_CHECK(lastIn.find("t") != nullptr && lastIn.find("t")->getFloat() == 7.0);
	TH_CHECK(lastIn.find("s") == nullptr);
	TH_CHECK(occurrences(cap.str(), "[?]") == 1);
}

TH_TEST(print_marker_multiple_columns_print_once) {
	bot::HwRegistry reg;
	int plays = 0;
	bot::Json lastIn;
	reg.add("dev", resultHw(&plays, &lastIn), "");

	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a dev.b;\n ?     ?;\n@\n");
	CerrCapture cap;
	bot::ActionRunner(reg).runAction(mats);

	TH_CHECK(plays == 1);
	TH_CHECK(lastIn.isObj() && lastIn.objSize() == 0);
	TH_CHECK(occurrences(cap.str(), "[?]") == 1);
	/* 归因取首个携带标记的列头 */
	TH_CHECK(cap.contains("[?] dev.a (row 1): "));
}

TH_TEST(print_marker_inherits_through_dash) {
	bot::HwRegistry reg;
	int plays = 0;
	reg.add("dev", resultHw(&plays, nullptr), "");

	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.s;\n ?;\n -;\n@\n");
	CerrCapture cap;
	bot::ActionRunner(reg).runAction(mats);

	TH_CHECK(plays == 2);
	TH_CHECK(cap.contains("[?] dev.s (row 1): "));
	TH_CHECK(cap.contains("[?] dev.s (row 2): "));
	TH_CHECK(occurrences(cap.str(), "[?]") == 2);
}

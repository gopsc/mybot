/* test_action_capture.cpp —— @Action 单元格捕获 `$var=field.path`（返回值字段赋值）
 *
 * 覆盖：数值字段→@Vars、文本字段→@Alias、点号嵌套路径、未声明自动新建、
 * 捕获后供后续 $(...) 与 @if(...) 消费、纯捕获列设备仍 play、覆盖结构层定义、
 * 报错契约（缺失字段 / 非标量目标 / @Vars 收非数值 / flowRef 拒绝 / 坏形态）。
 * 夹具形态与 test_action_if.cpp 同源（LambdaHw 桩 + HwRegistry 白盒）。
 */
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "action_runner.hpp"
#include "hardware.hpp"
#include "matrix.hpp"
#include "util_except.hpp"

namespace {

std::unique_ptr<bot::MtVars_Alias> aliasHw(const std::string& name, const std::string& target) {
	std::string text = "@Alias\nname  alias;\n   " + name + "  " + target + ";\n@\n";
	return bot::MtVars_Alias::Factory(fx::oneMatrix(text), 1);
}

std::unique_ptr<bot::MtVars_Vars> varsHw(const std::string& name, const std::string& value) {
	return bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\n   " + name + "  " + value + ";\n@\n"), 1,
		[](const std::string&) { return 0.0; });
}

/* 设备桩：play 返回 {result=OK, ...fields}，记录 play 次数与最后一次入参 */
std::unique_ptr<bot::MatrixVars_Hardware> sensorHw(const bot::Json& fields,
		int* plays, bot::Json* lastIn) {
	return std::make_unique<fx::LambdaHw>([fields, plays, lastIn](const bot::Json& in) {
		if (plays != nullptr) { ++*plays; }
		if (lastIn != nullptr) { *lastIn = in; }
		bot::Json o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		for (const auto& kv : fields.items()) { o.put(kv.first, kv.second); }
		return o;
	});
}

std::string readText(bot::HwRegistry& reg, const std::string& name) {
	bot::MatrixVars_Hardware* hv = reg.find(name);
	if (hv == nullptr) { return "<undefined>"; }
	return hv->read().getValue();
}

} // namespace

/* ---------------- 解析单点白盒 ---------------- */

TH_TEST(capture_parse_cell_forms) {
	/* 非捕获：不以 $ 开头 / $(...) 表达式 → nullopt（交回既有路径） */
	TH_CHECK(!bot::ActionRunner::parseCaptureCell("45", "d.p").has_value());
	TH_CHECK(!bot::ActionRunner::parseCaptureCell("-", "d.p").has_value());
	TH_CHECK(!bot::ActionRunner::parseCaptureCell("$(v1+v2)", "d.p").has_value());
	/* 命中：$var=field 与点号路径 */
	auto c = bot::ActionRunner::parseCaptureCell("$ax=ACCEL_X", "imu.ax");
	TH_CHECK(c.has_value() && c->var == "ax" && c->path == "ACCEL_X" && c->colHead == "imu.ax");
	auto n = bot::ActionRunner::parseCaptureCell("$t=data.temp", "s.t");
	TH_CHECK(n.has_value() && n->var == "t" && n->path == "data.temp");
	/* 坏形态响亮报错 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "以 '$' 开头",
		(void)bot::ActionRunner::parseCaptureCell("$ax", "imu.ax"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "不是安全标识符",
		(void)bot::ActionRunner::parseCaptureCell("$a-b=f", "d.p"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "缺少字段名",
		(void)bot::ActionRunner::parseCaptureCell("$ax=", "d.p"));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "含空段",
		(void)bot::ActionRunner::parseCaptureCell("$ax=a..b", "d.p"));
}

/* ---------------- 数值/文本捕获与自动新建 ---------------- */

TH_TEST(capture_numeric_field_autocreates_vars) {
	bot::HwRegistry reg;
	int plays = 0;
	bot::Json fields = bot::JsonObject();
	fields.put("ACCEL_X", bot::JsonFloat(1.5));
	reg.add("imu", sensorHw(fields, &plays, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nimu.ax;\n $ax=ACCEL_X;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	/* 纯捕获列（无参数）设备仍 play 了一次；未声明的 ax 按数值字段自动新建为 @Vars */
	TH_CHECK(plays == 1);
	TH_CHECK(readText(reg, "ax") == "1.5");
	bot::MatrixVars_Hardware* ax = reg.find("ax");
	TH_CHECK(ax != nullptr && std::string(ax->kindName()) == "vars");
}

TH_TEST(capture_text_field_autocreates_alias) {
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("label", bot::JsonString("hello"));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.s;\n $s=label;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(readText(reg, "s") == "hello");
	bot::MatrixVars_Hardware* sv = reg.find("s");
	TH_CHECK(sv != nullptr && std::string(sv->kindName()) == "alias");
}

TH_TEST(capture_nested_dot_path) {
	bot::HwRegistry reg;
	bot::Json inner = bot::JsonObject();
	inner.put("temp", bot::JsonFloat(42));
	bot::Json fields = bot::JsonObject();
	fields.put("data", inner);
	reg.add("s", sensorHw(fields, nullptr, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ns.t;\n $t=data.temp;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(readText(reg, "t") == "42");
}

TH_TEST(capture_into_declared_vars_and_alias) {
	/* 预声明的目标：按已声明种类落地（@Vars 数值 / @Alias 文本），不新建 */
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(7));
	fields.put("tag", bot::JsonString("ok"));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	reg.add("n", varsHw("n", "0"), "");
	reg.add("txt", aliasHw("txt", "init"), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a  dev.b;\n $n=v   $txt=tag;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(readText(reg, "n") == "7");
	TH_CHECK(readText(reg, "txt") == "ok");
}

/* ---------------- 捕获值供后续消费 ---------------- */

TH_TEST(capture_feeds_later_expression_row) {
	/* 同一行内表达式在捕获之前求值，故消费必须跨行：第 1 行捕获、第 2 行 $(x*2) */
	bot::HwRegistry reg;
	bot::Json aFields = bot::JsonObject();
	aFields.put("v", bot::JsonFloat(10));
	reg.add("a", sensorHw(aFields, nullptr, nullptr), "");
	bot::Json lastIn;
	bot::Json bFields = bot::JsonObject();
	reg.add("b", sensorHw(bFields, nullptr, &lastIn), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\na.out  b.in;\n $x=v    -;\n  -     $(x*2);\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	/* 第 2 行 b 收到 x*2 = 20（x 来自第 1 行捕获） */
	TH_CHECK(lastIn.isObj() && lastIn.get("in").has_value());
	TH_CHECK(lastIn.get("in")->getFloat() == 20.0);
}

TH_TEST(capture_feeds_later_if_block) {
	/* 动机用例：读传感器捕获进 @Vars，后续 @if(阈值) 据此分派 */
	bot::HwRegistry reg;
	int legPlays = 0;
	bot::Json imuHi = bot::JsonObject();
	imuHi.put("reading", bot::JsonFloat(10));
	reg.add("imu", sensorHw(imuHi, nullptr, nullptr), "");
	reg.add("leg", std::make_unique<fx::LambdaHw>([&legPlays](const bot::Json&) {
		++legPlays;
		bot::Json o = bot::JsonObject();
		o.put("result", bot::JsonString("OK"));
		return o;
	}), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\nimu.reading;\n $x=reading;\n@\n"
		"@if(x>5)\nleg.p;\n 90;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(legPlays == 1);	/* 10 > 5 成立 → leg 派发 */
}

/* ---------------- 覆盖结构层定义（会话遮蔽） ---------------- */

TH_TEST(capture_shadows_structure_var_within_run) {
	/* 结构层 k=100；捕获写入会话层遮蔽它（run 内生效），read 出被捕获值 */
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(7));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	reg.add("k", varsHw("k", "100"), "");	/* 结构层 */
	TH_CHECK(readText(reg, "k") == "100");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $k=v;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	TH_CHECK(readText(reg, "k") == "7");	/* 会话遮蔽 */
	TH_CHECK(reg.sessionSize() == 1);
}

/* ---------------- 参数列 + 捕获列混合（同设备一次 play） ---------------- */

TH_TEST(capture_mixes_with_param_on_same_device) {
	/* dev.mode 传参、dev.out 捕获：同一次 play 既收参数又取返回字段 */
	bot::HwRegistry reg;
	bot::Json lastIn;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(3));
	std::unique_ptr<bot::MatrixVars_Hardware> dev = std::make_unique<fx::LambdaHw>(
		[fields, &lastIn](const bot::Json& in) {
			lastIn = in;
			bot::Json o = bot::JsonObject();
			o.put("result", bot::JsonString("OK"));
			for (const auto& kv : fields.items()) { o.put(kv.first, kv.second); }
			return o;
		});
	reg.add("dev", std::move(dev), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.mode  dev.out;\n  1        $x=v;\n@\n");
	bot::ActionRunner(reg).runAction(mats);
	/* 参数照常投递、捕获照常落地 */
	TH_CHECK(lastIn.isObj() && lastIn.get("mode").has_value()
		&& lastIn.get("mode")->getFloat() == 1.0);
	TH_CHECK(readText(reg, "x") == "3");
}

/* ---------------- 报错契约 ---------------- */

TH_TEST(capture_missing_field_reports_loudly) {
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(1));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $x=nosuch;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not present in the return value",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(capture_into_nonscalar_rejected) {
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(1));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	reg.add("leg", fx::dummyHw(), "");	/* kindName = test-lambda（非标量） */
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $leg=v;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "not an @Vars/@Alias scalar",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(capture_vars_requires_numeric_field) {
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("label", bot::JsonString("text"));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	reg.add("n", varsHw("n", "0"), "");	/* @Vars 只收数值 */
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $n=label;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "requires a numeric field",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(capture_undeclared_bool_field_rejected) {
	/* 未声明目标 + 布尔字段：无法推断 @Vars/@Alias，提示先声明 */
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("flag", bot::JsonBool(true));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $x=flag;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cannot be inferred",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(capture_into_flowref_rejected) {
	/* 被引用为 controller/trigger 的名字不可覆盖（安全不变式，override 拒绝） */
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(1));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	reg.add("tgt", varsHw("tgt", "0"), "");
	reg.addFlowRef("tgt");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $tgt=v;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "controller or trigger",
		bot::ActionRunner(reg).runAction(mats));
}

TH_TEST(capture_bare_dollar_cell_reports_loudly) {
	bot::HwRegistry reg;
	bot::Json fields = bot::JsonObject();
	fields.put("v", bot::JsonFloat(1));
	reg.add("dev", sensorHw(fields, nullptr, nullptr), "");
	std::vector<mt::MatrixObject> mats = fx::manyMatrices(
		"@Action\ndev.a;\n $v;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "以 '$' 开头",
		bot::ActionRunner(reg).runAction(mats));
}

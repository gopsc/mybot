/* test_hardware.cpp —— 硬件变量基类 + 元数据收集（MetaProvider）
 *
 * 这两块是「结构脚本 → Lua 驱动入参」的唯一通路，此前只被 E2E 间接覆盖：
 *   parseMtDouble  动作矩阵单元格的类型解析（含 "-" 继承与首行占位符语义）
 *   ensureOk       halt-on-error 契约（result=="ERR" 即抛，trim 后比较）
 *   MetaProvider   字面列首采冻结 / "-" 列跳过 / name+controller+trigger 跳过 / $ 引用实时快照
 *   F-04′ 防线    destroy 期元数据：引用列快照必须带上（总线 fd 由此而来），
 *                  引用已释放只跳过该引用而非放弃整轮收集
 *   C1 防线        $ 引用成环时深度计数兜底，清晰报错而非栈溢出
 *   N3 防线        非表结果判契约违反（旧实现原样放行＝把「硬件没动」报成成功）
 */

#include <map>
#include <memory>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "fixtures.hpp"
#include "harness.hpp"
#include "hardware.hpp"
#include "json.hpp"
#include "matrix.hpp"
#include "robot.hpp"
#include "util_except.hpp"

using bot::Json;
using bot::JsonArray;
using bot::JsonBool;
using bot::JsonFloat;
using bot::JsonInt;
using bot::JsonNull;
using bot::JsonObject;
using bot::JsonString;
using bot::MatrixVars_Hardware;
using bot::MetaProvider;

/* ---------------- 基类生命周期 ---------------- */

TH_TEST(hardware_base_class_is_not_copyable) {
	/* 硬件变量一律经 unique_ptr 独占持有（子类持 lua_State 指针与共享槽等裸句柄） */
	TH_CHECK(!std::is_copy_constructible<MatrixVars_Hardware>::value);
	TH_CHECK(!std::is_copy_assignable<MatrixVars_Hardware>::value);
}

TH_TEST(hardware_build_destroy_default_to_noop) {
	/* R-3：build/destroy 是虚方法，基类缺省无操作；子类按需覆写。
	 * 「只 build 一次」由 RobotStruct::active() 那一层保证。 */
	fx::LambdaHw bare([](const Json&) { return JsonObject(); });
	bare.build();
	bare.destroy();
	TH_CHECK(true);
}

TH_TEST(hardware_read_defaults_to_play_with_empty_object) {
	/* P4/M1：read() 缺省实现 = play({})，驱动侧无需为只读快照另写入口 */
	Json seen = JsonNull();
	fx::LambdaHw v([&seen](const Json& in) {
		seen = in;
		Json out = JsonObject();
		out.put("count", JsonInt(3));
		return out;
	});
	Json snap = v.read();
	TH_CHECK(seen.isObj());
	TH_CHECK(seen.objSize() == 0);
	TH_CHECK(snap.get("count")->getInt() == 3);
}

/* ---------------- parseMtDouble ---------------- */

TH_TEST(parseMtDouble_reads_numeric_cells) {
	mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.deg;\n200;\n-3.5;\n1e2;\n@\n");
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 1, 0) == 200.0);
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 2, 0) == -3.5);
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 3, 0) == 100.0);
}

TH_TEST(parseMtDouble_inherits_dash_placeholder) {
	mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.deg;\n200;\n-;\n-;\n@\n");
	/* 连续 "-" 逐行继承同一个值（前向填充，非递归） */
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 2, 0) == 200.0);
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 3, 0) == 200.0);
}

TH_TEST(parseMtDouble_first_row_dash_is_zero) {
	/* 首数据行无可继承 → 0.0（沿用 Cangjie 语义：动作矩阵首行留空即零位） */
	mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.deg;\n-;\n@\n");
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(m, 1, 0) == 0.0);
}

TH_TEST(parseMtDouble_rejects_non_numeric_cell) {
	/* 报错必须带上出错单元格原文，否则用户无法在网格里定位
	 * （N-12：统一抛 IllegalArgumentException，全库单一解析错误类型） */
	mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.deg;\nabc;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "abc",
		bot::MatrixVars_Hardware::parseMtDouble(m, 1, 0));
	/* 尾部残留字符同样算非法（"12abc" 不能悄悄读成 12） */
	mt::MatrixObject m2 = fx::oneMatrix("@Action\nrelay0.deg;\n12abc;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "12abc",
		bot::MatrixVars_Hardware::parseMtDouble(m2, 1, 0));
}

TH_TEST(parseMtDouble_rejects_non_finite_cells) {
	/* L2：strtod 接受 nan/inf 字面量，非有限值流入舵机驱动即不可预测——
	 * 解析层显式拒绝并带原文。 */
	const char* bad[] = {"nan", "-nan", "inf", "-inf", "infinity"};
	for (const char* v : bad) {
		mt::MatrixObject m = fx::oneMatrix("@Action\nrelay0.deg;\n" + std::string(v) + ";\n@\n");
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, v,
			bot::MatrixVars_Hardware::parseMtDouble(m, 1, 0));
	}
	/* 正常有限值不受影响 */
	mt::MatrixObject ok = fx::oneMatrix("@Action\nrelay0.deg;\n1.25e2;\n@\n");
	TH_CHECK(bot::MatrixVars_Hardware::parseMtDouble(ok, 1, 0) == 125.0);
}

/* ---------------- ensureOk ---------------- */

TH_TEST(ensureOk_accepts_ok_objects_and_rejects_non_tables) {
	/* N3：非表结果一律判契约违反——表外没有 result 键可读，原样放行等于把
	 * 「硬件根本没动」报成成功（驱动漏 return、或把 @Alias 当 @Action 列前缀）。 */
	Json scalar = JsonInt(7);
	TH_CHECK_THROWS_MSG(std::runtime_error, "non-table result (int)",
		MatrixVars_Hardware::ensureOk(scalar, "play s1"));
	Json text = JsonString("angle");
	TH_CHECK_THROWS_MSG(std::runtime_error, "non-table result (string)",
		MatrixVars_Hardware::ensureOk(text, "play A"));

	Json ok = JsonObject();
	ok.put("result", JsonString("OK"));
	ok.put("value", JsonFloat(1.25));
	TH_CHECK(MatrixVars_Hardware::ensureOk(ok, "play x").get("value")->getFloat() == 1.25);

	/* L1 收紧：空表 {} 即「什么都没干」，旧实现判成功——现按契约错误拒绝 */
	Json plain = JsonObject();
	TH_CHECK_THROWS_MSG(std::runtime_error, "empty table",
		MatrixVars_Hardware::ensureOk(plain));

	/* 无 result 键但非空的数据表仍然通过：Relay/Servo 的 call 刻意返回
	 * {delay=..}/{channel=..} 走 controller 转发语义 */
	Json relay = JsonObject();
	relay.put("delay", JsonFloat(200.0));
	TH_CHECK(MatrixVars_Hardware::ensureOk(relay, "call Relay").get("delay")->getFloat() == 200.0);
}

TH_TEST(ensureOk_rejects_invalid_result_values) {
	/* result 键存在时只允许 "OK"/"ERR"，其余值一律契约错误（现驱动只有两值） */
	Json warn = JsonObject();
	warn.put("result", JsonString("WARN"));
	TH_CHECK_THROWS_MSG(std::runtime_error, "WARN",
		MatrixVars_Hardware::ensureOk(warn, "play x"));

	Json num = JsonObject();
	num.put("result", JsonInt(1));
	TH_CHECK_THROWS_MSG(std::runtime_error, "non-string",
		MatrixVars_Hardware::ensureOk(num, "play x"));
}

TH_TEST(ensureOk_throws_on_err_contract) {
	Json err = JsonObject();
	err.put("result", JsonString("ERR"));
	err.put("message", JsonString("i2c nack"));
	TH_CHECK_THROWS_MSG(std::runtime_error, "i2c nack",
		MatrixVars_Hardware::ensureOk(err, "play relay0"));
	TH_CHECK_THROWS_MSG(std::runtime_error, "play relay0",
		MatrixVars_Hardware::ensureOk(err, "play relay0"));

	/* 驱动常把 result 写成 "ERR " 之类，trim 后仍须判失败 */
	Json padded = JsonObject();
	padded.put("result", JsonString("  ERR\t"));
	TH_CHECK_THROWS_MSG(std::runtime_error, "Hardware call failed",
		MatrixVars_Hardware::ensureOk(padded));
}

TH_TEST(ensureOk_does_not_mistake_substring_for_error) {
	Json j = JsonObject();
	j.put("result", JsonString("OK"));
	j.put("message", JsonString("device reported ERR internally"));
	TH_CHECK(MatrixVars_Hardware::ensureOk(j).isObj());
}

/* ---------------- jsonMergeInto ---------------- */

TH_TEST(json_merge_into_overwrites_in_place) {
	Json dst = JsonObject();
	dst.put("a", JsonInt(1));
	dst.put("b", JsonInt(2));
	Json src = JsonObject();
	src.put("b", JsonString("B"));
	src.put("c", JsonInt(3));
	bot::jsonMergeInto(dst, src);
	/* 浅合并：同名覆盖且保持原位置，新键追加在尾部 */
	TH_CHECK(dst.toString() == R"({"a":1,"b":"B","c":3})");
}

/* ---------------- MetaProvider ---------------- */

TH_TEST(metaprovider_skips_name_structural_and_dash_columns) {
	/* name + 全部流引用列（controller/trigger 基名或基名+数字）是框架保留列：
	 * 一律不进元数据（按名模式跳过，不再由调用方传列号——漏传会让引用名
	 * 泄漏进 Lua 入参） */
	mt::MatrixObject m = fx::oneMatrix(
		"@Relay\nname controller2 trigger trigger3 note servo;\nr0 t0 t1 t2 hello -;\n@\n");
	bot::HwRegistry reg;
	MetaProvider prov(m, 1, &reg);
	Json meta = prov.collect();
	TH_CHECK(meta.toString() == R"({"note":"hello"})");
}

TH_TEST(metaprovider_freezes_literal_columns_after_first_collect) {
	/* P8/M2：字面列首采即冻结，之后每次只是重放缓存（避免逐帧重扫矩阵） */
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note;\nr0 hello;\n@\n");
	bot::HwRegistry reg;
	MetaProvider prov(m, 1, &reg);
	TH_CHECK(prov.collect().toString() == R"({"note":"hello"})");
	TH_CHECK(prov.collect().toString() == R"({"note":"hello"})");
}

TH_TEST(metaprovider_merges_live_snapshot_of_reference_column) {
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname src;\nr0 $t0;\n@\n");
	int reads = 0;
	auto t0 = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw([&reads](const Json&) {
		++reads;
		Json snap = JsonObject();
		snap.put("count", JsonInt(reads));
		return snap;
	}));
	bot::HwRegistry reg;
	reg.add("t0", std::move(t0));
	MetaProvider prov(m, 1, &reg);

	Json first = prov.collect();
	Json second = prov.collect();
	/* 引用列不入冻结缓存：每次 collect 都取实时快照 */
	TH_CHECK(reads == 2);
	TH_CHECK(first.get("count")->getInt() == 1);
	TH_CHECK(second.get("count")->getInt() == 2);
}

TH_TEST(metaprovider_unknown_reference_reports_clearly) {
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname src;\nr0 $ghost;\n@\n");
	bot::HwRegistry reg;
	MetaProvider prov(m, 1, &reg);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is not defined", prov.collect());
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "$ghost", prov.collect());
}

TH_TEST(metaprovider_scalar_reference_is_rejected) {
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname src;\nr0 $alias0;\n@\n");
	auto alias0 = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[](const Json&) { return JsonString("timer-0"); }));
	bot::HwRegistry reg;
	reg.add("alias0", std::move(alias0));
	MetaProvider prov(m, 1, &reg);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "non-object", prov.collect());
}

TH_TEST(metaprovider_vars_reference_fills_column_with_number) {
	/* @Vars 数值常量：$ 引用不再做「字段快照合并」，而是把数值文本写回承载 $ 的列；
	 * 运行时与 destroy 期都要解析。 */
	mt::MatrixObject vm = fx::oneMatrix("@Vars\nname value;\nspd 42;\n@\n");
	std::unique_ptr<MatrixVars_Hardware> vars = bot::MtVars_Vars::Factory(vm, 1);
	bot::HwRegistry reg;
	reg.add("spd", std::move(vars));

	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note src;\nr0 hello $spd;\n@\n");
	MetaProvider prov(m, 1, &reg);
	Json meta = prov.collect();
	TH_CHECK(meta.get("note")->getValue() == "hello");
	TH_CHECK(meta.get("src")->getValue() == "42");

	Json dmeta = prov.collectForDestroy();
	TH_CHECK(dmeta.get("src")->getValue() == "42");
}

TH_TEST(metaprovider_expression_reference_evaluates) {
	/* 元数据列写 $(...)：seed 解析/校验标识符，collect 惰性求值写回该列 */
	bot::HwRegistry reg;
	reg.add("v1", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv1 10;\n@\n"), 1));
	reg.add("v2", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv2 5;\n@\n"), 1));

	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note;\nr0 $(v1+v2+10);\n@\n");
	MetaProvider prov(m, 1, &reg);
	TH_CHECK(prov.collect().get("note")->getValue() == "25");
	TH_CHECK(prov.collectForDestroy().get("note")->getValue() == "25");
}

TH_TEST(metaprovider_expression_undefined_identifier_reports) {
	bot::HwRegistry reg;
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note;\nr0 $(ghost+1);\n@\n");
	MetaProvider prov(m, 1, &reg);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "ghost", prov.collect());
}

TH_TEST(metaprovider_circular_reference_hits_depth_guard) {
	/* C1 防线：$ 引用成环（这里经一个回入 collect() 的变量构造自引用）
	 * 必须被线程局部深度计数拦下并说人话，而不是无限互递归直到 SIGSEGV。 */
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname src;\nr0 $loop;\n@\n");
	std::function<Json()> reenter;
	bot::HwRegistry reg;
	reg.add("loop", std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[&reenter](const Json&) { return reenter(); })));
	MetaProvider prov(m, 1, &reg);
	reenter = [&prov]() { return prov.collect(); };

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "circular", prov.collect());
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "reference chain exceeds",
		prov.collect());
	/* 深度计数是 thread_local + RAII 递减：抛异常后必须已归零，
	 * 否则后续任何一次 collect() 都会被误判成环。 */
	mt::MatrixObject clean = fx::oneMatrix("@Relay\nname note;\nr0 hello;\n@\n");
	MetaProvider other(clean, 1, &reg);
	TH_CHECK(other.collect().toString() == R"({"note":"hello"})");
}

TH_TEST(metaprovider_destroy_keeps_reference_snapshot) {
	/* F-04′：destroy 期的元数据必须带上引用列快照。器件行的总线句柄 fd 与从机
	 * address 不是字面列，而是经 `$i2c-N` 从接口器件快照来的，drv_common 的
	 * i2c_pair 要用它们——只取字面列会让 PCA9685/MPU6050/BH1750 报
	 * "Invalid Argument: fd or address"，让十余个带 `if fd ~= nil` 守卫的
	 * 传感器静默丢失去初始化。 */
	mt::MatrixObject m = fx::oneMatrix(
		"@PCA9685\nname I2C address;\npca-0 $bus 0x40;\n@\n");
	Json snap = JsonObject();
	snap.put("result", JsonString("OK"));
	snap.put("fd", JsonInt(7));
	auto bus = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[snap](const Json&) { return snap; }));
	bot::HwRegistry reg;
	reg.add("bus", std::move(bus));

	MetaProvider prov(m, 1, &reg);
	Json meta = prov.collectForDestroy();
	TH_CHECK(meta.get("address") != std::nullopt);
	TH_CHECK(meta.get("address")->getValue() == "0x40");
	TH_CHECK(meta.get("fd") != std::nullopt);
	TH_CHECK(meta.get("fd")->getInt() == 7);
	/* 引用列本身（列名 I2C）不入元数据，只并入被引用方的快照字段 */
	TH_CHECK(meta.get("I2C") == std::nullopt);
	TH_CHECK(meta.get("name") == std::nullopt);
}

TH_TEST(metaprovider_destroy_skips_released_reference_without_aborting) {
	/* 引用已被销毁（数据前向引用链，如 Monitor→Ema→Daemon：引用者在倒序销毁里
	 * 反而最后出栈）——只跳过该引用，绝不抛错。F-04 要守的是「destroy 调用
	 * 本身绝不被跳过」，不是「不许解析引用」。 */
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note src;\nr0 hello $dead;\n@\n");
	auto dead = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[](const Json&) -> Json {
			throw bot::IllegalArgumentException(
				"read on 'x': Lua state not built or already released");
		}));
	bot::HwRegistry reg;
	reg.add("dead", std::move(dead));

	MetaProvider prov(m, 1, &reg);
	/* 运行期（play/build）仍必须响亮报错，不许静默吞掉 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "already released", prov.collect());

	/* 销毁期只跳过该引用：字面列照常返回，且不抛异常 */
	Json meta = prov.collectForDestroy();
	TH_CHECK(meta.get("note") != std::nullopt);
	TH_CHECK(meta.get("note")->getValue() == "hello");

	/* 深度计数是 thread_local + RAII：collectForDestroy 吞掉异常后必须已归零，
	 * 否则后续任何一次 collect() 都会被误判成引用成环。 */
	mt::MatrixObject clean = fx::oneMatrix("@Relay\nname note;\nr0 hello;\n@\n");
	MetaProvider other(clean, 1, &reg);
	TH_CHECK(other.collect().toString() == R"({"note":"hello"})");
}

TH_TEST(metaprovider_destroy_skips_err_reference_snapshot) {
	/* 守护槽已移交时 readSample 按 ERR 契约返回对象而非抛错；ERR 快照不是可用
	 * 元数据，必须跳过——否则 message/result 会被混进去初始化参数。 */
	mt::MatrixObject m = fx::oneMatrix("@Relay\nname note src;\nr0 hello $d0;\n@\n");
	Json errSnap = JsonObject();
	errSnap.put("result", JsonString("ERR"));
	errSnap.put("message", JsonString("sample slot not available"));
	auto d0 = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[errSnap](const Json&) { return errSnap; }));
	bot::HwRegistry reg;
	reg.add("d0", std::move(d0));

	MetaProvider prov(m, 1, &reg);
	Json meta = prov.collectForDestroy();
	TH_CHECK(meta.get("note") != std::nullopt);
	TH_CHECK(meta.get("note")->getValue() == "hello");
	TH_CHECK(meta.get("result") == std::nullopt);
	TH_CHECK(meta.get("message") == std::nullopt);
}

TH_TEST(registry_flowref_blocks_session_override) {
	/* N-6（controller/trigger 共用）：被结构引用列指向的名字，会话期 @Alias
	 * 不得覆盖——否则派发按名查到别名，报错与真实成因脱节。 */
	auto hw = std::unique_ptr<MatrixVars_Hardware>(new fx::LambdaHw(
		[](const Json&) { return JsonObject(); }));
	bot::HwRegistry reg;
	reg.add("t0", std::move(hw));
	reg.addFlowRef("t0");

	std::unique_ptr<bot::MtVars_Alias> alias = bot::MtVars_Alias::Factory(
		fx::oneMatrix("@Alias\nname alias;\nt0 duty;\n@\n"), 1);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "referenced as a controller or trigger",
		reg.override("t0", std::move(alias)));
}

TH_TEST(alias_matrix_requires_name_and_alias_columns) {
	mt::MatrixObject noName = fx::oneMatrix("@Alias\nalias;\nx;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no 'name' column",
		bot::MtVars_Alias::Factory(noName, 1));

	mt::MatrixObject noAlias = fx::oneMatrix("@Alias\nname;\nx;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no 'alias' column",
		bot::MtVars_Alias::Factory(noAlias, 1));
}

TH_TEST(alias_matrix_reads_its_target_column) {
	mt::MatrixObject m = fx::oneMatrix("@Alias\nname alias;\nspeed duty;\n@\n");
	std::unique_ptr<bot::MtVars_Alias> alias = bot::MtVars_Alias::Factory(m, 1);
	/* 别名变量 read() 返回目标列名字符串（供 @Action 列名二次解析） */
	TH_CHECK(alias->read().getValue() == "duty");
	/* "-" 继承：第二行未写 alias 时沿用上一行 */
	mt::MatrixObject m2 = fx::oneMatrix("@Alias\nname alias;\nspeed duty;\nfast -;\n@\n");
	std::unique_ptr<bot::MtVars_Alias> alias2 = bot::MtVars_Alias::Factory(m2, 2);
	TH_CHECK(alias2->read().getValue() == "duty");
}

TH_TEST(vars_matrix_requires_name_and_value_columns) {
	mt::MatrixObject noName = fx::oneMatrix("@Vars\nvalue;\nx;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no 'name' column",
		bot::MtVars_Vars::Factory(noName, 1));

	mt::MatrixObject noValue = fx::oneMatrix("@Vars\nname;\nx;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "no 'value' column",
		bot::MtVars_Vars::Factory(noValue, 1));
}

TH_TEST(vars_matrix_reads_its_numeric_value) {
	mt::MatrixObject m = fx::oneMatrix("@Vars\nname value;\nspd 42;\n@\n");
	std::unique_ptr<bot::MtVars_Vars> v = bot::MtVars_Vars::Factory(m, 1);
	/* read()/play() 均返回数值文本（供 $ 数值常量与 @Action 参数位替换） */
	TH_CHECK(v->read().getValue() == "42");
	TH_CHECK(v->play(JsonObject()).getValue() == "42");
	/* "-" 继承：第二行未写 value 时沿用上一行 */
	mt::MatrixObject m2 = fx::oneMatrix("@Vars\nname value;\nA 1;\nB -;\n@\n");
	std::unique_ptr<bot::MtVars_Vars> v2 = bot::MtVars_Vars::Factory(m2, 2);
	TH_CHECK(v2->read().getValue() == "1");
}

TH_TEST(vars_matrix_rejects_non_numeric_value) {
	/* @Vars 仅支持 Number：非数值字面量（含空值/nan/inf）在 Factory 处即报错，
	 * 与结构脚本 Number 列同一判定；合法格式（整数/小数/符号/科学计数法）通过。 */
	mt::MatrixObject bad = fx::oneMatrix("@Vars\nname value;\nspd fast;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "neither a Number",
		bot::MtVars_Vars::Factory(bad, 1));

	mt::MatrixObject nanv = fx::oneMatrix("@Vars\nname value;\nspd nan;\n@\n");
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "neither a Number",
		bot::MtVars_Vars::Factory(nanv, 1));

	mt::MatrixObject ok = fx::oneMatrix("@Vars\nname value;\na -1.5;\nb 2e3;\n@\n");
	TH_CHECK(bot::MtVars_Vars::Factory(ok, 1)->read().getValue() == "-1.5");
	TH_CHECK(bot::MtVars_Vars::Factory(ok, 2)->read().getValue() == "2e3");
}

namespace {

/* 与生产 resolver 同契约：查注册表、必须是 Vars、递归取数 */
std::function<double(const std::string&)> regResolver(const bot::HwRegistry* reg) {
	return [reg](const std::string& name) -> double {
		bot::MatrixVars_Hardware* hv = reg->find(name);
		if (hv == nullptr) {
			throw bot::IllegalArgumentException("expression references undefined '" + name + "'");
		}
		bot::MtVars_Vars* v = dynamic_cast<bot::MtVars_Vars*>(hv);
		if (v == nullptr) {
			throw bot::IllegalArgumentException("expression references non-Vars '" + name + "'");
		}
		return v->numericValue();
	};
}

} // namespace

TH_TEST(vars_expression_evaluates_lazily_and_tracks_override) {
	bot::HwRegistry reg;
	reg.add("v1", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv1 10;\n@\n"), 1));
	reg.add("v2", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv2 5;\n@\n"), 1));

	std::unique_ptr<bot::MtVars_Vars> v3 = bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv3 $(v1+v2+10);\n@\n"), 1, regResolver(&reg));
	TH_CHECK(v3->read().getValue() == "25");
	TH_CHECK(v3->play(JsonObject()).getValue() == "25");

	/* 惰性求值：覆盖 v2 后 v3 再读应反映新值（无需重建 v3） */
	reg.override("v2", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nv2 7;\n@\n"), 1));
	TH_CHECK(v3->read().getValue() == "27");
}

TH_TEST(vars_expression_cycle_is_detected) {
	bot::HwRegistry reg;
	/* a=$(b+1), b=$(a+1)：互相引用必须被深度计数拦下，而非栈溢出 */
	reg.add("a", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\na $(b+1);\n@\n"), 1, regResolver(&reg)));
	reg.add("b", bot::MtVars_Vars::Factory(
		fx::oneMatrix("@Vars\nname value;\nb $(a+1);\n@\n"), 1, regResolver(&reg)));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "circular @Vars",
		reg.find("a")->read());
}

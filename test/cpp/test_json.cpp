/* test_json.cpp —— 值语义 JSON 的契约固化
 *
 * Json 是 C++ 侧与 Lua 之间唯一的数据通货（play/read/元数据快照都走它），
 * 此前只有 E2E 间接覆盖。这里钉住四条容易被无声破坏的语义：
 *   1) 对象保插入序（Lua 侧 ffi 表转 JSON 后靠顺序做人类可读输出）
 *   2) 带型访问器一律抛 IllegalArgumentException，不静默转换
 *   3) 浮点走最短往返 + 整数型补 ".0"；NaN/Inf 序列化为 null（C8）
 *   4) Int 与 Float 分离，int64 大整数不经浮点保精度
 */

#include <cmath>
#include <limits>
#include <string>

#include "harness.hpp"
#include "json.hpp"
#include "util_except.hpp"

using bot::Json;
using bot::JsonArray;
using bot::JsonBool;
using bot::JsonFloat;
using bot::JsonInt;
using bot::JsonNull;
using bot::JsonObject;
using bot::JsonString;

TH_TEST(json_factory_type_predicates) {
	TH_CHECK(JsonNull().isNull());
	TH_CHECK(JsonBool(true).isBool());
	TH_CHECK(JsonInt(-7).isInt());
	TH_CHECK(JsonFloat(1.5).isFloat());
	TH_CHECK(JsonString("hi").isStr());
	TH_CHECK(JsonArray().isArr());
	TH_CHECK(JsonObject().isObj());
	/* 默认构造即 Null，与 JsonNull() 同型 */
	TH_CHECK(Json().isNull());
}

TH_TEST(json_accessors_reject_wrong_kind) {
	TH_CHECK(JsonInt(5).getInt() == 5);
	TH_CHECK(JsonString("s").getValue() == "s");
	TH_CHECK(std::abs(JsonFloat(2.25).getFloat() - 2.25) < 1e-12);
	TH_CHECK(JsonBool(false).getBool() == false);

	/* 错型访问必须报错，且报错里带上 kind 便于定位（不是裸崩） */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "asInt", JsonString("s").asInt());
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "wrong Json kind", JsonInt(1).getValue());
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "asObject", JsonArray().asObject());
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "asArray", JsonObject().asArray());
}

TH_TEST(json_object_keeps_insertion_order_and_overwrites_in_place) {
	Json o = JsonObject();
	o.put("zeta", JsonInt(1));
	o.put("alpha", JsonInt(2));
	o.put("mid", JsonInt(3));
	TH_CHECK(o.toString() == R"({"zeta":1,"alpha":2,"mid":3})");

	/* 同名覆盖：值换、位置不换（顺序稳定是 Lua 侧快照可读性的前提） */
	o.put("alpha", JsonString("x"));
	TH_CHECK(o.objSize() == 3);
	TH_CHECK(o.toString() == R"({"zeta":1,"alpha":"x","mid":3})");

	TH_CHECK(o.get("mid").has_value());
	TH_CHECK(o.get("mid")->getInt() == 3);
	TH_CHECK(!o.get("nope").has_value());
	TH_CHECK(o.get("nope") == std::nullopt);
}

TH_TEST(json_get_requires_object_receiver) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "asObject", JsonInt(1).get("k"));
}

TH_TEST(json_find_is_zero_copy_and_total) {
	/* F5-3：find 是零拷贝只读查找——命中返回对象内元素指针（身份可验），
	 * 缺失/非对象一律 nullptr（不抛，区别于 get 的旧契约）。 */
	Json o = JsonObject();
	o.put("a", JsonInt(1));
	o.put("b", JsonString("x"));
	const Json* pa = o.find("a");
	TH_CHECK(pa != nullptr && pa->getInt() == 1);
	/* 零拷贝：指针指向 items() 内部元素，非 optional 拷出 */
	TH_CHECK(pa == &o.items()[0].second);
	TH_CHECK(o.find("nope") == nullptr);
	/* 非对象：不抛、返回 nullptr（与 getPtr 口径一致） */
	TH_CHECK(JsonInt(1).find("k") == nullptr);
	TH_CHECK(JsonArray().find("k") == nullptr);
	TH_CHECK(JsonNull().find("k") == nullptr);
}

TH_TEST(json_put_on_non_object_throws) {
	/* F-19：put 对非对象显式报错——旧行为把整个值静默换成空对象，数据丢失 */
	Json j = JsonInt(42);
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "put", j.put("k", JsonInt(1)));
	TH_CHECK(j.isInt());
	TH_CHECK(j.getInt() == 42);
}

TH_TEST(json_array_index_bounds) {
	Json a = JsonArray();
	a.add(JsonInt(10));
	a.add(JsonString("b"));
	TH_CHECK(a.size() == 2);
	TH_CHECK(a.at(1).getValue() == "b");
	TH_CHECK(a.toString() == R"([10,"b"])");
	/* C-L3'：与全项目其余访问器统一抛 bot::IllegalArgumentException */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "index out of range", a.at(2));
	TH_CHECK(JsonArray().toString() == "[]");
	TH_CHECK(JsonObject().toString() == "{}");
}

TH_TEST(json_float_minimal_roundtrip) {
	/* 整数型浮点补 ".0"：让下游一眼区分 Float64 与 Int64 快照 */
	TH_CHECK(JsonFloat(1.0).toString() == "1.0");
	TH_CHECK(JsonFloat(0.0).toString() == "0.0");
	TH_CHECK(JsonFloat(2.5).toString() == "2.5");
	TH_CHECK(JsonFloat(-3.0).toString() == "-3.0");
	/* 最短往返：不输出 0.10000000000000001 这类噪声尾数 */
	TH_CHECK(JsonFloat(0.1).toString() == "0.1");
	/* 指数形态不再补 ".0" */
	TH_CHECK(JsonFloat(1e20).toString() == "1e+20");
}

TH_TEST(json_nan_inf_serialize_as_null) {
	const double nan = std::numeric_limits<double>::quiet_NaN();
	const double inf = std::numeric_limits<double>::infinity();
	/* C8：NaN/Inf 不是合法 JSON 字面量，输出 null 而非 "nan"/"inf" */
	TH_CHECK(JsonFloat(nan).toString() == "null");
	TH_CHECK(JsonFloat(inf).toString() == "null");
	TH_CHECK(JsonFloat(-inf).toString() == "null");

	Json o = JsonObject();
	o.put("v", JsonFloat(nan));
	TH_CHECK(o.toString() == R"({"v":null})");
}

TH_TEST(json_int64_not_routed_through_double) {
	/* 2^53+1：经 double 会掉精度，Int kind 必须原样往返 */
	const std::int64_t big = 9007199254740993LL;
	Json j = JsonInt(big);
	TH_CHECK(j.isInt());
	TH_CHECK(j.toString() == "9007199254740993");
	TH_CHECK(j.getInt() == big);
	TH_CHECK(JsonInt(std::numeric_limits<std::int64_t>::min()).toString()
		== "-9223372036854775808");
}

TH_TEST(json_string_escaping) {
	TH_CHECK(JsonString("").toString() == R"("")");
	TH_CHECK(JsonString("plain").toString() == R"("plain")");

	const std::string raw = std::string("a\"b\\c\nd\te") + "\x01" + "f";
	TH_CHECK(JsonString(raw).toString() == "\"a\\\"b\\\\c\\nd\\te\\u0001f\"");

	/* 非 ASCII（UTF-8 多字节）原样透传，不逐字节转 \uXXXX */
	TH_CHECK(JsonString("舵机").toString() == "\"舵机\"");
	/* 键名同样转义 */
	Json o = JsonObject();
	o.put(std::string("k") + "\n", JsonBool(true));
	TH_CHECK(o.toString() == "{\"k\\n\":true}");
}

TH_TEST(json_nested_serialize) {
	Json inner = JsonObject();
	inner.put("count", JsonInt(7));
	inner.put("v0", JsonFloat(1.5));
	Json arr = JsonArray();
	arr.add(inner);
	arr.add(JsonNull());
	Json outer = JsonObject();
	outer.put("snap", arr);
	TH_CHECK(outer.toString() == R"({"snap":[{"count":7,"v0":1.5},null]})");

	/* 嵌套对象经 get() 取出的是值拷贝，副本与原数组等值 */
	Json copy = *outer.get("snap");
	TH_CHECK(copy.isArr());
	TH_CHECK(copy.toString() == R"([{"count":7,"v0":1.5},null])");
}

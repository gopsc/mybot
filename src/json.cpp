#include "json.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>

#include "util_except.hpp"

namespace bot {

static void typeError(const char* what, Json::T t) {
	throw bot::IllegalArgumentException(
		std::string(what) + " called on the wrong Json kind (kind=" +
		std::to_string(static_cast<int>(t)) + ")");
}

const Json& Json::asObject() const { if (type != T::Obj) typeError("asObject", type); return *this; }
const Json& Json::asArray() const { if (type != T::Arr) typeError("asArray", type); return *this; }
const Json& Json::asString() const { if (type != T::Str) typeError("asString", type); return *this; }
const Json& Json::asInt() const { if (type != T::Int) typeError("asInt", type); return *this; }
const Json& Json::asFloat() const { if (type != T::Float) typeError("asFloat", type); return *this; }
const Json& Json::asBool() const { if (type != T::Bool) typeError("asBool", type); return *this; }

std::string Json::getValue() const { return asString().s; }
std::int64_t Json::getInt() const { return asInt().i; }
double Json::getFloat() const { return asFloat().d; }
bool Json::getBool() const { return asBool().b; }

std::optional<Json> Json::get(const std::string& key) const {
	const Json& o = asObject();	/* 旧契约保持：非对象接收者抛（见 json_get_requires_object_receiver） */
	(void)o;
	if (const Json* p = find(key)) { return *p; }
	return std::nullopt;
}

const Json* Json::find(const std::string& key) const {
	if (type != T::Obj) { return nullptr; }
	for (const auto& kv : obj) {
		if (kv.first == key) { return &kv.second; }
	}
	return nullptr;
}

Json* Json::getPtr(const std::string& key) {
	if (type != T::Obj) { return nullptr; }
	for (auto& kv : obj) {
		if (kv.first == key) { return &kv.second; }
	}
	return nullptr;
}

void Json::put(const std::string& key, Json v) {
	/* F-19：非对象显式报错——旧行为静默把整个值替换成空对象，数据丢失 */
	if (type != T::Obj) { typeError("put", type); }
	for (auto& kv : obj) {
		if (kv.first == key) { kv.second = std::move(v); return; }
	}
	obj.emplace_back(key, std::move(v));
}

const Json& Json::at(std::size_t n) const {
	const Json& a = asArray();
	if (n >= a.arr.size()) {
		/* C-L3'：统一用项目惯例的 bot::IllegalArgumentException——全项目其余
		 * 访问器（asObject/asArray/typeError）都抛它，上层统一 catch 才不漏接 */
		throw IllegalArgumentException("JsonArray index out of range");
	}
	return a.arr[n];
}

/* ---- 最短往返浮点表示（GCC ≥ 11 的 to_chars FP 保证最短往返；整数型补 ".0"）----
 * C8：NaN/Inf 非法 JSON，输出 null（与多数序列化器一致）。 */
static std::string formatDouble(double d) {
	if (d != d || d == std::numeric_limits<double>::infinity() ||
			d == -std::numeric_limits<double>::infinity()) {
		return "null";
	}
	char buf[64];
	auto res = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::general);
	std::string out(buf, res.ptr);
	if (out.find('.') == std::string::npos && out.find('e') == std::string::npos &&
			out.find('n') == std::string::npos && out.find('i') == std::string::npos) {
		out += ".0";
	}
	return out;
}

void jsonMergeInto(Json& dst, const Json& src) {
	const Json& s = src.asObject();
	for (const auto& kv : s.items()) {
		dst.put(kv.first, kv.second);
	}
}

/* 控制字符、引号、反斜杠才需要逐字节转义。base64（拍照回执的大头）全是
 * JSON 安全字符：逐字节 `out += c` 会把一次序列化变成数百万次小追加。
 * 先扫一遍，安全串整段 append。输出与慢路径逐字节相同。 */
static bool needsJsonEscape(const std::string& s) {
	for (unsigned char c : s) {
		if (c < 0x20 || c == '"' || c == '\\') { return true; }
	}
	return false;
}

static void escapeString(std::string& out, const std::string& s) {
	if (!needsJsonEscape(s)) {
		out.reserve(out.size() + s.size() + 2);
		out.push_back('"');
		out.append(s);
		out.push_back('"');
		return;
	}
	out += '"';
	for (unsigned char c : s) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20) {
					char buf[8];
					std::snprintf(buf, sizeof buf, "\\u%04x", c);
					out += buf;
				} else {
					out += static_cast<char>(c);
				}
		}
	}
	out += '"';
}

void Json::toStringImpl(const Json& j, std::string& out) {
	switch (j.type) {
		case T::Null: out += "null"; break;
		case T::Bool: out += j.b ? "true" : "false"; break;
		case T::Int: out += std::to_string(j.i); break;
		case T::Float: out += formatDouble(j.d); break;
		case T::Str: escapeString(out, j.s); break;
		case T::Arr:
			out += '[';
			for (std::size_t k = 0; k < j.arr.size(); ++k) {
				if (k) out += ',';
				toStringImpl(j.arr[k], out);
			}
			out += ']';
			break;
		case T::Obj:
			out += '{';
			for (std::size_t k = 0; k < j.obj.size(); ++k) {
				if (k) out += ',';
				escapeString(out, j.obj[k].first);
				out += ':';
				toStringImpl(j.obj[k].second, out);
			}
			out += '}';
			break;
	}
}

std::string Json::toString() const {
	std::string out;
	toStringImpl(*this, out);
	return out;
}

} // namespace bot
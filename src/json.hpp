#pragma once
/* json.hpp —— 值语义 JSON（等价 bot4cj 用到的 stdx.encoding.json 子集）
 * 单一 tagged struct + 工厂函数（JsonString(...) 等与 Cangjie 构造风格一致）。
 * 对象字段以 vector<pair<>,Json> 保插入序（Cangjie HashMap 亦保插入序）；
 * toString() 输出紧凑 JSON，浮点走最短往返表示（整数型浮点补 ".0"）。
 */

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace bot {

class Json {
public:
	enum class T { Null, Bool, Int, Float, Str, Arr, Obj };

	T type = T::Null;
	bool b = false;
	std::int64_t i = 0;
	double d = 0.0;
	std::string s;
	std::vector<Json> arr;
	std::vector<std::pair<std::string, Json>> obj;

	Json() = default;
	explicit Json(T t) : type(t) {}

	/* ---- 类型测试 ---- */
	bool isNull() const { return type == T::Null; }
	bool isBool() const { return type == T::Bool; }
	bool isInt() const { return type == T::Int; }
	bool isFloat() const { return type == T::Float; }
	bool isStr() const { return type == T::Str; }
	bool isArr() const { return type == T::Arr; }
	bool isObj() const { return type == T::Obj; }

	/* ---- 带型检查的访问器（错误类型抛 IllegalArgument）---- */
	const Json& asObject() const;
	const Json& asArray() const;
	const Json& asString() const;
	const Json& asInt() const;
	const Json& asFloat() const;
	const Json& asBool() const;

	std::string getValue() const;		/* Str 取值 */
	std::int64_t getInt() const;		/* Int 取值 */
	double getFloat() const;		/* Float 取值 */
	bool getBool() const;			/* Bool 取值 */

	/* ---- 对象操作 ---- */
	std::optional<Json> get(const std::string& key) const;
	/* F5-3：零拷贝只读查找——热路径（ensureOk、元数据合并）逐拍扫描大对象时
	 * 免去 get 的整值拷贝；不存在返回 nullptr。非对象也返回 nullptr（与
	 * getPtr 口径一致，不抛——调用点自判 res.isObj() 已在先）。 */
	const Json* find(const std::string& key) const;
	/* 就地取子对象指针（不存在返回 nullptr）：热路径逐拍更新子字段时
	 * 免去 get 拷出 + put 写回的两次深拷贝。指针在下次 put 本对象字段
	 * （可能引发 vector 重配）或本对象析构前有效（调用点仅对取到的
	 * 子对象继续 put，无失效窗口）。 */
	Json* getPtr(const std::string& key);
	void put(const std::string& key, Json v);	/* 同名覆盖，保持原序 */
	const std::vector<std::pair<std::string, Json>>& items() const { return obj; }
	std::size_t objSize() const { return obj.size(); }

	/* ---- 数组操作 ---- */
	std::size_t size() const { return arr.size(); }
	void add(Json v) { arr.push_back(std::move(v)); }
	const Json& at(std::size_t n) const;

	/* ---- 序列化 ---- */
	std::string toString() const;

private:
	static void toStringImpl(const Json& j, std::string& out);
};

/* ---- Cangjie 风格工厂（JsonString(name) 等直译原调用点）---- */
inline Json JsonNull() { return Json(Json::T::Null); }
inline Json JsonBool(bool v) { Json j(Json::T::Bool); j.b = v; return j; }
inline Json JsonInt(std::int64_t v) { Json j(Json::T::Int); j.i = v; return j; }
inline Json JsonFloat(double v) { Json j(Json::T::Float); j.d = v; return j; }
inline Json JsonString(const std::string& v) { Json j(Json::T::Str); j.s = v; return j; }
/* 移动重载：大字符串（base64 图像 ~2MB）从 luabridge 过来时 `std::string(s, n)`
 * 是临时量，走这条直接 move 进 j.s，省掉一次等大全量拷贝。 */
inline Json JsonString(std::string&& v) { Json j(Json::T::Str); j.s = std::move(v); return j; }
inline Json JsonArray() { return Json(Json::T::Arr); }
inline Json JsonObject() { return Json(Json::T::Obj); }

/* JsonObject 浅合并：把 src 的所有字段写入 dst（同名覆盖）。
 * N-15：原驻 hardware.cpp（元数据组装用），属 Json 值层操作，归位于此。 */
void jsonMergeInto(Json& dst, const Json& src);

} // namespace bot
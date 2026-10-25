/* luabridge.cpp —— Json↔Lua 桥接与 call_lua 单入口（N-17：自 luaend.cpp 拆分）
 *
 * 职责单一化：错误串、全局类型探测、Json↔Lua 递归互转（双向深度防线）、
 * call_lua 调用契约。进程内沙箱见 luasandbox.cpp；
 * 伞头 luaend.hpp 的对外声明不变。
 */

#include "luaend.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "debug_log.hpp"	/* logD */
#include "util_except.hpp"
#include "util_num.hpp"
#include "hardware.hpp"

namespace bot {

/* ---- 读取 Lua 栈顶错误对象为字符串 ----
 * lua_tolstring 对非 string/number 返回空指针——先判型；
 * string/number 原样转串，其余返回类型说明（issue #5 H5）。 */
std::string luaErrorString(lua_State* L) {
	int t = lua_type(L, -1);
	if (t == LUA_TSTRING || t == LUA_TNUMBER) {
		size_t n = 0;
		if (const char* s = lua_tolstring(L, -1, &n)) { return std::string(s, n); }
		return "<error tostring failed>";
	}
	return "<non-string error object, Lua type " + std::to_string(t) + ">";
}

/* ---- 探测全局变量类型（getglobal + type + pop，栈深不变）---- */

/* F5-2：luaGlobalType 的工作体。getglobal 可能执行 _G 的 __index 元方法
 * （驱动可给 _G 装元表）——任意驱动代码可在其中报错，必须经 pcall。 */
static int globalTypeClosure(lua_State* L) {
	const char* name = static_cast<const char*>(lua_touserdata(L, 1));
	lua_getglobal(L, name);
	int tp = lua_type(L, -1);
	lua_pop(L, 1);
	lua_pushinteger(L, tp);
	return 1;
}

int luaGlobalType(lua_State* L, const char* name) {
	/* F5-2：受保护帧内探测。__index 元方法报错（或 OOM longjmp）折成
	 * 「条目不存在」（LUA_TNIL）——调用方（luavar 的入口探测）走既有
	 * 的「入口缺失」ERR 契约，而不是无捕获 longjmp 裸崩。 */
	lua_pushcfunction(L, globalTypeClosure);
	lua_pushlightuserdata(L, const_cast<char*>(name));
	if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
		lua_pop(L, 1);		/* 弹出错误对象，栈深复原 */
		return LUA_TNIL;
	}
	int tp = static_cast<int>(lua_tointeger(L, -1));
	lua_pop(L, 1);
	return tp;
}

/* ---- NUL 防线（残留审计 #1）：C++ std::string 允许嵌入 '\0'，而 Lua 的
 * pushstring/setfield/getglobal 全按 C 字符串语义在首个 '\0' 处截断——
 * .mt 词法不把 '\0' 当分隔符，"servo.fd\0x" 这样的 @Action 参数键能通过
 * 上游 rejectReservedKeys 的全串比较，却在 setfield 处截断成 "servo.fd"
 * 覆盖结构元数据键（--tcp 场景等价于远程改总线句柄/从机地址/限幅）。
 * 收口：在 C++→Lua 边界统一拒绝任何含 '\0' 的键与字符串值，宁可报错也
 * 不让截断语义悄悄改掉键的含义。必须在压栈之前全量预校验——call_lua 的
 * 契约是异常路径不弄脏 Lua 栈，压栈中途抛出会跳过末尾的 lua_settop。 ---- */
static void rejectEmbeddedNul(const Json& val) {
	if (val.isStr()) {
		if (val.s.find('\0') != std::string::npos) {
			throw IllegalArgumentException("call_lua: string values must not contain"
				" a NUL byte (C-string truncation would silently change its meaning)");
		}
	} else if (val.isArr()) {
		for (std::size_t i = 0; i < val.size(); ++i) { rejectEmbeddedNul(val.at(i)); }
	} else if (val.isObj()) {
		for (const auto& kv : val.items()) {
			if (kv.first.find('\0') != std::string::npos) {
				/* 注意：错误文本不能内嵌原始键——它含 NUL，what() 经 c_str()
				 * 打印时会再次被截断，把诊断信息吞掉。只报长度与位置。 */
				throw IllegalArgumentException("call_lua: object key of length "
					+ std::to_string(kv.first.size()) + " must not contain a NUL byte"
					+ " — it would truncate at the Lua boundary and alias another field");
			}
			rejectEmbeddedNul(kv.second);
		}
	}
}

/* ---- 将 Json 值递归压入 Lua 栈（数组/对象转 Lua 表，H-03）----
 * N-15 深度防线：与读回方向（lua_value_to_json 的 C-9）对称——参数侧的
 * 自引用/超深嵌套同样无限递归，depth 计数在 kMaxLuaNesting 处抛
 * LuaNestingTooDeep（call_lua 就地转 ERR）。注意压栈是分步副作用，抛出后
 * 由 call_lua 的 lua_settop(L, top) 复原栈。 */
static void push_lua_value_impl(lua_State* L, const Json& val, int depth) {
	if (depth > kMaxLuaNesting) { throw LuaNestingTooDeep(kMaxLuaNesting); }
	if (val.isStr()) {
		lua_pushstring(L, val.s.c_str());
	} else if (val.isInt()) {
		lua_pushinteger(L, val.getInt());
	} else if (val.isFloat()) {
		lua_pushnumber(L, val.getFloat());
	} else if (val.isBool()) {
		lua_pushboolean(L, val.getBool() ? 1 : 0);
	} else if (val.isNull()) {
		lua_pushnil(L);
	} else if (val.isArr()) {
		lua_createtable(L, static_cast<int>(val.size()), 0);
		for (std::size_t i = 0; i < val.size(); ++i) {
			push_lua_value_impl(L, val.at(i), depth + 1);
			lua_rawseti(L, -2, static_cast<int>(i + 1));
		}
	} else if (val.isObj()) {
		lua_createtable(L, 0, 0);
		for (const auto& kv : val.items()) {
			push_lua_value_impl(L, kv.second, depth + 1);
			lua_setfield(L, -2, kv.first.c_str());
		}
	} else {
		logD([] { return "push_lua_value: unsupported JsonValue type, pushed nil"; });
		lua_pushnil(L);
	}
}

/* 仅本 TU 使用（阶段 5：自 luaend.hpp 伞头收窄为内部符号；depth 0 入口） */
static void push_lua_value(lua_State* L, const Json& val) {
	push_lua_value_impl(L, val, 0);
}

/* ---- 读取 Lua 栈上 idx 处的值并转换为 Json（递归）；表转 JsonArray/JsonObject ----
 * 调用前后栈深不变。
 * C-9 防线：每层嵌套表压一个 C++ 栈帧，只有碰到标量才终止——驱动返回自引用表
 * （t.self = t，最常见的笔误形态）即无限递归直到裸 SIGSEGV，无环但极深的表同理。
 * 用 depth 计数在 kMaxLuaNesting 处抛 LuaNestingTooDeep，由 call_lua 就地转 ERR。
 * 检查放在进入表分支的最开头（本层还没压任何东西），抛出时栈不受本层污染。 */
Json lua_value_to_json(lua_State* L, int idx, int depth);	/* 表分支递归用 */

/* 标量 → Json（数字/布尔/nil/字符串）。返回 false = 不是标量，由表分支接手。
 * 数字走 H-1 值域判据：NaN/inf/超出 int64 的 double 做 static_cast<long long>
 * 是未定义行为（UBSan float-cast-overflow 实证），非有限或超界直接走浮点分支，
 * 与 json.cpp 的序列化契约一致（非有限输出 null）。
 * 字符串取真实长度：lua_tolstring(L, idx, nullptr) 会在 '\0' 截断，驱动返回的
 * 含 NUL 字符串会被静默丢尾——反向 NUL 防线。 */
bool lua_scalar_to_json(lua_State* L, int idx, Json& out) {
	switch (lua_type(L, idx)) {
	case LUA_TNUMBER: {
		double d = lua_tonumber(L, idx);
		if (doubleFitsInt64(d)) {
			long long i = static_cast<long long>(d);
			out = (static_cast<double>(i) == d) ? JsonInt(i) : JsonFloat(d);
		} else {
			out = JsonFloat(d);
		}
		return true;
	}
	case LUA_TBOOLEAN:
		out = JsonBool(lua_toboolean(L, idx) != 0);
		return true;
	case LUA_TNIL:
		out = JsonNull();
		return true;
	case LUA_TSTRING: {
		size_t n = 0;
		if (const char* s = lua_tolstring(L, idx, &n)) { out = JsonString(std::string(s, n)); }
		else { out = JsonNull(); }
		return true;
	}
	default:
		return false;
	}
}

/* 表 → JsonArray / JsonObject。键的两种判据都在这里：
 *   L3 —— NaN / 超出 int64 的键做 static_cast<long long> 是 UB，与值路径共用
 *         util::doubleFitsInt64；先验后与 C7 非整键同路转字符串键保留数据；
 *   C7 —— 非整数数字键（如 3.5）截断会静默丢数据，同样转字符串键。
 * 调用前后栈深不变（表副本与键值各弹各的）。 */
Json lua_table_to_json(lua_State* L, int idx, int depth) {
	if (depth > kMaxLuaNesting) { throw LuaNestingTooDeep(kMaxLuaNesting); }
	std::vector<long long> arrKeys;
	std::map<long long, Json> arrVals;
	Json obj = JsonObject();
	lua_pushvalue(L, idx);			/* 表副本到栈顶 */
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		int keyType = lua_type(L, -2);
		if (keyType == LUA_TNUMBER) {
			double kd = lua_tonumber(L, -2);
			if (!doubleFitsInt64(kd)) {
				Json vj = lua_value_to_json(L, -1, depth + 1);
				obj.put(std::to_string(kd), vj);
			} else {
				long long k = static_cast<long long>(kd);
				if (static_cast<double>(k) != kd) {
					Json vj = lua_value_to_json(L, -1, depth + 1);
					obj.put(std::to_string(kd), vj);
				} else {
					Json vj = lua_value_to_json(L, -1, depth + 1);
					arrVals[k] = vj;
					arrKeys.push_back(k);
				}
			}
		} else if (keyType == LUA_TSTRING) {
			size_t kn = 0;
			if (const char* ks = lua_tolstring(L, -2, &kn)) {
				Json vj = lua_value_to_json(L, -1, depth + 1);
				obj.put(std::string(ks, kn), vj);
			}
		}
		lua_pop(L, 1);			/* 弹出值，保留键供下一次 Lua_next */
	}
	lua_pop(L, 1);				/* 弹出表副本 */
	if (!arrKeys.empty()) {
		/* 必须排序拷贝后按其迭代（同原实现对拷贝排序） */
		std::sort(arrKeys.begin(), arrKeys.end());
		if (obj.objSize() > 0) {
			/* 混合键表：整体转对象（数字键转字符串键），不丢字段 */
			for (long long k : arrKeys) { obj.put(std::to_string(k), arrVals[k]); }
			return obj;
		}
		Json arr = JsonArray();
		for (long long k : arrKeys) { arr.add(arrVals[k]); }
		return arr;
	}
	if (obj.objSize() > 0) { return obj; }
	return JsonArray();			/* 空表 → 空数组 */
}

/* Lua 栈上 idx 处的值 → Json（递归）；调用前后栈深不变。
 * 深度防线：每层嵌套表压一个 C++ 栈帧，只有碰到标量才终止——驱动返回自引用表
 * （t.self = t，最常见的笔误形态）即无限递归直到裸 SIGSEGV。超限抛
 * LuaNestingTooDeep，由 call_lua 就地转 ERR。检查放在进入表分支的最开头
 * （本层还没压任何东西），抛出时栈不受本层污染。 */
Json lua_value_to_json(lua_State* L, int idx, int depth) {
	Json scalar = JsonNull();
	if (lua_scalar_to_json(L, idx, scalar)) { return scalar; }
	if (lua_type(L, idx) == LUA_TTABLE) { return lua_table_to_json(L, idx, depth); }
	logD([&] {
		return "lua_value_to_json: unsupported Lua type " + std::to_string(lua_type(L, idx))
			+ ", returned null";
	});
	return JsonNull();
}

/* ---- F5-2：call_lua 的「取全局函数 + 造参数表 + 填参」整段搬进受保护帧 ----
 * lua_getglobal 会执行 _G 的 __index 元方法（驱动可装元表让任意驱动代码在
 * 宿主的 getglobal 期运行并报错）；lua_createtable/pushstring 会分配内存
 * （巨大 narr 或 OOM 即 LUA_ERRMEM）。这些 C-API 原先都在 pcall 之外——
 * 报错即无捕获越帧：longjmp 构建（默认源码构建）下 panic 后裸崩
 * （实测 exit 134/139，跳过 deactivate 清理链）；C++ unwind 构建下被宿主
 * 兜底 catch 折成含混的「non-standard exception」，真实报错文本全丢。
 * 两种形态都违反 ERR 契约。修法：整段进一个经 lua_pcall 的 C 闭包，Lua
 * 错误被 pcall 截住折成既有 ERR 契约；C++ 侧异常（LuaNestingTooDeep 等）
 * 在闭包内接住转 lua_error——**绝不穿透 Lua 帧**（C++ 异常与 longjmp 混越
 * 边界是 UB）。残余风险：pushcclosure 本身的微小分配仍在帧外，但它不受
 * 驱动输入控制（fixed-size Closure），不入判据。 */
static int prepareCallClosure(lua_State* L) {
	const Json* obj = static_cast<const Json*>(lua_touserdata(L, lua_upvalueindex(1)));
	const std::string* mode = static_cast<const std::string*>(lua_touserdata(L, lua_upvalueindex(2)));
	try {
		lua_getglobal(L, mode->c_str());
		/* 创建 Lua 表，装入全部字段 */
		lua_createtable(L, 0, 0);
		for (const auto& kv : obj->items()) {
			push_lua_value(L, kv.second);
			lua_setfield(L, -2, kv.first.c_str());
		}
		return 2;	/* [func, params] */
	} catch (const LuaNestingTooDeep& e) {
		/* N-15 参数侧深度防线：保持既有文案形态（原 call_lua 就地转 ERR 的措辞） */
		std::string msg = std::string("Lua function '") + mode->c_str()
			+ "' received " + e.what();
		lua_pushlstring(L, msg.c_str(), msg.size());
	} catch (const std::exception& e) {
		/* 其余 C++ 异常按 what() 折进 ERR；错误串构造自身 OOM 的极端残余
		 * 不再设防（catch 块内再抛将穿透 Lua 帧，属理论边界） */
		lua_pushlstring(L, e.what(), std::strlen(e.what()));
	}
	return lua_error(L);	/* longjmp 到外层 pcall——不穿透 Lua 帧 */
}

/* ---- 调用 Lua 脚本的全局 mode 函数（build/call/destroy/read）----
 * 每次调用后重置栈指针（恢复调用前栈深）。pcall 失败显式带 ERR 契约。
 *
 * 25.4 评估后判不改（102 行）：本函数的长度是**栈深记账**，不是控制流复杂度
 * ——进入时取 top，两条出口（准备段 pcall 失败的早退、末尾正常返回）都必须各自
 * lua_settop(L, top) 复原，中间全是相对栈下标（-nret / -1 / -2），其含义取决于
 * 此前压了几层。唯一像样的接缝是把契约表遍历那段（约 27 行）抽成 helper，
 * 但那正是 C1 防线记录过的出错面：
 * 旧实现就是因为 lua_pushnil 抬高栈顶后 -2 不再指向首个返回值，末值是标量时
 * lua_next 对非表调用直接 SIGSEGV（实测 Release exit 139）。把这段搬到调用边界
 * 另一边，等于让「栈上此刻有什么」这个编译器管不了的不变量跨函数传递。 */
Json call_lua(lua_State* L, const Json& json) {
	const Json& obj = json.asObject();
	Json ret = JsonObject();

	int top = lua_gettop(L);

	/* C4 防线：mode 缺失/非字符串时清晰报错，而非 bad_optional_access 裸异常 */
	auto modeField = obj.get("mode");
	if (!modeField || !modeField->isStr()) {
		throw IllegalArgumentException("call_lua: 'mode' field missing or not a string"
			" (expected build/call/destroy/read)");
	}
	std::string mode = modeField->getValue();
	rejectEmbeddedNul(obj);		/* NUL 防线：含 mode 在内全量预校验，栈尚未触碰 */

	/* F5-2：准备段整段入受保护帧（upvalue：Json 指针 + mode 指针，均指向
	 * 本函数栈上存活对象）。失败即 ERR 早退——原实现的「paramsPushed=false
	 * 则跳过 pcall」分支由该早退取代，末尾 settop 复原语义保持。 */
	lua_pushlightuserdata(L, const_cast<Json*>(&obj));
	lua_pushlightuserdata(L, static_cast<void*>(&mode));
	lua_pushcclosure(L, prepareCallClosure, 2);
	if (lua_pcall(L, 0, 2, 0) != LUA_OK) {
		std::string msg = luaErrorString(L);
		logD([&] { return "Lua call preparation failed: " + msg; });
		lua_settop(L, top);
		return makeErrResult(msg);
	}

	/* 栈：[func, params]，pcall 消费 func 与 params 各一层（准备段成功后必然执行） */
	{
		/* C3 防线：pcall 成功但返回 0 个值时，栈顶是调用前的旧栈顶——
		 * 以进入本函数时的栈深 top 为基准算返回值个数，nret > 0 才检查
		 * 返回值（否则会把无关栈上值当返回表遍历）。 */
		int status = lua_pcall(L, 1, LUA_MULTRET, 0);
		if (status == LUA_OK) {
			int nret = lua_gettop(L) - top;
			if (nret > 0 && lua_type(L, -nret) == LUA_TTABLE) {
				/* C1 防线（2026-09-20 审计）：契约表是**首个**返回值，遍历也必须
				 * 落在它上面。旧实现直接 lua_next(L, -2)：lua_pushnil 已把栈顶
				 * 抬高，-2 于是指向**最后一个**返回值——末值是标量时 lua_next
				 * 对非表调用直接 SIGSEGV（实测 Release exit 139），末值是表时
				 * 静默返回最后一个表、首个表的字段全丢且退出码 0。
				 * 这里先把首个返回值拷到栈顶，让 -1/-2 的语义与 nret 无关：
				 * pushvalue 后 [.. ret1 .. retN copy] → pushnil → lua_next(-2)
				 * 遍历的正是 copy（即 ret1）。多出来的 copy 由末尾 settop 复原。 */
				if (nret > 1) {
					logD([nret] {
						return "Lua returned " + std::to_string(nret)
							+ " values; only the first table is used (driver contract)";
					});
				}
				lua_pushvalue(L, -nret);	/* copy = 首个返回值（已判型为表） */
				lua_pushnil(L);
				while (lua_next(L, -2) != 0) {
					int keyType = lua_type(L, -2);
					if (keyType != LUA_TSTRING) {
						logD([keyType] { return "Lua return field skipped: key type " + std::to_string(keyType); });
						lua_pop(L, 1);		/* 弹出值，保留键供下一次 lua_next */
						continue;
					}
					size_t keyLen = 0;
					const char* keyPtr = lua_tolstring(L, -2, &keyLen);
					std::string key(keyPtr != nullptr ? keyPtr : "", keyPtr != nullptr ? keyLen : 0);
					Json val;
					try {
						val = lua_value_to_json(L, -1);
					} catch (const LuaNestingTooDeep& e) {
						/* C-9：就地转 ERR，绝不让它逃出去——call_lua 的调用方里
						 * freeImpl 是在 call_lua 之后才 lua_close 的，异常一逃就跳过
						 * 状态机关闭（泄漏），末尾的 lua_settop 也会被跳过而脏掉栈。 */
						/* makeErrResult 自带全新对象：丢弃已部分填充的字段，只留契约错误 */
						ret = makeErrResult("Lua function '" + mode + "' returned "
							+ e.what());
						break;
					}
					logD([&key, &val] { return std::string(key) + ": " + val.toString(); });
					ret.put(key, val);
					lua_pop(L, 1);
				}
				lua_pop(L, 1);		/* 弹出 copy（遍历用的那层） */
			} else {
				/* N3 防线：pcall 成功但首返回值不是表（少写 return → 0 个值，或返回
				 * nil/数字/字符串）。旧实现折成空表 {}，而 ensureOk 见「无 result 键」
				 * 即判成功——驱动漏 return 会被静默当成调用成功，硬件根本没动。 */
				std::string got = nret > 0
					? std::string("a non-table value (Lua type ") + lua_typename(L, lua_type(L, -nret)) + ")"
					: "no value";
				ret = makeErrResult("Lua function '" + mode + "' returned " + got
					+ "; the driver contract requires a table like {result=\"OK\", ...}");
			}
		} else {
			std::string errStr = luaErrorString(L);
			/* N-12：详情已在 message 字段达调用方（ensureOk 会带上下文抛出），
			 * stderr 双通道冗余打印降为 logD */
			logD([&] { return "Lua error details: " + errStr; });
			ret = makeErrResult(errStr);
		}
	}

	lua_settop(L, top);
	return ret;
}

} // namespace bot

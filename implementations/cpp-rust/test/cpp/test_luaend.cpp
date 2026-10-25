/* test_luaend.cpp —— Lua↔Json 边界（call_lua / lua_value_to_json / 深度上限）
 *
 * luaend.cpp 是宿主与 55 个驱动之间唯一的进出通道，此前只被 E2E 间接覆盖，
 * 一条深度契约都不曾直接测过——于是两类缺陷都能静默存活：
 *   C-9   驱动返回自引用表（t.self = t 这类笔误）→ 无界递归 → 裸 SIGSEGV
 *   泄漏  若在转换处把异常抛出去，call_lua 末尾的 lua_settop 与调用方
 *         freeImpl 里的 lua_close 都会被跳过（状态机脏 + 泄漏）
 * 因此这里的断言不只是「报错形态」，还包括「抛出后栈深复原」与「同一
 * lua_State 仍可继续服务下一次调用」——后者正是就地 catch 成 ERR 的理由。
 */

#include <memory>
#include <stdexcept>
#include <string>

#include "harness.hpp"
#include "json.hpp"
#include "luaend.hpp"
#include "util_except.hpp"

using bot::Json;
using bot::JsonArray;
using bot::JsonFloat;
using bot::JsonInt;
using bot::JsonObject;
using bot::JsonString;

namespace {

/* 独立 lua_State 的 RAII 持有者（本文件不碰沙箱，只开标准库） */
class State {
	lua_State* L_;

public:
	State() : L_(luaL_newstate()) {
		if (L_ == nullptr) { throw std::runtime_error("luaL_newstate failed"); }
		luaL_openlibs(L_);
	}
	~State() { if (L_ != nullptr) { lua_close(L_); } }
	State(const State&) = delete;
	State& operator=(const State&) = delete;

	lua_State* get() const { return L_; }
	int top() const { return lua_gettop(L_); }

	void chunk(const std::string& src) {
		if (luaL_dostring(L_, src.c_str()) != LUA_OK) {
			std::string err = bot::luaErrorString(L_);
			lua_settop(L_, 0);
			throw std::runtime_error("test chunk did not load: " + err);
		}
		lua_settop(L_, 0);
	}
};

Json callParams() {
	Json p = JsonObject();
	p.put("mode", JsonString("call"));
	p.put("x", JsonInt(1));
	return p;
}

/* 造一个恰好 n 层嵌套的全局表：RAW = {next={next=…{leaf=7}}} */
void setNestedGlobal(State& s, const char* name, int n) {
	std::string src = std::string(name) + " = { leaf = 7 }\n";
	for (int i = 0; i < n; ++i) { src += name + std::string(" = { next = ") + name + " }\n"; }
	s.chunk(src);
	lua_getglobal(s.get(), name);			/* 留在栈顶供转换 */
}

bool isErr(const Json& res) {
	auto r = res.get("result");
	return r && r->isStr() && r->getValue() == "ERR";
}

} // namespace

/* ---------------- C-9：自引用返回表 ---------------- */

TH_TEST(call_lua_turns_a_self_referential_result_into_err_instead_of_crashing) {
	State s;
	s.chunk("function call(data)\n"
		"  local t = { result = \"OK\" }\n"
		"  t.self = t\n"
		"  return t\n"
		"end\n");

	int before = s.top();
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(isErr(res));
	auto m = res.get("message");
	TH_CHECK(m && m->isStr());
	TH_CHECK(m->getValue().find("nests deeper than") != std::string::npos);
	/* 修复前这里是无限递归 → 栈溢出，根本走不到断言 */
	TH_CHECK(s.top() == before);
}

/* 就地 catch 的全部意义：状态机还能用（异常外逃会跳过调用方的 lua_close） */
TH_TEST(the_same_state_keeps_serving_after_a_nesting_error) {
	State s;
	s.chunk("function call(data)\n"
		"  local t = { result = \"OK\" }\n"
		"  t.self = t\n"
		"  return t\n"
		"end\n");
	Json bad = bot::call_lua(s.get(), callParams());
	TH_CHECK(isErr(bad));

	s.chunk("function call(data) return { result = \"OK\", v0 = 2.5 } end\n");
	Json good = bot::call_lua(s.get(), callParams());
	TH_CHECK(!isErr(good));
	TH_CHECK(good.get("v0") && good.get("v0")->getFloat() == 2.5);
}

/* ---------------- 深度上限的边界 ---------------- */

TH_TEST(lua_value_to_json_accepts_nesting_up_to_the_limit) {
	State s;
	setNestedGlobal(s, "RAW", bot::kMaxLuaNesting);

	/* 逐层走下去，确认不是「浅拷贝蒙过检查」而是整条链真的转换成功。
	 * 按值下沉：optional 是每轮的局部量，取它的地址会悬垂。 */
	Json cur = bot::lua_value_to_json(s.get(), -1);
	lua_pop(s.get(), 1);
	for (int i = 0; i < bot::kMaxLuaNesting; ++i) {
		auto next = cur.get("next");
		TH_CHECK(next.has_value());
		if (!next.has_value()) { return; }
		cur = *next;
	}
	TH_CHECK(cur.get("leaf") && cur.get("leaf")->getInt() == 7);
}

TH_TEST(lua_value_to_json_rejects_one_level_past_the_limit) {
	State s;
	setNestedGlobal(s, "RAW", bot::kMaxLuaNesting + 1);
	TH_CHECK_THROWS_MSG(bot::LuaNestingTooDeep, "nests deeper than",
		bot::lua_value_to_json(s.get(), -1));
	lua_pop(s.get(), 1);
}

/* ---------------- N-15：参数侧深度防线（push 方向） ---------------- */

namespace {

/* n 层嵌套数组包一个标量（最内层是标量），用于构造超深/边界参数值 */
Json nestedParams(int n) {
	Json v = JsonInt(1);
	for (int i = 0; i < n; ++i) {
		Json arr = JsonArray();
		arr.add(v);
		v = arr;
	}
	return v;
}

} // namespace

/* 参数同样不能无限深：C++ 侧 Json 虽不可能自引用，但程序化构造的超深表会让
 * push_lua_value_impl 无限递归。旧实现在压栈循环里抛出——异常逃出 call_lua，
 * 末尾 lua_settop 与调用方 freeImpl 的 lua_close 双双被跳过（状态机脏 + 泄漏）。
 * 现与返回侧（C-9）对称就地折 ERR，且压栈失败即中止本次调用（不真的调驱动）。 */
TH_TEST(call_lua_turns_too_deep_parameters_into_err_and_restores_stack) {
	State s;
	s.chunk("function call(data)\n"
		"  CALLED = true\n"
		"  return { result = \"OK\" }\n"
		"end\n");
	Json bad = callParams();
	bad.put("deep", nestedParams(bot::kMaxLuaNesting + 1));

	int before = s.top();
	Json res = bot::call_lua(s.get(), bad);

	TH_CHECK(isErr(res));
	auto m = res.get("message");
	TH_CHECK(m && m->isStr());
	TH_CHECK(m->getValue().find("nests deeper than") != std::string::npos);
	/* 修复前这里异常外逃 → 栈脏（走不到断言）；现末尾 lua_settop 复原 */
	TH_CHECK(s.top() == before);
	lua_getglobal(s.get(), "CALLED");
	TH_CHECK(lua_isnil(s.get(), -1));
	lua_pop(s.get(), 1);
}

/* 边界内不得误杀：恰好 kMaxLuaNesting 层仍能正常 round-trip */
TH_TEST(call_lua_accepts_parameters_within_the_depth_limit) {
	State s;
	s.chunk("function call(data)\n"
		"  return { result = \"OK\", seen = data.deep ~= nil }\n"
		"end\n");
	Json ok = callParams();
	ok.put("deep", nestedParams(bot::kMaxLuaNesting));

	Json res = bot::call_lua(s.get(), ok);
	TH_CHECK(!isErr(res));
	TH_CHECK(res.get("seen") && res.get("seen")->getBool());
	TH_CHECK(s.top() == 0);
}

/* 就地 catch 的全部意义：参数超深折 ERR 后状态机还能用 */
TH_TEST(the_same_state_keeps_serving_after_a_params_nesting_error) {
	State s;
	s.chunk("function call(data) return { result = \"OK\" } end\n");
	Json bad = callParams();
	bad.put("deep", nestedParams(bot::kMaxLuaNesting + 1));
	TH_CHECK(isErr(bot::call_lua(s.get(), bad)));

	s.chunk("function call(data) return { result = \"OK\", v0 = 5 } end\n");
	Json good = bot::call_lua(s.get(), callParams());
	TH_CHECK(!isErr(good));
	TH_CHECK(good.get("v0") && good.get("v0")->getInt() == 5);
}

/* ---------------- 回归护栏：既有形态不受影响 ---------------- */

TH_TEST(flat_sensor_results_still_round_trip) {
	State s;
	s.chunk("function call(data) return { result = \"OK\", v0 = 41.5, count = 3, ok = true } end\n");
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(!isErr(res));
	TH_CHECK(res.get("v0") && res.get("v0")->getFloat() == 41.5);
	TH_CHECK(res.get("count") && res.get("count")->getInt() == 3);
	TH_CHECK(res.get("ok") && res.get("ok")->getBool());
	TH_CHECK(s.top() == 0);
}

/* 数组式返回（nn.lua 的 W[层] 这类）是合法结构，不得被深度上限误杀 */
TH_TEST(nested_arrays_survive_the_conversion) {
	State s;
	s.chunk("function call(data) return { result = \"OK\", w = { {1, 2}, {3, 4} } } end\n");
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(!isErr(res));
	auto w = res.get("w");
	TH_CHECK(w && w->isArr() && w->size() == 2);
	TH_CHECK(w && w->at(1).isArr() && w->at(1).at(0).getInt() == 3);
}

/* ---------------- 2026-09-20 审计 C1：多值返回必须取「首个」 ---------------- */

/* 驱动多返回值时，契约表是**第一个**返回值（Java/Cangjie 原版语义亦然：
 * 只看首个返回表）。旧实现 lua_type(L, -nret) 判型看的是首个，随后
 * lua_pushnil 把栈顶抬高，lua_next(L, -2) 却落在**最后一个**返回值上：
 * 末值是标量 → lua_next 对非表调用 → 裸 SIGSEGV（实测 Release exit 139）；
 * 末值是表 → 静默返回最后一个表，首个表的字段全部丢失且退出码 0。
 * 这是「驱动违反返回契约」这条最该被折成清晰 ERR 的路径。 */
TH_TEST(call_lua_uses_the_first_table_when_a_driver_returns_several) {
	State s;
	s.chunk("function call(data)\n"
		"  return { result = \"OK\", a = 1 }, { result = \"OK\", b = 2 }\n"
		"end\n");

	int before = s.top();
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(!isErr(res));
	TH_CHECK(res.get("a") && res.get("a")->getInt() == 1);	/* 修复前丢失 */
	TH_CHECK(!res.get("b"));				/* 修复前误取第二个表 */
	TH_CHECK(s.top() == before);
}

/* 末值非表：修复前 lua_next 非表入参 → 段错误（不是 ERR、也不是 0 退出码） */
TH_TEST(call_lua_survives_a_scalar_after_the_result_table) {
	State s;
	s.chunk("function call(data)\n"
		"  return { result = \"OK\", a = 7 }, 42\n"
		"end\n");

	int before = s.top();
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(!isErr(res));
	TH_CHECK(res.get("a") && res.get("a")->getInt() == 7);
	TH_CHECK(s.top() == before);
}

/* 状态机在「末值非表」这条路径之后仍可继续服务（崩溃路径谈不上复原） */
TH_TEST(the_same_state_keeps_serving_after_a_multi_value_return) {
	State s;
	s.chunk("function call(data) return { result = \"OK\" }, \"extra\" end\n");
	Json first = bot::call_lua(s.get(), callParams());
	TH_CHECK(!isErr(first));

	s.chunk("function call(data) return { result = \"OK\", v0 = 3 } end\n");
	Json good = bot::call_lua(s.get(), callParams());
	TH_CHECK(good.get("v0") && good.get("v0")->getInt() == 3);
}

/* 首个返回值不是表但后面跟着表：仍必须走 N3 ERR 契约，不得因「后面有表」而放行 */
TH_TEST(call_lua_still_rejects_a_non_table_first_result_among_several) {
	State s;
	s.chunk("function call(data) return nil, { result = \"OK\", b = 2 } end\n");
	Json res = bot::call_lua(s.get(), callParams());
	TH_CHECK(isErr(res));
	TH_CHECK(!res.get("b"));
}

/* ---------------- 残留审计 #1：NUL 截断绕过防线 ---------------- */

/* .mt 词法不把 '\0' 当分隔符，参数键 "servo.fd\0x" 能通过上游 reserved-key
 * 的全串比较，但 lua_setfield(..., c_str()) 按 C 串截断成 "servo.fd"——
 * 等价远程覆盖总线句柄。防线：call_lua 压栈前全量拒绝含 NUL 的键/值。 */
TH_TEST(call_lua_rejects_a_params_key_with_embedded_nul) {
	State s;
	s.chunk("function call(data)\n"
		"  return { result = \"OK\", saw_fd = data.fd ~= nil }\n"
		"end\n");
	Json bad = callParams();
	bad.put(std::string("fd\0x", 4), JsonInt(9));

	int before = s.top();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "NUL byte",
		bot::call_lua(s.get(), bad));
	/* 异常路径不弄脏栈，状态机仍可继续服务 */
	TH_CHECK(s.top() == before);
	s.chunk("function call(data) return { result = \"OK\", v0 = 1 } end\n");
	TH_CHECK(!isErr(bot::call_lua(s.get(), callParams())));
}

/* 字符串值同样拒绝（嵌套在数组里也要拦住） */
TH_TEST(call_lua_rejects_a_string_value_with_embedded_nul) {
	State s;
	s.chunk("function call(data) return { result = \"OK\" } end\n");
	Json inner = JsonArray();
	inner.add(JsonString("ok"));
	inner.add(JsonString(std::string("a\0b", 3)));
	Json bad = callParams();
	bad.put("payload", inner);

	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "NUL byte",
		bot::call_lua(s.get(), bad));
	TH_CHECK(s.top() == 0);
}

/* 反方向：驱动返回含 NUL 的字符串，旧实现 lua_tolstring(..., nullptr) 静默
 * 丢尾——取真实长度保留全量数据（丢数据本身就是错误征兆，不截断藏错）。 */
TH_TEST(lua_value_to_json_preserves_embedded_nul_from_lua) {
	State s;
	s.chunk("function call(data) return { result = \"OK\", blob = \"a\\0b\" } end\n");
	Json res = bot::call_lua(s.get(), callParams());

	TH_CHECK(!isErr(res));
	auto blob = res.get("blob");
	TH_CHECK(blob && blob->isStr());
	TH_CHECK(blob && blob->getValue().size() == 3);
	TH_CHECK(blob && blob->getValue()[1] == '\0');
}

/* ---------------- L3：数字键转换去 UB ---------------- */

TH_TEST(oversized_number_keys_become_string_keys) {
	State s;
	/* Lua 表数字键可为超大数（t[1e300]=2）；NaN 键 LuaJIT 在赋值期即报
	 * "table index is NaN"，到不了转换层（isfinite 守卫是纵深防御）。
	 * 旧实现把键 static_cast<long long>——1e300 超界即未定义行为；
	 * 现与 C7 同路转字符串键保数据。 */
	s.chunk("T = {}\n"
		"T[1e300] = 2\n"
		"T[3] = 9\n");
	lua_getglobal(s.get(), "T");
	Json j = bot::lua_value_to_json(s.get(), -1);
	lua_pop(s.get(), 1);

	/* 混合键表整体转对象：超大数键原样进字符串键，整数键 3 并入为 "3" */
	TH_CHECK(j.isObj());
	TH_CHECK(j.get(std::to_string(1e300)) && j.get(std::to_string(1e300))->getInt() == 2);
	TH_CHECK(j.get("3") && j.get("3")->getInt() == 9);
}

/* ---------------- M3：dofile/loadfile 模块路径白名单 ---------------- */

/* 带沙箱的 State（与驱动/守护线程同路：openlibs + sandbox_lua） */
class SandboxState {
	lua_State* L_;

public:
	SandboxState() : L_(luaL_newstate()) {
		if (L_ == nullptr) { throw std::runtime_error("luaL_newstate failed"); }
		luaL_openlibs(L_);
		bot::sandbox_lua(L_);
	}
	~SandboxState() { if (L_ != nullptr) { lua_close(L_); } }
	SandboxState(const SandboxState&) = delete;
	SandboxState& operator=(const SandboxState&) = delete;

	lua_State* get() const { return L_; }

	/* 执行一段代码，失败时返回错误信息（不抛） */
	std::string run(const std::string& src) {
		if (luaL_dostring(L_, src.c_str()) == LUA_OK) {
			lua_settop(L_, 0);
			return "";
		}
		std::string err = bot::luaErrorString(L_);
		lua_settop(L_, 0);
		return err;
	}
};

/* 白名单内加载放行（以仓库真实 modules 树为准；CMake 工作目录即仓库根） */
TH_TEST(sandbox_dofile_allows_module_path) {
	SandboxState s;
	std::string err = s.run("dofile('./modules/lib/print_table.lua')");
	TH_CHECK(err.empty());
}

/* 白名单外绝对路径被拒，且错误信息带 sandbox 标记可诊断 */
TH_TEST(sandbox_dofile_rejects_outside_path) {
	SandboxState s;
	std::string err = s.run("dofile('/etc/hostname')");
	TH_CHECK(!err.empty());
	TH_CHECK(err.find("sandbox") != std::string::npos);
}

/* '..' 穿越被拒：路径字符串在白名单段之后紧跟 '..'，前缀 + '/' 规则不放行 */
TH_TEST(sandbox_dofile_rejects_dotdot_traversal) {
	SandboxState s;
	std::string err = s.run("dofile('./modules/../CMakeLists.txt')");
	TH_CHECK(!err.empty());
	TH_CHECK(err.find("sandbox") != std::string::npos);
}

/* loadfile 同规（mpath.lua 的存在性探测走同一条受限入口） */
TH_TEST(sandbox_loadfile_same_rule) {
	SandboxState s;
	std::string okErr = s.run("assert(loadfile('./modules/lib/mpath.lua'))");
	if (!okErr.empty()) { std::printf("[dbg] loadfile in-module err: %s\n", okErr.c_str()); }
	TH_CHECK(okErr.empty());
	TH_CHECK(!s.run("assert(loadfile('/etc/passwd'))").empty());
}

/* os.tmpname 被中和（可预测临时文件名是多用户主机上的符号链接竞争面，
 * 全仓驱动/守护 chunk 无一使用；与 os.execute 同组处理） */
TH_TEST(sandbox_neutralizes_os_tmpname) {
	SandboxState s;
	TH_CHECK(s.run("assert(os.tmpname == nil, 'os.tmpname must be neutralized')").empty());
	/* 中和不波及 os 表其余成员：getenv/time 是驱动合法依赖 */
	TH_CHECK(s.run("assert(type(os.getenv) == 'function' and type(os.time) == 'function')").empty());
}

/* A3（2026-09-20 审计）：require 不得绕过 dofile/loadfile 白名单。
 * 缺陷形态：dofile/loadfile 被包装后，`require` 仍走 package.loaders 里的
 * Lua 文件搜索器（C 层直接 luaL_loadfile），可加载模块树外的任意 .lua
 * （实测 require("evil_mod") 在 cwd 于树外时成功）。 */
TH_TEST(sandbox_require_cannot_load_files_outside_module_path) {
	SandboxState s;
	/* 文件搜索器被换成返回错误串的桩：require 必然失败并给出 sandbox 说明 */
	std::string err = s.run("require('definitely_not_a_preloaded_module')");
	TH_CHECK(!err.empty());
	TH_CHECK(err.find("sandbox") != std::string::npos);
	/* 路径搜索面同时关闭：loadlib 置 nil、path/cpath 清空 */
	TH_CHECK(s.run("assert(package.loadlib == nil, 'package.loadlib must be neutralized')").empty());
	TH_CHECK(s.run("assert(package.path == '', 'package.path must be cleared')").empty());
	TH_CHECK(s.run("assert(package.cpath == '', 'package.cpath must be cleared')").empty());
}

/* A3 的反向断言：驱动真实依赖的 require 必须仍然可用（ffi / bit 由 LuaJIT 的
 * preload 搜索器提供，与该收口正交；mpath 由宿主注册进 package.preload）。 */
TH_TEST(sandbox_require_still_serves_preloaded_modules) {
	SandboxState s;
	TH_CHECK(s.run("assert(type(require('ffi')) == 'table')").empty());
	TH_CHECK(s.run("assert(type(require('bit')) == 'table')").empty());
}

/* 被拒后状态机仍可用（错误走 lua_error，不污染后续调用） */
TH_TEST(sandbox_rejection_leaves_state_usable) {
	SandboxState s;
	(void)s.run("dofile('/etc/hostname')");
	std::string err = s.run("assert(1 + 1 == 2)");
	TH_CHECK(err.empty());
}

/* ---------------- C5：中和清单表驱动断言（2026-09-21 补全） ----------------
 * 此前只有 os.tmpname 单条断言；os.execute/exit/remove/rename 与 io 五件套
 * 无直接覆盖，「忘了中和」会绿。这里逐个断言：每个中和符号必须为 nil，
 * 每个保留符号（驱动合法依赖）必须仍可调用。 */

/* os 组中和的 5 项（luasandbox.cpp groups[0]，与实现同一份清单） */
TH_TEST(sandbox_neutralizes_all_os_entry_points) {
	SandboxState s;
	for (const char* fn : {"execute", "exit", "remove", "rename", "tmpname"}) {
		const std::string code = std::string("assert(os.") + fn
			+ " == nil, 'os." + fn + " must be neutralized')";
		const std::string err = s.run(code);
		if (!err.empty()) {
			std::printf("[FAIL] os.%s not neutralized: %s\n", fn, err.c_str());
		}
		TH_CHECK(err.empty());
	}
}

/* io 组中和的 5 项（luasandbox.cpp groups[1]） */
TH_TEST(sandbox_neutralizes_all_io_entry_points) {
	SandboxState s;
	for (const char* fn : {"popen", "open", "lines", "input", "output"}) {
		const std::string code = std::string("assert(io.") + fn
			+ " == nil, 'io." + fn + " must be neutralized')";
		const std::string err = s.run(code);
		if (!err.empty()) {
			std::printf("[FAIL] io.%s not neutralized: %s\n", fn, err.c_str());
		}
		TH_CHECK(err.empty());
	}
}

/* C5 反向断言：中和不得波及驱动合法依赖的保留符号。
 * 若这里红，说明中和清单过宽，「宁缺毋滥」被破坏，驱动生态会断。 */
TH_TEST(sandbox_preserves_driver_dependencies) {
	SandboxState s;
	/* 宿主注入 __mpath / package.preload["mpath"]，驱动引导样板依赖它 */
	TH_CHECK(s.run("assert(type(__mpath) == 'table', '__mpath injected')").empty());
	TH_CHECK(s.run("assert(type(package.preload['mpath']) == 'function')").empty());
	/* require 保留（仅 preload 面：ffi/bit），见 sandbox_require_still_serves_preloaded_modules */
	TH_CHECK(s.run("assert(type(require) == 'function')").empty());
	/* os 表其余成员仍在：getenv/time/clock 是驱动合法依赖 */
	TH_CHECK(s.run("assert(type(os.getenv) == 'function' and type(os.time) == 'function'"
		" and type(os.clock) == 'function')").empty());
	/* loadlib 必须中和（C 模块 dlopen 面），与 A3 一致 */
	TH_CHECK(s.run("assert(package.loadlib == nil, 'package.loadlib neutralized')").empty());
}


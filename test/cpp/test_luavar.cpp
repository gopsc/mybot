/* test_luavar.cpp —— @Action 参数与结构元数据的互斥契约（审计 #1 / C-1 防线）
 *
 * 动作参数与结构元数据最终合并成同一张 Lua 表交给驱动 call()。若 .mt 能写
 * `dev.note` / `dev.fd` / `dev.address` / `dev.max`，就等于动作脚本可以覆盖结构
 * 脚本定义的总线句柄、从机地址与舵机限幅——在 --tcp 模式下即远程改硬件拓扑。
 * 收口语义：结构元数据由 .sql 独占，.mt 只能引入新的参数键。
 *
 * 校验发生在 call_lua 之前，因此这些用例不需要任何 .lua 文件：
 * 放行路径会一路走到「未 build 的状态机」并由返回契约报错，据此区分两类错误。
 */

#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>

#include "harness.hpp"
#include "fixtures.hpp"
#include "json.hpp"
#include "luaexec.hpp"
#include "luavar.hpp"
#include "util_except.hpp"

using bot::Json;
using bot::JsonFloat;
using bot::JsonInt;
using bot::JsonObject;
using bot::JsonString;
using bot::MtVars_Lua;

namespace {

Json relayMetadata() {
	Json m = JsonObject();
	m.put("name", JsonString("relay0"));
	m.put("note", JsonString("hello-relay"));
	m.put("address", JsonInt(0x18));
	return m;
}

Json params(std::initializer_list<const char*> keys) {
	Json p = JsonObject();
	for (const char* k : keys) { p.put(k, JsonFloat(200.0)); }
	return p;
}

std::unique_ptr<MtVars_Lua> makeVar() {
	/* 第二参 forDestroy：true 走销毁期收集（字面列 + 引用列尽力而为快照，F-04′）
	 * ——本夹具不注入引用列，两条路径结果相同，故不区分。
	 * 无 controller：ctrlName/registry 走缺省值。 */
	return MtVars_Lua::Factory("./definitely-not-here-9f3a1c.lua", "relay0",
		[](bool) { return relayMetadata(); });
}

} // namespace

TH_TEST(action_param_may_not_shadow_structure_metadata) {
	auto v = makeVar();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "is rejected because",
		v->play(params({"note"})));
	/* 报错要点名「哪个变量的哪一列」并说明原因，便于用户直接改 .mt */
	try {
		v->play(params({"note"}));
	} catch (const std::exception& e) {
		const std::string msg = e.what();
		TH_CHECK(msg.find("Hardware variable 'relay0'") != std::string::npos);
		TH_CHECK(msg.find("@Action column 'relay0.note'") != std::string::npos);
		TH_CHECK(msg.find("structure-script metadata column") != std::string::npos);
	}
	/* 结构元数据里的任意列都受保护，不只是 note */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'relay0.name'", v->play(params({"name"})));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "'relay0.address'",
		v->play(params({"address"})));
}

TH_TEST(action_param_may_not_use_framework_reserved_keys) {
	auto v = makeVar();
	/* mode/result/message 由框架自己写入，动作脚本给同名键会污染契约判定 */
	for (const char* key : {"mode", "result", "message"}) {
		TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "framework-reserved key",
			v->play(params({key})));
	}
}

TH_TEST(action_param_with_a_new_key_is_allowed_through) {
	auto v = makeVar();
	/* 放行后一路走到未 build 的状态机，由返回契约报错——
	 * 关键是报错不得再是「保留键」那一类。 */
	std::string msg;
	try {
		v->play(params({"deg", "test"}));
	} catch (const std::exception& e) {
		msg = e.what();
	}
	TH_CHECK(msg.find("is rejected because") == std::string::npos);
	TH_CHECK(msg.find("Hardware call failed") != std::string::npos);
}

TH_TEST(empty_action_params_never_trip_the_guard) {
	auto v = makeVar();
	std::string msg;
	try {
		v->play(JsonObject());
	} catch (const std::exception& e) {
		msg = e.what();
	}
	TH_CHECK(msg.find("is rejected because") == std::string::npos);
}

TH_TEST(read_after_destroy_reports_instead_of_crashing) {
	/* 防御回归：状态机已释放时 read() 必须清晰报错，
	 * 而不是把空指针送进 LuaJIT（C1 环引用负路径实测暴露过的形态）。 */
	auto v = makeVar();
	/* 未 build 的变量全局 destroy 为 nil：跳过调用、释放状态机、不抛 */
	v->destroy();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Lua state not built", v->read());
	/* 二次销毁同样安全（幂等，不重复 lua_close） */
	v->destroy();
}

TH_TEST(play_after_destroy_reports_instead_of_crashing) {
	/* 与 read 同款防御：callImpl（play/playQuiet）此前缺 L_ 空守卫——destroy
	 * 之后的晚到派发会把空指针送进 LuaJIT（裸崩），而 read 路径却报得清清楚楚。 */
	auto v = makeVar();
	v->destroy();
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Lua state not built",
		v->play(params({"test"})));
	/* playQuiet 走同一入口，同样受守卫保护 */
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "Lua state not built",
		v->playQuiet(params({"test"})));
}

/* ---- controller/trigger 单元夹具（阶段 4；2.1 HwLookup 解耦的直接收益）----
 * 假注册表只实现只读查找接口；flow 目标是可配置回包并记录 play 输入的桩。
 * 驱动用真实 Lua 状态（.tmp 下最小 chunk），走完整 callImpl 编排——
 * 此前这一层只有 E2E 覆盖，单测需要装配完整 HwRegistry 而不可行。 */
namespace {

/* 记录收到的 play 输入并回放固定应答的桩 */
struct RecordingHw : bot::MatrixVars_Hardware {
	std::vector<Json> received;
	Json reply;
	explicit RecordingHw(Json r) : reply(std::move(r)) {}
	Json play(const Json& in) override { received.push_back(in); return reply; }
	const char* kindName() const override { return "test-stub"; }
};

class FakeLookup : public bot::HwLookup {
	std::map<std::string, bot::MatrixVars_Hardware*> byName_;

public:
	void put(const std::string& n, bot::MatrixVars_Hardware* h) { byName_[n] = h; }
	bot::MatrixVars_Hardware* find(const std::string& n) const override {
		auto it = byName_.find(n);
		return it == byName_.end() ? nullptr : it->second;
	}
	bool contains(const std::string& n) const override { return byName_.count(n) > 0; }
	/* 本夹具无 $(...) 列，求值器不被调用 */
	std::function<double(const std::string&)> makeVarsResolver() const override { return {}; }
	std::function<bot::ExprValue(const std::string&)> makeActionExprResolver() const override { return {}; }
};

std::string writeFlowDriver() {
	std::filesystem::create_directories(".tmp");
	std::string path = ".tmp/test_flow_drv.lua";
	std::ofstream f(path, std::ios::binary | std::ios::trunc);
	f << "function build(data) return { result = \"OK\" } end\n"
	  << "function call(data)\n"
	  << "  local t = data.trig0 and data.trig0.v0 or 0\n"
	  << "  return { result = \"OK\", t = t, c = data.c1 or 0 }\n"
	  << "end\n"
	  << "function destroy(data) return { result = \"OK\" } end\n";
	return path;
}

std::unique_ptr<MtVars_Lua> makeFlowVar(const std::string& path,
		FakeLookup& lookup, std::vector<std::string> ctrl,
		std::vector<std::string> trig) {
	return MtVars_Lua::Factory(path, "dev", [](bool) { return JsonObject(); },
		std::move(ctrl), std::move(trig), &lookup);
}

} // namespace

TH_TEST(trigger_result_is_merged_under_trigger_name_before_call) {
	FakeLookup lookup;
	RecordingHw trig0(JsonObject());
	auto trigReply = JsonObject();
	trigReply.put("result", JsonString("OK"));
	trigReply.put("v0", JsonFloat(1.5));
	RecordingHw trig0b(trigReply);
	lookup.put("trig0", &trig0b);
	std::string path = writeFlowDriver();
	auto dev = makeFlowVar(path, lookup, {}, {"trig0"});
	dev->build();
	Json res = dev->playQuiet(JsonObject());
	TH_CHECK(res.get("t")->getFloat() == 1.5);	/* 驱动从 data.trig0.v0 读到触发器结果 */
	TH_CHECK(trig0b.received.size() == 1);
	TH_CHECK(trig0b.received[0].isObj() && trig0b.received[0].items().empty());
	/* 触发以空参数调用（一次语义完整的 play），不是合并后的 payload */
}

TH_TEST(controller_fanout_sends_same_payload_and_returns_last) {
	FakeLookup lookup;
	auto r1 = JsonObject();
	r1.put("result", JsonString("OK"));
	r1.put("note", JsonString("one"));
	RecordingHw c1(r1);
	auto r2 = JsonObject();
	r2.put("result", JsonString("OK"));
	r2.put("note", JsonString("two"));
	RecordingHw c2(r2);
	lookup.put("c1", &c1);
	lookup.put("c2", &c2);
	std::string path = writeFlowDriver();
	auto dev = makeFlowVar(path, lookup, {"c1", "c2"}, {});
	dev->build();
	Json res = dev->playQuiet(JsonObject());
	TH_CHECK(res.get("note")->getValue() == "two");	/* 全部成功返回最后一个的结果 */
	TH_CHECK(c1.received.size() == 1);
	TH_CHECK(c2.received.size() == 1);
	/* 每个 controller 收同一份 payload（同列族不接力）：都含驱动返回表 */
	TH_CHECK(c1.received[0].get("result")->getValue() == "OK");
	TH_CHECK(c2.received[0].get("result")->getValue() == "OK");
}

TH_TEST(controller_err_halts_fanout_before_later_controllers) {
	FakeLookup lookup;
	auto bad = JsonObject();
	bad.put("result", JsonString("ERR"));
	bad.put("message", JsonString("bus NACK"));
	RecordingHw c1(bad);
	auto ok = JsonObject();
	ok.put("result", JsonString("OK"));
	RecordingHw c2(ok);
	lookup.put("c1", &c1);
	lookup.put("c2", &c2);
	std::string path = writeFlowDriver();
	auto dev = makeFlowVar(path, lookup, {"c1", "c2"}, {});
	dev->build();
	/* ensureOk 以 std::runtime_error 上抛（hardware.cpp ERR 契约） */
	TH_CHECK_THROWS_MSG(std::runtime_error, "bus NACK", dev->playQuiet(JsonObject()));
	TH_CHECK(c1.received.size() == 1);
	TH_CHECK(c2.received.size() == 0);	/* halt-on-error：后续 controller 不再被转发 */
}

/* ---- PL-2（2026-09-22）：执行预算窗口的 JIT 复原不变式 ----
 * 本机制靠「窗口内关 JIT」才能让指令计数钩子触发（LuaJIT 的 count 钩子只在
 * 解释器派发路径上跑）。代价可以接受，但**前提是窗口退出必须把 JIT 装回去**：
 * test/test_jit_warmup.lua 锁的是 HAL 变参 ABI 在 JIT 编译后的行为，
 * 它需要真机 /dev/i2c-*（本机跳过），所以那条路径在这里守不到——
 * 于是直接钉住不变式本身：arm 后关、disarm 后必须开。 */
static bool jitEngineOn(lua_State* L) {
	/* 括号截断不可省：jit.status() 返回 4 个值（状态 + 目标指令集名），
	 * 不截断时栈顶是最后一个字符串，lua_toboolean 恒为真——这个 bug 让用例
	 * 一度「arm 后仍报 JIT 开着」。 */
	if (luaL_dostring(L, "return (jit.status())") != LUA_OK) {
		lua_pop(L, 1);	/* 错误对象 */
		return false;
	}
	const bool on = lua_toboolean(L, -1) != 0;
	lua_pop(L, 1);
	return on;
}

TH_TEST(luaexec_arm_disarm_restores_jit_engine) {
	lua_State* L = bot::openSandboxedState();
	TH_CHECK(L != nullptr);
	TH_CHECK_MSG(jitEngineOn(L), "沙箱态初始应开着 JIT");

	bot::armLuaExecState(L);
	TH_CHECK_MSG(!jitEngineOn(L), "arm 后 JIT 必须关闭，否则 count 钩子不会触发");

	bot::disarmLuaExecState(L);
	TH_CHECK_MSG(jitEngineOn(L), "disarm 后 JIT 必须复原（test_jit_warmup.lua 的前提）");

	/* 幂等：重复 arm/disarm 不应把状态机留在半残 */
	bot::disarmLuaExecState(L);
	TH_CHECK(jitEngineOn(L));
	bot::armLuaExecState(L);
	bot::disarmLuaExecState(L);
	TH_CHECK(jitEngineOn(L));

	lua_close(L);
}

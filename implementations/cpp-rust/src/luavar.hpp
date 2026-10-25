#pragma once
/* luavar.hpp —— Lua 状态机硬件变量（移植 bot4cj/src/HV/Lua.cj）
 * Lua 状态机在工厂中提前创建；build() 加载脚本并跑一次 build，destroy() 释放。
 * controller 转发（出边）：元数据 ∪ 自己 Lua 返回表 → controller.play(payload)。
 * trigger 前置调用（入边）：先逐个 play trigger 列指向的变量，返回表以触发器
 * 名字为键并入调用参数，再运行自己的 Lua call——两者方向相反、共用一套
 * 引用登记（HwRegistry flowRefs）与「先声明」约束。
 */

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "hardware.hpp"
#include "luaend.hpp"
#include "luaexec.hpp"	/* armLuaExecState/disarmLuaExecState（armExecBudget 覆写用） */

namespace bot {

/* 2.1：只依赖 HwLookup 只读接口（hardware.hpp），不再前向引用 robot.hpp
 * 的 HwRegistry——装配层与 Lua 变量层经抽象解耦，测试可注入假实现。 */

class MtVars_Lua : public MatrixVars_Hardware {
	/* 顶层调用深度计数：只在外层 .mt 直接调用的原子处打印结果，
	 * 避免被 controller 转发的嵌套 Lua 调用重复输出。
	 * thread_local：controller 转发是同线程同步调用链，需跨实例共享计数；
	 * 而守护线程等并发路径各自独立，杜绝共享静态态的跨线程竞态。 */
	static thread_local int topDepth;

	/* ---- D（2026-09-23）：驱动返回表的**回收通道** ----
	 * play()（CallMode::Echo）的顶层回显此前只写 stderr：器件读到的值操作者看得见、
	 * **模型看不见**（run_action_script 的回执里一个字节的读数都没有）。这里加一条
	 * 同线程回收通道：非空时回显追加进它、**不再**写 stderr（工具回执随即把它带回
	 * 模型上下文，而那条回执本身也会被 verbose 日志打到同一条 stderr 流上，故不重复
	 * 打印同一份文本）。thread_local 与 topDepth 同款：只影响挂载它的线程——守护线程
	 * 等并发路径各自独立（其回显照旧走 stderr），不存在跨线程写入竞态。 */
	static thread_local std::string* callEchoSink;
	static void echoLine(const std::string& text);

	lua_State* L_;
	std::string luapath_;
	std::string name_;
	/* forDestroy=true 时走销毁期收集（MetaProvider::collectForDestroy）：
	 * 字面列 + 引用列的「尽力而为」快照——总线句柄 fd / 从机 address 正藏在
	 * 引用列里，去初始化（关断/断电/写寄存器）必须用它们；单个引用已释放时
	 * 只跳过该引用，不会让本驱动的 destroy 被跳过（F-04′）。 */
	std::function<Json(bool forDestroy)> getMetadata_;
	/* controller 转发引用（出边，可多列 = 扇出）：call 返回后，框架把「元数据 ∪
	 * 自己返回表」这同一份 payload 按列声明序逐个转发给这里的变量——同列族
	 * 不接力（跨变量链由目标自己的 controller 列表达）。任一返回 ERR 即停止：
	 * 不再转发给其余 controller，异常上抛整帧中断；全部成功时返回最后一个
	 * controller 的结果（单列与既有行为一致）。
	 * N-6：首次转发时把目标指针缓存进 ctrlPtrs_（注册表会拒绝会话期覆盖
	 * 引用名字，指针终身有效），后续转发不再逐次查表。 */
	std::vector<std::string> ctrlNames_;
	std::vector<MatrixVars_Hardware*> ctrlPtrs_;
	/* trigger 前置引用（入边）：当前零件每次 play 之前，框架先以空参数逐个
	 * 调用这里的变量，返回表以触发器名字为键并入调用参数。指针同 ctrl_ 一样
	 * 首用缓存——装配期已校验存在性且 flowRefs_ 拒绝会话期覆盖，指针终身有效。
	 * 只挂在 callImpl（play/playQuiet）上：read()/build/destroy 不触发。 */
	std::vector<std::string> trigNames_;
	std::vector<MatrixVars_Hardware*> trigPtrs_;
	HwLookup* registry_;

	explicit MtVars_Lua(lua_State* L, std::string luapath, std::string name,
			std::function<Json(bool)> getMetadata, std::vector<std::string> ctrlNames,
			std::vector<std::string> trigNames, HwLookup* registry)
		: L_(L), luapath_(std::move(luapath)), name_(std::move(name)),
		  getMetadata_(std::move(getMetadata)),
		  ctrlNames_(std::move(ctrlNames)), ctrlPtrs_(ctrlNames_.size(), nullptr),
		  trigNames_(std::move(trigNames)), trigPtrs_(trigNames_.size(), nullptr),
		  registry_(registry) {}

	/* ---- 一次 call 的三种出口形态（SAN-3，2026-09-22）----
	 * 原为 bool echo，agent 的重试判据需要"拿到 ERR 表本身"（表上带 http_status /
	 * curl_rc / retriable 等结构化字段），而 bool 表达不了第三种形态。 */
	enum class CallMode {
		Echo,	/* play()：顶层回显结果表（管道模式的动作进度输出） */
		Quiet,	/* playQuiet()：不回显；ERR 折成异常（agent 的模型调用走这条） */
		Raw,	/* playQuietRaw()：不回显；**ERR 时返回表**，由调用方自己判类 */
	};
	Json callImpl(const Json& json, CallMode mode);
	bool callEcho(CallMode m) const { return m == CallMode::Echo; }
	Json readImpl();
	void riseImpl();
	void freeImpl();

	/* PL-2：给本驱动的 lua_State 挂/摘执行预算钩子（budget=nullptr 即解除）。
	 * 由 RobotStruct 在 run_action_script 窗口内遍历注册表逐个调用——
	 * 必须覆盖全部 Lua 变量，因为 controller 转发/trigger 前置会走到别的 state。 */
	void armExecBudget(const LuaExecBudget* budget) override {
		if (budget != nullptr) { armLuaExecState(L_); } else { disarmLuaExecState(L_); }
	}

	/* C-1 防线：@Action 参数键与结构元数据键必须互斥（见 callImpl 注释） */
	void rejectReservedKeys(const Json& metadata, const Json& params) const;

	/* callImpl 的两段（阶段 3 拆分）：trigger 结果并入调用参数 /
	 * controller 扇出转发（注释与契约见实现处） */
	void mergeTriggerResults(Json& obj);
	Json forwardToControllers(const Json& metadata, const Json& res);

	/* flow 目标解析单点（N-6）：trigger/controller 首用把名字锁定为指针，
	 * 此后不再重查——注册表拒绝会话期覆盖引用名字，指针终身有效。未注册
	 * 即抛（装配期「先声明」约束保证目标存在，走到这里说明不变式被破坏）。 */
	MatrixVars_Hardware* flowTarget(std::vector<MatrixVars_Hardware*>& ptrs,
		const std::vector<std::string>& names, std::size_t k, const char* kind);

	static bool build_lua(lua_State* L, const std::string& luapath);

public:
	~MtVars_Lua() override {
		/* 防御：未成功销毁时（构造后/异常路径）不再泄漏状态机 */
		if (L_) { lua_close(L_); }
	}

	Json play(const Json& json) override { return callImpl(json, CallMode::Echo); }
	const char* kindName() const override { return "lua"; }
	/* agent 模式：同一个 call 路径但不回显结果（stdout 只留最终回答） */
	Json playQuiet(const Json& json) override { return callImpl(json, CallMode::Quiet); }
	/* SAN-3：ERR 时**返回表**而不是抛——agent 的传输层据此判定"这个错误可不可以
	 * 重试"（429/5xx 与 curl rc 都在这张表上）。表结构与 playQuiet 的成功返回一致
	 * （含 result/message 与驱动附加的 http_status / curl_rc / retriable /
	 * retry_after_ms），所以调用方拿到的永远是同一种形状。 */
	Json playQuietRaw(const Json& json) override { return callImpl(json, CallMode::Raw); }
	/* D（2026-09-23）：挂/摘回显回收通道（见 callEchoSink 注释）。**返回上一个值**，
	 * 调用方据此用 RAII 精确复原（异常路径也要复原，否则悬垂的 sink 指针会被后续
	 * 任何一次顶层 play() 写入）。传 nullptr 即恢复"写 stderr"的既有行为。 */
	static std::string* setCallEchoSink(std::string* sink) {
		std::string* prev = callEchoSink;
		callEchoSink = sink;
		return prev;
	}
	Json read() override { return readImpl(); }
	void build() override { riseImpl(); }
	void destroy() override { freeImpl(); }

	static std::unique_ptr<MtVars_Lua> Factory(const std::string& luapath, const std::string& name,
			std::function<Json(bool)> getMetadata, std::vector<std::string> ctrlNames = {},
			std::vector<std::string> trigNames = {}, HwLookup* registry = nullptr);
};

} // namespace bot
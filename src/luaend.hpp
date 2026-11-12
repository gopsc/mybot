#pragma once
/* luaend.hpp —— Lua 状态机辅助（移植 bot4cj/src/HV/Lua.cj 的公共部分）
 * 错误串、全局类型探测、沙箱、Json↔Lua 递归互转、call_lua 单入口。
 * N-17：实现拆为 luabridge.cpp（桥接/call_lua）与 luasandbox.cpp（沙箱），
 * 本伞头的对外声明不变。
 */

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <stdexcept>
#include <string>

#include "json.hpp"

namespace bot {

/* 读取 Lua 栈顶错误对象为字符串（判型防空指针） */
std::string luaErrorString(lua_State* L);

/* 探测全局变量类型（getglobal + type + pop，栈深不变） */
int luaGlobalType(lua_State* L, const char* name);

/* 收紧 Lua 沙箱：中和 os.execute/exit/remove/rename/tmpname、
 * io.popen/open/lines/input/output，dofile/loadfile 白名单化到模块路径内。
 *
 * **已声明的沙箱残余**（有意取舍而非遗漏，收紧它们会破坏驱动生态）：
 *   1. `load`/`loadstring` 未包裹——字符串源码不受路径白名单约束，模块树内
 *      驱动可自行加载任意字符串代码；
 *   2. `luaL_loadfile` 接受 LuaJIT 预编译字节码——白名单只限路径，不区分
 *      源码与字节码，字节码加载器是经典 LuaJIT 攻击面；
 *   3. `ffi` 本身即完整逃逸通道（调任意 C 符号/mmap/fork）——HAL、V4L2 直驱
 *      全依赖它，不可收紧。
 * 依据的威胁模型（docs/reference.md）：modules/ 下的 .lua 是信任级等同
 * mybot 用户的任意原生代码执行入口，本沙箱防「误用与路径穿越」，不对抗
 * 恶意驱动代码；若要把外部输入当不可信代码送进 Lua，必须先改威胁模型。 */
void sandbox_lua(lua_State* L);

/* 新建「标准库齐全 + 沙箱已收紧」的 Lua 状态；内存不足返回 nullptr。
 * 此前 luavar 与 daemonvar 各自 luaL_newstate + luaL_openlibs + sandbox_lua
 * 三连，靠注释约定同步。chunk 的 loadfile/pcall 不在此收口：两条路径的
 * 失败契约不同（daemon 区分 load/setup 两段报错；luavar 折成 bool）。 */
lua_State* openSandboxedState();

/* Lua↔Json 转换的嵌套深度上限（C-9 防线）。
 * 这是**语义**上限而非栈预算：8MB 栈容得下上万层，但「返回值嵌套 8 层以上」
 * 不可能是传感器读数——实测全部驱动的 build/call/destroy 返回都是一层扁平表
 * （result/message/v0..vN/count 全是标量），仓库里最深的结构是 nn.lua 的
 * W[层][神经元] 约 3 层。取 8 留一倍余量，超过即判定为自引用/畸形结构。
 * 一个上限同时挡住两种栈溢出：环（t.self=t，永不终止）与无环超深。 */
constexpr int kMaxLuaNesting = 8;

/* 超过 kMaxLuaNesting 时抛出（环与超深共用同一形态，故不区分） */
class LuaNestingTooDeep : public std::runtime_error {
public:
	explicit LuaNestingTooDeep(int limit)
		: std::runtime_error("Lua table nests deeper than " + std::to_string(limit)
			+ " levels; a hardware result is a flat table of scalars — this looks like a "
			+ "self-referential table (t.x = t) or an unintended recursive structure") {}
};

/* 将 Lua 栈上 idx 处的值递归转为 Json（int→字面整 判 Int，否则 Float）。
 * depth 由递归自身逐层传入，调用方留默认 0；超 kMaxLuaNesting 抛 LuaNestingTooDeep */
Json lua_value_to_json(lua_State* L, int idx, int depth = 0);

/* 调用 Lua 脚本的 mode 全局函数，传入表中字段；返回转换后的结果表。
 * 三条 ERR 路径：pcall 失败（并打印 Lua 错误详情）；pcall 成功但首返回值
 * 不是表（漏写 return / 返回标量）；返回值嵌套超深（LuaNestingTooDeep 就地
 * 转 ERR）——一律带 ERR 契约返回，不折成空表冒充成功。
 * 调用前后栈深不变（异常路径也复原，故该 lua_State 之后仍可安全复用）。 */
Json call_lua(lua_State* L, const Json& obj);

} // namespace bot
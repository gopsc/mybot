/* luasandbox.cpp —— Lua 沙箱收紧（N-17：自 luaend.cpp 拆分）
 *
 * 职责单一化：本文件只管「驱动进程内沙箱」——中和 os/io 危险入口、
 * dofile/loadfile 白名单化。Json↔Lua 桥接见 luabridge.cpp；
 * 伞头 luaend.hpp 的对外声明不变。
 */

#include "luaend.hpp"

#include <cstdio>
#include <cstring>
#include <string>

#include "util_file.hpp"
#include "util_path.hpp"

namespace bot {

/* '..' 判定单点（M2/B2-1）：util_path.hpp 的 hasDotDotComponent（按 '/'-段精确比较，
 * 不误伤含 '..' 子串的合法模块名，见审计 #8 注记）。 */

/* ---- 受限 dofile/loadfile 的路径校验（M3 收口）----
 * upvalue：1 = 白名单路径表（array 部分，每项一个允许前缀），2 = 原函数。
 * 白名单在 sandbox_lua 内由 BOT4CJ_MODULE_PATH（缺省 ./modules）逐段构建。
 * 放行条件：路径以某前缀开头且紧随 '/'（或恰好等于前缀本身），
 * 保证只能加载模块树内的文件，'..' 穿越依赖前缀逐字符比对天然失效。 */
static int restrictedLoader(lua_State* L) {
	luaL_checktype(L, 1, LUA_TSTRING);
	const char* path = lua_tostring(L, 1);

	lua_pushvalue(L, lua_upvalueindex(1));		/* 白名单表 */
	lua_pushnil(L);
	bool allowed = false;
	while (lua_next(L, -2) != 0) {
		const char* prefix = lua_tostring(L, -1);
		size_t len = prefix != nullptr ? lua_objlen(L, -1) : 0;
		if (prefix != nullptr
				&& strncmp(path, prefix, len) == 0
				&& (path[len] == '/' || path[len] == '\0')) {
			allowed = true;
		}
		lua_pop(L, 1);		/* 弹值留键 */
	}
	lua_pop(L, 1);			/* 弹白名单表 */

	if (!allowed) {
		return luaL_error(L, "sandbox: dofile/loadfile only allowed inside the module path (BOT4CJ_MODULE_PATH or ./modules), rejected: %s", path);
	}
	/* 前缀匹配挡不住 './modules/../CMakeLists.txt' 这类穿越（前缀后紧跟 '/'），
	 * 拒绝任何含 '..' 路径分量的请求；按分量精确比较而非子串匹配——审计 #8：
	 * strstr 会误拒含 '..' 子串的合法模块名（foo..bar.lua 之类）。判据单点：util。 */
	if (hasDotDotComponent(path)) {
		return luaL_error(L, "sandbox: dofile/loadfile path must not contain '..' component (traversal rejected): %s", path);
	}

	/* BQ-2：白名单只保证「路径在模块树内」，不保证「文件没被别人改写」——
	 * ffi 全能力的信任前提体检（组/他可写 → 响亮告警，判据单点 util_file）。 */
	auditTrustedFilePath(path, "沙箱加载文件");

	lua_pushvalue(L, lua_upvalueindex(2));		/* 原函数 */
	lua_pushvalue(L, 1);						/* path */
	/* 多返回值必须原样透传（2026-09-21 第七轮审计）：旧实现是 lua_call(L, 1, 1)，
	 * 把结果截到 1 个——而 `loadfile` 的契约是 `(chunk, errmsg)`。截断的后果是
	 * modules/lib/sensor_daemon_multi.lua 里 `local f, err = loadfile(drvpath)` 的
	 * err **恒为 nil**，于是 fail(-8, "cannot load driver: " .. tostring(err)) 永远
	 * 只打出 "(nil)"，多器件守护的"驱动加载失败"查不到成因。
	 * 用 LUA_MULTRET 并把实际结果个数回报给 Lua（dofile 现网 chunk 只回 1 值，
	 * 语义不变；loadfile 的失败路径从此拿得到 errmsg）。
	 * 注：额外实参（loadfile 的 mode/env）不转发——这是本包装的既有行为，
	 * 缺省 mode 即 "bt"，故只对显式收窄 mode 的调用者有差别。 */
	const int nargs = lua_gettop(L) - 2;		/* 调用前的入参个数（不含刚压的两个） */
	lua_call(L, 1, LUA_MULTRET);
	return lua_gettop(L) - nargs;
}

/* ---- 收紧 Lua 沙箱（issue #9 M1 可落地部分；M3 补 dofile/loadfile 收口）----
 * 保留 os.getenv/product、os.time|clock、require（驱动仅取 ffi/bit）；
 * 中和可直接破坏宿主的入口：os.execute/exit/remove/rename、io 五件套，
 * 并把全局 dofile/loadfile 限制到模块路径白名单内（驱动经 mpath.resolve
 * 加载 lib 目录下脚本的既有用法不变，'..' 穿越与绝对路径外读被拒绝）。
 * os.tmpname 一并中和：返回可预测路径的临时文件，是多用户主机上符号链接
 * 竞争的经典面，而全仓驱动与守护 chunk 无一使用它（仅独立 luajit 测试
 * test_camera.lua 在沙箱外用）。各全局缺表时跳过对应组。 */
/* M3：dofile/loadfile 白名单表。白名单来自 BOT4CJ_MODULE_PATH（':' 分段，
 * 去空），缺省 "./modules"——与 modules/lib/mpath.lua 的 paths() 同语义。
 * 白名单为空不可能（缺省值兜底），仍防御：空表时 restrictedLoader 全拒。 */
static void pushModuleWhitelist(lua_State* L) {
	lua_createtable(L, 0, 0);
	int n = 0;
	for (const std::string& p : splitModulePaths(modulePaths())) {
		lua_pushlstring(L, p.data(), p.size());
		lua_rawseti(L, -2, ++n);
	}
}

/* M3：把全局名 name 指向的原加载函数包上白名单校验（restrictedLoader）。
 * pushcclosure 的 upvalue 编号：先压的值 = index 1。restrictedLoader 约定
 * upvalue(1)=白名单表、(2)=原函数——故压入原函数后用 insert 把表拷贝
 * 挪到其下方，再 pushcclosure 恰好消耗这两个值。
 * （阶段 3 拆分注记：dofile/loadfile 两段此前逐字同构，收敛为本函数。） */
static void wrapLoader(lua_State* L, const char* name) {
	lua_getglobal(L, name);
	lua_pushvalue(L, 1);		/* 白名单表拷贝 */
	lua_insert(L, -2);			/* 顺序调整为 [表, 原函数] */
	lua_pushcclosure(L, restrictedLoader, 2);
	lua_setglobal(L, name);
}

/* ---- 阶段 2：宿主注入模块路径解析器（__mpath）----
 * 驱动文件的第一行需要先找到 lib/mpath.lua 才能解析其它 lib 文件。此前
 * 59 个驱动各自用 `(env):match("[^:]+")` **只取首段**，于是
 * docs/reference.md 承诺的「':' 分隔多路径按序查找」对全部器件驱动不成立
 * （首段不含 lib/ 时驱动加载即失败）。
 * 现在由宿主做这一跳：按模块路径逐段探测 lib/mpath.lua（util::findExistingModule），
 * 加载后注入全局 __mpath，并同时注册 package.preload["mpath"]（供未来
 * 驱动改写为 require("mpath")）。驱动侧统一写成
 *     local mpath = __mpath or dofile(<单根回退>)
 * ——回退分支只在**没有宿主**时走到（luajit 直跑测试、scscl_scan.lua、
 * virtbus.load_driver），那些场景下仓库根布局固定、单根即正确。
 * 失败仍走 fail-open（注入不了就不改变行为），但 BQ-2 起**响亮**：
 * 加载失败（mpath.lua 坏了）或「多段路径里一段都找不到」意味着 docs 承诺的
 * 多路径解析在宿主侧已经缺位——静默跳过会让「按序查找」退化成驱动各自的
 * 首段猜测且无任何线索。单段路径找不到不告警（单根回退对单根配置语义等价，
 * 也是 .tmp 类测试夹具的常态）。每进程一次。 */
static void warnMpathUnavailable(const char* why) {
	static bool warned = false;
	if (warned) { return; }
	warned = true;
	std::fprintf(stderr,
		"警告: 宿主未能注入 __mpath 模块路径解析器（%s）——"
		"驱动将退回各自模块路径首段的单根猜测，':' 分隔多路径按序查找"
		"在此进程内不成立\n", why);
}

static int returnUpvalue(lua_State* L) {
	lua_pushvalue(L, lua_upvalueindex(1));
	return 1;
}

/* ---- A3（2026-09-20 审计）：require 不得绕过 dofile/loadfile 白名单 ----
 *
 * 缺陷（本机复现）：dofile/loadfile 被包上 restrictedLoader 后看似只能加载
 * 模块树内的文件，但 `require` 走的是 package.loaders，其中的 Lua 文件搜索器
 * 在 **C 里直接 luaL_loadfile**，完全不经过被包装的全局函数；package.path 也
 * 可写。实测（cwd 在模块树外）：
 *     dofile("/.../outside/evil_mod.lua")  → rejected by sandbox
 *     require("evil_mod")                  → 加载成功并返回其内容
 * 即 hal.md/reference.md「只能加载模块树内的文件」的不变式不成立，且该残余
 * 未列入文件头声明的清单。
 *
 * 收口策略（保能力、不保任意路径读）：
 *   ① 保留 preload 搜索器 —— `require("ffi")` / `require("bit")` 全仓唯一的
 *      两个真实 require 都靠它（LuaJIT 把 ffi 注册为 preload；bit 在
 *      package.loaded），与文件系统无关，正是驱动需要的；
 *   ② 用**返回错误串**的桩替换 Lua 文件搜索器与 C 搜索器 —— require 失败时
 *      Lua 把各搜索器的返回值拼成错误信息，于是报错会明确指向「沙箱只允许
 *      模块树内的文件」，而不是含混的 module not found；
 *   ③ package.loadlib 置 nil（dlopen 任意 .so 是比读文件更大的面）；
 *   ④ package.path 清空 —— 文件搜索器已不可达，清空只是让下一个人不会
 *      误以为路径搜索仍然生效。
 * 与 dofile/loadfile 同一判据：驱动要用文件就必须走 mpath.resolve + dofile。
 * 说明：本沙箱是「防误用护栏，不是安全边界」（hal.md 信任边界节，ffi.C 仍是
 * 完整 libc），本条收口的是**声明与实现的一致性**。 */
static int disabledFileSearcher(lua_State* L) {
	lua_pushstring(L, "sandbox: require() may only load preloaded/built-in modules"
		" (ffi/bit/jit.*); loading a Lua file by module name is disabled"
		" — use dofile(mpath.resolve(...)) so the module-path whitelist applies");
	return 1;
}

static int disabledCSearcher(lua_State* L) {
	lua_pushstring(L, "sandbox: require() of a C module is disabled"
		" (package.loadlib/dlopen is not available to drivers)");
	return 1;
}

static void restrictRequireLoaders(lua_State* L) {
	lua_getglobal(L, "package");
	if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); return; }
	/* loaders[2] = Lua 文件搜索器、loaders[3] = C 搜索器（LuaJIT 5.1 布局）；
	 * loaders[1] 是 preload 搜索器，必须原样保留（ffi/bit/mpath 靠它）。
	 * loadlib 另行置 nil。返回错误串而非 nil：错误信息里就能看见「被沙箱拒绝」
	 * 而不是「没找到模块」。 */
	lua_getfield(L, -1, "loaders");
	if (lua_type(L, -1) == LUA_TTABLE) {
		lua_pushcfunction(L, disabledFileSearcher);
		lua_rawseti(L, -2, 2);
		lua_pushcfunction(L, disabledCSearcher);
		lua_rawseti(L, -2, 3);
	}
	lua_pop(L, 1);
	lua_pushnil(L);
	lua_setfield(L, -2, "loadlib");
	lua_pushstring(L, "");
	lua_setfield(L, -2, "path");
	lua_pushstring(L, "");
	lua_setfield(L, -2, "cpath");
	lua_pop(L, 1);
}

static void injectModulePathResolver(lua_State* L) {
	auto found = findExistingModule(modulePaths(), "lib/mpath.lua");
	if (!found) {
		/* BQ-2：多段配置一段都找不到 = 「按序查找」承诺缺位，响亮；
		 * 单段找不到 = 单根回退语义等价（测试夹具常态），保持静默。 */
		if (splitModulePaths(modulePaths()).size() > 1) {
			warnMpathUnavailable("任何模块路径段都未找到 lib/mpath.lua");
		}
		return;
	}
	if (luaL_loadfile(L, found->c_str()) != LUA_OK) {
		lua_pop(L, 1);
		warnMpathUnavailable("lib/mpath.lua 语法加载失败");
		return;
	}
	if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
		lua_pop(L, 1);
		warnMpathUnavailable("lib/mpath.lua 执行失败");
		return;
	}
	if (lua_type(L, -1) != LUA_TTABLE) {
		lua_pop(L, 1);
		warnMpathUnavailable("lib/mpath.lua 未返回模块表");
		return;
	}

	/* package.preload["mpath"] = function() return <表> end */
	lua_pushvalue(L, -1);						/* [t, t] */
	lua_pushcclosure(L, returnUpvalue, 1);		/* [t, loader] */
	lua_getglobal(L, "package");				/* [t, loader, package] */
	if (lua_type(L, -1) == LUA_TTABLE) {
		lua_getfield(L, -1, "preload");			/* [t, loader, package, preload] */
		if (lua_type(L, -1) == LUA_TTABLE) {
			lua_pushvalue(L, -3);				/* [..., preload, loader] */
			lua_setfield(L, -2, "mpath");
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	lua_pop(L, 1);
	lua_setglobal(L, "__mpath");				/* [] */
}

/* ---- P1-2：print → stderr 单点收口 ----
 * 驱动层 print() 默认走 stdout，与宿主的日志/诊断流（stderr）分离，导致：
 * ① 守护进程 stdout 被驱动输出污染，日志收集管道拿不到带时间戳的驱动诊断；
 * ② 48+ 驱动各自 print 混在业务输出里，故障定位时无法按流过滤。
 * 在沙箱层统一重定向——单点覆盖全部驱动，无需逐文件改。
 * 语义对齐 Lua 原生 print：参数间 tab 分隔、末尾换行、tostring 转换。 */
static int stderrPrint(lua_State* L) {
	const int n = lua_gettop(L);
	for (int i = 1; i <= n; ++i) {
		if (i > 1) { std::fputc('\t', stderr); }
		const char* s = lua_tostring(L, i);
		if (s != nullptr) {
			std::fputs(s, stderr);
		} else {
			/* 非字符串/数字：用类型名兜底（对齐 Lua 5.1 print 行为） */
			std::fprintf(stderr, "%s: %p", lua_typename(L, lua_type(L, i)), lua_topointer(L, i));
		}
	}
	std::fputc('\n', stderr);
	return 0;
}

void sandbox_lua(lua_State* L) {
	struct Group { const char* tab; const char* keys[5]; int n; };
	static const Group groups[] = {
		{"os", {"execute", "exit", "remove", "rename", "tmpname"}, 5},
		{"io", {"popen", "open", "lines", "input", "output"}, 5},
	};
	for (const auto& g : groups) {
		lua_getglobal(L, g.tab);
		if (lua_type(L, -1) == LUA_TTABLE) {
			for (int i = 0; i < g.n; ++i) {
				lua_pushnil(L);
				lua_setfield(L, -2, g.keys[i]);	/* 表在 -2 */
			}
		}
		lua_pop(L, 1);
	}

	/* P1-2：print → stderr，驱动诊断统一走 stderr（与宿主日志流同通道）。 */
	lua_pushcfunction(L, stderrPrint);
	lua_setglobal(L, "print");

	pushModuleWhitelist(L);
	wrapLoader(L, "dofile");
	wrapLoader(L, "loadfile");

	/* A3：require 的文件/C 搜索器收口（preload 保留，mpath 注入见下）。 */
	restrictRequireLoaders(L);

	lua_pop(L, 1);				/* 弹出白名单表，栈深复原 */

	/* 阶段 2：白名单就绪后再注入解析器（mpath.lua 自身经 dofile 加载，
	 * 必须走已包装的受限加载器，白名单须先建好） */
	injectModulePathResolver(L);
}

/* ---- 新建沙箱化 Lua 状态（重构计划 1 第 12 项）----
 * luavar 与 daemonvar 此前各自 newstate + openlibs + sandbox 三连。chunk
 * 的 loadfile/pcall 留在调用方：两条路径失败契约不同（daemon 区分
 * load/setup 两段报错——run_all.sh 守门按两种短语匹配；luavar 折成
 * bool），强行合一会稀释报错定位。 */
lua_State* openSandboxedState() {
	lua_State* L = luaL_newstate();
	if (L != nullptr) {
		luaL_openlibs(L);
		sandbox_lua(L);
	}
	return L;
}

} // namespace bot

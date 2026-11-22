#include "robot.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "pico/time.h"
#include "pico/util/queue.h"

#include "console.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#if USE_SD
#include "ff.h"
#include "f_util.h"
#include "hw_config.h"
#endif

typedef struct {
    char text[ROBOT_LOG_LINE];
} robot_log_msg_t;

static queue_t robot_log_queue;
static volatile bool robot_stop;
static char lua_file_buf[32 * 1024];

/* core1 栈放在普通 BSS，而不是 SDK 默认的 SCRATCH_X（只有 4KB）。
 * multicore_launch_core1_with_stack 会把 SP 设到数组末尾。 */
static uint32_t robot_core1_stack[16 * 1024 / sizeof(uint32_t)]
    __attribute__((aligned(8)));

#define ROBOT_STACK_FILL 0xDEADBEEFu

static void robot_paint_stack(void) {
    for (size_t i = 0; i < sizeof(robot_core1_stack) / sizeof(robot_core1_stack[0]); ++i) {
        robot_core1_stack[i] = ROBOT_STACK_FILL;
    }
}

static size_t robot_stack_used(void) {
    size_t i = 0;
    while (i < sizeof(robot_core1_stack) / sizeof(robot_core1_stack[0]) &&
           robot_core1_stack[i] == ROBOT_STACK_FILL) {
        ++i;
    }
    return sizeof(robot_core1_stack) - i * sizeof(robot_core1_stack[0]);
}

/* P0 只验证 Lua 运行时本身；真正的 Relay/Timer 驱动从 P1 开始从 SD 加载。 */
static const char kSmokeScript[] =
    "print('Lua smoke script loaded')\n"
    "function build(data)\n"
    "  return { result = 'OK' }\n"
    "end\n"
    "function call(data)\n"
    "  return { result = 'OK', delay = 200 }\n"
    "end\n"
    "function destroy(data)\n"
    "  return { result = 'OK' }\n"
    "end\n";

static int lua_heap_kb(lua_State *L) {
    return lua_gc(L, LUA_GCCOUNT, 0);
}

static int robot_lua_print(lua_State *L) {
    int n = lua_gettop(L);
    char buf[ROBOT_LOG_LINE];
    size_t off = 0;
    for (int i = 1; i <= n && off + 1 < sizeof(buf); ++i) {
        const char *s = lua_tostring(L, i);
        if (s == NULL) {
            s = lua_typename(L, lua_type(L, i));
        }
        int wrote = snprintf(buf + off, sizeof(buf) - off, "%s%s",
            i == 1 ? "" : "\t", s != NULL ? s : "?");
        if (wrote < 0) {
            break;
        }
        off += (size_t)wrote;
        if (off >= sizeof(buf)) {
            off = sizeof(buf) - 1;
        }
    }
    buf[off] = '\0';
    robot_log("Lua: %s", buf);
    return 0;
}

static int robot_os_getenv(lua_State *L) {
    (void)L;
    lua_pushnil(L);
    return 1;
}

static int robot_os_time(lua_State *L) {
    lua_pushnumber(L, (lua_Number)(time_us_64() / 1000000ull));
    return 1;
}

static int robot_os_clock(lua_State *L) {
    lua_pushnumber(L, (lua_Number)(time_us_64() / 1000000.0));
    return 1;
}

static int robot_os_date(lua_State *L) {
    (void)L;
    lua_pushliteral(L, "");
    return 1;
}

static int robot_os_difftime(lua_State *L) {
    lua_pushnumber(L, luaL_optnumber(L, 1, 0) - luaL_optnumber(L, 2, 0));
    return 1;
}

static int robot_os_setlocale(lua_State *L) {
    (void)L;
    lua_pushliteral(L, "C");
    return 1;
}

static int robot_os_noop(lua_State *L) {
    lua_pushnil(L);
    lua_pushliteral(L, "not supported on Pico");
    return 2;
}

static void robot_openlibs(lua_State *L) {
    static const lua_CFunction libs[] = {
        luaopen_base, luaopen_package, luaopen_table,
        luaopen_string, luaopen_math, luaopen_debug,
    };
    for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); ++i) {
        lua_pushcfunction(L, libs[i]);
        lua_call(L, 0, 0);
    }

    lua_register(L, "print", robot_lua_print);

    lua_newtable(L);
    lua_pushcfunction(L, robot_os_getenv); lua_setfield(L, -2, "getenv");
    lua_pushcfunction(L, robot_os_time); lua_setfield(L, -2, "time");
    lua_pushcfunction(L, robot_os_clock); lua_setfield(L, -2, "clock");
    lua_pushcfunction(L, robot_os_date); lua_setfield(L, -2, "date");
    lua_pushcfunction(L, robot_os_difftime); lua_setfield(L, -2, "difftime");
    lua_pushcfunction(L, robot_os_setlocale); lua_setfield(L, -2, "setlocale");
    lua_pushcfunction(L, robot_os_noop); lua_setfield(L, -2, "remove");
    lua_pushcfunction(L, robot_os_noop); lua_setfield(L, -2, "rename");
    lua_pushcfunction(L, robot_os_noop); lua_setfield(L, -2, "tmpname");
    lua_pushcfunction(L, robot_os_noop); lua_setfield(L, -2, "execute");
    lua_pushcfunction(L, robot_os_noop); lua_setfield(L, -2, "exit");
    lua_setglobal(L, "os");
}

/* ---- FatFS 上的 loadfile/dofile ---------------------------------------
 * Lua 5.1 自带 loadfile/dofile 走 newlib fopen，裸机没有文件系统。这里用
 * FatFS 读源码，再 luaL_loadbuffer；路径统一由 __mpath.resolve() 给出
 * （例如 /modules/Relay.lua）。buffer 是 core1 独占的静态区：Lua 编译完
 * chunk 后不再引用源码文本，因此嵌套 dofile 复用同一块 buffer 是安全的。
 */
#if USE_SD
static int load_file_to_stack(lua_State *L, const char *path) {
    FIL fp;
    FRESULT fr = f_open(&fp, path, FA_READ);
    if (fr != FR_OK) {
        lua_pushfstring(L, "cannot open %s (%s)", path, FRESULT_str(fr));
        return -1;
    }

    FSIZE_t size = f_size(&fp);
    if (size == 0 || size >= sizeof(lua_file_buf)) {
        f_close(&fp);
        lua_pushfstring(L, "%s: file size %lu unsupported", path,
            (unsigned long)size);
        return -1;
    }

    UINT read = 0;
    fr = f_read(&fp, lua_file_buf, (UINT)size, &read);
    f_close(&fp);
    if (fr != FR_OK || read != (UINT)size) {
        lua_pushfstring(L, "%s: read failed (%s)", path, FRESULT_str(fr));
        return -1;
    }

    return luaL_loadbuffer(L, lua_file_buf, read, path);
}
#else
static int load_file_to_stack(lua_State *L, const char *path) {
    lua_pushfstring(L, "cannot load %s: SD support disabled", path);
    return -1;
}
#endif

static int robot_lua_loadfile(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_settop(L, 1);
    int status = load_file_to_stack(L, path);
    if (status != 0) {
        lua_pushnil(L);
        lua_insert(L, -2);
        return 2;   /* nil, error */
    }
    return 1;       /* function */
}

static int robot_lua_dofile(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_settop(L, 1);
    if (load_file_to_stack(L, path) != 0) {
        return lua_error(L);
    }
    lua_remove(L, 1);   /* 去掉 path，只留 function */
    lua_call(L, 0, LUA_MULTRET);
    return lua_gettop(L);
}

static int robot_mpath_resolve(lua_State *L) {
    const char *rel = luaL_checkstring(L, 1);
    if (rel[0] == '/') {
        lua_pushstring(L, rel);
    } else {
        lua_pushfstring(L, "/modules/%s", rel);
    }
    return 1;
}

static void robot_set_lua_paths(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, robot_mpath_resolve);
    lua_setfield(L, -2, "resolve");
    lua_setglobal(L, "__mpath");

    lua_pushliteral(L, "/modules");
    lua_setglobal(L, "__mpath_roots");

    lua_register(L, "loadfile", robot_lua_loadfile);
    lua_register(L, "dofile", robot_lua_dofile);
}

/* ---- 每设备 Lua 环境 ---------------------------------------------------
 * 一个 lua_State 里，每个驱动实例有自己的 env 表：
 *   env.__index = _G           基础库/print/os/__mpath 回落
 *   env._G = env               模块里的 _G 看到本实例
 *   env.dofile/loadfile        带 env 上值的闭包，因此驱动内部的 dofile
 *                              也会落到同一个 env
 * 驱动 chunk 通过 lua_setfenv() 绑定到 env；drv_common 的 getfenv(2)
 * 因此仍能把 build/call/destroy 写回实例环境，而不是覆盖全局。
 */
static int load_file_to_env(lua_State *L, const char *path, int env_index) {
    int status = load_file_to_stack(L, path);
    if (status != 0) {
        return status;   /* error string on stack */
    }
    lua_pushvalue(L, env_index);
    lua_setfenv(L, -2);
    return 0;
}

static int env_loadfile(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_settop(L, 1);
    if (load_file_to_env(L, path, lua_upvalueindex(1)) != 0) {
        lua_pushnil(L);
        lua_insert(L, -2);
        return 2;   /* nil, error */
    }
    return 1;       /* function */
}

static int env_dofile(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_settop(L, 1);
    if (load_file_to_env(L, path, lua_upvalueindex(1)) != 0) {
        return lua_error(L);
    }
    lua_remove(L, 1);   /* 去掉 path，只留 function */
    lua_call(L, 0, LUA_MULTRET);
    return lua_gettop(L);
}

/* 栈顶是已经编译好的 chunk function；建立 env、绑定、执行，返回 registry ref。
 * 失败返回 LUA_NOREF，栈复原。 */
static int robot_create_env_from_function(lua_State *L, const char *name) {
    int func = lua_gettop(L);
    lua_newtable(L);                        /* env */
    int env = lua_gettop(L);

    lua_newtable(L);                        /* metatable */
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, env);

    /* 模块里的 _G 指向本实例，避免 __BOT4CJ_* 守卫跨驱动串用。 */
    lua_pushvalue(L, env);
    lua_setfield(L, env, "_G");

    /* 每个 env 独立 dofile/loadfile，闭包上值就是本 env。 */
    lua_pushvalue(L, env);
    lua_pushcclosure(L, env_loadfile, 1);
    lua_setfield(L, env, "loadfile");
    lua_pushvalue(L, env);
    lua_pushcclosure(L, env_dofile, 1);
    lua_setfield(L, env, "dofile");

    lua_pushvalue(L, env);
    lua_setfenv(L, func);
    lua_pushvalue(L, func);
    if (lua_pcall(L, 0, 0, 0) != 0) {
        const char *err = lua_tostring(L, -1);
        robot_log("Lua env %s init error: %s", name, err != NULL ? err : "?");
        lua_pop(L, 3);                      /* function, env, error */
        return LUA_NOREF;
    }

    lua_remove(L, func);                    /* 只留 env */
    return luaL_ref(L, LUA_REGISTRYINDEX);
}

static int robot_create_env_from_path(lua_State *L, const char *path,
        const char *name) {
    if (load_file_to_stack(L, path) != 0) {
        const char *err = lua_tostring(L, -1);
        robot_log("Lua env %s load error: %s", name, err != NULL ? err : "?");
        lua_pop(L, 1);
        return LUA_NOREF;
    }
    return robot_create_env_from_function(L, name);
}

static int robot_create_env_from_source(lua_State *L, const char *source,
        size_t size, const char *name) {
    if (luaL_loadbuffer(L, source, size, name) != 0) {
        const char *err = lua_tostring(L, -1);
        robot_log("Lua env %s compile error: %s", name, err != NULL ? err : "?");
        lua_pop(L, 1);
        return LUA_NOREF;
    }
    return robot_create_env_from_function(L, name);
}

static bool lua_env_call_entry(lua_State *L, int env_ref, const char *label,
        const char *name, bool with_test) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, env_ref);   /* env */
    int env = lua_gettop(L);
    lua_getfield(L, env, name);
    if (!lua_isfunction(L, -1)) {
        robot_log("Lua %s.%s missing", label, name);
        lua_pop(L, 2);
        return false;
    }

    lua_newtable(L);
    if (with_test) {
        lua_pushinteger(L, 200);
        lua_setfield(L, -2, "test");
        lua_pushliteral(L, "hello");
        lua_setfield(L, -2, "note");
    }
    if (lua_pcall(L, 1, 1, 0) != 0) {
        const char *err = lua_tostring(L, -1);
        robot_log("Lua %s.%s error: %s", label, name, err != NULL ? err : "?");
        lua_pop(L, 2);
        return false;
    }

    bool ok = true;
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "result");
        const char *result = lua_tostring(L, -1);
        if (result == NULL || strcmp(result, "OK") != 0) {
            /* Relay 的 call 只返回 {delay=...}，由 controller 转发；
             * P1 没有 controller，故 call 允许缺 result。 */
            if (!(strcmp(name, "call") == 0 && result == NULL)) {
                robot_log("Lua %s.%s result=%s", label, name,
                    result != NULL ? result : "(nil)");
                ok = false;
            }
        }
        lua_pop(L, 1);
        if (strcmp(name, "call") == 0) {
            lua_getfield(L, -1, "delay");
            if (lua_isnumber(L, -1)) {
                robot_log("Lua %s.%s delay=%d", label, name,
                    (int)lua_tointeger(L, -1));
            }
            lua_pop(L, 1);
        }
    } else {
        robot_log("Lua %s.%s returned non-table", label, name);
        ok = false;
    }
    lua_pop(L, 1);   /* result */
    lua_pop(L, 1);   /* env */
    return ok;
}

static void robot_lua_smoke(void) {
#if USE_SD
    sd_card_t *pSD = sd_get_by_num(0);
    if (pSD == NULL) {
        robot_log("SD: no card slot configured");
    } else {
        FRESULT fr = f_mount(&pSD->fatfs, pSD->pcName, 1);
        if (fr != FR_OK) {
            robot_log("SD: mount failed (%s)", FRESULT_str(fr));
        } else {
            robot_log("SD: mounted %s", pSD->pcName);
        }
    }
#endif

    lua_State *L = luaL_newstate();
    if (L == NULL) {
        robot_log("Lua: luaL_newstate failed");
        return;
    }

    robot_openlibs(L);
    robot_set_lua_paths(L);
    robot_log("%s state ready, heap=%dKB", LUA_VERSION, lua_heap_kb(L));

    int robot_env = robot_create_env_from_path(L, "/robot.lua", "robot.lua");
    if (robot_env == LUA_NOREF) {
        robot_log("Lua: using embedded smoke script");
        robot_env = robot_create_env_from_source(L, kSmokeScript,
            sizeof(kSmokeScript) - 1, "embedded-smoke");
    }

    /* P1-B 的第二个实例：证明两个驱动可以各自持有 build/call/destroy。 */
    int echo_env = robot_create_env_from_path(L, "/modules/Echo.lua", "Echo.lua");
    if (echo_env == LUA_NOREF) {
        robot_log("P1-B: /modules/Echo.lua unavailable; single-env check only");
    }

    bool ok = true;
    if (robot_env != LUA_NOREF) {
        bool env_ok = lua_env_call_entry(L, robot_env, "robot", "build", false) &&
                      lua_env_call_entry(L, robot_env, "robot", "call", true) &&
                      lua_env_call_entry(L, robot_env, "robot", "destroy", false);
        robot_log("Lua robot env: %s", env_ok ? "OK" : "FAILED");
        ok = ok && env_ok;
    } else {
        ok = false;
    }

    if (echo_env != LUA_NOREF) {
        bool env_ok = lua_env_call_entry(L, echo_env, "echo", "build", false) &&
                      lua_env_call_entry(L, echo_env, "echo", "call", true) &&
                      lua_env_call_entry(L, echo_env, "echo", "destroy", false);
        robot_log("Lua echo env: %s", env_ok ? "OK" : "FAILED");
        ok = ok && env_ok;
    }

    robot_log("Lua smoke %s, heap=%dKB", ok ? "OK" : "FAILED", lua_heap_kb(L));

    if (robot_env != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, robot_env);
    }
    if (echo_env != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, echo_env);
    }
    lua_close(L);
}

void robot_init(void) {
    robot_stop = false;
    queue_init(&robot_log_queue, sizeof(robot_log_msg_t), ROBOT_LOG_QUEUE_DEPTH);
}

void robot_start(void) {
    robot_paint_stack();
    multicore_launch_core1_with_stack(robot_core1, robot_core1_stack,
        sizeof(robot_core1_stack));
}

void robot_log(const char *fmt, ...) {
    robot_log_msg_t msg;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg.text, sizeof(msg.text), fmt, ap);
    va_end(ap);
    /* 日志是诊断通道，不允许阻塞实时控制；队列满则丢弃本条。 */
    (void)queue_try_add(&robot_log_queue, &msg);
}

void robot_poll_ui(void) {
    robot_log_msg_t msg;
#if USE_VGA
    wchar_t line[ROBOT_LOG_LINE + 2];
#endif
    /* 每轮最多排空 8 条，避免 core0 被 VGA 绘制拖住。 */
    for (int n = 0; n < 8; ++n) {
        if (!queue_try_remove(&robot_log_queue, &msg)) {
            break;
        }
        /* 串口始终输出：没有 VGA 时这是唯一可见的诊断通道。 */
        printf("[robot] %s\n", msg.text);
#if USE_VGA
        size_t i = 0;
        for (; i < ROBOT_LOG_LINE && msg.text[i] != '\0'; ++i) {
            line[i] = (wchar_t)(unsigned char)msg.text[i];
        }
        line[i++] = L'\n';
        line[i] = L'\0';
        printtovga(line);
#endif
    }
}

void robot_request_stop(void) {
    robot_stop = true;
}

bool robot_is_running(void) {
    return !robot_stop;
}

void robot_core1(void) {
    robot_log("core1: robot runtime started");
    robot_lua_smoke();
    robot_log("core1: stack high-water %u / %u bytes",
        (unsigned)robot_stack_used(), (unsigned)sizeof(robot_core1_stack));

    /* P0 心跳：持续 1s 分片睡眠，验证 core0 的 VGA/键盘不受影响，同时让
     * 停止请求能在 50ms 粒度内被看到。 */
    while (!robot_stop) {
        for (int i = 0; i < 20 && !robot_stop; ++i) {
            sleep_ms(50);
        }
        robot_log("core1: heartbeat (idle)");
    }

    robot_log("core1: stop requested, runtime idle");
    while (true) {
        tight_loop_contents();
    }
}

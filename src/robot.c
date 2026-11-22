#include "robot.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <ctype.h>

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "pico/time.h"
#include "pico/util/queue.h"
#include "hardware/i2c.h"

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

/* ---- P2：结构 SQL / MT 的最小运行期解析 --------------------------------
 * 这一阶段只覆盖 mybot 的启动期结构脚本和 @Action 叶子块：
 *   CREATE TABLE ...;               （忽略，列信息由 INSERT 的列清单给出）
 *   INSERT INTO t (cols) VALUES (...);
 *   @Action / 列头 / 数据行 / @
 * 支持多 INSERT、多数据行、同设备多参数；不支持 @if/@while/@Alias/$ref。
 */
#define P2_MAX_TABLES 6
#define P2_MAX_COLS 10
#define P2_MAX_DEVICES 8
#define P2_MAX_FIELDS 10
#define P2_MAX_ALIASES 8
#define P2_MAX_VARS 8
#define P2_MAX_NAME 24
#define P2_MAX_VALUE 32
#define P2_SQL_MAX (12 * 1024)
#define P2_MT_MAX (6 * 1024)

typedef struct {
    char key[P2_MAX_NAME];
    char value[P2_MAX_VALUE];
} p2_field_t;

typedef struct {
    char name[P2_MAX_NAME];
    char value[P2_MAX_VALUE];
} p2_var_t;

typedef struct {
    char name[P2_MAX_NAME];
    char target[P2_MAX_NAME];
} p2_alias_t;

typedef struct {
    char name[P2_MAX_NAME];
    char driver[P2_MAX_NAME];
    char controller[P2_MAX_NAME];
    p2_field_t meta[P2_MAX_FIELDS];
    int nmeta;
    int env_ref;
} p2_device_t;

typedef struct {
    char device[P2_MAX_NAME];
    char param[P2_MAX_NAME];
} p2_action_col_t;

typedef struct {
    bool ok;
    char result[16];
    int delay;
    int slept;
    p2_field_t fields[P2_MAX_FIELDS];
    int nfields;
} p2_call_result_t;

static p2_device_t p2_devices[P2_MAX_DEVICES];
static int p2_ndevices;
static p2_action_col_t p2_action_cols[P2_MAX_COLS];
static p2_var_t p2_vars[P2_MAX_VARS];
static int p2_nvars;
static p2_alias_t p2_aliases[P2_MAX_ALIASES];
static int p2_naliases;
static char p2_sql_buf[P2_SQL_MAX];
static char p2_mt_buf[P2_MT_MAX];

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

/* P3：真实 I2C HAL（RP2040 hardware_i2c） --------------------------------
 * 路径约定：
 *   /dev/i2c-0 -> i2c0，SDA GP6 / SCL GP7
 *   /dev/i2c-1 -> i2c1，SDA GP14 / SCL GP15
 *   /dev/i2c-fake 或 *virt* -> fd=2 的假总线（P2-B 回归仍可跑）
 * 外部需要 4.7k 上拉到 3.3V；内部 pull-up 只作辅助。
 */
#define P3_I2C_FAKE_FD 2
#define P3_I2C_MAX_BYTES 64

typedef struct {
    bool open;
    bool fake;
    i2c_inst_t *inst;
} p3_i2c_t;

static p3_i2c_t p3_i2c[3];

static bool p3_i2c_fake_path(const char *path) {
    return strstr(path, "fake") != NULL || strstr(path, "virt") != NULL;
}

static int p3_i2c_bus_from_path(const char *path) {
    const char *p = strstr(path, "i2c-");
    if (p != NULL) {
        int bus = atoi(p + 4);
        if (bus == 0 || bus == 1) {
            return bus;
        }
    }
    if (strstr(path, "i2c0") != NULL) {
        return 0;
    }
    if (strstr(path, "i2c1") != NULL) {
        return 1;
    }
    return -1;
}

static int robot_lua_i2c_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    if (p3_i2c_fake_path(path)) {
        p3_i2c[P3_I2C_FAKE_FD].open = true;
        p3_i2c[P3_I2C_FAKE_FD].fake = true;
        p3_i2c[P3_I2C_FAKE_FD].inst = NULL;
        lua_pushinteger(L, P3_I2C_FAKE_FD);
        return 1;
    }

    int bus = p3_i2c_bus_from_path(path);
    if (bus < 0) {
        lua_pushinteger(L, -1);
        return 1;
    }
    p3_i2c_t *slot = &p3_i2c[bus];
    if (slot->open) {
        lua_pushinteger(L, bus);
        return 1;
    }

    static const uint8_t sda_pin[2] = {6, 14};
    static const uint8_t scl_pin[2] = {7, 15};
    slot->inst = bus == 0 ? i2c0 : i2c1;
    i2c_init(slot->inst, 100 * 1000);
    gpio_set_function(sda_pin[bus], GPIO_FUNC_I2C);
    gpio_set_function(scl_pin[bus], GPIO_FUNC_I2C);
    gpio_pull_up(sda_pin[bus]);
    gpio_pull_up(scl_pin[bus]);
    slot->open = true;
    slot->fake = false;
    robot_log("I2C: opened %s (SDA GP%d, SCL GP%d)", path,
        sda_pin[bus], scl_pin[bus]);
    lua_pushinteger(L, bus);
    return 1;
}

static int robot_lua_i2c_close(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    if (fd >= 0 && fd < 3 && p3_i2c[fd].open) {
        if (!p3_i2c[fd].fake && p3_i2c[fd].inst != NULL) {
            i2c_deinit(p3_i2c[fd].inst);
        }
        p3_i2c[fd].open = false;
        p3_i2c[fd].fake = false;
        p3_i2c[fd].inst = NULL;
    }
    lua_pushinteger(L, 0);
    return 1;
}

static bool p3_i2c_probe_addr(int fd, int addr) {
    if (fd < 0 || fd >= 3 || !p3_i2c[fd].open) {
        return false;
    }
    if (p3_i2c[fd].fake) {
        return addr == 0x40;
    }
    uint8_t byte = 0;
    return i2c_read_timeout_us(p3_i2c[fd].inst, (uint8_t)addr, &byte, 1,
        false, 2000) == 1;
}

static int robot_lua_i2c_probe(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    int addr = (int)luaL_checkinteger(L, 2);
    lua_pushboolean(L, p3_i2c_probe_addr(fd, addr));
    return 1;
}

static int robot_lua_i2c_scan(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    lua_newtable(L);
    int n = 1;
    for (int addr = 0x08; addr <= 0x77; ++addr) {
        if (p3_i2c_probe_addr(fd, addr)) {
            lua_pushinteger(L, addr);
            lua_rawseti(L, -2, n++);
        }
    }
    return 1;
}

static int robot_lua_i2c_transfer(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    int addr = (int)luaL_checkinteger(L, 2);
    luaL_checktype(L, 3, LUA_TTABLE);
    int read_len = (int)luaL_optinteger(L, 4, 0);
    int write_len = (int)lua_objlen(L, 3);

    if (fd < 0 || fd >= 3 || !p3_i2c[fd].open ||
        addr < 0 || addr > 0x7F ||
        write_len < 0 || write_len > P3_I2C_MAX_BYTES ||
        read_len < 0 || read_len > P3_I2C_MAX_BYTES) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid i2c arguments");
        return 2;
    }

    uint8_t wbuf[P3_I2C_MAX_BYTES];
    uint8_t rbuf[P3_I2C_MAX_BYTES];
    for (int i = 0; i < write_len; ++i) {
        lua_rawgeti(L, 3, i + 1);
        int v = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (v < 0 || v > 255) {
            lua_pushnil(L);
            lua_pushliteral(L, "i2c byte out of range");
            return 2;
        }
        wbuf[i] = (uint8_t)v;
    }

    if (p3_i2c[fd].fake) {
        lua_createtable(L, read_len, 0);
        for (int i = 0; i < read_len; ++i) {
            lua_pushinteger(L, 0);
            lua_rawseti(L, -2, i + 1);
        }
        return 1;
    }

    i2c_inst_t *inst = p3_i2c[fd].inst;
    if (write_len > 0) {
        int rc = i2c_write_timeout_us(inst, (uint8_t)addr, wbuf, (size_t)write_len,
            read_len > 0, 50000);
        if (rc != write_len) {
            robot_log("I2C: write failed fd=%d addr=0x%02X rc=%d", fd, addr, rc);
            lua_pushnil(L);
            lua_pushliteral(L, "i2c write failed");
            return 2;
        }
    }
    if (read_len > 0) {
        int rc = i2c_read_timeout_us(inst, (uint8_t)addr, rbuf, (size_t)read_len,
            false, 50000);
        if (rc != read_len) {
            robot_log("I2C: read failed fd=%d addr=0x%02X rc=%d", fd, addr, rc);
            lua_pushnil(L);
            lua_pushliteral(L, "i2c read failed");
            return 2;
        }
    }

    lua_createtable(L, read_len, 0);
    for (int i = 0; i < read_len; ++i) {
        lua_pushinteger(L, rbuf[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

/* P1-C：Timer.lua 只需要阻塞毫秒。分片睡眠让 stop 请求在 50ms 内可见，
 * 同时因为 core1 独占机器人运行时，core0 的 VGA/USB 不受影响。 */
static int robot_lua_milli_sleep(lua_State *L) {
    lua_Number n = luaL_checknumber(L, 1);
    if (n < 0) {
        n = 0;
    }
    int ms = (int)n;
    while (ms > 0 && !robot_stop) {
        int chunk = ms > 50 ? 50 : ms;
        sleep_ms((uint32_t)chunk);
        ms -= chunk;
    }
    return 0;
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
    lua_register(L, "milli_sleep", robot_lua_milli_sleep);
    lua_register(L, "__i2c_open", robot_lua_i2c_open);
    lua_register(L, "__i2c_close", robot_lua_i2c_close);
    lua_register(L, "__i2c_transfer", robot_lua_i2c_transfer);
    lua_register(L, "__i2c_probe", robot_lua_i2c_probe);
    lua_register(L, "__i2c_scan", robot_lua_i2c_scan);

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
        const char *name, bool with_args) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, env_ref);   /* env */
    int env = lua_gettop(L);
    lua_getfield(L, env, name);
    if (!lua_isfunction(L, -1)) {
        robot_log("Lua %s.%s missing", label, name);
        lua_pop(L, 2);
        return false;
    }

    lua_newtable(L);
    if (with_args) {
        /* Relay/Echo 用 test/note，Timer 用 delay；三类参数同表传入，驱动各取所需。 */
        lua_pushinteger(L, 200);
        lua_setfield(L, -2, "test");
        lua_pushliteral(L, "hello");
        lua_setfield(L, -2, "note");
        lua_pushinteger(L, 200);
        lua_setfield(L, -2, "delay");
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
            lua_getfield(L, -1, "slept");
            if (lua_isnumber(L, -1)) {
                robot_log("Lua %s.%s slept=%d", label, name,
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

/* ---- P2 运行期脚本解析：结构 SQL / @Action MT ------------------------- */

static char *p2_trim(char *s) {
    while (*s != '\0' && isspace((unsigned char)*s)) {
        ++s;
    }
    char *end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1])) {
        --end;
    }
    *end = '\0';
    return s;
}

static void p2_copy_trim(char *dst, size_t cap, const char *begin, const char *end) {
    if (end == NULL) {
        end = begin + strlen(begin);
    }
    while (begin < end && isspace((unsigned char)*begin)) {
        ++begin;
    }
    while (end > begin && isspace((unsigned char)end[-1])) {
        --end;
    }
    size_t n = (size_t)(end - begin);
    if (n >= cap) {
        n = cap - 1;
    }
    memcpy(dst, begin, n);
    dst[n] = '\0';
}

static const char *p2_strcasestr(const char *haystack, const char *needle) {
    if (*needle == '\0') {
        return haystack;
    }
    for (; *haystack != '\0'; ++haystack) {
        const char *h = haystack;
        const char *n = needle;
        while (*h != '\0' && *n != '\0' &&
               tolower((unsigned char)*h) == tolower((unsigned char)*n)) {
            ++h;
            ++n;
        }
        if (*n == '\0') {
            return haystack;
        }
    }
    return NULL;
}

/* 去掉块注释、-- 行注释、# 行注释；引号内的内容原样保留。 */
static void p2_strip_comments(char *s) {
    char *r = s;
    char *w = s;
    bool block = false;
    bool line = false;
    char quote = '\0';
    while (*r != '\0') {
        if (block) {
            if (r[0] == '*' && r[1] == '/') {
                r += 2;
                block = false;
            } else {
                ++r;
            }
            continue;
        }
        if (line) {
            if (*r == '\n') {
                line = false;
                *w++ = *r++;
            } else {
                ++r;
            }
            continue;
        }
        if (quote != '\0') {
            *w++ = *r;
            if (*r == '\\' && r[1] != '\0') {
                *w++ = r[1];
                r += 2;
                continue;
            }
            if (*r == quote) {
                quote = '\0';
            }
            ++r;
            continue;
        }
        if (r[0] == '/' && r[1] == '*') {
            block = true;
            r += 2;
            continue;
        }
        if ((r[0] == '-' && r[1] == '-') || r[0] == '#') {
            line = true;
            r += (r[0] == '#') ? 1 : 2;
            continue;
        }
        if (*r == '\'' || *r == '"') {
            quote = *r;
        }
        *w++ = *r++;
    }
    *w = '\0';
}

static int p2_split_commas(char *s, char **out, int max) {
    int n = 0;
    char quote = '\0';
    char *start = s;
    for (char *p = s;; ++p) {
        bool at_end = (*p == '\0');
        if (!at_end && quote != '\0') {
            if (*p == quote) {
                quote = '\0';
            }
            continue;
        }
        if (!at_end && (*p == '\'' || *p == '"')) {
            quote = *p;
            continue;
        }
        if (at_end || *p == ',') {
            *p = '\0';
            if (n < max) {
                out[n++] = p2_trim(start);
            }
            if (at_end) {
                break;
            }
            start = p + 1;
        }
    }
    return n;
}

static int p2_split_ws(char *s, char **out, int max) {
    int n = 0;
    char *p = s;
    while (*p != '\0') {
        while (*p != '\0' && (isspace((unsigned char)*p) || *p == ';')) {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        if (n < max) {
            out[n++] = p;
        }
        while (*p != '\0' && !isspace((unsigned char)*p) && *p != ';') {
            ++p;
        }
        if (*p != '\0') {
            *p++ = '\0';
        }
    }
    return n;
}

static void p2_unquote(char *s) {
    size_t n = strlen(s);
    if (n >= 2 && (s[0] == '\'' || s[0] == '"') && s[n - 1] == s[0]) {
        memmove(s, s + 1, n - 2);
        s[n - 2] = '\0';
    }
}

static bool p2_add_field(p2_field_t *fields, int *count, const char *key,
        const char *value);

static p2_device_t *p2_find_device(const char *name) {
    for (int i = 0; i < p2_ndevices; ++i) {
        if (strcmp(p2_devices[i].name, name) == 0) {
            return &p2_devices[i];
        }
    }
    return NULL;
}

static const char *p2_find_var(const char *name) {
    for (int i = 0; i < p2_nvars; ++i) {
        if (strcmp(p2_vars[i].name, name) == 0) {
            return p2_vars[i].value;
        }
    }
    return NULL;
}

static void p2_add_var(const char *name, const char *value) {
    if (p2_nvars >= P2_MAX_VARS) {
        return;
    }
    p2_copy_trim(p2_vars[p2_nvars].name, sizeof(p2_vars[p2_nvars].name), name, NULL);
    p2_copy_trim(p2_vars[p2_nvars].value, sizeof(p2_vars[p2_nvars].value), value, NULL);
    p2_unquote(p2_vars[p2_nvars].name);
    p2_unquote(p2_vars[p2_nvars].value);
    ++p2_nvars;
}

static const char *p2_find_alias(const char *name) {
    for (int i = p2_naliases - 1; i >= 0; --i) {
        if (strcmp(p2_aliases[i].name, name) == 0) {
            return p2_aliases[i].target;
        }
    }
    return NULL;
}

static void p2_add_alias(const char *name, const char *target) {
    if (p2_naliases >= P2_MAX_ALIASES) {
        return;
    }
    p2_copy_trim(p2_aliases[p2_naliases].name, sizeof(p2_aliases[p2_naliases].name), name, NULL);
    p2_copy_trim(p2_aliases[p2_naliases].target, sizeof(p2_aliases[p2_naliases].target), target, NULL);
    p2_unquote(p2_aliases[p2_naliases].name);
    p2_unquote(p2_aliases[p2_naliases].target);
    ++p2_naliases;
}

static void p2_set_meta(p2_device_t *d, const char *key, const char *value) {
    for (int i = 0; i < d->nmeta; ++i) {
        if (strcmp(d->meta[i].key, key) == 0) {
            p2_copy_trim(d->meta[i].value, sizeof(d->meta[i].value), value, NULL);
            return;
        }
    }
    p2_add_field(d->meta, &d->nmeta, key, value);
}

static bool p2_add_field(p2_field_t *fields, int *count, const char *key,
        const char *value) {
    if (*count >= P2_MAX_FIELDS) {
        return false;
    }
    p2_copy_trim(fields[*count].key, sizeof(fields[*count].key), key, NULL);
    p2_copy_trim(fields[*count].value, sizeof(fields[*count].value), value, NULL);
    ++*count;
    return true;
}

static void p2_add_device(const char *driver, char **cols, char **vals, int n) {
    if (strcmp(driver, "Vars") == 0) {
        const char *name = NULL;
        const char *value = NULL;
        for (int i = 0; i < n; ++i) {
            if (strcmp(cols[i], "name") == 0) {
                name = vals[i];
            } else if (strcmp(cols[i], "value") == 0) {
                value = vals[i];
            }
        }
        if (name != NULL && value != NULL) {
            p2_add_var(name, value);
        }
        return;
    }
    if (strcmp(driver, "Alias") == 0) {
        const char *name = NULL;
        const char *alias = NULL;
        for (int i = 0; i < n; ++i) {
            if (strcmp(cols[i], "name") == 0) {
                name = vals[i];
            } else if (strcmp(cols[i], "alias") == 0) {
                alias = vals[i];
            }
        }
        if (name != NULL && alias != NULL) {
            p2_add_alias(name, alias);
        }
        return;
    }
    if (strcmp(driver, "Action") == 0 || strcmp(driver, "Daemon") == 0) {
        return;
    }
    if (p2_ndevices >= P2_MAX_DEVICES) {
        robot_log("P2: too many devices (max %d)", P2_MAX_DEVICES);
        return;
    }
    p2_device_t *d = &p2_devices[p2_ndevices];
    memset(d, 0, sizeof(*d));
    p2_copy_trim(d->driver, sizeof(d->driver), driver, NULL);
    d->env_ref = LUA_NOREF;
    for (int i = 0; i < n; ++i) {
        char key[P2_MAX_NAME];
        char value[P2_MAX_VALUE];
        p2_copy_trim(key, sizeof(key), cols[i], NULL);
        p2_copy_trim(value, sizeof(value), vals[i], NULL);
        p2_unquote(value);
        p2_add_field(d->meta, &d->nmeta, key, value);
        if (strcmp(key, "name") == 0) {
            p2_copy_trim(d->name, sizeof(d->name), value, NULL);
        } else if (strcmp(key, "controller") == 0) {
            p2_copy_trim(d->controller, sizeof(d->controller), value, NULL);
        }
    }
    if (d->name[0] == '\0') {
        snprintf(d->name, sizeof(d->name), "%s-%d", d->driver, p2_ndevices);
        p2_add_field(d->meta, &d->nmeta, "name", d->name);
    }
    robot_log("P2: device %s driver=%s controller=%s", d->name,
        d->driver, d->controller[0] != '\0' ? d->controller : "-");
    ++p2_ndevices;
}

static void p2_parse_sql(void) {
    p2_ndevices = 0;
    p2_nvars = 0;
    p2_naliases = 0;
    p2_strip_comments(p2_sql_buf);
    char *cur = p2_sql_buf;
    while ((cur = (char *)p2_strcasestr(cur, "INSERT INTO")) != NULL) {
        char *p = cur + strlen("INSERT INTO");
        while (*p != '\0' && isspace((unsigned char)*p)) {
            ++p;
        }
        char *lp = strchr(p, '(');
        if (lp == NULL) {
            break;
        }
        char table[P2_MAX_NAME];
        p2_copy_trim(table, sizeof(table), p, lp);
        char *rp = strchr(lp + 1, ')');
        if (rp == NULL) {
            break;
        }
        char colbuf[256];
        p2_copy_trim(colbuf, sizeof(colbuf), lp + 1, rp);

        char *vp = (char *)p2_strcasestr(rp, "VALUES");
        if (vp == NULL) {
            break;
        }
        char *vlp = strchr(vp, '(');
        if (vlp == NULL) {
            break;
        }
        char *vrp = strchr(vlp + 1, ')');
        if (vrp == NULL) {
            break;
        }
        char valbuf[512];
        p2_copy_trim(valbuf, sizeof(valbuf), vlp + 1, vrp);

        char *cols[P2_MAX_FIELDS];
        char *vals[P2_MAX_FIELDS];
        int nc = p2_split_commas(colbuf, cols, P2_MAX_FIELDS);
        int nv = p2_split_commas(valbuf, vals, P2_MAX_FIELDS);
        if (nc > 0 && nc == nv) {
            p2_add_device(table, cols, vals, nc);
        } else {
            robot_log("P2: INSERT %s column/value count mismatch (%d/%d)",
                table, nc, nv);
        }
        cur = vrp + 1;
    }
}

static size_t p2_read_file(const char *path, char *buf, size_t cap) {
#if USE_SD
    FIL fp;
    FRESULT fr = f_open(&fp, path, FA_READ);
    if (fr != FR_OK) {
        robot_log("P2: cannot open %s (%s)", path, FRESULT_str(fr));
        return 0;
    }
    FSIZE_t size = f_size(&fp);
    if (size == 0 || size >= cap) {
        robot_log("P2: %s size %lu unsupported", path, (unsigned long)size);
        f_close(&fp);
        return 0;
    }
    UINT read = 0;
    fr = f_read(&fp, buf, (UINT)size, &read);
    f_close(&fp);
    if (fr != FR_OK || read != (UINT)size) {
        robot_log("P2: read %s failed", path);
        return 0;
    }
    buf[read] = '\0';
    return read;
#else
    (void)path;
    (void)buf;
    (void)cap;
    robot_log("P2: SD support disabled");
    return 0;
#endif
}

static bool p2_lua_call(lua_State *L, int env_ref, const char *label,
        const char *func, const p2_field_t *fields, int nfields,
        p2_call_result_t *out) {
    memset(out, 0, sizeof(*out));
    lua_rawgeti(L, LUA_REGISTRYINDEX, env_ref);
    int env = lua_gettop(L);
    lua_getfield(L, env, func);
    if (!lua_isfunction(L, -1)) {
        robot_log("P2: %s.%s missing", label, func);
        lua_pop(L, 2);
        return false;
    }

    lua_newtable(L);
    for (int i = 0; i < nfields; ++i) {
        lua_pushstring(L, fields[i].key);
        lua_pushstring(L, fields[i].value);
        lua_rawset(L, -3);
    }
    if (lua_pcall(L, 1, 1, 0) != 0) {
        const char *err = lua_tostring(L, -1);
        robot_log("P2: %s.%s error: %s", label, func, err != NULL ? err : "?");
        lua_pop(L, 2);
        return false;
    }

    out->ok = true;
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "result");
        const char *result = lua_tostring(L, -1);
        if (result != NULL) {
            snprintf(out->result, sizeof(out->result), "%s", result);
            if (strcmp(result, "OK") != 0) {
                out->ok = false;
            }
        } else if (strcmp(func, "call") != 0) {
            out->ok = false;
        }
        lua_pop(L, 1);
        lua_getfield(L, -1, "delay");
        if (lua_isnumber(L, -1)) {
            out->delay = (int)lua_tointeger(L, -1);
        }
        lua_pop(L, 1);
        lua_getfield(L, -1, "slept");
        if (lua_isnumber(L, -1)) {
            out->slept = (int)lua_tointeger(L, -1);
        }
        lua_pop(L, 1);

        /* 保留结果表里的标量字段，供 $ref 合并 fd/path/baud/delay 等。 */
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            if (lua_type(L, -2) == LUA_TSTRING) {
                const char *key = lua_tostring(L, -2);
                const char *value = lua_tostring(L, -1);
                if (key != NULL && value != NULL && strcmp(key, "result") != 0) {
                    p2_add_field(out->fields, &out->nfields, key, value);
                }
            }
            lua_pop(L, 1);
        }
    } else {
        out->ok = false;
    }
    lua_pop(L, 2);   /* result, env */

    if (out->delay != 0) {
        robot_log("P2: %s.%s result=%s delay=%d", label, func,
            out->result[0] != '\0' ? out->result : "-", out->delay);
    } else if (out->slept != 0) {
        robot_log("P2: %s.%s result=%s slept=%d", label, func,
            out->result[0] != '\0' ? out->result : "-", out->slept);
    } else {
        robot_log("P2: %s.%s result=%s", label, func,
            out->result[0] != '\0' ? out->result : "-");
    }
    return out->ok;
}

static void p2_add_meta_fields(const p2_device_t *d, p2_field_t *fields, int *n) {
    for (int i = 0; i < d->nmeta; ++i) {
        if (*n < P2_MAX_FIELDS) {
            fields[(*n)++] = d->meta[i];
        }
    }
}

static const char *p2_expand_value(const char *value, char *buf, size_t cap) {
    const char *name = NULL;
    size_t len = 0;
    if (value[0] == '$' && value[1] == '(') {
        const char *end = strchr(value + 2, ')');
        if (end != NULL) {
            name = value + 2;
            len = (size_t)(end - name);
        }
    } else if (value[0] == '$' && value[1] != '\0') {
        name = value + 1;
        len = strlen(name);
    }
    if (name == NULL || len == 0 || len >= P2_MAX_NAME) {
        return value;
    }
    char key[P2_MAX_NAME];
    memcpy(key, name, len);
    key[len] = '\0';
    const char *var = p2_find_var(key);
    if (var == NULL) {
        return value;
    }
    p2_copy_trim(buf, cap, var, NULL);
    return buf;
}

static bool p2_is_bus_driver(const char *driver) {
    return strcmp(driver, "I2C") == 0 ||
           strcmp(driver, "SPI") == 0 ||
           strcmp(driver, "UART") == 0;
}

static bool p2_has_refs(const p2_device_t *d) {
    for (int i = 0; i < d->nmeta; ++i) {
        if (d->meta[i].value[0] == '$' && d->meta[i].value[1] != '\0') {
            return true;
        }
    }
    return false;
}

/* 把 $name 解析成：
 *   - Vars 表里的数值文本；或
 *   - 另一个设备的 call() 返回值字段（I2C -> fd，SPI -> fd/delay，
 *     UART -> fd/baud/path）。
 * 只做一层，与 mybot 的引用装配语义一致。
 */
static void p2_resolve_refs_for(lua_State *L, p2_device_t *d) {
    int n = d->nmeta;
    for (int i = 0; i < n; ++i) {
        const char *value = d->meta[i].value;
        if (value[0] != '$' || value[1] == '\0') {
            continue;
        }
        const char *name = value + 1;
        const char *var = p2_find_var(name);
        if (var != NULL) {
            p2_set_meta(d, d->meta[i].key, var);
            robot_log("P2: $%s -> %s", name, var);
            continue;
        }
        p2_device_t *src = p2_find_device(name);
        if (src == NULL || src == d || src->env_ref == LUA_NOREF) {
            robot_log("P2: unresolved reference $%s", name);
            continue;
        }
        p2_call_result_t res;
        if (!p2_lua_call(L, src->env_ref, src->name, "call", src->meta,
                src->nmeta, &res)) {
            robot_log("P2: reference $%s call failed", name);
            continue;
        }
        for (int k = 0; k < res.nfields; ++k) {
            p2_set_meta(d, res.fields[k].key, res.fields[k].value);
        }
        robot_log("P2: $%s -> %d field(s)", name, res.nfields);
    }
}

static bool p2_build_one(lua_State *L, p2_device_t *d) {
    p2_resolve_refs_for(L, d);
    char path[64];
    snprintf(path, sizeof(path), "/modules/%s.lua", d->driver);
    int env = robot_create_env_from_path(L, path, d->driver);
    if (env == LUA_NOREF) {
        robot_log("P2: cannot load driver %s", path);
        return false;
    }
    d->env_ref = env;
    p2_call_result_t res;
    if (!p2_lua_call(L, env, d->name, "build", d->meta, d->nmeta, &res)) {
        robot_log("P2: build %s failed", d->name);
        return false;
    }
    return true;
}

static bool p2_build_devices(lua_State *L) {
    bool built[P2_MAX_DEVICES] = {false};
    for (int pass = 0; pass < 2; ++pass) {
        for (int i = 0; i < p2_ndevices; ++i) {
            if (built[i]) {
                continue;
            }
            p2_device_t *d = &p2_devices[i];
            bool bus = p2_is_bus_driver(d->driver);
            bool refs = p2_has_refs(d);
            if (pass == 0 && refs && !bus) {
                continue;   /* 先建总线/无引用设备，再解析 $ref */
            }
            if (p2_build_one(L, d)) {
                built[i] = true;
            } else {
                built[i] = true;   /* 失败也标记，避免第二遍重复 */
            }
        }
    }
    return true;
}

static void p2_execute_row(lua_State *L, char **vals, int nvals) {
    for (int i = 0; i < P2_MAX_COLS; ++i) {
        if (p2_action_cols[i].device[0] == '\0') {
            break;
        }
        bool done = false;
        for (int j = 0; j < i; ++j) {
            if (strcmp(p2_action_cols[j].device, p2_action_cols[i].device) == 0) {
                done = true;
                break;
            }
        }
        if (done || i >= nvals) {
            continue;
        }
        p2_device_t *d = p2_find_device(p2_action_cols[i].device);
        if (d == NULL || d->env_ref == LUA_NOREF) {
            robot_log("P2: unknown device %s", p2_action_cols[i].device);
            continue;
        }

        p2_field_t fields[P2_MAX_FIELDS];
        int nf = 0;
        p2_add_meta_fields(d, fields, &nf);
        for (int j = i; j < P2_MAX_COLS; ++j) {
            if (p2_action_cols[j].device[0] == '\0') {
                break;
            }
            if (strcmp(p2_action_cols[j].device, d->name) == 0 && j < nvals) {
                char value_buf[P2_MAX_VALUE];
                const char *value = p2_expand_value(vals[j], value_buf,
                    sizeof(value_buf));
                p2_add_field(fields, &nf, p2_action_cols[j].param, value);
            }
        }

        p2_call_result_t res;
        if (!p2_lua_call(L, d->env_ref, d->name, "call", fields, nf, &res)) {
            robot_log("P2: %s call failed", d->name);
            continue;
        }
        if (res.delay != 0) {
            robot_log("P2: %s delay=%d", d->name, res.delay);
        } else if (res.slept != 0) {
            robot_log("P2: %s slept=%d", d->name, res.slept);
        } else {
            robot_log("P2: %s call ok", d->name);
        }

        if (d->controller[0] != '\0') {
            p2_device_t *ctl = p2_find_device(d->controller);
            if (ctl == NULL || ctl->env_ref == LUA_NOREF) {
                robot_log("P2: controller %s not found", d->controller);
                continue;
            }
            p2_field_t cf[P2_MAX_FIELDS];
            int cn = 0;
            p2_add_meta_fields(ctl, cf, &cn);
            p2_add_meta_fields(d, cf, &cn);
            char delay_text[16];
            snprintf(delay_text, sizeof(delay_text), "%d", res.delay);
            p2_add_field(cf, &cn, "delay", delay_text);
            p2_call_result_t cres;
            if (!p2_lua_call(L, ctl->env_ref, ctl->name, "call", cf, cn, &cres)) {
                robot_log("P2: controller %s call failed", ctl->name);
            } else {
                robot_log("P2: controller %s result=%s slept=%d", ctl->name,
                    cres.result[0] != '\0' ? cres.result : "-", cres.slept);
            }
        }
    }
}

static bool p2_run_mt(lua_State *L) {
    p2_strip_comments(p2_mt_buf);
    char *save = NULL;
    char *line = strtok_r(p2_mt_buf, "\n", &save);
    bool in_action = false;
    bool in_alias = false;
    bool in_vars = false;
    int ncols = 0;
    int alias_header = 0;
    int vars_header = 0;
    memset(p2_action_cols, 0, sizeof(p2_action_cols));

    while (line != NULL) {
        line = p2_trim(line);
        if (*line == '\0') {
            line = strtok_r(NULL, "\n", &save);
            continue;
        }

        if (in_alias) {
            if (line[0] == '@') {
                in_alias = false;
            } else if (alias_header == 0) {
                alias_header = 1;   /* name alias; */
            } else {
                char *cells[4];
                int n = p2_split_ws(line, cells, 4);
                if (n >= 2) {
                    p2_add_alias(cells[0], cells[1]);
                    robot_log("P2: @Alias %s -> %s", cells[0], cells[1]);
                }
            }
            line = strtok_r(NULL, "\n", &save);
            continue;
        }

        if (in_vars) {
            if (line[0] == '@') {
                in_vars = false;
            } else if (vars_header == 0) {
                vars_header = 1;    /* name value; */
            } else {
                char *cells[4];
                int n = p2_split_ws(line, cells, 4);
                if (n >= 2) {
                    p2_add_var(cells[0], cells[1]);
                    robot_log("P2: @Vars %s = %s", cells[0], cells[1]);
                }
            }
            line = strtok_r(NULL, "\n", &save);
            continue;
        }

        if (!in_action) {
            if (strncmp(line, "@Alias", 6) == 0) {
                in_alias = true;
                alias_header = 0;
            } else if (strncmp(line, "@Vars", 5) == 0) {
                in_vars = true;
                vars_header = 0;
            } else if (strncmp(line, "@Action", 7) == 0) {
                in_action = true;
            }
            line = strtok_r(NULL, "\n", &save);
            continue;
        }

        if (line[0] == '@') {
            break;
        }

        if (ncols == 0) {
            char *cells[P2_MAX_COLS];
            int n = p2_split_ws(line, cells, P2_MAX_COLS);
            for (int i = 0; i < n; ++i) {
                char *dot = strchr(cells[i], '.');
                if (dot == NULL) {
                    continue;
                }
                *dot = '\0';
                p2_copy_trim(p2_action_cols[ncols].device,
                    sizeof(p2_action_cols[ncols].device), cells[i], NULL);
                const char *param = dot + 1;
                const char *alias = p2_find_alias(param);
                if (alias != NULL) {
                    param = alias;
                }
                p2_copy_trim(p2_action_cols[ncols].param,
                    sizeof(p2_action_cols[ncols].param), param, NULL);
                ++ncols;
            }
            robot_log("P2: @Action columns=%d", ncols);
        } else {
            char *vals[P2_MAX_COLS];
            int n = p2_split_ws(line, vals, P2_MAX_COLS);
            if (n > 0) {
                p2_execute_row(L, vals, n);
            }
        }
        line = strtok_r(NULL, "\n", &save);
    }
    return ncols > 0;
}

static void p2_destroy_devices(lua_State *L) {
    for (int i = p2_ndevices - 1; i >= 0; --i) {
        p2_device_t *d = &p2_devices[i];
        if (d->env_ref != LUA_NOREF) {
            p2_call_result_t res;
            (void)p2_lua_call(L, d->env_ref, d->name, "destroy", d->meta,
                d->nmeta, &res);
            luaL_unref(L, LUA_REGISTRYINDEX, d->env_ref);
            d->env_ref = LUA_NOREF;
        }
    }
}

static bool robot_p2_run(lua_State *L) {
    const char *sql_path = "/robots/p3.sql";
    const char *mt_path = "/scripts/p3.mt";
    size_t n = p2_read_file(sql_path, p2_sql_buf, sizeof(p2_sql_buf));
    if (n == 0) {
        sql_path = "/robots/p2b.sql";
        mt_path = "/scripts/p2b.mt";
        n = p2_read_file(sql_path, p2_sql_buf, sizeof(p2_sql_buf));
    }
    if (n == 0) {
        sql_path = "/robots/relay-test.sql";
        mt_path = "/scripts/relay-test.mt";
        n = p2_read_file(sql_path, p2_sql_buf, sizeof(p2_sql_buf));
        if (n == 0) {
            robot_log("P2: no structure script on SD; skip script run");
            return false;
        }
    }
    robot_log("P2: using %s", sql_path);
    p2_parse_sql();
    robot_log("P2: parsed %d device(s)", p2_ndevices);
    if (p2_ndevices == 0) {
        return false;
    }
    p2_build_devices(L);

    n = p2_read_file(mt_path, p2_mt_buf, sizeof(p2_mt_buf));
    if (n == 0) {
        robot_log("P2: %s unavailable", mt_path);
    } else if (!p2_run_mt(L)) {
        robot_log("P2: no @Action block found");
    }

    p2_destroy_devices(L);
    return true;
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

    bool ok = true;
    bool p2_ran = robot_p2_run(L);
    int robot_env = LUA_NOREF;
    int echo_env = LUA_NOREF;
    int timer_env = LUA_NOREF;

    if (!p2_ran) {
        robot_env = robot_create_env_from_path(L, "/robot.lua", "robot.lua");
        if (robot_env == LUA_NOREF) {
            robot_log("Lua: using embedded smoke script");
            robot_env = robot_create_env_from_source(L, kSmokeScript,
                sizeof(kSmokeScript) - 1, "embedded-smoke");
        }

        /* P1-B 的第二个实例：证明两个驱动可以各自持有 build/call/destroy。 */
        echo_env = robot_create_env_from_path(L, "/modules/Echo.lua", "Echo.lua");
        if (echo_env == LUA_NOREF) {
            robot_log("P1-B: /modules/Echo.lua unavailable; single-env check only");
        }

        /* P1-C：真实 Timer.lua + 最小 HAL.lua，验证 milli_sleep 与 VGA 实时性。 */
        timer_env = robot_create_env_from_path(L, "/modules/Timer.lua", "Timer.lua");
        if (timer_env == LUA_NOREF) {
            robot_log("P1-C: /modules/Timer.lua unavailable; sleep check skipped");
        }
    } else {
        robot_log("P2: script run completed");
    }

    if (!p2_ran) {
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

        if (timer_env != LUA_NOREF) {
            bool env_ok = lua_env_call_entry(L, timer_env, "timer", "build", false) &&
                          lua_env_call_entry(L, timer_env, "timer", "call", true) &&
                          lua_env_call_entry(L, timer_env, "timer", "destroy", false);
            robot_log("Lua timer env: %s", env_ok ? "OK" : "FAILED");
            ok = ok && env_ok;
        }
    }

    robot_log("Lua smoke %s, heap=%dKB", ok ? "OK" : "FAILED", lua_heap_kb(L));

    if (!p2_ran) {
        if (robot_env != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, robot_env);
        }
        if (echo_env != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, echo_env);
        }
        if (timer_env != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, timer_env);
        }
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

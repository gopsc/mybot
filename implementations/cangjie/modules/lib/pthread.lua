-- pthread.lua - 守护线程 IPC 原语（纯 LuaJIT ffi）
-- bot4cj 仓颉语言机器人框架
--
-- 用途：@Daemon 机制的数据通路。守护线程在【独立 lua_State】上采样，
-- 经共享内存槽 publish 结果；主线程侧 latest 读取。线程本身的创建在仓颉
-- 宿主侧（HV/Daemon.cj 经 Cangjie spawn），本库只负责跨状态机的共享内存 + 互斥，
-- 全部经 ffi 直调 libc，无仓颉 cfunc（守住 issue #14 的纯 Lua 数据通路）。
--
-- 【共享槽布局】必须与 Daemon.cj 的 @C struct DaemonSlot 严格一致（同一 C ABI）：
--   offset 0   char    mutex[64]    pthread_mutex_t（aarch64=48B/x86_64=40B，预留 64）
--   offset 64  int32   count        已 publish 次数
--   offset 68  int32   nvals        本次值个数
--   offset 72  double  values[32]   采样值（P：16 → 32，支撑单守护聚合多路传感器）
--   offset 328 uint8   stop         停止标志（1=请求停止；紧随 values[32] 之后：
--                                    mutex 64 + count 4 + nvals 4 + values 256 = 328）
--
-- 【cdef 约定】只声明 mutex/slot 专有类型，不重复声明 HAL.lua 已定义的
-- open/ioctl/read/write/usleep（守护 chunk 会同时加载 HAL，重复 cdef 会报错）。
--
-- 【地址注入契约】（Low：注入地址 ≥2^53 精度）
-- 宿主经 lua_pushinteger 以 64 位整数 tag 注入槽地址（Daemon.cj:81），LuaJIT 整数 tag
-- 使任意 64 位值（含 ≥2^53、bit63 置位）逐位保真；本库只管把它当不透明句柄
-- 原样 ffi.cast 直传。地址在 Lua 数字域仅当被算术（+ - * /）或 tonumber 强制 double
-- 时才开始在 >=2^53 丢位——故各守护 chunk 禁止对地址做任何算术。
-- slot_attach 在此补前置守卫：非负整值被 double 化（非整/负）直接 error，把「已损坏的
-- 地址」显式红在守护初始化期；>=2^53 仅告警（注入路径逐位保真，拦截会误伤精确路径），
-- 提示该地址处于算术危险区、必须当不透明句柄直传。
--
-- 用法（守护侧，独立状态机）：
--   local P = dofile(.../lib/pthread.lua)
--   local slot = P.slot_attach(DAEMON_SLOT_ADDR)   -- 宿主注入的地址全局
--   while not P.should_stop(slot) do
--       local ax, ay, az = 采样()                   -- 经 HAL
--       P.publish(slot, {ax, ay, az})
--       milli_sleep(interval_ms)                    -- HAL 提供的节拍
--   end
-- 用法（主线程侧读取，通常由仓颉直接读槽；Lua 侧亦可用 latest）：
--   local vals, count = P.latest(slot)

local P = {}

-- 重复加载保护
if _G.__BOT4CJ_PTHREAD ~= nil then return _G.__BOT4CJ_PTHREAD end
_G.__BOT4CJ_PTHREAD = P

local has_ffi, ffi = false, nil
if rawget(_G, "jit") ~= nil then has_ffi, ffi = pcall(require, "ffi") end
if not has_ffi then
	error("pthread.lua requires LuaJIT with ffi")
end

------------------------------------------------------------------
-- ffi 声明（仅 mutex/slot 专有，避开与 HAL 的重复符号）
------------------------------------------------------------------
ffi.cdef[[
typedef struct { char __m[64]; } cj_pthread_mutex_t;
int pthread_mutex_init(cj_pthread_mutex_t *mutex, const void *attr);
int pthread_mutex_lock(cj_pthread_mutex_t *mutex);
int pthread_mutex_unlock(cj_pthread_mutex_t *mutex);
int pthread_mutex_destroy(cj_pthread_mutex_t *mutex);

typedef struct {
	char     mutex[64];
	int32_t  count;
	int32_t  nvals;
	double   values[32];
	uint8_t  stop;
} daemon_slot_t;
]]

P.SLOT_MAXVALS = 32

------------------------------------------------------------------
-- 地址 ↔ 指针
------------------------------------------------------------------
-- 整数地址（宿主以 Lua number 注入）→ 类型化指针。
-- 两步 cast：number → uint64_t → 目标指针类型（直接 number→pointer 不被允许）。
function P.ptr(addr, ctype)
	local u = ffi.cast("uint64_t", addr)
	return ffi.cast(ctype or "void *", u)
end

-- 指针 → 整数地址（用于把 ffi 分配的槽地址交给宿主/日志）
function P.addr(ptr)
	return tonumber(ffi.cast("uint64_t", ptr))
end

------------------------------------------------------------------
-- 共享槽
------------------------------------------------------------------
-- 附着到宿主分配的槽（addr 为整数地址）
function P.slot_attach(addr)
	-- 前置守卫：地址必须仍为非负整数值（整数 tag）。
	-- 注入路径（lua_pushinteger）对任意 64 位值逐位保真，故 ≥2^53 仅告警不拦截
	-- （拦了会误伤合法精确路径）；真正危险的是 Lua 侧算术/tonumber 把整数 double
	-- 化后在 ≥2^53 静默丢位——那是使用方违规，任何事后检查都不可见，见契约注释。
	if type(addr) ~= "number" or addr < 0 or addr % 1 ~= 0 then
		error("DAEMON_SLOT_ADDR must be a non-negative integer, got " .. tostring(addr))
	end
	if addr >= 2^53 then
		print("[pthread] warning: DAEMON_SLOT_ADDR " .. tostring(addr) .. " >= 2^53; treat as opaque, do NOT do arithmetic on it")
	end
	return ffi.cast("daemon_slot_t *", ffi.cast("uint64_t", addr))
end

-- 本库自行分配一个槽（仅供 Lua 侧测试/纯 Lua 场景；生产中由宿主 malloc 并注入地址）
function P.slot_new()
	local slot = ffi.new("daemon_slot_t[1]")
	slot[0].count = 0
	slot[0].nvals = 0
	slot[0].stop = 0
	P.mutex_init(slot)
	return slot
end

-- 取槽内 mutex 指针（slot 可能是数组[1]或指针，[0] 对两者都成立）
local function slot_mutex(slot)
	return ffi.cast("cj_pthread_mutex_t *", slot[0].mutex)
end

-- H-05：mutex 调用返回值一律检查。成功=0；EBUSY/EINVAL/EAGAIN/EDEADLK 等
-- 一律显式 error——静默忽略会在锁损坏时造成数据竞态或永久死锁。
local function mutex_call(op, m)
	local fn
	if op == "lock" then fn = ffi.C.pthread_mutex_lock
	else fn = ffi.C.pthread_mutex_unlock end
	local rc = fn(m)
	if rc ~= 0 then
		error("pthread_mutex_" .. op .. " failed: rc=" .. tostring(rc), 2)
	end
end

function P.mutex_init(slot)
	local m = slot_mutex(slot)
	local rc = ffi.C.pthread_mutex_init(m, nil)
	if rc ~= 0 then
		error("pthread_mutex_init failed: rc=" .. tostring(rc), 2)
	end
end

-- 守护侧：发布一组采样值（mutex 保护，count 自增）。
-- 入锁前校验 vals 全为数值：本库面向用户自写守护 chunk，若在持锁区间内
-- 对 ffi double 槽位赋非数值（nil/字符串等）会抛 error 跳过 unlock，
-- 主线程侧 play() 从此永久死锁——非法值必须在锁外显式红出来。
function P.publish(slot, vals)
	if type(vals) ~= "table" then
		error("publish: vals must be a table, got " .. type(vals))
	end
	local n = #vals
	if n > P.SLOT_MAXVALS then n = P.SLOT_MAXVALS end
	for i = 1, n do
		if type(vals[i]) ~= "number" then
			error("publish: vals[" .. i .. "] must be a number, got " .. type(vals[i]))
		end
	end
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	slot[0].nvals = n
	for i = 1, n do
		slot[0].values[i - 1] = vals[i]
	end
	slot[0].count = slot[0].count + 1
	mutex_call("unlock", m)
end

-- 主线程侧：读取最新一组值，返回 values 表（1 基）与 count
function P.latest(slot)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	local n = slot[0].nvals
	if n < 0 then n = 0 end
	if n > P.SLOT_MAXVALS then n = P.SLOT_MAXVALS end
	local t = {}
	for i = 0, n - 1 do
		t[i + 1] = slot[0].values[i]
	end
	local c = slot[0].count
	mutex_call("unlock", m)
	return t, c
end

-- 停止标志（守护循环轮询；宿主置位）
function P.should_stop(slot)
	return slot[0].stop ~= 0
end
function P.signal_stop(slot)
	slot[0].stop = 1
end

------------------------------------------------------------------
-- 跨语言槽布局核对（Low：槽布局人工维护）
-- 宿主侧 HV/Daemon.cj 手写 SLOT_*_OFF 与 @C struct DaemonSlot 一致；
-- 本库用 ffi 的运行时 struct 布局（编译器填充后的事实）逐项断言，
-- 把「仓颉定义 vs Lua cdef」的漂移在每次守护启动时自动暴露。
-- 仓颉侧基准（Daemon.cj:23-28，SLOT_SIZE=336）：
--   offset  0   char    mutex[64]     (pthread_mutex_t, 预留 64)
--   offset 64  int32   count
--   offset 68  int32   nvals
--   offset 72  double  values[32]
--   offset 328 uint8   stop
-- ffi.offsetof/sizeof 并非所有 arch 都可用——不可用时跳过断言（回退旧行为）。
-- ffi 命名空间内未声明原生 pthread_mutex_t（HAL 只声明大小截断的别名），
-- 故真实 mutex 尺寸无法直接 sizeof；仅在可解析时做 ≤64B 预留校验。
-- 【修复】失败直接 error() fail-fast，不再返回 false——调用方若忽略返回值
-- 会在错误偏移读写共享槽，ABI 漂移即跨语言内存踩踏。
------------------------------------------------------------------
local function assert_layout()
	if not ffi.offsetof then return end
	local ok, err_msg = pcall(function()
		-- P2: pthread_mutex_t 真实尺寸须 ≤ 预留 64B（aarch64=48、x86_64=40）。
		--     类型未声明则 pcall 捕获并跳过——无法断言比已声明的更多。
		local mutex_type_ok, msz = pcall(function() return ffi.sizeof("pthread_mutex_t") end)
		if mutex_type_ok and msz > 64 then
			error("pthread_mutex_t size " .. tostring(msz) .. " > 64B slot mutex reserve")
		end
		local checks = {
			{ "count",   64,  ffi.offsetof("daemon_slot_t", "count") },
			{ "nvals",   68,  ffi.offsetof("daemon_slot_t", "nvals") },
			{ "values",  72,  ffi.offsetof("daemon_slot_t", "values") },
			{ "stop",   328,  ffi.offsetof("daemon_slot_t", "stop") },
			{ "size",   336,  ffi.sizeof("daemon_slot_t") },
		}
		for _, c in ipairs(checks) do
			if c[3] ~= c[2] then
				error("slot layout mismatch: " .. c[1] .. "=" .. tostring(c[3]) .. " (expect " .. c[2] .. ")")
			end
		end
	end)
	if not ok then
		error("BOT4CJ slot layout check failed: " .. tostring(err_msg))
	end
end
P.assert_layout = assert_layout

return P

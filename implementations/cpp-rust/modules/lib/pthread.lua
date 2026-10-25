-- pthread.lua - 守护线程 IPC 原语（纯 LuaJIT ffi）
-- bot4cj 仓颉语言机器人框架
--
-- 用途：@Daemon 机制的数据通路。守护线程在【独立 lua_State】上采样，
-- 经共享内存槽 publish 结果；主线程侧 latest 读取。线程本身的创建在仓颉
-- 宿主侧（HV/Daemon.cj 经 Cangjie spawn），本库只负责跨状态机的共享内存 + 互斥，
-- 全部经 ffi 直调 libc，无仓颉 cfunc（守住 issue #14 的纯 Lua 数据通路）。
--
-- 【共享槽布局】必须与 src/daemonvar.hpp 的 DaemonSlot 严格一致（同一 C ABI）。
-- ABI v2（2026-10-16，SLOT_MAXVALS 参数化）：values 由定长数组改为堆指针 +
-- capacity 字段，头布局自此永久稳定（96B）；容量按槽分配（maxvals 列）。
--   offset 0   char    mutex[64]    pthread_mutex_t（aarch64=48B/x86_64=40B，预留 64）
--   offset 64  int32   count        已 publish 次数
--   offset 68  int32   nvals        本次值个数
--   offset 72  double  *values      指向 capacity 个 double 的堆数组
--   offset 80  int32   capacity     本槽容量（分配后不可变；锁外读合法）
--   offset 84  uint8   stop         停止标志
--   offset 88  int32   status       守护 setup 状态（0=正常；负=失败码）
--   offset 92  int32   quiesce      总线灭火位（BQ-1：仅弃管守护被置位；HAL 的
--                                   bus_quiesced 持锁读，置位后传输一律拒绝）
--
-- 【cdef 约定】只声明 mutex/slot 专有类型，不重复声明 hal_backend_glibc.lua 已
-- 定义的 open/ioctl/read/write/usleep（守护 chunk 会同时加载 HAL，其后端已 cdef
-- 过这些符号，重复 cdef 会报错）。
--
-- 【地址注入契约】（2026-09-20 起：宿主经 lua_pushlightuserdata 注入）
-- 宿主把槽地址以 lightuserdata 全局注入（daemonvar.cpp injectDaemonGlobals）。
-- lightuserdata 在 Lua 域**无算术、无 tonumber**——「地址被 double 化在 >=2^53
-- 静默丢位」这一风险类别在语言层面消除，无需任何「禁止算术」约定兜底。
-- slot_attach 另保留两条兼容入口：ffi 指针（cdata，Lua 侧测试自造）与
-- 非负整数（纯 Lua 场景兜底）——整数路径仍有 >=2^53 告警：地址在 Lua 数字域
-- 被算术（+ - * /）或 tonumber 强制 double 时开始丢位，故各守护 chunk 仍禁止
-- 对整数形态的地址做任何算术（生产路径注入的 lightuserdata 不受影响）。
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
	double   *values;
	int32_t  capacity;
	uint8_t  stop;
	uint8_t  reserved[3];
	int32_t  status;
	int32_t  quiesce;
} daemon_slot_t;
]]

-- 2.7：布局常量的单一事实源在宿主（daemonvar.hpp struct + 静态断言），
-- 守护启动时经 DAEMON_SLOT_LAYOUT 注入；此处手写值仅为无宿主注入环境兜底。
-- ABI v2（2026-10-16）：values 指针化 + capacity；头 96B；maxvals 注入语义
-- 变为「本槽容量」（宿主按 maxvals 列分配），兜底值 = slot_new 的缺省容量。
local base_layout = DAEMON_SLOT_LAYOUT or
	{ count = 64, nvals = 68, values = 72, capacity = 80, stop = 84,
	  status = 88, quiesce = 92, size = 96, maxvals = 64 }

P.SLOT_MAXVALS = base_layout.maxvals

------------------------------------------------------------------
-- 地址 ↔ 指针
------------------------------------------------------------------
-- 整数地址（兜底路径）→ 类型化指针。
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
-- 附着到宿主分配的槽（addr 为 lightuserdata / ffi 指针 / 非负整数）
function P.slot_attach(addr)
	-- 生产路径：宿主经 lua_pushlightuserdata 注入。lightuserdata 在 Lua 域
	-- 无算术、无 tonumber，无需数值守卫（契约见文件头「地址注入契约」）。
	local t = type(addr)
	if t == "userdata" then
		return ffi.cast("daemon_slot_t *", ffi.cast("void *", addr))
	end
	-- ffi 指针（cdata）：Lua 侧测试自造指针的入口，同为类型安全的句柄
	if t == "cdata" then
		return ffi.cast("daemon_slot_t *", ffi.cast("void *", addr))
	end
	-- 旧整数路径保留：纯 Lua 场景与既有测试兜底。
	-- 前置守卫：地址必须仍为非负整数值。
	-- 危险点在 Lua 侧算术/tonumber 把整数 double 化后在 >=2^53 静默丢位
	-- ——那是使用方违规，任何事后检查都不可见，见契约注释。
	if t ~= "number" or addr < 0 or addr % 1 ~= 0 then
		error("DAEMON_SLOT_ADDR must be lightuserdata, ffi pointer, or a non-negative integer, got " .. tostring(addr))
	end
	if addr >= 2^53 then
		print("[pthread] warning: DAEMON_SLOT_ADDR " .. tostring(addr) .. " >= 2^53; treat as opaque, do NOT do arithmetic on it")
	end
	return ffi.cast("daemon_slot_t *", ffi.cast("uint64_t", addr))
end

-- 本库自行分配一个槽（仅供 Lua 侧测试/纯 Lua 场景；生产中由宿主 malloc 并注入地址）。
-- ABI v2：capacity 可指定（缺省 P.SLOT_MAXVALS=64）；采样数组与槽由锚表共同存活
-- —— ffi 结构体的指针字段**不**给目标 cdata 建立 GC 引用，不锚定的话数组会在
-- 槽仍被使用时被回收（悬垂指针）。弱键锚表：槽本身被收集时锚随条目消失。
local slot_anchors = setmetatable({}, { __mode = "k" })
function P.slot_new(capacity)
	local cap = capacity or P.SLOT_MAXVALS
	if type(cap) ~= "number" or cap < 1 or cap % 1 ~= 0 then
		error("slot_new: capacity must be a positive integer, got " .. tostring(capacity))
	end
	local slot = ffi.new("daemon_slot_t[1]")
	local vals = ffi.new("double[?]", cap)
	slot_anchors[slot] = vals
	slot[0].count = 0
	slot[0].nvals = 0
	slot[0].stop = 0
	slot[0].values = vals
	slot[0].capacity = cap
	P.mutex_init(slot)
	return slot
end

-- 本槽容量（ABI v2）：分配后不可变，锁外读合法（非数据竞争——见 daemonvar.hpp）
function P.capacity(slot)
	return slot[0].capacity
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
	local cap = slot[0].capacity
	if n > cap then n = cap end
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
	-- 审计 #10：count 为槽内 int32，1ms interval 高频守护约 25 天即到
	-- 2^31 上限——先回绕再写入，避免 ffi 截断 2^31 成负数（UB）
	slot[0].count = (slot[0].count + 1) % 0x7FFFFFFF
	mutex_call("unlock", m)
end

-- 主线程侧：读取最新一组值，返回 values 表（1 基）与 count
function P.latest(slot)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	local n = slot[0].nvals
	if n < 0 then n = 0 end
	local cap = slot[0].capacity
	if n > cap then n = cap end
	local t = {}
	for i = 0, n - 1 do
		t[i + 1] = slot[0].values[i]
	end
	local c = slot[0].count
	mutex_call("unlock", m)
	return t, c
end

-- 停止标志（守护循环轮询；宿主置位）。
-- 与 C++ 侧 daemon_request_stop/daemon_stop_requested（daemonvar.cpp 槽内
-- mutex 临界区）同一契约：两侧读写都必须持锁——宿主置 stop 与守护轮询
-- 是跨线程并发，裸读写虽有 uint8 对齐单字节访存兜底，但名义上是数据竞争
-- （TSan 视角），且 mutex 已在槽内、加锁成本可忽略。
function P.should_stop(slot)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	local stop = slot[0].stop ~= 0
	mutex_call("unlock", m)
	return stop
end
function P.signal_stop(slot)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	slot[0].stop = 1
	mutex_call("unlock", m)
end

-- 守护 setup 状态（N-27）：0 = 正常；负 = 失败码（sensor_daemon.fail 写入）。
-- 与 stop 同一契约：读写都持槽内 mutex。宿主的读路径据此把「守护启动失败」
-- 报成错误，而不是把失败码当成一个采样值（旧实现把 -2 发进 v0，下游会把它
-- 当温度做闭环——只有 count 停滞这种间接迹象）。
function P.get_status(slot)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	local st = slot[0].status
	mutex_call("unlock", m)
	return st
end

function P.set_status(slot, code)
	local m = slot_mutex(slot)
	mutex_call("lock", m)
	slot[0].status = code
	mutex_call("unlock", m)
end

------------------------------------------------------------------
-- 跨语言槽布局核对（Low：槽布局人工维护）
-- 宿主侧 src/daemonvar.hpp 手写 SLOT_*_OFF 与 struct DaemonSlot 一致；
-- 本库用 ffi 的运行时 struct 布局（编译器填充后的事实）逐项断言，
-- 把「C++ 定义 vs Lua cdef」的漂移在每次守护启动时自动暴露。
-- 基准 = 宿主注入的 DAEMON_SLOT_LAYOUT（来自 daemonvar.hpp 的 SLOT_* 常量，
-- 2.7 起不再手抄：C++ struct 漂移会在守护启动时经注入值与 cdef 比对暴露）。
-- 无宿主注入时回退手写基准（ABI v2 起头 96B、values 为指针 + capacity；
-- 本表须与 src/daemonvar.hpp 的 SLOT_* 常量逐项一致）：
--   offset  0   char    mutex[64]     (pthread_mutex_t, 预留 64)
--   offset 64  int32   count
--   offset 68  int32   nvals
--   offset 72  double  *values        (capacity 个 double 的堆数组)
--   offset 80  int32   capacity
--   offset 84  uint8   stop
--   offset 88  int32   status         (N-27：0=正常，负=setup 失败码)
--   offset 92  int32   quiesce        (BQ-1 停机灭火位)
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
			{ "count",    base_layout.count,    ffi.offsetof("daemon_slot_t", "count") },
			{ "nvals",    base_layout.nvals,    ffi.offsetof("daemon_slot_t", "nvals") },
			{ "values",   base_layout.values,   ffi.offsetof("daemon_slot_t", "values") },
			{ "capacity", base_layout.capacity, ffi.offsetof("daemon_slot_t", "capacity") },
			{ "stop",     base_layout.stop,     ffi.offsetof("daemon_slot_t", "stop") },
			{ "status",   base_layout.status,   ffi.offsetof("daemon_slot_t", "status") },
			{ "quiesce",  base_layout.quiesce,  ffi.offsetof("daemon_slot_t", "quiesce") },
			{ "size",     base_layout.size,     ffi.sizeof("daemon_slot_t") },
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

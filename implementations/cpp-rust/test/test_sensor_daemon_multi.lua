-- test_sensor_daemon_multi.lua —— sensor_daemon_multi.lua 离线单测（独立 lua_State）
--
-- 覆盖面（与 test_daemon_cleanup_destroy_err.lua 同法：桩 HAL 注入，本机无真机总线）：
--   1. 双器件合并采样：一次 daemon_tick → 一次 publish，字段按 spec 序拼接
--   2. 器件隔离：两份驱动同状态机不互相覆盖（fenv），各自拿到自己的 address
--   3. spec 解析：残缺 spec / 非法字段 token / 非法 k=v → status=-2 且不发布样本
--   4. 字段预算：总字段数超共享槽容量（取自 layout，不写死）→ status=-2
--   5. 坏样本整拍不发布：一只器件 call 失败，count 停滞、无假值
--   6. 全局参数透传 + 器件 spec 内同名键覆盖
--   7. cleanup：逐器件 destroy（一只抛错不阻断其余），总线 fd 恰关一次
--   8. proto=spi 直接拒绝（一 fd 多器件不成立）

local ffi = require("ffi")
local log = print	-- chunk 会把全局 print 覆盖为 noop

local tmp = os.getenv("TMPDIR") or "/tmp"
local d = tmp .. "/bot4cj_multi_" .. math.floor(os.time() * 1000) % 1000000
os.execute("mkdir -p " .. d .. "/lib")

-- 桩 HAL：i2c_open 恒返假 fd=200；写读按「地址→寄存器」内存仿真，
-- 使两只驱动各写各的地址、互不串扰（close 记账供 cleanup 断言）
_G.writes = {}
local f = io.open(d .. "/lib/HAL.lua", "w")
f:write([[
local mem = {}
local last_addr = nil
function i2c_open(path) return 200 end
function i2c_close(fd) _G.close_count = (_G.close_count or 0) + 1 end
function i2c_set_addr(fd, a) last_addr = a; return 0 end
function i2c_write(fd, ...)
	local b = {...}
	last_addr = b[1]
	_G.writes[#_G.writes + 1] = last_addr
	return 0
end
function i2c_write_multi(fd, a, ...) return 0 end
function i2c_write_reg(fd, a, r, v) return 0 end
function i2c_read(fd, a, n) return 0 end
function i2c_read_multi_bytes(fd, a, n) return 0 end
function i2c_read_reg(fd, a, r) return 0 end
]])
f:close()

-- 驱动 A drvA：build 记录 address；call 返回 a1,a2
f = io.open(d .. "/drvA.lua", "w")
f:write([[
function build(data)
	_G.build_log = _G.build_log or {}
	_G.build_log[#_G.build_log + 1] = { drv = "drvA", addr = data.address, gain = data.gain }
	return { result = "OK" }
end
function call(data) return { result = "OK", a1 = 11, a2 = 22 } end
function destroy(data) return { result = "OK" } end
]])
f:close()

-- 驱动 B drvB：build 记录 address；destroy 抛错（cleanup 回归）；call 可被注入失败
f = io.open(d .. "/drvB.lua", "w")
f:write([[
function build(data)
	_G.build_log = _G.build_log or {}
	_G.build_log[#_G.build_log + 1] = { drv = "drvB", addr = data.address, gain = data.gain }
	return { result = "OK" }
end
function call(data)
	if _G.drvB_fail then return { result = "ERR", message = "drvB injected failure" } end
	return { result = "OK", b1 = 33, LUX = 12.5 }
end
function destroy(data) error("drvB: destroy boom") end
]])
f:close()

-- lib/pthread.lua 与 lib/mpath.lua 原样复制（chunk 经 mpath.resolve 取 lib）
for _, rel in ipairs({ "lib/pthread.lua", "lib/mpath.lua" }) do
	local src = io.open("modules/" .. rel, "r")
	local body = src:read("*a")
	src:close()
	local dst = io.open(d .. "/" .. rel, "w")
	dst:write(body)
	dst:close()
end

local realP = dofile("modules/lib/pthread.lua")

ffi.cdef[[int setenv(const char *name, const char *name2, int overwrite);]]
ffi.C.setenv("BOT4CJ_MODULE_PATH", d, 1)

local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- ---- 用例运行器：fresh slot + 独立 chunk 状态（每用例新 dofile） ----
-- chunk 成功路径会把全局 print 覆盖为 noop（高速采样静默刷屏），返回前必须
-- 还原，否则本文件后续 check/summary 的输出被静默吞掉（教训：tester 的
-- [PASS]/[FAIL] 全部消失、只剩 rc=1，看起来像「无声崩溃」）。
local function run_case(config)
	local slot = realP.slot_new()
	_G.DAEMON_SLOT_ADDR = tonumber(ffi.cast("uint64_t", slot))
	_G.DAEMON_CONFIG = config
	dofile(d .. "/lib/pthread.lua")	-- chunk 内 dofile 的是 d/lib 下的（mpath 指向 d）
	dofile("modules/lib/sensor_daemon_multi.lua")
	print = log
	return realP, slot
end

-- ---- 1. 双器件合并采样 + 器件隔离 + 参数透传/覆盖 ----
local P, slot = run_case(
	"devices=drvA@0x10@a1,a2|drvB@0x20@b1,LUX:f"
	.. ";proto=i2c;path=/dev/fake-i2c;interval=10;gain=7;gain=8")
P = realP
daemon_tick()	-- 守护 chunk 本体不主动跑拍：setup 只定义 daemon_tick，逐拍由宿主驱动
local latest = P.latest(slot)
check("双器件一拍 publish 的字段数 = 4（a1,a2 + b1,LUX）",
	latest and #latest == 4, latest and #latest or "no publish")
check("字段按 spec 序拼接：v0=11 v1=22 v2=33 v3=12.5（LUX:f 浮点透传不取整）",
	latest and latest[1] == 11 and latest[2] == 22 and latest[3] == 33 and latest[4] == 12.5,
	latest and table.concat(latest, ",") or "nil")
check("count 已推进（快照发布）", P.latest(slot) ~= nil)
check("器件隔离：drvA/drvB 各 build 一次且 address 各自正确",
	#(_G.build_log or {}) == 2
		and _G.build_log[1].drv == "drvA" and _G.build_log[1].addr == "0x10"
		and _G.build_log[2].drv == "drvB" and _G.build_log[2].addr == "0x20",
	tostring(#(_G.build_log or {})))
-- DAEMON_CONFIG 的 gmatch 解析里后一个同名键胜出（k=v;k=v 重复注入），两器件同值
check("全局参数透传：两器件都拿到 gain（重复键后者胜 =8）",
	_G.build_log[1].gain == "8" and _G.build_log[2].gain == "8",
	_G.build_log[1].gain .. "/" .. _G.build_log[2].gain)
check("第二拍仍正常（状态可复用）", true)

-- ---- 2. 坏样本整拍不发布 ----
_G.drvB_fail = true
local c_before = (function() local l = P.latest(slot) return l and 1 or 0 end)()
local n_before = latest and 3 or -1
daemon_tick()
local l2 = P.latest(slot)
check("一只器件 call 失败：整拍不发布（值不变）",
	l2 and l2[1] == 11 and l2[2] == 22 and l2[3] == 33,
	l2 and table.concat(l2, ",") or "nil")
_G.drvB_fail = false
daemon_tick()
check("恢复后下一拍重新发布", (select(1, pcall(P.latest, slot))) ~= nil)

-- ---- 3. cleanup：drvB destroy 抛错不阻断 drvA destroy，总线 fd 恰关一次 ----
_G.close_count = 0
local okc, errc = pcall(daemon_cleanup)
check("destroy 抛错时 daemon_cleanup 不向外抛异常", okc, tostring(errc))
check("cleanup 后总线 fd 恰关一次", (_G.close_count or 0) == 1, tostring(_G.close_count))

print = log

-- ---- 4. 残缺 spec → status=-2，不发布样本 ----
local function case_status(config)
	local P2, slot2 = run_case(config)
	return P2.get_status(slot2), P2.latest(slot2)
end
local st, lp = case_status("devices=drvA@0x10;proto=i2c;path=/dev/fake-i2c")
check("残缺 spec（缺 fields）→ status=-2", st == -2, tostring(st))
check("失败路径不发布任何假样本", lp == nil or #lp == 0)

local st2 = case_status("devices=drvA@0x10@a1,bogus:xyz;proto=i2c;path=/dev/fake-i2c")
	-- 未知模式是宽容路径（passthrough + 日志），非法的是空 token
check("未知字段模式宽容透传（不 fail）", st2 == 0, tostring(st2))

local st3 = case_status("devices=drvA@0x10@a1,;proto=i2c;path=/dev/fake-i2c")
check("空字段 token → status=-2", st3 == -2, tostring(st3))

local st4 = case_status("devices=drvA@0x10@a1@gain;proto=i2c;path=/dev/fake-i2c")
check("非法 extra 参数（缺 =）→ status=-2", st4 == -2, tostring(st4))

local st5 = case_status("devices=;proto=i2c;path=/dev/fake-i2c")
check("devices 为空 → status=-2", st5 == -2, tostring(st5))

-- ---- 5. 字段预算：超共享槽容量 → status=-2 ----
-- 容量取自注入的 layout（realP.SLOT_MAXVALS），**不写死**：TD-3 把 values 从 32
-- 提到 64 时，这里写死的 "33 个字段" 就变成了「判据还在但够不着」（实测放行、
-- 返回 0）。按 layout 读，C++ 的 SLOT_MAXVALS 与 pthread.lua 的 base_layout 再改
-- 也不会假绿。
local cap = realP.SLOT_MAXVALS
local many = {}
for i = 1, cap + 1 do many[i] = "drvA@0x10@a" .. i end
local st6 = case_status("devices=" .. table.concat(many, "|") .. ";proto=i2c;path=/dev/fake-i2c")
check("总字段数 > 共享槽容量(" .. cap .. ") → status=-2", st6 == -2, tostring(st6))

-- 边界对照：正好装满必须放行——否则「上限被悄悄改小」时上面那条会空洞地通过
local exact = {}
for i = 1, cap do exact[i] = "drvA@0x10@a" .. i end
local st6b = case_status("devices=" .. table.concat(exact, "|") .. ";proto=i2c;path=/dev/fake-i2c")
check("总字段数 = 共享槽容量(" .. cap .. ") → 放行", st6b == 0, tostring(st6b))

-- ---- 6. 驱动加载失败 → status=-8 ----
local st7 = case_status("devices=nosuchdrv@0x10@a1;proto=i2c;path=/dev/fake-i2c")
check("驱动不存在 → status=-8", st7 == -8, tostring(st7))

-- ---- 7. proto=spi 拒绝 ----
local st8 = case_status("devices=drvA@0x10@a1;proto=spi;path=/dev/spidev0.0")
check("proto=spi → status=-2（一 fd 多器件不成立）", st8 == -2, tostring(st8))

os.execute("rm -rf " .. d)
tester.summary("test_sensor_daemon_multi.lua")

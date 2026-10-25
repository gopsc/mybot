-- test_sensor_aggregate.lua —— sensor_aggregate.lua 离线单测（独立 lua_State）
--
-- 覆盖面（与 test_sensor_daemon_multi.lua 同法：本机无宿主、无真机总线，
-- 桩掉 DAEMON_PEER_SLOTS / DAEMON_SLOT_ADDR 两个宿主注入全局）：
--   1. 拼接序与值：两路 peer 各发布一组 → 一拍聚合 = 按声明序拼接的整组值
--   2. 瞬时等待：peer 尚未首发（count=0）→ 整拍不发布 + 限频日志路径不炸
--   3. peer 停止（stop 置位）→ status=-11，此后 tick 空转不再发布
--   4. peer setup 失败（status≠0）→ status=-10
--   5. 容量超预算（拼接 > 本槽 maxvals）→ status=-2（首拍即判）
--   6. sources 名字未注入 DAEMON_PEER_SLOTS → status=-12
--   7. config 缺 sources → status=-12

local ffi = require("ffi")
local log = print	-- 防御：chunk 不静默 print，但保留还原纪律（multi 测试的教训）

local realP = dofile("modules/lib/pthread.lua")

ffi.cdef[[int setenv(const char *name, const char *name2, int overwrite);]]
ffi.C.setenv("BOT4CJ_MODULE_PATH", "./modules", 1)

local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- 用例运行器：新 own 槽 + 可选 peer 槽集合 + fresh chunk 状态（每用例新 dofile）。
-- own_cap 显式给（覆盖用例 5 的窄容量）；peers 形如 { {name=..., cap=...} }，
-- 返回 own 槽与 peer 槽表（键 = 名字）供断言与预发布。
local function run_case(config, own_cap, peers_spec)
	local own = realP.slot_new(own_cap or 64)
	local peer_slots = {}
	local inject = {}
	for _, ps in ipairs(peers_spec or {}) do
		local s = realP.slot_new(ps.cap or 64)
		peer_slots[ps.name] = s
		inject[ps.name] = tonumber(ffi.cast("uint64_t", s))
	end
	_G.DAEMON_SLOT_ADDR = tonumber(ffi.cast("uint64_t", own))
	_G.DAEMON_PEER_SLOTS = next(inject) and inject or nil
	_G.DAEMON_CONFIG = config
	dofile("modules/lib/sensor_aggregate.lua")
	print = log
	return own, peer_slots
end

-- ---- 1. 拼接序与值：imu0(3 值) + baro0(2 值) → 一拍 5 值，声明序 ----
local own, peers = run_case("sources=imu0|baro0;interval=20", 64,
	{ { name = "imu0" }, { name = "baro0" } })
realP.publish(peers.imu0, { 1.5, -2.5, 3.25 })
realP.publish(peers.baro0, { 100.5, 1013.25 })
daemon_tick()
local l, c = realP.latest(own)
check("一拍聚合 5 值（3+2，声明序拼接）", l ~= nil and #l == 5, l and #l or "no publish")
check("拼接值逐位相等（imu0 在前 baro0 在后）",
	l and l[1] == 1.5 and l[2] == -2.5 and l[3] == 3.25 and l[4] == 100.5 and l[5] == 1013.25,
	l and table.concat(l, ",") or "nil")
check("聚合 count 已推进", c ~= nil and c >= 1, tostring(c))

-- peer 更新一拍后，下一拍聚合拿到新值（快照跟随）
realP.publish(peers.baro0, { 200.5, 2025.5 })
daemon_tick()
local l2 = realP.latest(own)
check("peer 更新后下一拍跟随（baro0 新值到位）",
	l2 and l2[4] == 200.5 and l2[5] == 2025.5,
	l2 and table.concat(l2, ",") or "nil")

-- ---- 2. 瞬时等待：新 peer 未首发 → 整拍不发布（值保持旧拍） ----
local own2, peers2 = run_case("sources=p1|p2;interval=5", 64,
	{ { name = "p1" }, { name = "p2" } })
realP.publish(peers2.p1, { 7 })
daemon_tick()	-- p2 尚无首帧：不发布
local lw, cw = realP.latest(own2)
check("peer 未首发：整拍不发布（count 停滞）", lw == nil or #lw == 0,
	lw and #lw or "nil")
realP.publish(peers2.p2, { 8, 9 })
daemon_tick()
local l3 = realP.latest(own2)
check("两路就绪后发布（7,8,9）", l3 and #l3 == 3 and l3[1] == 7 and l3[2] == 8 and l3[3] == 9,
	l3 and table.concat(l3, ",") or "nil")

-- ---- 3. peer 停止 → status=-11，此后空转 ----
local own3, peers3 = run_case("sources=px;interval=5", 64, { { name = "px" } })
realP.publish(peers3.px, { 42 })
daemon_tick()
check("正常一拍先发布", (select(1, realP.latest(own3))) ~= nil)
realP.signal_stop(peers3.px)	-- 模拟热删除置 stop
daemon_tick()
check("peer 停止 → status=-11", realP.get_status(own3) == -11, tostring(realP.get_status(own3)))
realP.signal_stop(peers3.px)	-- （幂等置位，无副作用）
local before = realP.latest(own3)
daemon_tick()	-- 已 fail：tick 空转
local after = realP.latest(own3)
check("fail 后 tick 空转（不再发布新值）",
	before ~= nil and after ~= nil and #after == #before, "publish after fail")

-- ---- 4. peer setup 失败 → status=-10 ----
local own4, peers4 = run_case("sources=pf;interval=5", 64, { { name = "pf" } })
realP.set_status(peers4.pf, -8)	-- peer 驱动加载失败（复用既有失败码）
daemon_tick()
check("peer setup 失败 → status=-10", realP.get_status(own4) == -10, tostring(realP.get_status(own4)))

-- ---- 5. 容量超预算 → status=-2（首拍即判） ----
local own5, peers5 = run_case("sources=pa|pb;interval=5", 4,
	{ { name = "pa" }, { name = "pb" } })
realP.publish(peers5.pa, { 1, 2, 3 })
realP.publish(peers5.pb, { 4, 5 })	-- 合计 5 > own 容量 4
daemon_tick()
check("拼接超本槽容量 → status=-2", realP.get_status(own5) == -2, tostring(realP.get_status(own5)))

-- ---- 6. sources 名字未注入 → status=-12 ----
local own6 = run_case("sources=ghost;interval=5", 64, {})	-- DAEMON_PEER_SLOTS = nil
check("未注入的 peer 名 → status=-12", realP.get_status(own6) == -12, tostring(realP.get_status(own6)))

-- ---- 7. config 缺 sources → status=-12 ----
local own7 = run_case("interval=5", 64, {})
check("缺 sources 列 → status=-12", realP.get_status(own7) == -12, tostring(realP.get_status(own7)))

tester.summary("test_sensor_aggregate.lua")

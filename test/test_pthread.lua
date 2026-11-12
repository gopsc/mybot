-- pthread.lua 单元测试（纯 luajit，单线程验证 IPC 原语）
-- 并发正确性（守护线程 publish + 主线程 latest）由仓颉侧 @Daemon 压测覆盖，此处只验证原语。
-- 用法（项目根目录）: luajit test/test_pthread.lua

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 check 曾与 tester.check 逐字重复）
local tester = dofile("test/lib/tester.lua")
local check = tester.check

local P = dofile("modules/lib/pthread.lua")

-- 地址 ↔ 指针往返
do
	local slot = P.slot_new()
	local addr = P.addr(slot)
	check("slot 地址为正整数", type(addr) == "number" and addr > 0, addr)
	local p2 = P.ptr(addr, "daemon_slot_t *")
	check("ptr(addr) 往返一致", P.addr(p2) == addr)
end

-- 基本 publish / latest 往返
do
	local slot = P.slot_new()
	P.publish(slot, { 1.5, -2.25, 3.0 })
	local vals, count = P.latest(slot)
	check("publish/latest 值往返", #vals == 3 and vals[1] == 1.5 and vals[2] == -2.25 and vals[3] == 3.0,
		vals[1] and vals[2] and vals[3])
	check("publish 计数=1", count == 1, count)
end

-- 多次 publish：count 累加，latest 取最新
do
	local slot = P.slot_new()
	for i = 1, 5 do P.publish(slot, { i * 10 }) end
	local vals, count = P.latest(slot)
	check("多次 publish 计数累加", count == 5, count)
	check("latest 取最新值", vals[1] == 50, vals[1])
end

-- 超过 MAXVALS 截断
do
	local slot = P.slot_new()
	local big = {}
	for i = 1, P.SLOT_MAXVALS + 5 do big[i] = i end
	P.publish(slot, big)
	local vals = P.latest(slot)
	check("超 MAXVALS 截断到上限", #vals == P.SLOT_MAXVALS, #vals)
end

-- 满额通道往返（values[SLOT_MAXVALS]，TD-3 起 64；支撑单守护聚合多路传感器）。
-- 逐通道核对而非只看首尾：扩容后若只断言 vals[32]，33..上限那段槽位
-- 回读错了也照样绿。
do
	local slot = P.slot_new()
	local full = {}
	for i = 1, P.SLOT_MAXVALS do full[i] = i * 0.5 end
	P.publish(slot, full)
	local vals, count = P.latest(slot)
	local all_match = #vals == P.SLOT_MAXVALS and count == 1
	local bad = nil
	for i = 1, P.SLOT_MAXVALS do
		if vals[i] ~= i * 0.5 then all_match = false; bad = i; break end
	end
	check("满额通道值往返", all_match,
		string.format("n=%s bad=%s", tostring(#vals), tostring(bad)))
end

-- 停止标志
do
	local slot = P.slot_new()
	check("初始 should_stop=false", P.should_stop(slot) == false)
	P.signal_stop(slot)
	check("signal_stop 后 should_stop=true", P.should_stop(slot) == true)
end

-- cdata ffi 指针附着（slot_attach 新路径，与宿主 lightuserdata 注入同族：
-- 类型安全句柄，不经 Lua 数字域）。lightuserdata 本体只能由 C API 产生，
-- 无法在纯 Lua 里自造——该路径由 run_all.sh 的守护 e2e（真注入）覆盖。
do
	local owner = P.slot_new()
	local attached = P.slot_attach(owner)	-- cdata 指针直传
	P.publish(attached, { 7.0, 8.0 })	-- 经附着句柄写
	local vals, count = P.latest(owner)	-- 经原句柄读
	check("cdata 指针附着与原句柄共享内存", vals[1] == 7.0 and vals[2] == 8.0 and count == 1,
		string.format("v1=%s v2=%s c=%s", tostring(vals[1]), tostring(vals[2]), tostring(count)))
	P.signal_stop(owner)
	check("cdata 跨句柄停止标志可见", P.should_stop(attached) == true)
end

-- 地址注入 → 附着（模拟守护线程：宿主给地址，Lua 附着同一块内存）
do
	local owner = P.slot_new()
	local addr = P.addr(owner)
	local attached = P.slot_attach(addr)	-- 第二个句柄，指向同一内存
	P.publish(attached, { 7.0, 8.0 })	-- 经附着句柄写
	local vals, count = P.latest(owner)	-- 经原句柄读
	check("附着句柄与原句柄共享内存", vals[1] == 7.0 and vals[2] == 8.0 and count == 1,
		string.format("v1=%s v2=%s c=%s", tostring(vals[1]), tostring(vals[2]), tostring(count)))
	P.signal_stop(owner)
	check("跨句柄停止标志可见", P.should_stop(attached) == true)
end

tester.summary("test_pthread.lua")

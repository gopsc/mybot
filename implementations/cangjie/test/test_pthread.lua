-- pthread.lua 单元测试（纯 luajit，单线程验证 IPC 原语）
-- 并发正确性（守护线程 publish + 主线程 latest）由仓颉侧 @Daemon 压测覆盖，此处只验证原语。
-- 用法（项目根目录）: luajit test/test_pthread.lua

local passed, failed = 0, 0
local function check(label, cond, detail)
	if cond then
		passed = passed + 1; print("[PASS] " .. label)
	else
		failed = failed + 1
		print("[FAIL] " .. label .. (detail ~= nil and ("  | " .. tostring(detail)) or ""))
	end
end

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
	check("超 MAXVALS 截断到 32", #vals == P.SLOT_MAXVALS, #vals)
end

-- 满额 32 通道往返（P：values[32]，支撑单守护聚合多路传感器）
do
	local slot = P.slot_new()
	local full = {}
	for i = 1, P.SLOT_MAXVALS do full[i] = i * 0.5 end
	P.publish(slot, full)
	local vals, count = P.latest(slot)
	check("满 32 通道值往返", #vals == P.SLOT_MAXVALS and vals[1] == 0.5
		and vals[32] == 32 * 0.5 and count == 1,
		string.format("n=%s last=%s", tostring(#vals), tostring(vals[32])))
end

-- 停止标志
do
	local slot = P.slot_new()
	check("初始 should_stop=false", P.should_stop(slot) == false)
	P.signal_stop(slot)
	check("signal_stop 后 should_stop=true", P.should_stop(slot) == true)
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

print(string.format("结果: %d 通过, %d 失败", passed, failed))
if failed > 0 then os.exit(1) end

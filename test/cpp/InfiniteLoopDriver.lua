-- InfiniteLoopDriver.lua —— test/cpp/test_agenttools.cpp 用的假驱动（PL-2 动作脚本执行预算）
--
-- 目的单一：`call()` **永不返回**，用来钉住「宿主对动作脚本有执行预算」这条语义。
-- 没有这个夹具，PL-2 的用例只能靠"跑很久"来间接观察，反向验证还会把 CI 挂死。
--
-- 两种挂法各钉一条路径（由 build 期的 looping 字段选）。
-- ⚠️ 列名**不能叫 mode**：宿主在 build 期会注入 mode="build"（驱动契约字段，
-- 见 luavar.cpp 的 riseImpl），数据列用 mode 会被它覆盖。
--   busy   ：`while true do end` —— 纯 Lua 死循环。**钩子必须能打断它**；
--            而在 LuaJIT 下这恰恰是 jit 开时钩子抓不到的那类（热点会编译成
--            trace），所以这条用例同时是「arm 时确实关了 JIT」的守门。
--   ret    ：死循环里做一次函数调用，避免被优化成空循环（更接近真实驱动的
--            参数处理循环）。
-- 其余入参一律返回 OK，使动作脚本能正常走到这一行。

local mode = "busy"

function build(data)
	if data ~= nil and data.looping ~= nil then mode = tostring(data.looping) end
	return { result = "OK" }
end

function destroy(data)
	return { result = "OK" }
end

function call(data)
	if mode == "ok" then return { result = "OK" } end	-- 正常返回：给「窗口收口」用例用
	if mode == "ret" then
		local n = 0
		while true do n = n + 1 end	-- 死循环里带一次算术，避免被优化成空循环
	end
	while true do end			-- busy：纯 Lua 死循环
end

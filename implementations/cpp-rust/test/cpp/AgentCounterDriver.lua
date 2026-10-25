-- AgentCounterDriver.lua —— wait_variable 回归用的假传感器（test/cpp/test_agenttools.cpp）
--
-- 每次 call() 把 count 加 1 并回 { result="OK", count=n, label="tick-<n>", text="abc" }：
--   * count 单调递增 → gt/ge 条件必在有限采样内满足、changed 在第二次采样即成立；
--   * label 随 count 变 → 字串 eq/ne 有判别力；
--   * text 恒为非数值字串 → 排序条件撞上它必须报参数错，而不是等到超时。
-- 每个变量实例各持一个 Lua 状态，计数互不干扰。

local count = 0

function build(data)
	return { result = "OK" }
end

function destroy(data)
	return { result = "OK" }
end

function call(data)
	count = count + 1
	return { result = "OK", count = count, label = "tick-" .. count, text = "abc" }
end

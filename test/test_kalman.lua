-- kalman.lua 单元测试（lua5.4 与 luajit 均可运行）
-- 用法（项目根目录）: lua5.4 test/test_kalman.lua

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 check 曾与 tester.check 逐字重复）
local tester = dofile("test/lib/tester.lua")
local check = tester.check

local Kalman = dofile("modules/lib/kalman.lua")

-- 用例1：首步手工值
-- X_mid = 1*0 = 0；P_mid = 1*0 + Q = 20；kg = 20/(20+200) = 1/11
-- X_now = 0 + (1/11)*(50-0) = 50/11
local kf = Kalman.new(20, 200)
local v1 = kf:filter(50)
check("首步滤波值 = Z*Q/(Q+R)", math.abs(v1 - 50 * 20 / 220) < 1e-12, v1)
check("首步协方差 P = (1-kg)*P_mid",
	math.abs(kf.P_last - (1 - 20 / 220) * 20) < 1e-12, kf.P_last)

-- 用例2：常量信号收敛
kf = Kalman.new(20, 200)
local v
for _ = 1, 200 do v = kf:filter(100) end
check("常量信号收敛到 100", math.abs(v - 100) < 0.01, v)

-- 用例3：Q=0 → 完全信任模型预测（kg=0，输出恒为初值）
kf = Kalman.new(0, 200)
v = kf:filter(100)
check("Q=0 时输出不跟随测量值", v == 0, v)

-- 用例4：R 远小于 Q → 高度信任测量，首步几乎等于测量值
kf = Kalman.new(200, 0.001)
v = kf:filter(50)
check("R 极小时首步紧贴测量值", math.abs(v - 50) < 0.05, v)

-- 用例5：噪声抑制——含噪常量信号，滤波后方差应显著小于原始
kf = Kalman.new(1, 50)
local seed = 12345
local function rnd()		-- 确定性线性同余伪随机（跨解释器一致）
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
local N = 500
local BURN_IN = 50	-- 滤波器从 X=0 起步，跳过收敛瞬态再统计
local raws, flts = {}, {}
for i = 1, N do
	raws[i] = 100 + (rnd() - 0.5) * 20	-- 100 ± 10 均匀噪声
	flts[i] = kf:filter(raws[i])
end
local function mean(t, from)
	local s = 0
	for i = from, #t do s = s + t[i] end
	return s / (#t - from + 1)
end
local function variance(t, from)
	local m = mean(t, from)
	local s = 0
	for i = from, #t do s = s + (t[i] - m) ^ 2 end
	return s / (#t - from + 1)
end
local raw_var, flt_var = variance(raws, BURN_IN + 1), variance(flts, BURN_IN + 1)
check("滤波后方差小于原始方差", flt_var < raw_var,
	string.format("raw=%.3f flt=%.3f", raw_var, flt_var))
check("滤波均值仍贴近真值 100", math.abs(mean(flts, BURN_IN + 1) - 100) < 1.0,
	mean(flts, BURN_IN + 1))

-- 用例6：字符串数值可被接受（框架元数据以字符串传值）
kf = Kalman.new("20", "200")
v = kf:filter("50")
check("字符串参数经 tonumber 接受", math.abs(v - 50 * 20 / 220) < 1e-12, v)

-- 用例7：非法参数报错
check("Kalman.new 非数值报错", pcall(Kalman.new, "abc", 1) == false)
check("Kalman.new Q<0 报错", pcall(Kalman.new, -1, 1) == false)
check("Kalman.new R=0 报错（kg=0/0 NaN）", pcall(Kalman.new, 1, 0) == false)
check("Kalman.new R<0 报错", pcall(Kalman.new, 1, -1) == false)
check("Kalman.new Q=0 R>0 合法", pcall(Kalman.new, 0, 1) == true)
check("filter 非数值报错", pcall(function() Kalman.new(1, 1):filter("xyz") end) == false)

-- 非有限值防线（2026-09-20 评估）：`Q < 0` / `R <= 0` 对 NaN 全为假、旧实现放行
check("Kalman.new Q=NaN 报错", pcall(Kalman.new, 0/0, 200) == false)
check("Kalman.new Q='nan' 报错", pcall(Kalman.new, "nan", 200) == false)
check("Kalman.new R=NaN 报错", pcall(Kalman.new, 20, 0/0) == false)
check("filter NaN 报错", pcall(function() Kalman.new(20, 200):filter(0/0) end) == false)
check("filter inf 报错", pcall(function() Kalman.new(20, 200):filter(math.huge) end) == false)
check("Q=inf 仍合法（既有语义：只用测量值）", pcall(Kalman.new, math.huge, 200) == true)

-- 用例8：Q=inf → kg 取极限 1（kg=inf/inf=NaN 的修复，2026-09-20）
-- Q=-inf 被 new 的 Q>=0 拒绝；filter 内 -inf 分支纯属防御（P_mid 恒非负）。
kf = Kalman.new(math.huge, 200)
v = kf:filter(50)
check("Q=inf 输出即测量值 50", v == 50, tostring(v))
check("Q=inf 后 P 回落 R（有限）",
	kf.P_last == 200 and kf.P_last == kf.P_last, tostring(kf.P_last))
v = kf:filter(30)
check("Q=inf 连续拍不产生 NaN", v == 30 and v == v, tostring(v))
for i = 1, 100 do v = kf:filter(100 + i) end
check("Q=inf 长跑保持有限", v == 200 and v == v, tostring(v))

tester.summary("test_kalman.lua")

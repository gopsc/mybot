-- ema.lua 单元测试（lua5.4 与 luajit 均可运行）
-- 用法（项目根目录）: lua5.4 test/test_ema.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local Ema = dofile("modules/lib/ema.lua")

-- α=1 完全直通
do
	local f = Ema.new(1.0)
	check("α=1 首样本直通", f:filter(5) == 5)
	check("α=1 后续直通", f:filter(9) == 9 and f:filter(-3) == -3)
end

-- 首样本初始化 + 精确序列（α=0.5）
do
	local f = Ema.new(0.5)
	check("首样本初始化为该样本(100)", f:filter(100) == 100)
	check("α=0.5 第2步=150", f:filter(200) == 150)
	check("α=0.5 第3步=225", f:filter(300) == 225)
	check("α=0.5 第4步=312.5", f:filter(400) == 312.5)
end

-- 带 init 初值：首样本即融合
do
	local f = Ema.new(0.5, 100)	-- 初值 100
	check("带 init：首样本 0 → 0.5*0+0.5*100=50", f:filter(0) == 50)
end

-- 阶跃收敛（α=0.2，0→100）
do
	local f = Ema.new(0.2)
	f:filter(0)				-- 初值 0
	local y
	for _ = 1, 30 do y = f:filter(100) end
	-- y = 100*(1-0.8^30) ≈ 99.88
	check("阶跃 30 拍收敛到 ~100", math.abs(y - 100) < 2, y)
end

-- value() 幂等、不推进状态
do
	local f = Ema.new(0.3)
	f:filter(10)
	check("value() 幂等不推进", f:value() == f:value())
end

-- reset
do
	local f = Ema.new(0.5)
	f:filter(10); f:filter(20)
	f:reset()
	check("reset() 后首样本重新初始化", f:filter(99) == 99)
	f:reset(50)
	check("reset(50) 后 filter(50)=50", f:filter(50) == 50)
end

-- 降噪：含噪常量信号，滤波后方差应显著小于原始
do
	local f = Ema.new(0.1)
	local seed = 24680
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local raws, flts = {}, {}
	for i = 1, 300 do
		local x = 50 + (rnd() - 0.5) * 20
		raws[i] = x
		flts[i] = f:filter(x)
	end
	local function var(t, from)
		local n, m = 0, 0
		for i = from, #t do m = m + t[i]; n = n + 1 end
		m = m / n
		local s = 0
		for i = from, #t do s = s + (t[i] - m) ^ 2 end
		return s / n
	end
	local rv, fv = var(raws, 51), var(flts, 51)	-- 跳过烧机期
	check("EMA 降噪：滤波后方差 < 原始", fv < rv, string.format("raw=%.3f flt=%.3f", rv, fv))
	check("滤波均值仍贴近真值 50", math.abs((function()
		local s = 0 for i = 51, 300 do s = s + flts[i] end return s / 250
	end)() - 50) < 1.0)
end

-- 字符串输入（框架元数据以字符串传值）
do
	local f = Ema.new("0.5")
	check("字符串 α/样本经 tonumber 接受", f:filter("10") == 10 and f:filter("20") == 15)
end

-- 错误路径
check("α=0 报错", pcall(Ema.new, 0) == false)
check("α>1 报错", pcall(Ema.new, 1.5) == false)
check("α 非数值报错", pcall(Ema.new, "x") == false)
check("filter 非数值报错", pcall(function() Ema.new(0.5):filter("xyz") end) == false)

tester.summary()

-- ema.lua - 指数移动平均滤波器（EMA，一阶低通）
-- bot4cj 仓颉语言机器人框架
--
-- 最常用的传感器平滑：y[n] = α·x[n] + (1-α)·y[n-1]
--   α ∈ (0,1]：α=1 完全跟随（不平滑），α 越小越平滑、滞后越大
--   单参数、O(1) 计算、无需窗口缓存，适合高频采样
-- 与 kalman.lua 接口一致（.new + :filter），可互换使用。
--
-- 用法：
--   local Ema = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/ema.lua")
--   local f = Ema.new(0.2)          -- α=0.2；可选第二参数为初始输出值
--   local y = f:filter(raw)         -- 每来一个样本调用一次
--   f:reset()                       -- 复位（下一个样本重新初始化）

local Ema = {}
Ema.__index = Ema

-- 创建滤波器
--   alpha: 平滑系数 (0,1]
--   init:  可选初始输出；缺省时用首个样本初始化（避免从 0 起跳）
-- 非有限值（NaN/±inf）防线：区间比较对 NaN 恒为假——只写
-- `alpha == nil or alpha <= 0 or alpha > 1` 时 NaN 三条全假、**穿过检查**
-- （2026-09-20 评估：alpha 列写 "nan" 会让整条滤波序列变成 NaN 却返回 OK）。
-- 故判据统一写成「必须同时满足上下界」的正向式，NaN 自然被拒。
function Ema.new(alpha, init)
	alpha = tonumber(alpha)
	if not (alpha ~= nil and alpha > 0 and alpha <= 1) then
		error("Ema.new: alpha must be in (0, 1], got " .. tostring(alpha))
	end
	local y0 = tonumber(init)
	if y0 ~= nil and not (y0 > -math.huge and y0 < math.huge) then y0 = nil end	-- 非有限初值按未给处理
	return setmetatable({
		alpha  = alpha,
		y      = y0,
		inited = (y0 ~= nil),
	}, Ema)
end

-- 输入一个样本，返回滤波后的值
function Ema:filter(x)
	x = tonumber(x)
	if not (x ~= nil and x > -math.huge and x < math.huge) then
		error("Ema:filter: x must be a finite number")
	end
	if not self.inited then
		self.y = x			-- 首个样本直接作为初值
		self.inited = true
	else
		self.y = self.alpha * x + (1 - self.alpha) * self.y
	end
	return self.y
end

-- 当前输出（不推进）
function Ema:value()
	return self.y
end

-- 复位；可给新初值，否则下一个样本重新初始化
function Ema:reset(init)
	local y0 = tonumber(init)
	if y0 ~= nil and not (y0 > -math.huge and y0 < math.huge) then y0 = nil end	-- 同 new：非有限按未给
	self.y = y0
	self.inited = (y0 ~= nil)
end

return Ema

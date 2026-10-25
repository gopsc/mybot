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
function Ema.new(alpha, init)
	alpha = tonumber(alpha)
	if alpha == nil or alpha <= 0 or alpha > 1 then
		error("Ema.new: alpha must be in (0, 1], got " .. tostring(alpha))
	end
	local y0 = tonumber(init)
	return setmetatable({
		alpha  = alpha,
		y      = y0,
		inited = (y0 ~= nil),
	}, Ema)
end

-- 输入一个样本，返回滤波后的值
function Ema:filter(x)
	x = tonumber(x)
	if x == nil then
		error("Ema:filter: x must be a number")
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
	self.y = tonumber(init)
	self.inited = (self.y ~= nil)
end

return Ema

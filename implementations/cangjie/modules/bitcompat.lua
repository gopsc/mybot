-- bitcompat.lua - 位运算的可移植实现
-- bot4cj 仓颉语言机器人框架
--
-- 背景：部分驱动模块原先使用 Lua 5.3+ 的位运算符（| & ~ << >>），
-- LuaJIT（5.1 语法）无法编译。本库以函数形式提供等价操作，双兼容：
--   - LuaJIT 下直接复用内建 bit 库（原生速度）
--   - 纯 Lua 5.4/5.1 环境下回退到算术实现（保持 lua5.4 独立调试能力）
--
-- 约定：仅支持非负整数、结果在 32 位有符号范围内
-- （本项目寄存器域均为 8~24 位，满足约定）。
--
-- 用法：local bitc = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/bitcompat.lua")

local M = {}

local ok, bit = pcall(require, "bit")
if ok then
	M.bor    = bit.bor
	M.band   = bit.band
	M.bxor   = bit.bxor
	M.lshift = bit.lshift
	M.rshift = bit.rshift
	return M
end

------------------------------------------------------------------
-- 算术回退实现
------------------------------------------------------------------
local function toint(v)
	local n = math.floor(tonumber(v) or 0)
	if n < 0 then n = 0 end	-- 负数不在约定范围内，按 0 处理
	return n
end

function M.band(a, b)
	a, b = toint(a), toint(b)
	local r, p = 0, 1
	while a > 0 and b > 0 do
		local da, db = a % 2, b % 2
		if da == 1 and db == 1 then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

function M.bor(a, b)
	a, b = toint(a), toint(b)
	local r, p = 0, 1
	while a > 0 or b > 0 do
		local da, db = a % 2, b % 2
		if da == 1 or db == 1 then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

function M.bxor(a, b)
	a, b = toint(a), toint(b)
	local r, p = 0, 1
	while a > 0 or b > 0 do
		local da, db = a % 2, b % 2
		if da ~= db then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

function M.lshift(a, n)
	return toint(a) * (2 ^ toint(n))
end

function M.rshift(a, n)
	return math.floor(toint(a) / (2 ^ toint(n)))
end

return M

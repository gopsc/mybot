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
-- 用法：local bitc = dofile(mpath.resolve("bitcompat.lua"))（mpath 见 modules/lib/mpath.lua）

local M = {}

------------------------------------------------------------------
-- 符号扩展原语（寄存器原码 → 有符号值）——纯算术，双解释器共用，
-- 必须先于 LuaJIT 早退分支定义（bit 库路径提前 return）
-- 全仓 ≥10 个驱动各自内联同一实现（s16/s12/s8/s16le），收敛于此单点维护：
--   M.u16le(b, i)   字节表 b 自下标 i 起小端 2 字节 → 无符号 16 位
--   M.s16le(b, i)   同上 → 有符号（补码）
--   M.s16(v)  16 位补码 → 有符号；M.s12(v)；M.s8(v)
------------------------------------------------------------------
function M.u16le(b, i)
	return b[i] + b[i + 1] * 256
end

function M.s16le(b, i)
	local v = b[i] + b[i + 1] * 256
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end

function M.s16(v)
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end

function M.s12(v)
	if v >= 0x800 then v = v - 0x1000 end
	return v
end

function M.s8(v)
	if v >= 0x80 then v = v - 0x100 end
	return v
end

------------------------------------------------------------------
-- CRC-8（D1 收敛，2026-09-25）：三处驱动手抄同一逐位算法、两套器件参数——
--   SHT3X/SGP30（Sensirion 约定）：poly 0x31、init 0xFF、16 位词按 hi/lo 展开；
--   MT6826S（磁编码器）：poly 0x07、init 0x00、字节表直入。
-- 算法单点在此（M.crc8(init, poly, bytes)），器件参数留在调用方——那是器件
-- 手册事实，不是可收敛的样板。各驱动的 *_VIRT 模型 crc8 **刻意保持独立实现**
-- （模型/驱动/测试三方交叉验证，改这里不必也不应动它们）。
-- 逐位等价说明：旧实现两派写法——「bxor(lshift(crc,1), poly) 再掩 0xFF」
-- （SHT3X/SGP30）与「bxor(band(lshift(crc,1),0xFF), poly)」（MT6826S）——在
-- poly ≤ 0xFF 时都与本实现（先掩后异）逐位一致：bit8 只被掩码移除，异 poly
-- 不产生进位。每拍至多几个词，逐位 8×len 次足够，不设查表。
-- 定义在早退分支之前：M.bxor/band/lshift 调用时才解析，两条路径（bit 库 /
-- 算术回退）都已就绪，且本函数不参与 LuaJIT 早退 return。
------------------------------------------------------------------
function M.crc8(init, poly, bytes)
	local crc = init
	for _, b in ipairs(bytes) do
		crc = M.bxor(crc, b)
		for _ = 1, 8 do
			local msb = M.band(crc, 0x80)
			crc = M.band(M.lshift(crc, 1), 0xFF)
			if msb ~= 0 then crc = M.bxor(crc, poly) end
		end
	end
	return crc
end

-- 非有限值防线（2026-09-20 审计 C2）：LuaJIT 的 bit 库对 NaN/±inf **不报错**，
-- 而是静默返回 0（实测 bit.band(NaN,0xFF)=0，lshift/rshift 同为 0）。驱动里
-- 一旦有 NaN 流进位运算（结构脚本字符串列写 "nan"、"1e400" 这类），得到的
-- 不是错误而是**一个合法的 0**：PCA9685 据此把 NaN 角度写成 ON=0/OFF=0
-- （无脉冲）却返回 result="OK"，既不动也不报错。
-- 包装层只拦**非有限**入参；一切有限入参逐字透传（含 1.5 这类既有的截断
-- 语义），故对现有驱动的行为零变化。两条路径（LuaJIT bit 库 / 算术回退）
-- 必须同规——回退实现的 toint 同样把 NaN 静默吃成 0。
local function guard(name, fn)
	return function(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then
				error(string.format(
					"bitcompat.%s: argument #%d is not finite (NaN/inf);"
					.. " refusing to silently produce 0", name, i), 2)
			end
		end
		return fn(...)
	end
end

local ok, bit = pcall(require, "bit")
if ok then
	M.bor    = guard("bor", bit.bor)
	M.band   = guard("band", bit.band)
	M.bxor   = guard("bxor", bit.bxor)
	M.lshift = guard("lshift", bit.lshift)
	M.rshift = guard("rshift", bit.rshift)
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

local function band2(a, b)
	local r, p = 0, 1
	while a > 0 and b > 0 do
		local da, db = a % 2, b % 2
		if da == 1 and db == 1 then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

local function bor2(a, b)
	local r, p = 0, 1
	while a > 0 or b > 0 do
		local da, db = a % 2, b % 2
		if da == 1 or db == 1 then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

local function bxor2(a, b)
	local r, p = 0, 1
	while a > 0 or b > 0 do
		local da, db = a % 2, b % 2
		if da ~= db then r = r + p end
		a, b, p = (a - da) / 2, (b - db) / 2, p * 2
	end
	return r
end

-- LuaJIT 的 bit 库是变参语义（bit.bor(a, b, c, ...)），回退实现同样收口为
-- 变参归约——否则 AD9833 的 bitc.bor(BIT_B28, wbits, muted and BIT_RESET or 0)
-- 这类三参调用在 lua5.4 调试路径下第三个参数被静默丢弃（审计 #5：RESET 位
-- 丢失，硬件收到错误命令且无任何报错）。
local function fold(op)
	return function(first, ...)
		local r = toint(first)
		for i = 1, select("#", ...) do
			r = op(r, toint((select(i, ...))))
		end
		return r
	end
end

M.band  = guard("band", fold(band2))
M.bor   = guard("bor", fold(bor2))
M.bxor  = guard("bxor", fold(bxor2))

function M.lshift(a, n)
	return toint(a) * (2 ^ toint(n))
end

function M.rshift(a, n)
	return math.floor(toint(a) / (2 ^ toint(n)))
end

-- 回退路径同样过防线（toint 对 NaN 同样静默返回 0）
M.lshift = guard("lshift", M.lshift)
M.rshift = guard("rshift", M.rshift)

return M

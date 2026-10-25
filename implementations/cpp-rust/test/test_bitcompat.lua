-- test_bitcompat.lua - 位运算非有限值防线回归（2026-09-20 审计 C2）
--
-- LuaJIT 的 bit 库对 NaN/±inf 不报错而是**静默返回 0**（实测 bit.band(NaN,0xFF)=0）。
-- 驱动里一旦有 NaN 流进位运算，得到的不是错误而是一个合法的 0：PCA9685 因此把
-- NaN 角度写成 ON=0/OFF=0（无脉冲）却返回 result="OK"。bitcompat 是全仓位运算
-- 的单点，故防线放在这里；**有限入参的行为必须逐字不变**（含既有的小数截断语义）。
--
-- 用法（项目根目录）: luajit test/test_bitcompat.lua
local tester = dofile("test/lib/tester.lua")
local bitc = dofile("modules/bitcompat.lua")

local nan = 0 / 0
local inf = math.huge

-- ---- 非有限入参：必须抛错，绝不静默返回 0 ----

local function raises(label, fn)
	local ok, err = pcall(fn)
	tester.check(label, ok == false and tostring(err):find("not finite", 1, true) ~= nil,
		ok and ("returned " .. tostring(err)) or tostring(err))
end

raises("band(NaN, 0xFF) 抛错", function() return bitc.band(nan, 0xFF) end)
raises("band(0xFF, NaN) 抛错（非首位参数同样拦）", function() return bitc.band(0xFF, nan) end)
raises("bor(1, inf) 抛错", function() return bitc.bor(1, inf) end)
raises("bxor(-inf, 1) 抛错", function() return bitc.bxor(-inf, 1) end)
raises("lshift(NaN, 8) 抛错", function() return bitc.lshift(nan, 8) end)
raises("rshift(NaN, 8) 抛错", function() return bitc.rshift(nan, 8) end)
raises("band(NaN, NaN) 抛错", function() return bitc.band(nan, nan) end)

-- ---- 有限入参：行为逐字不变（防线不得误伤）----

tester.check("band(0xF0, 0x0F) == 0", bitc.band(0xF0, 0x0F) == 0)
tester.check("band(0xBC, 0x0F) == 0x0C", bitc.band(0xBC, 0x0F) == 0x0C)
tester.check("bor(1, 2) == 3", bitc.bor(1, 2) == 3)
tester.check("bor(1, 2, 4) == 7（变参语义）", bitc.bor(1, 2, 4) == 7)
tester.check("bxor(0xFF, 0x0F) == 0xF0", bitc.bxor(0xFF, 0x0F) == 0xF0)
tester.check("lshift(1, 8) == 256", bitc.lshift(1, 8) == 256)
tester.check("rshift(256, 8) == 1", bitc.rshift(256, 8) == 1)
tester.check("band(1.5, 3) == 2（既有小数截断语义保留）", bitc.band(1.5, 3) == 2)
tester.check("band(0, 0xFF) == 0", bitc.band(0, 0xFF) == 0)

-- ---- 符号扩展原语不受影响（纯算术，共用路径）----

tester.check("s16(0x8000) == -32768", bitc.s16(0x8000) == -32768)
tester.check("s12(0x800) == -2048", bitc.s12(0x800) == -2048)
tester.check("s8(0x80) == -128", bitc.s8(0x80) == -128)
tester.check("u16le({0x34,0x12}, 1) == 0x1234", bitc.u16le({0x34, 0x12}, 1) == 0x1234)
tester.check("s16le({0x00,0x80}, 1) == -32768", bitc.s16le({0x00, 0x80}, 1) == -32768)

-- ---- CRC-8（D1 收敛自 SHT3X/SGP30/MT6826S 三处手抄）------------------------
-- 钉两套器件参数的已知值：Sensirion 例取 SHT3x 数据手册（0xBE 0xEF → 0x92）；
-- poly 0x07/init 0x00 取 CRC-8 标准校验串 "123456789" → 0xF4。两条解释器路径
-- （LuaJIT bit 库 / 算术回退）都必须命中同一批值。
tester.check("crc8(Sensirion 0xBEEF) == 0x92（数据手册例）",
	bitc.crc8(0xFF, 0x31, { 0xBE, 0xEF }) == 0x92)
local check = "123456789"
local bytes = {}
for i = 1, #check do bytes[i] = string.byte(check, i) end
tester.check("crc8(poly 0x07/init 0) 标准校验串 == 0xF4",
	bitc.crc8(0x00, 0x07, bytes) == 0xF4)
-- 空字节序列返回 init（旧实现的空表形态一致）
tester.check("crc8 空表返回初值", bitc.crc8(0xFF, 0x31, {}) == 0xFF)

tester.summary("test_bitcompat")
return 0

-- PCA9685.lua channel 越界校验离线测试（桩替身，不触碰真实 I2C）
-- 背景：channel 越界会写出 0x06+4*channel 之外的寄存器（issue #9 M2）
-- 用法: luajit test_pca9685_channel.lua（PCA9685 依赖 HAL，需 LuaJIT 的 ffi）

local writes = {}

dofile("modules/PCA9685.lua")

-- 桩：驱动加载后替换 HAL 全局。HAL 迁移（issue #14）后驱动 dofile 自带真实现，
-- 先注桩会被 HAL 的真函数覆盖；驱动在 call 时才解析全局名，后注桩才生效
function i2c_set_addr(fd, addr) return true end
function i2c_write_reg(fd, reg, val) writes[#writes + 1] = {reg = reg, val = val} end
-- call() 已改为单次 i2c_write_multi 原子写（AI 自增），按字节展开记录保持断言形态
function i2c_write_multi(fd, reg, ...)
	local bytes = {...}
	for i, b in ipairs(bytes) do
		writes[#writes + 1] = {reg = reg + i - 1, val = b}
	end
	return 0
end
function i2c_read_reg(fd, reg) return 0 end
function milli_sleep(ms) end

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 result_of/成败分支曾自成一套）
local tester = dofile("test/lib/tester.lua")
local result_of = tester.result_of

-- 合法调用应恰好写 4 个寄存器（LEDx_ON/OFF 共 4 字节）
local function expect_ok(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	tester.check(string.format("%-24s writes=4", label),
		result_of(ok, res) == "OK" and #writes == 4,
		string.format("result=%s writes=%d", result_of(ok, res), #writes))
end

-- 越界通道必须拒绝且一个寄存器都不写
local function expect_err(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	local msg = type(res) == "table" and tostring(res.message) or tostring(res)
	tester.check(string.format("%-24s message 含 channel", label),
		result_of(ok, res) == "ERR" and msg:find("channel", 1, true) ~= nil and #writes == 0,
		string.format("result=%s writes=%d msg=%s", result_of(ok, res), #writes, msg))
end

-- 合法边界
expect_ok("channel=0  (min)",    {fd = 3, address = "0x40", channel = 0,    angle = 45})
expect_ok("channel=15 (max)",    {fd = 3, address = "0x40", channel = 15,   angle = 45})
expect_ok("string channel='7'",  {fd = 3, address = "0x40", channel = "7",  angle = 45})

-- 越界：写出合法寄存器区（0x06~0x45）之外
expect_err("channel=16",         {fd = 3, address = "0x40", channel = 16,   angle = 45})
expect_err("channel=-1",         {fd = 3, address = "0x40", channel = -1,   angle = 45})
expect_err("channel=255",        {fd = 3, address = "0x40", channel = 255,  angle = 45})
expect_err("string channel='20'",{fd = 3, address = "0x40", channel = "20", angle = 45})

-- 26.3：非有限值同样必须落在「写任何寄存器之前」。旧的 `tonumber(channel)` 放行
-- 'nan'/'1e400'（出的是 number，`== nil` 为假），而下面 `channel < 0 or channel > 15`
-- 对 NaN 恒假也一并放行，于是 reg = LED0_ON_L + 4*NaN 是 NaN 却仍返回 result="OK"
-- ——本文件既有契约（越界即 0 次写）在驱动层被破。真机上后果被 hal/i2c.lua 的
-- byte_of 兜住（i2c_write_multi 返 -1 → 报 write failed），故本组是驱动契约修复
-- 而非安全修复；但同函数 angle 列早已用 finite_of，两处口径不一即防护漂移。
-- 本处桩替身不模拟 byte_of，故修复前的形态恰是「OK + 4 次写」，断言能看见。
expect_err("channel=NaN",          {fd = 3, address = "0x40", channel = 0 / 0,   angle = 45})
expect_err("channel=inf",          {fd = 3, address = "0x40", channel = 1e400,   angle = 45})
expect_err("string channel='nan'", {fd = 3, address = "0x40", channel = "nan",   angle = 45})
expect_err("string channel='1e400'", {fd = 3, address = "0x40", channel = "1e400", angle = 45})

tester.summary("pca9685_channel")

-- PCA9685.lua channel 越界校验离线测试（桩替身，不触碰真实 I2C）
-- 背景：channel 越界会写出 0x06+4*channel 之外的寄存器（issue #9 M2）
-- 用法: luajit test_pca9685_channel.lua（PCA9685 依赖 HAL，需 LuaJIT 的 ffi）

local writes = {}

-- 桩：模拟框架注册的 C 函数
function i2c_set_addr(fd, addr) end
function i2c_write_reg(fd, reg, val) writes[#writes + 1] = {reg = reg, val = val} end
function i2c_read_reg(fd, reg) return 0 end
function milli_sleep(ms) end

dofile("modules/PCA9685.lua")

local fails = 0

local function result_of(ok, res)
	if ok and type(res) == "table" then return tostring(res.result) end
	return tostring(res)
end

-- 合法调用应恰好写 4 个寄存器（LEDx_ON/OFF 共 4 字节）
local function expect_ok(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	local ok_result = (result_of(ok, res) == "OK") and #writes == 4
	if ok_result then
		print(string.format("[PASS] %-24s writes=4", label))
	else
		fails = fails + 1
		print(string.format("[FAIL] %-24s result=%s writes=%d", label,
			result_of(ok, res), #writes))
	end
end

-- 越界通道必须拒绝且一个寄存器都不写
local function expect_err(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	local is_err = (result_of(ok, res) == "ERR")
		and type(res) == "table"
		and tostring(res.message):find("channel") ~= nil
		and #writes == 0
	if is_err then
		print(string.format("[PASS] %-24s message=%s", label, tostring(res.message)))
	else
		fails = fails + 1
		print(string.format("[FAIL] %-24s result=%s writes=%d", label,
			result_of(ok, res), #writes))
	end
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

if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

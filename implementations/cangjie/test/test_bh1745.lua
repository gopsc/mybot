-- BH1745.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_bh1745.lua（BH1745 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_ina226.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。寄存器模型模拟软复位自清（写 bit7 -> 恢复默认态），
-- 颜色数据区预置大端字节流验证四通道拆分。

dofile("modules/BH1745.lua")

-- ==================== 寄存器模型 ====================
local regs = {}
local rd8_log = {}
local wr_log = {}
local sleeps = {}
local nak = false
local read_fail = false
local set_addr_fail = false
-- 器件身份（用例可改写模拟错挂芯片）
local part_id = 0x0B
local mfr_id = 0xE0

local function reset_device()
	regs = {
		[0x40] = part_id,		-- SYSTEM_CONTROL：复位后 bit7 自清
		[0x92] = mfr_id,
		-- 颜色数据区（大端）：R=0x1234 G=0x5678 B=0x9ABC C=0xDEF0
		[0x50] = 0x12, [0x51] = 0x34,
		[0x52] = 0x56, [0x53] = 0x78,
		[0x54] = 0x9A, [0x55] = 0xBC,
		[0x56] = 0xDE, [0x57] = 0xF0,
	}
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return not set_addr_fail end

function i2c_write_reg(fd, reg, val)
	if nak then return false end
	val = math.floor(val) % 256
	wr_log[#wr_log + 1] = { reg = reg, val = val }
	if reg == 0x40 and val >= 0x80 then reset_device() return true end	-- 软复位
	regs[reg] = val
	return true
end

function i2c_read_reg(fd, reg)
	if read_fail or nak then return -1 end
	rd8_log[#rd8_log + 1] = reg
	return regs[reg] or 0
end

function i2c_read_multi(fd, reg, n)
	if read_fail or nak then return -1 end
	local v = 0
	for i = 0, n - 1 do v = v * 256 + (regs[reg + i] or 0) end
	return v
end

function i2c_read_multi_bytes(fd, reg, n)
	if read_fail or nak then return nil end
	rd8_log[#rd8_log + 1] = reg
	local t = {}
	for i = 0, n - 1 do t[i + 1] = regs[reg + i] or 0 end
	return t
end

function milli_sleep(ms) sleeps[#sleeps + 1] = ms end

-- ==================== 断言辅助 ====================
local fails = 0
local function check(cond, label, extra)
	if cond then
		print(string.format("[PASS] %s", label))
	else
		fails = fails + 1
		print(string.format("[FAIL] %s%s", label, extra and (" (" .. tostring(extra) .. ")") or ""))
	end
end

local function result_of(ok, res)
	if ok and type(res) == "table" then return tostring(res.result) end
	return "EXC:" .. tostring(res)
end

local function expect_ok(label, fn)
	local ok, res = pcall(fn)
	check(result_of(ok, res) == "OK", label, result_of(ok, res))
	return ok and res or nil
end

local function expect_err(label, fn, msgpat)
	local ok, res = pcall(fn)
	local msg = type(res) == "table" and tostring(res.message) or tostring(res)
	check(result_of(ok, res) == "ERR" and msg:find(msgpat, 1, true) ~= nil,
		label, msg)
end

local function wr_of(reg)
	local v
	for _, w in ipairs(wr_log) do
		if w.reg == reg then v = w.val end
	end
	return v
end

local function has_sleep(ms)
	for _, s in ipairs(sleeps) do
		if s == ms then return true end
	end
	return false
end

local FD, ADDR = 3, 0x38

-- ==================== build：默认参数 ====================
reset_device()
wr_log, rd8_log, sleeps = {}, {}, {}
expect_ok("build 默认（160ms/x1）", function() return build({ fd = FD, address = "0x38" }) end)
check(wr_log[1] and wr_log[1].reg == 0x40 and wr_log[1].val == 0x80, "首笔写 = 软复位 0x80",
	wr_log[1] and string.format("0x%02X", wr_log[1].val) or "nil")
check(rd8_log[1] == 0x40 and rd8_log[2] == 0x92, "复位后双 ID 甄别 (0x40/0x92)",
	string.format("%s,%s", tostring(rd8_log[1]), tostring(rd8_log[2])))
check(wr_of(0x41) == 0x00, "MODE1 测量时间 160ms (0x00)", string.format("0x%02X", wr_of(0x41) or 0))
check(wr_of(0x42) == 0x10, "MODE2 RGBC_EN + 增益 x1 (0x10)", string.format("0x%02X", wr_of(0x42) or 0))
check(wr_of(0x44) == 0x02, "MODE3 通道有效判别 (0x02)", string.format("0x%02X", wr_of(0x44) or 0))
check(has_sleep(162), "等一个完整测量时间 (160+2ms)")

-- ==================== build：列取档 ====================
reset_device()
wr_log = {}
expect_ok("build mt='700' gain='16'", function()
	return build({ fd = FD, address = "0x38", mt = "700", gain = "16" })
end)
check(wr_of(0x41) == 0x02, "mt 700 -> 640ms (0x02)", string.format("0x%02X", wr_of(0x41) or 0))
check(wr_of(0x42) == 0x12, "gain 16 -> 0x12 (RGBC_EN|2)", string.format("0x%02X", wr_of(0x42) or 0))

reset_device()
wr_log = {}
expect_ok("build mt='100' gain='8'", function()
	return build({ fd = FD, address = "0x38", mt = "100", gain = "8" })
end)
check(wr_of(0x41) == 0x00, "mt 100 -> 缺省 160ms", string.format("0x%02X", wr_of(0x41) or 0))
check(wr_of(0x42) == 0x11, "gain 8 -> 向下降档 x2 (0x11)", string.format("0x%02X", wr_of(0x42) or 0))

-- ==================== build：错误通道 ====================
part_id = 0x0C
reset_device()
expect_err("build Part ID 不符", function() return build({ fd = FD, address = "0x38" }) end, "Not BH1745")
part_id = 0x0B

mfr_id = 0x5A
reset_device()
expect_err("build 厂商 ID 不符", function() return build({ fd = FD, address = "0x38" }) end, "Not BH1745")
mfr_id = 0xE0

nak = true
reset_device()
expect_err("build 器件无应答", function() return build({ fd = FD, address = "0x38" }) end, "Failed")
nak = false

expect_err("build 缺 fd", function() return build({ address = "0x38" }) end, "fd or address")

set_addr_fail = true
expect_err("build set_addr 失败", function() return build({ fd = FD, address = "0x38" }) end, "set_addr failed")
set_addr_fail = false

-- ==================== call：四通道大端拆分 ====================
reset_device()
wr_log, rd8_log = {}, {}
expect_ok("build（call 前置）", function() return build({ fd = FD, address = "0x38" }) end)

rd8_log = {}
local res = expect_ok("call 四通道读值", function() return call({ fd = FD, address = "0x38" }) end)
if res then
	check(res.R == 0x1234, "R = 0x1234（MSB 在前）", tostring(res.R))
	check(res.G == 0x5678, "G = 0x5678", tostring(res.G))
	check(res.B == 0x9ABC, "B = 0x9ABC", tostring(res.B))
	check(res.C == 0xDEF0, "C = 0xDEF0", tostring(res.C))
	check(rd8_log[1] == 0x50, "数据读走字节表接口，指针 0x50",
		string.format("0x%02X", rd8_log[1] or 0))
end

read_fail = true
expect_err("call 读失败", function() return call({ fd = FD, address = "0x38" }) end, "Failed to read")
read_fail = false

expect_err("call 缺 fd", function() return call({ address = "0x38" }) end, "fd or address")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

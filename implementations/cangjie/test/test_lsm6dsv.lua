-- LSM6DSV.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_lsm6dsv.lua（LSM6DSV 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_ina226.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。寄存器模型模拟 ST 复位语义：写 CTRL3 置 sw_reset(bit0)
-- 后寄存器恢复默认（CTRL3=0x04, IF_INC=1），bit0 首次轮询读到 1、随后自清。

dofile("modules/LSM6DSV.lua")

local bitc = dofile("modules/bitcompat.lua")

-- ==================== 寄存器模型 ====================
local regs = {}
local chip_id = 0x70
local reset_pending = false
local stuck_reset = false	-- 置 true 模拟 sw_reset 位卡死
local wr_log = {}
local rd_log = {}		-- read_multi（数据/配置突发读）记录
local rd8_log = {}		-- read_reg（单字节读）记录
local sleeps = {}
local nak = false
local read_fail = false
local set_addr_fail = false

local function reset_device()
	regs = {
		[0x0F] = chip_id,
		[0x12] = 0x04,		-- CTRL3 复位默认：IF_INC=1
	}
	reset_pending = false
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return not set_addr_fail end

function i2c_write_reg(fd, reg, val)
	if nak then return false end
	val = math.floor(val) % 256
	wr_log[#wr_log + 1] = { reg = reg, val = val }
	if reg == 0x12 and bitc.band(val, 0x01) ~= 0 then
		reset_device()		-- 软复位：恢复默认态，bit0 进入"复位中"
		reset_pending = true
		return true
	end
	regs[reg] = val
	return true
end

function i2c_read_reg(fd, reg)
	if read_fail or nak then return -1 end
	rd8_log[#rd8_log + 1] = reg
	if reg == 0x12 then
		local v = regs[reg] or 0
		if stuck_reset then return bitc.bor(v, 0x01) end
		if reset_pending then
			reset_pending = false
			return bitc.bor(v, 0x01)	-- 首次轮询见 bit0=1
		end
		return v
	end
	return regs[reg] or 0
end

function i2c_read_multi(fd, reg, n)
	if read_fail or nak then return -1 end
	rd_log[#rd_log + 1] = reg
	local v = 0
	for i = 0, n - 1 do v = v * 256 + (regs[reg + i] or 0) end
	return v
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

local function wr_of(reg)	-- 最后一次对寄存器的写值
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

local FD, ADDR = 3, 0x6A

-- ==================== build：默认参数 ====================
reset_device()
wr_log, rd_log, sleeps = {}, {}, {}
expect_ok("build 默认（缺省 ±8g/±500dps/120Hz）", function()
	return build({ fd = FD, address = "0x6A" })
end)
check(rd8_log[1] == 0x0F, "首笔读 = WHO_AM_I", string.format("0x%02X", rd8_log[1] or 0))
check(wr_of(0x12) == 0x44, "CTRL3 最终 = BDU|IF_INC (0x44)，sw_reset 自清",
	string.format("0x%02X", wr_of(0x12) or 0))
check(wr_of(0x10) == 0x06, "CTRL1 accel ODR=120Hz (0x06)", string.format("0x%02X", wr_of(0x10) or 0))
check(wr_of(0x11) == 0x06, "CTRL2 gyro ODR=120Hz (0x06)", string.format("0x%02X", wr_of(0x11) or 0))
check(bitc.band(wr_of(0x15) or 0, 0x0F) == 0x02, "CTRL6 fs_g=±500dps (0x2)",
	string.format("0x%02X", bitc.band(wr_of(0x15) or 0, 0x0F)))
check(bitc.band(wr_of(0x18) or 0, 0x03) == 0x02, "CTRL8 fs_xl=±8g (0x2)",
	string.format("0x%02X", bitc.band(wr_of(0x18) or 0, 0x03)))
check(has_sleep(100), "陀螺仪启动等待 100ms")
check(has_sleep(10), "复位自清轮询 10ms 步进")

-- ==================== build：列取档 ====================
reset_device()
wr_log = {}
expect_ok("build range='3' gyro='600' odr='100'", function()
	return build({ fd = FD, address = "0x6A", range = "3", gyro_range = "600", odr = "100" })
end)
check(bitc.band(wr_of(0x18) or 0, 0x03) == 0x00, "range 3 -> ±2g (0x0)",
	string.format("0x%02X", bitc.band(wr_of(0x18) or 0, 0x03)))
check(bitc.band(wr_of(0x15) or 0, 0x0F) == 0x02, "gyro 600 -> ±500dps (0x2)",
	string.format("0x%02X", bitc.band(wr_of(0x15) or 0, 0x0F)))
check(wr_of(0x10) == 0x06, "odr 100 -> 最近档 120Hz (0x06)", string.format("0x%02X", wr_of(0x10) or 0))

reset_device()
wr_log = {}
expect_ok("build gyro_range='4000' odr='10'", function()
	return build({ fd = FD, address = "0x6A", gyro_range = "4000", odr = "10" })
end)
check(bitc.band(wr_of(0x15) or 0, 0x0F) == 0x0C, "gyro 4000 -> 0xC（码不连续档）",
	string.format("0x%02X", bitc.band(wr_of(0x15) or 0, 0x0F)))
check(wr_of(0x10) == 0x02, "odr 10 -> 最近档 7.5Hz (0x02)", string.format("0x%02X", wr_of(0x10) or 0))

-- ==================== build：错误通道 ====================
chip_id = 0x6C
reset_device()
expect_err("build WHO_AM_I=0x6C（LSM6DSO 系）", function()
	return build({ fd = FD, address = "0x6A" }) end, "WHO_AM_I")
chip_id = 0x70

stuck_reset = true
reset_device()
expect_err("build 复位位卡死", function()
	return build({ fd = FD, address = "0x6A" }) end, "stuck")
stuck_reset = false

nak = true
reset_device()
expect_err("build 器件无应答", function()
	return build({ fd = FD, address = "0x6A" }) end, "Failed")
nak = false

expect_err("build 缺 fd", function() return build({ address = "0x6A" }) end, "fd or address")

set_addr_fail = true
expect_err("build set_addr 失败", function() return build({ fd = FD, address = "0x6A" }) end, "set_addr failed")
set_addr_fail = false

-- ==================== call：六轴小端拼字 ====================
reset_device()
wr_log = {}
expect_ok("build（call 前置）", function() return build({ fd = FD, address = "0x6A" }) end)

-- 小端预置：陀螺仪在 0x22（寄存器序在前）、加速度计在 0x28
-- GYRO_X=0x1000(4096) Y=0xFFFF(65535) Z=0；ACCEL_X=0xFC00(64512,-1024 原码) Y/Z=0
regs[0x22], regs[0x23] = 0x00, 0x10
regs[0x24], regs[0x25] = 0xFF, 0xFF
regs[0x26], regs[0x27] = 0x00, 0x00
regs[0x28], regs[0x29] = 0x00, 0xFC
regs[0x2A], regs[0x2B] = 0x00, 0x00
regs[0x2C], regs[0x2D] = 0x00, 0x00

rd_log = {}
local res = expect_ok("call 六轴读值", function() return call({ fd = FD, address = "0x6A" }) end)
if res then
	check(res.ACCEL_X == 64512, "ACCEL_X = 0xFC00 原始码（-1024 补码语义）", tostring(res.ACCEL_X))
	check(res.ACCEL_Y == 0 and res.ACCEL_Z == 0, "ACCEL_Y/Z = 0",
		tostring(res.ACCEL_Y) .. "/" .. tostring(res.ACCEL_Z))
	check(res.GYRO_X == 4096, "GYRO_X = 0x1000 (LSB 在前)", tostring(res.GYRO_X))
	check(res.GYRO_Y == 65535, "GYRO_Y = 0xFFFF（原始码不转负）", tostring(res.GYRO_Y))
	check(res.GYRO_Z == 0, "GYRO_Z = 0", tostring(res.GYRO_Z))
	check(rd_log[1] == 0x22 and rd_log[2] == 0x28, "读指针序 0x22(gyr) -> 0x28(acc)",
		string.format("0x%02X,0x%02X", rd_log[1] or 0, rd_log[2] or 0))
end

read_fail = true
expect_err("call 读失败", function() return call({ fd = FD, address = "0x6A" }) end, "Failed to read")
read_fail = false

expect_err("call 缺 fd", function() return call({ address = "0x6A" }) end, "fd or address")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

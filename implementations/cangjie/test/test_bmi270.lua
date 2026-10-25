-- BMI270.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_bmi270.lua（BMI270 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_ina226.lua 约定）：先 dofile 驱动（连带加载真 HAL 与
-- 真 blob 数据文件），再替换 HAL 全局。器件按寄存器模型建模，并模拟
-- blob 上传语义：0x5B/0x5C 设内部字地址（lo&0x0F + hi*16），0x5E 按字地址
-- 放置数据，0x59=0/1 控制加载；软复位（0x7E<-0xB6）恢复默认态。
-- blob 参照串由 bmi270_config.lua 独立解码，与驱动互为交叉验证。

dofile("modules/BMI270.lua")

local bitc = dofile("modules/bitcompat.lua")
local CONFIG = dofile("modules/lib/bmi270_config.lua")
local function hex2bin(h) return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end)) end
local FIFO_BIN = hex2bin(CONFIG.FIFO_HEX)
local FULL_BIN = hex2bin(CONFIG.FULL_HEX)

-- ==================== 寄存器模型 ====================
local regs = {}				-- 绝对字节地址 -> 值
local uploaded = {}			-- 上传缓冲（按字节序号 1 基）
local word_addr = 0			-- 当前内部字地址
local chip_id = 0x24
local stuck_status = nil	-- 非 nil 时 INTERNAL_STATUS 恒返回该值（超时用例）
local load_started = false
local wr_log = {}			-- 写事务记录 {reg, n, val(单字节时)}
local rd_log = {}			-- read_multi 寄存器序号记录
local sleeps = {}
local nak = false
local read_fail = false
local set_addr_fail = false

local function reset_device()
	regs = {
		[0x00] = chip_id,
		[0x40] = 0x33,		-- ACC_CONF 复位默认（odr=6Hz 假设值，考验证 [3:0] 掩码）
		[0x42] = 0x21,		-- GYR_CONF 复位默认
		[0x7D] = 0x00,
	}
	uploaded = {}
	load_started = false
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return not set_addr_fail end

function i2c_write_reg(fd, reg, val)
	if nak then return false end
	wr_log[#wr_log + 1] = { reg = reg, n = 1, val = math.floor(val) % 256 }
	if reg == 0x7E and val == 0xB6 then reset_device() return true end
	if reg == 0x59 then
		if val == 0x00 then uploaded = {} end
		if val == 0x01 then load_started = true end
	end
	regs[reg] = math.floor(val) % 256
	return true
end

function i2c_write_multi(fd, reg, ...)
	if nak then return -1 end
	local b = { ... }
	wr_log[#wr_log + 1] = { reg = reg, n = #b }
	if reg == 0x5B then			-- 内部字地址：lo(&0x0F) + hi*16
		word_addr = (b[1] % 256) + b[2] * 16
		regs[0x5B], regs[0x5C] = b[1], b[2]
		return 0
	end
	if reg == 0x5E then			-- 配置数据窗口：按字地址放置
		for k = 1, #b do uploaded[word_addr * 2 + k] = b[k] end
		return 0
	end
	for k = 1, #b do regs[reg + k - 1] = b[k] end
	return 0
end

function i2c_read_reg(fd, reg)
	if read_fail or nak then return -1 end
	if reg == 0x21 then
		if stuck_status then return stuck_status end
		return load_started and 0x01 or 0x00
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

local function wr_count(reg)
	local n = 0
	for _, w in ipairs(wr_log) do
		if w.reg == reg then n = n + 1 end
	end
	return n
end

local function has_sleep(ms)
	for _, s in ipairs(sleeps) do
		if s == ms then return true end
	end
	return false
end

local function blob_matches(bin)
	if #uploaded ~= #bin then return false, #uploaded .. "/" .. #bin end
	for k = 1, #bin do
		if uploaded[k] ~= bin:byte(k) then return false, "byte " .. k end
	end
	return true
end

local FD, ADDR = 3, 0x68

-- ==================== build：fifo blob（缺省） ====================
reset_device()
wr_log, rd_log, sleeps = {}, {}, {}
expect_ok("build 默认（fifo blob，缺省量程/ODR）", function()
	return build({ fd = FD, address = "0x68" })
end)

check(wr_log[1] and wr_log[1].reg == 0x7E and wr_log[1].val == 0xB6, "首笔写 = 软复位 0xB6",
	wr_log[1] and string.format("0x%02X", wr_log[1].reg) or "nil")
check(wr_log[2] and wr_log[2].reg == 0x7C, "次笔写 = PWR_CONF 关省电", wr_log[2] and string.format("0x%02X", wr_log[2].reg) or "nil")
check(wr_log[3] and wr_log[3].reg == 0x7D and wr_log[3].val == 0x00, "上传前全传感器下电", "0x7D")
check(wr_log[4] and wr_log[4].reg == 0x59 and wr_log[4].val == 0x00, "INIT_CTRL=0 准备下载", "0x59")

local okblob, why = blob_matches(FIFO_BIN)
check(okblob, "fifo blob 328 字节逐字节一致", why or "")
check(wr_count(0x5E) == 41 and wr_count(0x5B) == 41, "41 块 x (字地址+数据)",
	wr_count(0x5B) .. "/" .. wr_count(0x5E))

check(regs[0x40] == 0x38, "ACC_CONF 保留滤波位、ODR=100Hz(0x08) -> 0x38",
	string.format("0x%02X", regs[0x40] or 0))
check(regs[0x42] == 0x28, "GYR_CONF ODR=100Hz -> 0x28", string.format("0x%02X", regs[0x42] or 0))
check(regs[0x41] == 2, "ACC_RANGE=2 (±8g 缺省)", tostring(regs[0x41]))
check(regs[0x43] == 2, "GYR_RANGE=2 (±500dps 缺省)", tostring(regs[0x43]))
check(regs[0x7D] == 0x06, "PWR_CTRL 开 acc+gyr (0x06)", string.format("0x%02X", regs[0x7D] or 0))
check(has_sleep(100), "陀螺仪启动等待 100ms")
check(has_sleep(10), "INTERNAL_STATUS 轮询 10ms 步进")

-- ==================== build：full blob（8KB 兜底） ====================
reset_device()
wr_log = {}
expect_ok("build cfg='full'（8KB context blob）", function()
	return build({ fd = FD, address = "0x68", cfg = "full" })
end)
local okfull, whyfull = blob_matches(FULL_BIN)
check(okfull, "full blob 8192 字节逐字节一致", whyfull or "")
check(wr_count(0x5E) == 1024, "1024 块突发写", tostring(wr_count(0x5E)))

-- ==================== build：列取档 ====================
reset_device()
wr_log = {}
expect_ok("build range='3' gyro='600' odr='70'", function()
	return build({ fd = FD, address = "0x68", range = "3", gyro_range = "600", odr = "70" })
end)
check(regs[0x41] == 0, "range 3 -> ±2g (代码 0)", tostring(regs[0x41]))
check(regs[0x43] == 2, "gyro 600 -> ±500dps (代码 2)", tostring(regs[0x43]))
check(bitc.band(regs[0x40] or 0, 0x0F) == 0x07, "odr 70 -> 50Hz (0x07)",
	string.format("0x%02X", bitc.band(regs[0x40] or 0, 0x0F)))

reset_device()
wr_log = {}
expect_ok("build odr='12'（最近档 25Hz）", function()
	return build({ fd = FD, address = "0x68", odr = "12" })
end)
check(bitc.band(regs[0x40] or 0, 0x0F) == 0x06, "odr 12 -> 25Hz (0x06)",
	string.format("0x%02X", bitc.band(regs[0x40] or 0, 0x0F)))

-- ==================== build：错误通道 ====================
chip_id = 0x26
reset_device()
expect_err("build 芯片 ID 0x26 -> BMI260 变体提示", function()
	return build({ fd = FD, address = "0x68" }) end, "Chip ID")
chip_id = 0x24

stuck_status = 0x02
reset_device()
expect_err("build 内部状态卡死 -> 超时", function()
	return build({ fd = FD, address = "0x68" }) end, "config load failed")
stuck_status = nil

nak = true
reset_device()
expect_err("build 器件无应答", function()
	return build({ fd = FD, address = "0x68" }) end, "Failed")
nak = false

expect_err("build 缺 fd", function() return build({ address = "0x68" }) end, "fd or address")

set_addr_fail = true
expect_err("build set_addr 失败", function() return build({ fd = FD, address = "0x68" }) end, "set_addr failed")
set_addr_fail = false

-- ==================== call：六轴小端拼字 ====================
reset_device()
wr_log = {}
expect_ok("build（call 前置）", function() return build({ fd = FD, address = "0x68" }) end)

-- 小端预置：ACCEL_X=0x1000(4096) Y=0xFFFF(65535) Z=0x0000；GYRO_X=0xFC00(64512,即-1024 原码) Y/Z=0
regs[0x0C], regs[0x0D] = 0x00, 0x10
regs[0x0E], regs[0x0F] = 0xFF, 0xFF
regs[0x10], regs[0x11] = 0x00, 0x00
regs[0x12], regs[0x13] = 0x00, 0xFC
regs[0x14], regs[0x15] = 0x00, 0x00
regs[0x16], regs[0x17] = 0x00, 0x00

rd_log = {}
local res = expect_ok("call 六轴读值", function() return call({ fd = FD, address = "0x68" }) end)
if res then
	check(res.ACCEL_X == 4096, "ACCEL_X = 0x1000 (LSB 在前)", tostring(res.ACCEL_X))
	check(res.ACCEL_Y == 65535, "ACCEL_Y = 0xFFFF（原始码不转负）", tostring(res.ACCEL_Y))
	check(res.ACCEL_Z == 0, "ACCEL_Z = 0", tostring(res.ACCEL_Z))
	check(res.GYRO_X == 64512, "GYRO_X = 0xFC00 原始码（-1024 补码语义）", tostring(res.GYRO_X))
	check(res.GYRO_Y == 0 and res.GYRO_Z == 0, "GYRO_Y/Z = 0",
		tostring(res.GYRO_Y) .. "/" .. tostring(res.GYRO_Z))
	check(rd_log[#rd_log - 1] == 0x0C and rd_log[#rd_log] == 0x12,
		"读指针序 0x0C(acc) -> 0x12(gyr)",
		string.format("0x%02X,0x%02X", rd_log[#rd_log - 1] or 0, rd_log[#rd_log] or 0))
end

read_fail = true
expect_err("call 读失败", function() return call({ fd = FD, address = "0x68" }) end, "Failed to read")
read_fail = false

expect_err("call 缺 fd", function() return call({ address = "0x68" }) end, "fd or address")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

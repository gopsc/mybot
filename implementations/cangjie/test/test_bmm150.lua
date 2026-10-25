-- BMM150.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_bmm150.lua（BMM150 依赖 HAL 的 ffi，需 LuaJIT）
--
-- 黄金向量交叉验证：补偿期望值由 Bosch bmm150.c 原函数 C 编译生成
-- （test/test_bmm150_golden.c，gcc 编译运行），Lua 逐行移植必须精确复现
-- C 的截断除法与窄化回绕语义。数据字节按器件位域反向编码（enc13/enc13z/
-- enc14），原始码解析错误会直接打穿黄金向量。

dofile("modules/BMM150.lua")

-- ==================== 编码辅助（器件位域反向） ====================
-- 13 位：LSB = bit[7:3] 5 位 + MSB 全字节符号扩展
local function enc13(v)
	local msb = math.floor(v / 32) % 256
	local lsb = (v % 32) * 8
	return lsb, msb
end
-- Z 13 位：LSB = bit[7:1] 7 位 + MSB 全字节符号扩展
local function enc13z(v)
	local msb = math.floor(v / 128) % 256
	local lsb = (v % 128) * 2
	return lsb, msb
end
-- RHALL 14 位无符号：LSB = bit[7:2] 6 位 + MSB 全字节
local function enc14(r)
	local msb = math.floor(r / 64)
	local lsb = (r % 64) * 4
	return lsb, msb
end

-- ==================== 测试向量（与 test_bmm150_golden.c 一致） ====================
local trimA = { dig_x1 = -32, dig_y1 = -3, dig_x2 = -25, dig_y2 = 250,
	dig_z1 = 400, dig_z2 = 100, dig_z3 = -250, dig_z4 = 200,
	dig_xy1 = 137, dig_xy2 = 57, dig_xyz1 = 7920 }
local trimB = { dig_x1 = 0, dig_y1 = 0, dig_x2 = 0, dig_y2 = 0,
	dig_z1 = 100, dig_z2 = 100, dig_z3 = 0, dig_z4 = 100,
	dig_xy1 = 0, dig_xy2 = 0, dig_xyz1 = 500 }

local function trim_to_regs(t)
	return {
		[0x5D] = { t.dig_x1 % 256, t.dig_y1 % 256 },
		[0x62] = { t.dig_z4 % 256, math.floor(t.dig_z4 / 256) % 256,
			t.dig_x2 % 256, t.dig_y2 % 256 },
		[0x68] = { t.dig_z2 % 256, math.floor(t.dig_z2 / 256) % 256,
			t.dig_z1 % 256, math.floor(t.dig_z1 / 256) % 256,
			t.dig_xyz1 % 256, math.floor(t.dig_xyz1 / 256) % 128,
			t.dig_z3 % 256, math.floor(t.dig_z3 / 256) % 256,
			t.dig_xy2 % 256, t.dig_xy1 % 256 },
	}
end

local function data_to_regs(x, y, z, rhall)
	local xl, xh = enc13(x)
	local yl, yh = enc13(y)
	local zl, zh = enc13z(z)
	local rl, rh = enc14(rhall)
	return { [0x42] = xl, [0x43] = xh, [0x44] = yl, [0x45] = yh,
		[0x46] = zl, [0x47] = zh, [0x48] = rl, [0x49] = rh }
end

-- ==================== 寄存器模型 ====================
local regs = {}				-- 字节寄存器 + 字节表块（trim/data）
local blocks = {}			-- 绝对地址 -> 字节表（trim/data 块读）
local chip_id = 0x32
local wr_log = {}
local nak = false
local read_fail = false
local set_addr_fail = false

local function reset_device()
	regs = { [0x40] = chip_id }
	local t = trim_to_regs(trimA)
	for addr, bytes in pairs(t) do blocks[addr] = bytes end
	for addr, v in pairs(data_to_regs(-200, 100, -450, 512)) do regs[addr] = v end
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return not set_addr_fail end

function i2c_write_reg(fd, reg, val)
	if nak then return false end
	val = math.floor(val) % 256
	wr_log[#wr_log + 1] = { reg = reg, val = val }
	if reg == 0x4B and val >= 0x80 then
		regs[0x4B] = val - 0x80		-- 软复位：Power Control 位自清（回挂起态）
		return true
	end
	regs[reg] = val
	return true
end

function i2c_read_reg(fd, reg)
	if read_fail or nak then return -1 end
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
	local base = reg
	for span = 1, 20 do
		if blocks[base] then break end
		base = base - 1
	end
	local blk = blocks[base]
	local off = reg - base
	local t = {}
	for i = 1, n do t[i] = (blk and blk[off + i]) or regs[reg + i - 1] or 0 end
	return t
end

function milli_sleep(ms) end

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

local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-9)
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

local FD, ADDR = 3, 0x10

-- ==================== build：上电序列与默认 preset ====================
reset_device()
wr_log = {}
expect_ok("build 默认（regular preset）", function() return build({ fd = FD, address = "0x10" }) end)
check(wr_of(0x4B) == 0x01, "首笔写 = Power Control 上电", string.format("0x%02X", wr_of(0x4B) or 0))
check(wr_of(0x51) == 0x04 and wr_of(0x52) == 0x07, "regular REP_XY=4/REP_Z=7",
	string.format("%s/%s", tostring(wr_of(0x51)), tostring(wr_of(0x52))))
check(wr_of(0x4C) == 0x00, "OP_MODE = 10Hz + normal (0x00)", string.format("0x%02X", wr_of(0x4C) or 0))

-- ==================== call：黄金向量 A（典型 trim） ====================
local res = expect_ok("call 向量 A", function() return call({ fd = FD, address = "0x10" }) end)
if res then
	check(res.X ~= nil and near(res.X, -53), "A X = -53µT", tostring(res.X))
	check(res.Y ~= nil and near(res.Y, 19), "A Y = 19µT", tostring(res.Y))
	check(res.Z ~= nil and near(res.Z, -2047), "A Z = -2047µT（公式饱和）", tostring(res.Z))
end

-- ==================== call：黄金向量 B（简化 trim） ====================
-- trim 在 build 时缓存进驱动：换向量必须重新 build 重读 trim
blocks = trim_to_regs(trimB)
for addr, v in pairs(data_to_regs(100, -250, 300, 600)) do regs[addr] = v end
expect_ok("build 重读 trimB", function() return build({ fd = FD, address = "0x10" }) end)
res = expect_ok("call 向量 B", function() return call({ fd = FD, address = "0x10" }) end)
if res then
	check(res.X ~= nil and near(res.X, 31), "B X = 31µT", tostring(res.X))
	check(res.Y ~= nil and near(res.Y, -78), "B Y = -78µT", tostring(res.Y))
	check(res.Z ~= nil and near(res.Z, 2047), "B Z = 2047µT（公式饱和）", tostring(res.Z))
end

-- ==================== call：黄金向量 B2（溢出码 -> nil） ====================
for addr, v in pairs(data_to_regs(-4096, 4095, -16384, 600)) do regs[addr] = v end
res = expect_ok("call 向量 B2（溢出码）", function() return call({ fd = FD, address = "0x10" }) end)
if res then
	check(res.X == nil, "B2 X：原始码 -4096（XY 溢出翻转）-> nil", tostring(res.X))
	check(res.Y ~= nil and near(res.Y, 1279), "B2 Y = 1279µT（4095 非溢出）", tostring(res.Y))
	check(res.Z == nil, "B2 Z：原始码 -16384（Z 溢出）-> nil", tostring(res.Z))
end

-- ==================== call：黄金向量 C（RHALL=0 回退路径） ====================
blocks = trim_to_regs(trimA)
for addr, v in pairs(data_to_regs(-200, 100, -450, 0)) do regs[addr] = v end
expect_ok("build 重读 trimA", function() return build({ fd = FD, address = "0x10" }) end)
res = expect_ok("call 向量 C（RHALL=0）", function() return call({ fd = FD, address = "0x10" }) end)
if res then
	check(res.X ~= nil and near(res.X, -68), "C X = -68µT（dig_xyz1 回退路径）", tostring(res.X))
	check(res.Y ~= nil and near(res.Y, 28), "C Y = 28µT", tostring(res.Y))
	check(res.Z == nil, "C Z：RHALL=0 无回退 -> nil", tostring(res.Z))
end

-- ==================== build：preset 与错误通道 ====================
wr_log = {}
expect_ok("build preset='highaccuracy", function()
	return build({ fd = FD, address = "0x10", preset = "highaccuracy" })
end)
check(wr_of(0x51) == 0x17 and wr_of(0x52) == 0x29, "highaccuracy REP_XY=23/REP_Z=41",
	string.format("%s/%s", tostring(wr_of(0x51)), tostring(wr_of(0x52))))
check(wr_of(0x4C) == 0x28, "OP_MODE = 20Hz (0x05<<3)", string.format("0x%02X", wr_of(0x4C) or 0))

expect_err("build preset 非法", function()
	return build({ fd = FD, address = "0x10", preset = "turbo" }) end, "Invalid preset")

chip_id = 0x31
reset_device()
expect_err("build CHIP_ID 不符", function() return build({ fd = FD, address = "0x10" }) end, "CHIP_ID")
chip_id = 0x32

reset_device()
expect_err("build 缺 fd", function() return build({ address = "0x10" }) end, "fd or address")

set_addr_fail = true
expect_err("build set_addr 失败", function() return build({ fd = FD, address = "0x10" }) end, "set_addr failed")
set_addr_fail = false

expect_err("call 缺 fd", function() return call({ address = "0x10" }) end, "fd or address")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

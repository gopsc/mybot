-- EMC2101.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_emc2101.lua（EMC2101 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_ina226.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。寄存器模型覆盖驱动依赖的关键语义：
--   - 单字节读全部走 i2c_read_reg（rd8_log 记录读序，验证 MSB 先读锁存）
--   - LUT 槽位 0x50..0x5F 按写_multi 落盘，逐字节断言
--   - 外部温度故障特征码（0x3F8/0x3FF）与 11 位补码负温
--   - 双 Part ID + SMSC 厂商 ID 甄别

dofile("modules/EMC2101.lua")

-- ==================== 寄存器模型 ====================
local regs = {}
local rd8_log = {}
local wr_log = {}
local nak = false
local read_fail = false
local set_addr_fail = false
-- 器件复位默认：PWM_F=0x0F（100% 对应 lsb=30）
local function reset_device()
	regs = {
		[0x00] = 25,		-- 内部温度 25°C
		[0x02] = 0x00,		-- 状态
		[0x01] = 0x19,		-- 外部温度 MSB（25 + 0xA0 -> 25.625°C）
		[0x10] = 0xA0,		-- 外部温度 LSB
		[0x46] = 0xD6,		-- TACH LSB
		[0x47] = 0x06,		-- TACH MSB（计数 0x06D6=1750 -> 3085.7 RPM）
		[0x4A] = 0x00,		-- FAN_CONFIG（bit5=0 LUT 使能复位态）
		[0x4D] = 0x0F,		-- PWM_F 复位默认
		[0xFD] = 0x16,		-- PART_ID
		[0xFE] = 0x5D,		-- MFG_ID
	}
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return not set_addr_fail end

function i2c_write_reg(fd, reg, val)
	if nak then return false end
	val = math.floor(val) % 256
	wr_log[#wr_log + 1] = { reg = reg, val = val }
	regs[reg] = val
	return true
end

function i2c_write_multi(fd, reg, ...)
	if nak then return -1 end
	local b = { ... }
	wr_log[#wr_log + 1] = { reg = reg, n = #b }
	for k = 1, #b do regs[reg + k - 1] = b[k] end
	return 0
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
		if w.reg == reg and w.val then v = w.val end
	end
	return v
end

local function rd8_index(reg)	-- reg 最近一次单字节读在 rd8_log 中的位置
	local pos
	for i, r in ipairs(rd8_log) do
		if r == reg then pos = i end
	end
	return pos
end

local FD, ADDR = 3, 0x4C

-- ==================== build：手动模式 ====================
reset_device()
wr_log = {}
expect_ok("build 手动 duty='50'", function()
	return build({ fd = FD, address = "0x4C", duty = "50" })
end)
check(wr_of(0x4A) == 0x20, "FAN_CONFIG bit5=1（LUT 禁用）",
	string.format("0x%02X", wr_of(0x4A) or 0))
check(wr_of(0x4C) == 15, "FAN_SETTING = 50% x lsb30 = 15",
	tostring(wr_of(0x4C)))

reset_device()
wr_log = {}
expect_ok("build 手动缺 duty -> 0%", function()
	return build({ fd = FD, address = "0x4C" })
end)
check(wr_of(0x4C) == 0, "缺省停转 (lsb=0)", tostring(wr_of(0x4C)))

-- ==================== build：LUT 自主模式 ====================
reset_device()
wr_log = {}
expect_ok("build lut 4 项", function()
	return build({ fd = FD, address = "0x4C", lut = "70:100,40:0,60:60,50:30" })
end)
local want = { 40, 0, 50, 9, 60, 18, 70, 30, 0x7F, 0x3F, 0x7F, 0x3F, 0x7F, 0x3F, 0x7F, 0x3F }
local got = {}
for i = 0, 15 do got[i + 1] = regs[0x50 + i] end
local same = true
for i = 1, 16 do
	if got[i] ~= want[i] then same = false; break end
end
check(same, "LUT 槽位按温度升序 + 空槽兜底 [0x7F,0x3F]",
	table.concat(got, ","))
check(bitc and false or (regs[0x4A] == 0x00), "写完 LUT 重新启用（bit5=0)",
	string.format("0x%02X", regs[0x4A] or 0))

-- lut 非法输入
for _, c in ipairs({
	{ lut = "40:0,50:30,60:60,70:100,80:100,90:100,100:100,110:100,120:100", pat = "more than 8" },
	{ lut = "40-0", pat = "bad pair" },
	{ lut = "200:50", pat = "127" },
	{ lut = "50:120", pat = "100%" },
}) do
	reset_device()
	expect_err("build lut 非法（" .. c.pat .. "）", function()
		return build({ fd = FD, address = "0x4C", lut = c.lut }) end, c.pat)
end

-- ==================== build：身份甄别 ====================
reset_device()
regs[0xFD] = 0x15
expect_err("build PART_ID 不符", function()
	return build({ fd = FD, address = "0x4C" }) end, "Not EMC2101")

reset_device()
regs[0xFE] = 0x5C
expect_err("build MFG_ID 不符", function()
	return build({ fd = FD, address = "0x4C" }) end, "Not EMC2101")

reset_device()
regs[0xFD] = 0x28
expect_ok("build EMC2101-R（PART_ID=0x28）", function()
	return build({ fd = FD, address = "0x4C", duty = "20" })
end)

expect_err("build 缺 fd", function() return build({ address = "0x4C" }) end, "fd or address")

set_addr_fail = true
expect_err("build set_addr 失败", function() return build({ fd = FD, address = "0x4C" }) end, "set_addr failed")
set_addr_fail = false

-- ==================== call：采样 ====================
reset_device()
wr_log = {}
expect_ok("build（call 前置）", function() return build({ fd = FD, address = "0x4C", duty = "30" }) end)

rd8_log = {}
local res = expect_ok("call 采样", function() return call({ fd = FD, address = "0x4C" }) end)
if res then
	check(res.TEMP_IN == 25, "TEMP_IN = 25（整数）", tostring(res.TEMP_IN))
	check(res.TEMP_EXT == 25.625, "TEMP_EXT = 25.625（11 位含 1/8 分数）", tostring(res.TEMP_EXT))
	check(res.RPM > 3085.7 and res.RPM < 3085.8, "RPM = 5400000/1750 = 3085.7", tostring(res.RPM))
	check(res.STATUS == 0x00, "STATUS 透传", tostring(res.STATUS))
	local ip, lp = rd8_index(0x01), rd8_index(0x10)
	local tp, tl = rd8_index(0x47), rd8_index(0x46)
	check(ip and lp and ip < lp, "外部温度先读 MSB(0x01) 锁存",
		string.format("%s,%s", tostring(ip), tostring(lp)))
	check(tp and tl and tp < tl, "TACH 先读 MSB(0x47) 锁存",
		string.format("%s,%s", tostring(tp), tostring(tl)))
end

-- 外部温度故障特征码 -> TEMP_EXT=nil
reset_device()
regs[0x01], regs[0x10] = 0x7F, 0x00		-- raw11 = 0x3F8 开路
res = expect_ok("call 二极管开路", function() return call({ fd = FD, address = "0x4C" }) end)
if res then check(res.TEMP_EXT == nil, "开路 -> TEMP_EXT=nil", tostring(res.TEMP_EXT)) end

reset_device()
regs[0x01], regs[0x10] = 0x7F, 0xE0		-- raw11 = 0x3FF 短路
res = expect_ok("call 二极管短路", function() return call({ fd = FD, address = "0x4C" }) end)
if res then check(res.TEMP_EXT == nil, "短路 -> TEMP_EXT=nil", tostring(res.TEMP_EXT)) end

-- 负温（11 位补码）
reset_device()
regs[0x01], regs[0x10] = 0x80, 0x00		-- raw11 = 0x400 = -128.0°C
res = expect_ok("call 外部负温", function() return call({ fd = FD, address = "0x4C" }) end)
if res then check(res.TEMP_EXT == -128.0, "raw11 0x400 -> -128.0", tostring(res.TEMP_EXT)) end

-- 计数 0 -> RPM=0（防除零）
reset_device()
regs[0x46], regs[0x47] = 0x00, 0x00
res = expect_ok("call 风扇停转", function() return call({ fd = FD, address = "0x4C" }) end)
if res then check(res.RPM == 0, "TACH 计数 0 -> RPM=0", tostring(res.RPM)) end

-- ==================== call：切手动 duty ====================
reset_device()
expect_ok("build LUT（供 duty 切换用例）", function()
	return build({ fd = FD, address = "0x4C", lut = "50:50" })
end)
res = expect_ok("call duty='75' 切手动", function()
	return call({ fd = FD, address = "0x4C", duty = "75" })
end)
if res then
	check(res.duty == 75, "返回 duty=75", tostring(res.duty))
	check(res.lsb == 23, "lsb = floor(22.5+0.5) = 23", tostring(res.lsb))
	check(regs[0x4C] == 23, "FAN_SETTING 落寄存器", tostring(regs[0x4C]))
	check(regs[0x4A] == 0x20, "切手动自动禁 LUT", string.format("0x%02X", regs[0x4A]))
end

read_fail = true
expect_err("call 读失败", function() return call({ fd = FD, address = "0x4C" }) end, "Failed to read")
read_fail = false

expect_err("call 缺 fd", function() return call({ address = "0x4C" }) end, "fd or address")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

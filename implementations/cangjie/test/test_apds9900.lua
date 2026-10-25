-- APDS9900.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_apds9900.lua（APDS9900 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_sgp30.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。器件按寄存器文件建模，并强制校验 APDS-9900 的命令字节协议：
--   - 字节访问地址字节必须为 0x80|reg（命令位 7，位 6/5 为 0）
--   - 自动增量访问必须为 0xA0|reg（位 5 置位），按寄存器对连续读
--   - 数据寄存器小端流（低字节在前），独立摆放，检验驱动端字节序换算
--   - lux 用独立排列的公式重算（内核 apds990x 算法、0.1-lux 输出折算真 lux）

dofile("modules/APDS9900.lua")

-- ==================== 器件模型 ====================
local regs = {}				-- reg -> byte
local wr_log = {}			-- 写记录 {reg=, val=}
local id_reg = 0x29
local wr_nak = false
local rd_nak = false
local ch0_v, ch1_v, prox_v = 0, 0, 0

local function set_sensor(ch0, ch1, prox)
	ch0_v, ch1_v, prox_v = ch0, ch1, prox
	-- 小端寄存器对：低字节在前（0x14/0x15、0x16/0x17、0x18/0x19）
	regs[0x14] = ch0 % 256
	regs[0x15] = math.floor(ch0 / 256) % 256
	regs[0x16] = ch1 % 256
	regs[0x17] = math.floor(ch1 / 256) % 256
	regs[0x18] = prox % 256
	regs[0x19] = math.floor(prox / 256) % 256
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return true end

local function cmd_check(cmd, inc)
	assert(math.floor(cmd / 128) % 2 == 1, "command bit 7 not set")
	assert(math.floor(cmd / 64) % 2 == 0, "bit 6 must be 0 (APDS9900 has no bit6 reg)")
	assert(math.floor(cmd / 32) % 2 == (inc and 1 or 0), "auto-increment bit 5 mismatch")
	return cmd % 32
end

function i2c_write_reg(fd, cmd, val)
	if wr_nak then return false end
	local reg = cmd_check(cmd, false)
	wr_log[#wr_log + 1] = { reg = reg, val = math.floor(val) % 256 }
	regs[reg] = math.floor(val) % 256
	return true
end

function i2c_read_reg(fd, cmd)
	if rd_nak then return -1 end
	local reg = cmd_check(cmd, false)
	if reg == 0x12 then return id_reg end
	return regs[reg] or 0
end

function i2c_read_multi(fd, cmd, n)
	if rd_nak then return -1 end
	local reg = cmd_check(cmd, true)
	assert(n == 2, "only word reads expected, got " .. tostring(n))
	local b = { regs[reg] or 0, regs[reg + 1] or 0 }
	local v = 0
	for i = 0, n - 1 do v = v * 256 + b[i + 1] end
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

local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-6)
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

local FD, ADDR = 3, 0x39
local function reset()
	regs = {}
	wr_log = {}
	id_reg = 0x29
	wr_nak = false
	rd_nak = false
	ch0_v, ch1_v, prox_v = 0, 0, 0
end

local function reg(reg) return regs[reg] end
local function wr_at(i) return wr_log[i] end

-- 独立 lux 重算（内核 apds990x 算法；手排算式与驱动实现交叉验证）
local function lux_ref(ch0, ch1, again, cycles, df, ga_scaled)
	local iac1 = 1.00 * ch0 - 2.23 * ch1
	local iac2 = 0.70 * ch0 - 1.42 * ch1
	local iac = math.max(math.max(iac1, iac2), 0)
	local atime_ms = cycles * 87 / 32
	return iac * df * ga_scaled / 4096 / (again * atime_ms)
end

-- ==================== build：配置与寄存器值 ====================
reset()
expect_ok("build 默认（50ms/×1/100mA/×1/8 脉冲）", function() return build({ fd = FD, address = "0x39" }) end)
check(wr_at(1) and wr_at(1).reg == 0x00 and wr_at(1).val == 0x00, "首写 ENABLE=0 断电",
	wr_at(1) and string.format("0x%02X=0x%02X", wr_at(1).reg, wr_at(1).val))
check(reg(0x01) == 238, "ATIME=238（50ms -> 18 周期）", tostring(reg(0x01)))
check(reg(0x02) == 0xFF and reg(0x03) == 0xFF, "PTIME/WTIME=0xFF")
check(reg(0x0D) == 0x00 and reg(0x0C) == 0x00, "CONFIG/PERS=0")
check(reg(0x0E) == 8, "PPCOUNT=8", tostring(reg(0x0E)))
check(reg(0x0F) == 0x20, "CONTROL=0x20（100mA|PDIODE=IR|×1|×1）", string.format("0x%02X", reg(0x0F)))
check(reg(0x00) == 0x07, "ENABLE=0x07（PON|AEN|PEN）", string.format("0x%02X", reg(0x00)))

reset()
expect_ok("build 全自定义（696ms/×120/12.5mA/×8/64 脉冲）", function()
	return build({ fd = FD, address = "0x39", atime = "696", again = "120", pdrive = "12.5",
		pgain = "8", ppcount = "64", df = "60", ga = "0.5" })
end)
check(reg(0x01) == 0, "atime 696ms -> 256 周期（ATIME=0）", tostring(reg(0x01)))
check(reg(0x0F) == 0xEF, "CONTROL=0xEF（12.5mA|IR|×8|×120）", string.format("0x%02X", reg(0x0F)))
check(reg(0x0E) == 64, "PPCOUNT=64", tostring(reg(0x0E)))

reset()
expect_ok("build 最短积分（2.73ms -> 1 周期）", function() return build({ fd = FD, address = "0x39", atime = "2.73" }) end)
check(reg(0x01) == 255, "ATIME=255（1 周期）", tostring(reg(0x01)))

-- ==================== build：错误路径 ====================
reset()
expect_err("build 非法 atime（过短）", function() return build({ fd = FD, address = "0x39", atime = "2" }) end, "atime")
expect_err("build 非法 atime（过长）", function() return build({ fd = FD, address = "0x39", atime = "1000" }) end, "atime")
expect_err("build 非法 again", function() return build({ fd = FD, address = "0x39", again = "5" }) end, "again")
expect_err("build 非法 pdrive", function() return build({ fd = FD, address = "0x39", pdrive = "30" }) end, "pdrive")
expect_err("build 非法 pgain", function() return build({ fd = FD, address = "0x39", pgain = "3" }) end, "pgain")
expect_err("build 非法 ppcount", function() return build({ fd = FD, address = "0x39", ppcount = "0" }) end, "ppcount")
expect_err("build 非法 ga", function() return build({ fd = FD, address = "0x39", ga = "1.5" }) end, "df/ga")
expect_err("build 缺 fd", function() return build({ address = "0x39" }) end, "fd or address")
expect_err("build 非表参数", function() return build(true) end, "Invalid Arguments Type")

reset()
id_reg = 0x55
expect_err("build ID 错误", function() return build({ fd = FD, address = "0x39" }) end, "unexpected ID")
id_reg = 0x00
expect_ok("build ID=0x00 接受（部分批次）", function() return build({ fd = FD, address = "0x39" }) end)
id_reg = 0x29

reset()
wr_nak = true
expect_err("build 写无应答", function() return build({ fd = FD, address = "0x39" }) end, "not responding")
wr_nak = false
rd_nak = true
expect_err("build 读无应答", function() return build({ fd = FD, address = "0x39" }) end, "not responding")
rd_nak = false

-- ==================== call：数据与字节序 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x39" }) end)
set_sensor(10000, 2500, 517)
local res = expect_ok("call 读三通道", function() return call({ fd = FD, address = "0x39" }) end)
if res then
	check(res.CH0 == 10000, "CH0=10000（小端流换序正确）", tostring(res.CH0))
	check(res.CH1 == 2500, "CH1=2500", tostring(res.CH1))
	check(res.PROX == 517, "PROX=517", tostring(res.PROX))
	local want = lux_ref(10000, 2500, 1, 18, 52, 1966)
	check(near(res.LUX, want), "LUX 与独立重算一致（≈2256.8）",
		string.format("%s vs %s", tostring(res.LUX), tostring(want)))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x39" }) end)
set_sensor(1000, 1000, 0)
res = expect_ok("call 红外主导钳 0", function() return call({ fd = FD, address = "0x39" }) end)
if res then
	check(res.LUX == 0, "IR 占比高时 LUX=0", tostring(res.LUX))
end

reset()
expect_ok("call 前 build（×8 增益）", function() return build({ fd = FD, address = "0x39", again = "8" }) end)
set_sensor(10000, 2500, 300)
res = expect_ok("call 增益参与 lux 换算", function() return call({ fd = FD, address = "0x39" }) end)
if res then
	local want = lux_ref(10000, 2500, 8, 18, 52, 1966)
	check(near(res.LUX, want), "LUX 按 again=8 归一", string.format("%s vs %s", tostring(res.LUX), tostring(want)))
end

reset()
expect_ok("call 前 build（ga=0.5 自定义）", function() return build({ fd = FD, address = "0x39", ga = "0.5" }) end)
set_sensor(20000, 3000, 0)
res = expect_ok("call 自定义玻璃系数生效", function() return call({ fd = FD, address = "0x39" }) end)
if res then
	local want = lux_ref(20000, 3000, 1, 18, 52, math.floor(0.5 * 4096 + 0.5))
	check(near(res.LUX, want), "LUX 按 ga=0.5 换算", string.format("%s vs %s", tostring(res.LUX), tostring(want)))
end

-- ==================== call：错误路径 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x39" }) end)
rd_nak = true
expect_err("call 读无应答", function() return call({ fd = FD, address = "0x39" }) end, "not responding")
rd_nak = false
expect_err("call 非表参数", function() return call(9) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = FD }) end, "fd or address")

-- ==================== destroy ====================
reset()
expect_ok("destroy 前 build", function() return build({ fd = FD, address = "0x39" }) end)
reset()
expect_ok("destroy 断电", function() return destroy({ fd = FD, address = "0x39" }) end)
check(#wr_log == 1 and wr_at(1).reg == 0x00 and wr_at(1).val == 0x00, "destroy 写 ENABLE=0",
	wr_at(1) and string.format("0x%02X=0x%02X", wr_at(1).reg, wr_at(1).val))

reset()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
check(#wr_log == 0, "缺 fd 不发任何写", tostring(#wr_log))

reset()
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

-- MAX17048.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_max17048.lua（MAX17048 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_sgp30.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。器件按 16 位寄存器文件建模（POR 默认值依数据手册）：
--   - VCELL/SOC/CRATE 注入典型值，期望输出用独立算式重算交叉验证
--   - VERSION 可切 0x0012（17048）/0x0013（17049 刻度 x2）/0x001E（17043 应拒）
--   - MODE/VALRT/CONFIG/STATUS 的写全部落模型，供位级行为断言

dofile("modules/MAX17048.lua")

-- ==================== 器件模型 ====================
local regs = {}					-- reg -> 16 位值
local wr_log = {}				-- {reg=, hi=, lo=}
local ver_reg = 0x0012
local wr_nak = false
local rd_nak = false

local function inject()
	regs = {
		[0x02] = 0x6666,		-- VCELL：26214 x 78.125uV = 2.048V（17048）
		[0x04] = 0x5A80,		-- SOC：90 + 128/256 = 90.5%
		[0x06] = 0x0000,		-- MODE
		[0x08] = ver_reg,		-- VERSION
		[0x0C] = 0x971C,		-- CONFIG（POR：RCOMP=0x97，ATHD=28 -> 4%）
		[0x14] = 0x00FF,		-- VALRT（POR）
		[0x16] = 0xFE20,		-- CRATE：s16(-480) x 0.208 = -99.84 %/hr
		[0x1A] = 0x0100,		-- STATUS：RI 置位（上电常见）
	}
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return true end

function i2c_write_multi(fd, reg, hi, lo)
	if wr_nak then return -1 end
	hi, lo = math.floor(hi) % 256, math.floor(lo) % 256
	wr_log[#wr_log + 1] = { reg = reg, hi = hi, lo = lo }
	regs[reg] = hi * 256 + lo
	return 0
end

function i2c_read_multi(fd, reg, n)
	if rd_nak then return -1 end
	assert(n == 2, "only 16-bit reads expected")
	local v = regs[reg] or 0
	return math.floor(v / 256) % 256 * 256 + v % 256		-- 经大端字节路径
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

local FD, ADDR = 3, 0x36
local function reset()
	wr_log = {}
	ver_reg = 0x0012
	wr_nak = false
	rd_nak = false
	inject()
end

local function last_wr() return wr_log[#wr_log] end
local function wr_of(reg)
	for i = #wr_log, 1, -1 do
		if wr_log[i].reg == reg then return wr_log[i] end
	end
	return nil
end

-- ==================== build：版本自检 ====================
reset()
expect_ok("build 默认（17048）", function() return build({ fd = FD, address = "0x36" }) end)
check(#wr_log == 0, "默认 build 不写任何寄存器（纯只读）", tostring(#wr_log))

reset()
ver_reg = 0x0013
inject()
expect_ok("build 17049 变体", function() return build({ fd = FD, address = "0x36" }) end)

reset()
ver_reg = 0x001E
inject()
expect_err("build 17043 应拒", function() return build({ fd = FD, address = "0x36" }) end, "MAX17043")
ver_reg = 0x00AA
inject()
expect_err("build 版本未知应拒", function() return build({ fd = FD, address = "0x36" }) end, "unexpected version")
ver_reg = 0x0012

reset()
rd_nak = true
expect_err("build 读版本无应答", function() return build({ fd = FD, address = "0x36" }) end, "not responding")
rd_nak = false
reset()
wr_nak = true
expect_err("build quickstart 写无应答", function()
	return build({ fd = FD, address = "0x36", quickstart = "1" })
end, "not responding")
wr_nak = false
expect_err("build 缺 fd", function() return build({ address = "0x36" }) end, "fd or address")
expect_err("build 非表参数", function() return build(9) end, "Invalid Arguments Type")

-- ==================== build：可选配置写 ====================
reset()
expect_ok("build quickstart", function() return build({ fd = FD, address = "0x36", quickstart = "1" }) end)
check(wr_of(0x06) ~= nil and wr_of(0x06).hi == 0x40 and wr_of(0x06).lo == 0x00,
	"MODE 写 0x4000（QuickStart）", wr_of(0x06) and string.format("0x%02X%02X", wr_of(0x06).hi, wr_of(0x06).lo))

reset()
expect_ok("build valrt 阈值", function()
	return build({ fd = FD, address = "0x36", valrt_max = "4.2", valrt_min = "3.3" })
end)
check(wr_of(0x14) ~= nil and wr_of(0x14).hi == 210 and wr_of(0x14).lo == 165,
	"VALRT=210/165（4.2V/3.3V，20mV 步进）",
	wr_of(0x14) and string.format("0x%02X%02X", wr_of(0x14).hi, wr_of(0x14).lo))

reset()
expect_ok("build athd 阈值", function() return build({ fd = FD, address = "0x36", athd = "10" }) end)
check(wr_of(0x0C) ~= nil and wr_of(0x0C).hi == 0x97 and wr_of(0x0C).lo == 0x16,
	"CONFIG=0x9716（RCOMP 保留，ATHD=22=32-10）",
	wr_of(0x0C) and string.format("0x%02X%02X", wr_of(0x0C).hi, wr_of(0x0C).lo))

reset()
expect_err("build valrt_max 越界", function()
	return build({ fd = FD, address = "0x36", valrt_max = "6" })
end, "valrt_max")
expect_err("build athd 越界", function()
	return build({ fd = FD, address = "0x36", athd = "0" })
end, "athd")

-- ==================== call：读数换算（独立算式交叉验证） ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x36" }) end)
local res = expect_ok("call 四通道", function() return call({ fd = FD, address = "0x36" }) end)
if res then
	check(near(res.VCELL, 26214 * 78.125e-6), "VCELL=2.048V", tostring(res.VCELL))
	check(near(res.SOC, 90 + 128 / 256), "SOC=90.5%", tostring(res.SOC))
	check(near(res.CRATE, -480 * 0.208), "CRATE=-99.84%/hr", tostring(res.CRATE))
	check(res.STATUS == 1, "STATUS=1（RI 复位指示）", tostring(res.STATUS))
	check(#wr_log == 0, "call 默认不清除告警", tostring(#wr_log))
end

-- 17049 刻度 x2
reset()
ver_reg = 0x0013
inject()
expect_ok("call 前 build（17049）", function() return build({ fd = FD, address = "0x36" }) end)
res = expect_ok("call 17049 电压刻度", function() return call({ fd = FD, address = "0x36" }) end)
if res then
	check(near(res.VCELL, 26214 * 156.25e-6), "VCELL=4.096V（双节刻度）", tostring(res.VCELL))
end

-- ==================== call：clear 清除告警 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x36" }) end)
regs[0x1A] = 0x7F40			-- 告警位 bit0~5 全置 + EnVR（bit14）
res = expect_ok("call clear=1", function() return call({ fd = FD, address = "0x36", clear = "1" }) end)
if res then
	check(res.STATUS == 63, "STATUS=0x3F（读时可见）", tostring(res.STATUS))
	check(wr_of(0x1A) ~= nil and wr_of(0x1A).hi == 0x40 and wr_of(0x1A).lo == 0x40,
		"告警位清除且 EnVR 保留（0x7F40 -> 0x4040）",
		wr_of(0x1A) and string.format("0x%02X%02X", wr_of(0x1A).hi, wr_of(0x1A).lo))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x36" }) end)
regs[0x1A] = 0x4000			-- 无告警
expect_ok("call clear=1 无告警不写", function() return call({ fd = FD, address = "0x36", clear = "1" }) end)
check(#wr_log == 0, "无告警位不触发写", tostring(#wr_log))

reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x36" }) end)
rd_nak = true
expect_err("call 读无应答", function() return call({ fd = FD, address = "0x36" }) end, "not responding")
rd_nak = false
expect_err("call 非表参数", function() return call(1) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = FD }) end, "fd or address")

-- ==================== destroy ====================
reset()
expect_ok("destroy 无关断寄存器", function() return destroy({ fd = FD, address = "0x36" }) end)
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

-- AS3935.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_as3935.lua（AS3935 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile 驱动（连带加载真 HAL），再把驱动用到的 HAL 全局替换为桩。
-- 驱动在 build/call 时才解析全局名，后注桩生效——先注桩会被 HAL 的真函数覆盖
-- （test_pca9685_channel/float.lua 的旧桩模式即踩此坑，两个文件已同步修正）。
-- 桩内模拟器件语义：字节级寄存器模型；0x3C=0x96 软复位（恢复默认配置）、
-- 0x3D=0x96 RCO 校准（状态寄存器按用例可控的通过/失败）。
-- 事件注入：测试直接写模型 INT/距离/能量寄存器后调 call。

dofile("modules/AS3935.lua")
local bitc = dofile("modules/bitcompat.lua")

-- ==================== 桩与器件模型 ====================
local regs = {}					-- 寄存器地址 -> 字节值
local got_reset = false			-- 收到 0x3C=0x96
local got_calib = false			-- 收到 0x3D=0x96
local fail_write = false		-- 置 true 模拟总线写失败
local fail_read = false			-- 置 true 模拟总线读失败
local fail_regs = {}			-- 指定寄存器读失败（fail_read 优先级更高）
local set_addr_ok = true
local set_addr_log = {}
local sleep_total = 0
-- 用例可控的器件状态
local default_afe = 0x24		-- 复位后 AFE_GAIN（0x24 = 出厂室内增益）
local calib_srco_ok = true		-- RCO 校准后 SRCO 状态位（true = 通过/bit6=0）
local calib_trco_ok = true

-- 复位默认配置（datasheet 缺省：室内、NF=2、WDTH=2、SREJ=2、MIN_LIG=1、距离超范围）
local function reset_device()
	regs = {
		[0x00] = default_afe,
		[0x01] = 0x22,
		[0x02] = 0x02,
		[0x03] = 0x00,
		[0x04] = 0x00, [0x05] = 0x00, [0x06] = 0x00,
		[0x07] = 0x3F,
		[0x08] = 0x00,
	}
end

local function reset_model()
	reset_device()
	got_reset, got_calib = false, false
	fail_write, fail_read, set_addr_ok = false, false, true
	fail_regs = {}
	set_addr_log = {}
	sleep_total = 0
	default_afe = 0x24
	calib_srco_ok, calib_trco_ok = true, true
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr)
	set_addr_log[#set_addr_log + 1] = addr
	return set_addr_ok
end

function i2c_write_reg(fd, reg, val)
	if fail_write then return false end
	if reg == 0x3C and val == 0x96 then
		got_reset = true
		reset_device()			-- 软复位：恢复默认配置
		return true
	end
	if reg == 0x3D and val == 0x96 then
		got_calib = true
		-- 校准状态：bit6 = 1 即未通过（用例可控）
		regs[0x3A] = calib_trco_ok and 0x00 or 0x40
		regs[0x3B] = calib_srco_ok and 0x00 or 0x40
		return true
	end
	regs[reg] = val
	return true
end

function i2c_read_reg(fd, reg)
	if fail_read or fail_regs[reg] then return -1 end
	return regs[reg] or 0
end

function milli_sleep(ms) sleep_total = sleep_total + ms end

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

local function reg_is(reg, val, label)
	local extra = string.format("0x%02X", regs[reg] or 0)
	check(regs[reg] == val, label .. string.format(" (0x%02X=0x%02X)", reg, val), extra)
end

-- ==================== build：默认参数与配置写入 ====================
reset_model()
expect_ok("build 默认参数（全 '-'）", function() return build({ fd = 3, address = "0x03" }) end)
check(got_reset, "build 发送软复位 (0x3C=0x96)")
check(got_calib, "build 发送 RCO 校准 (0x3D=0x96)")
reg_is(0x00, 0x24, "缺省室内增益 AFE_GAIN")
reg_is(0x01, 0x22, "缺省 NF=2 WDTH=2")
reg_is(0x02, 0x02, "缺省 MIN_LIG=1 SREJ=2")
reg_is(0x03, 0x00, "缺省不屏蔽干扰源")
reg_is(0x08, 0x00, "缺省 TUN_CAP=0 且校准显示位已清")

-- 字符串 fd/address（框架元数据侧全为字符串）
reset_model()
expect_ok("build 字符串 fd='3' address='0x03'", function() return build({ fd = "3", address = "0x03" }) end)
check(#set_addr_log > 0 and set_addr_log[#set_addr_log] == 3,
	"set_addr 收到 0x03=3", tostring(set_addr_log[#set_addr_log]))

-- ==================== build：配置列 ====================
reset_model()
expect_ok("build indoor='0'（室外）", function() return build({ fd = 3, address = "0x03", indoor = "0" }) end)
reg_is(0x00, 0x1C, "室外增益 AFE_GAIN=0x0E<<1")

reset_model()
expect_ok("build nf='5' wdth='10' srej='15' min_lig='16' tun_cap='120'",
	function() return build({ fd = 3, address = "0x03", nf = "5", wdth = "10",
		srej = "15", min_lig = "16", tun_cap = "120" }) end)
reg_is(0x01, 0x5A, "NF=5 WDTH=10")
reg_is(0x02, 0x3F, "MIN_LIG=16(码3) SREJ=15")
reg_is(0x08, 0x0F, "TUN_CAP=120pF(码15)")

reset_model()
expect_ok("build min_lig='7'（向下取档到 5）", function() return build({ fd = 3, address = "0x03", min_lig = "7" }) end)
reg_is(0x02, 0x12, "MIN_LIG=5(码1) SREJ=2")

reset_model()
expect_ok("build mask_dist='1' tun_cap='100'", function() return build({ fd = 3, address = "0x03", mask_dist = "1", tun_cap = "100" }) end)
reg_is(0x03, 0x20, "MASK_DIST 置位")
reg_is(0x08, 0x0C, "TUN_CAP=100pF 截断到 8pF 步进(码12)")

reset_model()
expect_ok("build nf='9'（钳到 7）", function() return build({ fd = 3, address = "0x03", nf = "9" }) end)
reg_is(0x01, 0x72, "NF=9 钳到 7 WDTH=2")

-- ==================== build：错误通道 ====================
reset_model()
fail_write = true
expect_err("build 复位写失败", function() return build({ fd = 3, address = "0x03" }) end, "Failed to reset")

reset_model()
fail_read = true
expect_err("build 读 AFE_GAIN 失败", function() return build({ fd = 3, address = "0x03" }) end, "Failed to read AS3935 AFE_GAIN")

reset_model()
default_afe = 0x99
expect_err("build 复位默认值不符（在位甄别）", function() return build({ fd = 3, address = "0x03" }) end, "expect INDOOR default")

reset_model()
calib_trco_ok = false
expect_err("build TRCO 校准未通过", function() return build({ fd = 3, address = "0x03" }) end, "calibration failed")

reset_model()
calib_srco_ok = false
expect_err("build SRCO 校准未通过", function() return build({ fd = 3, address = "0x03" }) end, "calibration failed")

reset_model()
fail_regs = { [0x3A] = true, [0x3B] = true }
expect_err("build 读校准状态失败", function() return build({ fd = 3, address = "0x03" }) end, "calibration status")

reset_model()
set_addr_ok = false
expect_err("build set_addr 失败", function() return build({ fd = 3, address = "0x03" }) end, "set_addr failed")
set_addr_ok = true

expect_err("build 缺 fd", function() return build({ address = "0x03" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = 3 }) end, "fd or address")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")

-- ==================== call：事件读取 ====================
reset_model()
expect_ok("build 正常", function() return build({ fd = 3, address = "0x03" }) end)

local res = expect_ok("call 无事件", function() return call({ fd = 3, address = "0x03" }) end)
if res then
	check(res.EVENT == "none" and res.CODE == 0, "无事件 EVENT=none CODE=0", tostring(res.EVENT))
	check(res.DIST_KM == -1 and res.ENERGY == 0, "无事件时距离=-1 能量=0")
end

regs[0x03] = 0x01
res = expect_ok("call 噪声事件", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.EVENT == "noise" and res.CODE == 1, "EVENT=noise CODE=1", tostring(res.EVENT)) end

regs[0x03] = 0x04
res = expect_ok("call 干扰源事件", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.EVENT == "disturber" and res.CODE == 2, "EVENT=disturber CODE=2", tostring(res.EVENT)) end

-- 闪电事件：距离 + 21 位能量拼接 (0x12<<16 | 0x34<<8 | 0x56)
regs[0x03] = 0x08
regs[0x07] = 10
regs[0x04] = 0x56; regs[0x05] = 0x34; regs[0x06] = 0x12
res = expect_ok("call 闪电事件", function() return call({ fd = 3, address = "0x03" }) end)
if res then
	check(res.EVENT == "lightning" and res.CODE == 3, "EVENT=lightning CODE=3", tostring(res.EVENT))
	check(res.DIST_KM == 10, "DIST_KM=10", tostring(res.DIST_KM))
	check(res.ENERGY == 0x123456, "ENERGY=0x123456（21 位拼接）", tostring(res.ENERGY))
end

-- 距离特殊值
regs[0x07] = 0x3F
res = expect_ok("call 闪电(超范围)", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.DIST_KM == -1, "S_DIST=0x3F -> DIST_KM=-1", tostring(res.DIST_KM)) end

regs[0x07] = 0
res = expect_ok("call 闪电(距离未知)", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.DIST_KM == -1, "S_DIST=0 -> DIST_KM=-1", tostring(res.DIST_KM)) end

regs[0x07] = 1
res = expect_ok("call 闪电(雷暴头顶)", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.DIST_KM == 1, "S_DIST=1 -> DIST_KM=1（头顶）", tostring(res.DIST_KM)) end

-- INT 位域外杂散位：按位判定仍命中闪电
regs[0x03] = 0x0A
res = expect_ok("call INT 带杂散位", function() return call({ fd = 3, address = "0x03" }) end)
if res then check(res.CODE == 3, "0x0A 按位判定 -> lightning", tostring(res.CODE)) end

-- 错误通道
regs[0x03] = 0x00
fail_read = true
expect_err("call 读中断寄存器失败", function() return call({ fd = 3, address = "0x03" }) end, "interrupt register")
fail_read = false

regs[0x03] = 0x08
fail_regs = { [0x07] = true }
expect_err("call 读距离失败", function() return call({ fd = 3, address = "0x03" }) end, "distance")
fail_regs = { [0x05] = true }
expect_err("call 读能量失败", function() return call({ fd = 3, address = "0x03" }) end, "energy")
fail_regs = {}

expect_err("call 缺 fd", function() return call({ address = "0x03" }) end, "fd or address")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments")

-- ==================== destroy ====================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

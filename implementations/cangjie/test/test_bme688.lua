-- BME688.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_bme688.lua（BME688 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式（同 test_sgp30.lua 约定）：先 dofile 驱动（连带加载真 HAL），
-- 再替换 HAL 全局。器件按寄存器文件 + 转换状态机建模：
--   - 42 字节校准按确定性模式注入三块（0x8A/0xE1/0x00），测试内独立转录
--     Bosch 官方解析映射与补偿公式，与驱动交叉验证（专抓转录笔误）
--   - 写 CTRL_MEAS 模式位=1 触发转换：busy 至 10ms + gas_wait 寄存器逆向
--     解码时长（独立于驱动编码）；完成后按官方场格式（17 字节）填充数据
--   - 变体寄存器 0xF0 可切 0x00（BME680 低量程气体路）/0x01（BME688 高量程）

dofile("modules/BME688.lua")

-- ==================== 校准字节（确定性模式注入） ====================
local function calib_byte(i)
	return ((i * 37 + 11) % 200) + 28
end

-- 测试内独立转录的解析映射（Bosch bme68x.c get_calib_data）
local function expect_calib()
	local function s8(v) v = v % 256; if v >= 128 then v = v - 256 end return v end
	local function s16(v) v = v % 65536; if v >= 32768 then v = v - 65536 end return v end
	local b = {}
	for i = 1, 42 do b[i] = calib_byte(i) end
	local C = {}
	C.t1 = b[33] * 256 + b[32]
	C.t2 = s16(b[2] * 256 + b[1])
	C.t3 = s8(b[3])
	C.p1 = b[6] * 256 + b[5]
	C.p2 = s16(b[8] * 256 + b[7])
	C.p3 = s8(b[9])
	C.p4 = s16(b[12] * 256 + b[11])
	C.p5 = s16(b[14] * 256 + b[13])
	C.p6 = s8(b[16])
	C.p7 = s8(b[15])
	C.p8 = b[20] * 256 + b[19]
	C.p9 = s16(b[22] * 256 + b[21])
	C.p10 = b[23]
	C.h1 = b[26] * 16 + (b[25] % 16)
	C.h2 = b[24] * 16 + math.floor(b[25] / 16)
	C.h3 = s8(b[27]); C.h4 = s8(b[28]); C.h5 = s8(b[29])
	C.h6 = b[30]; C.h7 = s8(b[31])
	C.gh1 = s8(b[36]); C.gh2 = s16(b[35] * 256 + b[34]); C.gh3 = s8(b[37])
	C.res_heat_val = s8(b[38])
	C.res_heat_range = math.floor((b[40] % 64) / 16)
	C.range_sw_err = math.floor(s8(b[42]) / 16)
	return C
end

-- 测试内独立转录的补偿公式（Bosch 浮点版）
local function ref_temperature(adc, C)
	local var1 = (adc / 16384.0 - C.t1 / 1024.0) * C.t2
	local var2 = ((adc / 131072.0 - C.t1 / 8192.0) * (adc / 131072.0 - C.t1 / 8192.0)) * (C.t3 * 16.0)
	C.t_fine = var1 + var2
	return C.t_fine / 5120.0
end

local function ref_pressure(adc, C)
	local var1 = C.t_fine / 2.0 - 64000.0
	local var2 = var1 * var1 * (C.p6 / 131072.0) + var1 * C.p5 * 2.0
	var2 = var2 / 4.0 + C.p4 * 65536.0
	var1 = (C.p3 * var1 * var1 / 16384.0 + C.p2 * var1) / 524288.0
	var1 = (1.0 + var1 / 32768.0) * C.p1
	local pres = 1048576.0 - adc
	if var1 ~= 0 then
		pres = (pres - var2 / 4096.0) * 6250.0 / var1
		local w1 = C.p9 * pres * pres / 2147483648.0
		local w2 = pres * (C.p8 / 32768.0)
		local w3 = (pres / 256.0) * (pres / 256.0) * (pres / 256.0) * (C.p10 / 131072.0)
		pres = pres + (w1 + w2 + w3 + C.p7 * 128.0) / 16.0
	end
	return pres
end

local function ref_humidity(adc, C)
	local temp_comp = C.t_fine / 5120.0
	local var1 = adc - (C.h1 * 16.0 + C.h3 / 2.0 * temp_comp)
	local var2 = var1 * (C.h2 / 262144.0 *
		(1.0 + C.h4 / 16384.0 * temp_comp + C.h5 / 1048576.0 * temp_comp * temp_comp))
	local var3 = C.h6 / 16384.0
	local var4 = C.h7 / 2097152.0
	local hum = var2 + (var3 + var4 * temp_comp) * var2 * var2
	return math.max(0.0, math.min(100.0, hum))
end

local function ref_res_heat(temp, C, amb)
	local t = math.min(temp, 400)
	local var1 = C.gh1 / 16.0 + 49.0
	local var2 = C.gh2 / 32768.0 * 0.0005 + 0.00235
	local var3 = C.gh3 / 1024.0
	local var5 = var1 * (1.0 + var2 * t) + var3 * amb
	local r = 3.4 * (var5 * (4 / (4 + C.res_heat_range)) * (1 / (1 + C.res_heat_val * 0.002)) - 25)
	return math.max(0, math.min(255, math.floor(r)))
end

local K1 = { 0, 0, 0, 0, 0, -1, 0, -0.8, 0, 0, -0.2, -0.5, 0, -1, 0, 0 }
local K2 = { 0, 0, 0, 0, 0.1, 0.7, 0, -0.8, -0.1, 0, 0, 0, 0, 0, 0, 0 }
local function ref_gas_low(adc, range, sw_err)
	local var1 = 1340.0 + 5.0 * sw_err
	local var2 = var1 * (1.0 + K1[range + 1] / 100.0)
	local var3 = 1.0 + K2[range + 1] / 100.0
	return 1.0 / (var3 * 0.000000125 * (2 ^ range) * (((adc - 512.0) / var2) + 1.0))
end

local function ref_gas_high(adc, range)
	local var1 = math.floor(262144 / 2 ^ range)
	local var2 = (adc - 512) * 3 + 4096
	return 1000000.0 * var1 / var2
end

-- ==================== 器件模型 ====================
local regs = {}
local id_reg, variant_reg = 0x61, 0x01
local adc_temp, adc_pres, adc_hum = 524288, 300000, 30000
local gas_adc, gas_range = 600, 8
local heat_stab_ok = true
local busy_until = nil
local stuck = false
local meas_index = 0
local now_ms = 0
local wr_nak = false
local rd_nak = false

local function inject_regs()
	regs[0xD0] = id_reg
	regs[0xF0] = variant_reg
	for i = 1, 23 do regs[0x8A + i - 1] = calib_byte(i) end
	for i = 1, 14 do regs[0xE1 + i - 1] = calib_byte(23 + i) end
	for i = 1, 5 do regs[0x00 + i - 1] = calib_byte(37 + i) end
end

-- gas_wait 寄存器逆向解码（独立于驱动的编码）
local function decode_wait(v)
	return (v % 64) * (4 ^ math.floor(v / 64))
end

local function fill_field()
	local b2 = math.floor(adc_pres / 4096) % 256
	local b3 = math.floor(adc_pres / 16) % 256
	local b4 = (adc_pres % 16) * 16
	local b6 = math.floor(adc_temp / 4096) % 256
	local b7 = math.floor(adc_temp / 16) % 256
	local b8 = (adc_temp % 16) * 16
	meas_index = (meas_index + 1) % 256
	local flags = 0x20 + (heat_stab_ok and 0x10 or 0)
	local lm, ll = math.floor(gas_adc / 4) % 256, (gas_adc % 4) * 64 + (gas_range % 16) + flags
	regs[0x1D] = 0x80
	regs[0x1E] = meas_index
	regs[0x1F] = b2; regs[0x20] = b3; regs[0x21] = b4
	regs[0x22] = b6; regs[0x23] = b7; regs[0x24] = b8
	regs[0x25] = math.floor(adc_hum / 256); regs[0x26] = adc_hum % 256
	regs[0x2A] = lm; regs[0x2B] = ll		-- BME680 低量程路
	regs[0x2C] = lm; regs[0x2D] = ll		-- BME688 高量程路
end

local function advance()
	if busy_until ~= nil and not stuck and now_ms >= busy_until then
		busy_until = nil
		fill_field()
	end
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr) return true end

function i2c_write_reg(fd, reg, val)
	if wr_nak then return false end
	val = math.floor(val) % 256
	regs[reg] = val
	if reg == 0x74 and val % 4 == 1 then			-- 强制模式触发
		regs[0x1D] = 0x00
		busy_until = now_ms + 10 + decode_wait(regs[0x64] or 0)
	end
	return true
end

function i2c_read_reg(fd, reg)
	if rd_nak then return -1 end
	advance()
	return regs[reg] or 0
end

function i2c_read_multi(fd, reg, n)
	if rd_nak then return -1 end
	assert(n >= 1 and n <= 8, "chunk size " .. tostring(n))
	advance()
	local v = 0
	for i = 0, n - 1 do v = v * 256 + (regs[reg + i] or 0) end
	return v
end

function milli_sleep(ms) now_ms = now_ms + ms end

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

local function near(a, b, rel)
	return math.abs(a - b) <= (rel or 1e-6) * math.max(1.0, math.abs(a), math.abs(b))
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

local FD, ADDR = 3, 0x76
local function reset()
	regs = {}
	id_reg, variant_reg = 0x61, 0x01
	adc_temp, adc_pres, adc_hum = 524288, 300000, 30000
	gas_adc, gas_range = 600, 8
	heat_stab_ok = true
	busy_until = nil
	stuck = false
	meas_index = 0
	now_ms = 0
	wr_nak = false
	rd_nak = false
	inject_regs()
end

local function reg(a) return regs[a] end

-- ==================== build：配置与寄存器 ====================
reset()
local EC = expect_calib()
expect_ok("build 默认（BME688/320C/150ms）", function() return build({ fd = FD, address = "0x76" }) end)
check(reg(0x72) == 0x01, "CTRL_HUM=0x01（湿度 x1）", string.format("0x%02X", reg(0x72) or 0))
check(reg(0x74) == 0x24, "CTRL_MEAS=0x24（T/P x1，睡眠）", string.format("0x%02X", reg(0x74) or 0))
check(reg(0x75) == 0x08, "CONFIG=0x08（IIR x3）", string.format("0x%02X", reg(0x75) or 0))
check(reg(0x5A) == ref_res_heat(320, EC, 25), "RES_HEAT0 与独立反算一致",
	string.format("%s vs %s", tostring(reg(0x5A)), tostring(ref_res_heat(320, EC, 25))))
check(reg(0x64) == 101, "GAS_WAIT0=101（150ms 编码）", tostring(reg(0x64)))
check(reg(0x70) == 0x00, "CTRL_GAS0=0x00（加热器使能）", tostring(reg(0x70)))
check(reg(0x71) == 0x20, "CTRL_GAS1=0x20（高量程气体 + 设定点 0）", tostring(reg(0x71)))

reset()
variant_reg = 0x00
inject_regs()
expect_ok("build BME680 变体（0x00）", function() return build({ fd = FD, address = "0x76" }) end)
check(reg(0x71) == 0x10, "CTRL_GAS1=0x10（低量程气体）", tostring(reg(0x71)))

-- ==================== build：错误路径 ====================
reset()
id_reg = 0x58
inject_regs()
expect_err("build chip id 错误", function() return build({ fd = FD, address = "0x76" }) end, "unexpected chip id")
id_reg = 0x61
variant_reg = 0x02
inject_regs()
expect_err("build 变体错误", function() return build({ fd = FD, address = "0x76" }) end, "unexpected variant")
variant_reg = 0x01
inject_regs()
expect_err("build 非法 heatr_temp", function() return build({ fd = FD, address = "0x76", heatr_temp = "50" }) end, "heatr_temp")
expect_err("build 非法 heatr_dur", function() return build({ fd = FD, address = "0x76", heatr_dur = "5000" }) end, "heatr_dur")
expect_err("build 缺 fd", function() return build({ address = "0x76" }) end, "fd or address")
expect_err("build 非表参数", function() return build(0) end, "Invalid Arguments Type")

reset()
wr_nak = true
expect_err("build 写无应答", function() return build({ fd = FD, address = "0x76" }) end, "not responding")
wr_nak = false
rd_nak = true
expect_err("build 读无应答", function() return build({ fd = FD, address = "0x76" }) end, "not responding")
rd_nak = false

-- ==================== call：T/P/H/GAS 与独立公式交叉验证 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x76" }) end)
adc_temp, adc_pres, adc_hum = 505728, 298243, 25000
local res = expect_ok("call 四通道补偿", function() return call({ fd = FD, address = "0x76" }) end)
if res then
	local refT = ref_temperature(adc_temp, EC)
	local refP = ref_pressure(adc_pres, EC)
	local refH = ref_humidity(adc_hum, EC)
	local refG = ref_gas_high(gas_adc, gas_range)
	check(near(res.T, refT), "T 与独立公式一致", string.format("%s vs %s", tostring(res.T), tostring(refT)))
	check(near(res.P, refP), "P 与独立公式一致", string.format("%s vs %s", tostring(res.P), tostring(refP)))
	check(near(res.H, refH), "H 与独立公式一致", string.format("%s vs %s", tostring(res.H), tostring(refH)))
	check(near(res.GAS, refG), "GAS（高量程路）与独立公式一致",
		string.format("%s vs %s", tostring(res.GAS), tostring(refG)))
	check(res.GAS_OK == 1, "GAS_OK=1（valid+heat_stab）", tostring(res.GAS_OK))
	check(now_ms >= 158, "等待至转换完成（148ms 加热 + 10ms）", tostring(now_ms))
end

-- ==================== call：BME680 低量程路径 ====================
reset()
variant_reg = 0x00
inject_regs()
expect_ok("call 前 build（BME680 变体）", function() return build({ fd = FD, address = "0x76" }) end)
adc_temp, adc_pres, adc_hum = 515000, 301000, 28000
gas_adc, gas_range = 800, 5
res = expect_ok("call 低量程气体路", function() return call({ fd = FD, address = "0x76" }) end)
if res then
	local refG = ref_gas_low(gas_adc, gas_range, EC.range_sw_err)
	check(near(res.GAS, refG), "GAS（低量程路 + range_sw_err）与独立公式一致",
		string.format("%s vs %s", tostring(res.GAS), tostring(refG)))
end

-- ==================== call：heat_stab=0 与超时 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x76" }) end)
heat_stab_ok = false
res = expect_ok("call 加热未稳定只置标志", function() return call({ fd = FD, address = "0x76" }) end)
if res then
	check(res.GAS_OK == 0, "GAS_OK=0", tostring(res.GAS_OK))
	check(res.GAS ~= nil and res.T ~= nil, "数值仍返回（交消费者决策）")
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x76" }) end)
stuck = true
expect_err("call 转换超时", function() return call({ fd = FD, address = "0x76" }) end, "not ready")
check(now_ms >= 300, "超时前轮询 300ms", tostring(now_ms))
stuck = false

reset()
expect_ok("call 前 build", function() return build({ fd = FD, address = "0x76" }) end)
rd_nak = true
expect_err("call 读无应答", function() return call({ fd = FD, address = "0x76" }) end, "not responding")
rd_nak = false
expect_err("call 非表参数", function() return call(3) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = FD }) end, "fd or address")

-- ==================== destroy ====================
reset()
expect_ok("destroy 前 build", function() return build({ fd = FD, address = "0x76" }) end)
expect_ok("destroy 置睡眠", function() return destroy({ fd = FD, address = "0x76" }) end)
check(reg(0x74) % 4 == 0, "CTRL_MEAS 模式位清零（睡眠）", tostring(reg(0x74)))

reset()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)

reset()
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

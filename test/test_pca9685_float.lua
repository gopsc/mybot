-- PCA9685.lua 浮点角度兼容性离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_pca9685_float.lua（PCA9685 依赖 HAL 的 ffi，需 LuaJIT）
-- 校验点：合法角度恰写 4 个寄存器且 OFF 值与换算一致；越界角度限幅到 0~180

local writes = {}

-- 桩：模拟框架注册的 C 函数
function i2c_set_addr(fd, addr) end
function i2c_write_reg(fd, reg, val) writes[#writes + 1] = {reg = reg, val = val} end
function i2c_read_reg(fd, reg) return 0 end
function milli_sleep(ms) end

dofile("modules/PCA9685.lua")

local fails = 0

-- 驱动同款换算：offval = floor((0.5 + 2.0*angle/180) * 4096 / 20)，入参先限幅
local function expect_offval(angle)
	local a = angle
	if a < 0 then a = 0 end
	if a > 180 then a = 180 end
	return math.floor((0.5 + 2.0 * a / 180.0) * 4096.0 / 20.0)
end

local function try(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	if not ok then
		fails = fails + 1
		print(string.format("[FAIL] %-28s error: %s", label, tostring(res)))
		return
	end
	-- 取出 OFF 寄存器低两字节（reg+2, reg+3）合成 offval
	local offval = nil
	for _, w in ipairs(writes) do
		if w.reg == 0x06 + 4 * 6 + 2 then offval = w.val end
		if w.reg == 0x06 + 4 * 6 + 3 and offval then offval = offval + w.val * 256 end
	end
	local want = expect_offval(tonumber(data.angle))
	if offval == want and #writes == 4 then
		print(string.format("[PASS] %-28s writes=%d offval=%s",
			label, #writes, tostring(offval)))
	else
		fails = fails + 1
		print(string.format("[FAIL] %-28s writes=%d offval=%s (want %s)",
			label, #writes, tostring(offval), tostring(want)))
	end
end

-- 1) 数字角度（@Action 参数经 parseMt 为 JsonFloat，整数/浮点同路）
try("integer angle=45",        {fd = 3, address = "0x40", channel = 6, angle = 45})

-- 2) 字符串角度（结构脚本元数据侧全为字符串，保持兼容）
try("string angle='45'",       {fd = 3, address = "0x40", channel = "6", angle = "45"})
try("string angle='44.7'",     {fd = 3, address = "0x40", channel = "6", angle = "44.7"})

-- 3) 浮点数字角度（!32 类型保真后 Servo 返回的实际形态）
try("float angle=44.7",        {fd = 3, address = "0x40", channel = 6, angle = 44.7})

-- 4) 越界角度（驱动边界应限幅到 0~180，offval 落在 102~512）
try("string angle='250'",      {fd = 3, address = "0x40", channel = "6", angle = "250"})
try("string angle='-30'",      {fd = 3, address = "0x40", channel = "6", angle = "-30"})

if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

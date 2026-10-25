-- MT6826S.lua 离线测试（桩替身，不触碰真实 SPI）
-- 用法: luajit test_mt6826s.lua（MT6826S 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile 驱动（连带加载真 HAL），再替换 HAL.sys.ioctl_p——
-- 驱动的全双工帧经该间接层走，桩在此解析 spi_ioc_transfer 的 tx 缓冲区
-- （ffi.cast 取回命令/地址），按寄存器模型回填 rx 缓冲区：
--   - 固定值契约：0x004 bit0 恒 0、0x005 高 5 位恒 0，可注入违例
--   - CRC 由独立实现的 CRC-8（poly 0x07）计算，与驱动互为交叉验证；
--     可注入「首组坏/重试即好」与「持续坏」两种场景
--   - 帧日志记录命令/地址序，校验读帧协议

dofile("modules/MT6826S.lua")

local bitc = dofile("modules/bitcompat.lua")
local HALT = dofile("modules/lib/HAL.lua")		-- 守卫返回同一张表
local ffi = require("ffi")

-- ==================== 器件模型 ====================
local angle15 = 0				-- 15 位原始角（测试注入）
local status_bits = 0			-- STATUS[2:0]
local crc_bad = false			-- 持续 CRC 坏
local bad_fixed = false			-- 0x004 bit0 违例（协议一致性测试）
local fail_ioctl = false		-- 传输失败
local corrupt_groups = 0		-- 从当前帧起连续坏几组（4 帧一组）
local frames = {}				-- 帧日志 {cmd=, addr=}
local read_count = 0

-- 独立 CRC-8 实现（poly 0x07，MSB 先行，初值 0x00；与驱动交叉验证）
-- LuaJIT 无 5.3+ 位运算符，按 bitcompat 惯例走 bit 库
local function model_crc(bytes)
	local crc = 0
	for _, b in ipairs(bytes) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.bxor(bitc.band(bitc.lshift(crc, 1), 0xFF), 0x07)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
HALT.sys.ioctl_p = function(fd, req, msg)
	if fail_ioctl then return -1 end
	assert(req == HALT.SPI_IOC_MESSAGE_1, "unexpected ioctl")
	local m = msg[0]
	local n = tonumber(m.len)
	assert(n == 3, "read frame should be 3 bytes, got " .. tostring(n))
	local txb = ffi.cast("const uint8_t *", ffi.cast("void *", tonumber(m.tx_buf)))
	local rxb = ffi.cast("uint8_t *", ffi.cast("void *", tonumber(m.rx_buf)))
	local cmd = math.floor(txb[0] / 16) % 16
	local addr = (txb[0] % 16) * 256 + txb[1]
	frames[#frames + 1] = { cmd = cmd, addr = addr }
	local rx = { 0, 0, 0 }
	if cmd == 0x3 then
		read_count = read_count + 1
		local group = math.floor((read_count - 1) / 4)
		local corrupt = crc_bad or group < corrupt_groups
		local h = math.floor(angle15 / 128) % 256
		local l = (angle15 % 128) * 2
		local st = status_bits % 8
		if bad_fixed and addr == 0x004 then l = l + 1 end
		if addr == 0x003 then rx[3] = h
		elseif addr == 0x004 then rx[3] = l
		elseif addr == 0x005 then rx[3] = st
		elseif addr == 0x006 then
			rx[3] = model_crc({ h, l, st })
			if corrupt then rx[3] = bitc.bxor(rx[3], 0xA5) end
		end
		if addr == 0x006 and read_count % 4 == 0 and corrupt_groups > 0 then
			corrupt_groups = corrupt_groups - 1
		end
	end
	for i = 0, n - 1 do rxb[i] = rx[i + 1] end
	return n
end

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

local FD = 3
local function reset()
	angle15 = 0
	status_bits = 0
	crc_bad = false
	bad_fixed = false
	fail_ioctl = false
	corrupt_groups = 0
	frames = {}
	read_count = 0
end

-- ==================== build：在位自检与帧协议 ====================
reset()
local res = expect_ok("build 默认（自检读四寄存器）", function() return build({ fd = FD, delay = "0" }) end)
check(#frames == 4, "自检共 4 读帧", tostring(#frames))
local addrs = {}
for i, f in ipairs(frames) do addrs[i] = f.addr end
check(table.concat(addrs, ",") == "3,4,5,6", "读帧地址序 0x003~0x006", table.concat(addrs, ","))
check(frames[1].cmd == 0x3, "命令位 0011（读）", tostring(frames[1].cmd))

reset()
expect_ok("build zero=90", function() return build({ fd = FD, delay = "0", zero = "90" }) end)

reset()
fail_ioctl = true
expect_err("build 传输失败", function() return build({ fd = FD, delay = "0" }) end, "not responding")
fail_ioctl = false

reset()
bad_fixed = true
expect_err("build 固定位违例", function() return build({ fd = FD, delay = "0" }) end, "not responding")
bad_fixed = false

reset()
expect_err("build 缺 fd", function() return build({ delay = "0" }) end, "Invalid Argument: fd")
expect_err("build 非表参数", function() return build("x") end, "Invalid Arguments Type")

-- ==================== call：角度换算 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
angle15 = 8192
local res = expect_ok("call 90°", function() return call({ fd = FD }) end)
if res then
	check(res.RAW == 8192, "RAW=8192", tostring(res.RAW))
	check(near(res.ANGLE, 90.0), "ANGLE=90", tostring(res.ANGLE))
	check(res.STATUS == 0, "STATUS=0", tostring(res.STATUS))
	check(res.CRC_OK == 1, "CRC_OK=1", tostring(res.CRC_OK))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
angle15 = 0
res = expect_ok("call 0°", function() return call({ fd = FD }) end)
if res then
	check(res.RAW == 0 and near(res.ANGLE, 0.0), "ANGLE=0", tostring(res.ANGLE))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
angle15 = 32767
res = expect_ok("call 满码 359.99°", function() return call({ fd = FD }) end)
if res then
	check(res.RAW == 32767, "RAW=32767", tostring(res.RAW))
	check(near(res.ANGLE, 32767 * 360 / 32768), "ANGLE≈359.989", tostring(res.ANGLE))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
angle15 = 24576
status_bits = 5
res = expect_ok("call 带告警位", function() return call({ fd = FD }) end)
if res then
	check(res.STATUS == 5, "STATUS=5（超速+欠压）", tostring(res.STATUS))
	check(near(res.ANGLE, 270.0), "ANGLE=270", tostring(res.ANGLE))
end

-- ==================== call：CRC 校验与重试 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
angle15 = 8192
corrupt_groups = math.floor(read_count / 4) + 1		-- 下一组坏，重试组好
local before = read_count
res = expect_ok("call CRC 首组坏重试即好", function() return call({ fd = FD }) end)
if res then
	check(res.CRC_OK == 1, "CRC_OK=1（重试成功）", tostring(res.CRC_OK))
	check(read_count - before == 8, "重试多读一组（8 帧）", tostring(read_count - before))
	check(near(res.ANGLE, 90.0), "重试后角度正确", tostring(res.ANGLE))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
crc_bad = true
res = expect_ok("call CRC 持续坏置标志", function() return call({ fd = FD }) end)
if res then
	check(res.CRC_OK == 0, "CRC_OK=0", tostring(res.CRC_OK))
	check(res.RAW == 0, "数值照常返回", tostring(res.RAW))
end
crc_bad = false

-- ==================== zero 零位偏移 ====================
reset()
expect_ok("zero 前 build（zero=90）", function() return build({ fd = FD, delay = "0", zero = "90" }) end)
angle15 = 8192
res = expect_ok("zero 扣偏移", function() return call({ fd = FD }) end)
if res then
	check(near(res.ANGLE, 0.0), "90°-90°=0", tostring(res.ANGLE))
	check(res.RAW == 8192, "RAW 不受 zero 影响", tostring(res.RAW))
end

reset()
expect_ok("zero 前 build（zero=-90 归一 270）", function() return build({ fd = FD, delay = "0", zero = "-90" }) end)
angle15 = 0
res = expect_ok("zero 负值归一", function() return call({ fd = FD }) end)
if res then
	check(near(res.ANGLE, 90.0), "负 zero 归一后 (0-270)mod360=90", tostring(res.ANGLE))
end

reset()
expect_ok("zero 前 build（zero=90）", function() return build({ fd = FD, delay = "0", zero = "90" }) end)
angle15 = 0
res = expect_ok("zero 回绕", function() return call({ fd = FD }) end)
if res then
	check(near(res.ANGLE, 270.0), "0°-90° 回绕 270", tostring(res.ANGLE))
end

-- ==================== call：错误路径 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD, delay = "0" }) end)
fail_ioctl = true
expect_err("call 传输失败（含重试）", function() return call({ fd = FD }) end, "not responding")
fail_ioctl = false
expect_err("call 非表参数", function() return call(5) end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({}) end, "Invalid Argument: fd")

-- ==================== destroy ====================
reset()
expect_ok("destroy 只读器件无事可做", function() return destroy({ fd = FD }) end)
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

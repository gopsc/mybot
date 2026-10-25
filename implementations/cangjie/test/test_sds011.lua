-- SDS011.lua 离线测试（桩替身，不触碰真实串口）
-- 用法: luajit test_sds011.lua（SDS011 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile 驱动（连带加载真 HAL），再替换 HAL 全局 uart_*。
-- 器件按帧协议建模：
--   - uart_write 解析 19 字节请求帧（AA B4 + 校验和 + AB），按命令生成应答
--   - 应答 10 字节（AA C5 + 数据 + 独立实现的校验和 + AB），可注入
--     坏校验和/无应答/前导噪声三种异常
--   - PM 值换算用独立算式交叉验证；帧日志断言命令序

dofile("modules/SDS011.lua")

-- ==================== 器件模型 ====================
local pending = {}				-- 待读应答字节队列
local pm25_raw, pm10_raw = 423, 1000
local no_reply = false
local corrupt_reply = false
local noise_prefix = false
local wr_frames = {}			-- 请求帧记录
local flush_count = 0
local wr_nak = false

local function reset()
	pending = {}
	pm25_raw, pm10_raw = 423, 1000
	no_reply = false
	corrupt_reply = false
	noise_prefix = false
	wr_frames = {}
	flush_count = 0
	wr_nak = false
end

-- 独立应答校验和：字节 3..8 累加 mod 256
local function resp_cs(f)
	local sum = 0
	for i = 3, 8 do sum = sum + f[i] end
	return sum % 256
end

-- 命令 ACK 帧：AA C5 | 命令回显（cmd + 数据）| ID | CS | AB（10 字节）
local function queue_ack(cmd, d0)
	local f = { 0xAA, 0xC5, cmd, d0, 0, 0, 0xFF, 0xFF }
	f[9] = resp_cs(f)
	f[10] = 0xAB
	if corrupt_reply then f[9] = (f[9] + 1) % 256 end
	if noise_prefix then
		noise_prefix = false
		pending[#pending + 1] = 0x00
		pending[#pending + 1] = 0x55
	end
	for _, b in ipairs(f) do pending[#pending + 1] = b end
end

-- 查询应答帧：AA C5 | PM25L PM25H PM10L PM10H | ID | CS | AB（无命令回显字节）
local function queue_query()
	local f = { 0xAA, 0xC5, pm25_raw % 256, math.floor(pm25_raw / 256) % 256,
		pm10_raw % 256, math.floor(pm10_raw / 256) % 256, 0xFF, 0xFF }
	f[9] = resp_cs(f)
	f[10] = 0xAB
	if corrupt_reply then f[9] = (f[9] + 1) % 256 end
	if noise_prefix then
		noise_prefix = false
		pending[#pending + 1] = 0x00
		pending[#pending + 1] = 0x55
	end
	for _, b in ipairs(f) do pending[#pending + 1] = b end
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function uart_flush(fd)
	flush_count = flush_count + 1
	return 0
end

function uart_write(fd, data)
	if wr_nak then return -1 end
	assert(#data == 19, "request frame must be 19 bytes, got " .. tostring(#data))
	assert(data[1] == 0xAA and data[2] == 0xB4 and data[19] == 0xAB, "frame head/tail mismatch")
	local sum = 0
	for i = 3, 17 do sum = sum + data[i] end
	assert(data[18] == sum % 256, "request checksum mismatch")
	wr_frames[#wr_frames + 1] = { cmd = data[3], d0 = data[4] }
	local cmd, d0 = data[3], data[4]
	if no_reply then return #data end
	if cmd == 0x02 then
		queue_ack(0x02, d0)
	elseif cmd == 0x04 then
		queue_query()
	elseif cmd == 0x06 then
		queue_ack(0x06, d0)
	elseif cmd == 0x07 then
		queue_ack(0x07, 0x00)
	else
		queue_ack(cmd, d0)
	end
	return #data
end

function uart_read(fd, n, timeout_ms)
	local out = {}
	for _ = 1, n do
		if #pending == 0 then break end
		out[#out + 1] = table.remove(pending, 1)
	end
	return out
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

local FD = 3

-- ==================== build ====================
reset()
expect_ok("build 默认（被动模式 + 版本查询）", function() return build({ fd = FD }) end)
check(#wr_frames == 2, "build 发两帧（模式+版本）", tostring(#wr_frames))
check(wr_frames[1].cmd == 0x02 and wr_frames[1].d0 == 0x01, "切被动模式（0x02, 0x01）",
	string.format("0x%02X,%d", wr_frames[1].cmd, wr_frames[1].d0))
check(wr_frames[2].cmd == 0x07, "固件版本查询（0x07）", tostring(wr_frames[2].cmd))
check(flush_count >= 2, "发帧前清缓冲", tostring(flush_count))

reset()
corrupt_reply = true
expect_err("build 应答校验和坏", function() return build({ fd = FD }) end, "not responding")
corrupt_reply = false

reset()
no_reply = true
expect_err("build 无应答", function() return build({ fd = FD }) end, "not responding")
no_reply = false

reset()
wr_nak = true
expect_err("build 写失败", function() return build({ fd = FD }) end, "not responding")
wr_nak = false

reset()
expect_err("build 缺 fd", function() return build({}) end, "Invalid Argument: fd")
expect_err("build 非表参数", function() return build("x") end, "Invalid Arguments Type")

-- ==================== call：查询与换算 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD }) end)
local n_wr = #wr_frames
local res = expect_ok("call 查询读数", function() return call({ fd = FD }) end)
if res then
	check(near(res.PM25, 42.3), "PM25=42.3（0x1A7/10）", tostring(res.PM25))
	check(near(res.PM10, 100.0), "PM10=100.0（0x3E8/10）", tostring(res.PM10))
	check(#wr_frames == n_wr + 1 and wr_frames[#wr_frames].cmd == 0x04, "查询帧 0x04")
	check(flush_count >= 3, "查询前清缓冲（build 2 次 + call 1 次）", tostring(flush_count))
end

-- ==================== call：异常路径 ====================
reset()
expect_ok("call 前 build", function() return build({ fd = FD }) end)
corrupt_reply = true
expect_err("call 应答校验和坏", function() return call({ fd = FD }) end, "not responding")
corrupt_reply = false

reset()
expect_ok("call 前 build", function() return build({ fd = FD }) end)
no_reply = true
expect_err("call 无应答超时", function() return call({ fd = FD }) end, "not responding")
no_reply = false

reset()
expect_ok("call 前 build", function() return build({ fd = FD }) end)
noise_prefix = true
res = expect_ok("call 前导噪声容忍", function() return call({ fd = FD }) end)
if res then
	check(near(res.PM25, 42.3), "噪声后帧仍正确解析", tostring(res.PM25))
end

reset()
expect_ok("call 前 build", function() return build({ fd = FD }) end)
expect_err("call 缺 fd", function() return call({}) end, "Invalid Argument: fd")
expect_err("call 非表参数", function() return call(5) end, "Invalid Arguments")
expect_err("call 非法 power", function() return call({ fd = FD, power = "x" }) end, "power")

-- ==================== call：风扇电源控制 ====================
reset()
expect_ok("power 前 build", function() return build({ fd = FD }) end)
local res = expect_ok("power sleep", function() return call({ fd = FD, power = "sleep" }) end)
if res then
	check(res.POWER == "sleep", "POWER=sleep", tostring(res.POWER))
	check(wr_frames[#wr_frames].cmd == 0x06 and wr_frames[#wr_frames].d0 == 0,
		"睡眠命令 0x06 D0=0")
end
res = expect_ok("power work", function() return call({ fd = FD, power = "work" }) end)
if res then
	check(res.POWER == "work", "POWER=work", tostring(res.POWER))
	check(wr_frames[#wr_frames].cmd == 0x06 and wr_frames[#wr_frames].d0 == 1,
		"工作命令 0x06 D0=1")
end

-- ==================== destroy ====================
reset()
expect_ok("destroy 无资源释放", function() return destroy({ fd = FD }) end)
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

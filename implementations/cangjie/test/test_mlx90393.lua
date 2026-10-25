-- MLX90393.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_mlx90393.lua（MLX90393 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile 驱动（连带加载真 HAL），再把驱动用到的 HAL 全局替换为桩。
-- 驱动在 build/call 时才解析全局名，后注桩生效——先注桩会被 HAL 的真函数覆盖
-- （test_pca9685_channel/float.lua 的旧桩模式即踩此坑，两个文件已同步修正）。
-- 桩内模拟器件语义：0xF0 复位 / 0xD0 Memory Recall / 0x3F 启动单次测量 /
-- 0x60 写寄存器（地址[15:12]+数据[11:0]）/ 0x50 读寄存器 -> 3 字节应答 /
-- 0x4F 读结果 -> 9 字节应答（按驱动 OFF 表 [T Z Y X] + status 的同款字节序打包）。
--
-- 注意：字节序/灵敏度/SM_DONE 位等 datasheet 复核项与驱动常量是同一份假设，
-- 本测试验证的是协议时序与换算的自洽性；真机核对清单见 MLX90393.lua 头注释。

dofile("modules/MLX90393.lua")
local bitc = dofile("modules/bitcompat.lua")

-- ==================== 桩与器件模型 ====================
local regs12 = {}			-- 4 位寄存器地址 -> 12 位数据（GAIN 在 0x2）
local pending_rr = nil		-- 最近一次 RR 的寄存器地址
local status = 0x40			-- status 字节（bit6=SM_DONE 置位 = 已就绪可读）
local raw = { T = 800, Z = 1000, Y = -2000, X = 300 }	-- 模型原始计数（用例可改）

local got_reset, got_recall = false, false
local xyz_trigger = 0		-- 0x3F 触发次数
local gain_written = false	-- 已写 GAIN（回读校验桩用）
local last_gain_write = nil	-- 最近一次写入 GAIN 的 12 位数据
local last_read_n = nil		-- 最近一次逐字节读的宽度
local sleep_total = 0
local set_addr_log = {}

local fail_write = false	-- 置 true 模拟总线写失败
local fail_read = false		-- 置 true 模拟总线读失败
local corrupt_verify = false	-- 置 true 模拟 GAIN 写后回读不符
local set_addr_ok = true

-- 模型复位：recall 后的出厂 GAIN 取 GAIN_SEL=2（0x020），使读-改-写可观测
local function reset_model()
	regs12 = { [0x2] = 0x020 }
	pending_rr = nil
	status = 0x40
	raw = { T = 800, Z = 1000, Y = -2000, X = 300 }
	got_reset, got_recall = false, false
	xyz_trigger = 0
	gain_written = false
	last_gain_write = nil
	last_read_n = nil
	sleep_total = 0
	set_addr_log = {}
	fail_write, fail_read, corrupt_verify, set_addr_ok = false, false, false, true
end

-- 注意：桩定义在 dofile 之后（先定义会被 HAL 真函数覆盖）
function i2c_set_addr(fd, addr)
	set_addr_log[#set_addr_log + 1] = addr
	return set_addr_ok
end

function i2c_write_multi(fd, reg, ...)
	if fail_write then return -1 end
	local b = { ... }
	if #b == 0 then
		-- 单字节命令
		if reg == 0xF0 then got_reset = true end
		if reg == 0xD0 then got_recall = true end
		if reg == 0x3F then xyz_trigger = xyz_trigger + 1 end
		return 0
	elseif reg == 0x60 and #b == 2 then
		-- 写寄存器：16 位字 = 寄存器地址[15:12] + 数据[11:0]
		local w = b[1] * 256 + b[2]
		local a4 = math.floor(w / 4096)
		regs12[a4] = w % 4096
		if a4 == 0x2 then
			last_gain_write = regs12[a4]
			gain_written = true
		end
		return 0
	elseif reg == 0x50 and #b == 1 then
		pending_rr = math.floor(b[1] / 4)
		return 0
	end
	return 0
end

function i2c_read(fd, n)
	if fail_read then return -1 end
	if n == 1 then return status end
	return -1
end

function i2c_read_bytes(fd, n)
	if fail_read then return nil end
	last_read_n = n
	if n == 3 then
		-- RR 应答：16 位数据 + status
		local d = regs12[pending_rr] or 0
		if corrupt_verify and gain_written then
			d = bitc.bxor(d, 0x010)	-- 写后回读篡改，触发校验失败
		end
		return { math.floor(d / 256) % 256, d % 256, status }
	elseif n == 9 then
		-- RM 应答：按驱动 OFF 表同款字节序 [T Z Y X] + status 打包
		local b = {}
		local function put(off, v)
			b[off] = math.floor(v / 256) % 256
			b[off + 1] = v % 256
		end
		put(1, raw.T); put(3, raw.Z); put(5, raw.Y); put(7, raw.X)
		b[9] = status
		return b
	end
	return nil
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

-- ==================== build：默认参数与自检链路 ====================
reset_model()
expect_ok("build 默认参数 (gain/timeout 缺省)", function() return build({ fd = 3, address = "0x0C" }) end)
check(got_reset, "build 发送复位 (0xF0)")
check(got_recall, "build 发送 Memory Recall (0xD0)")
check(xyz_trigger == 1, "build 试测一帧（触发一次 0x3F）", tostring(xyz_trigger))
check(last_read_n == 9, "读结果为 9 字节应答", tostring(last_read_n))
check(sleep_total >= 7, "build 含复位/召回等待 (>=7ms)", tostring(sleep_total))
-- 出厂 GAIN_SEL=2 (0x020)：清 [6:4] 后写 GAIN_SEL=0 -> 0x000
check(last_gain_write == 0x000, "缺省 gain=0 写 GAIN=0x000",
	string.format("0x%03X", last_gain_write or 0))

-- 字符串 fd/address（框架元数据侧全为字符串），tonumber('0x0C') 须为 12
reset_model()
expect_ok("build 字符串 fd='3' address='0x0C'", function() return build({ fd = "3", address = "0x0C" }) end)
check(#set_addr_log > 0 and set_addr_log[#set_addr_log] == 12,
	"set_addr 收到 0x0C=12", tostring(set_addr_log[#set_addr_log]))

-- ==================== build：gain 钳位 ====================
reset_model()
expect_ok("build gain='7'", function() return build({ fd = 3, address = "0x0C", gain = "7" }) end)
check(last_gain_write == 0x070, "gain=7 写 GAIN=0x070", string.format("0x%03X", last_gain_write or 0))

reset_model()
expect_ok("build gain='9'（钳到 7）", function() return build({ fd = 3, address = "0x0C", gain = "9" }) end)
check(last_gain_write == 0x070, "gain=9 钳到 7 写 GAIN=0x070", string.format("0x%03X", last_gain_write or 0))

reset_model()
expect_ok("build gain='-1'（钳到 0）", function() return build({ fd = 3, address = "0x0C", gain = "-1" }) end)
check(last_gain_write == 0x000, "gain=-1 钳到 0 写 GAIN=0x000", string.format("0x%03X", last_gain_write or 0))

reset_model()
expect_ok("build gain='-'（归缺省 0）", function() return build({ fd = 3, address = "0x0C", gain = "-" }) end)
check(last_gain_write == 0x000, "gain='-' 写 GAIN=0x000", string.format("0x%03X", last_gain_write or 0))

reset_model()
expect_ok("build gain='3'", function() return build({ fd = 3, address = "0x0C", gain = "3" }) end)
check(last_gain_write == 0x030, "gain=3 写 GAIN=0x030（保留其余位）", string.format("0x%03X", last_gain_write or 0))

expect_ok("build timeout='100'", function() return build({ fd = 3, address = "0x0C", timeout = "100" }) end)

-- ==================== build：错误通道 ====================
reset_model()
corrupt_verify = true
expect_err("build GAIN 回读校验失败", function() return build({ fd = 3, address = "0x0C" }) end, "GAIN verify failed")

reset_model()
fail_write = true
expect_err("build 复位写失败", function() return build({ fd = 3, address = "0x0C" }) end, "Failed to reset")

reset_model()
fail_read = true
expect_err("build 读 GAIN 失败", function() return build({ fd = 3, address = "0x0C" }) end, "Failed to read MLX90393 GAIN")

reset_model()
set_addr_ok = false
expect_err("build set_addr 失败", function() return build({ fd = 3, address = "0x0C" }) end, "set_addr failed")
set_addr_ok = true

expect_err("build 缺 fd", function() return build({ address = "0x0C" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = 3 }) end, "fd or address")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")

-- ==================== call：换算（gain=0 基准灵敏度） ====================
reset_model()
expect_ok("build gain='0'", function() return build({ fd = 3, address = "0x0C", gain = "0" }) end)
local res = expect_ok("call 正常读值", function() return call({ fd = 3, address = "0x0C" }) end)
if res then
	check(near(res.X, 300 * 0.751), "X = 300 x 0.751 = 225.3µT", tostring(res.X))
	check(near(res.Y, -2000 * 0.751), "Y = -2000 x 0.751 = -1502µT（补码还原）", tostring(res.Y))
	check(near(res.Z, 1000 * 1.210), "Z = 1000 x 1.210 = 1210µT（Z 灵敏度不同）", tostring(res.Z))
	check(near(res.T, 25.0), "T = 800/32 = 25.0°C", tostring(res.T))
	check(res.XR == 300 and res.YR == -2000 and res.ZR == 1000 and res.TR == 800,
		"原始计数 XR/YR/ZR/TR 原样保留")
	check(res.status == 0x40, "status 字节随应答返回", string.format("0x%02X", res.status or 0))
	check(xyz_trigger == 2, "call 单独触发一次测量（build 试测 1 次 + call 1 次）", tostring(xyz_trigger))
end

-- ==================== call：gain=7 低增益灵敏度 ====================
reset_model()
expect_ok("build gain='7'", function() return build({ fd = 3, address = "0x0C", gain = "7" }) end)
res = expect_ok("call gain=7 读值", function() return call({ fd = 3, address = "0x0C" }) end)
if res then
	check(near(res.X, 300 * 0.751 * 25), "X = 300 x 18.775µT/LSB（5x/0.2x 反比）", tostring(res.X))
	check(near(res.Z, 1000 * 1.210 * 25), "Z 同比缩放", tostring(res.Z))
end

-- ==================== call：错误通道 ====================
reset_model()
expect_ok("build 正常", function() return build({ fd = 3, address = "0x0C" }) end)

status = 0x00	-- SM_DONE 永不置位
expect_err("call 测量超时", function() return call({ fd = 3, address = "0x0C" }) end, "timeout")

status = 0x80	-- ERROR 位
expect_err("call status ERROR 位", function() return call({ fd = 3, address = "0x0C" }) end, "status ERROR")

status = 0x40
fail_read = true
expect_err("call 轮询读失败", function() return call({ fd = 3, address = "0x0C" }) end, "Failed to poll")
fail_read = false

expect_err("call 缺 fd", function() return call({ address = "0x0C" }) end, "fd or address")
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

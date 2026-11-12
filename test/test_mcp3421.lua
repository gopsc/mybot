-- test_mcp3421.lua —— MCP3421 真实驱动 + 虚拟 I2C 总线 + 配置回显型 ADC 模型
-- 用法（项目根目录）: luajit test/test_mcp3421.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 335 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MCP3421.lua 尾部 MCP3421_VIRT，
-- 2026-09-15 自 virtbus/mcp3421.lua 迁入）」。本器件是 virtbus 库【首个
-- 单字节配置写 + 数据流纯读、读回帧末字节自带配置回显与 RDY 就绪位的
-- 命令式 I2C 器件】：无寄存器指针，写恒 1 字节配置（i2c_write_multi），
-- 读恒无指针纯读（i2c_read 大端合并）；18bit 档 4 字节帧（D[17:16] 在
-- 首字节低 2 位）、其余 3 字节（12/14 位档顶部重复符号位）。
--
-- 覆盖：模型侧配置位域解析/四档转换门（5/17/67/267ms advance）/各档
-- 补码帧编码（含 12/14 位重复符号位、18 位右对齐）/连续模式读走自动
-- 续转换/oneshot 读完待机/待机配置/码值钳制与电压注入/长度流语义/
-- 六类钩子/virt_tick 节拍与预武装；真实 build 四档配置字节与「写→纯读
-- 回显」序列及 8 路负路径；真实 call 轮询 RDY（5ms 步进）、电压换算、
-- oneshot 触发、wait 超时、5 路负路径、virt_tick 零等待两拍；destroy
-- 待机写与零事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（MCP3421_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MCP3421.lua")
local smod = MCP3421_VIRT

local ADDR = 0x68
local dev = smod.new()
vbus.attach("MCP3421@0x68", ADDR, dev)

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件复位 + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end

local function entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do t[#t + 1] = vbus.txlog[i] end
	return t
end
local function writes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "w" then t[#t + 1] = e.bytes end
	end
	return t
end
local function reads(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "r" then t[#t + 1] = e.bytes.n end
	end
	return t
end
local function set_addrs(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "set" then t[#t + 1] = e.addr end
	end
	return t
end
local function last_cfg(mark)
	local ws = writes(mark)
	return ws[#ws] and ws[#ws][1]
end
local function s18(t)
	local u = t[1] * 65536 + t[2] * 256 + t[3]
	if u >= 0x20000 then u = u - 0x40000 end
	return u
end
local function s16(t)
	local w = t[1] * 256 + t[2]
	if w >= 0x8000 then w = w - 0x10000 end
	return w
end

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
local mark = section()

check("上电默认 0x90：12bit/×1/连续", dev:config() == 0x90
	and dev:res_bits() == 12 and dev:pga() == 1 and dev:is_continuous(),
	string.format("cfg=%02X", dev:config()))
check("上电空闲：无进行中转换、无新结果", dev:remaining_ms() == nil and not dev:is_fresh())

-- 配置帧只接受恰好 1 字节
check("非 table 写 NACK", dev.write(0x90) == false)
check("空帧写 NACK", dev.write({}) == false)
check("2 字节帧 NACK（无寄存器指针）", dev.write({ 0x90, 0x00 }) == false)

-- 四档配置编码
dev.write({ 0x9C })
check("0x9C = 18bit/×1/cont（RDY 触发）", dev:res_bits() == 18 and dev:pga() == 1
	and dev:is_continuous() and dev:remaining_ms() == 267,
	tostring(dev:remaining_ms()))
dev.write({ 0x8B })
check("0x8B = 16bit/×8/oneshot", dev:res_bits() == 16 and dev:pga() == 8
	and not dev:is_continuous() and dev:remaining_ms() == 67)
dev.write({ 0x94 })
check("0x94 = 14bit/×1/cont", dev:res_bits() == 14 and dev:pga() == 1
	and dev:is_continuous() and dev:remaining_ms() == 17)
dev.write({ 0x91 })
check("0x91 = 12bit/×2/cont", dev:res_bits() == 12 and dev:pga() == 2
	and dev:is_continuous() and dev:remaining_ms() == 5)
check("配置字节全部入写序列", dev:write_count() == 4
	and dev:write_log()[1] == 0x9C and dev:write_log()[4] == 0x91)

-- build 时序：写 RDY=1 后转换中，回显 RDY=1 但低 6 位已是新配置
mark = section()
dev.write({ 0x9C })
local f = dev.read(4)
check("转换中回显 0x9C（RDY=1/低 6 位=1C）", f[4] == 0x9C,
	string.format("%02X", f[4]))
check("转换中读取不消耗结果（仍在倒计时）", dev:remaining_ms() == 267)

-- 四档转换门：门限前 RDY=1，到点 RDY=0
mark = section()
dev.write({ 0x9C })
dev:advance(266)
check("18bit 266ms 未就绪", dev.read(4)[4] == 0x9C and dev:remaining_ms() == 1)
dev:advance(1)
local rdy4 = dev.read(4)
check("18bit 267ms 就绪（echo=0x1C）", rdy4[4] == 0x1C,
	string.format("%02X", rdy4[4]))
mark = section()
dev.write({ 0x98 })
dev:advance(66); check("16bit 66ms 未就绪", dev.read(3)[3] == 0x98)
dev:advance(1); check("16bit 67ms 就绪（echo=0x18）", dev.read(3)[3] == 0x18)
mark = section()
dev.write({ 0x94 })
dev:advance(16); check("14bit 16ms 未就绪", dev.read(3)[3] == 0x94)
dev:advance(1); check("14bit 17ms 就绪（echo=0x14）", dev.read(3)[3] == 0x14)
mark = section()
dev.write({ 0x90 })
dev:advance(4); check("12bit 4ms 未就绪", dev.read(3)[3] == 0x90)
dev:advance(1); check("12bit 5ms 就绪（echo=0x10）", dev.read(3)[3] == 0x10)

-- 各档补码帧编码（与驱动 decode 互为交叉验证的独立编码）
mark = section()
dev.write({ 0x9C })
dev:set_raw(1000); dev:advance(267)
local e = dev.read(4)
check("18bit +1000 = 00 03 E8 + echo", e[1] == 0 and e[2] == 0x03 and e[3] == 0xE8
	and e[4] == 0x1C, string.format("%02X %02X %02X %02X", e[1], e[2], e[3], e[4]))
section(); dev.write({ 0x9C })
dev:set_raw(131071); dev:advance(267)
e = dev.read(4)
check("18bit 正满码 131071 = 01 FF FF", e[1] == 1 and e[2] == 0xFF and e[3] == 0xFF)
section(); dev.write({ 0x9C })
dev:set_raw(-131072); dev:advance(267)
e = dev.read(4)
check("18bit 负满码 -131072 = 02 00 00", e[1] == 2 and e[2] == 0 and e[3] == 0)
check("18bit 帧经驱动式合并/解码还原 -131072", s18(e) == -131072)

section(); dev.write({ 0x98 })
dev:set_raw(-20000); dev:advance(67)
e = dev.read(3)
check("16bit -20000 = B1 E0（int16）", e[1] == 0xB1 and e[2] == 0xE0
	and s16(e) == -20000)

section(); dev.write({ 0x94 })
dev:set_raw(5000); dev:advance(17)
e = dev.read(3)
check("14bit +5000 = 13 88（无符号扩展）", e[1] == 0x13 and e[2] == 0x88
	and s16(e) == 5000)
section(); dev.write({ 0x94 })
dev:set_raw(-4000); dev:advance(17)
e = dev.read(3)
check("14bit -4000 = F0 60（顶部 2 位重复符号）", e[1] == 0xF0 and e[2] == 0x60
	and s16(e) == -4000, string.format("%02X %02X", e[1], e[2]))

section(); dev.write({ 0x91 })
dev:set_raw(-100); dev:advance(5)
e = dev.read(3)
check("12bit -100 = FF 9C（顶部 4 位重复符号）", e[1] == 0xFF and e[2] == 0x9C
	and s16(e) == -100)
section(); dev.write({ 0x90 })
dev:set_raw(1500); dev:advance(5)
e = dev.read(3)
check("12bit +1500 = 05 DC", e[1] == 0x05 and e[2] == 0xDC and s16(e) == 1500)

-- 连续模式：读走一帧立即排下一转换
section(); dev.write({ 0x9C }); dev:advance(267)
check("就绪态 fresh=true", dev:is_fresh())
dev.read(4)
check("连续模式读走后自动续转（remaining=267、fresh=false）",
	dev:remaining_ms() == 267 and not dev:is_fresh())
check("续转未完成再读 RDY=1", dev.read(4)[4] == 0x9C)

-- oneshot：读完进待机，不自动续转
section(); dev.write({ 0x8C }); dev:set_raw(42); dev:advance(267)
e = dev.read(4)
check("oneshot 就绪帧 echo=0x0C、raw=42", e[4] == 0x0C and s18(e) == 42,
	string.format("echo=%02X raw=%d", e[4], s18(e)))
check("oneshot 读完进待机（无续转）", dev:remaining_ms() == nil and not dev:is_fresh())
check("待机态再读 RDY=1（无新数据）", dev.read(4)[4] == 0x8C)

-- 待机配置：O/C=0/RDY=0 立即空闲
section(); dev.write({ 0x9C })
check("连续转换进行中", dev:remaining_ms() == 267)
dev.write({ 0x0C })
check("写 0x0C 待机：转换取消、配置保留 18bit/×1",
	dev:remaining_ms() == nil and dev:res_bits() == 18 and dev:pga() == 1
	and not dev:is_continuous())

-- set_raw 位宽钳制
section(); dev.write({ 0x9C })
dev:set_raw(999999); check("18bit 钳 +131071", dev:raw_value() == 131071)
dev:set_raw(-999999); check("18bit 钳 -131072", dev:raw_value() == -131072)
section(); dev.write({ 0x90 })
dev:set_raw(9999); check("12bit 钳 +2047", dev:raw_value() == 2047)
dev:set_raw(-9999); check("12bit 钳 -2048", dev:raw_value() == -2048)

-- set_voltage 物理量注入（LSB=2.048/2^(res-1)/pga，与驱动同源）
section(); dev.write({ 0x90 })
dev:set_voltage(1.5)
check("12bit/×1：1.5V = 1500 LSB（1mV）", dev:raw_value() == 1500,
	tostring(dev:raw_value()))
section(); dev.write({ 0x98 })
dev:set_voltage(1.25)
check("16bit/×1：1.25V = 20000 LSB（62.5uV）", dev:raw_value() == 20000,
	tostring(dev:raw_value()))
section(); dev.write({ 0x9F })
dev:set_voltage(0.032)
check("18bit/×8：0.032V = 16384 LSB（1.953125uV）",
	math.abs(dev:raw_value() - 16384) <= 1, tostring(dev:raw_value()))
dev:set_voltage(0.256)
check("18bit/×8：0.256V 略超正满码钳 131071", dev:raw_value() == 131071)

-- 读长度由主设备决定（字节流）：按请求截取/补 0
section(); dev.write({ 0x9C }); dev:set_raw(1000); dev:advance(267)
local short = dev.read(1)
check("短读 1 字节只取首字节", short[1] == 0 and #short == 1)
-- 注意上一帧已被读走（连续模式续转中），重新造一帧就绪再测长读
dev:advance(267)
local long = dev.read(5)
check("长读 5 字节：帧后补 0（字节流语义）", long[4] == 0x1C and long[5] == 0)

-- 故障钩子
mark = section()
dev.nack = true
check("nack：写/读全拒", dev.write({ 0x90 }) == false and dev.read(3) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write：只拒写", dev.write({ 0x90 }) == false and dev.read(3) ~= nil)
dev.nack_write = false
dev.nack_read = true
check("nack_read：只拒读", dev.write({ 0x90 }) and dev.read(3) == nil)
dev.nack_read = false

mark = section()
dev:fail_write(function(b) return b == 0x9C end)
check("fail_write 按配置字节 0x9C 过滤", dev.write({ 0x9C }) == false)
check("fail_write 不影响其他字节（0x90 成功）", dev.write({ 0x90 }) == true)
dev:fail_write(nil)
dev:fail_read(function(n, fresh) return n == 4 end)
check("fail_read 按长度 4 过滤", dev.read(4) == nil and dev.read(3) ~= nil)
dev:fail_read(nil)

section(); dev.write({ 0x9C })
dev:set_never_ready(true)
dev:advance(100000)
check("never_ready：转换永不完成（RDY 恒 1）", dev:is_fresh() == false
	and dev.read(4)[4] == 0x9C)
dev:set_never_ready(false)

section(); dev.write({ 0x9C }); dev:corrupt_echo(true)
local bad = dev.read(4)
check("corrupt_echo：低 6 位翻转、RDY 位不变",
	(bad[4] % 64) ~= (0x9C % 64) and math.floor(bad[4] / 128) % 2 == 1,
	string.format("%02X", bad[4]))
dev:corrupt_echo(false)

mark = section()
dev:set_never_ready(true)
dev:reset()
check("reset 保留故障钩子（never_ready 仍生效）", dev:is_fresh() == false)
dev:clear_faults()
dev.write({ 0x9C }); dev:advance(267)
check("clear_faults 后转换可正常完成", dev:is_fresh())
mark = section()
dev.write({ 0x9C })
dev:reset_logs()
check("reset_logs 清空写序列（不动芯片配置 0x9C）", dev:write_count() == 0
	and dev:config() == 0x9C)

-- virt_tick：确定性正弦 + 预武装
section(); dev.write({ 0x9C })
local function tick18(n)
	dev:virt_tick(n)
	return s18(dev.read(4))
end
check("virt_tick 18bit/×1：n0=0、n8=+96000(+1.5V)、n24=-96000",
	tick18(0) == 0 and tick18(8) == 96000 and tick18(24) == -96000,
	string.format("%d/%d/%d", tick18(0), tick18(8), tick18(24)))
section(); dev.write({ 0x90 })
dev:virt_tick(8)
check("virt_tick 12bit 预武装：首读 RDY=0、raw=1500",
	dev.read(3)[3] == 0x10 and dev:raw_value() == 1500)

-- ======================================================================
-- 组 2：真实 build（经虚拟总线）
-- ======================================================================
mark = section()
local r = expect_ok("build 默认 18bit/×1/cont", function()
	return build({ fd = fd, address = "0x68" })
end)
if r then
	local ws, rs, ss = writes(mark), reads(mark), set_addrs(mark)
	check("build 序列：set_addr→1 笔单字节写→1 次 4B 纯读",
		#ss == 1 and ss[1] == ADDR and #ws == 1 and ws[1][1] == 0x9C
		and #rs == 1 and rs[1] == 4,
		string.format("set=%d w=%d r=%s", #ss, #ws, tostring(rs[1])))
	check("build 读前无指针写（纯读器件）", #ws == 1)
end

mark = section()
expect_ok("build 16bit/×8/oneshot", function()
	return build({ fd = fd, address = "0x68", res = "16", pga = "8", opmode = "oneshot" })
end)
check("配置字节 0x8B、回显读 3B", last_cfg(mark) == 0x8B and reads(mark)[1] == 3,
	string.format("%02X", last_cfg(mark) or 0))

mark = section()
expect_ok("build 14bit/×1/cont", function()
	return build({ fd = fd, address = "0x68", res = "14" })
end)
check("配置字节 0x94、回显读 3B", last_cfg(mark) == 0x94 and reads(mark)[1] == 3)

mark = section()
expect_ok("build 12bit/×2/cont", function()
	return build({ fd = fd, address = "0x68", res = "12", pga = "2" })
end)
check("配置字节 0x91、回显读 3B", last_cfg(mark) == 0x91 and reads(mark)[1] == 3)

-- build 负路径
mark = section()
expect_err("build 非 table", function() return build(7) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x68" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")

mark = section()
expect_err("build fd=99 未打开 → set_addr failed",
	function() return build({ fd = 99, address = "0x68" }) end, "set_addr failed")
check("set_addr 失败不产生读写事务", #writes(mark) == 0 and #reads(mark) == 0)

mark = section()
expect_err("build 非法 res=13",
	function() return build({ fd = fd, address = "0x68", res = "13" }) end, "res(bits)")
expect_err("build 非法 pga=3",
	function() return build({ fd = fd, address = "0x68", pga = "3" }) end, "pga(gain)")
expect_err("build 非法 opmode",
	function() return build({ fd = fd, address = "0x68", opmode = "x" }) end, "opmode")
check("参数非法不产生总线事务", #writes(mark) == 0 and #reads(mark) == 0)

mark = section()
dev:fail_write(function(b) return b == 0x9C end)
expect_err("build 配置写 NACK",
	function() return build({ fd = fd, address = "0x68" }) end, "config write failed")

mark = section()
dev:fail_read(function(n) return n == 4 end)
expect_err("build 回显读 NACK",
	function() return build({ fd = fd, address = "0x68" }) end, "echo read failed")

mark = section()
dev:corrupt_echo(true)
expect_err("build 回显低 6 位不匹配",
	function() return build({ fd = fd, address = "0x68" }) end, "echo mismatch")
dev:corrupt_echo(false)

-- ======================================================================
-- 组 3：真实 call（经虚拟总线，驱动轮询 RDY + milli_sleep 推进时钟）
-- ======================================================================
mark = section()
expect_ok("call 前置 build 18bit/×1", function()
	return build({ fd = fd, address = "0x68" })
end)
mark = #vbus.txlog
dev:set_raw(1000)
sleep_total = 0
r = expect_ok("call 18bit：轮询至 270ms 就绪、零写事务", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then
	check("raw=1000", r.raw == 1000, tostring(r.raw))
	check("voltage = 1000*2.048/131072 ≈ 15.625mV",
		near(r.voltage, 1000 * 2.048 / 131072, 1e-12), tostring(r.voltage))
	check("连续模式 call 无写、全是 4B 读", #writes(mark) == 0
		and #reads(mark) == 55 and reads(mark)[1] == 4,
		string.format("w=%d r=%d", #writes(mark), #reads(mark)))
	check("轮询睡眠总 270ms（5ms 步进 ×54）", sleep_total == 270,
		tostring(sleep_total))
end

sleep_total = 0
r = expect_ok("call 第二次：读走后续转再次轮询", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw 仍=1000、再睡 270ms", r.raw == 1000 and sleep_total == 270,
	string.format("raw=%s sleep=%s", tostring(r.raw), tostring(sleep_total))) end

-- 满码 ×8
mark = section()
expect_ok("rebuild 18bit/×8", function()
	return build({ fd = fd, address = "0x68", pga = "8" })
end)
mark = #vbus.txlog
dev:set_raw(131071)
r = expect_ok("call ×8 正满码 ≈ +0.256V", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=131071、voltage≈0.256V", r.raw == 131071
	and near(r.voltage, 131071 * 2.048 / 131072 / 8, 1e-9), tostring(r.voltage)) end
dev:set_raw(-131072)
r = expect_ok("call ×8 负满码 ≈ -0.256V", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-131072、voltage≈-0.256V", r.raw == -131072
	and near(r.voltage, -0.256, 1e-9), tostring(r.voltage)) end

-- 18bit 负码符号扩展
mark = section()
expect_ok("rebuild 18bit/×1", function()
	return build({ fd = fd, address = "0x68" })
end)
mark = #vbus.txlog
dev:set_raw(-1000)
r = expect_ok("call 18bit 负码 -1000", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-1000、voltage 为负", r.raw == -1000
	and near(r.voltage, -1000 * 2.048 / 131072, 1e-12), tostring(r.voltage)) end

-- 16/14/12 档
mark = section()
expect_ok("rebuild 16bit", function()
	return build({ fd = fd, address = "0x68", res = "16" })
end)
mark = #vbus.txlog
dev:set_raw(-20000)
r = expect_ok("call 16bit -20000 ≈ -1.25V（轮询 70ms）", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-20000、voltage=-1.25V、睡 70ms", r.raw == -20000
	and near(r.voltage, -1.25, 1e-9) and sleep_total == 70,
	string.format("%s/%s/%s", tostring(r.raw), tostring(r.voltage), tostring(sleep_total))) end

mark = section()
expect_ok("rebuild 14bit", function()
	return build({ fd = fd, address = "0x68", res = "14" })
end)
mark = #vbus.txlog
dev:set_raw(5000)
r = expect_ok("call 14bit +5000 = 1.25V（轮询 20ms）", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=5000、voltage=1.25V、睡 20ms", r.raw == 5000
	and near(r.voltage, 1.25, 1e-9) and sleep_total == 20, tostring(sleep_total)) end
dev:set_raw(-4000)
r = expect_ok("call 14bit -4000（顶部重复符号解码）", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-4000", r.raw == -4000, tostring(r.raw)) end

mark = section()
expect_ok("rebuild 12bit/×2", function()
	return build({ fd = fd, address = "0x68", res = "12", pga = "2" })
end)
mark = #vbus.txlog
dev:set_raw(-100)
r = expect_ok("call 12bit/×2 -100 = -0.05V（轮询 5ms）", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-100、voltage=-0.05V、睡 5ms、3B 读", r.raw == -100
	and near(r.voltage, -0.05, 1e-9) and sleep_total == 5
	and reads(mark)[1] == 3,
	string.format("%s/%s/%s", tostring(r.raw), tostring(r.voltage), tostring(sleep_total))) end

-- oneshot：每拍触发写
mark = section()
expect_ok("build oneshot 18bit/×1", function()
	return build({ fd = fd, address = "0x68", opmode = "oneshot" })
end)
mark = #vbus.txlog
local m0 = #vbus.txlog
dev:set_raw(42)
sleep_total = 0
r = expect_ok("call oneshot：先写 0x8C 触发再轮询", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then
	local ws = writes(mark)
	check("raw=42、触发字节 0x8C、睡 270ms", r.raw == 42
		and ws[#ws][1] == 0x8C and sleep_total == 270,
		string.format("raw=%s cfg=%02X sleep=%s", tostring(r.raw),
			ws[#ws] and ws[#ws][1] or 0, tostring(sleep_total)))
	check("call 窗口恰 1 笔触发写", #ws == 1, tostring(#ws))
end
-- 第二次 call 再次触发
r = expect_ok("call oneshot 第二次再次触发", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then
	local ws2 = {}
	for _, e in ipairs(entries(m0)) do
		if e.dir == "w" then ws2[#ws2 + 1] = e.bytes[1] end
	end
	check("累计 2 笔触发写均为 0x8C", #ws2 == 2 and ws2[1] == 0x8C and ws2[2] == 0x8C,
		string.format("%d 笔", #ws2))
end

-- 超时：never_ready
mark = section()
expect_ok("rebuild 18bit/×1（超时用）", function()
	return build({ fd = fd, address = "0x68" })
end)
dev:set_never_ready(true)
sleep_total = 0
expect_err("call 默认 wait=287 超时（not ready）",
	function() return call({ fd = fd, address = "0x68" }) end, "not ready")
check("默认等待 290ms（5ms 步进、>=287 退出）", sleep_total >= 287 and sleep_total <= 295,
	tostring(sleep_total))
sleep_total = 0
expect_err("call wait=50 覆盖超时",
	function() return call({ fd = fd, address = "0x68", wait = "50" }) end, "not ready")
check("wait=50 实睡 50ms", sleep_total == 50, tostring(sleep_total))
dev:set_never_ready(false)

-- call 负路径
mark = section()
expect_ok("rebuild 18bit/×1（负路径用）", function()
	return build({ fd = fd, address = "0x68" })
end)
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
expect_err("call fd=99 set_addr failed",
	function() return call({ fd = 99, address = "0x68" }) end, "set_addr failed")

mark = section()
expect_ok("rebuild oneshot（触发失败用）", function()
	return build({ fd = fd, address = "0x68", opmode = "oneshot" })
end)
dev:fail_write(function(b) return b == 0x8C end)
expect_err("oneshot 触发写 NACK",
	function() return call({ fd = fd, address = "0x68" }) end, "trigger write failed")
dev:fail_write(nil)

mark = section()
expect_ok("rebuild 18bit/×1（读失败用）", function()
	return build({ fd = fd, address = "0x68" })
end)
dev:fail_read(function() return true end)
expect_err("call 读 NACK",
	function() return call({ fd = fd, address = "0x68" }) end, "read failed")
dev:fail_read(nil)

-- virt_tick 守护式两拍：预武装首读就绪，零睡眠
mark = section()
expect_ok("rebuild 12bit/×1（守护场景）", function()
	return build({ fd = fd, address = "0x68", res = "12" })
end)
mark = #vbus.txlog
dev:virt_tick(8)
sleep_total = 0
r = expect_ok("call virt_tick 正峰：零等待 +1.5V", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=1500、voltage≈1.5、0ms 睡眠、仅 1 次读",
	r.raw == 1500 and near(r.voltage, 1.5, 1e-9) and sleep_total == 0
	and #reads(mark) == 1,
	string.format("raw=%s v=%s sleep=%s r=%d", tostring(r.raw), tostring(r.voltage),
		tostring(sleep_total), #reads(mark))) end
dev:virt_tick(24)
r = expect_ok("call virt_tick 负峰：-1.5V", function()
	return call({ fd = fd, address = "0x68" })
end)
if r then check("raw=-1500、voltage≈-1.5、零睡眠",
	r.raw == -1500 and near(r.voltage, -1.5, 1e-9) and sleep_total == 0,
	string.format("raw=%s sleep=%s", tostring(r.raw), tostring(sleep_total))) end

-- ======================================================================
-- 组 4：destroy
-- ======================================================================
mark = section()
expect_ok("destroy 前置 build 18bit/×1", function()
	return build({ fd = fd, address = "0x68" })
end)
local dm = #vbus.txlog
expect_ok("destroy 置待机", function()
	return destroy({ fd = fd, address = "0x68" })
end)
local dw = {}
for _, e in ipairs(entries(dm)) do
	if e.dir == "w" then dw[#dw + 1] = e.bytes[1] end
end
check("destroy 恰 1 笔写 0x0C（RDY=0/O/C=0，保留速率增益）",
	#dw == 1 and dw[1] == 0x0C, string.format("%d 笔 %s", #dw,
		dw[1] and string.format("%02X", dw[1]) or "-"))

mark = section()
expect_ok("rebuild 16bit/×8（destroy 编码用）", function()
	return build({ fd = fd, address = "0x68", res = "16", pga = "8", opmode = "oneshot" })
end)
dm = #vbus.txlog
expect_ok("destroy 16bit/×8 oneshot 写 0x0B", function()
	return destroy({ fd = fd, address = "0x68" })
end)
dw = {}
for _, e in ipairs(entries(dm)) do
	if e.dir == "w" then dw[#dw + 1] = e.bytes[1] end
end
check("destroy 保留 S+G 低 4 位 = 0x0B", #dw == 1 and dw[1] == 0x0B,
	dw[1] and string.format("%02X", dw[1]) or "-")

mark = section()
expect_ok("build 后验证 destroy 缺 fd 零事务", function()
	return build({ fd = fd, address = "0x68" })
end)
dm = #vbus.txlog
expect_ok("destroy 缺 fd/address 安全返回", function() return destroy({}) end)
local any_bus = false
for _, e in ipairs(entries(dm)) do
	if e.dir ~= "set" then any_bus = true end
end
check("缺 fd 无 set/w/r 事务", not any_bus)
expect_err("destroy 非 table", function() return destroy(nil) end, "Invalid Arguments Type")

-- ======================================================================
tester.summary()

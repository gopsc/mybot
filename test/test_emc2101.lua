-- test_emc2101.lua —— EMC2101 真实驱动 + 虚拟 I2C 总线 + 风扇控制混合模型
-- 用法（项目根目录）: luajit test/test_emc2101.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：EMC2101_GC=1 luajit test/test_emc2101.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 261 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/EMC2101.lua 尾部 EMC2101_VIRT，
-- 2026-09-15 自 virtbus/emc2101.lua 迁入）」。旧桩三处互证假绿已按
-- SMSC EMC2101 Datasheet Rev.2.54 与 Adafruit Arduino/CircuitPython
-- 两库交叉钉死、戳破：
--   1) FAN_CONFIG(0x4A) POR 旧桩给 0x00（LUT 激活）；datasheet
--      Table 6.18 DEFAULT=20h（PROG=1，上电即手动/可编程态）；
--   2) PWM_F(0x4D) POR 旧桩给 0x0F=15（full_lsb=30）；datasheet
--      Table 6.24 DEFAULT=17h=23——真实 full_lsb=46（50%→23/75%→35）；
--   3) TACH 读序旧桩与旧驱动都断言「先 MSB(0x47) 后 LSB(0x46)」；
--      datasheet §6.1 Data Read Interlock 明确 TACH 是【先读 LSB 锁存
--      MSB】（外温才是先 MSB 锁存 LSB，两路方向相反），两 Adafruit
--      库均 LSB first——驱动 call 读序已修，本测试锁正确序列 46 在 47 前。
--
-- 真实 build（无 milli_sleep，连续测量器件）：
--   手动缺省：set + 0xFD 指针/r + 0xFE 指针/r + 0x4D 指针/r
--   + lut_disable（0x4A 指针/r + {4A,v|20}）+ {4C,lsb}
--   = set+6w+4r 共 11 txlog；PWM_F POR 0x17 → full_lsb=46。
--   LUT 路径：前段同，禁 LUT 后 {50+16B} 一笔，再 lut_enable
--   （0x4A 指针/r + {4A,v&DF}）= set+8w+5r 共 14 txlog。
-- 真实 call 采样：set + 0x02/0x00/0x01/0x10/0x46/0x47 六组指针/r
--   = set+6w+6r 共 13 txlog（TACH 指针 46 必须在 47 之前）；
--   call({duty=N})：set + lut_disable（指针/r+写）+ {4C,lsb}
--   = set+3w+1r 共 5 txlog。
--
-- 覆盖：模型 POR 全表/指针 burst 自增回绕/双路 interlock 撕裂防护/
-- PROG 硬件门（FAN_SETTING+LUT 只读丢弃）/写掩码/测量区 ROM 只读/
-- 外温 11 位补码编解码与开路短路特征码/TACH 小端编码/virt_tick/
-- who 覆写/钩子；真实 build 手动与 LUT 两路径逐 txlog/横幅/字符串地址/
-- full_lsb=46 换算锚点/duty 钳位/lut 四类非法；build 负路径逐短路点；
-- 真实 call 采样读序/故障码/负温/停转/duty 切换；call 六读失败点；
-- destroy 安全。

if os.getenv("EMC2101_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x4C

-- 模型内嵌于驱动文件（EMC2101_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/EMC2101.lua")
local mmod = EMC2101_VIRT

local dev = mmod.new()

local dev = mmod.new()
vbus.attach("EMC2101@0x4C", ADDR, dev)

-- milli_sleep 桩：本器件驱动全程无睡眠，桩只累加（应恒 0）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 每个 section：器件回上电态 + 故障解除（挂载/fd 不动）
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
		if e.dir == "r" then t[#t + 1] = e end
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
local function wcode(b)
	local v = 0
	for i = 1, #b do v = v * 256 + b[i] end
	return v
end
local function wcodes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do t[#t + 1] = wcode(b) end
	return t
end
local function same_seq(got, want)
	if #got ~= #want then return false end
	for i = 1, #want do
		if got[i] ~= want[i] then return false end
	end
	return true
end
local function seq_hex(mark)
	local t = {}
	for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%X", v) end
	return table.concat(t, ",")
end
local function frame(b)
	if not b then return "nil" end
	local s = {}
	for i = 1, #b do s[i] = string.format("%02X", b[i]) end
	return table.concat(s, ",")
end
local function approx(a, b, tol)
	return type(a) == "number" and math.abs(a - b) <= (tol or 0.01)
end

local function capture(fn)
	local cap, old = {}, print
	print = function(...) cap[#cap + 1] = table.concat({ ... }, "\t") end
	local ok, res = pcall(fn)
	print = old
	return ok, res, table.concat(cap, "|")
end

-- 直接走总线回调（脱驱动）
local function w(...) return dev.write({ ... }) end
local function r1(...) return dev.read(...) end

-- 录制 dev.read 返回帧（txlog 的 r 条目只记请求长度 n，帧内容靠这个留档）
local function recording(fn)
	local saved, got = dev.read, {}
	dev.read = function(n)
		local r = saved(n)
		got[#got + 1] = r
		return r
	end
	local a, b, c = fn()
	dev.read = saved
	return got, a, b, c
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

-- ---- POR（Datasheet Rev.2.54 Table 6.1/6.18/6.23/6.24/6.25）----
check("POR 测量区 0x00/0x01/0x02/0x10 = 0",
	dev:reg(0x00) == 0 and dev:reg(0x01) == 0 and dev:reg(0x02) == 0
	and dev:reg(0x10) == 0)
check("POR TACH 0x46/0x47 = FF/FF（低速特征 65535）",
	dev:reg(0x46) == 0xFF and dev:reg(0x47) == 0xFF
	and dev:tach_count() == 65535,
	string.format("%02X/%02X", dev:reg(0x46), dev:reg(0x47)))
check("POR TACH 换算 RPM=5400000/65535≈82.4",
	approx(dev:rpm(), 5400000 / 65535, 0.1), tostring(dev:rpm()))
check("POR FAN_CONFIG 0x4A=0x20（PROG=1 手动态，旧桩误给 00）",
	dev:reg(0x4A) == 0x20 and dev:prog() == true,
	string.format("0x%02X", dev:reg(0x4A)))
check("POR FAN_SPINUP 0x4B=0x3F / FAN_SETTING 0x4C=0x00",
	dev:reg(0x4B) == 0x3F and dev:reg(0x4C) == 0x00)
check("POR PWM_F 0x4D=0x17=23（旧桩误给 0F）",
	dev:reg(0x4D) == 0x17 and dev:pwm_f() == 23,
	string.format("0x%02X", dev:reg(0x4D)))
check("POR full_lsb=2*23=46（旧桩 30）",
	dev:full_lsb() == 46, tostring(dev:full_lsb()))
check("POR PWM_DIV 0x4E=0x01 / LUT_HYST 0x4F=0x04",
	dev:reg(0x4E) == 0x01 and dev:reg(0x4F) == 0x04)
do
	local lut_ok = true
	for i = 1, 8 do
		local p = dev:lut()[i]
		if p.temp ~= 0x7F or p.duty ~= 0x3F then lut_ok = false end
	end
	check("POR LUT 8 槽全兜底 [0x7F,0x3F]", lut_ok)
	check("POR LUT 原始字节 50~5F 7F/3F 交错",
		dev:reg(0x50) == 0x7F and dev:reg(0x51) == 0x3F
		and dev:reg(0x5E) == 0x7F and dev:reg(0x5F) == 0x3F)
end
check("POR PART_ID=0x16 / MFG_ID=0x5D SMSC / REV=0x01",
	dev:part_id() == 0x16 and dev:mfg_id() == 0x5D and dev:rev() == 0x01,
	string.format("%02X/%02X/%02X", dev:part_id(), dev:mfg_id(), dev:rev()))
check("POR 观察口 status=0/internal=0/ext_code=0/ext=0.0/fan_setting=0",
	dev:status() == 0 and dev:internal_c() == 0 and dev:ext_code() == 0
	and dev:ext_temp_c() == 0 and dev:fan_setting() == 0)
check("POR ptr=nil（无指针纯读 NACK）", dev:ptr() == nil and r1(1) == nil)

-- ---- 8 位指针 / burst 自增 / 回绕 / 帧校验 ----
w(0x4D)
local s = r1(4)
check("burst 4D→50 = 17,01,04,7F（跨 PWM_DIV/HYST/LUT）",
	s and #s == 4 and s[1] == 0x17 and s[2] == 0x01 and s[3] == 0x04
	and s[4] == 0x7F, frame(s))
w(0xFE)
s = r1(3)
check("burst FE,FF 后回绕 00 = 5D,01,00",
	s and s[1] == 0x5D and s[2] == 0x01 and s[3] == 0x00, frame(s))
w(0x20)
check("未定义地址读 0", r1(1)[1] == 0)
w(0x00)
check("读 n=0 钳 1B", #r1(0) == 1)
check("读 n=100 钳 16B", #r1(100) == 16)
check("空帧/非表/坏字节 NACK", dev.write({}) == false
	and dev.write("x") == false and dev.write({ 0x00, 256 }) == false)
check("坏指针字节 NACK", w(0x100) == false)

-- ---- 写掩码（PROG=1 POR 下）----
w(0x4A, 0xFF)
check("写 0x4A=FF 落 7F（bit7 无定义），PROG 仍=1",
	dev:reg(0x4A) == 0x7F and dev:prog(), string.format("0x%02X", dev:reg(0x4A)))
w(0x4C, 0xFF)
check("写 0x4C=FF 落 3F（6 位占空比）", dev:reg(0x4C) == 0x3F)
w(0x4B, 0xFF)
check("写 0x4B=FF 落 3F", dev:reg(0x4B) == 0x3F)
w(0x4D, 0xFF)
check("写 0x4D=FF 落 1F（5 位 PWM_F），full_lsb=2*31=62",
	dev:reg(0x4D) == 0x1F and dev:full_lsb() == 62)
w(0x4E, 0xFF)
check("写 0x4E=FF 整字节落盘", dev:reg(0x4E) == 0xFF)
w(0x4F, 0xFF)
check("写 0x4F=FF 落 1F（5 位迟滞）", dev:reg(0x4F) == 0x1F)
w(0x50, 0xFF)
check("LUT 偶址温度槽 FF 落 7F", dev:reg(0x50) == 0x7F)
w(0x51, 0xFF)
check("LUT 奇址风速槽 FF 落 3F", dev:reg(0x51) == 0x3F)

-- ---- PROG 硬件门：PROG=0 时 FAN_SETTING/LUT 只读（写 ACK 丢弃）----
w(0x4A, 0x00)
check("写 0x4A=00：PROG=0（LUT 激活）", dev:reg(0x4A) == 0x00
	and not dev:prog())
w(0x4C, 0x10)
check("PROG=0 写 0x4C 丢弃（仍 3F）", dev:reg(0x4C) == 0x3F)
w(0x50, 0x40)
check("PROG=0 写 LUT 温度槽丢弃（仍 7F）", dev:reg(0x50) == 0x7F)
w(0x51, 0x20)
check("PROG=0 写 LUT 风速槽丢弃（仍 3F）", dev:reg(0x51) == 0x3F)
w(0x4A, 0x20)
check("恢复 PROG=1", dev:prog())
w(0x4C, 0x10)
check("PROG=1 写 0x4C=10 落盘", dev:reg(0x4C) == 0x10)
dev.write({ 0x50, 40, 0, 50, 14 })	-- burst 写两槽（十进制温度/风速）
check("burst 自增写 LUT：50=28(40°C)/51=00/52=32(50°C)/53=0E(14)",
	dev:reg(0x50) == 0x28 and dev:reg(0x51) == 0x00
	and dev:reg(0x52) == 0x32 and dev:reg(0x53) == 0x0E,
	string.format("%02X/%02X/%02X/%02X",
		dev:reg(0x50), dev:reg(0x51), dev:reg(0x52), dev:reg(0x53)))
w(0x4A, 0x00)
check("PROG=0 burst 写 LUT 整笔丢弃",
	(dev.write({ 0x50, 0x11, 0x22 }) == true)
	and dev:reg(0x50) == 0x28 and dev:reg(0x51) == 0x00)
w(0x4A, 0x20)

-- ---- 测量区/ROM 只读：写 ACK 丢弃 ----
dev:set_internal_temp_c(42)
dev:set_status(0x07)
w(0x00, 0x11); w(0x02, 0x00)
check("测量区 0x00/0x02 写丢弃（注入值保留 2A/07）",
	dev:reg(0x00) == 0x2A and dev:reg(0x02) == 0x07)
w(0x46, 0x00); w(0x47, 0x00)
check("TACH 字节写丢弃", dev:tach_count() == 65535)
w(0xFD, 0x99); w(0xFE, 0x99); w(0xFF, 0x99)
check("ROM 三字节写丢弃", dev:part_id() == 0x16 and dev:mfg_id() == 0x5D
	and dev:rev() == 0x01)

-- ---- 外温 11 位补码编解码（交叉锚点）----
dev:set_external_raw(205)
check("raw11=205 -> MSB=19/LSB=A0 -> 25.625°C",
	dev:reg(0x01) == 0x19 and dev:reg(0x10) == 0xA0
	and dev:ext_code() == 205 and dev:ext_temp_c() == 25.625,
	string.format("%02X/%02X", dev:reg(0x01), dev:reg(0x10)))
dev:set_external_raw(0x3F7)
check("raw11=3F7(1015) -> 7E/E0 -> 126.875°C（正最大附近）",
	dev:reg(0x01) == 0x7E and dev:reg(0x10) == 0xE0
	and approx(dev:ext_temp_c(), 126.875), tostring(dev:ext_temp_c()))
dev:set_external_raw(-1024)
check("raw11=-1024 -> 80/00 -> -128.0°C",
	dev:reg(0x01) == 0x80 and dev:reg(0x10) == 0x00
	and dev:ext_temp_c() == -128.0, tostring(dev:ext_temp_c()))
dev:set_external_raw(-1)
check("raw11=-1 -> FF/E0 -> -0.125°C（分数负温）",
	dev:reg(0x01) == 0xFF and dev:reg(0x10) == 0xE0
	and dev:ext_temp_c() == -0.125, tostring(dev:ext_temp_c()))
check("set_external_temp_c(25.7) 1/8 量化 -> 25.75",
	dev:set_external_temp_c(25.7) == 25.75, tostring(dev:ext_temp_c()))
dev:set_diode_fault("open")
check("开路特征码 3F8（7F/00）-> ext_temp_c=nil",
	dev:ext_code() == 0x3F8 and dev:reg(0x01) == 0x7F
	and dev:reg(0x10) == 0x00 and dev:ext_temp_c() == nil)
dev:set_diode_fault("short")
check("短路特征码 3FF（7F/E0）-> ext_temp_c=nil",
	dev:ext_code() == 0x3FF and dev:reg(0x01) == 0x7F
	and dev:reg(0x10) == 0xE0 and dev:ext_temp_c() == nil)
check("set_internal_temp_c(-12) -> F4/s8=-12；越界钳 ±127/±128",
	(dev:set_internal_temp_c(-12) and dev:reg(0x00) == 0xF4
	and dev:internal_c() == -12)
	and (dev:set_internal_temp_c(200) and dev:internal_c() == 127)
	and (dev:set_internal_temp_c(-200) and dev:internal_c() == -128))

-- ---- TACH 编码与 RPM 逆注入 ----
dev:set_tach_count(1750)
check("count=1750=06D6 -> LSB=D6/MSB=06，RPM=3085.71",
	dev:reg(0x46) == 0xD6 and dev:reg(0x47) == 0x06
	and approx(dev:rpm(), 3085.714, 0.01), tostring(dev:rpm()))
dev:set_rpm(3000)
check("set_rpm(3000) 反推 count=1800（整除）",
	dev:tach_count() == 1800 and dev:rpm() == 3000,
	tostring(dev:tach_count()))
dev:set_rpm(4200)
check("set_rpm(4200) 四舍五入 count=1286",
	dev:tach_count() == 1286 and approx(dev:rpm(), 4199.07, 0.05),
	dev:tach_count() .. "/" .. tostring(dev:rpm()))
dev:set_rpm(0)
check("set_rpm(0) -> count=0/rpm()=0（停转防除零）",
	dev:tach_count() == 0 and dev:rpm() == 0)

-- ---- Data Read Interlock：两路方向相反 + 撕裂防护（模型核心）----
dev:set_external_temp_c(25.625)
w(0x01)
check("外温先读 MSB=19（该拍把 LSB=A0 锁进影子）",
	r1(1)[1] == 0x19)
dev:set_external_temp_c(30.0)
w(0x10)
check("再读 LSB 拿到旧影子 A0（非新值 00，同源不撕裂）",
	r1(1)[1] == 0xA0)
w(0x01); check("重新配对读 MSB=1E", r1(1)[1] == 0x1E)
w(0x10); check("重配后 LSB=00", r1(1)[1] == 0x00)
dev:reset()
w(0x10)
check("POR 后未读 MSB 直接读 LSB = 影子初值 0", r1(1)[1] == 0x00)

dev:set_tach_count(1750)
w(0x46)
check("TACH 先读 LSB=D6（该拍把 MSB=06 锁进影子）",
	r1(1)[1] == 0xD6)
dev:set_tach_count(0x1234)
w(0x47)
check("再读 MSB 拿到旧影子 06（非新值 12，方向与外温相反）",
	r1(1)[1] == 0x06)
w(0x46); check("重新配对读 LSB=34", r1(1)[1] == 0x34)
w(0x47); check("重配后 MSB=12", r1(1)[1] == 0x12)
dev:reset()
w(0x47)
check("POR 后未读 LSB 直接读 MSB = 影子初值 FF", r1(1)[1] == 0xFF)

-- ---- virt_tick 32 拍确定性造数 ----
local function tick_vals(n)
	dev:virt_tick(n)
	return dev:internal_c(), dev:ext_temp_c(), dev:rpm(), dev:status()
end
local i0, e0, r0, st0 = tick_vals(0)
check("tick0：内 35/外 42.0/RPM 3000/status 0",
	i0 == 35 and e0 == 42.0 and r0 == 3000 and st0 == 0,
	string.format("%d/%s/%s/%d", i0, tostring(e0), tostring(r0), st0))
local i8, e8, r8 = tick_vals(8)
check("tick8（峰）：内 40/外 48.0/RPM≈4199（温高转速高反相）",
	i8 == 40 and e8 == 48.0 and approx(r8, 4199.07, 0.1),
	string.format("%d/%s/%s", i8, tostring(e8), tostring(r8)))
local i24, e24, r24 = tick_vals(24)
check("tick24（谷）：内 30/外 36.0/RPM 1800",
	i24 == 30 and e24 == 36.0 and r24 == 1800,
	string.format("%d/%s/%s", i24, tostring(e24), tostring(r24)))
tick_vals(32)
check("tick32 == tick0（32 拍周期）",
	dev:internal_c() == 35 and dev:ext_temp_c() == 42.0
	and dev:rpm() == 3000)
check("virt_tick 返回 self", dev:virt_tick(1) == dev)

-- ---- who 身份覆写 / 写日志 / 故障钩子 ----
dev:reset()
dev:who(0x28)
check("who(0x28) 落 0xFD（EMC2101-R 合法 Part ID）", dev:part_id() == 0x28)
dev:who(nil, 0x99)
check("who(nil,99) 仅改 MFG", dev:part_id() == 0x28 and dev:mfg_id() == 0x99)
dev:reset()
check("完整 reset 恢复出厂身份 16/5D",
	dev:part_id() == 0x16 and dev:mfg_id() == 0x5D)

w(0x4D, 0x17); w(0x4C, 0x10); w(0x00)
check("write_count 只数 ≥2B（2，纯指针不计）",
	dev:write_count() == 2, tostring(dev:write_count()))
check("write_log 记 reg/bytes",
	#dev:writes() == 2 and dev:writes()[1].reg == 0x4D
	and dev:writes()[1].bytes[2] == 0x17)
dev:reset_logs()
check("reset_logs 清零", dev:write_count() == 0 and #dev:writes() == 0)

dev.nack_write = true
check("nack_write 写 NACK", w(0x00) == false)
dev:clear_faults()
check("解除后写恢复", w(0x00) == true)
dev:set_external_temp_c(25.625)
w(0x01); r1(1)
dev.nack_read = true
check("nack_read 读 NACK", r1(1) == nil)
dev:clear_faults()
w(0x01)
check("解除后读恢复", r1(1)[1] == 0x19)
dev:fail_write(function(b) return #b == 2 and b[1] == 0x4C end)
check("fail_write 谓词命中占空比帧", w(0x4C, 0x10) == false)
check("fail_write 不影响其他写", w(0x4D, 0x17) == true)
dev:clear_faults()
w(0x02)
dev:fail_read(function(a) return a == 0x02 end)
check("fail_read 谓词按指针命中", r1(1) == nil)
dev:clear_faults()
dev.nack = true
check("nack 全断：写/读都 NACK", w(0x00) == false and r1(1) == nil)
dev:clear_faults()
dev.nack_write = true
check("reset 保留故障钩子", (dev:reset() and w(0x00)) == false)
dev:clear_faults()
check("reset 回 POR（4A=20/4D=17/LUT 兜底）",
	dev:reg(0x4A) == 0x20 and dev:reg(0x4D) == 0x17
	and dev:reg(0x50) == 0x7F and dev:reg(0x5F) == 0x3F)

-- =====================================================================
-- 组 2：真实 build（手动缺省，逐笔事务 + 横幅 + 字符串地址）
-- =====================================================================
mark = section()
local bframes, bbuild
local ok, res, banner = capture(function()
	bframes, bbuild = recording(function()
		return build({ fd = fd, address = "0x4C" })
	end)
	return bbuild
end)
check("build 手动缺省 OK", ok and res.result == "OK", tostring(res and res.result))
local es = entries(mark)
check("build 11 txlog（set+6w+4r）", #es == 11, tostring(#es))
check("build 首笔 set 0x4C", set_addrs(mark)[1] == 0x4C,
	string.format("0x%X", set_addrs(mark)[1]))
check("build 写序列 FD,FE,4D,4A 指针 + 4A20 + 4C00",
	same_seq(wcodes(mark), { 0xFD, 0xFE, 0x4D, 0x4A, 0x4A20, 0x4C00 }),
	seq_hex(mark))
do
	local rds = reads(mark)
	check("build 4 笔读宽度全 1", #rds == 4, tostring(#rds))
	local all1 = true
	for _, e in ipairs(rds) do if e.bytes.n ~= 1 then all1 = false end end
	check("4 读 n 全 =1", all1)
end
check("读帧 1=PART 16 / 2=MFG 5D",
	bframes[1][1] == 0x16 and bframes[2][1] == 0x5D,
	frame(bframes[1]) .. "|" .. frame(bframes[2]))
check("读帧 3=PWM_F 17（full_lsb 现算 46）/ 4=FAN_CONFIG 20",
	bframes[3][1] == 0x17 and bframes[4][1] == 0x20,
	frame(bframes[3]) .. "|" .. frame(bframes[4]))
check("build 后 4A=20（PROG 保持）/4C=00（停转）",
	dev:reg(0x4A) == 0x20 and dev:reg(0x4C) == 0x00)
check("横幅含 init OK/addr=0x4C/part=EMC2101/手动 0% lsb=0/46",
	banner:find("EMC2101 init OK", 1, true)
	and banner:find("addr=0x4C", 1, true)
	and banner:find("part=EMC2101", 1, true)
	and banner:find("lsb=0/46", 1, true), banner)
check("build 全程无睡眠", sleep_total == 0, tostring(sleep_total))

mark = section()
expect_ok("build 字符串 fd='3' address='0x4C'", function()
	return build({ fd = "3", address = "0x4C" })
end)
check("set_addr 收到 0x4C=76", set_addrs(mark)[1] == 76,
	tostring(set_addrs(mark)[1]))

-- =====================================================================
-- 组 3：build 配置档（duty 各锚点/钳位 + LUT 路径 + 四类非法）
-- =====================================================================
for _, spec in ipairs({
	{ 50, 23, "50%→23" }, { 75, 35, "75%→35" }, { 20, 9, "20%→9" },
	{ 30, 14, "30%→14（四舍五入）" }, { 100, 46, "100%→46（满码非 63）" },
	{ -5, 0, "负 duty 钳 0" }, { 150, 46, ">100 钳 100→46" },
	-- NaN 反例（26.1）：'nan' 过 tonumber 出的是 number（Lua 里 truthy），
	-- `tonumber(x) or 0` 的 or 兜不住，而 `< 0`/`> 100` 两条钳位对 NaN 恒假
	-- 放行，duty_to_lsb(NaN) 仍是 NaN，最后被 HAL 的 byte_of 挡成 nil → 报
	-- "Failed to write EMC2101 fan setting"，把配置笔误误报成 I2C 故障。
	-- 应与同列的 'abc' 同结论：归缺省 0（停转）。
	{ "nan", 0, "'nan' 归缺省 0（非报 I2C 故障）" },
}) do
	mark = section()
	ok, res, banner = capture(function()
		return build({ fd = fd, address = "0x4C", duty = tostring(spec[1]) })
	end)
	check("build duty=" .. spec[1] .. " " .. spec[3],
		ok and res.result == "OK" and dev:reg(0x4C) == spec[2],
		string.format("0x%02X", dev:reg(0x4C)))
	if spec[1] == 75 then
		check("75% 横幅 lsb=35/46", banner:find("lsb=35/46", 1, true) ~= nil, banner)
	end
end

-- LUT 路径（乱序给入，驱动按温度升序落盘；空槽 7F/3F 兜底）
mark = section()
local lok, lres, lbanner
lok, lres, lbanner = capture(function()
	return build({ fd = fd, address = "0x4C",
		lut = "70:100,40:0,60:60,50:30" })
end)
check("build LUT 4 项 OK", lok and lres.result == "OK",
	tostring(lres and lres.result))
check("build LUT 14 txlog（set+8w+5r）", #entries(mark) == 14,
	tostring(#entries(mark)))
do
	local lut = dev:lut()
	check("LUT 升序落盘 40/0,50/14,60/28,70/46（full_lsb=46）",
		lut[1].temp == 40 and lut[1].duty == 0
		and lut[2].temp == 50 and lut[2].duty == 14
		and lut[3].temp == 60 and lut[3].duty == 28
		and lut[4].temp == 70 and lut[4].duty == 46,
		string.format("%d/%d,%d/%d,%d/%d,%d/%d",
			lut[1].temp, lut[1].duty, lut[2].temp, lut[2].duty,
			lut[3].temp, lut[3].duty, lut[4].temp, lut[4].duty))
	check("LUT 空槽 5~8 全 7F/3F 兜底",
		lut[5].temp == 0x7F and lut[5].duty == 0x3F
		and lut[8].temp == 0x7F and lut[8].duty == 0x3F)
	check("lut_enable 后 0x4A=00（PROG=0，LUT 激活）",
		dev:reg(0x4A) == 0x00 and not dev:prog())
end
do
	-- 16 字节 LUT 写帧逐字节
	local multi
	for _, b in ipairs(writes(mark)) do
		if #b == 17 and b[1] == 0x50 then multi = b end
	end
	local want = { 0x50, 40, 0, 50, 14, 60, 28, 70, 46,
		0x7F, 0x3F, 0x7F, 0x3F, 0x7F, 0x3F, 0x7F, 0x3F }
	local same = multi ~= nil and #multi == 17
	if same then for i = 1, 17 do if multi[i] ~= want[i] then same = false end end end
	check("LUT 写帧 {50+16B} 逐字节一致", same, frame(multi))
	check("LUT 横幅 mode=LUT(4 项)",
		lbanner:find("LUT(4 项)", 1, true) ~= nil, lbanner)
end

-- 非法 lut（parse 在总线操作后、lut_disable 前，故 7 txlog 即止）
for _, spec in ipairs({
	{ "10:10,20:10,30:10,40:10,50:10,60:10,70:10,80:10,90:10",
		"more than 8 entries", "9 项超 8 槽" },
	{ "40:x", "bad pair", "坏对" },
	{ "128:0", "temp 128 > 127", "温度超 7 位" },
	{ "0:101", "duty 101 > 100%", "占空比超 100%" },
}) do
	mark = section()
	expect_err("非法 lut：" .. spec[3], function()
		return build({ fd = fd, address = "0x4C", lut = spec[1] })
	end, spec[2])
	check("非法 lut 止于 7 txlog（ID 2 读+PWM_F 读，不碰 4A/LUT）",
		#entries(mark) == 7, tostring(#entries(mark)))
	check("非法 lut 写序列仅 FD/FE/4D 指针",
		same_seq(wcodes(mark), { 0xFD, 0xFE, 0x4D }), seq_hex(mark))
end

-- =====================================================================
-- 组 4：真实 build 错误路径（逐短路点）
-- =====================================================================
mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x4C" }) end,
	"fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end,
	"fd or address")
expect_err("build address 非数值", function()
	return build({ fd = fd, address = "0xZZ" })
end, "fd or address")
expect_err("build 非表参数", function() return build(nil) end,
	"Invalid Arguments Type")
check("前置校验类错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build fd=99 未打开（set_addr 失败，零 txlog）", function()
	return build({ fd = 99, address = "0x4C" })
end, "set_addr failed")
check("set_addr 失败零 txlog（连 set 都不记）",
	#entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 无器件地址 0x01", function()
	return build({ fd = fd, address = "0x01" })
end, "ID registers")
-- 无器件：两 ID 指针写都 NACK（写失败不产生 r），驱动两读都发后统一判
check("无器件 txlog=3（set+FD/FE 两笔指针写 NACK）", #entries(mark) == 3,
	tostring(#entries(mark)))

mark = section()
dev:fail_read(function(a) return a == 0xFD end)
expect_err("build 读 PART_ID 失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "ID registers")
-- 驱动两 ID 读先都发再统一判：FD 指针/r 留痕后 FE 指针/r 也执行
check("PART 读失败 txlog=5（set+两 ID 指针/r 全留痕后统一判）",
	#entries(mark) == 5, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(a) return a == 0xFE end)
expect_err("build 读 MFG_ID 失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "ID registers")
check("MFG 读失败 txlog=5（两 ID 先都读再统一判）",
	#entries(mark) == 5, tostring(#entries(mark)))

mark = section()
dev:who(0x99)
expect_err("build PART_ID 不符", function()
	return build({ fd = fd, address = "0x4C" })
end, "Not EMC2101")
check("甄别失败 txlog=5（不进入 PWM_F）", #entries(mark) == 5,
	tostring(#entries(mark)))

mark = section()
dev:who(nil, 0x99)
expect_err("build MFG_ID 不符（非 5D）", function()
	return build({ fd = fd, address = "0x4C" })
end, "Not EMC2101")
check("MFG 不符 txlog=5", #entries(mark) == 5, tostring(#entries(mark)))

mark = section()
dev:who(0x28)
expect_ok("build Part ID=0x28（EMC2101-R）接受", function()
	return build({ fd = fd, address = "0x4C" })
end)

mark = section()
dev:fail_read(function(a) return a == 0x4D end)
expect_err("build 读 PWM_F 失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "PWM_F")
check("PWM_F 读失败 txlog=7（set+ID 4 事务+指针w+失败r）",
	#entries(mark) == 7, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(a) return a == 0x4A end)
expect_err("build lut_disable 读失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "Failed to disable EMC2101 LUT")
check("disable 读失败 txlog=9（ID+PWM_F 6 事务+4A 指针w+失败r）",
	#entries(mark) == 9, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x4A end)
expect_err("build lut_disable 写失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "Failed to disable EMC2101 LUT")
check("disable 写失败 txlog=10（读成功后写 NACK）",
	#entries(mark) == 10, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x4C end)
expect_err("build FAN_SETTING 写失败", function()
	return build({ fd = fd, address = "0x4C" })
end, "fan setting")
check("占空比写失败 txlog=11（disable 3 事务成功后 {4C} 写 NACK）",
	#entries(mark) == 11, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 17 and b[1] == 0x50 end)
expect_err("build LUT 16B 写失败", function()
	return build({ fd = fd, address = "0x4C", lut = "40:0,50:30" })
end, "Failed to write EMC2101 LUT")
check("LUT 写失败 txlog=11（disable 3 事务成功后）",
	#entries(mark) == 11, tostring(#entries(mark)))

mark = section()
do
	local hits = 0
	dev:fail_read(function(a)
		if a == 0x4A then hits = hits + 1; return hits == 2 end
	end)
	expect_err("build lut_enable 读失败（第 2 次读 4A）", function()
		return build({ fd = fd, address = "0x4C", lut = "40:0,50:30" })
	end, "Failed to enable EMC2101 LUT")
	check("enable 读失败 txlog=13（LUT 写成功后）",
		#entries(mark) == 13, tostring(#entries(mark)))
end

mark = section()
do
	local hits = 0
	dev:fail_write(function(b)
		if #b == 2 and b[1] == 0x4A then
			hits = hits + 1
			return hits == 2		-- 第 1 次=disable 放行，第 2 次=enable NACK
		end
		return false
	end)
	expect_err("build lut_enable 写失败（第 2 次写 4A）", function()
		return build({ fd = fd, address = "0x4C", lut = "40:0,50:30" })
	end, "Failed to enable EMC2101 LUT")
	check("enable 写失败 txlog=14", #entries(mark) == 14, tostring(#entries(mark)))
end

-- =====================================================================
-- 组 5：真实 call（采样读序/故障/负温/停转 + duty 切换 + tick 驱动）
-- =====================================================================
mark = section()
expect_ok("call 用例前 build 手动", function()
	return build({ fd = fd, address = "0x4C" })
end)

dev:set_internal_temp_c(25)
dev:set_external_temp_c(25.625)
dev:set_tach_count(1750)
dev:set_status(0)

mark = #vbus.txlog	-- 不 reset，窗口保留 build 配置
local cframes
local out
cframes, out = recording(function()
	return call({ fd = fd, address = "0x4C" })
end)
check("call 采样 OK", out and out.result == "OK", tostring(out and out.result))
check("采样 13 txlog（set+6w+6r）", #entries(mark) == 13, tostring(#entries(mark)))
check("采样指针序 02,00,01,10,46,47（TACH 46 在 47 前——驱动修复点）",
	same_seq(wcodes(mark), { 0x02, 0x00, 0x01, 0x10, 0x46, 0x47 }),
	seq_hex(mark))
check("读帧 status=00/TIN=19/EMSB=19/ELSB=A0/TLSB=D6/TMSB=06",
	cframes[1][1] == 0x00 and cframes[2][1] == 0x19
	and cframes[3][1] == 0x19 and cframes[4][1] == 0xA0
	and cframes[5][1] == 0xD6 and cframes[6][1] == 0x06,
	table.concat({ frame(cframes[1]), frame(cframes[2]), frame(cframes[3]),
		frame(cframes[4]), frame(cframes[5]), frame(cframes[6]) }, "|"))
check("TEMP_IN=25/TEMP_EXT=25.625/RPM≈3085.71/STATUS=0",
	out.TEMP_IN == 25 and out.TEMP_EXT == 25.625
	and approx(out.RPM, 3085.714, 0.01) and out.STATUS == 0,
	string.format("%d/%s/%s/%d", out.TEMP_IN, tostring(out.TEMP_EXT),
		tostring(out.RPM), out.STATUS))

dev:set_diode_fault("open")
dev:set_status(0x04)
out = expect_ok("call 二极管开路", function()
	return call({ fd = fd, address = "0x4C" })
end)
if out then
	check("开路 TEMP_EXT=nil/STATUS=0x04（TEMP_IN/RPM 照常）",
		out.TEMP_EXT == nil and out.STATUS == 0x04 and out.TEMP_IN == 25
		and approx(out.RPM, 3085.714, 0.01), tostring(out.TEMP_EXT))
end

dev:set_diode_fault("short")
out = expect_ok("call 二极管短路", function()
	return call({ fd = fd, address = "0x4C" })
end)
if out then check("短路 TEMP_EXT=nil", out.TEMP_EXT == nil) end

dev:set_external_raw(-1024)
dev:set_status(0)
out = expect_ok("call 负温 -128°C", function()
	return call({ fd = fd, address = "0x4C" })
end)
if out then
	check("TEMP_EXT=-128.0/STATUS=0", out.TEMP_EXT == -128.0 and out.STATUS == 0,
		tostring(out.TEMP_EXT))
end

dev:set_external_temp_c(25.625)
dev:set_tach_count(0)
out = expect_ok("call 停转 count=0", function()
	return call({ fd = fd, address = "0x4C" })
end)
if out then check("RPM=0（不除零）/外温恢复 25.625",
	out.RPM == 0 and out.TEMP_EXT == 25.625, tostring(out.RPM)) end
dev:set_tach_count(1750)

-- duty 切换（手动 build 后 4A 已=20）
mark = #vbus.txlog
out = expect_ok("call duty=50 切手动", function()
	return call({ fd = fd, address = "0x4C", duty = "50" })
end)
check("duty 5 txlog（set+4A 指针/r+4A20+4C17）",
	#entries(mark) == 5, tostring(#entries(mark)))
check("duty 写序列 4A,4A20,4C17",
	same_seq(wcodes(mark), { 0x4A, 0x4A20, 0x4C17 }), seq_hex(mark))
if out then
	check("返回 duty=50/lsb=23；芯片 4A=20/4C=17",
		out.duty == 50 and out.lsb == 23 and dev:reg(0x4A) == 0x20
		and dev:reg(0x4C) == 0x17,
		string.format("%d/%d", out.duty, out.lsb))
end

-- NaN 反例（26.1）：call 侧只判 `duty ~= nil`，NaN 穿透后两条钳位恒假放行，
-- 报 "Failed to write EMC2101 fan setting"；同列写 'abc' 走的是整块跳过。
mark = #vbus.txlog
out = expect_ok("call duty='abc' 视同未给（对照组）",
	function() return call({ fd = fd, address = "0x4C", duty = "abc" }) end)
check("对照组：'abc' 后芯片 4C 仍=0x17", dev:reg(0x4C) == 0x17,
	string.format("0x%02X", dev:reg(0x4C)))
mark = #vbus.txlog
out = expect_ok("call duty='nan' 同视未给（非报 I2C 故障）",
	function() return call({ fd = fd, address = "0x4C", duty = "nan" }) end)
check("duty NaN 与 'abc' 同结论：4C 仍=0x17", dev:reg(0x4C) == 0x17,
	string.format("0x%02X", dev:reg(0x4C)))

-- LUT build（4A=00 激活态）后切 duty：RMW 读 00 置位成 20
mark = section()
expect_ok("LUT build（4A 归零）", function()
	return build({ fd = fd, address = "0x4C", lut = "40:0,50:30" })
end)
check("LUT 模式下 4A=00", dev:reg(0x4A) == 0x00)
mark = #vbus.txlog
expect_ok("LUT 态 call duty=50 抢回手动", function()
	return call({ fd = fd, address = "0x4C", duty = "50" })
end)
check("抢手动写序仍 4A,4A20,4C17（00|20=20）",
	same_seq(wcodes(mark), { 0x4A, 0x4A20, 0x4C17 }), seq_hex(mark))
check("抢回后 4A=20/4C=17", dev:reg(0x4A) == 0x20 and dev:reg(0x4C) == 0x17)
mark = #vbus.txlog
out = expect_ok("call duty=150 钳 100", function()
	return call({ fd = fd, address = "0x4C", duty = "150" })
end)
if out then check("duty=100/lsb=46", out.duty == 100 and out.lsb == 46) end
check("钳位 call 仍 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))

-- virt_tick 驱动真实采样
mark = section()
expect_ok("tick 用例前 build", function()
	return build({ fd = fd, address = "0x4C" })
end)
local got0, got8, got24
for n, slot in ipairs({ { 0, "got0" }, { 8, "got8" }, { 24, "got24" } }) do
	dev:virt_tick(slot[1])
	local r = call({ fd = fd, address = "0x4C" })
	if slot[1] == 0 then got0 = r elseif slot[1] == 8 then got8 = r else got24 = r end
end
check("tick0 采样 TEMP_IN=35/TEMP_EXT=42.0/RPM=3000",
	got0.TEMP_IN == 35 and got0.TEMP_EXT == 42.0 and got0.RPM == 3000,
	string.format("%d/%s/%s", got0.TEMP_IN, tostring(got0.TEMP_EXT),
		tostring(got0.RPM)))
check("tick8 采样 TEMP_IN=40/TEMP_EXT=48.0/RPM≈4199",
	got8.TEMP_IN == 40 and got8.TEMP_EXT == 48.0
	and approx(got8.RPM, 4199.07, 0.1), tostring(got8.RPM))
check("tick24 采样 TEMP_IN=30/TEMP_EXT=36.0/RPM=1800",
	got24.TEMP_IN == 30 and got24.TEMP_EXT == 36.0 and got24.RPM == 1800,
	string.format("%d/%s/%s", got24.TEMP_IN, tostring(got24.TEMP_EXT),
		tostring(got24.RPM)))

-- =====================================================================
-- 组 6：真实 call 错误路径（六读短路点 + duty 路径 + 参数）
-- =====================================================================
mark = section()
expect_ok("call 失败用例前 build", function()
	return build({ fd = fd, address = "0x4C" })
end)
dev:set_internal_temp_c(25)
dev:set_external_temp_c(25.625)
dev:set_tach_count(1750)

for _, spec in ipairs({
	{ 0x02, 3, "status", "读 STATUS 失败" },
	{ 0x00, 5, "internal temperature", "读内部温度失败" },
	{ 0x01, 7, "external temperature", "读外温 MSB 失败" },
	{ 0x10, 9, "external temperature", "读外温 LSB 失败" },
	{ 0x46, 11, "TACH", "读 TACH LSB 失败" },
	{ 0x47, 13, "TACH", "读 TACH MSB 失败" },
}) do
	dev:clear_faults()
	dev:fail_read(function(a) return a == spec[1] end)
	mark = #vbus.txlog
	expect_err("call " .. spec[4], function()
		return call({ fd = fd, address = "0x4C" })
	end, spec[3])
	check(spec[4] .. " txlog=" .. spec[2],
		#entries(mark) == spec[2], tostring(#entries(mark)))
end
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 无器件地址 0x02", function()
	return call({ fd = fd, address = "0x02" })
end, "status")
check("无器件 txlog=2（set+02 指针写 NACK）",
	#entries(mark) == 2, tostring(#entries(mark)))

-- duty 路径失败
dev:fail_read(function(a) return a == 0x4A end)
mark = #vbus.txlog
expect_err("call duty lut_disable 读失败", function()
	return call({ fd = fd, address = "0x4C", duty = "50" })
end, "Failed to disable EMC2101 LUT")
check("duty disable 读失败 txlog=3", #entries(mark) == 3, tostring(#entries(mark)))
dev:clear_faults()

dev:fail_write(function(b) return #b == 2 and b[1] == 0x4A end)
mark = #vbus.txlog
expect_err("call duty lut_disable 写失败", function()
	return call({ fd = fd, address = "0x4C", duty = "50" })
end, "Failed to disable EMC2101 LUT")
check("duty disable 写失败 txlog=4", #entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

dev:fail_write(function(b) return #b == 2 and b[1] == 0x4C end)
mark = #vbus.txlog
expect_err("call duty FAN_SETTING 写失败", function()
	return call({ fd = fd, address = "0x4C", duty = "50" })
end, "fan setting")
check("duty 占空比写失败 txlog=5", #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 非表参数", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x4C" }) end,
	"fd or address")
check("call 参数错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

-- =====================================================================
-- 组 7：destroy（零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 无资源需释放（零事务）", function() return destroy({}) end)
check("destroy 零 txlog", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非表参数", function() return destroy(nil) end,
	"Invalid Arguments Type")

-- ==================== 汇总 ====================
tester.summary("EMC2101 结果")

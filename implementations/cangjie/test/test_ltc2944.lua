-- test_ltc2944.lua —— LTC2944 真实驱动 + 虚拟 I2C 总线 + 电量计模型
-- 用法（项目根目录）: luajit test/test_ltc2944.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：LTC_GC=1 luajit test/test_ltc2944.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + virtbus/ltc2944.lua 模型」。本器件是 virtbus 库【8 位字节指针 +
-- 16 位大端寄存器对、指针自增模 26 回绕】样板（ADI LTC2944，固定地址 0x64）：
--   寄存器文件 0x00~0x19；write 首字节=指针其后数据逐字节落位、read 从指针
--   连续读自增；0x02 电荷/0x08 电压/0x0E 电流（偏移二进制）/0x14 温度。
--   无 ID 寄存器，build = 读 STATUS ACK 兼在位甄别 + CONTROL 单字节写；
--   CONTROL(0x01) 是 8 位寄存器——3 字节帧 {0x01,0x00,ctrl} 会经指针自增
--   把 ctrl 踩进 CHG_MSB(0x02)（charge_msb_clobbered 哨兵，2026-09 审计 S1）。
--
-- 覆盖：模型侧 POR/指针事务与自增/模 26 回绕/16 位大端对独立公式交叉/
-- clobber 协议事实/坏帧 NACK/物理量逆注入闭环/virt_tick 32 拍/谓词+nack
-- 钩子/reset 保留钩子/种子构造；真实 build 事务形态（set→指针读 STATUS→
-- 1B CONTROL 写，零睡眠）、七档预分频码与归一、电荷不被踩哨兵、零/固定
-- 地址负路径；真实 call 四寄存器指针序 02/08/0E/14 与换算交叉、M/rsense
-- 量程、四路读失败短路、未 build 守卫；destroy 零总线事务。

if os.getenv("LTC_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/ltc2944.lua")
vbus.reset()

-- 固定地址器件：模型只挂 0x64
local dev = smod.new()
vbus.attach("LTC2944@0x64", 0x64, dev)
vbus.load_driver("modules/LTC2944.lua")

-- 驱动不调 milli_sleep；桩仅留痕，断言 build/call 全程零睡眠
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + (tonumber(ms) or 0) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))
check("i2c_set_addr 0x64", i2c_set_addr(fd, 0x64) == true)

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用，保留驱动配置出的 CONTROL）
local function window() return #vbus.txlog end

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
local function read_sizes(mark)
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
local function nwr(mark) return #writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 测试侧独立换算公式（照驱动注释双源常数，不看模型实现）
local function ref_v(raw) return raw / 65535 * 70.8 end
local function ref_i(raw, r) return (raw - 0x7FFF) / 0x7FFF * 0.064 / r end
local function ref_t(raw) return raw / 65535 * 510 - 273.15 end
local function ref_q(code, m, r) return code * 0.34e-6 * 1000 * (m * 0.05) / (r * 4096) end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点 API / 经 HAL）
-- =====================================================================
local m = section()
check("POR STATUS=0", dev:status() == 0)
check("POR CONTROL=0（非自动模式）", dev:control() == 0)
check("POR 四测量 u16 全 0",
	dev:charge_raw() == 0 and dev:voltage_raw() == 0 and dev:current_raw() == 0 and dev:temp_raw() == 0)
check("POR ptr=0/计数 0", dev:ptr() == 0 and dev:write_count() == 0 and dev:read_count() == 0)

-- HAL 形态：i2c_write_reg 返布尔；i2c_read_multi 合并大端；指针写+读两事务
m = section()
check("HAL i2c_write_reg 0x01,0xF0 返 true", i2c_write_reg(fd, 0x01, 0xF0) == true)
check("CONTROL=0xF0", dev:control() == 0xF0, string.format("%X", dev:control()))
check("写后 ptr=0x02", dev:ptr() == 0x02, tostring(dev:ptr()))
check("窗口 1 写（{01,F0} 一帧）", nwr(m) == 1 and #writes(m)[1] == 2
	and writes(m)[1][1] == 0x01 and writes(m)[1][2] == 0xF0)
check("HAL i2c_read_multi(0x08,2) 合并大端", i2c_read_multi(fd, 0x08, 2) == 0)
check("指针读窗口 1 写(指针 0x08)+1 读(n=2)",
	nwr(m) == 2 and nrd(m) == 1 and writes(m)[2][1] == 0x08 and read_sizes(m)[1] == 2,
	string.format("%d/%d", nwr(m), nrd(m)))
check("读后 ptr=0x0A", dev:ptr() == 0x0A, tostring(dev:ptr()))
local bt = i2c_read_multi_bytes(fd, 0x0E, 2)
check("i2c_read_multi_bytes 返字节表", type(bt) == "table" and #bt == 2)

-- 16 位大端对：独立 hi*256+lo 公式交叉，多组码经 API 写、HAL 读
for _, code in ipairs({ 0, 1, 255, 256, 0x1234, 0xABCD, 0xFFFF }) do
	section()
	dev:set_voltage_raw(code)
	check(string.format("V 码 0x%04X 字节序 MSB/LSB", code),
		dev:reg(0x08) == math.floor(code / 256) and dev:reg(0x09) == code % 256,
		string.format("%02X %02X", dev:reg(0x08), dev:reg(0x09)))
	check(string.format("V 码 0x%04X HAL 合并一致", code), i2c_read_multi(fd, 0x08, 2) == code)
end

-- burst 跨寄存器自增：指针 0x02 读 8 字节 = CHG/V 两对 + 阈值高对
section()
dev:set_word(0x02, 0x1111)
dev:set_word(0x04, 0x3333)
dev:set_word(0x06, 0x5555)
dev:set_word(0x08, 0x7777)
local burst = i2c_read_multi_bytes(fd, 0x02, 8)
check("8B burst 11 11 33 33 55 55 77 77",
	burst[1] == 0x11 and burst[2] == 0x11 and burst[3] == 0x33 and burst[4] == 0x33
	and burst[5] == 0x55 and burst[6] == 0x55 and burst[7] == 0x77 and burst[8] == 0x77,
	table.concat(burst, ","))

-- 指针模 26 回绕（datasheet：越过 0x19 回 0x00）
m = section()
check("越界 burst 写 ACK", i2c_write_multi(fd, 0x18, 0x11, 0x22, 0x33, 0x44) == 0)
check("落 0x18/0x19", dev:reg(0x18) == 0x11 and dev:reg(0x19) == 0x22)
check("回绕落 0x00/0x01", dev:reg(0x00) == 0x33 and dev:reg(0x01) == 0x44,
	string.format("%02X/%02X", dev:reg(0x00), dev:reg(0x01)))
check("回绕写后 ptr=0x02", dev:ptr() == 0x02)
local wrap = i2c_read_multi_bytes(fd, 0x19, 4)
check("读越过 0x19 回 0x00/0x01/0x02",
	wrap[1] == 0x22 and wrap[2] == 0x33 and wrap[3] == 0x44 and wrap[4] == 0x00,
	table.concat(wrap, ","))

-- charge_msb_clobbered 协议事实：3 字节帧经指针自增踩 CHG_MSB（模型忠实落位）
section()
dev:set_charge_raw(0xBEEF)
check("哨兵场景写 ACK", dev.write({ 0x01, 0x00, 0xF0 }) == true)
check("3B 帧 CONTROL=0x00（休眠）", dev:control() == 0x00)
check("3B 帧 CHG_MSB=0xF0（电荷被毁）", dev:reg(0x02) == 0xF0,
	string.format("%X", dev:reg(0x02)))
check("3B 帧 CHG_LSB 仍 0xEF", dev:reg(0x03) == 0xEF)
section()
dev:set_charge_raw(0xBEEF)
check("正确 2B 帧写 ACK", dev.write({ 0x01, 0xF0 }) == true)
check("正确帧 CONTROL=0xF0", dev:control() == 0xF0)
check("正确帧电荷保持 0xBEEF", dev:charge_raw() == 0xBEEF,
	string.format("%X", dev:charge_raw()))

-- 坏帧 NACK、状态不动、不留痕
m = section()
check("非 table=false", dev.write(0x01) == false)
check("空表=false", dev.write({}) == false)
check("非字节 256 整笔 NACK", dev.write({ 0x01, 256 }) == false)
check("非字节 -1 整笔 NACK", i2c_write_multi(fd, 0x01, -1) == -1)
check("坏帧后 CONTROL 仍 POR 0", dev:control() == 0)
-- 模型侧整笔拒收：write_count 不增；但主机发起的尝试仍照实记 txlog（1 笔 HAL 写）
check("坏帧模型侧不留痕", dev:write_count() == 0)
check("坏帧尝试仍上总线留痕（NACK）", nwr(m) == 1, tostring(nwr(m)))
check("read(0) 钳 1B", #dev.read(0) == 1)
check("read(99) 钳 16B", #dev.read(99) == 16)
check("read(非数) 钳 1B", #dev.read("x") == 1)

-- 物理量逆注入：与独立正算公式闭环（容差 ±1.5 code）
local function roundtrip_v(x)
	section()
	dev:set_voltage_v(x)
	local raw = dev:voltage_raw()
	check(string.format("V 逆注入 %.3f → raw≈%.1f", x, x / 70.8 * 65535),
		math.abs(raw - math.floor(x / 70.8 * 65535 + 0.5)) <= 1, tostring(raw))
	check(string.format("V 正算回闭环 %.3f", x), near(ref_v(raw), x, 70.8 / 65535 * 1.5))
end
local function roundtrip_t(x)
	section()
	dev:set_temp_c(x)
	local raw = dev:temp_raw()
	check(string.format("T 逆注入 %.2f → raw≈%.1f", x, (x + 273.15) / 510 * 65535),
		math.abs(raw - math.floor((x + 273.15) / 510 * 65535 + 0.5)) <= 1, tostring(raw))
	check(string.format("T 正算回闭环 %.2f", x), near(ref_t(raw), x, 510 / 65535 * 1.5))
end
for _, x in ipairs({ 0, 70.8, 12, 35.4, 11.6, 12.4 }) do roundtrip_v(x) end
for _, x in ipairs({ -273.15, 236.85, 25, 30, 35 }) do roundtrip_t(x) end

section()
for _, a in ipairs({ -1.28, -0.64, 0, 0.64, 1.28 }) do
	dev:set_current_a(a, 0.05)
	local raw = dev:current_raw()
	check(string.format("I 逆注入 %.2fA 闭环", a), near(ref_i(raw, 0.05), a, 0.064 / 0.05 / 32767 * 1.5),
		tostring(raw))
end
-- rsense 0.01 量程 ±6.4A
dev:set_current_a(6.4, 0.01)
check("I 6.4A@10mΩ raw≈满码", dev:current_raw() >= 65534, tostring(dev:current_raw()))
dev:set_current_a(-6.4, 0.01)
check("I -6.4A@10mΩ raw≈0", dev:current_raw() <= 1, tostring(dev:current_raw()))
-- 电荷 mAh 逆注入（M=4096/50mΩ 与 M=1 两档）
section()
dev:set_charge_mah(0.34, 4096, 0.05)
check("0.34mAh@M4096 → code≈1000", math.abs(dev:charge_raw() - 1000) <= 1,
	tostring(dev:charge_raw()))
dev:set_charge_mah(ref_q(65535, 1, 0.05), 1, 0.05)
check("满码 mAh@M1 → code≈65535", math.abs(dev:charge_raw() - 65535) <= 1,
	tostring(dev:charge_raw()))
-- 钳制
dev:set_voltage_v(999); check("V 钳 65535", dev:voltage_raw() == 65535)
dev:set_voltage_v(-1); check("V 钳 0", dev:voltage_raw() == 0)
dev:set_current_a(999); check("I 钳 65535", dev:current_raw() == 65535)
dev:set_current_a(-999); check("I 钳 0", dev:current_raw() == 0)
dev:set_temp_c(999); check("T 钳 65535", dev:temp_raw() == 65535)

-- virt_tick：32 拍确定性正弦 + 电荷爬坡
section()
local function tick_codes(n)
	dev:virt_tick(n)
	return dev:voltage_raw(), dev:current_raw(), dev:temp_raw(), dev:charge_raw()
end
local v0, i0, t0, q0 = tick_codes(0)
check("tick0 V raw=11108（12V）", v0 == 11108, tostring(v0))
check("tick0 I raw=53246（0.8A）", i0 == 53246, tostring(i0))
check("tick0 T raw=38955（30°C）", t0 == 38955, tostring(t0))
check("tick0 charge=10000", q0 == 10000, tostring(q0))
local v8, i8, _, q8 = tick_codes(8)
check("tick8 V=12.4V raw 11478", v8 == 11478, tostring(v8))
check("tick8 I=1.2A 峰 raw 63486（不削顶）", i8 == 63486, tostring(i8))
check("tick8 charge=11600", q8 == 11600, tostring(q8))
local v24, i24, t24 = tick_codes(24)
check("tick24 V=11.6V raw 10737", v24 == 10737, tostring(v24))
check("tick24 I=0.4A raw 43007", i24 == 43007, tostring(i24))
check("tick24 T=25°C raw 38312", t24 == 38312, tostring(t24))
local v32, _, _, q32 = tick_codes(32)
check("tick32 与 tick0 同相", v32 == v0, tostring(v32))
check("tick32 charge=16400", q32 == 16400, tostring(q32))
local prev
for n = 0, 31 do
	local _, _, _, q = tick_codes(n)
	if prev then check(string.format("charge 单调 n=%d", n), q > prev, tostring(q)) end
	prev = q
end

-- 故障钩子：谓词 + nack 三件
m = section()
dev:fail_write(function(b) return b[1] == 0x01 and #b == 2 and b[2] == 0xF0 end)
check("写谓词拦 {01,F0}", i2c_write_reg(fd, 0x01, 0xF0) == false)
check("{01,C0} 放行", i2c_write_reg(fd, 0x01, 0xC0) == true)
dev:clear_faults()
dev:fail_read(function(p) return p == 0x02 end)
check("读谓词拦指针 0x02", i2c_read_multi(fd, 0x02, 2) == -1)
check("读 NACK 指针不前进", dev:ptr() == 0x02, string.format("%X", dev:ptr()))
check("换指针 0x08 放行", i2c_read_multi(fd, 0x08, 2) >= 0)
dev:clear_faults()
dev.nack_write = true
check("nack_write 写全拦（含指针写）", i2c_write_reg(fd, 0x01, 0xF0) == false)
check("nack_write 指针读也失败", i2c_read_multi(fd, 0x08, 2) == -1)
dev.nack_write = false
dev.nack_read = true
check("nack_read 读全拦", i2c_read_multi(fd, 0x08, 2) == -1)
dev.nack_read = false
dev.nack = true
check("nack 双向全拦", i2c_write_reg(fd, 0x01, 0xF0) == false and i2c_read_multi(fd, 0x08, 2) == -1)
dev:clear_faults()

-- reset：回 POR/清留痕但保留钩子；reset_logs 只清计数
m = section()
i2c_write_reg(fd, 0x01, 0xD0)
dev.nack = true
dev:reset()
check("reset 后 CONTROL 回 0", dev:control() == 0)
check("reset ptr 归零", dev:ptr() == 0)
check("reset 清留痕", dev:write_count() == 0)
check("reset 保留 nack 钩子", dev.nack == true)
dev:clear_faults()
i2c_write_reg(fd, 0x01, 0xD0)
dev:reset_logs()
check("reset_logs 清计数", dev:write_count() == 0)
check("reset_logs 不动 CONTROL 0xD0", dev:control() == 0xD0,
	string.format("%X", dev:control()))

-- 种子构造
local d2 = smod.new({ status = 0x0F, control = 0xF0, charge = 100, voltage = 200,
	current = 0x7FFF, temp = 400 })
check("种子 status/control", d2:status() == 0x0F and d2:control() == 0xF0)
check("种子四 u16", d2:charge_raw() == 100 and d2:voltage_raw() == 200
	and d2:current_raw() == 0x7FFF and d2:temp_raw() == 400)
local d3 = smod.new({ control = 300, charge = "x", temp = -1, current = 70000 })
check("坏种子回 POR", d3:control() == 0 and d3:charge_raw() == 0
	and d3:temp_raw() == 0 and d3:current_raw() == 0)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
local function build_ok(opts)
	opts = opts or {}
	opts.fd = fd
	if opts.address == nil then opts.address = "0x64" end
	local r = build(opts)
	check("build OK", r.result == "OK", tostring(r.message))
	return r
end

-- 默认 build：set → 指针读 STATUS(00,2B) → {01,F0} CONTROL 写；零睡眠
local bk = section()
dev:set_charge_raw(0xABCD)	-- 哨兵预置：build 不得踩电荷
build_ok()
do
	local es = entries(bk)
	check("build 4 条事务（set/w/r/w）", #es == 4, tostring(#es))
	check("事务序 set→w→r→w",
		es[1].dir == "set" and es[2].dir == "w" and es[3].dir == "r" and es[4].dir == "w",
		table.concat((function()
			local s = {}
			for _, e in ipairs(es) do s[#s + 1] = e.dir end
			return s
		end)(), ","))
	check("set 地址 0x64", set_addrs(bk)[1] == 0x64, tostring(set_addrs(bk)[1]))
	local ws = writes(bk)
	check("两笔写：指针 {00} + 控制 {01,F0}",
		#ws == 2 and ws[1][1] == 0x00 and #ws[1] == 1 and ws[2][1] == 0x01 and ws[2][2] == 0xF0,
		string.format("%d 笔", #ws))
	check("在位甄别读 n=2", read_sizes(bk)[1] == 2)
	check("CONTROL=0xF0（自动 + M4096 码 6）", dev:control() == 0xF0,
		string.format("%X", dev:control()))
	check("build 零睡眠", sleep_total == 0, tostring(sleep_total))
	-- charge_msb_clobbered 哨兵：电荷保持 + 无首址 0x01 的 ≥3 字节帧
	check("电荷 0xABCD 未被 build 踩", dev:charge_raw() == 0xABCD,
		string.format("%X", dev:charge_raw()))
	local bad
	for _, f in ipairs(ws) do if f[1] == 0x01 and #f > 2 then bad = true end end
	check("无越界 CONTROL 多字节帧", not bad)
end

-- 字符串 fd
section()
build_ok({ fd = "3" })

-- 七档预分频码 0~6（M = 1/4/16/64/256/1024/4096）
local presc_cases = {
	{ "1", 0xC0 }, { "4", 0xC8 }, { "16", 0xD0 }, { "64", 0xD8 },
	{ "256", 0xE0 }, { "1024", 0xE8 }, { "4096", 0xF0 },
}
for _, c in ipairs(presc_cases) do
	section()
	build_ok({ prescaler = c[1] })
	check(string.format("prescaler=%s → CONTROL=0x%02X", c[1], c[2]),
		dev:control() == c[2], string.format("got %02X", dev:control()))
end
-- 吸附与归一：3→M1 码0、5→M4 码1、1023→M256 码4、1024→M1024 码5、
-- 999999→M4096 码6；"-"/abc/0/负值 → 缺省 M4096
for _, c in ipairs({
	{ "3", 0xC0 }, { "5", 0xC8 }, { "1023", 0xE0 }, { "1024", 0xE8 },
	{ "999999", 0xF0 }, { "-", 0xF0 }, { "abc", 0xF0 }, { "0", 0xF0 }, { "-2", 0xF0 },
}) do
	section()
	build_ok({ prescaler = c[1] })
	check(string.format("prescaler='%s' 吸附/归一 → 0x%02X", c[1], c[2]),
		dev:control() == c[2], string.format("got %02X", dev:control()))
end

-- ---- build 负路径 ----
local bm = section()
expect_err("build 非表", function() return build(7) end, "Invalid Arguments Type")
check("非表零事务", #entries(bm) == 0)

bm = section()
expect_err("build 缺 fd", function() return build({ address = "0x64" }) end, "fd or address")
check("缺 fd 零事务", #entries(bm) == 0)

bm = section()
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("缺 address 零事务", #entries(bm) == 0)

bm = section()
expect_err("build set_addr 失败（fd=99）",
	function() return build({ fd = 99, address = "0x64" }) end, "set_addr failed")

-- 固定地址：0x65 无挂载 → 指针读失败
bm = section()
expect_err("build 错地址 0x65 读失败",
	function() return build({ fd = fd, address = "0x65" }) end, "Failed to read LTC2944 status")

-- STATUS 读 NACK：set + 指针写 + 失败读，无 CONTROL 写
bm = section()
dev.nack_read = true
expect_err("build STATUS 读无应答",
	function() return build({ fd = fd, address = "0x64" }) end, "Failed to read LTC2944 status")
check("读 NACK：1 set + 1 写(指针) + 1 读、0 控制写",
	#set_addrs(bm) == 1 and nwr(bm) == 1 and nrd(bm) == 1,
	string.format("set=%d w=%d r=%d", #set_addrs(bm), nwr(bm), nrd(bm)))
dev:clear_faults()

-- CONTROL 写 NACK：精确谓词只拦 {01,F0}，STATUS 读照常
bm = section()
dev:fail_write(function(b) return b[1] == 0x01 and #b == 2 and b[2] == 0xF0 end)
expect_err("build CONTROL 写无应答",
	function() return build({ fd = fd, address = "0x64" }) end, "Failed to write LTC2944 control")
check("写 NACK：set + 指针写 + 读 + 失败控制写（共 4 事务）",
	#entries(bm) == 4 and #set_addrs(bm) == 1 and nwr(bm) == 2 and nrd(bm) == 1,
	tostring(#entries(bm)))
check("CONTROL 未被改写（POR 0）", dev:control() == 0, string.format("%X", dev:control()))
dev:clear_faults()

-- nack_write 会连 STATUS 指针写一起拦 → 在位甄别阶段失败
bm = section()
dev.nack_write = true
expect_err("nack_write 拦在 STATUS 指针写",
	function() return build({ fd = fd, address = "0x64" }) end, "Failed to read LTC2944 status")
check("无读事务（指针写即败）", nrd(bm) == 0 and nwr(bm) == 1,
	string.format("w=%d r=%d", nwr(bm), nrd(bm)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 未 build 先 call：重载驱动块重建模块级 rsense/presc（nil 态）
vbus.load_driver("modules/LTC2944.lua")
local cm0 = window()
expect_err("call 未 build 先调",
	function() return call({ fd = fd, address = "0x64" }) end, "not initialized")
-- set_addr 在未 build 守卫之前：仅 1 条 set，无指针写/读
check("未 build 仅 1 条 set 事务", #entries(cm0) == 1
	and entries(cm0)[1].dir == "set", tostring(#entries(cm0)))

section()
build_ok()

-- 标准换算点：chg=1000/V=32768/I=中点/T=32768（rsense 0.05、M4096）
dev:set_charge_raw(1000)
dev:set_voltage_raw(32768)
dev:set_current_raw(0x7FFF)
dev:set_temp_raw(32768)
local ck = window()
local r = expect_ok("call 标准换算点", function() return call({ fd = fd, address = "0x64" }) end)
if r then
	check("CHARGE=0.34 mAh", near(r.CHARGE, ref_q(1000, 4096, 0.05)), tostring(r.CHARGE))
	check("V=32768/65535*70.8", near(r.V, ref_v(32768)), tostring(r.V))
	check("I=0A（中点）", near(r.I, 0), tostring(r.I))
	check("T=32768 码换算", near(r.T, ref_t(32768)), tostring(r.T))
end
do
	local es = entries(ck)
	check("call 9 条事务（set + 4×指针写/读）", #es == 9, tostring(#es))
	check("set 1 次", #set_addrs(ck) == 1)
	check("4 指针写 + 4 读", nwr(ck) == 4 and nrd(ck) == 4,
		string.format("%d/%d", nwr(ck), nrd(ck)))
	local ptrs = {}
	for _, f in ipairs(writes(ck)) do ptrs[#ptrs + 1] = f[1] end
	check("指针序 02→08→0E→14",
		ptrs[1] == 0x02 and ptrs[2] == 0x08 and ptrs[3] == 0x0E and ptrs[4] == 0x14,
		table.concat(ptrs, ","))
	check("指针写均 1 字节", writes(ck)[1][1] == 0x02 and #writes(ck)[1] == 1
		and #writes(ck)[4] == 1)
	check("四读均 n=2", read_sizes(ck)[1] == 2 and read_sizes(ck)[4] == 2)
	check("call 零睡眠", sleep_total == 0, tostring(sleep_total))
end

-- 满量程端点：全 0 / 全 0xFFFF
for _, code in ipairs({ 0, 65535 }) do
	section()
	build_ok()
	dev:set_charge_raw(code)
	dev:set_voltage_raw(code)
	dev:set_current_raw(code)
	dev:set_temp_raw(code)
	r = expect_ok(string.format("call 全 %d 端点", code),
		function() return call({ fd = fd, address = "0x64" }) end)
	if r then
		check(string.format("CHARGE(%d)=%.6f", code, ref_q(code, 4096, 0.05)),
			near(r.CHARGE, ref_q(code, 4096, 0.05)), tostring(r.CHARGE))
		check(string.format("V(%d)=%.6f", code, ref_v(code)), near(r.V, ref_v(code)), tostring(r.V))
		check(string.format("I(%d)=%.6f", code, ref_i(code, 0.05)),
			near(r.I, ref_i(code, 0.05), 1e-12), tostring(r.I))
		check(string.format("T(%d)=%.6f", code, ref_t(code)), near(r.T, ref_t(code)), tostring(r.T))
	end
end
-- 满码电荷恰为 22.2819mAh（头部注释约 22.3mAh@M4096/50mΩ）
check("满码电荷 22.2819 mAh", near(ref_q(65535, 4096, 0.05), 22.2819, 1e-6))

-- M=1：电荷 LSB 缩 4096 倍
section()
build_ok({ prescaler = "1" })
dev:set_charge_raw(65535)
r = expect_ok("call M=1 满码电荷", function() return call({ fd = fd, address = "0x64" }) end)
if r then
	check("M=1 满码电荷≈0.00544 mAh", near(r.CHARGE, ref_q(65535, 1, 0.05), 1e-9),
		tostring(r.CHARGE))
end

-- rsense=0.01：电流量程 ±6.4A、电荷 LSB 放大 5 倍
section()
build_ok({ rsense = "0.01", prescaler = "4096" })
dev:set_current_raw(65535)
dev:set_charge_raw(1000)
r = expect_ok("call rsense=0.01", function() return call({ fd = fd, address = "0x64" }) end)
if r then
	check("I≈+6.4002A@10mΩ", near(r.I, ref_i(65535, 0.01), 1e-9), tostring(r.I))
	check("CHARGE=1.7 mAh@10mΩ", near(r.CHARGE, ref_q(1000, 4096, 0.01)), tostring(r.CHARGE))
end
-- rsense 归一："-"/"0"/负值 → 0.05（中点电流仍 0A）
for _, tok in ipairs({ "-", "0", "-0.1", "abc" }) do
	section()
	build_ok({ rsense = tok })
	dev:set_current_raw(0x7FFF)
	r = call({ fd = fd, address = "0x64" })
	check(string.format("rsense='%s' 归一中点 0A", tok), r.result == "OK" and near(r.I, 0),
		tostring(r.I))
end

-- virt_tick 闭环：守护姿势（每拍 tick 后 call），物理量随正弦、电荷单调
section()
build_ok()
local prev_q
for n = 0, 7 do
	dev:virt_tick(n)
	local rr = call({ fd = fd, address = "0x64" })
	local s = math.sin(2 * math.pi * n / 32)
	check(string.format("tick%d 四字段 OK", n), rr.result == "OK", tostring(rr.message))
	check(string.format("tick%d V≈%.2f", n, 12 + 0.4 * s),
		near(rr.V, 12 + 0.4 * s, 70.8 / 65535 * 1.5), tostring(rr.V))
	check(string.format("tick%d I≈%.2f", n, 0.8 + 0.4 * s),
		near(rr.I, 0.8 + 0.4 * s, 0.064 / 0.05 / 32767 * 1.5), tostring(rr.I))
	check(string.format("tick%d T≈%.1f", n, 30 + 5 * s),
		near(rr.T, 30 + 5 * s, 510 / 65535 * 1.5), tostring(rr.T))
	check(string.format("tick%d CHARGE≈%.6f", n, ref_q(10000 + 200 * n, 4096, 0.05)),
		near(rr.CHARGE, ref_q(10000 + 200 * n, 4096, 0.05)), tostring(rr.CHARGE))
	if prev_q then check(string.format("tick%d 电荷递增", n), rr.CHARGE > prev_q) end
	prev_q = rr.CHARGE
end

-- ---- call 负路径 ----
section()
build_ok()
expect_err("call 非表", function() return call(7) end, "Invalid Arguments")
cm0 = window()
check("非表零事务", #entries(cm0) == 0)

cm0 = section()
expect_err("call 缺 fd", function() return call({ address = "0x64" }) end, "fd or address")
check("缺 fd 零事务", #entries(cm0) == 0)

cm0 = section()
expect_err("call set_addr 失败",
	function() return call({ fd = 99, address = "0x64" }) end, "set_addr failed")

-- 四路读失败精确短路（谓词按读起始指针）
local fail_cases = {
	{ 0x02, "Failed to read LTC2944 charge", "电荷", 3 },
	{ 0x08, "Failed to read LTC2944 voltage", "电压", 5 },
	{ 0x0E, "Failed to read LTC2944 current", "电流", 7 },
	{ 0x14, "Failed to read LTC2944 temperature", "温度", 9 },
}
for _, fc in ipairs(fail_cases) do
	section()
	build_ok()
	dev:fail_read(function(p) return p == fc[1] end)
	local cm = window()
	expect_err(string.format("call %s读失败短路", fc[3]),
		function() return call({ fd = fd, address = "0x64" }) end, fc[2])
	check(string.format("%s失败共 %d 事务（set 在内）", fc[3], fc[4]),
		#entries(cm) == fc[4], tostring(#entries(cm)))
	dev:clear_faults()
end

-- 失败后下一拍恢复
section()
build_ok()
dev:set_voltage_raw(32768)
r = expect_ok("故障解除后 call 恢复", function() return call({ fd = fd, address = "0x64" }) end)
if r then check("恢复后 V 正确", near(r.V, ref_v(32768)), tostring(r.V)) end

-- nack_read：首个电荷读即败
section()
build_ok()
dev.nack_read = true
local cm = window()
expect_err("call nack_read 电荷失败",
	function() return call({ fd = fd, address = "0x64" }) end, "Failed to read LTC2944 charge")
check("nack_read 3 事务", #entries(cm) == 3, tostring(#entries(cm)))
dev:clear_faults()

-- nack_write：指针写失败同样表现为读失败
section()
build_ok()
dev.nack_write = true
cm = window()
expect_err("call nack_write 指针失败",
	function() return call({ fd = fd, address = "0x64" }) end, "Failed to read LTC2944 charge")
check("nack_write：指针写 1 读 0", nwr(cm) == 1 and nrd(cm) == 0,
	string.format("w=%d r=%d", nwr(cm), nrd(cm)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无关停寄存器，零总线事务）
-- =====================================================================
section()
build_ok()
local dk = window()
expect_ok("destroy OK", function() return destroy({ fd = fd, address = "0x64" }) end)
check("destroy 零总线事务", #entries(dk) == 0)

section()
expect_ok("destroy 空表也 OK", function() return destroy({}) end)
check("空表零事务", #entries(section()) == 0)

section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("destroy 非表零事务", #entries(section()) == 0)

tester.summary("test_ltc2944")

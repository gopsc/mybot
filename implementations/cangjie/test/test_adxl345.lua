-- test_adxl345.lua —— ADXL345 真实驱动 + 虚拟 I2C 总线 + 小端 regmap 模型
-- 用法（项目根目录）: luajit test/test_adxl345.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：ADXL_GC=1 luajit test/test_adxl345.lua
--
-- 从「dofile 驱动后覆盖 i2c_* 全局的 176 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/adxl345.lua 模型」。ADXL345 是【8 位寄存器指针 +
-- 6 字节小端 burst + FULL_RES 恒定灵敏度 IMU】（regmap 包装族，与 MPU6050
-- 大端模型成对侧）：
--   0x00 DEVID 只读 0xE5；0x2C BW_RATE POR 0x0A（100Hz）；0x2D POWER_CTL；
--   0x31 DATA_FORMAT build 先读回再 RMW（保高 4 位置 FULL_RES|量程码）；
--   0x32~0x37 三轴小端补码（X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,Z_MSB）。
--
-- 覆盖：模型侧 POR/小端编解码独立交叉/6B burst 字节序与指针自增/只读区写
-- ACK 丢弃（DEVID/数据区）/纯指针任意地址 ACK/配置口照存/坏帧 NACK 不动指针/
-- 未播种读 0/位域观察口（量程/FULL_RES/ODR 高性能与低功耗档/Measure）/s16
-- 钳制与 256 LSB/g 量化/virt_tick 32 拍三轴正弦（含 Z 轴 1g 偏置）/六类钩子/
-- reset 留钩保身份；真实 build 8 txlog（set+2×(w指针+r)+3×w2B）、22ms 等待、
-- RMW 保高位、range 向下降档 11 例、odr 最近取档平手取低 14 例、备地址 0x1D/
-- 字符串 fd/DEVID 不符与读失败/DF 读+写/BW/POWER 写失败精确短路与错误文案；
-- 真实 call 3 txlog（set+w32+r6）零睡眠、小端拼字正负零极值无符号返回（sign
-- 归守护）、连续三拍不串、virt_tick 闭环、无 build 守卫裸 call；destroy 零事务。

if os.getenv("ADXL_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local amod = dofile("modules/lib/virtbus/adxl345.lua")
vbus.reset()

local ADDR = 0x53
local dev = amod.new()
vbus.attach("ADXL345@0x53", ADDR, dev)
vbus.attach("ADXL345@0x1D", 0x1D, dev)	-- 同一模型挂备地址
vbus.load_driver("modules/ADXL345.lua")

-- milli_sleep：本器件无虚拟时钟，桩只累计（build 等两个测量周期可断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 有符号 s16 → 驱动口径的无符号原始码（负值由守护 sign='16' 展开）
local function u16(v) return v < 0 and v + 65536 or v end

-- 每个 section：器件回 POR + 故障解除 + who 身份显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0xE5)
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
-- 窗口内纯指针写（1 字节）地址序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
-- 窗口内寄存器写（2 字节 {reg,val}）
local function data_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 2 then t[#t + 1] = { reg = b[1], val = b[2] } end
	end
	return t
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("POR DEVID=0xE5", dev:devid() == 0xE5, string.format("0x%02X", dev:devid()))
check("POR BW_RATE=0x0A（100Hz）", dev:bw() == 0x0A, string.format("0x%02X", dev:bw()))
check("POR DATA_FORMAT=0x00", dev:df() == 0, string.format("0x%02X", dev:df()))
check("POR POWER_CTL=0x00（待机）", dev:power() == 0, string.format("0x%02X", dev:power()))
check("POR 数据区三轴全 0", (function()
	local x, y, z = dev:accel_raw()
	return x == 0 and y == 0 and z == 0
end)(), tostring((function() local x, y, z = dev:accel_raw(); return x .. "," .. y .. "," .. z end)()))
check("POR ptr=0", dev:pointer() == 0, tostring(dev:pointer()))

-- 小端编解码：独立公式交叉（不与驱动共用理解）
local le_cases = {
	{ 0x0000, 0, 0 }, { 0x0001, 1, 0 }, { 0x00FF, 255, 0 },
	{ 0x0100, 0, 1 }, { 0x1234, 0x34, 0x12 }, { 0x7FFF, 0xFF, 0x7F },
	{ 0xFFFF, 0xFF, 0xFF }, { 0x8000, 0x00, 0x80 }, { 0xFC00, 0x00, 0xFC },
}
for _, c in ipairs(le_cases) do
	dev:set_word_le(0x32, c[1])
	check(string.format("小端字 0x%04X 字节 LSB=0x%02X MSB=0x%02X", c[1], c[2], c[3]),
	      dev.regs[0x32] == c[2] and dev.regs[0x33] == c[3],
	      string.format("0x%02X,0x%02X", dev.regs[0x32], dev.regs[0x33]))
end
-- 有符号回读
for _, c in ipairs({ { 0, 0 }, { 1, 1 }, { 256, 256 }, { 32767, 32767 },
                    { 0xFFFF, -1 }, { 0xFF00, -256 }, { 0x8000, -32768 } }) do
	dev:set_word_le(0x34, c[1])
	check(string.format("get_sword_le(0x34) 0x%04X -> %d", c[1], c[2]),
	      dev:get_sword_le(0x34) == c[2], tostring(dev:get_sword_le(0x34)))
end

-- 6B burst：写指针 0x32 后一次读 6 字节，字节流按小端布局，读后指针到 0x38
dev:set_accel_raw(4096, -1, -1024)	-- 0x1000 / 0xFFFF / 0xFC00（旧桩种子）
check("写指针 0x32 ACK", dev.write({ 0x32 }) == true)
local b6 = dev.read(6)
check("burst 6B = 00 10 FF FF 00 FC（X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,Z_MSB）",
      b6 ~= nil and table.concat(b6, ",") == "0,16,255,255,0,252",
      b6 and table.concat(b6, ",") or "nil")
check("burst 后指针自增到 0x38", dev:pointer() == 0x38,
      string.format("0x%02X", dev:pointer()))
-- 指针 0xFF 起读跨边界回绕到 0x00（底座字节地址模 256 语义）
dev.write({ 0xFF })
local bw = dev.read(2)
check("自 0xFF burst 2B 回绕 0xFF→0x00（0xFF 未播种=0、0x00=DEVID E5）",
      bw ~= nil and bw[1] == 0x00 and bw[2] == 0xE5,
      bw and table.concat(bw, ",") or "nil")

-- 只读区：多字节写 ACK 但丢弃（DEVID、数据区 6 字节）
dev:set_accel_raw(4096, -1, -1024)
check("写 DEVID 2B ACK 丢弃",
      dev.write({ 0x00, 0xBE }) == true and dev:devid() == 0xE5,
      string.format("0x%02X", dev:devid()))
check("写 DATAX0 2B ACK 丢弃",
      dev.write({ 0x32, 0xAA, 0xBB }) == true and dev:get_word_le(0x32) == 0x1000,
      string.format("0x%04X", dev:get_word_le(0x32)))
check("写跨数据区 7B 帧 ACK 全丢弃",
      dev.write({ 0x32, 1, 2, 3, 4, 5, 6 }) == true
      and dev:get_word_le(0x32) == 0x1000 and dev:get_word_le(0x36) == 0xFC00,
      string.format("0x%04X 0x%04X", dev:get_word_le(0x32), dev:get_word_le(0x36)))
-- 纯指针写：任意地址（含只读/0xFF）都 ACK 并移动指针
for _, p in ipairs({ 0x00, 0x32, 0x37, 0xFF }) do
	check(string.format("纯指针写 0x%02X ACK 设 ptr", p),
	      dev.write({ p }) == true and dev:pointer() == p,
	      string.format("ptr=0x%02X", dev:pointer()))
end

-- 配置口照存（含高/低 nibble 各种组合，供 RMW 读回）
for _, w in ipairs({ { 0x2C, 0x00 }, { 0x2C, 0x1F }, { 0x2D, 0xFF },
                    { 0x31, 0xF0 }, { 0x31, 0x0F }, { 0x31, 0xAB } }) do
	check(string.format("写 0x%02X<-0x%02X 照存", w[1], w[2]),
	      dev.write({ w[1], w[2] }) == true and dev.regs[w[1]] == w[2],
	      string.format("0x%02X", dev.regs[w[1]]))
end
check("未播种地址读 0（0x10）", (function()
	dev.write({ 0x10 })
	local t = dev.read(1)
	return t ~= nil and t[1] == 0
end)())

-- 坏帧：空表/非 table NACK，且指针不动
dev.write({ 0x34 })
check("空表 NACK", dev.write({}) == false)
check("非 table NACK", dev.write(0x53) == false)
check("坏帧后指针仍 0x34（NACK 不动指针）", dev:pointer() == 0x34,
      string.format("0x%02X", dev:pointer()))

-- 位域观察口
local field_cases = {
	-- df, range_g, range_code, full_res
	{ 0x00, 2, 0, 0 }, { 0x01, 4, 1, 0 }, { 0x09, 4, 1, 1 },
	{ 0x0A, 8, 2, 1 }, { 0x0B, 16, 3, 1 }, { 0xF8, 2, 0, 1 },
}
for _, c in ipairs(field_cases) do
	dev:set(0x31, c[1])
	check(string.format("DATA_FORMAT=0x%02X → ±%dg code=%d FULL_RES=%d（高位不扰低位域）",
	      c[1], c[2], c[3], c[4]),
	      dev:range_g() == c[2] and dev:range_code() == c[3] and dev:full_res() == c[4],
	      string.format("±%s code=%s fr=%s", tostring(dev:range_g()),
	      tostring(dev:range_code()), tostring(dev:full_res())))
end
-- BW_RATE：高性能码 7..F 映射 ODR；低功耗码 0..6 不臆断（odr_hz=nil）；bit4 观察
local odr_field = {
	{ 0x07, 12.5 }, { 0x0A, 100 }, { 0x0F, 3200 },
}
for _, c in ipairs(odr_field) do
	dev:set(0x2C, c[1])
	check(string.format("BW_RATE=0x%02X → odr=%gHz", c[1], c[2]),
	      dev:odr_hz() == c[2] and dev:odr_code() == c[1] and dev:low_power() == 0,
	      string.format("odr=%s", tostring(dev:odr_hz())))
end
dev:set(0x2C, 0x19)	-- bit4=低功耗 + 码 9
check("BW_RATE=0x19 low_power=1（低 4 位码 9 仍按高性能档映射 50Hz）",
      dev:low_power() == 1 and dev:odr_hz() == 50,
      string.format("lp=%s odr=%s", tostring(dev:low_power()), tostring(dev:odr_hz())))
for _, c in ipairs({ 0x00, 0x06 }) do
	dev:set(0x2C, c)
	check(string.format("BW_RATE=0x%02X 低功耗档 odr_hz=nil（模型不臆断频率）", c),
	      dev:odr_hz() == nil, tostring(dev:odr_hz()))
end
dev:set(0x2D, 0x08)
check("POWER_CTL=0x08 measure=1", dev:measure() == 1 and dev:power() == 0x08)
dev:set(0x2D, 0x00)
check("POWER_CTL=0x00 measure=0", dev:measure() == 0)

-- s16 钳制 / 256 LSB/g 量化
dev:set_accel_raw(999999, -999999, 32767)
check("set_accel_raw 钳 ±32768（32767,-32768,32767）",
      (function() local x, y, z = dev:accel_raw()
	return x == 32767 and y == -32768 and z == 32767 end)())
local g_cases = {
	{ 0.30, 77 }, { -0.15, -38 }, { 1.0, 256 }, { 16.0, 4096 },
	{ -16.0, -4096 }, { 0.001, 0 }, { 128.0, 32767 }, { -128.0, -32768 },
}
for _, c in ipairs(g_cases) do
	dev:set_accel_g(c[1], nil, nil)
	check(string.format("set_accel_g(%g) → 码 %d（256 LSB/g 最近码）", c[1], c[2]),
	      dev:accel_raw() == c[2], tostring(dev:accel_raw()))
end
local gx, gy, gz = dev:set_accel_g(0.3, -0.15, 1):accel_g()
check("accel_g() 物理量回读 0.30/-0.15/1.0 g（3.9mg/LSB 量化粒度内）",
      near(gx, 0.3, 0.004) and near(gy, -0.15, 0.004) and near(gz, 1.0, 0.004),
      string.format("%g,%g,%g", gx, gy, gz))

-- virt_tick：32 拍确定性三轴正弦
local tick_exp = {
	[0]  = { 0, 67, 245 },
	[8]  = { 77, -38, 250 },
	[24] = { -77, 38, 262 },
}
for n, e in pairs(tick_exp) do
	dev:virt_tick(n)
	local x, y, z = dev:accel_raw()
	check(string.format("virt_tick(%d) X=%d Y=%d Z=%d", n, e[1], e[2], e[3]),
	      x == e[1] and y == e[2] and z == e[3],
	      string.format("%d,%d,%d", x, y, z))
end
dev:virt_tick(0)
local x0, y0, z0 = dev:accel_raw()
dev:virt_tick(32)
check("virt_tick(32) 回周期 = tick(0)",
      (function() local x, y, z = dev:accel_raw()
	return x == x0 and y == y0 and z == z0 end)())
-- 确定性：两独立实例同拍逐字段全等
local a, bb = amod.new(), amod.new()
a:virt_tick(11); bb:virt_tick(11)
local det = true
for _, r in ipairs({ 0x32, 0x34, 0x36 }) do
	if a:get_sword_le(r) ~= bb:get_sword_le(r) then det = false end
end
check("virt_tick 确定性（同 n 两实例三轴全等）", det)
-- 扫 0..60 拍：推进性 + 幅值有界（X/Y ±77 码、Z 243~269 恒正）
dev:virt_tick(0)
local first_x = dev:accel_raw()
local moved, bounded = false, true
for n = 1, 60 do
	dev:virt_tick(n)
	local x, y, z = dev:accel_raw()
	if x ~= first_x then moved = true end
	if math.abs(x) > 77 or math.abs(y) > 77 then bounded = false end
	if z < 243 or z > 269 then bounded = false end
end
check("virt_tick 随 n 推进（60 拍内 X 离开过初值）", moved)
check("virt_tick 幅值有界（|X/Y|≤77、Z∈[243,269] 恒正）", bounded)
check("virt_tick 返回模型自身（链式）", amod.new():virt_tick(3) ~= nil)

-- 六类故障钩子
mark = section()
dev.nack = true
check("nack=true 写读全拦", dev.write({ 0x2C }) == false and dev.read(1) == nil)
dev:clear_faults()
check("clear_faults 后恢复", dev.write({ 0x2C }) == true and dev.read(1) ~= nil)
dev.nack_write = true
check("nack_write 只拦写", dev.write({ 0x2C, 0x0A }) == false)
dev:clear_faults()
dev.nack_read = true
check("nack_read 只拦读（写仍 ACK）",
      dev.write({ 0x2C, 0x0A }) == true and dev.read(1) == nil)
dev:clear_faults()
dev:fail_write(function(b) return b[1] == 0x31 and #b == 2 end)
check("fail_write 谓词拦 DATA_FORMAT 2B 写、不拦 1B 指针",
      dev.write({ 0x31 }) == true and dev.write({ 0x31, 0x0A }) == false)
dev:clear_faults()
dev:fail_read(function(p, n) return p == 0x32 and n == 6 end)
check("fail_read 谓词按 (ptr,n) 拦 0x32/6B、不拦 DEVID 1B",
      (function() dev.write({ 0x00 }); return dev.read(1) end)() ~= nil
      and (function() dev.write({ 0x32 }); return dev.read(6) end)() == nil)
dev:clear_faults()

-- config_writes/write_count/reset_logs/pointer
section()
dev.write({ 0x32 })				-- 1B 读指针不计
dev.write({ 0x31, 0x0A })
dev.write({ 0x2C, 0x0A })
dev.write({ 0x2D, 0x08 })
local cw = dev:config_writes()
check("config_writes 收 3 笔 2B 配置写（不含 1B 指针/只读丢弃帧）",
      #cw == 3 and cw[1].reg == 0x31 and cw[1].val == 0x0A
      and cw[2].reg == 0x2C and cw[3].reg == 0x2D,
      tostring(#cw))
check("write_count=3", dev:write_count() == 3, tostring(dev:write_count()))
-- regmap 语义：多字节写不移动读指针，仅 1B 纯指针写设 ptr（故仍停在 0x32）
check("末笔多字节写后读指针仍停在 0x32（仅纯指针写移动 ptr）",
      dev:pointer() == 0x32, string.format("0x%02X", dev:pointer()))
dev:reset_logs()
check("reset_logs 清空留痕", #dev.write_log == 0 and #dev:config_writes() == 0)
-- reset：回 POR、ptr/留痕清零；故障钩子与 who 身份保留
section()
dev:set(0x31, 0xAB)
dev:who(0xE7)
dev.nack_read = true
dev:reset()
check("reset 后 DATA_FORMAT 回 0", dev:df() == 0, string.format("0x%02X", dev:df()))
check("reset 后 ptr=0 / 留痕空", dev:pointer() == 0 and #dev.write_log == 0)
check("reset 不清故障钩子（nack_read 仍在）", dev.nack_read == true)
check("reset 保留 who 身份 0xE7", dev:devid() == 0xE7,
      string.format("0x%02X", dev:devid()))
dev:clear_faults()

-- =====================================================================
-- 组 2：真实 build（set + 2×(w指针+r) + 3×w2B = 8 txlog，22ms 等待）
-- =====================================================================
mark = section()
expect_ok("build 默认（±8g / 100Hz）", function()
	return build({ fd = fd, address = "0x53" })
end)
check("build 一次 set_addr 0x53",
      #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x53,
      table.concat(set_addrs(mark), ","))
local pw = ptr_writes(mark)
check("build 两笔纯指针写 0x00(DEVID)、0x31(DATA_FORMAT)",
      #pw == 2 and pw[1] == 0x00 and pw[2] == 0x31, table.concat(pw, ","))
check("build 两次 1B 读（DEVID、DATA_FORMAT RMW 读回）",
      #reads(mark) == 2, tostring(#reads(mark)))
local dw = data_writes(mark)
check("build 三笔寄存器写顺序 0x31/0x2C/0x2D",
      #dw == 3 and dw[1].reg == 0x31 and dw[2].reg == 0x2C and dw[3].reg == 0x2D,
      tostring(#dw))
check("build DATA_FORMAT=0x0A（POR df=0 | FULL_RES | ±8g code2）",
      dw[1].val == 0x0A, string.format("0x%02X", dw[1].val))
check("build BW_RATE=0x0A（100Hz）", dw[2].val == 0x0A,
      string.format("0x%02X", dw[2].val))
check("build POWER_CTL=0x08（Measure）", dw[3].val == 0x08,
      string.format("0x%02X", dw[3].val))
check("build 共 8 txlog", #entries(mark) == 8, tostring(#entries(mark)))
check("build 后芯片态 FULL_RES=1/±8g/100Hz/Measure=1",
      dev:full_res() == 1 and dev:range_g() == 8 and dev:odr_hz() == 100
      and dev:measure() == 1)
check("build 等待两个测量周期 22ms（ceil(2000/100)+2）",
      sleep_total == 22, tostring(sleep_total))

-- RMW：DATA_FORMAT 保高 4 位
for _, c in ipairs({ { 0xF0, 0xFA }, { 0x50, 0x5A }, { 0x0F, 0x0A } }) do
	local m0 = section()
	dev:set(0x31, c[1])
	local r = build({ fd = fd, address = "0x53" })
	local w31
	for _, w in ipairs(data_writes(m0)) do if w.reg == 0x31 then w31 = w.val end end
	check(string.format("RMW DATA_FORMAT 预置 0x%02X → 写 0x%02X（保高 4 位）", c[1], c[2]),
	      r.result == "OK" and dev:df() == c[2] and w31 == c[2],
	      string.format("df=0x%02X w31=%s", dev:df(), tostring(w31)))
end

-- range 向下降档（非法/非正归缺省 ±8g）
local range_cases = {
	{ "-", 8, 0x0A }, { "2", 2, 0x08 }, { "4", 4, 0x09 }, { "8", 8, 0x0A },
	{ "16", 16, 0x0B }, { "3", 2, 0x08 }, { "7.9", 4, 0x09 },
	{ "600", 16, 0x0B }, { "abc", 8, 0x0A }, { "0", 8, 0x0A },
	{ "-5", 8, 0x0A },
}
for _, c in ipairs(range_cases) do
	local m0 = section()
	local r = build({ fd = fd, address = "0x53", range = c[1], odr = "-" })
	local w31
	for _, w in ipairs(data_writes(m0)) do if w.reg == 0x31 then w31 = w.val end end
	check(string.format("range=%s 向下降档 → ±%dg DATA_FORMAT=0x%02X",
	      tostring(c[1]), c[2], c[3]),
	      r.result == "OK" and w31 == c[3] and dev:range_g() == c[2],
	      string.format("got 0x%02X ±%s", tonumber(w31) or -1, tostring(dev:range_g())))
end

-- odr 最近取档（平手取低）+ 睡眠预算 ceil(2000/odr)+2
local odr_cases = {
	{ "-", 0x0A, 22 }, { "12.5", 0x07, 162 }, { "25", 0x08, 82 },
	{ "50", 0x09, 42 }, { "100", 0x0A, 22 }, { "200", 0x0B, 12 },
	{ "400", 0x0C, 7 }, { "800", 0x0D, 5 }, { "1600", 0x0E, 4 },
	{ "3200", 0x0F, 3 }, { "75", 0x09, 42 }, { "150", 0x0A, 22 },
	{ "5000", 0x0F, 3 }, { "1", 0x07, 162 },
}
for _, c in ipairs(odr_cases) do
	local m0 = section()
	local r = build({ fd = fd, address = "0x53", range = "-", odr = c[1] })
	local w2c
	for _, w in ipairs(data_writes(m0)) do if w.reg == 0x2C then w2c = w.val end end
	check(string.format("odr=%s 取档码 0x%02X / 等待 %dms",
	      tostring(c[1]), c[2], c[3]),
	      r.result == "OK" and w2c == c[2] and dev:bw() == c[2]
	      and sleep_total == c[3],
	      string.format("got 0x%02X sleep=%s", tonumber(w2c) or -1, tostring(sleep_total)))
end

-- 备地址 0x1D / 字符串 fd
mark = section()
expect_ok("build 备地址 '0x1D'", function()
	return build({ fd = fd, address = "0x1D" })
end)
check("set_addr 收到 0x1D", set_addrs(mark)[1] == 0x1D,
      string.format("0x%02X", set_addrs(mark)[1] or 0))
section()
expect_ok("build 字符串 fd='3'", function()
	return build({ fd = "3", address = "0x53" })
end)

-- build 负路径：参数校验
mark = section()
expect_err("build 非 table", function() return build(nil) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x53" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("参数校验路径零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x53" })
end, "set_addr failed")
check("fd=99 开窗零 txlog（未 open，set 在留痕前失败）",
      #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60", function()
	return build({ fd = fd, address = "0x60" })
end, "Failed to read ADXL345 DEVID")
check("错地址 set+w00 两 txlog（无挂载指针写 NACK、无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x00 and #reads(mark) == 0,
      tostring(#entries(mark)))

mark = section()
dev:who(0xE7)
expect_err("build DEVID=0xE7 不符", function()
	return build({ fd = fd, address = "0x53" })
end, "DEVID")
check("DEVID 不符 3 txlog（set+w00+r，甄别在读完后）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0x00 end)
expect_err("build DEVID 读失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to read ADXL345 DEVID")
check("DEVID 读失败 3 txlog（set+w00+r，失败 r 也留痕）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x00 end)
expect_err("build DEVID 指针写失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to read ADXL345 DEVID")
check("DEVID 指针写失败 2 txlog（set+w00，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0x31 end)
expect_err("build DATA_FORMAT 读失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to read ADXL345 DATA_FORMAT")
check("DATA_FORMAT 读失败 5 txlog（set+w00+r+w31+r）",
      #entries(mark) == 5 and #reads(mark) == 2, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return b[1] == 0x31 and #b == 2 end)
expect_err("build DATA_FORMAT 写失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to write ADXL345 DATA_FORMAT")
check("DATA_FORMAT 写失败 6 txlog（指针写放行、2B 配置写拦）",
      #entries(mark) == 6 and #reads(mark) == 2, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return b[1] == 0x2C and #b == 2 end)
expect_err("build BW_RATE 写失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to write ADXL345 BW_RATE")
check("BW_RATE 写失败 7 txlog", #entries(mark) == 7, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return b[1] == 0x2D and #b == 2 end)
expect_err("build POWER_CTL 写失败", function()
	return build({ fd = fd, address = "0x53" })
end, "Failed to write ADXL345 POWER_CTL")
check("POWER_CTL 写失败 8 txlog（无睡眠，失败在 milli_sleep 前短路）",
      #entries(mark) == 8 and sleep_total == 0,
      tostring(#entries(mark) .. " sleep=" .. sleep_total))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call（set + w32 指针 + r6 = 3 txlog，零睡眠）
-- =====================================================================
mark = section()
expect_ok("build 默认（为 call 准备芯片态）", function()
	return build({ fd = fd, address = "0x53" })
end)

mark = #vbus.txlog		-- build 后另开窗：call 零睡眠断言不受 build 22ms 影响
dev:set_accel_raw(4096, -1, -1024)	-- 旧桩种子：0x1000/0xFFFF/0xFC00
local cr = expect_ok("call 读三轴", function()
	return call({ fd = fd, address = "0x53" })
end)
if cr then
	check("call ACCEL_X=4096 无符号码", cr.ACCEL_X == 4096, tostring(cr.ACCEL_X))
	check("call ACCEL_Y=65535（-1 补码，驱动不展开）", cr.ACCEL_Y == 65535,
	      tostring(cr.ACCEL_Y))
	check("call ACCEL_Z=64512（-1024 补码）", cr.ACCEL_Z == 64512,
	      tostring(cr.ACCEL_Z))
	check("call 返回键名 ACCEL_X/Y/Z + result 契约",
	      cr.result == "OK" and cr.ACCEL_X ~= nil and cr.ACCEL_Y ~= nil
	      and cr.ACCEL_Z ~= nil)
end
check("call 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
check("call 一笔 0x32 纯指针写",
      #ptr_writes(mark) == 1 and ptr_writes(mark)[1] == 0x32,
      table.concat(ptr_writes(mark), ","))
local rd = reads(mark)
check("call 一次 6B burst 读 0x53",
      #rd == 1 and rd[1].addr == 0x53 and rd[1].bytes.n == 6,
      #rd == 1 and string.format("addr=0x%02X n=%s", rd[1].addr,
      tostring(rd[1].bytes and rd[1].bytes.n)) or tostring(#rd))
check("call 共 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
check("call 零睡眠", sleep_total == 22, tostring(sleep_total))	-- 仍是 build 的 22ms

-- 小端拼字：正/负/零/极值，驱动返回无符号码（sign='16' 归守护）
local word_cases = { 0, 1, 256, 4096, 32767, -1, -256, -1024, -32767, -32768 }
for _, wv in ipairs(word_cases) do
	dev:set_accel_raw(wv, wv, wv)
	local r = call({ fd = fd, address = "0x53" })
	check(string.format("call 小端拼字 %d → 无符号 %d", wv, u16(wv)),
	      r.result == "OK" and r.ACCEL_X == u16(wv) and r.ACCEL_Y == u16(wv)
	      and r.ACCEL_Z == u16(wv),
	      string.format("%s,%s,%s", tostring(r.ACCEL_X),
	      tostring(r.ACCEL_Y), tostring(r.ACCEL_Z)))
end

-- 连续三拍不串
local beats = { { 100, -200, 300 }, { -400, 500, -600 }, { 700, 0, -1 } }
for i, b in ipairs(beats) do
	dev:set_accel_raw(b[1], b[2], b[3])
	local r = call({ fd = fd, address = "0x53" })
	check(string.format("连续读第 %d 拍 %d/%d/%d 不串", i, b[1], b[2], b[3]),
	      r.result == "OK" and r.ACCEL_X == u16(b[1]) and r.ACCEL_Y == u16(b[2])
	      and r.ACCEL_Z == u16(b[3]),
	      string.format("%s/%s/%s", tostring(r.ACCEL_X),
	      tostring(r.ACCEL_Y), tostring(r.ACCEL_Z)))
end

-- virt_tick → 驱动正算闭环（无符号码）
for n, e in pairs({ [0] = { 0, 67, 245 }, [8] = { 77, -38, 250 },
                    [24] = { -77, 38, 262 } }) do
	dev:virt_tick(n)
	local r = call({ fd = fd, address = "0x53" })
	check(string.format("virt_tick(%d) 驱动闭环 X=%d Y=%d Z=%d", n,
	      e[1], u16(e[2]), u16(e[3])),
	      r.ACCEL_X == u16(e[1]) and r.ACCEL_Y == u16(e[2])
	      and r.ACCEL_Z == u16(e[3]),
	      string.format("%s,%s,%s", tostring(r.ACCEL_X),
	      tostring(r.ACCEL_Y), tostring(r.ACCEL_Z)))
end

-- 无 build 守卫：全新模型挂 0x1D，不 build 裸 call 直接合法（驱动不存模块状态）
section()
vbus.attach("ADXL345@0x1D", 0x1D, amod.new())
vbus.load_driver("modules/ADXL345.lua")
mark = #vbus.txlog
expect_ok("未 build 裸 call 合法（无 build 状态）", function()
	return call({ fd = fd, address = "0x1D" })
end)
check("裸 call 仍 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
vbus.attach("ADXL345@0x53", ADDR, dev)
vbus.attach("ADXL345@0x1D", 0x1D, dev)
vbus.load_driver("modules/ADXL345.lua")

-- call 负路径
mark = #vbus.txlog
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments: table")
expect_err("call 缺 fd", function() return call({ address = "0x53" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
check("call 参数校验零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call fd=99 set_addr", function()
	return call({ fd = 99, address = "0x53" })
end, "set_addr failed")
check("call fd=99 零 txlog", #entries(mark) == 0, tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call 错地址 0x60", function()
	return call({ fd = fd, address = "0x60" })
end, "Failed to read ADXL345 accel data")
check("call 错地址 set+w32 两 txlog（无挂载无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x32 and #reads(mark) == 0,
      tostring(#entries(mark)))

section()
dev:fail_read(function(p) return p == 0x32 end)
mark = #vbus.txlog
expect_err("call 数据读失败", function()
	return call({ fd = fd, address = "0x53" })
end, "Failed to read ADXL345 accel data")
check("数据读失败 3 txlog（set+w32+r）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
dev:clear_faults()

section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x32 end)
mark = #vbus.txlog
expect_err("call 指针写失败", function()
	return call({ fd = fd, address = "0x53" })
end, "Failed to read ADXL345 accel data")
check("call 指针写失败 2 txlog（set+w32，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无资源释放，arg_table 校验，零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 空表 OK", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_ok("destroy 带 fd 表也不碰总线", function()
	return destroy({ fd = fd, address = "0x53" })
end)
expect_err("destroy 非 table", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_adxl345")

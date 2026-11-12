-- test_apds9900.lua —— APDS-9900 真实驱动 + 虚拟 I2C 总线 + 命令字节协议模型
-- 用法（项目根目录）: luajit test/test_apds9900.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：APDS9900_GC=1 luajit test/test_apds9900.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 246 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/APDS9900.lua 尾部 APDS9900_VIRT，
-- 2026-09-15 自 virtbus/apds9900.lua 迁入）」。APDS-9900（TAOS TSL2771
-- 架构，APDS-9960 前代）不是朴素寄存器指针，而是命令字节寻址（datasheet
-- AV02-2049EN + Linux 内核 apds990x.c 交叉验证）：
--   首字节 bit7 COMMAND 必置、bit6:5 TYPE（00 重复字节/01 自动增量/
--   10 重复字/11 自动增量）、bit4:0 寄存器地址；驱动只用 0x80 字节
--   访问与 0xA0 字对自增，数据字对【小端】（偶址 LSB），HAL 大端
--   合并后驱动 read_word_le 换序（旧桩同样摆小端，字节序事实不变）。
--   ID 0x12 批次 ROM 接受 0x00/0x04/0x29，写 ACK 丢弃；ENABLE 0x00
--   bit7:6 保留写抹 0；测量区 0x14~0x19 只读写丢弃；阈值 0x04~0x09/
--   保留 0x0A0B/STATUS 0x13/0x1A~0x1F 驱动不碰，模型不建模整笔 NACK。
--
-- 真实 build（全程零 milli_sleep）：set + {80,00} 断电 + ID 指针读
-- （{92}+r1）+ 7 笔配置写 + {80,07} 启动 = set + 10 w + 1 r（12 txlog）；
-- 真实 call：set + 三笔 TYPE=01 字对读（{B4}+r2、{B6}+r2、{B8}+r2）
-- = set + 3 w + 3 r（7 txlog）；destroy：set + {80,00} = 2 txlog。
--
-- 覆盖：模型侧 POR/命令位与 TYPE 四态寻址/坏帧/未建模地址整笔 NACK/
-- 保留位抹除/ROM 与测量区只读丢弃/突发写落址/计数注入钳制与小端摆放/
-- virt_tick 确定性正弦/故障钩子；真实 build 寄存器序列逐笔编码/
-- 缺省与全自定义/atime 边界/三类增益与 LED 码/横幅/12 个参数错误分支/
-- ID 三接受一拒收/四类 NACK 短路点 txlog；真实 call 三通道字节序/
-- lux 内核两线算法多场景独立重算（增益/atime/df/ga/IR 钳零）/三路
-- 读失败精确短路；destroy 断电与缺参安全。

if os.getenv("APDS9900_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x39
-- 模型内嵌于驱动文件（APDS9900_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/APDS9900.lua")
local amod = APDS9900_VIRT

local dev = amod.new()
vbus.attach("APDS9900@0x39", ADDR, dev)

-- milli_sleep：本驱动 build/call 零睡眠，桩只累计供断言
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- 每个 section：器件回上电态 + 故障解除 + ID 恢复 0x29（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0x29)
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
-- 字节帧大端编码成整数（1 字节指针帧亦适用）
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
local function bytes_of(t)
	local s = {}
	for i = 1, #t do s[i] = tostring(t[i]) end
	return table.concat(s, ",")
end

-- 独立 lux 重算（内核 apds990x 两线 IR 补偿；手排算式与驱动交叉验证）
local function lux_ref(ch0, ch1, again, cycles, df, ga)
	local iac1 = 1.00 * ch0 - 2.23 * ch1
	local iac2 = 0.70 * ch0 - 1.42 * ch1
	local iac = math.max(math.max(iac1, iac2), 0)
	local atime_ms = cycles * 87 / 32
	return iac * df * math.floor(ga * 4096 + 0.5) / 4096 / (again * atime_ms)
end
-- 捕获驱动 print 横幅（build 成功恰好打印一行）
local function capture(fn)
	local cap, old = {}, print
	print = function(...) cap[#cap + 1] = table.concat({ ... }, "\t") end
	local ok, res = pcall(fn)
	print = old
	return ok, res, table.concat(cap, "|")
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

-- ---- POR ----
check("POR ENABLE=0x00", dev:enable() == 0x00, string.format("0x%02X", dev:enable()))
check("POR ATIME=0xFF", dev:atime() == 0xFF, string.format("0x%02X", dev:atime()))
check("POR PTIME=0xFF", dev:ptime() == 0xFF, string.format("0x%02X", dev:ptime()))
check("POR WTIME=0xFF", dev:wtime() == 0xFF, string.format("0x%02X", dev:wtime()))
check("POR PERS=0x00", dev:pers() == 0x00, tostring(dev:pers()))
check("POR CONFIG=0x00", dev:config() == 0x00, tostring(dev:config()))
check("POR PPCOUNT=0x01", dev:ppcount() == 0x01, tostring(dev:ppcount()))
check("POR CONTROL=0x00", dev:control() == 0x00, tostring(dev:control()))
check("POR ID=0x29", dev:id() == 0x29, string.format("0x%02X", dev:id()))
check("POR 三数据字对全 0", dev:ch0() == 0 and dev:ch1() == 0 and dev:prox() == 0)
check("POR ptr=0/ptype=0", dev:pointer() == 0 and dev:ptype() == 0,
	string.format("%d/%d", dev:pointer(), dev:ptype()))

-- ---- 命令字节与 TYPE 四态 ----
check("命令位缺失的数据写 NACK", dev.write({ 0x00, 0x07 }) == false)
check("坏帧不移动指针", dev:pointer() == 0, tostring(dev:pointer()))
check("空帧 NACK", dev.write({}) == false)
check("非表帧 NACK", dev.write("\x80") == false)

check("ID 指针写 {0x92} ACK", dev.write({ 0x92 }) == true)
check("指针/类型 = 0x12/00", dev:pointer() == 0x12 and dev:ptype() == 0)
local r1 = dev.read(1)
check("TYPE=00 读 1 字节 = ID 0x29", r1 and #r1 == 1 and r1[1] == 0x29,
	r1 and bytes_of(r1) or "nil")
local r3 = dev.read(3)
check("TYPE=00 重复字节读 3 = 29,29,29",
	r3 and #r3 == 3 and r3[1] == 0x29 and r3[2] == 0x29 and r3[3] == 0x29,
	r3 and bytes_of(r3) or "nil")

dev:set_ch0(0x1234)
check("自增指针 {0xB4} ACK 且 ptype=1",
	dev.write({ 0xB4 }) == true and dev:pointer() == 0x14 and dev:ptype() == 1)
local w2 = dev.read(2)
check("TYPE=01 字对读小端 34,12",
	w2 and w2[1] == 0x34 and w2[2] == 0x12, w2 and bytes_of(w2) or "nil")

check("重复字指针 {0xD4} ptype=2",
	dev.write({ 0xD4 }) == true and dev:ptype() == 2 and dev:pointer() == 0x14)
local rw4 = dev.read(4)
check("TYPE=10 重复字读 4 = 34,12,34,12",
	rw4 and rw4[1] == 0x34 and rw4[2] == 0x12 and rw4[3] == 0x34 and rw4[4] == 0x12,
	rw4 and bytes_of(rw4) or "nil")

check("自增字指针 {0xF4} ptype=3",
	dev.write({ 0xF4 }) == true and dev:ptype() == 3 and dev:pointer() == 0x14)
local w2b = dev.read(2)
check("TYPE=11 读 2 同线性自增 34,12",
	w2b and w2b[1] == 0x34 and w2b[2] == 0x12, w2b and bytes_of(w2b) or "nil")

dev:set_ch1(0x5678)
dev.write({ 0xB4 })
local cross = dev.read(4)
check("TYPE=01 跨字对读 4 = 34,12,78,56",
	cross and cross[1] == 0x34 and cross[2] == 0x12 and cross[3] == 0x78 and cross[4] == 0x56,
	cross and bytes_of(cross) or "nil")

check("STATUS 0x13 指针写 ACK（读时才验）", dev.write({ 0x93 }) == true)
check("STATUS 0x13 读 NACK", dev.read(1) == nil)
check("阈值 0x04 指针写 ACK", dev.write({ 0x84 }) == true)
check("阈值 0x04 读 NACK", dev.read(1) == nil)
check("0x1A 指针写 ACK/读 NACK",
	dev.write({ 0x9A }) == true and dev.read(1) == nil)
dev.write({ 0xB8 })
check("自增读越界进 0x1A 整笔 NACK", dev.read(3) == nil)
check("read(0) NACK", dev.read(0) == nil)

-- ---- 写路径 ----
check("ENABLE 写 {0x80,0x07}", dev.write({ 0x80, 0x07 }) and dev:enable() == 0x07,
	string.format("0x%02X", dev:enable()))
check("ENABLE 保留位 7:6 写抹 0（FF→3F）",
	dev.write({ 0x80, 0xFF }) and dev:enable() == 0x3F,
	string.format("0x%02X", dev:enable()))
check("ENABLE WEN/AIEN/PIEN 位照存（38）",
	dev.write({ 0x80, 0x38 }) and dev:enable() == 0x38,
	string.format("0x%02X", dev:enable()))
check("CONTROL 全 8 位照存 EF",
	dev.write({ 0x8F, 0xEF }) and dev:control() == 0xEF,
	string.format("0x%02X", dev:control()))
check("CONFIG WLONG 位照存 01",
	dev.write({ 0x8D, 0x01 }) and dev:config() == 0x01,
	string.format("0x%02X", dev:config()))
check("PPCOUNT=255 照存",
	dev.write({ 0x8E, 0xFF }) and dev:ppcount() == 255, tostring(dev:ppcount()))

check("ID ROM 写 ACK 但丢弃", dev.write({ 0x92, 0x55 }) and dev:id() == 0x29,
	string.format("0x%02X", dev:id()))
check("CDATA 写 ACK 丢弃", dev.write({ 0x94, 0xAB }) and dev:ch0() == 0x1234,
	string.format("0x%04X", dev:ch0()))
check("IRDATA 写 ACK 丢弃", dev.write({ 0x96, 0xAB }) and dev:ch1() == 0x5678,
	string.format("0x%04X", dev:ch1()))
check("PDATA 写 ACK 丢弃", dev.write({ 0x98, 0xAB }) and dev:prox() == 0,
	string.format("0x%04X", dev:prox()))
check("未建模地址数据写整笔 NACK（0x04）", dev.write({ 0x84, 0x10 }) == false)
check("未建模地址数据写整笔 NACK（0x1A）", dev.write({ 0x9A, 0x00 }) == false)

dev.write({ 0xA1, 0x10, 0x20 })
check("TYPE=01 突发写 ATIME=0x10", dev:atime() == 0x10, string.format("0x%02X", dev:atime()))
check("TYPE=01 突发写 PTIME=0x20", dev:ptime() == 0x20, string.format("0x%02X", dev:ptime()))
dev.write({ 0x81, 0x11, 0x22 })
check("TYPE=00 突发重复字节 ATIME=0x22（末值胜）",
	dev:atime() == 0x22, string.format("0x%02X", dev:atime()))
check("TYPE=00 突发不串 PTIME（仍 0x20）",
	dev:ptime() == 0x20, string.format("0x%02X", dev:ptime()))
dev.write({ 0xC1, 0xAA, 0xBB, 0xCC })
check("TYPE=10 重复字 4B：PTIME=0xBB", dev:ptime() == 0xBB,
	string.format("0x%02X", dev:ptime()))
check("TYPE=10 重复字 4B：ATIME=0xCC（低址回环）",
	dev:atime() == 0xCC, string.format("0x%02X", dev:atime()))
check("突发写落未建模地址整笔 NACK", dev.write({ 0xA4, 0x01, 0x02 }) == false)
check("失败突发不留半截（ATIME 仍 CC）",
	dev:atime() == 0xCC, string.format("0x%02X", dev:atime()))

-- ---- 注入 API ----
local a, b, c = dev:set_counts(70000, -5, 99999)
check("set_counts 上钳 65535（CH0）", dev:ch0() == 65535 and a == 65535,
	tostring(dev:ch0()))
check("set_counts 下钳 0（CH1）", dev:ch1() == 0 and b == 0, tostring(dev:ch1()))
check("set_counts 上钳 65535（PROX）", dev:prox() == 65535 and c == 65535,
	tostring(dev:prox()))
dev:set_ch0(0x00FF); dev:set_ch1(0x0100); dev:set_prox(0x0F0F)
dev.write({ 0xB4 })
local pin = dev.read(6)
check("三路独立 set_* 小端摆放 FF,00,00,01,0F,0F",
	pin and pin[1] == 0xFF and pin[2] == 0x00 and pin[3] == 0x00 and pin[4] == 0x01
	and pin[5] == 0x0F and pin[6] == 0x0F, pin and bytes_of(pin) or "nil")

check("set_reg RW 生效（CONTROL=EF）", dev:set_reg(0x0F, 0xEF):control() == 0xEF)
check("set_reg 改不动 ID ROM", dev:set_reg(0x12, 0x55):id() == 0x29,
	string.format("0x%02X", dev:id()))
check("who(0x04) 覆写批次", dev:who(0x04):id() == 0x04,
	string.format("0x%02X", dev:id()))
check("who() 无参保持", dev:who():id() == 0x04, string.format("0x%02X", dev:id()))
check("who() 身份跨 reset 保留", (dev:reset():id() == 0x04),
	string.format("0x%02X", dev:id()))

dev:virt_tick(0)
check("virt_tick n0 = 10000/2500/300",
	dev:ch0() == 10000 and dev:ch1() == 2500 and dev:prox() == 300,
	string.format("%d/%d/%d", dev:ch0(), dev:ch1(), dev:prox()))
dev:virt_tick(8)
check("virt_tick n8 峰 = 14000/3500/500",
	dev:ch0() == 14000 and dev:ch1() == 3500 and dev:prox() == 500,
	string.format("%d/%d/%d", dev:ch0(), dev:ch1(), dev:prox()))
dev:virt_tick(24)
check("virt_tick n24 谷 = 6000/1500/100",
	dev:ch0() == 6000 and dev:ch1() == 1500 and dev:prox() == 100,
	string.format("%d/%d/%d", dev:ch0(), dev:ch1(), dev:prox()))
local s4 = math.sin(4 * (2 * math.pi / 32))
local c04 = math.floor(10000 + 4000 * s4 + 0.5)
local c14 = math.floor(c04 / 4)
local px4 = math.floor(300 + 200 * s4 + 0.5)
dev:virt_tick(4)
check("virt_tick n4 与独立正弦一致",
	dev:ch0() == c04 and dev:ch1() == c14 and dev:prox() == px4,
	string.format("%d/%d/%d vs %d/%d/%d", dev:ch0(), dev:ch1(), dev:prox(), c04, c14, px4))
dev:virt_tick(0); dev:virt_tick(32)
check("virt_tick 32 拍周期", dev:ch0() == 10000 and dev:ch1() == 2500 and dev:prox() == 300)
check("virt_tick 返回 self", dev:virt_tick(0) == dev)

-- ---- 故障钩子 / 留痕 / 复位 ----
dev:reset_logs()
dev.nack_write = true
check("写故障注入 NACK", dev.write({ 0x80, 0x01 }) == false)
dev:clear_faults()
check("解除后写恢复", dev.write({ 0x80, 0x01 }) ~= false and dev:enable() == 0x01)
dev.nack_read = true
check("读故障注入 NACK", dev.read(1) == nil)
dev:clear_faults()
dev.write({ 0x92 })
check("解除后读恢复（who(0x04) 身份仍在）", dev.read(1)[1] == 0x04,
	string.format("0x%02X", dev.read(1)[1]))
dev:fail_write(function(b) return b[1] == 0x8F end)
check("fail_write 谓词命中 CONTROL", dev.write({ 0x8F, 0x00 }) == false)
check("fail_write 谓词不影响 ENABLE", dev.write({ 0x80, 0x02 }) ~= false)
dev:clear_faults()
dev:fail_read(function(p) return p == 0x12 end)
dev.write({ 0x92 })
check("fail_read 谓词命中 ID 读", dev.read(1) == nil)
dev:clear_faults()

dev:reset_logs()
dev.write({ 0x80, 0x00 })
dev.write({ 0x92 })
check("write_log 全量留痕（含指针写）2 笔",
	#dev.write_log == 2 and dev.write_log[1][1] == 0x80 and dev.write_log[2][1] == 0x92,
	tostring(#dev.write_log))
check("reset_logs 清空", dev:reset_logs() and #dev.write_log == 0)
check("reset 回 POR（ENABLE=0/ATIME=FF/ptr=0）",
	dev:reset():enable() == 0 and dev:atime() == 0xFF and dev:pointer() == 0
	and dev:ptype() == 0)
check("modeled 地址表（00/12/19 在，04/13/1F 不在）",
	dev:modeled(0x00) and dev:modeled(0x12) and dev:modeled(0x19)
	and not dev:modeled(0x04) and not dev:modeled(0x13) and not dev:modeled(0x1F))

-- =====================================================================
-- 组 2：真实 build（缺省参数，逐笔事务/寄存器值）
-- =====================================================================
mark = section()
local ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x39" })
end)
check("build 缺省 OK", ok and type(res) == "table" and res.result == "OK",
	tostring(ok and res and res.result or res))
local es = entries(mark)
check("build 12 txlog（set+10w+1r）", #es == 12,
	table.concat((function()
		local t = {}
		for _, e in ipairs(es) do t[#t + 1] = e.dir end
		return t
	end)(), ","))
check("build 首笔 set 0x39", set_addrs(mark)[1] == 0x39, tostring(set_addrs(mark)[1]))
check("build 写序列逐笔编码",
	same_seq(wcodes(mark), {
		0x8000, 0x92, 0x81EE, 0x82FF, 0x83FF, 0x8D00, 0x8C00,
		0x8E08, 0x8F20, 0x8007,
	}), table.concat((function()
		local t = {}
		for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%04X", v) end
		return t
	end)(), ","))
local rds = reads(mark)
check("build 恰 1 笔读（ID，n=1）", #rds == 1 and rds[1].bytes.n == 1,
	tostring(#rds))
check("ATIME=238（50ms → 18 周期）", dev:atime() == 238, tostring(dev:atime()))
check("PTIME=0xFF", dev:ptime() == 0xFF)
check("WTIME=0xFF", dev:wtime() == 0xFF)
check("CONFIG=0x00", dev:config() == 0x00)
check("PERS=0x00", dev:pers() == 0x00)
check("PPCOUNT=8", dev:ppcount() == 8, tostring(dev:ppcount()))
check("CONTROL=0x20（100mA|IR 管|×1|×1）",
	dev:control() == 0x20, string.format("0x%02X", dev:control()))
check("ENABLE=0x07（PON|AEN|PEN）",
	dev:enable() == 0x07, string.format("0x%02X", dev:enable()))
check("build 零睡眠", sleep_total == 0, tostring(sleep_total))
check("横幅含 init OK/id=0x29/atime=48.9ms/again=x1",
	banner:find("APDS9900 init OK", 1, true)
	and banner:find("id=0x29", 1, true)
	and banner:find("atime=48.9ms", 1, true)
	and banner:find("again=x1", 1, true), banner)

-- =====================================================================
-- 组 3：真实 build（自定义/边界/横幅）
-- =====================================================================
mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x39", atime = "696", again = "120",
		pdrive = "12.5", pgain = "8", ppcount = "64", df = "60", ga = "0.5" })
end)
check("build 全自定义 OK", ok and res.result == "OK", tostring(res and res.result))
check("atime 696ms → 256 周期（ATIME=0）", dev:atime() == 0, tostring(dev:atime()))
check("CONTROL=0xEF（12.5mA|IR|×8|×120）",
	dev:control() == 0xEF, string.format("0x%02X", dev:control()))
check("PPCOUNT=64", dev:ppcount() == 64, tostring(dev:ppcount()))
check("横幅全自定义字段",
	banner:find("again=x120", 1, true) and banner:find("led=12.5mA", 1, true)
	and banner:find("pgain=x8", 1, true) and banner:find("ppulse=64", 1, true)
	and banner:find("ga=0.50", 1, true), banner)

mark = section()
expect_ok("build 最短积分 2.73ms（1 周期）", function()
	return build({ fd = fd, address = "0x39", atime = "2.73" })
end)
check("ATIME=255", dev:atime() == 255, tostring(dev:atime()))

mark = section()
expect_ok("build atime=100ms（36 周期 → ATIME=220）", function()
	return build({ fd = fd, address = "0x39", atime = "100" })
end)
check("ATIME=220", dev:atime() == 220, tostring(dev:atime()))

mark = section()
expect_ok("build pdrive=50mA/pgain=×4 → CONTROL=0x68", function()
	return build({ fd = fd, address = "0x39", pdrive = "50", pgain = "4" })
end)
check("CONTROL=0x68（64+32+8）", dev:control() == 0x68,
	string.format("0x%02X", dev:control()))

mark = section()
expect_ok("build pdrive=25mA/pgain=×2 → CONTROL=0xA4", function()
	return build({ fd = fd, address = "0x39", pdrive = "25", pgain = "2" })
end)
check("CONTROL=0xA4", dev:control() == 0xA4, string.format("0x%02X", dev:control()))

mark = section()
expect_ok("build ppcount=255 上限接受", function()
	return build({ fd = fd, address = "0x39", ppcount = "255" })
end)
check("PPCOUNT=255", dev:ppcount() == 255, tostring(dev:ppcount()))

mark = section()
expect_ok("build ppcount 非数值静默缺省 8", function()
	return build({ fd = fd, address = "0x39", ppcount = "abc" })
end)
check("PPCOUNT=8（缺省）", dev:ppcount() == 8, tostring(dev:ppcount()))

-- NaN 反例（26.1）：'nan' 经 tonumber 出的是 **number**（Lua 里 truthy），故
-- `tonumber(x) or 缺省` 的 or 分支永不触发，而 NaN 与任何数比较都为假，
-- `< 2.73`/`> 696`/`< 1`/`> 255`/`<= 0`/`> 1` 六条区间判定一律放行（±inf 会
-- 被上/下界接住，只有 NaN 穿得过去）。后果分两级：
--   · ppcount 落寄存器，NaN 字节被 HAL 的 byte_of 挡成 nil → 报「APDS9900 not
--     responding (PPCOUNT write failed)」，把配置笔误误报成器件掉线；
--   · atime/df/ga 更重——df/ga 不落寄存器而落**模块级 cfg_\* 状态**，call 侧
--     的 `cfg_df or 52` 同样兜不住 NaN，于是此后每一次 call 的 LUX 都是 nan；
--     atime 的 NaN 经 cycles 钳位后照样穿过，污染 cfg_atime_ms 这个除数。
-- 判据取「与该列既有的非数字串同结论」：ppcount/df/ga 的 'abc' 本就静默归
-- 缺省，atime 的越界本就报 ERR（审计 P3 的 finite_of 口径）。
mark = section()
expect_ok("build ppcount='nan' 同静默缺省 8", function()
	return build({ fd = fd, address = "0x39", ppcount = "nan" })
end)
check("ppcount NaN → PPCOUNT=8（缺省，非 not responding）",
	dev:ppcount() == 8, tostring(dev:ppcount()))

mark = section()
expect_err("build atime='nan' 同越界报 ERR", function()
	return build({ fd = fd, address = "0x39", atime = "nan" })
end, "atime")

mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x39", df = "nan", ga = "nan" })
end)
check("build df/ga='nan' OK（归缺省）", ok and res.result == "OK",
	tostring(res and res.result))
check("df/ga NaN 横幅回落缺省 df=52 ga=0.48",
	banner:find("df=52", 1, true) ~= nil and banner:find("ga=0.48", 1, true) ~= nil,
	banner)
do
	dev:set_counts(10000, 2500, 517)
	local r = expect_ok("df/ga NaN 后 call 读数", function()
		return call({ fd = fd, address = "0x39" })
	end)
	check("LUX 未被 NaN 污染（≈2256.83，与缺省 build 同值）",
		r and near(r.LUX, lux_ref(10000, 2500, 1, 18, 52, 0.48), 1e-6),
		tostring(r and r.LUX))
end

mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x39", df = "inf" })
end)
check("build df='inf' OK（归缺省）", ok and res.result == "OK",
	tostring(res and res.result))
check("df inf 横幅回落缺省 df=52", banner:find("df=52", 1, true) ~= nil, banner)
do
	dev:set_counts(10000, 2500, 517)
	local r = expect_ok("df=inf 后 call 读数", function()
		return call({ fd = fd, address = "0x39" })
	end)
	check("LUX 未被 inf 污染", r and near(r.LUX,
		lux_ref(10000, 2500, 1, 18, 52, 0.48), 1e-6), tostring(r and r.LUX))
end

-- =====================================================================
-- 组 4：真实 build 错误路径
-- =====================================================================
-- 注意：atime/again/... 数值校验发生在 ID 甄别【之后】，每个错误用例都已
-- 完整走过 set+断电写+ID 指针读（4 txlog）；只有缺 fd/非表参数零事务。
mark = section()
expect_err("atime 过短", function()
	return build({ fd = fd, address = "0x39", atime = "2" })
end, "atime")
expect_err("atime 过长", function()
	return build({ fd = fd, address = "0x39", atime = "1000" })
end, "atime")
expect_err("again 非法", function()
	return build({ fd = fd, address = "0x39", again = "5" })
end, "again")
expect_err("pdrive 非法", function()
	return build({ fd = fd, address = "0x39", pdrive = "30" })
end, "pdrive")
expect_err("pgain 非法", function()
	return build({ fd = fd, address = "0x39", pgain = "3" })
end, "pgain")
expect_err("ppcount=0", function()
	return build({ fd = fd, address = "0x39", ppcount = "0" })
end, "ppcount")
expect_err("ppcount=256", function()
	return build({ fd = fd, address = "0x39", ppcount = "256" })
end, "ppcount")
expect_err("ga>1", function()
	return build({ fd = fd, address = "0x39", ga = "1.5" })
end, "df/ga")
expect_err("df 负值", function()
	return build({ fd = fd, address = "0x39", df = "-1" })
end, "df/ga")
check("9 个数值类参数错误均在 ID 甄别后短路（各 4 txlog，共 36）",
	#entries(mark) == 36, tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("缺 fd", function() return build({ address = "0x39" }) end, "fd or address")
expect_err("address 非数值", function()
	return build({ fd = fd, address = "0xZZ" })
end, "fd or address")
expect_err("非表参数", function() return build(true) end, "Invalid Arguments Type")
check("前置校验类错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
dev:who(0x55)
expect_err("ID=0x55 拒收", function()
	return build({ fd = fd, address = "0x39" })
end, "unexpected ID")
check("ID 失败 txlog=4（set+断电写+ID 指针+r）", #entries(mark) == 4,
	tostring(#entries(mark)))

mark = section()
dev:who(0x00)
expect_ok("ID=0x00 接受（部分批次）", function()
	return build({ fd = fd, address = "0x39" })
end)
mark = section()
dev:who(0x04)
local ok4, res4, banner4 = capture(function()
	return build({ fd = fd, address = "0x39" })
end)
check("ID=0x04 接受", ok4 and res4.result == "OK", tostring(res4.result))
check("ID=0x04 横幅 id=0x04", banner4:find("id=0x04", 1, true) ~= nil, banner4)

mark = section()
dev.nack_write = true
expect_err("首写 ENABLE 无应答", function()
	return build({ fd = fd, address = "0x39" })
end, "not responding")
check("首写失败 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x92 end)
expect_err("ID 指针写 NACK", function()
	return build({ fd = fd, address = "0x39" })
end, "read ID failed")
check("ID 指针写失败 txlog=3（set+断电写+失败指针写，无 r）",
	#entries(mark) == 3, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0x12 end)
expect_err("ID 数据阶段 NACK", function()
	return build({ fd = fd, address = "0x39" })
end, "read ID failed")
check("ID 数据 NACK txlog=4（失败 r 也留痕）",
	#entries(mark) == 4, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x81 end)
expect_err("ATIME 配置写失败", function()
	return build({ fd = fd, address = "0x39" })
end, "not responding")
check("配置写失败 txlog=5（set+断电写+ID 指针+r+失败写，后续 wr 短路）",
	#entries(mark) == 5, tostring(#entries(mark)))
check("配置写失败不发启动写（尾帧非 0x8007）",
	wcodes(mark)[#wcodes(mark)] == 0x81EE,
	string.format("%04X", wcodes(mark)[#wcodes(mark)]))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x80 and b[2] == 0x07 end)
expect_err("启动写 ENABLE 失败", function()
	return build({ fd = fd, address = "0x39" })
end, "enable failed")
check("启动写失败 txlog=12（全部配置写已发）", #entries(mark) == 12,
	tostring(#entries(mark)))

mark = section()
expect_err("无器件地址 0x40 首写 NACK", function()
	return build({ fd = fd, address = "0x40" })
end, "not responding")
check("无器件 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

-- =====================================================================
-- 组 5：真实 call（三通道字节序 + lux 内核算法）
-- =====================================================================
mark = section()
expect_ok("call 前 build（缺省 18 周期/×1）", function()
	return build({ fd = fd, address = "0x39" })
end)
dev:set_counts(10000, 2500, 517)
mark = #vbus.txlog
local s = expect_ok("call 读三通道", function() return call({ fd = fd, address = "0x39" }) end)
check("call 7 txlog（set+3w+3r）", #entries(mark) == 7, tostring(#entries(mark)))
check("call 指针序列 B4/B6/B8",
	same_seq(wcodes(mark), { 0xB4, 0xB6, 0xB8 }),
	table.concat((function()
		local t = {}
		for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%02X", v) end
		return t
	end)(), ","))
local cr = reads(mark)
check("call 三笔读均 n=2",
	#cr == 3 and cr[1].bytes.n == 2 and cr[2].bytes.n == 2 and cr[3].bytes.n == 2,
	tostring(#cr))
if s then
	check("CH0=10000（小端换序正确）", s.CH0 == 10000, tostring(s.CH0))
	check("CH1=2500", s.CH1 == 2500, tostring(s.CH1))
	check("PROX=517", s.PROX == 517, tostring(s.PROX))
	check("CH0/CH1/PROX 为整数计数",
		s.CH0 % 1 == 0 and s.CH1 % 1 == 0 and s.PROX % 1 == 0)
	check("LUX≈2256.83（独立重算）",
		near(s.LUX, lux_ref(10000, 2500, 1, 18, 52, 0.48), 1e-6),
		tostring(s.LUX))
end

mark = section()
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x39" }) end)
dev:set_counts(1000, 1000, 0)
s = expect_ok("IR 主导 lux 钳 0", function() return call({ fd = fd, address = "0x39" }) end)
if s then check("LUX=0", s.LUX == 0, tostring(s.LUX)) end

mark = section()
expect_ok("call 前 build（IR 极弱场景）", function()
	return build({ fd = fd, address = "0x39" })
end)
dev:set_counts(500, 2000, 0)
s = expect_ok("两线皆负 lux 钳 0", function() return call({ fd = fd, address = "0x39" }) end)
if s then check("LUX=0（CH1>CH0）", s.LUX == 0, tostring(s.LUX)) end

mark = section()
expect_ok("call 前 build（亮场景）", function()
	return build({ fd = fd, address = "0x39" })
end)
dev:set_counts(20000, 3000, 800)
s = expect_ok("亮场 iac1 取大", function() return call({ fd = fd, address = "0x39" }) end)
if s then
	check("LUX 亮场独立重算",
		near(s.LUX, lux_ref(20000, 3000, 1, 18, 52, 0.48), 1e-6),
		tostring(s.LUX))
end

for _, gain in ipairs({ 8, 16, 120 }) do
	mark = section()
	expect_ok("call 前 build（again=x" .. gain .. "）", function()
		return build({ fd = fd, address = "0x39", again = tostring(gain) })
	end)
	dev:set_counts(10000, 2500, 300)
	s = expect_ok("call again=x" .. gain, function()
		return call({ fd = fd, address = "0x39" })
	end)
	if s then
		check("LUX 按 again=x" .. gain .. " 归一",
			near(s.LUX, lux_ref(10000, 2500, gain, 18, 52, 0.48), 1e-6),
			tostring(s.LUX))
	end
end

mark = section()
expect_ok("call 前 build（ga=0.5）", function()
	return build({ fd = fd, address = "0x39", ga = "0.5" })
end)
dev:set_counts(20000, 3000, 0)
s = expect_ok("call ga=0.5", function() return call({ fd = fd, address = "0x39" }) end)
if s then
	check("LUX 按 ga=0.5 换算",
		near(s.LUX, lux_ref(20000, 3000, 1, 18, 52, 0.5), 1e-6), tostring(s.LUX))
end

mark = section()
expect_ok("call 前 build（df=70）", function()
	return build({ fd = fd, address = "0x39", df = "70" })
end)
dev:set_counts(20000, 3000, 0)
s = expect_ok("call df=70", function() return call({ fd = fd, address = "0x39" }) end)
if s then
	check("LUX 按 df=70 换算",
		near(s.LUX, lux_ref(20000, 3000, 1, 18, 70, 0.48), 1e-6), tostring(s.LUX))
end

mark = section()
expect_ok("call 前 build（atime=100ms/36 周期）", function()
	return build({ fd = fd, address = "0x39", atime = "100" })
end)
dev:set_counts(20000, 3000, 0)
s = expect_ok("call atime=100ms", function() return call({ fd = fd, address = "0x39" }) end)
if s then
	check("LUX 按 36 周期归一",
		near(s.LUX, lux_ref(20000, 3000, 1, 36, 52, 0.48), 1e-6), tostring(s.LUX))
end

-- =====================================================================
-- 组 6：真实 call 错误路径
-- =====================================================================
mark = section()
expect_ok("call 失败用例前 build", function()
	return build({ fd = fd, address = "0x39" })
end)
dev:set_counts(10000, 2500, 517)
dev:fail_write(function(b) return #b == 1 and b[1] == 0xB4 end)
mark = #vbus.txlog
expect_err("call CH0 指针写 NACK", function()
	return call({ fd = fd, address = "0x39" })
end, "read CH0 failed")
check("CH0 指针失败 txlog=2（set+失败指针写，无 r）",
	#entries(mark) == 2, tostring(#entries(mark)))

dev:clear_faults()
dev:fail_read(function(p) return p == 0x14 end)
mark = #vbus.txlog
expect_err("call CH0 数据阶段 NACK", function()
	return call({ fd = fd, address = "0x39" })
end, "read CH0 failed")
check("CH0 数据 NACK txlog=3（set+指针写+r，失败 r 留痕）",
	#entries(mark) == 3, tostring(#entries(mark)))

dev:clear_faults()
dev:fail_write(function(b) return #b == 1 and b[1] == 0xB6 end)
mark = #vbus.txlog
expect_err("call CH1 指针写 NACK", function()
	return call({ fd = fd, address = "0x39" })
end, "read CH1 failed")
check("CH1 指针失败 txlog=4（CH0 已完整读）", #entries(mark) == 4,
	tostring(#entries(mark)))

dev:clear_faults()
dev:fail_write(function(b) return #b == 1 and b[1] == 0xB8 end)
mark = #vbus.txlog
expect_err("call PROX 指针写 NACK", function()
	return call({ fd = fd, address = "0x39" })
end, "read PROX failed")
check("PROX 指针失败 txlog=6（CH0/CH1 已完整读，无 r）",
	#entries(mark) == 6, tostring(#entries(mark)))
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 非表参数", function() return call(9) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
check("call 参数错误不发总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call 无器件地址 0x40", function()
	return call({ fd = fd, address = "0x40" })
end, "read CH0 failed")
check("无器件 call txlog=2（set+失败指针写）", #entries(mark) == 2,
	tostring(#entries(mark)))

-- =====================================================================
-- 组 7：destroy
-- =====================================================================
mark = section()
expect_ok("destroy 前 build", function()
	return build({ fd = fd, address = "0x39" })
end)
mark = #vbus.txlog
expect_ok("destroy 断电", function()
	return destroy({ fd = fd, address = "0x39" })
end)
check("destroy 2 txlog（set+{80,00}）",
	#entries(mark) == 2 and wcodes(mark)[1] == 0x8000,
	tostring(#entries(mark)))
check("destroy 后 ENABLE=0（配置寄存器保留）",
	dev:enable() == 0 and dev:atime() == 238,
	string.format("EN=%02X ATIME=%d", dev:enable(), dev:atime()))

mark = section()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
check("缺 fd 不发任何事务", #entries(mark) == 0, tostring(#entries(mark)))

expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
tester.summary("APDS9900 结果")

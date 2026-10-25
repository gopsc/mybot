-- test_ina226.lua —— INA226 真实驱动 + 虚拟 I2C 总线 + 字寻址寄存器模型
-- 用法（项目根目录）: luajit test/test_ina226.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：INA_GC=1 luajit test/test_ina226.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 185 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/ina226.lua 模型」。INA226 与 INA219 同为【字寻址
-- 16 位寄存器 I2C 器件】（寄存器号 0x00~0x07 各代表一个 16 位字，写恒
-- {ptr,hi,lo}、读恒「写 ptr + 读 2 字节」，绝不能套字节地址 regmap），
-- 但协议事实差异逐条不同（勿照搬任何常数）：
--   CONFIG 复位默认 0x4127（bit14 保留恒 1、bit13:12 恒 0；位布局 RST/
--   AVG/VBUSCT/VSHCT/MODE，非 INA219 的 BRNG/PGA/SADC/BADC），RST bit15
--   自清不落盘、原地全文件复位；
--   SHUNT 16 位完整有符号无移位，LSB 2.5µV、量程固定 ±81.92mV（无 PGA，
--   INA219 是 10µV ×PGA/8 ±320mV）；
--   BUS 16 位无符号【无移位】直读，LSB 1.25mV（INA219 是 13 位 <<3 /
--   4mV 带 CNVR/OVF 标志；INA226 标志在独立 0x06 MASK/ENABLE）；
--   有真 ROM ID：0xFE=0x5449（'TI'）/0xFF=0x2260，只读，build 双 ID
--   甄别 + 复位默认值辅助校验（INA219 无 ID 寄存器）；
--   0x03 POWER/0x04 CURRENT/0x05 CALIB 驱动不用，全软件换算 I=Vshunt/R、
--   P=Vbus·I。
-- 连续模式（MODE=111 build 固定）结果恒有值，无转换门/无 pending；build 的
-- 10ms 复位等待 + ceil(2·ct·avg/1000)+2 首循环等待只是 sleep，模型不计时。
--
-- 覆盖：模型侧 POR 与 ROM ID/字寻址不串读/坏帧 NACK 不动指针/CONFIG 保留位
-- 读合成/ROM 写 ACK 丢弃/RST 自清全复位且不清 who 身份/s16 满码钳制/u16
-- 总线直读无移位/跨字 burst 奇尾补 0/物理量独立量化交叉/virt_tick 峰谷周期/
-- 六类钩子与 reset 保留钩子/who 覆写与显式恢复；真实 build 9 事务序列/
-- avg×ct 八八档配置字与睡眠表/向下降档与非法归一/双 ID 误挂/config 失配/
-- 十路负路径；真实 call 5 事务/正负电流功率/±满程/virt_tick 闭环/六路
-- 失败短路（未 build 守卫 1 条 set）；destroy 零事务。

if os.getenv("INA_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/ina226.lua")
vbus.reset()

local ADDR = 0x40
local dev = smod.new()
vbus.attach("INA226@0x40", ADDR, dev)
vbus.load_driver("modules/INA226.lua")

-- milli_sleep：累计时长（本模型无虚拟时钟，只累计供睡眠断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件回上电态 + 故障解除 + who 身份显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0x5449, 0x2260)
	dev:set_reset_cfg(0x4127)
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
-- 窗口内寄存器写 {ptr,hi,lo} 的字序列
local function write_words(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 3 then t[#t + 1] = b[1] * 65536 + b[2] * 256 + b[3] end
	end
	return t
end
local function b_arg(t, c) return { fd = fd, address = "0x40", avg = t, ct = c } end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("上电 CONFIG 默认 0x4127", dev:config() == 0x4127, string.format("0x%04X", dev:config()))
check("上电 MFG 0x5449", dev:mfg() == 0x5449, string.format("0x%04X", dev:mfg()))
check("上电 DIE 0x2260", dev:die() == 0x2260, string.format("0x%04X", dev:die()))
check("上电 SHUNT 为 0", dev:shunt_raw() == 0, tostring(dev:shunt_raw()))
check("上电 BUS 为 0", dev:bus_raw() == 0, tostring(dev:bus_raw()))
check("上电 ptr=0", dev:pointer() == 0, tostring(dev:pointer()))

-- 未预置字读作 0（0x03 POWER / 0x05 CALIB）
check("指针写 0x03", dev.write({ 0x03 }) == true)
local r3 = dev.read(2)
check("未预置字读 0x0000", r3 ~= nil and r3[1] == 0 and r3[2] == 0, r3 and table.concat(r3, ","))

-- 字寻址不串读：相邻字各自独立
dev.write({ 0x01, 0x12, 0x34 })
dev.write({ 0x02, 0xBE, 0xEF })
dev.write({ 0x01 })
local w1 = dev.read(2)
check("字 0x01 读回 0x1234", w1[1] == 0x12 and w1[2] == 0x34, table.concat(w1, ","))
dev.write({ 0x02 })
local w2 = dev.read(2)
check("字 0x02 读回 0xBEEF（不串字）", w2[1] == 0xBE and w2[2] == 0xEF, table.concat(w2, ","))

-- 跨字 burst：n>2 按字自增续读、奇数尾补 0
dev:set_word(0x03, 0xAAAA)
dev:set_word(0x04, 0xBBBB)
dev.write({ 0x03 })
local b5 = dev.read(5)
check("跨字 burst AA AA BB BB 00", b5[1] == 0xAA and b5[2] == 0xAA and b5[3] == 0xBB
      and b5[4] == 0xBB and b5[5] == 0x00, table.concat(b5, ","))

-- 坏长度：恰 1（指针）/恰 3（字写）合法，2/4/0/非 table 全 NACK
check("2 字节写 NACK", dev.write({ 0x00, 0x39 }) == false)
check("4 字节写 NACK", dev.write({ 0x00, 0x12, 0x34, 0x56 }) == false)
check("空表写 NACK", dev.write({}) == false)
check("非 table 写 NACK", dev.write(nil) == false)
check("字符串写 NACK", dev.write("x") == false)
check("read(0) NACK", dev.read(0) == nil)
check("坏帧不动指针（仍 0x03）", dev:pointer() == 0x03, string.format("0x%02X", dev:pointer()))

-- CONFIG 保留位读合成：bit14 恒 1、bit13:12 恒 0
dev.write({ 0x00, 0x00, 0x00 })
check("写 0x0000 读回 0x4000（bit14 合成）", dev:config() == 0x4000,
      string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x70, 0x07 })
check("写 0x7007 读回 0x4007（13:12 保留恒 0）", dev:config() == 0x4007,
      string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x0F, 0xFF })
check("写 0x0FFF 读回 0x4FFF", dev:config() == 0x4FFF,
      string.format("0x%04X", dev:config()))

-- ROM ID 只读：写 ACK 但丢弃
check("写 MFG ACK", dev.write({ 0xFE, 0x12, 0x34 }) == true)
check("MFG 不被改写", dev:mfg() == 0x5449, string.format("0x%04X", dev:mfg()))
check("写 DIE ACK", dev.write({ 0xFF, 0xAA, 0xBB }) == true)
check("DIE 不被改写", dev:die() == 0x2260, string.format("0x%04X", dev:die()))

-- RST：0x8000 不落盘、CONFIG 回默认、全文件复位、计数 +1
check("section 后复位计数 0", dev:reset_count() == 0)
dev.write({ 0x00, 0x12, 0x34 })
dev:set_shunt_raw(1234)
dev:set_word(0x05, 0xABCD)
check("RST 写 ACK", dev.write({ 0x00, 0x80, 0x00 }))
check("RST 后 CONFIG 回 0x4127", dev:config() == 0x4127, string.format("0x%04X", dev:config()))
check("RST 后 SHUNT 清空", dev:shunt_raw() == 0, tostring(dev:shunt_raw()))
check("RST 后 CALIB 清空", dev:word(0x05) == 0, string.format("0x%04X", dev:word(0x05)))
check("RST 位不落盘（读回非 0x8000）", dev:config() == 0x4127)
check("复位计数 1", dev:reset_count() == 1, tostring(dev:reset_count()))
dev.write({ 0x00, 0x80, 0x01 })
check("0x8001 也复位且计数 2", dev:config() == 0x4127 and dev:reset_count() == 2,
      string.format("0x%04X cnt=%s", dev:config(), tostring(dev:reset_count())))

-- who 身份覆写：软复位不恢复（喂 build 误挂），section 显式恢复
dev:who(0x0000, 0x2260)
check("who 覆写 MFG=0", dev:mfg() == 0x0000)
dev.write({ 0x00, 0x80, 0x00 })
check("RST 不恢复出厂 MFG", dev:mfg() == 0x0000)
dev:who(0x5449, 0x0000)
check("who 覆写 DIE=0", dev:die() == 0x0000)
dev:who(nil, 0x2260)
check("who(nil,...) 只改 DIE", dev:mfg() == 0x5449 and dev:die() == 0x2260)

-- s16 SHUNT（2.5µV，满码 ±32768/32767，量程 ±81.92mV）
dev:set_shunt_raw(32000)
check("+32000 码 0x7D00", (function()
	dev.write({ 0x01 }); local r = dev.read(2)
	return r[1] == 0x7D and r[2] == 0x00 end)())
dev:set_shunt_raw(-1)
check("-1 码 0xFFFF", (function()
	dev.write({ 0x01 }); local r = dev.read(2)
	return r[1] == 0xFF and r[2] == 0xFF end)())
check("-1 观察口解码", dev:shunt_raw() == -1)
check("-1 LSB = -2.5µV", near(dev:shunt_v(), -2.5e-6), tostring(dev:shunt_v()))
dev:set_shunt_raw(-32768)
check("负满码 -32768", dev:shunt_raw() == -32768)
check("负满程 -81.92mV", near(dev:shunt_v(), -0.08192), tostring(dev:shunt_v()))
dev:set_shunt_raw(32767)
check("正满码 32767", dev:shunt_raw() == 32767)
check("正满程 81.9175mV", near(dev:shunt_v(), 0.0819175), tostring(dev:shunt_v()))
dev:set_shunt_raw(999999)
check("正超程钳 32767", dev:shunt_raw() == 32767)
dev:set_shunt_raw(-999999)
check("负超程钳 -32768", dev:shunt_raw() == -32768)

-- u16 BUS（1.25mV 直读、无移位、无标志位）
dev:set_bus_raw(0xFFFF)
check("BUS 满码 0xFFFF（无左移/无标志）", dev:bus_raw() == 0xFFFF)
check("满码 81.91875V", near(dev:bus_v(), 81.91875), tostring(dev:bus_v()))
dev:set_bus_v(12)
check("12V → 码 9600（不左移）", dev:bus_raw() == 9600, tostring(dev:bus_raw()))
check("观察口回读 12V", near(dev:bus_v(), 12, 6.3e-4), tostring(dev:bus_v()))
dev:set_bus_v(36)
check("36V → 码 28800", dev:bus_raw() == 28800, tostring(dev:bus_raw()))
dev:set_bus_v(-5)
check("负压钳 0", dev:bus_raw() == 0)

-- 物理量独立交叉（2.5µV / 1.25mV 粒度）
dev:set_vip(24, 0.04)
check("24V → 19200 码", dev:bus_raw() == 19200, tostring(dev:bus_raw()))
check("40mV → 16000 LSB", dev:shunt_raw() == 16000, tostring(dev:shunt_raw()))
check("40mV/0.05Ω = 0.8A", near(dev:current_a(0.05), 0.8), tostring(dev:current_a(0.05)))
check("P = 19.2W", near(dev:power_w(0.05), 19.2), tostring(dev:power_w(0.05)))
check("40mV/0.1Ω = 0.4A", near(dev:current_a(0.1), 0.4), tostring(dev:current_a(0.1)))
dev:set_current_a(-0.3, 0.1)
check("set_current_a -0.3A → -0.03V 码 -12000", dev:shunt_raw() == -12000,
      tostring(dev:shunt_raw()))

-- virt_tick：确定性 / 峰谷 / 32 拍周期
local t1, t2 = smod.new(), smod.new()
t1:virt_tick(5); t2:virt_tick(5)
check("virt_tick 确定性", t1:bus_raw() == t2:bus_raw() and t1:shunt_raw() == t2:shunt_raw())
local tk = smod.new()
tk:virt_tick(0)
check("n0 = 12.0V/0.5A", near(tk:bus_v(), 12, 6.3e-4) and near(tk:current_a(0.1), 0.5),
      string.format("%sV %sA", tostring(tk:bus_v()), tostring(tk:current_a(0.1))))
check("n0 shunt 码 20000", tk:shunt_raw() == 20000, tostring(tk:shunt_raw()))
tk:virt_tick(8)
check("n8 峰 = 12.4V/0.8A", near(tk:bus_v(), 12.4, 6.3e-4) and near(tk:current_a(0.1), 0.8),
      string.format("%sV %sA", tostring(tk:bus_v()), tostring(tk:current_a(0.1))))
check("n8 shunt 码 32000", tk:shunt_raw() == 32000, tostring(tk:shunt_raw()))
tk:virt_tick(24)
check("n24 谷 = 11.6V/0.2A", near(tk:bus_v(), 11.6, 6.3e-4) and near(tk:current_a(0.1), 0.2),
      string.format("%sV %sA", tostring(tk:bus_v()), tostring(tk:current_a(0.1))))
check("n24 shunt 码 8000", tk:shunt_raw() == 8000, tostring(tk:shunt_raw()))
tk:virt_tick(32)
check("n32 = n0（32 拍周期）", near(tk:bus_v(), 12, 6.3e-4) and near(tk:current_a(0.1), 0.5))

-- 故障钩子
section()
check("挂 fail_write", dev:fail_write(function(b) return b[1] == 0x05 end) ~= nil)
check("定向写失败", dev.write({ 0x05, 0x12, 0x34 }) == false)
check("他寄存器照常", dev.write({ 0x03, 0x12, 0x34 }))
dev:clear_faults()
check("挂 fail_read", dev:fail_read(function(p, n) return p == 0x06 and n == 2 end) ~= nil)
dev.write({ 0x06 })
check("0x06 定向读失败", dev.read(2) == nil)
dev.write({ 0x03 })
check("0x03 读照常", dev.read(2) ~= nil)
dev:clear_faults()
dev.nack_write = true
check("nack_write 全写失败", dev.write({ 0x00, 0x80, 0x00 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 全读失败", dev.read(2) == nil)
dev.nack_read = false
dev.nack = true
check("nack 读写全失败", dev.write({ 0x00 }) == false and dev.read(2) == nil)
dev.nack = false
-- reset 保留故障钩子
dev:fail_write(function(b) return b[1] == 0x05 end)
dev:reset()
check("reset 后写钩子仍在", dev.write({ 0x05, 0x00, 0x01 }) == false)
-- reset 保留 who 身份（须显式恢复）
dev:who(0x1111)
dev:reset()
check("reset 保留 who 身份", dev:mfg() == 0x1111)
dev:clear_faults()
-- set_reset_cfg：复位默认值失配喂 build
dev:set_reset_cfg(0x0000)
check("set_reset_cfg 立即置位", dev:config() == 0x4000, string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x80, 0x00 })
check("RST 后仍是覆写默认 0x4000", dev:config() == 0x4000,
      string.format("0x%04X", dev:config()))
dev:set_reset_cfg(0x4127)

-- 留痕：config_writes 只收 3 字节字写
section()
dev.write({ 0x01 })
dev.write({ 0x00, 0x80, 0x00 })
dev.write({ 0x00, 0x45, 0x27 })
local cw = dev:config_writes()
check("config_writes 两笔字写（指针写不计）", #cw == 2
      and cw[1].reg == 0 and cw[1].word == 0x8000
      and cw[2].reg == 0 and cw[2].word == 0x4527,
      tostring(#cw))
dev:reset_logs()
check("reset_logs 清空", #dev:config_writes() == 0)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
mark = section()

local r = build({ fd = fd, address = "0x40" })
check("build 默认参数 OK", r.result == "OK", tostring(r.message))
-- 事务序列：set → RST 字写 → MFG(ptr+r) → DIE(ptr+r) → CONFIG 回显(ptr+r)
--           → 工作配置字写，共 9 条 txlog
local t = entries(mark)
check("build 9 txlog", #t == 9, tostring(#t))
check("build 序列 set→RST→MFG→DIE→CFG 回显→工作字",
      t[1].dir == "set" and
      t[2].dir == "w" and t[2].bytes[1] == 0x00 and t[2].bytes[2] == 0x80 and t[2].bytes[3] == 0x00 and
      t[3].dir == "w" and t[3].bytes[1] == 0xFE and t[4].dir == "r" and t[4].bytes.n == 2 and
      t[5].dir == "w" and t[5].bytes[1] == 0xFF and t[6].dir == "r" and t[6].bytes.n == 2 and
      t[7].dir == "w" and t[7].bytes[1] == 0x00 and t[8].dir == "r" and t[8].bytes.n == 2 and
      t[9].dir == "w" and t[9].bytes[1] == 0x00 and t[9].bytes[2] == 0x45 and t[9].bytes[3] == 0x27)
local ww = write_words(mark)
check("build 两笔字写 0x8000/0x4527", #ww == 2 and ww[1] == 0x008000 and ww[2] == 0x004527,
      table.concat(ww, ","))
check("build 三次 2B 读（MFG/DIE/CFG）", #reads(mark) == 3, tostring(#reads(mark)))
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR)
check("build 睡眠 10+38=48ms", sleep_total == 48, tostring(sleep_total))
check("build 触发一次软复位", dev:reset_count() == 1, tostring(dev:reset_count()))
check("build 后 CONFIG=0x4527", dev:config() == 0x4527, string.format("0x%04X", dev:config()))

-- 字符串 fd
section()
expect_ok("build 字符串 fd='3'", function() return build({ fd = "3", address = "0x40" }) end)

-- avg 八档（ct 缺省 1100 码4）：0x4127|code<<9，睡眠 10+ceil(2·1100·n/1000)+2
local avg_cases = {
	{    1, 0x4127,   15 }, {    4, 0x4327,   21 }, {   16, 0x4527,   48 },
	{   64, 0x4727,  153 }, {  128, 0x4927,  294 }, {  256, 0x4B27,  576 },
	{  512, 0x4D27, 1139 }, { 1024, 0x4F27, 2265 },
}
for _, c in ipairs(avg_cases) do
	section()
	local rr = build(b_arg(tostring(c[1]), nil))
	check(string.format("avg=%d → 0x%04X", c[1], c[2]),
		rr.result == "OK" and dev:config() == c[2],
		rr.result .. " " .. (rr.message or string.format("0x%04X", dev:config())))
	check(string.format("avg=%d 睡眠 %dms", c[1], c[3]), sleep_total == c[3], tostring(sleep_total))
end

-- ct 八档（avg 缺省 16 码2）：0x4407 起按 c<<6|c<<3，睡眠同公式
local ct_cases = {
	{  140, 0x4407,  17 }, {  204, 0x444F,  19 }, {  332, 0x4497,  23 },
	{  588, 0x44DF,  31 }, { 1100, 0x4527,  48 }, { 2116, 0x456F,  80 },
	{ 4156, 0x45B7, 145 }, { 8244, 0x45FF, 276 },
}
for _, c in ipairs(ct_cases) do
	section()
	local rr = build(b_arg(nil, tostring(c[1])))
	check(string.format("ct=%d → 0x%04X", c[1], c[2]),
		rr.result == "OK" and dev:config() == c[2],
		rr.result .. " " .. (rr.message or string.format("0x%04X", dev:config())))
	check(string.format("ct=%d 睡眠 %dms", c[1], c[3]), sleep_total == c[3], tostring(sleep_total))
end

-- 双档最快/最慢
section()
r = build({ fd = fd, address = "0x40", avg = "1", ct = "140" })
check("avg1/ct140 → 0x4007", r.result == "OK" and dev:config() == 0x4007,
      tostring(r.message) .. string.format(" 0x%04X", dev:config()))
check("最快档睡眠 13ms", sleep_total == 13, tostring(sleep_total))
section()
r = build({ fd = fd, address = "0x40", avg = "1024", ct = "8244" })
check("avg1024/ct8244 → 0x4FFF", r.result == "OK" and dev:config() == 0x4FFF,
      tostring(r.message) .. string.format(" 0x%04X", dev:config()))
check("最慢档睡眠 16896ms", sleep_total == 16896, tostring(sleep_total))

-- 向下降档/非法归一
local norm_cases = {
	{ "3", nil, 0x4127 }, { "15", nil, 0x4327 }, { "2000", nil, 0x4F27 },
	{ "-", nil, 0x4527 }, { "abc", nil, 0x4527 }, { "0", nil, 0x4527 }, { "-5", nil, 0x4527 },
	{ nil, "300", 0x444F }, { nil, "99999", 0x45FF }, { nil, "100", 0x4527 },
	{ nil, "-", 0x4527 }, { nil, "abc", 0x4527 },
}
for _, c in ipairs(norm_cases) do
	section()
	local rr = build({ fd = fd, address = "0x40", avg = c[1], ct = c[2] })
	check(string.format("avg='%s' ct='%s' 归一 → 0x%04X", tostring(c[1]), tostring(c[2]), c[3]),
		rr.result == "OK" and dev:config() == c[3],
		rr.message or string.format("0x%04X", dev:config()))
end

-- rshunt 归一（'-'/非法/负数 → 0.1Ω），call 电流验证
for _, rv in ipairs({ "-", "abc", "-1", "0" }) do
	section()
	expect_ok("build rshunt='" .. rv .. "'", function()
		return build({ fd = fd, address = "0x40", rshunt = rv })
	end)
	dev:set_shunt_raw(20000)	-- 50mV
	local crx = call({ fd = fd, address = "0x40" })
	check("rshunt='" .. rv .. "' 归缺省 → I=0.5A",
		crx.result == "OK" and near(crx.I, 0.5), tostring(crx.I))
end

-- ROM ID 误挂
mark = section()
dev:who(0x0000)
expect_err("build MFG 不符", function()
	return build({ fd = fd, address = "0x40" })
end, "Manufacturer ID")
check("MFG 错 4 txlog（set+wRST+wFE+r，挂载 r 先留痕再回调）",
      #entries(mark) == 4, tostring(#entries(mark)))
dev:who(0x5449)

mark = section()
dev:who(nil, 0x0000)
expect_err("build DIE 不符", function()
	return build({ fd = fd, address = "0x40" })
end, "Die ID")
check("DIE 错 6 txlog", #entries(mark) == 6, tostring(#entries(mark)))
dev:who(nil, 0x2260)

-- CONFIG 失配
mark = section()
dev:set_reset_cfg(0x0000)
expect_err("build 复位配置失配", function()
	return build({ fd = fd, address = "0x40" })
end, "Config after reset")
check("配置失配 8 txlog（读到回显后即失败）", #entries(mark) == 8, tostring(#entries(mark)))
dev:set_reset_cfg(0x4127)

-- build 负路径
mark = section()
expect_err("build 非 table", function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x40" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x40" })
end, "set_addr failed")
check("fd=99 开窗零 txlog（set 在留痕前失败）", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60", function()
	return build({ fd = fd, address = "0x60" })
end, "reset")
check("错地址 set+w 两 txlog（无挂载 RST 写 NACK）", #entries(mark) == 2
      and set_addrs(mark)[1] == 0x60, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x00 and b[2] == 0x80 end)
expect_err("build RST 写失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to write INA226 reset")
check("RST 写失败 2 txlog", #entries(mark) == 2, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0xFE end)
expect_err("build MFG 读失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to read INA226 manufacturer ID")
check("MFG 读失败 4 txlog（wFE 后 r 留痕再 NACK）", #entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0xFF end)
expect_err("build DIE 读失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to read INA226 die ID")
check("DIE 读失败 6 txlog", #entries(mark) == 6, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0x00 end)
expect_err("build CONFIG 回显读失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to read INA226 config")
check("CONFIG 读失败 8 txlog", #entries(mark) == 8, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
local seen_rst = false
dev:fail_write(function(b)
	if #b == 3 and b[1] == 0x00 then
		if b[2] == 0x80 then seen_rst = true; return false end
		return seen_rst		-- RST 之后的工作配置写失败
	end
	return false
end)
expect_err("build 工作配置写失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to write INA226 config")
check("工作配置写失败 9 txlog", #entries(mark) == 9, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
mark = section()
expect_ok("call 组前置 build（rshunt=0.1）", function()
	return build({ fd = fd, address = "0x40" })
end)
mark = #vbus.txlog	-- 窗口移到 build 后（sleep_total 保留 build 48ms）

dev:set_shunt_raw(20000)	-- 50mV
dev:set_bus_raw(9600)		-- 12V
local cr = expect_ok("call 正常读值", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("V = 12.0V", near(cr.V, 12, 6.3e-4), tostring(cr.V))
	check("I = 50mV/0.1Ω = 0.5A", near(cr.I, 0.5), tostring(cr.I))
	check("P = 6.0W", near(cr.P, 6.0), tostring(cr.P))
end

-- 事务序列：set + 两次「ptr 写 + 2B 读」（0x01 分流、0x02 总线）
local cw1 = writes(mark)
check("call 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
check("call 两笔纯指针写 0x01/0x02",
	#cw1 == 2 and cw1[1][1] == 0x01 and cw1[2][1] == 0x02 and #cw1[1] == 1 and #cw1[2] == 1,
	#cw1 .. ":" .. (cw1[1] and cw1[1][1]) .. "/" .. (cw1[2] and cw1[2][1]))
check("call 两次 2B 读", #reads(mark) == 2, tostring(#reads(mark)))
check("call 共 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
check("call 自身零睡眠（仍 build 的 48ms）", sleep_total == 48, tostring(sleep_total))

-- 反流/负功率
dev:set_shunt_raw(-20000)
cr = expect_ok("call 反流", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("I = -0.5A", near(cr.I, -0.5), tostring(cr.I))
	check("P = -6W", near(cr.P, -6.0), tostring(cr.P))
end

-- -1 LSB = -2.5µV → -25µA @0.1
dev:set_shunt_raw(-1)
cr = call({ fd = fd, address = "0x40" })
check("-1 LSB → -25µA", cr.result == "OK" and near(cr.I, -0.000025), tostring(cr.I))

-- 满量程 ±32768 LSB = ±81.92mV → ±0.8192A @0.1（正码钳到 32767）
dev:set_shunt_raw(32768)
cr = call({ fd = fd, address = "0x40" })
check("正满程 0.819175A（码钳 32767）", near(cr.I, 0.819175), tostring(cr.I))
dev:set_shunt_raw(-32768)
cr = call({ fd = fd, address = "0x40" })
check("负满程 -0.8192A", near(cr.I, -0.8192), tostring(cr.I))

-- BUS 满码无标志：0xFFFF 直接 = 81.91875V（INA219 这里要 >>3，INA226 不挪）
dev:set_shunt_raw(0)
dev:set_bus_raw(0xFFFF)
cr = call({ fd = fd, address = "0x40" })
check("BUS 满码直读 81.91875V（不 >>3）", near(cr.V, 81.91875), tostring(cr.V))

-- 连续三拍不串字（shunt 造数用有符号码，模型内部补码）
local seq = { {  4096, 0x2B66 }, {  8192, 0x2EE0 }, { -4096, 0x249A } }
for i, s in ipairs(seq) do
	dev:set_shunt_raw(s[1])
	dev:set_bus_raw(s[2])
	local x = call({ fd = fd, address = "0x40" })
	local exp_i = s[1] * 2.5e-6 / 0.1
	check("连续读第 " .. i .. " 拍不串字",
		x.result == "OK" and near(x.V, s[2] * 0.00125) and near(x.I, exp_i),
		tostring(x and x.V) .. "/" .. tostring(x and x.I))
end

-- virt_tick 造数 → 驱动正算闭环（独立公式 V=码·1.25mV，I=raw·2.5µV/0.1）
local vexp = { [0] = { 12.0, 0.5 }, [8] = { 12.4, 0.8 }, [24] = { 11.6, 0.2 } }
for n, e in pairs(vexp) do
	dev:virt_tick(n)
	local x = call({ fd = fd, address = "0x40" })
	check(string.format("virt_tick(%d) 闭环 V=%.1f I=%.1f", n, e[1], e[2]),
		near(x.V, e[1], 1e-3) and near(x.I, e[2], 2e-5),
		string.format("%s/%s", tostring(x.V), tostring(x.I)))
end

-- call 负路径
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x40" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
mark = #vbus.txlog
expect_err("call fd=99 set_addr", function() return call({ fd = 99, address = "0x40" }) end,
	"set_addr failed")
check("call fd=99 开窗零 txlog", #entries(mark) == 0, tostring(#entries(mark)))

section()
build({ fd = fd, address = "0x40" })
mark = #vbus.txlog
dev:fail_read(function(p) return p == 0x01 end)
expect_err("call 分流读失败", function() return call({ fd = fd, address = "0x40" }) end,
	"shunt voltage")
check("分流读失败 3 txlog（set+w01+r）", #entries(mark) == 3, tostring(#entries(mark)))
dev:clear_faults()
mark = #vbus.txlog
dev:fail_read(function(p) return p == 0x02 end)
expect_err("call 总线读失败", function() return call({ fd = fd, address = "0x40" }) end,
	"bus voltage")
check("总线读失败 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()
mark = #vbus.txlog
expect_err("call 错地址 0x60", function() return call({ fd = fd, address = "0x60" }) end,
	"shunt voltage")
check("错地址 set+w01 两 txlog（无挂载指针写 NACK 无 r）", #entries(mark) == 2
      and set_addrs(mark)[1] == 0x60, tostring(#entries(mark)))

-- 未 build 守卫：重载驱动（模块级 rshunt 回 nil）+ 新地址挂载
section()
vbus.attach("INA226@0x41", 0x41, smod.new())
vbus.load_driver("modules/INA226.lua")
mark = #vbus.txlog
expect_err("未 build 直接 call", function() return call({ fd = fd, address = "0x41" }) end,
	"build first")
check("未 build 仅 1 条 set（守卫在 set_addr 之后）", #entries(mark) == 1
      and entries(mark)[1].dir == "set", tostring(#entries(mark)))

-- =====================================================================
-- 组 4：destroy（无资源释放，arg_table 校验，零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 无资源释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非 table", function() return destroy("x") end, "Invalid Arguments Type")

tester.summary("test_ina226")

-- test_bh1745.lua —— BH1745NUC 真实驱动 + 虚拟 I2C 总线 + 稀疏字节寄存器模型
-- 用法（项目根目录）: luajit test/test_bh1745.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：BH1745_GC=1 luajit test/test_bh1745.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 198 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/BH1745.lua 尾部 BH1745_VIRT，
-- 2026-09-15 自 virtbus/bh1745.lua 迁入）」。协议事实照 datasheet
-- BH1745NUC Rev.002（2016-05-23）逐位核对：
--   寄存器图 0x40 SYSTEM_CONTROL（bit7 SW reset/bit6 INT reset 自清，
--     [5:0] Part ID ROM 0x0B）、0x41 MODE1 积分时间码 0..5
--     （160/320/640/1280/2560/5120ms，6/7 forbidden）、0x42 MODE2
--     （bit7 VALID 只读动态合成、读 0x42 也清 VALID；bit4 RGBC_EN；
--     [1:0] 增益 x1/x2/x16）、0x44 MODE3（写 0x02）、0x50~0x57
--     RGBC 数据【小端 LSB 在偶地址】、0x58/59 DINT、0x60 INTERRUPT、
--     0x61 PERSISTENCE POR 0x01、0x62/63 TH=0xFFFF、0x64/65 TL=0、
--     0x92 MFR ROM 0xE0；
--   **迁移抓出真实驱动字节序 bug**：旧驱动按大端 R=b1*256+b2 拼字，
--   datasheet Command Set 明确 0x50=RED_DATA_LSBs，已修 modules/BH1745.lua
--   为 R=b2*256+b1（旧桩用大端喂数互证假绿，本测试期望小端 0x1234）。
--
-- 真实 build：set + {40,80} 软复位 + 5ms + 0x40/0x92 双 ID 读（两读
-- 无条件都发）+ {41}{42}{44} 三笔字写 + sleep(mt+2) = 9 txlog，
-- 缺省档睡眠 5+162=167ms。真实 call：set + {50} 指针 + 8B burst = 3
-- txlog 零睡眠。无未 build 守卫，裸 call 合法读 0。
--
-- 覆盖：模型侧 POR/双 ID/SW·INT reset 自清/保留位抹除/forbidden 时间码/
-- VALID 读写翻转与「读 0x42 清 VALID」/积分门 advance 边界与连续周期/
-- 数据小端编码与四通道拆分/只读区写丢弃/未定义地址/坏帧 NACK/burst
-- 0xFF 回绕/中断阈值位域/超程钳/virt_tick 正弦/六类钩子；真实 build
-- 六档 mt 与三档 gain snap_down/双 ID 甄别负路径/三笔配置写精确短路/
-- 复位清注入；真实 call 小端拆分/失败短路/裸 call/virt_tick 闭环；
-- destroy 零事务。

if os.getenv("BH1745_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x38
-- 模型内嵌于驱动文件（BH1745_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/BH1745.lua")
local smod = BH1745_VIRT

local dev = smod.new()
vbus.attach("BH1745@0x38", ADDR, dev)

-- milli_sleep：累计时长 + 推模型积分门（守护不打桩，单测验证协议时序）
local sleep_total = 0
function milli_sleep(ms)
	sleep_total = sleep_total + ms
	dev:advance(ms)
end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 每个 section：器件回上电态 + 故障解除 + who 显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0x0B, 0xE0)
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
-- 窗口内寄存器写 {reg,val}（≥2B 事务首两字节）
local function reg_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b >= 2 then t[#t + 1] = { reg = b[1], val = b[2] } end
	end
	return t
end
local function write_of(mark, reg)
	for _, e in ipairs(reg_writes(mark)) do
		if e.reg == reg then return e.val end
	end
	return nil
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

-- ---- POR ----
check("POR SYS=0x0B（Part ID）", dev:reg(0x40) == 0x0B,
      string.format("0x%02X", dev:reg(0x40)))
check("POR MODE1=0x00", dev:reg(0x41) == 0x00)
check("POR MODE2=0x00", dev:reg(0x42) == 0x00)
check("POR MODE3=0x00", dev:reg(0x44) == 0x00)
check("POR PERSISTENCE=0x01", dev:reg(0x61) == 0x01,
      string.format("0x%02X", dev:reg(0x61)))
check("POR TH=0xFFFF（62 LSB/63 MSB）", dev:th() == 0xFFFF,
      string.format("0x%04X", dev:th()))
check("POR TL=0x0000", dev:tl() == 0x0000)
check("POR MFR=0xE0", dev:reg(0x92) == 0xE0,
      string.format("0x%02X", dev:reg(0x92)))
do
	local all_zero = true
	for a = 0x50, 0x59 do
		if dev:reg(a) ~= 0 then all_zero = false end
	end
	check("POR 数据区 0x50~0x59 全 0（含 DINT）", all_zero)
end
check("POR VALID=0/未使能/无积分门",
      dev:valid() == false and dev:enabled() == false
      and dev:remaining_ms() == nil)

-- ---- SW reset / INT reset 命令位 ----
check("SW reset {40,80} 成功", dev.write({ 0x40, 0x80 }) == true)
check("SW reset reset_count=1", dev:reset_count() == 1,
      tostring(dev:reset_count()))
check("SW reset 位自清：读 0x40=0x0B", dev:reg(0x40) == 0x0B,
      string.format("0x%02X", dev:reg(0x40)))
dev:set_rgbc_raw(111, 222, 333, 444)
check("INT reset {40,40} 成功", dev.write({ 0x40, 0x40 }) == true)
check("INT reset int_reset_count=1", dev:int_reset_count() == 1)
check("INT reset 不清数据（非全片复位）", dev:red_raw() == 111
      and dev:clear_raw() == 444, string.format("%d/%d", dev:red_raw(), dev:clear_raw()))
check("INT reset 位自清", dev:reg(0x40) == 0x0B)
check("SW reset 清注入数据/VALID/计数周期", (function()
	dev:virt_tick(3)
	dev.write({ 0x40, 0x80 })
	return dev:red_raw() == 0 and dev:clear_raw() == 0
	   and dev:valid() == false and dev:reset_count() == 2
	   and dev:measure_count() == 0 and dev:remaining_ms() == nil
end)())
check("{40,0B} 低位 ROM 不可写", (function()
	dev.write({ 0x40, 0x0B })
	return dev:reg(0x40) == 0x0B and dev:reset_count() == 2
end)())

-- ---- MODE1 保留位/forbidden 码 ----
dev.write({ 0x41, 0xFA })	-- 0xF8 保留 + 码 2
check("MODE1 [7:3] 保留抹除 → 码 2", dev:reg(0x41) == 0x02,
      string.format("0x%02X", dev:reg(0x41)))
check("MODE1 码 2 = 640ms", dev:period_ms() == 640,
      tostring(dev:period_ms()))
dev.write({ 0x42, 0x10 })	-- 使能
check("使能后 forbidden 码 6/7 无周期门", (function()
	dev.write({ 0x41, 0x06 })
	if dev:remaining_ms() ~= nil then return false end
	dev.write({ 0x41, 0x07 })
	return dev:remaining_ms() == nil
end)())
dev.write({ 0x41, 0x00 })

-- ---- MODE2 位语义 ----
check("MODE2 bit7 VALID/保留位写不落盘（写 0xFF 存 0x13）", (function()
	dev.write({ 0x42, 0xFF })
	return dev:reg(0x42) == 0x13	-- bit4 + bit1:0，抹 bit7/6/5/3/2
end)(), string.format("0x%02X", dev:reg(0x42)))
check("MODE2 gain 三档落位", (function()
	dev.write({ 0x42, 0x10 })
	if dev:gain_code() ~= 0 then return false end
	dev.write({ 0x42, 0x11 })
	if dev:gain_code() ~= 1 then return false end
	dev.write({ 0x42, 0x12 })
	return dev:gain_code() == 2
end)())
check("MODE2 forbidden gain=3 照存（硬件未定义不臆断）", (function()
	dev.write({ 0x42, 0x13 })
	return dev:gain_code() == 3
end)())
dev.write({ 0x42, 0x10 })

-- ---- VALID 动态语义 + 积分门 ----
check("写 MODE 寄存器即重启：VALID 清、remaining=160", (function()
	dev.write({ 0x41, 0x00 })
	return dev:valid() == false and dev:remaining_ms() == 160
end)(), tostring(dev:remaining_ms()))
dev:set_rgbc_raw(1000, 2000, 3000, 4000)
dev:advance(159.9)
check("159.9ms 未就绪 VALID=0", dev:valid() == false)
dev.write({ 0x42 })	-- 纯指针写，不触发 restart
local m2 = dev.read(1)
check("门内读 0x42 = 0x10（VALID 位 0）", m2[1] == 0x10,
      string.format("0x%02X", m2[1]))
dev:advance(0.2)
check("满 160ms 周期到点 VALID=1/measure=1/装载注入码",
      dev:valid() == true and dev:measure_count() == 1
      and dev:red_raw() == 1000 and dev:clear_raw() == 4000)
dev.write({ 0x42 })	-- burst 已自增到 0x43，重新指 0x42
m2 = dev.read(1)
check("读 0x42 回 0x90（VALID 合成位 1）", m2[1] == 0x90,
      string.format("0x%02X", m2[1]))
check("datasheet：读 MODE_CONTROL2 后 VALID 自动清 0",
      dev:valid() == false)
dev:advance(160)
check("连续模式自动排下一周期（measure=2、VALID=1）",
      dev:measure_count() == 2 and dev:valid() == true)
check("写 MODE3 也重启测量清 VALID", (function()
	dev.write({ 0x44, 0x02 })
	return dev:valid() == false and dev:remaining_ms() == 160
end)())
dev.write({ 0x42, 0x00 })
check("RGBC_EN=0 power down：门停", dev:enabled() == false
      and dev:remaining_ms() == nil)
dev:advance(9999)
check("停转后 advance 不出样", dev:measure_count() == 2)

-- ---- 数据块小端编码 ----
mark = section()
dev:set_rgbc_raw(0x1234, 0x5678, 0x9ABC, 0xDEF0)
local bytes = dev.read(8)
-- 先写指针（read 从当前 ptr 起）
dev.write({ 0x50 })
bytes = dev.read(8)
local function hexs(t)
	local s = {}
	for i = 1, #t do s[i] = string.format("%02X", t[i]) end
	return table.concat(s, " ")
end
check("8B burst 小端字节序 34 12 78 56 BC 9A F0 DE",
      hexs(bytes) == "34 12 78 56 BC 9A F0 DE", hexs(bytes))
check("观察口四通道 u16 小端拼字",
      dev:red_raw() == 0x1234 and dev:green_raw() == 0x5678
      and dev:blue_raw() == 0x9ABC and dev:clear_raw() == 0xDEF0)
do
	local r, g, b, c = dev:rgbc_raw()
	check("rgbc_raw 一次返四通道",
	      r == 0x1234 and g == 0x5678 and b == 0x9ABC and c == 0xDEF0)
end
check("单通道 setter 立即生效", (function()
	dev:set_blue_raw(0x0001)
	return dev:blue_raw() == 1 and dev:reg(0x54) == 0x01
	   and dev:reg(0x55) == 0x00
end)())
check("超程钳：负→0、99999→65535", (function()
	dev:set_rgbc_raw(-1, 99999, -100, 70000)
	return dev:red_raw() == 0 and dev:green_raw() == 65535
	   and dev:blue_raw() == 0 and dev:clear_raw() == 65535
end)())

-- ---- 只读区写丢弃 / 未定义地址 ----
mark = section()
check("只读数据区写 ACK 但丢弃", (function()
	for a = 0x50, 0x59 do
		if not dev.write({ a, 0xAA }) then return false end
	end
	if not dev.write({ 0x92, 0x5A }) then return false end
	for a = 0x50, 0x59 do
		if dev:reg(a) ~= 0 then return false end
	end
	return dev:reg(0x92) == 0xE0
end)())
check("未定义地址指针写 ACK、读 0", (function()
	for _, a in ipairs({ 0x43, 0x45, 0x4F, 0x5A, 0x66, 0x91, 0x93, 0xFF }) do
		if not dev.write({ a }) then return false end
		local t = dev.read(1)
		if not t or t[1] ~= 0 then return false end
	end
	return true
end)())
check("未定义地址字写 ACK 丢弃", (function()
	if not dev.write({ 0x43, 0x77 }) then return false end
	return dev:reg(0x43) == 0
end)())

-- ---- burst 自增/回绕/长度 ----
mark = section()
dev.write({ 0x50 })
dev:set_red_raw(0x0102)
bytes = dev.read(3)
check("跨通道 burst：读 3B=R 两字节 + G_LSB",
      bytes[1] == 0x02 and bytes[2] == 0x01 and bytes[3] == 0x00,
      hexs(bytes))
check("0xFF→0x00 算术回绕", (function()
	dev.write({ 0xFF })
	local t = dev.read(2)
	return t[1] == 0 and t[2] == dev:reg(0x00)
end)())
check("无指针纯读 NACK", (function()
	dev:reset()
	return dev.read(2) == nil
end)())
check("read 长度钳 1~16、0/非数 NACK", (function()
	dev.write({ 0x50 })
	if #dev.read(20) ~= 16 then return false end
	if dev.read(0) ~= nil then return false end
	return dev.read(-3) == nil
end)())

-- ---- 坏帧 ----
mark = section()
check("坏帧 nil/字符串/空表/非字节整笔 NACK", (function()
	dev.write({ 0x50 })
	if dev.write(nil) ~= false then return false end
	if dev.write("x") ~= false then return false end
	if dev.write({}) ~= false then return false end
	if dev.write({ 0x41, 256 }) ~= false then return false end
	if dev.write({ 0x41, -1 }) ~= false then return false end
	if dev.write({ 0x41, 1.5 }) ~= false then return false end
	return dev:ptr() == 0x50 and dev:reg(0x41) == 0x00
end)(), string.format("ptr=%s m1=0x%02X", tostring(dev:ptr()), dev:reg(0x41)))

-- ---- 中断/持久化/阈值位域 ----
mark = section()
dev.write({ 0x60, 0xFF })
check("INTERRUPT 位掩码：存 0x1D（LATCH/SOURCE/EN）",
      dev:reg(0x60) == 0x1D, string.format("0x%02X", dev:reg(0x60)))
check("INT STATUS bit7 只读恒 0", dev.read(1)[1] < 0x80)
dev.write({ 0x61 })
dev.write({ 0x61, 0xFF })
check("PERSISTENCE 存低 2 位 = 0x03", dev:reg(0x61) == 0x03,
      string.format("0x%02X", dev:reg(0x61)))
check("阈值对小端 burst 写 {62,34,12} → TH=0x1234", (function()
	dev.write({ 0x62, 0x34, 0x12 })
	return dev:th() == 0x1234
end)(), string.format("0x%04X", dev:th()))
check("TL 单字节写 {64,FF} → TL=0x00FF", (function()
	dev.write({ 0x64, 0xFF })
	return dev:tl() == 0x00FF
end)(), string.format("0x%04X", dev:tl()))

-- ---- virt_tick 确定性正弦 ----
mark = section()
dev:virt_tick(0)
local r0 = dev:red_raw()
check("virt_tick(0) 四通道正、VALID=1、小端可读",
      r0 > 0 and dev:green_raw() > r0 and dev:blue_raw() > 0
      and dev:clear_raw() > dev:green_raw() and dev:valid() == true)
check("virt_tick n8 峰/n16 中值/n24 谷/n32 回周期", (function()
	dev:virt_tick(8)
	local r8 = dev:red_raw()
	dev:virt_tick(16)
	local r16 = dev:red_raw()
	dev:virt_tick(24)
	local r24 = dev:red_raw()
	dev:virt_tick(32)
	local r32 = dev:red_raw()
	return r8 > r0 and math.abs(r16 - r0) <= 1 and r24 < r0
	   and math.abs(r32 - r0) <= 1 and r8 <= 65535 and r24 >= 0
end)())

-- ---- who 身份覆写 ----
mark = section()
check("who 覆写 Part ID/MFR", (function()
	dev:who(0x0C, 0x5A)
	return dev:reg(0x40) == 0x0C and dev:reg(0x92) == 0x5A
end)())
check("who 单项覆写 nil=不改", (function()
	dev:who(0x0B, nil)
	return dev:reg(0x40) == 0x0B and dev:reg(0x92) == 0x5A
end)())
check("who 身份跨软复位保留", (function()
	dev.write({ 0x40, 0x80 })
	return dev:reg(0x40) == 0x0B and dev:reg(0x92) == 0x5A
end)())
dev:who(0x0B, 0xE0)

-- ---- 故障钩子（reset 不解除） ----
mark = section()
check("nack 总线全拒", (function()
	dev.nack = true
	return dev.write({ 0x41, 0x01 }) == false and dev.read(1) == nil
end)())
dev:clear_faults()
check("fail_write 帧谓词", (function()
	dev:fail_write(function(b) return b[1] == 0x41 and #b == 2 end)
	return dev.write({ 0x41, 0x01 }) == false
	   and dev.write({ 0x44, 0x02 }) == true
end)())
check("fail_read(ptr,n) 谓词", (function()
	dev:fail_read(function(p, n) return p == 0x92 and n == 1 end)
	dev.write({ 0x92 })
	if dev.read(1) ~= nil then return false end
	dev.write({ 0x40 })
	return dev.read(1) ~= nil
end)())
check("nack_read 只拒读不拒写", (function()
	dev:clear_faults()
	dev.nack_read = true
	return dev.write({ 0x44, 0x02 }) == true and dev.read(1) == nil
end)())
check("reset 保留故障钩子", (function()
	dev:reset()
	return dev.nack_read == true and dev.read(1) == nil
end)())
dev:clear_faults()

-- =====================================================================
-- 组 2：真实 build（set→软复位→双 ID→三笔配置写→等首拍）
-- =====================================================================
mark = section()
local res = expect_ok("build 默认（160ms/x1）",
      function() return build({ fd = fd, address = "0x38" }) end)
check("build 共 9 txlog", #entries(mark) == 9, tostring(#entries(mark)))
do
	local ws = writes(mark)
	check("首笔写 = 软复位 {40,80}",
	      ws[1][1] == 0x40 and ws[1][2] == 0x80, hexs(ws[1] or {}))
	local rs = reads(mark)
	check("双 ID 各 1B 读（共 2 条 r）", #rs == 2, tostring(#rs))
	check("配置三笔 {41,00}{42,10}{44,02}",
	      write_of(mark, 0x41) == 0x00
	      and write_of(mark, 0x42) == 0x10
	      and write_of(mark, 0x44) == 0x02,
	      string.format("%02X/%02X/%02X",
	        write_of(mark, 0x41) or 0, write_of(mark, 0x42) or 0,
	        write_of(mark, 0x44) or 0))
end
check("build 睡眠 5 + (160+2) = 167ms", sleep_total == 167,
      tostring(sleep_total))
check("build 后已完成首个积分周期（VALID=1/measure=1）",
      dev:valid() == true and dev:measure_count() == 1)

-- ---- mt/gain snap_down 表 ----
local mt_cases = {
	{ mt = "160",  code = 0x00, sleep = 162 },
	{ mt = "320",  code = 0x01, sleep = 322 },
	{ mt = "640",  code = 0x02, sleep = 642 },
	{ mt = "1280", code = 0x03, sleep = 1282 },
	{ mt = "2560", code = 0x04, sleep = 2562 },
	{ mt = "5120", code = 0x05, sleep = 5122 },
	{ mt = "700",  code = 0x02, sleep = 642 },	-- 向下降档 640
	{ mt = "100",  code = 0x00, sleep = 162 },	-- 小于最小归缺省
	{ mt = "-",    code = 0x00, sleep = 162 },
	{ mt = "0",    code = 0x00, sleep = 162 },
	{ mt = "abc",  code = 0x00, sleep = 162 },
}
for _, c in ipairs(mt_cases) do
	mark = section()
	expect_ok("build mt=" .. tostring(c.mt),
	      function() return build({ fd = fd, address = "0x38", mt = c.mt }) end)
	check(string.format("mt=%s → MODE1 码 0x%02X", tostring(c.mt), c.code),
	      write_of(mark, 0x41) == c.code,
	      string.format("0x%02X", write_of(mark, 0x41) or 0))
	check(string.format("mt=%s 睡眠 5+%d=%d", tostring(c.mt), c.sleep,
	      c.sleep + 5), sleep_total == c.sleep + 5, tostring(sleep_total))
end

local gain_cases = {
	{ gain = "1",  val = 0x10 },
	{ gain = "2",  val = 0x11 },
	{ gain = "16", val = 0x12 },
	{ gain = "8",  val = 0x11 },	-- 向下降档 x2
	{ gain = "-",  val = 0x10 },
	{ gain = "0",  val = 0x10 },
	{ gain = "x",  val = 0x10 },
}
for _, c in ipairs(gain_cases) do
	mark = section()
	expect_ok("build gain=" .. tostring(c.gain),
	      function() return build({ fd = fd, address = "0x38", gain = c.gain }) end)
	check(string.format("gain=%s → MODE2=0x%02X", tostring(c.gain), c.val),
	      write_of(mark, 0x42) == c.val,
	      string.format("0x%02X", write_of(mark, 0x42) or 0))
end

mark = section()
expect_ok("build mt=700/gain=16 组合", function()
	return build({ fd = fd, address = "0x38", mt = "700", gain = "16" })
end)
check("组合：MODE1=0x02/MODE2=0x12",
      write_of(mark, 0x41) == 0x02 and write_of(mark, 0x42) == 0x12)

-- 软复位清注入：build 前注入的数据被 {40,80} 清掉
mark = section()
dev:set_rgbc_raw(500, 600, 700, 800)
expect_ok("build 软复位清旧注入", function()
	return build({ fd = fd, address = "0x38" })
end)
check("build 后数据区回 0（SW reset 先于配置）",
      dev:red_raw() == 0 and dev:clear_raw() == 0)

-- ---- build 负路径（精确短路 txlog） ----
mark = section()
expect_err("build 非 table", function() return build("x") end,
      "Invalid Arguments Type")
check("非 table 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 缺 fd", function()
	return build({ address = "0x38" })
end, "fd or address")
check("缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x38" })
end, "set_addr failed")
check("fd=99 零留痕", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60（合法未挂载）", function()
	return build({ fd = fd, address = "0x60" })
end, "soft reset")
check("错地址 set 成功 + 复位写 NACK = 2 事务", #entries(mark) == 2,
      tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x40 end)
expect_err("build 软复位写失败", function()
	return build({ fd = fd, address = "0x38" })
end, "soft reset")
check("复位写失败 = set+w 两事务", #entries(mark) == 2,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0x40 end)
expect_err("build Part ID 读失败", function()
	return build({ fd = fd, address = "0x38" })
end, "ID registers")
-- set + 复位写 + 0x40 读（w+r）+ 0x92 读（w+r，两读无条件都发）= 6
check("0x40 读失败仍发 0x92 读：6 txlog", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0x92 end)
expect_err("build MFR 读失败", function()
	return build({ fd = fd, address = "0x38" })
end, "ID registers")
check("0x92 读失败 = 6 txlog", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:who(0x0C, nil)
expect_err("build Part ID 不符", function()
	return build({ fd = fd, address = "0x38" })
end, "Not BH1745")
check("ID 不符 = 6 txlog（甄别在三笔配置前）", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:who(0x0B, nil)

mark = section()
dev:who(nil, 0x5A)
expect_err("build MFR 不符", function()
	return build({ fd = fd, address = "0x38" })
end, "Not BH1745")
check("MFR 不符 = 6 txlog", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:who(nil, 0xE0)

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x41 end)
expect_err("build MODE1 写失败", function()
	return build({ fd = fd, address = "0x38" })
end, "mode control 1")
-- set+复位写+两 ID 读(4)+失败的 MODE1 写(1) = 7
check("MODE1 失败 = 7 txlog", #entries(mark) == 7,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x42 end)
expect_err("build MODE2 写失败", function()
	return build({ fd = fd, address = "0x38" })
end, "mode control 2")
check("MODE2 失败 = 8 txlog", #entries(mark) == 8,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x44 end)
expect_err("build MODE3 写失败", function()
	return build({ fd = fd, address = "0x38" })
end, "mode control 3")
check("MODE3 失败 = 9 txlog", #entries(mark) == 9,
      tostring(#entries(mark)))
dev:clear_faults()

-- 备地址 0x39 同型号可挂
local dev39 = smod.new()
vbus.attach("BH1745@0x39", 0x39, dev39)
mark = #vbus.txlog
expect_ok("build 备地址 0x39", function()
	return build({ fd = fd, address = "0x39" })
end)
check("0x39 build 9 txlog", #entries(mark) == 9, tostring(#entries(mark)))

-- =====================================================================
-- 组 3：真实 call（set→0x50 指针→8B burst，小端拆四通道）
-- =====================================================================
mark = section()
expect_ok("call 前置 build", function()
	return build({ fd = fd, address = "0x38" })
end)

mark = #vbus.txlog
dev:set_rgbc_raw(0x1234, 0x5678, 0x9ABC, 0xDEF0)
res = expect_ok("call 四通道小端读值", function()
	return call({ fd = fd, address = "0x38" })
end)
if res then
	check("R=0x1234（小端修正后）", res.R == 0x1234, tostring(res.R))
	check("G=0x5678", res.G == 0x5678, tostring(res.G))
	check("B=0x9ABC", res.B == 0x9ABC, tostring(res.B))
	check("C=0xDEF0", res.C == 0xDEF0, tostring(res.C))
end
check("call 共 3 txlog（set + 指针写 + 8B 读）", #entries(mark) == 3,
      tostring(#entries(mark)))
do
	local rs = reads(mark)
	check("call 的 r 是 8 字节 burst", #rs == 1 and rs[1].bytes.n == 8,
	      string.format("%d 条 r/n=%s", #rs,
	        rs[1] and tostring(rs[1].bytes.n) or "nil"))
	check("call 指针写恰 {50}", (function()
		local ws = writes(mark)
		return #ws == 1 and ws[1][1] == 0x50 and #ws[1] == 1
	end)())
end

-- 极端码点
mark = section()
expect_ok("call 前置 build", function()
	return build({ fd = fd, address = "0x38" })
end)
mark = #vbus.txlog
dev:set_rgbc_raw(1, 255, 256, 65535)
res = expect_ok("call 极端码点", function()
	return call({ fd = fd, address = "0x38" })
end)
if res then
	check("1/255/256/65535 精确",
	      res.R == 1 and res.G == 255 and res.B == 256
	      and res.C == 65535,
	      string.format("%d/%d/%d/%d", res.R, res.G, res.B, res.C))
end

-- 裸 call（驱动无模块状态守卫）
mark = section()
res = expect_ok("reload 等价：无 build 裸 call 合法", function()
	return call({ fd = fd, address = "0x38" })
end)
check("裸 call = 3 txlog（set+指针+8B 读）", #entries(mark) == 3,
      tostring(#entries(mark)))
if res then
	check("裸 call 读到 POR 全 0",
	      res.R == 0 and res.G == 0 and res.B == 0 and res.C == 0)
end

-- virt_tick 闭环：守护路径预演（tick 后 call 零睡眠拿到新鲜数据）
mark = section()
expect_ok("tick 闭环前 build", function()
	return build({ fd = fd, address = "0x38" })
end)
local tickvals = {}
for n = 0, 3 do
	dev:virt_tick(n)
	local cr = expect_ok("call after virt_tick(" .. n .. ")",
	      function() return call({ fd = fd, address = "0x38" }) end)
	if cr then
		check(string.format("tick%d 四通道与模型一致", n),
		      cr.R == dev:red_raw() and cr.G == dev:green_raw()
		      and cr.B == dev:blue_raw() and cr.C == dev:clear_raw())
		tickvals[#tickvals + 1] = cr.R
	end
end
check("call 全程零 milli_sleep", sleep_total == 167,
      tostring(sleep_total))
check("tick 间 R 值有变化（正弦）", tickvals[1] ~= tickvals[2]
      or tickvals[2] ~= tickvals[3], table.concat(tickvals, ","))

-- call 负路径
mark = section()
expect_ok("call 失败前 build", function()
	return build({ fd = fd, address = "0x38" })
end)
dev:fail_read(function(p, n) return p == 0x50 and n == 8 end)
mark = #vbus.txlog
expect_err("call 8B 读失败", function()
	return call({ fd = fd, address = "0x38" })
end, "Failed to read")
check("读失败 = set+w+r 三事务", #entries(mark) == 3,
      tostring(#entries(mark)))
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 错地址 0x60 指针写 NACK", function()
	return call({ fd = fd, address = "0x60" })
end, "Failed to read")
check("无挂载指针写失败 = set+w 两事务（无 r）", #entries(mark) == 2,
      tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call 缺 fd", function()
	return call({ address = "0x38" })
end, "fd or address")
check("缺 fd 零事务", #entries(mark) == 0)

mark = #vbus.txlog
expect_err("call 非 table", function() return call(123) end,
      "Invalid Arguments Type: table")

-- =====================================================================
-- 组 4：destroy（arg_table 校验，零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 无资源释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_ok("destroy 带参也 OK", function()
	return destroy({ fd = fd, address = "0x38" })
end)
expect_err("destroy 非 table", function() return destroy("x") end,
      "Invalid Arguments Type")

tester.summary("test_bh1745")

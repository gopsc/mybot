-- test_mlx90393.lua —— MLX90393 真实驱动 + 虚拟 I2C 总线 + status-first 命令模型
-- 用法（项目根目录）: luajit test/test_mlx90393.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：MLX90393_GC=1 luajit test/test_mlx90393.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 263 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MLX90393.lua 尾部 MLX90393_VIRT，
-- 2026-09-15 自 virtbus/mlx90393.lua 迁入）」。旧桩与旧驱动共享同一份
-- 错误假设（status 收尾/bit6/WR 3B/GAIN 在 reg2/[T Z Y X] 序/T/32），
-- 已整体废弃。本文件按 datasheet 3901090393 Rev012 §15（两份官方资料 +
-- Adafruit/tedyapo 实现交叉验证）钉死协议：
--   应答【首字节永远是 status】：bit7 BURST/bit6 WOC/bit5 SM_MODE（单次
--   转换完成）/bit4 ERROR/bit3 SED/bit2 RS（RT 后首帧自清）/bit1:0 D
--   （附加数据 = 2D+2 字节）；RM 按 Status-TXYZ 组帧、zyxt 零分量跳过，
--   XYZT 全帧 9B；RR 2B [0x50,A<<2] → 3B；WR【4B】[0x60,Dhi,Dlo,A<<2]；
--   非法命令 I2C 恒 ACK + ERROR（坏帧才总线 NACK）；客户区 0x00~0x1F、
--   Melexis 区写保护；reg0x00 POR=0x007C（GAIN_SEL=7/HALLCONF=C）。
--   温度 u16：45.2 LSB/°C、25°C=46244；磁场 s16，µT/LSB 换算归驱动。
--
-- 真实 build（milli_sleep 桩转 advance）：set + {F0}+{D0} + RR reg0 r3 +
--   WR 4B + RR 回读 r3 + {3F} + 两次 {00}r1 轮询（默认转换门 2ms）+
--   {4F} r9 = set+9w+5r 共 15 txlog，睡眠 5+2+2=9ms；
-- 真实 call：set + {3F} + 两次 {00}r1 + {4F} r9 = 8 txlog。
--
-- 覆盖：模型 POR/status 合成/RS 自清/非法命令 ACK+ERROR/坏帧 NACK/RR-WR
-- 帧长与 abc/Melexis 写保护/突发中 RRWR 拒/SM 转换门与轮询/RM status-first
-- TXYZ 帧与零分量跳过/RM DRDY 低 ERROR/SB 突发与 SW 模式位/EX/HR/HS/RT/
-- zyxt=0 取 BURST_SEL/set_raw 钳制/set_sample 反算/virt_tick 确定性+预武装/
-- 故障钩子；真实 build 序列逐笔编码/gain RMW 各档与钳位/横幅/参数错误/
-- 五类 NACK 短路点/回读篡改；真实 call 四轴字节序与温度公式/增益档/超时/
-- ERROR 状态/四类总线失败；destroy 安全。

if os.getenv("MLX90393_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x0C
-- 模型内嵌于驱动文件（MLX90393_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MLX90393.lua")
local mmod = MLX90393_VIRT

local dev = mmod.new()
vbus.attach("MLX90393@0x0C", ADDR, dev)

-- milli_sleep 桩：累计并驱动模型虚拟时钟（转换门用）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function rround(v)
	if v >= 0 then return math.floor(v + 0.5) end
	return -math.floor(-v + 0.5)
end

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
local function bytes_of(t)
	local s = {}
	for i = 1, #t do s[i] = string.format("%02X", t[i]) end
	return table.concat(s, ",")
end
local function frame(b) return b and bytes_of(b) or "nil" end

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

-- ---- POR ----
check("POR reg0x00=0x007C（GAIN_SEL=7/HALLCONF=C）",
	dev:reg(0x00) == 0x007C, string.format("0x%04X", dev:reg(0x00)))
check("POR GAIN_SEL=7", dev:gain_sel() == 7, tostring(dev:gain_sel()))
check("POR 其余寄存器 0（reg0x02）", dev:reg(0x02) == 0)
check("POR mode=idle", dev:mode() == "idle", tostring(dev:mode()))
check("POR drdy=false", not dev:is_ready())
check("POR pending=nil", dev:pending() == nil, tostring(dev:pending()))
check("POR status=0x00", dev:current_status() == 0x00,
	string.format("0x%02X", dev:current_status()))
check("POR 种子 T=46244/X/Y/Z=0",
	select(1, dev:raw()) == 46244 and select(2, dev:raw()) == 0
	and select(3, dev:raw()) == 0 and select(4, dev:raw()) == 0)
do
	local sxy, sz = dev:sensitivities()
	check("POR gain7 灵敏度 XY=0.1502/Z=0.2420",
		near(sxy, 0.1502, 1e-9) and near(sz, 0.2420, 1e-9),
		string.format("%.6f/%.6f", sxy, sz))
end

-- ---- NOP/status ----
check("NOP {00} ACK", w(0x00) == true)
check("NOP 后 pending=status", dev:pending() == "status")
local s = r1(1)
check("NOP 读 1B status=0x00", s and #s == 1 and s[1] == 0x00, frame(s))
check("status 读后 pending 清空", dev:pending() == nil)
w(0x00)
check("status pending 读 n=3 NACK", r1(3) == nil)
check("长度不符不消费 pending", dev:pending() == "status")
r1(1)

-- ---- RT / RS 自清 ----
check("RT {F0} ACK", w(0xF0) == true)
s = r1(1)
check("RT 后首 status RS=1（0x04）", s and s[1] == 0x04, frame(s))
w(0x00); s = r1(1)
check("RS 读后自清（NOP status=0x00）", s[1] == 0x00, frame(s))
w(0xF0); dev:advance(1)
w(0x00); s = r1(1)
check("RS 也随 advance 自清", s[1] == 0x00, frame(s))

-- ---- RR ----
check("RR reg0 {50,00} ACK", w(0x50, 0x00) == true)
local rr = r1(3)
check("RR 应答 status-first 3B = 00,00,7C",
	rr and rr[1] == 0x00 and rr[2] == 0x00 and rr[3] == 0x7C, frame(rr))
check("RR 短帧 {50} NACK", w(0x50) == false)
check("RR abc≠0 {50,02} NACK", w(0x50, 0x02) == false)
check("RR 读宽度 2 NACK", (w(0x50, 0x00) and r1(2)) == nil)
check("RR 宽度不符不消费（再读 3B 成功）",
	(function() local x = r1(3); return x and #x == 3 end)())
check("Melexis 区 reg0x20 可读（{50,80} -> 00,00,00）",
	(function() w(0x50, 0x80); local x = r1(3); return x and x[1] == 0 and x[3] == 0 end)())

-- ---- WR ----
check("WR gain=0 帧 {60,00,0C,00} ACK", w(0x60, 0x00, 0x0C, 0x00) == true)
check("WR 后 reg0=0x000C", dev:reg(0x00) == 0x000C,
	string.format("0x%04X", dev:reg(0x00)))
s = r1(1)
check("WR 应答 status=0x00", s and s[1] == 0x00, frame(s))
check("WR 3B 短帧 NACK", w(0x60, 0x00, 0x0C) == false)
check("WR 5B 长帧 NACK", w(0x60, 0x00, 0x0C, 0x00, 0x00) == false)
check("WR 地址字节 abc≠0 NACK", w(0x60, 0x00, 0x0C, 0x02) == false)
check("坏帧不落寄存器（reg0 仍 000C）", dev:reg(0x00) == 0x000C)
check("WR Melexis 区 {60,12,34,80} 照 ACK", w(0x60, 0x12, 0x34, 0x80) == true)
check("Melexis 区写保护 reg0x20 不变", dev:reg(0x20) == 0,
	string.format("0x%04X", dev:reg(0x20)))
s = r1(1)
check("写保护应答 ERROR=0x10", s and s[1] == 0x10, frame(s))
w(0x00); r1(1)	-- 被接受的 NOP 清 ERROR
check("客户区 reg0x05 自由写",
	w(0x60, 0xAB, 0xCD, 0x14) and dev:reg(0x05) == 0xABCD,
	string.format("0x%04X", dev:reg(0x05)))

-- ---- HR 重灌 NVRAM 种子 ----
w(0xD0); r1(1)
check("HR 后 reg0 回 0x007C", dev:reg(0x00) == 0x007C,
	string.format("0x%04X", dev:reg(0x00)))
check("HR 后 reg0x05 回 0", dev:reg(0x05) == 0)
check("HS {E0} ACK status=0x00", (w(0xE0) and r1(1)[1]) == 0x00)

-- ---- 非法命令：I2C 恒 ACK + ERROR ----
check("非法命令 0x70 照 ACK", w(0x70) == true)
s = r1(1)
check("非法命令 status ERROR=0x10", s and s[1] == 0x10, frame(s))
check("非法命令留痕 unknown", #dev:unknown_commands() == 1
	and dev:unknown_commands()[1] == 0x70)
w(0x00); s = r1(1)
check("后续被接受命令清 ERROR", s[1] == 0x00, frame(s))

-- ---- SM 转换门 / NOP 轮询 / RM status-first TXYZ ----
dev:set_raw(46244, 300, -2000, 1000)
check("SM XYZT {3F} ACK", w(0x3F) == true)
check("SM 后 mode=single", dev:mode() == "single")
check("SM XYZT 默认转换门 2ms", dev:remaining_ms() == 2,
	tostring(dev:remaining_ms()))
w(0x00); s = r1(1)
check("转换中 SM_MODE=0（status 0x00）", s[1] == 0x00, frame(s))
check("NOP 轮询只读 status、不推进转换门（仍剩 2ms）", dev:remaining_ms() == 2,
	tostring(dev:remaining_ms()))
check("DRDY 低时 RM 无数据 NACK", (w(0x4F) and r1(9)) == nil)
check("DRDY 低读数据立即锁存 ERROR=0x10", dev:current_status() == 0x10,
	string.format("0x%02X", dev:current_status()))
check("RM 失败不消费 pending（仍 rm）", dev:pending() == "rm",
	tostring(dev:pending()))
w(0x00); s = r1(1)	-- 被接受的 NOP 清 ERROR 并覆盖 pending
check("NOP 后 ERROR 清（status 0x00）", s[1] == 0x00, frame(s))
dev:advance(1)
check("advance(1) 后剩 1ms 未就绪",
	dev:remaining_ms() == 1 and not dev:is_ready(), tostring(dev:remaining_ms()))
dev:advance(1)
check("advance 到点 drdy=true", dev:is_ready() and dev:remaining_ms() == nil)
w(0x00); s = r1(1)
check("就绪 status SM_MODE=0x20", s[1] == 0x20, frame(s))
w(0x4F)
local rm = r1(9)
check("RM XYZT 9B status-first TXYZ = 23,B4,A4,01,2C,F8,30,03,E8",
	rm and rm[1] == 0x23 and rm[2] == 0xB4 and rm[3] == 0xA4
	and rm[4] == 0x01 and rm[5] == 0x2C and rm[6] == 0xF8 and rm[7] == 0x30
	and rm[8] == 0x03 and rm[9] == 0xE8, frame(rm))
check("RM status D[1:0]=3（4 分量，2D+2=8 数据字节）",
	rm and rm[1] % 4 == 3)
check("RM 读走后回 idle/drdy 清", dev:mode() == "idle" and not dev:is_ready())
check("空闲再 RM 无数据 NACK", (w(0x4F) and r1(9)) == nil)

-- ---- RM 零分量跳过（SM YT，RM 5B；RM 掩码可与 SM 不同） ----
dev:set_raw(46244, 300, -2000, 1000)
w(0x35)							-- SM：T+Y（0x05）
check("SM T+Y 转换门 ceil=1ms", dev:remaining_ms() == 1,
	tostring(dev:remaining_ms()))
dev:advance(1)
w(0x45); local rm5 = r1(5)
check("RM YT 5B = 21,B4,A4,F8,30（status D=1，序 T 后 Y）",
	rm5 and #rm5 == 5 and rm5[1] == 0x21 and rm5[2] == 0xB4 and rm5[3] == 0xA4
	and rm5[4] == 0xF8 and rm5[5] == 0x30, frame(rm5))
-- 再做一次全分量 SM，只 RM X（3B status-first D=0）
w(0x3F); dev:advance(2)
w(0x42); local rx = r1(3)
check("RM 仅 X 3B = 20,01,2C（D=0）",
	rx and #rx == 3 and rx[1] == 0x20 and rx[2] == 0x01 and rx[3] == 0x2C,
	frame(rx))

-- ---- zyxt=0 取 BURST_SEL（reg0x01 低 4 位） ----
check("写 reg0x01 低 nibble=0x0F", w(0x60, 0x00, 0x0F, 0x04) == true)
w(0x30)
check("SM zyxt=0 -> 选 BURST_SEL=0x0F", dev:select_mask() == 0x0F,
	string.format("0x%X", dev:select_mask()))
dev:reset()
check("BURST_SEL=0 时 SM zyxt=0 被拒（ERROR）",
	(function() w(0x30); local x = r1(1); return x[1] == 0x10 end)())

-- ---- SB 突发 / SW 唤醒 / 模式转换被拒 / EX ----
check("SB XYZT {1F} ACK", w(0x1F) == true)
w(0x00); s = r1(1)
check("突发状态 BURST=0x80", s[1] == 0x80, frame(s))
check("首转换未完成 RM NACK", (w(0x4F) and r1(9)) == nil)
dev:advance(2)
w(0x4F); local b1 = r1(9)
check("突发就绪 RM status=0x83（BURST+D3）", b1 and b1[1] == 0x83, frame(b1))
w(0x4F); local b2 = r1(9)
check("突发 RM 不消费（可重复读）", b2 and #b2 == 9, frame(b2))
w(0x3F); s = r1(1)
check("突发中发 SM 被拒（SM 位清 + ERROR，0x90）", s[1] == 0x90, frame(s))
check("突发中 RR 不允许（ERROR 0x90，无数据帧）",
	(function() w(0x50, 0x00); local x = r1(1); return x[1] == 0x90 end)())
check("突发中 WR 被忽略（reg0 不变）",
	(function() local before = dev:reg(0x00); w(0x60, 0x00, 0x00, 0x00); r1(1)
		return dev:reg(0x00) == before end)(),
	string.format("0x%04X", dev:reg(0x00)))
w(0x80); s = r1(1)
check("EX 回 idle（status 0x00）", s[1] == 0x00 and dev:mode() == "idle", frame(s))
w(0x2F); s = r1(1)
check("SW 状态 WOC=0x40", s[1] == 0x40, frame(s))
w(0x3F); s = r1(1)
check("WOC 中 SM 被拒（0x50）", s[1] == 0x50, frame(s))
w(0x80); r1(1)

-- ---- 注入 API ----
dev:set_raw(70000, 40000, -40000, 123)
local tr, xr, yr, zr = dev:raw()
check("set_raw T 上钳 65535", tr == 65535, tostring(tr))
check("set_raw X 上钳 32767", xr == 32767, tostring(xr))
check("set_raw Y 下钳 -32768", yr == -32768, tostring(yr))
check("set_raw Z=123 照存", zr == 123, tostring(zr))
dev:reset()
-- POR 是 gain7：sxy=0.1502/sz=0.2420
dev:set_sample(30, 30.04, 0, 30)
tr, xr, yr, zr = dev:raw()
check("set_sample gain7 T30°C=46470", tr == 46470, tostring(tr))
check("set_sample gain7 X 30.04µT≈200 码", xr == 200, tostring(xr))
check("set_sample gain7 Z 30µT≈124 码", zr == 124, tostring(zr))
-- 切 gain0（reg0=0x000C）后 75.1µT -> 100 码
w(0x60, 0x00, 0x0C, 0x00); r1(1)
dev:set_sample(25, 75.1, -75.1, 121.0)
_, xr, yr, zr = dev:raw()
check("set_sample gain0 X 75.1µT=100 码", xr == 100, tostring(xr))
check("set_sample gain0 Y -75.1µT=-100 码（负值四舍五入）", yr == -100, tostring(yr))
check("set_sample gain0 Z 121µT=100 码", zr == 100, tostring(zr))

-- ---- virt_tick：确定性地磁正弦 + 预武装 ----
dev:reset()
dev:virt_tick(0)
local sxy0, sz0 = dev:sensitivities()
tr, xr, yr, zr = dev:raw()
check("tick n0 X=0（sin0）", xr == 0, tostring(xr))
check("tick n0 Z=50µT 反算码",
	zr == rround(50 / sz0), string.format("%d vs %d", zr, rround(50 / sz0)))
check("tick n0 T=25+5sin(π/4) 反算",
	tr == rround(46244 + 45.2 * 5 * math.sin(math.pi / 4)), tostring(tr))
dev:virt_tick(8)
tr, xr = select(1, dev:raw()), select(2, dev:raw())
check("tick n8 X=30µT 峰", xr == rround(30 / sxy0),
	string.format("%d vs %d", xr, rround(30 / sxy0)))
dev:virt_tick(24)
xr = select(2, dev:raw())
check("tick n24 X=-30µT 谷（含负）", xr == rround(-30 / sxy0),
	string.format("%d vs %d", xr, rround(-30 / sxy0)))
dev:virt_tick(32)
check("tick 32 拍周期 X=0", select(2, dev:raw()) == 0)
check("virt_tick 返回 self", dev:virt_tick(0) == dev)
-- 预武装：SM 零转换门，首拍 NOP 即 SM_MODE
w(0x3F); w(0x00); s = r1(1)
check("预武装后首次轮询即就绪（0x20）", s[1] == 0x20, frame(s))
w(0x4F); r1(9)
-- 守护 build 路径：virt_tick(0) 预武装后 build 首命令 RT 不得撤防，且
-- RT 应答守护不读 → rs_latch 叠到试测首拍 status（SM_MODE|RS = 0x24）
dev:virt_tick(0)
w(0xF0)							-- RT 应答不读（与守护同款）
w(0x3F); w(0x00); s = r1(1)
check("预武装经 RT 不撤（build 试测首拍就绪，status 0x24）",
	s[1] == 0x24, frame(s))
w(0x4F); r1(9)

-- ---- 故障钩子 / 留痕 / 复位 ----
dev:reset()
dev.nack_write = true
check("nack_write 写 NACK", w(0x00) == false)
dev:clear_faults()
check("解除后写恢复", w(0x00) == true); r1(1)
dev.nack_read = true
check("nack_read 读 NACK", r1(1) == nil)
dev:clear_faults()
w(0x00)
check("解除后读恢复", r1(1)[1] == 0x00)
dev:fail_write(function(b) return b[1] == 0xF0 end)
check("fail_write 谓词命中 RT", w(0xF0) == false)
check("fail_write 不影响 NOP", w(0x00) == true); r1(1)
dev:clear_faults()
w(0x3F)
dev:fail_read(function(pk) return pk and pk.k == "rm" end)
check("fail_read 谓词命中 RM 读", (w(0x4F) and r1(9)) == nil)
dev:clear_faults()
dev:set_error(true)
check("set_error 出现在 status", dev:current_status() == 0x10)
w(0x00); r1(1)
check("被接受命令清 ERROR", dev:current_status() == 0x00)
w(0x80); r1(1)	-- fail_read 用例残留在 single，先 EX 回 idle
dev:set_never_ready(true)
w(0x3F); dev:advance(10)
check("never_ready：advance 后仍不就绪", not dev:is_ready())
dev:clear_faults()
dev.nack_write = true
check("reset 保留故障钩子", (dev:reset() and w(0x00)) == false)
dev:clear_faults()
dev:reset_logs()
w(0x00); r1(1)
check("reset_logs 后命令留痕 1 条", dev:cmd_count() == 1, tostring(dev:cmd_count()))
local logs = dev:write_log()
check("write_log 记录帧字节", #logs == 1 and logs[1][1] == 0x00)
check("reset 回 POR", dev:reset():reg(0x00) == 0x007C and dev:mode() == "idle")

-- =====================================================================
-- 组 2：真实 build（缺省参数，逐笔事务）
-- =====================================================================
mark = section()
dev:set_raw(46244, 300, -2000, 1000)
local bframes
local ok, res, banner = capture(function()
	local r
	bframes, r = recording(function()
		return build({ fd = fd, address = "0x0C" })
	end)
	return r
end)
check("build 缺省 OK", ok and res.result == "OK", tostring(res and res.result))
local es = entries(mark)
check("build 15 txlog（set+9w+5r）", #es == 15,
	tostring(#es) .. ":" .. table.concat((function()
		local t = {}
		for _, e in ipairs(es) do t[#t + 1] = e.dir end
		return t
	end)(), ","))
check("build 首笔 set 0x0C", set_addrs(mark)[1] == 0x0C,
	tostring(set_addrs(mark)[1]))
check("build 写序列逐笔编码",
	same_seq(wcodes(mark), {
		0xF0, 0xD0, 0x5000, 0x60000C00, 0x5000,
		0x3F, 0x00, 0x00, 0x4F,
	}), table.concat((function()
		local t = {}
		for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%X", v) end
		return t
	end)(), ","))
local rds = reads(mark)
check("build 5 笔读宽度 3/3/1/1/9",
	#rds == 5 and rds[1].bytes.n == 3 and rds[2].bytes.n == 3
	and rds[3].bytes.n == 1 and rds[4].bytes.n == 1 and rds[5].bytes.n == 9,
	tostring(#rds))
check("RR 首读 status-first = 00,00,7C",
	bframes[1] and bframes[1][1] == 0x00 and bframes[1][2] == 0x00
	and bframes[1][3] == 0x7C, frame(bframes[1]))
check("RR 回读 = 00,00,0C",
	bframes[2] and bframes[2][1] == 0x00 and bframes[2][2] == 0x00
	and bframes[2][3] == 0x0C, frame(bframes[2]))
check("首次轮询 SM_MODE=0（转换中）",
	bframes[3] and bframes[3][1] == 0x00,
	string.format("%02X", bframes[3] and bframes[3][1] or -1))
check("二次轮询 SM_MODE=0x20（就绪）",
	bframes[4] and bframes[4][1] == 0x20,
	string.format("%02X", bframes[4] and bframes[4][1] or -1))
check("RM 9B status-first TXYZ = 23,B4,A4,01,2C,F8,30,03,E8",
	bframes[5] and #bframes[5] == 9
	and bframes[5][1] == 0x23 and bframes[5][2] == 0xB4 and bframes[5][3] == 0xA4
	and bframes[5][4] == 0x01 and bframes[5][5] == 0x2C and bframes[5][6] == 0xF8
	and bframes[5][7] == 0x30 and bframes[5][8] == 0x03 and bframes[5][9] == 0xE8,
	frame(bframes[5]))
check("build 睡眠 9ms（5 复位+2 召回+2 轮询）",
	sleep_total == 9, tostring(sleep_total))
check("build 后 reg0=0x000C", dev:reg(0x00) == 0x000C,
	string.format("0x%04X", dev:reg(0x00)))
check("横幅含 init OK/gain=0/sens_xy=0.7510/timeout=50ms",
	banner:find("MLX90393 init OK", 1, true)
	and banner:find("gain=0", 1, true)
	and banner:find("sens_xy=0.7510", 1, true)
	and banner:find("timeout=50ms", 1, true), banner)

-- 字符串 fd/address
mark = section()
expect_ok("build 字符串 fd='3' address='0x0C'", function()
	return build({ fd = "3", address = "0x0C" })
end)
check("set_addr 收到 0x0C=12", set_addrs(mark)[1] == 12,
	tostring(set_addrs(mark)[1]))

-- =====================================================================
-- 组 3：真实 build（gain 各档/钳位/timeout/横幅）
-- =====================================================================
mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x0C", gain = "7" })
end)
check("build gain=7 OK", ok and res.result == "OK", tostring(res and res.result))
check("gain=7 RMW 写 0x007C", dev:reg(0x00) == 0x007C,
	string.format("0x%04X", dev:reg(0x00)))
check("gain=7 WR 帧 {60,00,7C,00}",
	(function()
		for _, b in ipairs(writes(mark)) do
			if b[1] == 0x60 then return b[2] == 0 and b[3] == 0x7C and b[4] == 0 end
		end
		return false
	end)())
check("gain=7 横幅 sens_xy=0.1502/sens_z=0.2420",
	banner:find("sens_xy=0.1502", 1, true)
	and banner:find("sens_z=0.2420", 1, true), banner)

mark = section()
expect_ok("build gain=3（保留 HALLCONF=C）", function()
	return build({ fd = fd, address = "0x0C", gain = "3" })
end)
check("gain=3 写 reg0=0x003C", dev:reg(0x00) == 0x003C,
	string.format("0x%04X", dev:reg(0x00)))

mark = section()
expect_ok("build gain=9 钳到 7", function()
	return build({ fd = fd, address = "0x0C", gain = "9" })
end)
check("gain=9 写 0x007C", dev:reg(0x00) == 0x007C,
	string.format("0x%04X", dev:reg(0x00)))

mark = section()
expect_ok("build gain=-1 钳到 0", function()
	return build({ fd = fd, address = "0x0C", gain = "-1" })
end)
check("gain=-1 写 0x000C", dev:reg(0x00) == 0x000C)

mark = section()
expect_ok("build gain='-' 缺省 0", function()
	return build({ fd = fd, address = "0x0C", gain = "-" })
end)
check("gain='-' 写 0x000C", dev:reg(0x00) == 0x000C)

mark = section()
expect_ok("build gain='abc' 缺省 0", function()
	return build({ fd = fd, address = "0x0C", gain = "abc" })
end)
check("gain 非数值写 0x000C", dev:reg(0x00) == 0x000C)

-- 26.3：'nan' 与 'abc' 同属「非法归缺省」，但走的是另一条路——tonumber("nan")
-- 出的是 **number**（Lua 里 truthy），`gain == nil` 判据放行；随后 math.floor(NaN)
-- 仍是 NaN，`gain < 0` / `gain > 7` 两道钳位对 NaN 恒假也放行，于是
-- GAIN_TAB[NaN + 1] 读出 nil，灵敏度换算对 nil 做算术，build 抛的是 Lua error
-- 而非 ERR 表——操作者拿到「attempt to perform arithmetic on a nil value」，
-- 而不是一句配置错误。上面 'abc' 用例为绿恰恰掩盖了这一支。
mark = section()
local oknan, resnan, bannernan = capture(function()
	return build({ fd = fd, address = "0x0C", gain = "nan" })
end)
check("build gain=nan 不抛 Lua error（归缺省 0）",
	oknan and type(resnan) == "table" and resnan.result == "OK",
	oknan and tostring(resnan and resnan.result) or tostring(resnan))
check("gain=nan 写 0x000C（与 'abc' 同结论）", dev:reg(0x00) == 0x000C,
	string.format("0x%04X", dev:reg(0x00)))
check("gain=nan 横幅 sens_xy=0.7510（未对 nil 做算术）",
	bannernan:find("sens_xy=0.7510", 1, true) ~= nil, bannernan)

mark = section()
expect_ok("build timeout=100", function()
	return build({ fd = fd, address = "0x0C", timeout = "100" })
end)
local _, _, banner100 = capture(function()
	return build({ fd = fd, address = "0x0C", timeout = "100" })
end)
check("timeout=100 横幅", banner100:find("timeout=100ms", 1, true) ~= nil)

mark = section()
expect_ok("build timeout=0 归缺省 50", function()
	return build({ fd = fd, address = "0x0C", timeout = "0" })
end)
expect_ok("build timeout='-' 归缺省", function()
	return build({ fd = fd, address = "0x0C", timeout = "-" })
end)

-- 26.3：timeout='nan' 同上——`to == nil` 与 `to < 1` 对 NaN 均为假，于是
-- poll_timeout_ms = math.floor(NaN) = NaN；轮询 `while left > 0` 一拍都不进，
-- **每次**测量都立刻判超时，而超时文案用 %d 格式化 NaN 出 -9223372036854775808ms。
-- 判据取「与 '-' / '0' 同结论：归缺省 50ms」，即本文件既有口径。
mark = section()
local oktn, _, bannertn = capture(function()
	return build({ fd = fd, address = "0x0C", timeout = "nan" })
end)
check("build timeout=nan 归缺省 50ms",
	oktn and bannertn:find("timeout=50ms", 1, true) ~= nil, bannertn)
check("timeout=nan 横幅不含 %d 格式化 NaN 的哨兵值",
	bannertn:find("9223372036854775808", 1, true) == nil, bannertn)

-- =====================================================================
-- 组 4：真实 build 错误路径
-- =====================================================================
mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x0C" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build address 非数值", function()
	return build({ fd = fd, address = "0xZZ" })
end, "fd or address")
expect_err("build 非表参数", function() return build(nil) end, "Invalid Arguments Type")
check("前置校验类错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return b[1] == 0xF0 end)
expect_err("build RT 写失败", function()
	return build({ fd = fd, address = "0x0C" })
end, "Failed to reset")
check("RT 失败 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return b[1] == 0xD0 end)
expect_err("build HR 写失败", function()
	return build({ fd = fd, address = "0x0C" })
end, "Failed to recall")
check("HR 失败 txlog=3（set+F0+wD0）", #entries(mark) == 3, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(pk) return pk and pk.k == "rr" end)
expect_err("build 读 GAIN 失败", function()
	return build({ fd = fd, address = "0x0C" })
end, "Failed to read MLX90393 GAIN register")
check("RR 失败 txlog=5（set+F0+D0+wRR+失败 r 留痕）",
	#entries(mark) == 5, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 4 and b[1] == 0x60 end)
expect_err("build WR 写失败", function()
	return build({ fd = fd, address = "0x0C" })
end, "Failed to write MLX90393 GAIN register")
check("WR 失败 txlog=6（set+F0+D0+RR 写/读+失败 WR）", #entries(mark) == 6,
	tostring(#entries(mark)))

-- 回读篡改：第二次 RR（verify）返回 0x000D
mark = section()
do
	local real_read = dev.read
	local rr_n = 0
	dev.read = function(n)
		if dev:pending() == "rr" and n == 3 then
			rr_n = rr_n + 1
			if rr_n == 2 then return { 0x00, 0x00, 0x0D } end
		end
		return real_read(n)
	end
	expect_err("build GAIN 回读校验失败", function()
		return build({ fd = fd, address = "0x0C" })
	end, "GAIN verify failed")
	dev.read = real_read
end

mark = section()
dev:set_never_ready(true)
expect_err("build 试测超时（timeout=8ms）", function()
	return build({ fd = fd, address = "0x0C", timeout = "8" })
end, "measurement timeout")
check("超时路径睡眠 ≥8ms", sleep_total >= 8, tostring(sleep_total))
dev:clear_faults()

-- 轮询见到 ERROR 状态：dev.read 对 status 恒回 0x10
mark = section()
do
	local real_read = dev.read
	dev.read = function(n)
		if dev:pending() == "status" and n == 1 then return { 0x10 } end
		return real_read(n)
	end
	expect_err("build status ERROR", function()
		return build({ fd = fd, address = "0x0C" })
	end, "status ERROR")
	dev.read = real_read
end

mark = section()
dev:fail_read(function(pk) return pk and pk.k == "rm" end)
expect_err("build RM 读失败", function()
	return build({ fd = fd, address = "0x0C" })
end, "Failed to read MLX90393 measurement")

mark = section()
expect_err("无器件地址 0x40 RT NACK", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to reset")
check("无器件 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

-- =====================================================================
-- 组 5：真实 call（status-first 字节序 + 换算）
-- =====================================================================
mark = section()
expect_ok("call 前 build gain0", function()
	return build({ fd = fd, address = "0x0C", gain = "0" })
end)
dev:set_raw(46244, 300, -2000, 1000)
mark = #vbus.txlog
local out = expect_ok("call 正常读值", function() return call({ fd = fd, address = "0x0C" }) end)
check("call 8 txlog（set+3F+2 轮询+4F r9）", #entries(mark) == 8,
	tostring(#entries(mark)))
check("call 写序列 3F/00/00/4F",
	same_seq(wcodes(mark), { 0x3F, 0x00, 0x00, 0x4F }),
	table.concat((function()
		local t = {}
		for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%X", v) end
		return t
	end)(), ","))
if out then
	check("X = 300×0.751 = 225.3µT", near(out.X, 225.3), tostring(out.X))
	check("Y = -2000×0.751 = -1502µT（s16 补码）", near(out.Y, -1502), tostring(out.Y))
	check("Z = 1000×1.210 = 1210µT", near(out.Z, 1210), tostring(out.Z))
	check("T = 25°C（46244 基准）", near(out.T, 25), tostring(out.T))
	check("XR/YR/ZR 有符号原样", out.XR == 300 and out.YR == -2000 and out.ZR == 1000,
		string.format("%d/%d/%d", out.XR, out.YR, out.ZR))
	check("TR 无符号 46244", out.TR == 46244, tostring(out.TR))
	check("status=0x23（RM 帧首字节）", out.status == 0x23,
		string.format("0x%02X", out.status))
end

-- 温度其它点（15°C / 35°C；u16 无符号）
for _, spec in ipairs({ { 45792, 15.0 }, { 46696, 35.0 } }) do
	mark = section()
	expect_ok("温度用例前 build", function()
		return build({ fd = fd, address = "0x0C" })
	end)
	dev:set_raw(spec[1], 0, 0, 0)
	local rr2 = expect_ok("call 温度 " .. spec[2] .. "°C", function()
		return call({ fd = fd, address = "0x0C" })
	end)
	if rr2 then
		check(string.format("TR=%d -> T=%.1f°C", spec[1], spec[2]),
			near(rr2.T, spec[2], 1e-9), tostring(rr2.T))
		check("TR 原样无符号", rr2.TR == spec[1], tostring(rr2.TR))
	end
end

-- gain=7 高增益档：300 码 X = 45.06µT
mark = section()
expect_ok("gain7 前 build", function()
	return build({ fd = fd, address = "0x0C", gain = "7" })
end)
dev:set_raw(46244, 300, -2000, 1000)
out = expect_ok("call gain=7 读值", function()
	return call({ fd = fd, address = "0x0C" })
end)
if out then
	check("gain7 X = 300×0.1502 = 45.06µT（不是旧表的 18.775）",
		near(out.X, 45.06), tostring(out.X))
	check("gain7 Z = 1000×0.242 = 242µT", near(out.Z, 242), tostring(out.Z))
end

-- =====================================================================
-- 组 6：真实 call 错误路径
-- =====================================================================
mark = section()
expect_ok("失败用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
dev:set_raw(46244, 300, -2000, 1000)
dev:set_never_ready(true)
mark = #vbus.txlog
expect_err("call 测量超时（timeout=8）", function()
	return call({ fd = fd, address = "0x0C", timeout = "8" })
end, "measurement timeout")
check("超时路径睡眠 ≥8ms", sleep_total >= 8, tostring(sleep_total))
dev:clear_faults()

-- timeout 列只在 build 解析：call 传 timeout 不改模块值，故用 build timeout=8
mark = section()
expect_ok("短超时 build", function()
	return build({ fd = fd, address = "0x0C", timeout = "8" })
end)
dev:set_never_ready(true)
expect_err("call 沿用 build timeout=8 超时", function()
	return call({ fd = fd, address = "0x0C" })
end, "measurement timeout")
dev:clear_faults()

mark = section()
expect_ok("ERROR 用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
do
	local real_read = dev.read
	dev.read = function(n)
		if dev:pending() == "status" and n == 1 then return { 0x10 } end
		return real_read(n)
	end
	dev:set_raw(46244, 0, 0, 0)
	expect_err("call status ERROR", function()
		return call({ fd = fd, address = "0x0C" })
	end, "status ERROR")
	dev.read = real_read
end

mark = section()
expect_ok("SM 失败用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
dev:fail_write(function(b) return #b == 1 and b[1] == 0x3F end)
mark = #vbus.txlog
expect_err("call SM 写失败", function()
	return call({ fd = fd, address = "0x0C" })
end, "Failed to start")
check("SM 失败 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
expect_ok("轮询失败用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
dev.nack_read = true
mark = #vbus.txlog
expect_err("call 轮询读 NACK", function()
	return call({ fd = fd, address = "0x0C" })
end, "Failed to poll")
check("轮询失败 txlog=4（set+3F+00+失败 r 留痕）",
	#entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
expect_ok("RM 写失败用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
dev:set_raw(46244, 1, 2, 3)
dev:fail_write(function(b) return #b == 1 and b[1] == 0x4F end)
mark = #vbus.txlog
expect_err("call RM 命令写失败", function()
	return call({ fd = fd, address = "0x0C" })
end, "Failed to send")
check("RM 写失败 txlog=7（set+3F+2×NOP轮询+失败 w）",
	#entries(mark) == 7, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
expect_ok("RM 读失败用例前 build", function()
	return build({ fd = fd, address = "0x0C" })
end)
dev:fail_read(function(pk) return pk and pk.k == "rm" end)
mark = #vbus.txlog
expect_err("call RM 读失败", function()
	return call({ fd = fd, address = "0x0C" })
end, "Failed to read MLX90393 measurement")
check("RM 读失败 txlog=8（set+3F+2 轮询+4F+失败 r 留痕）", #entries(mark) == 8,
	tostring(#entries(mark)))
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 非表参数", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x0C" }) end, "fd or address")
check("call 参数错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

-- =====================================================================
-- 组 7：destroy
-- =====================================================================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
tester.summary("MLX90393 结果")

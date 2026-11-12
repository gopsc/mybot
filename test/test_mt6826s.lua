-- test_mt6826s.lua —— MT6826S 真实驱动 + 虚拟 SPI 总线 + 磁编码器模型
-- 用法（项目根目录）: luajit test/test_mt6826s.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：MT6826S_GC=1 luajit test/test_mt6826s.lua
--
-- 从「dofile 驱动后替换 HAL.sys.ioctl_p、ffi.cast 抠 spi_ioc_transfer 缓冲的
-- 手写桩」迁移到「真实驱动 + virtbus 注入层 + 内嵌模型（modules/MT6826S.lua
-- 尾部 MT6826S_VIRT，2026-09-15 自 virtbus/mt6826s.lua 迁入）」。
-- 迁移同时消除 HAL 缺口：驱动原本绕过全局 spi_* 自组全双工帧，现新增全局
-- 原语 spi_xfer_full（1 基表进/等长表出，hal/spi.lua + virtbus 双侧复刻），
-- 驱动只调全局——真机走 ioctl、无真机走内存模型，协议帧可经 txlog 断言。
--
-- 协议事实（数据手册 Rev1.1 第 8.6/11 章，三份独立实现交叉）：
--   SPI Mode3；24 位帧 = cmd4 + addr12 + data8（读 0011），MOSI
--   {0x3|addr_hi, addr_lo, dummy}，MISO 命令+地址段 Hi-Z、数据在末字节；
--   0x003=ANGLE[14:7]、0x004=ANGLE[6:0]<<1（bit0 恒 0）、0x005 高 5 位恒 0
--   +STATUS[2:0]、0x006=CRC-8（poly 0x07/init 0x00/MSB first 覆盖前三字节）。
--
-- 覆盖七组：
--   1) 模型事实：CRC 经典向量/帧解码（读/写/连续读/畸形帧）/四寄存器编码
--      与固定位/状态位/原始码与度数逆注入/钳制/坏 CRC 持续与区间配额/
--      传输故障钩子/reset 不清钩子/virt_tick 32 拍码钉与周期
--   2) 虚拟原语契约：spi_xfer_full 注入身份/等长收发/参数族拒绝/未开 fd/
--      delay 留痕与 __u16 钳制
--   3) 真实 build：sopen+setup(mode3)、4 帧地址/命令/MOSI/MISO Hi-Z、
--      横幅 delay/zero/status/crc_ok、delay 透传与钳制、CRC 坏仍 build OK、
--      传输失败/两类固定位违例/缺参负路径
--   4) 真实 call：90°/0°/满码/告警位、每轮 4 帧、zero 三场景、virt_tick
--      32 拍真实驱动闭环
--   5) call 重试：CRC 首组坏重试即好（8 帧）、CRC 持续坏 CRC_OK=0 数值照返、
--      帧失败当组 1 帧即返 + 重试（5 帧）、持续帧失败（2 帧）、固定位违例
--      （8 帧）、缺参
--   6) destroy：零总线事务、非表 ERR
--   7) （节奏由 MT6826S_GC 环境变量切换，无独立断言组）

if os.getenv("MT6826S_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local PATH = "/dev/spidev0.0"

-- 模型内嵌于驱动文件（MT6826S_VIRT 全局工厂，工厂表带 BUS="spi"）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MT6826S.lua")
local mm = MT6826S_VIRT

local dev = mm.new()
vbus.attach_spi("MT6826S@" .. PATH, PATH, dev)

local fd = spi_open(PATH)
check("spi_open 虚拟 fd=3", fd == 3, tostring(fd))
check("spi_setup mode3/8bit/1MHz 返回 0",
	spi_setup(fd, 3, 8, 1000000, 0) == 0)
do
	local setup
	for _, e in ipairs(vbus.txlog) do
		if e.dir == "setup" then setup = e end
	end
	check("setup 留痕 mode=3 bits=8 speed=1000000",
		setup ~= nil and setup.path == PATH and setup.mode == 3
		and setup.bits == 8 and setup.speed == 1000000)
end

local ANGLE_MAX = 32768
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

local function entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do t[#t + 1] = vbus.txlog[i] end
	return t
end
local function xframes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "x" then t[#t + 1] = e end
	end
	return t
end
local function frame_cmd(e) return math.floor(e.tx[1] / 16) % 16 end
local function frame_addr(e) return (e.tx[1] % 16) * 256 + e.tx[2] end

-- 每个 section：器件复位 + 故障解除（挂载/fd/setup 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	return #vbus.txlog
end

-- 横幅捕获（驱动 build 仅一条 print）
local cap_lines = {}
local real_print = print
local function cap_start()
	cap_lines = {}
	print = function(s) cap_lines[#cap_lines + 1] = tostring(s) end
end
local function cap_stop() print = real_print end
local function banner(pat)
	for _, s in ipairs(cap_lines) do
		if s:find(pat, 1, true) then return s end
	end
	return nil
end

-- 模型直调：发一帧读寄存器，返回末字节
local function mread(reg)
	return dev.xfer({ 0x30 + math.floor(reg / 256) % 16, reg % 256, 0x00 })[3]
end
-- 模型直调：读完整一组四寄存器
local function mgroup()
	return mread(0x003), mread(0x004), mread(0x005), mread(0x006)
end

-- ==================== 组 1：模型协议事实 ====================
do
	section()
	-- CRC-8 poly 0x07 经典向量（独立于驱动的第三份实现）
	check("CRC-8 经典向量 crc(123456789)=0xF4", dev:crc8({
		0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
	}) == 0xF4)

	-- 24 位帧解码：cmd4 + addr12（reg 0x003 高地址位为 0 → 首字节 0x30）
	dev:reset()
	dev.xfer({ 0x30, 0x03, 0x00 })
	dev.xfer({ 0x60, 0x09, 0x7F })
	dev.xfer({ 0xA0, 0x00, 0x00 })
	local fr = dev:frames()
	check("帧流水 cmd/addr：读0x003/写0x009/连续读",
		#fr == 3 and fr[1].cmd == 0x3 and fr[1].addr == 0x003
		and fr[2].cmd == 0x6 and fr[2].addr == 0x009
		and fr[3].cmd == 0xA and fr[3].addr == 0x000,
		#fr)
	local rxw = dev.xfer({ 0x60, 0x09, 0x7F })
	check("非读命令 MISO 全 0（Hi-Z/未定义段不声称数据）",
		rxw[1] == 0 and rxw[2] == 0 and rxw[3] == 0)
	local rx1 = dev.xfer({ 0x00 })
	check("非 3 字节帧返回等长 0 且不入帧流水",
		#rx1 == 1 and rx1[1] == 0 and #dev:frames() == 4)

	-- 四寄存器编码：h=ANGLE[14:7]、l=ANGLE[6:0]<<1
	dev:reset()
	dev:set_angle_raw(0)
	local h0, l0, st0, c0 = mgroup()
	check("raw=0：h/l/st 全 0、CRC=0（全零序列多项式结果）",
		h0 == 0 and l0 == 0 and st0 == 0 and c0 == 0,
		string.format("%02X %02X %02X %02X", h0, l0, st0, c0))

	dev:set_angle_raw(8192)
	local h1, l1 = mread(0x003), mread(0x004)
	check("raw=8192：h=0x40 l=0x00", h1 == 0x40 and l1 == 0x00,
		string.format("%02X %02X", h1, l1))

	dev:set_angle_raw(32767)
	local h2, l2 = mread(0x003), mread(0x004)
	check("raw=32767 满码：h=0xFF l=0xFE（bit0 恒 0）",
		h2 == 0xFF and l2 == 0xFE, string.format("%02X %02X", h2, l2))

	dev:set_angle_raw(24576); dev:set_status(5)
	local h3, l3, st3 = mread(0x003), mread(0x004), mread(0x005)
	check("raw=24576/status=5：h=0xC0 l=0 st=5（高 5 位 0）",
		h3 == 0xC0 and l3 == 0 and st3 == 5, tostring(st3))

	-- 固定位在全码域成立
	local even, highzero = true, true
	for _, r in ipairs({ 0, 1, 127, 128, 129, 16384, 32766, 32767 }) do
		dev:set_angle_raw(r)
		for s = 0, 7 do
			dev:set_status(s)
			local l = mread(0x004)
			local st = mread(0x005)
			if l % 2 ~= 0 then even = false end
			if math.floor(st / 8) ~= 0 then highzero = false end
		end
	end
	check("全码域 0x004 bit0 恒 0", even == true)
	check("全状态域 0x005 高 5 位恒 0", highzero == true)

	-- CRC 字节与独立计算交叉（多点）
	local cross = true
	for _, r in ipairs({ 0, 1, 8191, 8192, 24576, 32767 }) do
		dev:set_angle_raw(r); dev:set_status(r % 8)
		local h, l, st, c = mgroup()
		if dev:crc8({ h, l, st }) ~= c then cross = false end
	end
	check("多点 CRC 字节 == crc8(h,l,st)", cross)

	-- 度数逆注入（正算公式只在驱动，模型仅做反解）
	check("set_angle_deg 90/180/270/-90/360 反解码",
		dev:set_angle_deg(90):angle_raw() == 8192
		and dev:set_angle_deg(180):angle_raw() == 16384
		and dev:set_angle_deg(270):angle_raw() == 24576
		and dev:set_angle_deg(-90):angle_raw() == 24576
		and dev:set_angle_deg(360):angle_raw() == 0)
	local function round_deg(deg)
		return math.floor((deg % 360) * ANGLE_MAX / 360 + 0.5) % ANGLE_MAX
	end
	local inj_ok = true
	for _, deg in ipairs({ 0.5, 11.25, 90.3, 179.9, 300.7, 359.99 }) do
		if dev:set_angle_deg(deg):angle_raw() ~= round_deg(deg) then inj_ok = false end
	end
	check("任意度数四舍五入反解", inj_ok)

	-- 钳制
	dev:set_angle_raw(999999); local rhi = dev:angle_raw()
	dev:set_angle_raw(-99); local rlo = dev:angle_raw()
	dev:set_status(99); local shi = dev:status()
	dev:set_status(-3); local slo = dev:status()
	check("raw 钳 0~32767、status 钳 0~7",
		rhi == 32767 and rlo == 0 and shi == 7 and slo == 0,
		table.concat({ rhi, rlo, shi, slo }, ","))

	-- 固定位违例注入
	dev:set_angle_raw(0)
	dev:bad_fixed_l(true)
	check("bad_fixed_l：0x004 字节奇数", mread(0x004) % 2 == 1)
	dev:clear_faults()
	dev:bad_fixed_st(true)
	check("bad_fixed_st：0x005 字节高 5 位非零", math.floor(mread(0x005) / 8) ~= 0)
	dev:clear_faults()

	-- CRC 持续坏：只翻 CRC 字节，h/l/st 不动
	dev:reset()
	dev:set_angle_raw(8192)
	dev:corrupt_crc(true)
	local bh, bl, bst, bc = mgroup()
	check("corrupt_crc：h/l/st 不变、CRC 字节翻转",
		bh == 0x40 and bl == 0 and bst == 0
		and bc ~= dev:crc8({ bh, bl, bst }))
	dev:clear_faults()
	local gh, gl, gst, gc = mgroup()
	check("解除后 CRC 恢复", gc == dev:crc8({ gh, gl, gst }))

	-- CRC 区间配额：先耗一组（模拟 build），武装 1 组 → 坏一好二
	dev:reset()
	mgroup()
	dev:corrupt_next_groups(1)
	local function group_ok()
		local h, l, st, c = mgroup()
		return dev:crc8({ h, l, st }) == c
	end
	check("配额：武装后第 1 组坏", group_ok() == false)
	check("配额：重试第 2 组好", group_ok() == true)
	check("配额：第 3 组好（区间固定不复发）", group_ok() == true)
	dev:corrupt_next_groups(2)
	check("配额 2：连续两组坏", group_ok() == false and group_ok() == false)
	check("配额 2：其后好", group_ok() == true)

	-- 传输故障钩子
	dev:clear_faults()
	dev:fail_transfer(true)
	check("fail_transfer：xfer 返回 nil", dev.xfer({ 0x30, 0x03, 0 }) == nil)
	dev:clear_faults()
	local nf = 0
	dev:fail_when(function() nf = nf + 1; return nf == 2 end)
	check("fail_when 谓词定向：第 2 帧 nil、第 1/3 帧有表",
		dev.xfer({ 0x30, 0x03, 0 }) ~= nil
		and dev.xfer({ 0x30, 0x04, 0 }) == nil
		and dev.xfer({ 0x30, 0x05, 0 }) ~= nil)
	dev:clear_faults()
	dev:fail_transfer(true); dev:reset()
	check("reset 不清故障钩子（硬件复位修不好总线故障）",
		dev.xfer({ 0x30, 0x03, 0 }) == nil)
	dev:reset(); dev:clear_faults()

	-- virt_tick：32 拍线性爬坡码钉
	local pegs = {
		[0] = 0, [1] = 1024, [8] = 8192, [16] = 16384, [24] = 24576, [31] = 31744,
	}
	local peg_ok = true
	for n, want in pairs(pegs) do
		dev:virt_tick(n)
		if dev:angle_raw() ~= want then peg_ok = false end
	end
	check("virt_tick 码钉 0/1/8/16/24/31 拍", peg_ok)
	dev:virt_tick(0); local a = dev:angle_raw()
	dev:virt_tick(32); local b = dev:angle_raw()
	check("virt_tick 32 拍严格周期", a == b and a == 0)
	local det = true
	for n = 0, 31 do
		dev:virt_tick(n)
		local x = dev:angle_raw()
		dev:virt_tick(n + 32)
		if dev:angle_raw() ~= x then det = false end
	end
	check("virt_tick 确定性（n 与 n+32 同码）", det)
	dev:reset(); dev:clear_faults()
end

-- ==================== 组 2：虚拟全双工原语契约 ====================
do
	local mark = section()
	check("spi_xfer_full 已注入为虚拟实现",
		spi_xfer_full == vbus.v_spi_xfer_full)

	dev:set_angle_raw(8192)
	local rx = spi_xfer_full(fd, { 0x30, 0x03, 0x00 })
	check("原语正常：等长 3 字节 1 基表、末字节为 h=0x40",
		type(rx) == "table" and #rx == 3 and rx[3] == 0x40)
	local fr = xframes(mark)
	check("原语帧走 dev.xfer 且留痕（tx/rx/ok）",
		#fr == 1 and fr[1].ok == true and fr[1].tx[1] == 0x30
		and fr[1].rx[3] == 0x40)

	check("原语缺表 → nil", spi_xfer_full(fd) == nil)
	check("原语空表 → nil", spi_xfer_full(fd, {}) == nil)
	local big = {}
	for i = 1, 65 do big[i] = 0 end
	check("原语帧长 >64 → nil（不发帧）",
		spi_xfer_full(fd, big) == nil and #xframes(mark) == 1)
	check("原语非字节 → nil", spi_xfer_full(fd, { 0x30, 0x04, 256 }) == nil)
	check("原语未开 fd → nil", spi_xfer_full(99, { 0x30, 0x03, 0 }) == nil)
	local last = vbus.txlog[#vbus.txlog]
	check("未开 fd 仍留一条失败帧（rx=nil/path=nil）",
		last.dir == "x" and last.rx == nil and last.path == nil)

	section()
	spi_xfer_full(fd, { 0x30, 0x03, 0 }, 50)
	check("原语 delay=50 随帧留痕", vbus.txlog[#vbus.txlog].delay == 50)
	spi_xfer_full(fd, { 0x30, 0x03, 0 }, 99999)
	check("原语 delay 超 __u16 钳 65535",
		vbus.txlog[#vbus.txlog].delay == 65535)
end

-- ==================== 组 3：真实 build ====================
do
	local mark = section()
	cap_start()
	local r = build({ fd = fd, delay = "0" })
	cap_stop()
	check("build 默认 OK", type(r) == "table" and r.result == "OK", tostring(r and r.result))
	local fr = xframes(mark)
	check("build 在位自检 4 个 CS 帧", #fr == 4, tostring(#fr))
	local addrs, cmds, mos = {}, {}, {}
	for i, e in ipairs(fr) do
		addrs[i] = frame_addr(e)
		cmds[i] = frame_cmd(e)
		mos[i] = string.format("%02X%02X%02X", e.tx[1], e.tx[2], e.tx[3])
	end
	check("读帧地址序 0x003→0x006", table.concat(addrs, ",") == "3,4,5,6",
		table.concat(addrs, ","))
	check("四帧命令位均为 0011",
		cmds[1] == 0x3 and cmds[2] == 0x3 and cmds[3] == 0x3 and cmds[4] == 0x3)
	check("MOSI 逐帧 300300/300400/300500/300600",
		table.concat(mos, ",") == "300300,300400,300500,300600", table.concat(mos, ","))
	local hiz = true
	for _, e in ipairs(fr) do
		if e.rx[1] ~= 0 or e.rx[2] ~= 0 then hiz = false end
	end
	check("MISO 命令+地址段 Hi-Z（前两字节 0）", hiz)
	check("横幅含 init OK 与 fd/delay/zero/status/crc_ok",
		banner("MT6826S init OK") ~= nil
		and banner("fd=3") ~= nil and banner("delay=0us") ~= nil
		and banner("zero=0.0deg") ~= nil and banner("status=0") ~= nil
		and banner("crc_ok=true") ~= nil)

	-- delay 透传与钳制
	local m2 = section()
	build({ fd = fd, delay = "50" })
	local dfr = xframes(m2)
	check("delay=50 逐帧留痕",
		#dfr == 4 and dfr[1].delay == 50 and dfr[4].delay == 50)
	local m3 = section()
	build({ fd = fd, delay = "70000" })
	dfr = xframes(m3)
	check("delay=70000 钳 65535", dfr[1].delay == 65535)

	-- zero 横幅
	section()
	cap_start(); build({ fd = fd, delay = "0", zero = "90" }); cap_stop()
	check("zero=90 横幅 zero=90.0deg", banner("zero=90.0deg") ~= nil)

	-- status 透传到横幅
	section()
	dev:set_status(5)
	cap_start(); build({ fd = fd, delay = "0" }); cap_stop()
	check("status=5 时横幅 status=5 crc_ok=true",
		banner("status=5") ~= nil and banner("crc_ok=true") ~= nil)

	-- CRC 坏：build 只做固定位自检，CRC 不符不致命（横幅 crc_ok=false）
	section()
	dev:corrupt_crc(true)
	cap_start()
	local rb = build({ fd = fd, delay = "0" })
	cap_stop()
	check("CRC 坏 build 仍 OK（固定位未违例）", rb.result == "OK", rb.result)
	check("横幅 crc_ok=false", banner("crc_ok=false") ~= nil)
	dev:clear_faults()

	-- 负路径：传输失败（每轮首帧即败，仅 1 帧）
	mark = section()
	dev:fail_transfer(true)
	expect_err("build 传输失败",
		function() return build({ fd = fd, delay = "0" }) end, "not responding")
	dev:clear_faults()
	fr = xframes(mark)
	check("传输失败 1 帧即返回（read_snapshot 首帧短路）",
		#fr == 1 and fr[1].rx == nil, tostring(#fr))

	-- 负路径：两类固定位违例（四帧读完才判定）
	mark = section()
	dev:bad_fixed_l(true)
	expect_err("build 0x004 bit0 违例",
		function() return build({ fd = fd, delay = "0" }) end, "not responding")
	dev:clear_faults()
	check("固定位违例读满 4 帧", #xframes(mark) == 4)

	mark = section()
	dev:bad_fixed_st(true)
	expect_err("build 0x005 高 5 位违例",
		function() return build({ fd = fd, delay = "0" }) end, "not responding")
	dev:clear_faults()
	check("状态位违例读满 4 帧", #xframes(mark) == 4)

	expect_err("build 缺 fd", function() return build({ delay = "0" }) end,
		"Invalid Argument: fd")
	expect_err("build 非表参数", function() return build("x") end,
		"Invalid Arguments Type")
end

-- ==================== 组 4：真实 call 正常路径 ====================
do
	section()
	expect_ok("call 前 build", function() return build({ fd = fd, delay = "0" }) end)

	dev:set_angle_raw(8192)
	local r = call({ fd = fd })
	check("call 90°：RAW/ANGLE/STATUS/CRC_OK",
		r.RAW == 8192 and near(r.ANGLE, 90.0) and r.STATUS == 0 and r.CRC_OK == 1,
		string.format("RAW=%s ANGLE=%s ST=%s CRC=%s",
			tostring(r.RAW), tostring(r.ANGLE), tostring(r.STATUS), tostring(r.CRC_OK)))

	dev:set_angle_raw(0)
	r = call({ fd = fd })
	check("call 0°：RAW=0 ANGLE=0", r.RAW == 0 and near(r.ANGLE, 0.0), tostring(r.ANGLE))

	dev:set_angle_raw(32767)
	r = call({ fd = fd })
	check("call 满码端点：RAW=32767 ANGLE≈359.989",
		r.RAW == 32767 and near(r.ANGLE, 32767 * 360 / ANGLE_MAX), tostring(r.ANGLE))

	dev:set_angle_raw(24576); dev:set_status(5)
	r = call({ fd = fd })
	check("call 告警位：ANGLE=270 STATUS=5",
		near(r.ANGLE, 270.0) and r.STATUS == 5, tostring(r.STATUS))

	-- 单次 call 恰好 4 帧、地址序、无重试
	local mark = #vbus.txlog
	dev:set_angle_raw(12345)
	r = call({ fd = fd })
	local fr = xframes(mark)
	local addrs = {}
	for i, e in ipairs(fr) do addrs[i] = frame_addr(e) end
	check("单次 call 4 帧地址序 3,4,5,6",
		#fr == 4 and table.concat(addrs, ",") == "3,4,5,6", tostring(#fr))
	check("4 帧全部 ok（无重试）", fr[1].ok and fr[2].ok and fr[3].ok and fr[4].ok)

	-- zero 偏移三场景（每次 section 重新 build 以重置模块级 cfg_zero）
	section()
	build({ fd = fd, delay = "0", zero = "90" })
	dev:set_angle_raw(8192)
	r = call({ fd = fd })
	check("zero=90：90°-90°=0、RAW 不受影响",
		near(r.ANGLE, 0.0) and r.RAW == 8192, tostring(r.ANGLE))

	section()
	build({ fd = fd, delay = "0", zero = "-90" })
	dev:set_angle_raw(0)
	r = call({ fd = fd })
	check("zero=-90：(0-270) mod360=90", near(r.ANGLE, 90.0), tostring(r.ANGLE))

	section()
	build({ fd = fd, delay = "0", zero = "90" })
	dev:set_angle_raw(0)
	r = call({ fd = fd })
	check("zero=90 回绕：0°-90°=270", near(r.ANGLE, 270.0), tostring(r.ANGLE))

	-- NaN 反例（26.1）：`(z ~= nil and z ~= 0) and z % 360 or 0` 兜不住 NaN——
	-- 'nan' 过 tonumber 出的是 number（Lua 里 truthy），`z ~= nil` 与 `z ~= 0`
	-- 皆为真，`NaN % 360` 仍是 NaN，末尾 `NaN or 0` 又因 NaN 是 truthy 而取 NaN。
	-- cfg_zero 是模块级状态，于是驱动里 `cfg_zero ~= 0` 恒真、**每一次 call 的
	-- ANGLE 都变成 nan**：一次配置笔误把角度读数永久污染。delay 列的
	-- `tonumber(x) or 0` 同病——NaN 会流进 read_reg 的延时参数，并被横幅的 %d
	-- 打成 -9223372036854775808（string.format 对 NaN 不报错，只出垃圾）。
	section()
	build({ fd = fd, delay = "nan", zero = "nan" })
	dev:set_angle_raw(8192)
	r = call({ fd = fd })
	check("zero='nan' 归缺省：ANGLE=90°（未被污染成 nan）",
		near(r.ANGLE, 90.0) and r.RAW == 8192, tostring(r.ANGLE))
	cap_start(); build({ fd = fd, delay = "nan", zero = "nan" }); cap_stop()
	check("delay/zero='nan' 横幅回落缺省 delay=0us/zero=0.0deg",
		banner("delay=0us") ~= nil and banner("zero=0.0deg") ~= nil,
		tostring(banner("init OK")))

	-- virt_tick 32 拍经真实驱动闭环
	section()
	build({ fd = fd, delay = "0" })
	local loop_ok = true
	for n = 0, 31 do
		dev:virt_tick(n)
		local s = call({ fd = fd })
		local want_raw = dev:angle_raw()
		if s.RAW ~= want_raw or s.CRC_OK ~= 1
		   or not near(s.ANGLE, want_raw * 360 / ANGLE_MAX) then
			loop_ok = false
		end
	end
	check("virt_tick 32 拍真实驱动闭环（RAW/ANGLE/CRC_OK）", loop_ok)
end

-- ==================== 组 5：call 重试与故障 ====================
do
	-- CRC 首组坏、重试即好
	local mark = section()
	build({ fd = fd, delay = "0" })
	dev:set_angle_raw(8192)
	dev:corrupt_next_groups(1)		-- 武装在 build 之后：下一 call 首组坏
	local r = call({ fd = fd })
	check("CRC 首组坏重试即好 CRC_OK=1", r.CRC_OK == 1, tostring(r.CRC_OK))
	check("重试读两轮共 8 帧", #xframes(mark) == 4 + 8, tostring(#xframes(mark)))
	check("重试后角度正确", near(r.ANGLE, 90.0), tostring(r.ANGLE))

	-- CRC 持续坏：数值照返、CRC_OK=0
	section()
	build({ fd = fd, delay = "0" })
	dev:set_angle_raw(8192)
	dev:corrupt_crc(true)
	r = call({ fd = fd })
	check("CRC 持续坏：result OK / CRC_OK=0 / 数值照返",
		r.result == "OK" and r.CRC_OK == 0 and r.RAW == 8192
		and near(r.ANGLE, 90.0), tostring(r.CRC_OK))

	-- 帧失败谓词：只坏下轮首帧 → 当组 1 帧即败、重试组 4 帧成功（共 5 帧）
	mark = section()
	build({ fd = fd, delay = "0" })
	dev:set_angle_raw(8192)
	local calls = 0
	dev:fail_when(function()
		calls = calls + 1
		return calls == 1		-- call 的首个读帧失败，其余恢复
	end)
	r = call({ fd = fd })
	check("首帧失败后重试成功", r.result == "OK" and r.CRC_OK == 1,
		tostring(r.result))
	local fr = xframes(mark)
	check("首帧失败共 5 帧（败 1 + 重试 4）", #fr == 4 + 5, tostring(#fr))
	check("失败帧 rx=nil、其后帧恢复",
		fr[5].rx == nil and fr[6].ok and fr[7].ok and fr[8].ok and fr[9].ok)
	dev:clear_faults()

	-- 持续帧失败：每轮首帧即败，共 2 帧
	mark = section()
	build({ fd = fd, delay = "0" })
	dev:fail_transfer(true)
	expect_err("call 持续传输失败（重试一轮）",
		function() return call({ fd = fd }) end, "not responding")
	dev:clear_faults()
	fr = xframes(mark)
	check("持续帧失败共 2 帧（两轮各败在首帧）", #fr == 4 + 2, tostring(#fr))

	-- 固定位违例：每组读满 4 帧才判定，共 8 帧
	mark = section()
	build({ fd = fd, delay = "0" })
	dev:bad_fixed_l(true)
	expect_err("call 固定位违例（重试一轮）",
		function() return call({ fd = fd }) end, "not responding")
	dev:clear_faults()
	check("固定位违例共 8 帧", #xframes(mark) == 4 + 8, tostring(#xframes(mark)))

	expect_err("call 非表参数", function() return call(5) end, "Invalid Arguments")
	expect_err("call 缺 fd", function() return call({}) end, "Invalid Argument: fd")
end

-- ==================== 组 6：destroy ====================
do
	local mark = section()
	local r = destroy({ fd = fd })
	check("destroy OK 且零总线事务",
		r.result == "OK" and #xframes(mark) == 0, tostring(r.result))
	expect_err("destroy 非表参数", function() return destroy(nil) end,
		"Invalid Arguments Type")
end

tester.summary("MT6826S 结果")

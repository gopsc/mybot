-- test_tpl0501.lua —— TPL0501 真实驱动 + 虚拟 SPI 总线 + 器件模型
-- 用法（项目根目录）: luajit test/test_tpl0501.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「直接替换全局 spi_write 的手写字桩」迁移到「真实驱动 + virtbus SPI
-- 注入层 + virtbus/tpl0501.lua 单字节写-only 模型」：
-- 旧桩只能记一个 last_spi 值；新模型按器件事实（CS 帧 = 8 位移位寄存器、
-- CS 上升沿锁存最后字节、上电中点 127）解码，并覆盖 setup Mode0 留痕、
-- build 零发字、delay 透传、多字节帧移位语义、失败帧仍入 txlog 等旧桩
-- 触及不到的总线事实。
--   1) 模型协议事实：上电中点、单字节锁存、多字节帧取末字节、rx 纯 0、
--      帧级故障注入（失败帧不锁存/reset 不清钩子）；
--   2) build：只记录 rtotal 不发任何帧、缺省/10k/非法 rtotal、参数校验；
--   3) call：level/percent/ohms 三路换算与限幅、三参数优先级、delay 透传、
--      参数校验零发字、写失败与未打开 fd 负路径、故障后恢复；
--   4) destroy。
local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local potmod = dofile("modules/lib/virtbus/tpl0501.lua")
vbus.reset()

local SPI_PATH = "/dev/spidev0.0"
local dev = potmod.new()				-- 缺省 rtotal=100k（TPL0501-100）
vbus.attach_spi("TPL0501@spidev0.0", SPI_PATH, dev)
vbus.load_driver("modules/TPL0501.lua")

-- 驱动 build 不开总线（fd 经 @SPI 元数据流入），这里模拟 SPI 硬件变量的开总线
local fd = spi_open(SPI_PATH)
check("spi_open 虚拟 fd=3", fd == 3, tostring(fd))
check("spi_setup Mode0/8bit/1MHz 返回 0", spi_setup(fd, 0, 8, 1000000, 0) == 0)
do
	local s
	for _, e in ipairs(vbus.txlog) do if e.dir == "setup" then s = e end end
	check("setup 留痕 mode=0 bits=8 speed=1MHz",
		s and s.path == SPI_PATH and s.mode == 0 and s.bits == 8 and s.speed == 1000000,
		s and string.format("mode=%s bits=%s speed=%s", s.mode, s.bits, s.speed) or "无 setup 记录")
end

-- txlog 窗口：mark 之后的所有 CS 帧
local function xframes(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do
		if vbus.txlog[i].dir == "x" then t[#t + 1] = vbus.txlog[i] end
	end
	return t
end

-- 每个 section：模型复位（fd 与挂载不动），返回窗口起点
local function section()
	dev:reset()
	return #vbus.txlog
end

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- ==================== 1) 模型协议事实 ====================

section()
-- 1.1 上电默认中点 0x7F（抽头易失，不是 0）
check("模型：上电抽头=127（中点，非 0）", dev:wiper() == 127, tostring(dev:wiper()))
check("模型：上电 percent≈50%", near(dev:percent(), 127 / 255 * 100))
check("模型：缺省 rtotal=100000 且 ohms 线性",
	dev:rtotal() == 100000 and near(dev:ohms(), 127 / 255 * 100000))

-- 1.2 单字节帧即完整操作：CS 上升沿锁存
local rx1 = dev.xfer({ 200 })
check("模型：单字节帧锁存 wiper=200", dev:wiper() == 200, tostring(dev:wiper()))
local log = dev:byte_log()
check("模型：字节日志 {b=200,n=1}", log[1].b == 200 and log[1].n == 1)

-- 1.3 多字节帧的移位寄存器语义：只有最后 8 位被锁存，全部字节留痕
local rx3 = dev.xfer({ 1, 2, 3 })
check("模型：多字节帧锁存最后字节=3", dev:wiper() == 3, tostring(dev:wiper()))
check("模型：多字节帧日志记录帧长 n=3", dev:byte_log()[2].n == 3 and dev:byte_log()[2].b == 3)

-- 1.4 纯写同帧仍移入 MISO（全 0，器件无 SDO）
local function all_zero(t)
	for _, v in ipairs(t) do if v ~= 0 then return false end end
	return true
end
check("模型：纯写帧 rx 等长且全 0",
	#rx1 == 1 and rx1[1] == 0 and #rx3 == 3 and all_zero(rx3))

-- 1.5 构造可指定 rtotal；ohms() 可临时覆盖
local dev10k = potmod.new({ rtotal = 10000 })
check("模型：10k 型号 rtotal=10000", dev10k:rtotal() == 10000)
check("模型：ohms(rt) 临时覆盖换算",
	near(dev10k:ohms(), 127 / 255 * 10000) and near(dev10k:ohms(100000), 127 / 255 * 100000))
check("模型：set_rtotal 只接受正数",
	dev10k:set_rtotal(5000):rtotal() == 5000 and dev10k:set_rtotal(0):rtotal() == 5000)

-- 1.6 帧级故障注入：命中帧失败且不锁存；reset 不清钩子（负路径护栏）
dev:reset()
dev:fail_when(function(tx) return tx[1] == 77 end)
check("模型：fail_when 命中帧返回 nil", dev.xfer({ 77 }) == nil)
check("模型：失败帧不改变抽头（仍 127）", dev:wiper() == 127, tostring(dev:wiper()))
check("模型：未命中帧正常", dev.xfer({ 78 }) ~= nil and dev:wiper() == 78)
dev:reset()
check("模型：reset 后抽头回中点、故障钩子保留",
	dev:wiper() == 127 and dev.xfer({ 77 }) == nil)
dev:clear_fail()
check("模型：clear_fail 后恢复", dev.xfer({ 77 }) ~= nil and dev:wiper() == 77)

-- ==================== 2) build（真实驱动） ====================

-- 2.1 build 不发任何总线帧（写-only 无寄存器可配）
local m = section()
expect_ok("build 缺省 rtotal（100k）", function() return build({ fd = fd }) end)
check("build 零发字", #xframes(m) == 0, #xframes(m))

m = section()
expect_ok("build rtotal='10000'（TPL0501-10）",
	function() return build({ fd = fd, rtotal = "10000" }) end)
check("build 仍零发字", #xframes(m) == 0)

-- rtotal 非法值归缺省（通过后续 call 的 ohms 间接验证，见 2.4）
expect_ok("build rtotal='-' 归缺省", function() return build({ fd = fd, rtotal = "-" }) end)
expect_ok("build rtotal='0' 归缺省", function() return build({ fd = fd, rtotal = "0" }) end)
expect_ok("build rtotal='abc' 归缺省", function() return build({ fd = fd, rtotal = "abc" }) end)

-- 2.2 参数校验零发字
m = section()
expect_err("build 缺 fd", function() return build({ rtotal = "100000" }) end, "fd")
expect_err("build 入参非 table", function() return build("x") end, "table")
check("build 失败零发字", #xframes(m) == 0)

-- 2.3 切到 10k 型号验证 rtotal 真的进了换算
expect_ok("前置 build rtotal=10000", function() return build({ fd = fd, rtotal = "10000" }) end)
local r10k = expect_ok("10k：level=128 ohms≈5019.6Ω",
	function() return call({ fd = fd, level = "128" }) end)
if r10k then
	check("10k 型号 ohms=128/255*10000",
		near(r10k.ohms, 128 / 255 * 10000), tostring(r10k.ohms))
end

-- 2.4 非法 rtotal 归缺省 100k
expect_ok("归位 build rtotal 缺省", function() return build({ fd = fd, rtotal = "-" }) end)
local rdef = expect_ok("缺省：level=128 ohms≈50196Ω",
	function() return call({ fd = fd, level = "128" }) end)
if rdef then
	check("缺省型号 ohms=128/255*100000",
		near(rdef.ohms, 128 / 255 * 100000), tostring(rdef.ohms))
end

-- call 段统一基线：100k
expect_ok("call 段前置 build 100k", function() return build({ fd = fd, rtotal = "100000" }) end)

-- ==================== 3) call（真实驱动） ====================

-- 3.1 level 直写
local function one_byte_is(label, fn, want_level, res_check)
	local mk = section()
	local res = expect_ok(label, fn)
	local fs = xframes(mk)
	local one = #fs == 1 and #fs[1].tx == 1 and fs[1].tx[1] == want_level and fs[1].ok
	check(label .. "：总线上恰为一帧一字节 " .. want_level, one,
		#fs == 1 and (#fs[1].tx ~= 1 and "帧长=" .. #fs[1].tx or "字节=" .. tostring(fs[1].tx[1]))
		or "帧数=" .. #fs)
	check(label .. "：模型锁存值一致", dev:wiper() == want_level, tostring(dev:wiper()))
	if res and res_check then res_check(res) end
	return res
end

one_byte_is("call level=128", function() return call({ fd = fd, level = "128" }) end, 128,
	function(res)
		check("返回 level=128", res.level == 128, tostring(res.level))
		check("返回 ohms≈50196Ω", near(res.ohms, 128 / 255 * 100000), tostring(res.ohms))
	end)
one_byte_is("call level='64'（字符串入参）",
	function() return call({ fd = fd, level = "64" }) end, 64)
one_byte_is("call level=-10 限幅 0",
	function() return call({ fd = fd, level = "-10" }) end, 0)
one_byte_is("call level=999 限幅 255",
	function() return call({ fd = fd, level = "999" }) end, 255)

-- 3.2 percent 换算（floor(pct/100*255+0.5)）
one_byte_is("call percent='50' -> 128",
	function() return call({ fd = fd, percent = "50" }) end, 128)
one_byte_is("call percent='0' -> 0",
	function() return call({ fd = fd, percent = "0" }) end, 0)
one_byte_is("call percent='100' -> 255",
	function() return call({ fd = fd, percent = "100" }) end, 255)

-- 3.3 ohms 换算与限幅
one_byte_is("call ohms='50000'/100k -> 128",
	function() return call({ fd = fd, ohms = "50000" }) end, 128)
one_byte_is("call ohms='200000' 超限 -> 255",
	function() return call({ fd = fd, ohms = "200000" }) end, 255)

-- 3.4 三参数优先级 level > percent > ohms
one_byte_is("三参数同传取 level=10",
	function() return call({ fd = fd, level = "10", percent = "50", ohms = "50000" }) end, 10)
one_byte_is("percent+ohms 取 percent（10%->26）",
	function() return call({ fd = fd, percent = "10", ohms = "50000" }) end, 26)

-- 3.5 delay 透传到总线帧（不传 = nil，传 500 留痕，>65535 钳制）
do
	local mk = section()
	expect_ok("call 不带 delay", function() return call({ fd = fd, level = "10" }) end)
	local fs = xframes(mk)
	check("缺省 delay 留痕为 nil", #fs == 1 and fs[1].delay == nil, tostring(fs[1] and fs[1].delay))

	mk = section()
	expect_ok("call delay='500'", function() return call({ fd = fd, level = "11", delay = "500" }) end)
	fs = xframes(mk)
	check("delay=500 透传到帧", #fs == 1 and fs[1].delay == 500, tostring(fs[1] and fs[1].delay))

	mk = section()
	expect_ok("call delay='70000' 钳 65535",
		function() return call({ fd = fd, level = "12", delay = "70000" }) end)
	fs = xframes(mk)
	check("delay 钳制 65535", #fs == 1 and fs[1].delay == 65535, tostring(fs[1] and fs[1].delay))
end

-- 3.6 参数校验零发字
m = section()
expect_err("call 缺 level/percent/ohms",
	function() return call({ fd = fd }) end, "need level")
expect_err("call level 非数字",
	function() return call({ fd = fd, level = "abc" }) end, "not a number")
expect_err("call percent 非数字",
	function() return call({ fd = fd, percent = "abc" }) end, "not a number")
expect_err("call ohms 非数字",
	function() return call({ fd = fd, ohms = "abc" }) end, "not a number")
expect_err("call 缺 fd", function() return call({ level = "10" }) end, "fd")
expect_err("call 入参非 table", function() return call("x") end, "table")
check("call 参数校验失败零发字", #xframes(m) == 0, #xframes(m))
check("校验失败模型抽头不变（127）", dev:wiper() == 127, tostring(dev:wiper()))

-- 3.7 写失败负路径：帧级故障 + 未打开 fd
m = section()
dev:fail_when(function(tx) return tx[1] == 10 end)
expect_err("call 命中故障帧 -> ERR",
	function() return call({ fd = fd, level = "10" }) end, "Failed to write")
local fs = xframes(m)
check("失败帧仍入 txlog 且 ok=false",
	#fs == 1 and fs[1].ok == false and fs[1].rx == nil and fs[1].tx[1] == 10)
check("失败帧模型不锁存（仍 127）", dev:wiper() == 127, tostring(dev:wiper()))
dev:clear_fail()
m = section()
local rr = expect_ok("clear_fail 后恢复 level=10",
	function() return call({ fd = fd, level = "10" }) end)
check("恢复后帧成功且模型锁存 10",
	rr and #xframes(m) == 1 and xframes(m)[1].ok and dev:wiper() == 10)

-- 未打开的 fd（spi_paths[99]=nil，与挂载路径无关）
m = section()
expect_err("call 未打开 fd=99 -> ERR",
	function() return call({ fd = 99, level = "20" }) end, "Failed to write")
fs = xframes(m)
check("未打开 fd 的失败帧入日志 path=nil",
	#fs == 1 and fs[1].path == nil and fs[1].ok == false)
check("未打开 fd 不改变模型抽头（仍 127）", dev:wiper() == 127, tostring(dev:wiper()))

-- ==================== 4) destroy ====================

m = section()
expect_ok("destroy OK（无总线操作）", function() return destroy({}) end)
check("destroy 零发字", #xframes(m) == 0)

tester.summary("test_tpl0501")

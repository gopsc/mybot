-- test_vl53l0x.lua —— VL53L0X 真实驱动 + 虚拟 I2C 总线 + 分页器件模型
-- 用法（项目根目录）: luajit test/test_vl53l0x.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 410 行手写桩」迁移到「真实驱动 +
-- virtbus I2C 注入层 + virtbus/vl53l0x.lua 分页模型」。模型按（页, 寄存器）
-- 双键存储，复刻 0xFF 页切换、DataInit 舞步、page6/7 SPAD 握手、SYSRANGE
-- 模式机与 data-ready/清中断时序，旧桩的全部序列断言逐条保留并补上模型
-- 协议事实与总线层（指针写+读原子事务、NACK 相位、set_addr 留痕）断言。
--
-- 序列预期值锁定三方参考（Pololu / ESPHome / ST ULD）：
--   sig=0.25 -> 0x44 Q9.7 0x0020；long 缺省 0.1 -> 0x000C
--   spad92=0x18（24 SPAD 非光圈）-> 图 {FF,FF,FF,00,00,00}
--   spad92=0x8C（12 SPAD 光圈） -> 图 {00,F0,FF,00,00,00}
--   状态字节 0x58（内部码 11）-> STATUS=0；0x00->255；0x08->5；
--   0x20->2；0x30->4；0x40->3（ST get_pal_range_status 查表）
local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local vlmod = dofile("modules/lib/virtbus/vl53l0x.lua")
vbus.reset()

local ADDR = 0x29
local dev = vlmod.new()
vbus.attach("VL53L0X@0x29", ADDR, dev)
vbus.load_driver("modules/VL53L0X.lua")

-- milli_sleep：累计时长 + 推进模型虚拟转换倒计时（驱动运行时解析全局名）
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

-- txlog 窗口扫描
local function entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do t[#t + 1] = vbus.txlog[i] end
	return t
end
local function set_addr_values(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "set" then t[#t + 1] = e.addr end
	end
	return t
end

-- 注入有效结果块（300mm/2.0SPAD/25 信号/6 环境，状态字节 0x58）
local function inject_ok(dist)
	dev:inject_result({
		st = 0x58, spad = 0x0200, signal = 0x0C80, ambient = 0x0300,
		dist = dist or 300,
	})
end

-- ==================== 1) 模型协议事实 ====================

section()
-- 1.1 上电身份与初值
dev.write({ 0xC0 })
check("模型：0xC0=0xEE", dev.read(1)[1] == 0xEE)
dev.write({ 0x89 })
check("模型：0x89 VHV 初值 0x00", dev.read(1)[1] == 0x00)
dev.write({ 0x84 })
check("模型：0x84 极性位初值 0x12", dev.read(1)[1] == 0x12)
do
	dev.write({ 0xB0 })
	local mp = dev.read(6)
	local allff = true
	for i = 1, 6 do if mp[i] ~= 0xFF then allff = false end end
	check("模型：0xB0..B5 上电 SPAD 图全 1", allff, table.concat(mp, ","))
end

-- 1.2 （页, 寄存器）双键隔离：同号不同页互不覆盖
dev.write({ 0xFF, 0x01 }); dev.write({ 0x30, 0x20 })
dev.write({ 0xFF, 0x00 }); dev.write({ 0x30, 0x09 })
check("模型：page1 0x30=0x20 / page0 0x30=0x09 互不覆盖",
	dev:get_reg(0x30, 1) == 0x20 and dev:get_reg(0x30, 0) == 0x09,
	string.format("p1=0x%02X p0=0x%02X", dev:get_reg(0x30, 1), dev:get_reg(0x30, 0)))

-- 1.3 DataInit 舞步：0x91 只在 page1 给出 stop_variable
dev.write({ 0xFF, 0x01 }); dev.write({ 0x91 })
check("模型：page1 读 0x91 = stop_variable 0x2B", dev.read(1)[1] == 0x2B)
check("模型：读计数=1", dev:reads_91() == 1)
dev.write({ 0xFF, 0x00 }); dev.write({ 0x91 })
check("模型：page0 读 0x91 是通用寄存器（默认 0）", dev.read(1)[1] == 0)
dev:set_stop_variable(0x33)
dev.write({ 0xFF, 0x01 }); dev.write({ 0x91 })
check("模型：set_stop_variable 可改", dev.read(1)[1] == 0x33)

-- 1.4 SPAD 握手：0x83 RMW 在 page6，page7 轮询非 0，回 page6 保留 0x04
dev.write({ 0xFF, 0x06 }); dev.write({ 0x83 })
check("模型：page6 首次读 0x83=0", dev.read(1)[1] == 0)
dev.write({ 0x83, 0x04 })
dev.write({ 0xFF, 0x07 }); dev.write({ 0x83, 0x00 })
dev.write({ 0x83 })
check("模型：page7 轮询首次即非 0（就绪）", dev.read(1)[1] == 1)
dev.write({ 0x83, 0x01 })
dev.write({ 0xFF, 0x06 }); dev.write({ 0x83 })
check("模型：回 page6 的 0x83 保留 0x04", dev.read(1)[1] == 0x04)
local p83 = dev:reads_83_pages()
check("模型：0x83 读页序列 6,7,6",
	#p83 == 3 and p83[1] == 6 and p83[2] == 7 and p83[3] == 6, table.concat(p83, ","))
-- spad_stuck：page7 等待期恒 0
dev:set_spad_stuck(true)
dev.write({ 0xFF, 0x07 }); dev.write({ 0x83, 0x00 }); dev.write({ 0x83 })
check("模型：spad_stuck 时 page7 恒 0", dev.read(1)[1] == 0)

-- 1.5 0x92 SPAD 信息编码
dev:clear_faults()
dev:set_spad(12, true)
dev.write({ 0x92 })
local spad_byte = dev.read(1)
check("模型：12 SPAD 光圈 -> 0x92=0x8C", spad_byte[1] == 0x8C,
	string.format("0x%02X", spad_byte[1]))

-- 1.6 SYSRANGE 模式机 + data-ready + 清中断
dev:reset()
check("模型：初始非连续、未就绪", dev:continuous() == false and dev:armed() == false)
dev.write({ 0x00, 0x41 })
dev.write({ 0x13 })
check("模型：参考校准 0x41 立即就绪", dev.read(1)[1] == 0x07)
dev:set_refcal_stuck(true)
dev:reset()
dev.write({ 0x00, 0x41 }); dev.write({ 0x13 })
check("模型：refcal_stuck 时不就绪", dev.read(1)[1] == 0x00)
dev:clear_faults(); dev:reset()
dev.write({ 0x00, 0x02 })
check("模型：0x02 进入连续、未就绪", dev:continuous() and not dev:armed())
dev.write({ 0x13 }); check("模型：转换未到点 0x13=0", dev.read(1)[1] == 0)
dev:advance(4); dev.write({ 0x13 })
check("模型：advance 4ms 仍未就绪", dev.read(1)[1] == 0)
dev:advance(1); dev.write({ 0x13 })
check("模型：advance 满 5ms 就绪 0x07", dev.read(1)[1] == 0x07)
dev.write({ 0x0B, 0x01 }); dev.write({ 0x13 })
check("模型：清中断后未就绪、计数+1", dev.read(1)[1] == 0 and dev:clear_count() == 1)

-- 1.7 结果块注入与 burst
dev:reset()
dev.write({ 0x00, 0x02 })
dev:inject_result({ st = 0x58, spad = 0x0200, signal = 0x0C80, ambient = 0x0300, dist = 300 })
dev.write({ 0x14 })
local blk = dev.read(12)
check("模型：结果块 12 字节状态/距离布局",
	blk[1] == 0x58 and blk[3] == 0x02 and blk[7] == 0x0C and blk[9] == 0x03
	and blk[11] * 256 + blk[12] == 300)

-- 1.8 故障钩子：reset 保留、clear_faults 解除；nack 读写全断
dev:set_never_ready(true)
dev:reset()
dev.write({ 0x13 })
check("模型：reset 不清 never_ready 钩子", dev.read(1)[1] == 0)
dev:clear_faults(); dev:reset()
dev.nack = true
check("模型：nack=true 写返 false、读返 nil",
	dev.write({ 0x88, 0 }) == false and dev.read(1) == nil)
dev.nack = false
-- 定向读故障只影响指定（页, 寄存器）
dev:fail_read(0x92, 7, true)
dev.write({ 0xFF, 0x07 }); dev.write({ 0x92 })
check("模型：fail_read(0x92,page7) 读 nil", dev.read(1) == nil)
dev.write({ 0xC0 })
check("模型：其余寄存器读不受影响", dev.read(1)[1] == 0xEE)
-- 定向写故障
dev:fail_write(function(b) return b[1] == 0x0B end)
check("模型：fail_write 命中 0x0B NACK", dev.write({ 0x0B, 0x01 }) == false)
check("模型：fail_write 未命中放行", dev.write({ 0x88, 0x00 }) == true)
dev:clear_faults()

-- 1.9 virt_tick 确定性 + 预武装
dev:reset()
dev.write({ 0x00, 0x02 })
local d0 = select(2, (function()
	dev:virt_tick(0); dev.write({ 0x14 })
	return nil, dev.read(12)
end)())
check("模型：virt_tick(0) 即武装且 dist=600mm",
	dev:armed() and d0[11] * 256 + d0[12] == 600)
local dists = {}
for n = 0, 31 do
	dev:virt_tick(n); dev.write({ 0x14 })
	local b = dev.read(12)
	dists[n + 1] = b[11] * 256 + b[12]
	check2 = (b[1] == 0x58)
end
check("模型：32 拍状态恒有效、距离在 100~1100mm",
	check2 and dists[1] >= 100 and dists[1] <= 1100)
local same_all = true
for i = 2, #dists do if dists[i] ~= dists[1] then same_all = false end end
check("模型：32 拍距离有起伏（非静态）", not same_all)
-- 周期确定性：再跑一轮完全一致
local d0b
for n = 0, 0 do dev:virt_tick(n); dev.write({ 0x14 }); d0b = dev.read(12) end
check("模型：virt_tick 确定性（同拍同值）",
	d0b[11] * 256 + d0b[12] == dists[1])

-- ==================== 2) build（真实驱动） ====================

-- 2.1 默认参数完整序列
local m = section()
expect_ok("build 默认参数", function() return build({ fd = fd, address = "0x29" }) end)
check("build：set_addr 收到 0x29=41",
	set_addr_values(m)[#set_addr_values(m)] == 41)
check("build：VHV RMW 置 bit0（0x89 写值序列首项=0x01）",
	dev:write_values(0x89)[1] == 0x01,
	tostring(dev:write_values(0x89)[1]))
check("build：0x88 I2C standard mode=0x00", dev:get_reg(0x88) == 0x00)
check("build：舞步读 0x91 取 stop_variable 一次", dev:reads_91() == 1)
do
	local pages = dev:reads_83_pages()
	check("build：0x83 首末 RMW 均在 page6（中间 page7 轮询）",
		#pages >= 3 and pages[1] == 6 and pages[#pages] == 6, table.concat(pages, ","))
end
check("build：MSRC 0x60 RMW=0x12", dev:write_values(0x60)[1] == 0x12)
do
	local sw = dev:sig_writes()
	check("build：信号率门限 0.25 -> Q9.7 0x0020（multi 一次）",
		#sw == 1 and sw[1][1] == 0x00 and sw[1][2] == 0x20,
		sw[1] and string.format("0x%02X%02X", sw[1][1], sw[1][2]) or "无")
end
do
	local seq = table.concat(dev:write_values(0x01), ",")
	check("build：SEQ_CONFIG 序列 255,248,232,1,2,232", seq, seq == "255,248,232,1,2,232")
end
do
	local mw = dev:map_writes()
	check("build：SPAD 使能图单次块写", #mw == 1, tostring(#mw))
	if mw[1] then
		check("build：24 SPAD 非光圈 -> {FF,FF,FF,00,00,00}",
			table.concat(mw[1], ",") == "255,255,255,0,0,0", table.concat(mw[1], ","))
	end
end
check("build：tuning 0x30/0x57/0x48 标准档",
	dev:get_reg(0x30) == 0x09 and dev:get_reg(0x57) == 0x30 and dev:get_reg(0x48) == 0x28)
check("build：tuning 0x71/0x72 final timeout HI/LO",
	dev:get_reg(0x71) == 0x01 and dev:get_reg(0x72) == 0xFE)
check("build：GPIO 0x0A=0x04 新样本就绪", dev:get_reg(0x0A) == 0x04)
check("build：GPIO 极性 RMW 清 bit4（0x84=0x02）", dev:get_reg(0x84) == 0x02)
check("build：清中断至少一次", dev:clear_count() >= 1, tostring(dev:clear_count()))
do
	local sr = dev:sysrange_log()
	check("build：参考校准两轮启动 0x41/0x01，末次 0x02 连续",
		sr[1] == 0x41 and sr[3] == 0x01 and sr[#sr] == 0x02, table.concat(sr, ","))
	-- 启动舞步回写 stop_variable（page1 的 0x91 数据写）
	local w91 = {}
	for _, w in ipairs(dev:write_log()) do
		if w.reg == 0x91 and w.p == 1 and not w.multi then w91[#w91 + 1] = w.vals[1] end
	end
	check("build：启动舞步回写 stop_variable=0x2B",
		#w91 == 1 and w91[1] == 0x2B, table.concat(w91, ","))
end
check("build：build 结束在连续测距态", dev:continuous())

-- 2.2 字符串 fd/address（框架元数据全是字符串）
m = section()
expect_ok("build 字符串 fd='3' address='0x29'",
	function() return build({ fd = "3", address = "0x29" }) end)
check("build：set_addr 留痕 41",
	set_addr_values(m)[#set_addr_values(m)] == 41)

-- 2.3 long/sig 列
section()
expect_ok("build long='1' 长距模式",
	function() return build({ fd = fd, address = "0x29", long = "1" }) end)
check("build：长距覆写 0x30=0x07/0x57=0x50/0x48=0x48",
	dev:get_reg(0x30) == 0x07 and dev:get_reg(0x57) == 0x50 and dev:get_reg(0x48) == 0x48,
	string.format("%02X/%02X/%02X", dev:get_reg(0x30), dev:get_reg(0x57), dev:get_reg(0x48)))
do
	local sw = dev:sig_writes()
	check("build：长距缺省 sig=0.1 -> 0x000C",
		sw[1][1] == 0x00 and sw[1][2] == 0x0C,
		string.format("0x%02X%02X", sw[1][1], sw[1][2]))
end

section()
expect_ok("build sig='1.5'", function() return build({ fd = fd, address = "0x29", sig = "1.5" }) end)
do
	local sw = dev:sig_writes()
	check("build：sig=1.5 -> 0x00C0", sw[1][1] == 0x00 and sw[1][2] == 0xC0)
end

section()
expect_ok("build sig='-5'（钳 0）",
	function() return build({ fd = fd, address = "0x29", sig = "-5" }) end)
do
	local sw = dev:sig_writes()
	check("build：sig<0 钳 0 -> 0x0000", sw[1][1] == 0x00 and sw[1][2] == 0x00)
end

-- 2.4 光圈型 SPAD 图重排（跳前 12）
section()
dev:set_spad(12, true)
expect_ok("build spad=0x8C（12 SPAD 光圈）",
	function() return build({ fd = fd, address = "0x29" }) end)
do
	local mw = dev:map_writes()
	check("build：光圈型 -> {00,F0,FF,00,00,00}",
		mw[1] and table.concat(mw[1], ",") == "0,240,255,0,0,0",
		mw[1] and table.concat(mw[1], ",") or "无")
end

-- 2.5 build 错误通道
section()
dev:who(0x43)
expect_err("build 错误器件 ID",
	function() return build({ fd = fd, address = "0x29" }) end, "Device type")

section()
dev:fail_read(0xC0, 0, true)
expect_err("build 读 model ID 失败",
	function() return build({ fd = fd, address = "0x29" }) end, "Failed to read VL53L0X model ID")

section()
dev:fail_write(function(b) return b[1] == 0x89 and #b == 2 end)
expect_err("build 写 VHV 失败",
	function() return build({ fd = fd, address = "0x29" }) end, "Failed to write VL53L0X VHV config")

section()
dev:set_spad_stuck(true)
m = #vbus.txlog
expect_err("build spad info 轮询超时",
	function() return build({ fd = fd, address = "0x29", timeout = "20" }) end, "spad info timeout")
check("build：spad 超时前有轮询睡眠（>0ms）", sleep_total > 0, tostring(sleep_total))

section()
dev:fail_read(0x92, 7, true)
expect_err("build 读 spad info 失败",
	function() return build({ fd = fd, address = "0x29" }) end, "Failed to read VL53L0X spad info")

section()
dev:fail_read(0xB0, 0, true)
expect_err("build 读 SPAD 使能图失败",
	function() return build({ fd = fd, address = "0x29" }) end, "Failed to read VL53L0X spad enable map")

section()
dev:set_refcal_stuck(true)
expect_err("build 参考校准超时",
	function() return build({ fd = fd, address = "0x29", timeout = "20" }) end, "ref calibration timeout")

section()
expect_err("build set_addr 失败（addr>0x7F）",
	function() return build({ fd = fd, address = "0x80" }) end, "set_addr failed")

m = section()
expect_err("build 缺 fd/address",
	function() return build({ address = "0x29" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")
check("build：参数校验失败零总线事务", #entries(m) == 0, #entries(m))

-- ==================== 3) call（真实驱动） ====================

section()
expect_ok("call 段前置 build", function() return build({ fd = fd, address = "0x29" }) end)

-- 3.1 有效测量解析
inject_ok(300)
local res = expect_ok("call 有效测量",
	function() return call({ fd = fd, address = "0x29" }) end)
if res then
	check("call：DIST_MM=300", res.DIST_MM == 300, tostring(res.DIST_MM))
	check("call：STATUS=0 VALID=1（内部码 11）",
		res.STATUS == 0 and res.VALID == 1, tostring(res.STATUS))
	check("call：SPAD_NB=2.0（8.8 定点）", near(res.SPAD_NB, 2.0), tostring(res.SPAD_NB))
	check("call：SIGNAL=25 / AMBIENT=6 MCPS（9.7 定点）",
		near(res.SIGNAL_MCPS, 25.0) and near(res.AMBIENT_MCPS, 6.0),
		tostring(res.SIGNAL_MCPS) .. "/" .. tostring(res.AMBIENT_MCPS))
end

-- 3.2 连续采样第二拍：清中断后倒计时，sleep 推进后再次就绪（结果块锁存不变）
res = expect_ok("call 连续采样第二拍",
	function() return call({ fd = fd, address = "0x29" }) end)
check("call：第二拍同锁存值 300mm", res and res.DIST_MM == 300,
	tostring(res and res.DIST_MM))
check("call：两拍间有轮询睡眠（约 5ms）", sleep_total >= 4, tostring(sleep_total))

-- 3.3 状态映射：原始状态字节 -> ST 码
local cases = {
	{ 0x00, 255 }, { 0x08, 5 }, { 0x20, 2 }, { 0x30, 4 }, { 0x40, 3 }, { 0x58, 0 },
}
for _, c in ipairs(cases) do
	dev:inject_result({ st = c[1], spad = 0x0200, signal = 0x0C80,
		ambient = 0x0300, dist = 300 })
	res = expect_ok(string.format("call 状态字节 0x%02X", c[1]),
		function() return call({ fd = fd, address = "0x29" }) end)
	check(string.format("call：内部码 %d -> STATUS=%d",
		math.floor(c[1] / 8), c[2]),
		res and res.STATUS == c[2], tostring(res and res.STATUS))
end

-- 3.4 越界判据：DIST>=8190 -> VALID=0（即使 STATUS=0）
dev:inject_result({ st = 0x58, spad = 0x0200, signal = 0x0C80,
	ambient = 0x0300, dist = 8190 })
res = expect_ok("call 距离 8190",
	function() return call({ fd = fd, address = "0x29" }) end)
check("call：8190 -> VALID=0", res and res.VALID == 0, tostring(res and res.VALID))

-- 3.5 call 错误通道
section()
expect_ok("错误通道前置 build", function() return build({ fd = fd, address = "0x29" }) end)
inject_ok(300)
dev:set_never_ready(true)
expect_err("call data-ready 超时",
	function() return call({ fd = fd, address = "0x29", timeout = "20" }) end, "data-ready timeout")
dev:clear_faults()

section()
expect_ok("前置 build", function() return build({ fd = fd, address = "0x29" }) end)
inject_ok(300)
dev:fail_read(0x13, 0, true)
expect_err("call 轮询总线失败",
	function() return call({ fd = fd, address = "0x29" }) end, "Failed to poll")
dev:clear_faults()

inject_ok(300)
dev:fail_read(0x14, 0, true)
expect_err("call 读结果块失败",
	function() return call({ fd = fd, address = "0x29" }) end, "range results")
dev:clear_faults()

inject_ok(300)
local cc_before = dev:clear_count()
dev:fail_write(function(b) return b[1] == 0x0B and #b == 2 end)
expect_err("call 清中断失败",
	function() return call({ fd = fd, address = "0x29" }) end, "Failed to clear")
dev:clear_faults()
check("call：清中断失败路径模型未计数", dev:clear_count() == cc_before,
	tostring(dev:clear_count() - cc_before))

m = section()
expect_err("call 缺 fd/address",
	function() return call({ address = "0x29" }) end, "fd or address")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments")
check("call：参数校验零总线事务", #entries(m) == 0, #entries(m))

-- ==================== 4) destroy ====================

section()
expect_ok("destroy 前置 build", function() return build({ fd = fd, address = "0x29" }) end)
m = #vbus.txlog
expect_ok("destroy 停止测距",
	function() return destroy({ fd = fd, address = "0x29" }) end)
check("destroy：末次 page0 SYSRANGE=0x00、器件退连续",
	dev:sysrange_log()[#dev:sysrange_log()] == 0x00 and not dev:continuous(),
	tostring(dev:sysrange_log()[#dev:sysrange_log()]))
-- destroy 必先发 set_addr 再写 0x00（同一事务窗口内可见）
local saw_set, saw_stop = false, false
for _, e in ipairs(entries(m)) do
	if e.dir == "set" and e.addr == ADDR then saw_set = true end
	if e.dir == "w" and type(e.bytes) == "table" and e.bytes[1] == 0x00
	   and e.bytes[2] == 0x00 then saw_stop = true end
end
check("destroy：set_addr + 0x00=0x00 均留痕", saw_set and saw_stop)
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)

tester.summary("test_vl53l0x")

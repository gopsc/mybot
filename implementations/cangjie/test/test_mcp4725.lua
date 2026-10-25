-- test_mcp4725.lua —— MCP4725 真实驱动 + 虚拟 I2C 总线 + 命令位嵌入式模型
-- 用法（项目根目录）: luajit test/test_mcp4725.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 188 行手写帧桩」迁移到「真实驱动 +
-- virtbus I2C 注入层 + virtbus/mcp4725.lua 模型」。MCP4725 是本库首个
-- I2C 命令位嵌入式输出器件——无寄存器指针，命令类型在写流首字节高 3 位
-- （C2..C0），读为无指针纯读；模型真正解码驱动写下的每帧（快速写/
-- 写 DAC+EEPROM）并维护 DAC/EEPROM/掉电位/RDY 状态，旧桩只按脚本回吐
-- 合并值，无法验证「驱动写的帧能否被硅片正确解释」，本测试补上这层。
--
-- 帧布局锁定 Microchip DS20002039H / Adafruit 库（以真实驱动编解码为准）：
--   快速写 [00 PD1 PD0 D11..D8, D7..D0]（PD=bits5:4）；50% 码 2048 = 0x0800
--   EEP 写 [0110 PD1 PD0 00, D11..D4, D3..D0<<4]（PD=bits2:1）；2048 = 60 80 00
--   读回 5B：[RDY|PD<<4, D11..D4, D3..D0<<4, D11..D8(EEP), D7..D0(EEP)]
--   1B 读只回状态字节用于 RDY 轮询；EEPROM 写周期 25ms（驱动 50ms 步进）
local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local mcmod = dofile("modules/lib/virtbus/mcp4725.lua")
vbus.reset()

local ADDR = 0x62
local dev = mcmod.new()
vbus.attach("MCP4725@0x62", ADDR, dev)
vbus.load_driver("modules/MCP4725.lua")

-- milli_sleep：累计时长 + 推进 EEPROM 写周期虚拟时钟（驱动运行时解析全局名）
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

-- txlog 窗口
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
local function bytes_is(bs, want)
	if #bs ~= 1 then return false, "写事务数=" .. #bs end
	for i = 1, #want do
		if bs[1][i] ~= want[i] then
			return false, "实发 " .. table.concat(bs[1], ",")
		end
	end
	return true
end

-- ==================== 1) 模型协议事实 ====================

section()
-- 1.1 上电读回：RDY=1、PD=0、DAC/EEPROM=0
do
	local r = dev.read(5)
	check("模型：上电读回 5B = 80 00 00 00 00",
		r[1] == 0x80 and r[2] == 0 and r[3] == 0 and r[4] == 0 and r[5] == 0,
		table.concat(r, ","))
end

-- 1.2 快速写：PD 位 + 12 位码，只动易失 DAC
check("模型：快速写 [08,00] -> DAC=2048/PD=0",
	dev.write({ 0x08, 0x00 }) == true and dev:level() == 2048 and dev:pd() == 0)
check("模型：快速写不碰 EEPROM", dev:eeprom_code() == 0)
dev.write({ 0x0F, 0xFF })
check("模型：快速写 [0F,FF] -> 满码 4095", dev:level() == 4095)
dev.write({ 0x00, 0x00 })
check("模型：快速写 [00,00] -> 零码", dev:level() == 0)
-- PD=3、码 4095：b0=00 11 1111 = 0x3F
dev.write({ 0x3F, 0xFF })
check("模型：快速写 [3F,FF] -> 4095/PD=3", dev:level() == 4095 and dev:pd() == 3)
do
	local r = dev.read(1)
	check("模型：PD=3 读回状态字节 B0=RDY|PD<<4=B0", r[1] == 0xB0,
		string.format("0x%02X", r[1]))
end

-- 1.3 写 DAC+EEPROM：双码更新 + 写周期忙 + RDY 时序
dev:set_pd(0)
check("模型：EEP 写 [60,80,00] -> DAC=EEPROM=2048/进入忙",
	dev.write({ 0x60, 0x80, 0x00 }) == true
	and dev:level() == 2048 and dev:eeprom_code() == 2048 and dev:busy() == true)
check("模型：忙时 RDY=0x00", dev.read(1)[1] == 0x00)
check("模型：advance 24ms 仍忙（周期 25ms）", dev:advance(24):busy() == true)
check("模型：再 advance 1ms 完成", dev:advance(1):busy() == false)
check("模型：完成后 RDY=0x80", dev.read(1)[1] == 0x80)
do
	local r = dev.read(5)
	check("模型：完成后读回 80 80 00 08 00",
		r[1] == 0x80 and r[2] == 0x80 and r[3] == 0x00 and r[4] == 0x08 and r[5] == 0x00,
		table.concat(r, ","))
end
check("模型：RDY 轮询读计数=3（忙1+完成2）", dev:rdy_polls() == 3)
do
	local fw = dev:fast_writes()
	local ew = dev:eep_writes()
	check("模型：写日志分类（1.2 四条 fast + 1.3 一条 eep）", #fw == 4 and #ew == 1,
		#fw .. "/" .. #ew)
	check("模型：eep 留痕带码值 2048/PD=0",
		ew[1].code == 2048 and ew[1].pd == 0)
end

-- 1.4 命令分类与帧长/非法帧
dev:reset()
check("模型：空帧/单字节快速帧 NACK",
	dev.write({}) == false and dev.write({ 0x08 }) == false)
check("模型：EEP 命令缺字节 NACK", dev.write({ 0x60, 0x80 }) == false)
-- 010 只写 DAC（驱动未用）：合法帧照 ACK、留痕 unknown、不改状态
dev:set_dac(100)
check("模型：010 命令 ACK 但不改状态",
	dev.write({ 0x40, 0x00, 0x00 }) == true and dev:level() == 100)
check("模型：未用命令留痕 unknown",
	dev:write_log()[#dev:write_log()].cmd == "unknown")

-- 1.5 故障钩子：reset 保留、clear_faults 解除；按读长度定向断
dev:set_eep_stuck(true)
dev.write({ 0x60, 0x80, 0x00 })
dev:advance(500)
check("模型：eep_stuck 时 500ms 仍忙", dev:busy() == true)
dev:reset()
check("模型：reset 保留 eep_stuck 钩子、状态归零",
	dev.eep_stuck == true and dev:busy() == false and dev:level() == 0)
dev:clear_faults()
dev.nack = true
check("模型：nack=true 写返 false、读返 nil",
	dev.write({ 0x00, 0x00 }) == false and dev.read(5) == nil)
dev.nack = false
dev:fail_read(function(n) return n == 1 end)
check("模型：fail_read(n==1) 只断 RDY 轮询、5B 读回放行",
	dev.read(1) == nil and dev.read(5) ~= nil)
dev:fail_write(function(b) return b[1] == 0x60 end)
check("模型：fail_write 命中 EEP 帧 NACK、快速帧放行",
	dev.write({ 0x60, 0x80, 0x00 }) == false and dev.write({ 0x08, 0x00 }) == true)
dev:clear_faults()

-- 1.6 状态预置（build 在位读回非默认值）
dev:set_dac(2048):set_eeprom(2048):set_pd(0)
do
	local r = dev.read(5)
	check("模型：预置 2048/2048 读回 80 80 00 08 00",
		r[1] == 0x80 and r[2] == 0x80 and r[3] == 0x00 and r[4] == 0x08 and r[5] == 0x00)
end
dev:set_dac(99999)
check("模型：set_dac 钳 4095", dev:level() == 4095)

-- ==================== 2) build（真实驱动） ====================

-- 2.1 在位读回：真板 EEPROM 已写过 2048
local m = section()
dev:set_dac(2048):set_eeprom(2048)
expect_ok("build 默认地址 0x62 读回在位", function() return build({ fd = fd }) end)
do
	local es = entries(m)
	local nset, nread, nwrite = 0, 0, 0
	for _, e in ipairs(es) do
		if e.dir == "set" then nset = nset + 1 end
		if e.dir == "r" then nread = nread + 1 end
		if e.dir == "w" then nwrite = nwrite + 1 end
	end
	check("build：恰好 set_addr×1 + 纯读×1 + 零写",
		nset == 1 and nread == 1 and nwrite == 0,
		string.format("set=%d read=%d write=%d", nset, nread, nwrite))
	check("build：set_addr 收到 0x62=98", set_addrs(m)[1] == 98,
		tostring(set_addrs(m)[1]))
	check("build：纯读长度 5（无寄存器指针）", reads(m)[1] == 5,
		tostring(reads(m)[1]))
end

-- 2.2 字符串 fd/address
m = section()
dev:set_dac(2048):set_eeprom(2048)
expect_ok("build 字符串 fd='3' address='0x62'",
	function() return build({ fd = "3", address = "0x62" }) end)
check("build：set_addr 留痕 98", set_addrs(m)[1] == 98)

-- 2.3 vref 列（影响后续 call 换算，此节先验接受与缺省回退）
section()
expect_ok("build vref='3.3'", function() return build({ fd = fd, vref = "3.3" }) end)
section()
expect_ok("build vref 非法回退 5.0",
	function() return build({ fd = fd, vref = "-" }) end)

-- 2.4 build 错误通道
section()
dev.nack_read = true
expect_err("build 读回失败（器件不在位）",
	function() return build({ fd = fd }) end, "Failed to read MCP4725")

section()
expect_err("build set_addr 失败（addr>0x7F）",
	function() return build({ fd = fd, address = "0x80" }) end, "set_addr failed")

m = section()
expect_err("build 缺 fd", function() return build({ address = "0x62" }) end, "Invalid Argument: fd")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")
check("build：参数校验失败零总线事务", #entries(m) == 0, #entries(m))

-- ==================== 3) call 快速写（真实驱动） ====================

section()
expect_ok("快速写段前置 build（vref=5.0）", function() return build({ fd = fd }) end)

m = #vbus.txlog
local res = expect_ok("call percent='50'（快速写）",
	function() return call({ fd = fd, percent = "50" }) end)
check("call：code=floor(2047.5+0.5)=2048/eeprom 回显 0",
	res and res.level == 2048 and res.eeprom == 0, tostring(res and res.level))
check("call：返回 volt=2.5/percent 反算 2048*100/4095≈50.01",
	res and near(res.volt, 2.5) and near(res.percent, 2048 * 100 / 4095),
	tostring(res and res.volt) .. "/" .. tostring(res and res.percent))
do
	local ok, detail = bytes_is(writes(m), { 0x08, 0x00 })
	check("call：快速写帧 [0x08,0x00]", ok, detail)
end
check("模型：帧被解码 DAC=2048/PD=0/EEPROM 未动",
	dev:level() == 2048 and dev:pd() == 0 and dev:eeprom_code() == 0)
check("模型：快速写不产生读事务", #reads(m) == 0, #reads(m))

m = #vbus.txlog
res = expect_ok("call volt='2.5'（vref=5）",
	function() return call({ fd = fd, volt = "2.5" }) end)
check("call：volt 换算 2048", res and res.level == 2048, tostring(res and res.level))
local ok = bytes_is(writes(m), { 0x08, 0x00 })
check("call：帧 [0x08,0x00]", ok)

m = #vbus.txlog
res = expect_ok("call volt='5.0'（钳满码）",
	function() return call({ fd = fd, volt = "5.0" }) end)
check("call：volt=vref 钳 4095", res and res.level == 4095, tostring(res and res.level))
ok = bytes_is(writes(m), { 0x0F, 0xFF })
check("call：满码帧 [0x0F,0xFF]", ok)

m = #vbus.txlog
res = expect_ok("call level='-100'（负值钳 0）",
	function() return call({ fd = fd, level = "-100" }) end)
check("call：level 钳 0", res and res.level == 0, tostring(res and res.level))
ok = bytes_is(writes(m), { 0x00, 0x00 })
check("call：零码帧 [0x00,0x00]", ok)

-- level 超上限
m = #vbus.txlog
res = expect_ok("call level='99999'（超上限钳 4095）",
	function() return call({ fd = fd, level = "99999" }) end)
ok = bytes_is(writes(m), { 0x0F, 0xFF })
check("call：超上限钳满码", res and res.level == 4095 and ok)

-- 优先级 level > volt > percent
m = #vbus.txlog
res = expect_ok("call 三参同给，level 优先",
	function() return call({ fd = fd, level = "100", volt = "2.5", percent = "50" }) end)
ok = bytes_is(writes(m), { 0x00, 0x64 })
check("call：优先级 level（100=0x0064）", res and res.level == 100 and ok,
	tostring(res and res.level))
m = #vbus.txlog
res = expect_ok("call volt+percent，volt 优先",
	function() return call({ fd = fd, volt = "0.0", percent = "50" }) end)
ok = bytes_is(writes(m), { 0x00, 0x00 })
check("call：volt=0 压过 percent", res and res.level == 0 and ok)

-- percent=100 满码
m = #vbus.txlog
res = expect_ok("call percent='100'（满码）",
	function() return call({ fd = fd, percent = "100" }) end)
ok = bytes_is(writes(m), { 0x0F, 0xFF })
check("call：100% = 4095", res and res.level == 4095 and ok)

-- vref=3.3 换算
section()
expect_ok("前置 build vref=3.3", function() return build({ fd = fd, vref = "3.3" }) end)
m = #vbus.txlog
res = expect_ok("call volt='3.3' vref=3.3 钳满码",
	function() return call({ fd = fd, volt = "3.3" }) end)
check("call：3.3V 档满码", res and res.level == 4095, tostring(res and res.level))
m = #vbus.txlog
res = expect_ok("call volt='1.65' vref=3.3 半码",
	function() return call({ fd = fd, volt = "1.65" }) end)
check("call：半幅=2048（floor(2048+0.5)）", res and res.level == 2048,
	tostring(res and res.level))

-- 快速写失败
section()
expect_ok("错误通道前置 build", function() return build({ fd = fd }) end)
m = #vbus.txlog
dev.nack_write = true
expect_err("call 快速写 NACK",
	function() return call({ fd = fd, percent = "50" }) end, "Failed to write MCP4725 DAC")
check("call：失败帧仍入 txlog", #writes(m) == 1, #writes(m))
check("模型：NACK 帧不更新状态", dev:level() == 0)
dev:clear_faults()

-- ==================== 4) call EEPROM 写 + RDY 轮询 ====================

section()
expect_ok("EEP 段前置 build", function() return build({ fd = fd }) end)

m = #vbus.txlog
res = expect_ok("call percent='50' eep='1'（50ms 后首次轮询即完成）",
	function() return call({ fd = fd, percent = "50", eep = "1" }) end)
check("call：eep 成功回显 eeprom=1/level=2048",
	res and res.eeprom == 1 and res.level == 2048,
	tostring(res and res.eeprom))
do
	local ok, detail = bytes_is(writes(m), { 0x60, 0x80, 0x00 })
	check("call：EEP 写帧 [0x60,0x80,0x00]", ok, detail)
end
do
	local rs = reads(m)
	check("call：写后恰好一次 RDY 轮询读（25ms<50ms 步进）",
		#rs == 1 and rs[1] == 1, table.concat(rs, ","))
	check("call：轮询前睡 50ms（虚拟时钟推进写周期）",
		sleep_total == 50, tostring(sleep_total))
end
check("模型：DAC+EEPROM 双码=2048、当前不忙",
	dev:level() == 2048 and dev:eeprom_code() == 2048 and not dev:busy())

-- 满码 EEP 写
m = #vbus.txlog
res = expect_ok("call level='4095' eep='1'",
	function() return call({ fd = fd, level = "4095", eep = "1" }) end)
do
	local ok = bytes_is(writes(m), { 0x60, 0xFF, 0xF0 })
	check("call：满码 EEP 帧 [0x60,0xFF,0xF0]", ok)
end

-- 超时：RDY 永不就绪
section()
expect_ok("超时前置 build", function() return build({ fd = fd }) end)
dev:set_eep_stuck(true)
m = #vbus.txlog
expect_err("call EEPROM 写超时（10×50ms）",
	function() return call({ fd = fd, percent = "50", eep = "1" }) end,
	"EEPROM write timeout")
check("call：超时共轮询 10 次、累计睡 500ms",
	#reads(m) == 10 and sleep_total == 500,
	string.format("reads=%d sleep=%d", #reads(m), sleep_total))
check("模型：超时后器件仍报忙", dev:busy())
dev:clear_faults()

-- 轮询途中总线失败（必须与超时区分，2026-09 审计点）
section()
expect_ok("轮询失败前置 build", function() return build({ fd = fd }) end)
dev:fail_read(function(n) return n == 1 end)
expect_err("call RDY 轮询总线失败",
	function() return call({ fd = fd, percent = "50", eep = "1" }) end,
	"bus read failed while polling RDY")
dev:clear_faults()

-- EEP 写本身失败
section()
expect_ok("写失败前置 build", function() return build({ fd = fd }) end)
dev:fail_write(function(b) return b[1] == 0x60 end)
m = #vbus.txlog
expect_err("call EEP 写帧 NACK",
	function() return call({ fd = fd, percent = "50", eep = "1" }) end,
	"Failed to write MCP4725 DAC+EEPROM")
check("call：写失败后无轮询读/无睡眠",
	#reads(m) == 0 and sleep_total == 0,
	string.format("reads=%d sleep=%d", #reads(m), sleep_total))
dev:clear_faults()

-- ==================== 5) call 无参读回 ====================

section()
expect_ok("读回段前置 build（默认状态）", function() return build({ fd = fd }) end)
-- 先写 2048 进 EEPROM，再快速写 4095：读回应 DAC=4095/EEPROM=2048
expect_ok("预置：先 EEP 2048",
	function() return call({ fd = fd, level = "2048", eep = "1" }) end)
expect_ok("预置：再快速写 4095",
	function() return call({ fd = fd, level = "4095" }) end)
m = #vbus.txlog
res = expect_ok("call 无参读回", function() return call({ fd = fd }) end)
if res then
	check("读回：DAC=4095（易失码与 EEPROM 独立）", res.level == 4095,
		tostring(res.level))
	check("读回：EEPROM=2048", res.eeprom == 2048, tostring(res.eeprom))
	check("读回：pd=0/rdy=1", res.pd == 0 and res.rdy == 1,
		tostring(res.pd) .. "/" .. tostring(res.rdy))
	check("读回：volt=4095*5/4096≈4.9988", near(res.volt, 4095 * 5.0 / 4096),
		tostring(res.volt))
end
check("读回：窗口内纯读 n=5 ×1、零写",
	#reads(m) == 1 and reads(m)[1] == 5 and #writes(m) == 0,
	"reads=" .. #reads(m) .. " writes=" .. #writes(m))

m = #vbus.txlog
dev.nack_read = true
expect_err("call 无参读回失败",
	function() return call({ fd = fd }) end, "Failed to read MCP4725")
check("读失败窗口零写", #writes(m) == 0)
dev:clear_faults()

-- ==================== 6) call 参数校验 + destroy ====================

m = section()
expect_err("call 缺 fd", function() return call({ percent = "50" }) end, "Invalid Argument: fd")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments: table")
check("call：参数校验零总线事务", #entries(m) == 0, #entries(m))

m = section()
expect_ok("destroy 无资源需释放", function() return destroy({}) end)
check("destroy：零总线事务", #entries(m) == 0, #entries(m))

tester.summary("test_mcp4725")

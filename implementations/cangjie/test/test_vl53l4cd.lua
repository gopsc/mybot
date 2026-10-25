-- test_vl53l4cd.lua —— VL53L4CD 真实驱动 + 虚拟 I2C 总线 + ptr16 模型
-- 用法（项目根目录）: luajit test/test_vl53l4cd.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 300 行手写 16 位寄存器桩」迁移到
-- 「真实驱动 + virtbus I2C 注入层 + virtbus/vl53l4cd.lua 模型」。本器件是
-- virtbus 库【首个 16 位寄存器指针（ptr16）真实器件】——寄存器窗线性
-- 16 位寻址、指针事务为 2 字节大端地址、多字节写按地址自增（91 字节
-- 配置流就是一笔 0x002D 起的流写），与同系列 VL53L0X（8 位指针+分页）
-- 互相印证两种寻址体系的建模边界。模型在 regmap ptr16 底座上包装：
-- 软复位 reseed、0x0030/0x0031 data-ready 极性链动态合成、启动预武装/
-- 清中断 5ms 转换倒计时（advance 虚拟时钟）、固定地址结果块注入。
--
-- SetRangeTiming 编码预期值为驱动移植常量（osc=10000 时 macro=3865464），
-- 锁定对 ST ULD 源码的移植不被无意改动：
--   budget=50/inter=0  -> A=0x00C8 B=0x0185（267 归一化为 exp1/ls133）
--   budget=200         -> A=0x02D1 B=0x038B（1115 归一化为 exp3/ls139）
--   budget=10          -> A=0x001F B=0x0029
--   budget=50/inter=100（clock_pll=512）-> INTER=54016(0xD300) A=0x0060 B=0x0080
local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local tmod = dofile("modules/lib/virtbus/vl53l4cd.lua")
vbus.reset()

local ADDR = 0x29
local dev = tmod.new()
vbus.attach("VL53L4CD@0x29", ADDR, dev)
vbus.load_driver("modules/VL53L4CD.lua")

-- milli_sleep：累计时长 + 推进转换倒计时虚拟时钟（驱动运行时解析全局名）
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
-- 找首地址命中的写事务（16 位指针大端）
local function write_at(mark, reg16)
	for _, bs in ipairs(writes(mark)) do
		if #bs >= 2 and bs[1] * 256 + bs[2] == reg16 then return bs end
	end
end
-- 把一个 16 位寄存器写的值字节序列拼回（首 2 字节为指针，其余为数据）
local function write_values(bs)
	local t = {}
	for i = 3, #bs do t[#t + 1] = bs[i] end
	return t
end
local function hx(bs)
	local t = {}
	for i = 1, #bs do t[i] = string.format("%02X", bs[i]) end
	return table.concat(t, " ")
end
-- 结果块读：0x89(1B)/0x8C/0x8E/0x90/0x92/0x96(各 2B) 的纯指针写后紧跟的 r。
-- wait_ready 轮询的 0x30/0x31 同为 1B 读，必须按指针地址过滤，不能只数 r。
local RESULT_READ_LEN = {
	[0x0089] = 1, [0x008C] = 2, [0x008E] = 2,
	[0x0090] = 2, [0x0092] = 2, [0x0096] = 2,
}
local function result_reads(mark)
	local want, lens = nil, {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "w" and #e.bytes == 2 then
			want = RESULT_READ_LEN[e.bytes[1] * 256 + e.bytes[2]]
		elseif e.dir == "r" then
			if want then lens[#lens + 1] = e.bytes.n end
			want = nil
		else
			want = nil
		end
	end
	return lens
end

-- ==================== 1) 模型协议事实 ====================

section()
-- 1.1 上电种子：振荡器/PLL/固件状态
check("模型：OSC_FREQUENCY 种子 word=10000(0x2710)",
	dev:get_word(0x0006) == 10000, tostring(dev:get_word(0x0006)))
check("模型：OSC_CALIBRATE 种子 word=512(0x0200)",
	dev:get_word(0x00DE) == 512, tostring(dev:get_word(0x00DE)))
check("模型：固件状态种子 0x00E5=3", dev:get(0x00E5) == 3)

-- 1.2 软复位：保持无副作用、释放则芯片全新
dev:set(0x0030, 0x11)
dev.write({ 0x00, 0x00, 0x00 })
check("模型：0x0000=0x00 复位保持不清寄存器", dev:get(0x0030) == 0x11)
dev:set(0x0030, 0x11)
dev.write({ 0x00, 0x87, 0x40 })
dev.write({ 0x00, 0x86, 0x01 })
check("模型：复位前启动序列有留痕", #dev:start_writes() == 1 and dev:clear_count() == 1)
dev.write({ 0x00, 0x00, 0x01 })
check("模型：0x0000=0x01 释放后全新（mux 回种子/启动序列清零）",
	dev:get(0x0030) == nil and #dev:start_writes() == 0 and dev:clear_count() == 0)
check("模型：boot_releases 累计 1", dev:boot_releases() == 1)
check("模型：释放后固件立即就绪（预武装，守护 build 不驱动时钟）",
	dev:get(0x00E5) == 3)

-- 1.3 data-ready 极性链（配置流写 0x0030=0x11，bit4=1 → 有效极性 0）
dev:set(0x0030, 0x11)
check("模型：默认未启动未就绪（mux=0x11 时反电平 bit0=1 → 0x03）",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)
dev.write({ 0x00, 0x87, 0x40 })
check("模型：启动预武装（mux=0x11 bit0=0 → 0x02）",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x02)
-- 清中断 → 5ms 转换倒计时
dev.write({ 0x00, 0x86, 0x01 })
check("模型：清中断即解除武装",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)
check("模型：advance(4) 仍忙", (function()
	dev:advance(4); dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)
check("模型：advance(1) 就绪（共 5ms）", (function()
	dev:advance(1); dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x02)
-- 极性翻转：mux bit4=0 → 有效极性 1
dev:set(0x0030, 0x00)
check("模型：mux=0x00 翻转后就绪电平 bit0=1 → 0x03",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)

-- 1.4 停止态：清中断/advance 不再武装
dev:set(0x0030, 0x11)
dev.write({ 0x00, 0x87, 0x00 })
dev.write({ 0x00, 0x86, 0x01 })
dev:advance(50)
check("模型：停止态推进 50ms 仍不就绪",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)
check("模型：停止态 running=false", dev:running() == false)

-- 1.5 结果块注入（字节宽度，换算不进模型）
dev:inject_result({ st = 0x09, spad = 512, signal = 100, ambient = 50, sigma = 8, dist = 1234 })
check("模型：0x0089 状态原始码=0x09", dev:get(0x0089) == 0x09)
check("模型：SPAD word=512 / signal=100 / ambient=50 / sigma=8 / dist=1234",
	dev:get_word(0x008C) == 512 and dev:get_word(0x008E) == 100
	and dev:get_word(0x0090) == 50 and dev:get_word(0x0092) == 8
	and dev:get_word(0x0096) == 1234)

-- 1.6 故障钩子：reset 保留、clear_faults 解除
dev:set_boot_stuck(true)
dev.write({ 0x00, 0x00, 0x01 })
check("模型：boot_stuck 释放复位后 0x00E5=0", dev:get(0x00E5) == 0)
dev:reset()
check("模型：reset 保留 boot_stuck", dev:get(0x00E5) == 0)
dev:clear_faults()
dev:reset()
check("模型：clear_faults 后恢复 3", dev:get(0x00E5) == 3)
dev:set_never_ready(true)
dev.write({ 0x00, 0x87, 0x21 })
check("模型：never_ready 强制反极性电平（mux 回种子=0，int_pol=1 → bit0=0 即 0x02）",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x02)
dev:clear_faults()
check("模型：解除后恢复就绪（int_pol=1 → bit0=1 即 0x03）",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)
dev:fail_read(function(p, n) return p == 0x00E5 end)
check("模型：fail_read 按 16 位地址定向",
	(function() dev.write({ 0x00, 0xE5 }); return dev.read(1) end)() == nil)
dev:fail_write(function(b) return b[1] == 0 and b[2] == 0x86 end)
check("模型：fail_write 命中清中断帧 NACK",
	dev.write({ 0x00, 0x86, 0x01 }) == false)
dev:clear_faults()
dev.nack = true
check("模型：nack 读写全断",
	dev.write({ 0x00, 0x30, 0x11 }) == false
	and (function() dev.write({ 0x00, 0x31 }); return dev.read(1) end)() == nil)
dev:clear_faults()
dev.nack_read = true
check("模型：nack_read 只断读",
	(function() dev.write({ 0x00, 0x30, 0x11 }); return dev.write end)() ~= nil
	and (function() dev.write({ 0x00, 0x31 }); return dev.read(1) end)() == nil)
dev:clear_faults()

-- 1.7 virt_tick：32 拍确定性正弦 100~1100mm + 预武装
dev:reset()
dev.write({ 0x00, 0x87, 0x21 })
local function tick_dist(n)
	dev:virt_tick(n)
	return dev:get_word(0x0096)
end
check("模型：virt_tick 节拍 0/8/16/24 = 600/1100/600/100",
	tick_dist(0) == 600 and tick_dist(8) == 1100 and tick_dist(16) == 600
	and tick_dist(24) == 100)
check("模型：virt_tick 固定质量字段 st=9/spad=512/signal=100/ambient=50/sigma=8",
	dev:get(0x0089) == 0x09 and dev:get_word(0x008C) == 512
	and dev:get_word(0x008E) == 100 and dev:get_word(0x0090) == 50
	and dev:get_word(0x0092) == 8)
check("模型：virt_tick 后运行态预武装（mux=0 int_pol=1 → bit0=1 即 0x03）",
	(function() dev.write({ 0x00, 0x31 }); return dev.read(1)[1] end)() == 0x03)

-- ==================== 2) build（真实驱动） ====================

-- 2.1 默认参数：软复位/配置流/启动序列/清中断/尾三写
local m = section()
expect_ok("build 默认参数 budget=50/continuous",
	function() return build({ fd = fd, address = "0x29" }) end)
do
	local es = entries(m)
	local nset = 0
	for _, e in ipairs(es) do if e.dir == "set" then nset = nset + 1 end end
	check("build：恰好 set_addr×1", nset == 1, tostring(nset))
	check("build：set_addr 收到 0x29=41", set_addrs(m)[1] == 41,
		tostring(set_addrs(m)[1]))
end
do
	-- 软复位两笔（0x00 保持 / 0x01 释放）
	local hold = write_at(m, 0x0000)
	check("build：软复位保持帧 [00 00 00] 存在",
		hold ~= nil and #hold == 3 and hold[3] == 0x00, hold and hx(hold))
	-- 配置流：0x002D 起 91 字节（含 2 字节指针共 93）
	local cfg = write_at(m, 0x002D)
	check("build：默认配置流单事务 91 字节（帧长 93）",
		cfg ~= nil and #cfg == 93, tostring(cfg and #cfg))
	check("build：配置流末字节 0x0087=0x00", cfg and cfg[93] == 0x00)
end
do
	local sw = dev:start_writes()
	check("build：启动序列 VHV(0x40)→停(0x00)→连续(0x21)",
		#sw == 3 and sw[1] == 0x40 and sw[2] == 0x00 and sw[3] == 0x21,
		table.concat(sw, ","))
	check("build：清中断 2 次（VHV + 首测量）", dev:clear_count() == 2,
		tostring(dev:clear_count()))
end
check("build：尾三写 0x0008=0x09", dev:get(0x0008) == 0x09)
check("build：尾三写 0x000B=0x00", dev:get(0x000B) == 0x00)
check("build：尾三写 0x0024 word=0x0500", dev:get_word(0x0024) == 0x0500,
	string.format("0x%04X", dev:get_word(0x0024)))

-- 2.2 时序编码 budget=50 连续
check("build：RANGE_CONFIG_A=0x00C8", dev:get_word(0x005E) == 0x00C8,
	string.format("0x%04X", dev:get_word(0x005E)))
check("build：RANGE_CONFIG_B=0x0185", dev:get_word(0x0061) == 0x0185,
	string.format("0x%04X", dev:get_word(0x0061)))
check("build：INTERMEASUREMENT dword=0（连续模式）",
	dev:get(0x006C) == 0 and dev:get(0x006D) == 0
	and dev:get(0x006E) == 0 and dev:get(0x006F) == 0)
do
	-- 编码写均为 word（4 字节帧），INTER 为 dword（6 字节帧）
	local a, b, inter = write_at(m, 0x005E), write_at(m, 0x0061), write_at(m, 0x006C)
	check("build：A/B 为 2 字节 word 写、INTER 为 4 字节 dword 写",
		a and #a == 4 and b and #b == 4 and inter and #inter == 6,
		string.format("%d/%d/%d", a and #a, b and #b, inter and #inter))
	check("build：INTER dword 数据 00 00 00 00",
		inter and table.concat(write_values(inter), ",") == "0,0,0,0")
end
-- build 预武装路径：全程无轮询睡眠（启动即就绪；仅复位 1+5ms）
check("build：预武装下轮询零睡眠（仅复位 6ms）", sleep_total == 6,
	tostring(sleep_total))

-- 2.3 字符串 fd/address
m = section()
expect_ok("build 字符串 fd='3' address='0x29'",
	function() return build({ fd = "3", address = "0x29" }) end)
check("build：set_addr 留痕 41", set_addrs(m)[1] == 41)

-- 2.4 budget/inter 编码四档
section()
expect_ok("build budget='200'", function()
	return build({ fd = fd, address = "0x29", budget = "200" }) end)
check("build：budget=200 A=0x02D1 B=0x038B",
	dev:get_word(0x005E) == 0x02D1 and dev:get_word(0x0061) == 0x038B,
	string.format("0x%04X/0x%04X", dev:get_word(0x005E), dev:get_word(0x0061)))

section()
expect_ok("build budget='5'（钳到 10）", function()
	return build({ fd = fd, address = "0x29", budget = "5" }) end)
check("build：budget=10 A=0x001F B=0x0029",
	dev:get_word(0x005E) == 0x001F and dev:get_word(0x0061) == 0x0029,
	string.format("0x%04X/0x%04X", dev:get_word(0x005E), dev:get_word(0x0061)))

section()
expect_ok("build inter='100'（自主低功耗模式）", function()
	return build({ fd = fd, address = "0x29", inter = "100" }) end)
check("build：INTER 四字节 00 00 D3 00",
	dev:get(0x006C) == 0x00 and dev:get(0x006D) == 0x00
	and dev:get(0x006E) == 0xD3 and dev:get(0x006F) == 0x00,
	string.format("%02X %02X %02X %02X",
		dev:get(0x006C), dev:get(0x006D), dev:get(0x006E), dev:get(0x006F)))
check("build：自主模式 A=0x0060 B=0x0080",
	dev:get_word(0x005E) == 0x0060 and dev:get_word(0x0061) == 0x0080,
	string.format("0x%04X/0x%04X", dev:get_word(0x005E), dev:get_word(0x0061)))
check("build：自主模式启动值 0x40",
	dev:start_writes()[#dev:start_writes()] == 0x40)

section()
expect_err("build inter='30'（<=budget 非法）", function()
	return build({ fd = fd, address = "0x29", inter = "30" }) end,
	"Invalid inter-measurement")

-- 2.5 build 错误通道
section()
dev.nack_write = true
expect_err("build 软复位写失败", function()
	return build({ fd = fd, address = "0x29" }) end, "Failed to reset VL53L4CD")

section()
dev:set_boot_stuck(true)
expect_err("build 固件启动超时", function()
	return build({ fd = fd, address = "0x29" }) end, "firmware boot timeout")

section()
dev:fail_read(function(p) return p == 0x00E5 end)
expect_err("build 读固件状态失败", function()
	return build({ fd = fd, address = "0x29" }) end, "Failed to read firmware boot status")

section()
dev:fail_read(function(p) return p == 0x0031 end)
expect_err("build 轮询 data-ready 总线失败", function()
	return build({ fd = fd, address = "0x29" }) end, "Failed to poll VL53L4CD data-ready")

section()
dev:set_never_ready(true)
m = #vbus.txlog
expect_err("build VHV 测量超时", function()
	return build({ fd = fd, address = "0x29" }) end, "VHV measurement ready timeout")
check("build：超时轮询累计睡眠约 1000ms（1ms 步进）",
	sleep_total >= 1000, tostring(sleep_total))

section()
dev:fail_read(function(p) return p == 0x0006 end)
expect_err("build 读振荡器频率失败", function()
	return build({ fd = fd, address = "0x29" }) end, "Failed to read oscillator frequency")

section()
expect_err("build set_addr 失败（addr>0x7F）", function()
	return build({ fd = fd, address = "0x80" }) end, "set_addr failed")

m = section()
expect_err("build 缺 fd", function() return build({ address = "0x29" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")
check("build：参数校验失败零总线事务", #entries(m) == 0, #entries(m))

-- ==================== 3) call（真实驱动） ====================

section()
expect_ok("call 段前置 build", function()
	return build({ fd = fd, address = "0x29" }) end)

-- 3.1 有效测量：注入 1234mm / 800kcps / 400kcps / sigma 2.0 / 2 SPAD / st=0x09
dev:inject_result({ st = 0x09, spad = 512, signal = 100, ambient = 50, sigma = 8, dist = 1234 })
m = #vbus.txlog
local sleep_base = sleep_total	-- build 复位已睡 6ms，call 只看增量
local res = expect_ok("call 有效测量", function()
	return call({ fd = fd, address = "0x29" }) end)
if res then
	check("call：DIST_MM=1234", res.DIST_MM == 1234, tostring(res.DIST_MM))
	check("call：STATUS=0/VALID=1", res.STATUS == 0 and res.VALID == 1,
		tostring(res.STATUS) .. "/" .. tostring(res.VALID))
	check("call：SPAD_NB=2", res.SPAD_NB == 2, tostring(res.SPAD_NB))
	check("call：SIGNAL=800/AMBIENT=400 kcps",
		res.SIGNAL_KCPS == 800 and res.AMBIENT_KCPS == 400,
		tostring(res.SIGNAL_KCPS) .. "/" .. tostring(res.AMBIENT_KCPS))
	check("call：SIGMA_MM=2.0", near(res.SIGMA_MM, 2.0), tostring(res.SIGMA_MM))
end
do
	-- 结果块六个独立原子读（按指针地址过滤掉 wait_ready 的 0x30/0x31 轮询）
	local rs = result_reads(m)
	check("call：六次结果读长度序列 1,2,2,2,2,2",
		#rs == 6 and table.concat(rs, ",") == "1,2,2,2,2,2", table.concat(rs, ","))
	local clr = write_at(m, 0x0086)
	check("call：读完再清中断 [00 86 01]",
		clr ~= nil and #clr == 3 and clr[3] == 0x01, clr and hx(clr))
	check("call：首拍等转换倒计时增量睡约 5ms",
		sleep_total - sleep_base >= 5 and sleep_total - sleep_base <= 8,
		tostring(sleep_total - sleep_base))
end

-- 3.2 连续第二拍：清中断后模型重新计时， milli_sleep 推进后就绪
dev:inject_result({ st = 0x09, spad = 512, signal = 100, ambient = 50, sigma = 8, dist = 2000 })
m = #vbus.txlog
sleep_base = sleep_total
res = expect_ok("call 连续第二拍 dist=2000", function()
	return call({ fd = fd, address = "0x29" }) end)
check("call：第二拍读到新注入值", res and res.DIST_MM == 2000,
	tostring(res and res.DIST_MM))
check("call：第二拍同样增量等约 5ms 转换",
	sleep_total - sleep_base >= 5 and sleep_total - sleep_base <= 8,
	tostring(sleep_total - sleep_base))

-- 3.3 状态映射表
dev:inject_result({ st = 0x00, spad = 512, dist = 100 })
res = expect_ok("call raw 状态 0x00 → 255", function()
	return call({ fd = fd, address = "0x29" }) end)
check("call：raw=0 STATUS=255/VALID=0", res and res.STATUS == 255 and res.VALID == 0)

dev:inject_result({ st = 0x04, spad = 512, dist = 100 })
res = expect_ok("call raw 状态 0x04 → 2", function()
	return call({ fd = fd, address = "0x29" }) end)
check("call：raw=4 STATUS=2", res and res.STATUS == 2, tostring(res and res.STATUS))

dev:inject_result({ st = 0x09, spad = 0, dist = 100 })
res = expect_ok("call 有效状态但 SPAD=0 守卫", function()
	return call({ fd = fd, address = "0x29" }) end)
check("call：SPAD_NB=0 → STATUS=255（ST 同款守卫）",
	res and res.SPAD_NB == 0 and res.STATUS == 255 and res.VALID == 0)

-- 3.4 极性翻转：mux bit4=0（int_pol=1），armed 合成 bit0=1 仍就绪
dev:set(0x0030, 0x00)
dev:inject_result({ st = 0x09, spad = 512, signal = 100, ambient = 50, sigma = 8, dist = 1234 })
res = expect_ok("call mux 极性翻转后仍就绪", function()
	return call({ fd = fd, address = "0x29" }) end)
check("call：翻转极性下读到注入值 1234", res and res.DIST_MM == 1234,
	tostring(res and res.DIST_MM))
dev:set(0x0030, 0x11)

-- 3.5 错误通道：超时 / 轮询失败 / 结果读失败 / 清中断失败 / 参数
section()
expect_ok("错误段前置 build", function()
	return build({ fd = fd, address = "0x29" }) end)
dev:set_never_ready(true)
expect_err("call data-ready 超时", function()
	return call({ fd = fd, address = "0x29" }) end, "data-ready timeout")
dev:clear_faults()

dev:fail_read(function(p) return p == 0x0031 end)
expect_err("call 轮询总线失败", function()
	return call({ fd = fd, address = "0x29" }) end, "Failed to poll")
dev:clear_faults()

dev:fail_read(function(p) return p == 0x0096 end)
expect_err("call 读距离失败", function()
	return call({ fd = fd, address = "0x29" }) end, "range results")
dev:clear_faults()

dev:fail_write(function(b) return b[1] == 0 and b[2] == 0x86 end)
m = #vbus.txlog
expect_err("call 清中断写失败", function()
	return call({ fd = fd, address = "0x29" }) end, "Failed to clear VL53L4CD interrupt")
check("call：清中断失败发生在六结果读之后（6 个结果读已完成）",
	#result_reads(m) == 6, tostring(#result_reads(m)))
dev:clear_faults()

m = section()
expect_err("call 缺 fd", function() return call({ address = "0x29" }) end, "fd or address")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments")
check("call：参数校验零总线事务", #entries(m) == 0, #entries(m))

-- ==================== 4) destroy ====================

section()
expect_ok("destroy 段前置 build", function()
	return build({ fd = fd, address = "0x29" }) end)
m = #vbus.txlog
expect_ok("destroy 停止测距", function()
	return destroy({ fd = fd, address = "0x29" }) end)
do
	local sw = dev:start_writes()
	check("destroy：末笔 0x0087=0x00", sw[#sw] == 0x00, tostring(sw[#sw]))
	local st = write_at(m, 0x0087)
	check("destroy：发 [00 87 00]", st ~= nil and #st == 3 and st[3] == 0x00,
		st and hx(st))
	check("模型：destroy 后 running=false", dev:running() == false)
end
m = section()
expect_ok("destroy 缺 fd/address 安全返回", function() return destroy({}) end)
check("destroy：无 fd 零总线事务", #entries(m) == 0, #entries(m))

tester.summary("test_vl53l4cd")

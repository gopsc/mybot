-- test_ina219.lua —— INA219 真实驱动 + 虚拟 I2C 总线 + 字寻址寄存器模型
-- 用法（项目根目录）: luajit test/test_ina219.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 184 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/INA219.lua 尾部 INA219_VIRT，
-- 2026-09-15 自 virtbus/ina219.lua 迁入）」。本器件是 virtbus 库【首个
-- 字寻址 16 位寄存器 I2C 器件】（不用字节地址 regmap）：寄存器号 0x00~0x05
-- 各代表一个 16 位字，写恒 {ptr,hi,lo}、读恒「写 ptr + 读 2 字节」返回该字
-- hi/lo；CONFIG bit15=RST 软复位（0x8000 不落盘、原地恢复默认 0x399F），
-- 无 ID 寄存器，build 靠复位后读回 0x399F 做芯片甄别（INA226 默认 0x4127）；
-- 连续模式结果寄存器恒有值，无转换门/无 pending；电流/功率驱动全软件换算
-- （I=Vshunt/Rshunt，P=Vbus·I，不写 0x05 校准寄存器）。
--
-- 覆盖：模型侧字寻址不串读/RST 自清与全文件复位/坏长度 NACK/s16 与 13 位
-- 左移布局/低 3 位标志/物理量量化钳制/独立观察口换算/virt_tick 峰谷与周期/
-- 六类钩子与 reset 保留钩子；真实 build 八档 avg 配置字与转换循环睡眠/
-- 参数归一/错挂甄别/六类负路径；真实 call 两寄存器读序列/正负电流功率/
-- rshunt 归一/标志位不影响换算/virt_tick 闭环/六类负路径；destroy 零事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（INA219_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载（本地绑定 smod 供后续多处
-- smod.new() 沿用；中途二次 load_driver 重定义全局工厂不影响旧绑定）
vbus.load_driver("modules/INA219.lua")
local smod = INA219_VIRT

local ADDR = 0x40
local dev = smod.new()
vbus.attach("INA219@0x40", ADDR, dev)

-- milli_sleep：累计时长（本模型无虚拟时钟，只累加供睡眠断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

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
-- 窗口内寄存器写 {ptr,hi,lo} 的字序列
local function write_words(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 3 then t[#t + 1] = b[1] * 65536 + b[2] * 256 + b[3] end
	end
	return t
end
local function p_arg(t) return { fd = fd, address = "0x40", avg = t } end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("上电 CONFIG 默认 0x399F", dev:config() == 0x399F, string.format("0x%04X", dev:config()))
check("上电 SHUNT 为 0", dev:shunt_raw() == 0, tostring(dev:shunt_raw()))
check("上电 BUS 为 0", dev:bus_raw() == 0, tostring(dev:bus_raw()))

-- 未预置字读作 0（0x03 POWER / 0x05 CALIB）
check("指针写 0x03", dev.write({ 0x03 }) == true)
local r3 = dev.read(2)
check("未预置字读 0x0000", r3 ~= nil and r3[1] == 0 and r3[2] == 0, r3 and table.concat(r3, ","))

-- 字寻址不串读：相邻字各自独立，读 2 字节是该字 hi/lo 而非字节地址 ptr/ptr+1
dev.write({ 0x01, 0x12, 0x34 })
dev.write({ 0x02, 0xBE, 0xEF })
dev.write({ 0x01 })
local w1 = dev.read(2)
check("字 0x01 读回 0x1234", w1[1] == 0x12 and w1[2] == 0x34, table.concat(w1, ","))
dev.write({ 0x02 })
local w2 = dev.read(2)
check("字 0x02 读回 0xBEEF（不串字）", w2[1] == 0xBE and w2[2] == 0xEF, table.concat(w2, ","))

-- 坏长度：恰 1（指针）或恰 3（字写）合法，2/4/0/非 table 全 NACK
check("2 字节写 NACK", dev.write({ 0x00, 0x39 }) == false)
check("4 字节写 NACK", dev.write({ 0x00, 0x12, 0x34, 0x56 }) == false)
check("空表写 NACK", dev.write({}) == false)
check("非 table 写 NACK", dev.write(nil) == false)
check("read(0) NACK", dev.read(0) == nil)

-- RST：0x8000 不落盘、CONFIG 回默认、全文件复位、计数 +1
check("section 后复位计数 0", dev:reset_count() == 0)
check("写工作配置 0x3E67", dev.write({ 0x00, 0x3E, 0x67 }))
check("配置留存 0x3E67", dev:config() == 0x3E67, string.format("0x%04X", dev:config()))
dev:set_shunt_raw(1234)
check("RST 写 ACK", dev.write({ 0x00, 0x80, 0x00 }))
check("RST 后 CONFIG 回 0x399F", dev:config() == 0x399F, string.format("0x%04X", dev:config()))
check("RST 清 SHUNT", dev:shunt_raw() == 0, tostring(dev:shunt_raw()))
check("复位计数 1", dev:reset_count() == 1, tostring(dev:reset_count()))
-- RST 位同写其他位也触发复位（datasheet：同写位忽略）
dev.write({ 0x00, 0x80, 0x01 })
check("0x8001 也复位且计数 2", dev:config() == 0x399F and dev:reset_count() == 2,
	string.format("0x%04X cnt=%s", dev:config(), tostring(dev:reset_count())))

-- s16 编码与钳制（PGA=/8 满量程 ±320mV = ±32000 LSB）
dev:set_shunt_raw(-1024)
check("s16 负码 -1024", dev:shunt_raw() == -1024, tostring(dev:shunt_raw()))
dev:set_shunt_raw(33000)
check("正超程钳 32000", dev:shunt_raw() == 32000, tostring(dev:shunt_raw()))
dev:set_shunt_raw(-33000)
check("负超程钳 -32000", dev:shunt_raw() == -32000, tostring(dev:shunt_raw()))
check("32000 LSB = -0.32V", near(dev:shunt_v(), -0.32), tostring(dev:shunt_v()))

-- BUS 13 位左移 3 布局与低 3 位标志
dev:set_bus_v(12.0)
check("12.0V → 码 3000<<3", dev:bus_raw() == 3000 * 8, tostring(dev:bus_raw()))
check("观察口 bus_v 回读 12.0", near(dev:bus_v(), 12.0), tostring(dev:bus_v()))
dev:set_bus_flags(true, true)
check("CNVR|OVF 置位低 3 位=3", dev:bus_raw() % 8 == 3, tostring(dev:bus_raw()))
check("标志位不影响 >>3 电压", near(dev:bus_v(), 12.0), tostring(dev:bus_v()))
dev:set_bus_v(40)
check("超额定钳 8191 码（0xFFF8，低 3 位留给标志）", dev:bus_raw() == 0xFFF8,
	string.format("0x%04X", dev:bus_raw()))
check("钳顶 32.764V", near(dev:bus_v(), 32.764), tostring(dev:bus_v()))

-- 物理量化（4mV/10µV 粒度）独立交叉
dev:set_vip(8.192, 0.04)
check("8.192V → 2048 码", dev:bus_raw() == 2048 * 8, tostring(dev:bus_raw()))
check("40mV → 4000 LSB", dev:shunt_raw() == 4000, tostring(dev:shunt_raw()))
check("40mV/0.05Ω = 0.8A", near(dev:current_a(0.05), 0.8), tostring(dev:current_a(0.05)))
check("P = 6.5536W", near(dev:power_w(0.05), 6.5536), tostring(dev:power_w(0.05)))
check("40mV/0.1Ω = 0.4A", near(dev:current_a(0.1), 0.4), tostring(dev:current_a(0.1)))

-- virt_tick：确定性 / 峰谷 / 周期
local t1, t2 = smod.new(), smod.new()
t1:virt_tick(5); t2:virt_tick(5)
check("virt_tick 确定性", t1:bus_raw() == t2:bus_raw() and t1:shunt_raw() == t2:shunt_raw())
local tk = smod.new()
tk:virt_tick(0)
check("n0 = 12.0V/1.0A", near(tk:bus_v(), 12.0) and near(tk:current_a(0.1), 1.0),
	string.format("%sV %sA", tk:bus_v(), tk:current_a(0.1)))
tk:virt_tick(8)	-- sin(π/2)=1
check("n8 峰 = 12.4V/1.6A", near(tk:bus_v(), 12.4) and near(tk:current_a(0.1), 1.6),
	string.format("%sV %sA", tk:bus_v(), tk:current_a(0.1)))
tk:virt_tick(24) -- sin(3π/2)=-1
check("n24 谷 = 11.6V/0.4A", near(tk:bus_v(), 11.6) and near(tk:current_a(0.1), 0.4),
	string.format("%sV %sA", tk:bus_v(), tk:current_a(0.1)))
tk:virt_tick(32)
check("n32 = n0（32 拍周期）", near(tk:bus_v(), 12.0) and near(tk:current_a(0.1), 1.0))

-- 故障钩子
section()
check("挂 fail_write", dev:fail_write(function(b) return b[1] == 0x05 end) ~= nil)
check("定向写失败", dev.write({ 0x05, 0x12, 0x34 }) == false)
check("他寄存器写照常", dev.write({ 0x03, 0x12, 0x34 }))
dev:clear_faults()
check("挂 fail_read", dev:fail_read(function(p, n) return p == 0x04 and n == 2 end) ~= nil)
dev.write({ 0x04 })
check("0x04 定向读失败", dev.read(2) == nil)
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
-- reset 保留故障钩子（复位不得解除测试钩子）
dev:fail_write(function(b) return b[1] == 0x05 end)
dev:reset()
check("reset 后写钩子仍在", dev.write({ 0x05, 0x00, 0x01 }) == false)
dev:clear_faults()
-- set_reset_id：模拟错挂芯片
dev:set_reset_id(0x4127)
check("set_reset_id 立即可见 0x4127", dev:config() == 0x4127, string.format("0x%04X", dev:config()))
dev:reset()
check("reset 后复位身份保持 0x4127", dev:config() == 0x4127, string.format("0x%04X", dev:config()))
dev:set_reset_id(0x399F)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
mark = section()

local r = build({ fd = fd, address = "0x40" })
check("build 默认参数 OK", r.result == "OK", tostring(r.message))
-- 事务序列：RST 写 → 配置读（ptr 写 + r2）→ 工作配置写
local ww = write_words(mark)
check("build 两笔字写：0x8000/0x3E67", ww[1] == 0x008000 and ww[2] == 0x003E67 and #ww == 2,
	table.concat(ww, ","))
local cfg_read = 0
for _, e in ipairs(reads(mark)) do
	if e.bytes.n == 2 then cfg_read = cfg_read + 1 end
end
check("build 恰一次 2B 配置读", cfg_read == 1, tostring(cfg_read))
check("build 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
check("set_addr 0x40", set_addrs(mark)[1] == ADDR, string.format("0x%X", set_addrs(mark)[1] or 0))
check("build 睡眠 10+20=30ms", sleep_total == 30, tostring(sleep_total))
check("build 触发一次软复位", dev:reset_count() == 1, tostring(dev:reset_count()))

-- 字符串 fd
section()
expect_ok("build 字符串 fd='3'", function() return build({ fd = "3", address = "0x40" }) end)

-- avg 八档：配置字 0x3800|code<<7|code<<3|7 + 睡眠 10+ceil(2*532*n/1000)+2
local avg_cases = {
	{ 1, 0x399F, 14 }, { 2, 0x3CCF, 15 }, { 4, 0x3D57, 17 }, { 8, 0x3DDF, 21 },
	{ 16, 0x3E67, 30 }, { 32, 0x3EEF, 47 }, { 64, 0x3F77, 81 }, { 128, 0x3FFF, 149 },
}
for _, c in ipairs(avg_cases) do
	section()
	local rr = build(p_arg(tostring(c[1])))
	check(string.format("avg=%d → 0x%04X", c[1], c[2]),
		rr.result == "OK" and dev:config() == c[2],
		rr.result .. " " .. string.format("0x%04X", dev:config()))
	check(string.format("avg=%d 睡眠 %dms", c[1], c[3]), sleep_total == c[3], tostring(sleep_total))
end

-- avg 归一：非 2 幂/'-'/非法/0/超大 → 最近合法档（avg_code_of 取 floor 到表）
local norm_cases = {
	{ "3", 0x3CCF }, { "-", 0x3E67 }, { "abc", 0x3E67 }, { "0", 0x3E67 },
	{ "-5", 0x3E67 }, { "2000", 0x3FFF }, { "17", 0x3E67 }, { "15", 0x3DDF },
}
for _, c in ipairs(norm_cases) do
	section()
	local rr = build(p_arg(c[1]))
	check(string.format("avg='%s' 归一 → 0x%04X", c[1], c[2]),
		rr.result == "OK" and dev:config() == c[2], string.format("0x%04X", dev:config()))
end

-- rshunt 归一（'-'/非法/负数 → 缺省 0.1Ω）——call 电流换算验证
for _, rv in ipairs({ "-", "abc", "-1", "0" }) do
	section()
	expect_ok("build rshunt='" .. rv .. "'", function()
		return build({ fd = fd, address = "0x40", rshunt = rv })
	end)
	dev:set_shunt_raw(4000)	-- 40mV
	local crx = call({ fd = fd, address = "0x40" })
	check("rshunt='" .. rv .. "' 归缺省 → I=0.4A",
		crx.result == "OK" and near(crx.I, 0.4), tostring(crx.I))
end

-- 错挂 INA226（复位默认 0x4127）
section()
dev:set_reset_id(0x4127)
expect_err("build 复位配置不符（INA226 误挂）", function()
	return build({ fd = fd, address = "0x40" })
end, "Config after reset")
dev:set_reset_id(0x399F)

-- build 负路径
section()
expect_err("build 非 table", function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x40" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x40" })
end, "set_addr failed")

section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x00 and b[2] == 0x80 end)
expect_err("build RST 写失败", function() return build({ fd = fd, address = "0x40" }) end,
	"Failed to write INA219 reset")
dev:clear_faults()

section()
dev:fail_read(function(p) return p == 0x00 end)
expect_err("build 配置读失败", function() return build({ fd = fd, address = "0x40" }) end,
	"Failed to read INA219 config")
dev:clear_faults()

section()
dev:set_reset_id(0x0000)
expect_err("build 配置读回 0x0000 甄别失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Config after reset")
dev:set_reset_id(0x399F)

section()
-- RST/甄别通过后，工作配置写（第二笔 3 字节字写）失败
local seen_rst = false
dev:fail_write(function(b)
	if #b == 3 and b[1] == 0x00 then
		if b[2] == 0x80 then seen_rst = true; return false end -- RST 放行
		return seen_rst -- 之后的 CONFIG 写失败
	end
	return false
end)
expect_err("build 工作配置写失败", function() return build({ fd = fd, address = "0x40" }) end,
	"Failed to write INA219 config")
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
mark = section()
expect_ok("call 组前置 build（rshunt=0.05）", function()
	return build({ fd = fd, address = "0x40", rshunt = "0.05" })
end)
-- 窗口移到 build 末尾：下面的 call 事务断言不含 build 序列（sleep_total 保留 build 30ms）
mark = #vbus.txlog

-- 旧桩三点：40mV 分流 + 总线 raw 16384（码 2048 → 8.192V）
dev:set_shunt_raw(4000)
dev:set_bus_raw(16384)
local cr = expect_ok("call 正常读值", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("V = 8.192V", near(cr.V, 8.192), tostring(cr.V))
	check("I = 40mV/0.05Ω = 0.8A", near(cr.I, 0.8), tostring(cr.I))
	check("P = 6.5536W", near(cr.P, 6.5536), tostring(cr.P))
end

-- 事务序列：set_addr + 两次「ptr 写 + 2B 读」（0x01 分流、0x02 总线）
local ws = writes(mark)
local rs = reads(mark)
check("call 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
check("call 两笔纯指针写 0x01/0x02",
	#ws == 2 and ws[1][1] == 0x01 and ws[2][1] == 0x02 and #ws[1] == 1 and #ws[2] == 1,
	#ws .. ":" .. (ws[1] and ws[1][1]) .. "/" .. (ws[2] and ws[2][1]))
check("call 两次 2B 读", #rs == 2 and rs[1].bytes.n == 2 and rs[2].bytes.n == 2, tostring(#rs))
check("call 自身零睡眠（仅 build 30ms）", sleep_total == 30, tostring(sleep_total))

-- 反流/负功率：-1024 LSB = -10.24mV（码 0xFC00）
dev:set_shunt_raw(-1024)
cr = expect_ok("call 反流为负", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("I = -0.2048A", near(cr.I, -0.2048), tostring(cr.I))
	check("P = -1.6777216W", near(cr.P, -1.6777216), tostring(cr.P))
end

-- -1 LSB（0xFFFF）= -10µV → -0.0002A @0.05
dev:set_shunt_raw(-1)
cr = call({ fd = fd, address = "0x40" })
check("-1 LSB → -0.0002A", cr.result == "OK" and near(cr.I, -0.0002), tostring(cr.I))

-- 满量程 ±32000 LSB = ±0.32V → ±6.4A @0.05
dev:set_shunt_raw(32000)
cr = call({ fd = fd, address = "0x40" })
check("正满程 6.4A", near(cr.I, 6.4), tostring(cr.I))
dev:set_shunt_raw(-32000)
cr = call({ fd = fd, address = "0x40" })
check("负满程 -6.4A", near(cr.I, -6.4), tostring(cr.I))

-- 低 3 位标志不影响驱动换算（驱动 >>3）
dev:set_shunt_raw(4000)
dev:set_bus_raw(16384 + 3)
cr = call({ fd = fd, address = "0x40" })
check("CNVR|OVF 标志不影响 V", near(cr.V, 8.192), tostring(cr.V))

-- 连续三拍读不串字（值逐拍更新且两寄存器互不串扰）
local seq = { { 0x1000, 2400 * 8 }, { 0x2000, 2500 * 8 }, { 0x0800, 2600 * 8 } }
for i, s in ipairs(seq) do
	dev:set_shunt_raw(s[1])
	dev:set_bus_raw(s[2])
	local x = call({ fd = fd, address = "0x40" })
	local exp_i = (s[1] >= 0x8000 and s[1] - 0x10000 or s[1]) * 10e-6 / 0.05
	check("连续读第 " .. i .. " 拍不串字",
		x.result == "OK" and near(x.V, math.floor(s[2] / 8) * 0.004) and near(x.I, exp_i),
		tostring(x and x.V) .. "/" .. tostring(x and x.I))
end

-- rshunt 缺省 0.1Ω 路径
section()
expect_ok("call 组前置 build（缺省 rshunt）", function()
	return build({ fd = fd, address = "0x40" })
end)
dev:set_shunt_raw(4000)
cr = call({ fd = fd, address = "0x40" })
check("缺省 R100：40mV/0.1Ω = 0.4A", near(cr.I, 0.4), tostring(cr.I))

-- virt_tick 造数 → 驱动正算闭环（独立公式：V=码*0.004，I=raw*10µV/0.1）
local vexp = { [0] = { 12.0, 1.0 }, [8] = { 12.4, 1.6 }, [24] = { 11.6, 0.4 } }
for n, e in pairs(vexp) do
	dev:virt_tick(n)
	local x = call({ fd = fd, address = "0x40" })
	check(string.format("virt_tick(%d) 闭环 V=%.1f I=%.1f", n, e[1], e[2]),
		near(x.V, e[1], 1e-6) and near(x.I, e[2], 1e-6),
		string.format("%s/%s", tostring(x.V), tostring(x.I)))
end

-- call 负路径
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x40" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
expect_err("call fd=99 set_addr", function() return call({ fd = 99, address = "0x40" }) end,
	"set_addr failed")

section()
build({ fd = fd, address = "0x40" })
dev.nack_read = true
expect_err("call 全读失败（分流）", function() return call({ fd = fd, address = "0x40" }) end,
	"shunt voltage")
dev.nack_read = false
dev:fail_read(function(p) return p == 0x01 end)
expect_err("call 分流定向读失败", function() return call({ fd = fd, address = "0x40" }) end,
	"shunt voltage")
dev:clear_faults()
dev:fail_read(function(p) return p == 0x02 end)
expect_err("call 总线定向读失败", function() return call({ fd = fd, address = "0x40" }) end,
	"bus voltage")
dev:clear_faults()

-- 未 build 守卫：重新加载驱动（模块级 rshunt upvalue 回到 nil）+ 新挂载
vbus.attach("INA219@0x41", 0x41, smod.new())
vbus.load_driver("modules/INA219.lua")
expect_err("未 build 直接 call", function() return call({ fd = fd, address = "0x41" }) end,
	"build first")

-- =====================================================================
-- 组 4：destroy
-- =====================================================================
mark = section()
expect_ok("destroy 无资源释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非 table", function() return destroy("x") end, "Invalid Arguments Type")

tester.summary("test_ina219")

-- test_ina3221.lua —— INA3221 真实驱动 + 虚拟 I2C 总线 + 三通道字寻址模型
-- 用法（项目根目录）: luajit test/test_ina3221.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：INA3221_GC=1 luajit test/test_ina3221.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 210 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/INA3221.lua 尾部 INA3221_VIRT，
-- 2026-09-15 自 virtbus/ina3221.lua 迁入）」。INA3221 与 INA219/INA226
-- 同为【字寻址 16 位寄存器 I2C 器件】（寄存器号各代表一个 16 位字，写恒
-- {ptr,hi,lo}、读恒「写 ptr + 读 2 字节」，绝不能套字节地址 regmap），
-- 但它是【三通道】且协议事实逐条不同（勿照搬任何常数）：
--   CONFIG 0x00 复位默认 0x7127（3 通道全使能、AVG=1、双 1.1ms、连续），
--   全 16 位有定义【无保留位】（INA226 bit14 恒 1 读出要合成）；RST bit15
--   自清不落盘、原地全文件复位；驱动 CT 写死 1.1ms（无 ct 参），只有 avg 可调；
--   三通道各一对结果寄存器（SHUNT1/BUS1=0x01/02、CH2=0x03/04、CH3=0x05/06），
--   分流/总线【同为 13 位有效、左移 3 存放、低 3 位恒 0】，驱动读后 >>3：
--   分流 s13 有符号 LSB 40µV（±163.84mV），总线 u13 无符号 LSB 8mV
--   （满码 65.528V）——INA226 是 16 位不挪位的 2.5µV/1.25mV；
--   真 ROM ID：0xFE=0x5449（'TI'）/0xFF=0x3220（不是 INA226 的 0x2260），
--   build【先双 ID 甄别、后软复位】（INA226 是先复位后甄别还读回 CONFIG）；
--   芯片内无电流/功率/校准寄存器，I=Vshunt/RshuntN 全软件换算，三电阻独立。
-- 连续模式（MODE=111 build 固定）六结果寄存器恒有值，无转换门/无 pending；
-- build 的 10ms 复位等待 + ceil(3·2.2·avg)+2 首循环等待只是 sleep，模型不计时。
--
-- 覆盖：模型侧 POR 与 ROM ID/六数据寄存器上电零/字寻址不串读/坏帧 NACK
-- 不动指针/CONFIG 无保留位照存/ROM 写 ACK 丢弃/RST 自清全复位且不清 who
-- 身份/s13 三通道左移 3 存放与满码钳制/u13 总线/跨字 burst 奇尾补 0/
-- 物理量独立量化交叉/virt_tick 三通道峰谷周期/六类钩子与 reset 保留钩子/
-- who 覆写与显式恢复；真实 build 7 事务序列（先验 ID 后复位、无配置读回）/
-- avg 八档配置字与睡眠表/向下降档与非法归一/三 rshunt 归一/双 ID 误挂/
-- 十路负路径；真实 call 13 事务（set+六指针写+六读）/三通道正负电流/
-- ±满程/virt_tick 闭环/六路逐寄存器失败短路/错地址（未 build 守卫 1 条
-- set）；destroy 零事务。

if os.getenv("INA3221_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x40

-- 模型内嵌于驱动文件（INA3221_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/INA3221.lua")
local smod = INA3221_VIRT

local dev = smod.new()
vbus.attach("INA3221@0x40", ADDR, dev)

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
	dev:who(0x5449, 0x3220)
	dev:set_reset_cfg(0x7127)
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
-- 窗口内纯指针写（1 字节）的寄存器号序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
local function b_arg(t) return { fd = fd, address = "0x40", avg = t } end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("上电 CONFIG 默认 0x7127", dev:config() == 0x7127, string.format("0x%04X", dev:config()))
check("上电 MFG 0x5449", dev:mfg() == 0x5449, string.format("0x%04X", dev:mfg()))
check("上电 DIE 0x3220", dev:die() == 0x3220, string.format("0x%04X", dev:die()))
for ch = 1, 3 do
	check(string.format("上电 ch%d SHUNT 为 0", ch), dev:shunt_raw(ch) == 0, tostring(dev:shunt_raw(ch)))
	check(string.format("上电 ch%d BUS 为 0", ch), dev:bus_raw(ch) == 0, tostring(dev:bus_raw(ch)))
end
check("上电 ptr=0", dev:pointer() == 0, tostring(dev:pointer()))

-- 未预置字读作 0（0x0F MASK / 0x07 告警限）
check("指针写 0x0F", dev.write({ 0x0F }) == true)
local rF = dev.read(2)
check("未预置 MASK 读 0x0000", rF ~= nil and rF[1] == 0 and rF[2] == 0,
      rF and table.concat(rF, ","))

-- 字寻址不串读：相邻字各自独立（0x01 SHUNT1 / 0x02 BUS1）
dev.write({ 0x01, 0x12, 0x34 })
dev.write({ 0x02, 0xBE, 0xEF })
dev.write({ 0x01 })
local w1 = dev.read(2)
check("字 0x01 读回 0x1234", w1[1] == 0x12 and w1[2] == 0x34, table.concat(w1, ","))
dev.write({ 0x02 })
local w2 = dev.read(2)
check("字 0x02 读回 0xBEEF（不串字）", w2[1] == 0xBE and w2[2] == 0xEF, table.concat(w2, ","))

-- 跨字 burst：n>2 按字自增续读、奇数尾补 0（0x07/0x08 告警限寄存器）
dev:set_word(0x07, 0xAAAA)
dev:set_word(0x08, 0xBBBB)
dev.write({ 0x07 })
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
check("坏帧不动指针（仍 0x07）", dev:pointer() == 0x07, string.format("0x%02X", dev:pointer()))

-- CONFIG 全 16 位有定义【无保留位】：写啥读啥（对照 INA226 的 bit14 合成）
dev.write({ 0x00, 0x00, 0x00 })
check("写 0x0000 读回 0x0000（无保留位合成）", dev:config() == 0x0000,
      string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x0F, 0xFF })
check("写 0x0FFF 读回 0x0FFF", dev:config() == 0x0FFF,
      string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x7F, 0xFF })
check("写 0x7FFF 读回 0x7FFF（无 RST 不复位）", dev:config() == 0x7FFF,
      string.format("0x%04X", dev:config()))

-- ROM ID 只读：写 ACK 但丢弃
check("写 MFG ACK", dev.write({ 0xFE, 0x12, 0x34 }) == true)
check("MFG 不被改写", dev:mfg() == 0x5449, string.format("0x%04X", dev:mfg()))
check("写 DIE ACK", dev.write({ 0xFF, 0xAA, 0xBB }) == true)
check("DIE 不被改写", dev:die() == 0x3220, string.format("0x%04X", dev:die()))

-- RST：0x8000 不落盘、CONFIG 回默认、六数据寄存器全清零、计数 +1
check("section 后复位计数 0", dev:reset_count() == 0)
dev.write({ 0x00, 0x12, 0x34 })
dev:set_shunt_raw(1, 1250)
dev:set_shunt_raw(2, 625)
dev:set_shunt_raw(3, 312)
dev:set_bus_raw(1, 1250)
dev:set_word(0x0F, 0x0001)
check("RST 写 ACK", dev.write({ 0x00, 0x80, 0x00 }))
check("RST 后 CONFIG 回 0x7127", dev:config() == 0x7127, string.format("0x%04X", dev:config()))
check("RST 后 ch1 SHUNT 清空", dev:shunt_raw(1) == 0)
check("RST 后 ch2 BUS 清空", dev:bus_raw(2) == 0)
check("RST 后 ch3 SHUNT 清空", dev:shunt_raw(3) == 0)
check("RST 后 MASK 清空", dev:word(0x0F) == 0, string.format("0x%04X", dev:word(0x0F)))
check("RST 位不落盘（读回非 0x8000）", dev:config() == 0x7127)
check("复位计数 1", dev:reset_count() == 1, tostring(dev:reset_count()))
dev.write({ 0x00, 0x80, 0x01 })
check("0x8001 也复位且计数 2", dev:config() == 0x7127 and dev:reset_count() == 2,
      string.format("0x%04X cnt=%s", dev:config(), tostring(dev:reset_count())))

-- who 身份覆写：软复位不恢复（喂 build 误挂），section 显式恢复
dev:who(0x0000, 0x3220)
check("who 覆写 MFG=0", dev:mfg() == 0x0000)
dev.write({ 0x00, 0x80, 0x00 })
check("RST 不恢复出厂 MFG", dev:mfg() == 0x0000)
dev:who(0x5449, 0x0000)
check("who 覆写 DIE=0", dev:die() == 0x0000)
dev:who(nil, 0x3220)
check("who(nil,...) 只改 DIE", dev:mfg() == 0x5449 and dev:die() == 0x3220)

-- s13 SHUNT（40µV，码域 -4096~4095，寄存器字 = 码<<3，满量程 ±163.84mV）
dev:set_shunt_raw(1, 1250)
check("ch1 码 1250 → 字 0x2710（<<3）", dev:word(0x01) == 10000,
      string.format("0x%04X", dev:word(0x01)))
check("ch1 字读回 0x27,0x10", (function()
	dev.write({ 0x01 }); local r = dev.read(2)
	return r[1] == 0x27 and r[2] == 0x10 end)())
check("ch1 观察口码 1250", dev:shunt_raw(1) == 1250)
check("ch1 1250×40µV = 50mV", near(dev:shunt_v(1), 0.05), tostring(dev:shunt_v(1)))
dev:set_shunt_raw(1, -1)
check("-1 码 → 字 0xFFF8", dev:word(0x01) == 0xFFF8,
      string.format("0x%04X", dev:word(0x01)))
check("-1 观察口解码", dev:shunt_raw(1) == -1)
check("-1 LSB = -40µV", near(dev:shunt_v(1), -40e-6), tostring(dev:shunt_v(1)))
dev:set_shunt_raw(1, -4096)
check("负满码 -4096 → 字 0x8000", dev:word(0x01) == 0x8000,
      string.format("0x%04X", dev:word(0x01)))
check("负满码观察口 -4096", dev:shunt_raw(1) == -4096)
check("负满程 -163.84mV", near(dev:shunt_v(1), -0.16384), tostring(dev:shunt_v(1)))
dev:set_shunt_raw(1, 4095)
check("正满码 4095 → 字 0x7FF8", dev:word(0x01) == 0x7FF8,
      string.format("0x%04X", dev:word(0x01)))
check("正满程 163.80mV", near(dev:shunt_v(1), 0.16380), tostring(dev:shunt_v(1)))
dev:set_shunt_raw(1, 999999)
check("正超程钳 4095", dev:shunt_raw(1) == 4095)
dev:set_shunt_raw(1, -999999)
check("负超程钳 -4096", dev:shunt_raw(1) == -4096)

-- 三通道存储互相独立
dev:set_shunt_raw(1, 100)
dev:set_shunt_raw(2, -200)
dev:set_shunt_raw(3, 300)
check("三通道 SHUNT 独立 100/-200/300",
      dev:shunt_raw(1) == 100 and dev:shunt_raw(2) == -200 and dev:shunt_raw(3) == 300,
      string.format("%s/%s/%s", dev:shunt_raw(1), dev:shunt_raw(2), dev:shunt_raw(3)))
check("三通道 SHUNT 字独立 0x0320/0xF9C0/0x0960",
      dev:word(0x01) == 0x0320 and dev:word(0x03) == 0xF9C0 and dev:word(0x05) == 0x0960,
      string.format("%04X/%04X/%04X", dev:word(0x01), dev:word(0x03), dev:word(0x05)))
check("非法通道 9 返回 nil", dev:set_shunt_raw(9, 1):shunt_raw(9) == nil)

-- u13 BUS（8mV、码域 0~8191、字 = 码<<3，满码 65.528V）
dev:set_bus_raw(1, 8191)
check("BUS 满码字 0xFFF8（13 位全 1 左移 3，低 3 位恒 0）", dev:word(0x02) == 0xFFF8,
      string.format("0x%04X", dev:word(0x02)))
check("满码 65.528V", near(dev:bus_v(1), 65.528), tostring(dev:bus_v(1)))
dev:set_bus_v(1, 12)
check("12V → 码 1500、字 12000（0x2EE0）", dev:bus_raw(1) == 1500 and dev:word(0x02) == 12000,
      string.format("code=%s word=0x%04X", tostring(dev:bus_raw(1)), dev:word(0x02)))
check("观察口回读 12V", near(dev:bus_v(1), 12, 0.0041), tostring(dev:bus_v(1)))
dev:set_bus_v(1, 2.5)
check("2.5V → 码 313（312.5 四舍五入，回读 2.504V）", dev:bus_raw(1) == 313,
      tostring(dev:bus_raw(1)))
dev:set_bus_v(1, -5)
check("负压钳 0", dev:bus_raw(1) == 0)
dev:set_bus_raw(1, 99999)
check("正超程钳 8191", dev:bus_raw(1) == 8191)
dev:set_bus_raw(1, 100)
dev:set_bus_raw(2, 200)
dev:set_bus_raw(3, 300)
check("三通道 BUS 独立 100/200/300",
      dev:bus_raw(1) == 100 and dev:bus_raw(2) == 200 and dev:bus_raw(3) == 300)

-- 物理量独立交叉（40µV / 8mV 粒度，三通道不同 R）
dev:set_vi(1, 24, 0.04)
check("ch1 24V → 3000 码", dev:bus_raw(1) == 3000, tostring(dev:bus_raw(1)))
check("ch1 40mV → 1000 LSB", dev:shunt_raw(1) == 1000, tostring(dev:shunt_raw(1)))
check("ch1 40mV/0.1Ω = 0.4A", near(dev:current_a(1, 0.1), 0.4), tostring(dev:current_a(1, 0.1)))
check("ch1 40mV/0.01Ω = 4.0A", near(dev:current_a(1, 0.01), 4.0), tostring(dev:current_a(1, 0.01)))
dev:set_current_a(2, -0.3, 0.05)
check("ch2 set_current_a -0.3A@0.05 → -15mV 码 -375", dev:shunt_raw(2) == -375,
      tostring(dev:shunt_raw(2)))
check("ch2 反推 -0.3A", near(dev:current_a(2, 0.05), -0.3), tostring(dev:current_a(2, 0.05)))
dev:set_current_a(3, 1.248, 0.01)
check("ch3 1.248A@0.01 → 12.48mV 码 312", dev:shunt_raw(3) == 312, tostring(dev:shunt_raw(3)))

-- virt_tick：确定性 / 三通道峰谷 / 32 拍周期
local t1, t2 = smod.new(), smod.new()
t1:virt_tick(5); t2:virt_tick(5)
check("virt_tick 确定性（三通道全字段）",
      t1:bus_raw(1) == t2:bus_raw(1) and t1:shunt_raw(2) == t2:shunt_raw(2)
      and t1:bus_raw(3) == t2:bus_raw(3))
local tk = smod.new()
tk:virt_tick(0)
check("n0 ch1 12.0V/0.5A", near(tk:bus_v(1), 12, 0.0041) and near(tk:current_a(1, 0.01), 0.5, 2e-3),
      string.format("%sV %sA", tostring(tk:bus_v(1)), tostring(tk:current_a(1, 0.01))))
check("n0 ch1 shunt 码 125", tk:shunt_raw(1) == 125, tostring(tk:shunt_raw(1)))
check("n0 ch2 12.0V/1.0A、ch3 5.0V/0.3A",
      near(tk:bus_v(2), 12, 0.0041) and near(tk:current_a(2, 0.01), 1.0, 2e-3)
      and near(tk:bus_v(3), 5, 0.0041) and near(tk:current_a(3, 0.01), 0.3, 2e-3))
tk:virt_tick(8)
check("n8 峰 ch1 12.4V/0.8A", near(tk:bus_v(1), 12.4, 0.0041) and near(tk:current_a(1, 0.01), 0.8, 2e-3),
      string.format("%sV %sA", tostring(tk:bus_v(1)), tostring(tk:current_a(1, 0.01))))
check("n8 ch1 shunt 码 200", tk:shunt_raw(1) == 200, tostring(tk:shunt_raw(1)))
check("n8 峰 ch2 12.4V/1.4A、ch3 5.2V/0.448A",
      near(tk:bus_v(2), 12.4, 0.0041) and near(tk:current_a(2, 0.01), 1.4, 2e-3)
      and near(tk:bus_v(3), 5.2, 0.0041) and near(tk:current_a(3, 0.01), 0.448, 2e-3))
tk:virt_tick(24)
check("n24 谷 ch1 11.6V/0.2A", near(tk:bus_v(1), 11.6, 0.0041) and near(tk:current_a(1, 0.01), 0.2, 2e-3),
      string.format("%sV %sA", tostring(tk:bus_v(1)), tostring(tk:current_a(1, 0.01))))
check("n24 ch1 shunt 码 50", tk:shunt_raw(1) == 50, tostring(tk:shunt_raw(1)))
check("n24 谷 ch2 11.6V/0.6A、ch3 4.8V/0.152A",
      near(tk:bus_v(2), 11.6, 0.0041) and near(tk:current_a(2, 0.01), 0.6, 2e-3)
      and near(tk:bus_v(3), 4.8, 0.0041) and near(tk:current_a(3, 0.01), 0.152, 2e-3))
tk:virt_tick(32)
check("n32 = n0（32 拍周期）", near(tk:bus_v(1), 12, 0.0041) and near(tk:current_a(1, 0.01), 0.5, 2e-3)
      and near(tk:bus_v(3), 5, 0.0041))

-- 故障钩子
section()
check("挂 fail_write", dev:fail_write(function(b) return b[1] == 0x0F end) ~= nil)
check("定向写失败", dev.write({ 0x0F, 0x12, 0x34 }) == false)
check("他寄存器照常", dev.write({ 0x07, 0x12, 0x34 }))
dev:clear_faults()
check("挂 fail_read", dev:fail_read(function(p, n) return p == 0x05 and n == 2 end) ~= nil)
dev.write({ 0x05 })
check("0x05 定向读失败", dev.read(2) == nil)
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
dev:fail_write(function(b) return b[1] == 0x0F end)
dev:reset()
check("reset 后写钩子仍在", dev.write({ 0x0F, 0x00, 0x01 }) == false)
-- reset 保留 who 身份（须显式恢复）
dev:who(0x1111)
dev:reset()
check("reset 保留 who 身份", dev:mfg() == 0x1111)
dev:clear_faults()
-- set_reset_cfg：复位默认值（模型级事实；INA3221 驱动 build 不读回配置）
dev:set_reset_cfg(0x0000)
check("set_reset_cfg 立即置位", dev:config() == 0x0000, string.format("0x%04X", dev:config()))
dev.write({ 0x00, 0x80, 0x00 })
check("RST 后仍是覆写默认 0x0000", dev:config() == 0x0000,
      string.format("0x%04X", dev:config()))
dev:set_reset_cfg(0x7127)

-- 留痕：config_writes 只收 3 字节字写
section()
dev.write({ 0xFE })
dev.write({ 0x00, 0x80, 0x00 })
dev.write({ 0x00, 0x75, 0x27 })
local cw = dev:config_writes()
check("config_writes 两笔字写（指针写不计）", #cw == 2
      and cw[1].reg == 0 and cw[1].word == 0x8000
      and cw[2].reg == 0 and cw[2].word == 0x7527,
      tostring(#cw))
dev:reset_logs()
check("reset_logs 清空", #dev:config_writes() == 0)

-- =====================================================================
-- 组 2：真实 build（先双 ID 甄别 → 软复位 → 写工作配置，共 7 条 txlog）
-- =====================================================================
mark = section()

local r = build({ fd = fd, address = "0x40" })
check("build 默认参数 OK", r.result == "OK", tostring(r.message))
-- 事务序列：set → MFG(ptr+r) → DIE(ptr+r) → RST 字写 → 工作配置字写
local t = entries(mark)
check("build 7 txlog", #t == 7, tostring(#t))
check("build 序列 set→MFG→DIE→RST→工作字",
      t[1].dir == "set" and
      t[2].dir == "w" and t[2].bytes[1] == 0xFE and t[3].dir == "r" and t[3].bytes.n == 2 and
      t[4].dir == "w" and t[4].bytes[1] == 0xFF and t[5].dir == "r" and t[5].bytes.n == 2 and
      t[6].dir == "w" and t[6].bytes[1] == 0x00 and t[6].bytes[2] == 0x80 and t[6].bytes[3] == 0x00 and
      t[7].dir == "w" and t[7].bytes[1] == 0x00 and t[7].bytes[2] == 0x75 and t[7].bytes[3] == 0x27)
local ww = write_words(mark)
check("build 两笔字写 0x8000/0x7527", #ww == 2 and ww[1] == 0x008000 and ww[2] == 0x007527,
      table.concat(ww, ","))
check("build 两次 2B 读（MFG/DIE，无配置读回）", #reads(mark) == 2, tostring(#reads(mark)))
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR)
check("build 睡眠 10+108=118ms", sleep_total == 118, tostring(sleep_total))
check("build 触发一次软复位", dev:reset_count() == 1, tostring(dev:reset_count()))
check("build 后 CONFIG=0x7527", dev:config() == 0x7527, string.format("0x%04X", dev:config()))

-- 字符串 fd
section()
expect_ok("build 字符串 fd='3'", function() return build({ fd = "3", address = "0x40" }) end)

-- avg 八档（CT 写死 1.1ms 码4）：0x7127|code<<9，睡眠 10+ceil(6.6·n)+2
local avg_cases = {
	{    1, 0x7127,   19 }, {    4, 0x7327,   39 }, {   16, 0x7527,  118 },
	{   64, 0x7727,  435 }, {  128, 0x7927,  857 }, {  256, 0x7B27, 1702 },
	{  512, 0x7D27, 3392 }, { 1024, 0x7F27, 6771 },
}
for _, c in ipairs(avg_cases) do
	section()
	local rr = build(b_arg(tostring(c[1])))
	check(string.format("avg=%d → 0x%04X", c[1], c[2]),
		rr.result == "OK" and dev:config() == c[2],
		rr.result .. " " .. (rr.message or string.format("0x%04X", dev:config())))
	check(string.format("avg=%d 睡眠 %dms", c[1], c[3]), sleep_total == c[3], tostring(sleep_total))
end

-- 向下降档/非法归一
local norm_cases = {
	{ "3", 0x7127, 19 }, { "15", 0x7327, 39 }, { "2000", 0x7F27, 6771 },
	{ "-", 0x7527, 118 }, { "abc", 0x7527, 118 }, { "0", 0x7527, 118 },
	{ "-5", 0x7527, 118 },
}
for _, c in ipairs(norm_cases) do
	section()
	local rr = build(b_arg(c[1]))
	check(string.format("avg='%s' 归一 → 0x%04X/%dms", c[1], c[2], c[3]),
		rr.result == "OK" and dev:config() == c[2] and sleep_total == c[3],
		rr.message or string.format("0x%04X/%s", dev:config(), tostring(sleep_total)))
end

-- rshunt1/2/3 归一（'-'/非法/负数/0 → 0.01Ω），call 三通道电流验证
for _, rv in ipairs({ "-", "abc", "-1", "0" }) do
	section()
	expect_ok("build 三 rshunt='" .. rv .. "'", function()
		return build({ fd = fd, address = "0x40",
		               rshunt1 = rv, rshunt2 = rv, rshunt3 = rv })
	end)
	dev:set_shunt_raw(1, 1250)	-- 50mV
	dev:set_shunt_raw(2, 1250)
	dev:set_shunt_raw(3, 1250)
	local crx = call({ fd = fd, address = "0x40" })
	check("rshunt='" .. rv .. "' 归缺省 → 三通道 I=5.0A",
		crx.result == "OK" and near(crx.I1, 5.0, 1e-6) and near(crx.I2, 5.0, 1e-6)
		and near(crx.I3, 5.0, 1e-6),
		string.format("%s/%s/%s", tostring(crx.I1), tostring(crx.I2), tostring(crx.I3)))
end

-- ROM ID 误挂（驱动连读两个 ID 后统一判空/判值，故均在 5 条 txlog 处失败）
mark = section()
dev:who(0x1234)
expect_err("build MFG 不符", function()
	return build({ fd = fd, address = "0x40" })
end, "Unexpected IDs")
check("MFG 错 5 txlog（set+MFG 读写+DIE 读写）",
      #entries(mark) == 5, tostring(#entries(mark)))
dev:who(0x5449)

mark = section()
dev:who(nil, 0x3221)
expect_err("build DIE 不符", function()
	return build({ fd = fd, address = "0x40" })
end, "Unexpected IDs")
check("DIE 错 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
dev:who(nil, 0x3220)

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
end, "Failed to read INA3221 IDs")
check("错地址 set+wFE+wFF 三 txlog（无挂载两次指针写均 NACK、无 r）",
      #entries(mark) == 3 and set_addrs(mark)[1] == 0x60, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0xFE end)
expect_err("build MFG 读失败（DIE 仍连读）", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to read INA3221 IDs")
check("MFG 读失败 5 txlog（wFE+r 留痕后驱动仍发 wFF+r）",
      #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_read(function(p) return p == 0xFF end)
expect_err("build DIE 读失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to read INA3221 IDs")
check("DIE 读失败 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x00 and b[2] == 0x80 end)
expect_err("build RST 写失败", function()
	return build({ fd = fd, address = "0x40" })
end, "Failed to write INA3221 reset")
check("RST 写失败 6 txlog（set+4 读事务+失败 w）", #entries(mark) == 6, tostring(#entries(mark)))
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
end, "Failed to write INA3221 config")
check("工作配置写失败 7 txlog", #entries(mark) == 7, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call（一次读全三通道：set + 六指针写 + 六读 = 13 txlog）
-- =====================================================================
mark = section()
expect_ok("call 组前置 build（rshunt 0.1/0.05/0.01）", function()
	return build({ fd = fd, address = "0x40",
	               rshunt1 = "0.1", rshunt2 = "0.05", rshunt3 = "0.01" })
end)
mark = #vbus.txlog	-- 窗口移到 build 后（sleep_total 保留 build 118ms）

dev:set_shunt_raw(1, 1250); dev:set_bus_raw(1, 1250)	-- 50mV / 10V
dev:set_shunt_raw(2, 625);  dev:set_bus_raw(2, 625)	-- 25mV / 5V
dev:set_shunt_raw(3, 312);  dev:set_bus_raw(3, 312)	-- 12.48mV / 2.496V
local cr = expect_ok("call 三通道读值", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("V1 = 10.0V", near(cr.V1, 10, 1e-6), tostring(cr.V1))
	check("I1 = 50mV/0.1Ω = 0.5A", near(cr.I1, 0.5, 1e-6), tostring(cr.I1))
	check("V2 = 5.0V", near(cr.V2, 5, 1e-6), tostring(cr.V2))
	check("I2 = 25mV/0.05Ω = 0.5A", near(cr.I2, 0.5, 1e-6), tostring(cr.I2))
	check("V3 = 2.496V", near(cr.V3, 2.496, 1e-6), tostring(cr.V3))
	check("I3 = 12.48mV/0.01Ω = 1.248A", near(cr.I3, 1.248, 1e-6), tostring(cr.I3))
end

-- 事务序列：set + 六次「ptr 写 + 2B 读」，指针 0x01~0x06 严格升序
check("call 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
local pw = ptr_writes(mark)
check("call 六笔纯指针写 0x01~0x06",
	#pw == 6 and pw[1] == 0x01 and pw[2] == 0x02 and pw[3] == 0x03
	and pw[4] == 0x04 and pw[5] == 0x05 and pw[6] == 0x06,
	table.concat(pw, ","))
check("call 六次 2B 读", #reads(mark) == 6, tostring(#reads(mark)))
check("call 共 13 txlog", #entries(mark) == 13, tostring(#entries(mark)))
check("call 自身零睡眠（仍 build 的 118ms）", sleep_total == 118, tostring(sleep_total))

-- 反流（驱动 s13：0xFC00>>3=8064 → 8064-8192=-128，-128×40µV=-5.12mV）
dev:set_shunt_raw(1, -128)
cr = expect_ok("call ch1 反流为负", function() return call({ fd = fd, address = "0x40" }) end)
if cr then
	check("I1 = -0.0512A", near(cr.I1, -0.0512, 1e-9), tostring(cr.I1))
end

-- -1 LSB = -40µV → -0.0004A @0.1
dev:set_shunt_raw(1, -1)
cr = call({ fd = fd, address = "0x40" })
check("-1 LSB → -0.4mA", cr.result == "OK" and near(cr.I1, -0.0004, 1e-9), tostring(cr.I1))

-- 满量程 s13 ±4096 LSB = ±163.84mV → ch1 ±1.6384/1.638A @0.1
dev:set_shunt_raw(1, -4096)
cr = call({ fd = fd, address = "0x40" })
check("负满程 -1.6384A", near(cr.I1, -1.6384, 1e-9), tostring(cr.I1))
dev:set_shunt_raw(1, 4095)
cr = call({ fd = fd, address = "0x40" })
check("正满程 1.638A", near(cr.I1, 1.638, 1e-9), tostring(cr.I1))

-- BUS 满码 u13 8191（<<3 存放）= 65.528V
dev:set_shunt_raw(1, 0)
dev:set_bus_raw(2, 8191)
cr = call({ fd = fd, address = "0x40" })
check("ch2 BUS 满码 65.528V（>>3 后 8191×8mV）", near(cr.V2, 65.528, 1e-9), tostring(cr.V2))

-- 连续三拍三通道不串字（shunt 造数用有符号码，模型内部左移 3/补码）
local rsh = { 0.1, 0.05, 0.01 }
local beats = {
	{ {  1250, 1250 }, {  625,  625 }, {  312, 312 } },
	{ { -1000, 1000 }, { -500,  500 }, { -250, 250 } },
	{ {   250, 1500 }, {  700,  300 }, {  100, 800 } },
}
for i, beat in ipairs(beats) do
	for ch = 1, 3 do
		dev:set_shunt_raw(ch, beat[ch][1])
		dev:set_bus_raw(ch, beat[ch][2])
	end
	local x = call({ fd = fd, address = "0x40" })
	local ok = x.result == "OK"
	local detail = {}
	for ch = 1, 3 do
		local exp_i = beat[ch][1] * 40e-6 / rsh[ch]
		local exp_v = beat[ch][2] * 0.008
		ok = ok and near(x["V" .. ch], exp_v, 1e-9) and near(x["I" .. ch], exp_i, 1e-9)
		detail[ch] = string.format("ch%d %sV/%sA", ch, tostring(x["V" .. ch]), tostring(x["I" .. ch]))
	end
	check("连续读第 " .. i .. " 拍三通道不串字", ok, table.concat(detail, " "))
end

-- virt_tick 造数 → 驱动正算闭环（build 重建为缺省 10mΩ；独立公式 V=码·8mV）
section()
expect_ok("virt_tick 闭环前置 build（缺省 10mΩ）", function()
	return build({ fd = fd, address = "0x40" })
end)
local vexp = {
	[0]  = { 12.0, 0.5, 12.0, 1.0, 5.0, 0.3 },
	[8]  = { 12.4, 0.8, 12.4, 1.4, 5.2, 0.448 },
	[24] = { 11.6, 0.2, 11.6, 0.6, 4.8, 0.152 },
}
for n, e in pairs(vexp) do
	dev:virt_tick(n)
	local x = call({ fd = fd, address = "0x40" })
	check(string.format("virt_tick(%d) 闭环 V1/I1/V2/I2/V3/I3", n),
		near(x.V1, e[1], 0.0041) and near(x.I1, e[2], 2e-3)
		and near(x.V2, e[3], 0.0041) and near(x.I2, e[4], 2e-3)
		and near(x.V3, e[5], 0.0041) and near(x.I3, e[6], 2e-3),
		string.format("%s/%s %s/%s %s/%s",
			tostring(x.V1), tostring(x.I1), tostring(x.V2), tostring(x.I2),
			tostring(x.V3), tostring(x.I3)))
end

-- call 负路径
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x40" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
mark = #vbus.txlog
expect_err("call fd=99 set_addr", function() return call({ fd = 99, address = "0x40" }) end,
	"set_addr failed")
check("call fd=99 开窗零 txlog", #entries(mark) == 0, tostring(#entries(mark)))

-- 六个寄存器逐路失败：短路在第 k 个读，set + 2k-1 条（3/5/7/9/11/13）
section()
build({ fd = fd, address = "0x40" })
for idx, reg in ipairs({ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }) do
	dev:clear_faults()
	dev:fail_read(function(p) return p == reg end)
	mark = #vbus.txlog
	local crx = call({ fd = fd, address = "0x40" })
	local expect_tx = 1 + 2 * idx
	check(string.format("call 读 0x%02X 失败 → %d txlog", reg, expect_tx),
		crx.result == "ERR"
		and tostring(crx.message):find(string.format("register 0x%02X", reg), 1, true) ~= nil
		and #entries(mark) == expect_tx,
		string.format("%s tx=%s", tostring(crx.message), tostring(#entries(mark))))
end
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 错地址 0x60", function() return call({ fd = fd, address = "0x60" }) end,
	"register 0x01")
check("错地址 set+w01 两 txlog（无挂载指针写 NACK 无 r）", #entries(mark) == 2
      and set_addrs(mark)[1] == 0x60, tostring(#entries(mark)))

-- 未 build 守卫：重载驱动（模块级 rshunt1..3 回 nil）+ 新地址挂载
section()
vbus.attach("INA3221@0x41", 0x41, smod.new())
vbus.load_driver("modules/INA3221.lua")
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

tester.summary("test_ina3221")

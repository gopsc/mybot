-- test_max17043.lua —— MAX17043 真实驱动 + 虚拟 I2C 总线 + 偶地址字地图模型
-- 用法（项目根目录）: luajit test/test_max17043.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：MAX17043_GC=1 luajit test/test_max17043.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 150 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MAX17043.lua 尾部 MAX17043_VIRT，
-- 2026-09-15 自 virtbus/max17043.lua 迁入）」。MAX17043 是【偶地址稀疏
-- 字地图 I2C 器件】（寄存器指针是字节地址，全在偶地址且不连续：
-- 0x02/0x04/0x06/0x08/0x0C + 只写命令口 0xFE；写恒 {ptr,hi,lo}、读恒
-- 「写 ptr + 读 2 字节」，跨字 burst 按 +2 偶地址续读，不能套字节地址
-- regmap，也不能照抄 INA 族连续字索引）：
--   VCELL 0x02 12 位左移 4 存放（低 4 位恒 0），驱动读后 >>4，LSB 1.25mV
--   （满码字 0xFFF0=4095<<4，5.11875V——旧桩误把 0x7FF0 当满程超 12 位）；
--   SOC 0x04 u16 定点 1/256%（raw/256，芯片可报告 >100%，满码 255.996%）；
--   MODE 0x06 bit15 SLEEP 照存、bit14 QuickStart 自清不落盘；
--   VERSION 0x08 家族内不固定，build 只做存在性检查不判值；
--   CONFIG 0x0C POR 0x971C（bit15 是 RCOMP 的 MSB 不是复位位），全字照存；
--   CMD 0xFE 只写，恰写 0x0054 全片复位。
-- 驱动纯只读：build 不写任何寄存器（set+写 0x08 指针+读 2B 共 3 事务
-- 零睡眠），call 依次读 VCELL/SOC（set+两指针写+两读共 5 事务零睡眠），
-- 无 build 状态（裸 call 合法）、无 ID/POR/STATUS（那是 MAX17048 的 0x1A）。
--
-- 覆盖：模型侧 POR/偶地址不串读/坏帧 NACK 不动指针/未定义地址读写边界/
-- 只读区写 ACK 丢弃/QuickStart 自清/CONFIG 照存/CMD 0x0054 全片复位与错魔数
-- 忽略/who 覆写复位不恢复/set_reset_cfg/reset 清计数留钩子/VCELL 12 位
-- 左移 4 码域与钳制/SOC u16 1/256 定点/物理逆注入量化闭环/跨字 burst 与
-- 不可读边界/virt_tick 峰谷周期/六类钩子；真实 build 3 事务纯只读/字符串
-- fd/版本不判值/非表缺参/错地址/读失败短路；真实 call 5 事务换算/连续三拍
-- 不串字/virt_tick 闭环/无 build 守卫/两路读失败精确短路/错地址；
-- destroy 零事务。

if os.getenv("MAX17043_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（MAX17043_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MAX17043.lua")
local smod = MAX17043_VIRT

local ADDR = 0x36
local dev = smod.new()
vbus.attach("MAX17043@0x36", ADDR, dev)

-- milli_sleep：累计时长（本模型无虚拟时钟，只累计供零睡眠断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件回上电态 + 故障解除 + who 身份显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0x0100)
	dev:set_reset_cfg(0x971C)
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
-- 窗口内纯指针写（1 字节）的寄存器地址序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("上电 VERSION 默认 0x0100", dev:version() == 0x0100,
      string.format("0x%04X", dev:version()))
check("上电 CONFIG 默认 0x971C", dev:config() == 0x971C,
      string.format("0x%04X", dev:config()))
check("上电 MODE 为 0", dev:mode() == 0, string.format("0x%04X", dev:mode()))
check("上电 VCELL 为 0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))
check("上电 SOC 为 0", dev:soc_raw() == 0, tostring(dev:soc_raw()))
check("上电 ptr=0", dev:pointer() == 0, tostring(dev:pointer()))

-- 偶地址字地图：各寄存器不串读（对照旧 regmap 串字病）
dev:set_word(0x02, 0xABCD)
dev:set_word(0x04, 0x1234)
check("写指针 0x02 ACK", dev.write({ 0x02 }) == true)
local r2 = dev.read(2)
check("读 0x02 = AB CD（不串 0x04）",
      r2 ~= nil and r2[1] == 0xAB and r2[2] == 0xCD,
      r2 and table.concat(r2, ",") or "nil")
check("写指针 0x04 ACK", dev.write({ 0x04 }) == true)
local r4 = dev.read(2)
check("读 0x04 = 12 34（不串 0x02）",
      r4 ~= nil and r4[1] == 0x12 and r4[2] == 0x34,
      r4 and table.concat(r4, ",") or "nil")
check("读后指针不变（仍 0x04）", dev:pointer() == 0x04,
      string.format("0x%02X", dev:pointer()))

-- 坏帧：2/4/0 字节、非 table 全 NACK，且指针不动
check("2 字节帧 NACK", dev.write({ 0x02, 0x00 }) == false)
check("4 字节帧 NACK", dev.write({ 0x02, 0, 0, 0 }) == false)
check("空表 NACK", dev.write({}) == false)
check("非 table NACK", dev.write(0xFF) == false)
check("坏帧后指针仍 0x04（NACK 不动指针）", dev:pointer() == 0x04,
      string.format("0x%02X", dev:pointer()))
check("坏帧后寄存器未被踩（0x04 仍 0x1234）", dev:word(0x04) == 0x1234,
      string.format("0x%04X", dev:word(0x04)))

-- 未定义地址：指针写 ACK，但读 NACK；字写整笔 NACK
for _, p in ipairs({ 0x00, 0x0A, 0x10, 0x03 }) do
	check(string.format("指针写 0x%02X ACK", p), dev.write({ p }) == true)
	check(string.format("读未定义 0x%02X NACK", p), dev.read(2) == nil)
	check(string.format("字写未定义 0x%02X NACK", p),
	      dev.write({ p, 0x12, 0x34 }) == false)
end
-- 只写命令口 0xFE：指针写 ACK 但不可读
check("指针写 CMD 0xFE ACK", dev.write({ 0xFE }) == true)
check("读 CMD 0xFE NACK（只写口）", dev.read(2) == nil)

-- 只读区（VCELL/SOC 测量区、VERSION ROM）：字写 ACK 但丢弃
dev:set_word(0x02, 0x7654); dev:set_word(0x04, 0x7654)
check("写 VCELL ACK 丢弃", dev.write({ 0x02, 0xBE, 0xEF }) == true
      and dev:word(0x02) == 0x7654, string.format("0x%04X", dev:word(0x02)))
check("写 SOC ACK 丢弃", dev.write({ 0x04, 0xBE, 0xEF }) == true
      and dev:word(0x04) == 0x7654, string.format("0x%04X", dev:word(0x04)))
check("写 VERSION ACK 丢弃", dev.write({ 0x08, 0xBE, 0xEF }) == true
      and dev:version() == 0x0100, string.format("0x%04X", dev:version()))

-- MODE：QuickStart bit14 自清不落盘；SLEEP bit15 及其余位照存
check("写 MODE 0x4000（QS）读回 0x0000",
      dev.write({ 0x06, 0x40, 0x00 }) and dev:mode() == 0x0000,
      string.format("0x%04X", dev:mode()))
check("写 MODE 0xC000（SLEEP+QS）读回 0x8000",
      dev.write({ 0x06, 0xC0, 0x00 }) and dev:mode() == 0x8000,
      string.format("0x%04X", dev:mode()))
check("写 MODE 0x8000（仅 SLEEP）读回 0x8000",
      dev.write({ 0x06, 0x80, 0x00 }) and dev:mode() == 0x8000,
      string.format("0x%04X", dev:mode()))
check("写 MODE 0x5555 抹 bit14 存 0x1555",
      dev.write({ 0x06, 0x55, 0x55 }) and dev:mode() == 0x1555,
      string.format("0x%04X", dev:mode()))

-- CONFIG：全 16 位照存（bit15 是 RCOMP MSB，不是复位位，写 0xFFFF 不复位）
check("写 CONFIG 0x1234 照存",
      dev.write({ 0x0C, 0x12, 0x34 }) and dev:config() == 0x1234,
      string.format("0x%04X", dev:config()))
check("写 CONFIG 0xFFFF 照存（bit15 非复位位）",
      dev.write({ 0x0C, 0xFF, 0xFF }) and dev:config() == 0xFFFF
      and dev:reset_count() == 0, string.format("0x%04X rc=%s",
      dev:config(), tostring(dev:reset_count())))

-- CMD 0xFE 全片复位：恰 0x0054 触发，测量区/模式/配置回 POR，VERSION 保留
dev:set_vcell_raw(3000):set_soc_raw(20000)
dev.write({ 0x06, 0x80, 0x00 })
dev:set_reset_cfg(0x971C)
dev.write({ 0x0C, 0x80, 0x00 })
check("CMD 写 0x0054 ACK 且复位计数 +1",
      dev.write({ 0xFE, 0x00, 0x54 }) and dev:reset_count() == 1,
      tostring(dev:reset_count()))
check("CMD 复位后 VCELL=0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))
check("CMD 复位后 SOC=0", dev:soc_raw() == 0, tostring(dev:soc_raw()))
check("CMD 复位后 MODE=0", dev:mode() == 0, string.format("0x%04X", dev:mode()))
check("CMD 复位后 CONFIG=0x971C", dev:config() == 0x971C,
      string.format("0x%04X", dev:config()))
check("CMD 复位后 VERSION 保留 0x0100", dev:version() == 0x0100,
      string.format("0x%04X", dev:version()))
check("CMD 写错误魔数 0x1234 ACK 但不复位",
      dev.write({ 0xFE, 0x12, 0x34 }) and dev:reset_count() == 1,
      tostring(dev:reset_count()))

-- who 覆写 VERSION：立即生效，CMD 全片复位不恢复出厂
mark = section()
dev:who(0xDEAD)
check("who 覆写 VERSION=0xDEAD", dev:version() == 0xDEAD,
      string.format("0x%04X", dev:version()))
dev.write({ 0xFE, 0x00, 0x54 })
check("CMD 复位后 who 覆写不恢复（仍 0xDEAD）", dev:version() == 0xDEAD,
      string.format("0x%04X", dev:version()))
dev:who(0x0100)
check("显式 who 恢复 0x0100", dev:version() == 0x0100,
      string.format("0x%04X", dev:version()))
check("who(nil) 不改", dev:who(nil):version() == 0x0100)

-- set_reset_cfg：复位后的 CONFIG 默认值可覆写
dev:set_reset_cfg(0x5555)
check("set_reset_cfg 立即置 CONFIG", dev:config() == 0x5555,
      string.format("0x%04X", dev:config()))
dev.write({ 0xFE, 0x00, 0x54 })
check("CMD 复位后 CONFIG=自定义 0x5555", dev:config() == 0x5555,
      string.format("0x%04X", dev:config()))

-- reset()：回 POR、计数清零；故障钩子与身份保留策略同 INA 族
dev:set_vcell_raw(100)
dev.nack_read = true
dev:reset()
check("reset 后 VCELL 回 0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))
check("reset 后 reset_count 清零", dev:reset_count() == 0,
      tostring(dev:reset_count()))
check("reset 不清故障钩子（nack_read 仍在）", dev.nack_read == true)
dev:clear_faults()

-- VCELL 12 位左移 4 编码（低 4 位恒 0）
dev:set_vcell_raw(4095)
check("VCELL 码 4095 → 字 0xFFF0（满码）", dev:word(0x02) == 0xFFF0,
      string.format("0x%04X", dev:word(0x02)))
check("VCELL 满码 5.11875V", near(dev:vcell_v(), 5.11875), tostring(dev:vcell_v()))
check("VCELL 寄存器低 4 位恒 0", dev:word(0x02) % 16 == 0)
dev:set_vcell_raw(128)
check("VCELL 码 128 → 字 0x0800 → 0.16V",
      dev:word(0x02) == 0x0800 and near(dev:vcell_v(), 0.16),
      string.format("0x%04X %sV", dev:word(0x02), tostring(dev:vcell_v())))
dev:set_vcell_raw(0)
check("VCELL 码 0 → 0V", dev:word(0x02) == 0 and dev:vcell_v() == 0)
dev:set_vcell_raw(99999)
check("VCELL 超程钳 4095", dev:vcell_raw() == 4095, tostring(dev:vcell_raw()))
dev:set_vcell_raw(-5)
check("VCELL 负值钳 0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))
dev:set_word(0x02, 0x080F)
check("set_word 可造低 4 位非零字（>>4 仍 128）",
      dev:vcell_raw() == 128 and near(dev:vcell_v(), 0.16),
      string.format("0x%04X %s", dev:word(0x02), tostring(dev:vcell_raw())))

-- SOC u16 定点 1/256%（不钳到 100%）
dev:set_soc_raw(65535)
check("SOC 满码 65535 → 255.99609375%", near(dev:soc_pct(), 65535 / 256),
      tostring(dev:soc_pct()))
dev:set_soc_raw(32768)
check("SOC 32768 → 128%（芯片可 >100%）", near(dev:soc_pct(), 128),
      tostring(dev:soc_pct()))
dev:set_soc_raw(0)
check("SOC 0 → 0%", dev:soc_pct() == 0)
dev:set_soc_raw(70000)
check("SOC 超程钳 65535", dev:soc_raw() == 65535, tostring(dev:soc_raw()))
dev:set_soc_pct(85)
check("set_soc_pct(85) → 字 21760（0x5500）",
      dev:soc_raw() == 21760 and near(dev:soc_pct(), 85),
      string.format("%d %s%%", dev:soc_raw(), tostring(dev:soc_pct())))
dev:set_soc_pct(100)
check("set_soc_pct(100) → 字 25600", dev:soc_raw() == 25600,
      tostring(dev:soc_raw()))

-- 物理量逆注入独立量化闭环（常量与驱动同源，最近码）
dev:set_vcell_v(4.1)
check("set_vcell_v(4.1) → 码 3280 回读 4.1V",
      dev:vcell_raw() == 3280 and near(dev:vcell_v(), 4.1),
      string.format("%d %s", dev:vcell_raw(), tostring(dev:vcell_v())))
dev:set_vcell_v(3.333)
check("set_vcell_v(3.333) → 码 2666 回读 3.3325V（1.25mV 粒度）",
      dev:vcell_raw() == 2666 and near(dev:vcell_v(), 3.3325),
      string.format("%d %s", dev:vcell_raw(), tostring(dev:vcell_v())))
dev:set_soc_pct(33.5)
check("set_soc_pct(33.5) → 字 8576 回读精确",
      dev:soc_raw() == 8576 and near(dev:soc_pct(), 33.5),
      string.format("%d %s", dev:soc_raw(), tostring(dev:soc_pct())))

-- 跨字 burst：偶地址 +2 续读，奇尾补 0；途中遇不可读地址整笔 NACK
dev:set_word(0x02, 0x1122); dev:set_word(0x04, 0x3344); dev:set_word(0x06, 0x5566)
dev.write({ 0x02 })
local b6 = dev.read(6)
check("burst 6B 自 0x02 = 02,04,06 三对",
      b6 ~= nil and b6[1] == 0x11 and b6[2] == 0x22 and b6[3] == 0x33
      and b6[4] == 0x44 and b6[5] == 0x55 and b6[6] == 0x66,
      b6 and table.concat(b6, ",") or "nil")
local b3 = dev.read(3)
check("burst 3B = 当前字 hi/lo + 下一字 hi（11 22 33，字节流连续）",
      b3 ~= nil and b3[1] == 0x11 and b3[2] == 0x22 and b3[3] == 0x33,
      b3 and table.concat(b3, ",") or "nil")
dev.write({ 0x02 })
local b8 = dev.read(8)
check("burst 8B 自 0x02 跨四字 02/04/06/08 全可读（尾接 VERSION=01 00）",
      b8 ~= nil and #b8 == 8 and b8[7] == 0x01 and b8[8] == 0x00,
      b8 and table.concat(b8, ",") or "nil")
local b10 = dev.read(10)
check("burst 10B 越过 0x08 遇保留 0x0A 整笔 NACK", b10 == nil)
dev.write({ 0x08 })
check("自 0x08 读 2B 可读、读 4B 遇 0x0A NACK",
      dev.read(2) ~= nil and dev.read(4) == nil)
check("read(0)/read(-1) NACK", dev.read(0) == nil and dev.read(-1) == nil)

-- virt_tick：32 拍单节锂电正弦（n0=3.85V/80%，n8=4.1/88，n24=3.6/72）
local tick_exp = {
	[0]  = { 3.85, 80 },
	[8]  = { 4.10, 88 },
	[24] = { 3.60, 72 },
}
for n, e in pairs(tick_exp) do
	dev:virt_tick(n)
	check(string.format("virt_tick(%d) VCELL≈%.2fV", n, e[1]),
	      near(dev:vcell_v(), e[1], 0.00126), tostring(dev:vcell_v()))
	check(string.format("virt_tick(%d) SOC≈%d%%", n, e[2]),
	      near(dev:soc_pct(), e[2], 1 / 256), tostring(dev:soc_pct()))
end
dev:virt_tick(0)
local v0, s0 = dev:vcell_v(), dev:soc_pct()
dev:virt_tick(32)
check("virt_tick(32) 回周期 = tick(0)",
      near(dev:vcell_v(), v0, 1e-12) and near(dev:soc_pct(), s0, 1e-12),
      string.format("%s %s", tostring(dev:vcell_v()), tostring(dev:soc_pct())))

-- 六类故障钩子
mark = section()
dev.nack = true
check("nack=true 写读全拦", dev.write({ 0x02 }) == false and dev.read(2) == nil)
dev:clear_faults()
check("clear_faults 后恢复", dev.write({ 0x02 }) == true and dev.read(2) ~= nil)
dev.nack_write = true
check("nack_write 只拦写", dev.write({ 0x02 }) == false)
dev:clear_faults()
dev.nack_read = true
check("nack_read 只拦读（写仍 ACK）",
      dev.write({ 0x02 }) == true and dev.read(2) == nil)
dev:clear_faults()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x0C end)
check("fail_write 帧谓词拦 CONFIG 字写、不拦指针写",
      dev.write({ 0x0C }) == true and dev.write({ 0x0C, 0x12, 0x34 }) == false)
dev:clear_faults()
dev:fail_read(function(p, n) return p == 0x04 and n == 2 end)
check("fail_read 谓词按 (ptr,n) 拦 SOC、不拦 VCELL",
      (function() dev.write({ 0x02 }); return dev.read(2) end)() ~= nil
      and (function() dev.write({ 0x04 }); return dev.read(2) end)() == nil)
dev:clear_faults()

-- config_writes 只收 3B 字写；reset_logs 清空；指针随字写更新
section()
dev.write({ 0x02 })
dev.write({ 0x0C, 0x12, 0x34 })
dev.write({ 0xFE, 0x00, 0x54 })
local cw = dev:config_writes()
check("config_writes 收 2 笔字写（0x0C、0xFE），不含 1B 指针",
      #cw == 2 and cw[1].reg == 0x0C and cw[1].word == 0x1234
      and cw[2].reg == 0xFE and cw[2].word == 0x0054,
      tostring(#cw))
check("字写后指针停在 0xFE", dev:pointer() == 0xFE,
      string.format("0x%02X", dev:pointer()))
dev:reset_logs()
check("reset_logs 清空留痕（write_log 与 config_writes 均空）",
      #dev.write_log == 0 and #dev:config_writes() == 0)

-- =====================================================================
-- 组 2：真实 build（纯只读存在性检查：set + 写 0x08 指针 + 读 2B = 3 txlog）
-- =====================================================================
mark = section()
local br = expect_ok("build 正常（读 VERSION）", function()
	return build({ fd = fd, address = "0x36" })
end)
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x36,
      tostring(#set_addrs(mark)))
check("build 一笔 0x08 纯指针写",
      #ptr_writes(mark) == 1 and ptr_writes(mark)[1] == 0x08,
      table.concat(ptr_writes(mark), ","))
check("build 一次 2B 读", #reads(mark) == 1, tostring(#reads(mark)))
check("build 共 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
check("build 零写字（纯只读驱动）", #write_words(mark) == 0,
      tostring(#write_words(mark)))
check("build 零睡眠", sleep_total == 0, tostring(sleep_total))

mark = section()
expect_ok("build 字符串 fd='3'", function()
	return build({ fd = "3", address = "0x36" })
end)

-- VERSION 值不参与判定（存在性检查）：任意非失败值都 OK
mark = section()
dev:who(0xDEAD)
expect_ok("build VERSION=0xDEAD 仍通过（不判值）", function()
	return build({ fd = fd, address = "0x36" })
end)
dev:who(0x0100)

-- build 负路径
mark = section()
expect_err("build 非 table", function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x36" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("参数校验路径零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x36" })
end, "set_addr failed")
check("fd=99 开窗零 txlog（set 在留痕前失败）", #entries(mark) == 0,
      tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60", function()
	return build({ fd = fd, address = "0x60" })
end, "Failed to read MAX17043 version")
check("错地址 set+w08 两 txlog（无挂载指针写 NACK、无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x08 and #reads(mark) == 0,
      tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0x08 end)
expect_err("build VERSION 读失败", function()
	return build({ fd = fd, address = "0x36" })
end, "Failed to read MAX17043 version")
check("VERSION 读失败 3 txlog（set+w08+r，失败 r 也留痕）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x08 end)
expect_err("build VERSION 指针写失败", function()
	return build({ fd = fd, address = "0x36" })
end, "Failed to read MAX17043 version")
check("指针写失败 2 txlog（set+w08，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call（set + 0x02 写读 + 0x04 写读 = 5 txlog，零睡眠）
-- =====================================================================
mark = section()
dev:set_word(0x02, 0x0800)	-- >>4 = 128 → 0.16V
dev:set_soc_raw(32768)		-- 128%
local cr = expect_ok("call VCELL/SOC 换算", function()
	return call({ fd = fd, address = "0x36" })
end)
if cr then
	check("VCELL = 0x0800>>4 x 1.25mV = 0.16V", near(cr.VCELL, 0.16),
	      tostring(cr.VCELL))
	check("SOC = 32768/256 = 128%", near(cr.SOC, 128), tostring(cr.SOC))
end
check("call 一次 set_addr", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
local pw = ptr_writes(mark)
check("call 两笔纯指针写 0x02、0x04",
      #pw == 2 and pw[1] == 0x02 and pw[2] == 0x04, table.concat(pw, ","))
check("call 两次 2B 读", #reads(mark) == 2, tostring(#reads(mark)))
check("call 共 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
check("call 零睡眠", sleep_total == 0, tostring(sleep_total))

-- 满码 / 空电池 / 典型值
local cases = {
	{ 0xFFF0, 0xFFFF, 5.11875, 65535 / 256, "满码 5.11875V/255.996%" },
	{ 0x0000, 0x0000, 0,       0,           "空电池 0V/0%" },
	{ 0xCD00, 21760,  4.1,    85,          "典型 4.1V/85%" },
}
for _, c in ipairs(cases) do
	dev:set_word(0x02, c[1]); dev:set_soc_raw(c[2])
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("call %s：VCELL", c[5]),
	      x.result == "OK" and near(x.VCELL, c[3], 1e-9),
	      tostring(x and x.VCELL))
	check(string.format("call %s：SOC", c[5]),
	      x.result == "OK" and near(x.SOC, c[4], 1e-9),
	      tostring(x and x.SOC))
end

-- 连续三拍不串字
local beats = {
	{ 3.70, 80 }, { 4.05, 92 }, { 3.55, 15 },
}
for i, b in ipairs(beats) do
	dev:set_vcell_v(b[1]):set_soc_pct(b[2])
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("连续读第 %d 拍 %.2fV/%d%% 不串字", i, b[1], b[2]),
	      x.result == "OK" and near(x.VCELL, b[1], 0.00126)
	      and near(x.SOC, b[2], 1 / 256),
	      string.format("%sV %s%%", tostring(x and x.VCELL), tostring(x and x.SOC)))
end

-- virt_tick → 驱动正算闭环
for n, e in pairs({ [0] = { 3.85, 80 }, [8] = { 4.10, 88 }, [24] = { 3.60, 72 } }) do
	dev:virt_tick(n)
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("virt_tick(%d) 驱动闭环 %.2fV/%d%%", n, e[1], e[2]),
	      near(x.VCELL, e[1], 0.00126) and near(x.SOC, e[2], 1 / 256),
	      string.format("%sV %s%%", tostring(x.VCELL), tostring(x.SOC)))
end

-- 无 build 守卫：重载驱动 + 新地址挂载，裸 call 直接合法（驱动不存模块状态）
section()
vbus.attach("MAX17043@0x37", 0x37, smod.new())
vbus.load_driver("modules/MAX17043.lua")
i2c_set_addr(fd, 0x37)
mark = #vbus.txlog
local nc = expect_ok("未 build 裸 call 合法（无 build 状态）", function()
	return call({ fd = fd, address = "0x37" })
end)
check("裸 call 仍 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
vbus.attach("MAX17043@0x36", ADDR, dev)
vbus.load_driver("modules/MAX17043.lua")
local smod = MAX17043_VIRT
i2c_set_addr(fd, ADDR)

-- call 负路径
section()
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x36" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
mark = #vbus.txlog
expect_err("call fd=99 set_addr", function()
	return call({ fd = 99, address = "0x36" })
end, "set_addr failed")
check("call fd=99 开窗零 txlog", #entries(mark) == 0, tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call 错地址 0x60", function()
	return call({ fd = fd, address = "0x60" })
end, "Failed to read MAX17043 VCELL")
check("错地址 set+w02 两 txlog（无挂载无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x02, tostring(#entries(mark)))

section()
dev:fail_read(function(p) return p == 0x02 end)
mark = #vbus.txlog
expect_err("call VCELL 读失败", function()
	return call({ fd = fd, address = "0x36" })
end, "Failed to read MAX17043 VCELL")
check("VCELL 读失败 3 txlog（set+w02+r）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
dev:clear_faults()

section()
dev:fail_read(function(p) return p == 0x04 end)
mark = #vbus.txlog
expect_err("call SOC 读失败", function()
	return call({ fd = fd, address = "0x36" })
end, "Failed to read MAX17043 SOC")
check("SOC 读失败 5 txlog（set+w02+r+w04+r，VCELL 已成功）",
      #entries(mark) == 5 and #reads(mark) == 2, tostring(#entries(mark)))
dev:clear_faults()

section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x02 end)
mark = #vbus.txlog
expect_err("call VCELL 指针写失败", function()
	return call({ fd = fd, address = "0x36" })
end, "Failed to read MAX17043 VCELL")
check("VCELL 指针写失败 2 txlog（set+w02，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无资源释放，arg_table 校验，零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 无资源释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非 table", function() return destroy("x") end, "Invalid Arguments Type")

tester.summary("test_max17043")

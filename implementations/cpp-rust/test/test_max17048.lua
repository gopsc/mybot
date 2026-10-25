-- test_max17048.lua —— MAX17048 真实驱动 + 虚拟 I2C 总线 + 偶地址字地图模型
-- 用法（项目根目录）: luajit test/test_max17048.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：MAX17048_GC=1 luajit test/test_max17048.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 220 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MAX17048.lua 尾部 MAX17048_VIRT，
-- 2026-09-15 自 virtbus/max17048.lua 迁入）。MAX17048 是 MAX17043 的
-- 换代芯片（同固定地址 0x36、同偶地址稀疏字地图纯闭包骨架，但寄存器图
-- 扩展、常数逐条不同），datasheet MAX17048/17049 Rev.7 核对的差异：
--   VCELL 0x02 16 位直读（无 17043 的左移 4/>>4），LSB 78.125µV
--   （17049 双节 156.25µV，驱动按 VERSION 分支锁存）；
--   SOC 0x04 同为 u16 定点 1/256%；CRATE 0x16 s16 ×0.208%/hr（新增）；
--   MODE 0x06 bit14 QuickStart 自清、bit13 EnSleep 照存、bit12 HibStat
--     只读写忽略（17043 的 bit15 SLEEP 在本代移到 CONFIG）；
--   VERSION 0x08 build 精确甄别：0x0012/0x0013 放行、0x001E/0x001F 为
--   17043/44 拒收（17043 驱动只做存在性检查）；
--   VALRT 0x14 Figure 11：0x14=MIN（高字节）、0x15=MAX（低字节），
--   POR 0x00FF；**旧驱动 RMW 把 MAX/MIN 字节写反，本迁移已修复**
--   （valrt_max=4.2/valrt_min=3.3 正确落字 0xA5D2，旧桩锁的 0xD2A5 是错的）；
--   STATUS 0x1A 高字节六告警 RI/VH/VL/VR/HD/SC + bit6 EnVr，POR
--   0x0100（RI 上电置位），clear=1 回写清六标志保留 EnVr 与低字节；
--   CMD 0xFE 复位魔数 0x5400（17043 是 0x0054）；HIBRT 0x0A/VRESET
--   0x18/TABLE 0x40~0x7F 驱动不碰，模型不建模（读/字写 NACK）。
--
-- 真实 build：set + VERSION 指针读（3）+ 末尾 STATUS 横幅指针读（2）=
-- 5 txlog 零写字零睡眠；quickstart=1 加 1 笔 0x4000 字写 + 实睡 5ms；
-- valrt/athd 各为读改写 3 笔；STATUS 横幅读失败不致命。真实 call：
-- set + 四寄存器指针读 = 9 txlog 零睡眠，clear 且有标志加 1 笔字写。
--
-- 覆盖：模型侧 POR/偶地址不串读/坏帧 NACK/未建模地址边界/只读区写丢弃/
-- MODE 三位语义/CMD 0x5400 复位与旧魔数忽略/VALRT 字节序/STATUS
-- 标志注入/VCELL u16/SOC 定点/CRATE s16 编码与钳制/物理逆注入/跨字
-- burst 稀疏可读边界/virt_tick 三轴正弦/六类钩子；真实 build 版本甄别
-- 四分支/quickstart/VALRT RMW 字节序与越界/ATHD RMW/各读失败精确短路；
-- 真实 call 四通道换算/17049 刻度锁存/clear 三分支/逐路失败；destroy
-- 零事务。

if os.getenv("MAX17048_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（MAX17048_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MAX17048.lua")
local smod = MAX17048_VIRT

local ADDR = 0x36
local dev = smod.new()
vbus.attach("MAX17048@0x36", ADDR, dev)

-- milli_sleep：累计时长（本模型无虚拟时钟，只累计供睡眠断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件回上电态 + 故障解除 + who 显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0x0012)
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
-- 窗口内寄存器写 {ptr,hi,lo} 的字序列（编码成 ptr<<16|word）
local function write_words(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 3 then t[#t + 1] = b[1] * 65536 + b[2] * 256 + b[3] end
	end
	return t
end
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
-- 窗口内指定寄存器的最后一笔 3B 字写
local function write_of(mark, reg)
	for _, b in ipairs(writes(mark)) do
		if #b == 3 and b[1] == reg then return b end
	end
	return nil
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("上电 VERSION 默认 0x0012", dev:version() == 0x0012,
      string.format("0x%04X", dev:version()))
check("上电 CONFIG 默认 0x971C", dev:config() == 0x971C,
      string.format("0x%04X", dev:config()))
check("上电 VALRT 默认 0x00FF", dev:valrt() == 0x00FF,
      string.format("0x%04X", dev:valrt()))
check("POR VALRT MIN 码=0（0x14）", dev:valrt_min_code() == 0,
      tostring(dev:valrt_min_code()))
check("POR VALRT MAX 码=255（0x15）", dev:valrt_max_code() == 255,
      tostring(dev:valrt_max_code()))
check("上电 STATUS=0x0100（RI 置位）", dev:status() == 0x0100,
      string.format("0x%04X", dev:status()))
check("上电 flags=1（RI）", dev:flags() == 1, tostring(dev:flags()))
check("上电 EnVr=0", dev:envr() == 0, tostring(dev:envr()))
check("上电 MODE 为 0", dev:mode() == 0, string.format("0x%04X", dev:mode()))
check("上电 VCELL/SOC/CRATE 为 0",
      dev:vcell_raw() == 0 and dev:soc_raw() == 0 and dev:crate_raw() == 0)
check("上电 ptr=0", dev:pointer() == 0, tostring(dev:pointer()))

-- 偶地址字地图：各寄存器不串读
dev:set_word(0x02, 0xABCD); dev:set_word(0x04, 0x1234)
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

-- 未建模地址：指针写 ACK，但读 NACK；字写整笔 NACK
--（0x0A HIBRT、0x18 VRESET/ID 真实存在但驱动不碰，模型不建模）
for _, p in ipairs({ 0x00, 0x0A, 0x0E, 0x10, 0x12, 0x18, 0x1C, 0x03 }) do
	check(string.format("指针写 0x%02X ACK", p), dev.write({ p }) == true)
	check(string.format("读未建模 0x%02X NACK", p), dev.read(2) == nil)
	check(string.format("字写未建模 0x%02X NACK", p),
	      dev.write({ p, 0x12, 0x34 }) == false)
end
check("指针写 CMD 0xFE ACK", dev.write({ 0xFE }) == true)
check("读 CMD 0xFE NACK（只写口）", dev.read(2) == nil)

-- 只读区（VCELL/SOC/CRATE 测量区、VERSION ROM）：字写 ACK 但丢弃
dev:set_word(0x02, 0x7654); dev:set_word(0x04, 0x7654); dev:set_crate_raw(-1)
check("写 VCELL ACK 丢弃", dev.write({ 0x02, 0xBE, 0xEF }) == true
      and dev:word(0x02) == 0x7654, string.format("0x%04X", dev:word(0x02)))
check("写 SOC ACK 丢弃", dev.write({ 0x04, 0xBE, 0xEF }) == true
      and dev:word(0x04) == 0x7654, string.format("0x%04X", dev:word(0x04)))
check("写 CRATE ACK 丢弃", dev.write({ 0x16, 0x12, 0x34 }) == true
      and dev:crate_raw() == -1, tostring(dev:crate_raw()))
check("写 VERSION ACK 丢弃", dev.write({ 0x08, 0xBE, 0xEF }) == true
      and dev:version() == 0x0012, string.format("0x%04X", dev:version()))

-- MODE：QS bit14 自清+计数；EnSleep bit13 照存；HibStat bit12 只读写忽略；
-- bit15 保留抹掉
check("写 MODE 0x4000（QS）读回 0x0000 且计数",
      dev.write({ 0x06, 0x40, 0x00 }) and dev:mode() == 0x0000
      and dev:quickstart_count() == 1,
      string.format("0x%04X qs=%s", dev:mode(), tostring(dev:quickstart_count())))
check("写 MODE 0x6000（QS+EnSleep）读回 0x2000 且计数",
      dev.write({ 0x06, 0x60, 0x00 }) and dev:mode() == 0x2000
      and dev:quickstart_count() == 2,
      string.format("0x%04X qs=%s", dev:mode(), tostring(dev:quickstart_count())))
check("写 MODE 0x8000（保留位 bit15）读回 0x0000",
      dev.write({ 0x06, 0x80, 0x00 }) and dev:mode() == 0x0000,
      string.format("0x%04X", dev:mode()))
check("写 MODE 0x1000（HibStat 只读）读回 0x0000",
      dev.write({ 0x06, 0x10, 0x00 }) and dev:mode() == 0x0000,
      string.format("0x%04X", dev:mode()))
check("写 MODE 0x4555 抹 QS/HibStat 存 0x0555",
      dev.write({ 0x06, 0x45, 0x55 }) and dev:mode() == 0x0555,
      string.format("0x%04X", dev:mode()))

-- CONFIG：全 16 位照存（bit15 是 RCOMP MSB，不是复位位）
check("写 CONFIG 0x1234 照存",
      dev.write({ 0x0C, 0x12, 0x34 }) and dev:config() == 0x1234,
      string.format("0x%04X", dev:config()))
check("写 CONFIG 0xFFFF 照存（bit15 非复位位）",
      dev.write({ 0x0C, 0xFF, 0xFF }) and dev:config() == 0xFFFF
      and dev:reset_count() == 0, string.format("0x%04X rc=%s",
      dev:config(), tostring(dev:reset_count())))

-- VALRT：全字照存，字节序观察口（0x14=MIN 高字节、0x15=MAX 低字节）
check("写 VALRT 0xA5D2 照存（MIN=165/MAX=210）",
      dev.write({ 0x14, 0xA5, 0xD2 }) and dev:valrt() == 0xA5D2
      and dev:valrt_min_code() == 165 and dev:valrt_max_code() == 210,
      string.format("0x%04X", dev:valrt()))

-- STATUS：全字照存；set_flags 只动六标志保留 EnVr/低字节
dev:set_status(0x4040)
check("set_status 0x4040：flags=0、EnVr=1、低字节 0x40",
      dev:status() == 0x4040 and dev:flags() == 0 and dev:envr() == 1,
      string.format("0x%04X flags=%s envr=%s", dev:status(),
      tostring(dev:flags()), tostring(dev:envr())))
dev:set_flags(63)
check("set_flags(63) → 0x7F40（EnVr/低字节保留）",
      dev:status() == 0x7F40 and dev:flags() == 63 and dev:envr() == 1,
      string.format("0x%04X", dev:status()))
check("STATUS 字写 0x1234 照存",
      dev.write({ 0x1A, 0x12, 0x34 }) and dev:status() == 0x1234,
      string.format("0x%04X", dev:status()))

-- CMD 0xFE：17048 魔数 0x5400 全片复位；0x0054（17043 魔数）不复位
mark = section()
dev:set_vcell_raw(30000):set_soc_raw(20000):set_crate_raw(100)
dev.write({ 0x06, 0x20, 0x00 })		-- EnSleep
dev:set_flags(63)
check("CMD 写 0x5400 ACK 且复位计数 +1",
      dev.write({ 0xFE, 0x54, 0x00 }) and dev:reset_count() == 1,
      tostring(dev:reset_count()))
check("CMD 复位后 VCELL/SOC/CRATE=0",
      dev:vcell_raw() == 0 and dev:soc_raw() == 0 and dev:crate_raw() == 0)
check("CMD 复位后 MODE=0", dev:mode() == 0, string.format("0x%04X", dev:mode()))
check("CMD 复位后 CONFIG=0x971C", dev:config() == 0x971C,
      string.format("0x%04X", dev:config()))
check("CMD 复位后 VALRT=0x00FF（MIN=0/MAX=255）",
      dev:valrt() == 0x00FF and dev:valrt_min_code() == 0
      and dev:valrt_max_code() == 255, string.format("0x%04X", dev:valrt()))
check("CMD 复位后 STATUS=0x0100（RI 重新置位）", dev:status() == 0x0100,
      string.format("0x%04X", dev:status()))
check("CMD 复位后 VERSION 保留 0x0012", dev:version() == 0x0012,
      string.format("0x%04X", dev:version()))
check("CMD 写旧魔数 0x0054 ACK 但不复位",
      dev.write({ 0xFE, 0x00, 0x54 }) and dev:reset_count() == 1,
      tostring(dev:reset_count()))
check("CMD 写错误魔数 0x1234 ACK 但不复位",
      dev.write({ 0xFE, 0x12, 0x34 }) and dev:reset_count() == 1,
      tostring(dev:reset_count()))

-- who 覆写 VERSION：立即生效，CMD 复位不恢复出厂
mark = section()
dev:who(0x0013)
check("who 覆写 VERSION=0x0013（17049）", dev:version() == 0x0013,
      string.format("0x%04X", dev:version()))
dev.write({ 0xFE, 0x54, 0x00 })
check("CMD 复位后 who 覆写不恢复（仍 0x0013）", dev:version() == 0x0013,
      string.format("0x%04X", dev:version()))
dev:who(0x0012)
check("who(nil) 不改", dev:who(nil):version() == 0x0012)

-- set_reset_cfg：复位后的 CONFIG 默认值可覆写
dev:set_reset_cfg(0x5555)
check("set_reset_cfg 立即置 CONFIG", dev:config() == 0x5555,
      string.format("0x%04X", dev:config()))
dev.write({ 0xFE, 0x54, 0x00 })
check("CMD 复位后 CONFIG=自定义 0x5555", dev:config() == 0x5555,
      string.format("0x%04X", dev:config()))

-- reset()：回 POR、计数清零；故障钩子保留
section()
dev:set_vcell_raw(100)
dev.nack_read = true
dev:reset()
check("reset 后 VCELL 回 0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))
check("reset 后 STATUS 回 0x0100", dev:status() == 0x0100,
      string.format("0x%04X", dev:status()))
check("reset 后 reset/quickstart 计数清零",
      dev:reset_count() == 0 and dev:quickstart_count() == 0)
check("reset 不清故障钩子（nack_read 仍在）", dev.nack_read == true)
dev:clear_faults()

-- VCELL 16 位直读编码（78.125µV/LSB，满码 65535=5.119921875V）
dev:set_vcell_raw(65535)
check("VCELL 满码 65535 → 字 0xFFFF", dev:word(0x02) == 0xFFFF,
      string.format("0x%04X", dev:word(0x02)))
check("VCELL 满码 5.119921875V", near(dev:vcell_v(), 5.119921875),
      tostring(dev:vcell_v()))
dev:set_vcell_raw(47360)
check("VCELL 码 47360 → 3.7V（16 位直读无移位）",
      dev:word(0x02) == 47360 and near(dev:vcell_v(), 3.7),
      string.format("%d %sV", dev:word(0x02), tostring(dev:vcell_v())))
dev:set_vcell_raw(0)
check("VCELL 码 0 → 0V", dev:word(0x02) == 0 and dev:vcell_v() == 0)
dev:set_vcell_raw(99999)
check("VCELL 超程钳 65535", dev:vcell_raw() == 65535, tostring(dev:vcell_raw()))
dev:set_vcell_raw(-5)
check("VCELL 负值钳 0", dev:vcell_raw() == 0, tostring(dev:vcell_raw()))

-- SOC u16 定点 1/256%（不钳到 100%）
dev:set_soc_raw(65535)
check("SOC 满码 65535 → 255.99609375%", near(dev:soc_pct(), 65535 / 256),
      tostring(dev:soc_pct()))
dev:set_soc_raw(32768)
check("SOC 32768 → 128%（芯片可 >100%）", near(dev:soc_pct(), 128),
      tostring(dev:soc_pct()))
dev:set_soc_pct(85)
check("set_soc_pct(85) → 字 21760（0x5500）",
      dev:soc_raw() == 21760 and near(dev:soc_pct(), 85),
      string.format("%d %s%%", dev:soc_raw(), tostring(dev:soc_pct())))
dev:set_soc_raw(70000)
check("SOC 超程钳 65535", dev:soc_raw() == 65535, tostring(dev:soc_raw()))

-- CRATE s16 ×0.208%/hr（充正放负），总线字为补码
dev:set_crate_raw(-480)
check("CRATE -480 → 字 0xFE20、-99.84%/hr",
      dev:word(0x16) == 0xFE20 and dev:crate_raw() == -480
      and near(dev:crate_pcthr(), -99.84),
      string.format("0x%04X %s %s", dev:word(0x16), tostring(dev:crate_raw()),
      tostring(dev:crate_pcthr())))
dev:set_crate_raw(32767)
check("CRATE 正满码 32767 → 6815.536%/hr",
      near(dev:crate_pcthr(), 32767 * 0.208), tostring(dev:crate_pcthr()))
dev:set_crate_raw(-32768)
check("CRATE 负满码 -32768 → 字 0x8000",
      dev:word(0x16) == 0x8000 and dev:crate_raw() == -32768,
      string.format("0x%04X %s", dev:word(0x16), tostring(dev:crate_raw())))
dev:set_crate_raw(40000)
check("CRATE 超程钳 32767", dev:crate_raw() == 32767, tostring(dev:crate_raw()))
dev:set_crate_raw(-40000)
check("CRATE 负超程钳 -32768", dev:crate_raw() == -32768, tostring(dev:crate_raw()))
dev:set_crate_pcthr(10)
check("set_crate_pcthr(10) → 码 48（48×0.208=9.984）",
      dev:crate_raw() == 48 and near(dev:crate_pcthr(), 9.984),
      string.format("%d %s", dev:crate_raw(), tostring(dev:crate_pcthr())))
dev:set_crate_pcthr(-2.5)
check("set_crate_pcthr(-2.5) → 码 -12（-2.496）",
      dev:crate_raw() == -12 and near(dev:crate_pcthr(), -2.496),
      string.format("%d %s", dev:crate_raw(), tostring(dev:crate_pcthr())))

-- VALRT 物理量逆注入（20mV 最近码，MIN 在高字节）
dev:set_valrt_v(3.3, 4.2)
check("set_valrt_v(3.3,4.2) → 字 0xA5D2（MIN=165/MAX=210）",
      dev:valrt() == 0xA5D2 and dev:valrt_min_code() == 165
      and dev:valrt_max_code() == 210, string.format("0x%04X", dev:valrt()))
dev:set_valrt_v(0, 5.1)
check("set_valrt_v(0,5.1) → 字 0x00FF（POR 同侧）", dev:valrt() == 0x00FF,
      string.format("0x%04X", dev:valrt()))
dev:set_valrt_v(6, -1)
check("set_valrt_v 超程钳 255/0（vmin=6V→顶码 255、vmax=-1V→底码 0，双侧独立钳）",
      dev:valrt_min_code() == 255 and dev:valrt_max_code() == 0,
      string.format("%d/%d", dev:valrt_min_code(), dev:valrt_max_code()))

-- 物理量逆注入量化闭环
dev:set_vcell_v(4.1)
check("set_vcell_v(4.1) → 码 52480 回读 4.1V",
      dev:vcell_raw() == 52480 and near(dev:vcell_v(), 4.1),
      string.format("%d %s", dev:vcell_raw(), tostring(dev:vcell_v())))
dev:set_vcell_v(3.333)
check("set_vcell_v(3.333) → 码 42662 回读 3.33297V（78.125µV 粒度）",
      dev:vcell_raw() == 42662 and near(dev:vcell_v(), 42662 * 78.125e-6),
      string.format("%d %s", dev:vcell_raw(), tostring(dev:vcell_v())))
dev:set_soc_pct(33.5)
check("set_soc_pct(33.5) → 字 8576 回读精确",
      dev:soc_raw() == 8576 and near(dev:soc_pct(), 33.5),
      string.format("%d %s", dev:soc_raw(), tostring(dev:soc_pct())))

-- 跨字 burst：偶地址 +2 续读，无「奇尾补 0」；稀疏地图遇缺口整笔 NACK
dev:set_word(0x02, 0x1122); dev:set_word(0x04, 0x3344); dev:set_word(0x06, 0x5566)
dev.write({ 0x02 })
local b6 = dev.read(6)
check("burst 6B 自 0x02 = 02,04,06 三对",
      b6 ~= nil and b6[1] == 0x11 and b6[2] == 0x22 and b6[3] == 0x33
      and b6[4] == 0x44 and b6[5] == 0x55 and b6[6] == 0x66,
      b6 and table.concat(b6, ",") or "nil")
local b3 = dev.read(3)
check("burst 3B = 当前字 hi/lo + 下一字 hi（11 22 33）",
      b3 ~= nil and b3[1] == 0x11 and b3[2] == 0x22 and b3[3] == 0x33,
      b3 and table.concat(b3, ",") or "nil")
dev.write({ 0x02 })
local b8 = dev.read(8)
check("burst 8B 自 0x02 跨四字 02/04/06/08 全可读（尾 VERSION=00 12）",
      b8 ~= nil and #b8 == 8 and b8[7] == 0x00 and b8[8] == 0x12,
      b8 and table.concat(b8, ",") or "nil")
check("burst 10B 越过 0x08 遇缺口 0x0A 整笔 NACK", dev.read(10) == nil)
dev.write({ 0x0C })
check("自 0x0C 读 2B 可读、读 4B 遇缺口 0x0E NACK",
      dev.read(2) ~= nil and dev.read(4) == nil)
dev.write({ 0x14 })
check("自 0x14 读 4B = VALRT/CRATE 两字可读", dev.read(4) ~= nil)
check("自 0x14 读 6B 遇缺口 0x18（VRESET 不建模）NACK", dev.read(6) == nil)
dev.write({ 0x1A })
check("自 0x1A 读 2B（STATUS）可读、读 4B 遇缺口 0x1C NACK",
      dev.read(2) ~= nil and dev.read(4) == nil)
check("read(0)/read(-1) NACK", dev.read(0) == nil and dev.read(-1) == nil)

-- virt_tick：32 拍单节锂电正弦 + CRATE 余弦
local tick_exp = {
	[0]  = { 3.85, 80, 9.984 },
	[8]  = { 4.10, 88, 0 },
	[24] = { 3.60, 72, 0 },
}
for n, e in pairs(tick_exp) do
	dev:virt_tick(n)
	check(string.format("virt_tick(%d) VCELL≈%.2fV", n, e[1]),
	      near(dev:vcell_v(), e[1], 0.0001), tostring(dev:vcell_v()))
	check(string.format("virt_tick(%d) SOC≈%d%%", n, e[2]),
	      near(dev:soc_pct(), e[2], 1 / 256), tostring(dev:soc_pct()))
	check(string.format("virt_tick(%d) CRATE≈%.3f%%/hr", n, e[3]),
	      near(dev:crate_pcthr(), e[3], 0.001), tostring(dev:crate_pcthr()))
end
dev:set_flags(63)
dev:virt_tick(0)
check("virt_tick 不触碰 STATUS（flags 仍 63）", dev:flags() == 63,
      tostring(dev:flags()))
dev:virt_tick(0)
local v0, s0, c0 = dev:vcell_v(), dev:soc_pct(), dev:crate_pcthr()
dev:virt_tick(32)
check("virt_tick(32) 回周期 = tick(0)",
      near(dev:vcell_v(), v0, 1e-12) and near(dev:soc_pct(), s0, 1e-12)
      and near(dev:crate_pcthr(), c0, 1e-12),
      string.format("%s %s %s", tostring(dev:vcell_v()), tostring(dev:soc_pct()),
      tostring(dev:crate_pcthr())))

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
dev:fail_read(function(p, n) return p == 0x16 and n == 2 end)
check("fail_read 谓词按 (ptr,n) 拦 CRATE、不拦 SOC",
      (function() dev.write({ 0x04 }); return dev.read(2) end)() ~= nil
      and (function() dev.write({ 0x16 }); return dev.read(2) end)() == nil)
dev:clear_faults()

-- config_writes 只收 3B 字写；reset_logs 清空；指针随字写更新
section()
dev.write({ 0x02 })
dev.write({ 0x0C, 0x12, 0x34 })
dev.write({ 0xFE, 0x54, 0x00 })
local cw = dev:config_writes()
check("config_writes 收 2 笔字写（0x0C、0xFE 复位前）",
      #cw == 2 and cw[1].reg == 0x0C and cw[1].word == 0x1234
      and cw[2].reg == 0xFE and cw[2].word == 0x5400,
      tostring(#cw))
check("字写后指针停在 0xFE", dev:pointer() == 0xFE,
      string.format("0x%02X", dev:pointer()))
dev:reset_logs()
check("reset_logs 清空留痕（write_log 与 config_writes 均空）",
      #dev.write_log == 0 and #dev:config_writes() == 0)

-- =====================================================================
-- 组 2：真实 build
-- 基础路径：set + VERSION 指针读（2）+ STATUS 横幅指针读（2）= 5 txlog，
-- 零写字、零睡眠
-- =====================================================================
mark = section()
expect_ok("build 正常（17048 默认）", function()
	return build({ fd = fd, address = "0x36" })
end)
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x36,
      tostring(#set_addrs(mark)))
local pw = ptr_writes(mark)
check("build 两笔纯指针写 0x08、0x1A（VERSION + STATUS 横幅）",
      #pw == 2 and pw[1] == 0x08 and pw[2] == 0x1A, table.concat(pw, ","))
check("build 两次 2B 读", #reads(mark) == 2, tostring(#reads(mark)))
check("build 共 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
check("build 零写字", #write_words(mark) == 0, tostring(#write_words(mark)))
check("build 零睡眠", sleep_total == 0, tostring(sleep_total))

-- STATUS 横幅读失败不致命：build 仍 OK
mark = section()
dev:fail_read(function(p) return p == 0x1A end)
expect_ok("build STATUS 横幅读失败仍 OK（非致命）", function()
	return build({ fd = fd, address = "0x36" })
end)
check("横幅读失败仍 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()

-- 字符串 fd
mark = section()
expect_ok("build 字符串 fd='3'", function()
	return build({ fd = "3", address = "0x36" })
end)

-- VERSION 甄别四分支
mark = section()
dev:who(0x0013)
expect_ok("build VERSION=0x0013 按 MAX17049 放行", function()
	return build({ fd = fd, address = "0x36" })
end)
dev:who(0x001F)
expect_err("build VERSION=0x001F（17044）拒收", function()
	return build({ fd = fd, address = "0x36" })
end, "MAX17043")
mark = section()
dev:who(0x001E)
expect_err("build VERSION=0x001E（17043）拒收", function()
	return build({ fd = fd, address = "0x36" })
end, "MAX17043")
check("17043 误拦在版本读之后：4 txlog（set+w08+r+w1A? 否——短路无横幅）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
mark = section()
dev:who(0x00AA)
expect_err("build VERSION=0x00AA 未知版本拒收", function()
	return build({ fd = fd, address = "0x36" })
end, "unexpected version")
check("未知版本同样 3 txlog 短路", #entries(mark) == 3, tostring(#entries(mark)))
dev:who(0x0012)

-- build 负路径：参数校验
mark = section()
expect_err("build 非 table", function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x36" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("参数校验路径零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build fd=99 set_addr 失败", function()
	return build({ fd = 99, address = "0x36" })
end, "set_addr failed")
check("fd=99 开窗零 txlog", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60", function()
	return build({ fd = fd, address = "0x60" })
end, "not responding")
check("错地址 set+w08 两 txlog（无挂载指针写 NACK、无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x08 and #reads(mark) == 0,
      tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0x08 end)
expect_err("build VERSION 读失败", function()
	return build({ fd = fd, address = "0x36" })
end, "read version failed")
check("VERSION 读失败 3 txlog（set+w08+r，失败 r 也留痕）",
      #entries(mark) == 3 and #reads(mark) == 1, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 1 and b[1] == 0x08 end)
expect_err("build VERSION 指针写失败", function()
	return build({ fd = fd, address = "0x36" })
end, "read version failed")
check("指针写失败 2 txlog（set+w08，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

-- QuickStart
mark = section()
expect_ok("build quickstart=1", function()
	return build({ fd = fd, address = "0x36", quickstart = "1" })
end)
local qsw = write_of(mark, 0x06)
check("MODE 写 0x4000（QuickStart）",
      qsw ~= nil and qsw[2] == 0x40 and qsw[3] == 0x00,
      qsw and table.concat(qsw, ",") or "nil")
check("quickstart 后模型 MODE 自清为 0、计数=1",
      dev:mode() == 0 and dev:quickstart_count() == 1,
      string.format("0x%04X qs=%s", dev:mode(), tostring(dev:quickstart_count())))
check("quickstart build 共 6 txlog（5+1 字写）", #entries(mark) == 6,
      tostring(#entries(mark)))
check("quickstart 实睡 5ms", sleep_total == 5, tostring(sleep_total))

mark = section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x06 end)
expect_err("build quickstart 写失败", function()
	return build({ fd = fd, address = "0x36", quickstart = "1" })
end, "quickstart write failed")
check("quickstart 写失败 4 txlog（set+w08+r+w06）",
      #entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

-- VALRT 读改写（datasheet Figure 11：MIN 在 0x14、MAX 在 0x15）
mark = section()
expect_ok("build valrt 双侧 4.2/3.3", function()
	return build({ fd = fd, address = "0x36", valrt_max = "4.2", valrt_min = "3.3" })
end)
local vw = write_of(mark, 0x14)
check("VALRT 写字节 {0xA5,0xD2}（MIN=165 在高、MAX=210 在低）",
      vw ~= nil and vw[2] == 165 and vw[3] == 210,
      vw and table.concat(vw, ",") or "nil")
check("模型 VALRT=0xA5D2", dev:valrt() == 0xA5D2,
      string.format("0x%04X", dev:valrt()))
check("valrt build 共 8 txlog（5 + 指针读 2 + 字写 1）", #entries(mark) == 8,
      tostring(#entries(mark)))

mark = section()
expect_ok("build 仅 valrt_max=4.2（POR MIN=0 保留）", function()
	return build({ fd = fd, address = "0x36", valrt_max = "4.2" })
end)
vw = write_of(mark, 0x14)
check("仅置 MAX：写 {0x00,0xD2}（高字节 MIN 保持 POR 0）",
      vw ~= nil and vw[2] == 0x00 and vw[3] == 0xD2,
      vw and table.concat(vw, ",") or "nil")
check("模型 VALRT=0x00D2", dev:valrt() == 0x00D2,
      string.format("0x%04X", dev:valrt()))

mark = section()
expect_ok("build 仅 valrt_min=3.3（POR MAX=255 保留）", function()
	return build({ fd = fd, address = "0x36", valrt_min = "3.3" })
end)
vw = write_of(mark, 0x14)
check("仅置 MIN：写 {0xA5,0xFF}（低字节 MAX 保持 POR 255）",
      vw ~= nil and vw[2] == 0xA5 and vw[3] == 0xFF,
      vw and table.concat(vw, ",") or "nil")
check("模型 VALRT=0xA5FF", dev:valrt() == 0xA5FF,
      string.format("0x%04X", dev:valrt()))

mark = section()
expect_err("build valrt_max=6 越界", function()
	return build({ fd = fd, address = "0x36", valrt_max = "6" })
end, "valrt_max")
check("越界在 VALRT 读之后：5 txlog（set+w08+r+w14+r，无写）",
      #entries(mark) == 5 and #write_words(mark) == 0, tostring(#entries(mark)))
mark = section()
expect_err("build valrt_min=-0.1 越界", function()
	return build({ fd = fd, address = "0x36", valrt_min = "-0.1" })
end, "valrt_min")
check("valrt_min 越界同样 5 txlog 无写", #entries(mark) == 5, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(p) return p == 0x14 end)
expect_err("build VALRT 读失败", function()
	return build({ fd = fd, address = "0x36", valrt_max = "4.2" })
end, "read VALRT failed")
check("VALRT 读失败 5 txlog（set+w08+r+w14+r）", #entries(mark) == 5,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x14 end)
expect_err("build VALRT 写失败", function()
	return build({ fd = fd, address = "0x36", valrt_max = "4.2" })
end, "VALRT write failed")
check("VALRT 写失败 6 txlog（读成功后字写 NACK）", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:clear_faults()

-- ATHD（CONFIG 读改写，保高字节 RCOMP 与低字节 bit7:5）
mark = section()
expect_ok("build athd=10", function()
	return build({ fd = fd, address = "0x36", athd = "10" })
end)
local aw = write_of(mark, 0x0C)
check("CONFIG 写 0x9716（RCOMP 保留，ATHD=22=32-10）",
      aw ~= nil and aw[2] == 0x97 and aw[3] == 0x16,
      aw and table.concat(aw, ",") or "nil")
check("模型 CONFIG=0x9716", dev:config() == 0x9716,
      string.format("0x%04X", dev:config()))
check("athd build 共 8 txlog", #entries(mark) == 8, tostring(#entries(mark)))

mark = section()
dev:set_word(0x0C, 0x97F8)	-- 低字节 bit7:5 全 1 + ATHD=24
expect_ok("build athd=32 保留 bit7:5", function()
	return build({ fd = fd, address = "0x36", athd = "32" })
end)
aw = write_of(mark, 0x0C)
check("ATHD=32 编码 0：写 0x97E0（SLEEP/ALSC/ALRT 三位保留）",
      aw ~= nil and aw[2] == 0x97 and aw[3] == 0xE0,
      aw and table.concat(aw, ",") or "nil")
dev:set_word(0x0C, 0x971C)

mark = section()
expect_err("build athd=0 越界", function()
	return build({ fd = fd, address = "0x36", athd = "0" })
end, "athd")
check("athd 越界 3 txlog 无写（先校验后读 CONFIG）",
      #entries(mark) == 3 and #write_words(mark) == 0,
      tostring(#entries(mark)))
mark = section()
expect_err("build athd=33 越界", function()
	return build({ fd = fd, address = "0x36", athd = "33" })
end, "athd")

mark = section()
dev:fail_read(function(p) return p == 0x0C end)
expect_err("build CONFIG 读失败", function()
	return build({ fd = fd, address = "0x36", athd = "10" })
end, "read CONFIG failed")
check("CONFIG 读失败 5 txlog", #entries(mark) == 5, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 3 and b[1] == 0x0C end)
expect_err("build CONFIG 写失败", function()
	return build({ fd = fd, address = "0x36", athd = "10" })
end, "CONFIG write failed")
check("CONFIG 写失败 6 txlog", #entries(mark) == 6, tostring(#entries(mark)))
dev:clear_faults()

-- 全配置同时给：5 + QS 1 + VALRT 3 + ATHD 3 = 12 txlog，睡眠 5
mark = section()
expect_ok("build 全配置 quickstart+valrt+athd", function()
	return build({ fd = fd, address = "0x36", quickstart = "1",
	               valrt_max = "4.2", valrt_min = "3.3", athd = "10" })
end)
check("全配置共 12 txlog", #entries(mark) == 12, tostring(#entries(mark)))
check("全配置睡眠 5ms", sleep_total == 5, tostring(sleep_total))
-- 1 字节指针写序：08(VERSION)→14(VALRT)→0C(CONFIG)→1A(STATUS)；
-- QuickStart 的 0x06 是 3 字节字写（无前置指针读），已在 quickstart 专项断言
check("全配置指针序 08,14,0C,1A（0x06 QuickStart 为字写另检）",
      table.concat(ptr_writes(mark), ",") == "8,20,12,26",
      table.concat(ptr_writes(mark), ","))

-- =====================================================================
-- 组 3：真实 call（set + 四寄存器指针读 = 9 txlog，零睡眠）
-- =====================================================================
mark = section()
dev:set_vcell_raw(26214):set_soc_raw(0x5A80):set_crate_raw(-480)
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x36" }) end)
local cr = expect_ok("call 四通道", function()
	return call({ fd = fd, address = "0x36" })
end)
if cr then
	check("VCELL = 26214×78.125µV = 2.04796875V", near(cr.VCELL, 2.04796875),
	      tostring(cr.VCELL))
	check("SOC = 0x5A80/256 = 90.5%", near(cr.SOC, 90.5), tostring(cr.SOC))
	check("CRATE = -480×0.208 = -99.84%/hr", near(cr.CRATE, -99.84),
	      tostring(cr.CRATE))
	check("STATUS = 1（POR RI）", cr.STATUS == 1, tostring(cr.STATUS))
end
check("call 一次 set_addr", #set_addrs(mark) == 2 + 1 - 1, tostring(#set_addrs(mark)))
pw = ptr_writes(mark)
-- 窗口含一次 build：build 指针 08,1A；call 指针 02,04,16,1A
check("窗口指针序 build(08,1A)+call(02,04,16,1A)",
      table.concat(pw, ",") == "8,26,2,4,22,26", table.concat(pw, ","))

-- call 单独窗口：9 txlog
section()
dev:set_vcell_raw(26214):set_soc_raw(0x5A80):set_crate_raw(-480)
expect_ok("段内 build", function() return build({ fd = fd, address = "0x36" }) end)
mark = #vbus.txlog
cr = expect_ok("call 独立窗口", function() return call({ fd = fd, address = "0x36" }) end)
check("call 一次 set", #set_addrs(mark) == 1, tostring(#set_addrs(mark)))
check("call 四笔纯指针写 0x02/0x04/0x16/0x1A",
      table.concat(ptr_writes(mark), ",") == "2,4,22,26",
      table.concat(ptr_writes(mark), ","))
check("call 四次 2B 读", #reads(mark) == 4, tostring(#reads(mark)))
check("call 共 9 txlog", #entries(mark) == 9, tostring(#entries(mark)))
check("call 默认无写字", #write_words(mark) == 0, tostring(#write_words(mark)))
check("call 零睡眠（sleep_total 仍为 build 的 0）", sleep_total == 0,
      tostring(sleep_total))

-- 17049 刻度：须重新 build 让驱动重锁 cfg_lsb_v
section()
dev:who(0x0013)
dev:set_vcell_raw(26214)
expect_ok("17049 build", function() return build({ fd = fd, address = "0x36" }) end)
cr = expect_ok("call 17049 双节刻度", function()
	return call({ fd = fd, address = "0x36" })
end)
if cr then
	check("VCELL = 26214×156.25µV = 4.0959375V", near(cr.VCELL, 4.0959375),
	      tostring(cr.VCELL))
end

-- 满码/空电/CRATE 极值（回到 17048：section + build）
section()
expect_ok("回 17048 build", function() return build({ fd = fd, address = "0x36" }) end)
local cases = {
	{ 65535, 0xFFFF, 32767, 65535 * 78.125e-6, 65535 / 256, 32767 * 0.208, "满码" },
	{ 0,     0,      -32768, 0,                   0,            -32768 * 0.208, "空电/负满程" },
	{ 52480, 21760,  48,     4.1,                 85,           9.984,           "典型 4.1V/85%/+9.984" },
}
for _, c in ipairs(cases) do
	dev:set_vcell_raw(c[1]):set_soc_raw(c[2]):set_crate_raw(c[3])
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("call %s：VCELL/SOC/CRATE", c[7]),
	      x.result == "OK" and near(x.VCELL, c[4], 1e-9)
	      and near(x.SOC, c[5], 1e-9) and near(x.CRATE, c[6], 1e-9),
	      x and string.format("%s %s %s", tostring(x.VCELL), tostring(x.SOC),
	      tostring(x.CRATE)) or "ERR")
end

-- clear=1 三分支
section()
expect_ok("clear 段 build", function() return build({ fd = fd, address = "0x36" }) end)
dev:set_status(0x7F40)	-- 六标志全置 + EnVr + 低字节 0x40
mark = #vbus.txlog
cr = expect_ok("call clear=1（有标志）", function()
	return call({ fd = fd, address = "0x36", clear = "1" })
end)
if cr then check("STATUS 读值 63", cr.STATUS == 63, tostring(cr.STATUS)) end
local sw = write_of(mark, 0x1A)
check("清标志写 {0x40,0x40}（六标志清 0，EnVr/低字节保留）",
      sw ~= nil and sw[2] == 0x40 and sw[3] == 0x40,
      sw and table.concat(sw, ",") or "nil")
check("clear 共 10 txlog（9+1 字写）", #entries(mark) == 10, tostring(#entries(mark)))
check("模型 STATUS=0x4040", dev:status() == 0x4040,
      string.format("0x%04X", dev:status()))

mark = #vbus.txlog
expect_ok("call clear=1（无标志不写）", function()
	return call({ fd = fd, address = "0x36", clear = "1" })
end)
check("无标志 9 txlog 无写字", #entries(mark) == 9 and #write_words(mark) == 0,
      tostring(#entries(mark)))

dev:set_status(0x0040)	-- 仅低字节（高字节无标志）
mark = #vbus.txlog
expect_ok("call clear=1（高字节无标志不写）", function()
	return call({ fd = fd, address = "0x36", clear = "1" })
end)
check("高字节无标志不触发写", #entries(mark) == 9 and #write_words(mark) == 0,
      tostring(#entries(mark)))

-- clear 的 STATUS 写失败：驱动不检查返回值，call 仍 OK
section()
expect_ok("写失败段 build", function() return build({ fd = fd, address = "0x36" }) end)
dev:set_flags(63)
dev:fail_write(function(b) return #b == 3 and b[1] == 0x1A end)
mark = #vbus.txlog
expect_ok("call clear 写失败仍 OK（驱动忽略）", function()
	return call({ fd = fd, address = "0x36", clear = "1" })
end)
check("clear 写失败仍 10 txlog", #entries(mark) == 10, tostring(#entries(mark)))
dev:clear_faults()

-- 连续三拍不串字 + virt_tick 驱动闭环
section()
expect_ok("闭环段 build", function() return build({ fd = fd, address = "0x36" }) end)
local beats = {
	{ 3.70, 80, -5.0 }, { 4.05, 92, 2.5 }, { 3.55, 15, -12.0 },
}
for i, b in ipairs(beats) do
	dev:set_vcell_v(b[1]):set_soc_pct(b[2]):set_crate_pcthr(b[3])
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("连续读第 %d 拍不串字", i),
	      x.result == "OK" and near(x.VCELL, b[1], 0.0001)
	      and near(x.SOC, b[2], 1 / 256) and near(x.CRATE, b[3], 0.2081),
	      x and string.format("%sV %s%% %s%%/hr", tostring(x.VCELL),
	      tostring(x.SOC), tostring(x.CRATE)) or "ERR")
end
for n, e in pairs({ [0] = { 3.85, 80, 9.984 }, [8] = { 4.10, 88, 0 },
                   [24] = { 3.60, 72, 0 } }) do
	dev:virt_tick(n)
	local x = call({ fd = fd, address = "0x36" })
	check(string.format("virt_tick(%d) 驱动闭环", n),
	      near(x.VCELL, e[1], 0.0001) and near(x.SOC, e[2], 1 / 256)
	      and near(x.CRATE, e[3], 0.001),
	      string.format("%sV %s%% %s%%/hr", tostring(x.VCELL), tostring(x.SOC),
	      tostring(x.CRATE)))
end

-- 无 build 守卫：重载驱动后裸 call 合法（cfg_lsb_v 兜底 78.125µV）
section()
vbus.attach("MAX17048@0x37", 0x37, smod.new())
vbus.load_driver("modules/MAX17048.lua")
i2c_set_addr(fd, 0x37)
mark = #vbus.txlog
local nc = expect_ok("未 build 裸 call 合法（无硬守卫，刻度兜底）", function()
	return call({ fd = fd, address = "0x37" })
end)
check("裸 call 仍 9 txlog", #entries(mark) == 9, tostring(#entries(mark)))
vbus.attach("MAX17048@0x36", ADDR, dev)
vbus.load_driver("modules/MAX17048.lua")
local smod = MAX17048_VIRT
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
end, "read VCELL failed")
check("错地址 set+w02 两 txlog（无挂载无 r）",
      #entries(mark) == 2 and set_addrs(mark)[1] == 0x60
      and ptr_writes(mark)[1] == 0x02, tostring(#entries(mark)))

local fail_seq = {
	{ 0x02, "read VCELL failed", 3, 1 },
	{ 0x04, "read SOC failed",   5, 2 },
	{ 0x16, "read CRATE failed", 7, 3 },
	{ 0x1A, "read STATUS failed", 9, 4 },
}
for _, c in ipairs(fail_seq) do
	section()
	expect_ok("失败段 build", function() return build({ fd = fd, address = "0x36" }) end)
	dev:fail_read(function(p) return p == c[1] end)
	mark = #vbus.txlog
	expect_err(string.format("call 0x%02X 读失败", c[1]), function()
		return call({ fd = fd, address = "0x36" })
	end, c[2])
	check(string.format("0x%02X 读失败 %d txlog（%d 次 r）", c[1], c[3], c[4]),
	      #entries(mark) == c[3] and #reads(mark) == c[4],
	      string.format("%d txlog %d r", #entries(mark), #reads(mark)))
	dev:clear_faults()
end

section()
expect_ok("指针失败段 build", function() return build({ fd = fd, address = "0x36" }) end)
dev:fail_write(function(b) return #b == 1 and b[1] == 0x02 end)
mark = #vbus.txlog
expect_err("call VCELL 指针写失败", function()
	return call({ fd = fd, address = "0x36" })
end, "read VCELL failed")
check("VCELL 指针写失败 2 txlog（set+w02，无 r）",
      #entries(mark) == 2 and #reads(mark) == 0, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无资源释放，arg_table 校验，零总线事务）
-- =====================================================================
mark = section()
expect_ok("destroy 无资源释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_ok("destroy 带 fd 也 OK", function()
	return destroy({ fd = fd, address = "0x36" })
end)
expect_err("destroy 非 table", function() return destroy("x") end, "Invalid Arguments Type")

-- =====================================================================
-- 组 5:26.3b NaN 配置列拒绝（valrt_max/valrt_min/athd 走 finite_of）
-- =====================================================================
local mark_vmax = section()
expect_ok("valrt_max='nan' 跳过 VALRT 写（finite_of 返回 nil → 条件不满足）",
          function() return build({ fd = fd, address = "0x36", valrt_max = "nan" }) end)
-- VALRT 写路径会先读 REG_VALRT（1 次 r）再写 REG_VALRT（1 次 w）；
-- 跳过该路径意味着相比正常 build（含 VALRT 写）少 1r+1w。
-- 正常 build 有 3r+2w（VERSION+STATUS+VALRT read, VALRT+CONFIG write 视条件）；
-- NaN 路径应只有 2r+1w（VERSION+STATUS read, 无 VALRT/CONFIG write）。
check("valrt_max='nan' 无 VALRT 读事务",
      #reads(mark_vmax) == 2, tostring(#reads(mark_vmax)))

local mark_athd = section()
expect_ok("athd='nan' 跳过 ATHD 写",
          function() return build({ fd = fd, address = "0x36", athd = "nan" }) end)
check("athd='nan' 无 CONFIG 读事务",
      #reads(mark_athd) == 2, tostring(#reads(mark_athd)))

tester.summary("test_max17048")

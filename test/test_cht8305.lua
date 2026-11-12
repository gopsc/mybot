-- test_cht8305.lua —— CHT8305 真实驱动 + 虚拟 I2C 总线 + 温湿度模型
-- 用法（项目根目录）: luajit test/test_cht8305.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：CHT_GC=1 luajit test/test_cht8305.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + 内嵌模型（modules/CHT8305.lua 尾部 CHT8305_VIRT，2026-09-15
-- 自 virtbus/cht8305.lua 迁入）」。本器件是 virtbus 库【8 位「字寄存器」
-- 指针 + 无指针纯读 + 每通道转换门 + 双 ROM ID 甄别】样板（SensyLink
-- CHT8305C，地址 0x40~0x43，悬空 0x40）：
--   指针索引 16 位字寄存器（非字节）：0x00 T/0x01 H 测量只读字、0x02 配置
--   （POR 0、bit15 软复位自清）、0x03 告警限、0xFE MID=0x5959、0xFF DID=0x8305；
--   纯指针写恰 1 字节、字写 {ptr,MSB,LSB} 大端、纯读 i2c_read(fd,2) 不带
--   指针（不是 i2c_read_multi）；驱动软复位只发 {0x02,0x80} 半字帧——高字节
--   bit7=bit15 即触发，模型不替驱动补 LSB。写测量指针启动该通道 14ms 转换门，
--   门内纯读 NACK、advance 推进、完成后保持；virt_tick 预武装零等待（武装跨
--   软复位保留，守护 build 复位不断流）。
--
-- 覆盖：模型侧 POR/字寄存器指针与大端字节序/字自增/burst/未定义指针 NACK/
-- 坏帧 NACK/半字帧软复位/只读字写丢弃/双门 13·14ms 边界与通道独立/
-- never_ready/virt_tick 32 拍反相正弦/物理逆注入闭环/谓词+nack 钩子/
-- reset 保留钩子与武装/种子构造；真实 build 六事务序（set→{02,80}复位写
-- →{FE}→r→{FF}→r，sleep 10ms）与帧长哨兵、MID/DID 错、复位写/指针/读
-- 六类 NACK 负路径、零/坏参/错地址；真实 call 五事务序（set→{00}→r→
-- {01}→r，2×14ms=28ms 睡眠经 advance 过门）、边界与典型值独立公式交叉、
-- 无未 build 守卫事实、温/湿四路失败精确短路；destroy 零总线事务。

if os.getenv("CHT_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 悬空地址 0x40；同一模型可多挂（0x40~0x43），本文件主测 0x40
-- 模型内嵌于驱动文件（CHT8305_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/CHT8305.lua")
local smod = CHT8305_VIRT

local dev = smod.new()
vbus.attach("CHT8305@0x40", 0x40, dev)
vbus.attach("CHT8305@0x41", 0x41, dev)

-- milli_sleep 桩：累加 + 推模型虚拟时钟（build 10ms、call 2×14ms）
local sleep_total = 0
function milli_sleep(ms)
	sleep_total = sleep_total + (tonumber(ms) or 0)
	dev:advance(tonumber(ms) or 0)
end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))
check("i2c_set_addr 0x40", i2c_set_addr(fd, 0x40) == true)

-- 每个 section：身份覆写归位 + 器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:who(0x5959, 0x8305)	-- who(nil) 语义是「不改」，故显式恢复出厂 ID
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用）
local function window() return #vbus.txlog end

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
local function read_sizes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "r" then t[#t + 1] = e.bytes.n end
	end
	return t
end
local function nwr(mark) return #writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function rnd(x) return math.floor(x + 0.5) end

-- 测试侧独立换算（照驱动注释常数，不看模型实现）
local function ref_t(raw) return raw * 165.0 / 65535.0 - 40.0 end
local function ref_h(raw) return raw * 100.0 / 65535.0 end
local function ref_t_raw(t) return rnd((t + 40) * 65535 / 165) end
local function ref_h_raw(h) return rnd(h * 65535 / 100) end

local ARGS = { fd = fd, address = "0x40" }

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点 API / 经 HAL）
-- =====================================================================
local m = section()
check("POR ptr=0x00", dev:ptr() == 0x00, string.format("0x%02X", dev:ptr()))
check("POR config=0x0000", dev:config() == 0x0000, string.format("0x%04X", dev:config()))
check("POR alert=0x0000", dev:alert() == 0x0000)
check("MID=0x5959", dev:mid() == 0x5959, string.format("0x%04X", dev:mid()))
check("DID=0x8305", dev:did() == 0x8305, string.format("0x%04X", dev:did()))
check("POR T/H 无测量码", dev:temp_raw() == nil and dev:humi_raw() == nil)
check("POR 计数全 0", dev:write_count() == 0 and dev:read_count() == 0 and dev:reset_count() == 0)

-- 未完成转换：纯读 NACK，指针不动、读不计数
check("POR T 读 NACK（无转换）", dev.read(2) == nil)
check("NACK 后 ptr 仍 0x00", dev:ptr() == 0x00)
check("NACK 读不计数", dev:read_count() == 0)

-- HAL 形态：纯指针写 + 无指针纯读（i2c_read，区别 i2c_read_multi）
m = section()
check("HAL i2c_write_multi(fd,0xFE) 返 0", i2c_write_multi(fd, 0xFE) == 0)
check("窗口 1 写恰 1 字节 {FE}", nwr(m) == 1 and #writes(m)[1] == 1 and writes(m)[1][1] == 0xFE)
local midval = i2c_read(fd, 2)
check("HAL i2c_read 合并大端 MID=0x5959", midval == 0x5959,
	string.format("0x%X", midval + 0))
check("MID 纯读窗口无指针写（只 1w1r）", nwr(m) == 1 and nrd(m) == 1 and read_sizes(m)[1] == 2)
check("读 MID 后 ptr 字自增到 FF", dev:ptr() == 0xFF, string.format("0x%02X", dev:ptr()))
check("DID 纯读 0x8305", i2c_read(fd, 2) == 0x8305)
check("DID 读后到文件尾 0x100", dev:ptr() == 0x100)
check("文件尾外纯读 NACK（HAL 返 -1）", i2c_read(fd, 2) == -1)
check("读 NACK 指针不动（仍 0x100）", dev:ptr() == 0x100)

-- 配置/告警字写：{ptr,MSB,LSB} 大端落盘
m = section()
check("配置字写 {02,20,00} 返 0", i2c_write_multi(fd, 0x02, 0x20, 0x00) == 0)
check("config=0x2000（加热器位）", dev:config() == 0x2000, string.format("0x%04X", dev:config()))
check("config 写帧留痕 3 字节", nwr(m) == 1 and #writes(m)[1] == 3)
check("字写后 ptr=0x03", dev:ptr() == 0x03, tostring(dev:ptr()))
check("告警限字写", i2c_write_multi(fd, 0x03, 0x12, 0x34) == 0 and dev:alert() == 0x1234)
-- 半字写（仅高字节，保留低半）
section()
check("半字写 {02,7F} 高字节落盘低半保留",
	i2c_write_multi(fd, 0x02, 0x7F) == 0 and dev:config() == 0x7F00,
	string.format("0x%04X", dev:config()))
check("半字写后再全字 {02,7F,05}",
	i2c_write_multi(fd, 0x02, 0x7F, 0x05) == 0 and dev:config() == 0x7F05)
-- 跨字 burst：alert 满字后下一字 0x04 未定义，余字节忽略但帧 ACK
section()
check("跨地图 burst ACK（越界字节忽略）",
	i2c_write_multi(fd, 0x03, 0xAA, 0xBB, 0x00, 0x11) == 0)
check("alert=0xAABB（仅首字）", dev:alert() == 0xAABB, string.format("0x%04X", dev:alert()))

-- 只读字（T/H 测量结果、MID/DID）数据写 ACK 但丢弃
section()
dev:set_raw(0x1111, 0x2222)
check("T 测量字只读写 ACK", i2c_write_multi(fd, 0x00, 0xDE, 0xAD) == 0)
check("T 不被写毁 0x1111", dev:temp_raw() == 0x1111, string.format("0x%04X", dev:temp_raw()))
check("MID 只读写 ACK 不毁", i2c_write_multi(fd, 0xFE, 0x12, 0x34) == 0 and dev:mid() == 0x5959)
check("DID 只读写 ACK 不毁", i2c_write_multi(fd, 0xFF, 0x12, 0x34) == 0 and dev:did() == 0x8305)

-- 软复位：驱动同款半字帧 {02,80} 与完整 0x8000 帧
m = section()
i2c_write_multi(fd, 0x02, 0x20, 0x00)	-- 先配加热器
dev:set_raw(0x3333, 0x4444)
check("半字软复位帧 {02,80} ACK", i2c_write_multi(fd, 0x02, 0x80) == 0)
check("半字帧触发 reset_count+1", dev:reset_count() == 1, tostring(dev:reset_count()))
check("复位 config 回 0（bit15 自清）", dev:config() == 0)
check("复位清测量码", dev:temp_raw() == nil and dev:humi_raw() == nil)
check("复位 ptr 归 0", dev:ptr() == 0)
check("MID/DID ROM 常量仍在", dev:mid() == 0x5959 and dev:did() == 0x8305)
check("复位帧写计数 2（配置写+复位写）", dev:write_count() == 2, tostring(dev:write_count()))
check("全字 0x8000 帧同样复位",
	i2c_write_multi(fd, 0x02, 0x80, 0x00) == 0 and dev:reset_count() == 2)
-- burst 中第二字高字节带复位位也触发（03 写满后下一字越界不写，造 02 第二字节）
section()
check("低字节 0x80 不触发复位（复位位在高字节）",
	i2c_write_multi(fd, 0x02, 0x00, 0x80) == 0 and dev:reset_count() == 0 and dev:config() == 0x0080,
	string.format("cnt=%d cfg=0x%04X", dev:reset_count(), dev:config()))

-- 未定义指针 / 坏帧
m = section()
check("未定义指针 0x04 NACK", i2c_write_multi(fd, 0x04) == -1)
check("未定义指针 0x10 带数据 NACK", i2c_write_multi(fd, 0x10, 0x00) == -1)
check("保留区间 0xFD NACK", i2c_write_multi(fd, 0xFD) == -1)
check("非字节 256 整笔 NACK", dev.write({ 0x00, 256 }) == false)
check("非字节 -1 整笔 NACK", dev.write({ 0x00, -1 }) == false)
check("非 table NACK", dev.write(123) == false)
check("字符串 NACK", dev.write("x") == false)
check("空表 NACK", dev.write({}) == false)
check("坏帧模型侧不计数", dev:write_count() == 0, tostring(dev:write_count()))
check("坏帧寄存器不动（config 仍 0）", dev:config() == 0)
check("坏帧尝试仍上总线留痕（HAL 笔数含 NACK）", nwr(m) >= 3, tostring(nwr(m)))

-- 纯读长度：1 字节高字节、4 字节 burst 跨两字（走普通转换门，不在门组前武装）
section()
dev:set_raw(0x1234, 0x5678)
i2c_write_multi(fd, 0x00)
dev:advance(14)
local one = dev.read(1)
check("read(1) 返高字节", type(one) == "table" and #one == 1 and one[1] == math.floor(dev:temp_raw() / 256))
check("read(1) 后 ptr=0x01（按字自增）", dev:ptr() == 0x01)
-- 重新选 T，4 字节 burst 取 T+H（门只检起始字，T 就绪即可跨读 H 影子码）
i2c_write_multi(fd, 0x00)
dev:advance(14)
local four = dev.read(4)
local tcode, hcode = dev:temp_raw(), dev:humi_raw()
check("read(4) = T_hi T_lo H_hi H_lo",
	four[1] == math.floor(tcode / 256) and four[2] == tcode % 256 and
	four[3] == math.floor(hcode / 256) and four[4] == hcode % 256)
check("read(4) 后 ptr=0x02", dev:ptr() == 0x02)
check("非数 n 钳 1", #dev.read(-5) == 1)
check("超长 n 钳 8", #dev.read(99) == 8)

-- 转换门：13ms 未就绪 / 14ms 就绪；通道独立；结果保持
section()
dev:set_raw(0x6666, 0x9999)
check("指针 T 启动转换", i2c_write_multi(fd, 0x00) == 0)
check("conv_reg=0x00 remaining=14", dev:conv_reg() == 0x00 and dev:remaining_ms() == 14,
	string.format("%s/%s", tostring(dev:conv_reg()), tostring(dev:remaining_ms())))
check("门内纯读 NACK", dev.read(2) == nil)
check("门内读指针不动", dev:ptr() == 0x00)
dev:advance(13)
check("13ms 仍未就绪", dev.read(2) == nil)
dev:advance(1)
local bt = dev.read(2)
check("14ms T 就绪 66 66", bt and bt[1] == 0x66 and bt[2] == 0x66)
check("T 读完 ptr=0x01", dev:ptr() == 0x01)
-- H 通道：未写指针前未就绪
check("H 未触发读 NACK（通道独立）", dev.read(2) == nil)
check("NACK 指针不动 0x01", dev:ptr() == 0x01)
i2c_write_multi(fd, 0x01)
check("H 门内 NACK", dev.read(2) == nil)
dev:advance(14)
local bh = dev.read(2)
check("H 就绪 99 99", bh and bh[1] == 0x99 and bh[2] == 0x99)
-- 重触发使旧结果失效
i2c_write_multi(fd, 0x00)
check("重触发 T 立即 NACK", dev.read(2) == nil)
dev:set_raw(0x0102, nil)
dev:advance(14)
local bt2 = dev.read(2)
check("重触发完成读新码 01 02", bt2 and bt2[1] == 0x01 and bt2[2] == 0x02)
-- never_ready
section()
dev:set_never_ready(true)
i2c_write_multi(fd, 0x00)
dev:advance(999)
check("never_ready 推进无效", dev.read(2) == nil and dev:remaining_ms() == 14,
	tostring(dev:remaining_ms()))
check("never_ready 下武装也无效", (function() dev:virt_tick(0); return dev.read(2) == nil end)())
dev:set_never_ready(false)

-- 物理量逆注入闭环（测试侧独立公式）
section()
for _, t in ipairs({ -40, 0, 25, 85.3, 125 }) do
	dev:set_temp_c(t)
	check(string.format("set_temp_c(%.1f) 闭环", t),
		near(ref_t(dev:temp_raw()), t, 1 / 65535 * 165),
		string.format("%d->%s", dev:temp_raw(), tostring(ref_t(dev:temp_raw()))))
end
for _, h in ipairs({ 0, 25.7, 50, 100 }) do
	dev:set_humi_pct(h)
	check(string.format("set_humi_pct(%.1f) 闭环", h),
		near(ref_h(dev:humi_raw()), h, 1 / 65535 * 100),
		string.format("%d->%s", dev:humi_raw(), tostring(ref_h(dev:humi_raw()))))
end
dev:set_temp_c(-100)
check("温度超下程钳 0", dev:temp_raw() == 0, tostring(dev:temp_raw()))
dev:set_temp_c(500)
check("温度超上程钳 65535", dev:temp_raw() == 65535, tostring(dev:temp_raw()))
dev:set_humi_pct(-5)
check("湿度负钳 0", dev:humi_raw() == 0)
dev:set_humi_pct(200)
check("湿度超程钳 65535", dev:humi_raw() == 65535)
-- set_raw 不改就绪态（门纪律）
section()
dev:set_raw(1234, 5678)
check("set_raw 不置就绪", not dev:is_ready(0x00) and not dev:is_ready(0x01))

-- virt_tick：32 拍确定性反相正弦 + 预武装
section()
local function tick_codes(n)
	local d = smod.new()
	d:virt_tick(n)
	return d:temp_raw(), d:humi_raw(), d
end
local t0, h0 = tick_codes(0)
check("tick0 T=25°C raw", t0 == ref_t_raw(25), string.format("%d vs %d", t0, ref_t_raw(25)))
check("tick0 H=50% raw", h0 == ref_h_raw(50), string.format("%d vs %d", h0, ref_h_raw(50)))
local t8, h8 = tick_codes(8)
check("tick8 T=30°C raw", t8 == ref_t_raw(30), string.format("%d vs %d", t8, ref_t_raw(30)))
check("tick8 H=40% raw（反相谷）", h8 == ref_h_raw(40), string.format("%d vs %d", h8, ref_h_raw(40)))
local t24, h24 = tick_codes(24)
check("tick24 T=20°C raw（谷）", t24 == ref_t_raw(20), string.format("%d vs %d", t24, ref_t_raw(20)))
check("tick24 H=60% raw（峰）", h24 == ref_h_raw(60), string.format("%d vs %d", h24, ref_h_raw(60)))
local t32, h32 = tick_codes(32)
check("tick32 与 tick0 同相", t32 == t0 and h32 == h0)
-- 拍点单调：0→8 T 爬坡
local prev = -1
local mono = true
for n = 0, 8 do
	local d = smod.new(); d:virt_tick(n)
	if d:temp_raw() < prev then mono = false end
	prev = d:temp_raw()
end
check("tick0→8 T 单调爬坡", mono)
-- 预武装：写指针零等待，且跨软复位保留
section()
dev:virt_tick(0)
check("armed 标志", dev:is_armed())
i2c_write_multi(fd, 0x00)
check("武装下 T 指针写即就绪（remaining=0）", dev:remaining_ms() == 0 and dev.read(2) ~= nil)
i2c_write_multi(fd, 0x01)
check("武装下 H 指针写即就绪", dev.read(2) ~= nil)
i2c_write_multi(fd, 0x02, 0x80)
check("软复位后武装保留", dev:is_armed())
i2c_write_multi(fd, 0x00)
check("复位后 T 指针写仍即就绪", dev.read(2) ~= nil)

-- 故障钩子
m = section()
dev:fail_write(function(fr) return fr[1] == 0xFE end)
check("fail_write MID 谓词", dev.write({ 0xFE }) == false)
check("fail_write 他帧放行", dev.write({ 0xFF }) ~= false)
check("谓词拒收不计数", dev:write_count() == 1, tostring(dev:write_count()))
dev:fail_write(nil)
dev:set_raw(1, 2); dev:virt_tick(0)
dev:fail_read(function(p, n) return p == 0x01 and n == 2 end)
i2c_write_multi(fd, 0x00)
check("fail_read 按 (ptr,n) 谓词：T 放行", dev.read(2) ~= nil)
i2c_write_multi(fd, 0x01)
check("fail_read H 拦截", dev.read(2) == nil)
check("读 NACK 指针不前进（仍 0x01）", dev:ptr() == 0x01)
dev:fail_read(nil)
dev.nack_write = true
check("nack_write", dev.write({ 0x00 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read", dev.read(2) == nil)
dev.nack_read = false
dev.nack = true
check("nack 全拦写/读", dev.write({ 0x02 }) == false and dev.read(2) == nil)
dev.nack = false
check("reset 保留故障钩子", (function()
	dev:fail_write(function(fr) return fr[1] == 0xFE end)
	dev:reset()
	return dev.write({ 0xFE }) == false
end)())
dev:clear_faults()
check("clear_faults 后放行", dev.write({ 0xFE }) ~= false)
local cl = dev:write_count()
dev:reset_logs()
check("reset_logs 清计数", dev:write_count() == 0 and cl > 0)

-- who() 身份覆写：喂 build 负路径；软复位不恢复 ROM（覆写是外部故障）
section()
dev:who(0x1234, nil)
check("who 覆写 MID", dev:mid() == 0x1234)
dev:who(nil, 0x4321)
check("who 覆写 DID（MID 保持）", dev:did() == 0x4321 and dev:mid() == 0x1234)
i2c_write_multi(fd, 0x02, 0x80)
check("软复位后覆写仍在（ROM 损坏不会被复位修复）", dev:mid() == 0x1234 and dev:did() == 0x4321)

-- 种子构造
local s = smod.new({ temp = 0x6666, humi = 0x9999, config = 0x2000, alert = 0x1234,
                     mid = 0x1111, did = 0x2222 })
check("种子 T/H", s:temp_raw() == 0x6666 and s:humi_raw() == 0x9999)
check("种子测量置就绪", s:is_ready(0x00) and s:is_ready(0x01))
check("种子 config/alert", s:config() == 0x2000 and s:alert() == 0x1234)
check("种子 mid/did", s:mid() == 0x1111 and s:did() == 0x2222)
check("坏种子 config=0x8000 回 POR", smod.new({ config = 0x8000 }):config() == 0)
check("坏种子 temp 超程回 POR", smod.new({ temp = 70000 }):temp_raw() == nil)
check("坏种子 humi 字符串回 POR", smod.new({ humi = "x" }):humi_raw() == nil)
check("坏种子 alert 负回 POR", smod.new({ alert = -1 }):alert() == 0)
check("空种子等同 POR", smod.new({}):config() == 0 and smod.new({}):mid() == 0x5959)

-- =====================================================================
-- 组 2：真实 build（软复位 + MID/DID 双 ID 自检，sleep 10ms）
-- =====================================================================
local function do_build(args) return build(args or ARGS) end

local bm = section()
expect_ok("build 标准（复位+双 ID）", do_build)
local be = entries(bm)
check("build 共 6 事务", #be == 6, tostring(#be))
check("build 事务序 set/w{02,80}/w{FE}/r/w{FF}/r",
	be[1].dir == "set" and be[1].addr == 0x40 and
	be[2].dir == "w" and #be[2].bytes == 2 and be[2].bytes[1] == 0x02 and be[2].bytes[2] == 0x80 and
	be[3].dir == "w" and #be[3].bytes == 1 and be[3].bytes[1] == 0xFE and
	be[4].dir == "r" and be[4].bytes.n == 2 and
	be[5].dir == "w" and #be[5].bytes == 1 and be[5].bytes[1] == 0xFF and
	be[6].dir == "r" and be[6].bytes.n == 2)
check("build 复位写恰 2 字节（无 LSB 帧长哨兵）",
	#(entries(bm)[2].bytes) == 2)
check("build 睡眠 10ms", sleep_total == 10, tostring(sleep_total))
check("build 后 reset_count=1", dev:reset_count() == 1)
check("build 后 config 回 0", dev:config() == 0)
check("build 后读 MID 仍 0x5959", dev:mid() == 0x5959)

-- MID 错
bm = section(); dev:who(0x1234, nil)
expect_err("build MID 错", do_build, "manufacturer id")
check("MID 错短路 4 事务（set+复位写+FE+读）", #entries(bm) == 4, tostring(#entries(bm)))
-- DID 错
bm = section(); dev:who(nil, 0x1234)
expect_err("build DID 错", do_build, "device id")
check("DID 错读了两次 ID：6 事务", #entries(bm) == 6, tostring(#entries(bm)))

-- 复位写 NACK
bm = section()
dev:fail_write(function(fr) return fr[1] == 0x02 and #fr == 2 and fr[2] == 0x80 end)
expect_err("build 软复位写 NACK", do_build, "soft reset failed")
check("复位写失败仅 2 事务", #entries(bm) == 2, tostring(#entries(bm)))
-- MID 指针写 NACK
bm = section()
dev:fail_write(function(fr) return #fr == 1 and fr[1] == 0xFE end)
expect_err("build MID 指针写 NACK", do_build, "pointer write failed")
check("MID 指针失败 3 事务", #entries(bm) == 3, tostring(#entries(bm)))
-- MID 读 NACK
bm = section()
dev:fail_read(function(p) return p == 0xFE end)
expect_err("build MID 读 NACK", do_build, "read manufacturer id failed")
check("MID 读失败 4 事务", #entries(bm) == 4, tostring(#entries(bm)))
-- DID 指针写 NACK
bm = section()
dev:fail_write(function(fr) return #fr == 1 and fr[1] == 0xFF end)
expect_err("build DID 指针写 NACK", do_build, "pointer write failed")
check("DID 指针失败 5 事务", #entries(bm) == 5, tostring(#entries(bm)))
-- DID 读 NACK
bm = section()
dev:fail_read(function(p) return p == 0xFF end)
expect_err("build DID 读 NACK", do_build, "read device id failed")
check("DID 读失败 6 事务", #entries(bm) == 6, tostring(#entries(bm)))
-- nack_write：首笔复位写即败
bm = section(); dev.nack_write = true
expect_err("build nack_write 复位失败", do_build, "not responding")
check("nack_write 2 事务", #entries(bm) == 2)
dev.nack_write = false
-- nack_read：MID 读失败
bm = section(); dev.nack_read = true
expect_err("build nack_read MID 失败", do_build, "not responding")
check("nack_read 4 事务", #entries(bm) == 4)
dev.nack_read = false

-- 参数负路径
bm = section()
expect_err("build 非表", function() return build(4) end, "Invalid Arguments Type")
check("非表零事务", #entries(bm) == 0)
bm = section()
expect_err("build 缺 fd", function() return build({ address = "0x40" }) end, "fd or address")
check("缺 fd 零事务", #entries(bm) == 0)
bm = section()
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("缺 address 零事务", #entries(bm) == 0)
bm = section()
expect_err("build fd=99（未打开）", function() return build({ fd = 99, address = "0x40" }) end, "set_addr failed")
check("fd=99 set 在留痕前失败：0 事务", #entries(bm) == 0, tostring(#entries(bm)))
bm = section()
expect_err("build 错地址 0x60（无挂载）", function() return build({ fd = fd, address = "0x60" }) end, "soft reset failed")
check("错地址 set 留痕 + 复位写 NACK：2 事务", #entries(bm) == 2, tostring(#entries(bm)))
check("错地址记录 addr=0x60", entries(bm)[1].addr == 0x60)

-- =====================================================================
-- 组 3：真实 call（温/湿各「指针写 + 14ms 转换 + 纯读」，共 5 事务）
-- =====================================================================
-- 标准 call：tick 装码预武装（sleep 桩同时 advance，双重保险）
section()
expect_ok("call 前 build", do_build)
dev:virt_tick(0)
local cm = window()
local r0 = call(ARGS)
expect_ok("call 标准", function() return r0 end)
local ce = entries(cm)
check("call 共 5 事务", #ce == 5, tostring(#ce))
check("call 事务序 set/w{00}/r/w{01}/r",
	ce[1].dir == "set" and
	ce[2].dir == "w" and #ce[2].bytes == 1 and ce[2].bytes[1] == 0x00 and
	ce[3].dir == "r" and ce[3].bytes.n == 2 and
	ce[4].dir == "w" and #ce[4].bytes == 1 and ce[4].bytes[1] == 0x01 and
	ce[5].dir == "r" and ce[5].bytes.n == 2)
check("call 睡眠 28ms（2×14）", sleep_total == 10 + 28, tostring(sleep_total))
check("call T 与独立公式一致", near(r0.T, ref_t(t0), 1e-6),
	string.format("%s vs %s", tostring(r0.T), tostring(ref_t(t0))))
check("call H 与独立公式一致", near(r0.H, ref_h(h0)), 1e-6,
	string.format("%s vs %s", tostring(r0.H), tostring(ref_h(h0))))

-- 边界码：0 → -40°C/0%，0xFFFF → 125°C/100%（不武装，靠 sleep 桩 advance 过门）
section(); expect_ok("build（边界 0）", do_build)
dev:set_raw(0x0000, 0x0000)
local rlo = call(ARGS)
check("零码 T=-40.0", near(rlo.T, -40.0), tostring(rlo.T))
check("零码 H=0.0", near(rlo.H, 0.0), tostring(rlo.H))
section(); expect_ok("build（边界 FFFF）", do_build)
dev:set_raw(0xFFFF, 0xFFFF)
local rhi = call(ARGS)
check("满码 T=125.0", near(rhi.T, 125.0), tostring(rhi.T))
check("满码 H=100.0", near(rhi.H, 100.0), tostring(rhi.H))
-- 典型码
section(); expect_ok("build（典型码）", do_build)
dev:set_raw(0x6666, 0x9999)
local rmid = call(ARGS)
check("典型 T 交叉", near(rmid.T, ref_t(0x6666), 1e-9), tostring(rmid.T))
check("典型 H 交叉", near(rmid.H, ref_h(0x9999), 1e-9), tostring(rmid.H))
-- 无 tick：门靠驱动真实睡眠（桩 advance）推进，POR 测量码 nil 读 0
section(); expect_ok("build（无 tick）", do_build)
local rpor = call(ARGS)
check("无 tick 门经 sleep 推进也成功（T=-40/H=0）",
	near(rpor.T, -40.0) and near(rpor.H, 0.0), tostring(rpor.T))

-- 无未 build 守卫：reload 驱动重建模块后直接 call（区别 LTC2944）
section()
vbus.load_driver("modules/CHT8305.lua")
local cm2 = window()
dev:set_raw(0x1234, 0x2345)
local rnb = call(ARGS)
check("call 无未 build 守卫（直接 OK）", rnb and rnb.result == "OK", tostring(rnb and rnb.message))
check("裸 call 同样 5 事务", #entries(cm2) == 5, tostring(#entries(cm2)))
vbus.load_driver("modules/CHT8305.lua")	-- 恢复（后续用例先 build）

-- 温度指针写失败
section(); expect_ok("build（T 指针失败）", do_build)
dev:fail_write(function(fr) return #fr == 1 and fr[1] == 0x00 end)
cm = window()
expect_err("call T 指针写 NACK", function() return call(ARGS) end, "temp pointer write failed")
check("T 指针失败 2 事务、0 睡眠", #entries(cm) == 2 and sleep_total == 10,
	string.format("%d/%d", #entries(cm), sleep_total))
dev:fail_write(nil)
-- 温度读失败（never_ready：14ms 推进无效）
section(); expect_ok("build（T 读失败）", do_build)
dev:set_never_ready(true)
cm = window()
expect_err("call T 读 NACK", function() return call(ARGS) end, "read temperature failed")
check("T 读失败 3 事务、睡 14ms", #entries(cm) == 3 and sleep_total == 10 + 14,
	string.format("%d/%d", #entries(cm), sleep_total))
dev:set_never_ready(false)
-- 湿度指针写失败（T 已成功）
section(); expect_ok("build（H 指针失败）", do_build)
dev:virt_tick(0)
dev:fail_write(function(fr) return #fr == 1 and fr[1] == 0x01 end)
cm = window()
expect_err("call H 指针写 NACK", function() return call(ARGS) end, "humi pointer write failed")
check("H 指针失败 4 事务、睡 14ms", #entries(cm) == 4 and sleep_total == 10 + 14,
	string.format("%d/%d", #entries(cm), sleep_total))
dev:fail_write(nil)
-- 湿度读失败（定向谓词只拦 ptr=01，T 过门）
section(); expect_ok("build（H 读失败）", do_build)
dev:fail_read(function(p) return p == 0x01 end)
cm = window()
expect_err("call H 读 NACK", function() return call(ARGS) end, "read humidity failed")
check("H 读失败 5 事务、睡 28ms", #entries(cm) == 5 and sleep_total == 10 + 28,
	string.format("%d/%d", #entries(cm), sleep_total))
dev:fail_read(nil)
-- nack_write/nack_read
section(); expect_ok("build（call nack_write）", do_build)
dev.nack_write = true
cm = window()
expect_err("call nack_write 温度失败", function() return call(ARGS) end, "not responding")
check("nack_write 2 事务", #entries(cm) == 2)
dev.nack_write = false
section(); expect_ok("build（call nack_read）", do_build)
dev.nack_read = true
cm = window()
expect_err("call nack_read 温度失败", function() return call(ARGS) end, "not responding")
check("nack_read 3 事务", #entries(cm) == 3)
dev.nack_read = false

-- call 参数负路径
cm = section()
expect_err("call 非表", function() return call(6) end, "Invalid Arguments")
check("call 非表零事务", #entries(cm) == 0)
cm = section()
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
check("call 缺 address 零事务", #entries(cm) == 0)
cm = section()
expect_err("call fd=99", function() return call({ fd = 99, address = "0x40" }) end, "set_addr failed")
check("call fd=99 零事务", #entries(cm) == 0)
cm = section()
expect_err("call 错地址 0x60", function() return call({ fd = fd, address = "0x60" }) end, "temp pointer write failed")
check("call 错地址 2 事务", #entries(cm) == 2)

-- =====================================================================
-- 组 4：destroy（只校验参数表，零总线事务）
-- =====================================================================
local dm = section()
expect_ok("destroy OK", function() return destroy(ARGS) end)
check("destroy 零总线事务", #entries(dm) == 0, tostring(#entries(dm)))
dm = section()
expect_ok("destroy 空表也 OK", function() return destroy({}) end)
check("空表零事务", #entries(dm) == 0)
dm = section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("destroy 非表零事务", #entries(dm) == 0)

tester.summary()

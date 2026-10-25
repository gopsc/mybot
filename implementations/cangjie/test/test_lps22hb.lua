-- test_lps22hb.lua —— LPS22HB 真实驱动 + 虚拟 I2C 总线 + regmap 气压计模型
-- 用法（项目根目录）: luajit test/test_lps22hb.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：LPS_GC=1 luajit test/test_lps22hb.lua
--
-- 从「dofile 驱动后覆盖 i2c_* 全局的 210 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/lps22hb.lua 模型」。LPS22HB 是【8 位寄存器指针 +
-- 5 字节小端 burst + 地址 bit7 自动增量 + 三个自清零命令位 + 单次转换门】
-- 气压计（regmap 包装族，旧桩只建了 3 个寄存器，无增量位/无 STATUS/无连续
-- 模式/无 BOOT，本测逐一补齐）：
--   0x0F WHO_AM_I=0xB1（0xBD=LPS25HB 代际拦截）；0x10 CTRL_REG1 build 写 0x02
--   （BDU+ODR=000 单次）；0x11 CTRL_REG2 bit7 BOOT/bit4 FIFO_EN/bit3 IF_ADD_INC/
--   bit2 SWRESET/bit0 ONE_SHOT（后三者自清）；0x27 STATUS P_DA/T_DA 动态合成
--   读 MSB 清除；0x28~0x2C 气压 24 位 + 温度 16 位小端补码，burst 指针 0xA8
--   =0x28|0x80（bit7=自动增量；无位且 IF_ADD_INC=0 时连读重复同一寄存器）。
--
-- 覆盖：模型侧 POR/24·16 位小端编解码独立交叉/5B burst 字节序与指针落点/
-- bit7 与 IF_ADD_INC 两种增量路径/0x7F 回绕/无增量重复读/只读区写 ACK 丢弃/
-- 坏帧 NACK/三自清位（BOOT 即时、SWRESET 2ms 门、ONE_SHOT 3ms 门）/RMW 保
-- IF_ADD_INC/连续模式 ONE_SHOT 无效/ODR 五档周期与保留码/STATUS DA 置位与
-- MSB 读清除/s24·s16 钳制与量化/virt_tick 32 拍正弦 n0·8·24·32/never_ready/
-- 武装一次性与跨复位保留/六类钩子/reset 留钩保身份保 pending；真实 build
-- 门路径 11 txlog 睡 2ms、预武装 7 txlog 零睡眠、复位轮询耗尽 20ms 不致命、
-- 错 ID/读写失败精确短路与文案；真实 call 门路径 14 txlog 睡 3ms、预武装
-- 8 txlog 零睡眠、s24/s16 六组补码换算极值、virt_tick 三拍闭环、wait 超时
-- （50/3/-5）与五类读写失败短路；destroy 零事务。

if os.getenv("LPS_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local lmod = dofile("modules/lib/virtbus/lps22hb.lua")
vbus.reset()

local ADDR = 0x5D
local dev = lmod.new()
vbus.attach("LPS22HB@0x5D", ADDR, dev)
vbus.attach("LPS22HB@0x5C", 0x5C, dev)	-- 同一模型挂备地址
vbus.load_driver("modules/LPS22HB.lua")

-- milli_sleep 桩：累计睡眠量同时推进器件虚拟时钟（SWRESET/ONE_SHOT 门）
local sleep_total = 0
function milli_sleep(ms)
	sleep_total = sleep_total + ms
	dev:advance(ms)
end

-- 读值捕获：txlog 的 r 条目只记 {n=N} 不含读回字节，包一层 dev.read 留值
-- （attach 包装器按名动态取 dev.read，替换后即时生效；点回调无 self）
local rcap = {}
do
	local real_read = dev.read
	dev.read = function(n)
		local bb = real_read(n)
		rcap[#rcap + 1] = bb
		return bb
	end
end
local function rcap_reset() rcap = {} end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件回 POR + 故障解除 + who 身份显式恢复（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	dev:who(0xB1)
	sleep_total = 0
	rcap_reset()
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
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
local function data_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b >= 2 then t[#t + 1] = { reg = b[1], val = b[2], n = #b } end
	end
	return t
end

-- 脱驱动点回调读：写指针后读 n 字节
local function rb_n(ptr, n)
	dev.write({ ptr })
	return dev.read(n)
end
local function rb(ptr) return rb_n(ptr, 1)[1] end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("POR WHO_AM_I=0xB1", dev:devid() == 0xB1, string.format("0x%02X", dev:devid()))
check("POR CTRL_REG1=0x00", dev:ctrl1() == 0x00, string.format("0x%02X", dev:ctrl1()))
check("POR CTRL_REG2 动态读 0x00", dev:ctrl2_dynamic() == 0x00,
      string.format("0x%02X", dev:ctrl2_dynamic()))
check("POR STATUS=0x00（无新数据）", dev:status() == 0x00,
      string.format("0x%02X", dev:status()))
check("POR 气压 24 位=0", dev:press_raw() == 0, tostring(dev:press_raw()))
check("POR 温度 16 位=0", dev:temp_raw() == 0, tostring(dev:temp_raw()))
check("POR ptr=0", dev:pointer() == 0, tostring(dev:pointer()))
check("POR 非复位/非转换忙", not dev:resetting() and not dev:busy())
check("POR 模式 idle/ODR 码 0", dev:mode_name() == "idle" and dev:odr() == 0)
check("未播种寄存器读 0（0x12 RES_CONF）", rb(0x12) == 0, tostring(rb(0x12)))

-- 24 位小端编解码：独立公式交叉（不与驱动共用理解）
local le24 = {
	{ 0x000000, 0x00, 0x00, 0x00 }, { 0x000001, 0x01, 0x00, 0x00 },
	{ 0x000100, 0x00, 0x01, 0x00 }, { 0x010000, 0x00, 0x00, 0x01 },
	{ 0x123456, 0x56, 0x34, 0x12 }, { 0x7FFFFF, 0xFF, 0xFF, 0x7F },
	{ 0x800000, 0x00, 0x00, 0x80 }, { 0xFFFFFF, 0xFF, 0xFF, 0xFF },
	{ 0xFFF000, 0x00, 0xF0, 0xFF },
}
for _, c in ipairs(le24) do
	dev:set_word24_le(0x28, c[1])
	check(string.format("24 位小端 0x%06X → XL/L/H=%02X %02X %02X",
	      c[1], c[2], c[3], c[4]),
	      dev.regs[0x28] == c[2] and dev.regs[0x29] == c[3] and dev.regs[0x2A] == c[4],
	      string.format("%02X %02X %02X", dev.regs[0x28], dev.regs[0x29], dev.regs[0x2A]))
	check(string.format("24 位小端 0x%06X 有符号回读", c[1]),
	      dev:press_raw() == (c[1] >= 0x800000 and c[1] - 0x1000000 or c[1]))
end

-- 16 位小端温度编解码
local le16 = {
	{ 0x0000, 0x00, 0x00 }, { 0x00FF, 0xFF, 0x00 }, { 0xFF00, 0x00, 0xFF },
	{ 0x1234, 0x34, 0x12 }, { 0x7FFF, 0xFF, 0x7F }, { 0x8000, 0x00, 0x80 },
	{ 0xFF9C, 0x9C, 0xFF },
}
for _, c in ipairs(le16) do
	dev:set_word_le(0x2B, c[1])
	check(string.format("16 位小端 0x%04X → L/H=%02X %02X", c[1], c[2], c[3]),
	      dev.regs[0x2B] == c[2] and dev.regs[0x2C] == c[3],
	      string.format("%02X %02X", dev.regs[0x2B], dev.regs[0x2C]))
	check(string.format("16 位小端 0x%04X 有符号回读", c[1]),
	      dev:temp_raw() == (c[1] >= 0x8000 and c[1] - 0x10000 or c[1]))
end

-- 5B burst：指针 0xA8（bit7=增量）读出 XL,L,H,TL,TH，指针落 0x2D
dev:set_press_raw(4149248):set_temp_raw(2345)
local b = rb_n(0xA8, 5)
check("burst 5B 字节序 00 50 3F 29 09（1013hPa=0x3F5000/23.45°C）",
      b[1] == 0x00 and b[2] == 0x50 and b[3] == 0x3F and b[4] == 0x29 and b[5] == 0x09,
      string.format("%02X %02X %02X %02X %02X", b[1], b[2], b[3], b[4], b[5]))
check("burst 后指针落 0x2D", dev:pointer() == 0x2D, string.format("0x%02X", dev:pointer()))

-- 无增量：纯 0x28 指针连读重复 XL（POR IF_ADD_INC=0）
local x = rb_n(0x28, 3)
check("bit7=0 且 IF_ADD_INC=0：连读重复同一寄存器",
      x[1] == x[2] and x[2] == x[3] and x[1] == 0x00)
check("无增量读后指针停 0x28", dev:pointer() == 0x28,
      string.format("0x%02X", dev:pointer()))

-- 全局 IF_ADD_INC：置位后纯 0x28 指针连读也自增
check("写 CTRL_REG2 IF_ADD_INC=0x08", dev.write({ 0x11, 0x08 }) and dev:if_add_inc() == 1)
local y = rb_n(0x28, 3)
check("IF_ADD_INC=1：纯指针 0x28 连读 0x28/0x29/0x2A",
      y[1] == 0x00 and y[2] == 0x50 and y[3] == 0x3F,
      string.format("%02X %02X %02X", y[1], y[2], y[3]))
check("写 CTRL_REG2 清 IF_ADD_INC", dev.write({ 0x11, 0x00 }) and dev:if_add_inc() == 0)

-- 增量读到 0x7F 后按 7 位地址空间算术回绕 0x00（指针 0xFE=0x7E|0x80）
rb_n(0xFE, 4)
check("burst 0xFE(=0x7E|0x80) 4B 回绕后 ptr 落 0x02",
      dev:pointer() == 0x02, string.format("ptr=0x%02X", dev:pointer()))

-- 纯指针写任意地址 ACK（含只读/保留区）
for _, p in ipairs({ 0x0F, 0x27, 0x2A, 0x2C, 0x7F }) do
	check(string.format("纯指针写 0x%02X ACK", p), dev.write({ p }) == true)
end

-- 只读区 >=2B 写：ACK 但数据丢弃
check("WHO_AM_I 2B 写 ACK 但丢弃", dev.write({ 0x0F, 0xBD }) and dev:devid() == 0xB1)
check("STATUS 2B 写 ACK 但丢弃", dev.write({ 0x27, 0x03 }) and dev:status() == 0)
check("输出区 5B 写 ACK 但丢弃",
      dev.write({ 0x28, 0x11, 0x22, 0x33, 0x44, 0x55 })
      and dev.regs[0x28] == 0x00 and dev.regs[0x2C] == 0x09)

-- 坏帧 NACK
check("非 table 写 NACK", dev.write("xx") == false)
check("空表写 NACK", dev.write({}) == false)
check("nil 写 NACK", dev.write(nil) == false)
check("坏帧不留配置写痕", dev:write_count() == 5)	-- 08/00/0FBD/2703/28×5

-- CTRL_REG2 落盘位观察（仅 FIFO_EN/IF_ADD_INC）
dev.write({ 0x11, 0x10 })
check("FIFO_EN 落盘读 0x10", dev:ctrl2_dynamic() == 0x10,
      string.format("0x%02X", dev:ctrl2_dynamic()))
check("fifo_en 观察口=1", dev:fifo_en() == 1)
dev.write({ 0x11, 0x62 })	-- bit6/5 保留 + bit1 保留，无一落盘
check("保留位不落盘（0x62→读 0x00）", dev:ctrl2_dynamic() == 0x00,
      string.format("0x%02X", dev:ctrl2_dynamic()))

-- BOOT：即时自清，只计数
dev.write({ 0x11, 0x90 })	-- BOOT + FIFO_EN
check("BOOT 即时自清、FIFO_EN 保留（读 0x10）", dev:ctrl2_dynamic() == 0x10,
      string.format("0x%02X", dev:ctrl2_dynamic()))
check("BOOT 计数=1", dev:boot_count() == 1, tostring(dev:boot_count()))
dev.write({ 0x11, 0x80 })
check("纯 BOOT 后读 0x00、计数=2", dev:ctrl2_dynamic() == 0x00 and dev:boot_count() == 2)

-- SWRESET：2ms 门（读回 bit2=1 至结束），结束全寄存器回 POR
dev:set_press_raw(4149248):set_temp_raw(2345)
dev.write({ 0x10, 0x02 })
dev.write({ 0x11, 0x08 })	-- IF_ADD_INC 配置位
check("SWRESET 写 ACK", dev.write({ 0x11, 0x04 }) == true)
check("复位中读 bit2=1", dev:resetting() and rb(0x11) == 0x04,
      string.format("0x%02X", rb(0x11)))
dev:advance(1)
check("1ms 仍在复位", rb(0x11) == 0x04)
dev:advance(1)
check("2ms 复位结束 bit2=0", not dev:resetting() and rb(0x11) == 0x00)
check("SWRESET 后 CTRL_REG1 回 0", dev:ctrl1() == 0)
check("SWRESET 后 IF_ADD_INC 回 0", dev:if_add_inc() == 0)
check("SWRESET 后输出区清 0/STATUS=0",
      dev:press_raw() == 0 and dev:temp_raw() == 0 and dev:status() == 0)
-- pending 注入是测试侧资产：SWRESET 不清；武装 ONE_SHOT 后样本重新装载
dev:arm()
dev.write({ 0x11, 0x01 })
check("SWRESET 不清 pending（武装 ONE_SHOT 重装 4149248/2345、双 DA）",
      dev:press_raw() == 4149248 and dev:temp_raw() == 2345 and dev:status() == 3,
      string.format("%d/%d st=%d", dev:press_raw(), dev:temp_raw(), dev:status()))
check("ONE_SHOT 武装一次性消费", not dev:armed_state())
-- SWRESET 本身的预武装：重新 arm，复位即时完成且不消费武装
dev:arm()
check("SWRESET 预武装即时完成", (function()
	dev.write({ 0x11, 0x04 })
	return not dev:resetting() and rb(0x11) == 0x00
end)())
check("SWRESET 不消费武装（后续 ONE_SHOT 仍即时）", dev:armed_state() == true)

-- ONE_SHOT：3ms 门，完成装载样本并置双 DA；RMW 保 IF_ADD_INC
mark = #vbus.txlog
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_press_raw(4149248):set_temp_raw(2345)
dev.write({ 0x11, 0x08 })					-- 先配 IF_ADD_INC
check("ONE_SHOT RMW 帧 0x09 写 ACK", dev.write({ 0x11, 0x09 }) == true)
check("转换中动态读 0x09（IF_INC+ONE_SHOT）", dev:busy() and rb(0x11) == 0x09,
      string.format("0x%02X", rb(0x11)))
dev:advance(2)
check("2ms 转换未完成", rb(0x11) == 0x09 and dev:busy())
dev:advance(1)
check("3ms 转换完成 ONE_SHOT 自清（读 0x08）", not dev:busy() and rb(0x11) == 0x08,
      string.format("0x%02X", rb(0x11)))
check("完成后 STATUS P_DA|T_DA=0x03", dev:status() == 0x03,
      string.format("0x%02X", dev:status()))
check("完成后样本已装载", dev:press_raw() == 4149248 and dev:temp_raw() == 2345)
-- DA 的 MSB 读清除语义
rb(0x29)
check("读 PRESS_OUT_L 不清 DA", dev:status() == 0x03)
rb(0x2A)
check("读 PRESS_OUT_H 只清 P_DA（剩 T_DA=0x02）", dev:status() == 0x02,
      string.format("0x%02X", dev:status()))
rb(0x2B)
check("读 TEMP_OUT_L 不清 T_DA", dev:status() == 0x02)
rb(0x2C)
check("读 TEMP_OUT_H 清 T_DA（STATUS=0）", dev:status() == 0)

-- 连续模式：ODR!=0 时 ONE_SHOT 无效；advance 按周期出样
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_press_raw(1066496):set_temp_raw(-100)	-- -100 有符号码（补码 0xFF9C）
dev.write({ 0x10, 0x20 })	-- ODR 码 2=10Hz
check("ODR10Hz 模式 cont/10Hz", dev:mode_name() == "cont" and dev:odr_hz() == 10)
check("连续模式写 ONE_SHOT 自清无效（不忙）",
      dev.write({ 0x11, 0x01 }) and not dev:busy() and rb(0x11) == 0x00)
dev:advance(99)
check("99ms 未到周期无新样", dev:status() == 0)
dev:advance(1)
check("再 1ms（满 100ms）出新样 DA=3", dev:status() == 3)
rb(0x2A); rb(0x2C)
dev:advance(250)
check("250ms 内再产 2 拍（100/200ms 点）", dev:status() == 3)
dev.write({ 0x10, 0x00 })
rb(0x2A); rb(0x2C)
dev:advance(500)
check("回 ODR=000 进 idle、advance 不再产样",
      dev:mode_name() == "idle" and dev:status() == 0)

-- ODR 五档周期/保留码/位域观察
local odr_cases = {
	{ 0x10, 1, 1000 }, { 0x20, 2, 100 }, { 0x30, 3, 40 },
	{ 0x40, 4, 20 }, { 0x50, 5, 40 / 3 },
}
for _, c in ipairs(odr_cases) do
	dev.write({ 0x10, c[1] })
	local hz = dev:odr_hz()
	check(string.format("ODR 码 %d → %sHz（周期 %.3fms）",
	      c[2], tostring(hz), c[3]), hz ~= nil and near(hz, 1000 / c[3], 1e-9))
end
dev.write({ 0x10, 0x60 })
check("ODR 码 6 保留 odr_hz=nil", dev:odr_hz() == nil)
dev.write({ 0x10, 0x70 })
check("ODR 码 7 保留 odr_hz=nil", dev:odr_hz() == nil)
dev.write({ 0x10, 0xFF })
check("CTRL_REG1=0xFF 位域：BDU/EN_LPFP/LPFP_CFG/SIM 全 1",
      dev:bdu() == 1 and dev:lpf_en() == 1 and dev:lpf_cfg() == 1
      and (dev:ctrl1() % 2) == 1)

-- 75Hz 周期边界（13.333ms：13ms 无、14ms 有）
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_press_raw(4149248):set_temp_raw(2345)
dev.write({ 0x10, 0x50 })
dev:advance(13)
check("75Hz：13ms 未产样", dev:status() == 0)
dev:advance(1)
check("75Hz：再 1ms（14ms）产样", dev:status() == 3)

-- s24/s16 钳制与物理量量化
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_press_raw(99999999)
check("气压正超程钳 +8388607", dev:press_raw() == 8388607, tostring(dev:press_raw()))
dev:set_press_raw(-99999999)
check("气压负超程钳 -8388608", dev:press_raw() == -8388608, tostring(dev:press_raw()))
dev:set_temp_raw(99999)
check("温度正超程钳 +32767", dev:temp_raw() == 32767, tostring(dev:temp_raw()))
dev:set_temp_raw(-99999)
check("温度负超程钳 -32768", dev:temp_raw() == -32768, tostring(dev:temp_raw()))
dev:set_press_hpa(1013.0)
check("set_press_hpa(1013.0)=码 4149248", dev:press_raw() == 4149248,
      tostring(dev:press_raw()))
check("press_hpa 回读 1013.0（量化粒度 1/4096）", near(dev:press_hpa(), 1013.0, 0.00025),
      tostring(dev:press_hpa()))
dev:set_temp_c(23.45)
check("set_temp_c(23.45)=码 2345", dev:temp_raw() == 2345, tostring(dev:temp_raw()))
check("temp_c 回读 23.45（量化粒度 0.01）", near(dev:temp_c(), 23.45, 0.005),
      tostring(dev:temp_c()))
dev:set_press_hpa(1000)
check("nil 轴保持：只改气压温度不动", dev:temp_raw() == 2345)

-- virt_tick 32 拍确定性正弦
local tick_pts = {
	{ 0, 1013.25, 22.0 }, { 8, 1018.25, 24.0 }, { 24, 1008.25, 20.0 },
}
for _, p in ipairs(tick_pts) do
	dev:virt_tick(p[1])
	check(string.format("virt_tick n=%d P=%.2fhPa T=%.1f°C", p[1], p[2], p[3]),
	      near(dev:press_hpa(), p[2], 0.00025) and near(dev:temp_c(), p[3], 0.005)
	      and dev:status() == 3 and dev:armed_state(),
	      string.format("P=%.4f T=%.2f st=%d", dev:press_hpa(), dev:temp_c(), dev:status()))
end
dev:virt_tick(32)
check("virt_tick n=32 同 n=0", near(dev:press_hpa(), 1013.25, 0.00025))
check("virt_tick 气压全程在量程内（1008.25~1018.25hPa）",
      dev:press_hpa() > 1000 and dev:press_hpa() < 1020)

-- never_ready：门不完成、武装无效、连续不出样
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_never_ready(true)
dev:virt_tick(0)
dev.write({ 0x11, 0x04 })
check("never_ready 下 SWRESET 武装也无效（保持复位中）", dev:resetting())
dev:advance(100)
check("never_ready 下 advance 不结束复位", dev:resetting())
dev:set_never_ready(false)
dev:advance(100)
check("解除后 advance 立即结束复位", not dev:resetting())

-- 武装一次性消费
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev:set_press_raw(4149248):set_temp_raw(2345)
dev:arm()
dev.write({ 0x11, 0x01 })
check("武装 ONE_SHOT 即时完成", not dev:busy() and dev:status() == 3)
check("武装一次性消费", not dev:armed_state())
dev.write({ 0x11, 0x01 })
check("消费后再触发须走门（忙）", dev:busy())

-- 六类故障钩子
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev.nack = true
check("nack 写失败", dev.write({ 0x11, 0x04 }) == false)
check("nack 读失败", rb_n(0x0F, 1) == nil)
dev.nack = false
dev.write({ 0x0F })	-- 先落读指针（nack_write 开启后指针写也会 NACK）
dev.nack_write = true
check("nack_write：写失败", dev.write({ 0x10, 0x02 }) == false)
local nr = dev.read(1)
check("nack_write：读回调不受影响（指针在 0x0F 读出 0xB1）",
      nr ~= nil and nr[1] == 0xB1, tostring(nr and nr[1]))
dev.nack_write = false
dev.nack_read = true
check("nack_read：读失败", rb_n(0x0F, 1) == nil)
check("nack_read：写仍正常", dev.write({ 0x10, 0x02 }))
dev.nack_read = false
dev:fail_write(function(b) return b[1] == 0x10 and #b >= 2 end)
check("fail_write 谓词拦 CTRL_REG1 写", dev.write({ 0x10, 0x02 }) == false)
check("fail_write 谓词放行 CTRL_REG2 写", dev.write({ 0x11, 0x04 }) == true)
dev:clear_faults()
dev:fail_read(function(ptr, n) return n == 5 end)
check("fail_read 按长度谓词拦 5B burst", rb_n(0xA8, 5) == nil)
check("fail_read 谓词放行 1B 读", rb(0x0F) == 0xB1)
dev:clear_faults()

-- reset 语义：回 POR、留 who/钩子、清武装/never、pending 保留
dev:who(0xBD)
dev:fail_read(function() return true end)
dev:set_never_ready(true)
dev:set_press_raw(123456)
dev:reset()
check("reset 保留 who 覆写", dev:devid() == 0xBD)
check("reset 保留 read_pred 钩子", rb_n(0x0F, 1) == nil)
check("reset 清 never_ready", not dev:never_ready_state())
check("reset 清武装", not dev:armed_state())
dev:clear_faults(); dev:arm(); dev.write({ 0x11, 0x01 })
check("reset 保留 pending 注入（下次转换装载）", dev:press_raw() == 123456)

-- 留痕观察口
dev:reset(); dev:clear_faults(); dev:who(0xB1)
dev.write({ 0x0F })
dev.write({ 0x11, 0x04 })
check("write_count 只计 >=2B 配置写", dev:write_count() == 1)
local cw = dev:config_writes()
check("config_writes 记录 {0x11,0x04}",
      #cw == 1 and cw[1].reg == 0x11 and cw[1].val == 0x04)
dev:reset_logs()
check("reset_logs 清空留痕", dev:write_count() == 0)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================

-- 门路径（无武装）：11 txlog、2 次 1ms 轮询、配置字序列
mark = section()
local bm0 = sleep_total
expect_ok("build 门路径（复位轮询 2ms）", function()
	return build({ fd = fd, address = "0x5D" })
end)
local be = entries(mark)
check("build 门路径 11 txlog", #be == 11, tostring(#be))
check("build 门路径实睡 2ms", sleep_total - bm0 == 2, tostring(sleep_total - bm0))
check("build 首笔 set 0x5D", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x5D)
check("build 纯指针写序列 0F 11 11 11（ID+3 轮询；两笔配置写见 data_writes）",
      table.concat(ptr_writes(mark), ",") == "15,17,17,17",
      table.concat(ptr_writes(mark), ","))
local bd = data_writes(mark)
check("build 配置写两笔 {0x11,0x04}/{0x10,0x02}",
      #bd == 2 and bd[1].reg == 0x11 and bd[1].val == 0x04
      and bd[2].reg == 0x10 and bd[2].val == 0x02)
-- 三次复位轮询读值：忙、忙、完成（txlog r 条目不含字节，读值看 rcap）
local br = reads(mark)
check("build 4 次读（ID+3 轮询）", #br == 4, tostring(#br))
check("ID 读 0xB1", rcap[1] and rcap[1][1] == 0xB1,
      string.format("0x%02X", rcap[1] and rcap[1][1] or 0))
check("复位轮询读值 04/04/00",
      rcap[2] and rcap[2][1] == 0x04 and rcap[3][1] == 0x04 and rcap[4][1] == 0x00,
      string.format("%02X/%02X/%02X",
      rcap[2] and rcap[2][1] or 0, rcap[3] and rcap[3][1] or 0,
      rcap[4] and rcap[4][1] or 0))
check("build 后 CTRL_REG1=0x02", dev:ctrl1() == 0x02)
check("build 后 WHO_AM_I 仍 0xB1", dev:devid() == 0xB1)

-- 预武装路径（守护场景）：7 txlog、零睡眠
mark = section()
dev:arm()
bm0 = sleep_total
expect_ok("build 预武装（7 txlog 零睡眠）", function()
	return build({ fd = fd, address = "0x5D" })
end)
check("build 预武装 7 txlog", #entries(mark) == 7, tostring(#entries(mark)))
check("build 预武装零睡眠", sleep_total - bm0 == 0, tostring(sleep_total - bm0))
check("预武装仅 1 次轮询读（即见 bit2=0）",
      #reads(mark) == 2 and rcap[2] and rcap[2][1] == 0x00,
      tostring(#reads(mark)) .. "/" .. string.format("%02X", rcap[2] and rcap[2][1] or 0))

-- 备地址 0x5C
mark = section()
dev:arm()
expect_ok("build 备地址 0x5C", function()
	return build({ fd = fd, address = "0x5C" })
end)
check("备地址 set 0x5C", set_addrs(mark)[1] == 0x5C,
      string.format("0x%02X", set_addrs(mark)[1] or 0))

-- wait 参数透传（落到 cfg_wait，用 call 超时间接验证，此处只确认 build 不挑值）
mark = section()
dev:arm()
expect_ok("build 带 wait=3", function()
	return build({ fd = fd, address = "0x5D", wait = "3" })
end)
expect_ok("build wait 非法值归一缺省", function()
	return build({ fd = fd, address = "0x5D", wait = "abc" })
end)

-- 复位轮询 20ms 耗尽：驱动不报错（继续写 CTRL_REG1），仅消耗预算
mark = section()
dev:set_never_ready(true)
bm0 = sleep_total
expect_ok("SWRESET 轮询耗尽 20ms 仍继续（非致命）", function()
	return build({ fd = fd, address = "0x5D" })
end)
check("耗尽路径实睡 20ms", sleep_total - bm0 == 20, tostring(sleep_total - bm0))
check("耗尽路径 45 txlog（1+2+1+40+1）", #entries(mark) == 45,
      tostring(#entries(mark)))
check("耗尽后 CTRL_REG1 照写 0x02", dev:ctrl1() == 0x02)

-- 负路径
mark = section()
expect_err("build 非 table", function() return build(8) end, "Invalid Arguments Type")
check("非 table 零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x5D" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("参数校验零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build fd=99（set_addr 失败）", function()
	return build({ fd = 99, address = "0x5D" })
end, "set_addr failed")
check("fd=99 零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("build 错地址 0x60", function()
	return build({ fd = fd, address = "0x60" })
end, "not responding")
check("错地址 2 txlog（set+w0F 无 r）", #entries(mark) == 2,
      tostring(#entries(mark)))

mark = section()
dev:fail_read(function(ptr) return ptr == 0x0F end)
expect_err("build WHO_AM_I 读失败", function()
	return build({ fd = fd, address = "0x5D" })
end, "read WHO_AM_I failed")
check("ID 读失败 3 txlog（fail_read 也记 r）", #entries(mark) == 3,
      tostring(#entries(mark)))
dev:clear_faults()

mark = section()
dev:who(0xBD)
expect_err("build 拦下 LPS25HB（0xBD）", function()
	return build({ fd = fd, address = "0x5D" })
end, "0xBD")
check("错 ID 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
dev:who(0x99)
expect_err("build 其他错 ID", function()
	return build({ fd = fd, address = "0x5D" })
end, "unexpected WHO_AM_I")
dev:who(0xB1)

mark = section()
dev:fail_write(function(b) return b[1] == 0x11 and #b >= 2 and b[2] == 0x04 end)
expect_err("build 软复位写失败", function()
	return build({ fd = fd, address = "0x5D" })
end, "soft reset write failed")
check("复位写失败 4 txlog", #entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

-- 复位轮询读失败：门路径 + 第二次 0x11 读起 NACK（ID 读放行）
mark = section()
do
	local n11 = 0
	dev:fail_read(function(ptr)
		if ptr ~= 0x11 then return false end
		n11 = n11 + 1
		return n11 >= 1	-- 首次轮询即失败
	end)
	expect_err("build 复位轮询读失败", function()
		return build({ fd = fd, address = "0x5D" })
	end, "reset poll failed")
end
check("轮询失败 6 txlog（set+w0F+r+w04+w11+r）", #entries(mark) == 6,
      tostring(#entries(mark)))
dev:clear_faults()

-- CTRL_REG1 写失败：预武装路径 7 txlog
mark = section()
dev:arm()
dev:fail_write(function(b) return b[1] == 0x10 and #b >= 2 end)
expect_err("build CTRL_REG1 写失败", function()
	return build({ fd = fd, address = "0x5D" })
end, "CTRL_REG1 write failed")
check("CTRL1 写失败 7 txlog", #entries(mark) == 7, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================

-- 门路径：14 txlog、3 次 1ms 轮询、P/T 换算独立交叉
mark = section()
expect_ok("call 前 build（门路径）", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:set_press_raw(4149248):set_temp_raw(2345)
mark = #vbus.txlog
rcap_reset()	-- rcap 不按 txlog 窗口过滤，call 前清空 build 的 4 次读
bm0 = sleep_total
local res = expect_ok("call 标准大气（门路径 3ms）", function()
	return call({ fd = fd, address = "0x5D" })
end)
check("call 门路径 14 txlog", #entries(mark) == 14, tostring(#entries(mark)))
check("call 门路径实睡 3ms", sleep_total - bm0 == 3,
      tostring(sleep_total - bm0))
check("call 指针写序列 11 11 11 11 11 A8",
      table.concat(ptr_writes(mark), ",") == "17,17,17,17,17,168",
      table.concat(ptr_writes(mark), ","))
local cd = data_writes(mark)
check("call 仅一笔配置写 {0x11,0x01} 触发",
      #cd == 1 and cd[1].reg == 0x11 and cd[1].val == 0x01,
      tostring(#cd))
local cr = reads(mark)
check("call 6 次读（c2+4 轮询+5B 数据）", #cr == 6, tostring(#cr))
check("call c2 起始读 0x00", rcap[1] and rcap[1][1] == 0x00,
      string.format("0x%02X", rcap[1] and rcap[1][1] or 0))
check("call 轮询读值 01/01/01/00",
      rcap[2] and rcap[2][1] == 0x01 and rcap[3][1] == 0x01
      and rcap[4][1] == 0x01 and rcap[5][1] == 0x00,
      string.format("%02X/%02X/%02X/%02X",
      rcap[2] and rcap[2][1] or 0, rcap[3] and rcap[3][1] or 0,
      rcap[4] and rcap[4][1] or 0, rcap[5] and rcap[5][1] or 0))
check("call 末笔 5B burst 00 50 3F 29 09",
      cr[6].bytes.n == 5 and rcap[6] and #rcap[6] == 5
      and rcap[6][1] == 0x00 and rcap[6][2] == 0x50 and rcap[6][3] == 0x3F
      and rcap[6][4] == 0x29 and rcap[6][5] == 0x09,
      tostring(cr[6].bytes.n) .. "/"
      .. (rcap[6] and string.format("%02X %02X %02X %02X %02X",
         rcap[6][1], rcap[6][2], rcap[6][3], rcap[6][4], rcap[6][5]) or "nil"))
if res then
	check("P=1013.0 hPa", near(res.P, 1013.0, 1e-9), tostring(res.P))
	check("T=23.45 °C", near(res.T, 23.45, 1e-9), tostring(res.T))
end

-- 预武装路径：8 txlog、零睡眠；RMW 触发帧保 IF_ADD_INC
mark = section()
expect_ok("call 前 build（武装）", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:set_press_raw(1066496):set_temp_raw(-100)
dev:arm()
mark = #vbus.txlog
bm0 = sleep_total
res = expect_ok("call 预武装 8 txlog 零睡眠", function()
	return call({ fd = fd, address = "0x5D" })
end)
check("call 武装 8 txlog", #entries(mark) == 8, tostring(#entries(mark)))
check("call 武装零睡眠", sleep_total - bm0 == 0, tostring(sleep_total - bm0))
if res then
	check("P=260.375 hPa（旧桩点）", near(res.P, 260.375, 1e-9), tostring(res.P))
	check("T=-1.00 °C（有符号码 -100=补码 0xFF9C）", near(res.T, -1.0, 1e-9),
	      tostring(res.T))
end

-- 补码/极值换算（每拍武装，驱动独立解码交叉）
local conv_cases = {
	{ -4096, -100, -1.0, -1.0, "旧桩气压补码点 + 负温" },
	{ 8388607, 32767, 8388607 / 4096, 327.67, "正满程 s24/s16" },
	{ -8388608, -32768, -2048.0, -327.68, "负满程 s24/s16" },
	{ 0, 0, 0.0, 0.0, "零值" },
	{ 1, 1, 1 / 4096, 0.01, "+1 LSB" },
	{ -1, -1, -1 / 4096, -0.01, "-1 LSB" },
}
for _, c in ipairs(conv_cases) do
	mark = section()
	expect_ok("换算点 build：" .. c[5], function()
		return build({ fd = fd, address = "0x5D" })
	end)
	dev:set_press_raw(c[1]):set_temp_raw(c[2])
	dev:arm()
	local r = expect_ok("call 换算点：" .. c[5], function()
		return call({ fd = fd, address = "0x5D" })
	end)
	if r then
		check(string.format("%s：P=%.6f（码 %d）", c[5], c[3], c[1]),
		      near(r.P, c[3], 1e-12), tostring(r.P))
		check(string.format("%s：T=%.2f（码 %d）", c[5], c[4], c[2]),
		      near(r.T, c[4], 1e-12), tostring(r.T))
	end
end

-- virt_tick 三拍闭环（守护节拍：每拍 tick 后 call，零睡眠取新鲜正弦）
local loop_pts = { { 0, 1013.25, 22.0 }, { 8, 1018.25, 24.0 }, { 24, 1008.25, 20.0 } }
for _, p in ipairs(loop_pts) do
	mark = section()
	expect_ok("闭环 build n=" .. p[1], function()
		return build({ fd = fd, address = "0x5D" })
	end)
	dev:virt_tick(p[1])
	mark = #vbus.txlog
	bm0 = sleep_total
	local r = expect_ok("闭环 call n=" .. p[1], function()
		return call({ fd = fd, address = "0x5D" })
	end)
	check(string.format("闭环 n=%d 8 txlog 零睡眠", p[1]),
	      #entries(mark) == 8 and sleep_total - bm0 == 0,
	      string.format("%d txlog/%dms", #entries(mark), sleep_total - bm0))
	if r then
		check(string.format("闭环 n=%d P=%.2fhPa", p[1], p[2]),
		      near(r.P, p[2], 0.00025), tostring(r.P))
		check(string.format("闭环 n=%d T=%.1f°C", p[1], p[3]),
		      near(r.T, p[3], 0.005), tostring(r.T))
	end
end

-- wait 超时：必须先正常 build（复位门闭合）再开 never_ready——若 build 前开，
-- SWRESET 轮询耗尽后 reset_busy 残留，call 的 RMW 触发帧（c2=0x04→0x05）会
-- 再入复位分支、首次轮询读 0x04 被 v%2==0 误判完成，超时测试假通过
mark = section()
dev:arm()
expect_ok("超时组 build（预武装正常完成，wait=50）", function()
	return build({ fd = fd, address = "0x5D", wait = "50" })
end)
dev:set_never_ready(true)
mark = #vbus.txlog
bm0 = sleep_total
expect_err("call wait=50 超时", function()
	return call({ fd = fd, address = "0x5D" })
end, "not ready")
check("wait=50：106 txlog（1+2+1+51×2）", #entries(mark) == 106,
      tostring(#entries(mark)))
check("wait=50：实睡 50ms", sleep_total - bm0 == 50, tostring(sleep_total - bm0))

mark = #vbus.txlog
bm0 = sleep_total
expect_err("call wait=3 超时", function()
	return call({ fd = fd, address = "0x5D", wait = "3" })
end, "not ready")
check("wait=3：12 txlog（1+2+1+4×2）", #entries(mark) == 12,
      tostring(#entries(mark)))
check("wait=3：实睡 3ms", sleep_total - bm0 == 3, tostring(sleep_total - bm0))

mark = #vbus.txlog
bm0 = sleep_total
expect_err("call wait=-5 归一 0：首次轮询即超时", function()
	return call({ fd = fd, address = "0x5D", wait = "-5" })
end, "not ready")
check("wait=0：6 txlog（1+2+1+1×2）零睡眠",
      #entries(mark) == 6 and sleep_total - bm0 == 0,
      string.format("%d txlog/%dms", #entries(mark), sleep_total - bm0))

-- call 负路径（预武装，计数确定）
mark = section()
expect_err("call 非 table", function() return call(3) end, "Invalid Arguments")
check("call 非 table 零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
check("call 参数校验零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_err("call fd=99", function()
	return call({ fd = 99, address = "0x5D" })
end, "set_addr failed")
check("call fd=99 零事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
expect_ok("call 错地址组 build", function()
	return build({ fd = fd, address = "0x5D" })
end)
mark = #vbus.txlog
expect_err("call 错地址 0x60（c2 指针写 NACK）", function()
	return call({ fd = fd, address = "0x60" })
end, "read CTRL_REG2 failed")
check("call 错地址 2 txlog（set+w11 无 r）", #entries(mark) == 2,
      tostring(#entries(mark)))

mark = section()
expect_ok("c2 读失败组 build", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:fail_read(function(ptr) return ptr == 0x11 end)
mark = #vbus.txlog
expect_err("call 读 CTRL_REG2 失败", function()
	return call({ fd = fd, address = "0x5D" })
end, "read CTRL_REG2 failed")
check("c2 读失败 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
dev:clear_faults()

mark = section()
expect_ok("触发写失败组 build", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:fail_write(function(b) return b[1] == 0x11 and #b >= 2 end)
mark = #vbus.txlog
expect_err("call 触发写失败", function()
	return call({ fd = fd, address = "0x5D" })
end, "trigger write failed")
check("触发写失败 4 txlog", #entries(mark) == 4, tostring(#entries(mark)))
dev:clear_faults()

-- 轮询读失败：c2 读放行，首次轮询起 NACK（武装须关，否则无轮询）
mark = section()
expect_ok("轮询失败组 build", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:set_press_raw(4149248):set_temp_raw(2345)
do
	local n11 = 0
	dev:fail_read(function(ptr)
		if ptr ~= 0x11 then return false end
		n11 = n11 + 1
		return n11 >= 2	-- c2 读（第 1 次）放行，首次轮询（第 2 次）失败
	end)
	mark = #vbus.txlog
	expect_err("call 轮询读失败", function()
		return call({ fd = fd, address = "0x5D", wait = "50" })
	end, "poll failed")
	check("轮询失败 6 txlog（set+w11+r+w01+w11+r）", #entries(mark) == 6,
	      tostring(#entries(mark)))
end
dev:clear_faults()

mark = section()
expect_ok("数据读失败组 build", function()
	return build({ fd = fd, address = "0x5D" })
end)
dev:set_press_raw(4149248):set_temp_raw(2345)
dev:fail_read(function(ptr) return ptr == 0x28 end)
dev:arm()
mark = #vbus.txlog
expect_err("call 5B 数据读失败", function()
	return call({ fd = fd, address = "0x5D" })
end, "read data failed")
check("数据读失败 8 txlog", #entries(mark) == 8, tostring(#entries(mark)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（单次模式本身即 power-down，无总线动作）
-- =====================================================================
mark = section()
expect_ok("destroy 空表 OK", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_ok("destroy 带 fd 表也不碰总线", function()
	return destroy({ fd = fd, address = "0x5D" })
end)
expect_err("destroy 非 table", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_lps22hb")

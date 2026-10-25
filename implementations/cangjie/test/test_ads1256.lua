-- test_ads1256.lua —— ADS1256 真实驱动 + 虚拟 SPI 总线 + 器件模型
-- 用法（项目根目录）: luajit test/test_ads1256.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「直接 mock HAL.sys.ioctl_p 的 cdata 层」迁移到「真实驱动 + virtbus SPI
-- 注入层（spi_write/write3/read_multi 全局）+ virtbus/ads1256.lua 模型」：
-- 事务断言扫 vbus.txlog 的 CS 帧（一次 HAL 传输 = 一条 dir="x"），覆盖
--   1) 模型协议事实：命令流水、WREG 同帧解析、RDATAC 24bit 样本帧、RREG 回填、
--      有符号/电压 API、virt_tick 确定性、故障注入；
--   2) build：RESET→WAKEUP→4 个 WREG→SELFCAL→RDATAC 序列/参数钳制/55ms 时序/失败路径；
--   3) call：SDATAC→WREG MUX→SYNC→WAKEUP→RDATAC→4B 样本帧、单端/差分 MUX、
--      24bit 补码与 PGA 电压换算、第 4 字节丢弃、逐命令失败路径；
--   4) destroy：SDATAC 与失败路径。
local tester = dofile("test/lib/tester.lua")
local check = tester.check

local vbus = dofile("modules/lib/virtbus.lua")
local adsmod = dofile("modules/lib/virtbus/ads1256.lua")
vbus.reset()

local SPI_PATH = "/dev/spidev0.0"
local dev = adsmod.new()
vbus.attach_spi("ADS1256@spidev0.0", SPI_PATH, dev)
vbus.load_driver("modules/ADS1256.lua")

local fd = spi_open(SPI_PATH)
check("spi_open 虚拟 fd=3", fd == 3)
check("spi_setup Mode1/8bit/1.92MHz 返回 0", spi_setup(fd, 1, 8, 1920000, 0) == 0)

-- milli_sleep 桩：累计时长并推进模型虚拟时钟（ADS1256 驱动只 sleep 不轮询引脚，
-- advance 不影响读就绪，但时序断言用得到 sleep_total）
local sleep_total = 0
milli_sleep = function(ms) sleep_total = sleep_total + (tonumber(ms) or 0); dev:advance(ms) end

-- txlog 窗口：取 mark 之后的所有 CS 帧
local function xframes(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do
		if vbus.txlog[i].dir == "x" then t[#t + 1] = vbus.txlog[i] end
	end
	return t
end
local function setup_entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do
		if vbus.txlog[i].dir == "setup" then t[#t + 1] = vbus.txlog[i] end
	end
	return t
end
local function tx_of(e) return e.tx end
local function first_byte(e) return e.tx[1] end

-- 每个 section：模型状态机复位 + sleep 清零（fd 与总线挂载不动）
local function section()
	dev:reset()
	sleep_total = 0
	return #vbus.txlog
end

-- 便捷：在模型上直接打一帧
local function model_xfer(...) return dev.xfer({ ... }) end

-- ==================== 1) 模型协议事实 ====================

-- 1.1 24bit 样本帧编码（RDATAC 模式 + 4 dummy 字节）
dev.xfer({ 0x03 })	-- 进 RDATAC
check("模型：RDATAC 后 in_datac()=true", dev:in_datac() == true)
dev:set_raw(0x7FFFFF)
local f = dev.xfer({ 0, 0, 0, 0 })
check("模型：+满量程样本帧 7F FF FF 00",
	f[1] == 0x7F and f[2] == 0xFF and f[3] == 0xFF and f[4] == 0x00)
dev:set_raw(-8388608)
f = dev.xfer({ 0, 0, 0, 0 })
check("模型：-满量程样本帧 80 00 00 00",
	f[1] == 0x80 and f[2] == 0x00 and f[3] == 0x00 and f[4] == 0x00)
dev:set_raw(0x123456)
f = dev.xfer({ 0, 0, 0, 0 })
check("模型：0x123456 样本帧 12 34 56 00",
	f[1] == 0x12 and f[2] == 0x34 and f[3] == 0x56 and f[4] == 0x00)

-- 1.2 set_raw clamp 到 24bit 有符号范围
dev:set_raw(0x1000000)
f = dev.xfer({ 0, 0, 0, 0 })
check("模型：set_raw 超上限 clamp 到 7FFFFF", f[1] == 0x7F and f[3] == 0xFF)
dev:set_raw(-0x1000000)
f = dev.xfer({ 0, 0, 0, 0 })
check("模型：set_raw 超下限 clamp 到 800000", f[1] == 0x80 and f[2] == 0x00 and f[3] == 0x00)
check("模型：raw() 往返有符号", (function()
	dev:set_raw(-12345); return dev:raw() == -12345
end)())

-- 1.3 非 datac 模式 dummy 帧不出数据（MISO 全 0）
dev.xfer({ 0x0F })
f = dev.xfer({ 0, 0, 0, 0 })
check("模型：SDATAC 后 dummy 帧 MISO 全 0",
	not dev:in_datac() and f[1] == 0 and f[2] == 0 and f[3] == 0 and f[4] == 0)

-- 1.4 WREG 同帧解析（驱动 write3 一帧发完 cmd/count/data）
local r = model_xfer(0x51, 0x00, 0x58)
check("模型：WREG 帧 MISO 不回数据（全 0）", r[1] == 0 and r[2] == 0 and r[3] == 0)
local c = dev:config()
check("模型：WREG MUX=0x58 解码单端 AIN5",
	c.mux == 0x58 and c.single and c.channel == 5)
model_xfer(0x51, 0x00, 0x23)
c = dev:config()
check("模型：WREG MUX=0x23 解码差分 AIN2(+)/AIN3(-)",
	(not c.single) and c.pos == 2 and c.neg == 3)
model_xfer(0x52, 0x00, 0x04)
c = dev:config()
check("模型：WREG ADCON=0x04 解码 PGA 序号 4/×16", c.pga_idx == 4 and c.gain == 16)
model_xfer(0x53, 0x00, 0x80)
c = dev:config()
check("模型：WREG DRATE=0x80 解码 100 SPS", c.drate == 0x80 and c.sps == 100)
local rw = dev:reg_writes()
check("模型：reg_writes 流水 4 条且 reg/val 正确",
	#rw == 4 and rw[1].reg == 1 and rw[1].val == 0x58
	and rw[3].reg == 2 and rw[4].reg == 3 and rw[4].val == 0x80)

-- 1.5 RREG 回填（驱动当前不用，保证协议完整）
model_xfer(0x50, 0x00, 0x14)	-- 先写 STATUS=0x14
local rr = model_xfer(0x10, 0x00)	-- RREG STATUS count=0（命令帧不回值）
check("模型：RREG 命令帧 MISO 全 0（真实 t6 后才出值）", rr[1] == 0 and rr[2] == 0)
rr = model_xfer(0x00)
check("模型：后续 dummy 帧回填 STATUS=0x14", rr[1] == 0x14)

-- 1.6 RESET 复位状态机与寄存器
model_xfer(0x03)
check("模型：复位前在 datac", dev:in_datac())
model_xfer(0xFE)
check("模型：RESET 退出 datac、命令流水只留 RESET",
	not dev:in_datac() and #dev:cmd_log() == 1 and dev:cmd_log()[1].name == "RESET")

-- 1.7 set_voltage 物理量 API（常量对齐驱动 VREF=2.5/PGA）
dev:set_voltage(1.0, 0)
check("模型：set_voltage(1.0V,PGA×1) 反解 raw≈1677722（±1LSB）",
	math.abs(dev:raw() - 1677722) <= 1)
dev:set_voltage(0.625, 2)
check("模型：set_voltage(0.625V,PGA×4) 反解 raw=0x400000",
	dev:raw() == 0x400000)

-- 1.8 virt_tick 确定性正弦（守护节拍源）
local v0, v1, v8, v32 = dev:virt_tick(0):raw(), dev:virt_tick(1):raw(),
	dev:virt_tick(8):raw(), dev:virt_tick(32):raw()
check("模型：virt_tick 确定性 + 随拍变化 + 32 拍周期",
	v0 == v32 and v0 ~= v1 and v8 > v0)
local vmax, vmin = -math.huge, math.huge
for n = 0, 63 do
	local vv = dev:virt_tick(n):raw() * 5 / 8388608
	if vv > vmax then vmax = vv end
	if vv < vmin then vmin = vv end
end
check("模型：virt_tick 电压有界 0.25~2.25V（PGA×1 量程内）",
	vmax <= 2.26 and vmin >= 0.24, string.format("%.3f~%.3f", vmin, vmax))

-- 1.9 故障注入
dev:fail_when(function(tx) return tx[1] == 0xAA end)
check("模型：fail_when 命中帧 xfer 返 nil", dev.xfer({ 0xAA }) == nil)
check("模型：fail_when 未命中帧正常", dev.xfer({ 0x01 }) ~= nil)
dev:clear_fail()
dev:reset()

-- ==================== 2) build（真实驱动）====================
local mk, fr, res

section()
mk = #vbus.txlog
res = build({ fd = fd, delay = 0 })
fr = xframes(mk)
check("build 默认参数 OK", tostring(res.result) == "OK", res.message)
check("build 共 8 个 CS 帧", #fr == 8, #fr)
check("build 帧1 RESET=0xFE", first_byte(fr[1]) == 0xFE and #fr[1].tx == 1)
check("build 帧2 WAKEUP=0x00", first_byte(fr[2]) == 0x00 and #fr[2].tx == 1)
check("build 帧3 WREG STATUS {50,00,14}",
	fr[3].tx[1] == 0x50 and fr[3].tx[2] == 0x00 and fr[3].tx[3] == 0x14)
check("build 帧4 WREG MUX 默认 {51,00,08}",
	fr[4].tx[1] == 0x51 and fr[4].tx[2] == 0x00 and fr[4].tx[3] == 0x08)
check("build 帧5 WREG ADCON 默认 {52,00,00}",
	fr[5].tx[1] == 0x52 and fr[5].tx[3] == 0x00)
check("build 帧6 WREG DRATE=1000SPS {53,00,A0}",
	fr[6].tx[1] == 0x53 and fr[6].tx[3] == 0xA0)
check("build 帧7 SELFCAL=0xF0", first_byte(fr[7]) == 0xF0 and #fr[7].tx == 1)
check("build 帧8 RDATAC=0x03", first_byte(fr[8]) == 0x03 and #fr[8].tx == 1)
check("build 后模型进入连续读模式", dev:in_datac() == true)
check("build sleep 合计 60ms（5+5+50）", sleep_total == 60, sleep_total)
c = dev:config()
check("build 后模型配置 AIN0 单端/PGA×1/1000SPS",
	c.single and c.channel == 0 and c.gain == 1 and c.sps == 1000)

-- setup 留痕：ADS1256 要求 SPI Mode 1
local se = setup_entries(0)
check("总线：spi_setup Mode1/8bit/1.92MHz 留痕",
	#se >= 1 and se[#se].mode == 1 and se[#se].bits == 8
	and se[#se].speed == 1920000 and se[#se].path == SPI_PATH)

-- 自定义参数
section()
res = build({ fd = fd, delay = 0, drate = 0, pga = 3, channel = 5 })
check("build 自定义参数 OK", tostring(res.result) == "OK")
-- 直接从模型配置断言（比窗口下标稳）
c = dev:config()
check("build 自定义：AIN5 单端/PGA×8/30000SPS",
	c.channel == 5 and c.single and c.gain == 8 and c.sps == 30000)
-- 也核对线上 MUX/ADCON/DRATE 三帧字节（本次 build 恰好 8 帧）
local last8 = xframes(#vbus.txlog - 8)
check("build 自定义线帧 MUX=58/ADCON=03/DRATE=F0",
	last8[4].tx[3] == 0x58 and last8[5].tx[3] == 0x03 and last8[6].tx[3] == 0xF0)

-- 参数越界钳回缺省
section()
build({ fd = fd, delay = 0, drate = 15, pga = 7, channel = 8 })
c = dev:config()
check("build 越界参数钳缺省：AIN0/PGA×1/1000SPS",
	c.channel == 0 and c.pga_idx == 0 and c.sps == 1000)
section()
build({ fd = fd, delay = 0, drate = -1, pga = -1, channel = -1 })
c = dev:config()
check("build 负向越界同样钳缺省",
	c.channel == 0 and c.pga_idx == 0 and c.sps == 1000)

-- build 参数校验
section()
check("build 缺 fd ERR", build({ delay = 0 }).result == "ERR")
check("build 非表 ERR", build("x").result == "ERR")

-- build 逐命令失败路径（fail_when 按帧首字节精确命中，每次只崩一类）
local function build_fail(label, pred, msg_part)
	section()
	dev:fail_when(pred)
	local r2 = build({ fd = fd, delay = 0 })
	dev:clear_fail()
	check(label, r2.result == "ERR" and tostring(r2.message):find(msg_part, 1, true) ~= nil,
		tostring(r2.message))
end
build_fail("build RESET 帧失败 ERR", function(tx) return #tx == 1 and tx[1] == 0xFE end,
	"reset")
build_fail("build WAKEUP 帧失败 ERR", function(tx) return #tx == 1 and tx[1] == 0x00 end,
	"wake")
build_fail("build WREG STATUS 帧失败 ERR", function(tx) return tx[1] == 0x50 end,
	"STATUS")
build_fail("build WREG MUX 帧失败 ERR", function(tx) return tx[1] == 0x51 end,
	"MUX")
build_fail("build WREG ADCON 帧失败 ERR", function(tx) return tx[1] == 0x52 end,
	"ADCON")
build_fail("build WREG DRATE 帧失败 ERR", function(tx) return tx[1] == 0x53 end,
	"DRATE")
build_fail("build SELFCAL 帧失败 ERR", function(tx) return #tx == 1 and tx[1] == 0xF0 end,
	"self-calibration")
build_fail("build RDATAC 帧失败 ERR", function(tx) return #tx == 1 and tx[1] == 0x03 end,
	"continuous read")

-- ==================== 3) call（真实驱动）====================
section()
build({ fd = fd, delay = 0 })
local call_mark = #vbus.txlog

-- 3.1 单端默认 + 正满量程
dev:set_raw(0x7FFFFF)
res = call({ fd = fd, delay = 0, channel = 0 })
check("call 单端 OK", res.result == "OK", res.message)
check("call raw=8388607", res.raw == 8388607, tostring(res.raw))
check("call 电压≈+5.0V（PGA×1 满量程）", math.abs(res.voltage - 5.0) < 0.001,
	tostring(res.voltage))
fr = xframes(call_mark)
check("call 共 6 帧（5 命令 + 1 数据）", #fr == 6, #fr)
check("call 帧1 SDATAC=0x0F", first_byte(fr[1]) == 0x0F)
check("call 帧2 WREG MUX=0x08", fr[2].tx[1] == 0x51 and fr[2].tx[3] == 0x08)
check("call 帧3 SYNC=0xFC", first_byte(fr[3]) == 0xFC)
check("call 帧4 WAKEUP=0x00", first_byte(fr[4]) == 0x00)
check("call 帧5 RDATAC=0x03", first_byte(fr[5]) == 0x03)
check("call 帧6 是 4B dummy 数据帧（MOSI 全 0）",
	#fr[6].tx == 4 and fr[6].tx[1] == 0 and fr[6].tx[4] == 0
	and #fr[6].rx == 4 and fr[6].rx[1] == 0x7F)
-- call 时序：sync 1ms + ceil(1000/1000)+1=2ms = 3ms（不含 build 的 60）
check("call sleep=3ms（1000SPS：sync1 + 转换2）", sleep_total == 60 + 3, sleep_total)

-- 3.2 慢速率等待：drate=14（5SPS）→ ceil(1000/5)+1=201，+sync1 = 202ms
section()
build({ fd = fd, delay = 0, drate = 14 })
sleep_total = 0
call({ fd = fd, delay = 0, drate = 14 })
check("call 5SPS 等待 202ms", sleep_total == 202, sleep_total)

-- 3.3 单端换通道
section()
build({ fd = fd, delay = 0 })
local b0 = #vbus.txlog
dev:set_raw(0)
call({ fd = fd, delay = 0, channel = 5 })
check("call channel=5 的 WREG MUX=0x58", xframes(b0)[2].tx[3] == 0x58)

-- 3.4 差分 MUX
section()
build({ fd = fd, delay = 0 })
b0 = #vbus.txlog
dev:set_raw(0x000080)
res = call({ fd = fd, delay = 0, pos = 0, neg = 1 })
check("call 差分 OK", res.result == "OK")
check("call 差分 MUX=0x01 且 raw=128（正数）",
	xframes(b0)[2].tx[3] == 0x01 and res.raw == 128)
section()
build({ fd = fd, delay = 0 })
b0 = #vbus.txlog
res = call({ fd = fd, delay = 0, pos = 2, neg = 3 })
check("call 差分 AIN2/AIN3 的 MUX=0x23", xframes(b0)[2].tx[3] == 0x23)

-- 3.5 补码与 PGA 换算
section()
build({ fd = fd, delay = 0 })
dev:set_raw(-8388608)
res = call({ fd = fd, delay = 0 })
check("call 0x800000 符号扩展为 -8388608", res.raw == -8388608)
check("call 负满量程≈-5.0V", math.abs(res.voltage + 5.0) < 0.001)
section()
build({ fd = fd, delay = 0 })
dev:set_raw(0)
res = call({ fd = fd, delay = 0 })
check("call 零输入 raw=0 电压=0", res.raw == 0 and res.voltage == 0)
section()
build({ fd = fd, delay = 0 })
dev:set_raw(0x400000)
res = call({ fd = fd, delay = 0, pga = 2 })
check("call PGA×4 下 0x400000 → 0.625V",
	res.raw == 0x400000 and math.abs(res.voltage - 0.625) < 1e-9,
	tostring(res.voltage))

-- 3.6 第 4 字节被驱动丢弃：临时包一层 xfer 给数据帧第 4 字节塞 0xFF
section()
build({ fd = fd, delay = 0 })
local real_xfer = dev.xfer
dev.xfer = function(tx)
	local rx2 = real_xfer(tx)
	if rx2 ~= nil and #tx == 4 then rx2[4] = 0xFF end
	return rx2
end
dev:set_raw(0x123456)
res = call({ fd = fd, delay = 0 })
dev.xfer = real_xfer
check("call 数据帧第 4 字节 0xFF 不影响读数（驱动 rshift 8 丢弃）",
	res.raw == 0x123456, tostring(res.raw))

-- 3.7 数据帧失败
section()
build({ fd = fd, delay = 0 })
dev:fail_data(true)
res = call({ fd = fd, delay = 0 })
dev:fail_data(false)
check("call 数据帧失败 ERR（Failed to read data）",
	res.result == "ERR"
	and tostring(res.message):find("read data", 1, true) ~= nil, tostring(res.message))

-- 3.8 命令序列失败路径
section()
build({ fd = fd, delay = 0 })
dev:fail_when(function(tx) return #tx == 1 and tx[1] == 0x0F end)
res = call({ fd = fd, delay = 0 })
dev:clear_fail()
check("call SDATAC 失败 ERR", res.result == "ERR"
	and tostring(res.message):find("stop continuous", 1, true) ~= nil)

section()
build({ fd = fd, delay = 0 })
dev:fail_when(function(tx) return tx[1] == 0x51 end)
res = call({ fd = fd, delay = 0 })
dev:clear_fail()
check("call WREG MUX 失败 ERR", res.result == "ERR"
	and tostring(res.message):find("MUX", 1, true) ~= nil)
-- 驱动在 MUX 失败后补发 RDATAC 试图恢复模式
local tail = vbus.txlog[#vbus.txlog]
check("call MUX 失败后补发 RDATAC 恢复", tail.dir == "x" and first_byte(tail) == 0x03)

section()
build({ fd = fd, delay = 0 })
dev:fail_when(function(tx) return #tx == 1 and tx[1] == 0xFC end)
res = call({ fd = fd, delay = 0 })
dev:clear_fail()
check("call SYNC 失败 ERR", res.result == "ERR"
	and tostring(res.message):find("sync", 1, true) ~= nil)

section()
build({ fd = fd, delay = 0 })
-- WAKEUP 在 call 中是单字节 0x00；数据帧是 4 字节，不会误伤
dev:fail_when(function(tx) return #tx == 1 and tx[1] == 0x00 end)
res = call({ fd = fd, delay = 0 })
dev:clear_fail()
check("call WAKEUP 失败 ERR", res.result == "ERR"
	and tostring(res.message):find("wake", 1, true) ~= nil)

section()
build({ fd = fd, delay = 0 })
dev:fail_when(function(tx) return #tx == 1 and tx[1] == 0x03 end)
res = call({ fd = fd, delay = 0 })
dev:clear_fail()
check("call 重进 RDATAC 失败 ERR", res.result == "ERR"
	and tostring(res.message):find("continuous read", 1, true) ~= nil)

-- 3.9 参数校验
section()
build({ fd = fd, delay = 0 })
check("call 缺 fd ERR", call({ delay = 0 }).result == "ERR")
check("call 非表 ERR", call("x").result == "ERR")
check("call pos='-' 非数字 ERR", call({ fd = fd, pos = "-", neg = "1" }).result == "ERR")
check("call pos=8 越界 ERR", call({ fd = fd, pos = 8, neg = 0 }).result == "ERR")
check("call neg=9 越界 ERR", call({ fd = fd, pos = 0, neg = 9 }).result == "ERR")
check("call channel=9 越界 ERR", call({ fd = fd, channel = 9 }).result == "ERR")

-- 3.10 多拍连读（守护行为预演）：virt_tick 逐拍造数，读数随拍变化且自洽
section()
build({ fd = fd, delay = 0 })
local seq_v = {}
for n = 0, 7 do
	dev:virt_tick(n)
	local s = call({ fd = fd, delay = 0 })
	seq_v[#seq_v + 1] = s.voltage
end
check("连读 8 拍均 OK 且数值变化（合成波形）",
	#seq_v == 8 and seq_v[1] ~= seq_v[3] and seq_v[3] ~= seq_v[7])

-- ==================== 4) destroy ====================
section()
build({ fd = fd, delay = 0 })
local dmark = #vbus.txlog
res = destroy({ fd = fd })
check("destroy OK", res.result == "OK", res.message)
fr = xframes(dmark)
check("destroy 单帧 SDATAC=0x0F", #fr == 1 and first_byte(fr[1]) == 0x0F)
check("destroy 后模型退出连续读", not dev:in_datac())

section()
check("destroy 缺 fd ERR", destroy({}).result == "ERR")
check("destroy 非表 ERR", destroy("x").result == "ERR")
section()
build({ fd = fd, delay = 0 })
dev:fail_when(function(tx) return #tx == 1 and tx[1] == 0x0F end)
res = destroy({ fd = fd })
dev:clear_fail()
check("destroy SDATAC 帧失败 ERR", res.result == "ERR"
	and tostring(res.message):find("continuous read", 1, true) ~= nil)

tester.summary("test_ads1256")
return 0

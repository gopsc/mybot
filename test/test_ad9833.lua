-- test_ad9833.lua —— AD9833 真实驱动 + 虚拟 SPI 总线 + 器件模型
-- 用法（项目根目录）: luajit test/test_ad9833.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「直接替换全局 spi_write_multi 的手写字桩」迁移到「真实驱动 + virtbus SPI
-- 注入层 + 内嵌模型（modules/AD9833.lua 尾部 AD9833_VIRT，2026-09-15
-- 自 virtbus/ad9833.lua 迁入）16 位字解码模型」：
-- 旧桩只能逐字比对预期常量；新模型把帧真正解码回频率/相位/控制寄存器，
-- 字节序（低 14 位在前）、B28 两段拼接、波形位/RESET 语义都可独立断言，
-- 且覆盖 setup Mode2 留痕、非整字帧等旧桩触及不到的总线事实。
--   1) 模型协议事实：顶 2 位寻址、B28 LSB→MSB 28 位拼接（顺序敏感）、
--      B28=0/HLB 单半字写、PHASE0/1、波形位解码、FSELECT/PSELECT、故障注入；
--   2) build：5 字序列字节级、默认/440 方波 90°/三角波配置、参数校验零发字、
--      5 个逐字失败负路径；
--   3) call：freq 三字序列与解码、无键回显不发字、wave/mute/phase、
--      静音态保持 RESET、参数校验、逐字失败、12.5MHz 上限；
--   4) destroy。
local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local SPI_PATH = "/dev/spidev0.0"

-- 模型内嵌于驱动文件（AD9833_VIRT 全局工厂，工厂表带 BUS="spi"）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/AD9833.lua")
local ddsmod = AD9833_VIRT

local dev = ddsmod.new()
vbus.attach_spi("AD9833@spidev0.0", SPI_PATH, dev)

local fd = spi_open(SPI_PATH)
check("spi_open 虚拟 fd=3", fd == 3)
check("spi_setup Mode2/8bit/1MHz 返回 0", spi_setup(fd, 2, 8, 1000000, 0) == 0)
do
	local s
	for _, e in ipairs(vbus.txlog) do if e.dir == "setup" then s = e end end
	check("setup 留痕 mode=2 bits=8 speed=1MHz",
		s and s.path == SPI_PATH and s.mode == 2 and s.bits == 8 and s.speed == 1000000)
end

-- txlog 窗口：mark 之后的所有 CS 帧；words 还原为 16 位字
local function xframes(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do
		if vbus.txlog[i].dir == "x" then t[#t + 1] = vbus.txlog[i] end
	end
	return t
end
local function word_of(e) return e.tx[1] * 256 + e.tx[2] end
local function words_of(mark)
	local t = {}
	for _, e in ipairs(xframes(mark)) do t[#t + 1] = word_of(e) end
	return t
end
local function seq_is(label, mark, want)
	local got = words_of(mark)
	local same = #got == #want
	for i = 1, math.min(#got, #want) do
		if got[i] ~= want[i] then same = false; break end
	end
	local function hex(t)
		local u = {}
		for i, w in ipairs(t) do u[i] = string.format("0x%04X", w) end
		return table.concat(u, ",")
	end
	check(label, same, hex(got) .. " want " .. hex(want))
end

-- 每个 section：模型复位（fd 与挂载不动）
local function section()
	dev:reset()
	return #vbus.txlog
end

local function model_w(w) dev.xfer({ math.floor(w / 256), w % 256 }) end

-- datasheet 调谐字（与驱动同源公式，仅用于组织输入；解码反向断言只看模型）
local function tw(f) return math.floor(f * 268435456 / 25000000 + 0.5) end
local function pw(d) return math.floor(d * 4096 / 360 + 0.5) % 4096 end

-- ==================== 1) 模型协议事实 ====================

section()
-- 1.1 顶 2 位寻址与字日志
model_w(0x2100)
model_w(0x69F1)
model_w(0x4000)
model_w(0xC000)
local wl = dev:word_log()
check("模型：四字 kind 序列 ctrl/freq0/freq0/phase0",
	wl[1].kind == "ctrl" and wl[2].kind == "freq0" and
	wl[3].kind == "freq0" and wl[4].kind == "phase0")
check("模型：字日志 hi/lo 大端拆分",
	wl[2].hi == 0x69 and wl[2].lo == 0xF1 and wl[2].w == 0x69F1)

-- 1.2 B28 两段拼接：tw(1000)=10737=0x29F1
check("模型：tw(1000) 参考值=10737", tw(1000) == 10737, tw(1000))
check("模型：B28 拼出 FREQ0=10737", dev:freq_raw(0) == 10737, dev:freq_raw(0))
check("模型：freq_hz≈1000（f=raw·MCLK/2^28）",
	math.abs(dev:freq_hz() - 1000) < 0.05, string.format("%.4f", dev:freq_hz()))
check("模型：控制位 RESET=1/B28=1（ctrl=0x2100）",
	dev:muted() == true and dev:ctrl() == 0x2100)

-- 1.3 顺序敏感：低 14 位必须在前——反序拼出错误频率
section()
model_w(0x2000)						-- B28=1，RESET=0
local rev = tw(44000)				-- 0x7357E
model_w(0x4000 + math.floor(rev / 0x4000))	-- 故意先发高半字
model_w(0x4000 + rev % 0x4000)				-- 后发低半字
check("模型：高/低反序拼出错误值（顺序保护）",
	dev:freq_raw(0) ~= rev, string.format("got=%d want=%d", dev:freq_raw(0), rev))
-- 正确顺序
section()
model_w(0x2000)
model_w(0x4000 + rev % 0x4000)
model_w(0x4000 + math.floor(rev / 0x4000))
check("模型：低/高正序拼出 44000Hz 调谐字", dev:freq_raw(0) == rev, dev:freq_raw(0))
check("模型：freq_hz≈44000", math.abs(dev:freq_hz() - 44000) < 1, dev:freq_hz())

-- 1.4 B28=0/HLB 单半字写
section()
model_w(0x0000)						-- B28=0/HLB=0：只写低 14 位
model_w(0x4000 + 0x1234)
check("模型：HLB=0 只写低半字（freq=0x1234）", dev:freq_raw(0) == 0x1234, dev:freq_raw(0))
model_w(0x1000)						-- HLB=1：只写高 14 位
model_w(0x4000 + 0x001C)
check("模型：HLB=1 只写高半字（freq=0x71234）", dev:freq_raw(0) == 0x71234,
	string.format("0x%X", dev:freq_raw(0)))
model_w(0x0000)
model_w(0x4000 + 0x3ABC)			-- 切回 HLB=0：低半字替换、高保留
check("模型：再切 HLB=0 低半字覆盖（freq=0x73ABC）", dev:freq_raw(0) == 0x73ABC,
	string.format("0x%X", dev:freq_raw(0)))

-- 1.5 FREQ1 寄存器与 FSELECT 切换
section()
model_w(0x2000)
model_w(0x4000 + tw(1000) % 0x4000)
model_w(0x4000 + math.floor(tw(1000) / 0x4000))
model_w(0x8000 + tw(2000) % 0x4000)
model_w(0x8000 + math.floor(tw(2000) / 0x4000))
check("模型：FREQ0=1kHz / FREQ1=2kHz 独立存放",
	math.abs(dev:freq_raw(0) - tw(1000)) == 0 and math.abs(dev:freq_raw(1) - tw(2000)) == 0)
check("模型：默认 active FREQ0", dev:active_freq_reg() == 0)
model_w(0x2800)						-- B28|FSELECT
check("模型：FSELECT=1 后 active FREQ1 且 freq_hz≈2000",
	dev:active_freq_reg() == 1 and math.abs(dev:freq_hz() - 2000) < 0.1, dev:freq_hz())

-- 1.6 PHASE0/PHASE1 与 PSELECT
section()
model_w(0xC000 + pw(90))
model_w(0xE000 + pw(180))			-- bit13=1 → PHASE1
check("模型：PHASE0=90° PHASE1=180°",
	math.abs(dev:phase_raw(0) - 1024) == 0 and math.abs(dev:phase_raw(1) - 2048) == 0)
check("模型：默认 active PHASE0 = 90°",
	dev:active_phase_reg() == 0 and math.abs(dev:phase_deg() - 90) < 0.01, dev:phase_deg())
model_w(0x2400)						-- B28|PSELECT
check("模型：PSELECT=1 后读 180°", math.abs(dev:phase_deg() - 180) < 0.01, dev:phase_deg())

-- 1.7 波形位解码
local function wave_after(ctrlw)
	section()
	model_w(ctrlw)
	return dev:wave()
end
check("模型：sine = OPBITEN0/MODE0", wave_after(0x2000) == "sine")
check("模型：triangle = MODE1", wave_after(0x2002) == "triangle")
check("模型：square = OPBITEN1/DIV2", wave_after(0x2028) == "square")
check("模型：非法组合 unknown（OPBITEN1/MODE1）", wave_after(0x2022) == "unknown")
check("模型：SLEEP1/SLEEP12 位解码",
	(function()
		section(); model_w(0x20C0)
		return dev:sleep_mclk() and dev:sleep_dac()
	end)())

-- 1.8 非整字帧：奇数尾字节不入字日志；空帧 rx 空表
section()
local r3 = dev.xfer({ 0x20, 0x02, 0xFF })
check("模型：3 字节帧解 1 字、尾字节忽略", #dev:word_log() == 1 and dev:word_log()[1].w == 0x2002)
check("模型：rx 与请求等长（全双工补 0）", #r3 == 3 and r3[1] == 0 and r3[3] == 0)
local r1 = dev.xfer({ 0x55 })
check("模型：1 字节帧无完整字、rx 等长", #dev:word_log() == 1 and #r1 == 1)

-- 1.9 故障注入 + reset 语义
section()
dev:fail_when(function(tx) return tx[1] == 0x20 and tx[2] == 0x28 end)
check("模型：fail_when 命中帧返 nil", dev.xfer({ 0x20, 0x28 }) == nil)
check("模型：fail_when 未命中帧正常", dev.xfer({ 0x20, 0x02 }) ~= nil)
model_w(0x2028)						-- reset 也不能清故障钩子（负路径护栏）
dev:reset()
check("模型：reset 后故障钩子保留（防 build 负路径假绿）", dev.xfer({ 0x20, 0x28 }) == nil)
dev:clear_fail()
check("模型：clear_fail 后恢复", dev.xfer({ 0x20, 0x28 }) ~= nil)
section()
check("模型：reset 清零寄存器/相位/控制",
	dev:freq_raw(0) == 0 and dev:phase_raw(0) == 0 and dev:ctrl() == 0 and dev:muted() == false)

-- ==================== 2) build（真实驱动） ====================

-- 2.1 默认 1kHz/sine/0°
local b = section()
expect_ok("build 默认（1kHz/sine/0°）", function() return build({ fd = fd }) end)
seq_is("build 五字序列：RESET|B28→FREQ0L→FREQ0H→PHASE→放行",
	b, { 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2000 })
do
	local fr = xframes(b)
	check("build 每帧恰好 2 字节（16 位字一帧 CS）",
		#fr == 5 and #fr[1].tx == 2 and #fr[5].tx == 2)
end
check("build 后模型解码 freq≈1000Hz", math.abs(dev:freq_hz() - 1000) < 0.05)
check("build 后 wave=sine / 非静音 / phase=0",
	dev:wave() == "sine" and not dev:muted() and dev:phase_deg() == 0)

-- 2.2 440Hz 方波 90°
b = section()
expect_ok("build 440Hz/square/90°", function()
	return build({ fd = fd, freq = "440", wave = "square", phase = "90" })
end)
seq_is("build 方波序列（OPBITEN|DIV2，相位 0x400）",
	b, { 0x2100, 0x4000 + tw(440), 0x4000, 0xC000 + pw(90), 0x2028 })
check("build 方波解码：wave=square freq≈440 phase=90",
	dev:wave() == "square" and math.abs(dev:freq_hz() - 440) < 0.05
	and math.abs(dev:phase_deg() - 90) < 0.01,
	string.format("%s/%.3f/%.2f", dev:wave(), dev:freq_hz(), dev:phase_deg()))

-- 2.3 三角波大小写不敏感
b = section()
expect_ok("build Triangle（大小写不敏感）", function()
	return build({ fd = fd, wave = "Triangle" })
end)
seq_is("build 三角波放行字 0x2002",
	b, { 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2002 })
check("build 三角波解码", dev:wave() == "triangle")

-- 2.4 参数校验：失败不写任何字（校验全在发字之前）
b = section()
expect_err("build freq=0", function() return build({ fd = fd, freq = "0" }) end, "Invalid freq")
expect_err("build freq 超 12.5MHz", function() return build({ fd = fd, freq = "20000000" }) end, "Invalid freq")
expect_err("build wave 非法", function() return build({ fd = fd, wave = "bogus" }) end, "Invalid wave")
expect_err("build phase=450", function() return build({ fd = fd, phase = "450" }) end, "Invalid phase")
expect_err("build phase=-1", function() return build({ fd = fd, phase = "-1" }) end, "Invalid phase")
check("build 参数校验失败零发字", #xframes(b) == 0)
expect_err("build 缺 fd", function() return build({}) end, "Invalid Argument: fd")
expect_err("build 入参非 table", function() return build(7) end, "Invalid Arguments Type")

-- 2.4b NaN 反例（26.1）：'nan' 经 tonumber 出的是 **number**（Lua 里 truthy），
-- 故 build 侧 `tonumber(x) or 缺省` 的 or 分支永不触发，而 NaN 与任何数比较都
-- 为假，`f <= 0`/`f > WAVE_MAX_F`/`d < 0`/`d >= 360` 四条区间判定一律放行
-- （±inf 会被上/下界接住，只有 NaN 穿得过去）。后果两级：freq_hz/phase_deg
-- 是模块级状态，NaN 先落进去再发字——直接违反源码写的「全部校验通过后才落
-- 模块状态（失败半途不得污染跨 call 状态）」；随后 tuning_word(NaN) 的字节被
-- HAL 挡成 nil，报 "Failed to send AD9833 freq LSBs"，把配置笔误误报成 SPI
-- 总线故障。同列写 '-'/'abc' 走的是归缺省。
b = section()
expect_ok("build freq='nan' 同归缺省 1kHz", function()
	return build({ fd = fd, freq = "nan" })
end)
seq_is("build freq NaN 仍发缺省五字序列（频率字按 1000Hz）", b,
	{ 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2000 })
b = section()
expect_ok("build phase='nan' 同归缺省 0°", function()
	return build({ fd = fd, phase = "nan" })
end)
seq_is("build phase NaN 仍发缺省五字序列（相位字 0xC000）", b,
	{ 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2000 })

-- 2.5 build 逐字失败负路径（5 个字各失败一次）
local function fail_frame(label, hi, lo, msgpat)
	local m = section()
	dev:fail_when(function(tx) return tx[1] == hi and tx[2] == lo end)
	expect_err(label, function() return build({ fd = fd }) end, msgpat)
	dev:clear_fail()
	return m
end
fail_frame("build 失败@控制字 RESET|B28", 0x21, 0x00, "control word")
fail_frame("build 失败@FREQ0 低半字", 0x69, 0xF1, "freq LSBs")
fail_frame("build 失败@FREQ0 高半字", 0x40, 0x00, "freq MSBs")
fail_frame("build 失败@相位字", 0xC0, 0x00, "phase word")
fail_frame("build 失败@放行波形字", 0x20, 0x00, "waveform word")

-- 负路径后器件仍可正常 build（故障已清、状态可重建）
b = section()
expect_ok("负路径后重新 build 成功", function() return build({ fd = fd }) end)
seq_is("重建五字序列完整", b, { 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2000 })

-- ==================== 3) call（真实驱动） ====================

-- 3.1 频率变更（三角波态：控制字保持三角波位）
section()
expect_ok("前置 build triangle", function() return build({ fd = fd, wave = "triangle" }) end)
local c = #vbus.txlog
expect_ok("call freq=44000", function() return call({ fd = fd, freq = "44000" }) end)
local tw44 = tw(44000)
seq_is("call 频率三字：B28 控制字→FREQ0 低→FREQ0 高（低 14 位在前）",
	c, { 0x2002, 0x4000 + tw44 % 0x4000, 0x4000 + math.floor(tw44 / 0x4000) })
check("call 后模型解码 freq≈44000Hz 且波形保持三角",
	math.abs(dev:freq_hz() - 44000) < 1 and dev:wave() == "triangle",
	string.format("%.3f/%s", dev:freq_hz(), dev:wave()))

-- 3.2 无键 call：仅回显状态，不发字
c = #vbus.txlog
local echo = expect_ok("call 无键回显", function() return call({ fd = fd }) end)
check("回显 freq/wave/phase/mute",
	echo and echo.freq == 44000 and echo.wave == "triangle"
	and echo.phase == 0 and echo.mute == 0,
	echo and string.format("%s/%s/%s/%s", tostring(echo.freq), tostring(echo.wave),
		tostring(echo.phase), tostring(echo.mute)))
check("无键 call 零发字", #xframes(c) == 0)

-- 3.3 波形切换
c = #vbus.txlog
expect_ok("call wave=sine", function() return call({ fd = fd, wave = "sine" }) end)
seq_is("波形切换单字 0x2000", c, { 0x2000 })
check("模型 wave=sine", dev:wave() == "sine")

-- 3.4 静音/放行与静音态频率变更
c = #vbus.txlog
expect_ok("call mute=1", function() return call({ fd = fd, mute = "1" }) end)
seq_is("静音置 RESET（0x2100）", c, { 0x2100 })
check("模型 muted=true", dev:muted() == true)

c = #vbus.txlog
expect_ok("静音态 call freq=2000", function() return call({ fd = fd, freq = "2000" }) end)
seq_is("静音态频率三字保持 RESET（0x2100 起头）",
	c, { 0x2100, 0x4000 + tw(2000) % 0x4000, 0x4000 + math.floor(tw(2000) / 0x4000) })
check("静音态模型仍 muted", dev:muted() == true)

c = #vbus.txlog
expect_ok("call mute=0 放行", function() return call({ fd = fd, mute = "0" }) end)
seq_is("放行清 RESET（0x2000）", c, { 0x2000 })
check("模型 muted=false / freq≈2000", not dev:muted() and math.abs(dev:freq_hz() - 2000) < 0.1)

-- 3.5 相位变更
c = #vbus.txlog
expect_ok("call phase=180", function() return call({ fd = fd, phase = "180" }) end)
seq_is("相位字 180° = 0xC800", c, { 0xC000 + pw(180) })
check("模型 phase≈180°", math.abs(dev:phase_deg() - 180) < 0.01, dev:phase_deg())

-- 3.6 12.5MHz 上限（28 位满量程 raw=0x800000：低半字 0、高半字 0x2000）
section()
expect_ok("前置 build", function() return build({ fd = fd }) end)
c = #vbus.txlog
expect_ok("call freq=12.5MHz 上限", function() return call({ fd = fd, freq = "12500000" }) end)
seq_is("12.5MHz：控制字→0x4000（低 14=0）→0x6000（高 14=0x2000）",
	c, { 0x2000, 0x4000, 0x6000 })
check("模型 freq0=2^27（0x8000000）且 freq_hz=12.5MHz",
	dev:freq_raw(0) == 0x8000000 and math.abs(dev:freq_hz() - 12500000) < 1,
	string.format("0x%X", dev:freq_raw(0)))

-- 3.7 call 参数校验零发字
c = section()
expect_ok("校验前重建 build", function() return build({ fd = fd }) end)
c = #vbus.txlog
expect_err("call freq=-1", function() return call({ fd = fd, freq = "-1" }) end, "Invalid freq")
expect_err("call freq=0", function() return call({ fd = fd, freq = "0" }) end, "Invalid freq")
expect_err("call freq 超上限", function() return call({ fd = fd, freq = "12500001" }) end, "Invalid freq")
expect_err("call wave 非法", function() return call({ fd = fd, wave = "saw" }) end, "Invalid wave")
expect_err("call phase=360", function() return call({ fd = fd, phase = "360" }) end, "Invalid phase")
check("call 参数校验失败零发字", #xframes(c) == 0)
expect_err("call 缺 fd", function() return call({ freq = "1000" }) end, "Invalid Argument: fd")
expect_err("call 入参非 table", function() return call("x") end, "Invalid Arguments")

-- 3.7b NaN 反例（26.1）：call 侧三列只判 `== nil` 或裸 `tonumber`，NaN 一律
-- 穿透。freq/phase 的后果同 2.4b（先污染模块状态、再误报成 SPI 故障）；mute
-- 列最重——`mute_v ~= nil` 且 `NaN ~= 0` 皆为真，于是 mute="nan" 会**静默把
-- DDS 静音**，而调用方从未要求静音；同列写 "abc" 走的是「整块跳过、零发字」。
-- mute 用例排在本组最后（置位 muted 会影响后续控制字，3.8 自带前置 build）。
section()
expect_ok("NaN 组前置 build", function() return build({ fd = fd }) end)
c = #vbus.txlog
expect_err("call freq='nan' 报 Invalid freq（非 SPI 故障）",
	function() return call({ fd = fd, freq = "nan" }) end, "Invalid freq")
expect_err("call phase='nan' 报 Invalid phase",
	function() return call({ fd = fd, phase = "nan" }) end, "Invalid phase")
check("freq/phase NaN 零发字", #xframes(c) == 0, #xframes(c))
do
	-- 无键回显读的是驱动的模块级 freq_hz/phase_deg，正是源码注释「全部校验
	-- 通过后才落模块状态（失败半途不得污染跨 call 状态）」要护的那个状态
	local e = expect_ok("freq/phase NaN 后无键回显",
		function() return call({ fd = fd }) end)
	check("freq/phase NaN 未污染跨 call 状态（回显仍 1000Hz/0°）",
		e and math.abs(e.freq - 1000) < 0.05 and e.phase == 0,
		string.format("%s/%s", tostring(e and e.freq), tostring(e and e.phase)))
end

c = #vbus.txlog
expect_ok("call mute='abc' 视同未给（跳过、零发字）",
	function() return call({ fd = fd, mute = "abc" }) end)
check("mute 非法串零发字、模型非静音",
	#xframes(c) == 0 and dev:muted() == false, #xframes(c))
c = #vbus.txlog
expect_ok("call mute='nan' 同视未给",
	function() return call({ fd = fd, mute = "nan" }) end)
check("mute NaN 零发字、模型仍非静音（未被静默静音）",
	#xframes(c) == 0 and dev:muted() == false,
	"xframes=" .. #xframes(c) .. " muted=" .. tostring(dev:muted()))

-- 3.8 call 逐字失败负路径
section()
expect_ok("失败路径前置 build（sine 非静音）", function() return build({ fd = fd }) end)

local function fail_call(label, hi, lo, fn, msgpat)
	dev:fail_when(function(tx) return tx[1] == hi and tx[2] == lo end)
	expect_err(label, fn, msgpat)
	dev:clear_fail()
end
-- 注：驱动在发送前就落 wave_str，故负路径用与 build 相同的 sine（失败的波形
-- 切换仍会污染驱动模块状态，用 triangle 会让后续控制字变 0x2002/0x2102）
fail_call("call 失败@波形控制字", 0x20, 0x00,
	function() return call({ fd = fd, wave = "sine" }) end, "waveform word")
check("波形字失败模型仍 sine", dev:wave() == "sine")
fail_call("call 失败@相位字", 0xC8, 0x00,
	function() return call({ fd = fd, phase = "180" }) end, "phase word")
check("相位字失败模型 phase 仍 0", dev:phase_deg() == 0)
-- 频率三字：控制字/FREQ0L/FREQ0H（此时驱动未静音，控制字 0x2000；
-- 注：mute 失败用例必须排在频率之后——驱动在发送前就落 muted，失败的
-- mute=1 会让后续控制字变 0x2100）
fail_call("call freq 失败@控制字", 0x20, 0x00,
	function() return call({ fd = fd, freq = "44000" }) end, "control word")
fail_call("call freq 失败@低半字",
	math.floor((0x4000 + tw(44000) % 0x4000) / 256),
	(0x4000 + tw(44000) % 0x4000) % 256,
	function() return call({ fd = fd, freq = "44000" }) end, "freq LSBs")
fail_call("call freq 失败@高半字",
	math.floor((0x4000 + math.floor(tw(44000) / 0x4000)) / 256),
	(0x4000 + math.floor(tw(44000) / 0x4000)) % 256,
	function() return call({ fd = fd, freq = "44000" }) end, "freq MSBs")
-- 静音控制字放最后（会把驱动模块 muted 置位，重建时才复位）
fail_call("call mute=1 失败@控制字", 0x21, 0x00,
	function() return call({ fd = fd, mute = "1" }) end, "control word")
check("静音字失败模型仍非静音", dev:muted() == false)

-- 总线故障恢复的现实路径：半字失败会让器件 B28 锁存停在半截，
-- 驱动侧重建（RESET|B28+完整五字）后频率链路恢复正常
local rb = section()
expect_ok("负路径后重建 build", function() return build({ fd = fd, freq = "1000" }) end)
seq_is("重建五字序列完整", rb, { 0x2100, 0x4000 + tw(1000), 0x4000, 0xC000, 0x2000 })
c = #vbus.txlog
expect_ok("重建后 call freq=2000", function() return call({ fd = fd, freq = "2000" }) end)
check("恢复后模型解码 freq≈2000、三字完整",
	math.abs(dev:freq_hz() - 2000) < 0.1 and #xframes(c) == 3,
	string.format("%.4f/%d 帧", dev:freq_hz(), #xframes(c)))

-- ==================== 4) destroy ====================

expect_ok("destroy OK（无总线操作）", function() return destroy({}) end)

tester.summary("test_ad9833")

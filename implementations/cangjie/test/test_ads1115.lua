-- test_ads1115.lua —— ADS1115 真实驱动 + 虚拟 I2C 总线 + 字寻址/oneshot 模型
-- 用法（项目根目录）: luajit test/test_ads1115.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 326 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/ads1115.lua 模型」。本器件是 virtbus 库【首个
-- 字寻址 16 位寄存器 + oneshot 转换门/OS 就绪握手器件】（字寻址骨架同族
-- INA219：寄存器号 0x00~0x03 各代表一个 16 位字，绝不能套字节地址
-- regmap；但 INA219 连续模式无转换门，ADS1115 驱动走单次转换）：
--   0x00 CONVERSION 16 位有符号结果（直接编码，非 ADS1015 的 12 位左对齐）
--   0x01 CONFIG [15]OS [14:12]MUX [11:9]PGA [8]MODE [7:5]DR [4:0]比较器
-- OS 位读写语义相反：写 1（单次模式）启动转换，读时转换中=0/空闲=1，
-- 故模型 shadow 落写值、读回 bit15 按状态动态合成；转换门 = 1000/SPS
-- （125/62.5/31.25/15.625/7.8125/4/2.1053/1.1628ms），驱动 1ms 步进
-- 轮询（每档实际睡眠 = ceil(门限)），200ms 预算覆盖最慢 8SPS 档。
--
-- 覆盖：模型侧 POR/字寻址不串读/坏长度与越界/OS 动态合成与八档门边界/
-- 通道隔离/s16 补码/连续模式/阈值照读照写/武装零等待一次性消费/
-- virt_tick 峰谷周期/物理量 PGA 量化独立交叉/六类钩子与 reset 保留/
-- 卡死武装无效；真实 build 配置字与参数归一/写读事务序列/五路负路径；
-- 真实 call 启动前读保 PGA/DR→启动字→九次轮询（128SPS 档）→结果读
-- 完整序列与睡眠拍数、正负满码/通道与四差分对 MUX 字/PGA 回读与 6/7
-- 冗余/慢档等待/超时/三路读失败/virt_tick 零睡眠闭环；destroy 读改写。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/ads1115.lua")
vbus.reset()

local ADDR = 0x48
local dev = smod.new()
vbus.attach("ADS1115@0x48", ADDR, dev)
vbus.load_driver("modules/ADS1115.lua")

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
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
-- 窗口内字写 {ptr,hi,lo} 的拼字序列
local function write_words(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 3 then t[#t + 1] = b[1] * 65536 + b[2] * 256 + b[3] end
	end
	return t
end
-- 窗口内单字节指针写的指针序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end

local PGA_FS = { [0] = 6.144, 4.096, 2.048, 1.024, 0.512, 0.256 }
local CONV_MS = { [0] = 125, 62.5, 31.25, 15.625, 7.8125, 4, 1000/475, 1000/860 }
-- 驱动 1ms 步进轮询每档实际睡眠拍数 = ceil(转换门)
local SLEEP_TAB = { [0] = 125, 63, 32, 16, 8, 4, 3, 2 }
local DR_BITS = { [0] = 0x00, [1] = 0x20, [2] = 0x40, [3] = 0x60,
                  [4] = 0x80, [5] = 0xA0, [6] = 0xC0, [7] = 0xE0 }

-- 直接打一次 oneshot（写 OS=1 启动字，MUX=AIN0/PGA2），dr 为速率索引
local function start_oneshot(dr)
	local lo = DR_BITS[dr] + 0x03
	dev.write({ 0x01, 0xC5, lo })
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

check("POR CONFIG 读 0x8583", dev:config() == 0x8583, string.format("0x%04X", dev:config()))
check("POR shadow 0x8583", dev:config_shadow() == 0x8583)
check("POR LO_THRESH 0x8000", dev:lo_thresh() == 0x8000, string.format("0x%04X", dev:lo_thresh()))
check("POR HI_THRESH 0x7FFF", dev:hi_thresh() == 0x7FFF, string.format("0x%04X", dev:hi_thresh()))
check("POR CONVERSION 0", dev:conversion_raw() == 0)
check("POR 不 busy", not dev:busy())
check("POR active_mux=4(AIN0)", dev:active_mux() == 4)

-- 字寻址不串读：相邻字各自独立
dev.write({ 0x00, 0x12, 0x34 })
dev.write({ 0x01, 0x45, 0x83 })
dev.write({ 0x00 })
local c0 = dev.read(2)
check("字 0x00 读回 0x1234", c0[1] == 0x12 and c0[2] == 0x34, table.concat(c0, ","))
dev.write({ 0x01 })
local c1 = dev.read(2)
-- 0x4583 为 OS=0 单次写，空闲读回 bit15 动态合成 1 → 0xC583；hi/lo 仍是本字
check("字 0x01 读回本字 hi/lo（OS 合成 0xC583，不串字）",
      c1[1] == 0xC5 and c1[2] == 0x83, table.concat(c1, ","))

-- 坏事务：恰 1（指针）或恰 3（字）合法
check("空表写 NACK", dev.write({}) == false)
check("2 字节写 NACK", dev.write({ 0x01, 0x45 }) == false)
check("4 字节写 NACK", dev.write({ 0x01, 0x45, 0x83, 0x00 }) == false)
check("非 table 写 NACK", dev.write(7) == false)
check("指针越界 0x04 NACK", dev.write({ 0x04 }) == false)
check("字写越界寄存器 NACK", dev.write({ 0x05, 0x00, 0x00 }) == false)
check("read(0) NACK", dev.read(0) == nil)

-- OS 位读写相反：OS=0 单次写不启动；OS=1 启动后转换中读 0、空闲读 1
mark = section()
check("OS=0 单次写 ACK", dev.write({ 0x01, 0x45, 0x83 }))
check("OS=0 不启动（start_count=0）", dev:start_count() == 0, tostring(dev:start_count()))
check("OS=0 后空闲读回合成 OS=1（0xC583）", dev:config() == 0xC583,
      string.format("0x%04X", dev:config()))
check("shadow 保留驱动写值 0x4583", dev:config_shadow() == 0x4583,
      string.format("0x%04X", dev:config_shadow()))

-- 128SPS oneshot 门限 7.8125ms：启动即 busy、OS 读 0、结果完成前不变
dev:set_result(4, 32767)
start_oneshot(4)
check("OS=1 启动计数 +1", dev:start_count() == 1)
check("启动即 busy", dev:busy())
check("转换中 OS 读 0（0x4583）", dev:config() == 0x4583, string.format("0x%04X", dev:config()))
check("完成前 CONVERSION 保持旧值 0", dev:conversion_raw() == 0)
dev:advance(7)
check("7ms 未过 7.8125 门仍 busy", dev:busy())
dev:advance(0.8)
check("7.8ms 仍 busy", dev:busy())
dev:advance(0.02)
check("7.82ms 过門就绪", not dev:busy())
check("完成后 OS 读 1", dev:config() == 0xC583, string.format("0x%04X", dev:config()))
check("完成时装入注入码 32767", dev:conversion_raw() == 32767, tostring(dev:conversion_raw()))

-- 八档转换门边界：T-1ms 仍 busy（整数档 T 本身完成）
for dr = 0, 7 do
	local d0 = section()
	start_oneshot(dr)
	dev:advance(CONV_MS[dr] - 1)
	check(string.format("DR=%d 门前 1ms busy", dr), dev:busy())
	dev:advance(1)
	check(string.format("DR=%d 门后就绪", dr), not dev:busy())
end

-- s16 补码：正满/负满/-1
mark = section()
for _, raw in ipairs({ { 32767, 0x7FFF }, { -32768, 0x8000 }, { -1, 0xFFFF }, { 0, 0 } }) do
	dev:set_result(4, raw[1])
	start_oneshot(4); dev:advance(8)
	dev.write({ 0x00 })
	local b = dev.read(2)
	local u = b[1] * 256 + b[2]
	check(string.format("码 %d 帧编码 0x%04X", raw[1], raw[2]), u == raw[2],
	      string.format("0x%04X", u))
	check(string.format("码 %d s16 观察口还原", raw[1]), dev:conversion_raw() == raw[1])
end

-- 通道隔离：MUX 各自的注入码只在对应通道转换时装入
mark = section()
dev:set_result(4, 111)		-- AIN0
dev:set_result(6, 222)		-- AIN2
dev:set_result(0, -33)		-- 差分 0-1
-- 切 AIN2（0xE583）
dev.write({ 0x01, 0xE5, 0x83 }); dev:advance(8)
check("切 AIN2 后 active_mux=6", dev:active_mux() == 6)
check("AIN2 装入 222", dev:conversion_raw() == 222, tostring(dev:conversion_raw()))
-- 差分 0-1（0x8583）
dev.write({ 0x01, 0x85, 0x83 }); dev:advance(8)
check("差分 0-1 active_mux=0", dev:active_mux() == 0)
check("差分码 -33 装入", dev:conversion_raw() == -33, tostring(dev:conversion_raw()))
-- 回 AIN0
dev.write({ 0x01, 0xC5, 0x83 }); dev:advance(8)
check("回 AIN0 装入 111", dev:conversion_raw() == 111, tostring(dev:conversion_raw()))

-- 连续模式（MODE=0）：不 busy、OS 读恒 0、结果立即装入
mark = section()
dev:set_result(4, 1234)
dev.write({ 0x01, 0x44, 0x83 })		-- MUX=AIN0 MODE=0 DR=128，OS=0
check("连续写不 busy", not dev:busy())
check("连续模式 OS 读 0（0x4483）", dev:config() == 0x4483, string.format("0x%04X", dev:config()))
check("连续结果立即装入 1234", dev:conversion_raw() == 1234)
check("连续写 start_count 不增", dev:start_count() == 0)

-- 阈值寄存器照读照写
mark = section()
dev.write({ 0x02, 0x12, 0x34 })
dev.write({ 0x03, 0xAB, 0xCD })
check("LO 照写 0x1234", dev:lo_thresh() == 0x1234, string.format("0x%04X", dev:lo_thresh()))
check("HI 照写 0xABCD", dev:hi_thresh() == 0xABCD, string.format("0x%04X", dev:hi_thresh()))

-- 物理量 API 独立量化交叉（V*32768/FS 公式独立于驱动，常量另算）
mark = section()
local function code_after_single(ch, v, pga)
	section()
	dev:set_single(ch, v, pga)
	local mux = 4 + ch
	dev.write({ 0x01, 0x80 + mux * 0x10 + pga * 2, 0x83 })
	dev:advance(8)
	return dev:conversion_raw()
end
check("AIN0 1.5V@±2.048 码", code_after_single(0, 1.5, 2) == math.floor(1.5 * 32768 / 2.048 + 0.5))
check("AIN3 -0.2V@±0.256 码", code_after_single(3, -0.2, 5) == math.floor(-0.2 * 32768 / 0.256 + 0.5))
check("AIN1 满程钳 +32767", code_after_single(1, 10, 0) == 32767)
section()
dev:set_diff(2, -7.0, 0)		-- -7V 超 ±6.144 满程
dev.write({ 0x01, 0x80 + 2 * 0x10, 0x83 }); dev:advance(8)
check("差分负满程钳 -32768", dev:conversion_raw() == -32768, tostring(dev:conversion_raw()))

-- virt_tick：确定性正弦 1.65±0.25V，武装零等待、一次性消费、32 拍周期
mark = section()
local function tick_raw(n)
	section()
	dev:virt_tick(n)
	if not dev:armed() then return nil, "not armed" end
	start_oneshot(4)			-- 武装启动
	if dev:busy() then return nil, "armed but busy" end
	if dev:armed() then return nil, "armed not consumed" end
	return dev:conversion_raw()
end
local r0 = tick_raw(0)
local r8 = tick_raw(8)
local r24 = tick_raw(24)
local r32 = tick_raw(32)
local exp0 = math.floor(1.65 * 32768 / 2.048 + 0.5)
local exp8 = math.floor((1.65 + 0.25) * 32768 / 2.048 + 0.5)
check("virt_tick n0 武装零等待码", r0 == exp0, tostring(r0))
check("virt_tick n8 峰值码", r8 == exp8, tostring(r8) .. "/" .. tostring(exp8))
check("n8 峰 > n0", r8 > r0)
check("n24 谷 < n0", r24 < r0)
check("n32 = n0 周期", r32 == r0, tostring(r32) .. "/" .. tostring(r0))
-- 未武装的启动必须走真实门（武装只影响一次）
section()
dev:virt_tick(0)
start_oneshot(4); dev:advance(8)	-- 第一次消费武装
dev:set_result(4, 12345)
start_oneshot(4)
check("武装消费后第二次启动真实 busy", dev:busy())
dev:advance(8)
check("第二次转换完成 12345", dev:conversion_raw() == 12345)

-- 卡死：永不就绪、advance 不推进、武装无效
mark = section()
dev:set_never_ready(true)
dev:virt_tick(0)
start_oneshot(4)
check("卡死时武装无效仍 busy", dev:busy())
dev:advance(500)
check("卡死后 advance 500ms 不就绪", dev:busy())
check("卡死 OS 恒读 0", dev:config() == 0x4583, string.format("0x%04X", dev:config()))
dev:set_never_ready(false)
dev:advance(8)
check("解除卡死后完成", not dev:busy() and dev:conversion_raw() ~= nil)

-- 钩子：nack/nack_read/nack_write/谓词；reset 保留钩子
mark = section()
dev.nack = true
check("nack 写失败", dev.write({ 0x01, 0x45, 0x83 }) == false)
check("nack 读失败", dev.read(2) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write 写失败", dev.write({ 0x01, 0x45, 0x83 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 读失败", dev.read(2) == nil)
dev.nack_read = false
dev:fail_write(function(b) return #b == 3 and b[1] == 0x02 end)
check("谓词放行 CONFIG 写", dev.write({ 0x01, 0x45, 0x83 }))
check("谓词拦截 LO 写", dev.write({ 0x02, 0x80, 0x00 }) == false)
dev:fail_read(function(p) return p == 0x03 end)
dev.write({ 0x03 })
check("谓词拦截 HI 读", dev.read(2) == nil)
dev:fail_read(); dev:fail_write()
dev.nack_read = true
dev:reset()
check("reset 保留故障钩子", dev.nack_read == true)
check("reset 回 POR CONFIG", dev:config() == 0x8583, string.format("0x%04X", dev:config()))
check("reset 清启动计数", dev:start_count() == 0)
dev:clear_faults()

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
mark = section()
local b = expect_ok("build 默认 AIN0/±2.048V/128SPS", function()
	return build({ fd = fd, address = "0x48" })
end)
local ws = write_words(mark)
check("build 恰一笔字写", #ws == 1, tostring(#ws))
check("build 配置字 0x4583", ws[1] == 0x01 * 65536 + 0x4583,
      string.format("0x%06X", ws[1] or 0))
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR)
local rs = reads(mark)
check("build 一次 2B 回读", #rs == 1 and rs[1] == 2, table.concat(rs, ","))
check("build 零睡眠", sleep_total == 0, tostring(sleep_total))

-- 自定义全档
mark = section()
expect_ok("build 自定义 AIN3/PGA5/DR7", function()
	return build({ fd = fd, address = "0x48", pga = "5", dr = "7", channel = "3" })
end)
ws = write_words(mark)
check("build 配置字 0x7BE3", ws[1] == 0x01 * 65536 + 0x7BE3,
      string.format("0x%06X", ws[1] or 0))

-- 参数归一：越界全部回默认
mark = section()
expect_ok("build 越界参数归一默认", function()
	return build({ fd = fd, address = "0x48", pga = 9, dr = -1, channel = 99 })
end)
ws = write_words(mark)
check("归一后仍 0x4583", ws[1] == 0x01 * 65536 + 0x4583, string.format("0x%06X", ws[1] or 0))

-- build 负路径
section()
expect_err("build 非表参数", function() return build("x") end, "Invalid Arguments")
section()
expect_err("build 缺 fd", function() return build({ address = "0x48" }) end, "fd")
section()
expect_err("build 缺 addr", function() return build({ fd = fd }) end, "addr")
section()
expect_err("build set_addr 失败（fd=99）", function()
	return build({ fd = 99, address = "0x48" })
end, "set_addr failed")
section()
dev:fail_write(function(bb) return #bb == 3 and bb[1] == 0x01 end)
expect_err("build 配置写失败", function()
	return build({ fd = fd, address = "0x48" })
end, "Failed to write")
section()
dev.nack_read = true
expect_err("build 回读失败", function()
	return build({ fd = fd, address = "0x48" })
end, "Failed to read back")
section()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 默认档完整序列：set_addr → 读 CONFIG(指针+读) → 字写启动 →
-- 1ms 步进轮询 9 次 CONFIG（128SPS：8 拍睡眠）→ 读 CONVERSION
mark = section()
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x48" }) end)
dev:set_result(4, 32767)
mark = #vbus.txlog		-- call 窗口在 build 之后起算
local res = expect_ok("call 正满码 128SPS", function()
	return call({ fd = fd, address = "0x48" })
end)
if res then
	check("raw=32767", res.raw == 32767, tostring(res.raw))
	check("voltage=32767*2.048/32768", near(res.voltage, 32767 * 2.048 / 32768),
	      tostring(res.voltage))
end
check("call 一次 set_addr", #set_addrs(mark) == 1)
local cw = write_words(mark)
check("call 恰一笔启动字写", #cw == 1 and cw[1] == 0x01 * 65536 + 0xC583,
      string.format("0x%06X", cw[1] or 0))
local pw = ptr_writes(mark)
check("指针写 11 笔（10×CONFIG+1×CONVERSION）", #pw == 11, tostring(#pw))
local n1, n0 = 0, 0
for _, p in ipairs(pw) do if p == 0x01 then n1 = n1 + 1 elseif p == 0x00 then n0 = n0 + 1 end end
check("CONFIG 指针 10（启动前 1+轮询 9）", n1 == 10, tostring(n1))
check("CONVERSION 指针 1", n0 == 1, tostring(n0))
rs = reads(mark)
check("读事务 11 笔×2B", #rs == 11, tostring(#rs))
-- 轮询首读 t=0 必忙，故 8 拍 1ms 睡眠；末读 CONVERSION 在就绪后
check("128SPS 轮询睡眠 8ms", sleep_total == 8, tostring(sleep_total))

-- 负码 / -1 LSB
for _, raw in ipairs({ -32768, -1 }) do
	section()
	expect_ok("call 前 build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:set_result(4, raw)
	mark = #vbus.txlog
	res = expect_ok("call 码 " .. raw, function() return call({ fd = fd, address = "0x48" }) end)
	if res then
		check("raw 还原 " .. raw, res.raw == raw, tostring(res.raw))
		check("voltage 换算 " .. raw, near(res.voltage, raw * 2.048 / 32768),
		      tostring(res.voltage))
	end
end

-- call 参数切通道：启动字 MUX 表
local CH_WORD = { [0] = 0xC583, [1] = 0xD583, [2] = 0xE583, [3] = 0xF583 }
for ch = 0, 3 do
	section()
	expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:set_result(4 + ch, 100 + ch)
	mark = #vbus.txlog
	res = expect_ok("call 切 AIN" .. ch, function()
		return call({ fd = fd, address = "0x48", channel = ch })
	end)
	cw = write_words(mark)
	check(string.format("AIN%d 启动字 0x%04X", ch, CH_WORD[ch]),
	      cw[1] == 0x01 * 65536 + CH_WORD[ch], string.format("0x%06X", cw[1] or 0))
	if res then check("通道码隔离 " .. (100 + ch), res.raw == 100 + ch, tostring(res.raw)) end
end

-- PGA 缺省回读芯片配置：build ±4.096V（PGA=1）
section()
expect_ok("build PGA1", function() return build({ fd = fd, address = "0x48", pga = "1" }) end)
dev:set_result(4, 16000)
mark = #vbus.txlog
res = expect_ok("call 无 pga 参回读 PGA=1", function()
	return call({ fd = fd, address = "0x48" })
end)
if res then check("按 ±4.096V 换算 =2.0V", near(res.voltage, 16000 * 4.096 / 32768),
                  tostring(res.voltage)) end

-- PGA 字段 6/7 冗余编码 → ±0.256V（0.3.2 修复回归）
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev.write({ 0x01, 0x4D, 0x83 })		-- 外部把芯片 PGA 字段改成 110（OS=0 不启动）
dev:set_result(4, 1000)
mark = #vbus.txlog
res = expect_ok("call PGA=6 冗余编码", function()
	return call({ fd = fd, address = "0x48" })
end)
cw = write_words(mark)
check("PGA6 启动字 0xCD83", cw[1] == 0x01 * 65536 + 0xCD83, string.format("0x%06X", cw[1] or 0))
if res then check("按 ±0.256V 换算", near(res.voltage, 1000 * 0.256 / 32768),
                  tostring(res.voltage)) end

-- 差分四对 MUX 字
local DIFF = { { 0, 1, 0x8583 }, { 0, 3, 0x9583 }, { 1, 3, 0xA583 }, { 2, 3, 0xB583 } }
for _, t in ipairs(DIFF) do
	section()
	expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:set_result((t[1] == 0 and t[2] == 1) and 0 or (t[1] == 0 and 1 or t[1]), -300)
	mark = #vbus.txlog
	expect_ok(string.format("call 差分 %d-%d", t[1], t[2]), function()
		return call({ fd = fd, address = "0x48", pos = t[1], neg = t[2] })
	end)
	cw = write_words(mark)
	check(string.format("差分 %d-%d 启动字 0x%04X", t[1], t[2], t[3]),
	      cw[1] == 0x01 * 65536 + t[3], string.format("0x%06X", cw[1] or 0))
end
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
expect_err("call 不支持差分对 1-2", function()
	return call({ fd = fd, address = "0x48", pos = 1, neg = 2 })
end, "Unsupported diff")
expect_err("call 差分参数非数字", function()
	return call({ fd = fd, address = "0x48", pos = "-", neg = 1 })
end, "not a number")
expect_err("call 非法通道 4", function()
	return call({ fd = fd, address = "0x48", channel = 4 })
end, "Invalid channel")
expect_err("call 非表参数", function() return call(11) end, "Invalid Arguments")
expect_err("call 缺 addr", function() return call({ fd = fd }) end, "addr")

-- DR 八档：每档轮询睡眠拍数 = ceil(转换门)
for dr = 0, 7 do
	section()
	expect_ok("build DR" .. dr, function()
		return build({ fd = fd, address = "0x48", dr = tostring(dr) })
	end)
	dev:set_result(4, 5)
	mark = #vbus.txlog
	res = expect_ok("call DR" .. dr .. " 等到转换", function()
		return call({ fd = fd, address = "0x48" })
	end)
	check(string.format("DR=%d 睡眠 %dms（ceil 门限）", dr, SLEEP_TAB[dr]),
	      sleep_total == SLEEP_TAB[dr], tostring(sleep_total))
	if res then check("DR" .. dr .. " 结果码 5", res.raw == 5, tostring(res.raw)) end
end

-- 转换超时：卡死，轮询满 200ms 预算
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:set_never_ready(true)
mark = #vbus.txlog
expect_err("call 转换超时", function()
	return call({ fd = fd, address = "0x48" })
end, "Conversion timeout")
check("超时前轮询满 200ms", sleep_total == 200, tostring(sleep_total))
-- 超时时轮询读了 200 次 CONFIG，无 CONVERSION 读
pw = ptr_writes(mark)
local seen_conv = false
for _, p in ipairs(pw) do if p == 0x00 then seen_conv = true end end
check("超时路径不读 CONVERSION", not seen_conv)
section()

-- call 三路读失败 + 启动写失败
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev.nack_read = true
expect_err("call 读 CONFIG 失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to read config")
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:fail_write(function(bb) return #bb == 3 and bb[1] == 0x01 end)
expect_err("call 启动写失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to start conversion")
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:fail_read(function(p) return p == 0x00 end)	-- 只 NACK 结果读，轮询正常
dev:set_result(4, 1)
expect_err("call 读 CONVERSION 失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to read conversion")
section()
expect_err("call set_addr 失败（fd=99）", function()
	return call({ fd = 99, address = "0x48" })
end, "set_addr failed")
section()

-- virt_tick 闭环：守护式武装，call 零真实睡眠、电压跟正弦走
local function v_of(n) return 1.65 + 0.25 * math.sin(n * (2 * math.pi / 32)) end
for _, n in ipairs({ 0, 8, 24 }) do
	section()
	expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:virt_tick(n)
	mark = #vbus.txlog
	res = expect_ok("virt_tick n=" .. n .. " call", function()
		return call({ fd = fd, address = "0x48" })
	end)
	check(string.format("n=%d 武装零睡眠", n), sleep_total == 0, tostring(sleep_total))
	if res then
		check(string.format("n=%d 正弦电压闭环", n),
		      near(res.voltage, v_of(n), 0.0001), tostring(res.voltage))
	end
end

-- =====================================================================
-- 组 4：destroy（读改写置 MODE=1 + 清 OS，不误启动转换）
-- =====================================================================
mark = section()
-- 预置芯片为连续模式配置（OS=0 MODE=0），destroy 应读出 0x4483、写回 0x4583
dev.write({ 0x01, 0x44, 0x83 })
expect_ok("destroy 置单次断电态", function()
	return destroy({ fd = fd, address = "0x48" })
end)
cw = write_words(mark)
check("destroy 读改写字 0x4583", #cw == 1 and cw[1] == 0x01 * 65536 + 0x4583,
      string.format("0x%06X", cw[1] or 0))
check("destroy 一次 set_addr", #set_addrs(mark) == 1)
check("destroy 一次 CONFIG 读", #reads(mark) == 1)
check("写回 OS=0 未启动转换", dev:start_count() == 0 and not dev:busy())
check("写回后 shadow=0x4583（MODE=1）", dev:config_shadow() == 0x4583,
      string.format("0x%04X", dev:config_shadow()))

mark = section()
dev.nack_read = true
expect_ok("destroy 读失败安全返回", function()
	return destroy({ fd = fd, address = "0x48" })
end)
check("读失败零字写", #write_words(mark) == 0, tostring(#write_words(mark)))
section()

expect_err("destroy 缺 fd", function() return destroy({ address = "0x48" }) end, "fd")
expect_err("destroy 缺 addr", function() return destroy({ fd = fd }) end, "addr")
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments")
section()
expect_err("destroy set_addr 失败", function()
	return destroy({ fd = 99, address = "0x48" })
end, "set_addr failed")

-- ==================== 汇总 ====================
tester.summary()

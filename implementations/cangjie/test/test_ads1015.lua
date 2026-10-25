-- test_ads1015.lua —— ADS1015 真实驱动 + 虚拟 I2C 总线 + 字寻址/oneshot 模型
-- 用法（项目根目录）: luajit test/test_ads1015.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：ADS_GC=1 luajit test/test_ads1015.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 296 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/ads1015.lua 模型」。与 ADS1115【同一位布局、
-- 同一 OS 握手范式】，差异仅数据面与速率面：
--   ① CONVERSION 是 12 位有符号码【左对齐】放 16 位（低 4 位恒 0，
--      有效码 -2048~2047，驱动读出算术右移 4 位；非 ADS1115 的 s16 直编）；
--   ② DR 位 000~111 = 128/250/490/920/1600/2400/3300/3300 SPS（内核
--      ti-ads1015 表，110/111 同 3300），转换门精确 1000/SPS =
--      7.8125/4/2.0408/1.0870/0.625/0.4167/0.3030/0.3030ms，驱动 1ms
--      步进轮询（先读一次，busy 才睡），各档实际睡眠 = ceil(门限) =
--      8/4/3/2/1/1/1/1ms，超时预算 100 次（ADS1115 为 200 次）；
--   ③ 位布局不变故 build 默认字同为 0x4583（DR 位 100 在此是 1600SPS）、
--      自定义 0x7BE3、四差分 MUX 字与 PGA 6/7 冗余编码全部相同；
--   ④ 驱动无模块级 init upvalue——【无未 build 守卫】，reload 后裸 call
--      直接跑（区别 INA219/LTC2944）；destroy 缺 fd/addr 不报错、零事务
--      安全返回 OK（仅非表参数 ERR）。
--
-- 覆盖：模型侧 POR/字寻址不串读/坏长度与越界/OS 动态合成/八档门 ε 边界/
-- 12 位左对齐码表与低 4 位恒 0/通道隔离/连续模式/阈值照读照写/武装零等待
-- 一次性消费/virt_tick 峰谷周期/物理量 PGA 量化独立交叉/六类钩子与 reset
-- 保留/卡死武装无效；真实 build 配置字与参数归一/指针写+读回事务序列/
-- 回显 mismatch/六负路径；真实 call 启动前读保 PGA/DR→启动字→1ms 步进
-- 轮询→结果读完整序列与每档睡眠拍数、±满码左对齐/四单端与四差分 MUX
-- 字/PGA 回读与 6/7 冗余/超时 100ms/四路失败/virt_tick 零睡眠闭环/无未
-- build 守卫事实；destroy 读改写与缺参安全返回。

if os.getenv("ADS_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/ads1015.lua")
vbus.reset()

local ADDR = 0x48
local dev = smod.new()
vbus.attach("ADS1015@0x48", ADDR, dev)
vbus.load_driver("modules/ADS1015.lua")

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
-- datasheet 精确门限 1000/SPS（内核 DR 表；不用驱动 ceil 预算）
local CONV_MS = { [0] = 1000/128, [1] = 1000/250, [2] = 1000/490, [3] = 1000/920,
                  [4] = 1000/1600, [5] = 1000/2400, [6] = 1000/3300, [7] = 1000/3300 }
-- 驱动 1ms 步进（先读、busy 才睡）每档实际睡眠拍数 = ceil(门限)
local SLEEP_TAB = { [0] = 8, [1] = 4, [2] = 3, [3] = 2, [4] = 1, [5] = 1, [6] = 1, [7] = 1 }
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
check("POR CONVERSION 零码 word=0x0000", dev:conversion_word() == 0x0000,
      string.format("0x%04X", dev:conversion_word()))
check("POR CONVERSION 解码 0", dev:conversion_raw() == 0)
check("POR 不 busy", not dev:busy())
check("POR remaining nil", dev:remaining_ms() == nil)
check("POR active_mux=4(AIN0)", dev:active_mux() == 4)
check("POR start_count=0", dev:start_count() == 0)
check("POR ptr=0", dev:pointer() == 0)

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
check("字符串写 NACK", dev.write("x") == false)
check("非字节写 NACK", dev.write({ 0x01, 256 }) == false)
check("指针越界 0x04 NACK", dev.write({ 0x04 }) == false)
check("字写越界寄存器 NACK", dev.write({ 0x05, 0x00, 0x00 }) == false)
check("read(0) NACK", dev.read(0) == nil)
check("坏帧不改指针（ptr 留 0x01）", dev:pointer() == 0x01)

-- OS 位读写相反：OS=0 单次写不启动；OS=1 启动后转换中读 0、空闲读 1
mark = section()
check("OS=0 单次写 ACK", dev.write({ 0x01, 0x45, 0x83 }))
check("OS=0 不启动（start_count=0）", dev:start_count() == 0, tostring(dev:start_count()))
check("OS=0 后空闲读回合成 OS=1（0xC583）", dev:config() == 0xC583,
      string.format("0x%04X", dev:config()))
check("shadow 保留驱动写值 0x4583", dev:config_shadow() == 0x4583,
      string.format("0x%04X", dev:config_shadow()))

-- 1600SPS oneshot 门限 0.625ms（默认档）：启动即 busy、OS 读 0、结果完成前不变
dev:set_result(4, 2047)
start_oneshot(4)
check("OS=1 启动计数 +1", dev:start_count() == 1)
check("启动即 busy", dev:busy())
check("remaining=0.625", near(dev:remaining_ms(), 0.625), tostring(dev:remaining_ms()))
check("转换中 OS 读 0（0x4583）", dev:config() == 0x4583, string.format("0x%04X", dev:config()))
check("完成前 CONVERSION 保持旧值 0", dev:conversion_raw() == 0 and dev:conversion_word() == 0)
dev:advance(0.6)
check("0.6ms 未过 0.625 门仍 busy", dev:busy())
dev:advance(0.02)
check("0.62ms 仍 busy", dev:busy())
dev:advance(0.006)
check("0.626ms 过门就绪", not dev:busy())
check("完成后 OS 读 1", dev:config() == 0xC583, string.format("0x%04X", dev:config()))
check("完成时装注入码 2047", dev:conversion_raw() == 2047, tostring(dev:conversion_raw()))
check("正满码左对齐 word=0x7FF0（低 4 位恒 0）", dev:conversion_word() == 0x7FF0,
      string.format("0x%04X", dev:conversion_word()))

-- 八档转换门 ε 边界（快档门限 <1ms，统一用 0.001ms epsilon）
for dr = 0, 7 do
	section()
	start_oneshot(dr)
	check(string.format("DR=%d 启动即 busy(%.4fms)", dr, CONV_MS[dr]), dev:busy())
	dev:advance(CONV_MS[dr] - 0.001)
	check(string.format("DR=%d 门前 ε busy", dr), dev:busy())
	dev:advance(0.002)
	check(string.format("DR=%d 门后就绪", dr), not dev:busy())
	check(string.format("DR=%d 门后 OS=1", dr), dev:config() % 0x8000 >= 0 and
	      math.floor(dev:config() / 0x8000) == 1)
end
-- DR6/DR7 同为 3300SPS 门限相等
check("DR6/DR7 门限相同（3300SPS）", CONV_MS[6] == CONV_MS[7])
-- 门限常量表事实
check("ADS1015 门限表 7.8125/4/…/0.625/…/0.3030",
	near(CONV_MS[0], 7.8125) and CONV_MS[1] == 4 and near(CONV_MS[4], 0.625)
	and near(CONV_MS[6], 1000/3300))

-- 12 位左对齐码表：word=(raw<<4)，低 4 位恒 0
mark = section()
for _, c in ipairs({ { 2047, 0x7FF0 }, { -2048, 0x8000 }, { -1, 0xFFF0 },
                    { 1, 0x0010 }, { 100, 0x0640 }, { 0, 0x0000 } }) do
	dev:set_result(4, c[1])
	start_oneshot(6); dev:advance(1)	-- 3300SPS 快档过门
	local w = dev:conversion_word()
	check(string.format("码 %d 左对齐 0x%04X", c[1], c[2]), w == c[2],
	      string.format("0x%04X", w))
	check(string.format("码 %d 低 4 位恒 0", c[1]), w % 16 == 0)
	check(string.format("码 %d 解码还原", c[1]), dev:conversion_raw() == c[1])
end
-- 超程钳制
mark = section()
dev:set_result(4, 99999)
start_oneshot(4); dev:advance(1)
check("超正程钳 2047 / word 0x7FF0", dev:conversion_raw() == 2047
      and dev:conversion_word() == 0x7FF0)
dev:set_result(4, -99999)
start_oneshot(4); dev:advance(1)
check("超负程钳 -2048 / word 0x8000", dev:conversion_raw() == -2048
      and dev:conversion_word() == 0x8000)

-- 通道隔离：MUX 各自的注入码只在对应通道转换时装入
mark = section()
dev:set_result(4, 111)		-- AIN0
dev:set_result(6, 222)		-- AIN2
dev:set_result(0, -33)		-- 差分 0-1
-- 切 AIN2（0xE583）
dev.write({ 0x01, 0xE5, 0x83 }); dev:advance(1)
check("切 AIN2 后 active_mux=6", dev:active_mux() == 6)
check("AIN2 装入 222", dev:conversion_raw() == 222, tostring(dev:conversion_raw()))
check("AIN2 左对齐 0x0DE0", dev:conversion_word() == 0x0DE0,
      string.format("0x%04X", dev:conversion_word()))
-- 差分 0-1（0x8583）
dev.write({ 0x01, 0x85, 0x83 }); dev:advance(1)
check("差分 0-1 active_mux=0", dev:active_mux() == 0)
check("差分码 -33 装入（0xFDE0）", dev:conversion_raw() == -33
      and dev:conversion_word() == (-33 * 16) % 65536,
      string.format("%d/0x%04X", dev:conversion_raw(), dev:conversion_word()))
-- 回 AIN0
dev.write({ 0x01, 0xC5, 0x83 }); dev:advance(1)
check("回 AIN0 装入 111", dev:conversion_raw() == 111, tostring(dev:conversion_raw()))
-- 未注入的通道完成时装零码
dev.write({ 0x01, 0xD5, 0x83 }); dev:advance(1)
check("未注入 AIN1 完成装 0", dev:conversion_raw() == 0 and dev:conversion_word() == 0)

-- 连续模式（MODE=0）：不 busy、OS 读恒 0、结果立即装入
mark = section()
dev:set_result(4, 1234)
dev.write({ 0x01, 0x44, 0x83 })		-- MUX=AIN0 MODE=0 DR=128，OS=0
check("连续写不 busy", not dev:busy())
check("连续模式 OS 读 0（0x4483）", dev:config() == 0x4483, string.format("0x%04X", dev:config()))
check("连续结果立即装入 1234（0x4D20）", dev:conversion_raw() == 1234
      and dev:conversion_word() == 0x4D20,
      string.format("0x%04X", dev:conversion_word()))
check("连续写 start_count 不增", dev:start_count() == 0)

-- 阈值寄存器照读照写
mark = section()
dev.write({ 0x02, 0x12, 0x34 })
dev.write({ 0x03, 0xAB, 0xCD })
check("LO 照写 0x1234", dev:lo_thresh() == 0x1234, string.format("0x%04X", dev:lo_thresh()))
check("HI 照写 0xABCD", dev:hi_thresh() == 0xABCD, string.format("0x%04X", dev:hi_thresh()))

-- 物理量 API 独立量化交叉（V*2048/FS 公式独立于驱动，常量另算）
mark = section()
local function code_after_single(ch, v, pga)
	section()
	dev:set_single(ch, v, pga)
	local mux = 4 + ch
	dev.write({ 0x01, 0x80 + mux * 0x10 + pga * 2, 0x83 })
	dev:advance(8)
	return dev:conversion_raw()
end
check("AIN0 1.5V@±2.048 码", code_after_single(0, 1.5, 2) == math.floor(1.5 * 2048 / 2.048 + 0.5))
check("AIN3 -0.2V@±0.256 码", code_after_single(3, -0.2, 5) == math.floor(-0.2 * 2048 / 0.256 + 0.5))
check("AIN1 满程钳 +2047", code_after_single(1, 10, 0) == 2047)
section()
dev:set_diff(2, -7.0, 0)		-- -7V 超 ±6.144 满程
dev.write({ 0x01, 0x80 + 2 * 0x10, 0x83 }); dev:advance(8)
check("差分负满程钳 -2048", dev:conversion_raw() == -2048, tostring(dev:conversion_raw()))
-- set_result 只入注入表：空闲注入不得提前出现在 CONVERSION
section()
dev:set_result(4, 1777)
check("set_result 不提前装载（word 仍 0）", dev:conversion_word() == 0)
check("set_result 不启动转换", not dev:busy() and dev:start_count() == 0)

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
local exp0 = math.floor(1.65 * 2048 / 2.048 + 0.5)
local exp8 = math.floor((1.65 + 0.25) * 2048 / 2.048 + 0.5)
local exp24 = math.floor((1.65 - 0.25) * 2048 / 2.048 + 0.5)
check("virt_tick n0 武装零等待码", r0 == exp0, tostring(r0) .. "/" .. tostring(exp0))
check("virt_tick n8 峰值码", r8 == exp8, tostring(r8) .. "/" .. tostring(exp8))
check("n8 峰 > n0", r8 > r0)
check("n24 谷码", r24 == exp24, tostring(r24) .. "/" .. tostring(exp24))
check("n24 谷 < n0", r24 < r0)
check("n32 = n0 周期", r32 == r0, tostring(r32) .. "/" .. tostring(r0))
-- 未武装的启动必须走真实门（武装只影响一次）
section()
dev:virt_tick(0)
start_oneshot(4); dev:advance(1)	-- 第一次消费武装（0.625 门 1ms 完成）
dev:set_result(4, 1234)
start_oneshot(4)
check("武装消费后第二次启动真实 busy", dev:busy())
dev:advance(1)
check("第二次转换完成 1234（0x4D20）", dev:conversion_raw() == 1234
      and dev:conversion_word() == 0x4D20)

-- 卡死：永不就绪、advance 不推进、武装无效
mark = section()
dev:set_never_ready(true)
dev:virt_tick(0)
start_oneshot(4)
check("卡死时武装无效仍 busy", dev:busy())
dev:advance(500)
check("卡死后 advance 500ms 不就绪", dev:busy())
check("卡死 remaining 保持 0.625", near(dev:remaining_ms(), 0.625), tostring(dev:remaining_ms()))
check("卡死 OS 恒读 0", dev:config() == 0x4583, string.format("0x%04X", dev:config()))
dev:set_never_ready(false)
dev:advance(1)
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
check("谓词按 (ptr,n) 签名放行 CONFIG 读", (function()
	dev.write({ 0x01 }); return dev.read(2) ~= nil
end)())
dev:fail_read(); dev:fail_write()
-- 拒收坏帧/谓词不产生启动计数
check("拦截写未启动转换", dev:start_count() == 0)
dev.nack_read = true
dev:reset()
check("reset 保留故障钩子", dev.nack_read == true)
check("reset 回 POR CONFIG", dev:config() == 0x8583, string.format("0x%04X", dev:config()))
check("reset 清启动计数", dev:start_count() == 0)
dev:clear_faults()
-- reset_logs 只清写留痕
dev.write({ 0x02, 0x00, 0x01 })
check("reset_logs 前有留痕", #dev.write_log == 1)
dev:reset_logs()
check("reset_logs 后清空", #dev.write_log == 0)
check("config_writes 仅收 3B 字写", (function()
	dev:reset()
	dev.write({ 0x01 })				-- 指针写不计
	dev.write({ 0x01, 0x45, 0x83 })	-- 字写
	local wl = dev:config_writes()
	return #wl == 1 and wl[1].reg == 0x01 and wl[1].word == 0x4583
end)())

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
-- i2c_read_multi 在总线上 = 指针写 w{01} + 纯读 r(2)：
-- build 共 set + w{01,45,83} + w{01} + r(2) = 4 条 txlog
mark = section()
local b = expect_ok("build 默认 AIN0/±2.048V/1600SPS", function()
	return build({ fd = fd, address = "0x48" })
end)
local ws = write_words(mark)
check("build 恰一笔字写", #ws == 1, tostring(#ws))
check("build 配置字 0x4583（DR 位 100=1600SPS）", ws[1] == 0x01 * 65536 + 0x4583,
      string.format("0x%06X", ws[1] or 0))
check("build 一次 set_addr", #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR)
local rs = reads(mark)
check("build 一次 2B 回读", #rs == 1 and rs[1] == 2, table.concat(rs, ","))
local pw = ptr_writes(mark)
check("build 一次 CONFIG 指针写", #pw == 1 and pw[1] == 0x01, table.concat(pw, ","))
check("build 共 4 txlog（回读拆指针写+读）", #entries(mark) == 4, tostring(#entries(mark)))
check("build 零睡眠", sleep_total == 0, tostring(sleep_total))

-- 自定义全档（位布局与 ADS1115 同：AIN3/PGA5/DR7=3300SPS → 0x7BE3）
mark = section()
expect_ok("build 自定义 AIN3/PGA5/DR7(3300SPS)", function()
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
-- 字符串数字参数
mark = section()
expect_ok("build 字符串数字参数", function()
	return build({ fd = fd, address = "0x48", pga = "0", dr = "0", channel = "1" })
end)
ws = write_words(mark)
-- AIN1/PGA0/DR0: 0x5000|0x0100|0x0003 = 0x5103
check("字符串参数字 0x5103", ws[1] == 0x01 * 65536 + 0x5103, string.format("0x%06X", ws[1] or 0))

-- build 回显 mismatch：包装 read 翻转 CONFIG 低字节 bit7（0x0080），掩 0x7FFF 失配
mark = section()
do
	local orig_read = dev.read
	local flipped = false
	dev.read = function(n)
		local bb = orig_read(n)
		if bb and #bb == 2 and not flipped then
			flipped = true
			bb[2] = (bb[2] + 0x80) % 256	-- 翻低字节 bit7
		end
		return bb
	end
	expect_err("build 回显 mismatch", function()
		return build({ fd = fd, address = "0x48" })
	end, "echo mismatch")
	dev.read = orig_read
end

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
expect_err("build 错地址 0x60（无挂载，配置写 NACK）", function()
	return build({ fd = fd, address = "0x60" })
end, "Failed to write")
section()
dev:fail_write(function(bb) return #bb == 3 and bb[1] == 0x01 end)
expect_err("build 配置写谓词失败", function()
	return build({ fd = fd, address = "0x48" })
end, "Failed to write")
section()
dev.nack_read = true
expect_err("build 回读 NACK", function()
	return build({ fd = fd, address = "0x48" })
end, "Failed to read back")
section()
-- 错地址的 set 留痕正规验证：set 成功后首笔写即败，仅 set+w 两条
mark = #vbus.txlog
local rbad = build({ fd = fd, address = "0x60" })
check("错地址仅 set+w 两 txlog", rbad.result == "ERR" and #entries(mark) == 2,
      tostring(#entries(mark)))
check("错地址 set addr=0x60", entries(mark)[1].addr == 0x60)
section()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 默认档（1600SPS 门 0.625ms）完整序列：set_addr → 读 CONFIG(指针+读) →
-- 字写启动 → 首读 CONFIG 忙 → sleep 1ms → 二读就绪 → 读 CONVERSION。
-- 指针写 4 笔（01×3 + 00×1）、读 4 笔、字写 1 笔、set 1，共 10 txlog。
mark = section()
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x48" }) end)
dev:set_result(4, 2047)
mark = #vbus.txlog		-- call 窗口在 build 之后起算
local res = expect_ok("call 正满码 1600SPS", function()
	return call({ fd = fd, address = "0x48" })
end)
if res then
	check("raw=2047", res.raw == 2047, tostring(res.raw))
	check("voltage=2047*2.048/2048≈2.047", near(res.voltage, 2047 * 2.048 / 2048),
	      tostring(res.voltage))
end
check("call 一次 set_addr", #set_addrs(mark) == 1)
local cw = write_words(mark)
check("call 恰一笔启动字写", #cw == 1 and cw[1] == 0x01 * 65536 + 0xC583,
      string.format("0x%06X", cw[1] or 0))
pw = ptr_writes(mark)
check("指针写 4 笔（01×3 + 00×1）", #pw == 4, table.concat(pw, ","))
local n1, n0 = 0, 0
for _, p in ipairs(pw) do if p == 0x01 then n1 = n1 + 1 elseif p == 0x00 then n0 = n0 + 1 end end
check("CONFIG 指针 3（启动前 1 + 轮询 2）", n1 == 3, tostring(n1))
check("CONVERSION 指针 1", n0 == 1, tostring(n0))
rs = reads(mark)
check("读事务 4 笔×2B", #rs == 4 and rs[1] == 2, tostring(#rs))
check("call 共 10 txlog", #entries(mark) == 10, tostring(#entries(mark)))
-- 轮询首读 t=0 必忙（门 0.625 未睡），睡 1ms 后二读就绪
check("1600SPS 轮询睡眠 1ms", sleep_total == 1, tostring(sleep_total))

-- 负码 / -1 LSB / 小正码（左对齐解码三代表）
for _, raw in ipairs({ -2048, -1, 1 }) do
	section()
	expect_ok("call 前 build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:set_result(4, raw)
	mark = #vbus.txlog
	res = expect_ok("call 码 " .. raw, function() return call({ fd = fd, address = "0x48" }) end)
	if res then
		check("raw 还原 " .. raw, res.raw == raw, tostring(res.raw))
		check("voltage 换算 " .. raw, near(res.voltage, raw * 2.048 / 2048),
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
dev:set_result(4, 1000)
mark = #vbus.txlog
res = expect_ok("call 无 pga 参回读 PGA=1", function()
	return call({ fd = fd, address = "0x48" })
end)
if res then check("按 ±4.096V 换算 =2.0V", near(res.voltage, 1000 * 4.096 / 2048),
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
if res then check("按 ±0.256V 换算（1000→0.125V）", near(res.voltage, 1000 * 0.256 / 2048),
                  tostring(res.voltage)) end

-- 差分四对 MUX 字 + 码隔离
local DIFF = { { 0, 1, 0x8583, 0 }, { 0, 3, 0x9583, 1 }, { 1, 3, 0xA583, 2 }, { 2, 3, 0xB583, 3 } }
for _, t in ipairs(DIFF) do
	section()
	expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:set_result(t[4], -300)
	mark = #vbus.txlog
	res = expect_ok(string.format("call 差分 %d-%d", t[1], t[2]), function()
		return call({ fd = fd, address = "0x48", pos = t[1], neg = t[2] })
	end)
	cw = write_words(mark)
	check(string.format("差分 %d-%d 启动字 0x%04X", t[1], t[2], t[3]),
	      cw[1] == 0x01 * 65536 + t[3], string.format("0x%06X", cw[1] or 0))
	if res then check("差分码 -300 隔离", res.raw == -300, tostring(res.raw)) end
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
expect_err("call 缺 fd", function() return call({ address = "0x48" }) end, "fd")

-- DR 八档：每档轮询睡眠拍数 = ceil(转换门)；慢档 128SPS 指针 10 笔
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
	check(string.format("DR=%d 睡眠 %dms（ceil 门限 %.4f）", dr, SLEEP_TAB[dr], CONV_MS[dr]),
	      sleep_total == SLEEP_TAB[dr], tostring(sleep_total))
	if dr == 0 then
		-- 慢档：首读 + 8 睡后共 9 轮 CONFIG 指针 + 1 CONVERSION
		check("DR0 CONFIG 指针 10 笔", (function()
			local x = 0
			for _, p in ipairs(ptr_writes(mark)) do if p == 0x01 then x = x + 1 end end
			return x == 10
		end)(), "10")
	end
	if res then check("DR" .. dr .. " 结果码 5（左对齐 0x0050）",
		res.raw == 5 and dev:conversion_word() == 0x0050,
		tostring(res.raw) .. "/0x" .. string.format("%04X", dev:conversion_word())) end
end

-- 转换超时：卡死，轮询满 100ms 预算（ADS1015 为 100 次，区别 ADS1115 的 200）
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:set_never_ready(true)
mark = #vbus.txlog
expect_err("call 转换超时", function()
	return call({ fd = fd, address = "0x48" })
end, "Conversion timeout")
check("超时前轮询满 100ms", sleep_total == 100, tostring(sleep_total))
-- 超时时轮询读了 100 次 CONFIG，无 CONVERSION 读
pw = ptr_writes(mark)
local seen_conv = false
for _, p in ipairs(pw) do if p == 0x00 then seen_conv = true end end
check("超时路径不读 CONVERSION", not seen_conv)
check("超时 CONFIG 指针 101 笔（启动前 1+轮询 100）", (function()
	local x = 0
	for _, p in ipairs(pw) do if p == 0x01 then x = x + 1 end end
	return x == 101
end)(), tostring(#pw))
section()

-- call 失败路径：读 CONFIG / 启动写 / 读 CONVERSION / set_addr / 错地址
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev.nack_read = true
mark = #vbus.txlog
expect_err("call 读 CONFIG 失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to read config")
check("读 CONFIG 失败仅 set+w01+r 三 txlog", #entries(mark) == 3, tostring(#entries(mark)))
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:fail_write(function(bb) return #bb == 3 and bb[1] == 0x01 end)
mark = #vbus.txlog
expect_err("call 启动写失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to start conversion")
-- set + 读CONFIG(w01+r) + 启动写败 = 4 txlog
check("启动写失败 4 txlog", #entries(mark) == 4, tostring(#entries(mark)))
section()
expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
dev:fail_read(function(p) return p == 0x00 end)	-- 只 NACK 结果读，轮询正常（sleep 桩过门）
dev:set_result(4, 1)
mark = #vbus.txlog
expect_err("call 读 CONVERSION 失败", function()
	return call({ fd = fd, address = "0x48" })
end, "Failed to read conversion")
check("结果读失败走到完整 10 txlog（指针 00 后读败）", #entries(mark) == 10,
      tostring(#entries(mark)))
section()
expect_err("call set_addr 失败（fd=99）", function()
	return call({ fd = 99, address = "0x48" })
end, "set_addr failed")
section()
mark = #vbus.txlog
expect_err("call 错地址 0x60（无挂载）", function()
	return call({ fd = fd, address = "0x60" })
end, "Failed to read config")
-- 无挂载：set 成功后 read_multi 的指针写即 NACK，整笔读败且不产生读事务
check("错地址 set+w01 两 txlog（指针写 NACK 无读事务）", #entries(mark) == 2,
      tostring(#entries(mark)))
section()

-- 无未 build 守卫事实：reload 驱动重建模块后直接 call（驱动无模块级 init 状态）
section()
vbus.load_driver("modules/ADS1015.lua")
dev:set_result(4, 42)
mark = #vbus.txlog
local rnb = call({ fd = fd, address = "0x48" })
check("裸 call 无未 build 守卫直接 OK", rnb and rnb.result == "OK",
      tostring(rnb and rnb.message))
check("裸 call 同样 10 txlog", #entries(mark) == 10, tostring(#entries(mark)))
check("裸 call 结果码 42", rnb and rnb.raw == 42)
vbus.load_driver("modules/ADS1015.lua")	-- 恢复（后续组先 build）
section()

-- virt_tick 闭环：守护式武装，call 零真实睡眠、电压跟正弦走（量化 0.001V）
local function v_of(n) return 1.65 + 0.25 * math.sin(n * (2 * math.pi / 32)) end
for _, n in ipairs({ 0, 8, 24, 32 }) do
	section()
	expect_ok("build", function() return build({ fd = fd, address = "0x48" }) end)
	dev:virt_tick(n)
	mark = #vbus.txlog
	res = expect_ok("virt_tick n=" .. n .. " call", function()
		return call({ fd = fd, address = "0x48" })
	end)
	check(string.format("n=%d 武装零睡眠", n), sleep_total == 0, tostring(sleep_total))
	check(string.format("n=%d 武装仅 6 txlog（无轮询睡眠循环外仍读一次 CONFIG）", n),
		#entries(mark) < 10, tostring(#entries(mark)))
	if res then
		check(string.format("n=%d 正弦电压闭环", n),
		      near(res.voltage, v_of(n % 32), 0.0011), tostring(res.voltage))
	end
end

-- =====================================================================
-- 组 4：destroy（读改写置 MODE=1 + 清 OS，不误启动转换）
-- =====================================================================
-- 驱动 destroy：fd/addr 任一为 nil 不发总线直接 OK；set_addr 失败也安全 OK；
-- 仅非表参数 ERR。
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
check("destroy 共 4 txlog", #entries(mark) == 4, tostring(#entries(mark)))
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

-- 缺 fd/addr：安全 OK 且零总线事务（与 ADS1115 destroy 报错不同）
mark = #vbus.txlog
local d1 = destroy({ address = "0x48" })
check("destroy 缺 fd 安全 OK", d1.result == "OK", tostring(d1.message))
check("destroy 缺 fd 零 txlog", #entries(mark) == 0, tostring(#entries(mark)))
mark = #vbus.txlog
local d2 = destroy({ fd = fd })
check("destroy 缺 addr 安全 OK", d2.result == "OK")
check("destroy 缺 addr 零 txlog", #entries(mark) == 0)
mark = #vbus.txlog
local d3 = destroy({})
check("destroy 空表安全 OK", d3.result == "OK")
check("destroy 空表零 txlog", #entries(mark) == 0)
-- set_addr 失败（fd 未打开，vbus 校验在留痕之前）：不读不写、无 set 留痕，仍 OK
mark = #vbus.txlog
local d4 = destroy({ fd = 99, address = "0x48" })
check("destroy fd=99 set_addr 失败仍安全 OK", d4.result == "OK", tostring(d4.message))
check("destroy fd=99 set 败零 txlog", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments")
section()

-- ==================== 汇总 ====================
tester.summary()

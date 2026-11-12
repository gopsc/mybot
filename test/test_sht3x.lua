-- test_sht3x.lua —— SHT3X 真实驱动 + 虚拟 I2C 总线 + 命令字/CRC 模型
-- 用法（项目根目录）: luajit test/test_sht3x.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + 内嵌模型（modules/SHT3X.lua 尾部 SHT3X_VIRT，2026-09-15
-- 自 virtbus/sht3x.lua 迁入）」。本器件是 virtbus 库【首个 16 位
-- 命令字 + 每数据字 CRC-8 的命令式 I2C 器件】：无寄存器指针，每笔写恰为
-- 2 字节命令大端字（驱动借 i2c_write_reg(fd,hi,lo) 发送），测量/状态从
-- 总线纯读（i2c_read，无前置指针写），6 字节测量帧 = T_MSB T_LSB CRC |
-- RH_MSB RH_LSB CRC（CRC-8 poly 0x31/init 0xFF，向量 0xBEEF→0x92）。
--
-- 覆盖：模型侧 CRC 真算/状态寄存器四位语义（bit0 写校验和、bit1 命令
-- 状态读后清、bit4 复位检测、bit12 加热器）/非法命令 NACK 置 bit1/
-- 单次轮询转换门（advance 虚拟时钟，15.5/6.5/4.5ms 三档）/结果读后
-- 失效/周期模式 fetch 可重复读/坏 CRC 与卡死等钩子/virt_tick 节拍；
-- 真实 build 的「软复位→读状态」序列与 5 路负路径（含旧错位映射守卫：
-- bit0 不致命、bit1 致命）、真实 call 的 16ms 等待与 6 字节帧解析、
-- CRC_OK 降级不中断、4 路负路径、连续两拍；destroy 零事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（SHT3X_VIRT 全局工厂，CRC-8 公开在工厂表字段）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/SHT3X.lua")
local smod = SHT3X_VIRT

local ADDR = 0x44
local dev = smod.new()
vbus.attach("SHT3X@0x44", ADDR, dev)

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function word(bs) return bs[1] * 256 + bs[2] end

-- 每个 section：器件复位 + 故障解除（挂载/fd 不动）
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
local crc8 = smod.crc8

-- ======================================================================
-- 组 1：模型协议事实（直连模型 + 部分经总线）
-- ======================================================================
local mark = section()

check("CRC8 datasheet 向量 0xBEEF→0x92", crc8(0xBEEF) == 0x92,
	string.format("%02X", crc8(0xBEEF)))

-- 上电/复位状态：无命令时纯读 NACK；软复位+读状态回 0x0010+CRC
check("空闲纯读 3/6 字节均 NACK", dev.read(3) == nil and dev.read(6) == nil)
check("软复位写 30A2 成功", dev.write({ 0x30, 0xA2 }) == true)
check("读状态命令 F32D 成功", dev.write({ 0xF3, 0x2D }) == true)
local sb = dev.read(3)
check("状态帧 00 10 + 正确 CRC", sb and sb[1] == 0x00 and sb[2] == 0x10
	and sb[3] == crc8(0x0010), sb and string.format("%02X %02X %02X", sb[1], sb[2], sb[3]))
check("状态读后 bit4 保持（非 read-to-clear 位）", dev:current_status() == 0x0010,
	string.format("%04X", dev:current_status()))
check("状态读后无待读（再读 NACK）", dev.read(3) == nil)

-- 非法命令：NACK + 置 bit1，且不入识别命令序列
local nc = dev:cmd_count()
check("非法命令字返回 NACK", dev.write({ 0xAA, 0xAA }) == false)
check("非法命令被记入 bad_commands", dev:bad_commands()[1] == 0xAAAA)
check("非法命令不入识别命令序列", dev:cmd_count() == nc)
check("非法命令置 bit1", dev:current_status() % 4 == 2,
	string.format("%04X", dev:current_status()))
dev.write({ 0xF3, 0x2D })
local sb2 = dev.read(3)
check("状态上报 0x0012（bit4 在、bit1 新置，CRC 按 0x0012 算）",
	sb2 and sb2[1] == 0x00 and sb2[2] == 0x12 and sb2[3] == crc8(0x0012),
	sb2 and string.format("%02X %02X %02X", sb2[1], sb2[2], sb2[3]))
check("bit1 读后清零（bit4 保持 0x0010）", dev:current_status() == 0x0010,
	string.format("%04X", dev:current_status()))

-- 非 2 字节写：非法帧 NACK（SHT3x 只有 16 位命令）
check("1 字节写 NACK", dev.write({ 0x30 }) == false)
check("3 字节写 NACK", dev.write({ 0x30, 0xA2, 0x00 }) == false)

-- 清状态 0x3041：清标志位（bit4 也清，输出帧 CRC 按新字算）
dev:reset()
dev.write({ 0x30, 0x41 }); dev.write({ 0xF3, 0x2D })
local sc = dev.read(3)
check("清状态后状态字 = 0x0000", sc[1] * 256 + sc[2] == 0x0000
	and sc[3] == crc8(0x0000),
	string.format("%04X %02X", sc[1] * 256 + sc[2], sc[3]))

-- 加热器 bit12：开/关；清状态保留加热器位
dev:reset()
dev.write({ 0x30, 0x6D }); dev.write({ 0xF3, 0x2D })
local sh = dev.read(3)
check("加热器开 → 0x1010（bit12+bit4）", sh[1] * 256 + sh[2] == 0x1010,
	string.format("%04X", sh[1] * 256 + sh[2]))
dev.write({ 0x30, 0x66 }); dev.write({ 0x30, 0x41 }); dev.write({ 0xF3, 0x2D })
local so = dev.read(3)
check("加热器关+清状态 → 0x0000", so[1] * 256 + so[2] == 0x0000)
dev.write({ 0x30, 0x6D }); dev.write({ 0x30, 0x41 }); dev.write({ 0xF3, 0x2D })
local sk = dev.read(3)
check("加热器在位时清状态 → 0x1000（保留 bit12）", sk[1] * 256 + sk[2] == 0x1000,
	string.format("%04X", sk[1] * 256 + sk[2]))
-- 软复位关加热器并回 0x0010
dev.write({ 0x30, 0xA2 }); dev.write({ 0xF3, 0x2D })
local sr = dev.read(3)
check("软复位清加热器 → 0x0010", sr[1] * 256 + sr[2] == 0x0010)

-- 单次测量转换门（高重复性：max 15.5ms，驱动取整 16ms）
dev:reset()
dev:set_raw(26220, 32768)
dev.write({ 0x24, 0x00 })
check("转换未完成读 NACK（0ms）", dev.read(6) == nil)
dev:advance(15)
check("转换 15ms 仍未就绪（<15.5 取整门限 16）", dev.read(6) == nil)
dev:advance(1)
local mb = dev.read(6)
check("16ms 测量帧布局与双 CRC", mb and mb[1] == 0x66 and mb[2] == 0x6C
	and mb[3] == crc8(26220) and mb[4] == 0x80 and mb[5] == 0x00
	and mb[6] == crc8(32768),
	mb and string.format("%02X %02X %02X %02X %02X %02X",
		mb[1], mb[2], mb[3], mb[4], mb[5], mb[6]))
check("单次结果读后失效（再读 NACK）", dev.read(6) == nil)

-- 中/低重复性转换门限：7ms / 5ms
dev.write({ 0x24, 0x0B }); dev:advance(6)
check("中重复性 6ms 未就绪", dev.read(6) == nil)
dev:advance(1); check("中重复性 7ms 就绪", dev.read(6) ~= nil)
dev.write({ 0x24, 0x16 }); dev:advance(4)
check("低重复性 4ms 未就绪", dev.read(6) == nil)
dev:advance(1); check("低重复性 5ms 就绪", dev.read(6) ~= nil)
-- 时钟拉伸字走同一转换门
dev.write({ 0x2C, 0x06 }); check("时钟拉伸字未完成同样 NACK", dev.read(6) == nil)
dev:advance(16); check("时钟拉伸字 16ms 就绪", dev.read(6) ~= nil)

-- 长度不符的读 NACK（状态待读时读 6、测量待读时读 3）
dev.write({ 0xF3, 0x2D }); check("状态待读时读 6 字节 NACK", dev.read(6) == nil)
dev.read(3)	-- 消费
dev.write({ 0x24, 0x00 }); dev:advance(16)
check("测量待读时读 3 字节 NACK", dev.read(3) == nil)
dev.read(6)

-- 周期模式：启动字置周期态，fetch 可重复读；break 后空闲 fetch NACK
dev:reset()
dev:set_raw(100, 200)
check("周期启动 2032 成功", dev.write({ 0x20, 0x32 }) == true)
check("模型识别为周期态", dev:is_periodic())
check("fetch E000 成功", dev.write({ 0xE0, 0x00 }) == true)
local f1, f2 = dev.read(6), dev.read(6)
check("周期数据可重复 fetch", f1 ~= nil and f2 ~= nil
	and f1[1] == f2[1] and f1[6] == f2[6])
dev.write({ 0x30, 0x93 })
check("break 3093 退出周期态", not dev:is_periodic())
dev.write({ 0xE0, 0x00 })
check("空闲 fetch 无数据 NACK", dev.read(6) == nil)

-- 故障钩子
section()
dev:corrupt_crc(true)
dev.write({ 0xF3, 0x2D })
local bc = dev.read(3)
check("坏 CRC：状态帧 CRC 字节错误", bc and bc[3] ~= crc8(0x0010))
dev.write({ 0x24, 0x00 }); dev:advance(16)
local bm = dev.read(6)
check("坏 CRC：测量帧双 CRC 字节错误", bm and bm[3] ~= crc8(bm[1] * 256 + bm[2])
	and bm[6] ~= crc8(bm[4] * 256 + bm[5]))
dev:clear_faults()

dev:set_meas_stuck(true)
dev.write({ 0x24, 0x00 }); dev:advance(1000)
check("meas_stuck：超长时间仍 NACK", dev.read(6) == nil)
dev:set_meas_stuck(false); dev:reset()

dev:set_status_word(0x0002); dev.write({ 0xF3, 0x2D })
local ov = dev.read(3)
check("status_override：上报注入字且 CRC 按注入字算", ov[1] == 0x00 and ov[2] == 0x02
	and ov[3] == crc8(0x0002))
dev:clear_faults()

local n0 = dev:cmd_count()
dev:fail_cmd(function(w) return w == 0x2400 end)
check("fail_cmd 谓词命中返回 false", dev.write({ 0x24, 0x00 }) == false)
check("fail_cmd 拒识别不留命令", dev:cmd_count() == n0)
dev:fail_cmd(nil)
dev:fail_read(function(p, c, n) return n == 6 end)
dev.write({ 0x24, 0x00 }); dev:advance(16)
check("fail_read 谓词只断 6 字节读", dev.read(6) == nil)
dev.write({ 0xF3, 0x2D }); check("fail_read 不误伤 3 字节读", dev.read(3) ~= nil)
dev:clear_faults()

dev.nack = true
check("nack 全断写", dev.write({ 0x24, 0x00 }) == false)
check("nack 全断读", dev.read(3) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write 只断写", dev.write({ 0x24, 0x00 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 只断读", dev.read(3) == nil)
dev.nack_read = false

-- reset 保留故障钩子（防负路径假解除）；clear_faults 全清
dev:set_meas_stuck(true); dev:reset()
dev.write({ 0x24, 0x00 }); dev:advance(20)
check("reset 保留 meas_stuck 钩子", dev.read(6) == nil)
dev:clear_faults()
dev.write({ 0x24, 0x00 }); dev:advance(16)
check("clear_faults 后恢复", dev.read(6) ~= nil)

-- virt_tick 确定性节拍 + 预武装（守护不驱动时钟）
section()
local function tick_raw(n)
	dev:virt_tick(n); dev.write({ 0x24, 0x00 })
	-- 预武装：命令下发即就绪，无需 advance
	local m = dev.read(6)
	return m[1] * 256 + m[2], m[4] * 256 + m[5]
end
local t0, rh0 = tick_raw(0)
local t8 = tick_raw(8)
local t24 = tick_raw(24)
check("virt_tick T 节拍 n0=26214(25C)", t0 == 26214, tostring(t0))
check("virt_tick T 节拍 n8=28086(30C)", t8 == 28086, tostring(t8))
check("virt_tick T 节拍 n24=24341(20C)", t24 == 24341, tostring(t24))
check("virt_tick RH n0=42035(64.1%)", rh0 == 42035, tostring(rh0))
check("virt_tick 预武装零等待", dev:is_ready())
-- set_sample 物理量注入往返
dev:set_sample(0, 0)
dev.write({ 0x24, 0x00 })
local z = dev.read(6)
check("set_sample(0,0) → T raw 16851（floor 编码）", z[1] * 256 + z[2] == 16851,
	tostring(z[1] * 256 + z[2]))
check("set_sample(0,0) → RH raw 0", z[4] * 256 + z[5] == 0)
dev:set_sample(130, 100)
dev.write({ 0x24, 0x00 })
local f = dev.read(6)
check("set_sample(130,100) → 双满量程", f[1] * 256 + f[2] == 65535
	and f[4] * 256 + f[5] == 65535)

-- ======================================================================
-- 组 2：真实 build（软复位 → 读状态验证）
-- ======================================================================
mark = section()
local r = expect_ok("build 正常（软复位+状态 CRC+bit4）",
	function() return build({ fd = fd, address = "0x44" }) end)
if r then
	check("build set_addr 留痕 0x44", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x44)
	local ws = writes(mark)
	check("build 恰好 2 笔命令写", #ws == 2, tostring(#ws))
	check("build 命令序列 30A2 → F32D", #ws == 2 and word(ws[1]) == 0x30A2
		and word(ws[2]) == 0xF32D)
	check("build 一次 3 字节纯读", reads(mark)[1] == 3 and #reads(mark) == 1,
		table.concat(reads(mark), ","))
	check("build 睡眠 2+1=3ms", sleep_total == 3, tostring(sleep_total))
end

-- bit4 未置位只告警不失败
section()
dev:set_status_word(0x0000)
expect_ok("build 复位位 bit4 未置位仍继续",
	function() return build({ fd = fd, address = "0x44" }) end)

-- 旧错位映射守卫：bit0（写校验和状态）不致命；bit1（命令状态）致命
section()
dev:set_status_word(0x0001)
expect_ok("build bit0=1（写校验和诊断位）不致命",
	function() return build({ fd = fd, address = "0x44" }) end)
section()
dev:set_status_word(0x0002)
expect_err("build bit1=1 命令状态错误",
	function() return build({ fd = fd, address = "0x44" }) end, "command status error")

-- build 负路径
section()
expect_err("build 非 table 参数",
	function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd",
	function() return build({ address = "0x44" }) end, "fd or address")
expect_err("build 缺 address",
	function() return build({ fd = fd }) end, "fd or address")
expect_err("build 未打开 fd set_addr 失败",
	function() return build({ fd = 99, address = "0x44" }) end, "set_addr failed")

section()
dev:fail_cmd(function(w) return w == 0x30A2 end)
expect_err("build 软复位写失败",
	function() return build({ fd = fd, address = "0x44" }) end, "soft reset")

section()
dev:fail_read(function(p) return p == "status" end)
expect_err("build 读状态失败",
	function() return build({ fd = fd, address = "0x44" }) end, "Failed to read SHT3X status")

section()
dev:corrupt_crc(true)
expect_err("build 状态 CRC 不匹配",
	function() return build({ fd = fd, address = "0x44" }) end, "CRC mismatch")

-- ======================================================================
-- 组 3：真实 call（单次轮询：命令 → 16ms → 纯读 6 字节）
-- ======================================================================
mark = section()
dev:set_raw(26220, 32768)	-- ≈25°C / ≈50%RH
r = expect_ok("call 25C/50%",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("call set_addr 留痕", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x44)
	local ws = writes(mark)
	local wwords = {}
	for _, x in ipairs(ws) do wwords[#wwords + 1] = string.format("%04X", word(x)) end
	check("call 唯一命令写 2400", #ws == 1 and word(ws[1]) == 0x2400,
		table.concat(wwords, ","))
	check("call 一次 6 字节纯读（无指针写）", #reads(mark) == 1 and reads(mark)[1] == 6)
	check("call 睡眠 16ms（高重复性 max）", sleep_total == 16, tostring(sleep_total))
	check("T ≈ 25.0°C", near(r.T, 25.0, 0.05), tostring(r.T))
	check("RH ≈ 50.0%", near(r.RH, 50.0, 0.05), tostring(r.RH))
	check("CRC_OK=1", r.CRC_OK == 1, tostring(r.CRC_OK))
end

-- 两端量程点（驱动换算，不与模型互证——原始值由测试精确指定）
section()
dev:set_raw(0, 0)
r = expect_ok("call 零原始值",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("T = -45°C", near(r.T, -45.0, 1e-9), tostring(r.T))
	check("RH = 0%", r.RH == 0, tostring(r.RH))
	check("零值 CRC_OK=1", r.CRC_OK == 1)
end
section()
dev:set_raw(65535, 65535)
r = expect_ok("call 满量程",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("T = 130°C", near(r.T, 130.0, 1e-9), tostring(r.T))
	check("RH = 100%", near(r.RH, 100.0, 1e-9), tostring(r.RH))
end

-- CRC 失败：数据字节完好、CRC_OK=0，结果不中断（与 SGP30 约定一致）
section()
dev:set_raw(26220, 32768)
dev:corrupt_crc(true)
r = expect_ok("call CRC 双坏仍返回 OK",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("CRC_OK=0", r.CRC_OK == 0, tostring(r.CRC_OK))
	check("坏 CRC 不动数据字节（T 仍 ≈25）", near(r.T, 25.0, 0.05), tostring(r.T))
end
section()
dev:clear_faults()
r = expect_ok("call 清除故障后 CRC_OK=1",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then check("CRC_OK 恢复 1", r.CRC_OK == 1) end

-- 连续两拍：每拍独立命令+转换（第二拍的门由 milli_sleep 推进）
section()
dev:set_raw(16852, 0)
r = expect_ok("call 连续第 1 拍 0°C",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then check("第 1 拍 T≈0", near(r.T, 0, 0.05), tostring(r.T)) end
dev:set_raw(26214, 42035)	-- virt_tick(0) 同款种子
r = expect_ok("call 连续第 2 拍 25°C/64%",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("第 2 拍 T≈25", near(r.T, 25.0, 0.05), tostring(r.T))
	check("第 2 拍 RH≈64.14", near(r.RH, 64.14, 0.05), tostring(r.RH))
end

-- virt_tick 驱动（守护场景：零 advance 也必须立即就绪）
section()
dev:virt_tick(8)	-- 30°C / RH 相位 π/4 偏移：n=8 同样 64.14%RH
r = expect_ok("call virt_tick(8) 预武装样本",
	function() return call({ fd = fd, address = "0x44" }) end)
if r then
	check("tick(8) T≈30", near(r.T, 30.0, 0.05), tostring(r.T))
	check("tick(8) RH≈64.14", near(r.RH, 64.14, 0.05), tostring(r.RH))
end

-- call 负路径
section()
expect_err("call 非 table 参数",
	function() return call(123) end, "Invalid Arguments")
expect_err("call 缺 fd",
	function() return call({ address = "0x44" }) end, "fd or address")
expect_err("call 缺 address",
	function() return call({ fd = fd }) end, "fd or address")
expect_err("call 未打开 fd set_addr 失败",
	function() return call({ fd = 99, address = "0x44" }) end, "set_addr failed")

section()
dev:fail_cmd(function(w) return w == 0x2400 end)
expect_err("call 测量命令写失败",
	function() return call({ fd = fd, address = "0x44" }) end, "measure command")

section()
dev:fail_read(function(p) return p == "meas" end)
expect_err("call 读测量失败",
	function() return call({ fd = fd, address = "0x44" }) end, "Failed to read SHT3X measurement")

section()
dev.nack = true
expect_err("call 全断：测量命令写失败",
	function() return call({ fd = fd, address = "0x44" }) end, "measure command")
dev.nack = false

-- ======================================================================
-- 组 4：destroy（无总线资源，零事务）
-- ======================================================================
mark = section()
expect_ok("destroy 空表 OK", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

tester.summary("test_sht3x")

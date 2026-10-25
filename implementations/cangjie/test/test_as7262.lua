-- test_as7262.lua —— AS7262 真实驱动 + 虚拟 I2C 总线 + 间接窗口/握手模型
-- 用法（项目根目录）: luajit test/test_as7262.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 272 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + virtbus/as7262.lua 模型」。本器件是 virtbus 库【首个
-- 「硬件仅 3 寄存器 + 虚拟寄存器间接窗口 + TX/RX 就绪握手」I2C 器件】
-- （ams AS7262 六通道可见光光谱传感器，地址 0x49）：
--   I2C 总线上器件只暴露 STATUS 0x00（bit1=TX_VALID 写口忙、bit0=RX_VALID
--   读口有数据）、写口 WRITE 0x01、读口 READ 0x02；DEVICE_TYPE/CONTROL/
--   INT_T/六通道等虚拟寄存器（0x00~0x13）全部不能直接寻址，必须走 SparkFun
--   同款握手：读 = 等 TX 空 -> 写口发地址(bit7=0) -> 等 RX=1 -> 读读口；
--   写 = 等 TX 空 -> 写口发 地址|0x80 -> 再等 TX 空 -> 写口发数据。
--   写口字节【按状态机位置解释，不按 bit7】——数据相位 0x88（RST）也是数据。
--
-- 模型零延迟握手：TX 正常恒 0、读命令后 RX 立即 1、读口消费清 0，故驱动
-- build 除 RST 后硬睡 1000ms 外无轮询睡眠，call 就绪首读即通过；CONTORL
-- bit1=DATA_RDY 是只读动态合成位（写 0 清、写 1 无效，绝不可落影子）；
-- BANK=2 连续全通道一轮 = 2×INT_T×2.8ms = INT_T×5.6ms，set_result 只入
-- 注入表、转换完成事件才把六通道锁入数据寄存器。
--
-- 覆盖：模型侧 POR/零延迟握手/写口地址-数据状态机（0x88 不误判）/
-- DATA_RDY 合成与 RST 不落盘/转换门 279.9vs280.1ms/注入仅完成时同步/
-- BANK 停转/六通道 MSB-LSB 与序号等价/温度补码钳位/tx-rx 卡死/never_ready/
-- virt_tick 峰谷周期/坏帧八类/谓词钩子与 reset 保留；真实 build 的复位-
-- 甄别-积分-配置完整写口序列（9 笔）、gain 就近吸附四档、integ 钳位、
-- 甄别失败/握手超时/set_addr/参数负路径；真实 call 首拍零睡眠六通道+温度、
-- 第二拍 280ms 转换、负温度、超时预算 1060ms/握手挂死/总线失败/通道 V
-- 定向读失败/参数负路径/virt_tick 三拍零睡眠闭环；destroy 零事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/as7262.lua")
vbus.reset()

local ADDR = 0x49
local dev = smod.new()
vbus.attach("AS7262@0x49", ADDR, dev)
vbus.load_driver("modules/AS7262.lua")

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

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
-- 窗口内 1 字节指针写的指针序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
-- 窗口内写口 0x01 的 2B 写，返回第二字节序列（读地址<0x80/写地址>=0x80/数据）
local function port_vals(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 2 and b[1] == 0x01 then t[#t + 1] = b[2] end
	end
	return t
end
local function count_ptr(mark, p)
	local n = 0
	for _, x in ipairs(ptr_writes(mark)) do if x == p then n = n + 1 end end
	return n
end

-- 经写口握手写一个虚拟寄存器（直接点模型回调，组 1 造状态用）
local function vwrite(addr, val)
	assert(dev.write({ 0x01, addr + 0x80 }))
	assert(dev.write({ 0x01, val }))
end
-- 经写口握手读一个虚拟寄存器，返回读到的字节
local function vread(addr)
	assert(dev.write({ 0x00 }))
	assert(dev.read(1)[1] == 0)			-- 预冲刷 STATUS：无滞留 RX/TX 空
	assert(dev.write({ 0x01, addr }))	-- 读地址（bit7=0）
	assert(dev.write({ 0x00 }))
	assert(dev.read(1)[1] == 0x01)		-- RX_VALID 立即置位（零延迟）
	assert(dev.write({ 0x02 }))
	local b = dev.read(1)[1]
	return b
end

local CH = { "V", "B", "G", "Y", "O", "R" }

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

-- ---- POR 种子 ----
check("POR DEVICE_TYPE=0x3E", dev:device_type() == 0x3E, string.format("0x%02X", dev:device_type()))
check("POR CONTROL 合成读 0x08", dev:control() == 0x08, string.format("0x%02X", dev:control()))
check("POR CONTROL shadow 0x08", dev:control_shadow() == 0x08,
      string.format("0x%02X", dev:control_shadow()))
check("POR INT_T=0", dev:int_t() == 0)
check("POR GAIN=0(1x)", dev:gain() == 0)
check("POR BANK=2(连续全通道)", dev:bank() == 2)
check("POR TEMP=24°C", dev:temp_c() == 24, tostring(dev:temp_c()))
check("POR DATA_RDY=0", not dev:data_ready())
check("POR STATUS=0（TX/RX 空）", dev:status() == 0, tostring(dev:status()))
check("POR remaining=0", dev:remaining_ms() == 0, tostring(dev:remaining_ms()))
for i, name in ipairs(CH) do
	check("POR 通道 " .. name .. "=0", dev:channel(name) == 0)
	check("POR 序号 " .. i .. " 等价通道名", dev:channel(i) == 0)
end
check("POR 计数全 0", dev:reset_count() == 0 and dev:vread_count() == 0 and dev:vwrite_count() == 0)

-- ---- 零延迟握手读：STATUS 首读 TX=0、读地址后 RX 立即 1、读口消费清 0 ----
mark = section()
check("读 CONTROL 经握手得 0x08", vread(0x04) == 0x08)
check("读口消费后 RX 清空", dev:rx_pending() == nil)
dev.write({ 0x00 })
check("消费后 STATUS 回 0", dev.read(1)[1] == 0)
check("vread 计数 1", dev:vread_count() == 1, tostring(dev:vread_count()))
check("DEVICE_TYPE 经握手 0x3E", vread(0x00) == 0x3E)
check("TEMP 经握手 24", vread(0x06) == 24)

-- ---- 写口地址/数据状态机：数据 0x88 不得被误判为写地址 ----
mark = section()
check("写地址相位后 write_pending=0x05", dev.write({ 0x01, 0x85 }))
check("write_pending 观察口 0x05", dev:write_pending() == 0x05,
      tostring(dev:write_pending()))
check("数据相位 0x88 ACK", dev.write({ 0x01, 0x88 }))
check("数据 0x88 入 INT_T（未被当地址）", dev:int_t() == 0x88,
      string.format("0x%02X", dev:int_t()))
check("数据相位后 pending 清空", dev:write_pending() == nil)
check("vwrite 计数 1", dev:vwrite_count() == 1, tostring(dev:vwrite_count()))
dev.write({ 0x00 })
check("写全过程 TX 不忙 STATUS=0", dev.read(1)[1] == 0)

-- ---- DATA_RDY 只读动态合成：写 0 清、写 1 无效 ----
mark = section()
vwrite(0x04, 0x3A)			-- GAIN=3/BANK=2，bit1=1
check("DATA_RDY 写 1 无效（仍 false）", not dev:data_ready())
check("CONTROL 读回不含 bit1=0x38", dev:control() == 0x38,
      string.format("0x%02X", dev:control()))
check("shadow 同样不含 bit1", dev:control_shadow() == 0x38,
      string.format("0x%02X", dev:control_shadow()))
dev:virt_tick(0)				-- 唯一置就绪途径之一
check("tick 后 DATA_RDY=1", dev:data_ready())
check("CONTROL 合成读 0x3A", dev:control() == 0x3A, string.format("0x%02X", dev:control()))
vwrite(0x04, 0x3A)			-- 就绪态再写 bit1=1：保持
check("就绪态写 bit1=1 保持就绪", dev:data_ready() and dev:control() == 0x3A)
vwrite(0x04, 0x38)			-- bit1=0：清
check("写 bit1=0 清除就绪", not dev:data_ready() and dev:control() == 0x38)

-- ---- RST 位：自清除不落盘、回 POR、清 INT_T/就绪、计数 ----
mark = section()
vwrite(0x05, 50)
dev:virt_tick(0)
check("污染后 INT_T=50 且就绪", dev:int_t() == 50 and dev:data_ready())
vwrite(0x04, 0x88)			-- RST（数据 0x88 >=0x80 但在数据相位）
check("RST 计数 1", dev:reset_count() == 1, tostring(dev:reset_count()))
check("RST 位不落盘 shadow=0x08", dev:control_shadow() == 0x08,
      string.format("0x%02X", dev:control_shadow()))
check("RST 后 CONTROL=0x08", dev:control() == 0x08, string.format("0x%02X", dev:control()))
check("RST 清 INT_T 回 0", dev:int_t() == 0)
check("RST 清 DATA_RDY", not dev:data_ready())
check("RST 清通道", dev:channel("V") == 0)
check("RST 后 remaining=0", dev:remaining_ms() == 0)
check("RST 不改 DEVICE_TYPE", dev:device_type() == 0x3E)
vwrite(0x04, 0x88)
check("二次 RST 计数 2", dev:reset_count() == 2, tostring(dev:reset_count()))

-- ---- 转换门：INT_T=50 一轮 280ms；注入仅完成时同步 ----
mark = section()
-- POR 首轮 INT_T=0 周期在途（remaining=0 非 nil），先推进让它完成到空闲，
-- 与真实 build 的 RST 后 1000ms sleep 跨过首轮同款；之后清位才按新 INT_T 排轮
dev:advance(1)
check("POR 首轮完成到空闲", dev:data_ready() and dev:remaining_ms() == nil)
vwrite(0x05, 50)
check("cycle_ms=280", dev:cycle_ms() == 280, tostring(dev:cycle_ms()))
vwrite(0x04, 0x38)			-- 清位（BANK=2）排下一轮
check("清位后排 remaining=280", dev:remaining_ms() == 280,
      tostring(dev:remaining_ms()))
dev:set_result("V", 0x1234)
dev:set_result("B", 0x5678)
check("注入表已收 V", dev:result("V") == 0x1234)
check("未完成通道数据寄存器仍 0", dev:channel("V") == 0)
dev:advance(279.9)
check("279.9ms 未完成仍忙", not dev:data_ready())
check("279.9ms remaining≈0.1", math.abs((dev:remaining_ms() or 0) - 0.1) < 1e-9,
      tostring(dev:remaining_ms()))
check("门前通道仍 0", dev:channel("V") == 0)
dev:advance(0.2)
check("280.1ms 过門就绪", dev:data_ready())
check("完成时装入 V=0x1234", dev:channel("V") == 0x1234, string.format("0x%04X", dev:channel("V")))
check("完成时装入 B=0x5678", dev:channel("B") == 0x5678, string.format("0x%04X", dev:channel("B")))
check("未注入通道 G=0", dev:channel("G") == 0)
check("未注入通道 R=0", dev:channel("R") == 0)
vwrite(0x04, 0x38)
check("清 DATA_RDY 重排下一轮 280", dev:remaining_ms() == 280 and not dev:data_ready())

-- ---- BANK≠2 暂停转换；INT_T=0 周期 0（build RST 后首轮同款）----
mark = section()
vwrite(0x05, 50)
vwrite(0x04, 0x00)			-- GAIN=0/BANK=0
check("BANK=0 不排周期 remaining=nil", dev:remaining_ms() == nil)
dev:advance(9999)
check("BANK=0 advance 不置就绪", not dev:data_ready())
vwrite(0x05, 0)
vwrite(0x04, 0x08)			-- 回 BANK=2、清位；INT_T=0
check("INT_T=0 排周期 0", dev:remaining_ms() == 0)
dev:advance(1)
check("周期 0 advance 即完成", dev:data_ready())

-- ---- 六通道 MSB 偶地址 / LSB 奇地址，序号与名字等价 ----
mark = section()
local RAW = { V = 0x1234, B = 0x5678, G = 0x9ABC, Y = 0xDEF0, O = 0x1111, R = 0x2222 }
dev:set_results(RAW)			-- 仅入注入表
for i, name in ipairs(CH) do
	dev:set_channel_raw(name, RAW[name])
	check("通道 " .. name .. " MSB/LSB",
	      dev:vreg(0x08 + (i - 1) * 2) == math.floor(RAW[name] / 256)
	      and dev:vreg(0x09 + (i - 1) * 2) == RAW[name] % 256,
	      string.format("0x%02X%02X", dev:vreg(0x08 + (i - 1) * 2),
	                    dev:vreg(0x09 + (i - 1) * 2)))
	check("通道 " .. name .. " 拼回", dev:channel(name) == RAW[name])
	check("序号 " .. i .. " 与名字等价", dev:channel(i) == RAW[name])
end
dev:set_channel_raw("V", 70000)
check("u16 上钳 65535", dev:channel("V") == 65535, tostring(dev:channel("V")))
dev:set_channel_raw("V", -5)
check("u16 下钳 0", dev:channel("V") == 0)

-- ---- 温度二进制补码 + 钳位 ----
mark = section()
dev:set_temp(24)
check("温度 +24 编码 0x18", dev:vreg(0x06) == 0x18 and dev:temp_c() == 24)
dev:set_temp(-24)
check("温度 -24 编码 0xE8 还原", dev:vreg(0x06) == 0xE8 and dev:temp_c() == -24,
      string.format("0x%02X/%d", dev:vreg(0x06), dev:temp_c()))
dev:set_temp(-128)
check("温度 -128 编码 0x80", dev:vreg(0x06) == 0x80 and dev:temp_c() == -128)
dev:set_temp(200)
check("温度上钳 127", dev:temp_c() == 127 and dev:vreg(0x06) == 127)
dev:set_temp(-200)
check("温度下钳 -128", dev:temp_c() == -128 and dev:vreg(0x06) == 0x80)

-- ---- 握手卡死：TX 恒忙 / 读命令不置 RX ----
mark = section()
dev:set_tx_stuck(true)
check("tx_stuck STATUS bit1=1", dev:status() == 0x02, tostring(dev:status()))
dev.write({ 0x00 })
check("tx_stuck 读 STATUS=0x02", dev.read(1)[1] == 0x02)
dev:set_tx_stuck(false)
check("解除后 STATUS=0", dev:status() == 0)
dev:set_rx_stuck(true)
dev.write({ 0x01, 0x04 })
check("rx_stuck 读命令不置 RX", dev:rx_pending() == nil and dev:status() == 0)
dev:set_rx_stuck(false)
dev.write({ 0x01, 0x04 })
check("解除后 RX 立即置位", dev:rx_pending() == 0x04 and dev:status() == 0x01)

-- ---- never_ready：advance 不推、virt_tick 不武装 ----
mark = section()
dev:advance(1)				-- 先让 POR 零周期首轮完成到空闲
vwrite(0x05, 50)
vwrite(0x04, 0x38)
check("排轮 280", dev:remaining_ms() == 280)
dev:set_never_ready(true)
dev:advance(1000)
check("never_ready advance 不就绪", not dev:data_ready())
check("never_ready remaining 不推进", dev:remaining_ms() == 280,
      tostring(dev:remaining_ms()))
dev:virt_tick(0)
check("never_ready tick 不武装", not dev:data_ready())
check("never_ready tick 仍装通道数据", dev:channel("V") ~= 0)
dev:set_never_ready(false)
dev:advance(280)
check("解除后转换完成", dev:data_ready())

-- ---- virt_tick：确定性六通道正弦，n0/n8 峰/n24 谷/n32 周期 ----
mark = section()
dev:virt_tick(0)
check("tick n0 V=9000", dev:channel("V") == 9000, tostring(dev:channel("V")))
check("tick n0 B=16000", dev:channel("B") == 16000, tostring(dev:channel("B")))
check("tick n0 Y=31000", dev:channel("Y") == 31000, tostring(dev:channel("Y")))
check("tick n0 温度 25", dev:temp_c() == 25, tostring(dev:temp_c()))
check("tick n0 武装就绪", dev:data_ready())
local v0 = dev:channel("V")
dev:virt_tick(8)
local v8 = dev:channel("V")
check("tick n8 V 峰=12000", v8 == 12000, tostring(v8))
check("tick n8 温度 29", dev:temp_c() == 29, tostring(dev:temp_c()))
dev:virt_tick(24)
local v24 = dev:channel("V")
check("tick n24 V 谷=6000", v24 == 6000, tostring(v24))
check("tick n24 温度 21", dev:temp_c() == 21, tostring(dev:temp_c()))
dev:virt_tick(32)
check("tick n32=n0 周期", dev:channel("V") == v0, tostring(dev:channel("V")))
check("峰 > n0 > 谷", v8 > v0 and v0 > v24)

-- ---- 坏帧 NACK ----
mark = section()
check("非 table 写 NACK", dev.write(7) == false)
check("0B 写 NACK", dev.write({}) == false)
check("3B 写 NACK", dev.write({ 1, 2, 3 }) == false)
check("硬件指针越界 0x03 NACK", dev.write({ 0x03 }) == false)
check("写 STATUS(0x00) NACK", dev.write({ 0x00, 0x00 }) == false)
check("写 READ(0x02) NACK", dev.write({ 0x02, 0x00 }) == false)
check("写 0x03 数据 NACK", dev.write({ 0x03, 0x00 }) == false)
check("无指针读 NACK", dev.read(1) == nil)
dev.write({ 0x01 })
check("写口 0x01 读 NACK", dev.read(1) == nil)

-- ---- 故障钩子 + reset 保留 ----
mark = section()
dev.nack = true
check("nack 写失败", dev.write({ 0x01, 0x04 }) == false)
check("nack 读失败", dev.read(1) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write 写失败", dev.write({ 0x01, 0x04 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 读失败", dev.read(1) == nil)
dev.nack_read = false
dev:fail_write(function(b) return #b == 2 and b[1] == 0x01 and b[2] == 0x85 end)
check("谓词放行 CONTROL 写地址", dev.write({ 0x01, 0x84 }))
check("谓词拦截 INT_T 写地址", dev.write({ 0x01, 0x85 }) == false)
dev:fail_read(function(p) return p == 0x02 end)
dev.write({ 0x00 })
check("谓词放行 STATUS 读", dev.read(1) ~= nil)
dev.write({ 0x02 })
check("谓词拦截读口", dev.read(1) == nil)
dev:fail_read(); dev:fail_write()
dev.nack_read = true
dev:reset()
check("reset 保留故障钩子", dev.nack_read == true)
check("reset 回 POR CONTROL", dev:control() == 0x08)
check("reset 清 RST 计数", dev:reset_count() == 0)
dev:clear_faults()

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
-- 默认参数完整写口序列：
--   读 CONTROL(04) -> RST 写(84,88) -> 读 TYPE(00) ->
--   写 INT_T(85,32) -> 读 CONTROL(04) -> 写配置(84,3A)
mark = section()
local b = expect_ok("build 默认 gain64/integ50", function()
	return build({ fd = fd, address = "0x49" })
end)
check("build 后 INT_T=50", dev:int_t() == 50)
check("build 后 GAIN=3", dev:gain() == 3, tostring(dev:gain()))
check("build 后 BANK=2", dev:bank() == 2)
check("build 后 shadow=0x38（RDY 不入影子）", dev:control_shadow() == 0x38,
      string.format("0x%02X", dev:control_shadow()))
check("build 后首轮已就绪", dev:data_ready())
local pv = port_vals(mark)
local EXP_BUILD = { 0x04, 0x84, 0x88, 0x00, 0x85, 0x32, 0x04, 0x84, 0x3A }
check("build 写口 9 笔序列", #pv == #EXP_BUILD and table.concat(pv, ",") == table.concat(EXP_BUILD, ","),
      table.concat(pv, ","))
-- 读事务 = 3 虚拟读×4（预冲刷+等TX+等RX+读口）+ 3 虚拟写×2（两次等 TX）= 18
check("build 读事务 18 笔", #reads(mark) == 18, tostring(#reads(mark)))
check("build STATUS 指针 15 次（读9+写6）", count_ptr(mark, 0x00) == 15,
      tostring(count_ptr(mark, 0x00)))
check("build 读口指针 3 次", count_ptr(mark, 0x02) == 3, tostring(count_ptr(mark, 0x02)))
check("build 一次 set_addr 0x49",
      #set_addrs(mark) == 1 and set_addrs(mark)[1] == ADDR, table.concat(set_addrs(mark), ","))
check("build 仅 RST 硬睡 1000ms（握手零重试）", sleep_total == 1000, tostring(sleep_total))

-- 字符串 fd/address（框架元数据全是字符串）
mark = section()
expect_ok("build 字符串 fd='3' addr='0x49'", function()
	return build({ fd = "3", address = "0x49" })
end)
check("set_addr 收到 0x49=73", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 73,
      table.concat(set_addrs(mark), ","))

-- gain 就近吸附四档：尾写配置数据 = 0x02(保留 RDY) | code<<4 | 0x08
for _, t in ipairs({
	{ "1",    0, 0x0A },
	{ "3.7",  1, 0x1A },
	{ "16",   2, 0x2A },
	{ "64",   3, 0x3A },
	{ "20",   2, 0x2A },	-- 就近吸附到 16
}) do
	mark = section()
	expect_ok("build gain=" .. t[1], function()
		return build({ fd = fd, address = "0x49", gain = t[1] })
	end)
	check("gain=" .. t[1] .. " 代码 " .. t[2], dev:gain() == t[2], tostring(dev:gain()))
	local seq = port_vals(mark)
	check("gain=" .. t[1] .. " 尾配置字 0x" .. string.format("%02X", t[3]),
	      seq[#seq] == t[3], string.format("0x%02X", seq[#seq] or 0))
end

-- integ 归一/钳位
mark = section()
expect_ok("build integ=10", function()
	return build({ fd = fd, address = "0x49", integ = "10" })
end)
check("INT_T=10", dev:int_t() == 10)
check("cycle_ms=56", dev:cycle_ms() == 56, tostring(dev:cycle_ms()))
mark = section()
expect_ok("build integ=300 钳 255", function()
	return build({ fd = fd, address = "0x49", integ = "300" })
end)
check("INT_T=255", dev:int_t() == 255)

-- 器件甄别不符
mark = section()
dev:set_device_type(0x3D)			-- AS7261
expect_err("build 甄别拒绝 AS7261", function()
	return build({ fd = fd, address = "0x49" })
end, "expect 0x3E AS7262")
check("甄别失败前不写 INT_T", table.concat(port_vals(mark), ","):find("133") == nil
      and dev:int_t() == 0, table.concat(port_vals(mark), ","))

-- 握手挂死：首读 CONTROL 等 TX 超时（50 拍×5ms=250ms）
mark = section()
dev:set_tx_stuck(true)
expect_err("build TX 卡死", function()
	return build({ fd = fd, address = "0x49" })
end, "Failed to read AS7262 CONTROL_SETUP")
check("build 握手超时睡 250ms", sleep_total == 250, tostring(sleep_total))
dev:set_tx_stuck(false)

-- build 负路径
mark = section()
expect_err("build set_addr 失败（fd=99）", function()
	return build({ fd = 99, address = "0x49" })
end, "set_addr failed")
check("set_addr 失败零事务", #entries(mark) == 0)
section()
expect_err("build 缺 fd", function() return build({ address = "0x49" }) end, "fd or address")
section()
expect_err("build 缺 addr", function() return build({ fd = fd }) end, "fd or address")
section()
expect_err("build 非表参数", function() return build(nil) end, "Invalid Arguments Type")
section()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 首拍：build 的 RST advance(1000) 已完成首轮（值全 0）并置 RDY，
-- 直接装数据寄存器，call 首次轮询即就绪、零睡眠。
mark = section()
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x49" }) end)
dev:set_channel_raw("V", 0x1234); dev:set_channel_raw("B", 0x5678)
dev:set_channel_raw("G", 0x9ABC); dev:set_channel_raw("Y", 0xDEF0)
dev:set_channel_raw("O", 0x1111); dev:set_channel_raw("R", 0x2222)
dev:set_temp(24)
sleep_total = 0
mark = #vbus.txlog
local res = expect_ok("call 六通道+温度零睡眠", function()
	return call({ fd = fd, address = "0x49" })
end)
if res then
	check("V=0x1234", res.V == 0x1234, string.format("0x%04X", res.V))
	check("B=0x5678", res.B == 0x5678, string.format("0x%04X", res.B))
	check("G=0x9ABC", res.G == 0x9ABC, string.format("0x%04X", res.G))
	check("Y=0xDEF0", res.Y == 0xDEF0, string.format("0x%04X", res.Y))
	check("O=0x1111", res.O == 0x1111, string.format("0x%04X", res.O))
	check("R=0x2222", res.R == 0x2222, string.format("0x%04X", res.R))
	check("TEMP_C=24", res.TEMP_C == 24, tostring(res.TEMP_C))
end
check("首拍零睡眠", sleep_total == 0, tostring(sleep_total))
check("call 一次 set_addr", #set_addrs(mark) == 1)
pv = port_vals(mark)
-- 15 个读地址（poll CONTROL + 六通道×2 + TEMP + 清位前 CONTROL）+ 清位写(84,38)
local EXP_CALL = {
	0x04,
	0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13,
	0x06, 0x04,
	0x84, 0x38,
}
check("call 写口 17 笔序列", #pv == 17 and table.concat(pv, ",") == table.concat(EXP_CALL, ","),
      table.concat(pv, ","))
-- 读事务 = 15 虚拟读×4 + 清位虚拟写×2（两次等 TX）= 62
check("call 读事务 62 笔", #reads(mark) == 62, tostring(#reads(mark)))
check("call STATUS 指针 47 次（读45+清位写2）", count_ptr(mark, 0x00) == 47,
      tostring(count_ptr(mark, 0x00)))
check("call 读口指针 15 次", count_ptr(mark, 0x02) == 15, tostring(count_ptr(mark, 0x02)))
check("call 后清位重排 280ms", dev:remaining_ms() == 280 and not dev:data_ready())

-- 第二拍：5ms 步进轮询 56 拍=280ms，完成事件装入新一轮注入
dev:set_results({ V = 0xAAAA, B = 0xBBBB, G = 0xCCCC, Y = 0xDDDD, O = 0xEEEE, R = 0xFFFF })
sleep_total = 0
res = expect_ok("call 第二拍等 280ms 转换", function()
	return call({ fd = fd, address = "0x49" })
end)
check("第二拍睡 280ms（56×5ms）", sleep_total == 280, tostring(sleep_total))
if res then
	check("第二拍装入注入 V=0xAAAA", res.V == 0xAAAA, string.format("0x%04X", res.V))
	check("第二拍 R=0xFFFF", res.R == 0xFFFF, string.format("0x%04X", res.R))
end

-- 负温度补码
section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
dev:set_temp(-24)
sleep_total = 0
res = expect_ok("call 负温度", function() return call({ fd = fd, address = "0x49" }) end)
if res then check("TEMP_C=-24", res.TEMP_C == -24, tostring(res.TEMP_C)) end
check("负温度拍零睡眠", sleep_total == 0)

-- never_ready：首拍存量可读，第二拍耗尽 1060ms 预算超时
section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
dev:set_never_ready(true)
sleep_total = 0
expect_ok("never_ready 首拍读存量", function() return call({ fd = fd, address = "0x49" }) end)
check("首拍零睡眠", sleep_total == 0)
sleep_total = 0
expect_err("never_ready 第二拍超时 1060ms", function()
	return call({ fd = fd, address = "0x49" })
end, "data-ready timeout")
check("超时轮询睡满 1060ms", sleep_total == 1060, tostring(sleep_total))
dev:set_never_ready(false)

-- 握手挂死 / 总线读失败
section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
dev:set_tx_stuck(true)
sleep_total = 0
expect_err("call TX 卡死", function() return call({ fd = fd, address = "0x49" }) end,
           "Failed to poll AS7262 data-ready")
check("TX 卡死睡 250ms", sleep_total == 250, tostring(sleep_total))
dev:set_tx_stuck(false)

section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
dev.nack_read = true
sleep_total = 0
expect_err("call 总线读失败", function() return call({ fd = fd, address = "0x49" }) end,
           "Failed to poll AS7262 data-ready")
check("总线读失败零睡眠", sleep_total == 0)
dev:clear_faults()

-- 定向故障：poll CONTROL 的读口放行（第 1 次 0x02），V 通道 MSB（第 2 次）失败
section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
do
	local nread02 = 0
	dev:fail_read(function(p)
		if p ~= 0x02 then return false end
		nread02 = nread02 + 1
		return nread02 == 2	-- 第 2 次读口 = V MSB
	end)
end
expect_err("call 读 V 通道失败", function() return call({ fd = fd, address = "0x49" }) end,
           "Failed to read AS7262 channel V")
dev:clear_faults()

-- call 参数负路径
section()
expect_err("call set_addr 失败（fd=99）", function()
	return call({ fd = 99, address = "0x49" })
end, "set_addr failed")
section()
expect_err("call 缺 fd", function() return call({ address = "0x49" }) end, "fd or address")
section()
expect_err("call 缺 addr", function() return call({ fd = fd }) end, "fd or address")
section()
expect_err("call 非表参数", function() return call("x") end, "Invalid Arguments")
section()

-- virt_tick 守护式闭环：每拍预武装，call 全部零睡眠，值跟六通道正弦走
mark = section()
expect_ok("build", function() return build({ fd = fd, address = "0x49" }) end)
local TICK_V = { [0] = 9000, [8] = 12000, [24] = 6000 }
for _, n in ipairs({ 0, 8, 24 }) do
	dev:virt_tick(n)
	sleep_total = 0
	res = expect_ok("virt_tick n=" .. n .. " call 零睡眠", function()
		return call({ fd = fd, address = "0x49" })
	end)
	check(string.format("n=%d call 零睡眠", n), sleep_total == 0, tostring(sleep_total))
	if res then
		check(string.format("n=%d V 通道跟正弦 %d", n, TICK_V[n]),
		      res.V == TICK_V[n], tostring(res.V))
	end
end

-- =====================================================================
-- 组 4：destroy（无总线资源，零事务）
-- =====================================================================
mark = section()
expect_ok("destroy 正常表", function() return destroy({ fd = fd, address = "0x49" }) end)
check("destroy 零写事务", #writes(mark) == 0, tostring(#writes(mark)))
check("destroy 零读事务", #reads(mark) == 0, tostring(#reads(mark)))
check("destroy 零 set_addr", #set_addrs(mark) == 0, tostring(#set_addrs(mark)))
section()
expect_err("destroy 字符串参数", function() return destroy("x") end, "Invalid Arguments Type")
section()
expect_err("destroy nil 参数", function() return destroy(nil) end, "Invalid Arguments Type")
section()
expect_ok("destroy 空表也 OK（不校验 fd）", function() return destroy({}) end)
check("destroy 空表零事务", #entries(mark) == 0)

-- ==================== 汇总 ====================
tester.summary()

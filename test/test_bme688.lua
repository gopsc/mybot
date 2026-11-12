-- test_bme688.lua —— BME688 真实驱动 + 虚拟 I2C 总线 + 稀疏寄存器/forced 门模型
-- 用法（项目根目录）: luajit test/test_bme688.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：BME688_GC=1 luajit test/test_bme688.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 364 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/BME688.lua 尾部 BME688_VIRT，
-- 2026-09-15 自 virtbus/bme688.lua 迁入）」。三份独立实现交叉：模型只存
-- 协议字节/原始码（不含任何补偿），本测试照 Bosch BME68x-Sensor-API
-- v4.4.8 独立转录 42 字节解析与 float 补偿公式，与真实驱动交叉。
--
-- 旧桩互证假绿已戳破（API bme68x.c get_calib_data 实证）：
--   par_p8 必须按 int16_t 解释——旧桩第 36 行与驱动旧代码都漏了 s16，
--   负 p8 时气压偏出十几 hPa 仍互证假绿；驱动本次一并修复，本测试
--   独立参考照官方写成有符号，模型 NVM 种子含 p8=-4000 专此为证。
--
-- 覆盖七组：
--   1) 模型事实：POR/3 块 NVM 字节布局（独立 parse 钉死全部语义系数，
--      含 H1/H2 半字节、res_heat_range、有符号 range_sw_err）/指针自增
--      回绕/掩码/只读区丢弃/坏帧；forced 状态机：动态模式位、0x60 测量
--      状态、NEW_DATA 读出即清、meas_index、门限 12/160/100ms 与
--      gas_wait 编码、nb_conv 选 GAS_WAIT 寄存器；装场 17 字节双气体路
--      与四标志组合；软复位（注入态保留）/who/六类钩子/virt_tick 码钉
--   2) 真实 build：完整 txlog（软复位+10ms+双 ID+3 块分块读+七笔配置写）
--      与 RES_HEAT/GAS_WAIT 独立反算、参数档边界、BME680 变体
--   3) build 负路径：复位写/双 ID 读与错值/三校准块读/七配置写逐帧短路/
--      参数非法/非表/缺 fd/错地址
--   4) 真实 call：T/P/H/GAS 四通道独立公式交叉（高量程路）、160ms 门
--      逐轮询 txlog、BME680 低量程路（K1/K2 + range_sw_err）、二次 call
--      无 sleep 写、virt_tick 预武装零睡眠、场块读失败
--   5) call 负路径：CTRL 读/触发写/轮询读失败、300ms 超时（61 轮询/300ms）
--   6) GAS_OK 四标志组合（真实 call）
--   7) destroy 序列、缺 fd 安全、非表 ERR

if os.getenv("BME688_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x76
-- 模型内嵌于驱动文件（BME688_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/BME688.lua")
local mm = BME688_VIRT

local dev = mm.new()
vbus.attach("BME688@0x76", ADDR, dev)

-- ==================== 独立参考：42 字节解析（Bosch API v4.4.8） ====================
local function s8(v) v = v % 256; if v >= 128 then v = v - 256 end return v end
local function s16(v) v = v % 65536; if v >= 32768 then v = v - 65536 end return v end

-- 与驱动 parse_calib 同源 API、本测试独立转录；p8 必须是 s16（修复点）
local function ref_parse(b)
	local C = {}
	C.t1 = b[33] * 256 + b[32]
	C.t2 = s16(b[2] * 256 + b[1])
	C.t3 = s8(b[3])
	C.p1 = b[6] * 256 + b[5]
	C.p2 = s16(b[8] * 256 + b[7])
	C.p3 = s8(b[9])
	C.p4 = s16(b[12] * 256 + b[11])
	C.p5 = s16(b[14] * 256 + b[13])
	C.p6 = s8(b[16])
	C.p7 = s8(b[15])
	C.p8 = s16(b[20] * 256 + b[19])
	C.p9 = s16(b[22] * 256 + b[21])
	C.p10 = b[23]
	C.h1 = b[26] * 16 + (b[25] % 16)
	C.h2 = b[24] * 16 + math.floor(b[25] / 16)
	C.h3 = s8(b[27]); C.h4 = s8(b[28]); C.h5 = s8(b[29])
	C.h6 = b[30]; C.h7 = s8(b[31])
	C.gh1 = s8(b[36]); C.gh2 = s16(b[35] * 256 + b[34]); C.gh3 = s8(b[37])
	C.res_heat_val = s8(b[38])
	C.res_heat_range = math.floor((b[40] % 64) / 16)
	C.range_sw_err = math.floor(s8(b[42]) / 16)
	return C
end

-- ==================== 独立参考：Bosch float 补偿公式 ====================
local function ref_temperature(adc, C)
	local var1 = (adc / 16384.0 - C.t1 / 1024.0) * C.t2
	local var2 = ((adc / 131072.0 - C.t1 / 8192.0) ^ 2) * (C.t3 * 16.0)
	C.t_fine = var1 + var2
	return C.t_fine / 5120.0
end

local function ref_pressure(adc, C)
	local var1 = C.t_fine / 2.0 - 64000.0
	local var2 = var1 * var1 * (C.p6 / 131072.0)
	var2 = var2 + var1 * C.p5 * 2.0
	var2 = var2 / 4.0 + C.p4 * 65536.0
	var1 = (C.p3 * var1 * var1 / 16384.0 + C.p2 * var1) / 524288.0
	var1 = (1.0 + var1 / 32768.0) * C.p1
	local pres = 1048576.0 - adc
	if var1 ~= 0 then
		pres = (pres - var2 / 4096.0) * 6250.0 / var1
		local w1 = C.p9 * pres * pres / 2147483648.0
		local w2 = pres * (C.p8 / 32768.0)
		local w3 = (pres / 256.0) ^ 3 * (C.p10 / 131072.0)
		pres = pres + (w1 + w2 + w3 + C.p7 * 128.0) / 16.0
	end
	return pres
end

local function ref_humidity(adc, C)
	local tc = C.t_fine / 5120.0
	local var1 = adc - (C.h1 * 16.0 + C.h3 / 2.0 * tc)
	local var2 = var1 * (C.h2 / 262144.0 *
		(1.0 + C.h4 / 16384.0 * tc + C.h5 / 1048576.0 * tc * tc))
	local hum = var2 + (C.h6 / 16384.0 + C.h7 / 2097152.0 * tc) * var2 * var2
	return math.max(0.0, math.min(100.0, hum))
end

local K1 = { 0, 0, 0, 0, 0, -1, 0, -0.8, 0, 0, -0.2, -0.5, 0, -1, 0, 0 }
local K2 = { 0, 0, 0, 0, 0.1, 0.7, 0, -0.8, -0.1, 0, 0, 0, 0, 0, 0, 0 }
local function ref_gas_low(adc, range, sw_err)
	local var1 = 1340.0 + 5.0 * sw_err
	local var2 = var1 * (1.0 + K1[range + 1] / 100.0)
	local var3 = 1.0 + K2[range + 1] / 100.0
	return 1.0 / (var3 * 0.000000125 * (2 ^ range) * (((adc - 512.0) / var2) + 1.0))
end

local function ref_gas_high(adc, range)
	local var1 = math.floor(262144 / 2 ^ range)
	local var2 = (adc - 512) * 3 + 4096
	return 1000000.0 * var1 / var2
end

local function ref_res_heat(temp, C, amb)
	local t = math.min(temp, 400)
	local var1 = C.gh1 / 16.0 + 49.0
	local var2 = C.gh2 / 32768.0 * 0.0005 + 0.00235
	local var3 = C.gh3 / 1024.0
	local var5 = var1 * (1.0 + var2 * t) + var3 * amb
	local r = 3.4 * (var5 * (4 / (4 + C.res_heat_range)) *
		(1 / (1 + C.res_heat_val * 0.002)) - 25)
	return math.max(0, math.min(255, math.floor(r)))
end

-- 加热时长 → GAS_WAIT 寄存器值（与驱动 calc_gas_wait 独立同写）
local function ref_gas_wait(dur)
	if dur >= 0xFC0 then return 0xFF end
	local factor = 0
	while dur > 0x3F do dur = math.floor(dur / 4); factor = factor + 1 end
	return dur + factor * 64
end

-- gas_wait 寄存器逆向解码（ms，模型门限与本式独立交叉）
local function decode_wait(v) return (v % 64) * (4 ^ math.floor(v / 64)) end

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function relnear(a, b, rel) return math.abs(a - b) <= (rel or 1e-6) * math.max(1.0, math.abs(a), math.abs(b)) end

local CAL = ref_parse(dev:nvm())

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
local function frames(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "w" and #e.bytes >= 2 then t[#t + 1] = e.bytes end
	end
	return t
end
-- 指针式读序列：每条 r 对应最近一笔单字节指针写 → {p=reg, n=len}
local function ptr_reads(mark)
	local t, last = {}, nil
	for _, e in ipairs(entries(mark)) do
		if e.dir == "w" then
			last = #e.bytes == 1 and e.bytes[1] or nil
		elseif e.dir == "r" then
			t[#t + 1] = { p = last, n = e.bytes.n }
		end
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
local function count_reads(mark, p, n)
	local c = 0
	for _, e in ipairs(ptr_reads(mark)) do
		if e.p == p and e.n == n then c = c + 1 end
	end
	return c
end
local function rd(reg, n) dev.write({ reg }); return dev.read(n) end
local function byte(reg) return rd(reg, 1)[1] end

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
local mark = section()

-- POR（datasheet memory map）
check("POR 0x1D 状态=0x00", byte(0x1D) == 0x00)
check("POR press_msb/temp_msb/hum_msb=0x80",
	byte(0x1F) == 0x80 and byte(0x22) == 0x80 and byte(0x25) == 0x80)
check("POR 其余场字节 0（P/T/H lsb、gas 两路）",
	byte(0x20) == 0 and byte(0x21) == 0 and byte(0x23) == 0 and byte(0x24) == 0
	and byte(0x26) == 0 and byte(0x2A) == 0 and byte(0x2B) == 0
	and byte(0x2C) == 0 and byte(0x2D) == 0)
check("POR 配置寄存器全 0",
	byte(0x70) == 0 and byte(0x71) == 0 and byte(0x72) == 0
	and byte(0x74) == 0 and byte(0x75) == 0
	and byte(0x5A) == 0 and byte(0x64) == 0)
check("CHIP_ID=0x61 / 变体=0x01", byte(0xD0) == 0x61 and byte(0xF0) == 0x01)

-- NVM：总线分块读出的 42 字节与模型 nvm() 一致
local function bus_read_block(reg, n)
	local out = {}
	local done = 0
	while done < n do
		local c = math.min(6, n - done)
		local t = rd(reg + done, c)
		for i = 1, c do out[#out + 1] = t[i] end
		done = done + c
	end
	return out
end
do
	local nv = dev:nvm()
	local blk = {}
	local a = bus_read_block(0x8A, 23)
	for i = 1, 23 do blk[i] = a[i] end
	local b = bus_read_block(0xE1, 14)
	for i = 1, 14 do blk[23 + i] = b[i] end
	local c = bus_read_block(0x00, 5)
	for i = 1, 5 do blk[37 + i] = c[i] end
	local same = true
	for i = 1, 42 do if blk[i] ~= nv[i] then same = false end end
	check("3 块 NVM 总线读出 42 字节 = nvm()", same)
end

-- 独立 parse 钉死模型 NVM 语义（含 p8=-4000 的 s16 修复点）
check("NVM T 系数 t1=26280/t2=26505/t3=4",
	CAL.t1 == 26280 and CAL.t2 == 26505 and CAL.t3 == 4,
	string.format("%d/%d/%d", CAL.t1, CAL.t2, CAL.t3))
check("NVM P 系数 p1=37103 p2=-336 p8=-4000(s16) p9=-2105",
	CAL.p1 == 37103 and CAL.p2 == -336 and CAL.p3 == 88 and CAL.p4 == 3179
	and CAL.p5 == 64 and CAL.p6 == 45 and CAL.p7 == -67
	and CAL.p8 == -4000 and CAL.p9 == -2105 and CAL.p10 == 100,
	string.format("p1=%d p2=%d p3=%d p4=%d p5=%d p6=%d p7=%d p8=%d p9=%d p10=%d",
		CAL.p1, CAL.p2, CAL.p3, CAL.p4, CAL.p5, CAL.p6, CAL.p7, CAL.p8, CAL.p9, CAL.p10))
check("NVM H 半字节 h1=706/h2=891",
	CAL.h1 == 706 and CAL.h2 == 891 and CAL.h3 == 0 and CAL.h4 == 45
	and CAL.h5 == -20 and CAL.h6 == 120 and CAL.h7 == -100,
	string.format("h1=%d h2=%d h3=%d h4=%d h5=%d h6=%d h7=%d",
		CAL.h1, CAL.h2, CAL.h3, CAL.h4, CAL.h5, CAL.h6, CAL.h7))
check("NVM 加热器 gh1=-28/gh2=-11842/gh3=64",
	CAL.gh1 == -28 and CAL.gh2 == -11842 and CAL.gh3 == 64,
	string.format("%d/%d/%d", CAL.gh1, CAL.gh2, CAL.gh3))
check("NVM res_heat_val=30/range=1/range_sw_err=2（有符号高 4 位）",
	CAL.res_heat_val == 30 and CAL.res_heat_range == 1 and CAL.range_sw_err == 2,
	string.format("%d/%d/%d", CAL.res_heat_val, CAL.res_heat_range, CAL.range_sw_err))

-- 指针自增 + 模 256 回绕（0xFE→0xFF→0x00(NVM b38=30)→0x01(b39=0)）
do
	dev.write({ 0xFE })
	local t = dev.read(4)
	check("burst 指针自增并模 256 回绕进 COEFF3",
		t[1] == 0 and t[2] == 0 and t[3] == 30 and t[4] == 0,
		string.format("%d,%d,%d,%d", t[1], t[2], t[3], t[4]))
end

-- 未定义地址读 0，写 ACK 落盘
check("未定义地址 0x40 读 0", byte(0x40) == 0)
dev.write({ 0x40, 0x12 })
check("未定义地址写 ACK 且回读 12", byte(0x40) == 0x12)

-- 寄存器写掩码
dev.write({ 0x72, 0xFF }); check("CTRL_HUM 掩码 0x47", byte(0x72) == 0x47,
	string.format("%02X", byte(0x72)))
dev.write({ 0x75, 0xFF }); check("CONFIG 掩码 0x1D", byte(0x75) == 0x1D)
dev.write({ 0x70, 0xFF }); check("CTRL_GAS0 仅 bit3 → 0x08", byte(0x70) == 0x08)
dev.write({ 0x71, 0xFF }); check("CTRL_GAS1 掩码 0x3F", byte(0x71) == 0x3F)

-- 只读区写 ACK 丢弃
dev.write({ 0xD0, 0x99 }); check("CHIP_ID 只读写丢弃", byte(0xD0) == 0x61)
dev.write({ 0x8A, 0x00 }); check("COEFF1 只读写丢弃", byte(0x8A) == dev:nvm()[1])
dev:virt_tick(0); dev.write({ 0x74, 0x25 })	-- 预武装装一场
dev.write({ 0x22, 0x00 }); check("数据影子区只读写丢弃", byte(0x22) == math.floor(499588 / 4096) % 256)

-- 坏帧整笔 NACK
section()
check("空表写 NACK", dev.write({}) == false)
check("非表写 NACK", dev.write(nil) == false and dev.write(0x74) == false and dev.write("x") == false)
check("非字节写 NACK", dev.write({ 0x74, 300 }) == false and dev.write({ 0x74, "1" }) == false)
check("读 n 钳 1~16", #dev.read(0) == 1 and #dev.read(20) == 16)

-- ---- forced 状态机（非预武装，外部时钟） ----
section()
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 }); dev.write({ 0x75, 0x08 })
dev.write({ 0x64, 101 }); dev.write({ 0x70, 0x00 }); dev.write({ 0x71, 0x20 })
dev:set_tph_raw(505728, 298243, 25000)
local gate_cfg = dev:config()
check("配置解码 OSR 1/1/1 run_gas=2 heat_off=0 wait=148ms IIR 码 2",
	gate_cfg.os_t == 1 and gate_cfg.os_p == 1 and gate_cfg.os_h == 1
	and gate_cfg.run_gas == 2 and gate_cfg.heat_off == 0
	and gate_cfg.nb_conv == 0 and gate_cfg.gas_wait_ms == 148 and gate_cfg.iir == 2)
check("gas_wait 独立解码交叉：101→148ms", decode_wait(101) == 148)
check("gas_wait 边界：0→0 / 63→63 / 255→4032",
	decode_wait(0) == 0 and decode_wait(63) == 63 and decode_wait(255) == 4032)
dev.write({ 0x74, 0x25 })
check("触发后 busy / CTRL_MEAS 动态读回 0x25",
	dev:is_busy() and byte(0x74) == 0x25)
check("转换中状态字节 0x60（measuring+gas_measuring）", byte(0x1D) == 0x60)
check("默认档门限 160ms（TPH 12 + gas_wait 148）", dev:last_gate_ms() == 160,
	tostring(dev:last_gate_ms()))
check("159ms 未就绪", byte(0x1D) == 0x60)
dev:advance(159)
check("159ms 推进后仍忙", dev:is_busy() and byte(0x1D) == 0x60)
dev:advance(1)
check("160ms 到点 NEW_DATA=0x80 且回 sleep（CTRL 0x24）",
	byte(0x1D) == 0x80 and not dev:is_busy() and byte(0x74) == 0x24)
check("状态字节读出即清（new data not already read-out）", byte(0x1D) == 0x00)

-- 装场 17 字节解码（6/6/5 三块，含两路气体与 0x1E 序号）
do
	dev:set_meas_index(0)
	dev:set_gas_raw("low", 800, 5, true, false)
	dev:set_gas_raw("high", 600, 8, false, true)
	dev:set_tph_raw(505728, 298243, 25000)
	dev.write({ 0x74, 0x25 })
	dev:advance(160)
	dev.write({ 0x1D }); local f = dev.read(6)
	dev.write({ 0x23 }); local f2 = dev.read(6)
	dev.write({ 0x29 }); local f3 = dev.read(5)
	for i = 1, 6 do f[#f + 1] = f2[i] end
	for i = 1, 5 do f[#f + 1] = f3[i] end
	local ap = f[3] * 4096 + f[4] * 16 + math.floor(f[5] / 16)
	local at = f[6] * 4096 + f[7] * 16 + math.floor(f[8] / 16)
	local ah = f[9] * 256 + f[10]
	check("场 T/P/H 20/20/16 位拼装", at == 505728 and ap == 298243 and ah == 25000,
		string.format("%d/%d/%d", at, ap, ah))
	check("0x1E meas_index 首拍=0", f[2] == 0, tostring(f[2]))
	-- 低量程路 f[14]/f[15]：adc=800→msb=200 valid=1 stab=0 → 0x20+5
	check("低量程路 0x2A/2B 编码（adc800/range5/valid=1/stab=0）",
		f[14] == 200 and f[15] == 0x20 + 5, string.format("%02X/%02X", f[14], f[15]))
	-- 高量程路 f[16]/f[17]：adc=600 msb=150 valid=0 stab=1 → 0x10+8
	check("高量程路 0x2C/2D 编码（adc600/range8/valid=0/stab=1）",
		f[16] == 150 and f[17] == 0x10 + 8, string.format("%02X/%02X", f[16], f[17]))
	-- 下一场序号 +1
	dev.write({ 0x74, 0x25 })
	dev:advance(160)
	check("次场 meas_index=1", byte(0x1E) == 1, tostring(byte(0x1E)))
end

-- 门限变体：关加热器 / 禁 RUN_GAS / 高 OSR / nb_conv 选 GAS_WAIT
section()
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 })
dev.write({ 0x71, 0x20 }); dev.write({ 0x70, 0x08 }); dev.write({ 0x64, 101 })
dev.write({ 0x74, 0x25 })
check("heat_off=1 门限仅 TPH 12ms", dev:last_gate_ms() == 12, tostring(dev:last_gate_ms()))
section()
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 })
dev.write({ 0x71, 0x00 }); dev.write({ 0x64, 101 })
dev.write({ 0x74, 0x25 })
check("RUN_GAS=00 门限仅 TPH 12ms", dev:last_gate_ms() == 12)
section()
dev.write({ 0x72, 0x05 }); dev.write({ 0x74, 0xD4 })
dev.write({ 0x71, 0x10 }); dev.write({ 0x64, 0 })
dev.write({ 0x74, 0xD5 })
check("OSR x16/x16/x16 门限 100ms（cycles=48）", dev:last_gate_ms() == 100,
	tostring(dev:last_gate_ms()))
section()
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 })
dev.write({ 0x71, 0x29 })		-- nb_conv=9 → GAS_WAIT9 0x6D
dev.write({ 0x6D, 101 })		-- 148ms
dev.write({ 0x64, 0xFF })	-- 索引 0 不应被取
dev.write({ 0x70, 0x00 })
dev.write({ 0x74, 0x25 })
check("nb_conv=9 门取 GAS_WAIT9(0x6D)：160ms", dev:last_gate_ms() == 160,
	tostring(dev:last_gate_ms()))

-- 软复位
section()
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 }); dev.write({ 0x64, 101 })
dev:set_tph_raw(1, 2, 3); dev:virt_tick(7)
dev.write({ 0xE0, 0xB6 })
check("软复位 reset_count=1", dev:reset_count() == 1)
check("软复位清配置/场 POR", byte(0x74) == 0 and byte(0x1F) == 0x80)
check("软复位保留注入码与预武装", (select(1, dev:raw())) == 508897)
dev.write({ 0x72, 0x01 }); dev.write({ 0x74, 0x24 }); dev.write({ 0x64, 101 })
dev.write({ 0x71, 0x20 }); dev.write({ 0x70, 0x00 })
dev.write({ 0x74, 0x25 })
check("软复位后预武装仍触发即就绪", byte(0x1D) == 0x80)

-- who 误挂与回出厂
section()
dev:who(0x58, 0x02)
check("who 覆写双身份", byte(0xD0) == 0x58 and byte(0xF0) == 0x02)
dev:reset()
check("reset 身份回出厂 0x61/0x01", byte(0xD0) == 0x61 and byte(0xF0) == 0x01)

-- 故障钩子
section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0xE0 end)
check("fail_write 谓词只断复位写",
	dev.write({ 0xE0, 0xB6 }) == false and dev.write({ 0x74, 0x24 }) == true)
dev:clear_faults()
dev:fail_read(function(p, n) return p == 0xD0 end)
check("fail_read 谓词只断 0xD0", rd(0xD0, 1) == nil and byte(0xF0) == 0x01)
dev:clear_faults()
dev.nack_write = true
check("nack_write 全写断", dev.write({ 0x74, 0x24 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 全读断", dev.read(1) == nil)
dev.nack_read = false
dev.nack = true
check("nack 全断", dev.write({ 0x74 }) == false and dev.read(1) == nil)
dev.nack = false
check("reset 保留故障钩子（防负路径假解除）", (function()
	dev:fail_write(function(fr) return fr[1] == 0xE0 end)
	dev:reset()
	return dev.write({ 0xE0, 0xB6 }) == false
end)())
dev:clear_faults()

-- virt_tick 码钉
section()
local t0 = { dev:raw() }
dev:virt_tick(0)
local t1 = { dev:raw() }
check("tick(0) 原始码钉 T499588/P398974/H19950/G924-r12",
	t1[1] == 499588 and t1[2] == 398974 and t1[3] == 19950
	and t1[4] == 924 and t1[5] == 12,
	(function()
		local s = {} for i = 1, #t1 do s[i] = tostring(t1[i]) end
		return table.concat(s, ",")
	end)())
dev:virt_tick(8)
local t8 = { dev:raw() }
check("tick(8) 峰点 T509080/P403555/H21025/G924",
	t8[1] == 509080 and t8[2] == 403555 and t8[3] == 21025 and t8[4] == 924)
dev:virt_tick(24)
local t24 = { dev:raw() }
check("tick(24) 谷点 T490097/P400155/H23854/G332",
	t24[1] == 490097 and t24[2] == 400155 and t24[3] == 23854 and t24[4] == 332
	and t24[5] == 12)
do
	local d2 = mm.new(); d2:virt_tick(0)
	local o = { d2:raw() }
	check("tick 确定性（两实例 n0 相同）", o[1] == t1[1] and o[2] == t1[2] and o[3] == t1[3])
end
check("tick 两路气体同码同标志", t1[4] == t1[8] and t1[5] == t1[9] and t1[6] and t1[7])
dev.write({ 0x74, 0x25 })
check("tick 预武装触发即就绪零等待", dev:has_new_data())

-- reset 还原默认注入
section()
dev:set_tph_raw(1, 2, 3); dev:set_gas_raw("high", 5, 1, false, false)
dev:reset()
local r0 = { dev:raw() }
check("reset 还原默认码 524288/300000/30000 gas600/8 标志全 1",
	r0[1] == 524288 and r0[2] == 300000 and r0[3] == 30000 and r0[4] == 600
	and r0[5] == 8 and r0[6] == true and r0[7] == true)

-- ======================================================================
-- 组 2：真实 build（序列/参数档/变体）
-- ======================================================================
mark = section()
local res_heat_default = ref_res_heat(320, CAL, 25)
local r = expect_ok("build 默认 320C/150ms/amb25",
	function() return build({ fd = fd, address = "0x76" }) end)
if r then
	check("build set_addr 留痕 0x76", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x76)
	check("build 睡眠仅软复位后 10ms", sleep_total == 10, tostring(sleep_total))
	local fs = frames(mark)
	check("build 恰好 8 笔数据写（复位+七配置）", #fs == 8, tostring(#fs))
	check("build 写帧序 E0B6/72-01/74-24/75-08/5A-RH/64-65/70-00/71-20",
		fs[1][1] == 0xE0 and fs[1][2] == 0xB6
		and fs[2][1] == 0x72 and fs[2][2] == 0x01
		and fs[3][1] == 0x74 and fs[3][2] == 0x24
		and fs[4][1] == 0x75 and fs[4][2] == 0x08
		and fs[5][1] == 0x5A and fs[5][2] == res_heat_default
		and fs[6][1] == 0x64 and fs[6][2] == 101
		and fs[7][1] == 0x70 and fs[7][2] == 0x00
		and fs[8][1] == 0x71 and fs[8][2] == 0x20,
		table.concat((function()
			local t = {} for _, x in ipairs(fs) do t[#t + 1] = string.format("%02X%02X", x[1], x[2]) end
			return t
		end)(), ","))
	check("RES_HEAT0 独立反算一致", fs[5][2] == res_heat_default,
		string.format("%d vs %d", fs[5][2], res_heat_default))
	local pr = ptr_reads(mark)
	local expect_pr = {
		{ 0xD0, 1 }, { 0xF0, 1 },
		{ 0x8A, 6 }, { 0x90, 6 }, { 0x96, 6 }, { 0x9C, 5 },
		{ 0xE1, 6 }, { 0xE7, 6 }, { 0xED, 2 },
		{ 0x00, 5 },
	}
	local same = #pr == #expect_pr
	for i = 1, #expect_pr do
		if same and (pr[i].p ~= expect_pr[i][1] or pr[i].n ~= expect_pr[i][2]) then same = false end
	end
	check("build 指针读序：双 ID + COEFF1[6,6,6,5] + COEFF2[6,6,2] + COEFF3[5]",
		same, (function()
			local t = {} for _, e in ipairs(pr) do t[#t + 1] = string.format("%02X×%d", e.p, e.n) end
			return table.concat(t, ",")
		end)())
	check("build 寄存器落盘 0x72=01/0x74=24/0x75=08/0x64=65/0x70=00/0x71=20",
		byte(0x72) == 0x01 and byte(0x74) == 0x24 and byte(0x75) == 0x08
		and byte(0x64) == 0x65 and byte(0x70) == 0x00 and byte(0x71) == 0x20)
end

-- NaN 反例（26.1）：heatr_temp/heatr_dur/amb_temp 三列的 `tonumber(x) or 缺省`
-- 兜不住 NaN（'nan' 过 tonumber 出的是 number、Lua 里 truthy），而 `< 100`/
-- `> 400`/`< 1`/`> 4032` 四条区间判定对 NaN 恒假放行；amb_temp 更是完全没有
-- 区间判定。NaN/inf 一路传到 calc_res_heat/calc_gas_wait，最后被 HAL 的
-- byte_of 挡成 nil，报成 "BME688 not responding (RES_HEAT0 write failed)"
-- ——把配置笔误误报成器件掉线。三列应与 'abc' 同归缺省（320C/150ms/25C）。
mark = section()
r = expect_ok("build heatr_temp/heatr_dur/amb_temp='nan' 同归缺省",
	function() return build({ fd = fd, address = "0x76",
		heatr_temp = "nan", heatr_dur = "nan", amb_temp = "nan" }) end)
if r then
	local fs = frames(mark)
	check("NaN 三列的 RES_HEAT0/GAS_WAIT0 与缺省逐位同值",
		fs[5] and fs[5][1] == 0x5A and fs[5][2] == res_heat_default
		and fs[6] and fs[6][1] == 0x64 and fs[6][2] == 101,
		table.concat((function()
			local t = {} for _, x in ipairs(fs) do
				t[#t + 1] = string.format("%02X%02X", x[1], x[2])
			end
			return t
		end)(), ","))
end
mark = section()
r = expect_ok("build amb_temp='inf' 同归缺省 25C（该列无区间判定）",
	function() return build({ fd = fd, address = "0x76", amb_temp = "inf" }) end)
if r then
	local fs = frames(mark)
	check("amb_temp inf → RES_HEAT0 仍为 25C 反算值",
		fs[5] and fs[5][2] == res_heat_default, tostring(fs[5] and fs[5][2]))
end

-- 参数档边界 + RES_HEAT 随 amb/temp 变化
mark = section()
r = expect_ok("build 边界档 100C/4032ms",
	function() return build({ fd = fd, address = "0x76", heatr_temp = "100", heatr_dur = "4032" }) end)
if r then
	local fs = frames(mark)
	local rh100 = ref_res_heat(100, CAL, 25)
	check("100C RES_HEAT 独立反算", fs[5][2] == rh100, string.format("%d vs %d", fs[5][2], rh100))
	check("4032ms GAS_WAIT=0xFF（含 0xFC0 边界）", fs[6][2] == 0xFF and ref_gas_wait(4032) == 0xFF,
		string.format("%02X", fs[6][2]))
	check("1ms GAS_WAIT 编码=1", ref_gas_wait(1) == 1)
end
mark = section()
r = expect_ok("build amb_temp=40 影响 RES_HEAT",
	function() return build({ fd = fd, address = "0x76", amb_temp = "40" }) end)
if r then
	local fs = frames(mark)
	check("amb40 RES_HEAT 独立反算", fs[5][2] == ref_res_heat(320, CAL, 40))
	check("amb 改变 RES_HEAT 值", fs[5][2] ~= res_heat_default)
end
mark = section()
r = expect_ok("build 400C 上限",
	function() return build({ fd = fd, address = "0x76", heatr_temp = "400" }) end)
if r then
	local fs = frames(mark)
	check("400C RES_HEAT 独立反算", fs[5][2] == ref_res_heat(400, CAL, 25))
end

-- BME680 变体
mark = section()
dev:who(0x61, 0x00)
r = expect_ok("build BME680 变体（0xF0=0x00）",
	function() return build({ fd = fd, address = "0x76" }) end)
if r then
	local fs = frames(mark)
	check("BME680 CTRL_GAS1=0x10（低量程 RUN_GAS）",
		fs[8][1] == 0x71 and fs[8][2] == 0x10, string.format("%02X", fs[8][2]))
end

-- ======================================================================
-- 组 3：build 负路径
-- ======================================================================
section()
expect_err("build 非 table 参数", function() return build(0) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x76" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build 未打开 fd=99", function() return build({ fd = 99, address = "0x76" }) end, "set_addr failed")

section()
expect_err("build 错地址 0x60（无挂载→复位写 NACK）",
	function() return build({ fd = fd, address = "0x60" }) end, "soft reset failed")

section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0xE0 end)
expect_err("build 软复位写失败",
	function() return build({ fd = fd, address = "0x76" }) end, "soft reset failed")

section()
dev:fail_read(function(p) return p == 0xD0 end)
expect_err("build CHIP_ID 读失败",
	function() return build({ fd = fd, address = "0x76" }) end, "read chip id failed")

section()
dev:who(0x58, 0x01)
expect_err("build CHIP_ID 错值（BMP280 0x58）",
	function() return build({ fd = fd, address = "0x76" }) end, "unexpected chip id")

section()
dev:who(0x61, 0x02)
expect_err("build 变体错值 0x02",
	function() return build({ fd = fd, address = "0x76" }) end, "unexpected variant")

section()
dev:fail_read(function(p) return p >= 0x8A and p <= 0xA0 end)
expect_err("build COEFF1 读失败",
	function() return build({ fd = fd, address = "0x76" }) end, "read calibration failed")
section()
dev:fail_read(function(p) return p >= 0xE1 and p <= 0xEE end)
expect_err("build COEFF2 读失败",
	function() return build({ fd = fd, address = "0x76" }) end, "read calibration failed")
section()
dev:fail_read(function(p) return p >= 0x00 and p <= 0x04 end)
expect_err("build COEFF3 读失败",
	function() return build({ fd = fd, address = "0x76" }) end, "read calibration failed")

-- 七笔配置写逐帧短路
local cfg_fails = {
	{ 0x72, "CTRL_HUM" }, { 0x74, "CTRL_MEAS" }, { 0x75, "CONFIG" },
	{ 0x5A, "RES_HEAT0" }, { 0x64, "GAS_WAIT0" }, { 0x70, "CTRL_GAS0" },
	{ 0x71, "CTRL_GAS1" },
}
for _, spec in ipairs(cfg_fails) do
	section()
	local reg, what = spec[1], spec[2]
	dev:fail_write(function(fr) return #fr == 2 and fr[1] == reg end)
	expect_err("build " .. what .. " 写失败",
		function() return build({ fd = fd, address = "0x76" }) end, what .. " write failed")
end

section()
expect_err("build heatr_temp=50 非法",
	function() return build({ fd = fd, address = "0x76", heatr_temp = "50" }) end, "heatr_temp")
expect_err("build heatr_temp=401 非法",
	function() return build({ fd = fd, address = "0x76", heatr_temp = "401" }) end, "heatr_temp")
expect_err("build heatr_dur=5000 非法",
	function() return build({ fd = fd, address = "0x76", heatr_dur = "5000" }) end, "heatr_dur")
expect_err("build heatr_dur=0 非法",
	function() return build({ fd = fd, address = "0x76", heatr_dur = "0" }) end, "heatr_dur")

-- ======================================================================
-- 组 4：真实 call（四通道交叉 / 门限轮询 / 680 低路 / 预武装）
-- ======================================================================
mark = section()
build({ fd = fd, address = "0x76" })
dev:set_tph_raw(505728, 298243, 25000)
dev:set_gas_raw("high", 600, 8, true, true)
mark = #vbus.txlog
local sleep_base = sleep_total
r = expect_ok("call 高量程四通道补偿",
	function() return call({ fd = fd, address = "0x76" }) end)
if r then
	local refT = ref_temperature(505728, CAL)
	local refP = ref_pressure(298243, CAL)
	local refH = ref_humidity(25000, CAL)
	local refG = ref_gas_high(600, 8)
	check("T 与独立公式一致", relnear(r.T, refT, 1e-9),
		string.format("%.6f vs %.6f", r.T, refT))
	check("P 与独立公式一致（p8 s16 修复点）", relnear(r.P, refP, 1e-9),
		string.format("%.3f vs %.3f", r.P, refP))
	check("H 与独立公式一致", relnear(r.H, refH, 1e-9),
		string.format("%.6f vs %.6f", r.H, refH))
	check("GAS 高量程与独立公式一致", relnear(r.GAS, refG, 1e-9),
		string.format("%.3f vs %.3f", r.GAS, refG))
	check("GAS_OK=1", r.GAS_OK == 1, tostring(r.GAS_OK))
	check("call 睡眠 160ms（门限步进 5ms×32）", sleep_total - sleep_base == 160,
		tostring(sleep_total - sleep_base))
	check("call 轮询 0x1D 共 33 次（0..160ms）", count_reads(mark, 0x1D, 1) == 33,
		tostring(count_reads(mark, 0x1D, 1)))
	check("call 读 CTRL_MEAS 1 次", count_reads(mark, 0x74, 1) == 1)
	check("call 场块 6/6/5",
		count_reads(mark, 0x1D, 6) == 1 and count_reads(mark, 0x23, 6) == 1
		and count_reads(mark, 0x29, 5) == 1)
	local fs = frames(mark)
	check("call 数据写恰 1 笔触发 0x74|0x25（POR sleep 无 sleep 写）",
		#fs == 1 and fs[1][1] == 0x74 and fs[1][2] == 0x25, tostring(#fs))
end

-- 二次 call：完成回 sleep 后无 sleep 写
mark = #vbus.txlog
r = expect_ok("二次 call 正常", function() return call({ fd = fd, address = "0x76" }) end)
if r then
	local fs = frames(mark)
	check("二次 call 仍恰 1 笔 0x74 写（无多余 sleep 写）",
		#fs == 1 and fs[1][2] == 0x25, tostring(#fs))
end

-- BME680 低量程气体路
mark = section()
dev:who(0x61, 0x00)
build({ fd = fd, address = "0x76" })
dev:set_tph_raw(515000, 301000, 28000)
dev:set_gas_raw("low", 800, 5, true, true)
mark = #vbus.txlog
r = expect_ok("call BME680 低量程气体路",
	function() return call({ fd = fd, address = "0x76" }) end)
if r then
	local refT = ref_temperature(515000, CAL)
	local refP = ref_pressure(301000, CAL)
	local refH = ref_humidity(28000, CAL)
	local refG = ref_gas_low(800, 5, CAL.range_sw_err)
	check("680 T/P/H 一致", relnear(r.T, refT, 1e-9) and relnear(r.P, refP, 1e-9)
		and relnear(r.H, refH, 1e-9))
	check("680 GAS 低量程 K1/K2+range_sw_err 一致", relnear(r.GAS, refG, 1e-9),
		string.format("%.4f vs %.4f", r.GAS, refG))
	check("680 GAS_OK=1", r.GAS_OK == 1)
	check("680 call 门限仍 160ms（RUN_GAS=0x10）", sleep_total == 160 + 10,
		tostring(sleep_total))
end

-- virt_tick 预武装样本经真实驱动（零睡眠）
mark = section()
dev:who(0x61, 0x01)
build({ fd = fd, address = "0x76" })
dev:virt_tick(8)
mark = #vbus.txlog
sleep_base = sleep_total
r = expect_ok("call virt_tick(8) 预武装样本",
	function() return call({ fd = fd, address = "0x76" }) end)
if r then
	local refT = ref_temperature(509080, CAL)
	local refP = ref_pressure(403555, CAL)
	local refH = ref_humidity(21025, CAL)
	local refG = ref_gas_high(924, 13)
	check("tick8 T/P/H/GAS 与独立公式一致",
		relnear(r.T, refT, 1e-9) and relnear(r.P, refP, 1e-9)
		and relnear(r.H, refH, 1e-9) and relnear(r.GAS, refG, 1e-9),
		string.format("T%.4f/%.4f P%.2f/%.2f H%.4f/%.4f G%.1f/%.1f",
			r.T, refT, r.P, refP, r.H, refH, r.GAS, refG))
	check("tick8 GAS_OK=1", r.GAS_OK == 1)
	check("预武装零睡眠（call delta=0）", sleep_total - sleep_base == 0,
		tostring(sleep_total - sleep_base))
	check("预武装首轮询即就绪：0x1D n1 仅 1 次", count_reads(mark, 0x1D, 1) == 1)
end

-- 场块读失败（轮询过、首块 6B 失败）
section()
build({ fd = fd, address = "0x76" })
dev:virt_tick(0)
dev:fail_read(function(p, n) return p == 0x1D and n == 6 end)
expect_err("call 场首块读失败",
	function() return call({ fd = fd, address = "0x76" }) end, "read field failed")
section()
build({ fd = fd, address = "0x76" })
dev:virt_tick(0)
dev:fail_read(function(p) return p == 0x23 end)
expect_err("call 场第二块读失败",
	function() return call({ fd = fd, address = "0x76" }) end, "read field failed")

-- ======================================================================
-- 组 5：call 负路径
-- ======================================================================
section()
expect_err("call 非 table 参数", function() return call(3) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
expect_err("call fd=99", function() return call({ fd = 99, address = "0x76" }) end, "set_addr failed")

section()
build({ fd = fd, address = "0x76" })
dev:fail_read(function(p) return p == 0x74 end)
expect_err("call CTRL_MEAS 读失败",
	function() return call({ fd = fd, address = "0x76" }) end, "read CTRL_MEAS failed")

section()
build({ fd = fd, address = "0x76" })
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0x74 end)
expect_err("call 触发写失败",
	function() return call({ fd = fd, address = "0x76" }) end, "trigger write failed")

section()
build({ fd = fd, address = "0x76" })
dev:set_never_ready(true)
mark = #vbus.txlog
sleep_base = sleep_total
expect_err("call 转换超时 300ms",
	function() return call({ fd = fd, address = "0x76" }) end, "not ready")
check("超时前实睡 300ms", sleep_total - sleep_base == 300, tostring(sleep_total - sleep_base))
check("超时轮询 61 次（0..300ms 每 5ms）", count_reads(mark, 0x1D, 1) == 61,
	tostring(count_reads(mark, 0x1D, 1)))
dev:clear_faults()

section()
build({ fd = fd, address = "0x76" })
dev:set_never_ready(true)
expect_err("call wait=25ms 提前超时",
	function() return call({ fd = fd, address = "0x76", wait = "25" }) end, "not ready")
dev:clear_faults()

-- NaN 反例（26.1，本组后果最重）：`tonumber(data.wait) or cfg_wait or 300` 的
-- or 兜不住 NaN，而 `wait_ms < 0` 对 NaN 为假，于是 wait_ms = NaN 一路带到轮询
-- 循环的 `if waited >= wait_ms then return err(...)`——NaN 与任何数比较都为假，
-- **超时分支永不触发**：器件不就绪时循环永不退出（挂死，不是错值）。同一驱动
-- build 侧的 wait 列早已改用 finite_of，call 侧漏了，正是「防护漂移」的实证。
-- 本用例修复前不会失败而是**挂住**，故红基线用 timeout 取（见提交信息）。
section()
build({ fd = fd, address = "0x76" })
dev:set_never_ready(true)
mark = #vbus.txlog
sleep_base = sleep_total
expect_err("call wait='nan' 回落缺省 300ms 超时（非挂死）",
	function() return call({ fd = fd, address = "0x76", wait = "nan" }) end, "not ready")
check("wait NaN 回落缺省：实睡 300ms、轮询 61 次",
	sleep_total - sleep_base == 300 and count_reads(mark, 0x1D, 1) == 61,
	string.format("sleep=%d reads=%d", sleep_total - sleep_base,
		count_reads(mark, 0x1D, 1)))
dev:clear_faults()

section()
build({ fd = fd, address = "0x76" })
dev:set_never_ready(true)
dev:fail_read(function(p, n) return p == 0x1D and n == 1 end)
expect_err("call 轮询读失败",
	function() return call({ fd = fd, address = "0x76" }) end, "poll failed")
dev:clear_faults()

-- ======================================================================
-- 组 6：GAS_OK 标志四组合（真实 call，预武装零睡眠）
-- ======================================================================
section()
build({ fd = fd, address = "0x76" })
dev:virt_tick(0)
local function flag_call(valid, stab)
	dev:set_gas_flags("high", valid, stab)
	return call({ fd = fd, address = "0x76" })
end
check("valid=1 stab=1 → GAS_OK=1", flag_call(true, true).GAS_OK == 1)
check("valid=0 stab=1 → GAS_OK=0", flag_call(false, true).GAS_OK == 0)
check("valid=1 stab=0 → GAS_OK=0", flag_call(true, false).GAS_OK == 0)
check("valid=0 stab=0 → GAS_OK=0", flag_call(false, false).GAS_OK == 0)
check("标志坏时数值仍返回（交消费者决策）",
	flag_call(false, false).GAS ~= nil and flag_call(false, false).T ~= nil)

-- ======================================================================
-- 组 7：destroy
-- ======================================================================
mark = section()
build({ fd = fd, address = "0x76" })
mark = #vbus.txlog
expect_ok("destroy 置睡眠", function() return destroy({ fd = fd, address = "0x76" }) end)
do
	local fs = frames(mark)
	check("destroy 恰 1 笔写 0x74 清模式位（写 0x24）",
		#fs == 1 and fs[1][1] == 0x74 and fs[1][2] == 0x24,
		(function()
			local t = {} for _, x in ipairs(fs) do t[#t + 1] = string.format("%02X%02X", x[1], x[2]) end
			return table.concat(t, ",")
		end)())
	check("destroy 先读一次 CTRL_MEAS", count_reads(mark, 0x74, 1) == 1)
	check("destroy 共 4 事务（set+指针+读+写）", #entries(mark) == 4, tostring(#entries(mark)))
	check("destroy 后模式位清零", byte(0x74) % 4 == 0)
end

mark = section()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
check("destroy 缺 fd 零事务", #entries(mark) == 0, tostring(#entries(mark)))
section()
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_bme688")

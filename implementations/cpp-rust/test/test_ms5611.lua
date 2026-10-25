-- test_ms5611.lua —— MS5611 真实驱动 + 虚拟 I2C 总线 + 命令式气压计模型
-- 用法（项目根目录）: luajit test/test_ms5611.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的 312 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/MS5611.lua 尾部 MS5611_VIRT，
-- 2026-09-15 自 virtbus/ms5611.lua 迁入）」。本器件是 virtbus 库【首个
-- 「单字节命令里编码通道+OSR 档位」+「指针读 PROM/ADC」+ PROM 出厂校准
-- CRC-4 校验的命令式 I2C 器件】：无寄存器地图——0x1E 复位、0x40+2i/
-- 0x50+2i 启动 D1/D2 转换走 i2c_write_multi 单字节命令；PROM（0xA0+2i
-- 指针 + 2B 读）与 24 位 ADC（0x00 指针 + 3B 读）走 i2c_read_multi，
-- virtbus 复刻为「指针写事务 + 纯读」两步。补偿解算（一阶/二阶，
-- d1*sens ~2^56 拆位）完全在驱动侧，模型只给 PROM 系数与 24 位原始码。
--
-- 覆盖：模型侧 CRC-4 自洽（模型实现公开 + 测试 ffi/独立算法三方交叉）/
-- PROM 指针读八字与读后指针失效/长度约束/转换命令编码（偶数+区间，
-- 保留码 NACK）/五档 datasheet 最大转换门 0.60~9.04ms 边界/转换中与
-- 未启动 ADC 读 NACK/结果保持/D1D2 码区分/24 位钳制/set_pt 暖机一阶
-- 逆模型/armed 预武装/六类钩子/virt_tick 节拍；真实 build「复位→
-- 八字 PROM 指针读→CRC 校验兼在位甄别」事务序列与八路负路径；真实
-- call 双段转换命令-等待-指针读序列（ffi int64 独立参考复算暖机/低温
-- 二阶/极低温追加项三分支）/OSR 降档睡眠节拍/p0 海拔/virt_tick 零
-- 等待两拍/八路负路径；destroy 零总线事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（MS5611_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MS5611.lua")
local smod = MS5611_VIRT

local ADDR = 0x77
local dev = smod.new()
vbus.attach("MS5611@0x77", ADDR, dev)

local bitc = dofile("modules/bitcompat.lua")
local ffi = require("ffi")
local i64 = ffi.typeof("int64_t")

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

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
		if e.dir == "w" then t[#t + 1] = e.bytes[1] end
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

-- 测试侧独立 CRC-4（TE/PX4 同款布局，与模型/驱动实现各自独立）
local function test_crc_nib(prom8)
	local n_prom = {}
	for i = 1, 8 do n_prom[i] = prom8[i] % 65536 end
	local crc_read = math.floor(n_prom[8] / 4096) % 16
	n_prom[8] = n_prom[8] - (n_prom[8] % 256)
	local n_rem = 0
	for cnt = 0, 15 do
		local w = n_prom[math.floor(cnt / 2) + 1]
		if cnt % 2 == 1 then
			n_rem = bitc.bxor(n_rem, w % 256)
		else
			n_rem = bitc.bxor(n_rem, math.floor(w / 256))
		end
		n_rem = n_rem % 65536
		for _ = 1, 8 do
			if bitc.band(n_rem, 0x8000) ~= 0 then
				n_rem = bitc.bxor((n_rem * 2) % 65536, 0x3000)
			else
				n_rem = (n_rem * 2) % 65536
			end
		end
	end
	return math.floor((n_rem % 65536) / 4096) % 16, crc_read
end

-- int64 精确整数参考补偿（d1*sens ~2^56 超 double 2^53 线）
local function fdiv64(a, b)
	local m = a % b
	if m < 0 then m = m + b end
	return (a - m) / b
end
local function ref_comp(d1, d2, C)
	local dt = d2 - C[5] * 256
	local temp = 2000 + tonumber(fdiv64(i64(dt) * i64(C[6]), 8388608))
	local off = C[2] * 65536 + tonumber(fdiv64(i64(C[4]) * i64(dt), 128))
	local sens = C[1] * 32768 + tonumber(fdiv64(i64(C[3]) * i64(dt), 256))
	if temp < 2000 then
		local t2 = tonumber(fdiv64(i64(dt) * i64(dt), 2147483648))
		local off2 = tonumber(fdiv64(i64(5) * i64(temp - 2000) * i64(temp - 2000), 2))
		local sens2 = tonumber(fdiv64(i64(5) * i64(temp - 2000) * i64(temp - 2000), 4))
		if temp < -1500 then
			off2 = off2 + tonumber(i64(7) * i64(temp + 1500) * i64(temp + 1500))
			sens2 = sens2 + tonumber(fdiv64(i64(11) * i64(temp + 1500) * i64(temp + 1500), 2))
		end
		temp = temp - t2
		off = off - off2
		sens = sens - sens2
	end
	local p = tonumber(fdiv64(fdiv64(i64(d1) * i64(sens), 2097152) - i64(off), 32768))
	return temp, p
end

-- 驱动同款一阶（double 拆位），模型 set_pt 逆算闭环用
local function shr(x, k) return math.floor(x / 2 ^ k) end
local function fwd_comp(d1, d2, C)
	local dt = d2 - C[5] * 256
	local temp = 2000 + shr(dt * C[6], 23)
	local off = C[2] * 65536 + shr(C[4] * dt, 7)
	local sens = C[1] * 32768 + shr(C[3] * dt, 8)
	local dh, dl = math.floor(d1 / 4096), d1 % 4096
	local pc = shr(math.floor(dh * sens / 512 + dl * sens / 2097152) - off, 15)
	return pc / 100, temp / 100
end

local COEFF = { 40127, 36924, 23317, 23282, 33464, 31471 }		-- C1~C6
local function be3(t) return t[1] * 65536 + t[2] * 256 + t[3] end

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
local mark = section()

local prom = dev:prom_table()
check("PROM 种子：word0=0x06A4、C1~C6 为真实量级系数",
	prom[1] == 0x06A4 and prom[2] == 40127 and prom[7] == 31471
	and prom[8] % 4096 == 0x321,
	string.format("w0=%04X w7=%04X", prom[1], prom[8]))
local mnib, mstored = test_crc_nib(prom)
local ok_crc, got_crc = smod.crc4_ok(prom)
check("CRC-4：模型实现/测试独立实现/存储位域三方一致（nibble=5）",
	ok_crc and got_crc == mnib and mnib == mstored and mnib == 5,
	string.format("model=%s test=%d stored=%d", tostring(got_crc), mnib, mstored))
check("crc_is_valid 观察口", dev:crc_is_valid())

-- 无前置指针的纯读一律 NACK
check("无指针纯读 2/3/1 字节均 NACK",
	dev.read(2) == nil and dev.read(3) == nil and dev.read(1) == nil)

-- PROM 八字指针读
for i = 0, 7 do
	dev.write({ 0xA0 + 2 * i })
	local w = dev.read(2)
	check("PROM word" .. i .. " 指针 0x" .. string.format("%02X", 0xA0 + 2 * i)
		.. " → 0x" .. string.format("%04X", prom[i + 1]),
		w and #w == 2 and w[1] * 256 + w[2] == prom[i + 1])
end
-- 非 table/非单字节写 NACK
check("非 table 写 NACK", dev.write(0x1E) == false)
check("空帧/2 字节帧 NACK", dev.write({}) == false and dev.write({ 0x1E, 0x00 }) == false)

-- 读后指针失效（每次读必须重发指针）
section()
dev.write({ 0xA2 })
check("首次 PROM 读成功", dev.read(2) ~= nil)
check("指针读后失效（必须重发 0xA2）", dev.read(2) == nil)

-- 长度必须匹配
section()
dev.write({ 0xA0 }); check("PROM 指针读 3B 被拒", dev.read(3) == nil)
dev.write({ 0x00 }); check("ADC 指针读 2B 被拒", dev.read(2) == nil)
dev.write({ 0x00 }); check("ADC 指针读 1B 被拒", dev.read(1) == nil)

-- 转换命令编码：区间 + 仅偶数
section()
local valid_cmds = { 0x40, 0x42, 0x44, 0x46, 0x48, 0x50, 0x52, 0x54, 0x56, 0x58 }
for _, c in ipairs(valid_cmds) do
	check(string.format("转换命令 %02X 识别", c), dev.write({ c }) == true)
end
for _, c in ipairs({ 0x41, 0x49, 0x4A, 0x51, 0x59, 0x5A, 0x1F, 0x3F, 0x60, 0xFF }) do
	check(string.format("保留/越界命令 %02X NACK", c), dev.write({ c }) == false)
end

-- 五档转换门（datasheet 最大时间，驱动等待表留余量）
section(); dev.write({ 0x48 })
check("OSR4096 转换门 9.04ms、pending=d1",
	near(dev:remaining_ms(), 9.04) and dev:pending() == "d1",
	tostring(dev:remaining_ms()))
dev.write({ 0x00 }); check("转换中 ADC 读 NACK", dev.read(3) == nil)
dev:advance(9); dev.write({ 0x00 }); check("advance 9ms 仍未就绪", dev.read(3) == nil)
dev:advance(0.04); dev.write({ 0x00 })
check("9.04ms 到点：D1 种子帧 9085466 = 8AA59A",
	be3(dev.read(3)) == 9085466)

section(); dev.write({ 0x46 })
check("OSR2048 转换门 4.54ms", near(dev:remaining_ms(), 4.54))
dev:advance(4); dev.write({ 0x00 }); check("4ms 未就绪", dev.read(3) == nil)
dev:advance(1); dev.write({ 0x00 }); check("5ms 就绪", dev.read(3) ~= nil)

section(); dev.write({ 0x44 })
check("OSR1024 转换门 2.28ms", near(dev:remaining_ms(), 2.28))
dev:advance(2); dev.write({ 0x00 }); check("2ms 未就绪", dev.read(3) == nil)
dev:advance(1); dev.write({ 0x00 }); check("3ms 就绪", dev.read(3) ~= nil)

section(); dev.write({ 0x42 })
check("OSR512 转换门 1.17ms", near(dev:remaining_ms(), 1.17))
dev:advance(1); dev.write({ 0x00 }); check("1ms 未就绪", dev.read(3) == nil)
dev:advance(1); dev.write({ 0x00 }); check("2ms 就绪", dev.read(3) ~= nil)

section(); dev.write({ 0x40 })
check("OSR256 转换门 0.60ms", near(dev:remaining_ms(), 0.60))
dev:advance(1); dev.write({ 0x00 }); check("1ms 就绪", dev.read(3) ~= nil)

-- 未启动转换 ADC 读 NACK
section()
dev.write({ 0x00 })
check("无转换命令时 ADC 读 NACK", dev.read(3) == nil)

-- D1/D2 码区分 + 结果保持
section()
dev:set_d1(0x123456):set_d2(0x654321)
dev.write({ 0x48 }); dev:advance(10); dev.write({ 0x00 })
check("D1 帧 = 0x123456", be3(dev.read(3)) == 0x123456)
dev.write({ 0x00 })
check("oneshot 结果保持：重写指针可再读 D1", be3(dev.read(3)) == 0x123456)
dev.write({ 0x58 }); dev:advance(10); dev.write({ 0x00 })
check("D2 命令后帧 = 0x654321（最近转换命令选码）", be3(dev.read(3)) == 0x654321)

-- 24 位钳制
section()
dev:set_d1(2 ^ 25); check("D1 超上限钳 0xFFFFFF", dev:d1() == 0xFFFFFF)
dev:set_d2(-9); check("D2 负码钳 0", dev:d2() == 0)

-- PROM 读与转换态无关（转换中也可读）
section(); dev.write({ 0x48 })
dev.write({ 0xAE }); local w7 = dev.read(2)
check("转换中可读 PROM word7", w7 and w7[1] * 256 + w7[2] == prom[8])

-- 复位：清转换态/预武装、PROM reseed
section(); dev.write({ 0x48 }); dev:advance(10)
dev.write({ 0x1E })
check("软复位清 pending/转换/指针", dev:pending() == nil
	and dev:remaining_ms() == nil and dev:read_target() == nil)
dev.write({ 0x00 }); check("复位后无转换 ADC NACK", dev.read(3) == nil)
check("复位后 PROM 仍 CRC 自洽", dev:crc_is_valid())
check("0x1E 入命令序列且含转换命令记录",
	dev:cmd_log()[1] == 0x48 and dev:cmd_log()[2] == 0x1E)

-- set_pt 暖机一阶逆模型闭环（驱动正算复原，量化粒度 <=0.02）
section()
for _, q in ipairs({ { 1013.25, 22 }, { 1008.25, 20 }, { 1018.25, 24 }, { 1000, 21.5 } }) do
	dev:set_pt(q[1], q[2])
	local pp, tt = fwd_comp(dev:d1(), dev:d2(), COEFF)
	check(string.format("set_pt(%.2f hPa,%.1f°C) 逆算闭环", q[1], q[2]),
		near(pp, q[1], 0.02) and near(tt, q[2], 0.02),
		string.format("got %.3f/%.3f", pp, tt))
end

-- armed 预武装：转换命令即时就绪（D1/D2 连转零 advance）
section(); dev:virt_tick(0)
check("virt_tick 置 armed", dev:is_armed())
dev.write({ 0x48 })
check("armed 下 D1 命令即时就绪", dev:remaining_ms() == nil)
dev.write({ 0x00 }); check("armed D1 首读成功", dev.read(3) ~= nil)
dev.write({ 0x58 })
check("armed 下 D2 命令同样即时就绪", dev:remaining_ms() == nil)
dev.write({ 0x00 }); check("armed D2 首读成功", dev.read(3) ~= nil)

-- 故障钩子
section()
dev.nack = true
check("nack：写/读全拒", dev.write({ 0x48 }) == false and dev.read(2) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write：只拒写", dev.write({ 0x48 }) == false and dev.read(2) == nil)
dev.nack_write = false
dev.nack_read = true
dev.write({ 0xA0 }); check("nack_read：只读被拒", dev.read(2) == nil)
dev.nack_read = false

section()
dev:fail_cmd(function(b) return b == 0x1E end)
check("fail_cmd 按 0x1E 过滤", dev.write({ 0x1E }) == false)
check("fail_cmd 不影响 0x48", dev.write({ 0x48 }) == true)
dev:fail_cmd(nil)
dev:fail_read(function(t) return t == "prom" end)
dev.write({ 0xA0 }); check("fail_read 只断 PROM 读", dev.read(2) == nil)
dev:advance(10); dev.write({ 0x00 }); check("ADC 读不受影响", dev.read(3) ~= nil)
dev:fail_read(nil)

section()
dev:corrupt_prom(true)
check("corrupt_prom 不改变系数观察口（钩子只作用于读帧）", dev:crc_is_valid())
dev.write({ 0xAE })
local bad = dev.read(2)
local badw = bad[1] * 256 + bad[2]
check("word7 读帧 CRC 位域 +1、序列号低 12 位保留",
	math.floor(badw / 4096) % 16 == (math.floor(prom[8] / 4096) % 16 + 1) % 16
	and badw % 4096 == 0x321,
	string.format("%04X", badw))
check("篡改帧过不了测试侧独立 CRC", test_crc_nib(dev:prom_table())
	~= math.floor(badw / 4096) % 16)
dev:corrupt_prom(false)

section()
dev:corrupt_prom(true)
dev:reset()
check("reset 保留故障钩子", dev:crc_is_valid())
dev.write({ 0xAE })
local bad2 = dev.read(2)
check("reset 后 word7 读帧仍是坏 CRC（序列号位保留）",
	math.floor((bad2[1] * 256 + bad2[2]) / 4096) % 16
	== (math.floor(prom[8] / 4096) % 16 + 1) % 16)
dev:clear_faults()
dev:reset()
dev.write({ 0xAE }); local good = dev.read(2)
check("clear_faults 后 word7 读帧恢复", good[1] * 256 + good[2] == dev:prom_table()[8])

section()
dev.write({ 0x48 })
dev:reset_logs()
check("reset_logs 清空命令序列", dev:cmd_count() == 0)

-- virt_tick 节拍：P/T 同向正弦，n0=中、n8=峰、n24=谷
section()
local function tick(n)
	dev:virt_tick(n)
	return dev:d1(), dev:d2()
end
local d1a, d2a = tick(0)
local d1b, d2b = tick(8)
local d1c, d2c = tick(24)
check("virt_tick D1：n8 峰 > n0 > n24 谷", d1b > d1a and d1a > d1c,
	string.format("%d/%d/%d", d1a, d1b, d1c))
check("virt_tick D2：n8 峰 > n0 > n24 谷", d2b > d2a and d2a > d2c,
	string.format("%d/%d/%d", d2a, d2b, d2c))
local pp0, tt0 = fwd_comp(d1a, d2a, COEFF)
local pp8, tt8 = fwd_comp(d1b, d2b, COEFF)
check("virt_tick 物理量：n0≈1013.25hPa/22°C、n8≈1018.25/24",
	near(pp0, 1013.25, 0.02) and near(tt0, 22, 0.02)
	and near(pp8, 1018.25, 0.02) and near(tt8, 24, 0.02),
	string.format("n0 %.2f/%.2f n8 %.2f/%.2f", pp0, tt0, pp8, tt8))

-- ======================================================================
-- 组 2：真实 build（经虚拟总线）
-- ======================================================================
mark = section()
local r = expect_ok("build 默认（OSR4096/p0 缺省）", function()
	return build({ fd = fd, address = "0x77" })
end)
if r then
	local ws, rs, ss = writes(mark), reads(mark), set_addrs(mark)
	check("set_addr 恰 1 次=0x77", #ss == 1 and ss[1] == ADDR,
		string.format("%d 次", #ss))
	check("写序列：1E + A0,A2,...,AE 共 9 笔单字节",
		#ws == 9 and ws[1] == 0x1E and ws[2] == 0xA0 and ws[9] == 0xAE
		and ws[8] == 0xAC, table.concat(ws, ","))
	check("八字 PROM 各一次 2B 读", #rs == 8)
	for _, n in ipairs(rs) do check("PROM 读长度均 2", n == 2) end
	check("build 含复位重载真实睡眠 3ms（桩转 advance）", sleep_total == 3,
		tostring(sleep_total))
end

mark = section()
expect_ok("build 字符串 fd='3'", function()
	return build({ fd = "3", address = "0x77" })
end)
check("字符串 fd/address 同样 set_addr 0x77",
	set_addrs(mark)[1] == 0x77 and #writes(mark) == 9)

mark = section()
expect_ok("build osr='300' 向下降档到 256（build 无转换事务）", function()
	return build({ fd = fd, address = "0x77", osr = "300" })
end)
check("降档不改变 build 序列（仍 1E+8 指针）",
	#writes(mark) == 9 and #reads(mark) == 8)

section()
expect_ok("build osr='-' p0='1000'", function()
	return build({ fd = fd, address = "0x77", osr = "-", p0 = "1000" })
end)

-- build 负路径
section()
expect_err("build 非 table", function() return build(nil) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x77" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")

-- OSR 非法值显式报错（旧实现静默回落 #OSR_TAB = 4096 最慢档，与「向下降档」注释相反）
mark = section()
expect_err("build osr='100' 低于最小档显式报错", function()
	return build({ fd = fd, address = "0x77", osr = "100" })
end, "Invalid Argument: osr=100 is below the lowest ratio")
check("非法 OSR 不触总线（无写事务）",
	#writes(mark) == 0)

mark = section()
expect_err("build osr='10O' 非数字显式报错", function()
	return build({ fd = fd, address = "0x77", osr = "10O" })
end, "osr is not a number: '10O'")
check("非数字 OSR 不触总线", #writes(mark) == 0)

section()
expect_err("build osr='0' 显式报错（不再静默归缺省）", function()
	return build({ fd = fd, address = "0x77", osr = "0" })
end, "is below the lowest ratio")

mark = section()
expect_err("build fd=99 未打开 → set_addr failed",
	function() return build({ fd = 99, address = "0x77" }) end, "set_addr failed")
check("set_addr 失败零总线事务", #writes(mark) == 0 and #reads(mark) == 0)

section()
dev:fail_cmd(function(b) return b == 0x1E end)
expect_err("build 复位写失败",
	function() return build({ fd = fd, address = "0x77" }) end, "Failed to reset MS5611")
dev:fail_cmd(nil)

section()
dev:fail_read(function(t) return t == "prom" end)
expect_err("build PROM 读失败",
	function() return build({ fd = fd, address = "0x77" }) end, "Failed to read MS5611 PROM")
dev:fail_read(nil)

mark = section()
dev:fail_cmd(function(b) return b == 0xA0 end)
expect_err("build PROM 指针写失败（read_multi 整笔失败）",
	function() return build({ fd = fd, address = "0x77" }) end, "Failed to read MS5611 PROM")
check("指针写失败后无读事务", #reads(mark) == 0)
dev:fail_cmd(nil)

section()
dev:corrupt_prom(true)
expect_err("build PROM CRC 不符（兼在位甄别）",
	function() return build({ fd = fd, address = "0x77" }) end, "PROM CRC mismatch")
dev:corrupt_prom(false)

-- ======================================================================
-- 组 3：真实 call（经虚拟总线，ffi int64 参考三分支补偿交叉）
-- ======================================================================
section()
expect_ok("call 前置 build OSR4096", function()
	return build({ fd = fd, address = "0x77" })
end)
mark = #vbus.txlog
sleep_total = 0
local res = expect_ok("call 暖机解算（一阶；d1*sens 超 2^53 拆位）", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	local exp_t, exp_p = ref_comp(9085466, 8569156, COEFF)
	check("T_C 与 int64 参考一致", near(res.T_C, exp_t / 100, 1e-12),
		string.format("%s vs %s", tostring(res.T_C), tostring(exp_t / 100)))
	check("P_HPA 与 int64 参考一致", near(res.P_HPA, exp_p / 100, 1e-12),
		string.format("%s vs %s", tostring(res.P_HPA), tostring(exp_p / 100)))
	check("气压落合理区间 990~1030hPa", res.P_HPA > 990 and res.P_HPA < 1030,
		tostring(res.P_HPA))
	check("ALT_M 量级合理（±500m）", res.ALT_M > -500 and res.ALT_M < 500,
		tostring(res.ALT_M))
	check("ALT_M 与压高公式一致（p0=1013.25）",
		near(res.ALT_M, 44330 * (1 - (res.P_HPA / 1013.25) ^ 0.1902949), 1e-6))
	local ws, rs = writes(mark), reads(mark)
	check("call 写序列 48,00,58,00（双段转换+双指针）",
		#ws == 4 and ws[1] == 0x48 and ws[2] == 0x00
		and ws[3] == 0x58 and ws[4] == 0x00, table.concat(ws, ","))
	check("call 两次 3B ADC 读", #rs == 2 and rs[1] == 3 and rs[2] == 3,
		table.concat(rs, ","))
	check("两段转换各睡 10ms（共 20，桩转 advance）", sleep_total == 20,
		tostring(sleep_total))
end

-- 低温二阶
section()
expect_ok("rebuild OSR4096（低温用）", function()
	return build({ fd = fd, address = "0x77" })
end)
mark = #vbus.txlog
dev:set_d2(8000000)
local et, ep = ref_comp(9085466, 8000000, COEFF)
check("参考 TEMP 落普通低温段 [-1500,2000)", et < 2000 and et >= -1500, tostring(et))
res = expect_ok("call 低温二阶补偿", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("低温 T_C 对照", near(res.T_C, et / 100, 1e-12),
		string.format("%s vs %s", tostring(res.T_C), tostring(et / 100)))
	check("低温 P_HPA 对照", near(res.P_HPA, ep / 100, 1e-12),
		string.format("%s vs %s", tostring(res.P_HPA), tostring(ep / 100)))
end

-- 极低温追加项
section()
expect_ok("rebuild OSR4096（极低温用）", function()
	return build({ fd = fd, address = "0x77" })
end)
mark = #vbus.txlog
dev:set_d2(7616784)
et, ep = ref_comp(9085466, 7616784, COEFF)
check("参考 TEMP 落极低温段 (<-1500)", et < -1500, tostring(et))
res = expect_ok("call 极低温追加项补偿", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("极低温 T_C 对照", near(res.T_C, et / 100, 1e-12), tostring(res.T_C))
	check("极低温 P_HPA 对照", near(res.P_HPA, ep / 100, 1e-12), tostring(res.P_HPA))
end

-- OSR 降档
section()
expect_ok("rebuild osr='300'（降 256）", function()
	return build({ fd = fd, address = "0x77", osr = "300" })
end)
mark = #vbus.txlog
sleep_total = 0
res = expect_ok("call OSR256 双段转换", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	local ws = writes(mark)
	check("OSR256 命令 0x40/0x50 + 双 0x00 指针",
		#ws == 4 and ws[1] == 0x40 and ws[3] == 0x50, table.concat(ws, ","))
	check("两段等待各 1ms（共 2）", sleep_total == 2, tostring(sleep_total))
end

-- 自定义 p0
section()
expect_ok("rebuild p0='1000'", function()
	return build({ fd = fd, address = "0x77", p0 = "1000" })
end)
mark = #vbus.txlog
res = expect_ok("call 自定义 p0=1000", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("ALT_M 按 p0=1000 换算",
		near(res.ALT_M, 44330 * (1 - (res.P_HPA / 1000) ^ 0.1902949), 1e-6),
		tostring(res.ALT_M))
end

-- p0 非有限（26.3）：驱动该处注释写的契约是「非法/非正归缺省」，但 tonumber
-- 放行 'nan'（出的是 number，Lua 里 truthy），`p0 == nil` 与 `p0 <= 0` 对 NaN
-- 均为假，于是 NaN 被存进**模块级** p0_hpa；此后每一次 call 的
-- ALT_M = 44330*(1-(P_HPA/NaN)^0.19) 都是 NaN，却仍报 result="OK"——即
-- MT6826S 的 ANGLE 那类「一次污染、永久输出」形态，且 NaN 进 JSON 变 null，
-- 下游 sensor_daemon 的 fields=ALT_M 消费者拿到的是空值而非报错。
section()
expect_ok("rebuild p0='nan'（归缺省，不得污染模块级 p0_hpa）", function()
	return build({ fd = fd, address = "0x77", p0 = "nan" })
end)
res = expect_ok("call p0='nan' 后仍出有限海拔", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("p0=nan 回落缺省 1013.25（ALT_M 与压高公式一致，非 NaN）",
		near(res.ALT_M, 44330 * (1 - (res.P_HPA / 1013.25) ^ 0.1902949), 1e-6),
		tostring(res.ALT_M))
end
section()
expect_ok("rebuild p0='1e400'（inf 同样归缺省）", function()
	return build({ fd = fd, address = "0x77", p0 = "1e400" })
end)
res = expect_ok("call p0=inf 后仍出有限海拔", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("p0=inf 回落缺省（ALT_M 不是 inf；旧行为为 44330 定值）",
		near(res.ALT_M, 44330 * (1 - (res.P_HPA / 1013.25) ^ 0.1902949), 1e-6),
		tostring(res.ALT_M))
end

-- virt_tick 守护式两拍：armed 零等待
section()
expect_ok("rebuild OSR4096（守护场景）", function()
	return build({ fd = fd, address = "0x77" })
end)
mark = #vbus.txlog
dev:virt_tick(8)		-- 峰 1018.25hPa/24°C
sleep_total = 0
res = expect_ok("call virt_tick 峰：武装可读", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	-- 桩 milli_sleep 照走（驱动固定节拍 10ms×2）；armed 的价值是无 advance
	-- 的真实守护环境下转换门不再门控，已在组 1 直连模型验证
	check("P≈1018.25、T≈24、驱动节拍 20ms、4 写 2 读",
		near(res.P_HPA, 1018.25, 0.02) and near(res.T_C, 24, 0.02)
		and sleep_total == 20 and #writes(mark) == 4 and #reads(mark) == 2,
		string.format("P=%s T=%s sleep=%s", tostring(res.P_HPA),
			tostring(res.T_C), tostring(sleep_total)))
end
dev:virt_tick(24)	-- 谷 1008.25hPa/20°C
sleep_total = 0
res = expect_ok("call virt_tick 谷：武装可读", function()
	return call({ fd = fd, address = "0x77" })
end)
if res then
	check("P≈1008.25、T≈20、驱动节拍 20ms",
		near(res.P_HPA, 1008.25, 0.02) and near(res.T_C, 20, 0.02)
		and sleep_total == 20,
		string.format("P=%s T=%s", tostring(res.P_HPA), tostring(res.T_C)))
end

-- call 负路径
section()
expect_ok("rebuild OSR4096（负路径用）", function()
	return build({ fd = fd, address = "0x77" })
end)
expect_err("call 非 table", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
expect_err("call fd=99 set_addr failed",
	function() return call({ fd = 99, address = "0x77" }) end, "set_addr failed")

section()
expect_ok("rebuild OSR4096（D1 启动失败用）", function()
	return build({ fd = fd, address = "0x77" })
end)
dev:fail_cmd(function(b) return b == 0x48 end)
expect_err("call D1 转换启动失败",
	function() return call({ fd = fd, address = "0x77" }) end, "D1 conversion")
dev:fail_cmd(nil)

section()
expect_ok("rebuild OSR4096（D1 读失败用）", function()
	return build({ fd = fd, address = "0x77" })
end)
dev:fail_read(function(t) return t == "adc" end)
expect_err("call D1 ADC 读失败",
	function() return call({ fd = fd, address = "0x77" }) end, "Failed to read MS5611 D1")
dev:fail_read(nil)

section()
expect_ok("rebuild OSR4096（D2 启动失败用）", function()
	return build({ fd = fd, address = "0x77" })
end)
mark = #vbus.txlog
dev:fail_cmd(function(b) return b == 0x58 end)
expect_err("call D2 转换启动失败（D1 已完成）",
	function() return call({ fd = fd, address = "0x77" }) end, "Failed to start MS5611 D2")
dev:fail_cmd(nil)
local ws_d2 = writes(mark)
check("失败前已完成 D1 段（48,00 + 3B 读）",
	ws_d2[1] == 0x48 and ws_d2[2] == 0x00 and reads(mark)[1] == 3,
	table.concat(ws_d2, ","))

section()
expect_ok("rebuild OSR4096（D2 读失败用）", function()
	return build({ fd = fd, address = "0x77" })
end)
dev:fail_read(function(t)
	return t == "adc" and dev:pending() == "d2"
end)
expect_err("call D2 ADC 读失败（D1 段成功）",
	function() return call({ fd = fd, address = "0x77" }) end, "Failed to read MS5611 D2")
dev:fail_read(nil)

-- ======================================================================
-- 组 4：destroy（无总线资源，零事务）
-- ======================================================================
section()
expect_ok("rebuild 后 destroy", function()
	return build({ fd = fd, address = "0x77" })
end)
local dm = #vbus.txlog
expect_ok("destroy 无资源需释放", function()
	return destroy({ fd = fd, address = "0x77" })
end)
local any_bus = false
for _, e in ipairs(entries(dm)) do
	if e.dir ~= "set" then any_bus = true end
end
check("destroy 零 w/r 事务", not any_bus)
expect_err("destroy 非 table", function() return destroy(nil) end, "Invalid Arguments Type")

-- ======================================================================
tester.summary()

-- test_bmi270.lua —— BMI270 真实驱动 + 虚拟 I2C 总线 + blob 上传/六轴模型
-- 用法（项目根目录）: luajit test/test_bmi270.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：BMI270_GC=1 luajit test/test_bmi270.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 271 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/BMI270.lua 尾部 BMI270_VIRT，
-- 2026-09-15 自 virtbus/bmi270.lua 迁入）」。三份独立实现交叉：模型只存
-- 协议字节/原始码（不含 blob 内容与 g/dps 换算），本测试从
-- modules/lib/bmi270_config.lua 独立解码 fifo/full 两个官方 blob 逐字节
-- 比对，并独立重写字地址编码公式。
--
-- 旧桩互证假绿已戳破（datasheet BST-BMI270-DS000-08 + bmi2.c v2.86.1）：
--   1) ACC_CONF POR 旧桩 0x33（「odr=6Hz 假设值」）/GYR_CONF 0x21/
--      PWR_CONF 未播——实证 0xA8/0xA9/0x03；
--   2) 旧桩断言 build 后 0x40==0x38，真实 RMW 保高 4 位得 0xA8；
--   3) 旧桩未模拟 INIT_DATA(0x5E) 地址陷阱（burst 不自增、整帧进配置
--      窗口），且无加载门/NACK 钩子/virt_tick。
--
-- 覆盖七组：
--   1) 模型事实：POR 关键寄存器/指针自增回绕/写掩码/只读区丢弃/坏帧；
--      blob 缓冲 fifo 41 块/full 1024 块逐字节、字地址独立编码、
--      INIT_DATA 陷阱不自增到 0x5F、INIT_CTRL=0 清空；加载门 149/150ms
--      边界、长度不符 0x02、stuck/never_ready、who 跨软复位、六钩子、
--      物理量反算、virt_tick 码钉
--   2) 真实 build fifo：92 帧序列（复位+2 电源+INIT_CTRL+41 对块+
--      启动+4 配置+上电）、19 指针读、睡眠 2+1+1+150+100=254ms、
--      落盘 0xA8/0xA8/02/02/06、横幅；预武装路径 114ms/1 轮询
--   3) build full（2058 帧/8192B）与取档（range/gyro snap_down、
--      odr snap_near、'-' 与非法值归缺省）
--   4) build 负路径：0x26 变体/ID 读失败/stuck 0x02 与 never_ready
--      各 50 轮询 500ms/逐帧 fail_write 短路点/缺 fd/set_addr/错地址
--   5) 真实 call：0x0C 单指针读 12B（acc+gyr 并读防撕裂，C-L1）、
--      小端拼字 0x1000/0xFFFF/0xFC00、tick 闭环、零睡眠、二次 call
--   6) call 负路径：传感器读失败（单事务）、非表/缺 fd/错地址
--   7) destroy：零事务、非表 ERR

if os.getenv("BMI270_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x68

-- 模型内嵌于驱动文件（BMI270_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/BMI270.lua")
local mm = BMI270_VIRT

local dev = mm.new()
local mm = BMI270_VIRT

local dev = mm.new()
vbus.attach("BMI270@0x68", ADDR, dev)

-- ==================== 独立参考：官方 blob 解码 ====================
local CONFIG = dofile("modules/lib/bmi270_config.lua")
local function hex2bin(h)
	return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end
local FIFO_BIN = hex2bin(CONFIG.FIFO_HEX)
local FULL_BIN = hex2bin(CONFIG.FULL_HEX)

-- 字地址独立编码公式（bmi2.c upload_file）：word=字节序号/2，
-- 低 nibble 进 0x5B、高 8 位进 0x5C
local function word_enc(byte_index_1)
	local word = math.floor((byte_index_1 - 1) / 2)
	return word % 16, math.floor(word / 16)
end

-- milli_sleep：累计时长/清单 + 推进加载门虚拟时钟（驱动解析全局名）
local sleep_total = 0
local sleeps = {}
function milli_sleep(ms)
	sleep_total = sleep_total + ms
	sleeps[#sleeps + 1] = ms
	dev:advance(ms)
end

local fd = i2c_open("/dev/i2c-1")
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 每个 section：器件复位 + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	sleeps = {}
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
local function hx(v) return string.format("%02X", v or 0) end
local function u16(v) return v < 0 and v + 65536 or v end

-- 直连模型上传一个 blob（不走总线），返回 41/1024 块的帧序列引用
local function upload_via_model(blob)
	dev.write({ 0x59, 0x00 })
	for i = 1, #blob, 8 do
		local lo, hi = word_enc(i)
		dev.write({ 0x5B, lo, hi })
		local f = { 0x5E }
		for k = 0, 7 do f[#f + 1] = blob:byte(i + k) end
		dev.write(f)
	end
end

local function blob_matches(blob)
	local up = dev:uploaded()
	if #up ~= #blob then return false, #up .. "/" .. #blob end
	for k = 1, #blob do
		if up[k] ~= blob:byte(k) then return false, "byte " .. k end
	end
	return true
end

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
section()

-- POR（datasheet register overview RESET 列）
check("POR CHIP_ID=0x24", byte(0x00) == 0x24)
check("POR INTERNAL_STATUS=0x00", byte(0x21) == 0x00)
check("POR ACC_CONF=0xA8 / ACC_RANGE=0x02", byte(0x40) == 0xA8 and byte(0x41) == 0x02)
check("POR GYR_CONF=0xA9 / GYR_RANGE=0x00", byte(0x42) == 0xA9 and byte(0x43) == 0x00)
check("POR PWR_CONF=0x03 / PWR_CTRL=0x00", byte(0x7C) == 0x03 and byte(0x7D) == 0x00)
check("POR CMD(0x7E) 只写读恒 0", byte(0x7E) == 0x00)
do
	local allzero = true
	for a = 0x0C, 0x17 do if byte(a) ~= 0 then allzero = false end end
	check("POR 六轴测量区 0x0C..0x17 全 0", allzero)
end
check("POR 未定义地址 0x60 读 0", byte(0x60) == 0)
dev.write({ 0x60, 0x12 })
check("未定义地址写 ACK 落盘回读 0x12", byte(0x60) == 0x12)

-- 指针自增 + 模 256 回绕（0xFD→FE→FF→00(CHIP_ID 0x24)）
do
	local t = rd(0xFD, 4)
	check("burst 指针自增并模 256 回绕进 CHIP_ID",
		t[1] == 0 and t[2] == 0 and t[3] == 0 and t[4] == 0x24,
		table.concat({ t[1], t[2], t[3], t[4] }, ","))
end

-- 写掩码
dev.write({ 0x40, 0xFF }); check("ACC_CONF 全 8 位有效 → FF", byte(0x40) == 0xFF)
dev.write({ 0x41, 0xFF }); check("ACC_RANGE 掩码 0x03", byte(0x41) == 0x03)
dev.write({ 0x42, 0xFF }); check("GYR_CONF 全 8 位有效 → FF", byte(0x42) == 0xFF)
dev.write({ 0x43, 0xFF }); check("GYR_RANGE 掩码 0x0F（bit3 ois 合法）", byte(0x43) == 0x0F)
dev.write({ 0x7C, 0xFF }); check("PWR_CONF 掩码 0x07", byte(0x7C) == 0x07)
dev.write({ 0x7D, 0xFF }); check("PWR_CTRL 掩码 0x0F", byte(0x7D) == 0x0F)
dev.write({ 0x5B, 0xFF, 0xFF })
check("INIT_ADDR 0 低 4 位 0x0F / 1 全 8 位 FF / 合成字地址 4095",
	byte(0x5B) == 0x0F and byte(0x5C) == 0xFF and dev:word_addr() == 4095)

-- 只读区写 ACK 丢弃
dev.write({ 0x00, 0x99 }); check("CHIP_ID 只读写丢弃", byte(0x00) == 0x24)
dev:virt_tick(0)
local ax0 = select(1, dev:accel_raw())
dev.write({ 0x0C, 0x55, 0xAA }); check("测量区只读写丢弃", byte(0x0C) == ax0 % 256)
dev.write({ 0x21, 0x07 }); check("INTERNAL_STATUS 只读写丢弃", byte(0x21) == 0x00)
dev.write({ 0x7E, 0xB0 }); check("CMD 不落盘（fifo_flush 读仍 0）", byte(0x7E) == 0x00)

-- 坏帧整笔 NACK
section()
check("空表写 NACK", dev.write({}) == false)
check("非表写 NACK", dev.write(nil) == false and dev.write(0x59) == false and dev.write("x") == false)
check("非字节写 NACK", dev.write({ 0x59, 256 }) == false and dev.write({ 0x59, "1" }) == false)
dev.write({ 0x00 })
check("读 n 钳 1~16", #dev.read(0) == 1 and #dev.read(20) == 16)
check("无指针纯读 NACK", dev:reset() and dev.read(2) == nil)

-- ---- blob 缓冲：fifo 41 块逐字节 + 字地址独立编码 ----
section()
upload_via_model(FIFO_BIN)
check("fifo 上传 328 字节", dev:blob_len() == 328, tostring(dev:blob_len()))
check("fifo blob 逐字节 = 独立解码 FIFO_BIN", blob_matches(FIFO_BIN))
check("fifo 末字地址 164（41×4）", dev:word_addr() == 164, tostring(dev:word_addr()))
do
	local fs = dev:frames()
	-- 帧序：{59,00} + 41×({5B,lo,hi},{5E,8B})
	local ok = #fs == 83 and fs[1][1] == 0x59 and fs[1][2] == 0x00
	if ok then
		for k = 1, 41 do
			local af, df = fs[2 + (k - 1) * 2], fs[3 + (k - 1) * 2]
			local lo, hi = word_enc((k - 1) * 8 + 1)
			if not (af[1] == 0x5B and af[2] == lo and af[3] == hi and #af == 3) then
				ok = false
			end
			if not (df[1] == 0x5E and #df == 9) then ok = false end
			for j = 1, 8 do
				if df[j + 1] ~= FIFO_BIN:byte((k - 1) * 8 + j) then ok = false end
			end
		end
	end
	check("41 块帧序/字地址独立公式/数据窗 9 字节帧全对", ok, "frames=" .. #fs)
end

-- ---- INIT_DATA 地址陷阱：不普通自增、不进影子、不动读指针 ----
section()
dev.write({ 0x5B, 0x03, 0x00 })		-- 字地址 3（字节 6 起）
dev.write({ 0x33 })					-- 读指针放别处
dev.write({ 0x5E, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 })
check("陷阱帧 8 字节按字地址进窗口",
	dev:uploaded(8)[7] == 0xAA and dev:uploaded(8)[8] == 0xBB, tostring(dev:blob_len()))
check("陷阱不动读指针（仍 0x33）", dev:pointer() == 0x33, tostring(dev:pointer()))
check("0x5E/0x5F 不进寄存器影子", dev:reg(0x5E) == nil and dev:reg(0x5F) == nil)
check("陷阱帧计 blob_len=8", dev:blob_len() == 8, tostring(dev:blob_len()))
check("字地址按 8/2=4 推进到 7", dev:word_addr() == 7, tostring(dev:word_addr()))

-- ---- INIT_CTRL=0 清空缓冲与加载态 ----
section()
upload_via_model(FIFO_BIN)
dev.write({ 0x59, 0x01 })
check("加载启动后 init_ok（门尚未推进读 not_init）", byte(0x21) == 0x00)
dev:advance(150)
check("150ms 门到点 init_ok", dev:phase() == "ok" and byte(0x21) == 0x01)
dev.write({ 0x59, 0x00 })
check("INIT_CTRL=0 清空 blob/回 idle",
	dev:blob_len() == 0 and dev:phase() == "idle" and byte(0x21) == 0x00)

-- ---- 加载门边界 + 长度不符 ----
section()
upload_via_model(FIFO_BIN)
dev.write({ 0x59, 0x01 })
check("启动即 loading/not_init", dev:phase() == "loading" and byte(0x21) == 0x00)
dev:advance(149)
check("149ms 仍忙", dev:phase() == "loading" and byte(0x21) == 0x00)
dev:advance(1)
check("150ms 到点 init_ok（读惰性到点同样成立）", dev:phase() == "ok" and byte(0x21) == 0x01)
section()
dev.write({ 0x59, 0x00 })
dev.write({ 0x5E, 1, 2, 3, 4, 5, 6, 7, 8 })
dev.write({ 0x59, 0x01 })
check("长度 8 启动即 init_err(0x02)", dev:phase() == "error" and byte(0x21) == 0x02)
dev.write({ 0x59, 0x00 })
check("错误态可被 INIT_CTRL=0 清除", dev:phase() == "idle" and byte(0x21) == 0x00)

-- ---- full blob 8192 字节 / 1024 块 ----
section()
upload_via_model(FULL_BIN)
check("full 上传 8192 字节 / 末字地址 4096",
	dev:blob_len() == 8192 and dev:word_addr() == 4096,
	dev:blob_len() .. "/" .. dev:word_addr())
local okfull, whyfull = blob_matches(FULL_BIN)
check("full blob 逐字节 = 独立解码 FULL_BIN", okfull, whyfull or "")
dev:virt_tick(0)
dev.write({ 0x59, 0x01 })
check("预武装 full 启动即 init_ok", byte(0x21) == 0x01 and dev:phase() == "ok")

-- ---- stuck / never_ready / who / 软复位 ----
section()
upload_via_model(FIFO_BIN)
dev:set_stuck_status(0x05)
dev.write({ 0x59, 0x01 })
check("stuck 状态码优先级最高（nvm_error 0x05）", byte(0x21) == 0x05)
dev:set_stuck_status(nil)
dev:advance(150)
check("stuck 解除后门照常到点", byte(0x21) == 0x01)
section()
upload_via_model(FIFO_BIN)
dev:set_never_ready(true)
dev.write({ 0x59, 0x01 })
dev:advance(100000)
check("never_ready 门永不到点", dev:phase() == "loading" and byte(0x21) == 0x00)

section()
dev:who(0x26)
check("who 覆写 CHIP_ID=0x26", byte(0x00) == 0x26)
dev:virt_tick(0)
dev:set_accel_raw(123, 456, 789)
dev.write({ 0x7E, 0xB6 })
check("软复位 reset_count=1", dev:reset_count() == 1)
check("软复位不清 who 覆写（误挂甄别有效）", byte(0x00) == 0x26)
check("软复位保留注入码", (select(1, dev:accel_raw())) == 123)
check("软复位保留预武装", dev:is_prearmed() == true)
check("软复位清 blob 缓冲", dev:blob_len() == 0 and dev:phase() == "idle")
dev:reset()
check("上电 reset 身份回 0x24 / 预武装解除",
	byte(0x00) == 0x24 and dev:is_prearmed() == false)

-- ---- 故障钩子六类 ----
section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0x40 end)
check("fail_write 谓词只断 ACC_CONF",
	dev.write({ 0x40, 0xA8 }) == false and dev.write({ 0x42, 0xA8 }) == true)
dev:clear_faults()
dev:fail_read(function(p) return p == 0x00 end)
check("fail_read 谓词只断 CHIP_ID", rd(0x00, 1) == nil and byte(0x40) == 0xA8)
dev:clear_faults()
dev.nack_write = true
check("nack_write 全写断", dev.write({ 0x40, 0x00 }) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 全读断", dev.read(1) == nil)
dev.nack_read = false
dev.write({ 0x40 })
dev.nack = true
check("nack 全断（含指针写/读）", dev.write({ 0x40 }) == false and dev.read(1) == nil)
dev.nack = false
check("reset 保留故障钩子（防负路径假解除）", (function()
	dev:fail_write(function(fr) return fr[1] == 0x7E end)
	dev:reset()
	return dev.write({ 0x7E, 0xB6 }) == false
end)())
dev:clear_faults()

-- ---- 物理量逆注入 ----
section()
dev.write({ 0x41, 0x00 })		-- ±2g：16384 LSB/g
dev:set_accel_g(1, -1, 0)
check("±2g 档 1g/-1g → ±16384",
	(select(1, dev:accel_raw())) == 16384 and (select(2, dev:accel_raw())) == -16384)
dev.write({ 0x41, 0x03 })		-- ±16g：2048 LSB/g
dev:set_accel_g(1, 0, 0)
check("±16g 档 1g → 2048", (select(1, dev:accel_raw())) == 2048)
dev.write({ 0x43, 0x04 })		-- ±125dps：262.144 LSB/dps
dev:set_gyro_dps(10, 0, 0)
check("±125dps 档 10dps → 2621（量化 ±1）",
	math.abs((select(1, dev:gyro_raw())) - 2621) <= 1, tostring(select(1, dev:gyro_raw())))
dev.write({ 0x43, 0x00 })		-- ±2000dps：16.384 LSB/dps
dev:set_gyro_dps(100, 0, 0)
check("±2000dps 档 100dps → 1638（量化 ±1）",
	math.abs((select(1, dev:gyro_raw())) - 1638) <= 1)

-- ---- virt_tick 码钉（32 拍确定性正弦） ----
section()
dev:virt_tick(0)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(0) acc 300/-200/4096 gyr 0/0/0",
		x == 300 and y == -200 and z == 4096 and rx == 0 and ry == 0 and rz == 0,
		table.concat({ x, y, z, rx, ry, rz }, ","))
end
do
	local a6 = rd(0x0C, 6)
	check("tick(0) 小端总线字节（300=2C,01 / -200=38,FF / 4096=00,10）",
		a6[1] == 0x2C and a6[2] == 0x01 and a6[3] == 0x38 and a6[4] == 0xFF
		and a6[5] == 0x00 and a6[6] == 0x10)
end
dev:virt_tick(8)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(8) 峰点 acc 500/-350/4196 gyr 500/-400/300",
		x == 500 and y == -350 and z == 4196 and rx == 500 and ry == -400 and rz == 300,
		table.concat({ x, y, z, rx, ry, rz }, ","))
end
dev:virt_tick(24)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(24) 谷点 acc 100/-50/3996 gyr -500/400/-300",
		x == 100 and y == -50 and z == 3996 and rx == -500 and ry == 400 and rz == -300)
end
do
	local d2 = mm.new()
	d2:virt_tick(0)
	check("tick 确定性（两实例 n0 相同）", (select(1, d2:accel_raw())) == 300)
end
check("tick 即预武装", dev:is_prearmed() == true)
dev:reset()
check("reset 清注入码与预武装",
	(select(1, dev:accel_raw())) == 0 and dev:is_prearmed() == false)

-- ======================================================================
-- 组 2：真实 build（fifo 缺省，非预武装走满 150ms 门）
-- ======================================================================
local mark = section()
local cap
local oldprint = print
print = function(s) if type(s) == "string" and s:find("BMI270 init OK", 1, true) then cap = s end end
local r = expect_ok("build 默认 fifo（±8g/±500dps/100Hz）",
	function() return build({ fd = fd, address = "0x68" }) end)
print = oldprint
if r then
	check("build set_addr 留痕 0x68 一次",
		#set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x68)
	-- 睡眠：2(复位)+1+1(电源)+15×10(门)+100(陀螺启动)=254ms
	check("build 睡眠 2+1+1+150+100=254ms", sleep_total == 254, tostring(sleep_total))
	check("睡眠序列首 2ms/末 100ms/共 19 拍",
		sleeps[1] == 2 and sleeps[#sleeps] == 100 and #sleeps == 19,
		#sleeps .. " first=" .. tostring(sleeps[1]))
	local fs = dev:frames()
	check("build 恰好 92 笔数据写", #fs == 92, tostring(#fs))
	check("前四帧 7EB6/7C-00/7D-00/59-00",
		fs[1][1] == 0x7E and fs[1][2] == 0xB6
		and fs[2][1] == 0x7C and fs[2][2] == 0x00
		and fs[3][1] == 0x7D and fs[3][2] == 0x00
		and fs[4][1] == 0x59 and fs[4][2] == 0x00)
	-- 41 对块：fs[5..86]
	local bok = true
	for k = 1, 41 do
		local af, df = fs[4 + (k - 1) * 2 + 1], fs[4 + (k - 1) * 2 + 2]
		local lo, hi = word_enc((k - 1) * 8 + 1)
		if not (af[1] == 0x5B and af[2] == lo and af[3] == hi and #af == 3
			and df[1] == 0x5E and #df == 9) then bok = false end
		for j = 1, 8 do
			if df[j + 1] ~= FIFO_BIN:byte((k - 1) * 8 + j) then bok = false end
		end
	end
	check("build 41 块字地址+窗口数据全对", bok)
	check("收尾六帧 59-01/40-A8/42-A8/41-02/43-02/7D-06",
		fs[87][1] == 0x59 and fs[87][2] == 0x01
		and fs[88][1] == 0x40 and fs[88][2] == 0xA8
		and fs[89][1] == 0x42 and fs[89][2] == 0xA8
		and fs[90][1] == 0x41 and fs[90][2] == 0x02
		and fs[91][1] == 0x43 and fs[91][2] == 0x02
		and fs[92][1] == 0x7D and fs[92][2] == 0x06)
	-- 寄存器落盘（戳破旧桩 0x38）
	check("落盘 ACC_CONF=0xA8（POR 0xA8 高 4 位 RMW）", byte(0x40) == 0xA8, hx(byte(0x40)))
	check("落盘 GYR_CONF=0xA8（POR 0xA9 高 4 位 RMW）", byte(0x42) == 0xA8, hx(byte(0x42)))
	check("落盘 ACC_RANGE=2/GYR_RANGE=2/PWR_CONF=0/PWR_CTRL=6",
		byte(0x41) == 0x02 and byte(0x43) == 0x02
		and byte(0x7C) == 0x00 and byte(0x7D) == 0x06)
	-- 指针读：ID + 15 轮状态 + 2 CONF + PWR_CTRL
	local pr = ptr_reads(mark)
	check("指针读共 19：1 ID + 15 状态 + 2 CONF + 1 PWR_CTRL", #pr == 19, tostring(#pr))
	check("CHIP_ID 读在最前", pr[1].p == 0x00 and pr[1].n == 1)
	check("INTERNAL_STATUS 轮询 15 次（10..150ms）", count_reads(mark, 0x21, 1) == 15)
	check("CONF 读 0x40/0x42 各 1 次",
		count_reads(mark, 0x40, 1) == 1 and count_reads(mark, 0x42, 1) == 1)
	check("收尾 PWR_CTRL 读 1 次", count_reads(mark, 0x7D, 1) == 1)
	check("build 总线事务总数 131（set+92 写+19 指针写+19 读）",
		#entries(mark) == 131, tostring(#entries(mark)))
	check("blob 已入模型缓冲 328 字节", blob_matches(FIFO_BIN))
	check("横幅文案", cap ~= nil
		and cap:find("BMI270 init OK: addr=0x68, blob=fifo(328B), ±8g/±500dps, odr=100Hz", 1, true) ~= nil,
		tostring(cap))
end

-- 预武装路径（守护同款）：首拍轮询即 init_ok，睡眠 114ms
mark = section()
dev:virt_tick(0)
r = expect_ok("build 预武装（virt_tick 先于 build）",
	function() return build({ fd = fd, address = "0x68" }) end)
if r then
	check("预武装睡眠 2+1+1+10+100=114ms", sleep_total == 114, tostring(sleep_total))
	check("预武装状态轮询仅 1 次", count_reads(mark, 0x21, 1) == 1,
		tostring(count_reads(mark, 0x21, 1)))
	check("预武装指针读共 5", #ptr_reads(mark) == 5, tostring(#ptr_reads(mark)))
end

-- ======================================================================
-- 组 3：build full 与列取档
-- ======================================================================
mark = section()
dev:virt_tick(0)
cap = nil
oldprint = print
print = function(s) if type(s) == "string" and s:find("BMI270 init OK", 1, true) then cap = s end end
r = expect_ok("build cfg='full'（8192B context blob）",
	function() return build({ fd = fd, address = "0x68", cfg = "full" }) end)
print = oldprint
if r then
	check("full build 恰好 2058 笔数据写（4+2048+1+4+1）",
		#dev:frames() == 2058, tostring(#dev:frames()))
	check("full blob 8192 字节逐字节入模", blob_matches(FULL_BIN))
	check("full 横幅", cap ~= nil and cap:find("blob=full(8192B)", 1, true) ~= nil, tostring(cap))
end

-- 取档：量程 snap_down、ODR snap_near
mark = section()
dev:virt_tick(0)
r = expect_ok("build ±16g/±125dps/1600Hz 满档",
	function()
		return build({ fd = fd, address = "0x68",
			range = "16", gyro_range = "125", odr = "1600" })
	end)
if r then
	check("ACC_RANGE=3（±16g）", byte(0x41) == 0x03)
	check("GYR_RANGE=4（±125dps，dps 与码逆序）", byte(0x43) == 0x04)
	check("ACC/GYR_ODR=0x0C（1600Hz）",
		byte(0x40) % 16 == 0x0C and byte(0x42) % 16 == 0x0C,
		hx(byte(0x40)) .. "/" .. hx(byte(0x42)))
end

section()
dev:virt_tick(0)
r = expect_ok("build range=3/gyro=600/odr=70（降档+最近档）",
	function()
		return build({ fd = fd, address = "0x68",
			range = "3", gyro_range = "600", odr = "70" })
	end)
if r then
	check("range 3 降档 ±2g 代码 0", byte(0x41) == 0x00)
	check("gyro 600 降档 ±500dps 代码 2", byte(0x43) == 0x02)
	check("odr 70 最近 50Hz 代码 0x07",
		byte(0x40) % 16 == 0x07 and byte(0x42) % 16 == 0x07)
end

section()
dev:virt_tick(0)
r = expect_ok("build odr=12（最近 25Hz 代码 0x06）",
	function() return build({ fd = fd, address = "0x68", odr = "12" }) end)
if r then
	check("odr 12 → 0x06", byte(0x40) % 16 == 0x06 and byte(0x42) % 16 == 0x06)
end

section()
dev:virt_tick(0)
r = expect_ok("build 全 '-' 列归缺省（±8g/±500/100Hz/fifo）",
	function()
		return build({ fd = fd, address = "0x68",
			range = "-", gyro_range = "-", odr = "-", cfg = "-" })
	end)
if r then
	check("缺省档落盘 02/02/0x08",
		byte(0x41) == 0x02 and byte(0x43) == 0x02
		and byte(0x40) % 16 == 0x08 and byte(0x42) % 16 == 0x08)
	check("缺省走 fifo 328B", dev:blob_len() == 328)
end

section()
dev:virt_tick(0)
r = expect_ok("build 非法列值归缺省档",
	function()
		return build({ fd = fd, address = "0x68",
			range = "0", gyro_range = "abc", odr = "" })
	end)
if r then
	check("非法值缺省 ±8g/±500/100Hz",
		byte(0x41) == 0x02 and byte(0x43) == 0x02 and byte(0x40) % 16 == 0x08)
end

-- gyro 边界：2000→代码 0、250→代码 3、1000→代码 1
for _, spec in ipairs({ { "2000", 0 }, { "1000", 1 }, { "250", 3 }, { "125", 4 } }) do
	section()
	dev:virt_tick(0)
	r = build({ fd = fd, address = "0x68", gyro_range = spec[1] })
	check(string.format("gyro_range=%s 代码 %d", spec[1], spec[2]),
		r and r.result == "OK" and byte(0x43) == spec[2],
		"want " .. spec[2] .. " got " .. tostring(r and r.result))
end

-- ======================================================================
-- 组 4：build 负路径
-- ======================================================================
section()
expect_err("build 非 table 参数", function() return build(0) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x68" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build fd=99 未打开", function() return build({ fd = 99, address = "0x68" }) end,
	"set_addr failed")

section()
expect_err("build 错地址 0x60（无挂载→复位写 NACK）",
	function() return build({ fd = fd, address = "0x60" }) end, "soft reset")

section()
dev:who(0x26)
expect_err("build CHIP_ID=0x26 → BMI260 变体提示",
	function() return build({ fd = fd, address = "0x68" }) end, "Chip ID")

section()
dev:fail_read(function(p) return p == 0x00 end)
expect_err("build CHIP_ID 读失败",
	function() return build({ fd = fd, address = "0x68" }) end, "chip ID")

-- 逐帧 fail_write 短路点（均预武装，门不挡后续短路点）
local fail_points = {
	{ function(fr) return #fr == 2 and fr[1] == 0x7E end, "soft reset" },
	{ function(fr) return #fr == 2 and fr[1] == 0x7C end, "PWR_CONF" },
	{ function(fr) return #fr == 2 and fr[1] == 0x7D and fr[2] == 0x00 end, "PWR_CTRL" },
	{ function(fr) return #fr == 2 and fr[1] == 0x59 and fr[2] == 0x00 end, "INIT_CTRL" },
	{ function(fr) return fr[1] == 0x5B end, "config file" },
	{ function(fr) return fr[1] == 0x5E end, "config file" },
	{ function(fr) return #fr == 2 and fr[1] == 0x59 and fr[2] == 0x01 end, "config load" },
	{ function(fr) return #fr == 2 and fr[1] == 0x40 end, "ACC_CONF" },
	{ function(fr) return #fr == 2 and fr[1] == 0x42 end, "GYR_CONF" },
	{ function(fr) return #fr == 2 and fr[1] == 0x41 end, "ACC_RANGE" },
	{ function(fr) return #fr == 2 and fr[1] == 0x43 end, "GYR_RANGE" },
	{ function(fr) return #fr == 2 and fr[1] == 0x7D and fr[2] == 0x06 end, "acc+gyr" },
}
for _, spec in ipairs(fail_points) do
	section()
	dev:virt_tick(0)
	dev:fail_write(spec[1])
	expect_err("build 写短路：" .. spec[2],
		function() return build({ fd = fd, address = "0x68" }) end, spec[2])
end

section()
dev:virt_tick(0)
dev:fail_read(function(p) return p == 0x21 end)
expect_err("build INTERNAL_STATUS 读失败",
	function() return build({ fd = fd, address = "0x68" }) end, "internal status")
section()
dev:virt_tick(0)
dev:fail_read(function(p) return p == 0x40 end)
expect_err("build CONF 寄存器读失败",
	function() return build({ fd = fd, address = "0x68" }) end, "CONF registers")
section()
dev:virt_tick(0)
dev:fail_read(function(p) return p == 0x7D end)
expect_err("build PWR_CTRL 读失败",
	function() return build({ fd = fd, address = "0x68" }) end, "read BMI270 PWR_CTRL")

-- stuck 状态码：50 轮询 ×10ms = 500ms 超时
mark = section()
dev:virt_tick(0)
dev:set_stuck_status(0x02)
expect_err("build 状态卡死 0x02 → config load failed",
	function() return build({ fd = fd, address = "0x68" }) end, "config load failed")
check("卡死实睡 2+1+1+500=504ms", sleep_total == 504, tostring(sleep_total))
check("卡死轮询 50 次", count_reads(mark, 0x21, 1) == 50,
	tostring(count_reads(mark, 0x21, 1)))

-- never_ready：门不到点，状态恒 0x00，同样 50 轮询
mark = section()
dev:set_never_ready(true)
expect_err("build 加载门超时（状态 0x00）",
	function() return build({ fd = fd, address = "0x68" }) end,
	"internal status 0x00")
check("超时实睡 504ms / 轮询 50", sleep_total == 504 and count_reads(mark, 0x21, 1) == 50)

section()
dev.nack = true
expect_err("build 器件无应答", function() return build({ fd = fd, address = "0x68" }) end,
	"soft reset")

-- ======================================================================
-- 组 5：真实 call（六轴小端）
-- ======================================================================
section()
dev:virt_tick(0)
build({ fd = fd, address = "0x68" })
-- 小端预置：ACCEL X=0x1000 / Y=0xFFFF(-1) / Z=0；GYR X=0xFC00(-1024) / Y/Z=0
dev:set_accel_raw(4096, -1, 0)
dev:set_gyro_raw(-1024, 0, 0)
mark = #vbus.txlog
local sleep_base = sleep_total
r = expect_ok("call 六轴读值", function() return call({ fd = fd, address = "0x68" }) end)
if r then
	check("ACCEL_X=0x1000（LSB 在前）", r.ACCEL_X == 4096, tostring(r.ACCEL_X))
	check("ACCEL_Y=0xFFFF 原始码不转负", r.ACCEL_Y == 65535, tostring(r.ACCEL_Y))
	check("ACCEL_Z=0", r.ACCEL_Z == 0)
	check("GYRO_X=0xFC00 原始码（-1024 补码语义）", r.GYRO_X == 64512, tostring(r.GYRO_X))
	check("GYRO_Y/Z=0", r.GYRO_Y == 0 and r.GYRO_Z == 0)
	local pr = ptr_reads(mark)
	check("call 恰一次指针读 0x0C×12（单事务防撕裂）",
		#pr == 1 and pr[1].p == 0x0C and pr[1].n == 12,
		(function()
			local t = {} for _, e in ipairs(pr) do t[#t + 1] = string.format("%02X×%d", e.p, e.n) end
			return table.concat(t, ",")
		end)())
	check("call 零睡眠", sleep_total - sleep_base == 0, tostring(sleep_total - sleep_base))
	check("call set_addr 一次 / 总事务 3（set+1 指针写+1 读）",
		#set_addrs(mark) == 1 and #entries(mark) == 3, tostring(#entries(mark)))
	check("call 无 ≥2B 数据写", #frames(mark) == 0, tostring(#frames(mark)))
end

-- 二次 call：连续测量常驻，无任何写配置
mark = #vbus.txlog
r = expect_ok("二次 call 正常", function() return call({ fd = fd, address = "0x68" }) end)
if r then
	check("二次 call 仍恰一指针读", #ptr_reads(mark) == 1 and #frames(mark) == 0)
end

-- virt_tick 闭环：tick(8) 码经真实驱动读出
section()
dev:virt_tick(0)
build({ fd = fd, address = "0x68" })
dev:virt_tick(8)
r = expect_ok("call virt_tick(8) 样本", function() return call({ fd = fd, address = "0x68" }) end)
if r then
	check("tick8 六轴无符号码 = 模型 s16 展开",
		r.ACCEL_X == u16(500) and r.ACCEL_Y == u16(-350) and r.ACCEL_Z == u16(4196)
		and r.GYRO_X == u16(500) and r.GYRO_Y == u16(-400) and r.GYRO_Z == u16(300),
		table.concat({ r.ACCEL_X, r.ACCEL_Y, r.ACCEL_Z, r.GYRO_X, r.GYRO_Y, r.GYRO_Z }, ","))
end

-- ======================================================================
-- 组 6：call 负路径
-- ======================================================================
section()
expect_err("call 非 table 参数", function() return call(3) end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x68" }) end, "fd or address")
expect_err("call fd=99", function() return call({ fd = 99, address = "0x68" }) end,
	"set_addr failed")

section()
expect_err("call 错地址 0x60（指针写 NACK）",
	function() return call({ fd = fd, address = "0x60" }) end, "sensor data")

section()
dev:virt_tick(0)
build({ fd = fd, address = "0x68" })
dev:fail_read(function(p) return p == 0x0C end)
expect_err("call 传感器读失败（单事务）",
	function() return call({ fd = fd, address = "0x68" }) end, "sensor data")

-- ======================================================================
-- 组 7：destroy
-- ======================================================================
mark = section()
expect_ok("destroy 无资源需释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非 table 参数", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_bmi270")

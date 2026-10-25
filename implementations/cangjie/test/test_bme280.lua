-- test_bme280.lua - BME280 真实驱动在虚拟总线上的离线回归（无真机）
-- 用法: luajit test/test_bme280.lua（驱动 dofile HAL 加载 ffi，需 LuaJIT）
--
-- mock 方式：virtbus 内存 I2C 总线 + virtbus/bme280 器件模型（regmap 之上固化
-- NVM 校准布局、20bit 数据区位场、STATUS 合成与 forced 转换状态机），加载
-- 【真实】modules/BME280.lua 跑完整 build/call/destroy。milli_sleep 后注桩：
-- 既累计时长又驱动模型虚拟时钟（6ms 转换/50 次 NVM 轮询/100 次测量轮询）。
--
-- 覆盖点（对照 modules/BME280.lua 当前实现）：
--   1. build：ID 甄别（0x60 放行 / 0x58 错挂 BMP280 拦截 / 读 NACK）、软复位
--      0xE0<-0xB6、im_update 轮询与卡死超时（≥3+50ms）、T/P/H 校准块读取
--      （0x88 起 24B、0xA1、0xE1 起 7B 字节表长读）、CTRL 配置与写后回读
--      复核（配置写被器件吞掉→回读不一致）、主备地址 0x76/0x77、参数校验；
--   2. call：forced 触发写 0xF4<-0x25、measuring 位轮询（5+100ms 超时）、
--      0xF7/0xFB 两个 4 字节指针读取 20bit P/T 与 16bit H、无效读数
--      0x80000/0x8000、T/P/H 与测试独立转录的附录 8.3 参考公式交叉验证
--      （专抓 nibble/小端装配与补偿转录笔误）、burst NACK、参数校验；
--   3. destroy：CTRL_MEAS 模式位清零、缺 fd 安全、参数校验；
--   4. 模型协议行为：6ms 转换状态机（忙→到点就绪）、virt_tick 预武装
--           （触发即就绪，守护 E2E 路径）、确定性波形。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err
local vbus = dofile("modules/lib/virtbus.lua")
local bmemod = dofile("modules/lib/virtbus/bme280.lua")
vbus.reset()

local bme = bmemod.new()
vbus.attach("BME280@0x76", 0x76, bme)
vbus.attach("BME280@0x77", 0x77, bme)	-- 同一模型挂备地址
vbus.load_driver("modules/BME280.lua")

-- milli_sleep：累计时长 + 推进模型虚拟时钟（驱动运行时解析全局名，后注桩生效）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; bme:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起

-- ==================== datasheet 校准组与独立参考补偿（附录 8.3 浮点版） ====================
local CAL = {
	T1 = 27504, T2 = 26435, T3 = -1000,
	P1 = 36477, P2 = -10685, P3 = 3024, P4 = 2855, P5 = 140,
	P6 = -7, P7 = 15500, P8 = -14600, P9 = 6000,
	H1 = 75, H2 = 382, H3 = 0, H4 = 350, H5 = 0, H6 = 30,	-- H1 为 u8：datasheet 示例真值 75（0x4B，输出 45.3%RH 档）
}

local function ref_temperature(adc)
	local var1 = (adc / 16384.0 - CAL.T1 / 1024.0) * CAL.T2
	local var2 = (adc / 131072.0 - CAL.T1 / 8192.0) ^ 2 * CAL.T3
	local t_fine = var1 + var2
	return t_fine / 5120.0, t_fine
end

local function ref_pressure(adc, t_fine)
	local var1 = t_fine / 2.0 - 64000.0
	local var2 = var1 * var1 * CAL.P6 / 32768.0
	var2 = var2 + var1 * CAL.P5 * 2.0
	var2 = var2 / 4.0 + CAL.P4 * 65536.0
	var1 = (CAL.P3 * var1 * var1 / 524288.0 + CAL.P2 * var1) / 524288.0
	var1 = (1.0 + var1 / 32768.0) * CAL.P1
	local p = 1048576.0 - adc
	if var1 ~= 0 then
		p = (p - var2 / 4096.0) * 6250.0 / var1
		local w1 = CAL.P9 * p * p / 2147483648.0
		local w2 = p * CAL.P8 / 32768.0
		p = p + (w1 + w2 + CAL.P7) / 16.0
	end
	return p
end

local function ref_humidity(adc, t_fine)
	local h = t_fine - 76800.0
	h = (adc - (CAL.H4 * 64.0 + CAL.H5 / 16384.0 * h))
		* (CAL.H2 / 65536.0 * (1.0 + CAL.H6 / 67108864.0 * h
			* (1.0 + CAL.H3 / 67108864.0 * h)))
	h = h * (1.0 - CAL.H1 * h / 524288.0)
	return math.max(0.0, math.min(100.0, h))
end

local function near(a, b, rel)
	return math.abs(a - b) <= (rel or 1e-6) * math.max(1.0, math.abs(a), math.abs(b))
end

-- ==================== txlog 辅助 ====================
-- 找「单字节寄存器指针写 + 紧跟 n 字节读」的原子事务对
local function find_ptr_read(ptr, n)
	for i = 1, #vbus.txlog - 1 do
		local w, r = vbus.txlog[i], vbus.txlog[i + 1]
		if w.dir == "w" and #w.bytes == 1 and w.bytes[1] == ptr
			and r.dir == "r" and r.bytes.n == n then
			return true
		end
	end
	return false
end

local function find_data_write(reg, val)
	for _, e in ipairs(vbus.txlog) do
		if e.dir == "w" and #e.bytes >= 2 and e.bytes[1] == reg
			and (val == nil or e.bytes[2] == val) then
			return true
		end
	end
	return false
end

local function last_set_addr()
	for i = #vbus.txlog, 1, -1 do
		if vbus.txlog[i].dir == "set" then return vbus.txlog[i].addr end
	end
end

local function section()	-- 每个场景段：模型回构造态，虚拟时钟清零
	bme:reset()
	sleep_total = 0
end

-- ==================== call 未 build（必须在首个成功 build 之前） ====================
expect_err("call 未 build", function() return call({ fd = fd, address = "0x76" }) end, "not initialized")

-- ==================== build：配置与寄存器 ====================
section()
local build_mark = #vbus.txlog	-- 只统计本次 build 的事务（不能重配 vbus.txlog：核心走 upvalue 追加）
expect_ok("build 默认地址 0x76", function() return build({ fd = fd, address = "0x76" }) end)
check("CTRL_HUM=0x01（湿度 x1）", bme:get(0xF2) == 0x01, string.format("0x%02X", bme:get(0xF2) or 0))
check("CTRL_MEAS=0x24（T/P x1，睡眠）", bme:get(0xF4) == 0x24, string.format("0x%02X", bme:get(0xF4) or 0))
check("CONFIG=0x00（滤波关闭）", bme:get(0xF5) == 0x00, string.format("0x%02X", bme:get(0xF5) or 0))
do
	local cw = bme:config_writes()
	local want = { {0xE0,0xB6}, {0xF5,0x00}, {0xF2,0x01}, {0xF4,0x24} }
	local same = #cw == #want
	for i = 1, #want do
		if same and (cw[i].reg ~= want[i][1] or cw[i].val ~= want[i][2]) then same = false end
	end
	check("配置写序列：复位0xB6→F5→F2→F4=0x24", same,
		(function()
			local t = {}
			for _, e in ipairs(cw) do t[#t + 1] = string.format("%02X=%02X", e.reg, e.val) end
			return table.concat(t, ",")
		end)())
end
check("软复位后固定等 3ms 再轮询", sleep_total == 3, tostring(sleep_total))
check("校准块读：0x88 起 24B = 6 个 4 字节指针读",
	(function()
		local n = 0
		for i = build_mark + 1, #vbus.txlog - 1 do
			local w, r = vbus.txlog[i], vbus.txlog[i + 1]
			if w.dir == "w" and #w.bytes == 1
				and (w.bytes[1] >= 0x88 and w.bytes[1] <= 0x9C)
				and r.dir == "r" and r.bytes.n == 4 then n = n + 1 end
		end
		return n == 6
	end)(), "应读到 6 块")
check("湿度校准走字节表长读：0xE1 指针 + n=7", find_ptr_read(0xE1, 7))
check("H1 单字节读：0xA1 指针 + n=1", find_ptr_read(0xA1, 1))
check("STATUS im_update 轮询读：0xF3 指针 + n=1", find_ptr_read(0xF3, 1))

section()
expect_ok("build 备地址 0x77", function() return build({ fd = fd, address = "0x77" }) end)
check("备地址事务路由到 0x77", last_set_addr() == 0x77, string.format("0x%02X", last_set_addr() or 0))

-- ==================== build：错误路径 ====================
section()
bme:who(0x58)
expect_err("build chip id 错误（BMP280?）", function() return build({ fd = fd, address = "0x76" }) end, "chip id")

section()
bme.nvm_stuck = true
expect_err("build NVM 拷贝超时", function() return build({ fd = fd, address = "0x76" }) end, "copy timeout")
check("超时前轮询 3+50ms", sleep_total >= 53, tostring(sleep_total))

section()
do
	-- 驱动不判写返回值、靠写后回读复核：注入「器件吞掉配置写（未应用）」——
	-- F2/F4/F5 写成功但寄存器不变，回读不一致；读指针写（单字节）必须照常透传。
	local real_write = bme.write
	bme.write = function(bytes)
		if type(bytes) == "table" and #bytes >= 2
			and (bytes[1] == 0xF2 or bytes[1] == 0xF4 or bytes[1] == 0xF5) then
			return true
		end
		return real_write(bytes)
	end
	expect_err("build 配置写未生效（回读不一致）",
		function() return build({ fd = fd, address = "0x76" }) end, "configure")
	bme.write = real_write
end

section()
bme.nack_read = true
expect_err("build 读无应答（chip id 失败）", function() return build({ fd = fd, address = "0x76" }) end, "chip id")

section()
expect_err("build 缺 fd", function() return build({ address = "0x76" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build 非表参数", function() return build(0) end, "Invalid Arguments Type")

-- ==================== call：T/P/H 与独立公式交叉验证 ====================
section()
expect_ok("call 前 build", function() return build({ fd = fd, address = "0x76" }) end)
local res = expect_ok("call 三通道补偿", function() return call({ fd = fd, address = "0x76" }) end)
if res then
	local refT, t_fine = ref_temperature(519888)
	local refP = ref_pressure(415148, t_fine)
	local refH = ref_humidity(30000, t_fine)
	check("参考值落在未钳位合理区间",
		refT > 20 and refT < 30 and refP > 95000 and refP < 105000 and refH > 0 and refH < 100,
		string.format("T=%s P=%s H=%s", tostring(refT), tostring(refP), tostring(refH)))
	check("T 与独立公式一致（25.08°C 档）", near(res.T, refT),
		string.format("%s vs %s", tostring(res.T), tostring(refT)))
	check("P 与独立公式一致（≈100653Pa）", near(res.P, refP),
		string.format("%s vs %s", tostring(res.P), tostring(refP)))
	check("H 与独立公式一致（45.3%RH 档）", near(res.H, refH),
		string.format("%s vs %s", tostring(res.H), tostring(refH)))
end
check("forced 触发写：0xF4<-0x25（x1/x1 + mode=01）", find_data_write(0xF4, 0x25))
check("数据块读：0xF7 指针 + n=4（P高/T高）", find_ptr_read(0xF7, 4))
check("数据块读：0xFB 指针 + n=4（T低/H）", find_ptr_read(0xFB, 4))

-- ==================== 转换状态机：忙→到点就绪 ====================
section()
expect_ok("状态机用 build", function() return build({ fd = fd, address = "0x76" }) end)
i2c_set_addr(fd, 0x76)
i2c_write_reg(fd, 0xF4, 0x25)
check("触发后未推进时钟：STATUS=0x08（measuring）",
	i2c_read_multi(fd, 0xF3, 1) == 0x08,
	string.format("0x%02X", i2c_read_multi(fd, 0xF3, 1)))
bme:advance(5)
check("5ms（<6ms 转换）：仍 measuring", i2c_read_multi(fd, 0xF3, 1) == 0x08)
bme:advance(1)
check("6ms 到点：measuring 清零、数据区已填充", i2c_read_multi(fd, 0xF3, 1) == 0x00)

-- virt_tick 预武装（守护 proto=virt 路径：无人驱动虚拟时钟，触发即就绪）
section()
bme:virt_tick(3)
i2c_set_addr(fd, 0x76)
i2c_write_reg(fd, 0xF4, 0x25)
check("预武装后触发：零等待 STATUS=0x00", i2c_read_multi(fd, 0xF3, 1) == 0x00)
do
	local a = bmemod.new()
	a:virt_tick(0); a:virt_tick(4)
	local d0, d4 = {}, {}
	for r = 0xF7, 0xFE do d0[#d0 + 1] = a:get(r) end
	a:virt_tick(0); a:virt_tick(4)
	for r = 0xF7, 0xFE do d4[#d4 + 1] = a:get(r) end
	local deterministic = true
	for i = 1, 8 do if d0[i] ~= d4[i] then deterministic = false end end
	check("virt_tick 确定性（同序号同数据）", deterministic)
	a:virt_tick(0); local z = {}
	for r = 0xF7, 0xFE do z[#z + 1] = a:get(r) end
	local changed = false
	for i = 1, 8 do if z[i] ~= d0[i] then changed = true end end
	check("virt_tick 波形随序号变化（n=0≠n=4）", changed)
end

-- ==================== call：无效读数与超时 ====================
section()
expect_ok("无效温度用例 build", function() return build({ fd = fd, address = "0x76" }) end)
bme:set_raw(0x80000)
expect_err("call 无效温度读数（0x80000）", function() return call({ fd = fd, address = "0x76" }) end, "temperature")

section()
expect_ok("无效湿度用例 build", function() return build({ fd = fd, address = "0x76" }) end)
bme:set_raw(nil, nil, 0x8000)
expect_err("call 无效湿度读数（0x8000）", function() return call({ fd = fd, address = "0x76" }) end, "humidity")

section()
expect_ok("超时用例 build", function() return build({ fd = fd, address = "0x76" }) end)
bme.meas_stuck = true
expect_err("call 测量超时", function() return call({ fd = fd, address = "0x76" }) end, "timeout")
check("超时前轮询 5+100ms", sleep_total >= 105, tostring(sleep_total))
expect_err("call 非表参数", function() return call(3) end, "Invalid Arguments")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")

-- ==================== destroy ====================
section()
expect_ok("destroy 前 build", function() return build({ fd = fd, address = "0x76" }) end)
expect_ok("destroy 置睡眠", function() return destroy({ fd = fd, address = "0x76" }) end)
check("CTRL_MEAS 模式位清零（睡眠）", bme:get(0xF4) % 4 == 0, tostring(bme:get(0xF4)))

section()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
expect_err("destroy 非表参数", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_bme280")

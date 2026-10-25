-- test_mpu6050.lua - MPU6050 真实驱动在虚拟总线上的离线回归（无真机）
-- 用法: luajit test/test_mpu6050.lua（驱动 dofile HAL 加载 ffi，需 LuaJIT）
--
-- mock 方式：virtbus 内存 I2C 总线 + virtbus/mpu6050 寄存器器件模型，加载
-- 【真实】modules/MPU6050.lua 跑完整 build/call/destroy。模型只提供寄存器层
-- 事实（WHO_AM_I、14 字节 burst、补码字节），符号扩展与温度换算仍由驱动完成、
-- 由本测试独立断言。milli_sleep 后注桩以去掉 100ms 稳定等待（驱动运行时解析
-- 全局名，后注桩生效）。
--
-- 覆盖点（对照 modules/MPU6050.lua 当前实现）：
--   1. build：参数校验、默认地址 0x68 / 备地址 0x69、寄存器配置序列（PWR_MGMT_1
--      0x6B<-0x00 退睡眠、陀螺 0x1B<-0x08 ±500°/s、加速度 0x1C<-0x10 ±8g）、
--      100ms 稳定等待、WHO_AM_I 甄别（0x68 放行 / 0x71 错挂拦截 / 读失败）、
--      写 NACK 错误通道；
--   2. call：0x3B 起 14 字节 burst 原子读（写指针事务 + 读 n=14）、六轴 16 位
--      补码符号扩展（正/负/零/极值）、温度 °C=raw/340+36.53（正/负/零/室温/极值）、
--      burst NACK（nil）触发 ERR、六轴返回键名与量程无换算；
--   3. destroy：参数校验与成功返回；
--   4. 字符串 address（框架元数据侧全为字符串）兼容。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err
local vbus = dofile("modules/lib/virtbus.lua")
local mpmod = dofile("modules/lib/virtbus/mpu6050.lua")
vbus.reset()

local imu = mpmod.new()
vbus.attach("MPU6050@0x68", 0x68, imu)
vbus.attach("MPU6050@0x69", 0x69, imu)	-- 同一模型挂备地址，支持 0x69 build 用例
vbus.load_driver("modules/MPU6050.lua")

-- 去掉 build 的 1ms+100ms 实睡眠（累计仍可断言）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
local base = { fd = fd, address = "0x68" }

-- ==================== 断言辅助 ====================
local function result_of(ok, res) return tester.result_of(ok, res) end

-- txlog 中最后一次 set_addr 的地址
local function last_set_addr()
	for i = #vbus.txlog, 1, -1 do
		if vbus.txlog[i].dir == "set" then return vbus.txlog[i].addr end
	end
end

-- txlog 中最后一笔读事务与其紧邻的前一笔（指针写）事务
local function last_read()
	for i = #vbus.txlog, 1, -1 do
		if vbus.txlog[i].dir == "r" then return vbus.txlog[i], vbus.txlog[i - 1] end
	end
end

local function expect_axis(label, data, axis, expect)
	local ok, res = pcall(call, data)
	local got = ok and type(res) == "table" and res[axis] or nil
	check(label .. " " .. axis .. "=" .. tostring(expect),
		ok and got ~= nil and got == expect,
		"got=" .. tostring(got) .. " result=" .. result_of(ok, res))
end

-- 温度换算（浮点容差 1e-9）；模型注入原始 LSB，换算完全走驱动
local function expect_temp(label, raw, expectC)
	imu:reset()
	imu:set_temp_raw(raw)
	local ok, res = pcall(call, base)
	local gotC   = ok and type(res) == "table" and res.TEMP or nil
	local gotRaw = ok and type(res) == "table" and res.TEMP_RAW or nil
	check(string.format("%s raw=%d -> %.2f°C", label, raw, expectC),
		ok and gotC ~= nil and math.abs(gotC - expectC) < 1e-9
		and gotRaw == raw,
		string.format("got TEMP=%s TEMP_RAW=%s result=%s",
			tostring(gotC), tostring(gotRaw), result_of(ok, res)))
end

-- ==================== build：寄存器配置序列 ====================
imu:reset()
imu:clear_log()
sleep_total = 0
expect_ok("build 默认参数 (fd=3, address='0x68')", function() return build(base) end)

local cw = imu:config_writes()
check("build 恰好写 3 个配置寄存器", #cw == 3, tostring(#cw))
check("build 写 PWR_MGMT_1 退睡眠 (0x6B<-0x00)",
	cw[1].reg == 0x6B and cw[1].val == 0x00,
	string.format("reg=0x%02X val=0x%02X", cw[1] and cw[1].reg or -1, cw[1] and cw[1].val or -1))
check("build 写陀螺量程 ±500°/s (0x1B<-0x08)",
	cw[2].reg == 0x1B and cw[2].val == 0x08,
	string.format("reg=0x%02X val=0x%02X", cw[2] and cw[2].reg or -1, cw[2] and cw[2].val or -1))
check("build 写加速度量程 ±8g (0x1C<-0x10)",
	cw[3].reg == 0x1C and cw[3].val == 0x10,
	string.format("reg=0x%02X val=0x%02X", cw[3] and cw[3].reg or -1, cw[3] and cw[3].val or -1))
check("build 含 1ms 起步 + 100ms 稳定等待 (累计 101ms)", sleep_total == 101, tostring(sleep_total))
check("set_addr 收到 0x68=104", last_set_addr() == 0x68, tostring(last_set_addr()))

-- 备地址 0x69：同一模型挂在 0x69，配置写应全部 ACK
expect_ok("build 地址 '0x69'", function() return build({ fd = fd, address = "0x69" }) end)
check("set_addr 收到 0x69=105", last_set_addr() == 0x69, tostring(last_set_addr()))

-- ==================== build：WHO_AM_I 甄别 ====================
-- 错挂器件（MPU6500/9250 答 0x71）：纯写配置能通过，身份值必须拦下
imu:reset()
imu:who(0x71)
expect_err("build WHO_AM_I 不符 (0x71)", function() return build(base) end, "WHO_AM_I")
imu:reset()

-- 仅读方向 NACK：退睡眠写成功，身份读失败 → 显式 ERR
imu.nack_read = true
expect_err("build 读 WHO_AM_I 失败", function() return build(base) end, "not responding")
imu:reset()

-- ==================== build：错误通道 ====================
expect_err("build 缺 fd", function() return build({ address = "0x68" }) end, "Invalid Argument: fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "Invalid Argument: fd or address")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")

-- 写方向 NACK：第一笔 PWR_MGMT_1 就失败（HAL i2c_write_reg 布尔契约，
-- 虚拟总线必须同样返回 false 而不是 -1，否则 Lua 里 -1 为真会假绿）
imu.nack_write = true
expect_err("build 写失败触发 ERR", function() return build(base) end, "write failed")
imu:reset()

-- ==================== call：burst 原子读与符号扩展 ====================
imu:reset()
expect_ok("call 全零返回 OK", function() return call(base) end)
local r_e, ptr_e = last_read()
check("call 单次 burst 读 0x68 的 14 字节（原子，无撕裂窗口）",
	r_e ~= nil and r_e.bytes.n == 14 and r_e.addr == 0x68,
	r_e and string.format("addr=0x%02X n=%s", r_e.addr, tostring(r_e.bytes and r_e.bytes.n)) or "无读事务")
check("burst 前紧邻一笔 0x3B 寄存器指针写（I2C_RDWR 语义）",
	ptr_e ~= nil and ptr_e.dir == "w" and #ptr_e.bytes == 1 and ptr_e.bytes[1] == 0x3B,
	ptr_e and ("dir=" .. ptr_e.dir) or "无前序事务")
expect_axis("call 全零", base, "ACCEL_X", 0)
expect_axis("call 全零", base, "GYRO_Z",  0)

-- 全零 raw=0 → 0/340+36.53 = 36.53°C（datasheet 零点偏置）
local zok, zres = pcall(call, base)
check("call 全零温度 TEMP=36.53°C / TEMP_RAW=0",
	zok and type(zres) == "table" and math.abs(zres.TEMP - 36.53) < 1e-9
	and zres.TEMP_RAW == 0,
	zok and tostring(zres and zres.TEMP) or result_of(zok, zres))

-- 正值
imu:reset()
imu:set_accel(0x1234, nil, nil):set_gyro(nil, nil, 0x7FFF)
expect_axis("call 正加速度 x=0x1234", base, "ACCEL_X", 0x1234)
expect_axis("call 最大正角速度 z=0x7FFF", base, "GYRO_Z", 0x7FFF)

-- 负值（补码还原）
imu:reset()
imu:set_accel(nil, -1, nil):set_gyro(-32768, nil, nil)
expect_axis("call 负加速度 y=-1", base, "ACCEL_Y", -1)
expect_axis("call 最小负角速度 x=-32768", base, "GYRO_X", -32768)

-- 中间负值
imu:reset()
imu:set_accel(nil, nil, -32767):set_gyro(nil, -1234, nil)
expect_axis("call 负角速度 y=-1234", base, "GYRO_Y", -1234)
expect_axis("call 负加速度 z=-32767", base, "ACCEL_Z", -32767)

-- 六轴全部同时读到（一次 burst 填满 14 字节）
imu:reset()
imu:sample({ ax = 1, ay = 2, az = 3, gx = -4, gy = -3, gz = -2, temp = 340 })
local ok, res = pcall(call, base)
check("六轴同时正确（1,2,3,-4,-3,-2）",
	ok and res.ACCEL_X == 1 and res.ACCEL_Y == 2 and res.ACCEL_Z == 3
	and res.GYRO_X == -4 and res.GYRO_Y == -3 and res.GYRO_Z == -2 and res.result == "OK",
	ok and table.concat({ res.ACCEL_X, res.ACCEL_Y, res.ACCEL_Z, res.GYRO_X, res.GYRO_Y, res.GYRO_Z }, ",") or result_of(ok, res))
check("同一 burst 温度随行（raw=340 -> 37.53°C）",
	ok and math.abs(res.TEMP - 37.53) < 1e-9 and res.TEMP_RAW == 340,
	ok and string.format("TEMP=%s TEMP_RAW=%s", tostring(res and res.TEMP), tostring(res and res.TEMP_RAW)) or result_of(ok, res))

-- ==================== call：温度换算（°C = raw/340 + 36.53）====================
-- set_temp_raw 入参为有符号原始 LSB（补码由模型编码，与驱动 s16 解码成对侧）
expect_temp("温度零偏",     0,      36.53)                  -- raw=0
expect_temp("温度正 340",   340,    37.53)                  -- +1°C
expect_temp("温度负 -340",  -340,   35.53)                  -- -1°C（补码 0xFEAC）
expect_temp("温度典型室温", -5120,  -5120 / 340 + 36.53)    -- ≈ 21.47°C（补码 0xEC00）
expect_temp("温度极值负满", -32768, -32768 / 340 + 36.53)   -- 补码 0x8000
expect_temp("温度极值正满", 32767,  32767 / 340 + 36.53)    -- 补码 0x7FFF
-- 温度键契约：同时给换算值 TEMP(°C) 与原始值 TEMP_RAW
imu:reset()
imu:set_temp_raw(340)
local tok, tres = pcall(call, base)
check("温度键名 TEMP(°C)/TEMP_RAW 并存（37.53 / 340）",
	tok and type(tres.TEMP) == "number" and type(tres.TEMP_RAW) == "number"
	and math.abs(tres.TEMP - 37.53) < 1e-9 and tres.TEMP_RAW == 340,
	tok and string.format("TEMP=%s TEMP_RAW=%s", tostring(tres and tres.TEMP), tostring(tres and tres.TEMP_RAW))
		or result_of(tok, tres))

-- 量程无换算：直接返回寄存器原始值（不做 16384/65.5 除法），键名用驱动输出名
local raw_ok, raw = pcall(call, base)
check("call 返回键名 ACCEL_*/GYRO_* 与 result 契约",
	raw_ok and raw and raw.result == "OK" and raw.ACCEL_X ~= nil and raw.GYRO_X ~= nil,
	raw_ok and tostring(raw and raw.result) or result_of(raw_ok, raw))

-- ==================== call：错误通道 ====================
-- burst 读 NACK（配置写正常、仅读方向失败）必须触发 ERR（halt-on-error 契约）
imu.nack_read = true
expect_err("call 读失败触发 ERR", function() return call(base) end, "read failed")
imu:reset()

expect_err("call 缺 fd", function() return call({ address = "0x68" }) end, "Invalid Argument: fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "Invalid Argument: fd or address")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments Type")

-- ==================== virt_tick：守护仿真波形（proto=virt） ====================
do
	local R = mpmod.REG
	local sim = mpmod.new()
	sim:virt_tick(0)
	-- n=0：accel 正弦起点 ax=0；gyro 余弦起点 gx=满幅 10000；温度静态项 raw=1530（≈41.03°C）
	check("virt_tick n=0：ax=0 / gx=10000 / temp_raw=1530",
		sim:get_sword(R.ACCEL_XH) == 0
		and sim:get_sword(R.GYRO_XH) == 10000
		and sim:get_sword(R.TEMP_H) == 1530,
		string.format("ax=%d gx=%d temp=%d",
			sim:get_sword(R.ACCEL_XH), sim:get_sword(R.GYRO_XH), sim:get_sword(R.TEMP_H)))
	-- 三轴相位互差 120°：n=0 时 ay≈20000·sin(2π/3)≈17321，az≈-17321（容差 ±2 LSB）
	local ay, az = sim:get_sword(R.ACCEL_XH + 2), sim:get_sword(R.ACCEL_XH + 4)
	check("virt_tick n=0：ay/az 为 ±17321（120° 相位）",
		math.abs(ay - 20000 * math.sin(2 * math.pi / 3)) <= 2
		and math.abs(az - 20000 * math.sin(4 * math.pi / 3)) <= 2,
		"ay=" .. tostring(ay) .. " az=" .. tostring(az))
	-- 确定性：两个独立实例同节拍必须逐字段一致（E2E 数值可复现的前提）
	local a, b = mpmod.new(), mpmod.new()
	a:virt_tick(7); b:virt_tick(7)
	local det = true
	for _, r in ipairs({ R.ACCEL_XH, R.ACCEL_XH + 2, R.ACCEL_XH + 4,
			R.GYRO_XH, R.GYRO_XH + 2, R.GYRO_XH + 4, R.TEMP_H }) do
		if a:get_sword(r) ~= b:get_sword(r) then det = false end
	end
	check("virt_tick 确定性（同 n 两实例七字段全等）", det)
	-- 推进性与幅值边界：扫 0..60 拍 ax 必随 n 变化，六轴始终在波形幅值内，温度慢漂有界
	local first_ax = sim:get_sword(R.ACCEL_XH)	-- sim 已在 n=0
	local moved, bounded = false, true
	for n = 1, 60 do
		sim:virt_tick(n)
		if sim:get_sword(R.ACCEL_XH) ~= first_ax then moved = true end
		for _, r in ipairs({ R.ACCEL_XH, R.ACCEL_XH + 2, R.ACCEL_XH + 4 }) do
			if math.abs(sim:get_sword(r)) > 20000 then bounded = false end
		end
		for _, r in ipairs({ R.GYRO_XH, R.GYRO_XH + 2, R.GYRO_XH + 4 }) do
			if math.abs(sim:get_sword(r)) > 10000 then bounded = false end
		end
		local tr = sim:get_sword(R.TEMP_H)
		if tr < 1360 or tr > 1700 then bounded = false end
	end
	check("virt_tick 随 n 推进（60 拍内 ax 离开过初值）", moved)
	check("virt_tick 幅值有界（accel≤20000 / gyro≤10000 / temp∈[1360,1700] LSB）", bounded)
	-- 链式返回 self
	check("virt_tick 返回模型自身（链式）", mpmod.new():virt_tick(3) ~= nil)
end

-- ==================== destroy ====================
expect_ok("destroy 正常", function() return destroy(base) end)
expect_err("destroy 缺 fd", function() return destroy({ address = "0x68" }) end, "Invalid Argument")
expect_err("destroy 参数非表", function() return destroy(nil) end, "Invalid Arguments Type")

i2c_close(fd)
vbus.restore()
tester.summary("test_mpu6050")
return 0

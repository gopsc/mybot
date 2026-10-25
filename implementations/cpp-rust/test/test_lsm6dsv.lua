-- test_lsm6dsv.lua —— LSM6DSV16X 真实驱动 + 虚拟 I2C 总线 + 六轴模型
-- 用法（项目根目录）: luajit test/test_lsm6dsv.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：LSM6DSV_GC=1 luajit test/test_lsm6dsv.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 226 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/LSM6DSV.lua 尾部 LSM6DSV_VIRT，
-- 2026-09-15 自 virtbus/lsm6dsv.lua 迁入）」。协议事实依 ST 官方
-- lsm6dsv16x_reg.h + Zephyr dts 绑定钉死，三份独立实现交叉（模型只存
-- 原始码/寄存器事实，灵敏度倒数仅用于物理量逆注入）。
--
-- 迁移同时抓出真实驱动一处真机 bug：原 REG_CTRL8=0x18——官方 fs_xl 在
-- CTRL8(0x17)[1:0]，0x18 是 CTRL9；真机加计量程码被写进 CTRL9，加计
-- 永远 POR ±2g（横幅照印配置值）。已修为 0x17，本测试组 2 以
-- 「build 后 0x17=fs 码而 0x18 恒 0」钉死回归。
--
-- 旧桩互证假绿：
--   1) CTRL3 POR 旧桩播 0x04 且复位后「首拍读 1、次拍自清」——实证
--      POR=0x00、sw_reset 写即自清，真实驱动首拍轮询（仅睡一次 10ms）
--      即跳出，旧桩把轮询节奏放慢一拍；
--   2) 旧桩无 IF_INC=0 多字节读重复同址门、无 0x17/0x18 地址隔离
--      （所以真机地址 bug 从未被测试发现）、无 fs_g 0xC 不连续码观察、
--      无 STATUS 合成/卡死注入/故障钩子/virt_tick；
--   3) 小端双窗只测了手写 regs[]，未走真实驱动拼字与陀螺在前窗序。
--
-- 覆盖七组：
--   1) 模型事实：POR/双数据窗小端/0x17 vs 0x18 隔离/fs_g 0xC/保留码/
--      IF_INC 重复同址门与模 256 回绕/sw_reset 写即自清+reseed 保留
--      who/注入码/钩子、BOOT 自清/STATUS 动态合成/坏帧不挪指针/六钩子/
--      物理量逆注入/virt_tick 码钉
--   2) 真实 build：19 条 txlog（1 set+6 数据写+6 对指针读）、睡眠
--      10+100=110ms、6 帧序列、CTRL3=0x44/CTRL1=CTRL2=6/CTRL6=2/
--      0x17=2/0x18=0、横幅、reset_count=1
--   3) 列取档枚举：acc snap_down/gyr snap_down（含 124dps 落缺省、
--      4000→0xC）/odr 最近档平手取低（100→120、90→60）/'-'与非法值
--   4) build 负路径：0x6C 家族 ID/ID 与 CTRL3/CTRL6/CTRL8 读失败/
--      reset_stuck 10 轮询睡 100ms/6 个逐帧写失败短路点 txlog 计数/
--      fd=99/错地址 0x60/非表缺参
--   5) 真实 call：0x22/0x28 两指针读各 6B（陀螺在前）、小端拼字
--      0x1000/0xFFFF/0xFC00、tick 闭环三拍、零睡眠、每窗 5 事务
--   6) call 负路径：gyr/acc 读失败、非表/缺 fd/错地址
--   7) destroy：零事务、非表 ERR

if os.getenv("LSM6DSV_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x6A
-- 模型内嵌于驱动文件（LSM6DSV_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/LSM6DSV.lua")
local mm = LSM6DSV_VIRT

local dev = mm.new()
vbus.attach("LSM6DSV@0x6A", ADDR, dev)

-- milli_sleep：模型无转换门，桩只累计时长/清单（不推进任何虚拟时钟）
local sleep_total = 0
local sleeps = {}
function milli_sleep(ms)
	sleep_total = sleep_total + ms
	sleeps[#sleeps + 1] = ms
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

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
section()

-- POR（官方 register map RESET 列：除 ROM WHO_AM_I 外配置寄存器全 0）
check("POR WHO_AM_I=0x70", byte(0x0F) == 0x70)
check("POR CTRL1/2/3=0", byte(0x10) == 0 and byte(0x11) == 0 and byte(0x12) == 0)
check("POR CTRL6/CTRL8(0x17)/CTRL9(0x18)=0",
	byte(0x15) == 0 and byte(0x17) == 0 and byte(0x18) == 0)
check("POR STATUS=0x00（ODR 未配）", byte(0x1E) == 0x00)
do
	local ok = true
	for a = 0x22, 0x2D do if byte(a) ~= 0 then ok = false end end
	check("POR 双测量窗 0x22..0x2D 全 0", ok)
end
check("POR 未定义地址 0x60 读 0", byte(0x60) == 0)
dev.write({ 0x60, 0x12 })
check("未定义地址写 ACK 落盘回读 0x12", byte(0x60) == 0x12)

-- ---- IF_INC(CTRL3 bit2) 门：0=重复同址，1=指针自增；模 256 回绕 ----
section()
dev.write({ 0x60, 0xAA, 0xBB })
dev.write({ 0x60 })
local rep = dev.read(3)
check("POR IF_INC=0：burst 重复读同址（AA AA AA）",
	rep[1] == 0xAA and rep[2] == 0xAA and rep[3] == 0xAA, table.concat(rep, ","))
dev.write({ 0x12, 0x04 })
dev.write({ 0x60 })
local inc = dev.read(3)
check("IF_INC=1：burst 跨址自增（AA BB 00）",
	inc[1] == 0xAA and inc[2] == 0xBB and inc[3] == 0x00, table.concat(inc, ","))
dev.write({ 0x0D })
local towho = dev.read(4)
check("自增序列 0x0D..0x10 命中 0x0F WHO=0x70",
	towho[1] == 0 and towho[2] == 0 and towho[3] == 0x70 and towho[4] == 0,
	table.concat(towho, ","))
dev.write({ 0xFD, 0x11, 0x22, 0x33 })	-- 0xFD/FE/FF 播不同值
dev.write({ 0x00, 0x44 })
dev.write({ 0xFE })
local wrap = dev.read(4)
check("指针 0xFF→0x00 算术回绕",
	wrap[1] == 0x22 and wrap[2] == 0x33 and wrap[3] == 0x44 and wrap[4] == 0x00
	and dev:pointer() == 0x02,
	table.concat(wrap, ",") .. " ptr=" .. tostring(dev:pointer()))

-- ---- 配置寄存器忠实落盘 + 0x17/0x18 地址隔离 + fs_g 0xC ----
section()
dev.write({ 0x17, 0xFF })
check("CTRL8(0x17) 全 8 位落盘（fs_xl 低 2 + dualC/滤波高 6）", byte(0x17) == 0xFF)
dev.write({ 0x18, 0x80 })
check("0x17 fs_xl 不被 0x18 写牵动（两址隔离）", byte(0x17) == 0xFF)
check("CTRL9(0x18) 各位忠实落盘 0x80", byte(0x18) == 0x80)
dev.write({ 0x15, 0xFF })
check("CTRL6 全 8 位落盘（fs_g 低 4 + 滤波高 4，保留码也照存）", byte(0x15) == 0xFF)
check("观察口解码保留码 fs_g=0xF → gyr_dps=nil",
	dev:config().fs_g == 0x0F and dev:config().gyr_dps == nil)
dev.write({ 0x15, 0x0C })
check("fs_g=0xC 解码 ±4000dps（码不连续档）",
	dev:config().fs_g == 0x0C and dev:config().gyr_dps == 4000)
dev.write({ 0x10, 0xFF }); dev.write({ 0x11, 0xFF })
check("CTRL1/2 全 8 位落盘", byte(0x10) == 0xFF and byte(0x11) == 0xFF)

-- ---- 只读区写 ACK 丢弃 ----
section()
dev.write({ 0x0F, 0x6C }); check("WHO_AM_I ROM 只读写丢弃", byte(0x0F) == 0x70)
dev:virt_tick(0)
local x0 = select(1, dev:accel_raw())	-- 0x28 是 AX LSB（tick0 ax=300）
dev.write({ 0x28, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA })
check("加计窗只读写丢弃", byte(0x28) == x0 % 256)
dev.write({ 0x22, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 })
check("陀螺窗只读写丢弃（n0 陀螺全 0）", byte(0x22) == 0)
dev.write({ 0x1E, 0xFF })
check("STATUS 只读写丢弃（仍动态 0x00）", byte(0x1E) == 0x00)

-- ---- CTRL3：sw_reset 写即自清 + 立即 reseed；BOOT 自清 ----
section()
dev:who(0x6C)
dev:virt_tick(8)
dev:set_accel_raw(111, 222, 333)
dev:fail_write(function(fr) return fr[1] == 0x60 end)
dev.write({ 0x17, 0x03 }); dev.write({ 0x10, 0x06 })
dev.write({ 0x12, 0x01 })					-- sw_reset（同帧只有 bit0）
check("sw_reset 后 reset_count=1", dev:reset_count() == 1)
check("sw_reset 位写即自清（CTRL3 读 0，不等轮询）", byte(0x12) == 0x00)
check("reseed 清配置：CTRL8/CTRL1 回 0", byte(0x17) == 0 and byte(0x10) == 0)
check("软复位保留 who 覆写（误挂甄别有效）", byte(0x0F) == 0x6C)
check("软复位保留注入码（tick 预武装不被解除）",
	(select(1, dev:accel_raw())) == 111 and (select(1, dev:gyro_raw())) == 500)
check("软复位保留故障钩子", dev.write({ 0x60, 0x00 }) == false)
dev:clear_faults()
dev.write({ 0x12, 0x05 })					-- bit0 + IF_INC 同写
check("sw_reset 同帧其余位随复位作废（读仍 0）", byte(0x12) == 0x00)
check("第二次复位计数=2", dev:reset_count() == 2)
section()
dev.write({ 0x12, 0x84 })					-- BOOT + IF_INC
check("BOOT bit7 自清、其余位照落 0x04", byte(0x12) == 0x04)
check("boot_count=1（不 reseed）", dev:boot_count() == 1 and byte(0x0F) == 0x70)
dev.write({ 0x12, 0x84 })
check("BOOT 可重复计数=2", dev:boot_count() == 2 and byte(0x12) == 0x04)
dev.write({ 0x12, 0x81 })					-- BOOT + sw_reset 同写
check("sw_reset 优先：reseed 且 BOOT 不计数",
	byte(0x12) == 0x00 and dev:reset_count() == 1 and dev:boot_count() == 2)

-- ---- reset_stuck：CTRL3 bit0 读恒 1（喂 10 拍轮询超时）----
section()
dev:set_reset_stuck(true)
check("POR 0 被卡死钩子强读为 0x01", byte(0x12) == 0x01)
dev.write({ 0x12, 0x44 })
check("卡死后落盘位保留、bit0 强叠 0x45", byte(0x12) == 0x45)
dev:clear_faults()
check("clear_faults 解除卡死读 0x44", byte(0x12) == 0x44)

-- ---- STATUS 动态合成 ----
section()
dev.write({ 0x10, 0x06 })
check("仅配 accel ODR：STATUS=0x01 XLDA", byte(0x1E) == 0x01)
dev.write({ 0x11, 0x06 })
check("双 ODR：STATUS=0x03 XLDA|GDA", byte(0x1E) == 0x03)

-- ---- 坏帧整笔 NACK 且不挪指针；读长度钳位 ----
section()
dev.write({ 0x60 })							-- 指针先放 0x60
check("空表写 NACK", dev.write({}) == false)
check("非表写 NACK", dev.write(nil) == false and dev.write(0x10) == false and dev.write("x") == false)
check("非字节写 NACK", dev.write({ 0x10, 256 }) == false and dev.write({ 0x10, "1" }) == false)
check("坏帧不挪读指针（仍 0x60）", dev:pointer() == 0x60, tostring(dev:pointer()))
check("坏帧不落盘", byte(0x10) == 0)
check("读 n 钳 1~16", #rd(0x0F, 0) == 1 and #rd(0x0F, 20) == 16)
check("无指针纯读 NACK", dev:reset() and dev.read(2) == nil)

-- ---- 故障钩子六类 + reset 保留钩子 ----
section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0x17 end)
check("fail_write 谓词只断 CTRL8 写",
	dev.write({ 0x17, 0x02 }) == false and dev.write({ 0x18, 0x02 }) == true)
dev:clear_faults()
dev:fail_read(function(p) return p == 0x0F end)
check("fail_read 谓词只断 WHO 读", rd(0x0F, 1) == nil and byte(0x17) == 0)
dev:clear_faults()
dev.nack_write = true
check("nack_write 全写断（含数据写）", dev.write({ 0x10, 0x00 }) == false)
dev.nack_write = false
dev.write({ 0x10 })
dev.nack = true
check("nack 全断（含指针写/读）", dev.write({ 0x10 }) == false and dev.read(1) == nil)
dev.nack = false
dev.nack_read = true
check("nack_read 全读断", dev.read(1) == nil)
dev.nack_read = false
check("reset 保留故障钩子（防负路径假解除）", (function()
	dev:fail_write(function(fr) return fr[1] == 0x12 and fr[2] == 0x01 end)
	dev:reset()
	return dev.write({ 0x12, 0x01 }) == false
end)())
dev:clear_faults()

-- ---- 物理量逆注入（按当前 fs 档灵敏度倒数反算 s16 码）----
section()
dev.write({ 0x17, 0x00 })					-- ±2g：0.061mg/LSB → 16393.4 LSB/g
dev:set_accel_g(1, -1, 0)
check("±2g 档 1g/-1g → ±16393",
	(select(1, dev:accel_raw())) == 16393 and (select(2, dev:accel_raw())) == -16393)
dev.write({ 0x17, 0x03 })					-- ±16g：0.488mg/LSB → 2049.2 LSB/g
dev:set_accel_g(1, 0, 0)
check("±16g 档 1g → 2049", (select(1, dev:accel_raw())) == 2049)
dev.write({ 0x15, 0x00 })					-- ±125dps：4.375mdps → 228.571 LSB/dps
dev:set_gyro_dps(10, 0, 0)
check("±125dps 档 10dps → 2286（量化 ±1）",
	math.abs((select(1, dev:gyro_raw())) - 2286) <= 1, tostring(select(1, dev:gyro_raw())))
dev.write({ 0x15, 0x0C })					-- ±4000dps：140mdps → 7.143 LSB/dps
dev:set_gyro_dps(100, 0, 0)
check("±4000dps 档 100dps → 714（0xC 码）",
	math.abs((select(1, dev:gyro_raw())) - 714) <= 1, tostring(select(1, dev:gyro_raw())))
dev.write({ 0x15, 0x05 })					-- 保留码：回退缺省 ±500dps 因子
dev:set_gyro_dps(100, 0, 0)
check("fs_g 保留码 5 按缺省 ±500dps 因子 → 5714",
	math.abs((select(1, dev:gyro_raw())) - 5714) <= 1, tostring(select(1, dev:gyro_raw())))

-- ---- virt_tick 码钉（32 拍确定性正弦，连续测量常驻）----
section()
dev.write({ 0x12, 0x04 })					-- IF_INC（burst 跨轴前提）
dev:virt_tick(0)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(0) acc 300/-200/4098 gyr 0/0/0",
		x == 300 and y == -200 and z == 4098 and rx == 0 and ry == 0 and rz == 0,
		table.concat({ x, y, z, rx, ry, rz }, ","))
end
do
	local a6 = rd(0x28, 6)
	check("tick(0) 加计小端（300=2C,01 / -200=38,FF / 4098=02,10）",
		a6[1] == 0x2C and a6[2] == 0x01 and a6[3] == 0x38 and a6[4] == 0xFF
		and a6[5] == 0x02 and a6[6] == 0x10, table.concat(a6, ","))
	local g6 = rd(0x22, 6)
	local okg = true
	for i = 1, 6 do if g6[i] ~= 0 then okg = false end end
	check("tick(0) 陀螺窗 6 字节全 0", okg)
end
dev:virt_tick(8)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(8) 峰点 acc 500/-350/4198 gyr 500/-400/300",
		x == 500 and y == -350 and z == 4198 and rx == 500 and ry == -400 and rz == 300,
		table.concat({ x, y, z, rx, ry, rz }, ","))
end
dev:virt_tick(24)
do
	local x, y, z = dev:accel_raw()
	local rx, ry, rz = dev:gyro_raw()
	check("tick(24) 谷点 acc 100/-50/3998 gyr -500/400/-300",
		x == 100 and y == -50 and z == 3998 and rx == -500 and ry == 400 and rz == -300,
		table.concat({ x, y, z, rx, ry, rz }, ","))
end
do
	local d2 = mm.new()
	d2:virt_tick(0)
	check("tick 确定性（两实例 n0 相同）", (select(1, d2:accel_raw())) == 300)
end
dev:reset()
check("reset 清注入码", (select(1, dev:accel_raw())) == 0)

-- ======================================================================
-- 组 2：真实 build（缺省 ±8g/±500dps/120Hz）
-- ======================================================================
local mark = section()
local cap
local oldprint = print
print = function(s) if type(s) == "string" and s:find("LSM6DSV16X init OK", 1, true) then cap = s end end
local r = expect_ok("build 默认（缺省 ±8g/±500dps/120Hz）",
	function() return build({ fd = fd, address = "0x6A" }) end)
print = oldprint
if r then
	check("build set_addr 留痕 0x6A 一次",
		#set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x6A)
	-- 睡眠：首拍轮询前 10ms + 收尾陀螺启动 100ms = 110ms（sw_reset 写即自清）
	check("build 睡眠 10+100=110ms", sleep_total == 110, tostring(sleep_total))
	check("睡眠序列恰两拍 10/100",
		#sleeps == 2 and sleeps[1] == 10 and sleeps[2] == 100,
		#sleeps .. " first=" .. tostring(sleeps[1]))
	local fs = frames(mark)
	check("build 恰好 6 笔数据写", #fs == 6, tostring(#fs))
	check("帧序 12-01/12-44/10-06/11-06/15-02/17-02",
		fs[1][1] == 0x12 and fs[1][2] == 0x01
		and fs[2][1] == 0x12 and fs[2][2] == 0x44
		and fs[3][1] == 0x10 and fs[3][2] == 0x06
		and fs[4][1] == 0x11 and fs[4][2] == 0x06
		and fs[5][1] == 0x15 and fs[5][2] == 0x02
		and fs[6][1] == 0x17 and fs[6][2] == 0x02,
		(function()
			local t = {}
			for _, f in ipairs(fs) do t[#t + 1] = hx(f[1]) .. "-" .. hx(f[2]) end
			return table.concat(t, "/")
		end)())
	-- 指针读：WHO + 复位前 CTRL3 + 1 轮询 + 复位后 CTRL3 + CTRL6 + CTRL8
	local pr = ptr_reads(mark)
	check("指针读共 6，序 0F/12/12/12/15/17 均 n=1（首拍轮询即自清）",
		#pr == 6
		and pr[1].p == 0x0F and pr[2].p == 0x12 and pr[3].p == 0x12
		and pr[4].p == 0x12 and pr[5].p == 0x15 and pr[6].p == 0x17,
		(function()
			local t = {}
			for _, e in ipairs(pr) do t[#t + 1] = hx(e.p) .. "x" .. e.n end
			return table.concat(t, ",")
		end)())
	check("CTRL3 读恰 3 次（复位前+1 轮询+置 BDU 前）", count_reads(mark, 0x12, 1) == 3)
	check("build 总线事务总数 19（set+6 写+6 对指针读）",
		#entries(mark) == 19, tostring(#entries(mark)))
	-- 落盘
	check("落盘 CTRL3=0x44（BDU|IF_INC，sw_reset 自清）", byte(0x12) == 0x44, hx(byte(0x12)))
	check("落盘 CTRL1=CTRL2=0x06（120Hz，op_mode=0）",
		byte(0x10) == 0x06 and byte(0x11) == 0x06, hx(byte(0x10)) .. "/" .. hx(byte(0x11)))
	check("落盘 CTRL6 fs_g=±500dps 码 2", byte(0x15) == 0x02, hx(byte(0x15)))
	check("落盘 CTRL8(0x17) fs_xl=±8g 码 2", byte(0x17) == 0x02, hx(byte(0x17)))
	-- **真机 bug 回归钉**：修复前量程码写到 0x18（CTRL9），0x17 永远 POR
	check("0x18(CTRL9) 恒 0——加计 fs 码落在 0x17 而非 0x18（REG_CTRL8 bug 回归）",
		byte(0x18) == 0x00, hx(byte(0x18)))
	check("build 后 STATUS=0x03（XLDA|GDA）", byte(0x1E) == 0x03)
	check("模型记录软复位 1 次", dev:reset_count() == 1)
	check("横幅文案", cap ~= nil
		and cap:find("LSM6DSV16X init OK: addr=0x6A, ±8g/±500dps, odr=120Hz", 1, true) ~= nil,
		tostring(cap))
end

-- ======================================================================
-- 组 3：列取档枚举（acc/gyr snap_down，odr 最近档平手取低）
-- ======================================================================
mark = section()
r = expect_ok("build range='3' gyro='600' odr='100'（降档+最近档）",
	function()
		return build({ fd = fd, address = "0x6A",
			range = "3", gyro_range = "600", odr = "100" })
	end)
if r then
	check("range 3 降档 ±2g 码 0", byte(0x17) % 4 == 0, hx(byte(0x17)))
	check("gyro 600 降档 ±500dps 码 2", byte(0x15) % 16 == 2, hx(byte(0x15)))
	check("odr 100 → 最近档 120Hz 码 6（平手取低不适用，120 更近）",
		byte(0x10) % 16 == 6 and byte(0x11) % 16 == 6)
end

section()
r = expect_ok("build gyro_range='4000' odr='10'（不连续码+向低最近档）",
	function() return build({ fd = fd, address = "0x6A", gyro_range = "4000", odr = "10" }) end)
if r then
	check("gyro 4000 → fs_g=0xC", byte(0x15) % 16 == 0x0C, hx(byte(0x15)))
	check("odr 10 → 7.5Hz 码 2", byte(0x10) % 16 == 0x02)
end

section()
r = expect_ok("build 满档 ±16g/±125dps/7680Hz",
	function()
		return build({ fd = fd, address = "0x6A",
			range = "16", gyro_range = "125", odr = "7680" })
	end)
if r then
	check("fs_xl=3（±16g）", byte(0x17) % 4 == 3)
	check("fs_g=0（±125dps）", byte(0x15) % 16 == 0)
	check("odr=0x0C（7680Hz）", byte(0x10) % 16 == 0x0C and byte(0x11) % 16 == 0x0C)
end

section()
r = expect_ok("build gyro='124'（无 ≤124 档→缺省 500）/ odr='-'",
	function() return build({ fd = fd, address = "0x6A", gyro_range = "124", odr = "-" }) end)
if r then
	check("124dps 落缺省 ±500 码 2", byte(0x15) % 16 == 2, hx(byte(0x15)))
	check("'-' odr 落缺省 120Hz 码 6", byte(0x10) % 16 == 6)
end

section()
r = expect_ok("build 全 '-' 列归缺省（±8g/±500/120Hz）",
	function()
		return build({ fd = fd, address = "0x6A",
			range = "-", gyro_range = "-", odr = "-" })
	end)
if r then
	check("缺省落盘 fs_xl=2/fs_g=2/odr=6",
		byte(0x17) % 4 == 2 and byte(0x15) % 16 == 2 and byte(0x10) % 16 == 6)
end

section()
r = expect_ok("build 非法/非正列值归缺省档",
	function()
		return build({ fd = fd, address = "0x6A",
			range = "abc", gyro_range = "", odr = "0" })
	end)
if r then
	check("非法值缺省 ±8g/±500/120Hz",
		byte(0x17) % 4 == 2 and byte(0x15) % 16 == 2 and byte(0x10) % 16 == 6)
end

-- ODR 平手取低：90 恰在 60/120 中点 → 码 5（60Hz）
section()
r = build({ fd = fd, address = "0x6A", odr = "90" })
check("odr=90 平手取低 60Hz 码 5", r.result == "OK" and byte(0x10) % 16 == 5, hx(byte(0x10)))

-- acc 边界档枚举
for _, spec in ipairs({ { "2", 0 }, { "4", 1 }, { "8", 2 }, { "16", 3 },
                        { "15", 2 }, { "100", 3 }, { "1", 2 }, { "-5", 2 } }) do
	section()
	r = build({ fd = fd, address = "0x6A", range = spec[1] })
	check(string.format("range=%s → fs_xl 码 %d", spec[1], spec[2]),
		r.result == "OK" and byte(0x17) % 4 == spec[2],
		"want " .. spec[2] .. " got " .. tostring(r and r.result))
end

-- gyro 全档枚举（含 4000→0xC）
for _, spec in ipairs({ { "125", 0x0 }, { "250", 0x1 }, { "500", 0x2 },
                        { "1000", 0x3 }, { "2000", 0x4 }, { "4000", 0xC } }) do
	section()
	r = build({ fd = fd, address = "0x6A", gyro_range = spec[1] })
	check(string.format("gyro_range=%s → fs_g 码 %X", spec[1], spec[2]),
		r.result == "OK" and byte(0x15) % 16 == spec[2],
		"want " .. spec[2] .. " got " .. tostring(r and r.result))
end

-- odr 抽样：7.5 精确档 / 3840 / 超界钳最高
for _, spec in ipairs({ { "7.5", 0x2 }, { "30", 0x4 }, { "960", 0x9 },
                        { "3840", 0xB }, { "10000", 0xC } }) do
	section()
	r = build({ fd = fd, address = "0x6A", odr = spec[1] })
	check(string.format("odr=%s → 码 %X", spec[1], spec[2]),
		r.result == "OK" and byte(0x10) % 16 == spec[2],
		"want " .. spec[2] .. " got " .. tostring(r and r.result))
end

-- 非缺省档横幅
section()
cap = nil
oldprint = print
print = function(s) if type(s) == "string" and s:find("LSM6DSV16X init OK", 1, true) then cap = s end end
r = build({ fd = fd, address = "0x6A", range = "16", gyro_range = "4000", odr = "7.5" })
print = oldprint
check("满档横幅 ±16g/±4000dps/odr=7.5Hz",
	r.result == "OK" and cap ~= nil
	and cap:find("±16g/±4000dps, odr=7.5Hz", 1, true) ~= nil, tostring(cap))

-- ======================================================================
-- 组 4：build 负路径
-- ======================================================================
section()
expect_err("build 非 table 参数", function() return build(0) end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x6A" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build fd=99 未打开", function() return build({ fd = 99, address = "0x6A" }) end,
	"set_addr failed")

-- 错地址 0x60：set_addr 成功，WHO 指针写即 NACK（无 r 事务）
mark = section()
expect_err("build 错地址 0x60（无挂载）",
	function() return build({ fd = fd, address = "0x60" }) end, "Failed to read LSM6DSV16X WHO_AM_I")
check("错地址仅 set+指针写 2 条（读事务不产生）",
	#entries(mark) == 2 and entries(mark)[1].dir == "set" and entries(mark)[2].dir == "w",
	tostring(#entries(mark)))

-- 家族 ID 甄别
section()
dev:who(0x6C)
expect_err("build WHO_AM_I=0x6C（LSM6DSO 系）",
	function() return build({ fd = fd, address = "0x6A" }) end, "WHO_AM_I = 0x6C")

-- 定向读失败
section()
dev:fail_read(function(p) return p == 0x0F end)
expect_err("build WHO_AM_I 读失败",
	function() return build({ fd = fd, address = "0x6A" }) end, "Failed to read LSM6DSV16X WHO_AM_I")

section()
dev:fail_read(function(p) return p == 0x12 end)
expect_err("build CTRL3 读失败（复位前）",
	function() return build({ fd = fd, address = "0x6A" }) end, "Failed to read LSM6DSV16X CTRL3")

section()
dev:fail_read(function(p) return p == 0x15 end)
expect_err("build CTRL6 读失败",
	function() return build({ fd = fd, address = "0x6A" }) end, "CTRL6/CTRL8")

section()
dev:fail_read(function(p) return p == 0x17 end)
expect_err("build CTRL8(0x17) 读失败",
	function() return build({ fd = fd, address = "0x6A" }) end, "CTRL6/CTRL8")

-- sw_reset 位卡死：10 拍 ×10ms 超时
mark = section()
dev:set_reset_stuck(true)
expect_err("build sw_reset 位卡死 → not completed",
	function() return build({ fd = fd, address = "0x6A" }) end, "soft reset not completed")
check("卡死实睡 10×10=100ms（不到收尾 100ms）", sleep_total == 100, tostring(sleep_total))
check("卡死睡眠恰 10 拍", #sleeps == 10)
check("CTRL3 读 11 次（复位前 1 + 轮询 10）", count_reads(mark, 0x12, 1) == 11,
	tostring(count_reads(mark, 0x12, 1)))
check("卡死路径事务 26 条（1set+WHO2+CTRL3×2+复位写1+10 对轮询）",
	#entries(mark) == 26, tostring(#entries(mark)))

-- 逐帧写失败短路点（正常序 19 条，失败写本身照记）
-- 序号：1 set / 2-3 WHO / 4-5 c3 前读 / 6 复位写 / 7-8 轮询 /
--       9-10 c3 后读 / 11 BDU写 / 12 CTRL1 / 13 CTRL2 /
--       14-15 c6 读 / 16-17 c8 读 / 18 CTRL6 写 / 19 CTRL8 写
local fail_points = {
	{ function(fr) return #fr == 2 and fr[1] == 0x12 and fr[2] == 0x01 end,
	  "soft reset", 6, 0 },
	{ function(fr) return #fr == 2 and fr[1] == 0x12 and fr[2] == 0x44 end,
	  "CTRL3 (BDU)", 11, 0x44 },
	{ function(fr) return #fr == 2 and fr[1] == 0x10 end,
	  "CTRL1 (accel ODR)", 12, nil },
	{ function(fr) return #fr == 2 and fr[1] == 0x11 end,
	  "CTRL2 (gyro ODR)", 13, nil },
	{ function(fr) return #fr == 2 and fr[1] == 0x15 and fr[2] == 0x02 end,
	  "CTRL6 (gyro FS)", 18, nil },
	{ function(fr) return #fr == 2 and fr[1] == 0x17 and fr[2] == 0x02 end,
	  "CTRL8 (accel FS)", 19, nil },
}
for _, spec in ipairs(fail_points) do
	mark = section()
	dev:fail_write(spec[1])
	expect_err("build 写短路：" .. spec[2],
		function() return build({ fd = fd, address = "0x6A" }) end, spec[2])
	check("短路点事务恰 " .. spec[3] .. " 条", #entries(mark) == spec[3],
		tostring(#entries(mark)) .. " want " .. spec[3])
end
-- 短路副作用抽查
section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0x12 and fr[2] == 0x01 end)
build({ fd = fd, address = "0x6A" })
check("复位写失败：模型无复位记录", dev:reset_count() == 0)
section()
dev:fail_write(function(fr) return #fr == 2 and fr[1] == 0x10 end)
build({ fd = fd, address = "0x6A" })
check("CTRL1 写失败：CTRL3=0x44 已落、CTRL1 仍 0",
	byte(0x12) == 0x44 and byte(0x10) == 0x00)

-- 器件全程 NACK：首笔 WHO 指针写即败
section()
dev.nack = true
expect_err("build 器件无应答",
	function() return build({ fd = fd, address = "0x6A" }) end, "WHO_AM_I")

-- ======================================================================
-- 组 5：真实 call（六轴小端，陀螺窗在前）
-- ======================================================================
section()
r = expect_ok("build（call 前置）", function() return build({ fd = fd, address = "0x6A" }) end)
-- 小端预置：GYRO X=0x1000(4096) / Y=0xFFFF(-1) / Z=0；
-- ACCEL X=0xFC00(-1024 补码语义) / Y/Z=0
dev:set_gyro_raw(4096, -1, 0)
dev:set_accel_raw(-1024, 0, 0)
mark = #vbus.txlog
local sleep_base = sleep_total
r = expect_ok("call 六轴读值", function() return call({ fd = fd, address = "0x6A" }) end)
if r then
	check("GYRO_X=0x1000（LSB 在前）", r.GYRO_X == 4096, tostring(r.GYRO_X))
	check("GYRO_Y=0xFFFF 原始码不转负", r.GYRO_Y == 65535, tostring(r.GYRO_Y))
	check("GYRO_Z=0", r.GYRO_Z == 0)
	check("ACCEL_X=0xFC00 原始码（-1024 补码语义）", r.ACCEL_X == 64512, tostring(r.ACCEL_X))
	check("ACCEL_Y/Z=0", r.ACCEL_Y == 0 and r.ACCEL_Z == 0)
	local pr = ptr_reads(mark)
	check("call 恰两次指针读 0x22×6(陀螺在前) → 0x28×6",
		#pr == 2 and pr[1].p == 0x22 and pr[1].n == 6 and pr[2].p == 0x28 and pr[2].n == 6,
		(function()
			local t = {}
			for _, e in ipairs(pr) do t[#t + 1] = string.format("%02X×%d", e.p, e.n) end
			return table.concat(t, ",")
		end)())
	check("call 零睡眠", sleep_total - sleep_base == 0, tostring(sleep_total - sleep_base))
	check("call set_addr 一次 / 总事务 5（set+2 指针写+2 读）",
		#set_addrs(mark) == 1 and #entries(mark) == 5, tostring(#entries(mark)))
	check("call 无 ≥2B 数据写", #frames(mark) == 0, tostring(#frames(mark)))
end

-- 连续三拍 tick 闭环：数据常驻，每拍都是干净的 5 事务窗
for _, spec in ipairs({ { 0, 300, -200, 4098, 0, 0, 0 },
                        { 8, 500, -350, 4198, 500, -400, 300 },
                        { 24, 100, -50, 3998, -500, 400, -300 } }) do
	dev:virt_tick(spec[1])
	mark = #vbus.txlog
	r = call({ fd = fd, address = "0x6A" })
	check(string.format("tick(%d) call 六轴无符号码 = 模型 s16 展开", spec[1]),
		r.result == "OK"
		and r.ACCEL_X == u16(spec[2]) and r.ACCEL_Y == u16(spec[3]) and r.ACCEL_Z == u16(spec[4])
		and r.GYRO_X == u16(spec[5]) and r.GYRO_Y == u16(spec[6]) and r.GYRO_Z == u16(spec[7])
		and #entries(mark) == 5,
		table.concat({ r.ACCEL_X, r.ACCEL_Y, r.ACCEL_Z, r.GYRO_X, r.GYRO_Y, r.GYRO_Z }, ","))
end

-- ======================================================================
-- 组 6：call 负路径
-- ======================================================================
section()
expect_err("call 非 table 参数", function() return call(3) end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x6A" }) end, "fd or address")
expect_err("call fd=99", function() return call({ fd = 99, address = "0x6A" }) end,
	"set_addr failed")

mark = section()
expect_err("call 错地址 0x60（陀螺指针写 NACK）",
	function() return call({ fd = fd, address = "0x60" }) end, "gyro data")
check("错地址仅 set+指针写 2 条", #entries(mark) == 2, tostring(#entries(mark)))

section()
build({ fd = fd, address = "0x6A" })
dev:fail_read(function(p) return p == 0x22 end)
mark = #vbus.txlog
expect_err("call 陀螺读失败",
	function() return call({ fd = fd, address = "0x6A" }) end, "gyro data")
check("陀螺失败窗 set+指针写+空读 共 3 条", #entries(mark) == 3, tostring(#entries(mark)))

section()
build({ fd = fd, address = "0x6A" })
dev:fail_read(function(p) return p == 0x28 end)
mark = #vbus.txlog
expect_err("call 加计读失败（陀螺已成功）",
	function() return call({ fd = fd, address = "0x6A" }) end, "accel data")
check("加计失败窗 set+陀螺 2 事务+加计指针写 共 5 条（无加计 r）",
	#entries(mark) == 5, tostring(#entries(mark)))

-- ======================================================================
-- 组 7：destroy
-- ======================================================================
mark = section()
expect_ok("destroy 无资源需释放", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0, tostring(#entries(mark)))
expect_err("destroy 非 table 参数", function() return destroy(nil) end, "Invalid Arguments Type")

tester.summary("test_lsm6dsv")

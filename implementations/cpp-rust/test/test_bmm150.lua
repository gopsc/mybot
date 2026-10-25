-- test_bmm150.lua —— BMM150 真实驱动 + 虚拟 I2C 总线 + 地磁模型
-- 用法（项目根目录）: luajit test/test_bmm150.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：BMM_GC=1 luajit test/test_bmm150.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + 内嵌模型（modules/BMM150.lua 尾部 BMM150_VIRT，2026-09-15
-- 自 virtbus/bmm150.lua 迁入）」。本器件是 virtbus 库【8 位字节指针 +
-- 上电挂起态电源门 + 三段工厂 trim NVM + XY/Z 异构 13/15 位数据块】样板
-- （Bosch BMM150，地址族 0x10~0x13）：
--   复位后 suspend：仅 0x4B 可访问，CHIP_ID/trim/数据挂起态读 0x00，写
--   {0x4B,0x01} 上电后可读（CHIP_ID=0x32），驱动实睡 3ms；0x4B bit7 软
--   复位自清、易失内容丢失而 trim NVM/CHIP_ID ROM 保留。trim 16B 三段
--   0x5Dx2/0x62x4/0x68x10，0x6D bit7 保留读 0；数据 0x42 起 8B：XY 13
--   位有符号（-4096 溢出哨兵）、Z 15 位（-16384 哨兵）、RHALL 14 位无
--   符号；测量区只读。normal 连续出数无就绪握手，virt_tick 直装数据块。
--
-- 覆盖：模型侧挂起态电源门（CHIP_ID/trim 读 0、挂起写丢弃、下电丢内容）、
-- 软复位自清与 NVM/ROM 保留、trim 三段字节独立编码交叉（含 s8/s16/u16/
-- 0x6D 掩码/dig_xy1 无符号）、XY/Z/RHALL 位域独立 enc/dec 交叉与满码钳制、
-- burst 自增/0xFF 回绕/n 钳 16/无指针纯读 NACK、ODR 八档/mode 位、坏帧、
-- 六类钩子与 reset 保留、virt_tick 32 拍原始码；真实 build 13 事务序列
-- （Power→睡3→ID→三段 trim→REP_XY/REP_Z/OP_MODE）与四 preset 常量、
-- ID 不符/trim 读失败/各写失败短路/参数负路径；真实 call 3 事务零睡眠，
-- Bosch C 黄金向量 A/B/B2/C 精确复现（溢出轴 nil、RHALL=0 回退路径）、
-- virt_tick 闭环、未 build 守卫；destroy 零总线事务。

if os.getenv("BMM_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x10

-- 模型内嵌于驱动文件（BMM150_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/BMM150.lua")
local smod = BMM150_VIRT

local dev = smod.new()
local smod = BMM150_VIRT

local dev = smod.new()
vbus.attach("BMM150@0x10", ADDR, dev)
vbus.attach("BMM150@0x11", 0x11, dev)	-- SDO/CSB 引脚组合的另一常见地址

-- BMM150 无转换门：milli_sleep 只累计（build 实睡 3ms）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用，保留 trim 缓存与活动态）
local function window() return #vbus.txlog end

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
local function reg_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 2 then t[#t + 1] = { b[1], b[2] } end
	end
	return t
end
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
local function read_sizes(mark)
	local t = {}
	for _, e in ipairs(entries(mark)) do
		if e.dir == "r" then t[#t + 1] = e.bytes.n end
	end
	return t
end
local function nset(mark)
	local n = 0
	for _, e in ipairs(entries(mark)) do if e.dir == "set" then n = n + 1 end end
	return n
end
local function nwr(mark) return #reg_writes(mark) end
local function npt(mark) return #ptr_writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

-- 帧前缀谓词（sig 是前缀；sig {0xFE} 类短签名须能命中驱动长帧）
local function frame_prefix(sig)
	return function(b)
		if #b < #sig then return false end
		for i = 1, #sig do if b[i] ~= sig[i] then return false end end
		return true
	end
end
local function read_at(ptr)
	return function(p, n) return p == ptr end
end
local function hx(v) return string.format("0x%02X", v or 0) end
local function byte_eq(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- HAL 快捷
local function rreg(reg) return i2c_read_reg(fd, reg) end
local function rbytes(reg, n) return i2c_read_multi_bytes(fd, reg, n) end

-- ==================== 测试侧独立编解码（不看模型实现，纯 floor/%） ====================
-- X/Y 13 位：LSB 低 5 位<<3，MSB=floor(v/32)
local function enc13(v)
	return (v % 32) * 8, math.floor(v / 32) % 256
end
-- Z 15 位：LSB 低 7 位<<1，MSB=floor(v/128)
local function enc13z(v)
	return (v % 128) * 2, math.floor(v / 128) % 256
end
-- RHALL 14 位无符号
local function enc14(r)
	return (r % 64) * 4, math.floor(r / 64) % 256
end
-- trim 表 → 三段字节（与驱动 read_trim 的拼装严格同源、独立书写）
local function trim_segments(t)
	return {
		{ t.dig_x1 % 256, t.dig_y1 % 256 },
		{ t.dig_z4 % 256, math.floor(t.dig_z4 / 256) % 256, t.dig_x2 % 256, t.dig_y2 % 256 },
		{ t.dig_z2 % 256, math.floor(t.dig_z2 / 256) % 256,
			t.dig_z1 % 256, math.floor(t.dig_z1 / 256) % 256,
			t.dig_xyz1 % 256, math.floor(t.dig_xyz1 / 256) % 128,
			t.dig_z3 % 256, math.floor(t.dig_z3 / 256) % 256,
			t.dig_xy2 % 256, t.dig_xy1 % 256 },
	}
end

-- Bosch C 黄金向量（test_bmm150_golden.c 生成，旧桩沿用）
local trimA = { dig_x1 = -32, dig_y1 = -3, dig_x2 = -25, dig_y2 = 250,
	dig_z1 = 400, dig_z2 = 100, dig_z3 = -250, dig_z4 = 200,
	dig_xy1 = 137, dig_xy2 = 57, dig_xyz1 = 7920 }
local trimB = { dig_x1 = 0, dig_y1 = 0, dig_x2 = 0, dig_y2 = 0,
	dig_z1 = 100, dig_z2 = 100, dig_z3 = 0, dig_z4 = 100,
	dig_xy1 = 0, dig_xy2 = 0, dig_xyz1 = 500 }

local function build_ok(opts)
	opts = opts or {}
	opts.fd = fd
	if opts.address == nil then opts.address = "0x10" end
	local r = build(opts)
	check("build OK", r.result == "OK", tostring(r.message))
	return r
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点模型 API / 经 HAL）
-- =====================================================================
local mark = section()

-- ---- POR：挂起态 ----
check("POR 挂起态 powered=false", dev:powered() == false)
check("POR 0x4B=0x00", dev:reg(0x4B) == 0x00)
check("POR 内部 CHIP_ID 身份=0x32（ROM）", dev:chip_id() == 0x32)
check("POR OP_MODE/REP 不播种读 0", dev:op_mode() == 0 and dev:rep_xy() == 0 and dev:rep_z() == 0)
check("POR 数据块全 0", dev:x_raw() == 0 and dev:y_raw() == 0 and dev:z_raw() == 0 and dev:rhall() == 0)
check("POR reset_count/write_count=0", dev:reset_count() == 0 and dev:write_count() == 0)
check("POR 读指针 nil", dev:ptr() == nil)

-- ---- 挂起态：仅 0x4B 可访问，其余读 0x00（datasheet §4.2.2）----
i2c_set_addr(fd, ADDR)
check("挂起态 CHIP_ID 读 0x00", rreg(0x40) == 0)
check("挂起态读 CHIP_ID 留 ptr+r 两事务", npt(mark) == 1 and nrd(mark) == 1)
mark = window()
check("挂起态 trim 段1 读 0,0", byte_eq(rbytes(0x5D, 2), { 0, 0 }))
check("挂起态 trim 段2 读 4 个 0", byte_eq(rbytes(0x62, 4), { 0, 0, 0, 0 }))
check("挂起态 trim 段3 读 10 个 0", byte_eq(rbytes(0x68, 10), { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }))
check("挂起态数据块读 8 个 0", byte_eq(rbytes(0x42, 8), { 0, 0, 0, 0, 0, 0, 0, 0 }))
check("挂起态 0x4B 自身可读=0", rreg(0x4B) == 0)
-- 挂起态写其他寄存器 ACK 但丢弃
check("挂起态写 OP_MODE ACK", i2c_write_reg(fd, 0x4C, 0x28) == true)
check("挂起态写 OP_MODE 被丢弃", dev:op_mode() == 0)

-- ---- 上电 ----
mark = section()
check("写 Power ON 成功", i2c_write_reg(fd, 0x4B, 0x01) == true)
check("上电后 powered=true", dev:powered() == true)
check("0x4B 落盘 0x01", dev:reg(0x4B) == 0x01)
check("上电后 CHIP_ID=0x32", rreg(0x40) == 0x32)

-- ---- 默认工厂 trim 三段字节独立交叉 ----
do
	local seg = trim_segments(dev:trim())
	check("默认 trim 段1 字节", byte_eq(rbytes(0x5D, 2), seg[1]))
	check("默认 trim 段2 字节", byte_eq(rbytes(0x62, 4), seg[2]))
	check("默认 trim 段3 字节", byte_eq(rbytes(0x68, 10), seg[3]))
	-- 段3 具体值（z2=4000/z1=30000/xyz1=7920）
	check("默认 trim 段3 具体值", byte_eq(rbytes(0x68, 10),
		{ 160, 15, 48, 117, 240, 30, 0, 0, 57, 137 }))
	-- 0x6D=dig_xyz1 高字节，bit7 保留读 0
	check("0x6D 高字节=30（7920>>8）", dev:reg(0x6D) == 30 and rreg(0x6D) == 30)
end
-- 覆写 xyz1 验证 %0x7F 掩码
dev:set_trim({ dig_xyz1 = 32767 })
check("xyz1=32767 高字节 127（bit7 读 0）", rreg(0x6D) == 127)
dev:set_trim({ dig_xyz1 = 0 })
check("xyz1=0 高字节 0", rreg(0x6D) == 0)
dev:set_trim(trimA)	-- 后续用 trimA

-- ---- trimA / trimB 全字节独立交叉 ----
do
	local seg = trim_segments(trimA)
	check("trimA 段1=224,253", byte_eq(rbytes(0x5D, 2), seg[1]) and byte_eq(seg[1], { 224, 253 }))
	check("trimA 段2=200,0,231,250", byte_eq(rbytes(0x62, 4), seg[2]) and byte_eq(seg[2], { 200, 0, 231, 250 }))
	check("trimA 段3", byte_eq(rbytes(0x68, 10), seg[3]) and byte_eq(seg[3],
		{ 100, 0, 144, 1, 240, 30, 6, 255, 57, 137 }))
end
dev:set_trim(trimB)
do
	local seg = trim_segments(trimB)
	check("trimB 段1=0,0", byte_eq(rbytes(0x5D, 2), { 0, 0 }) and byte_eq(seg[1], { 0, 0 }))
	check("trimB 段2=100,0,0,0", byte_eq(rbytes(0x62, 4), seg[2]) and byte_eq(seg[2], { 100, 0, 0, 0 }))
	check("trimB 段3=100,0,100,0,244,1,0,0,0,0", byte_eq(rbytes(0x68, 10), seg[3])
		and byte_eq(seg[3], { 100, 0, 100, 0, 244, 1, 0, 0, 0, 0 }))
end

-- ---- 只读区写 ACK 丢弃 ----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)
check("写 CHIP_ID ACK 丢弃", i2c_write_reg(fd, 0x40, 0x99) == true and rreg(0x40) == 0x32)
check("写数据字节 ACK 丢弃", i2c_write_reg(fd, 0x43, 0x7F) == true and dev:x_raw() == 0)
check("写 trim NVM ACK 丢弃", i2c_write_reg(fd, 0x5D, 0x12) == true
	and rbytes(0x5D, 1)[1] == (dev:trim().dig_x1 % 256))

-- ---- 下电丢内容、重新上电 trim NVM 仍在 ----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)
i2c_write_reg(fd, 0x4C, 0x28)
dev:set_data(-200, 100, -450, 512)
check("配置/数据上电态可读", dev:op_mode() == 0x28 and dev:x_raw() == -200)
i2c_write_reg(fd, 0x4B, 0x00)	-- 回挂起
check("下电后 powered=false", dev:powered() == false)
check("下电后 CHIP_ID 读 0", rreg(0x40) == 0)
i2c_write_reg(fd, 0x4B, 0x01)	-- 重新上电
check("重新上电后 OP_MODE 丢失=0", dev:op_mode() == 0)
check("重新上电后数据丢失=0", dev:x_raw() == 0)
check("重新上电后 trim NVM 仍在（段1=224,253）", byte_eq(rbytes(0x5D, 2), { 224, 253 }))

-- ---- 软复位：bit7 自清、易失丢失、NVM/ROM 保留 ----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)
i2c_write_reg(fd, 0x4C, 0x28)
dev:set_data(-200, 100, -450, 512)
dev:who(0x33)
check("软复位 ACK", i2c_write_reg(fd, 0x4B, 0x81) == true)
check("软复位 bit7 自清落 0x01", dev:reg(0x4B) == 0x01)
check("软复位计数=1", dev:reset_count() == 1)
check("软复位后 powered=true（同帧 bit0）", dev:powered() == true)
check("软复位后 OP_MODE 丢失", dev:op_mode() == 0)
check("软复位后数据丢失全 0", dev:x_raw() == 0 and dev:rhall() == 0)
check("软复位后读指针清空", dev:ptr() == nil)
check("软复位后 trim NVM 保留", byte_eq(rbytes(0x5D, 2), { 224, 253 }))
check("软复位后 CHIP_ID ROM 覆写保留=0x33", rreg(0x40) == 0x33)
-- Bosch API 软复位魔数 0x83：bit7 自清、bit1/bit0 照落
i2c_write_reg(fd, 0x4B, 0x83)
check("0x83 软复位落低 7 位 0x03", dev:reg(0x4B) == 0x03 and dev:powered() == true)
check("连续软复位计数=2", dev:reset_count() == 2)

-- ---- XY/Z/RHALL 位域编解码（独立 enc 公式交叉）----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)	-- section 回挂起态，先上电数据区才有效
local function check_frame(x, y, z, r, label)
	dev:set_data(x, y, z, r)
	local xl, xh = enc13(x)
	local yl, yh = enc13(y)
	local zl, zh = enc13z(z)
	local rl, rh = enc14(r)
	local got = rbytes(0x42, 8)
	check(label .. " 8B 位域", byte_eq(got, { xl, xh, yl, yh, zl, zh, rl, rh }),
		table.concat(got, ","))
	check(label .. " 观察口回读", dev:x_raw() == x and dev:y_raw() == y
		and dev:z_raw() == z and dev:rhall() == r,
		string.format("%d,%d,%d,%d", dev:x_raw(), dev:y_raw(), dev:z_raw(), dev:rhall()))
end
check_frame(0, 0, 0, 0, "零点")
check_frame(-200, 100, -450, 512, "黄金 A")
check_frame(4095, 4095, 16383, 16383, "正满码")
check_frame(-4096, -4096, -16384, 1, "负满码/哨兵")
check_frame(1, -1, 1, 0, "±1 LSB")
-- 钳制
dev:set_data(99999, -99999, 99999, 99999)
check("正超程钳 4095/-4096/16383/16383", dev:x_raw() == 4095 and dev:y_raw() == -4096
	and dev:z_raw() == 16383 and dev:rhall() == 16383)
dev:set_data(-99999, 99999, -99999, -5)
check("负超程钳 -4096/4095/-16384/0", dev:x_raw() == -4096 and dev:y_raw() == 4095
	and dev:z_raw() == -16384 and dev:rhall() == 0)
-- 分轴 setter 互不干扰
dev:set_data(1, 2, 3, 4)
dev:set_x_raw(-200)
check("set_x_raw 只改 X", dev:x_raw() == -200 and dev:y_raw() == 2 and dev:z_raw() == 3 and dev:rhall() == 4)
dev:set_y_raw(100)
dev:set_z_raw(-450)
dev:set_rhall(512)
check("set_y/z/rhall 独立", dev:y_raw() == 100 and dev:z_raw() == -450 and dev:rhall() == 512)

-- ---- burst 自增 / 0xFF 回绕 / n 钳 16 / 无指针纯读 NACK ----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)
dev:set_data(-200, 100, -450, 512)
local full = rbytes(0x42, 8)
check("8B burst 读完指针=0x4A", dev:ptr() == 0x4A)
local mid = rbytes(0x44, 3)
check("中段 burst 从 Y_LSB 起 3B", byte_eq(mid, { full[3], full[4], full[5] }) and dev:ptr() == 0x47)
local wrap = rbytes(0xFF, 2)
check("0xFF burst 回绕 0x00（2B 不 NACK）", #wrap == 2 and dev:ptr() == 0x01)
local clamped = rbytes(0x42, 99)
check("读长度钳 16", #clamped == 16)
section()
check("无指针纯读 NACK（nil）", i2c_read_bytes(fd, 3) == nil)

-- ---- ODR 八档 + mode 位 ----
mark = section()
i2c_write_reg(fd, 0x4B, 0x01)
local ODR_WANT = { 10, 2, 6, 8, 15, 20, 25, 30 }
for code = 0, 7 do
	i2c_write_reg(fd, 0x4C, code * 8)
	check("ODR 码 " .. code .. "=" .. ODR_WANT[code + 1] .. "Hz",
		dev:odr_code() == code and dev:odr_hz() == ODR_WANT[code + 1],
		tostring(dev:odr_hz()))
end
i2c_write_reg(fd, 0x4C, 0x02)	-- bit[2:1]=01 forced
check("OP_MODE bit[2:1]=1 forced 观察口", dev:mode_code() == 1 and dev:odr_code() == 0)
i2c_write_reg(fd, 0x4C, 0x28)	-- 20Hz normal
check("0x28 解析=码5/20Hz/normal", dev:odr_code() == 5 and dev:odr_hz() == 20 and dev:mode_code() == 0)

-- ---- 坏帧 NACK ----
mark = section()
check("write(nil) NACK", dev.write(nil) == false)
check("write(字符串) NACK", dev.write("0x4B") == false)
check("write(空表) NACK", dev.write({}) == false)
check("write 非字节值 NACK", dev.write({ 0x4B, 300 }) == false)
check("write 指针超 0xFF NACK", dev.write({ 0x100 }) == false)
check("坏帧不增 write_count", dev:write_count() == 0)
check("1B 纯指针任意地址 ACK", dev.write({ 0x10 }) == true and dev:ptr() == 0x10)

-- ---- 留痕计数 ----
section()
i2c_write_reg(fd, 0x51, 0x04)
i2c_write_reg(fd, 0x52, 0x07)
check("两笔 ≥2B 写 write_count=2", dev:write_count() == 2)
check("write_log 记首地址", dev:writes()[1].reg == 0x51 and dev:writes()[2].reg == 0x52)
dev:reset_logs()
check("reset_logs 清零", dev:write_count() == 0 and #dev:writes() == 0)

-- ---- 六类钩子 + reset 保留 ----
mark = section()
dev.nack = true
check("nack 写失败", i2c_write_reg(fd, 0x4B, 0x01) == false)
check("nack 读失败", rreg(0x40) == -1)
dev.nack = false
dev.nack_write = true
check("nack_write 只拦写", i2c_write_reg(fd, 0x4C, 0x00) == false)
dev.nack_write = false
dev.nack_read = true
check("nack_read 只拦读", rreg(0x40) == -1)
dev.nack_read = false
dev:fail_write(frame_prefix({ 0x4C }))
check("fail_write 谓词拦 OP_MODE", i2c_write_reg(fd, 0x4C, 0x28) == false)
check("fail_write 不误伤 0x4B", i2c_write_reg(fd, 0x4B, 0x01) == true)
dev:fail_read(read_at(0x40))
check("fail_read 谓词拦 0x40", rreg(0x40) == -1)
check("fail_read 放行 0x4B", rreg(0x4B) == 0x01)
check("reset 保留故障钩子", (function()
	dev:fail_write(frame_prefix({ 0x4B }))
	dev:reset()
	return i2c_write_reg(fd, 0x4B, 0x01) == false
end)())
dev:clear_faults()
check("clear_faults 解除", i2c_write_reg(fd, 0x4B, 0x01) == true)

-- ---- virt_tick 32 拍原始码 ----
mark = section()
dev:virt_tick(0)
check("tick0 原始码 249/22/-54/512", dev:x_raw() == 249 and dev:y_raw() == 22
	and dev:z_raw() == -54 and dev:rhall() == 512)
dev:virt_tick(8)
check("tick8 原始码 357/-54/-93", dev:x_raw() == 357 and dev:y_raw() == -54 and dev:z_raw() == -93)
dev:virt_tick(16)
check("tick16 原始码 249/-125/-133", dev:x_raw() == 249 and dev:y_raw() == -125 and dev:z_raw() == -133)
dev:virt_tick(24)
check("tick24 原始码 141/-54/-93", dev:x_raw() == 141 and dev:y_raw() == -54 and dev:z_raw() == -93)
dev:virt_tick(32)
check("tick32 周期回 tick0", dev:x_raw() == 249 and dev:y_raw() == 22 and dev:z_raw() == -54)

-- =====================================================================
-- 组 2：真实 build（上电序列 + ID + trim + preset）
-- =====================================================================
-- 默认 regular，13 txlog 精确序列：
--   set / w{4B,01} / w{40}·r1 / w{5D}·r2 / w{62}·r4 / w{68}·r10
--   / w{51} / w{52} / w{4C}
-- = 1 set + 8 w（4 笔 2B 寄存器写 + 4 笔 1B 指针写）+ 4 r
local function assert_build_sequence(label, want_rxy, want_rz, want_op)
	local m0 = section()
	sleep_total = 0
	build_ok()
	check(label .. " 共 13 条事务", #entries(m0) == 13, tostring(#entries(m0)))
	check(label .. " 1 set", nset(m0) == 1)
	check(label .. " 8 条写目录（4 寄存器写 + 4 指针写）", #writes(m0) == 8)
	check(label .. " 4 条 2B 寄存器写", nwr(m0) == 4)
	check(label .. " 4 条 1B 指针写", npt(m0) == 4)
	check(label .. " 指针序 0x40/0x5D/0x62/0x68",
		table.concat(ptr_writes(m0), ",") == "64,93,98,104")
	check(label .. " 读长度序 1/2/4/10", table.concat(read_sizes(m0), ",") == "1,2,4,10")
	local rw = reg_writes(m0)
	check(label .. " 首写 {4B,01} Power", rw[1][1] == 0x4B and rw[1][2] == 0x01, hx(rw[1][1]))
	check(label .. " REP_XY=" .. want_rxy, rw[2][1] == 0x51 and rw[2][2] == want_rxy)
	check(label .. " REP_Z=" .. want_rz, rw[3][1] == 0x52 and rw[3][2] == want_rz)
	check(label .. " OP_MODE=" .. hx(want_op), rw[4][1] == 0x4C and rw[4][2] == want_op, hx(rw[4][2]))
	check(label .. " 实睡 3ms", sleep_total == 3, tostring(sleep_total))
end
assert_build_sequence("regular", 0x04, 0x07, 0x00)

-- 四个 preset 配置常量（PRESETS 表）
local PRESET_CASES = {
	{ "lowpower", 0x01, 0x01, 0x00, 10 },
	{ "regular", 0x04, 0x07, 0x00, 10 },
	{ "enhanced", 0x07, 0x0D, 0x00, 10 },
	{ "highaccuracy", 0x17, 0x29, 0x28, 20 },
}
for _, c in ipairs(PRESET_CASES) do
	local m0 = section()
	build_ok({ preset = c[1] })
	local rw = reg_writes(m0)
	check("preset " .. c[1] .. " REP_XY=" .. c[2], rw[2][2] == c[2], tostring(rw[2][2]))
	check("preset " .. c[1] .. " REP_Z=" .. c[3], rw[3][2] == c[3], tostring(rw[3][2]))
	check("preset " .. c[1] .. " OP_MODE=" .. hx(c[4]) .. " " .. c[5] .. "Hz",
		rw[4][2] == c[4] and dev:odr_hz() == c[5])
end
-- '-' 缺省落 regular
do
	local m0 = section()
	build_ok({ preset = "-" })
	local rw = reg_writes(m0)
	check("preset '-' 缺省 regular 4/7/00", rw[2][2] == 0x04 and rw[3][2] == 0x07 and rw[4][2] == 0x00)
end

-- 备用地址 0x11
do
	local m0 = section()
	build_ok({ address = "0x11" })
	check("备地址 0x11 build 13 事务", #entries(m0) == 13)
	local addrs = {}
	for _, e in ipairs(entries(m0)) do if e.addr then addrs[#addrs + 1] = e.addr end end
	check("事务全部走 0x11", addrs[1] == 0x11 and addrs[#addrs] == 0x11, hx(addrs[1]))
end

-- ---- build 负路径 ----
mark = section()
expect_err("build 非表", function() return build(nil) end, "Invalid Arguments Type")
check("非表零事务", #entries(mark) == 0)

mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x10" }) end, "fd or address")
check("缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
check("缺 address 零事务", #entries(mark) == 0)

mark = section()
expect_err("build fd=99", function() return build({ fd = 99, address = "0x10" }) end, "set_addr failed")
check("fd=99 set 在留痕前失败零事务", #entries(mark) == 0)

mark = section()
expect_err("build addr=0x80 超 0x7F", function() return build({ fd = fd, address = "0x80" }) end, "set_addr failed")
check("0x80 零事务", #entries(mark) == 0)

mark = section()
expect_err("build 非法 preset", function()
	return build({ fd = fd, address = "0x10", preset = "turbo" })
end, "Invalid preset")
-- preset 校验在 i2c_pair 之后：有 1 条 set、无写
check("非法 preset 1 set 零写", nset(mark) == 1 and nwr(mark) == 0 and #writes(mark) == 0)

mark = section()
expect_err("build 错地址 0x60（未挂载）", function() return build({ fd = fd, address = "0x60" }) end, "Failed to power on")
check("0x60 = 1 set + 1 w NACK", #entries(mark) == 2 and nset(mark) == 1 and nwr(mark) == 1)

mark = section()
dev:who(0x31)
expect_err("build CHIP_ID 不符", function() return build({ fd = fd, address = "0x10" }) end, "CHIP_ID")
check("ID 不符短路在 4 事务（set+w+ptr+r）", #entries(mark) == 4 and nrd(mark) == 1)

mark = section()
dev:fail_read(read_at(0x40))
expect_err("build CHIP_ID 读失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 CHIP_ID")
check("ID 读失败 4 事务（fail_read 也留 r 痕）", #entries(mark) == 4 and nrd(mark) == 1)
dev:clear_faults()

mark = section()
dev:fail_read(read_at(0x5D))
expect_err("build trim 段1 读失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 trim")
check("trim1 失败 6 事务", #entries(mark) == 6 and nrd(mark) == 2)
dev:clear_faults()

mark = section()
dev:fail_read(read_at(0x62))
expect_err("build trim 段2 读失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 trim")
check("trim2 失败 8 事务", #entries(mark) == 8 and nrd(mark) == 3)
dev:clear_faults()

mark = section()
dev:fail_read(read_at(0x68))
expect_err("build trim 段3 读失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 trim")
check("trim3 失败 10 事务", #entries(mark) == 10 and nrd(mark) == 4)
dev:clear_faults()

mark = section()
dev:fail_write(frame_prefix({ 0x4B, 0x01 }))
expect_err("build Power 写失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to power on")
check("Power 失败 2 事务", #entries(mark) == 2)
dev:clear_faults()

mark = section()
dev:fail_write(frame_prefix({ 0x51 }))
expect_err("build REP_XY 写失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to write BMM150 REP_XY")
-- set1 + Power1 + ID2 + trim6 = 10，再 1 笔失败的 REP_XY 写 = 11
check("REP_XY 失败 11 事务（含失败 2B 写）", #entries(mark) == 11 and nwr(mark) == 2)
dev:clear_faults()

mark = section()
dev:fail_write(frame_prefix({ 0x52 }))
expect_err("build REP_Z 写失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to write BMM150 REP_Z")
check("REP_Z 失败 12 事务（含失败 2B 写）", #entries(mark) == 12 and nwr(mark) == 3)
dev:clear_faults()

mark = section()
dev:fail_write(frame_prefix({ 0x4C }))
expect_err("build OP_MODE 写失败", function() return build({ fd = fd, address = "0x10" }) end, "Failed to write BMM150 OP_MODE")
check("OP_MODE 失败 13 事务（含失败 2B 写）", #entries(mark) == 13 and nwr(mark) == 4)
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call（8B 原子读 + Bosch 补偿 + 黄金向量）
-- =====================================================================
-- 黄金向量公共流程：section → 装 trim/数据 → build（驱动缓存 trim）→ call
local function golden(label, t, x, y, z, r, wantX, wantY, wantZ)
	local m0 = section()
	dev:set_trim(t)
	dev:set_data(x, y, z, r)
	build_ok()
	m0 = window()	-- call 事务窗口从 build 之后开
	local sleep_base = sleep_total
	local res
	local ok = expect_ok("call " .. label, function()
		res = call({ fd = fd, address = "0x10" })
		return res
	end)
	check(label .. " call 3 事务（set+ptr+r8）", #entries(m0) == 3
		and nset(m0) == 1 and npt(m0) == 1 and nrd(m0) == 1)
	check(label .. " 读指针=0x42、长度 8", ptr_writes(m0)[1] == 0x42 and read_sizes(m0)[1] == 8)
	check(label .. " call 零睡眠（build 已睡 3ms）", sleep_total == sleep_base,
		tostring(sleep_total - sleep_base))
	if ok then
		check(label .. " X=" .. tostring(wantX), res.X == wantX, tostring(res.X))
		check(label .. " Y=" .. tostring(wantY), res.Y == wantY, tostring(res.Y))
		check(label .. " Z=" .. tostring(wantZ), res.Z == wantZ, tostring(res.Z))
	end
	return res
end
golden("A 典型 trim", trimA, -200, 100, -450, 512, -53, 19, -2047)
golden("B 简化 trim", trimB, 100, -250, 300, 600, 31, -78, 2047)
golden("B2 XY/Z 溢出哨兵", trimB, -4096, 4095, -16384, 600, nil, 1279, nil)
golden("C RHALL=0 回退", trimA, -200, 100, -450, 0, -68, 28, nil)

-- virt_tick 闭环：默认工厂 trim，build 后逐拍 tick→call
do
	section()
	build_ok()
	local TICK_WANT = {
		[0] = { 30, 3, -24 }, [8] = { 50, -12, -42 },
		[16] = { 30, -27, -60 }, [24] = { 10, -12, -42 },
	}
	for n, w in pairs(TICK_WANT) do
		dev:virt_tick(n)
		local res = call({ fd = fd, address = "0x10" })
		check("tick " .. n .. " 闭环 X", res.X == w[1], tostring(res.X))
		check("tick " .. n .. " 闭环 Y", res.Y == w[2], tostring(res.Y))
		check("tick " .. n .. " 闭环 Z", res.Z == w[3], tostring(res.Z))
	end
end

-- 未 build 守卫：reload 驱动清 trim upvalue
vbus.load_driver("modules/BMM150.lua")
mark = section()
expect_err("裸 call 未 build", function() return call({ fd = fd, address = "0x10" }) end, "not built")
check("未 build 仍有 1 条 set（i2c_pair 在前）", nset(mark) == 1 and #entries(mark) == 1)

-- call 负路径（先正常 build）
section()
dev:set_trim(trimA)
dev:set_data(-200, 100, -450, 512)
build_ok()

mark = window()
expect_err("call 非表", function() return call(nil) end, "Invalid Arguments")
check("call 非表零事务", #entries(mark) == 0)

mark = window()
expect_err("call 缺 fd", function() return call({ address = "0x10" }) end, "fd or address")
check("call 缺 fd 零事务", #entries(mark) == 0)

mark = window()
expect_err("call fd=99", function() return call({ fd = 99, address = "0x10" }) end, "set_addr failed")
check("call fd=99 零事务", #entries(mark) == 0)

mark = window()
expect_err("call 错地址 0x60", function() return call({ fd = fd, address = "0x60" }) end, "Failed to read BMM150 data")
check("call 0x60 = set+指针写 NACK 共 2 条无 r", #entries(mark) == 2 and nrd(mark) == 0)

mark = window()
dev:fail_read(read_at(0x42))
expect_err("call 数据读失败", function() return call({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 data")
check("call 读失败 3 事务（fail_read 留 r 痕）", #entries(mark) == 3 and nrd(mark) == 1)
dev:clear_faults()

mark = window()
dev:fail_write(frame_prefix({ 0x42 }))
expect_err("call 指针写失败", function() return call({ fd = fd, address = "0x10" }) end, "Failed to read BMM150 data")
check("call 指针写失败 2 事务无 r", #entries(mark) == 2 and nrd(mark) == 0)
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无总线资源要释放）
-- =====================================================================
mark = section()
expect_ok("destroy 空表 OK", function() return destroy({}) end)
check("destroy 零总线事务", #entries(mark) == 0)

mark = section()
expect_ok("destroy 带 fd 也 OK", function() return destroy({ fd = fd, address = "0x10" }) end)
check("destroy 带 fd 仍零事务", #entries(mark) == 0)

mark = section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("destroy 非表零事务", #entries(mark) == 0)

tester.summary("test_bmm150")

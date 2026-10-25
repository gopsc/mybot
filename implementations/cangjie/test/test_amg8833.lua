-- test_amg8833.lua —— AMG8833 真实驱动 + 虚拟 I2C 总线 + 像素块模型
-- 用法（项目根目录）: luajit test/test_amg8833.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + virtbus/amg8833.lua 模型」。本器件是 virtbus 库【8 位字节指针 +
-- 128 字节像素块连续 burst 读 + 帧周期门】样板（Panasonic Grid-EYE 8x8
-- 热电堆，地址 0x69 缺省/0x68）：
--   寄存器按字节寻址，读指针随字节自增、0xFF 后回绕 0x00；0x80 起 128B
--   = 64 像素 ×2B，12 位补码小端（LSB 偶地址）、0.25°C/LSB、MSB 高 4 位 0；
--   热敏电阻 0x0E/0x0F 同构、0.0625°C/LSB。RST 0x01 是命令寄存器：0x3F
--   初始复位（回 POR + 帧计时重启，值不落盘）、0x30 标志复位。PCTL 0x00
--   仅 0x00=normal 持续出帧，FPSC bit0 选 10/1Hz；首帧在一个帧周期后就绪，
--   驱动不查就绪位、靠 milli_sleep 等 120/1020ms，模型 advance 推帧门、
--   virt_tick 直接装移动热点热图预武装。
--
-- 覆盖：模型侧 POR/12 位小端像素与热敏编解码（独立 enc/dec 公式交叉、
-- ±满码钳）/16B 块 burst 与指针自增/0xFF 回绕/RST 0x3F 命令语义与 0x30
-- 标志复位/值不落盘/复位保留钩子/PCTL sleep·stand-by 停采与唤醒重排/
-- FPSC 切帧率/99vs100·999vs1000 帧门边界/跨多拍/queue 注入/无注入保持/
-- 只读区写忽略/virt_tick 热点旋转与热敏正弦/坏帧/谓词钩子；真实 build
-- 四笔写序列（PCTL/RST/INTC/FPSC）与 5+120(1020)ms 睡眠、1Hz/0x68、
-- 四笔写各自失败与参数负路径；真实 call 热敏+8 像素块共 9 读事务形态、
-- 聚合 MAXT/MINT/AVGT/热点行列/THERM、负温阵列、chunk 定向失败、
-- virt_tick 零睡眠闭环；destroy 零总线事务与非表负路径。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
local smod = dofile("modules/lib/virtbus/amg8833.lua")
vbus.reset()

local ADDR = 0x69
local dev = smod.new()
vbus.attach("AMG8833@0x69", ADDR, dev)
vbus.attach("AMG8833@0x68", 0x68, dev)	-- AD_SELECT 拉高的备用地址，同一模型
vbus.load_driver("modules/AMG8833.lua")

-- milli_sleep：累计时长 + 推进帧虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))
check("i2c_set_addr 0x69", i2c_set_addr(fd, ADDR) == true)

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用，保留 build 出来的活动状态）
local function window()
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
-- 窗口内 2B 寄存器写 {reg,val}
local function reg_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 2 then t[#t + 1] = { b[1], b[2] } end
	end
	return t
end
-- 窗口内 1B 指针写序列
local function ptr_writes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do
		if #b == 1 then t[#t + 1] = b[1] end
	end
	return t
end
-- 窗口内读事务返回长度序列
local function read_sizes(mark)
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
local function n2b(mark) return #reg_writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

-- HAL 快捷
local function read_bytes(reg, n) return i2c_read_multi_bytes(fd, reg, n) end

-- 测试侧独立 12 位补码小端编解码（不看模型实现，纯 floor/%）
local function enc12(v)
	local u = math.floor(v) % 0x1000
	return u % 256, math.floor(u / 256)
end
local function dec12(lo, hi)
	local u = (hi % 16) * 256 + lo
	if u >= 0x800 then u = u - 0x1000 end
	return u
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

local function build_ok(opts)
	opts = opts or {}
	opts.fd = fd
	if opts.address == nil then opts.address = "0x69" end
	local r = build(opts)
	check("build OK", r.result == "OK", tostring(r.message))
	return r
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点 API / 经 HAL）
-- =====================================================================
local mark = section()

-- ---- POR ----
check("POR PCTL=0x00(normal)", dev:reg(0x00) == 0x00)
check("POR RST 命令寄存器不落盘=0", dev:reg(0x01) == 0)
check("POR FPSC=0(10Hz)", dev:reg(0x02) == 0x00)
check("POR INTC=0", dev:reg(0x03) == 0x00)
check("POR active(normal)", dev:is_active())
check("POR period=100ms", dev:period_ms() == 100)
check("POR remaining=100(首帧在途)", dev:remaining_ms() == 100)
check("POR frames=0", dev:frame_count() == 0)
check("POR reset_count=0", dev:reset_count() == 0)
check("POR 像素 0 全 0", dev:pixel_raw(0) == 0 and dev:pixel_raw(63) == 0)
check("POR 热敏=0", dev:therm_raw() == 0)
check("POR 读指针 nil（无纯读）", dev:ptr() == nil)

-- ---- 12 位小端编解码（API 公式 vs 独立 enc/dec；经模型观察口与 HAL 总线双路）----
dev:set_pixel_c(27, 42.75)			-- 171 码
do
	local lo, hi = enc12(171)
	check("171 码模型 LSB=独立编码", dev:reg(0x80 + 54) == lo and lo == 171, lo)
	check("171 码 MSB=0", dev:reg(0x81 + 54) == hi and hi == 0, hi)
	check("观察口 pixel_raw=171", dev:pixel_raw(27) == 171)
	check("观察口 pixel_c=42.75", near(dev:pixel_c(27), 42.75))
end
dev:set_pixel_c(0, -5)				-- -20 码 = 0xFEC
do
	local lo, hi = enc12(-20)
	check("-20 码 LSB=0xEC", dev:reg(0x80) == lo and lo == 0xEC, string.format("%x", lo))
	check("-20 码 MSB=0x0F", dev:reg(0x81) == hi and hi == 0x0F, hi)
	check("观察口 pixel_raw=-20", dev:pixel_raw(0) == -20, dev:pixel_raw(0))
end
dev:set_pixel_raw(63, 2047)
check("正满码 2047（0x7FF）", dev:pixel_raw(63) == 2047 and dev:reg(0xFE) == 0xFF and dev:reg(0xFF) == 0x07)
dev:set_pixel_raw(63, -2048)
check("负满码 -2048（0x800）", dev:pixel_raw(63) == -2048 and dev:reg(0xFF) == 0x08 and dev:reg(0xFE) == 0x00)
dev:set_pixel_raw(63, 99999)
check("正向超范围钳 2047", dev:pixel_raw(63) == 2047)
dev:set_pixel_raw(63, -99999)
check("负向超范围钳 -2048", dev:pixel_raw(63) == -2048)
-- MSB 高 4 位恒 0
dev:set_pixel_raw(30, 2047)
check("12 位帧高 4 位恒 0", dev:reg(0x80 + 61) <= 0x0F, dev:reg(0x80 + 61))

dev:set_therm_c(25)					-- 400 码 = 0x190
do
	local lo, hi = enc12(400)
	check("therm 400 LSB=0x90", dev:reg(0x0E) == lo and lo == 0x90)
	check("therm 400 MSB=1", dev:reg(0x0F) == hi and hi == 1)
	check("therm_raw=400", dev:therm_raw() == 400)
	check("therm_c=25", near(dev:therm_c(), 25))
end
dev:set_therm_c(-10)				-- -160 码
check("therm 负温 -160=-10°C", dev:therm_raw() == -160 and near(dev:therm_c(), -10),
      tostring(dev:therm_raw()))

-- 经真实 HAL 读回，独立 dec12 解码交叉（0x80 块 16B = 像素 0..7）
dev:set_pixel_raw(0, 171)
dev:set_pixel_raw(7, 7)
dev:set_pixel_raw(1, -20)
do
	local b = read_bytes(0x80, 16)
	check("HAL 块读 16 字节", type(b) == "table" and #b == 16, tostring(b))
	check("HAL 像素0 dec12=171", b and dec12(b[1], b[2]) == 171)
	check("HAL 像素1 dec12=-20", b and dec12(b[3], b[4]) == -20)
	check("HAL 像素7 dec12=7", b and dec12(b[15], b[16]) == 7)
end

-- ---- burst 自增 / 块边界 / 0xFF 回绕 ----
dev:set_pixel_raw(63, 63)
check("指针写 0xF0 ACK", i2c_write_reg(fd, 0xF0, 63) == true)
-- 上一笔是 2B 写不是指针写；块读前先纯指针
local bp = read_bytes(0xF0, 16)
check("末块 0xF0 读 16B", #bp == 16)
check("末块像素63 LSB=63", bp[15] == 63 and bp[16] == 0, string.format("%d,%d", bp[15], bp[16]))
check("末块读完内部指针回绕 0x00", dev:ptr() == 0x00, string.format("%x", dev:ptr() or -1))
-- 单字节续读：回绕后读 PCTL
local one = read_bytes(0x00, 1)
check("回绕区读 PCTL=0", one[1] == 0x00)
-- 非对齐短读 3B：0x82 起 = 像素1 LSB/MSB + 像素2 LSB
dev:set_pixel_raw(2, 0x2BC)		-- 700 码：LSB=0xBC MSB=0x02
do
	local b3 = read_bytes(0x82, 3)
	check("非对齐 3B 短读", #b3 == 3 and b3[1] == 0xEC and b3[2] == 0x0F and b3[3] == 0xBC,
	      b3 and table.concat({ b3[1], b3[2], b3[3] }, ",") or "nil")
end

-- ---- RST 0x3F / 0x30 命令语义 ----
dev:reset()
dev:set_pixel_raw(3, 123)
dev:set_therm_c(33)
check("写 RST=0x3F ACK", i2c_write_reg(fd, 0x01, 0x3F) == true)
check("initial reset 计数=1", dev:reset_count() == 1)
check("RST 清像素区", dev:pixel_raw(3) == 0)
check("RST 清热敏", dev:therm_raw() == 0)
check("RST 配置回 POR(PCTL=0)", dev:reg(0x00) == 0)
check("RST 帧计时重启 remaining=100", dev:remaining_ms() == 100)
check("RST 值不落盘", dev:reg(0x01) == 0)
check("写 RST=0x30 标志复位 ACK", i2c_write_reg(fd, 0x01, 0x30) == true)
check("flag reset 计数=1", dev:flag_reset_count() == 1)
check("标志复位不增 initial 计数", dev:reset_count() == 1)
check("写 RST=0x55 杂值 ACK 无效", i2c_write_reg(fd, 0x01, 0x55) == true)
check("杂值不增任何计数", dev:reset_count() == 1 and dev:flag_reset_count() == 1)
-- 复位保留故障钩子
dev:fail_write(function(b) return b[1] == 0x02 end)
i2c_write_reg(fd, 0x01, 0x3F)
check("硬件复位保留故障钩子", dev:reg(0x02) == 0 and (function()
	return i2c_write_reg(fd, 0x02, 0x01) == false
end)())
dev:clear_faults()

-- ---- PCTL sleep/stand-by 停采、唤醒重排 ----
dev:reset()
check("写 PCTL=0x10 sleep", i2c_write_reg(fd, 0x00, 0x10) == true)
check("sleep 不 active", not dev:is_active())
check("sleep period 观察口 nil", dev:period_ms() == nil)
check("sleep remaining=nil", dev:remaining_ms() == nil)
dev:set_pixel_raw(9, 300)
dev:advance(5000)
check("sleep 下不产帧", dev:frame_count() == 0)
check("sleep 下数据保持", dev:pixel_raw(9) == 300)
check("PCTL=0x20 stand-by 也停", (i2c_write_reg(fd, 0x00, 0x20) == true) and not dev:is_active())
-- sleep 中切帧率落盘但不启动
i2c_write_reg(fd, 0x02, 0x01)
check("sleep 中 FPSC 记录为 1Hz", dev:fps_1hz())
check("sleep 中仍 remaining=nil", dev:remaining_ms() == nil)
-- 唤醒：按当前帧率重排首帧
i2c_write_reg(fd, 0x00, 0x00)
check("唤醒 active", dev:is_active())
check("唤醒 period=1000", dev:period_ms() == 1000)
check("唤醒 remaining=1000", dev:remaining_ms() == 1000)

-- ---- 帧门：边界 / 跨拍 / queue 注入 / 无注入保持 ----
dev:reset()
i2c_write_reg(fd, 0x02, 0x01)		-- 1Hz（写即重排 remaining=1000）
do
	local f = {}; for i = 0, 63 do f[i] = 40 end		-- 10°C
	dev:queue_frame_raw(f)
	dev:advance(999)
	check("1Hz 999ms 帧未到", dev:frame_count() == 0 and dev:pixel_raw(0) ~= 40)
	dev:advance(1)
	check("1Hz 1000ms 帧到点装载", dev:frame_count() == 1 and dev:pixel_raw(0) == 40)
	check("到点后 remaining 重排", near(dev:remaining_ms(), 1000))
	dev:advance(2000)
	check("无注入：再产 2 帧事件但数据保持", dev:frame_count() == 3 and dev:pixel_raw(0) == 40)
end
dev:reset()
do
	local f1, f2, f3 = {}, {}, {}
	for i = 0, 63 do f1[i], f2[i], f3[i] = 1, 2, 3 end
	dev:queue_frame_raw(f1); dev:queue_frame_raw(f2); dev:queue_frame_raw(f3)
	dev:advance(99)
	check("10Hz 99ms 不出帧", dev:frame_count() == 0)
	dev:advance(1)
	check("10Hz 100ms 出第 1 帧", dev:frame_count() == 1 and dev:pixel_raw(0) == 1)
	dev:advance(200)
	check("再 200ms 跨 2 帧（共 3）", dev:frame_count() == 3 and dev:pixel_raw(0) == 3,
	      tostring(dev:frame_count()))
	check("注入队列耗尽", dev:queue_len() == 0)
end
-- queue_frame_c 摄氏度入口
dev:reset()
do
	local fc = {}; for i = 0, 63 do fc[i] = 26.5 end	-- 106 码
	dev:queue_frame_c(fc)
	dev:advance(100)
	check("queue_frame_c 26.5°C=106 码", dev:pixel_raw(0) == 106 and near(dev:pixel_c(0), 26.5))
end

-- ---- 只读区写忽略但 ACK ----
dev:reset()
check("写热敏 LSB ACK", i2c_write_reg(fd, 0x0E, 0xAB) == true)
check("写热敏 MSB ACK", i2c_write_reg(fd, 0x0F, 0xCD) == true)
check("热敏只读写被忽略", dev:reg(0x0E) == 0 and dev:reg(0x0F) == 0)
check("写像素区 ACK", i2c_write_multi(fd, 0x80, 0x7F, 0x07) == 0)
check("像素只读写被忽略", dev:reg(0x80) == 0 and dev:reg(0x81) == 0)
-- 配置区 burst 多字节落盘
check("burst 写 INTC+STAT", i2c_write_multi(fd, 0x03, 0x11, 0x22) == 0)
check("burst 首址落盘", dev:reg(0x03) == 0x11 and dev:reg(0x04) == 0x22,
      string.format("%x,%x", dev:reg(0x03), dev:reg(0x04)))

-- ---- virt_tick 确定性热图 ----
dev:reset()
dev:virt_tick(0)
do
	local maxt, maxi, sumc = -999, 0, 0
	for i = 0, 63 do
		local t = dev:pixel_c(i)
		sumc = sumc + t
		if t > maxt then maxt, maxi = t, i end
	end
	check("tick0 热点峰值约 45°C", maxt >= 44 and maxt <= 45.25, tostring(maxt))
	check("tick0 热点 [3][6]", math.floor(maxi / 8) == 3 and maxi % 8 == 6,
	      string.format("[%d][%d]", math.floor(maxi / 8), maxi % 8))
	check("tick0 阵列均值在背景与峰值之间", sumc / 64 > 25 and sumc / 64 < maxt,
	      tostring(sumc / 64))
	check("tick0 therm=30°C", near(dev:therm_c(), 30), tostring(dev:therm_c()))
end
dev:virt_tick(8)
do
	local maxt, maxi = -999, 0
	for i = 0, 63 do local t = dev:pixel_c(i); if t > maxt then maxt, maxi = t, i end end
	check("tick8 热点行旋转到 6", math.floor(maxi / 8) == 6,
	      string.format("[%d][%d]", math.floor(maxi / 8), maxi % 8))
	check("tick8 therm=32°C", near(dev:therm_c(), 32), tostring(dev:therm_c()))
end
dev:virt_tick(24)
check("tick24 therm=28°C", near(dev:therm_c(), 28), tostring(dev:therm_c()))

-- ---- 坏帧 NACK / 谓词钩子 ----
dev:reset()
check("非 table NACK", dev.write(0x42) == false)
check("0B NACK", dev.write({}) == false)
check("纯指针 >0xFF NACK", dev.write({ 0x100 }) == false)
check("无指针纯读 NACK", dev.read(2) == nil)
dev.nack = true
check("nack 写失败", i2c_write_reg(fd, 0x03, 0x00) == false)
check("nack 读失败", read_bytes(0x0E, 2) == nil)
dev.nack = false
dev.nack_write = true
check("nack_write 连指针写一起拦", read_bytes(0x0E, 2) == nil)
dev.nack_write = false
dev.nack_read = true
check("nack_read 仅读方向", i2c_write_reg(fd, 0x03, 0x05) == true and read_bytes(0x03, 1) == nil)
dev.nack_read = false
dev:fail_write(function(b) return b[1] == 0x02 end)
check("定向写钩子：FPSC 被拦", i2c_write_reg(fd, 0x02, 0x01) == false)
check("定向写钩子：INTC 正常", i2c_write_reg(fd, 0x03, 0x00) == true)
dev:fail_read(function(p) return p == 0x0E end)
check("定向读钩子：therm 被拦", read_bytes(0x0E, 2) == nil)
check("定向读钩子：像素正常", read_bytes(0x80, 2) ~= nil)
dev:clear_faults()
check("清钩子后恢复", i2c_write_reg(fd, 0x02, 0x01) == true and read_bytes(0x0E, 2) ~= nil)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
mark = section()
build_ok()
check("build 4 笔 2B 写", n2b(mark) == 4, tostring(n2b(mark)))
do
	local expect_w = { { 0x00, 0x00 }, { 0x01, 0x3F }, { 0x03, 0x00 }, { 0x02, 0x00 } }
	local same = #reg_writes(mark) == 4
	for i = 1, 4 do
		local g = reg_writes(mark)[i]
		same = same and g[1] == expect_w[i][1] and g[2] == expect_w[i][2]
	end
	check("build 写序列 PCTL/RST/INTC/FPSC", same,
	      (function()
		local s = {}
		for _, g in ipairs(reg_writes(mark)) do s[#s + 1] = string.format("%02X=%02X", g[1], g[2]) end
		return table.concat(s, ",")
	      end)())
end
check("build 无读事务", nrd(mark) == 0)
check("build 一次 set_addr 0x69", table.concat(set_addrs(mark), ",") == "105")
check("build 睡眠 5+120=125ms", sleep_total == 125, tostring(sleep_total))
check("build 触发一次初始复位", dev:reset_count() == 1)
check("build 后 10Hz", not dev:fps_1hz())
check("build 后 active", dev:is_active())
check("build 睡眠跨过首帧（frame=1）", dev:frame_count() == 1, tostring(dev:frame_count()))
check("build 后剩余帧计时=80ms", dev:remaining_ms() == 80, tostring(dev:remaining_ms()))

-- 1Hz + 显式 0x68
mark = section()
build_ok({ address = "0x68", fps = "1" })
check("1Hz FPSC=0x01", reg_writes(mark)[4][1] == 0x02 and reg_writes(mark)[4][2] == 0x01)
check("1Hz set_addr 0x68", table.concat(set_addrs(mark), ",") == "104")
check("1Hz 睡眠 5+1020=1025ms", sleep_total == 1025, tostring(sleep_total))
check("build 后 period=1000", dev:period_ms() == 1000)
check("1Hz 首帧也已跨过", dev:frame_count() == 1 and dev:remaining_ms() == 980,
      string.format("%s/%s", tostring(dev:frame_count()), tostring(dev:remaining_ms())))
-- fps 非 1 一律 10Hz（含脏值）
mark = section()
build_ok({ fps = "10" })
check("fps='10' 落 10Hz", reg_writes(mark)[4][2] == 0x00)

-- ---- build 负路径 ----
mark = section()
expect_err("build 非表", function() return build(42) end, "Invalid Arguments Type: table")
check("非表零事务", #entries(mark) == 0)

mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x69" }) end, "Invalid Argument: fd")
check("缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("build set_addr 失败", function()
	return build({ fd = 99, address = "0x69" })
end, "set_addr failed")
check("set_addr 失败零总线事务", #entries(mark) == 0)

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x00 end)
expect_err("PCTL 写失败", function() return build({ fd = fd }) end, "power control")
check("PCTL 失败仅 1 笔写", n2b(mark) == 1)
check("PCTL 失败未复位", dev:reset_count() == 0)
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x01 end)
expect_err("RST 写失败", function() return build({ fd = fd }) end, "initial reset")
check("RST 失败 2 笔写（PCTL 已过）", n2b(mark) == 2)
check("RST 失败 reset_count=0", dev:reset_count() == 0)
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x03 end)
expect_err("INTC 写失败", function() return build({ fd = fd }) end, "interrupt control")
check("INTC 失败 3 笔写", n2b(mark) == 3)
check("INTC 失败时 RST 已生效", dev:reset_count() == 1)
dev:clear_faults()

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x02 end)
expect_err("FPSC 写失败", function() return build({ fd = fd }) end, "frame rate")
check("FPSC 失败 4 笔写", n2b(mark) == 4)
check("FPSC 失败后仍 POR 默认 10Hz", not dev:fps_1hz())
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 默认像素帧（0 基码表，沿用旧桩事实）：61 个 80 码(20°C) +
-- 像素0=-20 码(-5°C) + 像素27=171 码(42.75°C) + 像素63=40 码(10°C)
local function default_frame_c()
	local t = {}
	for i = 0, 63 do t[i] = 20 end
	t[0] = -5
	t[27] = 42.75
	t[63] = 10
	return t
end

mark = section()
build_ok()
dev:set_frame_c(default_frame_c())
dev:set_therm_c(25)
sleep_total = 0
mark = window()
local r = expect_ok("call 聚合读取", function() return call({ fd = fd }) end)
if r then
	check("MAXT=42.75", near(r.MAXT, 42.75), tostring(r.MAXT))
	check("MINT=-5", near(r.MINT, -5), tostring(r.MINT))
	check("AVGT=5071*0.25/64=19.80859375", near(r.AVGT, 5071 * 0.25 / 64, 1e-9),
	      tostring(r.AVGT))
	check("热点 [3][3]", r.MAXR == 3 and r.MAXC == 3,
	      string.format("[%d][%d]", r.MAXR, r.MAXC))
	check("THERM=25", near(r.THERM, 25), tostring(r.THERM))
end
check("call 9 个读事务（therm 1 + 像素 8）", nrd(mark) == 9, tostring(nrd(mark)))
check("call 无 2B 配置写", n2b(mark) == 0)
check("call 一次 set_addr", #set_addrs(mark) == 1)
check("首读 therm 2B", read_sizes(mark)[1] == 2 and ptr_writes(mark)[1] == 0x0E,
      table.concat(read_sizes(mark), ","))
check("像素块读全 16B", (function()
	for k = 2, 9 do if read_sizes(mark)[k] ~= 16 then return false end end
	return true
end)())
do
	local expect_ptrs = { 0x0E, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0 }
	local same = #ptr_writes(mark) == 9
	for i = 1, 9 do same = same and ptr_writes(mark)[i] == expect_ptrs[i] end
	check("指针序列 0E/80/90/A0/B0/C0/D0/E0/F0", same,
	      table.concat(ptr_writes(mark), ","))
end
check("call 零睡眠", sleep_total == 0, tostring(sleep_total))

-- address 缺省 0x69（不传 address）
check("call 缺省地址 0x69", (function()
	local ok2, rr = pcall(call, { fd = fd })
	return ok2 and rr.result == "OK"
end)())

-- 全负温阵列：极值交换
mark = section()
build_ok()
do
	local cold = {}
	for i = 0, 63 do cold[i] = -25 end
	cold[40] = 5
	dev:set_frame_c(cold)
end
mark = window()
r = expect_ok("call 全负温阵列", function() return call({ fd = fd }) end)
if r then
	check("冷阵列 MAXT=5（像素40）", near(r.MAXT, 5), tostring(r.MAXT))
	check("冷阵列 MINT=-25", near(r.MINT, -25), tostring(r.MINT))
	check("冷阵列热点 [5][0]", r.MAXR == 5 and r.MAXC == 0,
	      string.format("[%d][%d]", r.MAXR, r.MAXC))
end

-- 连续两拍 virt_tick：零睡眠闭环且聚合随热图变化
mark = section()
build_ok()
sleep_total = 0
local tick_cases = {
	{ 0, 3, 6, 30 },
	{ 8, 6, 3, 32 },
}
for _, tc in ipairs(tick_cases) do
	dev:virt_tick(tc[1])
	local rr = call({ fd = fd })
	check(string.format("tick%d 热点 [%d][%d]/therm=%d 闭环", tc[1], tc[2], tc[3], tc[4]),
	      rr.result == "OK" and rr.MAXR == tc[2] and rr.MAXC == tc[3] and
	      near(rr.THERM, tc[4]),
	      rr.result == "OK" and string.format("[%d][%d]/%s", rr.MAXR, rr.MAXC, tostring(rr.THERM)) or rr.message)
end
check("tick 闭环零睡眠", sleep_total == 0, tostring(sleep_total))
-- 两拍 MAXR 不同（通用 E2E count 断言的模型侧依据）
dev:virt_tick(0); local a = call({ fd = fd })
dev:virt_tick(8); local b = call({ fd = fd })
check("tick0 vs tick8 热点行变化", a.MAXR ~= b.MAXR, string.format("%s/%s", a.MAXR, b.MAXR))

-- ---- call 负路径 ----
mark = section()
expect_err("call 非表", function() return call(42) end, "Invalid Arguments: table")
check("call 非表零事务", #entries(mark) == 0)

mark = section()
expect_err("call 缺 fd", function() return call({}) end, "Invalid Argument: fd")
check("call 缺 fd 零事务", #entries(mark) == 0)

mark = section()
expect_err("call set_addr 失败", function() return call({ fd = 99 }) end, "set_addr failed")
check("call set_addr 失败零事务", #entries(mark) == 0)

mark = section()
build_ok()
dev:fail_read(function(p) return p == 0x0E end)
mark = window()
expect_err("热敏读失败", function() return call({ fd = fd }) end, "thermistor")
check("热敏失败仅 1 个读事务", nrd(mark) == 1, tostring(nrd(mark)))
dev:clear_faults()

mark = section()
build_ok()
dev:fail_read(function(p) return p == 0x80 end)
mark = window()
expect_err("像素块 0 读失败", function() return call({ fd = fd }) end, "pixels (chunk 0)")
check("chunk0 失败：therm + chunk0 共 2 读", nrd(mark) == 2, tostring(nrd(mark)))
dev:clear_faults()

mark = section()
build_ok()
dev:fail_read(function(p) return p == 0xD0 end)
mark = window()
expect_err("像素块 5 读失败", function() return call({ fd = fd }) end, "pixels (chunk 5)")
check("chunk5 失败：therm + 6 块共 7 读", nrd(mark) == 7, tostring(nrd(mark)))
dev:clear_faults()

mark = section()
build_ok()
dev.nack_write = true
mark = window()
expect_err("nack_write：therm 指针写失败", function() return call({ fd = fd }) end, "thermistor")
dev.nack_write = false

-- =====================================================================
-- 组 4：destroy（无总线资源要释放）
-- =====================================================================
mark = section()
build_ok()
mark = window()
expect_ok("destroy OK", function() return destroy({ fd = fd }) end)
check("destroy 零总线事务", #entries(mark) == 0)

mark = section()
expect_ok("destroy 空表也 OK", function() return destroy({}) end)
check("空表零事务", #entries(mark) == 0)

mark = section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("destroy 非表零事务", #entries(mark) == 0)

tester.summary("test_amg8833")

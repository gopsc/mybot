-- test_pcf8574.lua —— PCF8574 真实驱动 + 虚拟 I2C 总线 + P 口模型
-- 用法（项目根目录）: luajit test/test_pcf8574.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：PCF_GC=1 luajit test/test_pcf8574.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + 内嵌模型（modules/PCF8574.lua 尾部 PCF8574_VIRT，2026-09-15
-- 自 virtbus/pcf8574.lua 迁入）」。本器件是 virtbus 库【无寄存器图 ·
-- 单字节 P 口写 + 无指针纯读】极简样板（NXP PCF8574/PCF8574A，地址族
-- 0x20~0x27 / 0x38~0x3F）：
--   写事务无寄存器地址，每个数据字节直接进 P 口输出锁存（驱动恒 1B）；
--   读事务无指针纯读，返回引脚即时电平；准双向：写 1 弱上拉（外部可拉
--   低）、写 0 强驱动低，引脚读值 = latch & ~pull_low，POR 锁存 0xFF。
--   无 ID 寄存器，build 靠一次纯读 ACK 做在位甄别。
--
-- 覆盖：模型侧 POR/单字节与多字节逐字节锁存（末字节留口）/非字节 NACK/
-- 无指针纯读与连续读重复引脚态/准双向真值表（独立按位公式交叉）/外部
-- 拉低掩码与 pull·release 幂等/种子构造/virt_tick walking 8 拍/谓词与
-- nack 钩子/reset 保留钩子·清激励/reset_logs 边界；真实 build 事务形态
-- （set→纯读→1B 锁存写，无指针写相位）、地址族与 out 缺省/越界参数、
-- 读写 NACK 负路径、零睡眠；真实 call 写后回读/纯读保持/准双向闭环/
-- virt_tick 八拍值、参数与总线负路径；destroy 零总线事务。

if os.getenv("PCF_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（PCF8574_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/PCF8574.lua")
local smod = PCF8574_VIRT

-- 同一模型挂地址族边界（0x20/0x27 = PCF8574，0x38/0x3F = PCF8574A 都要 build 成功）
local dev = smod.new()
vbus.attach("PCF8574@0x20", 0x20, dev)
vbus.attach("PCF8574@0x27", 0x27, dev)
vbus.attach("PCF8574A@0x38", 0x38, dev)
vbus.attach("PCF8574A@0x3F", 0x3F, dev)

-- 驱动不调 milli_sleep；桩仅留痕，断言 build/call 全程零睡眠
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + (tonumber(ms) or 0) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))
check("i2c_set_addr 0x20", i2c_set_addr(fd, 0x20) == true)

-- 每个 section：器件回 POR + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	sleep_total = 0
	return #vbus.txlog
end
-- 只开事务窗口、不复位器件（build 之后用，保留驱动配置出的锁存状态）
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
local function nwr(mark) return #writes(mark) end
local function nrd(mark) return #read_sizes(mark) end

-- 测试侧独立 8 位按位与 + 准双向公式（不看模型实现，逐位 floor/%）
local function band8_ref(a, b)
	a, b = a % 256, b % 256
	local r, p = 0, 1
	for _ = 1, 8 do
		if a % 2 == 1 and b % 2 == 1 then r = r + p end
		a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
	end
	return r
end
local function pins_ref(latch, pull) return band8_ref(latch, 255 - pull) end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点 API / 经 HAL）
-- =====================================================================
local m = section()
check("POR 锁存 0xFF（全弱上拉/输入态）", dev:latch() == 0xFF, tostring(dev:latch()))
check("POR 引脚态 0xFF", dev:pins() == 0xFF, tostring(dev:pins()))
check("POR 外部拉低掩码 0", dev:pull_low() == 0)
check("POR 写/读计数 0", dev:write_count() == 0 and dev:read_count() == 0,
	string.format("%d/%d", dev:write_count(), dev:read_count()))

-- 单字节写 = P 口锁存
i2c_set_addr(fd, 0x20)
check("HAL 写 0x5A 返 0", i2c_write_multi(fd, 0x5A) == 0)
check("锁存=0x5A", dev:latch() == 0x5A, string.format("%X", dev:latch()))
check("引脚态随锁存 0x5A", dev:pins() == 0x5A, string.format("%X", dev:pins()))
check("写计数=1", dev:write_count() == 1)
check("末笔写值 0x5A", dev:last_write() == 0x5A)
check("留痕帧恰 1B", #dev:frames()[1] == 1 and dev:frames()[1][1] == 0x5A)
-- txlog 形态：无 set（本组开场只 set 过一次），新增 1 笔 w、0 笔 r
check("窗口 1 写 0 读", nwr(m) == 1 and nrd(m) == 0, string.format("%d/%d", nwr(m), nrd(m)))

-- 多字节写：逐字节传送 P 口、末字节留口、整帧留痕
m = section()
check("HAL 多字节写 01,02,03 返 0", i2c_write_multi(fd, 0x01, 0x02, 0x03) == 0)
check("末字节锁存 0x03", dev:latch() == 0x03, string.format("%X", dev:latch()))
check("写计数=1（一帧）", dev:write_count() == 1)
check("帧表 1 帧 3B", #dev:frames() == 1 and #dev:frames()[1] == 3)
check("帧字节序 01/02/03",
	dev:frames()[1][1] == 0x01 and dev:frames()[1][2] == 0x02 and dev:frames()[1][3] == 0x03)

-- 坏写：非字节整笔 NACK、锁存不动；非 table/0 长帧回调直接 false
m = section()
check("256 非字节 HAL 写返 -1", i2c_write_multi(fd, 256) == -1)
check("非字节后锁存仍 POR", dev:latch() == 0xFF, tostring(dev:latch()))
check("写计数仍 0（坏帧不留痕）", dev:write_count() == 0)
check("dev.write 非 table=false", dev.write(0xAA) == false)
check("dev.write 空表=false", dev.write({}) == false)

-- 无指针纯读：读事务前【没有】指针写相位
m = section()
local v1 = i2c_read(fd, 1)
check("i2c_read 1B 返引脚态", v1 == 0xFF, tostring(v1))
check("纯读窗口 0 写 1 读", nwr(m) == 0 and nrd(m) == 1, string.format("%d/%d", nwr(m), nrd(m)))
check("读长度记录 n=1", read_sizes(m)[1] == 1)
local t4 = i2c_read_bytes(fd, 4)
check("连续读 4B 表长 4", type(t4) == "table" and #t4 == 4)
check("4B 重复当前引脚态 0xFF",
	t4[1] == 0xFF and t4[2] == 0xFF and t4[3] == 0xFF and t4[4] == 0xFF,
	table.concat(t4, ","))
check("读计数=2", dev:read_count() == 2)
-- 回调层 n 钳制（HAL 不会发，但模型契约要稳）
check("dev.read(20) 钳 16B", #dev.read(20) == 16)
check("dev.read(0) 钳 1B", #dev.read(0) == 1)
check("dev.read(非数) 钳 1B", #dev.read("x") == 1)

-- 准双向真值表：锁存 × 外部拉低掩码，独立公式逐组交叉
m = section()
local latches = { 0x00, 0x55, 0xAA, 0xFF }
local pulls = { 0x00, 0x0F, 0xF0, 0xFF, 0xAA }
for _, L in ipairs(latches) do
	for _, P in ipairs(pulls) do
		dev:set_latch(L)
		dev:set_pull_low(P)
		check(string.format("准双向 latch=%02X pull=%02X → pins=%02X", L, P, pins_ref(L, P)),
			dev:pins() == pins_ref(L, P),
			string.format("got %02X want %02X", dev:pins(), pins_ref(L, P)))
	end
end
-- 强驱低位恒 0：外部掩码任何位都抬不起来
dev:set_latch(0x00)
check("latch=0 pull=0xFF 仍读 0", dev:pins() == 0)
-- 全弱上拉无外部激励 = 全 1
dev:set_latch(0xFF); dev:release_all()
check("latch=FF pull=0 读 FF", dev:pins() == 0xFF)

-- 外部激励 API：pull/release 幂等、越界脚忽略、非字节掩码忽略
m = section()
dev:pull(3)
check("pull(3) 掩码 0x08", dev:pull_low() == 0x08, string.format("%X", dev:pull_low()))
dev:pull(3)
check("pull(3) 重复幂等", dev:pull_low() == 0x08)
dev:pull(7); dev:pull(0)
check("pull 3,7,0 掩码 0x89", dev:pull_low() == 0x89, string.format("%X", dev:pull_low()))
check("引脚态 0x76", dev:pins() == 0x76, string.format("%X", dev:pins()))
dev:release(3)
check("release(3) 后掩码 0x81", dev:pull_low() == 0x81, string.format("%X", dev:pull_low()))
dev:release(7)
check("release(7) 掩码 0x01", dev:pull_low() == 0x01)
dev:release(0); dev:release(0)
check("release(0) 幂等清零", dev:pull_low() == 0)
dev:pull(8); dev:pull(-1)
check("越界脚 8/-1 忽略", dev:pull_low() == 0)
dev:set_pull_low(256); dev:set_pull_low("z")
check("非字节掩码忽略", dev:pull_low() == 0)
dev:set_pull_low(0x0F)
dev:release_all()
check("release_all 清零", dev:pull_low() == 0)
-- set_latch 非字节忽略
dev:set_latch(300)
check("set_latch(300) 忽略", dev:latch() == 0xFF)

-- 种子构造：合法种子生效、非法回 POR
local d2 = smod.new({ latch = 0x0F, pull_low = 0x03 })
check("种子 latch=0F/pull=03", d2:latch() == 0x0F and d2:pull_low() == 0x03)
check("种子派生 pins=0x0C", d2:pins() == 0x0C, string.format("%X", d2:pins()))
local d3 = smod.new({ latch = "x", pull_low = -1 })
check("坏种子回 POR FF/0", d3:latch() == 0xFF and d3:pull_low() == 0)

-- virt_tick：walking 低电平 8 拍周期，只改外部掩码、不动锁存
m = section()
local tick_want = { 0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F }
for n = 0, 7 do
	dev:virt_tick(n)
	check(string.format("tick%d 掩码=1<<%d 引脚=%d", n, n, 255 - 2 ^ n),
		dev:pull_low() == 2 ^ n and dev:pins() == tick_want[n + 1],
		string.format("pull=%X pins=%d", dev:pull_low(), dev:pins()))
end
dev:virt_tick(8)
check("tick8 周期回到 tick0（pins=254）", dev:pins() == 254 and dev:pull_low() == 0x01,
	string.format("%d/%X", dev:pins(), dev:pull_low()))
check("tick 不改锁存（仍 0xFF）", dev:latch() == 0xFF)
dev:set_pull_low(0xFF)
dev:virt_tick(2)
check("tick 覆盖旧掩码为单脚 0x04", dev:pull_low() == 0x04, string.format("%X", dev:pull_low()))

-- 故障钩子：谓词 + nack 三件
m = section()
dev:fail_write(function(b) return b[1] == 0x55 end)
check("写谓词拦 0x55", i2c_write_multi(fd, 0x55) == -1)
check("0x5A 放行", i2c_write_multi(fd, 0x5A) == 0)
check("被拦帧不入帧表", dev:write_count() == 1 and dev:last_write() == 0x5A)
dev:clear_faults()
dev:fail_read(function(n) return n == 4 end)
check("读谓词拦 n=4", i2c_read_bytes(fd, 4) == nil)
check("n=1 放行", i2c_read_bytes(fd, 1) ~= nil)
dev:clear_faults()
dev.nack_write = true
check("nack_write 写全拦", i2c_write_multi(fd, 0x00) == -1)
dev.nack_write = false
dev.nack_read = true
check("nack_read 读全拦", i2c_read(fd, 1) == -1)
dev.nack_read = false
dev.nack = true
check("nack 双向全拦", i2c_write_multi(fd, 0x00) == -1 and i2c_read(fd, 1) == -1)
dev:clear_faults()

-- reset：回 POR/清激励/清留痕，但保留故障钩子
m = section()
i2c_write_multi(fd, 0x12)
dev:set_pull_low(0x34)
dev.nack = true
dev:reset()
check("reset 后锁存回 FF", dev:latch() == 0xFF)
check("reset 后外部激励清零", dev:pull_low() == 0)
check("reset 后引脚 FF", dev:pins() == 0xFF)
check("reset 后留痕清零", dev:write_count() == 0 and #dev:frames() == 0)
check("reset 保留 nack 钩子", dev.nack == true)
dev:clear_faults()
-- reset_logs：只清计数，不动芯片/激励状态
i2c_write_multi(fd, 0x77)
dev:set_pull_low(0x0F)
dev:reset_logs()
check("reset_logs 清计数", dev:write_count() == 0 and #dev:frames() == 0)
check("reset_logs 不动锁存 0x77", dev:latch() == 0x77, string.format("%X", dev:latch()))
check("reset_logs 不动激励 0x0F", dev:pull_low() == 0x0F)

-- =====================================================================
-- 组 2：真实 build
-- =====================================================================
local function build_ok(opts)
	opts = opts or {}
	opts.fd = fd
	if opts.address == nil then opts.address = "0x20" end
	local r = build(opts)
	check("build OK", r.result == "OK", tostring(r.message))
	return r
end

-- 默认 build：set → 纯读在位 → 1B 锁存写 0xFF；读前无指针写
local mk = section()
build_ok()
do
	local es = entries(mk)
	check("build 3 条事务（set/r/w）", #es == 3, tostring(#es))
	check("事务序 set→r→w",
		es[1].dir == "set" and es[2].dir == "r" and es[3].dir == "w",
		table.concat((function()
			local s = {}
			for _, e in ipairs(es) do s[#s + 1] = e.dir end
			return s
		end)(), ","))
	check("set 地址 0x20", set_addrs(mk)[1] == 0x20, tostring(set_addrs(mk)[1]))
	check("在位甄别纯读 n=1", read_sizes(mk)[1] == 1)
	check("纯读前无写相位（无寄存器指针）", nwr(mk) == 1)
	check("唯一一帧写恰 1B", #writes(mk)[1] == 1)
	check("初始锁存写 0xFF", writes(mk)[1][1] == 0xFF,
		string.format("%X", writes(mk)[1][1] or 0))
	check("模型锁存=0xFF", dev:latch() == 0xFF)
	check("build 零睡眠", sleep_total == 0, tostring(sleep_total))
end

-- 显式初始锁存
section()
build_ok({ out = "15" })
check("out=15 锁存写 0x0F", dev:last_write() == 0x0F, string.format("%X", dev:last_write() or 0))
check("模型锁存 0x0F", dev:latch() == 0x0F)
check("强驱低 4 位，引脚 0x0F", dev:pins() == 0x0F, string.format("%X", dev:pins()))

-- 缺省占位 "-" / "" / 非数字串（驱动宽松解析为缺省 0xFF）
for _, tok in ipairs({ "-", "", "abc" }) do
	section()
	build_ok({ out = tok })
	check(string.format("out='%s' 缺省 0xFF", tok), dev:last_write() == 0xFF,
		string.format("%X", dev:last_write() or 0))
end

-- 地址族边界：0x27 上界、0x38 PCF8574A 下界、0x3F 上界
for _, a in ipairs({ "0x27", "0x38", "0x3F" }) do
	section()
	build_ok({ address = a })
	check(string.format("地址族边界 %s build 成功", a), true)
end

-- ---- build 负路径 ----
local bm = section()
expect_err("地址越族 0x30", function() return build({ fd = fd, address = "0x30" }) end, "invalid address")
check("越族零总线事务", #set_addrs(bm) <= 1 and nwr(bm) == 0 and nrd(bm) == 0)

bm = section()
expect_err("地址越族 0x48", function() return build({ fd = fd, address = "0x48" }) end, "invalid address")
check("越族 0x48 零事务", #set_addrs(bm) <= 1 and nwr(bm) == 0 and nrd(bm) == 0)

bm = section()
expect_err("地址越族 0x1F", function() return build({ fd = fd, address = "0x1F" }) end, "invalid address")
check("越族 0x1F 零事务", #set_addrs(bm) <= 1 and nwr(bm) == 0 and nrd(bm) == 0)

bm = section()
expect_err("初始锁存 256 越界", function() return build({ fd = fd, address = "0x20", out = "256" }) end, "range 0~255")
-- 越界发生在【在位读通过之后】：已有 1 set + 1 读，无锁存写
check("out 越界：1 set + 1 在位读、0 锁存写",
	#entries(bm) == 2 and #set_addrs(bm) == 1 and nrd(bm) == 1 and nwr(bm) == 0,
	tostring(#entries(bm)))

bm = section()
expect_err("初始锁存负值", function() return build({ fd = fd, address = "0x20", out = "-5" }) end, "range 0~255")
check("负值同 2 事务 0 写", #entries(bm) == 2 and nwr(bm) == 0, tostring(#entries(bm)))

bm = section()
expect_err("缺 fd/address", function() return build({ address = "0x20" }) end, "fd or address")
check("缺 fd 零事务", #entries(bm) == 0)

bm = section()
expect_err("build 非表", function() return build(7) end, "Invalid Arguments Type")
check("非表零事务", #entries(bm) == 0)

bm = section()
expect_err("set_addr 失败（fd=99）", function() return build({ fd = 99, address = "0x20" }) end,
	"set_addr failed")

-- 在位读 NACK
bm = section()
dev.nack_read = true
expect_err("build 在位读无应答", function() return build({ fd = fd, address = "0x20" }) end,
	"not responding")
check("读 NACK：1 set + 1 读、0 写",
	#set_addrs(bm) == 1 and nrd(bm) == 1 and nwr(bm) == 0,
	string.format("set=%d r=%d w=%d", #set_addrs(bm), nrd(bm), nwr(bm)))
dev:clear_faults()

-- 锁存写 NACK（谓词精确拦 0xFF）
bm = section()
dev:fail_write(function(b) return b[1] == 0xFF end)
expect_err("build 锁存写无应答", function() return build({ fd = fd, address = "0x20" }) end,
	"latch write failed")
check("写 NACK：1 set + 1 读 + 失败的 1 写",
	#set_addrs(bm) == 1 and nrd(bm) == 1 and nwr(bm) == 1,
	string.format("set=%d r=%d w=%d", #set_addrs(bm), nrd(bm), nwr(bm)))
dev:clear_faults()

-- =====================================================================
-- 组 3：真实 call
-- =====================================================================
-- 写锁存后回读：set → 1B 写 → 纯读
section()
build_ok()
local ck = window()
local r = expect_ok("call 写 0xAA", function() return call({ fd = fd, address = "0x20", out = "170" }) end)
if r then
	check("OUT=0xAA", r.OUT == 0xAA, string.format("%X", r.OUT))
	check("PINS=0xAA", r.PINS == 0xAA, string.format("%X", r.PINS))
end
do
	local es = entries(ck)
	check("call 3 条事务 set→w→r", #es == 3 and
		es[1].dir == "set" and es[2].dir == "w" and es[3].dir == "r", tostring(#es))
	check("写帧 1B=0xAA", writes(ck)[1][1] == 0xAA and #writes(ck)[1] == 1)
	check("回读纯读 n=1", read_sizes(ck)[1] == 1)
	check("call 零睡眠", sleep_total == 0, tostring(sleep_total))
end

-- 不传 out：纯读，无写事务，PINS/OUT 保持上一拍锁存
local ck2 = window()
r = expect_ok("call 纯读引脚", function() return call({ fd = fd, address = "0x20" }) end)
if r then
	check("纯读 PINS=0xAA", r.PINS == 0xAA, string.format("%X", r.PINS))
	check("纯读 OUT 保持 0xAA", r.OUT == 0xAA, string.format("%X", r.OUT))
end
check("纯读事务 set+r 共 2 条", #entries(ck2) == 2)
check("纯读窗口 0 写", nwr(ck2) == 0)
check("纯读窗口 1 读", nrd(ck2) == 1)

-- build 出的初始锁存被 call 继承
section()
build_ok({ out = "15" })
r = expect_ok("call 继承 build 的 OUT=0x0F", function() return call({ fd = fd, address = "0x20" }) end)
if r then
	check("OUT=0x0F", r.OUT == 0x0F, string.format("%X", r.OUT))
	check("PINS=0x0F", r.PINS == 0x0F, string.format("%X", r.PINS))
end

-- 准双向语义闭环：弱上拉被外部拉低、强驱低、释放恢复
section()
build_ok()
dev:set_pull_low(0xF0)
r = expect_ok("弱上拉高 4 位被外部拉低", function() return call({ fd = fd, address = "0x20", out = "255" }) end)
if r then
	check("OUT=0xFF", r.OUT == 0xFF)
	check("PINS=0x0F（外部低胜弱上拉）", r.PINS == 0x0F, string.format("%X", r.PINS))
end
r = expect_ok("强驱动低", function() return call({ fd = fd, address = "0x20", out = "0" }) end)
if r then
	check("PINS=0x00（外部掩码不再相关）", r.PINS == 0x00, string.format("%X", r.PINS))
end
dev:release_all()
r = expect_ok("释放外部后写回 FF", function() return call({ fd = fd, address = "0x20", out = "255" }) end)
if r then
	check("PINS=0xFF 恢复", r.PINS == 0xFF, string.format("%X", r.PINS))
end

-- 单脚 pull/release 经真实 call 回读
section()
build_ok()
dev:pull(0)
r = call({ fd = fd, address = "0x20" })
check("P0 被拉低 PINS=0xFE", r.PINS == 0xFE, string.format("%X", r.PINS))
dev:pull(4)
r = call({ fd = fd, address = "0x20" })
check("P0+P4 拉低 PINS=0xEE", r.PINS == 0xEE, string.format("%X", r.PINS))
dev:release(0)
r = call({ fd = fd, address = "0x20" })
check("释放 P0 PINS=0xEF", r.PINS == 0xEF, string.format("%X", r.PINS))

-- virt_tick 闭环：守护姿势（每拍 tick 后纯读 call），8 拍 walking 全不同
section()
build_ok()
local seen = {}
for n = 0, 7 do
	dev:virt_tick(n)
	local rr = call({ fd = fd, address = "0x20" })
	check(string.format("守护 tick%d 纯读 PINS=%d OUT=255", n, 255 - 2 ^ n),
		rr.result == "OK" and rr.PINS == 255 - 2 ^ n and rr.OUT == 0xFF,
		rr.result == "OK" and string.format("%d/%d", rr.PINS, rr.OUT) or tostring(rr.message))
	seen[rr.PINS] = true
end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check("8 拍 PINS 8 个不同值（E2E count 断言依据）", distinct == 8, tostring(distinct))
-- tick 后带 out 的 call：锁存被改写，引脚 = 新锁存 & ~掩码
dev:virt_tick(0)	-- pull=0x01
r = call({ fd = fd, address = "0x20", out = "0" })
check("tick 中写 0 强驱低 PINS=0", r.PINS == 0, string.format("%X", r.PINS))

-- ---- call 负路径 ----
section()
build_ok()
expect_err("call out 256 越界", function() return call({ fd = fd, address = "0x20", out = "256" }) end,
	"range 0~255")
expect_err("call out -1 越界", function() return call({ fd = fd, address = "0x20", out = "-1" }) end,
	"range 0~255")
-- out 非数字串：驱动跳过写当纯读（宽松事实）
r = call({ fd = fd, address = "0x20", out = "zzz" })
check("out='zzz' 当纯读 OK", r.result == "OK" and r.PINS == 0xFF,
	string.format("%s/%s", tostring(r.result), tostring(r.PINS)))

local cm2 = section()
expect_err("call 非表", function() return call(2) end, "Invalid Arguments Type")
check("call 非表零事务", #entries(cm2) == 0)

cm2 = section()
expect_err("call 缺 fd/address", function() return call({ fd = fd }) end, "fd or address")
check("缺 fd 零事务", #entries(cm2) == 0)

cm2 = section()
expect_err("call set_addr 失败", function() return call({ fd = 99, address = "0x20" }) end,
	"set_addr failed")

cm2 = section()
build_ok()
dev.nack_write = true
local cm3 = window()
expect_err("call 锁存写 NACK", function() return call({ fd = fd, address = "0x20", out = "1" }) end,
	"latch write failed")
check("写 NACK：set+失败写、无回读", nwr(cm3) == 1 and nrd(cm3) == 0 and #set_addrs(cm3) == 1,
	string.format("set=%d r=%d w=%d", #set_addrs(cm3), nrd(cm3), nwr(cm3)))
dev.nack_write = false
dev.nack_read = true
cm3 = window()
expect_err("call 引脚读 NACK", function() return call({ fd = fd, address = "0x20" }) end,
	"read failed")
check("读 NACK：set+1 纯读、0 写", nrd(cm3) == 1 and nwr(cm3) == 0 and #set_addrs(cm3) == 1,
	string.format("set=%d r=%d w=%d", #set_addrs(cm3), nrd(cm3), nwr(cm3)))
dev:clear_faults()

-- =====================================================================
-- 组 4：destroy（无关停寄存器，零总线事务）
-- =====================================================================
section()
build_ok()
local dk = window()
expect_ok("destroy OK", function() return destroy({ fd = fd, address = "0x20" }) end)
check("destroy 零总线事务", #entries(dk) == 0)

section()
expect_ok("destroy 空表也 OK", function() return destroy({}) end)
check("空表零事务", #entries(section()) == 0)

section()
expect_err("destroy 非表", function() return destroy(nil) end, "Invalid Arguments Type")
check("destroy 非表零事务", #entries(section()) == 0)

-- 26.3b NaN 配置列拒绝（out 走 finite_of）
section()
expect_ok("build out='nan' 归缺省 0xFF（finite_of 返回 nil → 走缺省分支）",
          function() return build({ fd = fd, address = "0x20", out = "nan" }) end)

section()
build_ok()
expect_ok("call out='nan' 跳过写（finite_of 返回 nil → 条件不满足）",
          function() return call({ fd = fd, address = "0x20", out = "nan" }) end)
local ck = window()
check("call out='nan' 零写事务（仅读引脚）",
      #writes(ck) == 0, tostring(#writes(ck)))

tester.summary("test_pcf8574")

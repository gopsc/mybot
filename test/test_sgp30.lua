-- test_sgp30.lua —— SGP30 真实驱动 + 虚拟 I2C 总线 + 命令字/CRC/载荷模型
-- 用法（项目根目录）: luajit test/test_sgp30.lua（驱动依赖 HAL ffi，需 LuaJIT）
--
-- 从「dofile 驱动后替换 i2c_* 全局的手写桩」迁移到「真实驱动 + virtbus
-- 注入层 + 内嵌模型（modules/SGP30.lua 尾部 SGP30_VIRT，2026-09-15
-- 自 virtbus/sgp30.lua 迁入）」。本器件是 virtbus 库【16 位命令字 +
-- 每数据字 CRC-8、且命令带读写数据载荷的命令式 I2C 器件】：无寄存器指针，
-- 写流首两字节恒 0x20xx 命令大端字（无载荷走 i2c_write_reg、带载荷走
-- i2c_write_multi），应答全部无指针纯读（i2c_read）。CRC-8 poly 0x31/
-- init 0xFF（向量 0xBEEF→0x92），模型/驱动/测试三份独立实现交叉。
--
-- 覆盖：模型侧 CRC 向量/三类待读应答（自检 0xD400 220ms 门、测量 12ms 门、
-- 基线 10ms 门）与读后失效/启动相 15s 固定 400,0/帧长与载荷内嵌 CRC 校验
--（Set_AH 5B、Set_baseline 8B，坏 CRC NACK 不更新）/非法命令字/六类钩子/
-- virt_tick warm+预武装；真实 build「自检 → Init」序列、睡眠 234ms 与
-- 9 路负路径（含坏字/坏 CRC/读失败/init 失败）、基线恢复四分支；真实 call
-- 的 AH 湿度命令（独立公式交叉、去重重发/坏帧重试）、测量 6 字节帧与
-- CRC_OK 降级、启动相→成熟切换、负路径；HAL.sys 内存文件 mock 下的基线
-- 周期存盘/destroy 存盘/重建恢复/全 0 不覆盖；destroy 零事务。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x58
-- 模型内嵌于驱动文件（SGP30_VIRT 全局工厂，CRC-8 公开在工厂表字段）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/SGP30.lua")
local smod = SGP30_VIRT

local dev = smod.new()
vbus.attach("SGP30@0x58", ADDR, dev)

local HALT = dofile("modules/lib/HAL.lua")	-- 守卫返回同一张 HAL 表

-- ==================== 独立 CRC8 / AH 公式（与模型、驱动三方交叉） ====================
local bitc = dofile("modules/bitcompat.lua")
local function crc8(word)
	local crc = 0xFF
	for _, b in ipairs({ math.floor(word / 256) % 256, word % 256 }) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.band(bitc.bxor(bitc.lshift(crc, 1), 0x31), 0xFF)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end
local function ah_ticks_of(t, rh)	-- Sensirion 绝对湿度公式独立重算
	local ah = 216.7 * (rh / 100.0 * 6.112 * math.exp(17.62 * t / (243.12 + t)) / (273.15 + t))
	return math.floor(ah * 256 + 0.5)
end

-- milli_sleep：累计时长 + 推进转换虚拟时钟（驱动运行时解析全局名）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms; dev:advance(ms) end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function word16(bs, i) return bs[i] * 256 + bs[i + 1] end

-- ==================== HAL.sys 内存文件 mock（基线持久化，不触真实 FS） ====================
local files = {}
local next_ffd = 10
local fds = {}
HALT.sys.open = function(path, flags)
	if flags ~= 0 and files[path] == nil then files[path] = "" end	-- 写打开视作 O_CREAT
	if files[path] == nil then return -1 end
	next_ffd = next_ffd + 1
	fds[next_ffd] = { path = path, off = 0 }
	return next_ffd
end
HALT.sys.read = function(ffd, buf, n)
	local e = fds[ffd]
	local s = files[e.path]
	local cnt = math.min(n, #s - e.off)
	for i = 0, cnt - 1 do buf[i] = s:byte(e.off + i + 1) end
	e.off = e.off + cnt
	return cnt
end
HALT.sys.write = function(ffd, buf, n)
	local bytes = {}
	for i = 0, n - 1 do bytes[#bytes + 1] = string.char(math.floor(tonumber(buf[i]))) end
	files[fds[ffd].path] = table.concat(bytes)	-- O_TRUNC 语义
	return n
end
HALT.sys.close = function(ffd) fds[ffd] = nil; return 0 end

-- os.time 桩（基线存盘节拍）
local now_s = 1000000000
local real_time = os.time
os.time = function() return now_s end

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
local function cmd_words(mark)
	local t = {}
	for _, x in ipairs(writes(mark)) do t[#t + 1] = x[1] * 256 + x[2] end
	return t
end
local function has_cmd(mark, w)
	for _, c in ipairs(cmd_words(mark)) do if c == w then return true end end
	return false
end
local function count_cmd(mark, w)
	local n = 0
	for _, c in ipairs(cmd_words(mark)) do if c == w then n = n + 1 end end
	return n
end

-- ======================================================================
-- 组 1：模型协议事实（直连模型）
-- ======================================================================
local mark = section()

check("CRC8 datasheet 向量 0xBEEF→0x92", crc8(0xBEEF) == 0x92,
	string.format("%02X", crc8(0xBEEF)))
check("模型/测试 CRC 实现一致（多点）",
	smod.crc8(0xD400) == crc8(0xD400) and smod.crc8(400) == crc8(400)
	and smod.crc8(0x1234) == crc8(0x1234))

-- 空闲：无待读，任何长度纯读 NACK
check("空闲纯读 3/6 字节均 NACK", dev.read(3) == nil and dev.read(6) == nil)

-- 自检：0x2032 → 220ms 门 → 3 字节 0xD400+CRC，读后失效
check("自检写 2032 成功", dev.write({ 0x20, 0x32 }) == true)
check("自检门限前读 NACK（0ms）", dev.read(3) == nil)
dev:advance(219)
check("自检 219ms 未就绪（datasheet max 220）", dev.read(3) == nil)
dev:advance(1)
local sb = dev.read(3)
check("自检 220ms 帧 D400+CRC", sb and word16(sb, 1) == 0xD400 and sb[3] == crc8(0xD400),
	sb and string.format("%02X%02X%02X", sb[1], sb[2], sb[3]) or "nil")
check("自检应答读后失效", dev.read(3) == nil)

-- Init + 启动相 + 测量门
check("Init 2003 成功", dev.write({ 0x20, 0x03 }) == true)
dev:set_raw(800, 123)
check("测量写 2008 成功", dev.write({ 0x20, 0x08 }) == true)
dev:advance(11)
check("测量 11ms 未就绪（max 12）", dev.read(6) == nil)
dev:advance(1)
local mb = dev.read(6)
check("启动相测量帧 = 400/0（15s 内固定输出）", mb
	and word16(mb, 1) == 400 and mb[3] == crc8(400)
	and word16(mb, 4) == 0 and mb[6] == crc8(0),
	mb and string.format("%d,%d", word16(mb, 1), word16(mb, 4)) or "nil")
check("测量应答读后失效", dev.read(6) == nil)
-- 长度守卫
-- 至此 iaq_ms=12（上轮测量门 11+1 的 advance 也在累计）：再推 14976，
-- 叠加本轮测量门 12ms 后恰满 15000，进入成熟相
dev:advance(14976)
check("度过 15s 启动相后二次测量", dev.write({ 0x20, 0x08 }) == true)
dev:advance(12)
check("测量待读读 3 字节 NACK", dev.read(3) == nil)
check("测量待读读 4 字节 NACK", dev.read(4) == nil)
local mm = dev.read(6)
check("成熟相报注入值 800/123", mm and word16(mm, 1) == 800 and word16(mm, 4) == 123,
	mm and string.format("%d,%d", word16(mm, 1), word16(mm, 4)) or "nil")

-- 帧长与载荷校验
section()
check("1 字节写 NACK", dev.write({ 0x20 }) == false)
check("纯命令 3 字节写 NACK", dev.write({ 0x20, 0x08, 0x00 }) == false)
check("非 0x20 族命令 3682 NACK", dev.write({ 0x36, 0x82 }) == false)
check("未建模字入 bad_commands", #dev:bad_commands() == 1 and dev:bad_commands()[1] == 0x3682)
check("长度错误不入识别序列", dev:cmd_count() == 0)
local ticks = ah_ticks_of(25.0, 40.0)
check("Set_AH 4 字节短帧 NACK",
	dev.write({ 0x20, 0x61, math.floor(ticks / 256) % 256, ticks % 256 }) == false)
check("Set_AH 内嵌坏 CRC NACK", dev.write({ 0x20, 0x61, 0x00, 0x10, 0x00 }) == false)
check("坏写 CRC 计数=1", dev:bad_write_crc_count() == 1)
check("坏 CRC 时 AH 不更新", dev:ah_word() == nil)
check("Set_AH 5 字节正确帧 ACK",
	dev.write({ 0x20, 0x61, math.floor(ticks / 256) % 256, ticks % 256, crc8(ticks) }) == true)
check("AH 字存储=独立公式 ticks", dev:ah_word() == ticks,
	string.format("%d vs %d", dev:ah_word() or -1, ticks))
local ahp = dev:payload_of(0x2061)
check("AH 载荷留痕 3 字节", ahp and #ahp == 3 and ahp[3] == crc8(ticks))
check("Set_baseline 7 字节短帧 NACK",
	dev.write({ 0x20, 0x1E, 0xAA, 0xAA, crc8(0xAAAA), 0xBB, 0xBB }) == false)
check("Set_baseline 8 字节好帧 ACK",
	dev.write({ 0x20, 0x1E, 0xAA, 0xAA, crc8(0xAAAA), 0xBB, 0xBB, crc8(0xBBBB) }) == true)
do
	local b1, b2 = dev:baseline()
	check("基线两字存储", b1 == 0xAAAA and b2 == 0xBBBB, string.format("%04X/%04X", b1, b2))
end

-- Get_baseline：门 10ms + 6 字节 + set→get 一致
check("Get_baseline 2015 成功", dev.write({ 0x20, 0x15 }) == true)
dev:advance(9)
check("基线 9ms 未就绪", dev.read(6) == nil)
dev:advance(1)
local gb = dev.read(6)
check("基线帧 AAAA+crc | BBBB+crc", gb and word16(gb, 1) == 0xAAAA and gb[3] == crc8(0xAAAA)
	and word16(gb, 4) == 0xBBBB and gb[6] == crc8(0xBBBB))
check("基线应答读后失效", dev.read(6) == nil)
-- 基线载荷内嵌坏 CRC：NACK 且保持旧值
dev:set_baseline(0x1111, 0x2222)
check("Set_baseline 内嵌坏 CRC NACK",
	dev.write({ 0x20, 0x1E, 0x99, 0x99, crc8(0x9999), 0x88, 0x88, (crc8(0x8888) + 1) % 256 }) == false)
do
	local b1, b2 = dev:baseline()
	check("坏 CRC 帧不更新基线", b1 == 0x1111 and b2 == 0x2222)
end

-- 自检坏字注入
section()
dev:set_selftest_word(0x1234)
dev.write({ 0x20, 0x32 }); dev:advance(220)
local bw = dev.read(3)
check("自检坏字按注入回读且 CRC 自洽", bw and word16(bw, 1) == 0x1234 and bw[3] == crc8(0x1234))

-- 坏应答 CRC 钩子（三类应答）
section()
dev:corrupt_crc(true)
dev.write({ 0x20, 0x32 }); dev:advance(220)
local cs = dev.read(3)
check("corrupt：自检 CRC 翻转", cs and cs[3] ~= crc8(0xD400))
dev.write({ 0x20, 0x15 }); dev:advance(10)
local cb = dev.read(6)
check("corrupt：基线双 CRC 翻转", cb and cb[3] ~= crc8(0x1234) and cb[6] ~= crc8(0x5678))
dev.write({ 0x20, 0x08 }); dev:advance(12)
local cm = dev.read(6)
check("corrupt：测量双 CRC 翻转（数据字节不动）", cm and cm[1] == 0x01 and cm[2] == 0x90
	and cm[3] ~= crc8(400) and cm[6] ~= crc8(0))
dev:reset()
check("reset 保留 corrupt 钩子", (function()
	dev.write({ 0x20, 0x32 }); dev:advance(220)
	local x = dev.read(3)
	return x and x[3] ~= crc8(0xD400)
end)())
dev:clear_faults(); dev:reset()
dev.write({ 0x20, 0x32 }); dev:advance(220)
check("clear_faults 后 CRC 恢复", (function()
	local x = dev.read(3)
	return x and x[3] == crc8(0xD400)
end)())

-- 定向谓词与 nack 字段
section()
dev:fail_cmd(function(w) return w == 0x2032 end)
check("fail_cmd 只断自检", dev.write({ 0x20, 0x32 }) == false
	and dev.write({ 0x20, 0x03 }) == true)
dev:clear_faults()
dev:fail_read(function(p) return p == "measure" end)
dev.write({ 0x20, 0x32 }); dev:advance(220)
check("fail_read 不误伤自检读", dev.read(3) ~= nil)
dev.write({ 0x20, 0x08 }); dev:advance(12)
check("fail_read 断测量读", dev.read(6) == nil)
dev:clear_faults()
dev.nack_write = true
check("nack_write 写拒绝", dev.write({ 0x20, 0x03 }) == false)
dev.nack_write = false
dev.write({ 0x20, 0x08 })
dev.nack_read = true
check("nack_read 读拒绝", dev.read(6) == nil)
dev.nack_read = false
dev.nack = true
check("nack 全断写读", dev.write({ 0x20, 0x03 }) == false and dev.read(3) == nil)
dev.nack = false

-- virt_tick：确定性正弦 + warm（度过启动相）+ 预武装（零转换门）
section()
local function tick_vals(n)
	dev:virt_tick(n)
	dev.write({ 0x20, 0x03 }); dev.write({ 0x20, 0x08 })
	local b = dev.read(6)	-- 预武装：无 advance
	return word16(b, 1), word16(b, 4)
end
local c0a, t0a = tick_vals(0)
local c0b, t0b = (function()
	local d2 = smod.new(); d2:virt_tick(0); d2.write({ 0x20, 0x03 }); d2.write({ 0x20, 0x08 })
	local b = d2.read(6)
	return word16(b, 1), word16(b, 4)
end)()
check("virt_tick 确定性（两实例同拍）", c0a == c0b and t0a == t0b,
	string.format("%d/%d vs %d/%d", c0a, t0a, c0b, t0b))
check("virt_tick warm：不报启动相 400/0", c0a ~= 400 and t0a ~= 0,
	string.format("%d/%d", c0a, t0a))
check("virt_tick 预武装零等待", dev:is_ready())
local c8, t8 = 0
do
	dev:virt_tick(8); dev.write({ 0x20, 0x08 })
	local b = dev.read(6)
	c8, t8 = word16(b, 1), word16(b, 4)
end
check("virt_tick n8 峰点 CO2=700", c8 == 700, tostring(c8))
check("virt_tick 幅值在合理 IAQ 区间", c0a >= 400 and c0a <= 700 and t0a >= 40 and t0a <= 200,
	string.format("%d/%d", c0a, t0a))

-- reset 还原种子
section()
dev:set_raw(999, 888); dev:set_baseline(1, 2)
dev.write({ 0x20, 0x61, 0x00, 0x64, crc8(0x0064) })
dev:reset()
do
	local c, t = dev:raw()
	local b1, b2 = dev:baseline()
	check("reset 还原测量种子 400/0 与基线 1234/5678",
		c == 400 and t == 0 and b1 == 0x1234 and b2 == 0x5678)
end
check("reset 清 AH", dev:ah_word() == nil)
check("reset 后空闲纯读 NACK", dev.read(6) == nil)

-- ======================================================================
-- 组 2：真实 build（自检 0x2032 → Init 0x2003）
-- ======================================================================
mark = section()
local r = expect_ok("build 默认（无基线列）",
	function() return build({ fd = fd, address = "0x58" }) end)
if r then
	check("build set_addr 留痕 0x58", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x58)
	local ws = writes(mark)
	check("build 恰好 2 笔命令写", #ws == 2, tostring(#ws))
	check("build 命令序 2032 → 2003",
		cmd_words(mark)[1] == 0x2032 and cmd_words(mark)[2] == 0x2003,
		table.concat((function() local t = {} for _, w in ipairs(cmd_words(mark)) do t[#t+1] = string.format("%04X", w) end return t end)(), ","))
	check("build 一次 3 字节纯读（无指针写）", #reads(mark) == 1 and reads(mark)[1] == 3,
		table.concat(reads(mark), ","))
	check("build 睡眠 222+12=234ms", sleep_total == 234, tostring(sleep_total))
end

-- 无基线文件：不恢复
mark = section()
r = expect_ok("build baseline 文件不存在 → fresh",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/nope" }) end)
if r then check("无文件不下发 Set_baseline", not has_cmd(mark, 0x201E)) end

-- 基线恢复成功
files["/mock/good"] = (function()
	local s = ""
	for _, w in ipairs({ 0x89AB, 0xCDEF }) do
		s = s .. string.char(math.floor(w / 256) % 256, w % 256, crc8(w))
	end
	return s
end)()
mark = section()
r = expect_ok("build 合法基线文件 → 恢复",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/good" }) end)
if r then
	check("恢复下发 Set_baseline", count_cmd(mark, 0x201E) == 1)
	local ws = writes(mark)
	local setf
	for _, x in ipairs(ws) do
		if x[1] * 256 + x[2] == 0x201E then setf = x end
	end
	check("Set_baseline 帧 8 字节 = 文件 6 字节内容", setf and #setf == 8
		and setf[3] == 0x89 and setf[4] == 0xAB and setf[5] == crc8(0x89AB)
		and setf[6] == 0xCD and setf[7] == 0xEF and setf[8] == crc8(0xCDEF),
		setf and table.concat((function() local t = {} for _, b in ipairs(setf) do t[#t+1] = string.format("%02X", b) end return t end)(), " ") or "nil")
	check("恢复多睡 12ms（234+12=246）", sleep_total == 246, tostring(sleep_total))
end

-- 基线恢复跳过分支
files["/mock/badcrc"] = string.char(0x12, 0x34, 0x00, 0x56, 0x78, 0x00)
files["/mock/short"] = string.char(0x12, 0x34, 0x00)
files["/mock/zero"] = (function()
	local s = ""
	for _, w in ipairs({ 0, 0 }) do s = s .. string.char(0, 0, crc8(w)) end
	return s
end)()
mark = section()
expect_ok("build 基线文件 CRC 坏 → 安全跳过",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/badcrc" }) end)
check("坏 CRC 文件不下发 Set_baseline", not has_cmd(mark, 0x201E))
mark = section()
expect_ok("build 基线短文件 → 跳过",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/short" }) end)
check("短文件不下发 Set_baseline", not has_cmd(mark, 0x201E))
mark = section()
expect_ok("build 全 0 基线 → 跳过",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/zero" }) end)
check("全 0 不下发 Set_baseline", not has_cmd(mark, 0x201E))

-- build 负路径
section()
expect_err("build 非 table 参数", function() return build("x") end, "Invalid Arguments Type")
expect_err("build 缺 fd", function() return build({ address = "0x58" }) end, "fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end, "fd or address")
expect_err("build 未打开 fd set_addr 失败",
	function() return build({ fd = 99, address = "0x58" }) end, "set_addr failed")

section()
dev:fail_cmd(function(w) return w == 0x2032 end)
expect_err("build 自检写失败（器件无应答）",
	function() return build({ fd = fd, address = "0x58" }) end, "not responding")

section()
dev:fail_read(function(p) return p == "selftest" end)
expect_err("build 自检读失败",
	function() return build({ fd = fd, address = "0x58" }) end, "Failed to read SGP30 selftest")

section()
dev:set_selftest_word(0x1234)
expect_err("build 自检字错误",
	function() return build({ fd = fd, address = "0x58" }) end, "selftest failed")

section()
dev:corrupt_crc(true)
expect_err("build 自检 CRC 坏",
	function() return build({ fd = fd, address = "0x58" }) end, "selftest failed")

section()
dev:fail_cmd(function(w) return w == 0x2003 end)
expect_err("build Init 写失败",
	function() return build({ fd = fd, address = "0x58" }) end, "Failed to send SGP30 Init")

-- ======================================================================
-- 组 3：真实 call（湿度命令 → 测量 2008 → 14ms → 纯读 6 字节）
-- ======================================================================
mark = section()
build({ fd = fd, address = "0x58" })
mark = #vbus.txlog
local sleep_base = sleep_total	-- 截掉 build 的 234ms
r = expect_ok("call 启动相默认测量 400/0",
	function() return call({ fd = fd, address = "0x58" }) end)
if r then
	check("call set_addr 留痕 0x58", #set_addrs(mark) == 1 and set_addrs(mark)[1] == 0x58)
	check("call 唯一命令写 2008", count_cmd(mark, 0x2008) == 1 and #writes(mark) == 1,
		tostring(#writes(mark)))
	check("无补偿输入不下发 AH", not has_cmd(mark, 0x2061))
	check("call 一次 6 字节纯读", #reads(mark) == 1 and reads(mark)[1] == 6)
	check("call 睡眠 14ms", sleep_total - sleep_base == 14, tostring(sleep_total - sleep_base))
	check("CO2EQ=400 / TVOC=0", r.CO2EQ == 400 and r.TVOC == 0,
		string.format("%s/%s", tostring(r.CO2EQ), tostring(r.TVOC)))
	check("CRC_OK=1", r.CRC_OK == 1, tostring(r.CRC_OK))
end

-- 启动相 → 成熟相切换（真实驱动路径）
mark = section()
build({ fd = fd, address = "0x58" })
dev:advance(15000)	-- 度过启动相（iaq 虚拟时钟）
dev:set_raw(812, 137)
mark = #vbus.txlog
r = expect_ok("call 成熟相注入值 812/137",
	function() return call({ fd = fd, address = "0x58" }) end)
if r then
	check("CO2EQ=812 / TVOC=137", r.CO2EQ == 812 and r.TVOC == 137,
		string.format("%s/%s", tostring(r.CO2EQ), tostring(r.TVOC)))
end

-- 湿度补偿：AH 帧载荷与独立公式交叉
mark = section()
build({ fd = fd, address = "0x58" })	-- build 清 last_ah_ticks
mark = #vbus.txlog
local sleep_base = sleep_total	-- 截掉 build 的 234ms
local ticks25 = ah_ticks_of(25.0, 40.0)
r = expect_ok("call 湿度补偿 25C/40%",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = 40.0 })
	end)
if r then
	check("补偿拍下发 Set_AH", count_cmd(mark, 0x2061) == 1)
	local af
	for _, x in ipairs(writes(mark)) do
		if x[1] * 256 + x[2] == 0x2061 then af = x end
	end
	check("AH 帧 5 字节且 ticks=独立公式", af and #af == 5
		and af[3] == math.floor(ticks25 / 256) % 256 and af[4] == ticks25 % 256
		and af[5] == crc8(ticks25),
		af and string.format("%d vs %d", af[3] * 256 + af[4], ticks25) or "nil")
	check("AH 帧 CRC 模型也认可", af and smod.crc8(af[3] * 256 + af[4]) == af[5])
	check("补偿拍睡眠 12(AH)+14(测量)=26ms", sleep_total - sleep_base == 26,
		tostring(sleep_total - sleep_base))
end
-- 模型侧记录的 AH 字与公式一致
check("模型 AH 观察口一致", dev:ah_word() == ticks25)

mark = #vbus.txlog
expect_ok("call 湿度不变不重发 AH",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = 40.0 })
	end)
check("相同 AH 跳过 2061", not has_cmd(mark, 0x2061))

mark = #vbus.txlog
expect_ok("call 湿度变化重发 AH",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 30.0,
		              rh_field = "v1", v1 = 40.0 })
	end)
check("变化后重新下发 2061", count_cmd(mark, 0x2061) == 1)

-- 异常补偿输入：不下发、不影响测量
mark = #vbus.txlog
r = expect_ok("call RH 越界 101 跳过补偿",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = 101 })
	end)
if r then check("越界 RH 不下发 AH", not has_cmd(mark, 0x2061)) end
-- 审计 P3：非有限补偿输入。NaN 会让 `rh < 0 or rh > 100` 恒假、
-- ah_ticks_of 里的 0..0xFFFF 钳位同样拦不住，一路走到 send_cmd 才在 HAL 的
-- byte_of 处炸——末态安全但层次错、报错落在总线层。现在按本函数契约
-- 「输入异常返回 nil」在正确的层跳过补偿，主测量不受影响。
mark = #vbus.txlog
r = expect_ok("call RH=nan 跳过补偿",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = "nan" })
	end)
if r then check("非有限 RH 不下发 AH", not has_cmd(mark, 0x2061)) end
mark = #vbus.txlog
r = expect_ok("call T=inf 跳过补偿",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = "1e400",
		              rh_field = "v1", v1 = 40.0 })
	end)
if r then check("非有限 T 不下发 AH", not has_cmd(mark, 0x2061)) end
mark = #vbus.txlog
r = expect_ok("call 缺快照键跳过补偿",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0",
		              rh_field = "v1", v1 = 40.0 })
	end)
if r then check("缺 t 快照不下发 AH", not has_cmd(mark, 0x2061)) end

-- AH 写失败：call 不中断，下拍同值重试（last_ah 未更新）
section()
build({ fd = fd, address = "0x58" })
dev:fail_cmd(function(w) return w == 0x2061 end)
mark = #vbus.txlog
r = expect_ok("call AH 写器件拒绝仍测量成功",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = 40.0 })
	end)
if r then
	check("拒绝拍测量照常", r.result == "OK" and r.CO2EQ == 400)
	check("拒绝拍 AH 不入模型状态", dev:ah_word() == nil)
end
dev:clear_faults()
mark = #vbus.txlog
expect_ok("call 下拍同值重试 AH",
	function()
		return call({ fd = fd, address = "0x58", t_field = "v0", v0 = 25.0,
		              rh_field = "v1", v1 = 40.0 })
	end)
check("重试拍下发 2061", count_cmd(mark, 0x2061) == 1)
check("重试后模型记录 AH", dev:ah_word() == ticks25)

-- 测量 CRC 坏：标志位降级，不报错
section()
build({ fd = fd, address = "0x58" })
dev:corrupt_crc(true)
r = expect_ok("call 测量帧 CRC 坏 → OK + CRC_OK=0",
	function() return call({ fd = fd, address = "0x58" }) end)
if r then
	check("CRC_OK=0（兼容契约）", r.CRC_OK == 0, tostring(r.CRC_OK))
	check("坏 CRC 不动数据（启动相仍 400）", r.CO2EQ == 400)
end
dev:clear_faults()

-- virt_tick 预武装成熟样本经真实驱动
section()
build({ fd = fd, address = "0x58" })
dev:virt_tick(8)	-- CO2 峰 700
r = expect_ok("call virt_tick(8) 预武装样本",
	function() return call({ fd = fd, address = "0x58" }) end)
if r then
	check("tick(8) CO2EQ=700", r.CO2EQ == 700, tostring(r.CO2EQ))
	check("virt_tick 帧 CRC_OK=1", r.CRC_OK == 1)
end

-- call 负路径
section()
build({ fd = fd, address = "0x58" })
expect_err("call 非 table 参数", function() return call(123) end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x58" }) end, "fd or address")
expect_err("call 缺 address", function() return call({ fd = fd }) end, "fd or address")
expect_err("call 未打开 fd set_addr 失败",
	function() return call({ fd = 99, address = "0x58" }) end, "set_addr failed")

section()
build({ fd = fd, address = "0x58" })
dev:fail_cmd(function(w) return w == 0x2008 end)
expect_err("call 测量写失败（无应答）",
	function() return call({ fd = fd, address = "0x58" }) end, "measure write failed")

section()
build({ fd = fd, address = "0x58" })
dev:fail_read(function(p) return p == "measure" end)
expect_err("call 测量读失败",
	function() return call({ fd = fd, address = "0x58" }) end, "Failed to read SGP30")

-- ======================================================================
-- 组 4：基线持久化（周期存盘 / destroy / 重建恢复）与 destroy 零事务
-- ======================================================================
files["/mock/base"] = nil
mark = section()
expect_ok("build 启用持久化（无文件）",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/base" }) end)

now_s = now_s + 3600	-- 触发周期存盘
mark = #vbus.txlog
r = expect_ok("call 触发周期存盘",
	function() return call({ fd = fd, address = "0x58" }) end)
if r then
	check("周期存盘下发 Get_baseline", count_cmd(mark, 0x2015) == 1)
	-- 该拍两次纯读：测量 6B + Get_baseline 6B
	local rs = reads(mark)
	check("存盘读两次均 6 字节", #rs == 2 and rs[1] == 6 and rs[2] == 6,
		table.concat(rs, ","))
end
local saved = files["/mock/base"]
check("基线文件落盘 6 字节", saved ~= nil and #saved == 6, saved and tostring(#saved) or "nil")
do
	local b1, b2 = dev:baseline()
	check("文件内容 = 模型基线两字+双 CRC", saved
		and saved:byte(1) == math.floor(b1 / 256) % 256 and saved:byte(2) == b1 % 256
		and saved:byte(3) == crc8(b1) and saved:byte(4) == math.floor(b2 / 256) % 256
		and saved:byte(5) == b2 % 256 and saved:byte(6) == crc8(b2))
end

now_s = now_s + 60	-- 未到周期
mark = #vbus.txlog
expect_ok("call 60s 内不重复存盘",
	function() return call({ fd = fd, address = "0x58" }) end)
check("未到周期不下发 Get_baseline", not has_cmd(mark, 0x2015))

mark = #vbus.txlog
expect_ok("destroy 退出前再存一次",
	function() return destroy({ fd = fd, address = "0x58" }) end)
check("destroy 触发 Get_baseline", count_cmd(mark, 0x2015) == 1)

-- 重建：从文件恢复（与此前存盘内容逐字节一致）
mark = section()
local rb = expect_ok("重建后恢复基线",
	function() return build({ fd = fd, address = "0x58", baseline = "/mock/base" }) end)
if rb then
	local setf
	for _, x in ipairs(writes(mark)) do
		if x[1] * 256 + x[2] == 0x201E then setf = x end
	end
	check("重建下发 8 字节 Set_baseline", setf ~= nil and #setf == 8)
	check("恢复内容与存盘逐字节一致", setf and saved
		and setf[3] == saved:byte(1) and setf[4] == saved:byte(2) and setf[5] == saved:byte(3)
		and setf[6] == saved:byte(4) and setf[7] == saved:byte(5) and setf[8] == saved:byte(6))
end

-- 全 0 基线：Get 照常但不覆盖旧文件
section()
build({ fd = fd, address = "0x58", baseline = "/mock/base" })
dev:set_baseline(0, 0)
local before = files["/mock/base"]
mark = #vbus.txlog
expect_ok("destroy 全 0 基线不存盘",
	function() return destroy({ fd = fd, address = "0x58" }) end)
check("全 0 仍下发 Get_baseline", count_cmd(mark, 0x2015) == 1)
check("全 0 不覆盖旧文件", files["/mock/base"] == before)

-- destroy 缺 fd：安全返回且零总线事务
mark = section()
expect_ok("destroy 缺 fd 安全返回", function() return destroy({}) end)
check("destroy 缺 fd 零事务", #entries(mark) == 0, tostring(#entries(mark)))

os.time = real_time
tester.summary("test_sgp30")

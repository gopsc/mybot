-- test_as3935.lua —— AS3935 真实驱动 + 虚拟 I2C 总线 + 事件型模型
-- 用法（项目根目录）: luajit test/test_as3935.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：AS3935_GC=1 luajit test/test_as3935.lua
--
-- 从「dofile 驱动后替换 i2c_* 全局的 267 行手写桩」迁移到「真实驱动 +
-- virtbus 注入层 + 内嵌模型（modules/AS3935.lua 尾部 AS3935_VIRT，2026-09-15
-- 自 virtbus/as3935.lua 迁入）」。旧桩三处假绿已被严格模型
-- 戳破（按 SparkFun_AS3935_Arduino_Library / ESPHome as3935 与 datasheet
-- DS-AS3935 §8 寄存器表交叉钉死）：
--   1) 旧桩 regs[reg]=val 允许写只读区、写事件位、污染保留位——严格模型
--      按位掩码与只读丢弃；
--   2) 旧桩不模拟「读 0x03 清事件锁存」与 MASK_DIST/PWD 对注入的硬件门；
--   3) 旧桩校准状态可控但没建 0x3D=0x96 命令与 DONE(bit7)/NOK(bit6) 的
--      关系，严格模型命令即完成、NOK 由 set_calib_fail 注入决定。
--
-- 真实 build（milli_sleep 桩只累加不 advance——本器件无转换门）：
--   set + {3C,96} + {00}r1 在位甄别 + 7 笔 modify_reg（每笔 {ptr}r1+
--   {ptr,val}，共 21 txlog）+ {3D,96} + 显示位置 {08,C0}/睡 2ms/清 {08,00}
--   两笔 modify_reg（6 txlog）+ {3B}r1 SRCO + {3A}r1 TRCO
--   = set+23w+12r 共 36 txlog；睡眠 2+2=4ms。
-- 真实 call：set + 睡 2ms + {03}r1 = set+1w+1r 共 3 txlog（非闪电）；
--   闪电再 {07}r1 + 3×({ptr}r1) = 加 8 txlog，全序列 11 txlog。
--
-- 覆盖：模型 POR/ burst 自增与回绕/空间外 NACK/写掩码与只读丢弃/
-- INT 读后清且 RMW 不丢事件/MASK_DIST 屏蔽干扰/PWD 检测停摆/
-- 距离能量独立保留与 21 位编码/两条直接命令与错误数据忽略/
-- DONE/NOK 与校准失败注入/who 身份覆写/virt_tick 8 拍事件脚本/
-- 故障钩子；真实 build 逐笔写序列/12 读全 1B/横幅/字符串地址/
-- 室内外增益/各字段档与钳位/取档/六类 NACK 短路点/无器件地址/参数错误；
-- 真实 call 四事件优先级/读后清/距离三特殊值/能量边界/mask 下序列/
-- tick 驱动；call 四类总线失败与参数错误；destroy 安全。

if os.getenv("AS3935_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local ADDR = 0x03
local EVT_NOISE, EVT_DISTURBER, EVT_LIGHTNING = 0x01, 0x04, 0x08
-- 模型内嵌于驱动文件（AS3935_VIRT 全局工厂）：load_driver 完成驱动定义
-- 与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/AS3935.lua")
local mmod = AS3935_VIRT

local dev = mmod.new()

local dev = mmod.new()
vbus.attach("AS3935@0x03", ADDR, dev)

-- milli_sleep 桩：本器件无转换门，只累加（build 4ms / call 每拍 2ms）
local sleep_total = 0
function milli_sleep(ms) sleep_total = sleep_total + ms end

local fd = i2c_open("/dev/i2c-1")	-- 虚拟 fd 从 3 起
check("i2c_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 每个 section：器件回上电态 + 故障解除（挂载/fd 不动）
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
		if e.dir == "r" then t[#t + 1] = e end
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
local function wcode(b)
	local v = 0
	for i = 1, #b do v = v * 256 + b[i] end
	return v
end
local function wcodes(mark)
	local t = {}
	for _, b in ipairs(writes(mark)) do t[#t + 1] = wcode(b) end
	return t
end
local function same_seq(got, want)
	if #got ~= #want then return false end
	for i = 1, #want do
		if got[i] ~= want[i] then return false end
	end
	return true
end
local function seq_hex(mark)
	local t = {}
	for _, v in ipairs(wcodes(mark)) do t[#t + 1] = string.format("%X", v) end
	return table.concat(t, ",")
end
local function frame(b)
	if not b then return "nil" end
	local s = {}
	for i = 1, #b do s[i] = string.format("%02X", b[i]) end
	return table.concat(s, ",")
end

local function capture(fn)
	local cap, old = {}, print
	print = function(...) cap[#cap + 1] = table.concat({ ... }, "\t") end
	local ok, res = pcall(fn)
	print = old
	return ok, res, table.concat(cap, "|")
end

-- 直接走总线回调（脱驱动）
local function w(...) return dev.write({ ... }) end
local function r1(...) return dev.read(...) end

-- 录制 dev.read 返回帧（txlog 的 r 条目只记请求长度 n，帧内容靠这个留档）
local function recording(fn)
	local saved, got = dev.read, {}
	dev.read = function(n)
		local r = saved(n)
		got[#got + 1] = r
		return r
	end
	local a, b, c = fn()
	dev.read = saved
	return got, a, b, c
end

-- =====================================================================
-- 组 1：模型协议事实（脱驱动，直接点回调/调 API）
-- =====================================================================
local mark = section()

-- ---- POR ----
check("POR 0x00=0x24（PWD=0/AFE_GB=0x12 室内）", dev:reg(0x00) == 0x24,
	string.format("0x%02X", dev:reg(0x00)))
check("POR afe_gb()=0x12", dev:afe_gb() == 0x12, string.format("0x%X", dev:afe_gb()))
check("POR pwd=false", not dev:pwd())
check("POR 0x01=0x22（NF=2/WDTH=2）", dev:reg(0x01) == 0x22,
	string.format("0x%02X", dev:reg(0x01)))
check("POR nf_lev=2/wdth=2", dev:nf_lev() == 2 and dev:wdth() == 2,
	string.format("%d/%d", dev:nf_lev(), dev:wdth()))
check("POR 0x02=0x02（MIN_LIG=1 码 0/SREJ=2）", dev:reg(0x02) == 0x02)
check("POR min_lig_code=0/srej=2", dev:min_lig_code() == 0 and dev:srej() == 2)
check("POR 0x03=0x00（无事件/不屏蔽）", dev:reg(0x03) == 0x00)
check("POR event=0/mask=false", dev:event() == 0 and not dev:mask_dist())
check("POR 能量三字节 0", dev:reg(0x04) == 0 and dev:reg(0x05) == 0
	and dev:reg(0x06) == 0 and dev:energy() == 0)
check("POR 0x07=0x3F（距离超量程）", dev:reg(0x07) == 0x3F
	and dev:distance() == 0x3F, string.format("0x%02X", dev:distance()))
check("POR 0x08=0x00", dev:reg(0x08) == 0 and dev:tun_cap_code() == 0)
check("POR TRCO/SRCO 状态=0x00（未校准 DONE=0 NOK=0）",
	dev:trco_status() == 0 and dev:srco_status() == 0,
	string.format("%02X/%02X", dev:trco_status(), dev:srco_status()))
check("POR 命令寄存器不落盘（0x3C/0x3D=0）",
	dev:reg(0x3C) == nil and dev:reg(0x3D) == nil)
check("POR 计数器全 0", dev:reset_count() == 0 and dev:rco_count() == 0
	and dev:write_count() == 0)
check("POR ptr=nil（无指针纯读 NACK）", dev:ptr() == nil and r1(1) == nil)

-- ---- 8 位指针 / burst 自增 / 空间 ----
check("纯指针 {00} ACK", w(0x00) == true)
local s = r1(1)
check("读 1B = 0x24", s and #s == 1 and s[1] == 0x24, frame(s))
w(0x00)
s = r1(4)
check("burst 4B 自增 00~03 = 24,22,02,00",
	s and #s == 4 and s[1] == 0x24 and s[2] == 0x22 and s[3] == 0x02
	and s[4] == 0x00, frame(s))
w(0x3E)
s = r1(3)
check("burst 0x3E,0x3F 后回绕 0x00 = 00,00,24",
	s and s[1] == 0x00 and s[2] == 0x00 and s[3] == 0x24, frame(s))
check("指针 0x40（空间外）读 NACK", (w(0x40) and r1(1)) == nil)
check("空帧/坏字节 NACK", w() == false and dev.write({}) == false
	and dev.write({ 0x00, 0x100 }) == false)
check("纯指针写不计 write_count", dev:write_count() == 0,
	tostring(dev:write_count()))

-- ---- 配置寄存器写掩码（保留位丢弃）----
w(0x00, 0xFF)
check("写 0x00=FF 落 0x3F（bit[7:6] 保留）", dev:reg(0x00) == 0x3F,
	string.format("0x%02X", dev:reg(0x00)))
check("PWD 位随写生效", dev:pwd())
w(0x01, 0xFF)
check("写 0x01=FF 落 0x7F（bit7 保留）", dev:reg(0x01) == 0x7F)
w(0x02, 0xFF)
check("写 0x02=FF 落 0x3F（bit[7:6] 保留）", dev:reg(0x02) == 0x3F)
w(0x08, 0xFF)
check("写 0x08=FF 落 0xCF（bit[5:4] 保留）", dev:reg(0x08) == 0xCF,
	string.format("0x%02X", dev:reg(0x08)))
w(0x04, 0xAA)
check("能量 LSB 只读：写 ACK 丢弃", dev:reg(0x04) == 0)
w(0x07, 0x12)
check("距离只读：写不影响 0x3F", dev:reg(0x07) == 0x3F)
w(0x3A, 0xFF)
check("TRCO 状态只读", dev:reg(0x3A) == 0)

-- ---- 0x03 动态合成：RMW 不丢事件、主机写不清事件 ----
dev:reset()
dev:set_int_raw(0x08)
w(0x03, 0x20)
check("事件锁存中 RMW 置 MASK_DIST：0x03=0x28（事件保留）",
	dev:reg(0x03) == 0x28, string.format("0x%02X", dev:reg(0x03)))
check("mask_dist 观察口=true", dev:mask_dist())
w(0x03, 0x00)
check("RMW 清 MASK_DIST：0x03=0x08（事件仍保留，写不清事件）",
	dev:reg(0x03) == 0x08, string.format("0x%02X", dev:reg(0x03)))
w(0x03, 0xFF)
check("写 0x03=FF 仍只动 bit5（0x28），杂散位不落盘",
	dev:reg(0x03) == 0x28, string.format("0x%02X", dev:reg(0x03)))
w(0x03, 0x00)

-- ---- INT 读后清 + 距离能量独立保留 ----
dev:set_int_raw(0x04)
w(0x03); s = r1(1)
check("读 0x03 返回干扰码 0x04", s and s[1] == 0x04, frame(s))
check("读后事件码立即清零（bit5 无）", dev:reg(0x03) == 0x00
	and dev:event() == 0, string.format("0x%02X", dev:reg(0x03)))
check("dev:strike(10, 0x123456)", dev:strike(10, 0x123456) == true)
w(0x03); r1(1)
check("读 INT 不清距离/能量（0x07=10/energy=0x123456）",
	dev:distance() == 10 and dev:energy() == 0x123456,
	string.format("%d/%d", dev:distance(), dev:energy()))

-- ---- 21 位能量编码 / 距离边界 ----
dev:strike(63, 0x1FFFFF)
check("能量满码三字节 LSB=FF/MSB=FF/MMSB=1F",
	dev:reg(0x04) == 0xFF and dev:reg(0x05) == 0xFF and dev:reg(0x06) == 0x1F,
	string.format("%02X,%02X,%02X", dev:reg(0x04), dev:reg(0x05), dev:reg(0x06)))
check("energy()=0x1FFFFF=2097151", dev:energy() == 0x1FFFFF,
	tostring(dev:energy()))
check("距离码 63 直存", dev:distance() == 63)
dev:strike(1, 0)
check("能量 0 / 距离 1（头顶）", dev:energy() == 0 and dev:distance() == 1)
dev:strike(70, 9999999)
check("strike 钳制 dist<=63/energy<=0x1FFFFF",
	dev:distance() == 63 and dev:energy() == 0x1FFFFF)

-- ---- 事件注入与 MASK_DIST / PWD 硬件门 ----
dev:reset()
check("noise() 装 0x01", dev:noise() and dev:event() == EVT_NOISE)
w(0x03); r1(1)
check("disturber() 装 0x04", dev:disturber() and dev:event() == EVT_DISTURBER)
w(0x03); r1(1)
w(0x03, 0x20)						-- MASK_DIST=1
check("MASK_DIST=1 屏蔽 disturber（返回 false/无事件）",
	dev:disturber() == false and dev:event() == 0)
check("MASK_DIST 不屏蔽 noise", dev:noise() == true and dev:event() == 0x01)
w(0x03); r1(1)
check("MASK_DIST 不屏蔽 lightning",
	dev:strike(8, 123) == true and dev:event() == 0x08)
w(0x03); r1(1)
w(0x03, 0x00)						-- 解除屏蔽
check("解除后 disturber 恢复", dev:disturber() == true and dev:event() == 0x04)
w(0x03); r1(1)
w(0x00, 0x01)						-- PWD=1
check("PWD=1 下 strike/noise/disturber 全拒",
	dev:strike(1, 1) == false and dev:noise() == false
	and dev:disturber() == false and dev:event() == 0)
check("PWD 下 I2C 配置照读照写（0x01 落 0x72）",
	(w(0x01, 0x72) and dev:reg(0x01)) == 0x72)
w(0x00, 0x24)						-- 唤醒回室内增益
check("唤醒后注入恢复", dev:noise() == true)
w(0x03); r1(1)

-- ---- 直接命令 ----
dev:reset()
w(0x01, 0x7E)						-- 先改配置
check("软复位 {3C,96} ACK 且 reset_count=1",
	w(0x3C, 0x96) == true and dev:reset_count() == 1)
check("软复位后 0x01 回 POR 0x22", dev:reg(0x01) == 0x22,
	string.format("0x%02X", dev:reg(0x01)))
check("软复位后事件清空、距离回 0x3F", dev:event() == 0
	and dev:distance() == 0x3F)
w(0x3C)
check("命令寄存器读回 0（不落盘）", r1(1)[1] == 0x00)
check("错误命令数据 {3C,00} ACK 但不算复位",
	w(0x3C, 0x00) == true and dev:reset_count() == 1)
check("RCO 校准 {3D,96}：rco_count=1",
	w(0x3D, 0x96) == true and dev:rco_count() == 1)
check("校准完成 TRCO/SRCO=0x80（DONE=1/NOK=0）",
	dev:trco_status() == 0x80 and dev:srco_status() == 0x80,
	string.format("%02X/%02X", dev:trco_status(), dev:srco_status()))
w(0x3D)
check("0x3D 读回 0", r1(1)[1] == 0x00)
check("错误数据 {3D,00} 不算校准",
	w(0x3D, 0x00) == true and dev:rco_count() == 1)
dev:set_calib_fail("trco")
w(0x3D, 0x96)
check("注入 TRCO 失败：TRCO=0xC0/SRCO=0x80",
	dev:trco_status() == 0xC0 and dev:srco_status() == 0x80,
	string.format("%02X/%02X", dev:trco_status(), dev:srco_status()))
dev:set_calib_fail("srco")
w(0x3D, 0x96)
check("注入 SRCO 失败：TRCO=0x80/SRCO=0xC0",
	dev:trco_status() == 0x80 and dev:srco_status() == 0xC0)
dev:set_calib_fail(true)
w(0x3D, 0x96)
check("注入双失败：两状态 0xC0",
	dev:trco_status() == 0xC0 and dev:srco_status() == 0xC0)
dev:set_calib_fail(false)
w(0x3D, 0x96)
check("清除注入：两状态回 0x80",
	dev:trco_status() == 0x80 and dev:srco_status() == 0x80)

-- ---- who 身份覆写（软复位保留，完整 reset 恢复）----
dev:who(0x99)
check("who(0x99) 立即落 0x00", dev:reg(0x00) == 0x99)
w(0x3C, 0x96)
check("软复位后身份仍是覆写值 0x99（喂在位甄别负路径）", dev:reg(0x00) == 0x99)
dev:reset()
check("完整 reset() 恢复 POR 身份 0x24", dev:reg(0x00) == 0x24)

-- ---- virt_tick 8 拍事件脚本（确定性，喂守护）----
local function tick_call(n)
	dev:virt_tick(n)
	return dev:event(), dev:distance(), dev:energy()
end
check("tick0 none（预武装拍）", tick_call(0) == 0)
local e2, d2, g2 = tick_call(2)
check("tick2 lightning dist=31 energy=782842",
	e2 == 0x08 and d2 == 31 and g2 == 782842,
	string.format("%d/%d/%d", e2, d2, g2))
check("tick4 noise", tick_call(4) == 0x01)
local e6, d6, g6 = tick_call(6)
check("tick6 lightning dist=31 energy=217157",
	e6 == 0x08 and d6 == 31 and g6 == 217157,
	string.format("%d/%d/%d", e6, d6, g6))
check("tick7 disturber", tick_call(7) == 0x04)
check("tick1/3/5 none", tick_call(1) == 0 and tick_call(3) == 0
	and tick_call(5) == 0)
check("tick8 == tick0（8 拍周期）", tick_call(8) == 0)
check("virt_tick 返回 self", dev:virt_tick(0) == dev)

-- ---- 写日志 / 故障钩子 / 复位保留 ----
dev:reset()
w(0x01, 0x22); w(0x3C, 0x96); w(0x00)
check("write_count 只数 ≥2B 事务（2，纯指针不计）",
	dev:write_count() == 2, tostring(dev:write_count()))
check("write_log 记 reg/bytes",
	#dev:writes() == 2 and dev:writes()[1].reg == 0x01
	and dev:writes()[1].bytes[2] == 0x22)
dev:reset_logs()
check("reset_logs 清零", dev:write_count() == 0 and dev:reset_count() == 0
	and #dev:writes() == 0)

dev.nack_write = true
check("nack_write 写 NACK", w(0x00) == false)
dev:clear_faults()
check("解除后写恢复", w(0x00) == true); r1(1)
w(0x00)
dev.nack_read = true
check("nack_read 读 NACK", r1(1) == nil)
dev:clear_faults()
w(0x00)
check("解除后读恢复", r1(1)[1] == 0x24)
dev:fail_write(function(b) return b[1] == 0x3C end)
check("fail_write 谓词命中复位帧", w(0x3C, 0x96) == false)
check("fail_write 不影响其他写", w(0x01, 0x22) == true)
dev:clear_faults()
w(0x07)
dev:fail_read(function(a) return a == 0x07 end)
check("fail_read 谓词按指针命中", r1(1) == nil)
dev:clear_faults()
dev.nack = true
check("nack 全断：写/读都 NACK", w(0x00) == false and r1(1) == nil)
dev:clear_faults()
dev.nack_write = true
check("reset 保留故障钩子", (dev:reset() and w(0x00)) == false)
dev:clear_faults()
check("reset 回 POR", dev:reg(0x00) == 0x24 and dev:reg(0x07) == 0x3F
	and dev:trco_status() == 0x00)

-- =====================================================================
-- 组 2：真实 build（缺省参数，逐笔事务）
-- =====================================================================
mark = section()
local bframes
local ok, res, banner = capture(function()
	local r
	bframes, r = recording(function()
		return build({ fd = fd, address = "0x03" })
	end)
	return r
end)
check("build 缺省 OK", ok and res.result == "OK", tostring(res and res.result))
local es = entries(mark)
check("build 36 txlog（set+23w+12r）", #es == 36,
	tostring(#es) .. ":" .. table.concat((function()
		local t = {}
		for _, e in ipairs(es) do t[#t + 1] = e.dir end
		return t
	end)(), ","))
check("build 首笔 set 0x03", set_addrs(mark)[1] == 0x03,
	tostring(set_addrs(mark)[1]))
check("build 写序列逐笔编码",
	same_seq(wcodes(mark), {
		0x3C96,								-- 软复位
		0x00,								-- 在位甄别指针
		0x00, 0x0024,						-- RMW 0x00 AFE 室内
		0x01, 0x0122,						-- RMW 0x01 NF=2
		0x01, 0x0122,						-- RMW 0x01 WDTH=2
		0x02, 0x0202,						-- RMW 0x02 min_lig 码 0
		0x02, 0x0202,						-- RMW 0x02 SREJ=2
		0x03, 0x0300,						-- RMW 0x03 MASK_DIST=0
		0x08, 0x0800,						-- RMW 0x08 TUN_CAP=0
		0x3D96,								-- RCO 校准命令
		0x08, 0x08C0,						-- 显示位置 0x03<<6
		0x08, 0x0800,						-- 显示位清
		0x3B,								-- SRCO 状态指针
		0x3A,								-- TRCO 状态指针
	}), seq_hex(mark))
local rds = reads(mark)
check("build 12 笔读宽度全 1", #rds == 12, tostring(#rds))
do
	local all1 = true
	for _, e in ipairs(rds) do if e.bytes.n ~= 1 then all1 = false end end
	check("12 读 n 全 =1", all1)
end
check("读帧 1 = AFE 0x24（在位甄别）",
	bframes[1] and bframes[1][1] == 0x24, frame(bframes[1]))
check("读帧 2 = RMW 0x00 回读 0x24",
	bframes[2] and bframes[2][1] == 0x24, frame(bframes[2]))
check("读帧 3~8 = 六笔配置 RMW 回读 22,22,02,02,00,00",
	bframes[3][1] == 0x22 and bframes[4][1] == 0x22
	and bframes[5][1] == 0x02 and bframes[6][1] == 0x02 and bframes[7][1] == 0x00
	and bframes[8][1] == 0x00,
	table.concat({ frame(bframes[3]), frame(bframes[4]), frame(bframes[5]),
		frame(bframes[6]), frame(bframes[7]), frame(bframes[8]) }, "|"))
check("读帧 9 = 显示位置位前回读 0x00",
	bframes[9] and bframes[9][1] == 0x00, frame(bframes[9]))
check("读帧 10 = 显示位清除前回读 0xC0",
	bframes[10] and bframes[10][1] == 0xC0, frame(bframes[10]))
check("读帧 11 = SRCO 0x80", bframes[11] and bframes[11][1] == 0x80,
	frame(bframes[11]))
check("读帧 12 = TRCO 0x80", #bframes == 12 and bframes[12][1] == 0x80,
	#bframes .. ":" .. frame(bframes[12]))
check("build 睡眠 4ms（复位 2 + 校准显示窗 2）",
	sleep_total == 4, tostring(sleep_total))
check("build 后 0x00=0x24/0x01=0x22/0x02=0x02/0x03=0x00/0x08=0x00",
	dev:reg(0x00) == 0x24 and dev:reg(0x01) == 0x22 and dev:reg(0x02) == 0x02
	and dev:reg(0x03) == 0x00 and dev:reg(0x08) == 0x00)
check("横幅含 addr=0x03/indoor/各缺省值",
	banner:find("AS3935 init OK", 1, true)
	and banner:find("addr=0x03", 1, true)
	and banner:find("indoor", 1, true)
	and banner:find("nf=2", 1, true)
	and banner:find("wdth=2", 1, true)
	and banner:find("srej=2", 1, true)
	and banner:find("min_lig_c=0", 1, true)
	and banner:find("mask_dist=false", 1, true)
	and banner:find("tun_cap=0pF", 1, true), banner)

-- 字符串 fd/address
mark = section()
expect_ok("build 字符串 fd='3' address='0x03'", function()
	return build({ fd = "3", address = "0x03" })
end)
check("set_addr 收到 0x03=3", set_addrs(mark)[1] == 3,
	tostring(set_addrs(mark)[1]))

-- =====================================================================
-- 组 3：真实 build（室内外/各字段档/钳位/取档）
-- =====================================================================
mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x03", indoor = "0" })
end)
check("build indoor=0 OK", ok and res.result == "OK", tostring(res and res.result))
check("室外增益 0x00=0x1C（0x0E<<1）", dev:reg(0x00) == 0x1C,
	string.format("0x%02X", dev:reg(0x00)))
check("室外横幅 outdoor", banner:find("outdoor", 1, true) ~= nil, banner)

mark = section()
expect_ok("build 全字段拉满", function()
	return build({ fd = fd, address = "0x03",
		nf = "5", wdth = "10", srej = "15", min_lig = "16", tun_cap = "120" })
end)
check("NF=5/WDTH=10 -> 0x01=0x5A", dev:reg(0x01) == 0x5A,
	string.format("0x%02X", dev:reg(0x01)))
check("MIN_LIG=16 码 3/SREJ=15 -> 0x02=0x3F", dev:reg(0x02) == 0x3F,
	string.format("0x%02X", dev:reg(0x02)))
check("TUN_CAP=120pF 码 15 -> 0x08=0x0F", dev:reg(0x08) == 0x0F,
	string.format("0x%02X", dev:reg(0x08)))

mark = section()
expect_ok("build min_lig=7 向下取档 5（码 1）", function()
	return build({ fd = fd, address = "0x03", min_lig = "7" })
end)
check("0x02=0x12（码 1/SREJ 缺省 2）", dev:reg(0x02) == 0x12,
	string.format("0x%02X", dev:reg(0x02)))

mark = section()
expect_ok("build min_lig=9 码 2", function()
	return build({ fd = fd, address = "0x03", min_lig = "9" })
end)
check("0x02=0x22", dev:reg(0x02) == 0x22, string.format("0x%02X", dev:reg(0x02)))

mark = section()
expect_ok("build mask_dist=1/tun_cap=100", function()
	return build({ fd = fd, address = "0x03", mask_dist = "1", tun_cap = "100" })
end)
check("MASK_DIST 置位 0x03=0x20", dev:reg(0x03) == 0x20,
	string.format("0x%02X", dev:reg(0x03)))
check("100pF/8=12 -> 0x08=0x0C（8pF 步进截断）", dev:reg(0x08) == 0x0C,
	string.format("0x%02X", dev:reg(0x08)))

mark = section()
expect_ok("build nf=9 钳 7 / wdth=11 钳 10", function()
	return build({ fd = fd, address = "0x03", nf = "9", wdth = "11" })
end)
check("0x01=0x7A", dev:reg(0x01) == 0x7A,
	string.format("0x%02X", dev:reg(0x01)))

mark = section()
expect_ok("build tun_cap=200 钳 120pF（码 15）", function()
	return build({ fd = fd, address = "0x03", tun_cap = "200" })
end)
check("0x08=0x0F", dev:reg(0x08) == 0x0F, string.format("0x%02X", dev:reg(0x08)))

mark = section()
expect_ok("build 非法列归缺省（'-'/abc）", function()
	return build({ fd = fd, address = "0x03",
		nf = "-", wdth = "abc", srej = "x", min_lig = "x",
		mask_dist = "x", tun_cap = "-" })
end)
check("缺省落 0x22/0x02/0x00/0x00",
	dev:reg(0x01) == 0x22 and dev:reg(0x02) == 0x02
	and dev:reg(0x03) == 0x00 and dev:reg(0x08) == 0x00)

-- NaN 与上面那组**同契约**：'nan'/'inf'/'-inf' 经 tonumber 出的都是 number
-- （Lua 里 truthy），`(tonumber(x) or 缺省) ~= 0` 的 `or` 兜不住，于是 NaN
-- 走「非零即真」这一档——mask_dist 会把 REG_INT 的 MASK_DIST 置成 0x20，
-- 而上一条已钉死「非法列归缺省」= 0x00。数值列（nf/wdth/srej/min_lig/
-- tun_cap）走 int_or -> finite_of，本来就把 NaN 挡在缺省，此处一并覆盖防回退。
mark = section()
ok, res, banner = capture(function()
	return build({ fd = fd, address = "0x03",
		nf = "nan", wdth = "inf", srej = "-inf", min_lig = "nan",
		mask_dist = "nan", tun_cap = "inf", indoor = "nan" })
end)
check("build 非有限列 OK", ok and res.result == "OK", tostring(res and res.result))
check("非有限列同归缺省 0x22/0x02/0x00/0x00",
	dev:reg(0x01) == 0x22 and dev:reg(0x02) == 0x02
	and dev:reg(0x03) == 0x00 and dev:reg(0x08) == 0x00,
	string.format("0x%02X/0x%02X/0x%02X/0x%02X", dev:reg(0x01),
		dev:reg(0x02), dev:reg(0x03), dev:reg(0x08)))
check("非有限列横幅仍是缺省 indoor/mask_dist=false",
	banner:find("indoor", 1, true) ~= nil
	and banner:find("mask_dist=false", 1, true) ~= nil
	and banner:find("nf=2", 1, true) ~= nil, banner)

-- =====================================================================
-- 组 4：真实 build 错误路径
-- =====================================================================
mark = section()
expect_err("build 缺 fd", function() return build({ address = "0x03" }) end,
	"fd or address")
expect_err("build 缺 address", function() return build({ fd = fd }) end,
	"fd or address")
expect_err("build address 非数值", function()
	return build({ fd = fd, address = "0xZZ" })
end, "fd or address")
expect_err("build 非表参数", function() return build(nil) end,
	"Invalid Arguments Type")
check("前置校验类错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x3C end)
expect_err("build 复位写失败", function()
	return build({ fd = fd, address = "0x03" })
end, "Failed to reset")
check("复位失败 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

mark = section()
dev:fail_read(function(a) return a == 0x00 end)
expect_err("build 读 AFE_GAIN 失败", function()
	return build({ fd = fd, address = "0x03" })
end, "Failed to read AS3935 AFE_GAIN")
check("AFE 读失败 txlog=4（set+复位w+指针w+失败 r 留痕）",
	#entries(mark) == 4, tostring(#entries(mark)))

mark = section()
dev:who(0x99)
expect_err("build 复位默认值不符（在位甄别 not AS3935?）", function()
	return build({ fd = fd, address = "0x03" })
end, "expect INDOOR default")
check("甄别失败 txlog=4（不进入 RMW）", #entries(mark) == 4,
	tostring(#entries(mark)))

mark = section()
dev:fail_write(function(b) return #b == 2 and b[1] == 0x00 end)
expect_err("build AFE RMW 写失败", function()
	return build({ fd = fd, address = "0x03" })
end, "Failed to write AS3935 AFE gain")
check("AFE RMW 失败 txlog=7（set+复位+甄别 w/r+RMW 指针 w/r+失败 w）",
	#entries(mark) == 7, tostring(#entries(mark)))

mark = section()
dev:set_calib_fail("trco")
expect_err("build TRCO 校准未通过", function()
	return build({ fd = fd, address = "0x03" })
end, "calibration failed")
mark = section()
dev:set_calib_fail("srco")
expect_err("build SRCO 校准未通过", function()
	return build({ fd = fd, address = "0x03" })
end, "calibration failed")

mark = section()
dev:fail_read(function(a) return a == 0x3B end)
expect_err("build 读 SRCO 状态失败", function()
	return build({ fd = fd, address = "0x03" })
end, "calibration status")
-- 驱动 SRCO/TRCO 先两笔都读再统一判失败，故 TRCO 读也留痕（共 36）
check("SRCO 读失败 txlog=36（TRCO 读也执行后统一报错）",
	#entries(mark) == 36, tostring(#entries(mark)))

mark = section()
expect_err("无器件地址 0x01 复位 NACK", function()
	return build({ fd = fd, address = "0x01" })
end, "Failed to reset")
check("无器件 txlog=2（set+w）", #entries(mark) == 2, tostring(#entries(mark)))

-- =====================================================================
-- 组 5：真实 call（四事件 + 距离能量 + 读后清 + tick 驱动）
-- =====================================================================
mark = section()
expect_ok("call 用例前 build", function()
	return build({ fd = fd, address = "0x03" })
end)

mark = #vbus.txlog
local out = expect_ok("call 无事件", function()
	return call({ fd = fd, address = "0x03" })
end)
check("无事件 3 txlog（set+{03}+r1）", #entries(mark) == 3,
	tostring(#entries(mark)))
check("无事件写序列仅指针 03", same_seq(wcodes(mark), { 0x03 }),
	seq_hex(mark))
check("call 实睡 2ms", sleep_total == 6, tostring(sleep_total))	-- build 4 + 2
if out then
	check("none/CODE=0/DIST=-1/ENERGY=0",
		out.EVENT == "none" and out.CODE == 0 and out.DIST_KM == -1
		and out.ENERGY == 0, string.format("%s/%d/%d/%d",
			out.EVENT, out.CODE, out.DIST_KM, out.ENERGY))
end

dev:strike(10, 0x123456)
mark = #vbus.txlog
out = expect_ok("call 闪电事件", function()
	return call({ fd = fd, address = "0x03" })
end)
check("闪电 11 txlog（set+INT+DIST+3×EGY）", #entries(mark) == 11,
	tostring(#entries(mark)))
check("闪电写序列 03/07/04/05/06",
	same_seq(wcodes(mark), { 0x03, 0x07, 0x04, 0x05, 0x06 }), seq_hex(mark))
if out then
	check("lightning/CODE=3/DIST=10/ENERGY=0x123456",
		out.EVENT == "lightning" and out.CODE == 3 and out.DIST_KM == 10
		and out.ENERGY == 0x123456, string.format("%s/%d/%d/%d",
			out.EVENT, out.CODE, out.DIST_KM, out.ENERGY))
end

mark = #vbus.txlog
out = expect_ok("call 第二次（读后清，事件已走）", function()
	return call({ fd = fd, address = "0x03" })
end)
check("第二次仅 3 txlog", #entries(mark) == 3, tostring(#entries(mark)))
if out then
	check("事件已清 none/DIST=-1/ENERGY=0",
		out.EVENT == "none" and out.CODE == 0 and out.DIST_KM == -1
		and out.ENERGY == 0)
end

dev:noise()
out = expect_ok("call 噪声事件", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("noise/CODE=1/3 txlog 路径",
	out.EVENT == "noise" and out.CODE == 1 and out.DIST_KM == -1,
	tostring(out.EVENT)) end

dev:disturber()
out = expect_ok("call 干扰源事件", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("disturber/CODE=2",
	out.EVENT == "disturber" and out.CODE == 2, tostring(out.EVENT)) end

-- INT 杂散位：0x0A 按位判仍命中闪电（驱动优先级 闪电>干扰>噪声）
dev:strike(10, 0x123456)
dev:set_int_raw(0x0A)
out = expect_ok("call INT=0x0A 杂散位", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("0x0A 按位判 -> lightning CODE=3 且读距离能量",
	out.CODE == 3 and out.DIST_KM == 10 and out.ENERGY == 0x123456,
	string.format("%d/%d/%d", out.CODE, out.DIST_KM, out.ENERGY)) end

-- 距离特殊值
for _, spec in ipairs({
	{ 0x3F, -1, "超量程" }, { 0, -1, "未知" }, { 1, 1, "头顶" },
	{ 62, 62, "62km" },
}) do
	dev:strike(spec[1], 42)
	out = expect_ok("call 闪电距离" .. spec[3], function()
		return call({ fd = fd, address = "0x03" })
	end)
	if out then
		check(string.format("S_DIST=%d -> DIST_KM=%s", spec[1], tostring(spec[2])),
			out.CODE == 3 and out.DIST_KM == spec[2] and out.ENERGY == 42,
			string.format("%d/%d", out.DIST_KM, out.ENERGY))
	end
end

-- 能量边界
dev:strike(5, 0x1FFFFF)
out = expect_ok("call 能量满码", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("ENERGY=2097151", out.ENERGY == 2097151, tostring(out.ENERGY)) end

-- MASK_DIST 配置下真实 call：干扰被屏、噪声照报
mark = section()
expect_ok("mask build", function()
	return build({ fd = fd, address = "0x03", mask_dist = "1" })
end)
dev:disturber()
out = expect_ok("call mask 下干扰源 -> none", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("屏蔽生效 CODE=0", out.CODE == 0, tostring(out.CODE)) end
dev:noise()
out = expect_ok("call mask 下噪声照报", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("noise CODE=1", out.CODE == 1, tostring(out.CODE)) end
dev:strike(20, 999)
out = expect_ok("call mask 下闪电照报", function()
	return call({ fd = fd, address = "0x03" })
end)
if out then check("lightning CODE=3 DIST=20",
	out.CODE == 3 and out.DIST_KM == 20 and out.ENERGY == 999) end

-- virt_tick 驱动真实 call
mark = section()
expect_ok("tick 用例前 build", function()
	return build({ fd = fd, address = "0x03" })
end)
local seq_name = {}
for n = 0, 7 do
	dev:virt_tick(n)
	local r = call({ fd = fd, address = "0x03" })
	seq_name[#seq_name + 1] = r.EVENT
end
check("tick0~7 事件序 none,none,lightning,none,noise,none,lightning,disturber",
	table.concat(seq_name, ",") ==
	"none,none,lightning,none,noise,none,lightning,disturber",
	table.concat(seq_name, ","))

-- =====================================================================
-- 组 6：真实 call 错误路径
-- =====================================================================
mark = section()
expect_ok("call 失败用例前 build", function()
	return build({ fd = fd, address = "0x03" })
end)

dev:fail_read(function(a) return a == 0x03 end)
mark = #vbus.txlog
expect_err("call 读 INT 失败", function()
	return call({ fd = fd, address = "0x03" })
end, "interrupt register")
check("INT 读失败 txlog=3（set+指针w+失败 r）", #entries(mark) == 3,
	tostring(#entries(mark)))
dev:clear_faults()

dev:strike(10, 0x123456)
dev:fail_read(function(a) return a == 0x07 end)
mark = #vbus.txlog
expect_err("call 读距离失败", function()
	return call({ fd = fd, address = "0x03" })
end, "distance")
check("距离读失败 txlog=5（INT 成功后）", #entries(mark) == 5,
	tostring(#entries(mark)))
dev:clear_faults()

dev:strike(10, 0x123456)
dev:fail_read(function(a) return a == 0x04 end)
mark = #vbus.txlog
expect_err("call 读能量 LSB 失败", function()
	return call({ fd = fd, address = "0x03" })
end, "energy")
-- 驱动 lsb/msb/mmsb 先三笔都读再统一判失败，故 MSB/MMSB 读也留痕（共 11）
check("LSB 失败 txlog=11（MSB/MMSB 读也执行后统一报错）", #entries(mark) == 11,
	tostring(#entries(mark)))
dev:clear_faults()

dev:strike(10, 0x123456)
dev:fail_read(function(a) return a == 0x06 end)
mark = #vbus.txlog
expect_err("call 读能量 MMSB 失败", function()
	return call({ fd = fd, address = "0x03" })
end, "energy")
check("MMSB 失败 txlog=11（前四读成功）", #entries(mark) == 11,
	tostring(#entries(mark)))
dev:clear_faults()

mark = #vbus.txlog
expect_err("call 无器件地址 0x02", function()
	return call({ fd = fd, address = "0x02" })
end, "interrupt register")
check("无器件 txlog=2（set+指针 w NACK）", #entries(mark) == 2,
	tostring(#entries(mark)))

mark = #vbus.txlog
expect_err("call 非表参数", function() return call("x") end, "Invalid Arguments")
expect_err("call 缺 fd", function() return call({ address = "0x03" }) end,
	"fd or address")
check("call 参数错误零总线事务", #entries(mark) == 0, tostring(#entries(mark)))

-- =====================================================================
-- 组 7：destroy
-- =====================================================================
expect_ok("destroy 无资源需释放", function() return destroy({}) end)
expect_err("destroy 非表参数", function() return destroy(nil) end,
	"Invalid Arguments Type")

-- ==================== 汇总 ====================
tester.summary("AS3935 结果")

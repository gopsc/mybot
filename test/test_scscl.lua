-- test_scscl.lua —— SCSCL 总线舵机 真实驱动 + 虚拟 UART 总线 + 协议模型
-- 用法（项目根目录）: luajit test/test_scscl.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：SCSCL_GC=1 luajit test/test_scscl.lua
--
-- 覆盖真实驱动 modules/SCSCL.lua（build PING 探测 / call 大端位置写 /
-- read 反馈块 / destroy 扭矩关闭）与内嵌模型 SCSCL_VIRT（FT-SCS 帧协议、
-- 校验和、广播/站号过滤、寄存器地图、运动学 advance）。
--
-- 协议事实（《SCS通信协议》+《SCSCL舵机内存表手册》，驱动/模型/测试三处交叉）：
--   帧：FF FF ID LEN 指令/错误 参数… CS；总长 = LEN + 4；
--   CS = 0xFF - (Σ(ID..参数) mod 256)（注意与 MH-Z19 的补码式不同）
--   经典向量：PING 请求 FF FF 01 02 01 FB，应答 FF FF 01 02 00 FC
--   寄存器（大端）：0x28 扭矩、0x2A 位置、0x2C 时间、0x2E 速度、0x38 起反馈块
--
-- 覆盖六组：
--   1) 模型协议事实：帧组装/校验和交叉、PING/读/写应答、广播与站号过滤、
--      只读/越界写拒绝、非法帧不应答、四故障钩子、reset 不清钩子、运动学
--   2) 虚拟原语：1M 白名单 open、uart 采纳 adopt_fd（drv_common 跨状态机路径）
--   3) 真实 build：PING 帧逐字节与留痕、id 校验负路径、无应答/错误状态负路径
--   4) 真实 call：位置/时间/速度大端帧、限幅管线、扭矩单发与合帧、正负路径
--   5) 真实 read：反馈块解码、advance 后位置/移动标志、噪声聚合、负路径
--   6) destroy：扭矩关闭帧、未建路径零事务、失败路径
--   7) set_id 烧号：解锁→广播写号帧序、模型站号切换与 persisted 语义、
--      独占忽略同行参数、旧/新站号 PING 对照、负路径

if os.getenv("SCSCL_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local PATH = "/dev/serial0"

-- 模型内嵌于驱动文件（SCSCL_VIRT 全局工厂，工厂表带 BUS="uart"）
vbus.load_driver("modules/SCSCL.lua")
local sm = SCSCL_VIRT

local dev = sm.new()
vbus.attach_uart("SCSCL@" .. PATH, PATH, dev)

local fd = uart_open(PATH, 1000000)
check("uart_open 虚拟 fd=3 @1000000（新白名单档）", fd == 3, tostring(fd))

-- 独立第三份校验和实现（测试侧交叉，不与驱动/模型共享代码）
local function cs(t, from, to)
	local s = 0
	for i = from, to do s = s + t[i] end
	return 0xFF - (s % 0x100)
end

local function same_bytes(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function entries(mark)
	local t = {}
	for i = (mark or 0) + 1, #vbus.txlog do t[#t + 1] = vbus.txlog[i] end
	return t
end
local function dirs_of(es)
	local t = {}
	for _, e in ipairs(es) do t[#t + 1] = e.dir end
	return t
end
local function count_dir(es, dir)
	local c = 0
	for _, e in ipairs(es) do
		if e.dir == dir then c = c + 1 end
	end
	return c
end
local function last_dir(es, dir)
	for i = #es, 1, -1 do
		if es[i].dir == dir then return es[i] end
	end
end

-- 元数据模板（结构元数据 = fd/id/限幅列；动作参数另行合并）
local function meta(extra)
	local m = { fd = fd, id = 1 }
	for k, v in pairs(extra or {}) do m[k] = v end
	return m
end

-- 每个 section：器件复位 + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	vbus.uart_fail_read = false
	return #vbus.txlog
end

-- 横幅捕获（驱动 build 打印）
local cap_lines = {}
local real_print = print
local function cap_start()
	cap_lines = {}
	print = function(s) cap_lines[#cap_lines + 1] = tostring(s) end
end
local function cap_stop() print = real_print end
local function cap_has(pat)
	for _, s in ipairs(cap_lines) do
		if s:find(pat, 1, true) then return true end
	end
	return false
end

-- ==================== 组 1：模型协议事实 ====================
do
	section()
	-- 经典向量：PING 请求帧校验和 0xFB（独立实现 vs 常量）
	local PING = { 0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB }
	check("PING 请求 CS=0xFB", cs(PING, 3, 5) == 0xFB, string.format("0x%02X", cs(PING, 3, 5)))

	-- on_write 直调：PING → 6 字节应答 FF FF 01 02 00 FC
	local r = dev.on_write(PING)
	check("PING 应答逐字节 = FF FF 01 02 00 FC（经典向量）",
		type(r) == "table" and same_bytes(r, { 0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC }),
		r and table.concat(r, ",") or "nil")
	check("PING 留痕 kind=ping valid=true",
		dev:request_count() == 1 and dev:requests()[1].kind == "ping"
		and dev:requests()[1].valid == true)

	-- 位置写（大端）：位置 512 → 02 00，速度 300 → 01 2C，时间 0
	dev:reset()
	local WR512 = { 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0x02, 0x00, 0x00, 0x00, 0x01, 0x2C, 0 }
	WR512[13] = cs(WR512, 3, 12)
	dev:set_present_position(0)
	r = dev.on_write(WR512)
	check("写位置 512/速度 300 应答 = FF FF 01 02 00 FC",
		type(r) == "table" and same_bytes(r, { 0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC }),
		r and table.concat(r, ",") or "nil")
	check("大端寄存器落盘：goal=512 time=0 speed=300",
		dev:goal_position() == 512 and dev:run_time() == 0 and dev:run_speed() == 300)
	check("目标与当前位置不同 → 移动标志置 1", dev:moving() == 1)

	-- 广播写（0xFE）：执行但不应答
	dev:reset()
	local BW = { 0xFF, 0xFF, 0xFE, 0x04, 0x03, 0x28, 0x01, 0 }	-- 扭矩=1
	BW[8] = cs(BW, 3, 7)
	check("广播写不应答（nil）", dev.on_write(BW) == nil)
	check("广播写已生效 torque=1", dev:torque_enable() == 1)
	-- 广播 PING 应答带本站 ID（协议文档：广播 PING 也应答）
	-- 帧 CS = 0xFF - ((FE+02+01) mod 256) = 0xFE
	r = dev.on_write({ 0xFF, 0xFF, 0xFE, 0x02, 0x01, 0xFE })
	check("广播 PING 应答 id=本站 1",
		type(r) == "table" and r[3] == 1 and r[5] == 0)

	-- 站号过滤：非本站静默且寄存器不动
	dev:reset()
	dev:set_id(1)
	local OTHER = { 0xFF, 0xFF, 0x07, 0x04, 0x03, 0x28, 0x02, 0 }	-- 发往 id=7
	OTHER[8] = cs(OTHER, 3, 7)
	check("非本站 ID 不应答", dev.on_write(OTHER) == nil)
	check("非本站 ID 不落寄存器", dev:torque_enable() == 0)

	-- 读反馈块：0x38 起 11 字节
	dev:reset()
	dev:set_id(1)
	dev:set_present_position(250)
	dev:set_load(50):set_voltage_raw(99):set_temp_c(41):set_status(3)
	local RD = { 0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x0B, 0 }
	RD[8] = cs(RD, 3, 7)
	r = dev.on_write(RD)
	check("读应答 17 字节（LEN=13）且帧头正确",
		type(r) == "table" and #r == 17 and r[1] == 0xFF and r[2] == 0xFF
		and r[3] == 1 and r[4] == 13 and r[5] == 3,
		r and table.concat(r, ",") or "nil")
	check("反馈块大端解码：pos=250 speed=0 load=50 volt=99 temp=41 status=3 moving=1",
		r[6] * 256 + r[7] == 250 and r[8] * 256 + r[9] == 0
		and r[10] * 256 + r[11] == 50 and r[12] == 99 and r[13] == 41
		and r[15] == 3 and r[16] == 1)
	check("读应答 CS 与独立实现一致", r[17] == cs(r, 3, 16), string.format("0x%02X", r[17]))

	-- 只读地址写拒绝（0x38 反馈区）：整笔不应答且不落盘
	dev:reset()
	local ROW = { 0xFF, 0xFF, 0x01, 0x05, 0x03, 0x38, 0xAA, 0x55, 0 }
	ROW[9] = cs(ROW, 3, 8)
	check("只读地址写整笔拒绝", dev.on_write(ROW) == nil)

	-- 越界地址写/读拒绝
	local OOR = { 0xFF, 0xFF, 0x01, 0x05, 0x03, 0x50, 0x01, 0x02, 0 }
	OOR[9] = cs(OOR, 3, 8)
	check("地图外地址写拒绝", dev.on_write(OOR) == nil)
	local ORR = { 0xFF, 0xFF, 0x01, 0x04, 0x02, 0x50, 0x02, 0 }
	ORR[8] = cs(ORR, 3, 7)
	check("地图外地址读拒绝", dev.on_write(ORR) == nil)
	local BADR = { 0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x00, 0 }	-- n=0
	BADR[8] = cs(BADR, 3, 7)
	check("读长度 0 拒绝", dev.on_write(BADR) == nil)

	-- 非法帧一律不应答且留痕 valid=false
	dev:reset()
	check("短帧不应答", dev.on_write({ 0xFF, 0xFF, 0x01 }) == nil)
	check("坏帧头不应答", dev.on_write({ 0xFE, 0xFF, 0x01, 0x02, 0x01, 0xFB }) == nil)
	local BADCS = { 0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFA }
	check("坏校验和不应答", dev.on_write(BADCS) == nil)
	local LENBAD = { 0xFF, 0xFF, 0x01, 0x03, 0x01, 0xFB }
	check("LEN 与帧长不符不应答", dev.on_write(LENBAD) == nil)
	local rq = dev:requests()
	check("四类非法请求均留痕 valid=false",
		#rq == 4 and not rq[1].valid and not rq[2].valid and not rq[3].valid and not rq[4].valid)

	-- 故障钩子
	dev:no_reply(true)
	r = dev.on_write(PING)
	check("no_reply 返 nil 且请求留痕 valid=true",
		r == nil and dev:requests()[dev:request_count()].valid == true)
	dev:no_reply(false)
	dev:fail_write(true)
	dev:reset_logs()
	check("fail_write 返 false 且不解析请求",
		dev.on_write(PING) == false and dev:request_count() == 0)
	dev:fail_write(false)
	dev:corrupt_checksum(true)
	r = dev.on_write(PING)
	check("corrupt_checksum 翻转应答 CS（帧头仍在）",
		r[1] == 0xFF and r[3] == 1 and r[6] ~= cs(r, 3, 5))
	dev:corrupt_checksum(false)
	dev:noise(true)
	r = dev.on_write(PING)
	dev:noise(false)
	local clean = dev.on_write(PING)
	check("noise 前置 3 个无帧头噪声字节后接完整帧",
		#r == 9 and r[1] == 0x00 and r[2] == 0x01 and r[3] == 0x02
		and same_bytes({ r[4], r[5], r[6], r[7], r[8], r[9] }, clean))

	-- reset 回 POR 但不清钩子
	dev:no_reply(true)
	dev:set_present_position(777)
	dev:reset()
	check("reset 回 POR（位置归 0、速度初值 1000）",
		dev:present_position() == 0 and dev:run_speed() == 1000)
	check("reset 不清 no_reply 钩子", dev.on_write(PING) == nil)
	dev:clear_faults()
	check("clear_faults 后恢复应答", dev.on_write(PING) ~= nil)

	-- 运动学：速度模式
	dev:reset()
	dev:set_present_position(0)
	local MOVE = { 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0x02, 0x58, 0x00, 0x00, 0x01, 0x2C, 0 }
	MOVE[13] = cs(MOVE, 3, 12)	-- 目标 600 速度 300
	dev.on_write(MOVE)
	dev:advance(1000)
	check("速度模式 1s 推进 300 步（600→300）",
		dev:present_position() == 300 and dev:moving() == 1)
	local RF = { 0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x0B, 0 }
	RF[8] = cs(RF, 3, 7)
	r = dev.on_write(RF)
	check("运动中速度反馈=300", r[8] * 256 + r[9] == 300)
	dev:advance(1000)
	check("再 1s 到位（600）moving=0", dev:present_position() == 600 and dev:moving() == 0)

	-- 运动学：时间模式（speed=0 time=2000 → 折算 300 步/s）
	dev:reset()
	dev:set_present_position(0)
	local MT = { 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0x02, 0x58, 0x07, 0xD0, 0x00, 0x00, 0 }
	MT[13] = cs(MT, 3, 12)	-- 目标 600 时间 2000 速度 0
	dev.on_write(MT)
	dev:advance(1000)
	check("时间模式折算 300 步/s（2000ms 走 600 步）", dev:present_position() == 300)

	-- 运动学：都为 0 → 出厂默认速度 1000
	dev:reset()
	dev:set_present_position(0)
	local MD = { 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0x02, 0x58, 0x00, 0x00, 0x00, 0x00, 0 }
	MD[13] = cs(MD, 3, 12)
	dev.on_write(MD)
	dev:advance(100)
	check("默认速度 1000 步/s：100ms 推进 100 步", dev:present_position() == 100)

	-- 运动学：目标超量程钳 1023
	dev:reset()
	dev:set_present_position(0)
	local MBIG = { 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0 }
	MBIG[13] = cs(MBIG, 3, 12)
	dev.on_write(MBIG)
	dev:advance(2000)
	check("目标 0xFFFF 钳 1023 到位", dev:present_position() == 1023)

	-- virt_tick：一拍 20ms 确定性推进
	dev:reset()
	dev:set_present_position(0)
	dev.on_write(MOVE)
	dev:virt_tick(0)
	check("virt_tick 推进 20ms → 6 步（300 步/s）", dev:present_position() == 6)

	-- 站号烧写寄存器事实（0x05 站号 / 0x30 EPROM 锁 / persisted_id 掉电语义）
	dev:reset()
	check("POR：站号 1 / 锁 1 / persisted=1",
		dev:id() == 1 and dev:lock() == 1 and dev:persisted_id() == 1)
	local PING1 = { 0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB }
	local ID_W7 = { 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x05, 0x07, 0 }
	ID_W7[8] = cs(ID_W7, 3, 7)
	check("上锁写 0x05：站号立即切换但掉电不保存（persisted 仍 1）",
		dev.on_write(ID_W7) ~= nil and dev:id() == 7 and dev:persisted_id() == 1)
	local PING7 = { 0xFF, 0xFF, 0x07, 0x02, 0x01, 0 }
	PING7[6] = cs(PING7, 3, 5)
	check("切换后旧站号不应答 / 新站号应答",
		dev.on_write(PING1) == nil and dev.on_write(PING7) ~= nil)
	local LOCK0 = { 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x30, 0x00, 0 }
	LOCK0[8] = cs(LOCK0, 3, 7)
	dev:set_id(1)	-- 注入回 1（同时视为已保存）
	dev.on_write(LOCK0)
	check("解锁后 lock=0", dev:lock() == 0)
	local ID_W9 = { 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x05, 0x09, 0 }
	ID_W9[8] = cs(ID_W9, 3, 7)
	dev.on_write(ID_W9)
	check("解锁写 0x05：persisted 同步更新",
		dev:id() == 9 and dev:persisted_id() == 9)
	-- 广播写 0x05：不应答但立即切换
	local BID = { 0xFF, 0xFF, 0xFE, 0x04, 0x03, 0x05, 0x08, 0 }
	BID[8] = cs(BID, 3, 7)
	check("广播写 0x05 不应答且切站号",
		dev.on_write(BID) == nil and dev:id() == 8 and dev:persisted_id() == 8)
end

-- ==================== 组 2：虚拟原语（新白名单 / uart 采纳） ====================
do
	section()
	check("921600 白名单可通过", uart_open(PATH, 921600) >= 0)
	check("576000 白名单拒绝（未列入）", uart_open(PATH, 576000) == -1)
	check("1M 白名单（模型镜像同步）", uart_open(PATH, 1000000) >= 0)

	-- adopt_fd（bus="uart"）：跨状态机采纳的 fd 能直接读写到同路径模型
	local mark = #vbus.txlog
	check("adopt_fd uart 分支返回 true", vbus.adopt_fd(77, PATH, nil, "uart") == true)
	local PING = { 0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB }
	check("采纳 fd 后 uart_write 到路径模型", uart_write(77, PING) == 6)
	local rep = uart_read(77, 64, 10)
	check("采纳 fd 后 uart_read 取回应答",
		type(rep) == "table" and #rep == 6 and rep[6] == 0xFC)
	local es = entries(mark)
	check("采纳留痕 dir=adopt", count_dir(es, "adopt") == 1)
end

-- ==================== 组 3：真实 build（PING 探测） ====================
do
	local mark = section()
	expect_err("fd 缺失 ERR", function() return build({ id = 1 }) end,
		"Invalid Argument: fd")
	expect_err("id 缺失 ERR", function() return build({ fd = fd }) end,
		"Invalid Argument: id")
	expect_err("id=0 ERR", function() return build(meta({ id = 0 })) end,
		"Invalid Argument: id")
	expect_err("id=254（广播不可作站号）ERR", function() return build(meta({ id = 254 })) end,
		"Invalid Argument: id")
	expect_err("id 非整数 ERR", function() return build(meta({ id = 1.5 })) end,
		"Invalid Argument: id")
	check("负路径零总线事务", #entries(mark) == 0)

	-- 站号不匹配 → PING 无应答
	dev:set_id(2)
	expect_err("id=1 对站号 2 的舵机 PING 超时 ERR",
		function() return build(meta({ id = 1 })) end, "No PING response")
	dev:set_id(1)
	dev:no_reply(true)
	expect_err("no_reply 下 PING 超时 ERR",
		function() return build(meta({ id = 1 })) end, "No PING response")
	dev:no_reply(false)

	-- 错误状态（status 位）→ build 失败
	dev:set_status(4)
	expect_err("错误状态 PING ERR（status=4）",
		function() return build(meta({ id = 1 })) end, "error status 4")
	dev:set_status(0)

	-- 正常路径：帧逐字节 + 横幅 + 留痕
	mark = section()
	cap_start()
	local ok_b = expect_ok("build OK", function() return build(meta({ id = 1 })) end)
	cap_stop()
	check("build 横幅含 id/fd", cap_has("SCSCL init OK: id=1 fd=3"))
	local es = entries(mark)
	check("总线时序 uf→uw（flush 一次 + PING 一帧）",
		dirs_of(es)[1] == "uf" and dirs_of(es)[2] == "uw" and dirs_of(es)[3] == "ur")
	check("PING 请求帧逐字节 = FF FF 01 02 01 FB",
		same_bytes(last_dir(es, "uw").bytes, { 0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB }),
		table.concat(last_dir(es, "uw").bytes, ","))
	check("build 留痕 kind=ping 且有效", dev:requests()[#dev:requests()].kind == "ping")
	check("build 返回 OK", ok_b ~= nil and ok_b.result == "OK")
end

-- ==================== 组 4：真实 call（位置/速度/时间/扭矩） ====================
do
	local mark = section()
	dev:set_present_position(0)

	-- 位置单发：时间/速度缺省为 0
	local r = expect_ok("position=512 OK", function()
		return call(meta({ position = 512 }))
	end)
	check("位置回调字段回显", r.position == 512 and r.speed == 0 and r.time == 0 and r.id == 1)
	check("帧逐字节 = FF FF 01 09 03 2A 02 00 00 00 00 00 C6",
		same_bytes(last_dir(entries(mark), "uw").bytes,
			{ 0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6 }),
		table.concat(last_dir(entries(mark), "uw").bytes, ","))
	check("模型落盘 goal=512 speed=0 time=0",
		dev:goal_position() == 512 and dev:run_speed() == 0 and dev:run_time() == 0)

	-- 速度+时间参数：位置 512 速度 300 时间 0
	mark = section()
	expect_ok("position+speed OK", function()
		return call(meta({ position = 512, speed = 300 }))
	end)
	check("模型落盘 speed=300", dev:run_speed() == 300)

	-- 时间模式：speed 缺省 0、time=400
	mark = section()
	expect_ok("position+time OK", function()
		return call(meta({ position = 512, time = 400 }))
	end)
	check("模型落盘 time=400 speed=0",
		dev:run_time() == 400 and dev:run_speed() == 0)

	-- 限幅管线（对齐 Servo.lua 语义）
	mark = section()
	r = expect_ok("offset+限幅中位", function()
		return call(meta({ max = 800, min = 200, offset = 10, position = 500 }))
	end)
	check("position=500 offset=10 → 510", r.position == 510)
	r = expect_ok("低限幅", function()
		return call(meta({ max = 800, min = 200, offset = 10, position = 100 }))
	end)
	check("position=100+10 → 钳到 min=200", r.position == 200)
	r = expect_ok("高限幅", function()
		return call(meta({ max = 800, min = 200, offset = 10, position = 1000 }))
	end)
	check("position=1000+10 → 钳到 max=800", r.position == 800)
	r = expect_ok("max<0 反向", function()
		return call(meta({ max = -800, min = 0, offset = 0, position = 300 }))
	end)
	check("max=-800 → 1023-300=723", r.position == 723)
	r = expect_ok("小数四舍五入", function()
		return call(meta({ position = 100.4 }))
	end)
	check("100.4 → 100", r.position == 100)
	r = expect_ok("小数进位", function()
		return call(meta({ position = 100.5 }))
	end)
	check("100.5 → 101", r.position == 101)

	-- 扭矩：单发 0x28；与位置同发时先扭矩后位置（两帧）
	mark = section()
	r = expect_ok("torque=1 单发 OK", function()
		return call(meta({ torque = 1 }))
	end)
	check("扭矩单发返回 torque 且无 position", r.torque == 1 and r.position == nil)
	check("扭矩帧 = FF FF 01 04 03 28 01 CE",
		same_bytes(last_dir(entries(mark), "uw").bytes,
			{ 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x01, 0xCE }),
		table.concat(last_dir(entries(mark), "uw").bytes, ","))
	check("模型 torque=1", dev:torque_enable() == 1)

	mark = section()
	expect_ok("torque+position 同发 OK", function()
		return call(meta({ torque = 2, position = 400 }))
	end)
	local es = entries(mark)
	check("同发两帧：先扭矩后位置",
		count_dir(es, "uw") == 2
		and es[1].bytes[6] == 0x28 and es[2].bytes[6] == 0x2A)
	check("模型 torque=2 goal=400",
		dev:torque_enable() == 2 and dev:goal_position() == 400)

	-- 负路径
	expect_err("speed=-1 ERR", function()
		return call(meta({ position = 0, speed = -1 }))
	end, "Invalid Argument: speed")
	expect_err("speed=1001 ERR", function()
		return call(meta({ position = 0, speed = 1001 }))
	end, "Invalid Argument: speed")
	expect_err("time=10000 ERR", function()
		return call(meta({ position = 0, time = 10000 }))
	end, "Invalid Argument: time")
	expect_err("torque=3 ERR", function()
		return call(meta({ torque = 3 }))
	end, "Invalid Argument: torque")
	expect_err("空参（无 position/torque）ERR", function()
		return call(meta({}))
	end, "Invalid Argument: position")
	expect_err("fd 非法 ERR", function()
		return call(meta({ fd = -1, position = 100 }))
	end, "Invalid Argument: fd")
	-- 审计 #4：call/read 入口改走 arg_table，非表报错文案与其统一
	expect_err("非表 ERR", function() return call(nil) end, "Invalid Arguments Type: table")

	-- 审计 P3：非有限入参。旧实现两处失效——
	--   ① `tonumber(x) or 0` 对 NaN 无效（NaN 非 nil，`or` 不触发），
	--      区间检查（`< 0` / `> 1000`）对 NaN 恒假，直通到 build_frame；
	--   ② 扭矩帧先于位置参数校验下发，位置非法时舵机已被设成刚性，
	--      却报 "Failed to write goal position"（部分提交 + 报错指向错误的帧）。
	-- 现在校验段零总线事务：非有限入参不得留下任何物理副作用。
	mark = section()
	expect_err("position=nan ERR", function()
		return call(meta({ position = "nan", torque = 1 }))
	end, "Invalid Argument: position")
	expect_err("speed=nan ERR", function()
		return call(meta({ position = 100, speed = "nan" }))
	end, "Invalid Argument: speed")
	expect_err("time=inf ERR", function()
		return call(meta({ position = 100, time = "1e400" }))
	end, "Invalid Argument: time")
	expect_err("torque=nan ERR", function()
		return call(meta({ torque = "nan" }))
	end, "Invalid Argument: torque")
	expect_err("max=nan ERR（软限位不得静默消失成全行程）", function()
		return call(meta({ position = 300, max = "nan", min = "0" }))
	end, "Invalid Argument: max")
	check("非有限入参零总线事务（无部分提交）",
		count_dir(entries(mark), "uw") == 0,
		"uw=" .. count_dir(entries(mark), "uw"))
	check("非有限入参后模型扭矩仍为 0（舵机未被设成刚性）",
		dev:torque_enable() == 0, tostring(dev:torque_enable()))

	-- 写失败（TX 错误）→ ERR；恢复后正常
	dev:fail_write(true)
	expect_err("TX 失败 ERR", function()
		return call(meta({ position = 100 }))
	end, "Failed to write goal position")
	dev:fail_write(false)
	expect_ok("故障撤销后恢复写", function()
		return call(meta({ position = 100 }))
	end)
end

-- ==================== 组 5：真实 read（反馈块） ====================
do
	local mark = section()
	dev:set_load(50):set_voltage_raw(99):set_temp_c(41):set_status(3)
	dev:set_present_position(250)

	local r = expect_ok("read OK", function() return read(meta({})) end)
	check("反馈解码：position=250 speed=0 load=50 voltage=99 temp=41 status=3",
		r.position == 250 and r.speed == 0 and r.load == 50
		and r.voltage == 99 and r.temp == 41 and r.status == 3)
	check("请求帧 = FF FF 01 04 02 38 0B B5",
		same_bytes(last_dir(entries(mark), "uw").bytes,
			{ 0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x0B, 0xB5 }),
		table.concat(last_dir(entries(mark), "uw").bytes, ","))
	check("时序含 uf→uw→ur", count_dir(entries(mark), "uf") == 1
		and count_dir(entries(mark), "uw") == 1 and count_dir(entries(mark), "ur") == 1)

	-- advance 后 read：位置与移动标志联动
	dev:set_present_position(0)
	expect_ok("写目标 600@300 步/s", function()
		return call(meta({ position = 600, speed = 300 }))
	end)
	dev:advance(500)
	r = expect_ok("read after advance OK", function() return read(meta({})) end)
	check("500ms 后 position=150 moving=1 speed=300",
		r.position == 150 and r.moving == 1 and r.speed == 300)

	-- 噪声前置：聚合扫描仍可解出
	dev:noise(true)
	r = expect_ok("噪声帧聚合 read OK", function() return read(meta({})) end)
	dev:noise(false)
	check("噪声下位置仍解码正确", r.position == 150)

	-- 负路径
	dev:no_reply(true)
	expect_err("无应答 read ERR（超时）", function() return read(meta({})) end,
		"No feedback response")
	dev:no_reply(false)
	dev:corrupt_checksum(true)
	expect_err("坏校验和 read ERR（无有效帧）", function() return read(meta({})) end,
		"no valid frame")
	dev:corrupt_checksum(false)
	expect_err("read fd 非法 ERR", function() return read(meta({ fd = -1 })) end,
		"Invalid Argument: fd")
	expect_err("read 非表 ERR", function() return read(nil) end, "Invalid Arguments Type: table")

	-- 总线级硬错误
	vbus.uart_fail_read = true
	expect_err("链路硬错误 read ERR", function() return read(meta({})) end, "read error")
	vbus.uart_fail_read = false
end

-- ==================== 组 6：destroy（扭矩关闭） ====================
do
	local mark = section()
	expect_ok("destroy OK", function() return destroy(meta({})) end)
	check("扭矩关闭帧 = FF FF 01 04 03 28 00 CF",
		same_bytes(last_dir(entries(mark), "uw").bytes,
			{ 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x00, 0xCF }),
		table.concat(last_dir(entries(mark), "uw").bytes, ","))
	check("模型 torque=0（自由）", dev:torque_enable() == 0)

	-- build 未成功（fd 非法）→ 跳过写且零事务
	mark = section()
	expect_ok("destroy fd 非法仍 OK", function() return destroy({ id = 1 }) end)
	check("未建路径零总线事务", #entries(mark) == 0)

	-- 写失败路径
	dev:fail_write(true)
	expect_err("destroy TX 失败 ERR", function() return destroy(meta({})) end,
		"Failed to write torque-off")
	dev:fail_write(false)
	expect_err("destroy 非表 ERR", function() return destroy(nil) end,
		"Invalid Arguments Type: table")
end

-- ==================== 组 7：set_id 烧号 ====================
do
	local mark = section()		-- 模型回 id=1 / 锁 1
	dev:set_present_position(0)

	-- 审计 H-3 防线负路径：结构期未声明 allow_burn → set_id 烧号拒绝
	local mark_guard = section()
	expect_err("未授权 allow_burn：set_id 烧号拒绝", function()
		return call(meta({ set_id = 7 }))
	end, "requires allow_burn")
	check("拒绝路径零总线事务（未解锁 EPROM、未广播写号）",
		count_dir(entries(mark_guard), "uw") == 0)

	-- 正常烧号（结构元数据带 allow_burn=1 授权）：解锁帧（0x30=0，发往当前站号）
	-- → 广播写号帧（0xFE/0x05=7）
	local r = expect_ok("set_id=7 OK", function()
		return call(meta({ set_id = 7, allow_burn = 1 }))
	end)
	check("返回 set_id=7 且带生效说明",
		r.set_id == 7 and r.note == "断电重启后生效")
	local es = entries(mark)
	check("恰两帧 uw（无位置帧混入）", count_dir(es, "uw") == 2)
	check("解锁帧 = FF FF 01 04 03 30 00 C7（发往当前站号）",
		same_bytes(es[1].bytes, { 0xFF, 0xFF, 0x01, 0x04, 0x03, 0x30, 0x00, 0xC7 }),
		table.concat(es[1].bytes, ","))
	check("写号帧 = FF FF FE 04 03 05 07 EE（广播，与手册例 3 同型）",
		same_bytes(es[2].bytes, { 0xFF, 0xFF, 0xFE, 0x04, 0x03, 0x05, 0x07, 0xEE }),
		table.concat(es[2].bytes, ","))
	check("模型：站号=7 / 已解锁 / 已持久化",
		dev:id() == 7 and dev:lock() == 0 and dev:persisted_id() == 7)
	check("驱动先解锁后写号（persisted 更新即证明顺序正确）",
		dev:persisted_id() == 7)

	-- 烧号后：旧站号 PING 超时、新站号可正常 build（模型站号已切换不 reset）
	expect_err("烧号后旧站号 build 超时 ERR", function()
		return build(meta({ id = 1 }))
	end, "No PING response")
	expect_ok("烧号后新站号 build OK", function()
		return build(meta({ id = 7 }))
	end)

	-- set_id 独占：同行携带的 position/torque 数值被忽略（"-" 继承的产物）
	mark = section()
	r = expect_ok("set_id 与 position 同行：忽略位置", function()
		return call(meta({ set_id = 8, position = 512, speed = 300, torque = 1, allow_burn = 1 }))
	end)
	local es2 = entries(mark)
	check("仅两帧且分别为 0x30 解锁与 0x05 写号（无位置/扭矩帧）",
		count_dir(es2, "uw") == 2
		and es2[1].bytes[6] == 0x30 and es2[2].bytes[6] == 0x05
		and es2[2].bytes[3] == 0xFE)
	check("同行位置被忽略：模型未收到位置写", dev:goal_position() == 0 and r.set_id == 8)

	-- set_id<=0（"-" 首行解析为 0 的形态）不触发烧号：与位置照常共存
	mark = section()
	r = expect_ok("set_id=0 不烧号，位置照常", function()
		return call(meta({ set_id = 0, position = 100, speed = 0, time = 0 }))
	end)
	check("仅位置帧（无 0x05/0x30 帧）",
		count_dir(entries(mark), "uw") == 1
		and entries(mark)[1].bytes[6] == 0x2A and dev:goal_position() == 100)
	check("模型未发生站号切换", dev:id() == 1 and dev:persisted_id() == 1)

	-- 负路径
	section()
	expect_err("set_id=0 且无位置 ERR（提示含 set_id）", function()
		return call(meta({ set_id = 0 }))
	end, "set_id")
	expect_err("set_id=254 ERR", function()
		return call(meta({ set_id = 254 }))
	end, "Invalid Argument: set_id")
	expect_err("set_id 非整数 ERR", function()
		return call(meta({ set_id = 1.5 }))
	end, "Invalid Argument: set_id")
	expect_err("空参 ERR 提示含 set_id", function()
		return call(meta({}))
	end, "set_id")
	dev:fail_write(true)
	expect_err("解锁帧 TX 失败 ERR", function()
		return call(meta({ set_id = 5, allow_burn = 1 }))
	end, "Failed to write EPROM unlock")
	dev:fail_write(false)
	expect_ok("故障撤销后恢复烧号", function()
		return call(meta({ set_id = 5, allow_burn = 1 }))
	end)
	check("模型站号=5 持久化", dev:id() == 5 and dev:persisted_id() == 5)
end

tester.summary("SCSCL")

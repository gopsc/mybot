-- test_mhz19.lua —— MHZ19 真实驱动 + 虚拟 UART 总线 + CO₂ 器件模型
-- 用法（项目根目录）: luajit test/test_mhz19.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：MHZ19_GC=1 luajit test/test_mhz19.lua
--
-- 从「dofile 驱动后手写 uart_* 桩（局部计数、拼应答表）」迁移到
-- 「真实驱动 + virtbus 注入层 + 内嵌模型（modules/MHZ19.lua 尾部 MHZ19_VIRT，
-- 2026-09-15 自 virtbus/mhz19.lua 迁入）」：协议帧、读轮次、
-- flush 时序全部经 txlog 留痕断言，噪声/不应答/坏校验和/写失败/链路硬错误
-- 全部由模型与总线级钩子提供，不再手拼桩函数。
--
-- 协议事实（Winsen MH-Z19B 手册，与驱动/模型三处交叉）：
--   请求 9B：FF 01 86 00 00 00 00 00 79（CS = (0x100 - Σb2..b8) % 0x100）
--   应答 9B：FF 86 HI LO TEMP S 00 00 CS；CO₂ = HI*256 + LO，TEMP 字节 = °C+40
--   经典向量：CO₂=500 → FF 86 01 F4 42 00 00 00 43（26°C）
--
-- 覆盖六组：
--   1) 模型事实：checksum 交叉、on_write 直调应答、ppm/温度/状态注入与钳制、
--      非法请求不应答、四故障钩子、reset 不清钩子、virt_tick 钉值/周期
--   2) 虚拟原语契约：注入身份、open baud/path 负路径、write 校验静默
--      （非法入参零留痕）、byte_of floor 语义、read n 校验与 512 钳制、
--      uart_fail_read、flush 清环、close 后读写全灭
--   3) 真实 build：uf 留痕恰一次、横幅、fd 非法/非表负路径且零事务
--   4) 真实 call：uw 请求帧逐字节、应答帧经典向量 500ppm/26°C、
--      uf→uw→ur 时序、正常单轮读、噪声双轮聚合、32 拍 tick 驱动闭环
--   5) call 负路径：no_reply→超时、坏校验和→无帧、fail_read→读错、
--      fail_write→写失败（零请求留痕）、坏 fd 零事务、缺参
--   6) destroy：OK 且零总线事务、非表 ERR

if os.getenv("MHZ19_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local PATH = "/dev/serial0"
local REQ = { 0xFF, 0x01, 0x86, 0x00, 0x00, 0x00, 0x00, 0x00, 0x79 }

-- 模型内嵌于驱动文件（MHZ19_VIRT 全局工厂，工厂表带 BUS="uart"）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/MHZ19.lua")
local mm = MHZ19_VIRT

local dev = mm.new()
vbus.attach_uart("MHZ19@" .. PATH, PATH, dev)

local fd = uart_open(PATH, 9600)
check("uart_open 虚拟 fd=3", fd == 3, tostring(fd))

-- 独立第三份校验和实现（测试侧交叉，不与驱动/模型共享代码）
local function cs9(t)
	local s = 0
	for i = 2, 8 do s = s + t[i] end
	return (256 - (s % 256)) % 256
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

-- 每个 section：器件复位 + 故障解除（挂载/fd 不动）
local function section()
	dev:reset()
	dev:clear_faults()
	vbus.uart_fail_read = false
	return #vbus.txlog
end

-- 横幅捕获（驱动 build 仅一条 print）
local cap_lines = {}
local real_print = print
local function cap_start()
	cap_lines = {}
	print = function(s) cap_lines[#cap_lines + 1] = tostring(s) end
end
local function cap_stop() print = real_print end
local function banner(pat)
	for _, s in ipairs(cap_lines) do
		if s:find(pat, 1, true) then return s end
	end
	return nil
end

-- ==================== 组 1：模型协议事实 ====================
do
	section()
	-- 经典向量交叉：请求帧校验和 0x79（独立实现 vs 常量）
	check("请求帧 CS=0x79", cs9(REQ) == 0x79, string.format("0x%02X", cs9(REQ)))

	-- on_write 直调：合法请求 → 9 字节应答（默认 400ppm/65 字节温度/状态 0）
	local r = dev.on_write({ 0xFF, 0x01, 0x86, 0, 0, 0, 0, 0, 0x79 })
	check("直调应答 9 字节且帧头 FF 86",
		type(r) == "table" and #r == 9 and r[1] == 0xFF and r[2] == 0x86)
	check("400ppm 拆 HI=1 LO=144，TEMP 字节 65",
		r[3] == 1 and r[4] == 144 and r[5] == 65 and r[6] == 0)
	check("应答 CS 与独立实现一致", r[9] == cs9(r), string.format("0x%02X", r[9]))
	check("合法请求留痕 valid=true",
		dev:request_count() == 1 and dev:requests()[1].valid == true)

	-- CO₂=500 经典向量（旧测试同款）：HI LO = 01 F4，26°C → 字节 66
	dev:reset()
	dev:set_co2(500):set_temp_c(26)
	r = dev.on_write(REQ)
	check("500ppm/26°C 应答帧逐字节 = FF 86 01 F4 42 00 00 00 43",
		same_bytes(r, { 0xFF, 0x86, 0x01, 0xF4, 0x42, 0x00, 0x00, 0x00, 0x43 }),
		table.concat(r, ","))

	-- 钳制语义：ppm floor+0..65535、温度字节 -40..215、状态 %256
	dev:set_co2(-5)
	check("set_co2 负值钳 0", dev:co2() == 0)
	dev:set_co2(70000)
	check("set_co2 超界钳 65535 且 HI=LO=255", dev:co2() == 65535)
	dev:set_co2(400.9)
	check("set_co2 小数 floor", dev:co2() == 400)
	dev:set_temp_c(-50)
	check("set_temp_c 下越界钳字节 0", dev:temp_raw() == 0)
	dev:set_temp_c(220)
	check("set_temp_c 上越界钳字节 255", dev:temp_raw() == 255)
	dev:set_status(300)
	check("set_status 取模 256", dev:status() == 44)

	-- 非法请求一律不应答（真机对垃圾字节流不回帧），且留痕 valid=false
	dev:reset()
	check("短帧不应答", dev.on_write({ 0xFF, 0x01, 0x86 }) == nil)
	check("坏帧头不应答",
		dev.on_write({ 0xFE, 0x01, 0x86, 0, 0, 0, 0, 0, 0x7A }) == nil)
	check("坏校验和请求不应答",
		dev.on_write({ 0xFF, 0x01, 0x86, 0, 0, 0, 0, 0, 0x78 }) == nil)
	local rq = dev:requests()
	check("三类非法请求均留痕 valid=false",
		#rq == 3 and rq[1].valid == false and rq[2].valid == false and rq[3].valid == false)
	dev:reset_logs()
	check("reset_logs 清空请求留痕", dev:request_count() == 0)

	-- 故障钩子三态：nil（不应答但请求仍算合法）、false（TX 失败不解析请求）
	dev:no_reply(true)
	r = dev.on_write(REQ)
	check("no_reply 返 nil 且请求留痕 valid=true",
		r == nil and dev:requests()[1].valid == true)
	dev:no_reply(false)
	check("撤 no_reply 后恢复应答", dev.on_write(REQ) ~= nil)
	dev:fail_write(true)
	dev:reset_logs()
	check("fail_write 返 false 且不解析请求",
		dev.on_write(REQ) == false and dev:request_count() == 0)
	dev:fail_write(false)
	dev:corrupt_checksum(true)
	r = dev.on_write(REQ)
	check("corrupt_checksum 翻转应答 CS（帧头仍在）",
		r[1] == 0xFF and r[2] == 0x86 and r[9] ~= cs9(r))
	dev:corrupt_checksum(false)
	dev:noise(true)
	r = dev.on_write(REQ)
	dev:noise(false)
	local clean = dev.on_write(REQ)
	check("noise 前置 3 个无帧头噪声字节后接完整帧",
		#r == 12 and r[1] == 0x00 and r[2] == 0x01 and r[3] == 0x02
		and same_bytes({ r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12] }, clean))

	-- reset 回初值但不清钩子（负路径 section 防假绿）
	dev:no_reply(true)
	dev:set_co2(1234)
	dev:reset()
	check("reset 回 400ppm 初值", dev:co2() == 400)
	check("reset 不清 no_reply 钩子", dev.on_write(REQ) == nil)
	dev:clear_faults()
	check("clear_faults 后恢复应答", dev.on_write(REQ) ~= nil)

	-- virt_tick：32 拍爬坡 400 + m*128，钉值 + 周期 + 确定性
	dev:reset()
	dev:virt_tick(0)
	check("tick 0 钉值 400", dev:co2() == 400)
	dev:virt_tick(5)
	check("tick 5 钉值 1040", dev:co2() == 1040)
	dev:virt_tick(31)
	check("tick 31 钉值 4368", dev:co2() == 4368)
	dev:virt_tick(32)
	check("tick 32 回卷 400（周期 32）", dev:co2() == 400)
	dev:virt_tick(7)
	local hold = dev:co2()
	dev:virt_tick(7)
	check("tick 确定性（同拍同值）", hold == 1296 and dev:co2() == 1296, tostring(hold))
end

-- ==================== 组 2：虚拟原语契约 ====================
do
	section()
	check("五 uart 全局均为 virtbus 注入实现",
		uart_open == vbus.v_uart_open and uart_close == vbus.v_uart_close
		and uart_flush == vbus.v_uart_flush and uart_write == vbus.v_uart_write
		and uart_read == vbus.v_uart_read)

	-- open：baud/path 白名单同 HAL；非法 -1 且零留痕
	local mark = #vbus.txlog
	check("坏波特率 -1", uart_open(PATH, 1234) == -1)
	check("坏路径 -1（serial 无数字）", uart_open("/dev/serial", 9600) == -1)
	check("坏路径 -1（tty 含非法字符）", uart_open("/dev/ttyX-1", 9600) == -1)
	check("非法 open 零留痕", #vbus.txlog == mark)
	local fd2 = uart_open("/dev/ttyUSB9", 115200)
	check("ttyUSB9@115200 打开成功", fd2 > fd, tostring(fd2))
	local e = vbus.txlog[#vbus.txlog]
	check("uopen 留痕 path+baud",
		e.dir == "uopen" and e.path == "/dev/ttyUSB9" and e.baud == 115200)

	-- write：入参非法一律 -1 且不发事务（HAL 校验语义镜像）
	mark = #vbus.txlog
	check("write 非表 -1", uart_write(fd, "x") == -1)
	check("write 空表 -1", uart_write(fd, {}) == -1)
	local big = {}
	for i = 1, 513 do big[i] = 0x55 end
	check("write 超 512 字节 -1", uart_write(fd, big) == -1)
	check("write 字节越界 256 → -1", uart_write(fd, { 0xFF, 0x86, 256 }) == -1)
	check("write 字节负值 → -1", uart_write(fd, { -1 }) == -1)
	check("write 非数字字节 → -1", uart_write(fd, { "abc" }) == -1)
	check("write 未开 fd → -1", uart_write(99, { 0x01 }) == -1)
	check("非法 write 全部零留痕", #vbus.txlog == mark)
	-- byte_of 为 floor 而非拒绝：3.7 落环为 3
	check("write 小数 floor 成功", uart_write(fd, { 3.7 }) == 1)
	local we = last_dir(entries(mark), "uw")
	check("留痕 bytes 已 floor", we and same_bytes(we.bytes, { 3 }))
	uart_flush(fd)

	-- read：n 校验同 HAL；n>512 钳 512
	mark = #vbus.txlog
	check("read n=0 → nil", uart_read(fd, 0) == nil)
	check("read n 负值 → nil", uart_read(fd, -5) == nil)
	check("read n 非数字 → nil", uart_read(fd, "x") == nil)
	check("read 未开 fd → nil", uart_read(99, 9) == nil)
	check("非法 read 零留痕", #vbus.txlog == mark)
	check("read n=600 钳 512 返表", type(uart_read(fd, 600)) == "table")
	e = vbus.txlog[#vbus.txlog]
	check("ur 留痕 n=512", e.dir == "ur" and e.n == 512 and #e.bytes == 0)
	check("字符串 n=\"9\" 可用", type(uart_read(fd, "9")) == "table")

	-- 环 drain：应答入环后按请求量分段取走
	mark = #vbus.txlog
	check("write 请求帧返 9", uart_write(fd, REQ) == 9)
	local part = uart_read(fd, 4)
	check("环分段：先 4 字节 FF 86 01 90",
		same_bytes(part, { 0xFF, 0x86, 0x01, 0x90 }), table.concat(part, ","))
	part = uart_read(fd, 9)
	check("续读补余 5 字节且尾 CS 正确",
		#part == 5 and part[5] == cs9({ 0xFF, 0x86, 0x01, 0x90, 0x41, 0, 0, 0, part[5] }))
	check("环空后读空表（超时语义）", #uart_read(fd, 9) == 0)

	-- flush：清输入环 + 留痕；无效 fd -1
	uart_write(fd, REQ)
	mark = #vbus.txlog
	check("flush 有效 fd 返 0", uart_flush(fd) == 0)
	check("uf 留痕", vbus.txlog[#vbus.txlog].dir == "uf")
	check("flush 后读空表", #uart_read(fd, 9) == 0)
	check("flush 未开 fd -1", uart_flush(99) == -1)

	-- 总线级硬错误：uart_fail_read → nil 且事务记 err=true
	vbus.uart_fail_read = true
	mark = #vbus.txlog
	check("fail_read 返 nil", uart_read(fd, 9) == nil)
	e = vbus.txlog[#vbus.txlog]
	check("fail_read 留痕 err=true", e.dir == "ur" and e.err == true)
	vbus.uart_fail_read = false

	-- close：静默清登记（零留痕），此后读写全灭
	mark = #vbus.txlog
	check("close 返 0", uart_close(fd2) == 0)
	check("close 零留痕", #vbus.txlog == mark)
	check("close 后 write -1", uart_write(fd2, { 0x01 }) == -1)
	check("close 后 read nil", uart_read(fd2, 9) == nil)
	check("close 负 fd -1", uart_close(-1) == -1)
end

-- ==================== 组 3：真实 build ====================
do
	local mark = section()
	cap_start()
	local res = build({ fd = fd })
	cap_stop()
	check("build OK", res.result == "OK", tostring(res.message))
	check("横幅含 MHZ19 init OK: fd=3（9600 8N1 预热提示）",
		banner("MHZ19 init OK: fd=" .. fd .. " (9600 8N1") ~= nil)
	local es = entries(mark)
	check("build 事务恰一条 uf", #es == 1 and es[1].dir == "uf" and es[1].path == PATH,
		table.concat(dirs_of(es), ","))

	expect_err("build 非表 ERR", function() return build(1) end,
		"Invalid Arguments Type: table")
	expect_err("build 缺 fd ERR", function() return build({}) end,
		"Invalid Argument: fd")
	expect_err("build fd<0 ERR", function() return build({ fd = -1 }) end,
		"Invalid Argument: fd")
	check("fd 非法 build 零事务", #entries(mark) == 1)
end

-- ==================== 组 4：真实 call ====================
do
	-- 默认态：400ppm/25°C，uf→uw→ur 单轮聚合
	local mark = section()
	local res = expect_ok("call 默认读数 OK", function() return call({ fd = fd }) end)
	check("CO2=400 TEMP=25 S=0",
		res and res.CO2 == 400 and res.TEMP == 25 and res.S == 0,
		res and string.format("%s/%s/%s", res.CO2, res.TEMP, res.S))
	local es = entries(mark)
	check("事务时序 uf→uw→ur",
		table.concat(dirs_of(es), ",") == "uf,uw,ur", table.concat(dirs_of(es), ","))
	local uw = last_dir(es, "uw")
	check("uw 请求帧逐字节 = FF 01 86 00*5 79", same_bytes(uw.bytes, REQ),
		table.concat(uw.bytes, ","))
	local ur = last_dir(es, "ur")
	check("正常应答单轮读满 9 字节", ur.n == 9 and #ur.bytes == 9)
	check("应答帧逐字节 = FF 86 01 90 41 00 00 00 A8",
		same_bytes(ur.bytes,
			{ 0xFF, 0x86, 0x01, 0x90, 0x41, 0x00, 0x00, 0x00, 0xA8 }),
		table.concat(ur.bytes, ","))
	check("驱动收发均 ok 且请求留痕合法",
		uw.ok == true and dev:request_count() == 1
		and dev:requests()[1].valid == true)

	-- 经典向量：500ppm/26°C 经真实驱动解出 TEMP=26
	mark = section()
	dev:set_co2(500):set_temp_c(26)
	res = expect_ok("call 500ppm OK", function() return call({ fd = fd }) end)
	check("CO2=500 TEMP=26", res.CO2 == 500 and res.TEMP == 26,
		string.format("%s/%s", res.CO2, res.TEMP))
	check("500ppm 应答帧 = FF 86 01 F4 42 00 00 00 43",
		same_bytes(last_dir(entries(mark), "ur").bytes,
			{ 0xFF, 0x86, 0x01, 0xF4, 0x42, 0x00, 0x00, 0x00, 0x43 }))

	-- 状态字节透传
	mark = section()
	dev:set_status(0x41)
	res = expect_ok("call 带状态 OK", function() return call({ fd = fd }) end)
	check("S 字节透传 65", res.S == 65, tostring(res.S))

	-- 前导噪声：帧跨两轮到达，驱动聚合扫描仍解出正确 CO₂
	mark = section()
	dev:set_co2(1234):noise(true)
	res = expect_ok("call 噪声环境 OK", function() return call({ fd = fd }) end)
	check("噪声双轮聚合后 CO2=1234",
		res.CO2 == 1234 and count_dir(entries(mark), "ur") == 2,
		string.format("%s/%d 轮", res.CO2, count_dir(entries(mark), "ur")))
	check("第二轮补齐帧尾 FF 86 完整",
		last_dir(entries(mark), "ur").bytes[1] == 0x00)

	-- virt_tick 32 拍经真实驱动闭环（含 32 回卷拍共 33 次）
	mark = section()
	local all_ok = true
	for n = 0, 32 do
		dev:virt_tick(n)
		local r = call({ fd = fd })
		local want = 400 + (n % 32) * 128
		if r.result ~= "OK" or r.CO2 ~= want then
			all_ok = false
			break
		end
	end
	check("tick 33 次驱动闭环 CO2 逐拍钉值", all_ok)
	check("33 拍共 99 事务（每拍 uf+uw+ur）", #entries(mark) == 99,
		tostring(#entries(mark)))
end

-- ==================== 组 5：call 负路径 ====================
do
	-- 不应答：3 轮读全空 → timeout (no bytes)
	local mark = section()
	dev:no_reply(true)
	expect_err("no_reply → 超时无字节", function() return call({ fd = fd }) end,
		"MHZ19 no valid response: timeout (no bytes)")
	local es = entries(mark)
	check("超时路径 uw 成功 + 3 轮空读",
		count_dir(es, "uw") == 1 and count_dir(es, "ur") == 3
		and #last_dir(es, "ur").bytes == 0, table.concat(dirs_of(es), ","))

	-- 坏校验和：帧头命中但 CS 落空 → no valid frame
	mark = section()
	dev:corrupt_checksum(true)
	expect_err("坏 CS → 无有效帧", function() return call({ fd = fd }) end,
		"MHZ19 no valid response: no valid frame (head FF 86 + checksum)")
	es = entries(mark)
	check("坏 CS 路径 3 轮读、首帧 9 字节被弃",
		count_dir(es, "ur") == 3 and #es[3].bytes == 9)

	-- 链路硬错误：首轮 nil 即报 read error
	mark = section()
	vbus.uart_fail_read = true
	expect_err("fail_read → 读错误", function() return call({ fd = fd }) end,
		"MHZ19 no valid response: read error")
	es = entries(mark)
	check("read error 立即短路（1 次 err 事务）",
		count_dir(es, "ur") == 1 and last_dir(es, "ur").err == true)
	vbus.uart_fail_read = false

	-- TX 失败：-1 → Failed to write，且模型不解析请求（零留痕）
	mark = section()
	dev:fail_write(true)
	expect_err("fail_write → 写请求失败", function() return call({ fd = fd }) end,
		"Failed to write MHZ19 request (-1)")
	es = entries(mark)
	check("写失败留痕 ok=false 且无后续读",
		count_dir(es, "uw") == 1 and last_dir(es, "uw").ok == false
		and count_dir(es, "ur") == 0)
	check("写失败不进请求解析", dev:request_count() == 0)

	-- 入参负路径
	expect_err("call 非表 ERR", function() return call("x") end,
		"Invalid Arguments Type: table")
	expect_err("call 缺 fd ERR", function() return call({}) end,
		"Invalid Argument: fd")
	mark = section()
	expect_err("call 未开 fd → 写失败", function() return call({ fd = 99 }) end,
		"Failed to write MHZ19 request (-1)")
	check("未开 fd 全链路零事务（flush 也静默）", #entries(mark) == 0)

	-- 恢复性：故障清除后同一 fd 直接可读
	mark = section()
	expect_ok("负路径后恢复正常读数", function() return call({ fd = fd }) end)
	check("恢复后 CO2=400",
		last_dir(entries(mark), "ur") ~= nil and call({ fd = fd }).CO2 == 400)
end

-- ==================== 组 6：destroy ====================
do
	local mark = section()
	expect_ok("destroy OK", function() return destroy({ fd = fd }) end)
	check("destroy 零总线事务", #entries(mark) == 0)
	expect_err("destroy 非表 ERR", function() return destroy(nil) end,
		"Invalid Arguments Type: table")
end

tester.summary("MHZ19")

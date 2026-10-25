-- test_sds011.lua —— SDS011 真实驱动 + 虚拟 UART 总线 + 颗粒物器件模型
-- 用法（项目根目录）: luajit test/test_sds011.lua（驱动依赖 HAL ffi，需 LuaJIT）
--   GC 压力节奏：SDS011_GC=1 luajit test/test_sds011.lua
--
-- 从「dofile 驱动后手写 uart_* 桩（局部 pending 队列、手拼 ACK/查询表）」迁移到
-- 「真实驱动 + virtbus 注入层 + 内嵌模型（modules/SDS011.lua 尾部 SDS011_VIRT，
-- 2026-09-15 自 virtbus/sds011.lua 迁入）」：19 字节请求帧/10 字节
-- 应答帧、读轮次、flush 时序全部经 txlog 留痕断言；坏校验和/不应答/写失败/
-- 主动流残留帧/丢单命令应答全部由模型钩子与总线级钩子提供。
--
-- 协议事实（驱动头注释：py-sds011 与 ricki-z/SDS011 互证；三处独立实现交叉）：
--   请求 19B：AA B4 CMD D0*12 FF FF CS AB（CS = Σb3..b17 % 256）
--   应答 10B：AA C5 b3 b4 b5 b6 FF FF CS AB（CS = Σb3..b8 % 256）
--     —— 驱动 read_frame 的扫描窗口恰 10 字节：acc[i+2..i+7] 求和、acc[i+8] 比对，
--        故应答数据段只有 4 字节，ID 两字节计入校验和（本文件与模型各自独立实现）。
--   同帧换语义：0x04 → b3..b6 = PM25L PM25H PM10L PM10H（/10 = µg/m³）；
--               0x02/0x06 → b3 b4 = 命令号 D0（回显校验）；0x07 → b3 b4 = 固件版本
--   经典向量：PM2.5=423(42.3) PM10=1000(100.0) →
--             AA C5 A7 01 E8 03 FF FF 91 AB
--
-- 覆盖六组：
--   1) 模型事实：两侧 CS 独立实现交叉、四类命令应答逐字节、钳制、状态位
--      （passive/sleeping）、非法/未知命令不应答、六故障钩子、reset 不清钩子、
--      virt_tick 钉值与小数不变量
--   2) 虚拟原语契约：注入身份、open/write/read 校验与零留痕、环跨轮 drain、
--      flush 清环、uart_fail_read、close 静默
--   3) 真实 build：两事务序列、横幅固件版本、被动回显、timeout 列透传、
--      版本应答丢失仍降级 OK、fd 负路径
--   4) 真实 call：查询帧/应答帧逐字节、PM 换算、power sleep/work 回显、
--      小端字节拆分、残留主动流多轮扫描、tick 波形闭环与事务计数
--   5) call/build 负路径：超时、坏 CS、读错、写失败、未开 fd、缺参、恢复性
--   6) destroy：OK 且零总线事务、非表 ERR

if os.getenv("SDS011_GC") == "1" then
	collectgarbage("setpause", 1)
	collectgarbage("setstepmul", 100000)
end

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

local PATH = "/dev/serial0"

-- 测试侧独立请求帧校验和实现（Σb3..b17 % 256，与驱动/模型不共享代码）
local function req_cs(f)
	local s = 0
	for i = 3, 17 do s = s + f[i] end
	return s % 256
end

-- 测试侧独立应答校验和实现（Σb3..b8 % 256）
local function resp_cs(f)
	local s = 0
	for i = 3, 8 do s = s + f[i] end
	return s % 256
end

-- 构造 19 字节合法请求帧（模板 = 驱动 make_frame 的等价式，CS 用本文件独立实现）
local function req(cmd, d0)
	local f = { 0xAA, 0xB4, cmd }
	for _ = 1, 12 do f[#f + 1] = d0 or 0 end
	f[#f + 1] = 0xFF
	f[#f + 1] = 0xFF
	f[#f + 1] = req_cs(f)
	f[#f + 1] = 0xAB
	return f
end

local REQ_QUERY = req(0x04, 0)
local REQ_PASSIVE = req(0x02, 1)

-- 应答帧参考向量（由模型独立组装，本处仅作逐字节断言的第三份实现）
local RSP_QUERY = { 0xAA, 0xC5, 0xA7, 0x01, 0xE8, 0x03, 0xFF, 0xFF, 0x91, 0xAB }
local ACK_PASSIVE = { 0xAA, 0xC5, 0x02, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x01, 0xAB }
local RSP_VERSION = { 0xAA, 0xC5, 0x07, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x05, 0xAB }

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

-- 模型内嵌于驱动文件（SDS011_VIRT 全局工厂，工厂表带 BUS="uart"）：
-- load_driver 完成驱动定义与重注入后，从全局取工厂建实例再挂载
vbus.load_driver("modules/SDS011.lua")
local mm = SDS011_VIRT

local dev = mm.new()
vbus.attach_uart("SDS011@" .. PATH, PATH, dev)

local fd = uart_open(PATH, 9600)
check("uart_open 虚拟 fd=3", fd == 3, tostring(fd))

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
	-- 请求帧校验和交叉：查询 0x04+510=0x02、切被动 0x02+12*1+510=0x0C
	check("查询请求 CS=0x02", req_cs(REQ_QUERY) == 0x02, string.format("0x%02X", req_cs(REQ_QUERY)))
	check("切被动请求 CS=0x0C", req_cs(REQ_PASSIVE) == 0x0C, string.format("0x%02X", req_cs(REQ_PASSIVE)))
	check("请求帧 19 字节、尾 AB", #REQ_QUERY == 19 and REQ_QUERY[19] == 0xAB)

	-- 0x04 查询：默认 423/1000 → 经典向量（小端拆分；10 字节定长应答）
	local r = dev.on_write(REQ_QUERY)
	check("查询应答 10 字节且帧头 AA C5",
		type(r) == "table" and #r == 10 and r[1] == 0xAA and r[2] == 0xC5)
	check("423/1000 应答逐字节 = AA C5 A7 01 E8 03 FF FF 91 AB",
		same_bytes(r, RSP_QUERY), table.concat(r, ","))
	check("应答 CS 与独立实现一致", resp_cs(r) == r[9], string.format("0x%02X", r[9]))

	-- 0x02 命令 ACK：b3 b4 = 命令号 D0（驱动回读校验 passive 的依据）
	r = dev.on_write(req(0x02, 1))
	check("切被动 ACK = AA C5 02 01 00 00 FF FF 01 AB",
		same_bytes(r, ACK_PASSIVE), table.concat(r, ","))
	check("ACK CS 与独立实现一致", resp_cs(r) == r[9], string.format("0x%02X", r[9]))
	check("0x02 D0=1 后 passive 置位", dev:passive_mode() == true)
	r = dev.on_write(req(0x02, 0))
	check("0x02 D0=0 撤回主动模式", dev:passive_mode() == false and r[4] == 0)

	-- 0x06 睡眠/工作：D0=0 停转、D0=1 运转
	r = dev.on_write(req(0x06, 0))
	check("睡眠 ACK b3 b4 = 06 00 且 sleeping", r[3] == 0x06 and r[4] == 0 and dev:sleeping() == true)
	check("睡眠 ACK CS=0x04", r[9] == 0x04, string.format("0x%02X", r[9]))
	r = dev.on_write(req(0x06, 1))
	check("工作 ACK b3 b4 = 06 01 且恢复运转", r[4] == 1 and dev:sleeping() == false)
	check("工作 ACK CS=0x05", r[9] == 0x05, string.format("0x%02X", r[9]))

	-- 0x07 版本：b3 b4 = 固件主/次版本
	r = dev.on_write(req(0x07, 0))
	check("版本应答 = AA C5 07 00 00 00 FF FF 05 AB", same_bytes(r, RSP_VERSION),
		table.concat(r, ","))
	dev:set_firmware(160, 300)
	r = dev.on_write(req(0x07, 0))
	check("set_firmware 取模 256 → b3 b4 = 160 44", r[3] == 160 and r[4] == 44,
		string.format("%d,%d", r[3], r[4]))

	-- 钳制与 floor 语义
	dev:reset()
	dev:set_pm25_raw(-5)
	check("set_pm25_raw 负值钳 0", dev:pm25_raw() == 0)
	dev:set_pm25_raw(70000)
	check("set_pm25_raw 超界钳 65535", dev:pm25_raw() == 65535)
	r = dev.on_write(REQ_QUERY)
	check("65535 拆 FF FF", r[3] == 0xFF and r[4] == 0xFF)
	dev:set_pm10_raw(42.9)
	check("set_pm10_raw 小数 floor", dev:pm10_raw() == 42)
	r = dev.on_write(REQ_QUERY)
	check("42 拆 2A 00", r[5] == 0x2A and r[6] == 0x00)

	-- 非法请求一律不应答（真机对垃圾字节流不回帧），且留痕 valid=false
	dev:reset()
	check("短帧不应答", dev.on_write({ 0xAA, 0xB4, 0x04 }) == nil)
	local junk = req(0x04, 0)
	junk[1], junk[2] = 0xB4, 0xAA	-- 长度/CS/尾全对，唯帧头不对
	check("坏帧头不应答", dev.on_write(junk) == nil)
	local bad = req(0x04, 0)
	bad[18] = (bad[18] + 1) % 256
	check("坏校验和请求不应答", dev.on_write(bad) == nil)
	bad = req(0x04, 0)
	bad[19] = 0xAA
	check("坏尾字节不应答", dev.on_write(bad) == nil)
	check("未知命令不应答", dev.on_write(req(0x05, 0)) == nil)
	local rq = dev:requests()
	check("四类非法请求均留痕 valid=false",
		#rq == 5 and rq[1].valid == false and rq[2].valid == false
		and rq[3].valid == false and rq[4].valid == false)
	check("未知命令帧自身合法（valid=true）只是不应答", rq[5].valid == true)
	check("请求留痕带 cmd/d0", rq[5].cmd == 0x05 and rq[5].d0 == 0)
	dev:reset_logs()
	check("reset_logs 清空请求留痕", dev:request_count() == 0)

	-- 故障钩子：三态 + 残留推送 + 定向丢单命令应答
	dev:no_reply(true)
	r = dev.on_write(REQ_QUERY)
	check("no_reply 返 nil 且请求留痕 valid=true",
		r == nil and dev:requests()[1].valid == true)
	dev:no_reply(false)
	check("撤 no_reply 后恢复应答", dev.on_write(REQ_QUERY) ~= nil)
	dev:fail_write(true)
	dev:reset_logs()
	check("fail_write 返 false 且不解析请求",
		dev.on_write(REQ_QUERY) == false and dev:request_count() == 0)
	dev:fail_write(false)
	dev:corrupt_checksum(true)
	r = dev.on_write(REQ_QUERY)
	check("corrupt_checksum 应答 CS +1 翻转（帧头仍在）",
		r[1] == 0xAA and r[2] == 0xC5 and r[9] == (0x91 + 1) and r[10] == 0xAB,
		string.format("0x%02X", r[9]))
	dev:corrupt_checksum(false)
	-- 残留主动帧：10 + 10 = 20 字节，帧头/ID/尾齐但 CS 字段填 0（扫描必落空）
	dev:stale_push(true)
	r = dev.on_write(req(0x02, 1))
	dev:stale_push(false)
	local clean_ack = dev.on_write(req(0x02, 1))
	check("stale_push 前置 10 字节残留帧后接完整 ACK",
		#r == 20 and r[1] == 0xAA and r[2] == 0xC5 and r[9] == 0 and r[10] == 0xAB
		and same_bytes({ r[11], r[12], r[13], r[14], r[15], r[16], r[17], r[18],
			r[19], r[20] }, clean_ack), table.concat(r, ","))
	-- 残留帧自身不得通过校验（否则会被当成 PM=0 的合法查询应答消费）
	check("残留帧 CS 字段 0 不等于合法 CS",
		resp_cs({ r[11], r[12], r[1], r[2], r[3], r[4], r[5], r[6] }) ~= r[9]
		and r[9] == 0)
	dev:swallow_next(0x04)
	check("swallow_next 吞掉指定命令的应答（nil）", dev.on_write(REQ_QUERY) == nil)
	check("swallow_next 单次消费后自动解除", dev.on_write(REQ_QUERY) ~= nil)
	dev:swallow_next(0x04)
	check("swallow_next 不误吞其它命令", dev.on_write(req(0x02, 1)) ~= nil)
	check("swallow_next 仍待吞本命令", dev.on_write(REQ_QUERY) == nil)
	-- reset 回初值但不清钩子（负路径 section 防假绿）
	dev:no_reply(true)
	dev:set_pm25_raw(1234)
	dev:reset()
	check("reset 回 423 初值", dev:pm25_raw() == 423)
	check("reset 回主动模式（上电默认）", dev:passive_mode() == false)
	check("reset 不清 no_reply 钩子", dev.on_write(REQ_QUERY) == nil)
	dev:clear_faults()
	check("clear_faults 后恢复应答", dev.on_write(REQ_QUERY) ~= nil)

	-- virt_tick：5 拍一周扬尘爬坡，钉值 + 恒带一位小数不变量
	dev:reset()
	dev:virt_tick(0)
	check("tick 0 钉值 105/163", dev:pm25_raw() == 105 and dev:pm10_raw() == 163)
	dev:virt_tick(3)
	check("tick 3 钉值 129/187", dev:pm25_raw() == 129 and dev:pm10_raw() == 187)
	dev:virt_tick(4)
	check("tick 4 钉值 137/195", dev:pm25_raw() == 137 and dev:pm10_raw() == 195)
	dev:virt_tick(5)
	check("tick 5 回卷 105（周期 5）", dev:pm25_raw() == 105 and dev:pm10_raw() == 163)
	local all_frac = true
	for n = 0, 9 do
		dev:virt_tick(n)
		if dev:pm25_raw() % 10 == 0 or dev:pm10_raw() % 10 == 0 then all_frac = false end
	end
	check("tick 波形 mod10 恒非 0（PM 读数恒带小数）", all_frac)
	dev:virt_tick(7)
	local hold = dev:pm25_raw()
	dev:virt_tick(7)
	check("tick 确定性（同拍同值）", hold == 121 and dev:pm25_raw() == 121, tostring(hold))
end

-- ==================== 组 2：虚拟原语契约 ====================
do
	section()
	check("五 uart 全局均为 virtbus 注入实现",
		uart_open == vbus.v_uart_open and uart_close == vbus.v_uart_close
		and uart_flush == vbus.v_uart_flush and uart_write == vbus.v_uart_write
		and uart_read == vbus.v_uart_read)

	-- open：先 baud 白名单再 path；非法 -1 且零留痕
	local mark = #vbus.txlog
	check("坏波特率 -1", uart_open(PATH, 1234) == -1)
	check("坏路径 -1（serial 无数字）", uart_open("/dev/serial", 9600) == -1)
	check("坏路径 -1（tty 含非法字符）", uart_open("/dev/ttyU SB0", 9600) == -1)
	check("非法 open 零留痕", #vbus.txlog == mark)
	local fd2 = uart_open("/dev/ttyUSB9", 115200)
	check("ttyUSB9@115200 打开成功", fd2 > fd, tostring(fd2))
	local e = vbus.txlog[#vbus.txlog]
	check("uopen 留痕 path+baud",
		e.dir == "uopen" and e.path == "/dev/ttyUSB9" and e.baud == 115200)

	-- write：入参非法一律 -1 且不发事务
	mark = #vbus.txlog
	check("write 非表 -1", uart_write(fd, "x") == -1)
	check("write 空表 -1", uart_write(fd, {}) == -1)
	local big = {}
	for i = 1, 513 do big[i] = 0x55 end
	check("write 超 512 字节 -1", uart_write(fd, big) == -1)
	check("write 字节越界 256 → -1", uart_write(fd, { 0xAA, 0xB4, 256 }) == -1)
	check("write 字节负值 → -1", uart_write(fd, { -1 }) == -1)
	check("write 非数字字节 → -1", uart_write(fd, { "abc" }) == -1)
	check("write 未开 fd → -1", uart_write(99, REQ_QUERY) == -1)
	check("非法 write 全部零留痕", #vbus.txlog == mark)
	check("write 小数 floor 成功", uart_write(fd, { 3.7 }) == 1)
	e = last_dir(entries(mark), "uw")
	check("留痕 bytes 已 floor", e and same_bytes(e.bytes, { 3 }))
	uart_flush(fd)

	-- read：n 校验同 HAL；n>512 钳 512
	mark = #vbus.txlog
	check("read n=0 → nil", uart_read(fd, 0) == nil)
	check("read n 负值 → nil", uart_read(fd, -5) == nil)
	check("read n 非数字 → nil", uart_read(fd, "x") == nil)
	check("read 未开 fd → nil", uart_read(99, 10) == nil)
	check("非法 read 零留痕", #vbus.txlog == mark)
	check("read n=600 钳 512 返表", type(uart_read(fd, 600)) == "table")
	e = vbus.txlog[#vbus.txlog]
	check("ur 留痕 n=512", e.dir == "ur" and e.n == 512 and #e.bytes == 0)
	check("字符串 n=\"10\" 可用", type(uart_read(fd, "10")) == "table")

	-- 环跨轮 drain：19 字节请求 → 20 字节应答（残留帧 + ACK），分段取尽
	mark = #vbus.txlog
	dev:stale_push(true)
	check("write 切被动请求返 19", uart_write(fd, REQ_PASSIVE) == 19)
	dev:stale_push(false)
	local part = uart_read(fd, 4)
	check("环分段：先 4 字节 AA C5 00 00",
		same_bytes(part, { 0xAA, 0xC5, 0, 0 }), table.concat(part, ","))
	part = uart_read(fd, 10)
	check("续读 10 字节跨两帧（残留帧尾 + ACK 帧头）",
		same_bytes(part, { 0, 0, 0xFF, 0xFF, 0x00, 0xAB, 0xAA, 0xC5, 0x02, 0x01 }),
		table.concat(part, ","))
	part = uart_read(fd, 10)
	check("读尽剩 6 字节且 CS 位置正确",
		same_bytes(part, { 0x00, 0x00, 0xFF, 0xFF, 0x01, 0xAB }), table.concat(part, ","))
	check("drain 事务计数 uw+3 次 ur", count_dir(entries(mark), "uw") == 1
		and count_dir(entries(mark), "ur") == 3,
		table.concat(dirs_of(entries(mark)), ","))
	check("环空后读空表（超时语义）", #uart_read(fd, 10) == 0)

	-- flush：清输入环 + 留痕；无效 fd -1
	uart_write(fd, REQ_QUERY)
	mark = #vbus.txlog
	check("flush 有效 fd 返 0", uart_flush(fd) == 0)
	check("uf 留痕", vbus.txlog[#vbus.txlog].dir == "uf")
	check("flush 后读空表", #uart_read(fd, 10) == 0)
	check("flush 未开 fd -1", uart_flush(99) == -1)

	-- 总线级硬错误：uart_fail_read → nil 且事务记 err=true
	vbus.uart_fail_read = true
	mark = #vbus.txlog
	check("fail_read 返 nil", uart_read(fd, 10) == nil)
	e = vbus.txlog[#vbus.txlog]
	check("fail_read 留痕 err=true", e.dir == "ur" and e.err == true)
	vbus.uart_fail_read = false

	-- close：静默清登记（零留痕），此后读写全灭
	mark = #vbus.txlog
	check("close 返 0", uart_close(fd2) == 0)
	check("close 零留痕", #vbus.txlog == mark)
	check("close 后 write -1", uart_write(fd2, REQ_QUERY) == -1)
	check("close 后 read nil", uart_read(fd2, 10) == nil)
	check("close 后无 uw 留痕", count_dir(entries(mark), "uw") == 0)
	check("close 负 fd -1", uart_close(-1) == -1)
end

-- ==================== 组 3：真实 build ====================
do
	local mark = section()
	cap_start()
	local res = build({ fd = fd })
	cap_stop()
	check("build OK", res.result == "OK", tostring(res.message))
	check("横幅含 SDS011 init OK: fd=3 firmware=7.0 (passive mode)",
		banner("SDS011 init OK: fd=" .. fd .. " firmware=7.0 (passive mode)") ~= nil)
	local es = entries(mark)
	check("build 两命令事务序列",
		table.concat(dirs_of(es), ",") == "uf,uw,ur,uf,uw,ur",
		table.concat(dirs_of(es), ","))
	local uw1 = es[2]
	check("首帧 = 切被动 19 字节（0x02 D0=1）",
		uw1.dir == "uw" and same_bytes(uw1.bytes, REQ_PASSIVE), table.concat(uw1.bytes, ","))
	local ur1 = es[3]
	check("被动 ACK 单轮读满 10 字节", ur1.n == 10 and #ur1.bytes == 10)
	check("ACK 逐字节 = AA C5 02 01 00 00 FF FF 01 AB",
		same_bytes(ur1.bytes, ACK_PASSIVE), table.concat(ur1.bytes, ","))
	local uw2 = es[5]
	check("次帧 = 版本查询（0x07, CS=0x05）", uw2.bytes[3] == 0x07 and uw2.bytes[18] == 0x05)
	check("版本应答逐字节 = AA C5 07 00 00 00 FF FF 05 AB",
		same_bytes(es[6].bytes, RSP_VERSION), table.concat(es[6].bytes, ","))
	check("器件被动位由驱动命令置起", dev:passive_mode() == true)
	check("build 请求留痕恰两次", dev:request_count() == 2
		and dev:requests()[1].valid == true and dev:requests()[2].valid == true)

	-- timeout 列：透传到 uart_read 的 n 不变（应答定长 10），非法值回落默认
	mark = section()
	res = build({ fd = fd, timeout = "800" })
	check("timeout=800 build OK", res.result == "OK", tostring(res.message))
	local ok_n = true
	for _, x in ipairs(entries(mark)) do
		if x.dir == "ur" and x.n ~= 10 then ok_n = false end
	end
	check("ur 每轮请求量恒 10（timeout 不参与虚拟层）", ok_n)
	mark = section()
	check("timeout 负值回落默认仍 OK", build({ fd = fd, timeout = "-1" }).result == "OK")
	check("timeout 非数字回落默认仍 OK", build({ fd = fd, timeout = "-" }).result == "OK")

	-- 版本应答丢失：驱动仅 dbg，横幅降级 firmware=? 且 build 仍 OK
	mark = section()
	dev:swallow_next(0x07)
	cap_start()
	res = build({ fd = fd })
	cap_stop()
	check("版本丢失 build 仍 OK", res.result == "OK", tostring(res.message))
	check("横幅降级 firmware=?", banner("firmware=?") ~= nil)
	es = entries(mark)
	check("版本丢失：第二条命令 3 轮空读后继续",
		count_dir(es, "uw") == 2 and count_dir(es, "ur") == 4,
		table.concat(dirs_of(es), ","))

	-- 负路径
	expect_err("build 非表 ERR", function() return build(1) end,
		"Invalid Arguments Type: table")
	expect_err("build 缺 fd 报 UART 列提示", function() return build({}) end,
		"Invalid Argument: fd (does the UART column reference an @UART variable?)")
	expect_err("build fd<0 ERR", function() return build({ fd = -1 }) end,
		"Invalid Argument: fd")
	mark = section()
	local rerr = build({ fd = 99 })
	check("未开 fd build 报 write failed",
		rerr.result == "ERR" and tostring(rerr.message):find("set passive mode: write failed (-1)", 1, true) ~= nil,
		tostring(rerr.message))
	check("未开 fd 全链路零事务", #entries(mark) == 0)
end

-- ==================== 组 4：真实 call ====================
do
	-- 查询默认值
	local mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	local res = expect_ok("call 查询 OK", function() return call({ fd = fd }) end)
	check("PM25=42.3 PM10=100.0",
		res and res.PM25 == 42.3 and res.PM10 == 100.0,
		res and string.format("%s/%s", res.PM25, res.PM10))
	local es = entries(mark)
	check("查询事务时序 uf→uw→ur",
		table.concat(dirs_of(es), ",") == "uf,uw,ur", table.concat(dirs_of(es), ","))
	check("uw 查询请求帧逐字节（AA B4 04 00*12 FF FF 02 AB）",
		same_bytes(es[2].bytes, REQ_QUERY), table.concat(es[2].bytes, ","))
	check("应答帧逐字节 = AA C5 A7 01 E8 03 FF FF 91 AB",
		same_bytes(es[3].bytes, RSP_QUERY), table.concat(es[3].bytes, ","))
	check("收发均 ok 且请求 cmd=0x04",
		es[2].ok == true and dev:requests()[dev:request_count()].cmd == 0x04)

	-- 小端字节拆分交叉（非整百值）
	mark = section()
	dev:set_pm25_raw(1):set_pm10_raw(256)
	res = expect_ok("call 边界拆分 OK", function() return call({ fd = fd }) end)
	check("PM25=0.1 PM10=25.6", res.PM25 == 0.1 and res.PM10 == 25.6,
		string.format("%s/%s", res.PM25, res.PM10))
	check("应答 b3 b4 = 01 00、b5 b6 = 00 01",
		same_bytes(last_dir(entries(mark), "ur").bytes,
			{ 0xAA, 0xC5, 0x01, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0x00, 0xAB }))

	-- 满量程（低字节 FF、高字节 FF；PM10 全零）
	mark = section()
	dev:set_pm25_raw(65535):set_pm10_raw(0)
	res = expect_ok("call 满量程 OK", function() return call({ fd = fd }) end)
	check("PM25=6553.5 PM10=0.0", res.PM25 == 6553.5 and res.PM10 == 0,
		string.format("%s/%s", res.PM25, res.PM10))
	check("满量程应答 CS=0xFC", last_dir(entries(mark), "ur").bytes[9] == 0xFC)

	-- 风扇电源控制
	mark = section()
	res = expect_ok("call power sleep OK", function() return call({ fd = fd, power = "sleep" }) end)
	check("POWER=sleep 且不发查询",
		res.POWER == "sleep" and last_dir(entries(mark), "uw").bytes[3] == 0x06
		and last_dir(entries(mark), "uw").bytes[4] == 0)
	check("睡眠后模型 sleeping 置位", dev:sleeping() == true)
	mark = section()
	res = expect_ok("call power work OK", function() return call({ fd = fd, power = "work" }) end)
	check("POWER=work 且 D0=1",
		res.POWER == "work" and last_dir(entries(mark), "uw").bytes[4] == 1
		and last_dir(entries(mark), "ur").bytes[4] == 1)
	check("work 后模型恢复运转", dev:sleeping() == false)
	mark = section()
	expect_err("call 非法 power 报用法", function() return call({ fd = fd, power = " standby " }) end,
		"Invalid Argument: power ' standby ' (sleep|work)")
	check("非法 power 零总线事务", #entries(mark) == 0)

	-- 残留主动流：每条命令应答前垫一帧坏 CS 推送，驱动多轮扫描后仍建立被动模式
	mark = section()
	dev:stale_push(true)
	cap_start()
	res = build({ fd = fd })
	cap_stop()
	dev:stale_push(false)
	es = entries(mark)
	check("残留帧环境 build 仍 OK", res.result == "OK", tostring(res.message))
	check("两命令各多一轮扫描（4 次 ur）",
		table.concat(dirs_of(es), ",") == "uf,uw,ur,ur,uf,uw,ur,ur",
		table.concat(dirs_of(es), ","))
	check("首轮读到残留帧（10 字节、CS 字段填 0）",
		#es[3].bytes == 10 and es[3].bytes[1] == 0xAA and es[3].bytes[9] == 0)
	check("第二轮扫描命中真 ACK = AA C5 02 01 ...",
		same_bytes(es[4].bytes, ACK_PASSIVE), table.concat(es[4].bytes, ","))
	check("版本应答同样前置残留帧", es[7].bytes[9] == 0 and #es[7].bytes == 10)
	check("最终仍解出固件版本", es[8].bytes[3] == 0x07 and banner("firmware=7.0") ~= nil)

	-- virt_tick 波形经真实驱动闭环（5 拍一周，含回卷共 6 次）
	mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	local all_ok = true
	local want25 = { 10.5, 11.3, 12.1, 12.9, 13.7 }
	local want10 = { 16.3, 17.1, 17.9, 18.7, 19.5 }
	for n = 0, 5 do
		dev:virt_tick(n)
		local r = call({ fd = fd })
		local m = n % 5
		if r.result ~= "OK" or r.PM25 ~= want25[m + 1] or r.PM10 ~= want10[m + 1] then
			all_ok = false
			break
		end
	end
	check("tick 6 次驱动闭环 PM 逐拍钉值（含回卷）", all_ok)
	check("6 拍共 18 事务（每拍 uf+uw+ur）", #entries(mark) == 18, tostring(#entries(mark)))
end

-- ==================== 组 5：负路径 ====================
do
	-- 不应答：3 轮读全空 → no valid response (query)
	local mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	dev:no_reply(true)
	expect_err("no_reply → 查询无应答", function() return call({ fd = fd }) end,
		"SDS011 not responding (query: no valid response)")
	local es = entries(mark)
	check("超时路径 uw 成功 + 3 轮空读",
		count_dir(es, "uw") == 1 and count_dir(es, "ur") == 3
		and #last_dir(es, "ur").bytes == 0, table.concat(dirs_of(es), ","))

	-- 坏校验和：帧头命中但 CS 落空（同窗口重复扫描 3 轮）
	mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	dev:corrupt_checksum(true)
	expect_err("坏 CS → 无有效帧", function() return call({ fd = fd }) end,
		"SDS011 not responding (query: no valid response)")
	es = entries(mark)
	check("坏 CS 路径 3 轮读、首帧 10 字节被弃",
		count_dir(es, "ur") == 3 and #es[3].bytes == 10 and es[3].bytes[9] == (0x91 + 1),
		string.format("0x%02X", es[3].bytes[9]))

	-- 链路硬错误：首轮 nil 即短路
	mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	vbus.uart_fail_read = true
	expect_err("fail_read → 无有效帧", function() return call({ fd = fd }) end,
		"SDS011 not responding (query: no valid response)")
	es = entries(mark)
	check("read error 立即短路（1 次 err 事务）",
		count_dir(es, "ur") == 1 and last_dir(es, "ur").err == true)
	vbus.uart_fail_read = false

	-- TX 失败：-1 → write failed，模型不解析请求
	mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	local rc0 = dev:request_count()
	dev:fail_write(true)
	expect_err("fail_write → 写请求失败", function() return call({ fd = fd }) end,
		"SDS011 not responding (query: write failed (-1))")
	es = entries(mark)
	check("写失败留痕 ok=false 且无后续读",
		count_dir(es, "uw") == 1 and last_dir(es, "uw").ok == false
		and count_dir(es, "ur") == 0)
	check("写失败不进请求解析", dev:request_count() == rc0,
		string.format("%d -> %d", rc0, dev:request_count()))

	-- power 路径的错误文案
	mark = section()
	build({ fd = fd })
	mark = #vbus.txlog
	dev:no_reply(true)
	expect_err("no_reply → power 无应答", function() return call({ fd = fd, power = "sleep" }) end,
		"SDS011 not responding (power: no valid response)")

	-- build 期无应答（被动模式建立失败）
	mark = section()
	dev:no_reply(true)
	local rerr = build({ fd = fd })
	check("build no_reply → not responding (set passive mode)",
		rerr.result == "ERR"
		and tostring(rerr.message):find("SDS011 not responding (set passive mode: ", 1, true) ~= nil,
		tostring(rerr.message))

	-- 入参负路径
	expect_err("call 非表 ERR", function() return call("x") end,
		"Invalid Arguments Type: table")
	expect_err("call 缺 fd ERR", function() return call({}) end, "Invalid Argument: fd")
	mark = section()
	local r99 = call({ fd = 99 })
	check("call 未开 fd → write failed",
		r99.result == "ERR" and tostring(r99.message):find("(query: write failed (-1))", 1, true) ~= nil,
		tostring(r99.message))
	check("未开 fd 全链路零事务（flush 也静默）", #entries(mark) == 0)

	-- 恢复性：故障清除后同一 fd 直接可读
	mark = section()
	local rres = expect_ok("负路径后恢复正常读数", function() return call({ fd = fd }) end)
	check("恢复后 PM25=42.3", rres and rres.PM25 == 42.3, rres and tostring(rres.PM25))
end

-- ==================== 组 6：destroy ====================
do
	local mark = section()
	expect_ok("destroy OK", function() return destroy({ fd = fd }) end)
	check("destroy 零总线事务", #entries(mark) == 0)
	expect_err("destroy 非表 ERR", function() return destroy(nil) end,
		"Invalid Arguments Type: table")
end

-- ==================== 组 7:26.3b NaN 配置列拒绝 ====================
do
	local mark = section()
	expect_ok("timeout='nan' 归缺省 300ms（finite_of 返回 nil → 走缺省分支）",
	          function() return build({ fd = fd, timeout = "nan" }) end)
	check("timeout='nan' 使用缺省超时（仍有事务）",
	      #entries(mark) > 0, tostring(#entries(mark)))
end

tester.summary("SDS011")

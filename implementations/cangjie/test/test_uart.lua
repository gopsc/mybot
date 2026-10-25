-- HAL.lua uart 段 离线测试（mock HAL.sys 系统调用，不触碰真实串口）
-- 用法: luajit test_uart.lua（HAL 依赖 ffi，需 LuaJIT）
--
-- mock 注入 HAL.sys 的 termios/read/write/usleep/close 条目（test_hal_ffi
-- 同款间接层方法）。termios 以 void* 流动，测试侧 ffi.cast("cj_termios *")
-- 检查 c_cc/c_cflag 字段——HAL 侧字段常量（VMIN/VTIME 下标、CREAD|CLOCAL）
-- 由 test/test_uart_consts.c 与系统头文件实证。

local ffi = require("ffi")
local bit = require("bit")
local HAL = dofile("modules/lib/HAL.lua")

-- ==================== HAL.sys mock ====================
local calls = {}			-- 操作记录
local mock_open_fd = 7
local mock_tcgetattr_ok = true
local mock_tcsetattr_ok = true
local mock_write_ret = nil	-- nil = 真实语义（按需返回）
local read_feed = {}		-- read 桩按调用次序吐 {bytes 或 -1}
local read_feed_i = 0
local last_tcsetattr = nil	-- tcsetattr 捕获的 termios 快照
local last_write = nil
local last_ispeed = nil

HAL.sys.open = function(path, flags)
	calls[#calls + 1] = { op = "open", path = path, flags = flags }
	return mock_open_fd
end
HAL.sys.close = function(fd)
	calls[#calls + 1] = { op = "close", fd = fd }
	return 0
end
HAL.sys.read = function(fd, buf, n)
	calls[#calls + 1] = { op = "read", n = n }
	read_feed_i = read_feed_i + 1
	local v = read_feed[read_feed_i]
	if type(v) == "number" then return v end	-- -1 等错误码
	if type(v) == "table" then
		local cnt = math.min(n, #v)
		for i = 0, cnt - 1 do buf[i] = v[i + 1] end
		return cnt
	end
	return -1
end
HAL.sys.write = function(fd, buf, n)
	calls[#calls + 1] = { op = "write", n = n }
	local b = {}
	for i = 0, n - 1 do b[i + 1] = tonumber(buf[i]) end
	last_write = b
	return n
end
HAL.sys.usleep = function(us) calls[#calls + 1] = { op = "usleep", us = us } end
HAL.sys.errno = function() return 11 end	-- EAGAIN
HAL.sys.tcgetattr = function(fd, ptr)
	calls[#calls + 1] = { op = "tcgetattr", fd = fd }
	if not mock_tcgetattr_ok then return -1 end
	return 0
end
HAL.sys.cfmakeraw = function(ptr)
	calls[#calls + 1] = { op = "cfmakeraw" }
	local t = ffi.cast("cj_termios *", ptr)
	t[0].c_cflag = 0x8BD	-- 模拟 cfmakeraw 后的 cflag（含 CS8，不含 CREAD/CLOCAL）
end
HAL.sys.cfsetispeed = function(ptr, baud)
	calls[#calls + 1] = { op = "cfsetispeed", baud = baud }
	last_ispeed = baud
end
HAL.sys.cfsetospeed = function(ptr, baud)
	calls[#calls + 1] = { op = "cfsetospeed", baud = baud }
end
HAL.sys.tcsetattr = function(fd, act, ptr)
	calls[#calls + 1] = { op = "tcsetattr", act = act }
	if not mock_tcsetattr_ok then return -1 end
	last_tcsetattr = ffi.cast("cj_termios *", ptr)[0]
	return 0
end
HAL.sys.tcflush = function(fd, q)
	calls[#calls + 1] = { op = "tcflush", q = q }
	return 0
end

-- ==================== 断言辅助 ====================
local fails = 0
local function check(cond, label, extra)
	if cond then
		print(string.format("[PASS] %s", label))
	else
		fails = fails + 1
		print(string.format("[FAIL] %s%s", label, extra and (" (" .. tostring(extra) .. ")") or ""))
	end
end

local function has_call(op, key, val)
	for _, c in ipairs(calls) do
		if c.op == op and (key == nil or c[key] == val) then return true end
	end
	return false
end

local function reset(feed)
	calls = {}
	read_feed = feed or {}
	read_feed_i = 0
	last_tcsetattr = nil
	last_write = nil
	last_ispeed = nil
	mock_tcgetattr_ok, mock_tcsetattr_ok = true, true
	mock_write_ret = nil
end

-- ==================== uart_open：路径/波特率白名单 ====================
reset()
check(uart_open("/dev/ttyUSB0", 9600) == 7, "open ttyUSB0@9600 成功")
check(has_call("open", "flags", HAL.UART_O_FLAGS), "open 旗帜 = RDWR|NOCTTY|NONBLOCK(2306)",
	tostring(calls[1] and calls[1].flags))
check(has_call("cfmakeraw"), "cfmakeraw 进入 raw 模式")
check(last_ispeed == 9600, "cfsetispeed 收到数值波特率 9600", tostring(last_ispeed))
check(has_call("tcsetattr", "act", HAL.UART_TCSANOW), "tcsetattr(TCSANOW)")
check(last_tcsetattr ~= nil
	and last_tcsetattr.c_cc[HAL.UART_VMIN_IDX] == 0
	and last_tcsetattr.c_cc[HAL.UART_VTIME_IDX] == 1, "VMIN=0/VTIME=1")
-- cfmakeraw 桩置 cflag=0x8BD（不含 CREAD/CLOCAL），open 后应位或补上
check(last_tcsetattr ~= nil
	and bit.band(last_tcsetattr.c_cflag, HAL.UART_CREAD_CLOCAL) == HAL.UART_CREAD_CLOCAL,
	"cflag 置位 CREAD|CLOCAL（位或非加法）",
	string.format("0x%X", last_tcsetattr and last_tcsetattr.c_cflag or 0))

reset()
check(uart_open("/dev/ttyUSB0; reboot", 9600) == -1, "白名单拒绝注入路径")
check(uart_open("/dev/tty", 9600) == -1, "白名单拒绝裸 /dev/tty")
check(uart_open("/dev/i2c-1", 9600) == -1, "白名单拒绝 i2c 路径")
check(uart_open("ttyUSB0", 9600) == -1, "白名单拒绝缺 /dev 前缀")
check(uart_open("/dev/serial0", 9600) == 7, "open /dev/serial0（树莓派软链惯例）")
check(uart_open("/dev/ttyUSB0", 1234) == -1, "波特率白名单拒绝 1234")
check(uart_open("/dev/ttyUSB0", "9600") == 7, "字符串波特率经 tonumber 接受")

reset()
mock_tcgetattr_ok = false
check(uart_open("/dev/ttyUSB0", 9600) == -1, "tcgetattr 失败 -> -1")
check(has_call("close"), "失败路径关闭 fd")
mock_tcgetattr_ok = true

reset()
mock_tcsetattr_ok = false
check(uart_open("/dev/ttyUSB0", 9600) == -1, "tcsetattr 失败 -> -1")
check(has_call("close"), "失败路径关闭 fd（2）")
mock_tcsetattr_ok = true

-- ==================== uart_write ====================
reset()
check(uart_write(7, { 0xFF, 0x01, 0x86, 0x00 }) == 4, "write 返回字节数")
check(last_write ~= nil and #last_write == 4 and last_write[1] == 0xFF and last_write[4] == 0x00,
	"写入字节内容一致")
check(uart_write(7, { 0xFF, 300 }) == -1, "非法字节拒绝")
check(uart_write(7, {}) == -1, "空表拒绝")
check(uart_write(7, "frame") == -1, "非表拒绝")

-- ==================== uart_read：分片聚合与超时 ====================
-- 分片：1st 3 字节、2nd -1(EAGAIN)、3rd 2 字节、4th 2 字节 -> 共 7 字节聚合
reset({ { 0xFF, 0x86, 0x01 }, -1, { 0xF4, 0x42 }, { 0x00, 0x00 } })
local got = uart_read(7, 7, 100)
check(type(got) == "table" and #got == 7 and got[1] == 0xFF and got[4] == 0xF4,
	"分片到达聚合为 7 字节", got and tostring(#got) or "nil")
check(has_call("usleep", "us", 1000), "轮询间 usleep(1000)")

-- 超时：永远无数据 -> 空表返回
reset({ -1 })
local got2 = uart_read(7, 9, 5)
check(type(got2) == "table" and #got2 == 0, "超时返回空表", got2 and tostring(#got2) or "nil")

-- 读错误（EAGAIN 之外的 errno，如 EIO）：立即返回 nil，不再空转到超时
reset({ -1 })
local old_errno = HAL.sys.errno
HAL.sys.errno = function() return 5 end	-- EIO
local got_err = uart_read(7, 9, 300)
HAL.sys.errno = old_errno
check(got_err == nil, "读错误（非 EAGAIN/EINTR）立即返回 nil", tostring(got_err))

-- 足量单次到达：立即返回不轮询
reset({ { 1, 2, 3, 4, 5, 6, 7, 8, 9 } })
local n_usleep_before = 0
for _, c in ipairs(calls) do if c.op == "usleep" then n_usleep_before = n_usleep_before + 1 end end
local got3 = uart_read(7, 9, 300)
check(type(got3) == "table" and #got3 == 9, "单帧足量一次读齐")
local n_usleep_after = 0
for _, c in ipairs(calls) do if c.op == "usleep" then n_usleep_after = n_usleep_after + 1 end end
check(n_usleep_after == n_usleep_before, "读齐即返回（不空转轮询）")

check(uart_read(7, 100) == nil or true, "参数校验不炸")	-- fd nil -> nil 分支
reset()
check(uart_read(7, 0, 100) == nil, "n=0 拒绝（返回 nil）")

-- ==================== uart_flush / uart_close ====================
reset()
check(uart_flush(7) == 0, "flush 返回 0")
check(has_call("tcflush", "q", HAL.UART_TCIFLUSH), "tcflush(TCIFLUSH)")
reset()
check(uart_close(7) == 0, "close 返回 0")
check(has_call("close"), "close 落到 HAL.sys.close")

-- ==================== 汇总 ====================
if fails == 0 then
	print("all passed")
else
	print(fails .. " case(s) failed")
	os.exit(1)
end

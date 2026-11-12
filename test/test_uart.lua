-- HAL 的 uart 段（modules/lib/hal/uart.lua，经 HAL.lua 聚合加载）离线测试
-- （mock HAL.sys 系统调用，不触碰真实串口）
-- 覆盖：open 路径/波特率白名单、raw 8N1 配置、read/write/flush、
-- close 恢复 open 前 termios（销毁重置）及恢复失败/无快照等分支
-- 用法: luajit test_uart.lua（HAL 依赖 ffi，需 LuaJIT）
--
-- mock 注入 HAL.sys 的 termios/read/write/usleep/close 条目（test_hal_ffi
-- 同款间接层方法）。termios 以 void* 流动，测试侧 ffi.cast("cj_termios *")
-- 检查 c_cc/c_cflag 字段——HAL 侧字段常量（VMIN/VTIME 下标、CREAD|CLOCAL）
-- 由 test/test_uart_consts.c 与系统头文件实证。

local ffi = require("ffi")
local bit = require("bit")
local HAL = dofile("modules/lib/HAL.lua")

-- 波特率期望编码随 glibc 版本分叉（glibc 2.42 起 B* 即字面 Hz，见 hal/uart.lua
-- 段首注释与 test_uart_baud.lua）：此处独立推导期望值，避免与 HAL 的
-- 探测逻辑同义反复。旧版 B9600=13，2.42+ B9600=9600（余档同形）。
-- 非 glibc（musl）没有该符号：取符号那步用 pcall 包住，按旧编号表处理
-- （musl 的 B* 就是 Linux ABI 旧编号，test_uart_consts 在 alpine 下已实证）。
pcall(ffi.cdef, [[ const char* gnu_get_libc_version(void); ]])
local ok_v, vstr_p = pcall(function() return ffi.C.gnu_get_libc_version() end)
local v_major, v_minor = string.match((ok_v and vstr_p ~= nil) and ffi.string(vstr_p) or "", "(%d+)%.(%d+)")
local glibc_hz_baud = v_major ~= nil
	and (tonumber(v_major) * 1000 + tonumber(v_minor)) >= 2042
-- 旧 ABI 编码表（glibc < 2.42；与 hal/uart.lua 的 UART_B_CONST_LEGACY 同源）
local LEGACY_BCONST = {
	[1200] = 9, [2400] = 11, [4800] = 12, [9600] = 13, [19200] = 14, [38400] = 15,
	[57600] = 0x1001, [115200] = 0x1002, [230400] = 0x1003, [460800] = 0x1004,
	[500000] = 0x1005, [921600] = 0x1007, [1000000] = 0x1008,
}
local function expect_bconst(hz) return glibc_hz_baud and hz or LEGACY_BCONST[hz] end

-- ==================== HAL.sys mock ====================
local calls = {}			-- 操作记录
local mock_open_fd = 7
local mock_tcgetattr_ok = true
local mock_tcsetattr_ok = true
local mock_cfspeed_ok = true	-- false = cfsetispeed/cfsetospeed 返回 -1
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
	-- 模拟 open 前设备侧的常规（非 raw）配置：close 恢复断言据此比对
	local t = ffi.cast("cj_termios *", ptr)
	t[0].c_cflag = 0x1234
	t[0].c_cc[HAL.UART_VMIN_IDX] = 4
	return 0
end
HAL.sys.cfmakeraw = function(ptr)
	calls[#calls + 1] = { op = "cfmakeraw" }
	local t = ffi.cast("cj_termios *", ptr)
	t[0].c_cflag = 0x8BD	-- 模拟 cfmakeraw 后的 cflag（含 CS8，不含 CREAD/CLOCAL）
end
-- cfset*speed 收到的是 glibc 常量而非 Hz（见 HAL 段首注释）；返回 0 表成功
HAL.sys.cfsetispeed = function(ptr, baud)
	calls[#calls + 1] = { op = "cfsetispeed", baud = baud }
	if mock_cfspeed_ok == false then return -1 end
	last_ispeed = baud
	return 0
end
HAL.sys.cfsetospeed = function(ptr, baud)
	calls[#calls + 1] = { op = "cfsetospeed", baud = baud }
	if mock_cfspeed_ok == false then return -1 end
	return 0
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
-- F4/N-33：断言收敛到 test/lib/tester.lua。本文件调用点是 check(cond, label, extra)
-- 的「条件在前」序，逐个改序收益为零，故保留一个薄委托（断言实现单点在 tester）。
local tester = dofile("test/lib/tester.lua")
local check = function(cond, label, extra) tester.check(label, cond, extra) end

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
	mock_cfspeed_ok = true
	mock_write_ret = nil
end

-- ==================== uart_open：路径/波特率白名单 ====================
reset()
check(uart_open("/dev/ttyUSB0", 9600) == 7, "open ttyUSB0@9600 成功")
check(has_call("open", "flags", HAL.UART_O_FLAGS),
	"open 旗帜 = RDWR|NOCTTY|NONBLOCK|CLOEXEC(526594)",
	tostring(calls[1] and calls[1].flags))
check(has_call("cfmakeraw"), "cfmakeraw 进入 raw 模式")
check(last_ispeed == expect_bconst(9600), "cfsetispeed 收到当版 glibc 编码 B9600（非错编码）",
	tostring(last_ispeed))
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

-- 高波特率档：常数映射（SCSCL 总线舵机出厂默认 500k/1M）
check(uart_open("/dev/ttyUSB0", 115200) == 7, "115200 白名单接受")
check(last_ispeed == expect_bconst(115200), "115200 -> 当版 glibc B115200 编码", string.format("0x%X", last_ispeed or 0))
check(uart_open("/dev/ttyUSB0", 500000) == 7, "500000 白名单接受")
check(last_ispeed == expect_bconst(500000), "500000 -> 当版 glibc B500000 编码", string.format("0x%X", last_ispeed or 0))
check(uart_open("/dev/ttyUSB0", 1000000) == 7, "1000000 白名单接受")
check(last_ispeed == expect_bconst(1000000), "1000000 -> 当版 glibc B1000000 编码", string.format("0x%X", last_ispeed or 0))
check(uart_open("/dev/ttyUSB0", 576000) == -1, "波特率白名单拒绝 576000（未列入）")

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

reset()
mock_cfspeed_ok = false
check(uart_open("/dev/ttyUSB0", 9600) == -1, "cfsetispeed 失败 -> -1（返回码被检查）")
check(has_call("close"), "失败路径关闭 fd（3）")
mock_cfspeed_ok = true

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

-- 超时上限：超过 UART_READ_MAX_MS 显式返回 nil，不得与参数线性空转
reset({ -1 })
check(uart_read(7, 4, HAL.UART_READ_MAX_MS + 1) == nil,
	"超时超上限（60001ms）显式返回 nil")
check(not has_call("read"), "超上限不发 read 系统调用（配置错误立即暴露）")
reset({ { 1, 2 } })
local got_cap = uart_read(7, 2, HAL.UART_READ_MAX_MS)
check(type(got_cap) == "table" and #got_cap == 2, "上限值 60000ms 本身放行")

-- 主评估 B：非有限超时（NaN/±inf，含字符串形态）在真机路径显式拒绝返回 nil
reset()
check(uart_read(7, 2, 0 / 0) == nil, "NaN 超时返回 nil")
check(uart_read(7, 2, math.huge) == nil, "+inf 超时返回 nil")
check(uart_read(7, 2, -math.huge) == nil, "-inf 超时返回 nil")
check(uart_read(7, 2, "nan") == nil, "字符串 'nan' 超时返回 nil")
check(uart_read(7, 2, "1e400") == nil, "字符串 '1e400'（溢出为 inf）超时返回 nil")

-- ==================== uart_flush ====================
reset()
check(uart_flush(7) == 0, "flush 返回 0")
check(has_call("tcflush", "q", HAL.UART_TCIFLUSH), "tcflush(TCIFLUSH)")

-- ==================== uart_close：销毁时恢复原始 termios ====================
-- open 建立快照（mock tcgetattr 以 cflag=0x1234/VMIN=4 模拟设备原始配置）
reset()
check(uart_open("/dev/ttyUSB0", 9600) == 7, "open 建立恢复快照")
reset()
check(uart_close(7) == 0, "close 返回 0")
check(has_call("tcsetattr", "act", HAL.UART_TCSANOW), "close 前 tcsetattr(TCSANOW) 恢复")
check(last_tcsetattr ~= nil and last_tcsetattr.c_cflag == 0x1234
	and last_tcsetattr.c_cc[HAL.UART_VMIN_IDX] == 4,
	"恢复的是 open 前原始 termios（cflag/VMIN）",
	last_tcsetattr and string.format("0x%X", last_tcsetattr.c_cflag) or "nil")
check(has_call("close"), "close 落到 HAL.sys.close")

-- 快照一次性：恢复并清除后，重复 close 不再 tcsetattr
reset()
check(uart_close(7) == 0, "重复 close 仍返回 0")
check(not has_call("tcsetattr"), "无快照不再 tcsetattr")
check(has_call("close"), "重复 close 仍落到 HAL.sys.close")

-- 未打开过的 fd：无快照直接关闭，不试图恢复
check(uart_close(99) == 0, "未打开 fd 直接 close")
check(not has_call("tcsetattr"), "未打开 fd 不 tcsetattr")

-- 恢复失败（设备已拔出等）：告警但关闭不被阻断，返回值仍是 close 的结果
reset()
check(uart_open("/dev/ttyUSB0", 9600) == 7, "open 重建快照（恢复失败路径）")
reset()
mock_tcsetattr_ok = false
check(uart_close(7) == 0, "恢复失败仍返回 close 结果")
check(has_call("tcsetattr"), "恢复失败已尝试 tcsetattr")
check(has_call("close"), "恢复失败仍关闭 fd")
mock_tcsetattr_ok = true

-- open 配置失败路径不登记快照：此后 close 不产生恢复调用
reset()
mock_tcsetattr_ok = false
check(uart_open("/dev/ttyUSB0", 9600) == -1, "open tcsetattr 失败 -> -1（不登记快照）")
mock_tcsetattr_ok = true
reset()
check(uart_close(7) == 0, "配置失败的 fd close 返回 0")
check(not has_call("tcsetattr"), "失败路径不产生残留快照")

-- ==================== virtbus uart_read 超时对偶（主评估 B） ====================
-- 旧 virtbus 实现：`local timeout = tonumber(timeout_ms) or 0` 之后
-- `if timeout > bus.UART_READ_MAX_MS then return nil end` —— NaN 与任何数比较
-- 均为 false，NaN **穿过**上限检查被放行、返回空表；而真机 HAL 显式返回 nil
-- （上一节已钉死同一组入参）→「仿真绿真机红」。修复改走 bus.finite_of。
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()
vbus.inject()
local vfd = uart_open("/dev/ttyUSB0", 9600)
check(vfd ~= nil and vfd >= 0, "virtbus：uart_open 成功")
check(uart_read(vfd, 2, 0 / 0) == nil, "virtbus：NaN 超时返回 nil（旧实现放行返回空表）")
check(uart_read(vfd, 2, math.huge) == nil, "virtbus：+inf 超时返回 nil")
check(uart_read(vfd, 2, -math.huge) == nil, "virtbus：-inf 超时返回 nil")
check(uart_read(vfd, 2, "nan") == nil, "virtbus：字符串 'nan' 超时返回 nil")
check(type(uart_read(vfd, 2, 10)) == "table", "virtbus：合法超时仍返回表（放行集不变）")
check(type(uart_read(vfd, 2)) == "table", "virtbus：缺省超时仍返回表（nil→0 语义不变）")
vbus.reset()

-- ==================== 汇总 ====================
tester.summary("test_uart.lua")

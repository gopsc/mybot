-- test_hal_quiesce_host.lua —— 宿主 HAL（__hal_call）路径的停机灭火检查
--
-- 与 test_hal_quiesce.lua 的分工：那份测 HAL_ffi 回退路径；本文件用 mock
-- __hal_call 强制加载 modules/lib/HAL.lua 的 portable/host 分支，验证
-- i2c/spi/uart 的真实传输入口也会在进宿主 HAL 前检查守护槽 quiesce 位。
-- 不触碰真实硬件；从仓库根目录运行：luajit test/test_hal_quiesce_host.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check
local ffi = require("ffi")

local calls = 0
_G.__hal_call = function(op, ...)
	if op == "last_error" then return "" end
	if op == "i2c_open" then return 7 end
	if op == "spi_open" then return 8 end
	if op == "uart_open" then return 9 end
	if op == "close_handle" then return 0 end
	if op == "spi_setup" then return 0 end
	if op == "i2c_transfer" then
		local _, _, _, n = ...
		calls = calls + 1
		local out = {}
		for i = 1, n do out[i] = 0 end
		return out
	end
	if op == "spi_transfer" then
		local _, data = ...
		calls = calls + 1
		local out = {}
		for i = 1, #data do out[i] = 0 end
		return out
	end
	if op == "uart_write" then
		local _, data = ...
		calls = calls + 1
		return #data
	end
	if op == "uart_read" then calls = calls + 1; return {} end
	if op == "uart_flush" then calls = calls + 1; return 0 end
	error("unexpected bridge op " .. tostring(op))
end

local HAL = dofile("modules/lib/HAL.lua")
check("宿主分支加载成功", HAL.backend == "host", tostring(HAL.backend))

local fd = i2c_open("/dev/i2c-1")
check("i2c_open 可打开", fd == 7)
i2c_set_addr(fd, 0x68)

local n0 = calls
check("无槽注入：i2c_write_reg 放行", i2c_write_reg(fd, 0x00, 0x01) == true)
check("无槽注入：确实进了一次宿主传输", calls == n0 + 1)

-- 与 daemonvar.hpp / pthread.lua 的 ABI v2 布局一致；零初始化 mutex 在
-- glibc 上等价静态初始化（与 test_hal_quiesce.lua 同规）。
local layout = { count = 64, nvals = 68, values = 72, capacity = 80,
	stop = 84, status = 88, quiesce = 92, size = 96, maxvals = 64 }
local slot = ffi.new("char[96]")
_G.DAEMON_SLOT_ADDR = ffi.cast("void *", slot)
_G.DAEMON_SLOT_LAYOUT = layout
dofile("modules/lib/pthread.lua")

local function setq(v)
	local m = ffi.cast("cj_pthread_mutex_t *", slot)
	assert(ffi.C.pthread_mutex_lock(m) == 0)
	ffi.cast("int32_t *", slot + 92)[0] = v
	ffi.C.pthread_mutex_unlock(m)
end

setq(0)
check("quiesce=0：i2c_write_reg 放行", i2c_write_reg(fd, 0x00, 0x01) == true)

setq(1)
local before = calls
check("quiesce=1：i2c_write_reg 拒绝", i2c_write_reg(fd, 0x00, 0x01) == false)
check("quiesce=1：i2c_read_reg 拒绝", i2c_read_reg(fd, 0x00) == -1)
check("quiesce=1：spi_write 拒绝", spi_write(8, 0xAA) == -1)
check("quiesce=1：uart_write 拒绝", uart_write(9, { 0x01 }) == -1)
check("quiesce=1：uart_read 拒绝", uart_read(9, 2, 0) == nil)
check("quiesce=1：零宿主传输调用", calls == before)

check("quiesce=1：i2c_open 仍放行", i2c_open("/dev/i2c-1") == 7)
local close_ok = pcall(function() i2c_close(fd) end)
check("quiesce=1：i2c_close 仍放行", close_ok)

tester.summary("宿主 HAL 停机灭火检查")

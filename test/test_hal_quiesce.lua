-- test_hal_quiesce.lua —— HAL 停机灭火检查（BQ-1，与 src/daemonvar.hpp 的 quiesce 位配对）
-- 离线单测：mock HAL.sys.* 系统调用层，自造共享槽（ffi 零初始化内存在 glibc 上
-- 即 PTHREAD_MUTEX_INITIALIZER），验证 quiesce 置位后 i2c/spi/uart 传输在进内核前
-- 被拒绝、未置位/无槽注入时照常放行。不触碰真实硬件。
-- 用法（项目根目录）: luajit test/test_hal_quiesce.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local ffi = require("ffi")
local HAL = dofile("modules/lib/HAL.lua")
-- cj_pthread_mutex_t 已由 hal_backend_glibc.lua 声明（与 pthread.lua 逐字一致），
-- 直接复用不再重复 cdef：LuaJIT 对同名重声明以首次为准

------------------------------------------------------------------
-- mock 系统调用层（只记 ioctl_p/read/write 调用次数，恒成功）
------------------------------------------------------------------
local syscalls = 0
local mock_ioctl_ret = 0
local mock_rw_ret = 8
HAL.sys.open = function(path, flags) return 7 end
HAL.sys.close = function(fd) return 0 end
HAL.sys.ioctl_i = function(fd, req, val) return mock_ioctl_ret end
HAL.sys.ioctl_p = function(fd, req, ptr)
	syscalls = syscalls + 1
	return mock_ioctl_ret
end
HAL.sys.read = function(fd, buf, n)
	syscalls = syscalls + 1
	return mock_rw_ret
end
HAL.sys.write = function(fd, buf, n)
	syscalls = syscalls + 1
	return n
end
HAL.sys.errno = function() return 0 end

-- 2026-09-30 方案 A 重构：新增总线传输原语 mock
HAL.sys.i2c_rdwr = function(fd, msgs, nmsgs)
	syscalls = syscalls + 1
	return mock_ioctl_ret
end
HAL.sys.spi_setup = function(fd, mode, bits, speed)
	syscalls = syscalls + 1
	return 0
end
HAL.sys.spi_xfer = function(fd, tx, rx, len, delay_us)
	syscalls = syscalls + 1
	return mock_ioctl_ret
end

-- 与宿主 injectDaemonGlobals 注入的布局同形（daemonvar.hpp：quiesce@592）
local slot = ffi.new("char[600]")
local layout = { count = 64, nvals = 68, values = 72, stop = 584,
	status = 588, quiesce = 592, size = 600, maxvals = 64 }
local function quiesce_ptr()
	return ffi.cast("int32_t *", slot + layout.quiesce)
end
local function set_quiesce(v)
	-- 持锁写（与 C++ 侧 daemon_quiesce 同纪律；测试单线程，锁必成）
	local m = ffi.cast("cj_pthread_mutex_t *", slot)
	assert(ffi.C.pthread_mutex_lock(m) == 0)
	quiesce_ptr()[0] = v
	ffi.C.pthread_mutex_unlock(m)
end

local fd = 7
i2c_set_addr(fd, 0x68)

------------------------------------------------------------------
-- ① 无槽注入（主线程形态）：传输照常
------------------------------------------------------------------
local n0 = syscalls
check("无 DAEMON_SLOT_ADDR：i2c_write_reg 放行", i2c_write_reg(fd, 0x00, 0x01) == true)
check("无 DAEMON_SLOT_ADDR：确实进了一次内核调用", syscalls == n0 + 1)

------------------------------------------------------------------
-- ② 槽注入 + quiesce=0（正常守护形态）：照常放行
------------------------------------------------------------------
_G.DAEMON_SLOT_ADDR = ffi.cast("void *", slot)
_G.DAEMON_SLOT_LAYOUT = layout
set_quiesce(0)
check("quiesce=0：i2c_read_reg 放行", i2c_read_reg(fd, 0x00) == 0)
check("quiesce=0：uart_write 放行", uart_write(fd, { 0x01, 0x02 }) == 2)
check("quiesce=0：spi_write 放行", spi_write(fd, 0xAA) == 0)

------------------------------------------------------------------
-- ③ quiesce=1（灭火）：三族传输一律拒绝、零内核调用
------------------------------------------------------------------
set_quiesce(1)
local before = syscalls
check("quiesce=1：i2c_write_reg 拒绝", i2c_write_reg(fd, 0x00, 0x01) == false)
check("quiesce=1：i2c_read_reg 拒绝", i2c_read_reg(fd, 0x00) == -1)
check("quiesce=1：i2c_read_multi 拒绝（-1）", i2c_read_multi(fd, 0x00, 2) == -1)
check("quiesce=1：spi_write 拒绝（-1）", spi_write(fd, 0xAA) == -1)
check("quiesce=1：uart_write 拒绝", uart_write(fd, { 0x01 }) == -1)
check("quiesce=1：uart_read 拒绝（nil）", uart_read(fd, 4, 0) == nil)
check("quiesce=1：零内核调用（拒绝发生在进内核前）", syscalls == before)

------------------------------------------------------------------
-- ④ open/close 不受灭火约束（守护退出路径要能关 fd，泄漏比拒绝更糟）
------------------------------------------------------------------
local ofd = i2c_open("/dev/i2c-1")
check("quiesce=1：i2c_open 仍放行（fd 语义）", ofd == 7)
i2c_close(ofd)
check("quiesce=1：i2c_close 仍放行", true)

------------------------------------------------------------------
-- ⑤ 布局缺 quiesce 键（旧宿主注入形态）：检查退化为恒放行，不报错
------------------------------------------------------------------
_G.DAEMON_SLOT_LAYOUT = { count = 64, nvals = 68, values = 72, stop = 584,
	status = 588, size = 592, maxvals = 64 }
i2c_set_addr(fd, 0x68)	-- ④ 的 close 已清掉 fd 的地址登记，重新挂上
check("旧布局（无 quiesce 键）：i2c_write_reg 放行", i2c_write_reg(fd, 0x00, 0x01) == true)

tester.summary("HAL 停机灭火检查")

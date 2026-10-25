-- test_drv_guard.lua — 驱动 build 守卫（guard_build fd 回滚）与 UART path 缓存回归
-- 覆盖：
--   1) build 中途抛 Lua error → 折成 {result="ERR", message="build() raised: ..."}
--      契约，回滚关闭已打开的总线 fd（SPI 桩实证），call 拒绝半配置句柄
--   2) 正常 build 不受守卫影响（不触发回滚、fd 照常下发）
--   3) UART call 下发 build 时缓存的 path（C-L6：不信任 call 元数据）

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

-- ==================== SPI：build 抛错 → fd 回滚 + ERR 契约 ====================
dofile("modules/SPI.lua")

-- 桩：open 成功、setup 抛错、close 记账（驱动以全局名调用，桩在 dofile 后生效）
local closed = {}
spi_open = function(path) return 7 end
spi_setup = function() error("boom: setup exploded", 0) end
spi_close = function(f) closed[#closed + 1] = f end

expect_err("SPI build 抛错折成 ERR 契约",
	function() return build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8,
		speed = 1000000, delay = 0 }) end,
	"build() raised: boom")

check("回滚已关闭打开的 fd", closed[1] == 7, tostring(closed[1]))
expect_err("回滚后 call 拒绝下发半配置句柄", function() return call({}) end, "not opened")

-- 正常路径不受守卫影响
spi_setup = function() return 0 end
closed = {}
local okr = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8,
	speed = 1000000, delay = 0 })
check("正常 build 不受守卫影响", type(okr) == "table" and okr.result == "OK" and okr.fd == 7,
	tostring(okr and okr.message))
check("正常路径不触发回滚", #closed == 0, tostring(#closed))

-- ==================== UART：call 返回 build 缓存的 path（C-L6）====================
dofile("modules/UART.lua")
uart_open = function(path, baud) return 9 end
uart_close = function(f) end

expect_ok("UART build OK",
	function() return build({ path = "/dev/ttyAMA0", baud = 115200 }) end)
local uc = call({ path = "/dev/WRONG" })
check("UART call 下发 build 时缓存的 path", uc.path == "/dev/ttyAMA0", tostring(uc.path))
check("UART call fd/baud 照常下发", uc.fd == 9 and uc.baud == 115200,
	tostring(uc.fd) .. "/" .. tostring(uc.baud))

tester.summary("drv_guard")

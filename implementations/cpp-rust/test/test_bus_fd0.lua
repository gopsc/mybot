-- 总线驱动 fd 0 契约测试（无硬件：桩替换 HAL 的 open/close，不触碰任何真机总线）
--
-- HAL 约定 open 成功返回 fd >= 0、失败返回 -1（见 modules/lib/hal/i2c.lua 的 i2c_open 注释），
-- GPIO.lua 也按 >= 0 / < 0 判定。但 I2C/SPI/UART 曾按 fd > 0 / fd <= 0 判定，
-- 把合法句柄 0 当成打开失败。
--
-- fd 0 不是理论值：内核把最小可用描述符分配给 open，stdin 被关闭时
-- （systemd StandardInput=null、--input 模式配合 0<&-）真实返回 0。本机实测：
--   DEV=/dev/i2c-1 luajit -e '...open(DEV,0)...' 0<&-   -->  fd=0
--
-- 当时的后果以 UART 最严重：build 按 < 0 判失败故接受 fd 0 并报 OK，
-- 而 call 按 <= 0 判有效性 → 永久返回 "UART not opened (build first)"，
-- destroy 按 > 0 判是否关闭 → 句柄泄漏。即 build 成功而器件永远不可用。
--
-- 用法（项目根目录）: luajit test/test_bus_fd0.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- 各驱动把 build/call/destroy 定义为全局，fd 是各自的 local upvalue，
-- 故逐个 dofile 后立即验证；桩在每次 dofile 之后重装（驱动按全局名动态解析）。
local closed

local function reset_stub()
	closed = {}
end

------------------------------------------------------------
-- I2C
------------------------------------------------------------
dofile("modules/I2C.lua")
reset_stub()
i2c_open = function(_) return 0 end
i2c_close = function(f) closed[#closed + 1] = f; return 0 end

local r = build({ path = "/dev/i2c-1" })
check("I2C build 接受 fd 0", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or tostring(type(r)))
check("I2C build 回传 fd 0", type(r) == "table" and r.fd == 0,
	type(r) == "table" and tostring(r.fd) or nil)

r = call({})
check("I2C call 接受 fd 0", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or nil)
check("I2C call 下发 fd 0 给引用方", type(r) == "table" and r.fd == 0,
	type(r) == "table" and tostring(r.fd) or nil)

r = destroy({})
check("I2C destroy 返回 OK", type(r) == "table" and r.result == "OK")
check("I2C destroy 关闭了 fd 0", closed[1] == 0, tostring(closed[1]))

-- 负路径不得被削弱：open 失败(-1) 仍须清晰报错
i2c_open = function(_) return -1 end
r = build({ path = "/dev/i2c-1" })
check("I2C build 仍拒绝 open 失败(-1)", type(r) == "table" and r.result == "ERR",
	type(r) == "table" and tostring(r.result) or nil)

------------------------------------------------------------
-- SPI
------------------------------------------------------------
dofile("modules/SPI.lua")
reset_stub()
spi_open = function(_) return 0 end
spi_close = function(f) closed[#closed + 1] = f; return 0 end
spi_setup = function(_) return 0 end

r = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
check("SPI build 接受 fd 0", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or tostring(type(r)))

r = call({ path = "/dev/spidev0.0" })
check("SPI call 接受 fd 0", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or nil)
check("SPI call 下发 fd 0 给引用方", type(r) == "table" and r.fd == 0,
	type(r) == "table" and tostring(r.fd) or nil)

r = destroy({ path = "/dev/spidev0.0" })
check("SPI destroy 关闭了 fd 0", closed[1] == 0, tostring(closed[1]))

spi_open = function(_) return -1 end
r = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
check("SPI build 仍拒绝 open 失败(-1)", type(r) == "table" and r.result == "ERR",
	type(r) == "table" and tostring(r.result) or nil)

------------------------------------------------------------
-- UART（原缺陷最严重：build 与 call/destroy 判定标准互相矛盾）
------------------------------------------------------------
dofile("modules/UART.lua")
reset_stub()
uart_open = function(_, _) return 0 end
uart_close = function(f) closed[#closed + 1] = f; return 0 end
uart_flush = function(_) return 0 end

r = build({ path = "/dev/ttyUSB0", baud = 9600 })
check("UART build 接受 fd 0", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or tostring(type(r)))

r = call({})
check("UART call 接受 fd 0（曾永久报 not opened）", type(r) == "table" and r.result == "OK",
	type(r) == "table" and tostring(r.message) or nil)
check("UART call 下发 fd 0 给设备驱动", type(r) == "table" and r.fd == 0,
	type(r) == "table" and tostring(r.fd) or nil)
check("UART call 随 fd 回传 baud", type(r) == "table" and r.baud == 9600,
	type(r) == "table" and tostring(r.baud) or nil)

r = destroy({})
check("UART destroy 关闭了 fd 0（曾泄漏）", closed[1] == 0, tostring(closed[1]))

uart_open = function(_, _) return -1 end
r = build({ path = "/dev/ttyUSB0", baud = 9600 })
check("UART build 仍拒绝 open 失败(-1)", type(r) == "table" and r.result == "ERR",
	type(r) == "table" and tostring(r.result) or nil)

tester.summary()

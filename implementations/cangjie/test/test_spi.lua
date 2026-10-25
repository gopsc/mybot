-- SPI.lua 离线测试（桩替身，不触碰真实 SPI 硬件）
-- 用法: luajit test/test_spi.lua（SPI 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile HAL（连带加载 ffi），再替换 HAL.sys.* 系统调用层；
-- SPI.lua dofile 时复用已缓存的 __BOT4CJ_HAL（含 mock），全局 spi_open 等由 SPI.lua 定义。
-- 覆盖：build 参数校验、call 前置检查、destroy 关闭、正常流程。

local tester = dofile("test/lib/tester.lua")
local ffi = require("ffi")

-- ==================== 加载驱动（触发 HAL + SPI 全局定义）====================
-- 设置模块路径确保 mpath 能找到 lib/ 下的依赖
local HAL = dofile("modules/lib/HAL.lua")
dofile("modules/lib/print_table.lua")
dofile("modules/SPI.lua")

-- ==================== mock 系统调用层 ====================
local calls = {}
local mock_open_fd = 7
local mock_ioctl_ret = 0
local mock_setup_ret = 0	-- spi_setup 返回值

HAL.sys.open = function(path, flags)
	calls[#calls + 1] = { op = "open", path = path, flags = flags }
	return mock_open_fd
end
HAL.sys.close = function(fd)
	calls[#calls + 1] = { op = "close", fd = fd }
	return 0
end
HAL.sys.ioctl_p = function(fd, req, ptr)
	local rec = { op = "ioctl_p", fd = fd, req = req }
	-- 记录 spi_setup 的参数
	if req == HAL.SPI_IOC_WR_MODE then
		rec.u8 = tonumber(ffi.cast("uint8_t *", ptr)[0])
	elseif req == HAL.SPI_IOC_WR_BITS_PER_WORD then
		rec.u8 = tonumber(ffi.cast("uint8_t *", ptr)[0])
	elseif req == HAL.SPI_IOC_WR_MAX_SPEED_HZ then
		rec.u32 = tonumber(ffi.cast("uint32_t *", ptr)[0])
	elseif req == HAL.SPI_IOC_MESSAGE_1 then
		rec.len = tonumber(ptr[0].len)
		if ptr[0].tx_buf ~= 0 then
			rec.tx = ffi.string(ffi.cast("const char *",
				ffi.cast("const void *", ptr[0].tx_buf)), rec.len)
		end
		if ptr[0].rx_buf ~= 0 then
			local rxb = ffi.cast("uint8_t *", ffi.cast("void *", ptr[0].rx_buf))
			rec.rx_filled = true
		end
	end
	calls[#calls + 1] = rec
	return mock_ioctl_ret
end
HAL.sys.ioctl_i = function(fd, req, val)
	calls[#calls + 1] = { op = "ioctl_i", fd = fd, req = req, val = val }
	return mock_ioctl_ret
end

local function reset()
	calls = {}
	mock_ioctl_ret = 0
	mock_setup_ret = 0
end

-- ==================== build 测试 ====================
local res

-- 1. path 缺失
reset()
res = build({ spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
tester.check("build 缺 path 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 2. spi_mode 缺失
reset()
res = build({ path = "/dev/spidev0.0", bits = 8, speed = 1000000, delay = 0 })
tester.check("build 缺 spi_mode 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 3. spi_mode 越界 (>3)
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 4, bits = 8, speed = 1000000, delay = 0 })
tester.check("build spi_mode=4 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 4. bits 缺失
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, speed = 1000000, delay = 0 })
tester.check("build 缺 bits 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 5. bits < 7
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 6, speed = 1000000, delay = 0 })
tester.check("build bits=6 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 6. bits > 16
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 17, speed = 1000000, delay = 0 })
tester.check("build bits=17 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 7. speed 缺失
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, delay = 0 })
tester.check("build 缺 speed 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 8. speed <= 0
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 0, delay = 0 })
tester.check("build speed=0 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 9. speed 负值
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = -1000, delay = 0 })
tester.check("build speed=-1000 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 10. delay 缺失（SPI.lua 要求 delay 参数）
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000 })
tester.check("build 缺 delay 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 11. delay 负值
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000, delay = -1 })
tester.check("build delay=-1 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 12. 正常 build：参数正确
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 1, bits = 8, speed = 1920000, delay = 100 })
tester.check("build 正常参数返回 OK", tostring(res.result) == "OK")
tester.check("build 返回 fd", res.fd ~= nil and res.fd >= 0)
tester.check("build 打开 /dev/spidev0.0", calls[1].op == "open" and calls[1].path == "/dev/spidev0.0")
-- spi_setup 应发出 MODE/BITS/SPEED 三个 ioctl
local setup_reqs = {}
for _, c in ipairs(calls) do
	if c.op == "ioctl_p" and c.req ~= HAL.SPI_IOC_MESSAGE_1 then
		setup_reqs[#setup_reqs + 1] = c.req
	end
end
tester.check("build 发出 3 个 spi_setup ioctl", #setup_reqs == 3)

-- 13. 正常 build：mode=0, bits=16, speed=500000
reset()
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 16, speed = 500000, delay = 0 })
tester.check("build mode=0 bits=16 speed=500000 返回 OK", tostring(res.result) == "OK")

-- ==================== call 测试 ====================
-- call 需要先 build 成功（fd > 0）

-- 14. build 后 call 正常
reset()
build({ path = "/dev/spidev0.0", spi_mode = 1, bits = 8, speed = 1000000, delay = 50 })
res = call({ path = "/dev/spidev0.0" })
tester.check("call 返回 OK", tostring(res.result) == "OK")
tester.check("call 返回 fd", res.fd ~= nil and res.fd >= 0)
tester.check("call 返回 delay", res.delay == 50)

-- 15. 未 build 直接 call（fd 未初始化）
-- SPI.lua 的 fd 是 local，重新 dofile 可重置
dofile("modules/SPI.lua")
res = call({ path = "/dev/spidev0.0" })
tester.check("未 build call 返回 ERR", tostring(res.result) == "ERR", res.message)

-- ==================== destroy 测试 ====================
-- 16. 正常 destroy
reset()
build({ path = "/dev/spidev0.0", spi_mode = 1, bits = 8, speed = 1000000, delay = 0 })
res = destroy({ path = "/dev/spidev0.0" })
tester.check("destroy 返回 OK", tostring(res.result) == "OK")
-- 检查 close 被调用
local close_called = false
for _, c in ipairs(calls) do
	if c.op == "close" then close_called = true; break end
end
tester.check("destroy 调用 spi_close", close_called)

-- 17. destroy 后 call 应失败
res = call({ path = "/dev/spidev0.0" })
tester.check("destroy 后 call 返回 ERR", tostring(res.result) == "ERR", res.message)

-- 18. destroy 缺参数（arg_table 校验）
reset()
build({ path = "/dev/spidev0.0", spi_mode = 1, bits = 8, speed = 1000000, delay = 0 })
res = destroy(nil)
tester.check("destroy nil 参数返回 ERR", tostring(res.result) == "ERR", res.message)

-- ==================== 负路径：open 失败 ====================
reset()
mock_open_fd = -1
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
tester.check("open 失败 build 返回 ERR", tostring(res.result) == "ERR", res.message)
mock_open_fd = 7	-- 恢复

-- ==================== 负路径：ioctl 失败 ====================
reset()
mock_ioctl_ret = -1
res = build({ path = "/dev/spidev0.0", spi_mode = 0, bits = 8, speed = 1000000, delay = 0 })
tester.check("ioctl 失败 build 返回 ERR", tostring(res.result) == "ERR", res.message)
mock_ioctl_ret = 0	-- 恢复

-- ==================== summary ====================
tester.summary("test_spi")
return 0

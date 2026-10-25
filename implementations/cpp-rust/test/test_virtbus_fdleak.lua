-- test_virtbus_fdleak.lua - 虚拟总线 fd 生命周期回归（审计覆盖缺口 #4）
-- 真实 HAL 与虚拟 HAL 共享同一套驱动 open/close 调用模式：驱动/链路若在
-- build/call/destroy 循环里 open 而不 close（或失败路径漏 close），这里用
-- virtbus.fd_count() 快照即可在纯 Lua 层检出，不必依赖真机 /proc。
-- 覆盖三条路径的 fd 收敛：
--   1. 正常循环：open → build/call×N → destroy → close，重复 30 轮
--   2. 失败循环：地址无器件（build NACK → ERR）重复 30 轮
--   3. UART 链路：open/attach_uart → 写读 → close，重复 30 轮
-- 依赖：LuaJIT（驱动 dofile HAL 需 ffi；milli_sleep 走真 usleep，无硬件副作用）
-- 用法（项目根目录）: luajit test/test_virtbus_fdleak.lua（run_all.sh 自动纳入）

local tester = dofile("test/lib/tester.lua")
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

vbus.load_driver("modules/BH1750.lua")
local light = BH1750_VIRT.new({ count = 30000 })
vbus.attach("bh1750@0x23", 0x23, light)

local base = vbus.fd_count()
tester.check("夹具初始 fd 计数为基线", base == 0, base)

-- 1. 正常循环：fd 必须每轮全额归还（open 1 个，destroy+close 后归零）
local leak_ok = true
local peak = 0
for _ = 1, 30 do
	local fd = i2c_open("/dev/i2c-1")
	local r = build({ fd = fd, address = 0x23, mode = "H" })
	if tostring(r.result) ~= "OK" then leak_ok = false end
	for _ = 1, 5 do
		local c = call({ fd = fd, address = 0x23, mode = "H" })
		if tostring(c.result) ~= "OK" then leak_ok = false end
	end
	if vbus.fd_count() > peak then peak = vbus.fd_count() end
	r = destroy({ fd = fd, address = 0x23 })
	if tostring(r.result) ~= "OK" then leak_ok = false end
	i2c_close(fd)
	if vbus.fd_count() ~= base then leak_ok = false end
end
tester.check("30 轮 open/build/call/destroy 后 fd 回落基线（无泄漏）", leak_ok and vbus.fd_count() == base,
	string.format("peak=%d end=%d", peak, vbus.fd_count()))
tester.check("循环中同时挂存的 fd 不超过 1（open 后即用即还）", peak <= 1, peak)

-- 2. 失败循环：NACK 路径（地址无器件）build/call 恒 ERR——失败路径同样不得漏 close
local fail_leak = true
for _ = 1, 30 do
	local fd = i2c_open("/dev/i2c-1")
	build({ fd = fd, address = 0x50, mode = "H" })	-- 0x50 无器件 → NACK → ERR
	call({ fd = fd, address = 0x50, mode = "H" })
	i2c_close(fd)
	if vbus.fd_count() ~= base then fail_leak = false end
end
tester.check("30 轮 NACK 失败循环后 fd 回落基线", fail_leak and vbus.fd_count() == base,
	vbus.fd_count())

-- 3. UART 链路：attach_uart + open/写读/close 重复，输入环随 close 丢弃
vbus.attach_uart("probe@/dev/serial0", "/dev/serial0", {
	on_write = function(bytes) return { 0xAA, 0xBB } end,
})
local uart_ok = true
for _ = 1, 30 do
	local fd = uart_open("/dev/serial0", 9600)
	if fd < 0 then uart_ok = false end
	uart_write(fd, { 0x01, 0x02 })
	local r = uart_read(fd, 2, 10)
	if r == nil or r[1] ~= 0xAA or r[2] ~= 0xBB then uart_ok = false end
	uart_close(fd)
	if vbus.fd_count() ~= base then uart_ok = false end
end
tester.check("30 轮 UART open/write/read/close 后 fd 回落基线", uart_ok and vbus.fd_count() == base,
	vbus.fd_count())

vbus.restore()
tester.summary("test_virtbus_fdleak")
return 0

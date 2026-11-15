-- test_hal_state.lua —— 宿主 HAL 状态文件桥回归（无真实文件、无硬件）
--
-- 验证 HAL.lua 的 state_read/state_write 确实经 __hal_call，且 state_write
-- 把 Lua 字节数组原样过桥；真实落盘/路径拒绝由 test/cpp/test_hal_state.cpp 覆盖。
-- 用法（项目根目录）: luajit test/test_hal_state.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local calls = {}
_G.__hal_call = function(op, ...)
	local args = { ... }
	calls[#calls + 1] = { op = op, args = args }
	if op == "state_read" then
		if args[1] == "missing.bin" then return nil end
		return { 10, 20, 30, 40, 50, 60 }
	end
	if op == "state_write" then return 0 end
	if op == "last_error" then return "mock state error" end
	return -1
end

local HAL = dofile("modules/lib/HAL.lua")

check("HAL.lua 定义 state_read", type(state_read) == "function")
check("HAL.lua 定义 state_write", type(state_write) == "function")

local read = state_read("sgp30-baseline.bin")
check("state_read 走 __hal_call", calls[#calls].op == "state_read")
check("state_read 返回字节数组",
	type(read) == "table" and #read == 6 and read[1] == 10 and read[6] == 60)
check("state_read 缺失文件返回 nil", state_read("missing.bin") == nil)

local wrote = state_write("sgp30-baseline.bin", { 1, 2, 3, 4, 5, 6 })
local writeCall = calls[#calls]
check("state_write 走 __hal_call", writeCall.op == "state_write" and wrote == 0)
check("state_write 参数原样过桥",
	writeCall.args[1] == "sgp30-baseline.bin"
	and type(writeCall.args[2]) == "table"
	and #writeCall.args[2] == 6
	and writeCall.args[2][1] == 1
	and writeCall.args[2][6] == 6)

tester.summary("HAL state")

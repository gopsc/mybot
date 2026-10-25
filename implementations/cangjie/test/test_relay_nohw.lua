-- Relay.lua 无硬件测试（最小样例：不需要任何总线/真机，甚至不需要 HAL）
-- Relay 是纯软件模块：build/call/destroy 只做参数处理，不触 I2C/SPI/UART，
-- 因此无需 mock HAL、无需 ffi，luajit 或 lua5.4 均可直接运行。
-- 用法（项目根目录）: luajit test/test_relay_nohw.lua
--                 或 lua5.4 test/test_relay_nohw.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

dofile("modules/Relay.lua")

-- 用例1：build 无需资源，返回 OK
local r = build({})
check("build 返回 OK", type(r) == "table" and r.result == "OK")

-- 用例2：destroy 无需资源，返回 OK
r = destroy({})
check("destroy 返回 OK", type(r) == "table" and r.result == "OK")

-- 用例3：call 把 test 转换为 delay
r = call({ test = "200", note = "hello-relay" })
check("call 转换 test=200 -> delay=200", type(r) == "table" and r.delay == 200,
	(type(r) == "table") and tostring(r.delay) or tostring(type(r)))

-- 用例4：test 缺省取 0
r = call({})
check("call 无 test 时 delay=0", type(r) == "table" and r.delay == 0,
	(type(r) == "table") and tostring(r.delay) or nil)

-- 用例5：非法参数（非表）返回 ERR
r = call("not a table")
check("call 非表参数返回 ERR", type(r) == "table" and r.result == "ERR")

tester.summary()

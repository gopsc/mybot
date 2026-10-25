-- test_daemon_cleanup_destroy_err.lua —— 回归：destroy 抛错时守护仍必须释放总线 fd
--
-- 缺陷（2026-09-20 审计 · 中）：sensor_daemon.lua 的 daemon_cleanup() 把
-- destroy(params) 写成**裸调**——驱动 destroy 抛异常时函数当场中断，
-- close_bus() 与 vbus.restore() 都不再执行，build 期打开的总线 fd 泄漏到
-- 进程退出（宿主只 pcall 了 cleanup 本身，随后就 lua_close；HAL 也没有
-- ffi.gc 兜底）。反复启停守护会耗尽 fd。修法：pcall(destroy, params)。
--
-- 本文件在**独立 lua_State**（独立进程）里跑，因此可以走完整的 setup →
-- cleanup 路径：setup 后 fd 处于打开态，随后让 destroy 抛错并断言 fd 仍被关闭。
-- 与 test_h07_fd.lua 同法用桩 HAL 注入（本机无真机总线）。
local ffi = require("ffi")
local log = print	-- sensor_daemon 会把全局 print 覆盖为 noop

local tmp = os.getenv("TMPDIR") or "/tmp"
local d = tmp .. "/bot4cj_cleanup_err_" .. math.floor(os.time() * 1000) % 1000000
os.execute("mkdir -p " .. d .. "/lib")

-- 桩 HAL：i2c_open 恒返假 fd=200；i2c_close 记账到全局 close_log
_G.close_log = {}
local f = io.open(d .. "/lib/HAL.lua", "w")
f:write([[
function i2c_open(path) return 200 end
function i2c_close(fd) close_log[fd] = (close_log[fd] or 0) + 1 end
function spi_open(path) return -1 end
function spi_close(fd) end
function spi_setup(...) return 0 end
function uart_open(p, b) return -1 end
function uart_close(fd) end
]])
f:close()

-- 桩驱动：build/call 成功；destroy **抛错**（模拟「器件去初始化失败」）
f = io.open(d .. "/boombdrv.lua", "w")
f:write([[
function build(data)
	if type(data.fd) ~= "number" or data.fd <= 0 then
		return { result = "ERR", message = "boombdrv: fd invalid" }
	end
	return { result = "OK" }
end
function call(data) return { result = "OK", v = 7 } end
function destroy(data) error("boombdrv: destroy boom") end
]])
f:close()

-- lib/pthread.lua 与 lib/mpath.lua 原样复制（sensor_daemon 经 mpath.resolve 取 lib）
for _, rel in ipairs({ "lib/pthread.lua", "lib/mpath.lua" }) do
	local src = io.open("modules/" .. rel, "r")
	local body = src:read("*a")
	src:close()
	local dst = io.open(d .. "/" .. rel, "w")
	dst:write(body)
	dst:close()
end

local realP = dofile("modules/lib/pthread.lua")
local slot = realP.slot_new()
_G.DAEMON_SLOT_ADDR = tonumber(ffi.cast("uint64_t", slot))
_G.DAEMON_CONFIG = "driver=boombdrv;proto=i2c;path=/dev/fake-i2c;addr=0x0;fields=v"
ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]
ffi.cdef[[char *strstr(const char *haystack, const char *needle);]]
ffi.C.setenv("BOT4CJ_MODULE_PATH", d, 1)

dofile("modules/lib/sensor_daemon.lua")
print = log

local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- setup 已把 fd=200 打开
check("setup 后未发生 close（fd 处于打开态）", (close_log[200] or 0) == 0,
	close_log[200])

-- 关键断言：destroy 抛错，daemon_cleanup 必须仍然关闭总线 fd 且不向外抛
local ok, err = pcall(daemon_cleanup)
check("destroy 抛错时 daemon_cleanup 不向外抛异常", ok, tostring(err))
check("destroy 抛错后总线 fd 仍被关闭（fix：close_bus 不再被跳过）",
	(close_log[200] or 0) == 1, "close_log[200]=" .. tostring(close_log[200]))

os.execute("rm -rf " .. d)
tester.summary("test_daemon_cleanup_destroy_err.lua")

-- test_h07_fd.lua - H-07 回归：sensor_daemon 守护退出前关闭总线 fd
-- 无真机环境：以临时 BOT4CJ_MODULE_PATH 注入桩 HAL/驱动，真实 pthread 槽，
-- 断言：
--   1) setup 成功后总线 fd 已打开（驱动 build 生效、daemon_tick 可发布）
--   2) daemon_cleanup() 关闭该 fd（i2c_close 恰被调用一次）
--   3) 再次 daemon_cleanup() 幂等（close 仍只一次）
local ffi = require("ffi")
-- sensor_daemon 会把全局 print 覆盖为 noop，先捕获真实 print 供本测试输出用
local log = print

-- 桩 HAL 与桩驱动写进临时模块目录（sensor_daemon 按 BOT4CJ_MODULE_PATH 寻址）
local tmp = os.getenv("TMPDIR") or "/tmp"
local d = tmp .. "/bot4cj_h07_" .. math.floor(os.time() * 1000) % 1000000
os.execute("mkdir -p " .. d .. "/lib")

-- 桩 HAL：i2c_open 固定返回假 fd=100；i2c_close 经全局 close_log 记账
_G.close_log = {}
local f = io.open(d .. "/lib/HAL.lua", "w")
f:write([[
function i2c_open(path) return 100 end
function i2c_close(fd) close_log[fd] = (close_log[fd] or 0) + 1 end
function spi_open(path) return -1 end
function spi_close(fd) end
function spi_setup(...) return 0 end
function uart_open(p, b) return -1 end
function uart_close(fd) end
]])
f:close()

-- 桩驱动：build/call 均成功，call 返回固定 field v=42
f = io.open(d .. "/stubdrv.lua", "w")
f:write([[
function build(data)
	if type(data.fd) ~= "number" or data.fd <= 0 then
		return { result = "ERR", message = "stubdrv: fd invalid" }
	end
	fd_seen = data.fd
	return { result = "OK" }
end
function call(data) return { result = "OK", v = 42 } end
]])
f:close()
_G.fd_seen = nil

-- lib/pthread.lua：直接复制真实实现（含重复加载保护，同模块表）
local pfile = io.open("modules/lib/pthread.lua", "r")
local pthread_src = pfile:read("*a")
pfile:close()
f = io.open(d .. "/lib/pthread.lua", "w")
f:write(pthread_src)
f:close()

-- lib/mpath.lua：sensor_daemon 统一经「首段加载 mpath + resolve」取 lib，
-- 桩目录同样要有它（resolve 后命中的才是上面的桩 HAL）
local mfile = io.open("modules/lib/mpath.lua", "r")
local mpath_src = mfile:read("*a")
mfile:close()
f = io.open(d .. "/lib/mpath.lua", "w")
f:write(mpath_src)
f:close()

-- 真实 pthread 分配共享槽，取整数地址注入
local realP = dofile("modules/lib/pthread.lua")
local slot = realP.slot_new()
_G.DAEMON_SLOT_ADDR = tonumber(ffi.cast("uint64_t", slot))
_G.DAEMON_CONFIG = "driver=stubdrv;proto=i2c;path=/dev/fake-i2c;addr=0x0;fields=v"
-- LuaJIT 无 os.setenv，经 ffi 直调 libc
ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]
ffi.C.setenv("BOT4CJ_MODULE_PATH", d, 1)

-- 以守护 chunk 语义加载并完成 setup（等价 daemon_body 首拍）；setup 失败会直接 throw
dofile("modules/lib/sensor_daemon.lua")

local pass, fail = 0, 0
local function check(label, cond, detail)
	if cond then pass = pass + 1; log("[PASS] " .. label)
	else fail = fail + 1; log("[FAIL] " .. label .. " (" .. tostring(detail) .. ")") end
end

-- 1) setup 成功 → 驱动 build 见到 fd=100，daemon_tick 采样可发布
check("sensor_daemon setup 驱动收到 fd", fd_seen == 100, fd_seen)
daemon_tick()
local vals, cnt = realP.latest(slot)
check("daemon_tick 发布字段 v=42", #vals == 1 and vals[1] == 42 and cnt == 1,
	"#vals=" .. #vals .. " vals[1]=" .. tostring(vals[1]))

-- 2) 守护退出清理：daemon_cleanup() 关闭总线 fd
daemon_cleanup()
check("daemon_cleanup 关闭 fd=100", close_log[100] == 1, close_log[100])

-- 3) 幂等：再次调用不重复 close
daemon_cleanup()
check("daemon_cleanup 幂等（仅一次 close）", close_log[100] == 1, close_log[100])

-- 清理临时目录
os.execute("rm -rf " .. d)

log(("H-07 fd-close: %d 通过, %d 失败"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
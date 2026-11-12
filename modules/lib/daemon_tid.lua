-- daemon_tid.lua - 诊断守护 chunk（D 方案：setup 一次 + 定义全局 daemon_tick 单次采样）
-- daemon_body 先 pcall 本 chunk 一次完成 setup，随后逐拍 getglobal("daemon_tick")+pcall，
-- 拍间由 Cangjie sleep 让出绿色线程（不再由 chunk 内 ffi usleep 阻塞 worker）。
--
-- 【用途】仅供回归使用：robots/test/multidaemon.sql 以本 chunk 起 4 个守护
-- （d0-d3）验证多守护并发 + 独立 lua_State + 交错 teardown（run_all.sh 的
-- multidaemon 用例）。不是可直接引用的生产 chunk——真实采样 chunk 见
-- lib/sensor_daemon.lua，示例见 docs/daemon.md。
if jit then jit.off() end

local ffi = require("ffi")
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local P = dofile(mpath.resolve("lib/pthread.lua"))

pcall(ffi.cdef, "long gettid(void);")		-- glibc 2.30+
local tid = tonumber(ffi.C.gettid())
local slot = P.slot_attach(DAEMON_SLOT_ADDR)

io.stderr:write("[daemon-tid] setup on tid=" .. tostring(tid) .. "\n")
io.stderr:flush()

local n = 0
-- daemon_body 逐拍调用（单次采样）；发布 {tid, 计数}
function daemon_tick()
	n = n + 1
	P.publish(slot, { tid, n })
end

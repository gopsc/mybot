-- daemon_probe.lua - 模拟传感器守护 chunk（D 方案：setup + 全局 daemon_tick 单次采样）
-- daemon_body 先 pcall 本 chunk 一次完成 setup，随后逐拍调用 daemon_tick，拍间 Cangjie sleep 让出。
if jit then jit.off() end

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local P = dofile(mpath.resolve("lib/pthread.lua"))
P.assert_layout()
local slot = P.slot_attach(DAEMON_SLOT_ADDR)

local t = 0
-- 逐拍发布 {1.5, 2.5, 3.5, sin}；v0=1.5 作跨语言布局校验锚点
function daemon_tick()
	t = t + 1
	P.publish(slot, { 1.5, 2.5, 3.5, math.sin(t * 0.1) * 100 })
end

-- setup 阶段立即发布首帧：下游引用方在首个 tick 前即可读到就绪值
-- （避免「守护首发 interval 前，首行动作引用到空槽」的预热竞态）
daemon_tick()

-- sim_sensor_daemon.lua - 仿真器 IMU/里程计守护采样 chunk（2026-10-16）
-- bot4cj 仓颉语言机器人框架
--
-- 把 mybot-sim 的 IMU/里程计桥采样进共享槽：kind=imu 发布 yaw/角速度/前向加速度/
-- 竖直速度/离地 5 字段，kind=odom 发布位置/航向/速度/累计里程 5 字段。复用
-- modules/Sim.lua 的 imu()/odom() 客户端（一问一答、惰性连接、超时收行），
-- 本 chunk 不重复声明任何 socket 协议——协议单点在 Sim.lua。
--
-- 与 sensor_daemon.lua 的语义差异（其余——拍间让出、错误限频、坏样本不发布、
-- status 失败码——同源）：
--   1. **不碰硬件总线**：数据源是仿真器进程，没有 fd 要开要关；
--      槽协议（P.publish/get_status）仍走 lib/pthread.lua 原语。
--   2. **仿真器缺席不是永久失败**：imu()/odom() 每次 call 惰性重连（仿真器
--      后起即接上），故缺席按**逐拍错误**处理（count 停滞 + 限频日志），
--      不写 status 失败码——与「驱动加载失败」这类永不自愈的失败区分。
--   3. 永久失败只有一种：kind 列缺失/非法（配置错误，status=-2）。
--   4. daemon_cleanup 关掉 Sim.lua 可能持有的连接 fd（H-07 口径）。
--
-- DAEMON_CONFIG（"k=v;k=v"，来自 @Daemon 矩阵除 name/chunk 外的列）：
--   kind     imu | odom（必填；加载期由宿主 checkDaemonKind 校验）
--   interval 由 daemon_body 逐拍 sleep 使用，不在本 chunk 内处理
--
-- 用法示例（与 sources 聚合连用，见 robots/spider_sim_nav.sql）：
--   INSERT INTO Daemon (name, chunk, kind, interval)
--     VALUES ('imu0', 'lib/sim_sensor_daemon.lua', 'imu', '20');
--   INSERT INTO Daemon (name, chunk, kind, interval)
--     VALUES ('odom0', 'lib/sim_sensor_daemon.lua', 'odom', '20');
--   INSERT INTO Daemon (name, chunk, sources, interval, maxvals)
--     VALUES ('nav0', 'lib/sensor_aggregate.lua', 'imu0|odom0', '50', '16');

if jit then jit.off() end

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local P = dofile(mpath.resolve("lib/pthread.lua"))
dofile(mpath.resolve("Sim.lua"))	-- imu()/odom() 客户端（其 build/call/destroy 全局与本 chunk 无冲突）

local slot = P.slot_attach(DAEMON_SLOT_ADDR)
P.assert_layout()	-- 跨语言槽布局漂移在守护启动期显式暴露（daemon_probe 同款自检）

local log = print	-- 保留真实 print（Sim.lua 只在 BOT4CJ_DEBUG=1 时打印）

-- 解析配置串（语法已由宿主校验；此处分两键即可，宽容兜底与 sensor_daemon 同源）
local cfg = {}
for pair in string.gmatch(DAEMON_CONFIG or "", "([^;]+)") do
	local eq = string.find(pair, "=")
	if eq then
		cfg[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
	end
end

-- setup 失败（kind 缺失/非法）：写 status 失败码 → daemon_tick 置空转。
-- 错误码口径沿用 -2（build/配置类错误）。宿主读路径见 status ≠ 0 即响亮报错。
local function fail(code, msg)
	log("[sim_sensor_daemon] setup failed (" .. tostring(code) .. "): " .. tostring(msg))
	P.set_status(slot, code)
	P.publish(slot, {})	-- 只推进 count（nvals=0），不发布任何假样本
	function daemon_tick() end
end

local kind = cfg.kind
if kind ~= "imu" and kind ~= "odom" then
	fail(-2, "config 'kind' must be imu|odom, got: " .. tostring(kind))
	return
end

-- kind → 采样函数 + 字段序（publish 顺序即此表顺序，下游按 v0..vN 引用）
local sampler, field_names
if kind == "imu" then
	sampler = imu
	field_names = { "yaw_deg", "gyro_z", "acc_fwd", "vy", "airborne" }
else
	sampler = odom
	field_names = { "x", "z", "theta_deg", "v", "odo" }
end

-- daemon_body 逐拍调用：一次采样 → 提取字段 → publish。
-- 错误语义与 sensor_daemon 同源：仿真器缺席/断开/帧畸形按逐拍错误处理
-- （不发布、count 停滞是诊断线索），限频日志（首 3 次 + 每 100 次一条摘要）；
-- 仿真器后起时下一拍自动重连恢复，无需人工干预。
local tick_errors = 0
local tick_total  = 0
function daemon_tick()
	local ok, res = pcall(sampler)
	if not ok or type(res) ~= "table" or res.result ~= "OK" then
		tick_errors = tick_errors + 1
		tick_total  = tick_total + 1
		if tick_errors <= 3 or tick_total % 100 == 0 then
			local why = ok and type(res) == "table" and res.message or tostring(res)
			log(string.format("[sim_sensor_daemon] tick error #%d (total %d): %s",
				tick_errors, tick_total, why))
		end
		return
	end
	local vals = {}
	for i, name in ipairs(field_names) do
		vals[i] = tonumber(res[name]) or 0
	end
	P.publish(slot, vals)
	tick_errors = 0
end

-- H-07：守护退出（stop 后、Lua_free 前）由 daemon_body 调用。Sim.lua 可能持有
-- imu/odom 的连接 fd，经其 destroy() 关闭（内部全是 nil 安全的 drop）。
-- destroy 失败不改变返回（退出路径上的资源释放优先于传播无人接收的错误，
-- 与 sensor_daemon 的 cleanup 语义取舍一致）。
function daemon_cleanup()
	local ok, err = pcall(destroy, {})
	if not ok then
		io.stderr:write(string.format(
			"[sim_sensor_daemon] Sim.lua destroy() failed during cleanup (fd may stay open until lua_close): %s\n",
			tostring(err)))
	end
end

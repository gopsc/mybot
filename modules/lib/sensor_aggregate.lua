-- sensor_aggregate.lua - 多守护聚合 chunk（sources 列，2026-10-16 路线图阶段 2）
-- bot4cj 仓颉语言机器人框架
--
-- 动机（docs/daemon.md「多守护聚合器」）：sensor_daemon_multi 已把**同一条 I2C
-- 总线**上的 N 只器件合进一个守护；跨总线/跨协议（多 IMU + 气感 + 里程计）仍要
-- 多个守护各占一个槽，下游 @Monitor/@Ema 得逐个 $ 引用、拿到的是**不同时刻**
-- 的拼盘。本 chunk 用一路守护把若干 peer 守护的最新快照按 sources 序拼接进
-- **同一次 publish**：消费方一个 $ 引用拿到统一视图（v 下标 = sources 序 ×
-- 各 peer 字段序），跨源时差收敛到本守护的 interval。
--
-- 与 sensor_daemon 的契约差异：
--   1. 器件清单来自 sources 列（peer 守护名，'|' 或 ',' 分隔），宿主在加载期
--      解析出各 peer 槽并注入 DAEMON_PEER_SLOTS 表（名字 → lightuserdata；
--      引用自己 / 重名 / 未知名都在加载期拒绝——见 src/daemonconf.cpp 的
--      resolveDaemonSources）
--   2. 本守护**不碰任何总线**：无 driver/proto/path，也没有 fd 要关；
--      daemon_cleanup 无事可做（不定义）
--   3. peer 死亡是**永久性**失败（见下），错误码扩展：
--      -10 peer setup 失败（peer 的 status ≠ 0，它永远不会出数）
--      -11 peer 已停止（热删除或断电位——继续发布等于拿陈旧值冒充采样）
--      -12 sources 名字未注入（宿主与 chunk 版本错配的防御；宿主路径不会发生）
--      -2  拼接总数超过本槽容量（maxvals 列，加载期算不出——peer 的 nvals
--          运行期才知道，故在首拍检测并永久失败）
--
-- DAEMON_CONFIG（"k=v;k=v"，来自 @Daemon 矩阵除 name/chunk 外的列）：
--   sources  必填。peer 守护名清单，'|' 分隔（SQL 里推荐用 |，避开逗号）。
--            每个 peer 取其**整组** values（v0..vN），按 sources 声明序拼接。
--   maxvals  建议显式给：缺省 64；聚合容量应 ≥ 各 peer nvals 之和（peer 各自
--            的容量上限之和是最坏情况预算）。
--   interval 照常逐拍让出（拍频即聚合快照率）。
--
-- 用法示例（两只守护 + 一路聚合）：
--   CREATE TABLE Daemon (name String, chunk String, driver String, proto String,
--                        path String, addr String, interval String, fields String);
--   INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
--     VALUES ('imu0', 'lib/sensor_daemon.lua', 'MPU6050', 'virt', '/dev/i2c-1',
--             '0x68', '10', 'ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z|TEMP:f');
--   INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
--     VALUES ('baro0', 'lib/sensor_daemon.lua', 'BME280', 'virt', '/dev/i2c-1',
--             '0x76', '50', 'TEMP:f|PRESS:f|HUM:f');
--   INSERT INTO Daemon (name, chunk, sources, interval, maxvals)
--     VALUES ('agg0', 'lib/sensor_aggregate.lua', 'imu0|baro0', '20', '16');
--   上游 @Ema/@Monitor 用 field=v0..v9 按拼接顺序引用（先 imu0 的 7 个，再
--   baro0 的 3 个）。

if jit then jit.off() end

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local P = dofile(mpath.resolve("lib/pthread.lua"))
dofile(mpath.resolve("lib/HAL.lua"))	-- 布局互锁与守护态读原语同源加载（无总线调用）

local slot = P.slot_attach(DAEMON_SLOT_ADDR)
P.assert_layout()	-- 跨语言槽布局漂移在守护启动期显式暴露（daemon_probe 同款自检）

local log = print	-- 保留真实 print（setup/tick 诊断可见；本 chunk 不静默 print）

-- setup 失败：打日志 → 写 status 失败码 → daemon_tick 置空转（daemon_body 仍
-- 逐拍调用直到 stop）。语义与 sensor_daemon.fail 同源：失败响亮、绝不伪装采样。
local function fail(code, msg)
	log("[sensor_aggregate] setup/tick failed (" .. tostring(code) .. "): " .. tostring(msg))
	P.set_status(slot, code)
	P.publish(slot, {})	-- 只推进 count（nvals=0），不发布任何假样本
	function daemon_tick() end
end

-- 解析配置（语法已由宿主在加载期校验：sources 非空、无空令牌/重名/自引用）
local cfg = {}
for pair in string.gmatch(DAEMON_CONFIG or "", "([^;]+)") do
	local eq = string.find(pair, "=")
	if eq then
		cfg[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
	end
end

local sources = cfg.sources
if sources == nil or sources == "" then
	fail(-12, "config missing 'sources' (host did not pass the sources column?)")
	return
end

-- peer 槽附着：宿主注入的 DAEMON_PEER_SLOTS（名字 → lightuserdata）。
-- 名字缺失即防御性失败——宿主路径在加载期已拒绝未知名，走到这里说明注入
-- 与配置两份来源不一致（版本错配一类），静默跳过会让 v 下标悄悄移位。
local peers = {}
for name in string.gmatch(sources, "[^,|]+") do
	local addr = rawget(_G, "DAEMON_PEER_SLOTS") and DAEMON_PEER_SLOTS[name]
	if addr == nil then
		fail(-12, "sources name '" .. tostring(name) .. "' has no injected peer slot")
		return
	end
	peers[#peers + 1] = { name = name, slot = P.slot_attach(addr) }
end
if #peers == 0 then
	fail(-12, "sources parsed to zero peers: '" .. tostring(sources) .. "'")
	return
end

local own_cap = P.capacity(slot)

-- daemon_body 逐拍调用：逐 peer 检查存活 → 读最新快照 → 拼接 → 一次 publish。
-- 错误限频与 sensor_daemon 同口径：瞬时等待（peer 尚未首发）只限频提示，
-- 永久失败（peer 停止 / setup 失败 / 容量超预算）置 status 后空转。
local wait_notes = 0
local wait_total = 0
function daemon_tick()
	-- 自身 stop 已置（断电屏障/热删除先给全体置位）：安静跳过，不再诊断 peer。
	-- 不查的话，屏障的置位窗口里会打出误导性的「peer 已停止（热删除）」。
	if P.should_stop(slot) then return end
	local vals = {}
	local n = 0
	for _, peer in ipairs(peers) do
		-- 永久失败①：peer setup 失败（其槽 status ≠ 0，它永远不会出数）
		local st = P.get_status(peer.slot)
		if st ~= 0 then
			fail(-10, "peer daemon '" .. peer.name .. "' setup failed (its slot status "
				.. tostring(st) .. "); aggregation can never produce data")
			return
		end
		-- 永久失败②：peer 已停止（热删除置 stop，只置不清）。继续拼接等于
		-- 拿陈旧快照冒充实时采样，且缺一段后 v 下标整体移位——宁可响亮死。
		if P.should_stop(peer.slot) then
			fail(-11, "peer daemon '" .. peer.name .. "' has stopped (hot-removed or"
				.. " powering down); restart this aggregator with an updated sources list")
			return
		end
		local t, c = P.latest(peer.slot)
		if c == 0 or t == nil or #t == 0 then
			-- 瞬时：peer 尚未首发（守护 setup 需数毫秒），整拍不发布
			wait_notes = wait_notes + 1
			wait_total = wait_total + 1
			if wait_notes <= 3 or wait_total % 100 == 0 then
				log(string.format(
					"[sensor_aggregate] waiting first sample from peer '%s' (tick %d)",
					peer.name, wait_total))
			end
			return
		end
		for i = 1, #t do
			n = n + 1
			vals[n] = t[i]
		end
	end
	-- 永久失败③：拼接总数超本槽容量。首拍即可判定（peer nvals 稳定后不再
	-- 增长），配置错误——提高本行 maxvals 或裁剪 sources。
	if n > own_cap then
		fail(-2, "aggregated " .. n .. " values exceed this daemon's slot capacity "
			.. own_cap .. " (raise the 'maxvals' column or trim sources: " .. sources .. ")")
		return
	end
	P.publish(slot, vals)
	wait_notes = 0
end

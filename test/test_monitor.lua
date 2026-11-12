-- test_monitor.lua —— Monitor 守护数据消费驱动离线测试
-- 用法（项目根目录）: luajit test/test_monitor.lua
--
-- Monitor 是纯软件驱动（不申请资源、不碰总线），直接 dofile 即可，无需桩设备。
-- 它的输入 v0..vN / count 不是 .mt 里的字面配置列，而是**被引用守护发布的快照**
-- 经引用机制合并进元数据而来；它的输出若本变量声明了 controller 列，会被框架
-- 转发给执行器。也就是说本驱动坐在「守护采样 → 引用消费 → 决策 → 转发执行」
-- 这条闭环的中间，是链上后果最重的一环，此前却在 test/ 下没有任何覆盖。
--
-- 覆盖：基本消费（level 阈值判定 / out 与 count 透传）、多字段守护 v0..vN 透传、
-- v0 缺失的启动瞬间负路径、read 的引用语义（无采样先 ERR、有采样返回最近快照）、
-- 以及非有限值防线（26.3）。
local tester = dofile("test/lib/tester.lua")
local check = tester.check

dofile("modules/Monitor.lua")
-- Monitor 以全局函数名暴露 build/call/destroy/read；先接到 local，避免与其它
-- 同名全局的驱动互相覆盖（与 test_servo_timer_nan.lua 同惯例）。
local mon_build, mon_call, mon_read, mon_destroy = build, call, read, destroy

------------------------------------------------------------------
-- read 的引用语义：必须在任何成功 call 之前断言「无采样」这一支
------------------------------------------------------------------
local r = mon_read({})
check("read: 尚无采样时报 ERR", r.result == "ERR", tostring(r.result))
check("read: ERR 文案为 no sample yet",
	type(r.message) == "string" and r.message:find("no sample yet", 1, true) ~= nil,
	tostring(r.message))

------------------------------------------------------------------
-- 生命周期与基本消费路径
------------------------------------------------------------------
check("build: OK", mon_build({}).result == "OK")
check("destroy: OK", mon_destroy({}).result == "OK")

r = mon_call({ v0 = 0.5, count = 3 })
check("call: v0=0.5 判 LOW", r.result == "OK" and r.level == "LOW", tostring(r.level))
check("call: out 透传 v0", r.out == 0.5, tostring(r.out))
check("call: count 透传", r.count == 3, tostring(r.count))
check("call: v0 字段一并透传", r.v0 == 0.5, tostring(r.v0))

r = mon_call({ v0 = 2.0 })
check("call: v0=2.0 判 HIGH", r.level == "HIGH", tostring(r.level))
check("call: 未给 count 则不出现该键", r.count == nil, tostring(r.count))

r = mon_call({ v0 = 1, v1 = -2, v2 = 3.5, count = 7 })
check("call: 多字段守护 v1/v2 透传", r.v1 == -2 and r.v2 == 3.5,
	tostring(r.v1) .. "/" .. tostring(r.v2))

-- 阈值边界：> 1.0 才是 HIGH，恰等于 1.0 判 LOW
r = mon_call({ v0 = 1.0 })
check("call: v0=1.0 判 LOW（阈值是严格大于）", r.level == "LOW", tostring(r.level))

-- 守护尚未发布任何采样（启动瞬间）或被引用列缺失
r = mon_call({ count = 1 })
check("call: v0 缺失报 ERR", r.result == "ERR", tostring(r.result))
check("call: v0 缺失的 ERR 文案", 
	type(r.message) == "string" and r.message:find("v0 missing", 1, true) ~= nil,
	tostring(r.message))

-- read 现在应返回最近一次**成功**的决策快照（上面 v0 缺失那次失败不更新 last）
r = mon_read({})
check("read: 返回最近成功快照（失败 call 不覆盖）",
	type(r) == "table" and r.v0 == 1.0 and r.level == "LOW",
	tostring(r and r.v0))

------------------------------------------------------------------
-- 非有限值（26.3）
------------------------------------------------------------------
-- v0/count 的 NaN 不来自用户笔误，而来自「某个上游传感器驱动已经把 NaN 当合法
-- 采样发布出来」的二次传播（MS5611 的 p0、MT6826S 的 ANGLE 都是这一类的上游）。
-- 旧行为：`tonumber` 放行 'nan'（出的是 number），`v0 == nil` 判据不触发，于是
-- level 静默判 "LOW"（NaN > 1.0 恒假）、out = NaN 且 result = "OK"——即「拿着
-- 无效值做出了决策并宣称成功」，NaN 进 JSON 变 null，转发给执行器的是空值。
-- 判据取「与 v0 缺失同结论」：本文件既有口径就是拒绝并报 ERR。
r = mon_call({ v0 = "nan", count = 1 })
check("call: v0='nan' 报 ERR（不得以 OK 输出 NaN 决策值）",
	r.result == "ERR", tostring(r.result) .. "/out=" .. tostring(r.out))
r = mon_call({ v0 = 0 / 0, count = 1 })
check("call: v0=数值 NaN 报 ERR（守护发布数值 NaN 的形态）",
	r.result == "ERR", tostring(r.result))
r = mon_call({ v0 = "1e400", count = 1 })
check("call: v0=inf 报 ERR", r.result == "ERR", tostring(r.result))
r = mon_call({ v0 = "-1e400", count = 1 })
check("call: v0=-inf 报 ERR", r.result == "ERR", tostring(r.result))

-- count 缺失与非有限必须同结论：省略该键，而不是透传一个 JSON null 计数
r = mon_call({ v0 = 0.5, count = "nan" })
check("call: count=nan 省略该键", r.result == "OK" and r.count == nil,
	tostring(r.count))
r = mon_call({ v0 = 0.5, count = 0 / 0 })
check("call: count=数值 NaN 省略该键", r.result == "OK" and r.count == nil,
	tostring(r.count))

-- vN 透传循环同样只放行有限值：否则 v0 拦住了、v1..vN 仍把 NaN 带进结果表
r = mon_call({ v0 = 0.5, v1 = 0 / 0, v2 = 2 })
check("call: v1=数值 NaN 不透传，v2 照常透传",
	r.result == "OK" and r.v1 == nil and r.v2 == 2,
	tostring(r.v1) .. "/" .. tostring(r.v2))
-- 字符串型的 vN 本来就不透传（判据含 type(v)=="number"），此处钉住不被放宽
r = mon_call({ v0 = 0.5, v1 = "7" })
check("call: v1='7' 字符串仍不透传（口径未被放宽）", r.v1 == nil, tostring(r.v1))

tester.summary("test_monitor.lua")

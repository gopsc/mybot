-- Ema.lua / Kalman.lua 驱动层非有限值防线测试（离线；纯 Lua 逻辑，无总线/ffi 依赖）
-- 用法（项目根目录）: luajit test/test_ema_kalman_driver.lua
--
-- 背景（2026-09-20 评估）：两驱动的列解析写作 `tonumber(x) or 缺省`，而 NaN 是
-- truthy——String 列（robots/spider2.sql 的 Ema.alpha 就是 String 列）里写 "nan"
-- 会一路变成 NaN 参数，库内的区间校验（`alpha <= 0 or alpha > 1`、`Q < 0`）对
-- NaN 全为假也拦不住，最终 result="OK" 却发布 NaN。
--   改前：build(alpha='nan') 返回 alpha=NaN（断言 "回落缺省" 失败）；
--         call({in='nan'}) 让库抛错、裸 Lua 异常逃出 call（expect_err 失败）。
--   改后：非有限列值回落缺省；样本列非有限按「无输入值」走 ERR 契约。
-- 判别性：本文件在修复前必失败，修复后全绿。
--
-- 注：lib/ema.lua、lib/kalman.lua 的库层防线（pcall 转 ERR）由
-- test_ema.lua / test_kalman.lua 覆盖；本文件只钉驱动层这一环。

local tester = dofile("test/lib/tester.lua")
local check, expect_ok, expect_err = tester.check, tester.expect_ok, tester.expect_err

-- ==================== Ema 驱动 ====================
dofile("modules/Ema.lua")

-- 非有限 alpha 回落缺省（改前 res.alpha 为 NaN → `res.alpha == 0.2` 失败）
local res = expect_ok("Ema build alpha='nan' 仍返回 OK",
	function() return build({ name = "e0", alpha = "nan" }) end)
check("Ema alpha='nan' 回落缺省 0.2（不是 NaN）",
	res ~= nil and res.alpha == 0.2, res and tostring(res.alpha))

res = expect_ok("Ema build alpha='1e400'（溢出字面量）",
	function() return build({ name = "e0", alpha = "1e400" }) end)
check("Ema alpha='1e400' → inf 亦回落缺省 0.2",
	res ~= nil and res.alpha == 0.2, res and tostring(res.alpha))

-- 合法值不被收紧（回落只对非有限值生效）
res = expect_ok("Ema build alpha='0.35'",
	function() return build({ name = "e0", alpha = "0.35" }) end)
check("Ema alpha='0.35' 逐字生效", res ~= nil and res.alpha == 0.35,
	res and tostring(res.alpha))

-- 样本列非有限 → ERR 契约（改前库抛错，expect_err 拿到 EXC: 而失败）
expect_err("Ema call in='nan' 返回 ERR（不是裸异常）",
	function() return call({ ["in"] = "nan" }) end, "no input value")
expect_err("Ema call in='inf' 返回 ERR",
	function() return call({ ["in"] = "inf" }) end, "no input value")
expect_err("Ema call 无非有限无输入 → ERR",
	function() return call({}) end, "no input value")

-- 合法样本仍走通（回归锁）
res = expect_ok("Ema call in='10'", function() return call({ ["in"] = "10" }) end)
check("Ema 输出为有限数值", res ~= nil and res.out == 10 and res.out == res.out,
	res and tostring(res.out))

-- ==================== Kalman 驱动 ====================
dofile("modules/Kalman.lua")

res = expect_ok("Kalman build Q='nan' R='nan' 仍返回 OK",
	function() return build({ name = "k0", Q = "nan", R = "nan" }) end)
check("Kalman Q='nan' 回落缺省 20", res ~= nil and res.Q == 20,
	res and tostring(res.Q))
check("Kalman R='nan' 回落缺省 200", res ~= nil and res.R == 200,
	res and tostring(res.R))

res = expect_ok("Kalman build Q='30' R='300'",
	function() return build({ name = "k0", Q = "30", R = "300" }) end)
check("Kalman Q/R 合法值逐字生效",
	res ~= nil and res.Q == 30 and res.R == 300,
	res and (tostring(res.Q) .. "/" .. tostring(res.R)))

expect_err("Kalman call in='nan' 返回 ERR（不是裸异常）",
	function() return call({ ["in"] = "nan" }) end, "no input value")
expect_err("Kalman call in='-inf' 返回 ERR",
	function() return call({ ["in"] = "-inf" }) end, "no input value")

res = expect_ok("Kalman call in='50'", function() return call({ ["in"] = "50" }) end)
check("Kalman 输出为有限数值",
	res ~= nil and type(res.out) == "number" and res.out == res.out,
	res and tostring(res.out))

tester.summary("test_ema_kalman_driver")

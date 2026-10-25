-- test_multipath_layout.lua - 非缺省多路径布局冒烟（fix-plan 3-3 + 2026-09-20 阶段 2）
-- 背景：HAL.lua / virtbus.lua / drv_common.lua 定位 lib/bus_contract.lua、
-- lib/virtbus.lua 原先只取 BOT4CJ_MODULE_PATH 首段——多路径布局下首段没有
-- 对应文件时，HAL 引导直接失败、virt_prepare 误报 cannot load。现逐段探测。
-- 本用例以「首段不存在、次段为仓库 modules」的布局验证四处收敛：
--   1) virtbus.lua 可加载且带 bus_contract；
--   2) drv_common.virt_prepare 不再误报 cannot load（旧实现在此布局必失败，
--      是本次修复的判别性用例）；
--   3) 全部路径段都不存在时仍按原契约报 cannot load（fail 可诊断）；
--   4) HAL 聚合门面加载五个总线域后全局齐全（26.2 按域拆分的回归面）。
--
-- 【边界：驱动侧多路径由宿主保证（阶段 2）】驱动文件的第一行要找到
-- lib/mpath.lua 才能解析其它 lib——那一跳现在由宿主 sandbox_lua 完成
-- （注入全局 __mpath），驱动统一写成 `local mpath = __mpath or <单根回退>`。
-- 因此「多路径 + 真驱动加载」在 **mybot 运行期**成立，判别性用例是
-- run_all.sh hardening 段的 multipath_module_path（跑真二进制）。
-- 本文件是 luajit 直跑（没有宿主），回退分支只支持单根布局，故这里**不**断言
-- 「多路径下直跑 dofile 驱动」——那是回退分支的既有边界，不是缺陷。
--
-- 依赖 ffi 设环境变量（os.setenv 不存在）→ 仅 LuaJIT 可跑，run_all.sh 默认即 luajit。
-- 用法（项目根目录）: luajit test/test_multipath_layout.lua（run_all.sh 自动纳入）
local tester = dofile("test/lib/tester.lua")
local ffi = require("ffi")
ffi.cdef[[
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
]]

local function with_env(value, fn)
	local old = os.getenv("BOT4CJ_MODULE_PATH")
	ffi.C.setenv("BOT4CJ_MODULE_PATH", value, 1)
	local ok, err = pcall(fn)
	if old == nil then ffi.C.unsetenv("BOT4CJ_MODULE_PATH")
	else ffi.C.setenv("BOT4CJ_MODULE_PATH", old, 1) end
	if not ok then error(err, 0) end
end

-- 1) 首段不存在：virtbus 仍可加载，且拿到 bus_contract 单点
with_env("test/mpath_p2:./modules", function()
	local vbus = dofile("modules/lib/virtbus.lua")
	tester.check("多路径布局 virtbus 可加载", type(vbus) == "table")
	tester.check("virtbus 携带 bus_contract", type(vbus.bus_contract) == "table")
	tester.check("bus_contract 提供 byte_of", type(vbus.bus_contract.byte_of) == "function")
end)

-- 2) 判别性用例：旧实现在此布局 virt_prepare 必报 cannot load，现应成功
with_env("test/mpath_p2:./modules", function()
	dofile("modules/lib/drv_common.lua")
	-- 无 address/fd 的最小数据行：不走挂载，只验证 virtbus 定位与 inject 通路
	local why = virt_prepare({ proto = "virt", name = "smoke" })
	tester.check("virt_prepare 多路径布局成功（返回 nil）", why == nil)
	-- 还原全局 i2c_*/spi_*/uart_*，不给后续用例留下注入态
	if __BOT4CJ_VIRTBUS then __BOT4CJ_VIRTBUS.reset() end
end)

-- 3) 全部段都不存在：保持 cannot load 报错契约（可诊断、不静默）
with_env("test/mpath_p1:test/mpath_p2", function()
	dofile("modules/lib/drv_common.lua")
	local why = virt_prepare({ proto = "virt", name = "smoke" })
	tester.check("全段无 virtbus 报 cannot load", why == "cannot load lib/virtbus.lua")
end)

-- 4) 26.2 按域拆分后：HAL 变成聚合门面，五个总线域各一文件、由门面按
--    BOT4CJ_MODULE_PATH 逐段探测 lib/hal/*.lua 加载。本例钉的是**拆分本身的
--    回归面**：门面漏列某个域、或 ctx 少传一个共享上下文，都会让对应的总线
--    全局缺失——在非缺省路径布局下也要照常齐全。
--    上面 1)~3) 都不加载 HAL，故这里是本进程内 HAL 的首次真实加载。
--    注：逐段探测那一跳的判别性用例不在这里——门面带 `./modules` 兜底，
--    只取首段的坏形态会被兜底掩盖；真正的判据是 run_all.sh hardening 段的
--    multipath_module_path（跑真二进制 + 真沙箱，首段为不存在的路径），
--    与本文件 1)~3) 对 bus_contract/virtbus 的分工同理。
with_env("test/mpath_p2:./modules", function()
	local HAL = dofile("modules/lib/HAL.lua")
	tester.check("多路径布局 HAL 门面可加载", type(HAL) == "table")
	local missing = {}
	for _, n in ipairs({ "i2c_open", "i2c_read_reg16", "spi_open", "spi_xfer_full",
		"gpio_request_line", "uart_open", "uart_read", "pwm_config", "milli_sleep" }) do
		if type(_G[n]) ~= "function" then missing[#missing + 1] = n end
	end
	tester.check("五个总线域全局齐全（含 i2c 的 16 位指针段）",
		#missing == 0, table.concat(missing, ","))
	tester.check("uart 域的加载期探测已跑（UART_B_CONST 导出）",
		type(HAL.UART_B_CONST) == "table")
end)

tester.summary("test_multipath_layout")
return 0

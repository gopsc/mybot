-- test_virt_model_discovery.lua — 内嵌模型发现必须确定（D2-6 / F1-8）
--
-- 背景：drv_common.virt_prepare 用 `pairs(_G)` 后缀扫描找 `<DRIVER>_VIRT`，
-- 而 pairs 的遍历顺序不确定——同一 lua_State 里出现两个模型时「谁胜出」是
-- 随机的：挂错模型会让测试读到另一颗器件的寄存器语义（静默错位，比报错难查）。
-- 宿主的正常形态是一变量一 lua_State（只加载一个驱动），但测试/调试里
-- 「一个状态 dofile 两个驱动」是常见手滑。
--
-- 本文件钉住两个方向：
--   ① 正对照：单模型 → 发现成功（virt_prepare 返回 nil 且完成注入）；
--   ② 负路径：双模型 → 必须**明确报错并点名两个模型**，不静默取其一。
--
-- 依赖 LuaJIT（驱动 dofile HAL 时加载真 ffi 库；只做发现与内存挂载，不发真实 I/O）。
-- 用法（项目根目录）: luajit test/test_virt_model_discovery.lua（run_all.sh 自动纳入）
local tester = dofile("test/lib/tester.lua")
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- ---- ① 正对照：只加载一个带模型的驱动 ----
dofile("modules/BH1750.lua")	-- 定义 BH1750_VIRT，并加载 HAL/drv_common
tester.check("单模型：驱动已定义内嵌模型", type(BH1750_VIRT) == "table")

local why = virt_prepare({ proto = "virt", fd = 3, address = 0x23 })
tester.check("单模型：virt_prepare 不报错（发现成功）", why == nil, tostring(why))
tester.check("单模型：已完成虚拟注入", vbus._injected == true)

-- ---- ② 负路径：同一状态再载入第二个带模型的驱动 ----
vbus._injected = false	-- 复位重入口，让发现逻辑真的再跑一遍（注入本身不参与本断言）
dofile("modules/ADXL345.lua")
tester.check("双模型：第二个模型已就位", type(ADXL345_VIRT) == "table")

why = virt_prepare({ proto = "virt", fd = 3, address = 0x23 })
tester.check("双模型：virt_prepare 必须明确报错（不静默取其一）", why ~= nil,
	tostring(why))
if why ~= nil then
	tester.check("双模型：报错点名两个模型",
		why:find("BH1750_VIRT", 1, true) ~= nil and why:find("ADXL345_VIRT", 1, true) ~= nil,
		tostring(why))
end

vbus.restore()
tester.summary("test_virt_model_discovery")
return 0

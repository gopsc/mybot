-- test_virtbus_bh1750.lua - 真实驱动在虚拟总线上的链路回归（issue #18）
-- 用 virtbus 虚拟 I2C 总线 + 内嵌模型（modules/BH1750.lua 尾部 BH1750_VIRT，
-- 2026-09-15 自 virtbus/bh1750.lua 迁入）加载【真实】BH1750 驱动，
-- 无真机完成：
--   build（PowerOn + 模式命令）→ call（读照度换算 LUX）→ destroy（PowerDown），
--   并覆盖故障路径：模型注入 NACK（器件掉线）、地址不在总线（无器件负路径）。
-- 依赖：LuaJIT（BH1750 dofile HAL 时加载真 ffi 库；milli_sleep 走真 usleep，
--       无硬件副作用）。
-- 用法（项目根目录，LuaJIT）: luajit test/test_virtbus_bh1750.lua（run_all.sh 自动纳入）
local tester = dofile("test/lib/tester.lua")
local vbus = dofile("modules/lib/virtbus.lua")
vbus.reset()

-- 模型内嵌于驱动文件（BH1750_VIRT 全局工厂）：load_driver 完成驱动定义与
-- 重注入后，从全局取工厂建实例再挂载——建实例/挂载不依赖注入顺序
vbus.load_driver("modules/BH1750.lua")

-- 虚拟 BH1750（地址 0x23）：0x7530 → mode H 下 25000 lux
local light = BH1750_VIRT.new({ count = 30000 })
vbus.attach("bh1750@0x23", 0x23, light)

-- build：应在位判定成功（PowerOn 0x01 / 连续 H 0x10 写成功）
local fd = i2c_open("/dev/i2c-1")
local res = build({ fd = fd, address = 0x23, mode = "H" })
tester.check("build 在位判定成功返回 OK", tostring(res.result) == "OK")
tester.check("build 发出 PowerOn 命令 0x01", light.cmds[1] == 0x01)
tester.check("build 发出连续 H 命令 0x10", light.cmds[2] == 0x10)
tester.check("模型解释上电+连续 H 状态",
	light.state.power == true and light.state.mode == "H" and light.state.once == false)

-- call：读回 0x7530 → LUX = count/1.2 = 25000（纯读不产生命令写）
light:clear_cmds()
res = call({ fd = fd, address = 0x23, mode = "H" })
tester.check("call 返回 OK", tostring(res.result) == "OK")
tester.check("call 照度换算正确 (30000/1.2)", math.abs(res.LUX - 25000) < 1e-6)
tester.check("纯读测量值不产生命令写", #light.cmds == 0)

-- 动态改读数：set_count 后驱动应读到新值
light:set_count(1200)
res = call({ fd = fd, address = 0x23, mode = "H" })
tester.check("set_count 后读到新照度 (1200/1.2=1000)",
	tostring(res.result) == "OK" and math.abs(res.LUX - 1000) < 1e-6)

-- 故障注入：模型 NACK 模拟器件掉线，驱动 call 应显式 ERR
light:set_count(30000)
light.nack = true
res = call({ fd = fd, address = 0x23, mode = "H" })
tester.check("器件 NACK 时 call 显式 ERR", tostring(res.result) == "ERR")
light.nack = false
res = call({ fd = fd, address = 0x23, mode = "H" })
tester.check("撤销 NACK 后恢复 OK", tostring(res.result) == "OK")

-- destroy：发 PowerDown 0x00
light:clear_cmds()
res = destroy({ fd = fd, address = 0x23 })
tester.check("destroy 返回 OK", tostring(res.result) == "OK")
tester.check("destroy 发出 PowerDown 0x00", light.cmds[#light.cmds] == 0x00)
tester.check("模型解释掉电状态", light.state.power == false)

-- 负路径：地址不在总线（0x50 无器件）→ build 写 NACK → 显式 ERR
res = build({ fd = fd, address = 0x50, mode = "H" })
tester.check("地址无器件 build 显式 ERR", tostring(res.result) == "ERR")

-- virt_tick 合成波形（守护 proto=virt 每拍造数）：钉值 + 回卷 + 经真实驱动出浮点
light:clear_cmds()
light:virt_tick(0)
tester.check("virt_tick(0) 相位中点 count=15002", light.count == 15002)
light:virt_tick(8)
tester.check("virt_tick(8) 波峰 count=18002", light.count == 18002)
light:virt_tick(24)
tester.check("virt_tick(24) 波谷 count=12002", light.count == 12002)
light:virt_tick(32)
tester.check("virt_tick 32 拍回卷与 0 拍同值", light.count == 15002)
res = call({ fd = fd, address = 0x23, mode = "H" })
tester.check("tick 造数经真实驱动换算 LUX=15002/1.2",
	tostring(res.result) == "OK" and math.abs(res.LUX - 15002 / 1.2) < 1e-6)
tester.check("相位中点拍 LUX 带小数（15002 非 6 的倍数）", res.LUX ~= math.floor(res.LUX))
tester.check("波峰波谷同样除不尽（整数相位无 6 的倍数）",
	(18002 % 6 ~= 0) and (12002 % 6 ~= 0))
tester.check("virt_tick 只造测量值、零命令写", #light.cmds == 0)
light:reset(30000)
tester.check("reset 回注入初值", light.count == 30000 and #light.cmds == 0)

i2c_close(fd)
vbus.restore()

tester.summary("test_virtbus_bh1750")
return 0

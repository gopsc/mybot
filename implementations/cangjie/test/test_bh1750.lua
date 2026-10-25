-- BH1750.lua 离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_bh1750.lua（BH1750 依赖 HAL 的 ffi，需 LuaJIT）
--
-- mock 方式：先 dofile 驱动（连带加载真 HAL），再把驱动用到的 HAL 全局替换为桩。
-- 驱动在 build/call 时才解析全局名，后注桩生效（test_pca9685_channel 踩过的坑）。
--
-- 覆盖点（对照 modules/BH1750.lua 当前实现）：
--   1. build：命令序列（Power On -> 可选 MTreg -> 模式命令）、mode/once/mtreg
--      列解析与钳制、一帧等待、在位判定（写失败即 ERR）、错误通道；
--   2. call：纯读 2 字节（非指针读）、按档位/MTreg 的 LUX 换算、单次模式
--      先发命令再等待、读写失败错误通道；
--   3. destroy：Power Down 成功、写失败不致命、错误通道。

dofile("modules/BH1750.lua")

-- ==================== 桩与设备模型 ====================
-- 后注桩（先定义会被 HAL 真函数覆盖）。writes 记录单字节命令序列；
-- read_val 控制 i2c_read 返回的大端合并值。
local writes = {}
local set_addr_log = {}
local sleep_total = 0
local read_val = 0
local fail_write = false
local fail_read = false
local set_addr_ok = true

function i2c_set_addr(fd, addr)
	set_addr_log[#set_addr_log + 1] = addr
	return set_addr_ok
end

function i2c_write_multi(fd, cmd, ...)
	if fail_write then return -1 end
	writes[#writes + 1] = { cmd = cmd, extra = { ... } }
	return 0
end

function i2c_read(fd, n)
	if fail_read then return -1 end
	return read_val
end

function milli_sleep(ms) sleep_total = sleep_total + ms end

-- ==================== 命令常量（与驱动一致） ====================
local CMD_POWER_DOWN = 0x00
local CMD_POWER_ON   = 0x01
local CMD_CONT_H     = 0x10
local CMD_CONT_H2    = 0x11
local CMD_CONT_L     = 0x13
local CMD_ONCE_H     = 0x20
local CMD_ONCE_H2    = 0x21
local CMD_ONCE_L     = 0x23
local CMD_MT_HIGH    = 0x40
local CMD_MT_LOW     = 0x60

local base = { fd = 3, address = "0x23" }
local near = function(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ==================== 断言辅助（共享测试框架） ====================
local tester = dofile("test/lib/tester.lua")
local check, expect_ok = tester.check, tester.expect_ok
local expect_err, expect_cmds = tester.expect_err, tester.expect_cmds

-- 期望命令序列：cmd_log 与 expect 逐条比对（expect 为 {cmd} 列表，单字节命令）
-- 注：expect_cmds 第 2 参为当前命令记录表 writes（共享库不持有测试私有的桩日志）

-- ==================== build：默认与档位 ====================
writes = {}; sleep_total = 0; set_addr_log = {}
expect_ok("build 默认 (mode=H 连续, mtreg=69)", function() return build(base) end)
expect_cmds("build 命令序列 PowerOn + ContH(0x01,0x10)", writes, { CMD_POWER_ON, CMD_CONT_H })
check("set_addr 收到 0x23=35", #set_addr_log > 0 and set_addr_log[#set_addr_log] == 0x23,
	tostring(set_addr_log[#set_addr_log]))
check("build 等一帧 H(120ms)", sleep_total == 120, tostring(sleep_total))

writes = {}; sleep_total = 0
expect_ok("build mode=H2", function() return build({ fd = 3, address = "0x23", mode = "H2" }) end)
expect_cmds("build H2 用 ContH2(0x11)", writes, { CMD_POWER_ON, CMD_CONT_H2 })
check("build H2 等一帧 120ms", sleep_total == 120, tostring(sleep_total))

writes = {}; sleep_total = 0
expect_ok("build mode=L", function() return build({ fd = 3, address = "0x23", mode = "L" }) end)
expect_cmds("build L 用 ContL(0x13)", writes, { CMD_POWER_ON, CMD_CONT_L })
check("build L 等一帧 16ms", sleep_total == 16, tostring(sleep_total))

-- 单次模式列取值：once=1 / once=true
writes = {}; sleep_total = 0
expect_ok("build once='1'", function() return build({ fd = 3, address = "0x23", once = "1" }) end)
expect_cmds("build 单次 H 用 OnceH(0x20)", writes, { CMD_POWER_ON, CMD_ONCE_H })
check("build 单次也等一帧(首发有效)", sleep_total == 120, tostring(sleep_total))

writes = {}; sleep_total = 0
expect_ok("build once='true' H2", function() return build({ fd = 3, address = "0x23", mode = "H2", once = "true" }) end)
expect_cmds("build 单次 H2 用 OnceH2(0x21)", writes, { CMD_POWER_ON, CMD_ONCE_H2 })

-- ==================== build：MTreg ====================
-- mtreg=100：命令 = 0x40|(100>>5)&7 = 0x43，0x60|(100&0x1F) = 0x64
writes = {}; sleep_total = 0
expect_ok("build mtreg=100 (H 连续)", function() return build({ fd = 3, address = "0x23", mtreg = "100" }) end)
expect_cmds("build MTreg 命令对 0x43,0x64 夹在 PowerOn 与模式之间", writes, { CMD_POWER_ON, 0x43, 0x64, CMD_CONT_H })
check("build 等一帧按 mtreg 归一 (H: 120*100/69 ≈ 173.9ms)",
	math.abs(sleep_total - 120 * 100 / 69) < 1e-6, string.format("%.1f", sleep_total))

writes = {}; sleep_total = 0
expect_ok("build mtreg=30 钳制到 31", function() return build({ fd = 3, address = "0x23", mtreg = "30" }) end)
-- 31>>5 = 0 -> 0x40；31&0x1F = 31 -> 0x60|31 = 0x7F
expect_cmds("build mtreg 钳制下限 31 -> 0x40,0x7F", writes, { CMD_POWER_ON, 0x40, 0x7F, CMD_CONT_H })

writes = {}; sleep_total = 0
expect_ok("build mtreg=300 钳制到 254", function() return build({ fd = 3, address = "0x23", mtreg = "300" }) end)
-- 254>>5 = 7 -> 0x47；254&0x1F = 30 -> 0x60|30 = 0x7E
expect_cmds("build mtreg 钳制上限 254 -> 0x47,0x7E", writes, { CMD_POWER_ON, 0x47, 0x7E, CMD_CONT_H })

-- ==================== build：错误通道 ====================
expect_err("build 非法 mode", function() return build({ fd = 3, address = "0x23", mode = "X" }) end, "Invalid mode")
fail_write = true
expect_err("build 上电写失败", function() return build(base) end, "power on failed")
fail_write = false
set_addr_ok = false
expect_err("build set_addr 失败", function() return build(base) end, "set_addr failed")
set_addr_ok = true
expect_err("build 缺 fd", function() return build({ address = "0x23" }) end, "Invalid Argument")
expect_err("build 缺 address", function() return build({ fd = 3 }) end, "Invalid Argument")
expect_err("build 参数非表", function() return build(nil) end, "Invalid Arguments Type")

-- ==================== call：LUX 换算（含 MTreg 归一） ====================
-- H 档 mtreg=69：LUX = count/1.2
expect_ok("call 前置 build (H)", function() return build(base) end)
read_val = 0x0DC2		-- 3522
local res = expect_ok("call 读 0x0DC2", function() return call(base) end)
check("H 档 LUX = count/1.2 = 2935", res and near(res.LUX, 3522 / 1.2, 1e-6), tostring(res and res.LUX))

-- H2：LUX = count/2.4
expect_ok("call 前置 build (H2)", function() return build({ fd = 3, address = "0x23", mode = "H2" }) end)
res = expect_ok("call H2", function() return call(base) end)
check("H2 档 LUX = count/2.4 = 1467.5", res and near(res.LUX, 3522 / 2.4, 1e-6), tostring(res and res.LUX))

-- L：LUX = count/0.3
expect_ok("call 前置 build (L)", function() return build({ fd = 3, address = "0x23", mode = "L" }) end)
res = expect_ok("call L", function() return call(base) end)
check("L 档 LUX = count/0.3 = 11740", res and near(res.LUX, 3522 / 0.3, 1e-6), tostring(res and res.LUX))

-- MTreg 归一：H mtreg=100，LUX = count*69/(1.2*100)
expect_ok("call 前置 build (H mtreg=100)", function() return build({ fd = 3, address = "0x23", mtreg = "100" }) end)
res = expect_ok("call mtreg=100", function() return call(base) end)
check("MTreg 比例换算 LUX=count*69/120≈2025.15", res and near(res.LUX, 3522 * 69 / 120, 1e-6),
	tostring(res and res.LUX))

-- 满量程：H 档 count=65535 -> 54612.5 lx
expect_ok("call 前置 build (H)", function() return build(base) end)
read_val = 0xFFFF
res = expect_ok("call 满量程", function() return call(base) end)
check("H 档满量程 LUX≈54612.5", res and near(res.LUX, 65535 / 1.2, 1e-3), tostring(res and res.LUX))

-- 零光照
read_val = 0x0000
res = expect_ok("call 零光照", function() return call(base) end)
check("零光照 LUX=0", res and res.LUX == 0, tostring(res and res.LUX))

-- ==================== call：单次模式 + 错误通道 ====================
-- 单次模式：call 每拍先发单次命令 + 等一帧再纯读
writes = {}; sleep_total = 0
expect_ok("call 前置 build (H2 once)", function() return build({ fd = 3, address = "0x23", mode = "H2", once = "1" }) end)
read_val = 0x0DC2
writes = {}; sleep_total = 0		-- 只统计 call 本身的命令与等待
res = expect_ok("call 单次 H2", function() return call(base) end)
expect_cmds("单次 call 先发 OnceH2(0x21)", writes, { CMD_ONCE_H2 })
check("单次 call 等一帧 120ms", sleep_total == 120, tostring(sleep_total))
check("单次 H2 LUX=1467.5", res and near(res.LUX, 3522 / 2.4, 1e-6), tostring(res and res.LUX))

fail_read = true
expect_err("call 读失败", function() return call(base) end, "read measurement failed")
fail_read = false

expect_err("call 缺 fd", function() return call({ address = "0x23" }) end, "Invalid Argument")
expect_err("call 缺 address", function() return call({ fd = 3 }) end, "Invalid Argument")
expect_err("call 参数非表", function() return call("x") end, "Invalid Arguments Type")

-- ==================== destroy ====================
writes = {}
expect_ok("destroy 正常", function() return destroy(base) end)
expect_cmds("destroy 发 PowerDown(0x00)", writes, { CMD_POWER_DOWN })
fail_write = true
expect_ok("destroy 写失败不致命", function() return destroy(base) end)
fail_write = false
expect_err("destroy 缺 fd", function() return destroy({ address = "0x23" }) end, "Invalid Argument")
expect_err("destroy 参数非表", function() return destroy(nil) end, "Invalid Arguments Type")

-- ==================== 汇总 ====================
tester.summary()
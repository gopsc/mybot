-- PCA9685.lua 写失败错误路径离线测试（桩替身，不触碰真实 I2C）
-- 背景：build/call/destroy 曾不检查 i2c_write_reg/i2c_write_multi 返回值，
--       总线断开时仍返回 OK，halt-on-error 链路对执行器失效
-- 用法: luajit test_pca9685_writefail.lua（PCA9685 依赖 HAL，需 LuaJIT 的 ffi）

local fail_write = false
local writes = {}

dofile("modules/PCA9685.lua")

-- 桩：驱动加载后替换 HAL 全局（驱动在 call 时才解析全局名，后注桩才生效）
function i2c_set_addr(fd, addr) return true end
function i2c_write_reg(fd, reg, val)
	if fail_write then return false end
	writes[#writes + 1] = { reg = reg, val = val }
	return true
end
function i2c_write_multi(fd, reg, ...)
	if fail_write then return -1 end
	local bytes = {...}
	for i, b in ipairs(bytes) do
		writes[#writes + 1] = { reg = reg + i - 1, val = b }
	end
	return 0
end
function i2c_read_reg(fd, reg) return 0 end
function milli_sleep(ms) end

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 result_of/成败分支曾自成一套）
local tester = dofile("test/lib/tester.lua")
local result_of = tester.result_of

local function expect_err(label, fn, msgpat)
	writes = {}
	local ok, res = pcall(fn)
	local msg = type(res) == "table" and tostring(res.message) or tostring(res)
	tester.check(string.format("%-26s message=%s", label, msg),
		result_of(ok, res) == "ERR" and msg:find(msgpat, 1, true) ~= nil
			and #writes <= 1,	-- 失败即返回，不得继续写后续寄存器
		string.format("result=%s writes=%d", result_of(ok, res), #writes))
end

local base = { fd = 3, address = "0x40" }

fail_write = true
expect_err("build 首笔写失败 -> ERR", function() return build(base) end, "MODE1")
expect_err("call PWM 写失败 -> ERR",
	function() return call({ fd = 3, address = "0x40", channel = 6, angle = 45 }) end,
	"PWM registers")
-- destroy 写失败（M3，2026-09-23 起）：尽力释放、静默 OK——重启写不动不算失败，
-- 「资源不可用即静默成功」（drv_common.lua 约定；本期望随 M3 从 ERR 改为 OK，
-- 2026-09-24 对齐）。仍断言至多一笔写（失败即止，不重复轰总线）。
do
	writes = {}
	local ok, res = pcall(function() return destroy(base) end)
	tester.check(string.format("%-26s message=%s", "destroy 写失败 -> OK(M3)",
			type(res) == "table" and tostring(res.message) or tostring(res)),
		result_of(ok, res) == "OK" and #writes <= 1,
		string.format("result=%s writes=%d", result_of(ok, res), #writes))
end
-- destroy 非表入参（D2-1 调和，2026-09-24）：返 ERR 不抛错、也不静默成功
do
	local ok, res = pcall(function() return destroy(nil) end)
	tester.check("destroy 非表入参 -> ERR(D2-1)",
		result_of(ok, res) == "ERR",
		string.format("ok=%s result=%s", tostring(ok), result_of(ok, res)))
end
fail_write = false

tester.summary("pca9685_writefail")

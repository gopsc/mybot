-- PCA9685.lua 浮点角度兼容性离线测试（桩替身，不触碰真实 I2C）
-- 用法: luajit test_pca9685_float.lua（PCA9685 依赖 HAL 的 ffi，需 LuaJIT）
-- 校验点：合法角度恰写 4 个寄存器且 OFF 值与换算一致；越界角度限幅到 0~180

local writes = {}

dofile("modules/PCA9685.lua")

-- 桩：驱动加载后替换 HAL 全局。HAL 迁移（issue #14）后驱动 dofile 自带真实现，
-- 先注桩会被 HAL 的真函数覆盖；驱动在 call 时才解析全局名，后注桩才生效
function i2c_set_addr(fd, addr) return true end
function i2c_write_reg(fd, reg, val) writes[#writes + 1] = {reg = reg, val = val} end
-- call() 已改为单次 i2c_write_multi 原子写（AI 自增），按字节展开记录保持断言形态
function i2c_write_multi(fd, reg, ...)
	local bytes = {...}
	for i, b in ipairs(bytes) do
		writes[#writes + 1] = {reg = reg + i - 1, val = b}
	end
	return 0
end
function i2c_read_reg(fd, reg) return 0 end
function milli_sleep(ms) end

-- F4/N-33：断言收敛到 test/lib/tester.lua（本地 fails/成败分支曾自成一套）
local tester = dofile("test/lib/tester.lua")

-- 驱动同款换算：offval = floor((0.5 + 2.0*angle/180) * 4096 / 20)，入参先限幅
local function expect_offval(angle)
	local a = angle
	if a < 0 then a = 0 end
	if a > 180 then a = 180 end
	return math.floor((0.5 + 2.0 * a / 180.0) * 4096.0 / 20.0)
end

local function try(label, data)
	writes = {}
	local ok, res = pcall(call, data)
	if not ok then
		tester.check(label, false, "call error: " .. tostring(res))
		return
	end
	-- 取出 OFF 寄存器低两字节（reg+2, reg+3）合成 offval
	local offval = nil
	for _, w in ipairs(writes) do
		if w.reg == 0x06 + 4 * 6 + 2 then offval = w.val end
		if w.reg == 0x06 + 4 * 6 + 3 and offval then offval = offval + w.val * 256 end
	end
	local want = expect_offval(tonumber(data.angle))
	tester.check(string.format("%-28s writes=%d offval=%s", label, #writes, tostring(offval)),
		offval == want and #writes == 4,
		string.format("want offval=%s writes=4", tostring(want)))
end

-- 1) 数字角度（@Action 参数经 parseMt 为 JsonFloat，整数/浮点同路）
try("integer angle=45",        {fd = 3, address = "0x40", channel = 6, angle = 45})

-- 2) 字符串角度（结构脚本元数据侧全为字符串，保持兼容）
try("string angle='45'",       {fd = 3, address = "0x40", channel = "6", angle = "45"})
try("string angle='44.7'",     {fd = 3, address = "0x40", channel = "6", angle = "44.7"})

-- 3) 浮点数字角度（!32 类型保真后 Servo 返回的实际形态）
try("float angle=44.7",        {fd = 3, address = "0x40", channel = 6, angle = 44.7})

-- 4) 越界角度（驱动边界应限幅到 0~180，offval 落在 102~512）
try("string angle='250'",      {fd = 3, address = "0x40", channel = "6", angle = "250"})
try("string angle='-30'",      {fd = 3, address = "0x40", channel = "6", angle = "-30"})

-- 5) 非有限角度（审计 P3）：必须按 ERR 契约返回，且**一个寄存器都不写**。
-- 旧实现里 NaN 会穿过 `angle<0` / `>180` 两道限幅（NaN 比较恒假），一路走到
-- bitcompat 的守卫抛 Lua error——末梢兜住了（不会写出坏脉宽）但炸在错误的层：
-- 宿主收到的是异常而不是 ERR 契约，排障看不出是入参问题。
-- 用 pcall 包住：驱动若退回"抛错"形态，这里是一条带原因的失败，而非文件中止。
local function try_reject(label, angle)
	writes = {}
	local ok, res = pcall(call, {fd = 3, address = "0x40", channel = "6", angle = angle})
	tester.check(label .. " → ERR 且零总线事务",
		ok and type(res) == "table" and res.result == "ERR" and #writes == 0,
		ok and string.format("result=%s writes=%d", tostring(res and res.result), #writes)
			or ("raised: " .. tostring(res)))
end
try_reject("angle='nan'", "nan")
try_reject("angle='inf'", "1e400")
try_reject("angle='-inf'", "-1e400")
try_reject("angle 缺失", nil)

tester.summary("pca9685_float")

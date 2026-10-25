-- PWM 离线单元测试
-- 分两层，均不触硬件：
--   1) HAL 段：mock HAL.sys.* 记录 sysfs 写入，验证路径、数值与写序
--   2) 驱动层：桩替换全局 pwm_* 函数，验证 build/call/destroy 的参数与契约
-- 用法（项目根目录）: luajit test/test_pwm.lua

-- GC 压力护栏：本套件曾因 sysfs_write 的 ffi 缓冲越界 1 字节（写坏相邻
-- GC 对象头）出现概率性段错误，崩溃点离出错写操作很远、正常跑约 50% 复现。
-- 最激进 GC 节奏让这类潜伏的堆/ffi 越界在当次测试内必然暴露（修复前 100% 崩）。
collectgarbage("setpause", 1)
collectgarbage("setstepmul", 100000)

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local ffi = require("ffi")
local HAL = dofile("modules/lib/HAL.lua")

------------------------------------------------------------------
-- 第一层：HAL 段（mock 系统调用层）
------------------------------------------------------------------
local log = {}		-- {{op="open"/"write", path=, data=}}
local deny = {}		-- path -> true 表示 open 失败（模拟节点不存在）
local mock_npwm = "2\n"	-- npwm 属性内容（默认双通道）

HAL.sys.open = function(path, flags)
	log[#log + 1] = { op = "open", path = path, flags = flags }
	if deny[path] then return -1 end
	return 7
end
HAL.sys.close = function(fd) return 0 end
HAL.sys.write = function(fd, buf, n)
	local data = ffi.string(buf, n)
	log[#log + 1] = { op = "write", data = data }
	-- 模拟内核副作用：写 export 后通道节点出现，写 unexport 后消失。
	-- 否则 pwm_export 收尾的存在性复检永远失败（首次导出用例会假红）。
	-- sysfs_write 恒为 open→write，故本条的前一条即目标路径。
	local prev = log[#log - 1]
	if prev ~= nil and prev.op == "open" and type(prev.path) == "string" then
		local c = prev.path:match("^/sys/class/pwm/pwmchip(%d+)/export$")
		if c ~= nil then
			-- 越界通道号：内核静默忽略，目录不会生成（用于越界诊断用例）
			local nch = tonumber(mock_npwm) or 2
			if (tonumber(data) or -1) < nch then
				deny["/sys/class/pwm/pwmchip" .. c .. "/pwm" .. data .. "/enable"] = nil
			end
		else
			local u = prev.path:match("^/sys/class/pwm/pwmchip(%d+)/unexport$")
			if u ~= nil then
				deny["/sys/class/pwm/pwmchip" .. u .. "/pwm" .. data .. "/enable"] = true
			end
		end
	end
	return n
end
HAL.sys.errno = function() return 0 end
HAL.sys.read = function(fd, buf, n)
	-- 仅 npwm 用到：把预设内容拷进缓冲区。显式给 #s：内核 read 只回填
	-- 实际字节、不加 NUL（ffi.copy 省略 len 且源是 Lua 字符串时会多拷
	-- 一个结尾 NUL；这里目标缓冲固定 16B 当前安全，显式 len 更忠实）。
	local s = mock_npwm
	if #s > n then s = s:sub(1, n) end
	ffi.copy(buf, s, #s)
	return #s
end

-- 取写入序列：{{path=, data=}}（sysfs_write 恒为 open→write，故写的前一条即其路径）
local function seq()
	local out = {}
	for i, e in ipairs(log) do
		if e.op == "write" then
			out[#out + 1] = { path = (log[i - 1] or {}).path, data = e.data }
		end
	end
	return out
end

local function reset(exported)
	log = {}
	deny = {}
	if not exported then
		deny["/sys/class/pwm/pwmchip0/pwm1/enable"] = true
	end
end

local CHIP, CH = 0, 1
local BASE = "/sys/class/pwm/pwmchip0/pwm1"

-- 未导出时 export 写通道号
reset(false)
check("export: 写入通道号到 export", pwm_export(CHIP, CH) == true)
do
	local s = seq()
	check("export: 仅一次写且路径正确",
		#s == 1 and s[1].path == "/sys/class/pwm/pwmchip0/export" and s[1].data == "1",
		s[1] and (s[1].path .. " <- " .. s[1].data))
end

-- 已导出时不重复 export（重复写会被内核 EINVAL 拒绝）
reset(true)
check("export: 已导出则幂等", pwm_export(CHIP, CH) == true)
check("export: 已导出不产生写入", #seq() == 0)

-- 通道数读取与越界诊断（内核对越界通道静默忽略，必须靠 npwm 提示）
reset(true)
check("npwm: 读取通道数", pwm_npwm(CHIP) == 2, tostring(pwm_npwm(CHIP)))
reset(false)
mock_npwm = "1\n"
check("export: 通道越界时失败（npwm=1 却要 pwm1）", pwm_export(CHIP, 1) == false)
mock_npwm = "2\n"

-- 把 channel 误填成 GPIO 引脚号（如 17）必须被前置校验拦下，
-- 而不是等内核回一个无法自解释的 EINVAL
reset(false)
deny["/sys/class/pwm/pwmchip0/pwm17/enable"] = true
check("export: channel 填引脚号(17)被前置拦截", pwm_export(CHIP, 17) == false)

-- 频率/占空比 → ns 换算与写序
reset(true)
local ok, period_ns, duty_ns = pwm_config(CHIP, CH, 20000, 50)
check("config: 成功", ok == true)
check("config: period_ns = 1e9/20000 = 50000", period_ns == 50000, period_ns)
check("config: duty_ns = 50% = 25000", duty_ns == 25000, duty_ns)
do
	local s = seq()
	check("config: 写序为 duty=0 → period → duty",
		#s == 3
		and s[1].path == BASE .. "/duty_cycle" and s[1].data == "0"
		and s[2].path == BASE .. "/period"     and s[2].data == "50000"
		and s[3].path == BASE .. "/duty_cycle" and s[3].data == "25000",
		#s)
end

-- 占空比 100% 时 duty_ns 钳到 period（内核不允许 duty > period）
reset(true)
ok, period_ns, duty_ns = pwm_config(CHIP, CH, 1000, 100)
check("config: duty=100% 钳到 period", ok and duty_ns == period_ns, duty_ns .. "/" .. period_ns)

-- 非法参数
reset(true)
check("config: 频率 0 被拒", pwm_config(CHIP, CH, 0, 50) == false)
reset(true)
check("config: 负频率被拒", pwm_config(CHIP, CH, -1, 50) == false)
reset(true)
check("config: duty>100 被拒", pwm_config(CHIP, CH, 1000, 101) == false)
reset(true)
check("config: duty<0 被拒", pwm_config(CHIP, CH, 1000, -1) == false)

-- 路径穿越防护：chip/channel 必须是非负整数
reset(true)
check("安全: 拒绝 chip 路径穿越", pwm_config("../..", CH, 1000, 50) == false)
reset(true)
check("安全: 拒绝 channel 小数", pwm_config(CHIP, "1.5", 1000, 50) == false)
reset(true)
check("安全: 拒绝 channel 负数", pwm_config(CHIP, "-1", 1000, 50) == false)

-- 使能与极性
reset(true)
check("enable: 写 1", pwm_enable(CHIP, CH, true) == true)
check("enable: 写入内容正确", seq()[1].data == "1")
reset(true)
pwm_enable(CHIP, CH, false)
check("enable: 关闭写 0", seq()[1].data == "0")
reset(true)
pwm_set_polarity(CHIP, CH, true)
check("polarity: inversed", seq()[1].data == "inversed")
reset(true)
pwm_set_polarity(CHIP, CH, false)
check("polarity: normal", seq()[1].data == "normal")

-- 取消导出：先停输出再 unexport
reset(true)
check("unexport: 成功", pwm_unexport(CHIP, CH) == true)
do
	local s = seq()
	check("unexport: 先 enable=0 再写 unexport",
		#s == 2 and s[1].path == BASE .. "/enable" and s[1].data == "0"
		and s[2].path == "/sys/class/pwm/pwmchip0/unexport" and s[2].data == "1",
		#s)
end

------------------------------------------------------------------
-- 第二层：驱动层（桩替换全局 pwm_*）
------------------------------------------------------------------
local plog = {}		-- 记录驱动对 HAL 的调用

pwm_export = function(c, h) plog[#plog + 1] = { op = "export", c = c, h = h }; return true end
pwm_unexport = function(c, h) plog[#plog + 1] = { op = "unexport", c = c, h = h }; return true end
pwm_enable = function(c, h, on) plog[#plog + 1] = { op = "enable", c = c, h = h, on = on }; return true end
pwm_set_polarity = function(c, h, inv) plog[#plog + 1] = { op = "polarity", inv = inv }; return true end
pwm_config = function(c, h, f, d)
	plog[#plog + 1] = { op = "config", c = c, h = h, f = f, d = d }
	return true, math.floor(1e9 / f), math.floor(1e9 / f * d / 100)
end

-- 重新加载驱动（模块级状态按实例隔离，重 dofile 等价于新建硬件变量）
local function reload()
	plog = {}
	dofile("modules/PWM.lua")
end

local function last(op)
	for i = #plog, 1, -1 do
		if plog[i].op == op then return plog[i] end
	end
	return nil
end

local function count(op)
	local n = 0
	for _, e in ipairs(plog) do if e.op == op then n = n + 1 end end
	return n
end

-- 参数校验（负路径）
reload()
local r = build("x")
check("build: 参数非表时报错", r.result == "ERR")
check("build: 缺 chip 报错", build({ channel = "1" }).result == "ERR")
check("build: 缺 channel 报错", build({ chip = "0" }).result == "ERR")
check("build: 频率非法报错", build({ chip = "0", channel = "1", frequency = "0" }).result == "ERR")
check("build: duty 越界报错", build({ chip = "0", channel = "1", duty = "150" }).result == "ERR")

-- 正常 build：给了 duty 才使能
reload()
r = build({ chip = "0", channel = "1", frequency = "20000", duty = "0" })
check("build: 成功", r.result == "OK", r.message)
check("build: 导出 chip0/pwm1",
	last("export") ~= nil and last("export").c == 0 and last("export").h == 1)
check("build: 按给定频率配置", (last("config") or {}).f == 20000)
check("build: 给了 duty 则使能", count("enable") == 1 and last("enable").on == true)

-- 未给 duty：只配频率，不上电输出
reload()
r = build({ chip = "0", channel = "1", frequency = "20000" })
check("build: 无 duty 也成功", r.result == "OK", r.message)
check("build: 无 duty 不使能", count("enable") == 0)
check("build: 无 duty 时占空比为 0", (last("config") or {}).d == 0)

-- invert
reload()
build({ chip = "0", channel = "1", frequency = "20000", duty = "0", invert = "1" })
check("build: invert='1' 设置反相", (last("polarity") or {}).inv == true)

-- call：设占空比
reload()
build({ chip = "0", channel = "1", frequency = "20000", duty = "0" })
r = call({ duty = "50" })
check("call: 成功", r.result == "OK", r.message)
check("call: duty 传至 HAL", last("config").d == 50)
check("call: 返回值含 ns", r.period_ns == 50000 and r.duty_ns == 25000,
	tostring(r.duty_ns) .. "/" .. tostring(r.period_ns))
check("call: 已使能后不重复 enable", count("enable") == 1)

-- call：value 作为 duty 别名
reload()
build({ chip = "0", channel = "1", frequency = "20000" })
r = call({ value = "75" })
check("call: value 别名生效", r.result == "OK" and last("config").d == 75, r.message)
check("call: 首帧自动使能", count("enable") == 1 and last("enable").on == true)

-- call：controller 转发场景不带 duty 时沿用上次
reload()
build({ chip = "0", channel = "1", frequency = "20000", duty = "40" })
r = call({})
check("call: 无参数沿用上次占空比", r.result == "OK" and last("config").d == 40, r.message)

-- call：越界与未初始化
reload()
build({ chip = "0", channel = "1", frequency = "20000" })
check("call: duty 越界报错", call({ duty = "150" }).result == "ERR")
reload()
check("call: 未 build 报错", call({ duty = "50" }).result == "ERR")

-- destroy
reload()
build({ chip = "0", channel = "1", frequency = "20000", duty = "0" })
r = destroy({})
check("destroy: 成功", r.result == "OK", r.message)
check("destroy: 取消导出", count("unexport") == 1)
-- 注：「unexport 前先 enable=0」是 HAL 内部职责，已在第一层断言；
-- 这里 pwm_unexport 被桩替换，驱动层只需确认它被调用。

tester.summary("test_pwm")

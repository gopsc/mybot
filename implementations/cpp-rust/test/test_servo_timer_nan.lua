-- test_servo_timer_nan.lua —— 非有限值防线回归（Servo / Timer）
--
-- 背景（审计 2026-09-20 · 中）：Lua 里只有 nil/false 为假，而 NaN 与任何数比较
-- 恒为 false，于是 `x < 0` / `x > 180` 这类区间判定对 NaN **全部放行**。这一族
-- 缺陷此前无任何离线覆盖（grep 证实全仓没有测试传入过 "nan"/"inf"/"1e400"），
-- 且本仓库两个被点名的驱动 test/ 下**根本没有测试文件**（Servo / Timer）。
--
-- 本文件补上这两条：
--   Servo.angle / max / min / offset 非有限 → ERR（0–180 执行器保护钳位不得被绕过）
--   Timer.delay 非有限 → ERR（旧行为是 slept=nan 且实际几乎不睡，节拍丢失）
--
-- 两者都是纯软件驱动（不申请资源、不碰总线），故直接 dofile 即可，无需桩设备。
-- 用法（项目根目录）: luajit test/test_servo_timer_nan.lua
local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- Timer 经 HAL.milli_sleep → HAL.sys.usleep 阻塞：替换为记账桩，避免真睡。
local ffi = require("ffi")
local HAL = dofile("modules/lib/HAL.lua")
local sleeps = {}
HAL.sys.usleep = function(usec)
	sleeps[#sleeps + 1] = tonumber(usec)
	return 0
end

dofile("modules/Servo.lua")
-- Timer.lua 以全局函数名暴露 build/call/destroy；先跑完 Servo 断言再加载 Timer，
-- 两者同名全局会互相覆盖，故分开小节并在加载后立即断言。
local servo_call = call

------------------------------------------------------------------
-- Servo：angle 非有限
------------------------------------------------------------------
check("Servo: angle=180 正常",
	servo_call({ angle = "180", channel = "3", max = "180", min = "0" }).angle == 180)
check("Servo: angle=nan 拒绝",
	servo_call({ angle = "nan", channel = "3", max = "180", min = "0" }).result == "ERR",
	tostring(servo_call({ angle = "nan", channel = "3" }).message))
check("Servo: angle=inf 拒绝",
	servo_call({ angle = "1e400", channel = "3", max = "180", min = "0" }).result == "ERR")
check("Servo: angle=-inf 拒绝",
	servo_call({ angle = "-1e400", channel = "3", max = "180", min = "0" }).result == "ERR")
check("Servo: angle 缺失拒绝",
	servo_call({ channel = "3" }).result == "ERR")

-- Servo：max/min/offset 非有限（旧本地 num_or_zero 的 tonumber 放行 NaN，
-- 使第 89-93 行限幅比较恒假、保护钳位整体失效）。
-- 注意 Servo.call 的正常返回**没有 result 键**（返回 {channel, angle}，由
-- controller 转发），故成功判据是「无 message 且有数值 angle」，不是 result=="OK"。
local r = servo_call({ angle = "90", channel = "3", max = "nan", min = "0", offset = "0" })
check("Servo: max=nan 回落 0（钳位仍生效，角度为 0）",
	r.message == nil and r.angle == 0, tostring(r.angle))
r = servo_call({ angle = "90", channel = "3", max = "180", min = "0", offset = "nan" })
check("Servo: offset=nan 回落 0（角度不受污染）",
	r.message == nil and r.angle == 90, tostring(r.angle))
r = servo_call({ angle = "90", channel = "3", max = "1e400", min = "0" })
check("Servo: max=inf 回落 0（角度不变成 inf/NaN）",
	r.message == nil and r.angle == 0, tostring(r.angle))

-- Servo：channel 非有限（26.3）。本文件上面四组钉的是 angle/max/min/offset，
-- channel 是同一函数里唯一漏网的配置列：`tonumber(data.channel)` 对 'nan' 出的
-- 是 number，`channel == nil` 判据放行，于是 { channel = NaN, angle = a } 以
-- **成功形状**返回（本驱动的正常返回没有 result 键，见上方注），由框架合并进
-- 元数据后转发给 controller/PCA9685——NaN 通道号进 JSON 变 null，下游拿到的是
-- 空值而不是报错。angle 那一路已有 finite_of，故判据取「与 angle=nan 同结论」。
r = servo_call({ angle = "90", channel = "nan", max = "180", min = "0" })
check("Servo: channel=nan 拒绝（不得以成功形状转发 NaN 通道号）",
	r.result == "ERR", tostring(r.channel))
r = servo_call({ angle = "90", channel = "1e400", max = "180", min = "0" })
check("Servo: channel=inf 拒绝", r.result == "ERR", tostring(r.channel))
r = servo_call({ angle = "90", channel = "3", max = "180", min = "0" })
check("Servo: channel=3 正常（判据未误伤有限值）",
	r.message == nil and r.channel == 3, tostring(r.channel))

------------------------------------------------------------------
-- Timer：delay 非有限
------------------------------------------------------------------
dofile("modules/Timer.lua")
local timer_call = call

sleeps = {}
local tr = timer_call({ delay = "100" })
check("Timer: delay=100 正常", tr.result == "OK" and tr.slept == 100, tostring(tr.slept))
check("Timer: 实际下发 100ms→100000us",
	sleeps[#sleeps] == 100000, tostring(sleeps[#sleeps]))

local n_before = #sleeps
tr = timer_call({ delay = "nan" })
check("Timer: delay=nan 拒绝（旧行为 slept=nan 且不睡）", tr.result == "ERR",
	tostring(tr.message))
check("Timer: delay=nan 未下发睡眠", #sleeps == n_before)
tr = timer_call({ delay = "1e400" })
check("Timer: delay=inf 拒绝", tr.result == "ERR")
tr = timer_call({ delay = "-1e400" })
check("Timer: delay=-inf 拒绝", tr.result == "ERR")
check("Timer: delay 缺失拒绝", timer_call({}).result == "ERR")
check("Timer: delay 超上限拒绝", timer_call({ delay = "4294968" }).result == "ERR")

tester.summary("test_servo_timer_nan.lua")

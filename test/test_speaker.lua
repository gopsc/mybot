-- test_speaker.lua — Speaker 驱动离线单测（无声卡、无 libasound、无真睡）
-- 真实路径经 asound 字段替换 mock：Speaker 以 local 持有 asound 模块表，
-- 替换字段对它立即可见（HAL.sys 同款注入手法，见 modules/lib/asound.lua 头）。
-- 仿真路径不 mock、直接跑（simulate='1'）。
-- 用法（项目根目录）: luajit test/test_speaker.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local asound = dofile("modules/lib/asound.lua")

local log = {}				-- PCM 原语调用序列（{cmd=...}，配 expect_cmds）
local frames = 0			-- 本 call 累计写入帧数
local scan = { min = 0, max = 0, first = nil }	-- 样本摆幅/首样本（包络 sanity）
local FAKE = {}

asound.open_stream = function(dev, rate)
	log[#log + 1] = { cmd = "open", dev = dev, rate = rate }
	return FAKE
end
local function mock_write(pcm, buf, n)
	log[#log + 1] = { cmd = "write", n = n }
	frames = frames + n
	if scan.first == nil then scan.first = buf[0] end
	for i = 0, n - 1 do
		local v = buf[i]
		if v < scan.min then scan.min = v elseif v > scan.max then scan.max = v end
	end
	return n
end
asound.write = mock_write
asound.prepare = function(pcm)
	log[#log + 1] = { cmd = "prepare" }
	return 0
end
asound.drain = function(pcm)
	log[#log + 1] = { cmd = "drain" }
	return 0
end
asound.close = function(pcm)
	log[#log + 1] = { cmd = "close" }
	return 0
end

dofile("modules/Speaker.lua")

local function reset() frames = 0; scan.min, scan.max, scan.first = 0, 0, nil end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end

-- ======== 仿真模式：build 校验 + 音调数学 ========

local r = build({ simulate = "1" })
check("build(simulate) OK 且带 simulated=true",
	type(r) == "table" and r.result == "OK" and r.simulated == true)
check("仿真模式不触 PCM 原语（log 空）", #log == 0)

tester.expect_err("build 非法 preset", function()
	return build({ simulate = "1", preset = "zzz" }) end, "preset")
tester.expect_err("build 非法 rate", function()
	return build({ simulate = "1", rate = "9" }) end, "rate")
tester.expect_err("build 越界 volume", function()
	return build({ simulate = "1", volume = "101" }) end, "volume")
tester.expect_err("build 越界 max_ms", function()
	return build({ simulate = "1", max_ms = "60001" }) end, "max_ms")

-- MIDI 号 → 频率（十二平均律 A4=440）：钢琴两端 + 标准音 + 中央C
local NOTE_HZ = {
	{ 21, 27.5 },			-- A0 钢琴最低音
	{ 60, 261.6256 },		-- 中央 C
	{ 69, 440 },			-- A4 标准音
	{ 81, 880 },			-- A5
	{ 108, 4186.0095 },		-- C8 钢琴最高音
}
for _, t in ipairs(NOTE_HZ) do
	r = call({ note = t[1], delay = 50 })
	check(string.format("note=%d -> %.4fHz", t[1], t[2]),
		r.result == "OK" and near(r.freq, t[2]),
		(type(r) == "table") and tostring(r.freq) or tostring(r))
end

-- 音名 → 频率（含等异名同音 c#4=db4、大写输入）
local NAME_HZ = {
	{ "a4", 440 }, { "A4", 440 },
	{ "c#4", 277.1826 }, { "db4", 277.1826 },
	{ "bb3", 233.0819 },
	{ "b7", 3951.066 },
	{ "c8", 4186.0095 },
}
for _, t in ipairs(NAME_HZ) do
	r = call({ note = t[1], delay = 50 })
	check(string.format("note='%s' -> %.4fHz", t[1], t[2]),
		r.result == "OK" and near(r.freq, t[2]),
		(type(r) == "table") and tostring(r.freq) or tostring(r))
end

-- 裸音名（省八度，缺省八度 4 = 中央C八度）：'a' 即 440Hz，'c' 即中央C
local BARE_HZ = {
	{ "c", 261.6256 }, { "C", 261.6256 },
	{ "a", 440 }, { "b", 493.8833 }, { "f", 349.2317 },
	{ "c#", 277.1826 }, { "db", 277.1826 }, { "g#", 415.3047 },
}
for _, t in ipairs(BARE_HZ) do
	r = call({ note = t[1], delay = 50 })
	check(string.format("note='%s'(省八度->4) -> %.4fHz", t[1], t[2]),
		r.result == "OK" and near(r.freq, t[2]),
		(type(r) == "table") and tostring(r.freq) or tostring(r))
end
r = call({ note = "c", delay = 50 })
check("裸音名回显大写原拼写（note='C'）", r.note == "C", tostring(r.note))
r = call({ note = "g#", delay = 50 })
check("裸升降音名回显大写原拼写（note='G#'）", r.note == "G#", tostring(r.note))

r = call({ note = "c#4", delay = 50 })
check("音名回显大写原拼写（note='C#4'）", r.note == "C#4", tostring(r.note))
r = call({ note = "69", delay = 50 })
check("数字文本（@Alias 间接路线）按 MIDI 号认 -> 440Hz",
	r.result == "OK" and near(r.freq, 440) and r.note == 69)

-- 音调来源判定：互斥 / 缺省 / 越界 / 格式
tester.expect_err("note+freq 同给即歧义报错", function()
	return call({ note = 69, freq = 440, delay = 100 }) end, "mutually exclusive")
tester.expect_err("sine 无 note 无 freq 报必填", function()
	return call({ delay = 100 }) end, "required")
tester.expect_err("note='-' 占位等同缺省", function()
	return call({ note = "-", delay = 100 }) end, "required")
tester.expect_err("note=20 低于钢琴域", function()
	return call({ note = 20, delay = 100 }) end, "21~108")
tester.expect_err("note=109 超过钢琴域（提示改用 freq）", function()
	return call({ note = 109, delay = 100 }) end, "use freq")
tester.expect_err("note='c-1'（MIDI 0）越界", function()
	return call({ note = "c-1", delay = 100 }) end, "21~108")
tester.expect_err("note='c#8'（MIDI 109）越界", function()
	return call({ note = "c#8", delay = 100 }) end, "21~108")
tester.expect_err("note=60.5 非整数 MIDI", function()
	return call({ note = 60.5, delay = 100 }) end, "MIDI number")
tester.expect_err("note=NaN 拒绝", function()
	return call({ note = 0 / 0, delay = 100 }) end, "MIDI number")
tester.expect_err("note='h4' 非法音名", function()
	return call({ note = "h4", delay = 100 }) end, "MIDI number")
tester.expect_err("note='c##4' 双升降号不支持", function()
	return call({ note = "c##4", delay = 100 }) end, "MIDI number")

-- silence：音调可省（缺省 0Hz）；给了 note 也照校验（契约统一，同 noise×freq）
r = call({ delay = 100, wave = "silence" })
check("silence 无音调参数 OK（freq=0）",
	r.result == "OK" and r.freq == 0, tostring(r.freq))
r = call({ delay = 100, wave = "silence", note = "c4" })
check("silence + note 契约统一（校验过、幅值零）",
	r.result == "OK" and near(r.freq, 261.6256), tostring(r.freq))
r = call({ delay = 100, wave = "noise", note = 69 })
check("noise + note 契约统一（freq 无频谱意义仍必填同款）",
	r.result == "OK" and near(r.freq, 440), tostring(r.freq))

-- freq 路径回归
r = call({ freq = 880, delay = 100 })
check("freq 路径 OK 且无 note 回显",
	r.result == "OK" and near(r.freq, 880) and r.note == nil)
tester.expect_err("freq=0 非 silence 拒绝", function()
	return call({ freq = 0, delay = 100 }) end, "only valid with preset=silence")
tester.expect_err("freq=10 低于可听域", function()
	return call({ freq = 10, delay = 100 }) end, "20~20000")
tester.expect_err("缺 delay 拒绝", function()
	return call({ note = 69 }) end, "delay")
tester.expect_err("delay=0 拒绝", function()
	return call({ note = 69, delay = 0 }) end, "> 0")
tester.expect_err("delay 超 max_ms 拒绝", function()
	return call({ note = 69, delay = 20000 }) end, "max_ms")

r = destroy({})
check("仿真模式 destroy released=false",
	r.result == "OK" and r.released == false)

-- ======== 真实路径（mock PCM）：时序 / 帧数 / 包络 / underrun ========

r = build({})
check("build 实模式 OK（default@16000）",
	r.result == "OK" and r.device == "default" and r.rate == 16000)
tester.expect_cmds("build 期 open_stream 恰一次", log, { "open" }, "cmd")
log = {}

reset()
r = call({ note = 81, delay = 150 })		-- A5，2400 帧 = 单块
check("call(note=81,150ms) OK（freq=880 回显）",
	r.result == "OK" and near(r.freq, 880) and r.note == 81)
check("帧数 = rate*ms/1000（2400）", frames == 2400, tostring(frames))
tester.expect_cmds("单块播放序列 prepare→write→drain", log,
	{ "prepare", "write", "drain" }, "cmd")
check("attack 包络首样本为 0（pos0 env=0）", scan.first == 0, tostring(scan.first))
check("正弦摆幅贯通包络（vol=80：|峰|≈32767*0.64）",
	scan.max > 20000 and scan.min < -20000,
	scan.min .. "/" .. scan.max)
log = {}

reset()
r = call({ freq = 440, delay = 400 })		-- 6400 帧 = 4096+2304 两块
check("400ms -> 6400 帧", frames == 6400, tostring(frames))
tester.expect_cmds("drain 后第二次 call 必须 prepare（-EBADFD 回归）", log,
	{ "prepare", "write", "write", "drain" }, "cmd")
log = {}

reset()
r = call({ note = 69, delay = 200, volume = 50 })
check("volume 逐次覆盖（峰值 ≤ 32767*0.25）",
	r.result == "OK" and r.volume == 50 and scan.max <= 8193 and scan.max > 6000,
	scan.min .. "/" .. scan.max)
log = {}

-- underrun（-EPIPE）：prepare 后重写本块一次，自愈
local fail_once = true
asound.write = function(pcm, buf, n)
	if fail_once then
		fail_once = false
		log[#log + 1] = { cmd = "write-ePIPE" }
		return -asound.EPIPE
	end
	return mock_write(pcm, buf, n)
end
reset()
r = call({ note = 69, delay = 100 })
asound.write = mock_write
check("underrun 一次自愈（帧数不缺）", r.result == "OK" and frames == 1600,
	tostring(frames))
tester.expect_cmds("underrun 序列 prepare→EPIPE→prepare→write→drain", log,
	{ "prepare", "write-ePIPE", "prepare", "write", "drain" }, "cmd")
log = {}

-- underrun 二连：重试仍失败，如实报错（静默丢样本=时长悄悄变短）
local fails = 0
asound.write = function(pcm, buf, n)
	fails = fails + 1
	if fails <= 2 then return -asound.EPIPE end
	return mock_write(pcm, buf, n)
end
tester.expect_err("underrun 二连如实报错", function()
	return call({ note = 69, delay = 100 }) end, "underrun")
asound.write = mock_write
log = {}

asound.write = function(pcm, buf, n) return -77 end
tester.expect_err("write 其他 errno 报 writei failed", function()
	return call({ note = 69, delay = 100 }) end, "snd_pcm_writei failed")
asound.write = mock_write
log = {}

local real_prepare = asound.prepare
asound.prepare = function(pcm)
	log[#log + 1] = { cmd = "prepare" }
	return -77
end
tester.expect_err("prepare 失败如实报错", function()
	return call({ note = 69, delay = 100 }) end, "snd_pcm_prepare failed")
asound.prepare = real_prepare
log = {}

-- 重复 build：先 close 旧句柄再 open（PWM 同款守卫）
r = build({})
check("重复 build OK", r.result == "OK")
tester.expect_cmds("重复 build 先 close 再 open", log, { "close", "open" }, "cmd")
log = {}

-- 开卡失败：带原因报错，不静默降级
local real_open = asound.open_stream
asound.open_stream = function(dev, rate) return nil, "no card" end
r = build({})
asound.open_stream = real_open
check("build 开卡失败带原因",
	type(r) == "table" and r.result == "ERR" and r.message:find("no card", 1, true) ~= nil,
	(type(r) == "table") and tostring(r.message) or tostring(r))
log = {}

r = build({})
check("失败后重开 OK", r.result == "OK")
tester.expect_cmds("重开序列（句柄已失，无 close）", log, { "open" }, "cmd")
log = {}

r = destroy({})
check("destroy OK released=true", r.result == "OK" and r.released == true)
tester.expect_cmds("destroy 序列 drain→close", log, { "drain", "close" }, "cmd")
log = {}

r = destroy({})
check("二次 destroy 幂等（released=false）",
	r.result == "OK" and r.released == false)

tester.summary("test_speaker")

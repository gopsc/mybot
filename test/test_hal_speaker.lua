-- test_hal_speaker.lua —— 宿主 HAL 的 Speaker 桥回归（无 ALSA、无声卡）
--
-- 用假的 __hal_call 验证三件事：
--   1) HAL.lua 暴露 speaker_* 且全部经 __hal_call（Lua 不再直接碰 ALSA）；
--   2) asound.lua 在宿主模式走 speaker_*，不再 ffi.load libasound；
--   3) asound.write 把 cdata 样本块按原始 S16_LE 字节过桥，不逐样本 JSON 化。
--
-- 独立 luajit 回退路径（无 __hal_call）由 test_speaker.lua 的字段 mock 覆盖。
-- 用法（项目根目录）: luajit test/test_hal_speaker.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local calls = {}
_G.__hal_call = function(op, ...)
	local args = { ... }
	calls[#calls + 1] = { op = op, args = args }
	if op == "speaker_open" then return 7 end
	if op == "speaker_write" then
		local raw = args[2]
		return math.floor(#raw / 2)
	end
	if op == "speaker_prepare" or op == "speaker_drain" or op == "speaker_close" then
		return 0
	end
	if op == "speaker_errmsg" then return "mock ALSA error" end
	if op == "last_error" then return "mock last error" end
	return -1
end

local HAL = dofile("modules/lib/HAL.lua")

check("HAL.lua 定义 speaker_open", type(speaker_open) == "function")
check("HAL.lua 定义 speaker_write", type(speaker_write) == "function")
check("HAL.lua 定义 speaker_prepare", type(speaker_prepare) == "function")
check("HAL.lua 定义 speaker_drain", type(speaker_drain) == "function")
check("HAL.lua 定义 speaker_close", type(speaker_close) == "function")
check("HAL.lua 定义 speaker_errmsg", type(speaker_errmsg) == "function")

local h = speaker_open("default", 16000)
check("speaker_open 走 __hal_call", h == 7 and calls[#calls].op == "speaker_open")
check("speaker_open 参数原样过桥",
	calls[#calls].args[1] == "default" and calls[#calls].args[2] == 16000)

local asound = dofile("modules/lib/asound.lua")
check("asound 识别宿主桥", asound.loaded() == true)
check("asound.load 宿主模式直接成功", asound.load() == true)

local pcm, err = asound.open_stream("default", 16000)
check("asound.open_stream 走 speaker_open", pcm == 7 and err == nil)

local buf = asound.alloc(4)
buf[0], buf[1], buf[2], buf[3] = 1, -1, 32767, -32768
local n = asound.write(pcm, buf, 4)
local writeCall = calls[#calls]
check("asound.write 走 speaker_write", n == 4 and writeCall.op == "speaker_write")
check("asound.write 传原始 S16_LE 字节（4 帧 = 8B）",
	type(writeCall.args[2]) == "string" and #writeCall.args[2] == 8)

check("asound.prepare 走 speaker_prepare", asound.prepare(pcm) == 0
	and calls[#calls].op == "speaker_prepare")
check("asound.drain 走 speaker_drain", asound.drain(pcm) == 0
	and calls[#calls].op == "speaker_drain")
check("asound.close 走 speaker_close", asound.close(pcm) == 0
	and calls[#calls].op == "speaker_close")
check("asound.errmsg 走 speaker_errmsg", asound.errmsg(-32) == "mock ALSA error"
	and calls[#calls].op == "speaker_errmsg")

-- 驱动级回归：Speaker.lua 的非 simulate 路径也必须只经 speaker_* 桥，
-- 不能悄悄回退到 asound 的 ffi 直驱。用它自己的 build/call/destroy 走一遍。
dofile("modules/Speaker.lua")
local br = build({ device = "mock", rate = 16000, preset = "sine",
	volume = 80, max_ms = 10000 })
check("Speaker.build 经 speaker_open", br.result == "OK"
	and calls[#calls].op == "speaker_open")
local cr = call({ freq = 440, delay = 10 })
check("Speaker.call 经 speaker_prepare/write/drain",
	cr.result == "OK" and calls[#calls].op == "speaker_drain")
local dr = destroy({})
check("Speaker.destroy 经 speaker_close", dr.result == "OK"
	and calls[#calls].op == "speaker_close")

tester.summary("HAL speaker")

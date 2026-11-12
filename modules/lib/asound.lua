-- asound.lua —— Speaker 驱动的音频传输（LuaJIT ffi 直驱 libasound）
--
-- 这一层只做「打开 PCM 设备、按 S16_LE 单声道写样本、收尾」，不认识任何
-- 波形语义；波形形状/音调/时长在驱动（modules/Speaker.lua）里。
--
-- 【为什么用 ffi 而不是 shell-out】（与 hal_backend_glibc.lua 的 ffi 直驱同一论证）
--   * 驱动沙箱已中和 os.execute/io.popen（luasandbox.cpp），aplay 管道路线不可用；
--   * ffi 直调 libasound 无需头文件、无编译期依赖，只要求运行期有 libasound.so；
--   * ALSA C API（snd_pcm_open/set_params/writei/drain/close）签名稳定、全为
--     定参函数——不存在 libcurl 的 curl_easy_setopt 那种变参陷阱（参数类型
--     由宏展开决定，签名正确性只能靠调用方自觉）。
--
-- 运行期依赖：libasound.so.2（Debian/Ubuntu: libasound2；ALSA 1.x 全系 ABI 稳定）。
-- 缺库不是构建错误——只有配置了 Speaker 的结构脚本才需要它；build 期经
-- load() 把「缺库」变成清晰报错，而不是等到第一次发声才失败。
--
-- 编号常量（SND_PCM_* / EPIPE）与本文件的对账：test/test_speaker_consts.c
-- 编译期与 <alsa/asoundlib.h> 比对（F-24 常量自检同族，事实源经
-- gen_const_check.cmake 从本文件抽取）；开发头文件非构建依赖，构建机没装
-- 时该自检不产出、run_all.sh 按跳过计。
--
-- 重复加载保护（与 HAL.lua 同一做法）：驱动与测试都会 dofile
-- 本文件，ffi.cdef 重复声明同一符号会直接报错，故用全局缓存保证只初始化一次。
-- 测试以**字段替换**注入 mock（HAL.sys 同款）：本表被 dofile 方以 local 引用
-- 持有，替换字段对既有引用立即可见。
if _G.__BOT4CJ_ASOUND ~= nil then return _G.__BOT4CJ_ASOUND end

local ffi = require("ffi")

ffi.cdef[[
typedef struct _snd_pcm snd_pcm_t;
int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
int snd_pcm_set_params(snd_pcm_t *pcm, int format, int access,
	unsigned int channels, unsigned int rate, int soft_resample,
	unsigned int latency_us);
long snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, long size);
int snd_pcm_prepare(snd_pcm_t *pcm);
int snd_pcm_drain(snd_pcm_t *pcm);
int snd_pcm_close(snd_pcm_t *pcm);
const char *snd_strerror(int errnum);
]]

local M = {}

-- ALSA 编号常量（<alsa/asoundlib.h> 枚举值；ABI 稳定，漂移由
-- test_speaker_consts.c 编译期断言）。EPIPE 是 POSIX errno（underrun 时
-- snd_pcm_writei 返回 -EPIPE，Linux x86_64/aarch64 均为 32）。
local SND_PCM_STREAM_PLAYBACK = 0
local SND_PCM_FORMAT_S16_LE = 2
local SND_PCM_ACCESS_RW_INTERLEAVED = 3
local EPIPE = 32

-- 供驱动判定 underrun 重试用（与常量段一起被 gen_const_check.cmake 抽取）
M.EPIPE = EPIPE

-- 立体声上限/缺省：单声道 16kHz 是提示音的甜点位（样本量小、Lua 生成便宜，
-- 4kHz 以上泛音仍有余量）；上限对齐常见设备能力，越界由驱动报错。
M.RATE_MIN = 8000
M.RATE_MAX = 48000
M.RATE_DEFAULT = 16000
M.CHANNELS = 1
M.LATENCY_US = 500000		-- 0.5s 环形缓冲：writei 阻塞节流由 ALSA 负责

local C, load_err

-- 惰性加载：dlopen 候选名按常见发行版顺序探测（Debian/Ubuntu 为
-- libasound.so.2；开发包提供 libasound.so）
function M.load()
	if C then return true end
	if load_err then return false, load_err end
	local names = { "libasound.so.2", "libasound.so" }
	for _, n in ipairs(names) do
		local ok, h = pcall(ffi.load, n)
		if ok then
			C = h
			return true
		end
	end
	load_err = "libasound not found (install libasound2 / alsa-lib)"
	return false, load_err
end

-- 实际 dlopen 成功的库句柄（测试判「真加载/被 mock」用）
function M.loaded() return C end

-- 打开播放流并配好参数。返回 (handle, nil) 或 (nil, errmsg)。
-- device 形如 "default" / "hw:0,0" / "plughw:0,0"；rate 8000~48000。
function M.open_stream(device, rate)
	local ok, e = M.load()
	if not ok then return nil, e end
	local ref = ffi.new("snd_pcm_t *[1]")
	local rc = C.snd_pcm_open(ref, device, SND_PCM_STREAM_PLAYBACK, 0)
	if rc < 0 then
		return nil, "snd_pcm_open('" .. tostring(device) .. "'): "
			.. ffi.string(C.snd_strerror(rc))
	end
	local pcm = ref[0]
	rc = C.snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE,
		SND_PCM_ACCESS_RW_INTERLEAVED, M.CHANNELS, rate, 1, M.LATENCY_US)
	if rc < 0 then
		local msg = "snd_pcm_set_params(rate=" .. tostring(rate) .. "): "
			.. ffi.string(C.snd_strerror(rc))
		C.snd_pcm_close(pcm)
		return nil, msg
	end
	return pcm
end

-- 写一帧块（interleaved S16）。返回写入帧数，失败返回负 errno。
-- underrun 恢复不在本层：-EPIPE 由驱动判 M.EPIPE 后调 prepare 再重试
-- （放绑定层会让 mock 测不到驱动的恢复路径）。
function M.write(pcm, buf, frames)
	return tonumber(C.snd_pcm_writei(pcm, buf, frames))
end

-- underrun 后重新准备设备（驱动在 write 返回 -EPIPE 时调用）
function M.prepare(pcm)
	return tonumber(C.snd_pcm_prepare(pcm))
end

-- 播完缓冲内剩余样本再返回（保证「call 返回 = 声音播完」）
function M.drain(pcm)
	return tonumber(C.snd_pcm_drain(pcm))
end

-- 关闭设备（destroy 收尾）
function M.close(pcm)
	return tonumber(C.snd_pcm_close(pcm))
end

-- errno → 人话（含正/负码两种形态）
function M.errmsg(rc)
	if C == nil then return "errno " .. tostring(rc) end
	return ffi.string(C.snd_strerror(rc < 0 and rc or -rc))
end

-- 样本缓冲（int16 每帧 × 单声道）
function M.alloc(frames)
	return ffi.new("int16_t[?]", frames)
end

rawset(_G, "__BOT4CJ_ASOUND", M)
return M

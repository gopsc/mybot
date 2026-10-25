-- AgentFakeCamera.lua —— test/cpp/test_agenttools.cpp 用的假摄像头驱动
--
-- 不碰硬件、不读文件：合成一段**体积可控、魔数正确**的假图片回给宿主，用来钉住
-- `capture_image` 的体积判据。存在的理由与 AgentFakeDriver.lua 相同——真驱动
-- modules/Camera.lua 的每条返回路径都带 `bytes` 字段，于是「驱动没报原始字节数时，
-- base64 长度这道兜底还能不能拦住超限图」在离线守门里没有夹具可构造。
--
-- 载荷构造：JPEG 头（FF D8 FF E0 00 10 "JFIF" 00，11 字节；宿主与社会化驱动的
-- 魔数判据只看前 3 字节）之后补若干 'A'。**先拼原始字节、最后统一 base64**，
-- 不在 base64 文本上做拼接——那样会在末尾留下一个 '=' 填充位，宿主拿到的是
-- 「有填充的碎片」，解码语义由调用方自觉维持，太脆。
--
-- 配置（矩阵元数据列，build 期以**顶层字段**到达，与真驱动 Camera.lua 读 data.src
-- 的形态一致）：
--   raw_bytes : 目标原始字节数（缺省 0 = 返回空 b64）
--   omit_bytes: "yes" 时**不返回** bytes 字段（模拟漏填声明的驱动）
--   format    : 声明的图片格式（缺省 jpeg）
--   fixed_size: "WxH" 时 call 恒返回该 width/height（模拟「设备把请求就近调档」，
--               与真驱动返回**协商值**的语义一致；缺省不返回尺寸字段）

local cfg_raw_bytes = 0
local cfg_omit_bytes = false
local cfg_format = "jpeg"
local cfg_fixed_size = nil

local JPEG_HEADER = string.char(0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10)
	.. "JFIF" .. string.char(0x00)

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- 独立的最简 base64（三字节一组；测试夹具不复用被测驱动的算法）
local function base64(s)
	local out, i = {}, 1
	while i <= #s do
		local b1 = s:byte(i)
		local b2 = s:byte(i + 1)
		local b3 = s:byte(i + 2)
		local n = (b2 and 1 or 0) + (b3 and 1 or 0)
		local v = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		local function ch(shift) return B64_CHARS:sub(math.floor(v / shift) % 64 + 1,
			math.floor(v / shift) % 64 + 1) end
		out[#out + 1] = ch(262144) .. ch(4096)
			.. (n >= 1 and ch(64) or "=") .. (n >= 2 and ch(1) or "=")
		i = i + 3
	end
	return table.concat(out)
end

-- 原始字节数 → base64 长度（4/3 上取整），供测试侧精确断言
local function base64_len(raw)
	return math.floor((raw + 2) / 3) * 4
end

function build(data)
	if data ~= nil then
		if data.raw_bytes ~= nil then cfg_raw_bytes = tonumber(data.raw_bytes) or 0 end
		if data.format ~= nil then cfg_format = tostring(data.format) end
		if data.fixed_size ~= nil then cfg_fixed_size = tostring(data.fixed_size) end
		cfg_omit_bytes = (data.omit_bytes == "yes")
	end
	cfg_raw_bytes = math.floor(cfg_raw_bytes)
	return { result = "OK" }
end

function destroy(data)
	return { result = "OK" }
end

function call(data)
	local out = {
		result = "OK",
		source = "v4l2",	-- 扮演**真机**：source=file 会被宿主按仿真路径解读（不缩放、
				-- 调档说明也不生效），与 fixed_size 的「设备调档」语义冲突
		format = cfg_format,
		b64 = base64(JPEG_HEADER .. string.rep("A", math.max(0, cfg_raw_bytes - #JPEG_HEADER))),
	}
	if not cfg_omit_bytes then out.bytes = cfg_raw_bytes end
	if cfg_fixed_size ~= nil then
		local w, h = cfg_fixed_size:match("^(%d+)x(%d+)$")
		-- 转成**数字**：真驱动返回的是数值；Lua 字串跨到宿主是 JSON 字符串，
		-- 宿主的 isInt 判据不认，尺寸会被当成「没报告」而漏掉
		out.width, out.height = tonumber(w), tonumber(h)
	end
	return out
end

-- requires: video
-- Camera.lua 真机抓帧回归：需 /dev/video*（且有 V4L2 MJPEG 摄像头）。
-- 无设备时守门按上面这行标记自动跳过（与 test_jit_warmup.lua 的 `-- requires: i2c` 同机制）。
-- 可用 BOT4CJ_TEST_VIDEO 指定设备路径。
-- 用法（项目根目录）: luajit test/test_camera_v4l2.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

-- 最小 base64 解码（只为本测试服务）：用来验证返回的帧尾是 EOI
local function b64decode(s)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local map = {}
	for i = 1, #chars do map[chars:sub(i, i)] = i - 1 end
	local out, acc, bits = {}, 0, 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "=" then break end
		acc = acc * 64 + map[c]
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			out[#out + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
			acc = acc % 2 ^ bits
		end
	end
	return table.concat(out)
end

dofile("modules/Camera.lua")

local dev = os.getenv("BOT4CJ_TEST_VIDEO") or "/dev/video0"

local b = build({ path = dev })
check("真机 build 成功（无 warning）", b.result == "OK" and b.warning == nil,
	tostring(b.warning or b.message))

local res = call({})
check("真机抓帧返回 OK", res.result == "OK", tostring(res.message))
if res.result == "OK" then
	check("来源标记为 v4l2", res.source == "v4l2")
	check("格式标记为 jpeg", res.format == "jpeg")
	check("分辨率已协商", (res.width or 0) > 0 and (res.height or 0) > 0,
		tostring(res.width) .. "x" .. tostring(res.height))
	check("帧数据量合理（>1KB）", (res.bytes or 0) > 1024, tostring(res.bytes))
	-- MJPEG 抓到的就是一段完整 JPEG：base64 必以 /9j/ 开头（FF D8 FF）
	check("base64 以 /9j/ 开头（JPEG SOI）", res.b64:sub(1, 4) == "/9j/",
		res.b64:sub(1, 8))
	-- 截断帧已在驱动内重取（lib/mjpeg_frame.lua）：出去的帧必须完整。
	-- 2026-09-19 实测：UVC 设备约半数帧在熵编码中途截断，宽松解码器（ffmpeg）
	-- 看不出问题，模型网关的严格解析器会 400「图片输入格式/解析错误」。
	local raw = b64decode(res.b64)
	check("帧尾是 EOI（ffd9）——帧完整", raw:sub(-2) == "\xff\xd9",
		"实际帧尾 " .. raw:sub(-2):gsub(".", function(c) return string.format("%02x ", c:byte()) end))
	check("bytes 字段与解码长度一致", res.bytes == #raw,
		tostring(res.bytes) .. " vs " .. #raw)
	-- 连续抓两帧，验证流是活的、缓冲正常回收
	local res2 = call({})
	check("连续第二帧同样成功", res2.result == "OK")
end

check("destroy 返回 OK", destroy({}).result == "OK")
tester.summary("Camera 真机抓帧")

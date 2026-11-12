-- mjpeg_frame.lua —— MJPEG 帧完整性校验与收尾规范化
--
-- 独立成库的原因与 HAL.lua 相同：规则要能离线单测（test/test_camera.lua）。
--
-- 【为什么需要】UVC 摄像头的 MJPEG 帧可能**在熵编码中途截断**（2026-09-19 实测某
-- 设备约半数帧如此：内核不置 V4L2_BUF_FLAG_ERROR，V4L2 层无从感知；宽松解码器
-- libjpeg/ffmpeg 照样出图，但 OpenAI 兼容网关的严格解析器一律 400
-- 「图片输入格式/解析错误」）。截断意味着 MCU 数据缺失，字节级修补（补 EOI、
-- 补填充位）都救不回来——唯一正确的处理是「不完整就整帧丢弃重取」。
--
-- 判据：帧尾是否以 EOI（ffd9）收尾。JPEG 熵编码段内 0xFF 一律字节填充（ff→ff00）、
-- 重启标记是 ffd0-d7，段内不可能出现 ffd9；但 APP1（EXIF）里可能内嵌缩略图自带
-- 完整 JPEG（含它自己的 EOI），因此只在**帧尾窗口**里找，绝不全文搜索。
-- 找到 EOI 时同时截掉其后的尾部填充（实测见过 EOI 后跟 2 字节 0x00 的设备）。
--
-- M.normalize(payload)：
--   完整帧 → 规范化后的帧字节（截到 EOI 为止）
--   截断帧 → nil（调用方应丢弃重取）
if _G.__BOT4CJ_MJPEG_FRAME ~= nil then return _G.__BOT4CJ_MJPEG_FRAME end

local M = {}

local TAIL_WINDOW = 8	-- EOI 搜索窗口：覆盖帧尾填充即可（实测填充 ≤ 2 字节）

function M.normalize(payload)
	if type(payload) ~= "string" or #payload < 4 then return nil end
	local tail = payload:sub(-TAIL_WINDOW)
	local prefix = tail:match(".*\xff\xd9")
	if prefix == nil then return nil end	-- 尾部无 EOI = 熵编码截断
	-- EOI 恰在帧尾（prefix 覆盖整个 tail）→ 无需截断，直接返回原串：
	-- `payload:sub(1, #payload)` 仍会分配一份等大的新串（Lua 字符串不可变），
	-- 对 1.2MB 帧就是白拷一次。常见路径（UVC 设备多数帧其实是完整的）由此省掉。
	if #prefix == #tail then return payload end
	return payload:sub(1, #payload - #tail + #prefix)
end

-- 图片格式判定（2026-09-21 审计 AG-9）：按**魔数**判，不看扩展名。
--
-- 为什么需要：仿真来源（--camera-src）可以是任意图片，而驱动曾经恒返回
-- format="jpeg"、宿主据此恒拼 `data:image/jpeg;base64,`——传一张 PNG 就会得到
-- 「JPEG 标签 + PNG 字节」，严格网关按图片解析直接 400。同一族的教训：
-- 「声明的类型」必须由**内容**决定，而不是由调用方的期望或文件扩展名决定。
--
-- 只认视觉模型实际支持的四种（OpenAI 兼容端点普遍接受）：jpeg / png / gif / webp。
-- 返回 nil 表示不认识的格式——调用方据此响亮拒绝，而不是猜一个 MIME 发出去。
-- 注意 webp 是 RIFF 容器：必须连第 9-12 字节的 "WEBP" 一起看，否则 WAV/AVI
-- 也会被认成图片。
local function image_format(bytes)
	if type(bytes) ~= "string" or #bytes < 4 then return nil end
	-- 每条判据只看自己需要的字节数：把入口最小长度写成 12 会把合法的小图误判成
	-- 「不认识」（9 字节的 JPEG 就够判魔数）——实测踩过，宿主侧同一处也踩了。
	if bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 and bytes:byte(3) == 0xFF then
		return "jpeg"
	end
	if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
	if bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a" then return "gif" end
	if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "webp" end
	return nil
end

M.image_format = image_format

-- 视觉模型支持的格式白名单（供调用方判断「这个 format 能不能发给模型」）
M.SUPPORTED_FORMATS = { jpeg = true, png = true, gif = true, webp = true }

_G.__BOT4CJ_MJPEG_FRAME = M
return M
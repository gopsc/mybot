-- utf8.lua —— UTF-8 合法性判据 + 消毒（2026-09-21 审计 AG-1 单点，Lua 侧）
--
-- 与 C++ 侧 src/util.hpp 的 utf8DecodeAt / isValidUtf8 / sanitizeUtf8 **同一套
-- 判据与同一套文案**：两处必须一致，否则「宿主消毒过的报文」与「驱动侧看到的
-- 报文」会对「什么算非法」产生分歧，排查时极难定位。
--
-- 【为什么需要】JSON 字符串只允许合法 UTF-8，而本仓库 json.lua 的编码器对
-- 0x80-0xFF 是**字节透明**的（那是「合法多字节 UTF-8 原样透传」所必需）。
-- 任何一处把非法字节放进消息文本，请求体就是非法 UTF-8，严格校验的网关
-- 直接 HTTP 400。
--
-- 分两层：
--   ① 数据进入模型上下文的边界（run_command 输出 / 脚本首注释 / 结构脚本头）
--      由宿主消毒，用户看到的是「非法字节已省略」的**可读替换**；
--   ② 本库的 valid()/sanitize() 是 Lua 侧 json.lua 组报文前的**最后一道**兜底：
--      它挡的是「宿主消毒也没覆盖到的路径」。2026-09-25 #8 起 Lua 协议驱动
--      轨道已删，Lua 侧不再有出站 HTTP 报文路径；本库由 test_utf8.lua 与
--      C++ 侧同表向量互钉保留（改动任一侧都要两边过）。
--
-- 判据按 RFC 3629：拒绝过长编码（C0/C1 开头）、拒绝 UTF-16 代理区（ED A0..BF）、
-- 拒绝 > U+10FFFF（F4 90.. 与 F5..FF）。与 Python/Node 的严格解码器一致。
if _G.__BOT4CJ_UTF8 ~= nil then return _G.__BOT4CJ_UTF8 end

local M = {}

-- 折叠说明的文案，与 src/util.hpp 的 kInvalidUtf8Marker 同字面
M.MARKER = "[! invalid UTF-8 bytes omitted"

-- 取 s 中从 i 开始的序列：返回 (合法字节数, 码点)；非法返回 (0, nil)
local function decode_at(s, i, n)
	local c0 = s:byte(i)
	if c0 == nil then return 0, nil end
	if c0 < 0x80 then return 1, c0 end

	local need, cp
	if c0 >= 0xC2 and c0 <= 0xDF then
		need, cp = 1, c0 % 0x20
	elseif c0 >= 0xE0 and c0 <= 0xEF then
		need, cp = 2, c0 % 0x10
	elseif c0 >= 0xF0 and c0 <= 0xF4 then
		need, cp = 3, c0 % 0x08
	else
		return 0, nil	-- 0x80-0xC1（孤立续字节 / 过长编码首字节）、0xF5-0xFF
	end
	if i + need > n then return 0, nil end	-- 续字节越过末尾：序列被截断

	for k = 1, need do
		local c = s:byte(i + k)
		if c < 0x80 or c > 0xBF then return 0, nil end	-- 续字节必须是 10xxxxxx
		cp = cp * 0x40 + (c % 0x40)
	end
	-- 过长编码：解码值必须落在该长度对应的最小码点之上
	if need == 2 and cp < 0x800 then return 0, nil end
	if need == 3 and cp < 0x10000 then return 0, nil end
	if cp >= 0xD800 and cp <= 0xDFFF then return 0, nil end	-- UTF-16 代理区
	if cp > 0x10FFFF then return 0, nil end
	return need + 1, cp
end

-- 整串是否合法 UTF-8
function M.valid(s)
	if type(s) ~= "string" then return false end
	local n = #s
	local i = 1
	while i <= n do
		local len = decode_at(s, i, n)
		if len == 0 then return false end
		i = i + len
	end
	return true
end

-- 消毒：非法序列替换成 U+FFFD（EF BF BD），合法前缀逐字节不变。
-- 连续非法字节折叠成**一个** U+FFFD 并计数（理由同 C++ 侧：热路径上 64 个坏
-- 字节不该变成 64 个替换符；折叠的是本就无法解读的噪声，不是要保真的内容）。
function M.sanitize(s)
	if type(s) ~= "string" then return s end
	local n = #s
	local out, i = {}, 1
	while i <= n do
		local len = decode_at(s, i, n)
		if len > 0 then
			out[#out + 1] = s:sub(i, i + len - 1)
			i = i + len
		else
			local run = 0
			while i <= n do
				local l = decode_at(s, i, n)
				if l > 0 then break end
				i = i + 1
				run = run + 1
			end
			out[#out + 1] = "\239\191\189"
			if run > 1 then
				out[#out + 1] = M.MARKER .. run .. " bytes]"
			end
		end
	end
	return table.concat(out)
end

_G.__BOT4CJ_UTF8 = M
return M

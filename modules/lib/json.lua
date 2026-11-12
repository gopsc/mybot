-- json.lua —— LuaJIT 侧严格 JSON 编解码（供 agent 模式的 LLM 协议驱动使用）
--
-- 为什么需要：C++ 侧的 src/jsonparse.cpp 只服务宿主进程内的值流转；Lua 驱动要
-- 通过 HTTP 与模型服务交换 **JSON 文本**，必须在 Lua 侧有对应能力。两者语义对齐
-- （严格语法、深度上限、转义与代理对完整），由 test/test_json_lua.lua 钉住。
--
-- 【替代方案评估（决策记录，#29）】
-- cjson（LuaJIT 生态标配）是主要替代：
--   1) 严格模式：cjson 需开启 lua_cjson.safe 并配置 invalid_number 拒绝，
--      深度限制（cjson 2.1+）可达，但 null/空数组/稀疏表的语义与本实现
--      （编码 null → null、null 数组空洞有损点显式声明）逐项核对成本高；
--   2) 语义对齐锚点：本实现与 C++ 端由 test_json_lua.lua 钉住「严格语法 +
--      深度上限 + 转义与代理对完整」，换 cjson 需重建该对齐面；
--   3) 零依赖取向：cjson 是独立的 C 扩展（非 LuaJIT 内建），引入即新增
--      运行期依赖，与项目「运行期只需 LuaJIT + glibc」冲突。
-- 结论：保持自研（安全契约 + 双端语义对齐 + 零依赖三方权衡）。若项目方
-- 决策接受 cjson，需先完成 test_json_lua.lua 全量语义核对再替换。
--
-- 【26.4 库能力面断言】截至 2026-10-06 全仓 grep 仅 test/test_json_lua.lua 加载本库，
-- 无生产消费者（src/util_utf8.hpp:12 提及本库是注释里命名 Lua 侧对等编码器，不是
-- 加载点；docs/agent.md:991 是能力表登记）。上方「供 agent 模式的 LLM 协议驱动
-- 使用」是设计意图，尚未落地。由 test_json_lua.lua 单测守语法与语义对齐面。
--
-- 用法：
--   local json = dofile(mpath.resolve("lib/json.lua"))
--   json.encode({ a = 1 })                    --> '{"a":1}'
--   json.decode('{"a":1}').a                  --> 1
--   json.encode({ content = json.null })      --> '{"content":null}'
--
-- 约定（与 C++ 侧的差异是 Lua 表语义决定的）：
--   * 解码 null → nil：Lua 表无法区分「字段为 null」与「字段不存在」，二者
--     在本项目的用途（取 content/tool_calls）下等价；
--   * null 出现在**数组**里会留下空洞（`[1,null,3]` 解码为 {1,nil,3} 稀疏表），
--     重编码会报错——encoder 对不连续键按对象走、而稀疏表键是数字，触发
--     「object key must be a string」。项目内无「解码→重编码数组」路径，属可接受的有损点；
--   * 编码 nil → 报错：对象里静默丢字段会造出「看起来对、实际缺参」的坏请求，
--     要显式 JSON null 请用 json.null；
--   * 空表编码为 {}（对象）；只有当键恰好是 1..n 连续正整数时才编码为数组。
-- 重复加载保护（与 HAL.lua 同一做法）：驱动与测试都会 dofile 本文件
if _G.__BOT4CJ_JSON ~= nil then return _G.__BOT4CJ_JSON end

local json = {}

-- JSON null 的显式哨兵（仅编码方向需要）
local null = setmetatable({}, { __tostring = function() return "null" end })
json.null = null

-- JSON 空数组的显式哨兵。Lua 里 {} 既可能是空数组也可能是空对象，编解码无法自行
-- 分辨（见文件头约定），而二者在 JSON 里是不同的东西：JSON Schema 的
-- "required": [] 若被写成 {}，DeepSeek 会直接 400
-- （Invalid schema: {} is not of type "array"）。需要产出 [] 时写 json.empty_array。
local empty_array = setmetatable({}, { __tostring = function() return "[]" end })
json.empty_array = empty_array

-- 与 C++ 侧 kJsonMaxDepth 同值：递归下降解析深嵌套会吃栈，模型可被诱导吐出深嵌套
local MAX_DEPTH = 64

------------------------------------------------------------------
-- 编码
------------------------------------------------------------------
local ESCAPE = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s, out)
	-- B3（2026-09-22）：gsub 对「无需转义」的串也整串分配一份拷贝——base64
	-- 图片（JSON 安全字符集）是大头，1.6MB 的 payload 无谓多一次全量拷贝。
	-- 先用 find（O(n) 扫描、零分配）判「无可转义字符」走快路径。
	if s:find('[%z\1-\31\\"]') == nil then
		out[#out + 1] = '"'
		out[#out + 1] = s
		out[#out + 1] = '"'
		return
	end
	out[#out + 1] = '"'
	out[#out + 1] = (s:gsub('[%z\1-\31\\"]', function(c)
		local e = ESCAPE[c]
		if e then return e end
		return string.format("\\u%04x", string.byte(c))
	end))
	out[#out + 1] = '"'
end

-- 数组长度：键必须是 1..n 连续正整数；否则返回 0（按对象编码）。
-- 空洞表若按数组编码会产出非法 JSON（[1,,3]），故不连续一律走对象分支。
local function array_len(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return 0 end
		n = n + 1
	end
	if n == 0 then return 0 end
	for i = 1, n do
		if t[i] == nil then return 0 end
	end
	return n
end

local function encode_number(v, out)
	if v ~= v or v == math.huge or v == -math.huge then
		error("json.encode: non-finite number is not valid JSON", 0)
	end
	-- 整数值的浮点（如 4096.0 来自 @Action 读数）写成整数形态：部分服务端对
	-- 整型字段收到 4096.0 会报类型错。LuaJIT 无 math.type，用 v % 1 判定，
	-- 并以 2^53 为整数可精确表示的上界。
	if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
		out[#out + 1] = string.format("%d", v)
	else
		out[#out + 1] = string.format("%.14g", v)
	end
end

local function encode_value(v, out, depth)
	if depth > MAX_DEPTH then error("json.encode: nesting too deep", 0) end
	if v == null then
		out[#out + 1] = "null"
		return
	end
	if v == empty_array then
		out[#out + 1] = "[]"
		return
	end
	local t = type(v)
	if t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		encode_number(v, out)
	elseif t == "string" then
		encode_string(v, out)
	elseif t == "table" then
		local n = array_len(v)
		if n > 0 then
			out[#out + 1] = "["
			for i = 1, n do
				if i > 1 then out[#out + 1] = "," end
				encode_value(v[i], out, depth + 1)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for k, val in pairs(v) do
				if type(k) ~= "string" then
					error("json.encode: object key must be a string, got " .. type(k), 0)
				end
				-- 这里曾有一条 `if val == nil then error(...)`，声称「字段为 nil 即报错」。
				-- 它是**死代码**（2026-09-21 审计 AG-15，已执行验证）：Lua 表不可能存在
				-- 「键存在、值为 nil」的项，pairs 永远不会产出 nil，所以那条分支不可达，
				-- 而文档却据此承诺了一个不存在的保证——后果是必填字段为 nil 时被**静默
				-- 丢掉**（实测 json.encode({role="tool", tool_call_id=nil, content="x"})
				-- 产出 {"content":"x","role":"tool"}），真机只回一个含混的 400。
				-- 正确的做法不是在这里假装检查（语法上做不到），而是由调用方对自己
				-- 组装的必填字段显式断言：由调用方对自己拼的报文负责
				--（缺失会在这里被静默丢字段，出站前必须点名到字段与消息）。
				if not first then out[#out + 1] = "," end
				first = false
				encode_string(k, out)
				out[#out + 1] = ":"
				encode_value(val, out, depth + 1)
			end
			out[#out + 1] = "}"
		end
	else
		error("json.encode: unsupported type " .. t, 0)
	end
end

function json.encode(value)
	local out = {}
	encode_value(value, out, 0)
	return table.concat(out)
end

------------------------------------------------------------------
-- 解码
------------------------------------------------------------------
local function fail(text, pos, msg)
	error(string.format("json.decode: %s at offset %d", msg, pos), 0)
end

local function skip_ws(text, i)
	local _, e = text:find("^[ \t\r\n]*", i)
	return e + 1
end

local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local decode_value

local function decode_string(text, i)
	i = i + 1	-- 跳过开引号
	local buf, n = {}, 0
	while true do
		local c = text:sub(i, i)
		if c == "" then fail(text, i, "unterminated string") end
		if c == '"' then return table.concat(buf), i + 1 end
		if c == "\\" then
			local e = text:sub(i + 1, i + 1)
			local simple = {
				['"'] = '"', ["\\"] = "\\", ["/"] = "/",
				b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
			}
			if simple[e] then
				n = n + 1
				buf[n] = simple[e]
				i = i + 2
			elseif e == "u" then
				local hex = text:sub(i + 2, i + 5)
				if #hex ~= 4 or hex:find("%X") then fail(text, i, "invalid \\u escape") end
				local cp = tonumber(hex, 16)
				i = i + 6
				if cp >= 0xD800 and cp <= 0xDBFF then
					if text:sub(i, i + 1) ~= "\\u" then fail(text, i, "lone high surrogate") end
					local hex2 = text:sub(i + 2, i + 5)
					if #hex2 ~= 4 or hex2:find("%X") then fail(text, i, "invalid low surrogate") end
					local lo = tonumber(hex2, 16)
					if lo < 0xDC00 or lo > 0xDFFF then fail(text, i, "invalid low surrogate") end
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					i = i + 6
				elseif cp >= 0xDC00 and cp <= 0xDFFF then
					fail(text, i, "lone low surrogate")
				end
				n = n + 1
				buf[n] = utf8_char(cp)
			else
				fail(text, i, "invalid escape")
			end
		else
			if string.byte(c) < 0x20 then fail(text, i, "unescaped control character") end
			n = n + 1
			buf[n] = c
			i = i + 1
		end
	end
end

local function decode_number(text, i)
	local s = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
	if not s or not (s:match("^%-?%d+$") or s:match("^%-?%d+%.%d+$")
			or s:match("^%-?%d+[eE][%+%-]?%d+$")
			or s:match("^%-?%d+%.%d+[eE][%+%-]?%d+$")) then
		fail(text, i, "invalid number")
	end
	-- JSON 数字语法是 -?(0|[1-9]\d*)：前导零必须拒绝，"01" 不是合法 JSON
	local digits = s:match("^%-?(%d+)")
	if digits ~= nil and #digits > 1 and digits:sub(1, 1) == "0" then
		fail(text, i, "invalid number (leading zero)")
	end
	local v = tonumber(s)
	if v == nil then fail(text, i, "invalid number") end
	return v, i + #s
end

local function decode_array(text, i, depth)
	if depth > MAX_DEPTH then fail(text, i, "nesting too deep") end
	i = skip_ws(text, i + 1)	-- 跳过 '['
	local out, n = {}, 0
	if text:sub(i, i) == "]" then return out, i + 1 end
	while true do
		local v
		v, i = decode_value(text, i, depth + 1)
		n = n + 1
		out[n] = v
		i = skip_ws(text, i)
		local c = text:sub(i, i)
		if c == "," then
			i = skip_ws(text, i + 1)
		elseif c == "]" then
			return out, i + 1
		else
			fail(text, i, "expected ',' or ']'")
		end
	end
end

local function decode_object(text, i, depth)
	if depth > MAX_DEPTH then fail(text, i, "nesting too deep") end
	i = skip_ws(text, i + 1)	-- 跳过 '{'
	local out = {}
	if text:sub(i, i) == "}" then return out, i + 1 end
	while true do
		if text:sub(i, i) ~= '"' then fail(text, i, "expected object key string") end
		local k
		k, i = decode_string(text, i)
		i = skip_ws(text, i)
		if text:sub(i, i) ~= ":" then fail(text, i, "expected ':'") end
		i = skip_ws(text, i + 1)
		local v
		v, i = decode_value(text, i, depth + 1)
		out[k] = v
		i = skip_ws(text, i)
		local c = text:sub(i, i)
		if c == "," then
			i = skip_ws(text, i + 1)
		elseif c == "}" then
			return out, i + 1
		else
			fail(text, i, "expected ',' or '}'")
		end
	end
end

function decode_value(text, i, depth)
	if depth > MAX_DEPTH then fail(text, i, "nesting too deep") end
	local c = text:sub(i, i)
	if c == "{" then return decode_object(text, i, depth) end
	if c == "[" then return decode_array(text, i, depth) end
	if c == '"' then return decode_string(text, i) end
	if c == "t" then
		if text:sub(i, i + 3) == "true" then return true, i + 4 end
		fail(text, i, "invalid literal")
	end
	if c == "f" then
		if text:sub(i, i + 4) == "false" then return false, i + 5 end
		fail(text, i, "invalid literal")
	end
	if c == "n" then
		if text:sub(i, i + 3) == "null" then return nil, i + 4 end
		fail(text, i, "invalid literal")
	end
	if c == "-" or (c >= "0" and c <= "9") then return decode_number(text, i) end
	fail(text, i, "unexpected character")
end

function json.decode(text)
	if type(text) ~= "string" then error("json.decode: expected string", 0) end
	local i = skip_ws(text, 1)
	local v
	v, i = decode_value(text, i, 0)
	i = skip_ws(text, i)
	if i <= #text then fail(text, i, "trailing characters after top-level value") end
	return v
end

_G.__BOT4CJ_JSON = json
return json

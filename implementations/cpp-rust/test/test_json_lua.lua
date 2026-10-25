-- json.lua 单元测试（Lua 侧严格 JSON 编解码）
-- 用法（项目根目录）: luajit test/test_json_lua.lua
--
-- 与 C++ 侧的 src/jsonparse.cpp 语义对齐（严格语法、深度上限、转义与代理对），
-- 两边用同一批边界形态钉住；差异只有一处且是 Lua 表语义决定的：JSON null
-- 解码为 nil（Lua 表无法区分「字段为 null」与「字段不存在」）。

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local json = dofile("modules/lib/json.lua")

-- ---- 标量解码 ----
check("null → nil", json.decode("null") == nil)
check("true", json.decode("true") == true)
check("false", json.decode("false") == false)
check("整数", json.decode("42") == 42)
check("负整数", json.decode("-7") == -7)
check("浮点", json.decode("3.5") == 3.5)
check("指数", json.decode("1e3") == 1000.0)
check("带空白", json.decode("  \t\r\n 1 ") == 1)
check("字符串", json.decode('"hi"') == "hi")

-- ---- 容器解码 ----
local v = json.decode('{"a":1,"b":[true,"x"],"c":{"d":2.5},"e":null}')
check("对象字段", v.a == 1)
check("数组长度", #v.b == 2)
check("数组元素", v.b[1] == true and v.b[2] == "x")
check("嵌套对象", v.c.d == 2.5)
check("null 字段等同缺失", v.e == nil)
check("空对象", type(json.decode("{}")) == "table")
check("空数组", type(json.decode("[]")) == "table")

-- ---- 字符串转义 ----
check("常见转义", json.decode('"a\\nb\\t\\"c\\\\d\\/"') == "a\nb\t\"c\\d/")
check("\\u BMP", json.decode('"\\u4e2d"') == "\228\184\173")		-- U+4E2D 中
check("代理对 → 4 字节 UTF-8", json.decode('"\\ud83d\\ude00"')
	== string.char(0xF0, 0x9F, 0x98, 0x80))				-- U+1F600
check("原样 UTF-8 透传", json.decode('"机器人"') == "机器人")

-- ---- 编码 ----
check("编码整数", json.encode(42) == "42")
check("编码负整数", json.encode(-7) == "-7")
check("整数值浮点写成整数形态", json.encode(4096.0) == "4096")
check("编码浮点", json.encode(3.5) == "3.5")
check("编码布尔", json.encode(true) == "true")
check("编码 null 哨兵", json.encode(json.null) == "null")
-- 空数组与空对象在 JSON 里是不同的东西，Lua 的 {} 无法自行分辨，故空数组要显式哨兵
check("编码空数组哨兵", json.encode(json.empty_array) == "[]")
check("对象里的空数组", json.encode({ required = json.empty_array }) == '{"required":[]}')
check("空数组与 null 不相混", json.decode(json.encode(json.empty_array)) ~= json.null)
check("编码字符串转义", json.encode("a\nb") == '"a\\nb"')
check("编码数组", json.encode({ 1, 2, 3 }) == "[1,2,3]")
check("编码空表 → 对象", json.encode({}) == "{}")
check("编码对象（单键）", json.encode({ a = 1 }) == '{"a":1}')

-- ---- 往返 ----
do
	local text = '{"model":"m","messages":[{"role":"user","content":"你好"}],"n":3,"f":0.5}'
	local back = json.decode(text)
	check("往返：字段保持", back.model == "m" and back.n == 3 and back.f == 0.5)
	check("往返：再编码可再解码", json.decode(json.encode(back)).messages[1].content == "你好")
end

-- ---- 坏输入必须报错（不是静默返回 nil）----
local function rejects(text, why)
	local ok = pcall(json.decode, text)
	check("拒绝: " .. why, not ok)
end
rejects("", "空串")
rejects('{"a":1}garbage', "尾随字符")
rejects('"abc', "未闭合字符串")
rejects('"a\\qb"', "非法转义")
rejects('"\\ud83d"', "孤立高代理")
rejects('"\\ude00"', "孤立低代理")
rejects('"a\nb"', "未转义控制字符")
rejects("01", "前导零")
rejects("+1", "正号")
rejects(".5", "无整数部分")
rejects("1.", "无小数部分")
rejects("NaN", "NaN 字面量")
rejects("{1:2}", "对象键非字符串")
rejects('{"a" 1}', "缺冒号")
rejects("[1 2]", "数组缺逗号")
rejects('{"a":', "截断")

do
	local deep = string.rep("[", 70) .. string.rep("]", 70)
	local ok = pcall(json.decode, deep)
	check("拒绝: 嵌套过深", not ok)
	local shallow = string.rep("[", 40) .. "1" .. string.rep("]", 40)
	check("上限之下可解", type(json.decode(shallow)) == "table")
end

-- ---- 坏编码也必须报错 ----
-- 注：Lua 表里 `{a = nil}` 与 `{}` 是同一张表（键根本不存在），故「nil 字段」
-- 没有可构造的用例；encoder 里那条防御分支不可达，此处只验证其余形态。
check("空表按对象编码", json.encode({ a = nil }) == "{}")
check("拒绝非字符串键", not pcall(json.encode, { [1.5] = "x" }))
check("拒绝非有限数", not pcall(json.encode, 0 / 0))
check("拒绝函数", not pcall(json.encode, print))

-- ---- 数组内 null：空洞即稀疏表，重编码报错（头注释已声明的有损点）----
local sp = json.decode("[1,null,3]")
check("数组内 null 留下空洞", sp[1] == 1 and sp[2] == nil and sp[3] == 3,
	"no N/2/3 " .. tostring(sp[1]))
check("空洞数组重编码报错（数字键非字符串）",
	not pcall(json.encode, sp))
check("全 null 数组解码为空表", next(json.decode("[null,null]")) == nil)
check("全 null 数组重编码为空对象", json.encode(json.decode("[null,null]")) == "{}")

tester.summary("json.lua 单测")

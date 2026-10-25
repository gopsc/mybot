-- test_utf8.lua —— lib/utf8.lua 的判据与消毒（2026-09-21 审计 AG-1）
-- 用法（项目根目录）: luajit test/test_utf8.lua
--
-- 本文件与 test/cpp/test_util.cpp 的 utf8_* 用例**同表向量**：两边判据必须一致，
-- 否则「宿主消毒过的报文」与「驱动侧看到的报文」会对「什么算非法」产生分歧。
-- 改动任一侧的判据时，两边用例都要过。

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local utf8 = dofile("modules/lib/utf8.lua")

local function bytes(...)
	local out = {}
	for _, b in ipairs({ ... }) do out[#out + 1] = string.char(b) end
	return table.concat(out)
end

-- ---- 合法序列（含各长度边界与上限）----
local VALID = {
	{ "空串", "" },
	{ "纯 ASCII", "plain ascii" },
	{ "控制字符合法", bytes(0x00, 0x7f) },
	{ "U+0080 最短二字节", bytes(0xc2, 0x80) },
	{ "U+07FF 二字节上限", bytes(0xdf, 0xbf) },
	{ "U+0800 最短三字节", bytes(0xe0, 0xa0, 0x80) },
	{ "U+FFFD", bytes(0xef, 0xbf, 0xbd) },
	{ "U+10000 最短四字节", bytes(0xf0, 0x90, 0x80, 0x80) },
	{ "U+10FFFF 上限", bytes(0xf4, 0x8f, 0xbf, 0xbf) },
	{ "真多字节", "舵机温度" },
}
for _, v in ipairs(VALID) do
	check("valid 接受：" .. v[1], utf8.valid(v[2]), "被误判为非法")
end

-- ---- 非法序列（每一类都必须拒）----
-- 这些类别与 C++ 侧 utf8_rejects_every_illegal_class 逐条对应。
local INVALID = {
	{ "原始坏字节 0xFF（AG-1 复现输入）", bytes(0xff) },
	{ "孤立续字节 0x80", bytes(0x80) },
	{ "ASCII 中间的孤立续字节", bytes(0x41, 0x80, 0x42) },
	{ "过长编码 C0 AF", bytes(0xc0, 0xaf) },
	{ "过长编码 C1 BF", bytes(0xc1, 0xbf) },
	{ "过长编码 E0 80 AF", bytes(0xe0, 0x80, 0xaf) },
	{ "过长编码 F0 80 80 AF", bytes(0xf0, 0x80, 0x80, 0xaf) },
	{ "UTF-16 代理区 ED A0 80", bytes(0xed, 0xa0, 0x80) },
	{ "UTF-16 代理区 ED BF BF", bytes(0xed, 0xbf, 0xbf) },
	{ "超过 U+10FFFF（F4 90..）", bytes(0xf4, 0x90, 0x80, 0x80) },
	{ "超过 U+10FFFF（F5..）", bytes(0xf5, 0x80, 0x80, 0x80) },
	{ "0xFE", bytes(0xfe) },
	{ "三字节序列被截断", bytes(0xe4, 0xb8) },
	{ "四字节序列被截断", bytes(0xf0, 0x9f, 0x98) },
}
for _, v in ipairs(INVALID) do
	check("valid 拒绝：" .. v[1], not utf8.valid(v[2]), "被误判为合法")
end

-- ---- 消毒：替换成 U+FFFD，合法前缀逐字节不变 ----
do
	local bad = bytes(0x41, 0xff, 0x42)		-- "A\xffB"
	local fixed = utf8.sanitize(bad)
	check("sanitize：坏字节替换为 U+FFFD 且保留两侧 ASCII",
		fixed == bytes(0x41, 0xef, 0xbf, 0xbd, 0x42), fixed:byte(1, -1))
	check("sanitize：产物合法", utf8.valid(fixed))
end

do
	-- 合法内容（含多字节与 NUL）逐字节不变
	local good = "舵机" .. bytes(0x00, 0x7f)
	check("sanitize：合法内容逐字节不变", utf8.sanitize(good) == good)
end

do
	-- 连续坏字节折叠成一个替换符 + 计数（与 C++ 侧同文案）
	local run = string.rep(bytes(0xff), 5)
	local fixed = utf8.sanitize(bytes(0x41) .. run .. bytes(0x42))
	check("sanitize：连续坏字节折叠且计数", utf8.valid(fixed)
		and fixed:find("[! invalid UTF-8 bytes omitted5 bytes]", 1, true) ~= nil, fixed)
	check("sanitize：折叠后首尾仍是原来的 ASCII",
		fixed:sub(1, 1) == "A" and fixed:sub(-1) == "B")
	check("sanitize：单个坏字节不加计数说明（避免噪音）",
		utf8.sanitize(bytes(0xff)) == bytes(0xef, 0xbf, 0xbd))
end

do
	-- 混合 + 幂等 + 端到端「消毒后必合法」
	local mixed = "舵" .. bytes(0xff, 0xff, 0x80) .. "机"
		.. bytes(0xe0, 0x80, 0xaf) .. "温"
	check("混合串本身非法", not utf8.valid(mixed))
	local once = utf8.sanitize(mixed)
	check("混合串消毒后合法", utf8.valid(once))
	check("消毒幂等", utf8.sanitize(once) == once)
	check("混合串保留合法多字节两端", once:sub(1, 3) == "舵" and once:sub(-3) == "温")
end

do
	-- 输出上限截断正好切在多字节中间（run_command 64KB 边界的真实形态）
	local s = string.rep("a", 10) .. bytes(0xe4, 0xb8)	-- 半个「中」
	check("截断尾部本身非法", not utf8.valid(s))
	check("截断尾部消毒后合法", utf8.valid(utf8.sanitize(s)))
end

do
	-- 非字符串入参：valid 判假、sanitize 原样返回（不抛错，供探测用）
	check("valid(nil) 为假", not utf8.valid(nil))
	check("valid(数字) 为假", not utf8.valid(42))
	check("sanitize(nil) 原样返回", utf8.sanitize(nil) == nil)
end

tester.summary("utf8.lua 单测")

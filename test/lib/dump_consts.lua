-- dump_consts.lua —— 把后端 consts 表逐行打印为「NAME=值」（构建期常量抽取用）
-- 用法：luajit test/dump_consts.lua <后端文件>
--
-- 2026-10-01 加固（P0 复发预防）：gen_const_check.cmake 对 hal_backend_glibc.lua
-- 的 consts 表改**执行期求值**——由 LuaJIT 解释器加载后端、把表原样倒出来，
-- 不再用正则匹配「NAME = 值」的书写风格。抽取契约从「正则模式 ↔ 书写风格」
-- 收窄为「后端导出 M.consts 表」这一条接口契约（本来就在后端接口注释里写明）。
-- 键排序保证输出确定（pairs 无序）；只输出 number 值——标识符/字符串值不是
-- 本自检要钉的编号/布局常量。
local M = assert(dofile(assert(arg[1], "用法：luajit test/dump_consts.lua <后端文件>")))
assert(type(M) == "table" and type(M.consts) == "table",
	"后端未导出 consts 表（M.consts）——常量抽取失败：后端接口契约被破坏，"
	.. "请核对「平台常量（导出为 M.consts 表）」一节")
local keys = {}
for k in pairs(M.consts) do
	keys[#keys + 1] = k
end
table.sort(keys)
for _, k in ipairs(keys) do
	local v = M.consts[k]
	if type(v) == "number" then
		io.write(k, "=", tostring(v), "\n")
	end
end

-- H03ARR.lua - H-03 修复验证驱动（数组入参 / 出参双向）
-- 经 src 引用列，data.values 是守护 arr_src 的 values(JsonArray) 快照。
-- 修复前：入参 JsonArray 被 call_lua 静默丢弃（data.values 为 nil）；
--         出参 Lua 表（list）被 LUA_TTABLE 跳过。修复后应双向贯通。
--
-- 26.5 单测覆盖：无单元/端到端测试；仅用于 H-03 修复验证，未接入 run_all.sh 守门。
--
-- 标准前导：drv_common 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

function build(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	return { result = "OK" }
end

function destroy(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	return { result = "OK" }
end

function call(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end

	-- 入参方向：JsonArray 应已转成 Lua 表（# 可测长、下标可取元素、可迭代求和）
	local values = data.values
	local n, sum, first = 0, 0, 0
	if type(values) == "table" then
		n = #values
		for i = 1, n do sum = sum + values[i] end
		first = values[1] or 0
	else
		return err("H-03 input: values is not a Lua table (got " .. type(values) .. ")")
	end

	-- 出参方向：返回表内含 list 数组，应被还原为 JsonArray
	return {
		result = "OK",
		values_n = n,
		values_first = first,
		values_sum = sum,
		list = { 10, 20, 30 }
	}
end
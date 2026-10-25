-- Relay 中继测试模块
-- bot4cj 仓颉语言机器人框架
-- 配合通用 controller 引用机制使用：先处理收到的参数（test → delay），
-- 返回值由框架与元数据合并后转发给 controller 指定的硬件变量（如 Timer）
-- 用法：在结构脚本中定义 @Relay 矩阵并带 controller 列，见 robots/relay-test.sql

-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))


-- 【配置脚本】纯软件模块，没有资源需要申请
--
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Relay builder func get a table --------", data)

	return {  result = "OK"  }

end


-- 【销毁Relay】没有资源需要释放
--
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用Relay】
-- 把收到的 test 参数转换为 delay 返回，由框架转发给 controller
--
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Relay caller func get a table --------", data)

	-----------------------------------------------------
	local delay = tonumber(data.test)
	if delay == nil then
		delay = 0
	end

	print(string.format("Relay: test=%s note=%s -> delay=%s",
		tostring(data.test), tostring(data.note), tostring(delay)))

	-- 返回值将与元数据合并后转发给 controller
	return {  delay = delay  }

end

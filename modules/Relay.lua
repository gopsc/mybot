-- Relay 中继测试模块
-- bot4cj 仓颉语言机器人框架
-- 配合通用 controller 引用机制使用：先处理收到的参数（test → delay），
-- 返回值由框架与元数据合并后转发给 controller 指定的硬件变量（如 Timer）
-- 用法：在结构脚本中定义 @Relay 矩阵并带 controller 列，见 robots/relay-test.sql

-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")


-- 【配置脚本】纯软件模块，没有资源需要申请
--
function build(data)

	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Relay builder func get a table --------", data)

	return {  result = "OK"  }

end


-- 【销毁Relay】没有资源需要释放
--
function destroy(data)

	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	return {  result = "OK"  }

end


-- 【调用Relay】
-- 把收到的 test 参数转换为 delay 返回，由框架转发给 controller
--
function call(data)

	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Relay caller func get a table --------", data)

	-----------------------------------------------------
	local delay = tonumber(data.test)
	if delay == nil then
		delay = 0
	end

	print(string.format("Relay: test=%s note=%s -> delay=%d",
		tostring(data.test), tostring(data.note), delay))

	-- 返回值将与元数据合并后转发给 controller
	return {  delay = delay  }

end

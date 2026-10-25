-- Relay 中继测试模块
-- bot4cj 仓颉语言机器人框架
-- 配合通用 controller 引用机制使用：先处理收到的参数（test → delay），
-- 返回值由框架与元数据合并后转发给 controller 指定的硬件变量（如 Timer）
-- 用法：在结构脚本中定义 @Relay 矩阵并带 controller 列，见 robots/relay-test.sql

-- 标准前导：print_table 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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
	-- 审计 P3：走 finite_of（drv_common 单点）。NaN 非 nil，`== nil` 兜不住，
	-- 会把 NaN 当 delay 转发给 controller，报错点落在下游 Timer 上，
	-- 排障看不出源头是本行的入参。保留「缺失/占位符按 0」这条既有语义
	-- （动作脚本里的 "-" 单元格依赖它），只是把"非法"与"缺失"同等对待。
	local delay = finite_of(data.test)
	if delay == nil then
		delay = 0
	end

	print(string.format("Relay: test=%s note=%s -> delay=%s",
		tostring(data.test), tostring(data.note), tostring(delay)))

	-- 返回值将与元数据合并后转发给 controller
	return {  delay = delay  }

end

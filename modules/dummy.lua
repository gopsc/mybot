-- Dummy 无实际用处的测试模块
-- bot4cj 仓颉语言机器人框架
-- 不连接任何硬件，仅用于测试 MtVars_Lua 的完整生命周期
-- （build 元数据传递、call 参数合并、destroy 释放）以及返回值回传
-- 用法：在机器人结构脚本 .mt 中添加 @Dummy 矩阵并定义 name 列，
--       然后在 @Action 中以 dummy.echo 之类的列名调用
--
-- 26.5 单测覆盖：由 run_all.sh 的 servo_virt / ctrl2_basic / dev_expr e2e 覆盖
-- （scripts/test/servo.mt + ctrl2_basic.mt + dev_expr_cell.mt）


-- 标准前导：print_table/drv_common 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))



-- 内部状态：仅存于Lua状态机内存中，destroy后即废弃
local call_count = 0



-- 【配置脚本】
-- 该脚本负责初始化Dummy，纯软件模块没有资源需要申请
--
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua builder func get a table --------", data)

	call_count = 0		-- 重置内部状态

	return {
		result = "OK",
		hint   = "Dummy is ready (and will do nothing useful)"
	}

end

-- 【销毁Dummy的脚本】没有资源需要释放
--
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua ender func get a table --------", data)

	print(string.format("Dummy served %d call(s) in its meaningless life", call_count))

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用Dummy】
-- 什么都不做，仅统计调用次数并把收到的参数原样（或回声）返回
-- NOTE(20260902-qing): 接收一个参数（表），返回一个结果（表）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua caller func get a table --------", data)

	call_count = call_count + 1

	-----------------------------------------------------
	-- 可选的回声参数：传入 echo 则原样返回，不传则返回固定问候
	local echo = data.echo
	if echo == nil then
		echo = "hello from dummy"
	end

	-- 返回字典
 	return {
		result = "OK",
		count  = call_count,
		echo   = echo
	}

end
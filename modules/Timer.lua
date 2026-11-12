-- Timer 软件定时器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 在未来替代内建的Speaker（Speaker目前仅负责延时）
--
-- 26.5 单测覆盖：由 run_all.sh 的 mtmerge_e2e / daemon_build_raise / signal_halt e2e 覆盖
-- （Timer 出现在 .tmp/mtm/robot.sql / .tmp/fixmod.sql / .tmp/signal_robot.sql 夹具）


-- 标准前导：HAL/print_table/drv_common 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))




-- 【配置脚本】
-- 该脚本负责初始化Timer，纯软件定时器没有资源需要申请
--
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua builder func get a table --------", data)

	return {  result = "OK"  }	-- 返回成功信号

end

-- 【销毁Timer的脚本】没有资源需要释放
--
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua ender func get a table --------", data)

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用Timer】
-- 阻塞指定的毫秒数，作为动作矩阵的节拍（beat）
-- NOTE(20260902-qing): 接收一个参数（表），返回一个结果（表）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua caller func get a table --------", data)

	-----------------------------------------------------
	local delay = data.delay
	if delay == nil then	-- 检查延时参数是否存在
		return err("Invalid Argument: delay")
	end

	-- 审计 2026-09-20（中）：必须过 finite_of。tonumber("nan") 得到 NaN，
	-- `delay < 0` 对 NaN 恒假故放行；math.floor(NaN+0.5) 仍是 NaN，
	-- `ms > 4294967` 同样恒假——于是请求变成「睡 NaN 毫秒」：FFI 侧把 NaN
	-- 转成 unsigned int 得 0，实际几乎不睡（节拍丢失）却返回 slept=nan。
	delay = finite_of(delay)
	if delay == nil then	-- 检查延时参数是否是数值（含非有限）
		return err("Invalid Argument: delay (not a finite number)")
	end

	if delay < 0 then	-- 延时不得为负
		return err("Invalid Argument: delay (negative)")
	end

	-----------------------------------------------------
	local ms = math.floor(delay + 0.5)	-- 舍入为整数毫秒

	-- HAL 的 usleep 收 unsigned int 微秒（上限约 4294967ms ≈ 71.6 分钟），
	-- 超限会 32 位回绕成随机短延时——静默破坏节拍，显式报错
	if ms > 4294967 then
		return err("Invalid Argument: delay exceeds usleep limit (max 4294967 ms)")
	end

	milli_sleep(ms)			-- 阻塞指定毫秒数

	-- 返回字典
 	return {
		result = "OK",
		slept  = ms
	}

end
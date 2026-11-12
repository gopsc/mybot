-- Servo 舵机驱动模块
-- bot4cj 仓颉语言机器人框架
-- 由仓颉内建版本（MtVars_Servo + hd/Servo.cj）迁移而来：
-- 对输入角度做 offset 漂移、|min|/|max| 限幅、max<0 反向处理，
-- 返回 {channel, angle}，由框架的 controller 机制转发给 PWM 控制器（如 PCA9685）
--
-- 元数据列：max/min/offset/channel（"-" 或非法值按 0 处理，与仓颉版 parseMt 首行语义一致）
-- 输入参数：angle（支持浮点）
-- 用法见 robots/spider1.sql 的 Servo 表与 scripts/*.mt 动作脚本

-- 标准前导：print_table 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))


-- 占位符 "-" 或非法值按 0 处理。
-- 审计 2026-09-20（中）：必须过 finite_of —— 本地 `tonumber(v) or 0` 挡不住
-- NaN（NaN 是 truthy 且非 nil），NaN 的 max/min/offset 会让第 89-93 行每一道
-- 限幅比较恒假，保护钳位整体失效；而 drv_common 早已提供 finite_of 单点，
-- 这里此前是自造的第二份判定（正是审计要收口的形态）。
local function num_or_zero(v)
	local n = finite_of(v)
	if n == nil then return 0 end
	return n
end


-- 【配置脚本】纯软件模块，没有资源需要申请
--
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Servo builder func get a table --------", data)

	return {  result = "OK"  }

end


-- 【销毁Servo】没有资源需要释放
--
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用Servo】
-- 角度处理管线（与仓颉版 Servo.setAngle 一致）：
--   angle + offset → 限幅 [|min|, |max|] → max < 0 时反向 (180 - a)
--
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Servo caller func get a table --------", data)

	-----------------------------------------------------
	-- 审计 2026-09-20（中）：angle 必须过 finite_of。NaN 会让第 85-89 行的
	-- 每一道限幅比较都为假（NaN 与任何数比较恒假），0–180 的执行器保护钳位
	-- 形同不存在，NaN 一路作为指令角度转给 controller/舵机。
	-- （max/min/offset 走 num_or_zero，已由 finite_of 兜底。）
	local angle = finite_of(data.angle)
	if angle == nil then	-- 检查angle参数是否存在且为有限数值
		return err("Invalid Argument: angle (missing or not a finite number)")
	end

	-- 26.3：与同函数 angle（上面）及 max/min/offset（num_or_zero → finite_of）
	-- 同口径。旧的 tonumber 放行 'nan'/'1e400'（出的是 number，`== nil` 为假），
	-- 于是 { channel = NaN } 以**成功形状**返回（本驱动的正常返回没有 result 键），
	-- 由框架合并进元数据后转发给 controller/PCA9685——NaN 通道号进 JSON 变 null，
	-- 下游拿到空值而非报错。
	local channel = finite_of(data.channel)
	if channel == nil then	-- 检查channel参数是否存在且为有限数值
		return err("Invalid Argument: channel (missing or not a finite number)")
	end

	local max    = num_or_zero(data.max)
	local min    = num_or_zero(data.min)
	local offset = num_or_zero(data.offset)

	-----------------------------------------------------
	local a = angle + offset			-- 加上漂移值
	if a > math.abs(max) then a = math.abs(max) end
	if a < math.abs(min) then a = math.abs(min) end
	if max < 0 then a = 180 - a end		-- 负max表示舵机方向相反
	if a < 0 then a = 0 end
	if a > 180 then a = 180 end		-- 物理角度限幅，防 offset/|max| 配置击穿下游（PCA9685 侧亦限幅）

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("Servo: angle=%s offset=%s -> %s (channel %s)",
			tostring(angle), tostring(offset), tostring(a), tostring(channel)))
	end

	-- 返回值将与元数据合并后由框架转发给 controller
	return {  channel = channel, angle = a  }

end

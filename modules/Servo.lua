-- Servo 舵机驱动模块
-- bot4cj 仓颉语言机器人框架
-- 由仓颉内建版本（MtVars_Servo + hd/Servo.cj）迁移而来：
-- 对输入角度做 offset 漂移、|min|/|max| 限幅、max<0 反向处理，
-- 返回 {channel, angle}，由框架的 controller 机制转发给 PWM 控制器（如 PCA9685）
--
-- 元数据列：max/min/offset/channel（"-" 或非法值按 0 处理，与仓颉版 parseMt 首行语义一致）
-- 输入参数：angle（支持浮点）
-- 用法见 robots/spider1.sql 的 Servo 表与 scripts/*.mt 动作脚本

-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")


-- 占位符 "-" 或非法值按 0 处理
local function num_or_zero(v)
	local n = tonumber(v)
	if n == nil then return 0 end
	return n
end


-- 【配置脚本】纯软件模块，没有资源需要申请
--
function build(data)

	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Servo builder func get a table --------", data)

	return {  result = "OK"  }

end


-- 【销毁Servo】没有资源需要释放
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


-- 【调用Servo】
-- 角度处理管线（与仓颉版 Servo.setAngle 一致）：
--   angle + offset → 限幅 [|min|, |max|] → max < 0 时反向 (180 - a)
--
function call(data)

	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Servo caller func get a table --------", data)

	-----------------------------------------------------
	local angle = tonumber(data.angle)
	if angle == nil then	-- 检查angle参数是否存在且为数值
		return {
			result = "ERR",
			message = "Invalid Argument: angle (missing or not a number)"
		}
	end

	local channel = tonumber(data.channel)
	if channel == nil then	-- 检查channel参数是否存在且为数值
		return {
			result = "ERR",
			message = "Invalid Argument: channel (missing or not a number)"
		}
	end

	local max    = num_or_zero(data.max)
	local min    = num_or_zero(data.min)
	local offset = num_or_zero(data.offset)

	-----------------------------------------------------
	local a = angle + offset			-- 加上漂移值
	if a > math.abs(max) then a = math.abs(max) end
	if a < math.abs(min) then a = math.abs(min) end
	if max < 0 then a = 180 - a end		-- 负max表示舵机方向相反

	print(string.format("Servo: angle=%s offset=%s -> %s (channel %d)",
		tostring(angle), tostring(offset), tostring(a), channel))

	-- 返回值将与元数据合并后由框架转发给 controller
	return {  channel = channel, angle = a  }

end

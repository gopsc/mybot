-- GPIO Linux 标准字符设备（gpiod uAPI）驱动模块
-- bot4cj 仓颉语言机器人框架
--
-- 任何 Linux（内核 >= 4.8，CONFIG_GPIO_CDEV 开启）通用：树莓派/瑞芯微/
-- 全志等仅芯片路径与线号不同，皆走 /dev/gpiochipN ioctl（见 HAL.lua GPIO 段）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE GPIO (
--       name      String,
--       chip      String,
--       offset    String,
--       direction String,
--       active    String,
--       init      String
--   );
--   INSERT INTO GPIO (name, chip, offset, direction, active, init)
--     VALUES ('led-0', '/dev/gpiochip0', '17', 'out', 'high', '0');
--   INSERT INTO GPIO (name, chip, offset, direction, active, init)
--     VALUES ('sw-0', '/dev/gpiochip0', '27', 'in', '-', '-');
-- chip    /dev/gpiochipN：Pi 4/Bullseye 为 gpiochip0；Pi 5 主 GPIO 在 RP1 上
--         为 gpiochip4（用 gpiodetect/gpioinfo 确认）
-- offset  控制器线号（Pi 上即 BCM 号）；勿写 '-'（归一为 0 会误用 0 号线）
-- direction out = 输出，in = 输入（二选一，必填）
-- active  low = 低电平有效（可选，缺省 high）
-- init    输出模式的上电初值 0/1（可选，缺省 0）
--
-- call 参数：out 模式带 value（0/1，非 0 归一为 1）；in 模式无参数，
-- 返回 { result, value }（0/1）
--
-- 权限：用户须在 gpio 组（树莓派 OS 已预置 udev 规则）
-- 二期可扩展：GPIO_GET_LINEEVENT 边沿事件输入（限位开关/编码器）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：GPIO 操作可能高频（点动），默认关闭逐次打印
local DEBUG = false

-- 模块级状态（build 申请，跨 call 保持于状态机内存，destroy 释放）
local hfd = -1		-- GPIO 句柄 fd
local is_output = false

-- 【配置脚本】请求 GPIO 线句柄
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		print("-------- GPIO builder func get a table --------")
		print_table(data)
		print("-----------------------------------------------")
	end

	-----------------------------------------------------
	local chip = data.chip
	if chip == nil or chip == "" or chip == "0" then
		return {
			result = "ERR",
			message = "Invalid Argument: chip (missing; also note offset must not be '-')"
		}
	end

	local offset = tonumber(data.offset)
	if offset == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: offset (must not be '-')"
		}
	end

	local direction = data.direction
	if direction ~= "out" and direction ~= "in" then
		return {
			result = "ERR",
			message = "Invalid Argument: direction (out|in)"
		}
	end

	local active_low = (data.active == "low")
	local init = tonumber(data.init) or 0

	-----------------------------------------------------
	-- 重复 build 先释放旧句柄再请求（防御：不依赖调用方保证 build 恰一次）
	if hfd >= 0 then
		gpio_free_line(hfd)
		hfd = -1
	end

	hfd = gpio_request_line(chip, offset, direction, init, active_low)
	if hfd < 0 then
		return {
			result = "ERR",
			message = "Failed to request GPIO line " .. tostring(offset) .. " on " .. tostring(chip)
		}
	end
	is_output = (direction == "out")

	print(string.format("GPIO init OK: %s line %d, %s%s",
		chip, offset, direction, active_low and " (active low)" or ""))
	return {  result = "OK"  }

end

-- 【销毁GPIO】释放线占用（句柄 fd 关闭即解绑）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	gpio_free_line(hfd)
	hfd = -1

	return {  result = "OK"  }

end


-- 【调用GPIO】输出模式：设值（data.value 0/1）；输入模式：读值
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		print("-------- GPIO caller func get a table --------")
		print_table(data)
		print("----------------------------------------------")
	end

	if hfd < 0 then
		return {
			result = "ERR",
			message = "GPIO not initialized (build first)"
		}
	end

	-----------------------------------------------------
	if is_output then
		local v = tonumber(data.value)
		if v == nil then
			return {
				result = "ERR",
				message = "Invalid Argument: value (0 or 1)"
			}
		end
		local norm = (v ~= 0) and 1 or 0		-- 非 0 归一为 1（内核语义）

		if not gpio_set_value(hfd, norm) then
			return {
				result = "ERR",
				message = "Failed to set GPIO value"
			}
		end

		if DEBUG then
			print(string.format("GPIO: set %d", norm))
		end
		return {  result = "OK", value = norm  }
	end

	-----------------------------------------------------
	-- 输入模式：读值
	local v = gpio_get_value(hfd)
	if v < 0 then
		return {
			result = "ERR",
			message = "Failed to get GPIO value"
		}
	end

	if DEBUG then
		print(string.format("GPIO: get %d", v))
	end
	return {  result = "OK", value = v  }

end

-- GPIO Linux 标准字符设备（gpiod uAPI）驱动模块
-- bot4cj 仓颉语言机器人框架
--
-- 任何 Linux（内核 >= 4.8，CONFIG_GPIO_CDEV 开启）通用：树莓派/瑞芯微/
-- 全志等仅芯片路径与线号不同，皆走 /dev/gpiochipN ioctl（见 lib/hal/gpio.lua）
--
-- 【为何不直接用 libgpiod（决策记录，#32）】
-- libgpiod 是 Linux GPIO 的推荐用户态封装，但本项目经 LuaJIT FFI 直调
-- gpiod uAPI（/dev/gpiochipN ioctl）：
--   1) 直调内核 uAPI 即规范本身（内核文档 gpio.rst 定义的字符设备 ABI），
--      libgpiod 只是其上的一层 C 封装，不改变 ABI 语义；
--   2) 零运行期依赖：FFI 直调只需 glibc，libgpiod 需额外安装 libgpiod2 且
--      C API（gpiod_line_request 等）需逐函数 FFI 声明并处理版本差异
--      （v1 chip 句柄 vs v2 line 句柄 API 不兼容）；
--   3) 本项目另有 I2C/SPI/UART 同为直调 ioctl（lib/hal/*.lua），GPIO 保持一致，
--      避免"一种总线一个封装库"的依赖碎片。
-- 若未来需要边沿事件（GPIO_GET_LINEEVENT）或更复杂配置，再评估 libgpiod v2。
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

-- 标准前导：HAL/print_table（部分驱动含 drv_common）经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：GPIO 操作可能高频（点动），默认关闭逐次打印
local DEBUG = false

-- 模块级状态（build 申请，跨 call 保持于状态机内存，destroy 释放）
local hfd = -1		-- GPIO 句柄 fd
local is_output = false

-- 句柄回滚（C-M3'）：build 中途抛 Lua error 时由 guard_build 调用（幂等）
local function rollback_hfd()
	if hfd >= 0 then
		gpio_free_line(hfd)
		hfd = -1
	end
end

local function build_impl(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		print("-------- GPIO builder func get a table --------")
		print_table(data)
		print("-----------------------------------------------")
	end

	-----------------------------------------------------
	local chip = data.chip
	if chip == nil or chip == "" or chip == "0" then
		return err("Invalid Argument: chip (missing; also note offset must not be '-')")
	end

	-- 26.3：finite_of 而非 tonumber——与同文件 init 列（下面 num_or）、value 列
	-- （call 段 finite_of）同口径，这是 GPIO 里最后一处裸 tonumber 数值列。
	-- 行为上非有限值本来也打不到硬件（hal/gpio.lua 的 offset 归一化对 NaN 由
	-- `offset ~= math.floor(offset)` 命中、对 inf 由 uint32 上界命中，均返回 -1），
	-- 但那条路径报的是「Failed to request GPIO line nan on /dev/gpiochipN」——
	-- 读起来像芯片坏了，而实际是配置列写了非数值。提前拦下让错误指名 offset 列。
	local offset = finite_of(data.offset)
	if offset == nil then
		return err("Invalid Argument: offset (must not be '-')")
	end

	local direction = data.direction
	if direction ~= "out" and direction ~= "in" then
		return err("Invalid Argument: direction (out|in)")
	end

	local active_low = (data.active == "low")
	-- init 列经 num_or 而非 `tonumber(x) or 0`：'nan' 过 tonumber 出的是 number
	-- （Lua 里 truthy），`or` 兜不住，会原样下发。后果被 HAL.gpio_request_line 的
	-- byte_of 兜底中和成 0（安全侧），故这是形态一致性修复而非行为修复——但同文件
	-- value 列（见 call 段的 finite_of）早已归一，两处口径不一即防护漂移。
	local init = num_or(data.init, 0)

	-----------------------------------------------------
	-- 重复 build 先释放旧句柄再请求（防御：不依赖调用方保证 build 恰一次）
	if hfd >= 0 then
		gpio_free_line(hfd)
		hfd = -1
	end

	hfd = gpio_request_line(chip, offset, direction, init, active_low)
	if hfd < 0 then
		return err("Failed to request GPIO line " .. tostring(offset) .. " on " .. tostring(chip))
	end
	is_output = (direction == "out")

	-- C-L7：与其他驱动的 DEBUG 约定一致——GPIO 点动高频，成功打印须门控
	if DEBUG then
		print(string.format("GPIO init OK: %s line %d, %s%s",
			chip, offset, direction, active_low and " (active low)" or ""))
	end
	return {  result = "OK"  }

end

-- build 全程守卫：异常折成 ERR 契约并回滚已请求的线句柄（drv_common.guard_build）
function build(data)
	return guard_build(rollback_hfd, build_impl, data)
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

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		print("-------- GPIO caller func get a table --------")
		print_table(data)
		print("----------------------------------------------")
	end

	if hfd < 0 then
		return err("GPIO not initialized (build first)")
	end

	-----------------------------------------------------
	if is_output then
		-- 审计 2026-09-20（中）：`(v ~= 0) and 1 or 0` 对 NaN 判**真**——Lua 里
		-- 只有 nil/false 为假，而 NaN ~= 0 恒为 true，于是 value="nan" 会把线
		-- **驱动到高电平**并返回 result="OK"。HAL.gpio_set_value 的 NaN→0 安全
		-- 缺省（fail-safe 低电平）在此被提前绕过，继电器/执行器类负载尤其危险。
		-- 非有限值必须在归一之前拦下：用 finite_of（NaN/inf/非数值 → nil）。
		local v = finite_of(data.value)
		if v == nil then
			return err("Invalid Argument: value (0 or 1)")
		end
		local norm = (v ~= 0) and 1 or 0		-- 非 0 归一为 1（内核语义）

		if not gpio_set_value(hfd, norm) then
			return err("Failed to set GPIO value")
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
		return err("Failed to get GPIO value")
	end

	if DEBUG then
		print(string.format("GPIO: get %d", v))
	end
	return {  result = "OK", value = v  }

end

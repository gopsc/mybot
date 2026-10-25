-- hal/gpio.lua —— HAL 的 GPIO 域（gpiod uAPI ABI v1）
-- bot4cj 仓颉语言机器人框架
--
-- 本文件是 modules/lib/HAL.lua 的**分块**，不是可独立加载的模块：由门面按序
-- loadfile 后以 ctx 表传入共享上下文（见门面「各总线域加载」段）。
-- 正文自 HAL.lua 逐字搬迁（26.2 按域拆分），注释与错误文案未改写。
local ctx = assert(..., "hal/gpio.lua 须由 modules/lib/HAL.lua 聚合加载（不支持单独 dofile）")
local HAL, ffi, bus, byte_of = ctx.HAL, ctx.ffi, ctx.bus, ctx.byte_of
local O_RDWR = ctx.O_RDWR

------------------------------------------------------------------
-- GPIO（gpiod uAPI ABI v1：/dev/gpiochipN ioctl）
------------------------------------------------------------------
-- 内核标准接口（>= 4.8），跨 SoC 通用：树莓派/瑞芯微/全志等仅路径与
-- 线号不同。结构体全部定宽字段，x86_64/aarch64 布局一致。
-- 2026-09-30 方案 A 重构：ffi.cdef 声明、尺寸自检、ioctl 编号常量全部下沉到后端，
-- 本域经 HAL.GPIO_* 访问（门面的后端加载段已重导出）。

-- 请求一条 GPIO 线，返回句柄 fd（供 set/get 使用）；失败返回 -1
-- direction: "out" | "in"；default_value：输出模式的上电值（0/1）
-- active_low：true = 低电平有效（可选）
function gpio_request_line(chip_path, offset, direction, default_value, active_low)
	if type(chip_path) ~= "string" then return -1 end
	-- 前缀取平台差异单点（阶段 A-2）；前缀如引入正则元字符需先转义
	if string.match(chip_path, "^" .. HAL.platform.gpio_prefix .. "%d+$") == nil then
		print("HAL: invalid gpiochip path: " .. tostring(chip_path))
		return -1
	end
	offset = tonumber(offset)
	-- 必须为非负整数：小数（如 17.9）写入 uint32 字段会被静默截断成另一个线号，
	-- 配置错误显式拒绝而非将错就错
	if offset == nil or offset < 0 or offset > 0xFFFFFFFF or offset ~= math.floor(offset) then
		print("HAL: invalid gpio offset: " .. tostring(offset))
		return -1
	end

	local chipfd = tonumber(HAL.sys.open(chip_path, O_RDWR + HAL.O_CLOEXEC))
	if chipfd == nil or chipfd < 0 then
		print("HAL: failed to open gpiochip: " .. chip_path)
		return -1
	end

	local flags
	if direction == "out" then
		flags = HAL.GPIOHANDLE_REQUEST_OUTPUT
	else
		flags = HAL.GPIOHANDLE_REQUEST_INPUT
	end
	if active_low then
		flags = flags + HAL.GPIOHANDLE_REQUEST_ACTIVE_LOW		-- 位不重叠，算术加即可（HAL 不加载位库）
	end

	local req = ffi.new("cj_gpiohandle_request")	-- ffi.new 零初始化
	req.lineoffsets[0] = offset
	req.flags = flags
	if direction == "out" then
		-- C2（2026-09-20 审计）：默认电平走 byte_of 归一化——旧的
		-- `tonumber(default_value) or 0` 挡不住 NaN（NaN 是 truthy），
		-- 而 `(NaN ~= 0)` 为真 → 配置写 "nan" 会把线**驱动到高电平**。
		-- byte_of 对非有限值返回 nil，回落 0（非有效电平 = 安全侧）。
		local dv = byte_of(default_value) or 0
		req.default_values[0] = (dv ~= 0) and 1 or 0	-- 内核语义：非 0 即有效电平
	end
	req.consumer_label = "bot4cj"
	req.lines = 1

	if HAL.sys.ioctl_p(chipfd, HAL.GPIO_GET_LINEHANDLE, req) ~= 0 or req.fd < 0 then
		print("HAL: failed to request gpio line " .. tostring(offset) ..
		      " on " .. chip_path)
		HAL.sys.close(chipfd)
		return -1
	end

	local hfd = tonumber(req.fd)
	HAL.sys.close(chipfd)		-- 取得句柄后 chip fd 即可关闭（内核 uAPI 约定）
	return hfd
end

-- 设置输出值（非 0 归一为 1，内核把非 0 一律当有效电平），成功返回 true
function gpio_set_value(hfd, v)
	hfd = tonumber(hfd)
	if hfd == nil or hfd < 0 then return false end
	local data = ffi.new("cj_gpiohandle_data")
	-- C2 审计同族（2026-09-20 评估）：与上面的 default_values 同口径——旧的
	-- `tonumber(v) or 0` 挡不住 NaN（NaN 是 truthy，`(NaN ~= 0)` 为真会把线
	-- **驱动到高电平**）。非有限值回落 0（安全侧）；有限值保持「非 0 归一为 1」
	-- 的既有语义（不用 byte_of：它把 300 这类越界值判非法，语义比这里更窄）。
	local n = bus.finite_of(v)
	data.values[0] = (n ~= nil and n ~= 0) and 1 or 0
	return HAL.sys.ioctl_p(hfd, HAL.GPIOHANDLE_SET_LINE_VALUES, data) == 0
end

-- 读取输入值，返回 0/1；失败返回 -1
function gpio_get_value(hfd)
	hfd = tonumber(hfd)
	if hfd == nil or hfd < 0 then return -1 end
	local data = ffi.new("cj_gpiohandle_data")
	if HAL.sys.ioctl_p(hfd, HAL.GPIOHANDLE_GET_LINE_VALUES, data) ~= 0 then return -1 end
	return tonumber(data.values[0])
end

-- 释放 GPIO 句柄（关闭句柄 fd 即释放线占用）
function gpio_free_line(hfd)
	hfd = tonumber(hfd)
	if hfd ~= nil and hfd >= 0 then HAL.sys.close(hfd) end
end

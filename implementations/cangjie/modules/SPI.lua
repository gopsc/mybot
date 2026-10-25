-- SPI 硬件

--
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 文件句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局；
-- -1 = 未打开，与 I2C/destroy 后状态一致）
local fd = -1

-- 全局传输延时（build 从元数据设置；call 随 fd 返回给引用本变量的设备驱动）
local delay_us = 0

function build(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- SPI.Lua builder func get a table --------", data)
	local path = data.path

	-- 检查文件句柄参数是否存在
	if path == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: path"
		}
	end

	-- 模式（0~3：CPOL/CPHA 组合，与 Linux spidev 一致）
	local spi_mode = tonumber(data.spi_mode)
	if spi_mode == nil or spi_mode < 0 or spi_mode > 3 then
		return {
			result = "ERR",
			message = "Invalid Arguments: spi_mode (0~3)"
		}
	end

	-- 比特（每字位数，7~16）
	local bits = tonumber(data.bits)
	if bits == nil or bits < 7 or bits > 16 then
		return {
			result = "ERR",
			message = "Invalid Arguments: bits (7~16)"
		}
	end


	-- 速率（Hz，必须为正）
	local speed = tonumber(data.speed)
	if speed == nil or speed <= 0 then
		return {
			result = "ERR",
			message = "Invalid Arguments: speed (>0)"
		}
	end

	-- 延时（单次传输后 CS 拉高前等待，us，非负）
	local delay = tonumber(data.delay)
	if delay == nil or delay < 0 then
		return {
			result = "ERR",
			message = "Invalid Arguments: delay (>=0)"
		}
	end

	-- 重复 build 先关旧 fd 再开新（防御：不依赖调用方保证 build 恰一次；
	-- 与 I2C/GPIO 的守卫一致——否则旧 fd 永久泄漏）
	if fd ~= nil and fd > 0 then
		spi_close(fd)
		fd = -1
	end

	-- 开始执行
	fd = spi_open(path)
	if fd <= 0 then
		return {
			result = "ERR",
			message = "Failed to open SPI file"
		}
	end

	delay_us = delay or 0
	local res = spi_setup(fd, spi_mode, bits, speed, delay)
	if res ~= 0  then
		-- setup 失败必须关掉已打开的 fd：否则半配置句柄泄漏并残留在全局，
		-- 后续 call 会把它流给下游设备驱动
		spi_close(fd)
		fd = -1
		return {
			result = "ERR",
			message = "Failed to setup SPI device"
		}
	end

	return {
		result = "OK",
		fd = fd
	}

end




function destroy(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- SPI.Lua ender func get a table --------", data)

	spi_close(fd)
	fd = -1

	return {
		result = "OK"
	}

end





function call(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- SPI.Lua caller func get a table --------", data)

	-- build 未成功不下发无效 fd（与 UART.lua 的校验对齐）
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "SPI not opened (build first)"
		}
	end

	return {
		result = "OK",
		fd = fd,
		delay = delay_us
	}

end

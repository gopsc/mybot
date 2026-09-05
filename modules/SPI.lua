-- SPI 硬件

--
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/HAL.lua")
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")

SPI_SUCCESS = 0
SPI_FAILED = 1

-- 全局文件句柄
fd = 0

-- 全局传输延时（build 从元数据设置；call 随 fd 返回给引用本变量的设备驱动）
delay_us = 0

function build(data)

	-- 检查该参数是否是一张表
	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
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

	-- 模式
	local spi_mode = data.spi_mode
	if spi_mode == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: spi_mode"
		}
	end
	print(spi_mode)
	spi_mode = tonumber(spi_mode)

	-- 比特
	local bits = data.bits
	if bits == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: bits"
		}
	end
	bits = tonumber(bits)


	-- 速率
	local speed = data.speed
	if speed == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: speed"
		}
	end
	speed = tonumber(speed)

	--
	local delay = data.delay
	if delay == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: delay"
		}
	end
	delay = tonumber(delay)

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
	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	dbg_table("-------- SPI.Lua ender func get a table --------", data)
	print(string.format("now fd: %i", fd))

	spi_close(fd)
	fd = -1

	return {
		result = "OK"
	}

end





function call(data)

	-- 检查该参数是否是一张表
	if type(data) ~= "table" then
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	dbg_table("-------- SPI.Lua caller func get a table --------", data)

	return {
		fd = fd,
		delay = delay_us
	}

end

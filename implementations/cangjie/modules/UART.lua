-- UART 硬件（串口总线矩阵）

--
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 文件句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局）
local fd = 0

-- 全局波特率（build 从元数据设置；call 随 fd 返回给引用本变量的设备驱动）
local baud = 9600

function build(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- UART.lua builder func get a table --------", data)

	local path = data.path
	if path == nil then
		return {
			result = "ERR",
			message = "Invalid Arguments: path"
		}
	end

	local uart_baud = tonumber(data.baud)
	if uart_baud == nil or uart_baud <= 0 then
		return {
			result = "ERR",
			message = "Invalid Arguments: baud (positive number)"
		}
	end

	-- 重复 build 先关旧句柄再开新（与 I2C/GPIO/SPI 的守卫一致；
	-- 否则旧 fd 泄漏且残留在 HAL.uart_baud 表中）
	if fd ~= nil and fd > 0 then
		uart_close(fd)
		fd = 0
	end

	-- 打开串口（raw 8N1 + 非阻塞；波特率白名单在 HAL 内校验）
	local opened = uart_open(path, uart_baud)
	if opened == nil or opened < 0 then
		return {
			result = "ERR",
			message = "Failed to open UART file"
		}
	end

	fd = opened
	baud = uart_baud

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print("UART opened: " .. path .. " @ " .. tostring(baud) .. " baud, fd=" .. tostring(fd))
	end
	return {  result = "OK"  }

end

-- 【销毁UART】关闭串口句柄
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- UART.lua ender func get a table --------", data)

	if fd ~= nil and fd > 0 then
		uart_close(fd)
		fd = 0
	end

	return {  result = "OK"  }

end


-- 【调用UART】把句柄与波特率交给引用本变量的设备驱动
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	dbg_table("-------- UART.lua caller func get a table --------", data)

	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "UART not opened (build first)"
		}
	end

	-- 返回字典（fd 经引用机制流入设备驱动元数据）
 	return {
		result = "OK",
		fd     = fd,
		baud   = baud
	}

end

-- I2C 硬件

--
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 文件句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局；
-- 每个硬件变量独立 lua_State，故天然隔离）
local fd = -1

function build(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	dbg_table("-------- I2C.Lua builder func get a table --------", data)

	local path = data.path
	if path == nil then	-- 检查文件句柄参数是否存在
		return {
			result = "ERR",
			message = "No I2C path"
		}
	end


	-- 重复 build 先关旧 fd 再开新（防御：不依赖调用方保证 build 恰一次）
	if fd ~= nil and fd > 0 then
		i2c_close(fd)
		fd = -1
	end

	-- 开始执行
	fd = i2c_open(path)
	if fd <= 0 then
		return {
			result = "ERR",
			message = "Failed to open I2C file"
		}
	end

	
	-- 返回结果
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

	i2c_close(fd)
	fd = -1

	return {  result = "OK"  }

end





function call(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	-- build 未成功不下发无效 fd（与 UART.lua 的校验对齐）
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "I2C not opened (build first)"
		}
	end

	return {  result = "OK",  fd = fd  }

end

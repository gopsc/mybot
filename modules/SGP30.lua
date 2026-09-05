-- SGP30 空气质量传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 金属氧化物（MOX）气体传感器，I2C地址0x58，输出TVOC(ppb)与CO2eq(ppm)
-- NOTE(20260902-qing): 上电Init后前15秒读数固定为CO2eq=400/TVOC=0，
-- 且Measure的间隔不得小于1秒，脚本节拍请自行保证


-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/HAL.lua")
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")
local bitc = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/bitcompat.lua")


-- CRC8校验字（多项式0x31，初值0xFF）
local function crc8(word)
	local crc = 0xFF
	local hi = math.floor(word / 256) % 256
	local lo = word % 256
	for _, b in ipairs({hi, lo}) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.band(bitc.bxor(bitc.lshift(crc, 1), 0x31), 0xFF)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end


-- 【配置脚本】发送Init_air_quality，进入持续测量模式
-- FIXME(20260902-qing): 异常处理
--
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Lua builder func get a table --------", data)


	-----------------------------------------------------
	local fd = data.fd
	if fd == nil then	-- 检查文件句柄参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	local addr = data.address
	if addr == nil then	-- 检查地址参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: address"
		}
	end

	addr = tonumber(addr)

	-----------------------------------------------------
	-----------------------------------------------------

	i2c_set_addr(fd, addr)		-- 开始配置SGP30

	i2c_write_reg(fd, 0x20, 0x03)	-- Init_air_quality（2字节命令）

	milli_sleep(10)			-- 等待初始化完成

	return {  result = "OK"  }	-- 返回成功信号

end

-- 【销毁SGP30的脚本】没有需要关闭的资源
--
function destroy(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Lua ender func get a table --------", data)

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用SGP30】测量一次空气质量
-- 返回CO2eq(ppm)与TVOC(ppb)，命令式协议：写命令 -> 等待 -> 纯读
-- NOTE(20260902-qing): 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	dbg_table("-------- Lua caller func get a table --------", data)

	-----------------------------------------------------
	local fd = data.fd
	if fd == nil then	-- 检查文件句柄参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	local addr = data.address
	if addr == nil then	-- 检查地址参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: address"
		}
	end

	addr = tonumber(addr)

	-----------------------------------------------------
	i2c_set_addr(fd, addr)		-- 设置I2C地址

	i2c_write_reg(fd, 0x20, 0x08)	-- Measure_air_quality（2字节命令）

	milli_sleep(12)			-- 等待测量完成

	local raw = i2c_read(fd, 6)	-- 纯读6字节（不写任何指针字节）
	if raw < 0 then
		return {
			result = "ERR",
			message = "Failed to read SGP30"
		}
	end

	-- 拆出6个字节（大端）：CO2eq + CRC, TVOC + CRC
	local b = {}
	for i = 0, 5 do
		b[i] = math.floor(raw / 256 ^ (5 - i)) % 256
	end

	local co2  = bitc.bor(bitc.lshift(b[0], 8), b[1])
	local tvoc = bitc.bor(bitc.lshift(b[3], 8), b[4])

	-- CRC校验
	local crc_ok = (crc8(co2) == b[2]) and (crc8(tvoc) == b[5])

	-- 返回字典
 	return {
		result = "OK",
		CO2EQ  = co2,
		TVOC   = tvoc,
		CRC_OK = crc_ok and 1 or 0
	}

end

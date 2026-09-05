-- MPU6050 陀螺仪与加速度计 驱动模块
-- bot4cj 仓颉语言机器人框架


-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/HAL.lua")
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")
local bitc = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/bitcompat.lua")


local ADDR_0		= 0x68	-- 默认地址
local ADDR_1		= 0x69	-- 额外地址
local PWR_MGMT_1	= 0x6B	-- 电源管理寄存器1
local PWR_NOSLEEP	= 0x00	-- 电源管理 - 非睡眠模式
local GYRO_CONF_REG	= 0x1B	-- 陀螺仪配置寄存器
local GYRO_FS_500DPS	= 0x08	-- 陀螺仪量程 - 正负500度/秒
local GYRO_REG_X_HIGH	= 0x43	-- x 陀螺仪轴 高字节
local GYRO_REG_X_LOW	= 0x44	--
local GYRO_REG_Y_HIGH	= 0x45	-- y
local GYRO_REG_Y_LOW	= 0x46	--
local GYRO_REG_Z_HIGH	= 0x47	-- z
local GYRO_REG_Z_LOW	= 0x48	--
local ACCEL_CONF_REG	= 0x1C	-- 加速度计配置的寄存器
local ACCEL_FS_8g	= 0x10	-- 加速度计量程 正负8g
local ACCEL_REG_X_HIGH	= 0x3B	-- x
local ACCEL_REG_X_LOW	= 0x3C	--
local ACCEL_REG_Y_HIGH	= 0x3D	-- y
local ACCEL_REG_Y_LOW	= 0x3E	--
local ACCEL_REG_Z_HIGH	= 0x3F	-- Z
local ACCEL_REG_Z_LOW	= 0x40	--

-- 【配置脚本】
-- 该脚本负责初始化MPU6050
-- FIXME(20260602-qing): 异常处理
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
			message = "Invalid Arguments: addr"
		}
	end

	addr = tonumber(addr)

	-----------------------------------------------------
	-----------------------------------------------------

	i2c_set_addr(fd, addr)		-- 开始配置PCA9685
	milli_sleep(1)			-- 

	i2c_write_reg(fd, PWR_MGMT_1, PWR_NOSLEEP)		-- 退出睡眠
	i2c_write_reg(fd, GYRO_CONF_REG, GYRO_FS_500DPS)	-- 设陀螺仪量程
	i2c_write_reg(fd, ACCEL_CONF_REG, ACCEL_FS_8g)		-- 设加速度计量程

	milli_sleep(100)		-- 等待稳定

	return {  result = "OK"  }	-- 返回成功信号

end

-- 【重置MPU6050的脚本】
function destroy(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	dbg_table("-------- Lua ender func get a table --------", data)

	-----------------------------------------------------
	local fd = data.fd
	if fd == nil then	-- 检查fd参数是否存在
		return {
			result = "ERR",
			message = "Invalid Arguments: fd"
		}
	end

	-----------------------------------------------------
	local addr = data.address
	if addr == nil then	-- 检查address参数是否存在
		return {
			result = "ERR",
			message = "Invalid Arguments: addr"
		}
	end
	addr = tonumber(addr)

	-----------------------------------------------------


	i2c_set_addr(fd, addr)		-- 准备配置
	--i2c_write_reg(fd, 0x00, 0x80)	-- FIXME: 进入睡眠模式

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用MPU6050】
-- NOTE(20260612-qing): 接收一个参数（表），返回一个结果（表）
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
	if fd == nil then	-- 检查fd参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end
	local addr = data.address

	-----------------------------------------------------
	if addr == nil then	-- 检查address参数是否存在
		return {
			result = "ERR",
			message = "Invalid Argument: addr"
		}
	end
	addr = tonumber(addr)

	-----------------------------------------------------
	i2c_set_addr(fd, addr)	-- 设置I2C地址

	local accel_x_high = i2c_read_reg(fd, ACCEL_REG_X_HIGH)
	local accel_x_low  = i2c_read_reg(fd, ACCEL_REG_X_LOW)
	local accel_y_high = i2c_read_reg(fd, ACCEL_REG_Y_HIGH)
	local accel_y_low  = i2c_read_reg(fd, ACCEL_REG_Y_LOW)
	local accel_z_high = i2c_read_reg(fd, ACCEL_REG_Z_HIGH)
	local accel_z_low  = i2c_read_reg(fd, ACCEL_REG_Z_LOW)

	local gyro_x_high  = i2c_read_reg(fd, GYRO_REG_X_HIGH)
	local gyro_x_low   = i2c_read_reg(fd, GYRO_REG_X_LOW)
	local gyro_y_high  = i2c_read_reg(fd, GYRO_REG_Y_HIGH)
	local gyro_y_low   = i2c_read_reg(fd, GYRO_REG_Y_LOW)
	local gyro_z_high  = i2c_read_reg(fd, GYRO_REG_Z_HIGH)
	local gyro_z_low   = i2c_read_reg(fd, GYRO_REG_Z_LOW)

	-- 返回字典
 	return {
		result  = "OK",
		ACCEL_X = bitc.bor(bitc.lshift(accel_x_high, 8), accel_x_low),
		ACCEL_Y = bitc.bor(bitc.lshift(accel_y_high, 8), accel_y_low),
		ACCEL_Z = bitc.bor(bitc.lshift(accel_z_high, 8), accel_z_low),
		GYRO_X  = bitc.bor(bitc.lshift(gyro_x_high, 8), gyro_x_low),
		GYRO_Y  = bitc.bor(bitc.lshift(gyro_y_high, 8), gyro_y_low),
		GYRO_Z  = bitc.bor(bitc.lshift(gyro_z_high, 8), gyro_z_low)
	}

end


-- MPU6050 陀螺仪与加速度计 驱动模块
-- bot4cj 仓颉语言机器人框架


-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table、驱动公共样板 drv_common（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))


local ADDR_0		= 0x68	-- 默认地址
local ADDR_1		= 0x69	-- 额外地址
local REG_WHO_AM_I	= 0x75	-- 身份寄存器（只读）
local WHO_AM_I_VAL	= 0x68	-- MPU6050 身份值（bit0 恒 0）
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
-- 温度寄存器 0x41/0x42 位于 14 字节 burst 的 t[7]/t[8]
local TEMP_LSB_PER_DEG	= 340.0	-- 温度灵敏度 340 LSB/°C（datasheet 寄存器映射表）
local TEMP_OFFSET_DEG	= 36.53	-- raw=0 对应 36.53°C（片上温度，非环境温度精确量）

-- 【配置脚本】
-- 该脚本负责初始化MPU6050
-- FIXME(20260602-qing): 异常处理
--
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua builder func get a table --------", data)

	-----------------------------------------------------
	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------
	-----------------------------------------------------

	milli_sleep(1)			-- 

	if not i2c_write_reg(fd, PWR_MGMT_1, PWR_NOSLEEP) then		-- 退出睡眠
		return err("MPU6050 not responding (PWR_MGMT_1 write failed, check address and wiring)")
	end

	-- WHO_AM_I 甄别：总线上任意会 ACK 的器件（或错地址）都能通过纯写配置的
	-- build——读身份寄存器把错挂器件挡在 build 期（同批 IMU 均已甄别）
	local who = i2c_read_reg(fd, REG_WHO_AM_I)
	if who < 0 then
		return err("MPU6050 not responding (WHO_AM_I read failed, check address and wiring)")
	end
	if who ~= WHO_AM_I_VAL then
		return err(string.format("MPU6050 WHO_AM_I = 0x%02X (expect 0x68, not MPU6050?)", who))
	end

	if not i2c_write_reg(fd, GYRO_CONF_REG, GYRO_FS_500DPS) then	-- 设陀螺仪量程
		return err("MPU6050 write failed: GYRO_CONFIG")
	end
	if not i2c_write_reg(fd, ACCEL_CONF_REG, ACCEL_FS_8g) then	-- 设加速度计量程
		return err("MPU6050 write failed: ACCEL_CONFIG")
	end

	milli_sleep(100)		-- 等待稳定

	return {  result = "OK"  }	-- 返回成功信号

end

-- 【重置MPU6050的脚本】
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua ender func get a table --------", data)

	-----------------------------------------------------
	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用MPU6050】
-- NOTE(20260612-qing): 接收一个参数（表），返回一个结果（表）
-- 六轴返回有符号 16 位（补码）原始值：加速度 ±8g、陀螺 ±500°/s 量程的寄存器原始量，
-- 未做量程比例换算（要物理单位需按灵敏度系数另算）；
-- TEMP 为换算后的摄氏度浮点，TEMP_RAW 为其有符号原始值。
function call(data)


	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Lua caller func get a table --------", data)

	-----------------------------------------------------
	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------

	-- 16 位补码符号扩展：高/低字节合并成有符号数
	local function s16(hi, lo)
		local v = bitc.bor(bitc.lshift(hi, 8), lo)
		if v >= 32768 then v = v - 65536 end	-- 负值还原
		return v
	end

	-- 六轴 burst read：0x3B 起 14 字节单次原子事务（ACCEL 6B + TEMP 2B + GYRO 6B）。
	-- 取代原 12 次独立单字节读：跨事务间寄存器已刷新，hi/lo 可能来自不同采样（撕裂）；
	-- 且逐次读的 -1 失败值不经检查会被 s16 合成伪读数（datasheet 亦推荐 burst 保证一致性）。
	local t = i2c_read_multi_bytes(fd, ACCEL_REG_X_HIGH, 14)
	if t == nil then
		return err("MPU6050 read failed (burst 0x3B..0x48, check wiring)")
	end

	-- 温度：t[7]/t[8] 为 TEMP_OUT（0x41/0x42）有符号原始值，
	-- 按 datasheet 公式换算摄氏度：°C = raw / 340 + 36.53。
	-- 片上温度受芯片自热影响，通常高于环境温度几度，非精密环境温度传感器。
	local tempRaw = s16(t[7], t[8])
	local tempC   = tempRaw / TEMP_LSB_PER_DEG + TEMP_OFFSET_DEG

	-- 返回字典：六轴为有符号 16 位原始值（未做量程比例换算），TEMP 为摄氏度浮点
 	return {
 		result  = "OK",
 		ACCEL_X = s16(t[1],  t[2]),
 		ACCEL_Y = s16(t[3],  t[4]),
 		ACCEL_Z = s16(t[5],  t[6]),
 		GYRO_X  = s16(t[9],  t[10]),
 		GYRO_Y  = s16(t[11], t[12]),
 		GYRO_Z  = s16(t[13], t[14]),
 		TEMP    = tempC,
 		TEMP_RAW = tempRaw
 	}

end
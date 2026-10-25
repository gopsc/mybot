-- PCA9685 PWM控制板




-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table、驱动公共样板 drv_common（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 关键寄存器与模式位（PCA9685 数据手册 §7.3 寄存器映射）
local REG_MODE1    = 0x00	-- 模式寄存器1
local MODE1_RESTART= 0x80	-- 重启位：置 1 触发已排队的计数重启
local MODE1_SLEEP  = 0x10	-- 睡眠位：置 1 关闭振荡器，改 PRE_SCALE 前必须进入
local MODE1_AI     = 0x20	-- 地址自增位：置 1 使寄存器写自动递增
local REG_PRESCALE = 0xFE	-- 预分频寄存器（实际频率 = 25MHz / (4096 * (prescale+1))）
local LED0_ON_L    = 0x06	-- 通道 0 ON 计数低字节（后续通道每 4 字节步进）

-- 时基与脉宽换算常量（见 call/build）
local OSC_CLK_HZ     = 25000000	-- 板载 25MHz 振荡器
local PWM_RESOLUTION = 4096	-- 12 位分辨率（0~4095 计数）
local PERIOD_MS      = 20	-- 50Hz 周期（20ms）
local PULSE_0DEG_MS  = 0.5	-- 0 度对应脉宽
local PULSE_180DEG_MS= 2.5	-- 180 度对应脉宽




-- 【配置脚本】
-- 该脚本负责初始化PCA9685
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
	local freq = 50.0							-- 设置PWM频率
	local prescale_val = OSC_CLK_HZ / (PWM_RESOLUTION * freq) - 1.0	-- 25MHz主频
	local prescale = prescale_val + 0.5

	if not i2c_write_reg(fd, REG_MODE1, MODE1_RESTART) then	-- 触发一次重启（唤醒振荡器）
		return err("PCA9685 not responding (MODE1 write failed, check address and wiring)")
	end

	milli_sleep(5)			-- 等待振荡器启动

	if not i2c_write_reg(fd, REG_MODE1, MODE1_SLEEP) then	-- 进入SLEEP模式（允许改频率）
		return err("PCA9685 write failed: MODE1 (SLEEP)")
	end
	if not i2c_write_reg(fd, REG_PRESCALE, math.floor(prescale)) then
		return err("PCA9685 write failed: PRE_SCALE")
	end
	if not i2c_write_reg(fd, REG_MODE1, MODE1_AI) then	-- 退出SLEEP并开启地址自增
		return err("PCA9685 write failed: MODE1 (AI)")
	end

	milli_sleep(5)			-- 等待振荡器启动

	return {  result = "OK"  }	-- 返回成功信号

end

-- 【销毁PCA9685的脚本】重置PCA9685
-- NOTE(20260612-qing): 其实可以不需要，因为我们只是清空设置
--
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

	if not i2c_write_reg(fd, REG_MODE1, MODE1_RESTART) then	-- 触发重启（非复位配置，仅重新开始计数）
		return err("PCA9685 write failed: MODE1 (restart)")
	end

	return {  result = "OK"  }	-- 返回成功信号

end


-- 【调用PCA9685】
-- 将一个舵机通道转动到一个角度
-- NOTE(20260612-qing): 接收一个参数（表），返回一个结果（表）
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
	local channel = data.channel
	if channel == nil then	-- 检查channel参数是否存在
		return err("Invalid Argument: channel")
	end
	channel = tonumber(channel)
	if channel == nil then	-- 检查channel是否是数值
		return err("Invalid Argument: channel (not a number)")
	end
	channel = math.floor(channel)	-- 寄存器地址需要整数通道号

	-- PCA9685 只有 16 路输出：越界的 channel 会写出 0x06+4*channel 之外的
	-- 寄存器（如 -1 落到 MODE 区），污染同总线器件配置甚至击穿脉宽，显式拒绝
	if channel < 0 or channel > 15 then
		return err("Invalid Argument: channel (out of range 0-15)")
	end

	local angle = data.angle

	-----------------------------------------------------
	if angle == nil then	-- 检查angle参数是否存在
		return err("Invalid Argument: angle")
	end
	angle = tonumber(angle)
	if angle == nil then	-- 检查angle是否是数值（支持浮点角度）
		return err("Invalid Argument: angle (not a number)")
	end
	if angle < 0 then angle = 0 end
	if angle > 180 then angle = 180 end	-- 限幅，防止超出0.5~2.5ms脉宽损伤舵机

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("Lua hardware drive set angle: %.2f", angle))
	end

	-----------------------------------------------------

	-- 计算需要的参数
	local min = PULSE_0DEG_MS	-- 0度对应0.5ms
	local max = PULSE_180DEG_MS	-- 180度对应2.5ms
	local width = min + (max - min) * (angle / 180.0)
	local offval = math.floor(width * PWM_RESOLUTION / PERIOD_MS)
	local reg = LED0_ON_L + 4 * channel

	-- ON 计数恒为 0（脉宽自周期起点起算），OFF 计数写入低/高字节。
	-- build 已开 AI 自增：4 字节合为单次 I2C_RDWR 原子更新——原 4 次独立事务
	-- 存在半更新窗口，并发访问同一总线时舵机会吃到新旧混合脉宽
	local off_lo = bitc.band(offval, 0xFF)
	local off_hi = bitc.band(bitc.rshift(offval, 8), 0xFF)
	if i2c_write_multi(fd, reg, 0x00, 0x00, off_lo, off_hi) ~= 0 then
		return err("PCA9685 write failed: PWM registers (channel " .. tostring(channel) .. ")")
	end

	-- 返回字典
 	return { result = "OK" }

end
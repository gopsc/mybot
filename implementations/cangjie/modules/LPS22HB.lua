-- LPS22HB 高精度气压计 驱动模块（I2C，ST MEMS）
-- bot4cj 仓颉语言机器人框架
-- 260~1260 hPa 绝对气压，24 位气压 + 16 位温度输出，片内温补。
-- 本驱动用单次（one-shot）模式：call 触发一次转换并等待完成，低功耗且
-- 每次读到的是新鲜样本（机器人的低频气压轮询/海拔测量场景）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LPS22HB (
--       name    String,
--       I2C     String,
--       address String,
--       wait    String    -- 单次转换超时 ms（默认 50，转换约 3ms）
--   );
--   INSERT INTO LPS22HB (name, I2C, address, wait) VALUES ('baro-0', 'i2c-1', '0x5D', '-');
-- 地址 0x5D（SA0 接高）或 0x5C（SA0 接地）；一条总线两颗（SA0 各异）。
--
-- call 返回 { result, P(hPa), T(°C) }，换算（数据手册）：
--   P = 24 位原始值 / 4096；T = 16 位原始值 / 100
-- 接 sensor_daemon：fields=P|T（浮点，勿配 sign），interval >= wait。
--
-- 实现要点（寄存器语义经 Adafruit_LPS2X 库全源核对，内核 st_pressure 家族
-- 驱动同源互证）：
--   1. WHO_AM_I（0x0F）= 0xB1（LPS25HB 为 0xBD，插错代际在此拦下）
--   2. 多字节读须带自动增量位：0x28|0x80 起 5 字节（3 气压 + 2 温度，
--      小端）；HAL 合并读 5 字节在 2^40 内，精度无虞
--   3. CTRL_REG1（0x10）= BDU（bit1）+ ODR=000（单次/power-down）；
--      BDU 置位保证输出寄存器读期间不被刷新撕裂
--   4. 单次转换：CTRL_REG2（0x11）bit0 硬件自清零，轮询其为完成标志
--   5. 补码：气压 24 位（负值减 0x1000000）、温度 16 位
--      （Adafruit 实现减 0xFFFFFF 少 1，本驱动按标准补码修正）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：气压计低频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_WHOAMI   = 0x0F
local REG_CTRL1    = 0x10		-- [6:4]ODR [3]EN_LPFP [2]LPFP_CFG [1]BDU [0]SIM
local REG_CTRL2    = 0x11		-- [7]BOOT [4]FIFO_EN [2]SWRESET [1?] [0]ONE_SHOT
local REG_PRESS    = 0xA8		-- 0x28|0x80（自动增量）起 5 字节

local CHIP_ID      = 0xB1
local CTRL1_VALUE  = 0x02		-- BDU 置位，ODR=000（单次模式）
local BIT_SWRESET  = 0x04
local BIT_ONESHOT  = 0x01

local wait_default = 50

-- ==================== 模块级配置 ====================
local cfg_wait

-- ==================== 配置脚本 ====================
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- LPS22HB builder func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-- WHO_AM_I 自检
	local id = i2c_read_reg(fd, REG_WHOAMI)
	if id < 0 then
		return {
			result = "ERR",
			message = "LPS22HB not responding (read WHO_AM_I failed, check address 0x5C/0x5D and wiring)"
		}
	end
	if id ~= CHIP_ID then
		return {
			result = "ERR",
			message = string.format("LPS22HB unexpected WHO_AM_I 0x%02X (expect 0xB1; 0xBD=LPS25HB)", id)
		}
	end

	-- 软复位（SWRESET 自清零），轮询至完成
	if not i2c_write_reg(fd, REG_CTRL2, BIT_SWRESET) then
		return {
			result = "ERR",
			message = "LPS22HB not responding (soft reset write failed)"
		}
	end
	local waited = 0
	while waited < 20 do
		local c2 = i2c_read_reg(fd, REG_CTRL2)
		if c2 < 0 then
			return {
				result = "ERR",
				message = "LPS22HB not responding (reset poll failed)"
			}
		end
		if math.floor(c2 / 4) % 2 == 0 then break end
		milli_sleep(1)
		waited = waited + 1
	end

	-- 单次模式 + BDU（输出寄存器读期间不刷新，防撕裂）
	if not i2c_write_reg(fd, REG_CTRL1, CTRL1_VALUE) then
		return {
			result = "ERR",
			message = "LPS22HB not responding (CTRL_REG1 write failed)"
		}
	end

	local wait = tonumber(data.wait)
	if wait == nil or wait < 0 then wait = wait_default end
	cfg_wait = math.floor(wait)

	print(string.format("LPS22HB init OK: addr=0x%02X id=0xB1 mode=oneshot wait=%dms", addr, cfg_wait))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 触发单次转换 -> 轮询完成 -> 5 字节突发读 -> 换算 P/T
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- LPS22HB caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	local wait_ms = tonumber(data.wait) or cfg_wait or wait_default
	if wait_ms < 0 then wait_ms = 0 end

	-- 触发单次转换（读改写保留其余位；ONE_SHOT 硬件自清零）
	local c2 = i2c_read_reg(fd, REG_CTRL2)
	if c2 < 0 then
		return {
			result = "ERR",
			message = "LPS22HB not responding (read CTRL_REG2 failed)"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL2, c2 - c2 % 2 + BIT_ONESHOT) then
		return {
			result = "ERR",
			message = "LPS22HB not responding (trigger write failed)"
		}
	end

	-- 轮询 ONE_SHOT 位清零（转换完成）
	local waited = 0
	while true do
		local v = i2c_read_reg(fd, REG_CTRL2)
		if v < 0 then
			return {
				result = "ERR",
				message = "LPS22HB not responding (poll failed)"
			}
		end
		if v % 2 == 0 then break end
		if waited >= wait_ms then
			return {
				result = "ERR",
				message = "LPS22HB conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)"
			}
		end
		milli_sleep(1)
		waited = waited + 1
	end

	-- 5 字节突发读：气压 24 位（小端）+ 温度 16 位（小端）
	local v = i2c_read_multi(fd, REG_PRESS, 5)
	if v < 0 then
		return {
			result = "ERR",
			message = "LPS22HB not responding (read data failed)"
		}
	end
	local b = {}
	for i = 0, 4 do b[i + 1] = math.floor(v / 256 ^ (4 - i)) % 256 end
	local pres = b[1] + b[2] * 256 + b[3] * 65536
	if pres >= 0x800000 then pres = pres - 0x1000000 end		-- 24 位补码
	local temp = b[4] + b[5] * 256
	if temp >= 0x8000 then temp = temp - 0x10000 end			-- 16 位补码

	return {
		result = "OK",
		P = pres / 4096.0,
		T = temp / 100.0
	}

end

-- ==================== 销毁 ====================
-- 单次模式本身即 power-down；fd 归 I2C 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end

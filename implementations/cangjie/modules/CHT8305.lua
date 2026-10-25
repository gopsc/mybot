-- CHT8305 温湿度传感器 驱动模块（I2C，申矽凌微 SensyLink）
-- bot4cj 仓颉语言机器人框架
-- 第二代数字温湿度传感器：±3.0%RH / ±0.5℃（最大），14 位 ADC，2.5~5.5V，
-- DFN3x3-6 封装。协议为指针寄存器风格（写指针 -> 等转换 -> 纯读 2 字节），
-- 无 CRC。ALERT 开漏输出（过限告警）本驱动未用（轮询）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE CHT8305 (
--       name    String,
--       I2C     String,
--       address String
--   );
--   INSERT INTO CHT8305 (name, I2C, address) VALUES ('th-0', 'i2c-1', '0x40');
-- 地址由 AD0 引脚选（接 GND/Vcc/SDA/SCL -> 4 个从地址），悬空 = 0x40
-- （数据手册 8 位地址 0x80）；一条总线最多 4 颗。
--
-- call 返回 { result, T(°C), H(%RH) }——14 位满量程换算：
--   T = raw x 165/65535 - 40；RH = raw x 100/65535
-- 接 sensor_daemon：fields=T|H（浮点，勿配 sign），interval >= 30ms 即可
--   （每次 call 内含 2 x 14ms 转换等待）。
--
-- 实现要点（协议与换算经官方 sensylink/CHT8305 与 RobTillaart/CHT8305
-- 两套实现逐行互证，官方代码即以 MID==0x5959 作在位校验）：
--   1. 指针寄存器：0x00 温度 / 0x01 湿度 / 0x02 配置 / 0x03 告警限 /
--      0x04 电压（换算公式存疑，两源之一标注 best guess，本驱动不实现）/
--      0xFE 厂商 ID（0x5959）/ 0xFF 器件 ID（0x8305）
--   2. 配置位：bit15 软复位、bit14 时钟拉伸、bit13 加热器、bit12 模式、
--      bit10 温度分辨率、bit9:8 湿度分辨率（缺省 14 位）——本驱动只发
--      软复位，其余保持 POR 默认
--   3. 转换等待：14 位双通道约 13ms，取 14ms 余量（RobTillaart 同值）
--   4. 告警限（HLIMIT/TLIMIT，0x03）编程流程未实现，按手册另行操作

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（指针） ====================
local REG_TEMP  = 0x00
local REG_HUMI  = 0x01
local REG_CONF  = 0x02
local REG_MID   = 0xFE
local REG_DID   = 0xFF

local MID_MAGIC = 0x5959		-- 厂商 ID（官方代码在位校验同款）
local DID_MAGIC = 0x8305		-- 器件 ID
local CFG_SOFT_RESET = 0x80
local T_CONV_MS = 14			-- 14 位转换等待（数据手册 2 x 6.5ms + 余量）

-- ==================== 模块级配置 ====================
local cfg_addr

-- 写指针寄存器（单字节命令，无数据）
local function set_pointer(fd, reg)
	return i2c_write_multi(fd, reg) == 0
end

-- 读当前指针指向的 16 位寄存器
local function read_reg16(fd)
	local v = i2c_read(fd, 2)
	if v < 0 then return nil end
	return v % 65536
end

-- ==================== 配置脚本 ====================
-- 软复位 -> 厂商/器件 ID 自检
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- CHT8305 builder func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-- 软复位（bit15 自清零，恢复 POR 默认配置）：
	-- 写寄存器必须单事务 [指针, 数据]——两段式会把数据字节当指针发（双源实现均同）
	if i2c_write_multi(fd, REG_CONF, 0x80) ~= 0 then
		return {
			result = "ERR",
			message = "CHT8305 not responding (soft reset failed, check address 0x40 and wiring)"
		}
	end
	milli_sleep(10)

	-- 厂商/器件 ID 自检
	if not set_pointer(fd, REG_MID) then
		return {
			result = "ERR",
			message = "CHT8305 not responding (pointer write failed)"
		}
	end
	local mid = read_reg16(fd)
	if mid == nil then
		return {
			result = "ERR",
			message = "CHT8305 not responding (read manufacturer id failed)"
		}
	end
	if mid ~= MID_MAGIC then
		return {
			result = "ERR",
			message = string.format("CHT8305 unexpected manufacturer id 0x%04X (expect 0x%04X)", mid, MID_MAGIC)
		}
	end
	if not set_pointer(fd, REG_DID) then
		return {
			result = "ERR",
			message = "CHT8305 not responding (pointer write failed)"
		}
	end
	local did = read_reg16(fd)
	if did == nil then
		return {
			result = "ERR",
			message = "CHT8305 not responding (read device id failed)"
		}
	end
	if did ~= DID_MAGIC then
		return {
			result = "ERR",
			message = string.format("CHT8305 unexpected device id 0x%04X (expect 0x%04X)", did, DID_MAGIC)
		}
	end

	cfg_addr = addr
	print(string.format("CHT8305 init OK: addr=0x%02X mid=0x%04X did=0x%04X", addr, mid, did))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 触发并读取温度 + 湿度（各一次指针写 + 14ms 转换等待 + 2 字节读）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- CHT8305 caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------
	-- 温度
	if not set_pointer(fd, REG_TEMP) then
		return {
			result = "ERR",
			message = "CHT8305 not responding (temp pointer write failed)"
		}
	end
	milli_sleep(T_CONV_MS)
	local t_raw = read_reg16(fd)
	if t_raw == nil then
		return {
			result = "ERR",
			message = "CHT8305 not responding (read temperature failed)"
		}
	end
	-- 湿度
	if not set_pointer(fd, REG_HUMI) then
		return {
			result = "ERR",
			message = "CHT8305 not responding (humi pointer write failed)"
		}
	end
	milli_sleep(T_CONV_MS)
	local h_raw = read_reg16(fd)
	if h_raw == nil then
		return {
			result = "ERR",
			message = "CHT8305 not responding (read humidity failed)"
		}
	end

	return {
		result = "OK",
		T = t_raw * 165.0 / 65535.0 - 40.0,
		H = h_raw * 100.0 / 65535.0
	}

end

-- ==================== 销毁 ====================
-- 无关断寄存器（低功耗由配置位另行操作，本驱动不触碰）；fd 归 I2C 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end

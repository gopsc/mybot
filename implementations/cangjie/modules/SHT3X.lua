-- SHT3X 温湿度传感器 驱动模块（I2C，兼容 SHT30/31/35）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SHT3X (
--       name    String,
--       I2C     String,
--       address String
--   );
--   INSERT INTO SHT3X (name, I2C, address) VALUES ('sht3x-0', 'i2c-1', '0x44');
--
-- call 无需额外参数（元数据由框架自动合并传入），
-- 返回 { result, T(°C), RH(%RH), CRC_OK }。
-- 接 sensor_daemon：fields 填 T|RH；值已是换算后的浮点，切勿配 sign=16
-- （sign 是给原始 16 位补码整数用的，会破坏浮点）。
--
-- 实现要点：
--   1. 树莓派 BCM 系列 I2C 主控对时钟拉伸支持有缺陷，测量固定用【轮询模式】
--      （0x2400 单次·高重复性）：写命令 -> milli_sleep(16) -> 纯读 6 字节
--   2. SHT3X 命令为 16 位双字节，恰与 i2c_write_reg(fd, hi, lo) 的 2 字节
--      原子写吻合；HAL 的 i2c_write_reg 返回 true/false，可直接检查
--   3. i2c_read 纯读 n 字节按大端合并：纯 Lua 算术，失败返回 -1、成功恒为
--      非负且 6 字节（<=2^48）在 double 域内精确——负值还原分支为旧 cfunc
--      桥的防御遗留，现恒不触发，保留作护栏
--   4. CRC8 多项式 0x31、初值 0xFF（与 SGP30.lua 相同；数据手册校验向量
--      0xBEEF -> 0x92）。6 字节 = T_MSB T_LSB CRC | RH_MSB RH_LSB CRC
--   5. 出厂校准无系数表；换算 T = -45 + 175*raw/65535，RH = 100*raw/65535

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令（16 位，双字节发送） ====================
local CMD_SOFT_RESET  = { 0x30, 0xA2 }	-- 软复位，约 1.5ms 后就绪
local CMD_READ_STATUS = { 0xF3, 0x2D }	-- 读状态寄存器：2 数据字节 + CRC
-- 单次测量·轮询模式（不用时钟拉伸，树莓派 BCM 主控不支持）
local CMD_MEAS_HIGH   = { 0x24, 0x00 }	-- 高重复性，最大 15.5ms
local MEAS_WAIT_MS    = 16		-- 轮询等待（不低于数据手册最大值）

-- ==================== 状态寄存器位（数据手册 Table 18，读命令 0xF32D） ====================
--   bit0 = 写数据校验和状态（'1' = 上次写数据校验和失败）
--   bit1 = 命令状态（'1' = 上一命令未处理或非法）
--   bit4 = 系统复位检测（软复位/硬复位/上电后置位）
-- 旧映射把 bit0/bit1 当作命令/复位位——真命令错误漏检、复位检测位永错
-- （2026-09 审计 M1 已修；bit0 仅诊断参考，build 不判）
local ST_WRITE_CRC = 0x0001		-- bit0：写数据校验和状态
local ST_CMD_STATUS = 0x0002		-- bit1：1=上一命令未处理或非法
local ST_RESET_SEEN = 0x0010		-- bit4：1=发生过复位（软复位/硬复位/上电）

-- CRC8校验字（多项式0x31，初值0xFF，与 SGP30.lua 一致）
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

-- 纯读 n 字节 → n 字节表（0 基下标）。失败（-1）返回 nil；
-- 其余负值按旧 cfunc 桥的有符号合并语义还原为无符号（现 HAL 恒为正，防御分支）
local function read_bytes(fd, n)
	local raw = i2c_read(fd, n)
	if raw == -1 then return nil end
	if raw < 0 then raw = raw + 256 ^ n end
	local b = {}
	for i = 0, n - 1 do
		b[i] = math.floor(raw / 256 ^ (n - 1 - i)) % 256
	end
	return b
end

-- 【配置脚本】软复位 + 读状态寄存器验证响应
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- SHT3X builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then	-- 检查 fd/address 参数
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 软复位（HAL 的 i2c_write_reg 是 2 字节原子写，返回 true/false）
	if not i2c_write_reg(fd, CMD_SOFT_RESET[1], CMD_SOFT_RESET[2]) then
		return {
			result = "ERR",
			message = "Failed to write SHT3X soft reset"
		}
	end
	milli_sleep(2)			-- 复位就绪约 1.5ms

	-- 读状态寄存器验证响应
	if not i2c_write_reg(fd, CMD_READ_STATUS[1], CMD_READ_STATUS[2]) then
		return {
			result = "ERR",
			message = "Failed to write SHT3X read status"
		}
	end
	milli_sleep(1)
	local sb = read_bytes(fd, 3)
	if sb == nil then
		return {
			result = "ERR",
			message = "Failed to read SHT3X status"
		}
	end

	local status = sb[0] * 256 + sb[1]
	if crc8(status) ~= sb[2] then
		return {
			result = "ERR",
			message = "SHT3X status CRC mismatch"
		}
	end
	if bitc.band(status, ST_CMD_STATUS) ~= 0 then
		return {
			result = "ERR",
			message = "SHT3X command status error (bit1: last command not processed)"
		}
	end
	if bitc.band(status, ST_RESET_SEEN) == 0 then
		print("SHT3X: reset flag (bit4) not set in status, continuing")
	end

	print(string.format("SHT3X init OK: addr=0x%02X, status=0x%04X", addr, status))
	return {  result = "OK"  }

end

-- 【销毁SHT3X】没有需要释放的资源（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用SHT3X】单次测量（轮询模式）：写命令 -> 等待 -> 纯读 6 字节
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- SHT3X caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 单次测量（0x2400 轮询·高重复性），等待转换完成
	if not i2c_write_reg(fd, CMD_MEAS_HIGH[1], CMD_MEAS_HIGH[2]) then
		return {
			result = "ERR",
			message = "Failed to write SHT3X measure command"
		}
	end
	milli_sleep(MEAS_WAIT_MS)

	local b = read_bytes(fd, 6)
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read SHT3X measurement"
		}
	end

	-----------------------------------------------------
	local st  = b[0] * 256 + b[1]		-- 温度原始值（16 位无符号）
	local srh = b[3] * 256 + b[4]		-- 湿度原始值（16 位无符号）
	local crc_ok = (crc8(st) == b[2]) and (crc8(srh) == b[5])

	local T  = -45.0 + 175.0 * st / 65535.0
	local RH = 100.0 * srh / 65535.0

	if DEBUG then
		print(string.format("SHT3X: T=%.2f C, RH=%.2f %%RH, CRC %s",
			T, RH, crc_ok and "OK" or "FAIL"))
	end

	-- 返回字典（CRC_OK：0/1，参照 SGP30 的约定不因 CRC 失败而中断）
 	return {
		result = "OK",
		T      = T,
		RH     = RH,
		CRC_OK = crc_ok and 1 or 0
	}

end

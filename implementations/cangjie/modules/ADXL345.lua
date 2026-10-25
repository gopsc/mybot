-- ADXL345 三轴加速度计 驱动模块
-- bot4cj 仓颉语言机器人框架
-- Analog Devices，I2C 地址 0x53/0x1D（ALT ADDRESS 引脚，模块缺省 0x53），
-- ±2/4/8/16g，13 位 @ ±16g，输出三轴原始码：ACCEL_X/Y/Z
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE ADXL345 (
--       name    String,
--       I2C     String,
--       address String,
--       range   String,
--       odr     String
--   );
--   INSERT INTO ADXL345 (name, I2C, address, range, odr)
--     VALUES ('acc0', 'i2c-1', '0x53', '-', '-');
-- range = 量程 g（2/4/8/16，非法值向下降档，缺省 8）
-- odr   = 输出数据率 Hz（12.5/25/50/100/200/400/800/1600/3200，取最近档，
--         平手取低，缺省 100；低功耗降带宽档 0x0~0x6 本驱动不使用）
-- 各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回 { result, ACCEL_X, ACCEL_Y, ACCEL_Z }
-- （16 位补码语义的原始无符号码，与 MPU6050/BMI270/LSM6DSV 驱动同约定，
-- 负值由守护 sign='16' 展开）
-- 接 sensor_daemon：fields=ACCEL_X|ACCEL_Y|ACCEL_Z，sign='16'
--
-- 实现要点（寄存器/语义依 Adafruit CircuitPython ADXL34x 库核实，MIT）：
--   1. 甄别：DEVID(0x00) = 0xE5
--   2. DATA_FORMAT(0x31) 恒置 FULL_RES（bit3）：全量程灵敏度恒定
--      3.9mg/LSB（256 LSB/g）、数据 16 位左对齐——量程列只改削顶电平
--      （Adafruit 同款策略，非 FULL_RES 的 10 位逐档灵敏度模式不用）
--   3. 启动：POWER_CTL(0x2D) 写 0x08（Measure 位；芯片复位后为待机态，
--      写前先清 bit4 Sleep/bit5 Link——与 Adafruit 参考一致）
--   4. 数据寄存器小端：DATAX0(0x32) 起 6 字节 = X_LSB,X_MSB,Y_LSB,...
--      （与 BMI270/LSM6DSV 同，与 MPU6050 相反）
--   5. BW_RATE(0x2C) 低 4 位速率码：12.5Hz=0x7 线性到 3200Hz=0xF；
--      高性能区外还有低功耗降带宽档 0x0~0x6（不使用）
--   6. 敲击/自由落体/活动检测引擎（0x1D~0x30 中断组）本驱动未接——
--      框架为守护轮询路径，中断型事件驱动待框架支持后再扩展

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：高频采样，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_DEVID       = 0x00
local REG_BW_RATE     = 0x2C		-- bit4=低功耗 [3:0]=速率码
local REG_POWER_CTL   = 0x2D		-- bit3=Measure
local REG_DATA_FORMAT = 0x31		-- bit3=FULL_RES [1:0]=量程
local REG_DATAX0      = 0x32		-- 三轴数据 6 字节（小端）

local DEVID       = 0xE5
local FULL_RES    = 0x08
local MEASURE     = 0x08

-- 量程档 g（DATA_FORMAT 代码 0..3），缺省 ±8g
local acc_tab = { 2, 4, 8, 16 }
-- 数据率档 Hz（BW_RATE 代码 7..F），缺省 100Hz
local odr_tab  = { 12.5, 25, 50, 100, 200, 400, 800, 1600, 3200 }

-- 向下取档：不大于 n 的最大合法档（量程类）；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

-- 最近取档：差值最小档（ODR 类），平手取低
local function snap_near(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	local best, bd = def_i, math.huge
	for i = 1, #tab do
		local d = math.abs(n - tab[i])
		if d < bd then best, bd = i, d end
	end
	return best
end

local function range_code_of(v)
	local i = snap_down(v, acc_tab, 3)
	return i - 1, acc_tab[i]
end

local function odr_code_of(v)
	local i = snap_near(v, odr_tab, 4)
	return 6 + i, odr_tab[i]		-- 12.5Hz=0x7 起
end

-- 读 6 字节并拆 1 基字节数组；失败返回 nil
local function read_bytes6(fd, reg)
	local raw = i2c_read_multi(fd, reg, 6)
	if raw < 0 then return nil end
	local b = {}
	for i = 0, 5 do
		b[i + 1] = math.floor(raw / 256 ^ (5 - i)) % 256
	end
	return b
end

-- 【配置脚本】DEVID 甄别 -> FULL_RES+量程 -> 速率 -> 测量模式
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- ADXL345 builder func get a table --------", data)
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

	-- 列配置
	local range_v, range_g = range_code_of(data.range)
	local odr_code_v, odr_hz = odr_code_of(data.odr)

	-----------------------------------------------------
	-- 芯片甄别
	local id = i2c_read_reg(fd, REG_DEVID)
	if id < 0 then
		return {
			result = "ERR",
			message = "Failed to read ADXL345 DEVID"
		}
	end
	if id ~= DEVID then
		return {
			result = "ERR",
			message = string.format("DEVID = 0x%02X (expect 0xE5, not ADXL345?)", id)
		}
	end

	-- 数据格式：保留高位、置 FULL_RES + 量程
	local df = i2c_read_reg(fd, REG_DATA_FORMAT)
	if df < 0 then
		return {
			result = "ERR",
			message = "Failed to read ADXL345 DATA_FORMAT"
		}
	end
	if not i2c_write_reg(fd, REG_DATA_FORMAT,
		bitc.bor(bitc.band(df, 0xF0), bitc.bor(FULL_RES, range_v))) then
		return {
			result = "ERR",
			message = "Failed to write ADXL345 DATA_FORMAT"
		}
	end

	-- 数据率（高性能档，清低功耗位）
	if not i2c_write_reg(fd, REG_BW_RATE, odr_code_v) then
		return {
			result = "ERR",
			message = "Failed to write ADXL345 BW_RATE"
		}
	end

	-- 进入测量模式（清 Sleep/Link 位，同 Adafruit 参考）
	if not i2c_write_reg(fd, REG_POWER_CTL, MEASURE) then
		return {
			result = "ERR",
			message = "Failed to write ADXL345 POWER_CTL"
		}
	end

	-- 等两个测量周期，首拍数据就绪
	local wait_ms = math.ceil(2 * 1000 / odr_hz) + 2
	milli_sleep(wait_ms)

	print(string.format("ADXL345 init OK: addr=0x%02X, ±%dg, odr=%gHz (FULL_RES 3.9mg/LSB)",
		addr, range_g, odr_hz))
	return {  result = "OK"  }

end

-- 【销毁ADXL345】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用ADXL345】读三轴原始码
-- NOTE: 数据寄存器小端（LSB 在前）；返回 16 位补码语义的无符号原始码
-- （负值由守护 sign='16' 展开；FULL_RES 下 256 LSB/g 恒定）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- ADXL345 caller func get a table --------", data)
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
	local b = read_bytes6(fd, REG_DATAX0)
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read ADXL345 accel data"
		}
	end

	local ret = {
		result  = "OK",
		ACCEL_X = bitc.bor(bitc.lshift(b[2], 8), b[1]),
		ACCEL_Y = bitc.bor(bitc.lshift(b[4], 8), b[3]),
		ACCEL_Z = bitc.bor(bitc.lshift(b[6], 8), b[5])
	}

	if DEBUG then
		print(string.format("ADXL345: X=%d Y=%d Z=%d", ret.ACCEL_X, ret.ACCEL_Y, ret.ACCEL_Z))
	end

	return ret

end

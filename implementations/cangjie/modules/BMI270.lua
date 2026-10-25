-- BMI270 六轴 IMU（16 位加速度计 + 16 位陀螺仪）驱动模块
-- bot4cj 仓颉语言机器人框架
-- Bosch Sensortec，I2C 地址 0x68/0x69（SDO 引脚，与 MPU6050 同址），
-- 输出六轴原始码：ACCEL_X/Y/Z（g）与 GYRO_X/Y/Z（dps）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BMI270 (
--       name       String,
--       I2C        String,
--       address    String,
--       range      String,
--       gyro_range String,
--       odr        String,
--       cfg        String
--   );
--   INSERT INTO BMI270 (name, I2C, address, range, gyro_range, odr, cfg)
--     VALUES ('imu0', 'i2c-1', '0x68', '-', '-', '-', '-');
-- range      = 加速度计量程 g（2/4/8/16，非法值向下降档，缺省 8，同 MPU6050 驱动）
-- gyro_range = 陀螺仪量程 dps（125/250/500/1000/2000，非法值向下降档，缺省 500）
-- odr        = 输出数据率 Hz（25/50/100/200/400/800/1600，取最近档，缺省 100）
-- cfg        = 配置文件 blob：'fifo'（缺省，328B）/ 'full'（8KB，见下）
-- 各列写 '-' 按缺省值处理
--
-- 接 sensor_daemon：fields=ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z，
-- sign='16'（输出为 16 位补码语义的原始无符号码，与 MPU6050 驱动同约定，
-- 负值由守护的 sign 展开而非驱动侧转负）
--
-- 实现要点（依 Bosch BMI270-SensorAPI v2.46.1 bmi2.c/bmi2_defs.h + datasheet 钉死）：
--   1. 与 MPU6050 的两大差异，勿照搬：
--      a) 陀螺仪与特性引擎必须先上传配置文件 blob 才工作（MPU6050 写两个
--         寄存器就能用）；不传 blob 只有加速度计可用
--      b) 数据寄存器小端（LSB 在前），MPU6050 是大端——照搬会六轴全错
--   2. blob 双版本（modules/lib/bmi270_config.lua，Bosch 官方 MIT）：
--      'fifo'  = maximum_fifo 变体 328B，只含传感器数据必需配置（片上特性
--                算法不启用——框架滤波自做），上传 41 事务，Zephyr 通用驱动同款；
--      'full'  = context 变体 8KB，全特性引擎兜底；个别硅版 fifo 陀螺仪
--                不出数时换用，上传约 1s
--      上传协议（bmi2.c upload_file）：INIT_CTRL(0x59)=0 -> 每块先写内部字地址
--      （字节序号/2，12 位小端，低字节 &0x0F）到 0x5B/0x5C，再 8 字节突发写
--      INIT_DATA(0x5E) -> INIT_CTRL=1 -> 轮询 INTERNAL_STATUS(0x21) 到 0x01
--      （BMI2_INIT_OK；注意是状态码不是位掩码）
--   3. 初始化全序：软复位(0x7E<-0xB6) -> 验芯片 ID 0x24（读到 0x26 是 BMI260
--      变体）-> 关高级省电(PWR_CONF=0) -> 上电配置上传 -> ODR 读改写 [3:0] 域
--      （保留复位默认滤波）-> 量程 -> PWR_CTRL |0x06（acc+gyr）-> 等 100ms
--      陀螺仪启动
--   4. call 用 0x0C/0x12 两次 6 字节原子读（HAL.i2c_read_multi 的 I2C_RDWR
--      合并事务，无指针竞态；不并成一次 12 字节读——HAL 合并读 6 字节以上
--      超 Lua number 精度上限）
--   5. 原始码换算（写配置时定）：加速度计 LSB/g = 16384/8192/4096/2048
--      （±2/4/8/16g）；陀螺仪 LSB/dps = 262.144/131.072/65.536/32.768/16.384
--      （±125/250/500/1000/2000dps）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local CONFIG = dofile(mpath.resolve("lib/bmi270_config.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：高频采样，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_CHIP_ID    = 0x00
local REG_ACC_DATA   = 0x0C		-- 加速度计 X_LSB 起 6 字节（小端）
local REG_GYR_DATA   = 0x12		-- 陀螺仪 X_LSB 起 6 字节（小端）
local REG_INT_STATUS = 0x21		-- 内部状态码：0x01 = BMI2_INIT_OK
local REG_ACC_CONF   = 0x40		-- [3:0]=ODR [6:4]=滤波 [7]=性能模式
local REG_ACC_RANGE  = 0x41		-- [1:0]：0=±2g 1=±4g 2=±8g 3=±16g
local REG_GYR_CONF   = 0x42		-- [3:0]=ODR [6:4]=滤波 [7]=噪声性能
local REG_GYR_RANGE  = 0x43		-- [2:0]：0=±2000 1=±1000 2=±500 3=±250 4=±125dps
local REG_INIT_CTRL  = 0x59		-- 0=准备下载 1=开始加载
local REG_INIT_ADDR  = 0x5B		-- 内部字地址（0x5B 低字节 &0x0F + 0x5C 高字节）
local REG_INIT_DATA  = 0x5E		-- 配置数据窗口
local REG_PWR_CONF   = 0x7C		-- bit0 = 高级省电（上传期间必须关）
local REG_PWR_CTRL   = 0x7D		-- bit1=gyr_en bit2=acc_en
local REG_CMD        = 0x7E		-- 命令寄存器

local CHIP_ID        = 0x24
local CMD_SOFT_RESET = 0xB6
local PWR_ACC_GYR    = 0x06
local INIT_OK        = 0x01

-- 上传块长（Bosch read_write_len 上限 32 内取 8：fifo/full 两种 blob 长度
-- 均为 8 的倍数，免去官方 API 的 2 字节余量分支；字地址随块推进 4）
local CHUNK = 8

-- ==================== 配置表 ====================
-- 加速度计量程 g（代码 0..3），缺省 ±8g
local acc_tab = { 2, 4, 8, 16 }
-- 陀螺仪量程 dps（与代码逆序：125=4 ... 2000=0），缺省 ±500dps
local gyr_tab = { 125, 250, 500, 1000, 2000 }
-- 输出数据率 Hz（25Hz=代码 0x06 起），缺省 100Hz
local odr_tab = { 25, 50, 100, 200, 400, 800, 1600 }

-- 向下取档：不大于 n 的最大合法档（量程类，保守取小）；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

-- 最近取档：差值最小档（ODR 类，双向皆可），平手取低
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

local function acc_code_of(v)
	local i = snap_down(v, acc_tab, 3)
	return i - 1, acc_tab[i]
end

local function gyr_code_of(v)
	local i = snap_down(v, gyr_tab, 3)
	return #gyr_tab - i, gyr_tab[i]		-- dps 与寄存器代码逆序
end

local function odr_code_of(v)
	local i = snap_near(v, odr_tab, 3)
	return 0x05 + i, odr_tab[i]
end

-- ==================== 配置文件 blob ====================
-- hex 串惰性解码为二进制（每状态机一次）；长度不符立即失败（数据文件损坏
-- 会在驱动加载时报错，而不是 build 时静默上传垃圾）
local function hex2bin(h)
	return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end
local BLOBS = {
	fifo = hex2bin(CONFIG.FIFO_HEX),
	full = hex2bin(CONFIG.FULL_HEX),
}
if #BLOBS.fifo ~= 328 or #BLOBS.full ~= 8192 then
	error("BMI270 config blob size mismatch: fifo=" .. #BLOBS.fifo .. " full=" .. #BLOBS.full)
end

-- 上传 blob：字地址（字节序号/2，低字节 &0x0F + 高字节）-> 0x5B，再 CHUNK
-- 字节突发写 0x5E（依 bmi2.c upload_file：地址按 2 字节字粒度，burst<=32）
local function upload_blob(fd, blob)
	for i = 1, #blob, CHUNK do
		local word = math.floor((i - 1) / 2)
		local bytes = { blob:byte(i, math.min(i + CHUNK - 1, #blob)) }
		if not i2c_write_multi(fd, REG_INIT_ADDR, word % 16, math.floor(word / 16)) then
			return false
		end
		if i2c_write_multi(fd, REG_INIT_DATA, unpack(bytes)) ~= 0 then
			return false
		end
	end
	return true
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

-- 读 1 字节寄存器；失败返回 nil
local function read_reg8(fd, reg)
	local v = i2c_read_multi(fd, reg, 1)
	if v < 0 then return nil end
	return v
end

-- 【配置脚本】软复位 -> 验 ID -> 上传 blob -> ODR/量程 -> 上电
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BMI270 builder func get a table --------", data)
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
	local acc_code_v, acc_g = acc_code_of(data.range)
	local gyr_code_v, gyr_dps = gyr_code_of(data.gyro_range)
	local odr_code_v, odr_hz = odr_code_of(data.odr)
	local blob_name = (data.cfg == "full") and "full" or "fifo"
	local blob = BLOBS[blob_name]

	-----------------------------------------------------
	-- 软复位（含 450µs 复位延时，取 2ms 余量）
	if not i2c_write_reg(fd, REG_CMD, CMD_SOFT_RESET) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 soft reset"
		}
	end
	milli_sleep(2)

	-- 芯片甄别（0x26 = BMI260 变体，blob 不通用）
	local id = i2c_read_reg(fd, REG_CHIP_ID)
	if id < 0 then
		return {
			result = "ERR",
			message = "Failed to read BMI270 chip ID"
		}
	end
	if id ~= CHIP_ID then
		return {
			result = "ERR",
			message = string.format("Chip ID = 0x%02X (expect 0x24; 0x26 means BMI260 variant?)", id)
		}
	end

	-- 关高级省电（上传前提）+ 全传感器下电（复位后本就为 0，显式写保平安）
	if not i2c_write_reg(fd, REG_PWR_CONF, 0x00) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 PWR_CONF"
		}
	end
	milli_sleep(1)
	if not i2c_write_reg(fd, REG_PWR_CTRL, 0x00) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 PWR_CTRL"
		}
	end
	milli_sleep(1)

	-- 上传配置文件 blob
	if not i2c_write_reg(fd, REG_INIT_CTRL, 0x00) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 INIT_CTRL"
		}
	end
	if not upload_blob(fd, blob) then
		return {
			result = "ERR",
			message = "Failed to upload BMI270 config file (" .. blob_name .. ")"
		}
	end
	if not i2c_write_reg(fd, REG_INIT_CTRL, 0x01) then
		return {
			result = "ERR",
			message = "Failed to start BMI270 config load"
		}
	end

	-- 轮询内部状态码（0x01 = BMI2_INIT_OK），10ms 步进 50 次（500ms 超时）
	local st = -1
	for _ = 1, 50 do
		milli_sleep(10)
		st = i2c_read_reg(fd, REG_INT_STATUS)
		if st == INIT_OK or st < 0 then break end
	end
	if st < 0 then
		return {
			result = "ERR",
			message = "Failed to read BMI270 internal status"
		}
	end
	if st ~= INIT_OK then
		return {
			result = "ERR",
			message = string.format("BMI270 config load failed: internal status 0x%02X (expect 0x01 INIT_OK)",
				st)
		}
	end

	-- ODR：读改写 [3:0] 域，保留复位默认滤波/性能位
	local acc_conf = read_reg8(fd, REG_ACC_CONF)
	local gyr_conf = read_reg8(fd, REG_GYR_CONF)
	if acc_conf == nil or gyr_conf == nil then
		return {
			result = "ERR",
			message = "Failed to read BMI270 CONF registers"
		}
	end
	if not i2c_write_reg(fd, REG_ACC_CONF,
		bitc.bor(bitc.band(acc_conf, 0xF0), odr_code_v)) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 ACC_CONF"
		}
	end
	if not i2c_write_reg(fd, REG_GYR_CONF,
		bitc.bor(bitc.band(gyr_conf, 0xF0), odr_code_v)) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 GYR_CONF"
		}
	end

	-- 量程
	if not i2c_write_reg(fd, REG_ACC_RANGE, acc_code_v) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 ACC_RANGE"
		}
	end
	if not i2c_write_reg(fd, REG_GYR_RANGE, gyr_code_v) then
		return {
			result = "ERR",
			message = "Failed to write BMI270 GYR_RANGE"
		}
	end

	-- 上电：加速度计 + 陀螺仪（温度恒开；保留其余位）
	local pc = read_reg8(fd, REG_PWR_CTRL)
	if pc == nil then
		return {
			result = "ERR",
			message = "Failed to read BMI270 PWR_CTRL"
		}
	end
	if not i2c_write_reg(fd, REG_PWR_CTRL, bitc.bor(pc, PWR_ACC_GYR)) then
		return {
			result = "ERR",
			message = "Failed to enable BMI270 acc+gyr"
		}
	end

	-- 陀螺仪启动等待（数据手册 ~40ms，取 100ms 余量，首拍数据就绪）
	milli_sleep(100)

	print(string.format("BMI270 init OK: addr=0x%02X, blob=%s(%dB), ±%dg/±%ddps, odr=%dHz",
		addr, blob_name, #blob, acc_g, gyr_dps, odr_hz))
	return {  result = "OK"  }

end

-- 【销毁BMI270】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用BMI270】读六轴原始码
-- NOTE: 数据寄存器小端（LSB 在前，与 MPU6050 大端相反）；返回 16 位补码
-- 语义的无符号原始码（与 MPU6050 驱动同约定，负值由守护 sign='16' 展开）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BMI270 caller func get a table --------", data)
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
	local a = read_bytes6(fd, REG_ACC_DATA)
	if a == nil then
		return {
			result = "ERR",
			message = "Failed to read BMI270 accel data"
		}
	end
	local g = read_bytes6(fd, REG_GYR_DATA)
	if g == nil then
		return {
			result = "ERR",
			message = "Failed to read BMI270 gyro data"
		}
	end

	-- 返回字典（小端拼字：值 = MSB<<8 | LSB）
 	return {
		result  = "OK",
		ACCEL_X = bitc.bor(bitc.lshift(a[2], 8), a[1]),
		ACCEL_Y = bitc.bor(bitc.lshift(a[4], 8), a[3]),
		ACCEL_Z = bitc.bor(bitc.lshift(a[6], 8), a[5]),
		GYRO_X  = bitc.bor(bitc.lshift(g[2], 8), g[1]),
		GYRO_Y  = bitc.bor(bitc.lshift(g[4], 8), g[3]),
		GYRO_Z  = bitc.bor(bitc.lshift(g[6], 8), g[5])
	}

end

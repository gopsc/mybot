-- LSM6DSV16X 六轴 IMU（16 位加速度计 + 16 位陀螺仪）驱动模块
-- bot4cj 仓颉语言机器人框架
-- ST，I2C 地址 0x6A/0x6B（SA0 引脚，与 MPU6050/BMI270 的 0x68/0x69 错开可共存），
-- 输出六轴原始码：ACCEL_X/Y/Z（g）与 GYRO_X/Y/Z（dps）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LSM6DSV (
--       name       String,
--       I2C        String,
--       address    String,
--       range      String,
--       gyro_range String,
--       odr        String
--   );
--   INSERT INTO LSM6DSV (name, I2C, address, range, gyro_range, odr)
--     VALUES ('imu0', 'i2c-1', '0x6A', '-', '-', '-');
-- range      = 加速度计量程 g（2/4/8/16，非法值向下降档，缺省 8）
-- gyro_range = 陀螺仪量程 dps（125/250/500/1000/2000/4000，向下降档，缺省 500）
-- odr        = 输出数据率 Hz（7.5/15/30/60/120/240/480/960/1920/3840/7680，
--              取最近档，缺省 120Hz——100Hz 无对应档，'100' 也落 120）
-- 各列写 '-' 按缺省值处理
--
-- 接 sensor_daemon：fields=ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z，
-- sign='16'（输出为 16 位补码语义的原始无符号码，与 MPU6050/BMI270 驱动同
-- 约定，负值由守护展开而非驱动侧转负）
--
-- 实现要点（依 ST STM32duino lsm6dsv16x_reg.h 官方定义钉死，2026-09 提取）：
--   1. 基础六轴采集【不需要上传任何固件 blob】（FSM/MLC/SFLP 才需要），
--      初始化即写几个寄存器，比 BMI270 简单得多
--   2. 与老 ST 芯片（LSM6DSO 系）的两大布局差异，网上老示例勿照搬：
--      a) ODR 换全新统一码表（4 位域）：1.875/7.5/15/.../7680Hz，
--         老 104/208/833Hz 档位不复存在
--      b) 量程域挪出 CTRL1/CTRL2：加计 FS 在 CTRL8(0x18)[1:0]、
--         陀螺 FS 在 CTRL6(0x15)[3:0]（±4000dps=0xC，码不连续）
--   3. 数据寄存器小端（LSB 在前）：陀螺仪在前 OUTX_L_G=0x22、
--      加速度计 OUTX_L_A=0x28（与 BMI270 的"加速计在前"相反）
--   4. call 两次 6 字节原子读（HAL.i2c_read_multi 的 I2C_RDWR 合并事务；
--      12 字节并读超 HAL 合并读的 Lua number 精度上限）
--   5. 初始化全序：WHO_AM_I(0x0F)=0x70 甄别 -> CTRL3 软复位（bit0 自清，
--      轮询至清零）-> CTRL3 置 BDU(防撕裂) 保 IF_INC -> CTRL1/CTRL2 写 ODR
--      （op_mode=0 高性能）-> CTRL6/CTRL8 读改写量程 -> 等 100ms 陀螺启动
--   6. 灵敏度（ST 惯例 32768x sens > 标称量程）：±2/4/8/16g =
--      0.061/0.122/0.244/0.488 mg/LSB；±125/250/500/1000/2000/4000dps =
--      4.375/8.75/17.5/35/70/140 mdps/LSB
--   7. 仅支持 LSM6DSV16X（WHO_AM_I 0x70）；V32X 等其他家族 ID 明确报错

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
local REG_WHO_AM_I = 0x0F
local REG_CTRL1    = 0x10		-- bit[3:0]=odr_xl bit[6:4]=op_mode_xl
local REG_CTRL2    = 0x11		-- bit[3:0]=odr_g   bit[6:4]=op_mode_g
local REG_CTRL3    = 0x12		-- bit0=sw_reset(自清) bit2=if_inc bit6=bdu
local REG_CTRL6    = 0x15		-- bit[3:0]=fs_g bit[6:4]=lpf1_g_bw
local REG_CTRL8    = 0x18		-- bit[1:0]=fs_xl bit[2:4]=hp_lpf2_xl_bw...
local REG_STATUS   = 0x1E		-- bit0=xlda bit1=gda（本驱动连续模式直读不用）
local REG_OUT_G    = 0x22		-- 陀螺仪 X_LSB 起 6 字节（小端）
local REG_OUT_A    = 0x28		-- 加速度计 X_LSB 起 6 字节（小端）

local CHIP_ID      = 0x70
local BDU_MASK     = 0x40
local IF_INC_MASK  = 0x04
local SW_RESET     = 0x01

-- ==================== 配置表 ====================
-- 加速度计量程 g（CTRL8 代码 0..3），缺省 ±8g
local acc_tab = { 2, 4, 8, 16 }
-- 陀螺仪量程 dps（CTRL6 代码 0/1/2/3/4/0xC——4000 档码不连续），缺省 ±500dps
local gyr_tab  = { 125, 250, 500, 1000, 2000, 4000 }
local gyr_code = { 0x0, 0x1, 0x2, 0x3, 0x4, 0xC }
-- 输出数据率 Hz（统一 ODR 码表 0x2..0xC），缺省 120Hz
local odr_tab  = { 7.5, 15, 30, 60, 120, 240, 480, 960, 1920, 3840, 7680 }
local odr_code = { 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC }

-- 向下取档：不大于 n 的最大合法档（量程类，保守取小）；非法/非正归缺省档
local function snap_down(v, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #acc_tab, 1, -1 do
		if acc_tab[i] <= n then return i end
	end
	return def_i
end

local function acc_code_of(v)
	local i = snap_down(v, 3)
	return i - 1, acc_tab[i]
end

local function gyr_code_of(v)
	local n = tonumber(v)
	local def_i = 3
	if n == nil or n <= 0 then return gyr_code[def_i], gyr_tab[def_i] end
	for i = #gyr_tab, 1, -1 do
		if gyr_tab[i] <= n then return gyr_code[i], gyr_tab[i] end
	end
	return gyr_code[def_i], gyr_tab[def_i]
end

-- 最近取档：差值最小档（ODR 类，双向皆可），平手取低
local function odr_code_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return odr_code[5], odr_tab[5] end
	local best, bd = 5, math.huge
	for i = 1, #odr_tab do
		local d = math.abs(n - odr_tab[i])
		if d < bd then best, bd = i, d end
	end
	return odr_code[best], odr_tab[best]
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

-- 【配置脚本】WHO_AM_I 甄别 -> 软复位（自清轮询）-> BDU -> ODR/量程 -> 等启动
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- LSM6DSV builder func get a table --------", data)
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
	local fs_xl_v, acc_g = acc_code_of(data.range)
	local fs_g_v, gyr_dps = gyr_code_of(data.gyro_range)
	local odr_xl_v, odr_hz = odr_code_of(data.odr)

	-----------------------------------------------------
	-- 芯片甄别
	local id = i2c_read_reg(fd, REG_WHO_AM_I)
	if id < 0 then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X WHO_AM_I"
		}
	end
	if id ~= CHIP_ID then
		return {
			result = "ERR",
			message = string.format("WHO_AM_I = 0x%02X (expect 0x70 LSM6DSV16X; 0x6C = LSM6DSO 系，V32X 等家族亦不同)", id)
		}
	end

	-- 软复位：读改写置 bit0（保留 IF_INC），轮询自清（10ms 步进 10 次）
	local c3 = read_reg8(fd, REG_CTRL3)
	if c3 == nil then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X CTRL3"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL3, bitc.bor(c3, SW_RESET)) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X soft reset"
		}
	end
	local settled = false
	for _ = 1, 10 do
		milli_sleep(10)
		local s = i2c_read_reg(fd, REG_CTRL3)
		if s < 0 then break end
		if bitc.band(s, SW_RESET) == 0 then settled = true; break end
	end
	if not settled then
		return {
			result = "ERR",
			message = "LSM6DSV16X soft reset not completed (sw_reset bit stuck)"
		}
	end

	-- 置 BDU（输出寄存器不被读撕裂），保 IF_INC（地址自增，突发读前提）；
	-- bitcompat 无 bnot，清 bit0 用字面掩码 0xFE（此时复位已完成 bit0 必为 0）
	c3 = read_reg8(fd, REG_CTRL3)
	if c3 == nil then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X CTRL3"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL3, bitc.bor(bitc.band(c3, 0xFE), bitc.bor(BDU_MASK, IF_INC_MASK))) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X CTRL3 (BDU)"
		}
	end

	-- ODR（op_mode=0 高性能模式）+ 量程（CTRL6/CTRL8 读改写保留滤波域）
	if not i2c_write_reg(fd, REG_CTRL1, odr_xl_v) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X CTRL1 (accel ODR)"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL2, odr_xl_v) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X CTRL2 (gyro ODR)"
		}
	end
	local c6 = read_reg8(fd, REG_CTRL6)
	local c8 = read_reg8(fd, REG_CTRL8)
	if c6 == nil or c8 == nil then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X CTRL6/CTRL8"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL6, bitc.bor(bitc.band(c6, 0xF0), fs_g_v)) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X CTRL6 (gyro FS)"
		}
	end
	if not i2c_write_reg(fd, REG_CTRL8, bitc.bor(bitc.band(c8, 0xFC), fs_xl_v)) then
		return {
			result = "ERR",
			message = "Failed to write LSM6DSV16X CTRL8 (accel FS)"
		}
	end

	-- 陀螺仪启动等待（ST 惯例 ~70-80ms，取 100ms 余量，首拍数据就绪）
	milli_sleep(100)

	print(string.format("LSM6DSV16X init OK: addr=0x%02X, ±%dg/±%ddps, odr=%gHz",
		addr, acc_g, gyr_dps, odr_hz))
	return {  result = "OK"  }

end

-- 【销毁LSM6DSV】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用LSM6DSV】读六轴原始码
-- NOTE: 数据寄存器小端（LSB 在前）；返回 16 位补码语义的无符号原始码
-- （与 MPU6050/BMI270 驱动同约定，负值由守护 sign='16' 展开）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- LSM6DSV caller func get a table --------", data)
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
	local g = read_bytes6(fd, REG_OUT_G)
	if g == nil then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X gyro data"
		}
	end
	local a = read_bytes6(fd, REG_OUT_A)
	if a == nil then
		return {
			result = "ERR",
			message = "Failed to read LSM6DSV16X accel data"
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

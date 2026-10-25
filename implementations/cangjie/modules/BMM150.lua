-- BMM150 三轴地磁传感器 驱动模块（上电挂起态 + 工厂 trim 温度补偿）
-- bot4cj 仓颉语言机器人框架
-- Bosch Sensortec，I2C 地址 0x10/0x11/0x12/0x13（CSB/SDO 引脚四组合，
-- 模块常见 0x10/0x11），XY ±1300µT / Z ±2500µT，13 位 + RHALL
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BMM150 (
--       name    String,
--       I2C     String,
--       address String,
--       preset  String
--   );
--   INSERT INTO BMM150 (name, I2C, address, preset)
--     VALUES ('mag0', 'i2c-1', '0x10', '-');
-- preset = 'lowpower | 'regular | 'enhanced | 'highaccuracy（缺省 regular），
--   四种 preset 对应 ODR/重复次数表：10/10/10/20Hz，rep_xy 1/4/7/23，
--   rep_z 1/7/13/41（依 Bosch bmm150_set_presetmode 钉死）；'-' 缺省
--
-- call 无需额外参数，返回 { result, X, Y, Z }（补偿后微特斯拉浮点）。
-- 三轴补偿管线均以 /16 收尾（compensate_x/y 的末步与 compensate_z 的
-- 「LSB -> micro-tesla」换算同构），输出即 µT——依 Bosch BMM150_SensorAPI
-- master 的 int16 compensate_* 文档「data(micro-tesla) in int16_t」钉死，
-- 勿再乘缩放系数；溢出/饱和异常轴为 nil（原始码 -4096(XY)/-16384(Z)
-- 或 RHALL/trim 不可用）
-- 接 sensor_daemon：fields=X|Y|Z（浮点透传，勿配 sign）
--
-- 实现要点（寄存器/公式依 Bosch BMM150_SensorAPI master 逐行核实）：
--   1. 上电序列与所有常规芯片相反：复位后芯片处于 suspend 挂起态，
--      必须先写 0x4B bit0=1（Power Control）再等 3ms，才能读 CHIP_ID
--      （0x40 = 0x32）与 trim 寄存器
--   2. 工厂 trim 16 字节三段直读：0x5Dx2（dig_x1/y1）、0x62x4（dig_z4、
--      dig_x2、dig_y2）、0x68x10（dig_z2、dig_z1、dig_z3、dig_xy2、
--      dig_xyz1、dig_xy1），逐字节拼装含符号/掩码（0x68+5 字节高位置 0x7F）
--   3. 数据 0x42 起 8 字节：X/Y = 13 位（LSB&0xF8>>3 + MSB 有符号 x32）、
--      Z = 13 位（LSB&0xFE>>1 + MSB 有符号 x128）、RHALL = 14 位无符号
--      （LSB&0xFC>>2 + MSB x64）；原始码 -4096(XY)/-16384(Z) = 溢出
--   4. 温度补偿：Bosch compensate_x/y/z 整数管线逐行移植——C 的除法
--      向零截断（Lua floor 对负数不同，走 idiv 截断助手）、uint16/int16
--      回绕走 u16/s16 助手；黄金向量由 Bosch 原函数 C 编译生成
--      （test/test_bmm150.lua 交叉验证）
--   5. OPMODE(0x4C)：bit[4:3]=ODR（10/2/6/8/15/20/25/30Hz 码 0~7）、
--      bit[2:1]=工作模式（normal=0）；重复次数 0x51(REP_XY)/0x52(REP_Z)
--   6. 无中断/FIFO 路径（守护周期采样不需要）；正常模式典型电流 170µA

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_CHIP_ID   = 0x40
local REG_DATA      = 0x42		-- X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,Z_MSB,RHALL_LSB,RHALL_MSB
local REG_POWER     = 0x4B		-- bit0=Power Control bit7=Soft Reset
local REG_OP_MODE   = 0x4C		-- bit[4:3]=ODR bit[2:1]=工作模式
local REG_REP_XY    = 0x51
local REG_REP_Z     = 0x52
local REG_DIG_X1    = 0x5D		-- trim 段 1（2 字节）
local REG_DIG_Z4    = 0x62		-- trim 段 2（4 字节）
local REG_DIG_Z2    = 0x68		-- trim 段 3（10 字节）

local CHIP_ID       = 0x32
local POWER_ON      = 0x01
local POWER_ON_RST  = 0x81
local ODR_MSK       = 0x18
local MODE_MSK      = 0x06
local STARTUP_MS    = 3			-- BMM150_START_UP_TIME

-- 溢出与饱和常量（Bosch 原值）
local OV_XY   = -4096
local OV_Z    = -16384
local SAT_Z_P = 32767
local SAT_Z_N = -32767

-- 预设模式表（odr 码 / REP_XY / REP_Z，依 bmm150_set_presetmode）
local PRESETS = {
	lowpower     = { odr = 0x00, rxy = 0x01, rz = 0x01 },
	regular      = { odr = 0x00, rxy = 0x04, rz = 0x07 },
	enhanced     = { odr = 0x00, rxy = 0x07, rz = 0x0D },
	highaccuracy = { odr = 0x05, rxy = 0x17, rz = 0x29 },
}
local PRESET_ODR_HZ = { [0x00] = 10, [0x05] = 20 }

-- 模块级状态（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local trim = nil

-- ==================== C 语义算术助手 ====================
-- 截断除法：C 整数除法向零截断，Lua floor 对负数向 -inf，负数路径必须走 idiv
local function idiv(a, b)
	local q = a / b
	if q >= 0 then return math.floor(q) end
	return math.ceil(q)
end
-- uint16/int16/int8 回绕（Bosch 公式中的显式窄化转换）
local function u16(v) return v % 0x10000 end
local function s16(v)
	v = v % 0x10000
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end
local function s8(v)
	v = v % 0x100
	if v >= 0x80 then v = v - 0x100 end
	return v
end

-- ==================== trim 寄存器解析 ====================
-- 三段直读 0x5Dx2 / 0x62x4 / 0x68x10，拼装依 bmm150.c read_trim_registers
local function read_trim(fd)
	local t1 = i2c_read_multi_bytes(fd, REG_DIG_X1, 2)
	if t1 == nil then return nil end
	local t2 = i2c_read_multi_bytes(fd, REG_DIG_Z4, 4)
	if t2 == nil then return nil end
	local t3 = i2c_read_multi_bytes(fd, REG_DIG_Z2, 10)
	if t3 == nil then return nil end
	local t = {}
	t.dig_x1 = s8(t1[1])
	t.dig_y1 = s8(t1[2])
	t.dig_z4 = s16(t2[1] + t2[2] * 256)
	t.dig_x2 = s8(t2[3])
	t.dig_y2 = s8(t2[4])
	t.dig_z2 = s16(t3[2] * 256 + t3[1])
	t.dig_z1 = u16(t3[4] * 256 + t3[3])
	t.dig_z3 = s16(t3[8] * 256 + t3[7])
	t.dig_xy2 = s8(t3[9])
	-- dig_xyz1：高字节在 0x68+5 且仅低 7 位有效（&0x7F），低字节在 0x68+4
	t.dig_xyz1 = u16((t3[6] % 0x80) * 256 + t3[5])
	t.dig_xy1 = t3[10]
	return t
end

-- ==================== 温度补偿（Bosch compensate_x/y/z 逐行移植） ====================
local function compensate_x(mag_x, rhall, t)
	local retval = -32768
	if mag_x ~= OV_XY then
		local comp_x0 = 0
		if rhall ~= 0 then comp_x0 = rhall
		elseif t.dig_xyz1 ~= 0 then comp_x0 = t.dig_xyz1 end
		if comp_x0 ~= 0 then
			local x1 = t.dig_xyz1 * 16384
			local x2 = u16(idiv(x1, comp_x0) - 0x4000)	-- uint16 回绕
			retval = s16(x2)
			local x3 = retval * retval
			local x4 = t.dig_xy2 * idiv(x3, 128)
			local x5 = t.dig_xy1 * 128		-- dig_xy1 为 uint8_t（0~255），勿符号扩展
			local x6 = retval * x5
			local x7 = idiv(x4 + x6, 512) + 0x100000
			local x8 = s8(t.dig_x2) + 0xA0
			local x9 = idiv(x7 * x8, 4096)
			local x10 = mag_x * x9
			retval = s16(idiv(x10, 8192))
			retval = idiv(retval + s8(t.dig_x1) * 8, 16)
		end
	end
	return retval
end

local function compensate_y(mag_y, rhall, t)
	local retval = -32768
	if mag_y ~= OV_XY then
		local comp_y0 = 0
		if rhall ~= 0 then comp_y0 = rhall
		elseif t.dig_xyz1 ~= 0 then comp_y0 = t.dig_xyz1 end
		if comp_y0 ~= 0 then
			local y1 = idiv(t.dig_xyz1 * 16384, comp_y0)	-- 与 x 不同：先除后窄化
			local y2 = u16(y1 - 0x4000)
			retval = s16(y2)
			local y3 = retval * retval
			local y4 = t.dig_xy2 * idiv(y3, 128)
			local y5 = t.dig_xy1 * 128		-- dig_xy1 为 uint8_t（0~255），勿符号扩展
			local y6 = idiv(y4 + retval * y5, 512)
			local y7 = s8(t.dig_y2) + 0xA0
			local y8 = idiv((y6 + 0x100000) * y7, 4096)
			local y9 = mag_y * y8
			retval = s16(idiv(y9, 8192))
			retval = idiv(retval + s8(t.dig_y1) * 8, 16)
		end
	end
	return retval
end

local function compensate_z(mag_z, rhall, t)
	local retval = -32768
	if mag_z ~= OV_Z then
		if t.dig_z2 ~= 0 and t.dig_z1 ~= 0 and rhall ~= 0 and t.dig_xyz1 ~= 0 then
			local z0 = s16(rhall) - t.dig_xyz1
			local z1 = idiv(t.dig_z3 * z0, 4)
			local z2 = (mag_z - t.dig_z4) * 32768
			local z3 = t.dig_z1 * (s16(rhall) * 2)
			local z4 = s16(idiv(z3 + 32768, 65536))
			retval = idiv(z2 - z1, t.dig_z2 + z4)
			if retval > SAT_Z_P then retval = SAT_Z_P
			elseif retval < SAT_Z_N then retval = SAT_Z_N end
			retval = idiv(retval, 16)	-- Bosch 原注释：LSB -> micro-tesla 换算
		end
	end
	return retval
end

-- 【配置脚本】上电（挂起态 -> 工作态）-> 验 ID -> trim -> preset + normal
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BMM150 builder func get a table --------", data)
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

	-- 预设模式列（'-' 缺省 regular）
	local pname = string.lower(tostring(data.preset or "regular"))
	if pname == "-" or pname == "" then pname = "regular" end
	local p = PRESETS[pname]
	if p == nil then
		return {
			result = "ERR",
			message = "Invalid preset: '" .. tostring(data.preset) ..
				"' (expect lowpower/regular/enhanced/highaccuracy)"
		}
	end

	-----------------------------------------------------
	-- 上电：芯片复位后处于 suspend 挂起态，先写 Power Control 再等 3ms，
	-- 之后才允许读 CHIP_ID / trim
	if not i2c_write_reg(fd, REG_POWER, POWER_ON) then
		return {
			result = "ERR",
			message = "Failed to power on BMM150"
		}
	end
	milli_sleep(STARTUP_MS)

	local id = i2c_read_reg(fd, REG_CHIP_ID)
	if id < 0 then
		return {
			result = "ERR",
			message = "Failed to read BMM150 CHIP_ID"
		}
	end
	if id ~= CHIP_ID then
		return {
			result = "ERR",
			message = string.format("CHIP_ID = 0x%02X (expect 0x32, not BMM150?)", id)
		}
	end

	-- 工厂 trim 16 字节（补偿必需，无 trim 数据则输出无意义）
	trim = read_trim(fd)
	if trim == nil then
		return {
			result = "ERR",
			message = "Failed to read BMM150 trim registers"
		}
	end

	-- 预设：重复次数 + ODR，随后进 normal 模式（bit[2:1] = 0）
	if not i2c_write_reg(fd, REG_REP_XY, p.rxy) then
		return {
			result = "ERR",
			message = "Failed to write BMM150 REP_XY"
		}
	end
	if not i2c_write_reg(fd, REG_REP_Z, p.rz) then
		return {
			result = "ERR",
			message = "Failed to write BMM150 REP_Z"
		}
	end
	local mode = p.odr * 8		-- ODR 置 bit[4:3] + normal 模式（bit[2:1]=0）
	if not i2c_write_reg(fd, REG_OP_MODE, mode) then
		return {
			result = "ERR",
			message = "Failed to write BMM150 OP_MODE"
		}
	end

	print(string.format("BMM150 init OK: addr=0x%02X, preset=%s (odr=%dHz)",
		addr, pname, PRESET_ODR_HZ[p.odr] or 10))
	return {  result = "OK"  }

end

-- 【销毁BMM150】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用BMM150】读三轴，补偿换算微特斯拉
-- NOTE: 8 字节一次原子读（字节表接口）；溢出轴返回 nil
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BMM150 caller func get a table --------", data)
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
	if trim == nil then
		return {
			result = "ERR",
			message = "BMM150 not built (trim data missing)"
		}
	end

	local m = i2c_read_multi_bytes(fd, REG_DATA, 8)
	if m == nil then
		return {
			result = "ERR",
			message = "Failed to read BMM150 data"
		}
	end

	-- 13 位有符号拆装（MSB 寄存器存符号扩展位，Bosch 构造法）：
	-- X/Y 字段在 LSB 的 bit[7:3]（>>3 = /8），Z 在 bit[7:1]（>>1 = /2），
	-- RHALL 在 bit[7:2]（>>2 = /4，14 位无符号）
	local x_raw = s8(m[2]) * 32 + math.floor((m[1] % 0x100) / 8)
	local y_raw = s8(m[4]) * 32 + math.floor((m[3] % 0x100) / 8)
	local z_raw = s8(m[6]) * 128 + math.floor((m[5] % 0x100) / 2)
	local rhall = math.floor((m[8] % 0x100) * 64 + (m[7] % 0x100) / 4)

	local x = compensate_x(x_raw, rhall, trim)
	local y = compensate_y(y_raw, rhall, trim)
	local z = compensate_z(z_raw, rhall, trim)

	-- 溢出哨兵 -32768 -> nil（不能用 and/or 惯用法：then 值为 nil 时必落 or 分支）
	-- 三轴管线均已 /16 收尾、输出 µT（见文件头），无需再乘任何系数
	local X, Y, Z
	if x == -32768 then X = nil else X = x end
	if y == -32768 then Y = nil else Y = y end
	if z == -32768 then Z = nil else Z = z end

	local ret = {
		result = "OK",
		X = X,
		Y = Y,
		Z = Z
	}

	if DEBUG then
		print(string.format("BMM150: X=%s Y=%s Z=%s µT",
			tostring(ret.X), tostring(ret.Y), tostring(ret.Z)))
	end

	return ret

end

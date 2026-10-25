-- INA219 单通道高边电流/功率监测计 驱动模块（I2C，地址 0x40~0x4F）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA219 (
--       name    String,
--       I2C     String,
--       address String,
--       rshunt  String,
--       avg     String
--   );
--   INSERT INTO INA219 (name, I2C, address, rshunt, avg)
--     VALUES ('ina219-0', 'i2c-1', '0x40', '0.1', '16');
-- rshunt = 分流电阻阻值（欧姆）。CJMCU-219 模块板载 R100 = 0.1Ω（缺省值），
--   量程 ±320mV -> 约 ±3.2A；动力电堵转电流大时注意换小阻值或改用 INA3221（10mΩ）
-- avg = 每次测量的平均样本数（1/2/4/8/16/32/64/128，非法值归 16）
-- 注意：rshunt 勿写 '-'（占位符归一为 0 会使电流除零，与 ADS1115 pga/dr 同理）
--
-- call 无需额外参数，返回 { result, V(总线电压 V), I(电流 A，反流为负), P(功率 W) }
-- 接 sensor_daemon：fields=V|I|P（浮点，勿配 sign）
--
-- 实现要点（换算依 Linux 内核 drivers/iio/adc/ina2xx-adc.c 钉死）：
--   1. 分流寄存器 16 位完整有符号、无移位，LSB 10µV（PGA=/8 时量程 ±320mV）；
--      总线寄存器 13 位有效、左移 3 位（读后 >>3），LSB 4mV
--      （INA3221 是 13 位左移 3 / LSB 40µV，两颗芯片对齐与 LSB 均不同，勿照搬）
--   2. INA219 没有 ID 寄存器（INA3221 的 0xFE/0xFF 在此不存在）：
--      build 以「软复位后读回配置默认值 0x399F」做芯片甄别
--      （INA226 默认 0x4127，可区分；INA226 本身有 0xFE/0xFF ID 寄存器，无需此法）
--   3. 电流/功率寄存器（0x04/0x03）需写校准寄存器才有效——本驱动不写校准，
--      全软件换算：I = 分流压降 / Rshunt，P = V x I（与内核 ina2xx 驱动同思路，
--      省去 Current_LSB/校准公式换算链）
--   4. 连续模式（MODE=111）下寄存器始终保有最近完成的转换值，call 直接读；
--      build 后等一个转换循环（总线+分流 各 532µs x 平均次数）再返回
--   5. BRNG=1（32V 档）+ PGA=/8，器件额定测量范围仍为 0~26V

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_CONFIG  = 0x00
local REG_SHUNT   = 0x01		-- 分流电压（16 位有符号）
local REG_BUS     = 0x02		-- 总线电压（13 位左移 3，无符号）
local REG_MASK    = 0x06		-- 标志：bit1=CNVR 转换就绪，bit0=OVF 溢出

-- 配置默认值（软复位后读回应等于此值，作为芯片甄别）
local CFG_DEFAULT = 0x399F		-- BRNG=32V, PGA=/8, 双 ADC 12 位, 连续模式

-- ==================== 配置位 ====================
-- [15]=RST [13]=BRNG [12:11]=PGA [10:7]=BADC [6:3]=SADC [2:0]=MODE
local CFG_RST      = 0x8000
local CFG_BRNG_32V = bitc.lshift(1, 13)	-- 1<<13（LuaJIT 5.1 无 <<，走 bitcompat）
local CFG_PGA_DIV8 = bitc.lshift(3, 11)	-- 3<<11（分流量程 ±320mV）
local CFG_MODE_CONT = 0x7			-- 连续 + 分流 + 总线

local IT_532US_US = 532			-- 12 位单次转换时间（µs），平均模式的基时

-- 平均样本数 -> SADC/BADC 代码。datasheet 表：3=12 位单次 532µs、
-- 9=2 次、10=4、11=8、12=16、13=32、14=64、15=128 次平均
-- （8 是 12 位单次的别名码，不是"2 次平均"——旧表把 2 次映射到 8 使
-- avg≥2 的每一档实际平均次数减半，2026-09 审计 S3 已修）
local avg_tab  = { 1, 2, 4, 8, 16, 32, 64, 128 }
local avg_code = { 3, 9, 10, 11, 12, 13, 14, 15 }

local DEF_RSHUNT = 0.1			-- 缺省分流电阻 100mΩ（CJMCU-219 板载 R100）

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt

-- 换算常数
local SHUNT_LSB_V = 10e-6			-- 分流寄存器 LSB：10µV（16 位有符号）
local BUS_LSB_V   = 0.004			-- 总线寄存器 LSB：4mV（>>3 后 13 位无符号）

-- 16 位有符号还原（分流寄存器用）
local function s16(v)
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end

-- 读 16 位寄存器原始值；失败（-1）返回 nil（2 字节合并恒为正且精确，无回绕）
local function read_reg16(fd, reg)
	local v = i2c_read_multi(fd, reg, 2)
	if v < 0 then return nil end
	return v
end

-- 写 16 位寄存器（i2c_write_multi 返回 0 = 成功）
local function write_reg16(fd, reg, val16)
	local hi = math.floor(val16 / 256) % 256
	local lo = val16 % 256
	return i2c_write_multi(fd, reg, hi, lo) == 0
end

-- 平均样本数列 -> 代码（非法/'-' 归一值落到最近的合法档，缺省 16 次 = code 12）
local function avg_code_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return 12, 16 end
	for i = #avg_tab, 1, -1 do
		if n >= avg_tab[i] then return avg_code[i], avg_tab[i] end
	end
	return 12, 16
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

-- 【配置脚本】软复位 -> 配置默认值甄别芯片 -> 写工作配置 -> 等待首拍就绪
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA219 builder func get a table --------", data)
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

	-- 模块级配置：跨 call 保持
	local avg_code_v, avg_n = avg_code_of(data.avg)
	rshunt = rshunt_of(data.rshunt)

	-----------------------------------------------------
	-- 软复位
	if not write_reg16(fd, REG_CONFIG, CFG_RST) then
		return {
			result = "ERR",
			message = "Failed to write INA219 reset"
		}
	end
	milli_sleep(10)

	-- 无 ID 寄存器：读回配置默认值甄别芯片（INA3221 的 0xFE/0xFF 手段在此不存在）
	local cfg = read_reg16(fd, REG_CONFIG)
	if cfg == nil then
		return {
			result = "ERR",
			message = "Failed to read INA219 config"
		}
	end
	if cfg ~= CFG_DEFAULT then
		return {
			result = "ERR",
			message = string.format("Config after reset = 0x%04X (expect 0x%04X, not INA219?)", cfg, CFG_DEFAULT)
		}
	end

	-- 写工作配置：32V 档 + PGA /8 + 平均 + 连续模式
	local config = bitc.bor(CFG_BRNG_32V,
		bitc.bor(CFG_PGA_DIV8,
		bitc.bor(bitc.lshift(avg_code_v, 7),
		bitc.bor(bitc.lshift(avg_code_v, 3), CFG_MODE_CONT))))
	if not write_reg16(fd, REG_CONFIG, config) then
		return {
			result = "ERR",
			message = "Failed to write INA219 config"
		}
	end

	-- 等待一个转换循环（总线 + 分流 各 532µs x 平均次数），首拍数据就绪
	local loop_ms = math.ceil(2 * IT_532US_US * avg_n / 1000) + 2
	milli_sleep(loop_ms)

	print(string.format("INA219 init OK: addr=0x%02X, avg=%d, rshunt=%.4f Ω", addr, avg_n, rshunt))
	return {  result = "OK"  }

end

-- 【销毁INA219】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用INA219】读单通道：总线电压（V）、电流（A，反流为负）、功率（W）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA219 caller func get a table --------", data)
	end

	-- build 前调用时 rshunt 为 nil，除法会抛裸 Lua error（pcall 兜底信息难看）
	if rshunt == nil then
		return {
			result = "ERR",
			message = "INA219 not built (build first)"
		}
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
	local s = read_reg16(fd, REG_SHUNT)
	if s == nil then
		return {
			result = "ERR",
			message = "Failed to read INA219 shunt voltage"
		}
	end
	local b = read_reg16(fd, REG_BUS)
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read INA219 bus voltage"
		}
	end

	-----------------------------------------------------
	local shunt_v = s16(s) * SHUNT_LSB_V			-- 分流压降（V，有符号）
	local bus_v = bitc.rshift(b, 3) * BUS_LSB_V	-- 总线电压（V）

	local ret = {
		result = "OK",
		V = bus_v,						-- 总线电压（V）
		I = shunt_v / rshunt,				-- 电流（A，可负）
		P = bus_v * shunt_v / rshunt		-- 功率（W，软件计算）
	}

	if DEBUG then
		print(string.format("INA219: V=%.3fV I=%.3fA P=%.3fW", ret.V, ret.I, ret.P))
	end

	return ret

end

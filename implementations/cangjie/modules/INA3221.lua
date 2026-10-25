-- INA3221 三通道高边电流/电压监测计 驱动模块（I2C，地址 0x40~0x43）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA3221 (
--       name    String,
--       I2C     String,
--       address String,
--       avg     String,
--       rshunt1 String,
--       rshunt2 String,
--       rshunt3 String
--   );
--   INSERT INTO INA3221 (name, I2C, address, avg, rshunt1, rshunt2, rshunt3)
--     VALUES ('ina3221-0', 'i2c-1', '0x40', '16', '0.01', '0.01', '0.01');
-- avg = 每次测量的平均样本数（1/4/16/64/128/256/512/1024，非法值归 16）
-- rshuntN = 通道 N 分流电阻阻值（欧姆），缺省/非法按 0.01Ω（10mΩ，CJMCU 模块板载值）
-- 注意：rshuntN 勿写 '-'（占位符归一为 0 会使电流除零，与 ADS1115 pga/dr 同理）
--
-- call 无需额外参数，一次读全三通道，返回
--   { result, V1, I1, V2, I2, V3, I3 }（总线电压 V；电流 A，反流为负）
-- 接 sensor_daemon：fields=V1|I1|V2|I2|V3|I3（浮点，勿配 sign）
--
-- 实现要点（换算依 Linux 内核 drivers/hwmon/ina3221.c 钉死）：
--   1. 分流/总线寄存器同为 13 位有效、左移 3 位存放，读取后 >> 3；
--      分流为有符号（补码），LSB 40µV；总线无符号，LSB 8mV
--      （INA219 移植陷阱：两颗芯片对齐方向与 LSB 均不同，勿照搬 Arduino INA219 库）
--   2. 连续模式（MODE=111）下寄存器始终保有最近一次完成的转换值，call 直接读；
--      build 后等待一个完整转换循环（通道数 x (总线CT+分流CT) x 平均次数）再返回，
--      避免首拍读到复位零值
--   3. 一个芯片 = 一个硬件变量：配置寄存器是芯片级的，勿按通道拆变量互相覆盖
--   4. 电流 = 分流压降 / Rshunt，有符号；芯片内无电流/功率寄存器（INA219 的
--      校准寄存器在 INA3221 上已取消），换算全在驱动侧
--   5. build 校验制造商/芯片 ID：0xFE=0x5449("TI")、0xFF=0x3220

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
local REG_SHUNT1  = 0x01		-- 通道1 分流电压
local REG_BUS1    = 0x02		-- 通道1 总线电压
local REG_SHUNT2  = 0x03
local REG_BUS2    = 0x04
local REG_SHUNT3  = 0x05
local REG_BUS3    = 0x06
local REG_MASK    = 0x0F		-- 标志/使能（bit0 = CVRF 转换就绪）
local REG_MANUF   = 0xFE			-- 制造商 ID：0x5449("TI")
local REG_DIE     = 0xFF			-- 芯片 ID：0x3220

local ID_MANUF    = 0x5449
local ID_DIE      = 0x3220

-- ==================== 配置位（内核 ina3221.c 同款布局） ====================
-- [15]=RST [14:12]=通道使能(ch1=bit14,ch2=13,ch3=12) [11:9]=AVG
-- [8:6]=总线CT [5:3]=分流CT [2:0]=MODE(bit0 分流/bit1 总线/bit2 连续)
local CFG_RST        = 0x8000
local CFG_CH_ALL     = bitc.lshift(0x7, 12)	-- 0x7<<12（3 通道全使能）
local CFG_MODE_CONT  = 0x7			-- 连续 + 分流 + 总线
local CT_1100US      = 4			-- CT 代码 100 = 1.1ms

-- 平均样本数 -> AVG 代码（000~111）
local avg_tab = { 1, 4, 16, 64, 128, 256, 512, 1024 }

local DEF_RSHUNT = 0.01			-- 缺省分流电阻 10mΩ

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt1, rshunt2, rshunt3

-- 换算常数
local SHUNT_LSB_V = 40e-6			-- 分流寄存器 LSB：40µV（>>3 后有符号 13 位）
local BUS_LSB_V   = 0.008			-- 总线寄存器 LSB：8mV（>>3 后无符号 13 位）

-- 13 位有符号还原（分流寄存器 >>3 后使用）
local function s13(v)
	if v >= 0x1000 then v = v - 0x2000 end
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

-- 平均样本数列 -> AVG 代码（非法/占位归一值落到最近的合法档，缺省 16）
local function avg_code_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return 2, 16 end		-- 代码 2 = 16 次
	for i = #avg_tab, 1, -1 do
		if n >= avg_tab[i] then return i - 1, avg_tab[i] end
	end
	return 2, 16
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

-- 【配置脚本】校验 ID -> 软复位 -> 写配置（连续模式/三通道/平均）-> 等待首拍就绪
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA3221 builder func get a table --------", data)
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
	local avg_idx, avg_n = avg_code_of(data.avg)
	rshunt1 = rshunt_of(data.rshunt1)
	rshunt2 = rshunt_of(data.rshunt2)
	rshunt3 = rshunt_of(data.rshunt3)

	-----------------------------------------------------
	-- 校验芯片身份
	local manuf = read_reg16(fd, REG_MANUF)
	local die = read_reg16(fd, REG_DIE)
	if manuf == nil or die == nil then
		return {
			result = "ERR",
			message = "Failed to read INA3221 IDs"
		}
	end
	if manuf ~= ID_MANUF or die ~= ID_DIE then
		return {
			result = "ERR",
			message = string.format("Unexpected IDs: manuf=0x%04X die=0x%04X (not INA3221?)", manuf, die)
		}
	end

	-- 软复位，随后写入工作配置
	if not write_reg16(fd, REG_CONFIG, CFG_RST) then
		return {
			result = "ERR",
			message = "Failed to write INA3221 reset"
		}
	end
	milli_sleep(10)

	-- 连续模式 + 三通道使能 + 平均 + 1.1ms 转换时间
	local config = bitc.bor(CFG_CH_ALL,
		bitc.bor(bitc.lshift(avg_idx, 9),
		bitc.bor(bitc.lshift(CT_1100US, 6),
		bitc.bor(bitc.lshift(CT_1100US, 3), CFG_MODE_CONT))))
	if not write_reg16(fd, REG_CONFIG, config) then
		return {
			result = "ERR",
			message = "Failed to write INA3221 config"
		}
	end

	-- 等待一个完整转换循环（3 通道 x (总线CT+分流CT) x 平均次数），首拍数据就绪
	local loop_ms = math.ceil(3 * (1.1 + 1.1) * avg_n) + 2
	milli_sleep(loop_ms)

	print(string.format("INA3221 init OK: addr=0x%02X, avg=%d, rshunt=%.4f/%.4f/%.4f Ω",
		addr, avg_n, rshunt1, rshunt2, rshunt3))
	return {  result = "OK"  }

end

-- 【销毁INA3221】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用INA3221】读全三通道：总线电压（V）与电流（A，反流为负）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA3221 caller func get a table --------", data)
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

	-- build 前置守卫：rshunt1..3 仅 build 赋值，未 build 先 call 会做 nil 除法
	-- 裸 error（与 INA219 的守卫对齐）
	if rshunt1 == nil or rshunt2 == nil or rshunt3 == nil then
		return {
			result = "ERR",
			message = "INA3221 not built (build first)"
		}
	end

	-----------------------------------------------------
	local regs = { REG_SHUNT1, REG_BUS1, REG_SHUNT2, REG_BUS2, REG_SHUNT3, REG_BUS3 }
	local raw = {}
	for i, reg in ipairs(regs) do
		raw[i] = read_reg16(fd, reg)
		if raw[i] == nil then
			return {
				result = "ERR",
				message = "Failed to read INA3221 register 0x" .. string.format("%02X", reg)
			}
		end
	end

	local rsh = { rshunt1, rshunt2, rshunt3 }
	local ret = {  result = "OK"  }
	for ch = 1, 3 do
		local s = raw[2 * ch - 1]
		local b = raw[2 * ch]
		local shunt_v = s13(bitc.rshift(s, 3)) * SHUNT_LSB_V		-- 分流压降（V，有符号）
		local bus_v = bitc.rshift(b, 3) * BUS_LSB_V				-- 总线电压（V）
		-- 返回字典：Vn = 总线电压，In = 电流（可负）
		ret["V" .. ch] = bus_v
		ret["I" .. ch] = shunt_v / rsh[ch]
	end

	if DEBUG then
		print(string.format(
			"INA3221: ch1 %.3fV %.3fA | ch2 %.3fV %.3fA | ch3 %.3fV %.3fA",
			ret.V1, ret.I1, ret.V2, ret.I2, ret.V3, ret.I3))
	end

	return ret

end

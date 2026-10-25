-- INA226 单通道高边电流/功率监测计 驱动模块（I2C，地址 0x40~0x4F）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA226 (
--       name    String,
--       I2C     String,
--       address String,
--       rshunt  String,
--       avg     String,
--       ct      String
--   );
--   INSERT INTO INA226 (name, I2C, address, rshunt, avg, ct)
--     VALUES ('ina226-0', 'i2c-1', '0x40', '0.1', '16', '1100');
-- rshunt = 分流电阻阻值（欧姆）。CJMCU-226 模块板载 R100 = 0.1Ω（缺省值），
--   但分流量程固定 ±81.92mV -> 0.1Ω 仅约 ±0.82A；动力电监测建议换小阻值
--   外置分流（10mΩ -> ±8.19A），INA226 精度（0.1% 增益 / 2.5µV LSB）为 INA219 的 4 倍
-- avg = 每次测量的平均样本数（1/4/16/64/128/256/512/1024，非法值向下降档，缺省 16）
-- ct  = 单次转换时间 µs（140/204/332/588/1100/2116/4156/8244，非法值向下降档，缺省 1100）
--   注意 avg=1024 且 ct=8244 时一个转换循环约 17s，build 会等满一循环才返回
-- 各列写 '-' 按缺省值处理（直接引用路径跳过该列，守护路径 tonumber('-')=nil，均走缺省分支）
--
-- call 无需额外参数，返回 { result, V(总线电压 V), I(电流 A，反流为负), P(功率 W) }
-- 接 sensor_daemon：fields=V|I|P（浮点，勿配 sign）
--
-- 实现要点（换算依 TI datasheet SBOS547 + Linux 内核 ina2xx 钉死）：
--   1. INA226 与 INA219 寄存器布局同构（0x00 Config/0x01 Shunt/0x02 Bus/0x03 Power），
--      但换算完全不同，勿照搬：
--      分流寄存器 16 位完整有符号、无移位，LSB 2.5µV（量程固定 ±81.92mV，无 PGA）；
--      总线寄存器 16 位无符号、无移位，LSB 1.25mV（INA219 是 13 位左移 3 / LSB 4mV）
--   2. 有真 ID 寄存器（INA219 没有）：0xFE 厂商 ID 恒 0x5449（'TI'）、
--      0xFF 芯片 ID 恒 0x2260，build 据此甄别芯片；
--      软复位后配置默认值 0x4127（AVG=1, 双通道 1.1ms, 连续模式）作辅助校验
--   3. 无校准寄存器（0x05 是 Alert Limit）：芯片不输出电流值，本驱动全软件换算
--      I = 分流压降 / Rshunt，P = V x I；0x03 Power 寄存器（LSB=31.25mW=25x总线LSB）不用
--   4. 连续模式（MODE=111）下寄存器始终保有最近完成的转换值，call 直接读；
--      build 后等一个转换循环（总线+分流 各 ct x 平均次数）再返回
--   5. config 位布局与 INA219 不同：[15]=RST [14]=保留(恒1) [11:9]=AVG
--      [8:6]=VBUSCT [5:3]=VSHCT [2:0]=MODE（INA219 是 BRNG/PGA/SADC/BADC）
--   6. Mask/Enable（0x04）标志位也与 INA219（0x06）不同：bit3=CVRF 转换就绪、
--      bit2=OVF 溢出（本驱动连续模式直接读，不轮询标志）

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
local REG_CONFIG = 0x00
local REG_SHUNT  = 0x01		-- 分流电压（16 位有符号，LSB 2.5µV）
local REG_BUS    = 0x02		-- 总线电压（16 位无符号，LSB 1.25mV）
local REG_MASK   = 0x04		-- 标志：bit3=CVRF 转换就绪，bit2=OVF 溢出
local REG_MFG    = 0xFE		-- 厂商 ID，恒 0x5449（'TI'）
local REG_DIE    = 0xFF		-- 芯片 ID，恒 0x2260

-- 配置默认值（软复位后读回应等于此值，辅助校验）
local CFG_DEFAULT = 0x4127		-- AVG=1, 双通道 1.1ms, 连续模式

-- ==================== 配置位 ====================
-- [15]=RST [14]=保留(恒1) [11:9]=AVG [8:6]=VBUSCT [5:3]=VSHCT [2:0]=MODE
local CFG_RST         = 0x8000
local CFG_RESERVED_14 = 0x4000		-- bit14 保留位，复位即 1，写配置时保持
local CFG_MODE_CONT   = 0x7			-- 连续 + 分流 + 总线

-- 平均样本数档（代码 0~7）
local avg_tab = { 1, 4, 16, 64, 128, 256, 512, 1024 }

-- 单次转换时间档 µs（代码 0~7，VBUSCT/VSHCT 同档）
local ct_tab = { 140, 204, 332, 588, 1100, 2116, 4156, 8244 }

local DEF_RSHUNT = 0.1			-- 缺省分流电阻 100mΩ（CJMCU-226 板载 R100）
local DEF_AVG_IDX = 3			-- 缺省平均 16 次（avg_tab 下标）
local DEF_CT_IDX  = 5			-- 缺省转换 1.1ms（ct_tab 下标）

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt

-- 换算常数
local SHUNT_LSB_V = 2.5e-6			-- 分流寄存器 LSB：2.5µV（16 位有符号）
local BUS_LSB_V   = 1.25e-3			-- 总线寄存器 LSB：1.25mV（16 位无符号）

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

-- 数值列 -> 档位下标：向下降档到不大于 n 的最大合法档；非法/非正数归缺省档
-- （'-' 占位符经 tonumber 为 nil，同样归缺省档）
local function snap_idx(v, tab, def_idx)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_idx end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_idx
end

-- 平均样本数列 -> （代码, 实际样本数）
local function avg_code_of(v)
	local i = snap_idx(v, avg_tab, DEF_AVG_IDX)
	return i - 1, avg_tab[i]
end

-- 转换时间列 -> （代码, 实际 µs）
local function ct_code_of(v)
	local i = snap_idx(v, ct_tab, DEF_CT_IDX)
	return i - 1, ct_tab[i]
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

-- 【配置脚本】软复位 -> ID 寄存器甄别芯片 -> 写工作配置 -> 等待首拍就绪
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA226 builder func get a table --------", data)
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
	local ct_code_v, ct_us = ct_code_of(data.ct)
	rshunt = rshunt_of(data.rshunt)

	-----------------------------------------------------
	-- 软复位
	if not write_reg16(fd, REG_CONFIG, CFG_RST) then
		return {
			result = "ERR",
			message = "Failed to write INA226 reset"
		}
	end
	milli_sleep(10)

	-- ID 寄存器甄别芯片（INA219 没有的手段，INA3221 同款）
	local mfg = read_reg16(fd, REG_MFG)
	if mfg == nil then
		return {
			result = "ERR",
			message = "Failed to read INA226 manufacturer ID"
		}
	end
	if mfg ~= 0x5449 then
		return {
			result = "ERR",
			message = string.format("Manufacturer ID = 0x%04X (expect 0x5449 'TI', not INA226?)", mfg)
		}
	end
	local die = read_reg16(fd, REG_DIE)
	if die == nil then
		return {
			result = "ERR",
			message = "Failed to read INA226 die ID"
		}
	end
	if die ~= 0x2260 then
		return {
			result = "ERR",
			message = string.format("Die ID = 0x%04X (expect 0x2260, not INA226?)", die)
		}
	end

	-- 辅助校验：软复位后配置默认值
	local cfg = read_reg16(fd, REG_CONFIG)
	if cfg == nil then
		return {
			result = "ERR",
			message = "Failed to read INA226 config"
		}
	end
	if cfg ~= CFG_DEFAULT then
		return {
			result = "ERR",
			message = string.format("Config after reset = 0x%04X (expect 0x%04X)", cfg, CFG_DEFAULT)
		}
	end

	-- 写工作配置：保留位 + 平均 + 双通道转换时间 + 连续模式
	local config = bitc.bor(CFG_RESERVED_14,
		bitc.bor(bitc.lshift(avg_code_v, 9),
		bitc.bor(bitc.lshift(ct_code_v, 6),
		bitc.bor(bitc.lshift(ct_code_v, 3), CFG_MODE_CONT))))
	if not write_reg16(fd, REG_CONFIG, config) then
		return {
			result = "ERR",
			message = "Failed to write INA226 config"
		}
	end

	-- 等待一个转换循环（总线 + 分流 各 ct x 平均次数），首拍数据就绪
	local loop_ms = math.ceil(2 * ct_us * avg_n / 1000) + 2
	milli_sleep(loop_ms)

	print(string.format("INA226 init OK: addr=0x%02X, avg=%d, ct=%dµs, rshunt=%.4f Ω", addr, avg_n, ct_us, rshunt))
	return {  result = "OK"  }

end

-- 【销毁INA226】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用INA226】读单通道：总线电压（V）、电流（A，反流为负）、功率（W）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- INA226 caller func get a table --------", data)
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

	-- build 前置守卫：rshunt 仅 build 赋值，未 build 先 call 会做 nil 除法
	-- 裸 error（与 INA219 的守卫对齐）
	if rshunt == nil then
		return {
			result = "ERR",
			message = "INA226 not built (build first)"
		}
	end

	-----------------------------------------------------
	local s = read_reg16(fd, REG_SHUNT)
	if s == nil then
		return {
			result = "ERR",
			message = "Failed to read INA226 shunt voltage"
		}
	end
	local b = read_reg16(fd, REG_BUS)
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read INA226 bus voltage"
		}
	end

	-----------------------------------------------------
	local shunt_v = s16(s) * SHUNT_LSB_V			-- 分流压降（V，有符号）
	local bus_v = b * BUS_LSB_V						-- 总线电压（V，16 位无符号无移位）

	local ret = {
		result = "OK",
		V = bus_v,						-- 总线电压（V）
		I = shunt_v / rshunt,				-- 电流（A，可负）
		P = bus_v * shunt_v / rshunt		-- 功率（W，软件计算）
	}

	if DEBUG then
		print(string.format("INA226: V=%.3fV I=%.3fA P=%.3fW", ret.V, ret.I, ret.P))
	end

	return ret

end

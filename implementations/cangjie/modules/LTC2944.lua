-- LTC2944 多节电池电量计 驱动模块（I2C，地址固定 0x64）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LTC2944 (
--       name      String,
--       I2C       String,
--       address   String,
--       rsense    String,
--       prescaler String
--   );
--   INSERT INTO LTC2944 (name, I2C, address, rsense, prescaler)
--     VALUES ('gauge-0', 'i2c-1', '0x64', '0.05', '4096');
-- rsense = 分流电阻（Ω），缺省 0.05（50mΩ）——电荷量程与它成正比：
--   50mΩ 时最大可累计约 22.3mAh（M=4096），大容量电池组须换小阻值
--   （1mΩ -> 约 1.1Ah），勿写 '-'（占位符归一为 0 会使电流除零）
-- prescaler = 库仑计预分频 M（1/4/16/64/256/1024/4096，非法值归 4096 最大量程）
--
-- call 无需额外参数，返回
--   { result, CHARGE(累计电荷 mAh，自上电/配置起), V(电池电压 V),
--     I(电流 A，充电为正), T(温度 °C) }
-- 接 sensor_daemon：fields=CHARGE|V|I|T（浮点，勿配 sign）
--
-- 实现要点（换算经 ADI Linduino LTC2944.cpp 与内核 ltc2941-battery-gauge.c 双源核对）：
--   1. 寄存器地址与 LTC2943 不同：电压 0x08、电流 0x0E、温度 0x14（0x02 起为
--      电荷与阈值），勿照搬 LTC2943 驱动
--   2. 电压：16 位无符号，V = raw / 65535 x 70.8（满量程 70.8V，工作范围 3.6~60V）
--   3. 电流：偏移二进制（中点 0x7FFF = 0A），A = (raw - 0x7FFF)/0x7FFF x 0.064 / rsense
--      （ΔSENSE 满量程 ±64mV；LTC2943 为 ±60mV，勿混用）
--   4. 温度：°C = raw / 65535 x 510 - 273.15（满量程 510K）
--   5. 电荷：16 位无符号自上电/配置起累计，0xFFFF 回绕需上层处理；
--      mAh = code x 0.34e-3 x (M x 0.05) / (rsense x 4096)
--   6. 控制寄存器（0x01）：[7:6]=ADC 模式（0xC0 自动连续）、[5:3]=预分频码、
--      [0]=关断。本驱动配置为自动模式连续测量
--   7. 无 ID 寄存器；STATUS（0x00）仅作存在性检查（读不到 = 器件不在）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：电量计读取频率低，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_STATUS  = 0x00		-- 状态（存在性检查）
local REG_CONTROL = 0x01		-- 控制：[7:6]模式 [5:3]预分频 [0]关断
local REG_CHG_MSB = 0x02		-- 累计电荷
local REG_CHG_LSB = 0x03
local REG_V_MSB   = 0x08		-- 电池电压
local REG_V_LSB   = 0x09
local REG_I_MSB   = 0x0E		-- 电流（偏移二进制）
local REG_I_LSB   = 0x0F
local REG_T_MSB   = 0x14		-- 温度
local REG_T_LSB   = 0x15

-- ==================== 换算常数 ====================
local FS_VOLTAGE_V = 70.8			-- 电压满量程（V）
local FS_SENSE_V   = 0.064			-- ΔSENSE 满量程（±64mV）
local FS_TEMP_K    = 510.0			-- 温度满量程（K）
local CHARGE_LSB_AH = 0.34e-6		-- 电荷 LSB（Ah @ M=4096, 50mΩ）

-- ==================== 预分频 M -> 控制码（[5:3]） ====================
local presc_tab  = { 1, 4, 16, 64, 256, 1024, 4096 }

local DEF_RSENSE = 0.05			-- 缺省分流电阻 50mΩ

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rsense, presc_m

-- 读 16 位寄存器原始值；失败（-1）返回 nil（2 字节合并恒为正且精确，无回绕）
local function read_reg16(fd, reg)
	local v = i2c_read_multi(fd, reg, 2)
	if v < 0 then return nil end
	return v
end

-- 注意：CONTROL(0x01) 是 8 位寄存器，必须单字节写。若像 16 位寄存器一样
-- 发 [0x01, 0x00, ctrl] 三字节，器件寄存器指针自增会把 0x00 写进 CONTROL
-- （[7:6]=00 = Sleep 模式，器件不再转换）、把 ctrl 写进 CHG_MSB(0x02) 破坏累计电荷。

-- 预分频列 -> (M 值, 控制码)；非法/'-' 归一值落最大量程 4096
local function presc_code_of(v)
	local m = tonumber(v)
	if m ~= nil then
		for i = #presc_tab, 1, -1 do
			if m >= presc_tab[i] then return presc_tab[i], i - 1 end
		end
	end
	return 4096, 6
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rsense_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSENSE end
	return r
end

-- 【配置脚本】存在性检查 + 写控制（自动模式 + 预分频）
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		print("-------- LTC2944 builder func get a table --------")
		print_table(data)
		print("--------------------------------------------------")
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
	rsense = rsense_of(data.rsense)
	presc_m = presc_code_of(data.prescaler)

	-----------------------------------------------------
	-- 存在性检查（无 ID 寄存器，读不到即失败）
	local status = read_reg16(fd, REG_STATUS)
	if status == nil then
		return {
			result = "ERR",
			message = "Failed to read LTC2944 status"
		}
	end

	-- 控制字：自动模式（[7:6]=11）| 预分频码（[5:3]）
	-- 预分频码经 presc_code_of 返回的 M 反查：码 = log4(M)
	local code
	for i = 1, #presc_tab do
		if presc_tab[i] == presc_m then code = i - 1 end
	end
	local control = bitc.bor(0xC0, bitc.lshift(code, 3))
	if not i2c_write_reg(fd, REG_CONTROL, control) then
		return {
			result = "ERR",
			message = "Failed to write LTC2944 control"
		}
	end

	print(string.format("LTC2944 init OK: addr=0x%02X, rsense=%.4f Ω, prescaler M=%d, status=0x%04X",
		addr, rsense, presc_m, status))
	return {  result = "OK"  }

end

-- 【销毁LTC2944】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用LTC2944】读累计电荷 / 电压 / 电流 / 温度
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		print("-------- LTC2944 caller func get a table --------")
		print_table(data)
		print("-------------------------------------------------")
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

	-- build 前置守卫：rsense/presc_m 仅 build 赋值，未 build 先 call 会做 nil 算术
	if rsense == nil or presc_m == nil then
		return {
			result = "ERR",
			message = "LTC2944 not initialized (build first)"
		}
	end

	-----------------------------------------------------
	local chg = read_reg16(fd, REG_CHG_MSB)
	if chg == nil then
		return {
			result = "ERR",
			message = "Failed to read LTC2944 charge"
		}
	end
	local vraw = read_reg16(fd, REG_V_MSB)
	if vraw == nil then
		return {
			result = "ERR",
			message = "Failed to read LTC2944 voltage"
		}
	end
	local iraw = read_reg16(fd, REG_I_MSB)
	if iraw == nil then
		return {
			result = "ERR",
			message = "Failed to read LTC2944 current"
		}
	end
	local traw = read_reg16(fd, REG_T_MSB)
	if traw == nil then
		return {
			result = "ERR",
			message = "Failed to read LTC2944 temperature"
		}
	end

	-----------------------------------------------------
	local ret = {
		result = "OK",
		CHARGE = chg * CHARGE_LSB_AH * 1000 * (presc_m * 0.05) / (rsense * 4096),
		V = vraw / 65535.0 * FS_VOLTAGE_V,
		I = (iraw - 0x7FFF) / 0x7FFF * FS_SENSE_V / rsense,
		T = traw / 65535.0 * FS_TEMP_K - 273.15
	}

	if DEBUG then
		print(string.format("LTC2944: charge=%.2fmAh V=%.3fV I=%.3fA T=%.2fC",
			ret.CHARGE, ret.V, ret.I, ret.T))
	end

	return ret

end

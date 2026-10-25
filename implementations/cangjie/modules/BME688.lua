-- BME688.lua - 四合一环境传感器（温度/湿度/气压/气体）驱动模块
-- bot4cj 仓颉语言机器人框架
-- Bosch BME688（兼容 BME680 变体）：I2C 地址 0x76/0x77，Chip ID 0x61。
-- 气体为 MOX 传感器输出电阻（Ω）；IAQ/气味分类属 Bosch 专有 BSEC2 宿主库，
-- 本驱动不做——输出原始气体电阻交上层决策。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BME688 (
--       name       String,
--       I2C        String,
--       address    String,
--       heatr_temp String,   -- 加热器目标温度 C 100~400（默认 320）
--       heatr_dur  String,   -- 加热时长 ms 1~4032（默认 150）
--       amb_temp   String,   -- 环境温度 C（res_heat 反算用，默认 25）
--       wait       String    -- call 转换超时 ms（默认 300；守护 interval 建议 >= it）
--   );
--   INSERT INTO BME688 (name, I2C, address, heatr_temp, heatr_dur, amb_temp, wait)
--     VALUES ('env0', 'i2c-1', '0x76', '-', '-', '-', '-');
--
-- call 返回：{ result, T, P, H, GAS, GAS_OK }
--   T=°C P=Pa H=%RH（Bosch 公开 float 补偿公式）GAS=Ω GAS_OK=1 表示本次气体
--   测量 valid 且加热稳定（Bosch 建议丢弃 GAS_OK=0 的样本，本驱动仍给值+标志）。
--   强制模式逐次触发：call 阻塞等待转换完成（带气体约 160ms），超时返回 ERR
--   （守护 daemon_tick 跳拍不发布）；interval 建议 200~300ms。
--   变体 ID（0xF0）自动甄别：0x01=BME688（高量程气体路）/ 0x00=BME680（低量程）。
--
-- 寄存器事实与公式全部以 Bosch BME68x-Sensor-API v4.4.8 源码为基准：
--   校准 3 块（0x8A x23 / 0xE1 x14 / 0x00 x5，共 42 字节，H1/H2 半字节打包）；
--   数据场 17 字节（0x1D 起，20 位 P/T + 16 位 H + 10 位气体 x 高低两路）；
--   CTRL_GAS_1 的 RUN_GAS：0x10=BME680 低量程 / 0x20=BME688 高量程。
--   过采样固定 x1（T/P/H），IIR 滤波 ×3，可按需调。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（Bosch bme68x_defs.h） ====================
local REG_IDAC0     = 0x50
local REG_RES_HEAT0 = 0x5A
local REG_GAS_WAIT0 = 0x64
local REG_CTRL_GAS0 = 0x70		-- bit3 HCTRL：0=加热器使能
local REG_CTRL_GAS1 = 0x71		-- bit5:4 RUN_GAS（0x10 低/0x20 高），bit3:0 NBCONV
local REG_CTRL_HUM  = 0x72		-- bit2:0 OSR_H
local REG_FIELD0    = 0x1D		-- 数据场 0（17 字节，偏移 0x11）
local REG_CTRL_MEAS = 0x74		-- bit7:5 OSR_T，bit4:2 OSR_P，bit1:0 模式
local REG_CONFIG    = 0x75		-- bit4:2 IIR 滤波
local REG_CHIP_ID   = 0xD0
local REG_SOFT_RST  = 0xE0
local REG_COEFF1    = 0x8A		-- 23 字节
local REG_COEFF2    = 0xE1		-- 14 字节
local REG_COEFF3    = 0x00		-- 5 字节（含 res_heat_range/range_sw_err）
local REG_VARIANT   = 0xF0		-- 0x00=BME680（低量程气体）0x01=BME688（高量程）

local RST_CMD       = 0xB6
local VARIANT_680   = 0x00
local VARIANT_688   = 0x01
local CHIP_ID       = 0x61

local NEW_DATA_MSK  = 0x80
local GASM_VALID    = 0x20
local HEAT_STAB     = 0x10
local GAS_RANGE_MSK = 0x0F
local RUN_GAS_L     = 0x10
local RUN_GAS_H     = 0x20
local MODE_MSK      = 0x03
local MODE_FORCED   = 0x01

-- ==================== 工具 ====================
local function s8(v)
	v = v % 256
	if v >= 128 then v = v - 256 end
	return v
end

local function s16(v)
	v = v % 65536
	if v >= 32768 then v = v - 65536 end
	return v
end

-- 分块读 n 字节（HAL 合并读上限 8 字节；寄存器自动增量跨块连续）
local function read_block(fd, reg, n)
	local out = {}
	local done = 0
	while done < n do
		-- HAL 合并读钳制 1~6（8 字节合并值超 2^53 丢精度），按 6 分块
		local chunk = math.min(6, n - done)
		local v = i2c_read_multi(fd, reg + done, chunk)
		if v < 0 then return nil end
		for i = 0, chunk - 1 do
			out[done + i + 1] = math.floor(v / 256 ^ (chunk - 1 - i)) % 256
		end
		done = done + chunk
	end
	return out
end

-- ==================== 校准解析（get_calib_data，42 字节 1 基表） ====================
local function parse_calib(b)
	local C = {}
	-- 温度
	C.t1 = b[33] * 256 + b[32]					-- par_t1 无符号（0xE9/0xEA）
	C.t2 = s16(b[2] * 256 + b[1])				-- 0x8B/0x8A
	C.t3 = s8(b[3])
	-- 气压（注意寄存器图里 P6/P7 顺序颠倒：idx14=P7 idx15=P6）
	C.p1 = b[6] * 256 + b[5]
	C.p2 = s16(b[8] * 256 + b[7])
	C.p3 = s8(b[9])
	C.p4 = s16(b[12] * 256 + b[11])
	C.p5 = s16(b[14] * 256 + b[13])
	C.p6 = s8(b[16])
	C.p7 = s8(b[15])
	C.p8 = b[20] * 256 + b[19]
	C.p9 = s16(b[22] * 256 + b[21])
	C.p10 = b[23]
	-- 湿度（H1/H2 半字节打包）
	C.h1 = b[26] * 16 + (b[25] % 16)
	C.h2 = b[24] * 16 + math.floor(b[25] / 16)
	C.h3 = s8(b[27])
	C.h4 = s8(b[28])
	C.h5 = s8(b[29])
	C.h6 = b[30]
	C.h7 = s8(b[31])
	-- 加热器
	C.gh1 = s8(b[36])
	C.gh2 = s16(b[35] * 256 + b[34])
	C.gh3 = s8(b[37])
	C.res_heat_val = s8(b[38])
	C.res_heat_range = math.floor((b[40] % 256) % 64 / 16)
	C.range_sw_err = math.floor(s8(b[42]) / 16)
	return C
end

-- ==================== 补偿公式（Bosch BME68x-Sensor-API 浮点版） ====================
local function calc_temperature(adc, C)
	local var1 = (adc / 16384.0 - C.t1 / 1024.0) * C.t2
	local var2 = ((adc / 131072.0 - C.t1 / 8192.0) * (adc / 131072.0 - C.t1 / 8192.0)) * (C.t3 * 16.0)
	C.t_fine = var1 + var2
	return C.t_fine / 5120.0
end

local function calc_pressure(adc, C)
	local var1 = C.t_fine / 2.0 - 64000.0
	local var2 = var1 * var1 * (C.p6 / 131072.0)
	var2 = var2 + var1 * C.p5 * 2.0
	var2 = var2 / 4.0 + C.p4 * 65536.0
	var1 = (C.p3 * var1 * var1 / 16384.0 + C.p2 * var1) / 524288.0
	var1 = (1.0 + var1 / 32768.0) * C.p1
	local pres = 1048576.0 - adc
	if var1 ~= 0 then
		pres = (pres - var2 / 4096.0) * 6250.0 / var1
		var1 = C.p9 * pres * pres / 2147483648.0
		var2 = pres * (C.p8 / 32768.0)
		local var3 = (pres / 256.0) * (pres / 256.0) * (pres / 256.0) * (C.p10 / 131072.0)
		pres = pres + (var1 + var2 + var3 + C.p7 * 128.0) / 16.0
	else
		pres = 0
	end
	return pres
end

local function calc_humidity(adc, C)
	local temp_comp = C.t_fine / 5120.0
	local var1 = adc - (C.h1 * 16.0 + C.h3 / 2.0 * temp_comp)
	local var2 = var1 * (C.h2 / 262144.0 *
		(1.0 + C.h4 / 16384.0 * temp_comp + C.h5 / 1048576.0 * temp_comp * temp_comp))
	local var3 = C.h6 / 16384.0
	local var4 = C.h7 / 2097152.0
	local hum = var2 + (var3 + var4 * temp_comp) * var2 * var2
	if hum > 100.0 then hum = 100.0 elseif hum < 0.0 then hum = 0.0 end
	return hum
end

-- BME680 低量程气体路（k1/k2 修正表 + range_sw_err）
local K1 = { 0, 0, 0, 0, 0, -1, 0, -0.8, 0, 0, -0.2, -0.5, 0, -1, 0, 0 }
local K2 = { 0, 0, 0, 0, 0.1, 0.7, 0, -0.8, -0.1, 0, 0, 0, 0, 0, 0, 0 }
local function calc_gas_low(adc, gas_range, sw_err)
	local range_f = 2 ^ gas_range
	local var1 = 1340.0 + 5.0 * sw_err
	local var2 = var1 * (1.0 + K1[gas_range + 1] / 100.0)
	local var3 = 1.0 + K2[gas_range + 1] / 100.0
	return 1.0 / (var3 * 0.000000125 * range_f * (((adc - 512.0) / var2) + 1.0))
end

-- BME688 高量程气体路
local function calc_gas_high(adc, gas_range)
	local var1 = math.floor(262144 / 2 ^ gas_range)
	local var2 = (adc - 512) * 3 + 4096
	return 1000000.0 * var1 / var2
end

-- 目标温度 -> RES_HEAT 寄存器值
local function calc_res_heat(temp, C, amb_temp)
	local t = temp
	if t > 400 then t = 400 end
	local var1 = C.gh1 / 16.0 + 49.0
	local var2 = C.gh2 / 32768.0 * 0.0005 + 0.00235
	local var3 = C.gh3 / 1024.0
	local var4 = var1 * (1.0 + var2 * t)
	local var5 = var4 + var3 * amb_temp
	local r = 3.4 * (var5 * (4 / (4 + C.res_heat_range)) *
		(1 / (1 + C.res_heat_val * 0.002)) - 25)
	r = math.floor(r)
	if r < 0 then r = 0 elseif r > 255 then r = 255 end
	return r
end

-- 加热时长 -> GAS_WAIT 寄存器值
local function calc_gas_wait(dur)
	if dur >= 0xFC0 then return 0xFF end
	local factor = 0
	while dur > 0x3F do
		dur = math.floor(dur / 4)
		factor = factor + 1
	end
	return dur + factor * 64
end

-- ==================== 模块级配置 ====================
local C					-- 校准参数集（含 t_fine，跨 call 更新）
local cfg_variant		-- VARIANT_680 / VARIANT_688
local cfg_wait			-- call 转换超时 ms

-- ==================== 配置脚本 ====================
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BME688 builder func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-- 软复位 -> Chip ID -> 变体甄别
	if not i2c_write_reg(fd, REG_SOFT_RST, RST_CMD) then
		return {
			result = "ERR",
			message = "BME688 not responding (soft reset failed, check address 0x76/0x77 and wiring)"
		}
	end
	milli_sleep(10)
	local id = i2c_read_reg(fd, REG_CHIP_ID)
	if id < 0 then
		return {
			result = "ERR",
			message = "BME688 not responding (read chip id failed)"
		}
	end
	if id ~= CHIP_ID then
		return {
			result = "ERR",
			message = string.format("BME688 unexpected chip id 0x%02X (expect 0x61)", id)
		}
	end
	local variant = i2c_read_reg(fd, REG_VARIANT)
	if variant ~= VARIANT_680 and variant ~= VARIANT_688 then
		return {
			result = "ERR",
			message = string.format("BME688 unexpected variant id 0x%02X (expect 0x00/0x01)", variant)
		}
	end

	-- 读 42 字节校准（3 块）并解析
	local b1 = read_block(fd, REG_COEFF1, 23)
	local b2 = read_block(fd, REG_COEFF2, 14)
	local b3 = read_block(fd, REG_COEFF3, 5)
	if b1 == nil or b2 == nil or b3 == nil then
		return {
			result = "ERR",
			message = "BME688 not responding (read calibration failed)"
		}
	end
	local coeff = {}
	for i = 1, 23 do coeff[i] = b1[i] end
	for i = 1, 14 do coeff[23 + i] = b2[i] end
	for i = 1, 5 do coeff[37 + i] = b3[i] end
	C = parse_calib(coeff)

	-- 解析配置
	local err
	local heatr_temp = math.floor(tonumber(data.heatr_temp) or 320)
	if heatr_temp < 100 or heatr_temp > 400 then
		err = "Invalid Argument: heatr_temp '" .. tostring(data.heatr_temp) .. "' (range 100~400)"
	end
	if err then return { result = "ERR", message = err } end
	local heatr_dur = math.floor(tonumber(data.heatr_dur) or 150)
	if heatr_dur < 1 or heatr_dur > 4032 then
		return {
			result = "ERR",
			message = "Invalid Argument: heatr_dur '" .. tostring(data.heatr_dur) .. "' (range 1~4032)"
		}
	end
	local amb_temp = tonumber(data.amb_temp) or 25
	local wait = tonumber(data.wait)
	if wait == nil or wait < 0 then wait = 300 end

	-- 写配置：过采样 x1 x1 x1 + IIR x3 + 加热器设定点 0 + 运行气体位
	local wfail = nil
	local function wr(reg, val, what)
		if wfail == nil and not i2c_write_reg(fd, reg, val) then
			wfail = "BME688 not responding (" .. what .. " write failed)"
		end
	end

	wr(REG_CTRL_HUM, 0x01, "CTRL_HUM")			-- 湿度 x1
	wr(REG_CTRL_MEAS, 0x24, "CTRL_MEAS")		-- 温度/气压 x1，睡眠模式
	wr(REG_CONFIG, 0x08, "CONFIG")				-- IIR 滤波 x3
	wr(REG_RES_HEAT0, calc_res_heat(heatr_temp, C, amb_temp), "RES_HEAT0")
	wr(REG_GAS_WAIT0, calc_gas_wait(heatr_dur), "GAS_WAIT0")
	wr(REG_CTRL_GAS0, 0x00, "CTRL_GAS0")		-- 加热器使能（bit3=0）
	local run_gas = (variant == VARIANT_688) and RUN_GAS_H or RUN_GAS_L
	wr(REG_CTRL_GAS1, run_gas + 0x00, "CTRL_GAS1")	-- 设定点 0
	if wfail ~= nil then
		return {
			result = "ERR",
			message = wfail
		}
	end

	cfg_variant = variant
	cfg_wait = math.floor(wait)

	print(string.format("BME688 init OK: addr=0x%02X variant=%s heatr=%dC/%dms t1=%d p1=%d h1=%d",
		addr, variant == VARIANT_688 and "BME688" or "BME680", heatr_temp, heatr_dur, C.t1, C.p1, C.h1))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 触发一次强制模式转换（T+P+H+气体），等待完成后读场数据并补偿。
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BME688 caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	local wait_ms = tonumber(data.wait) or cfg_wait or 300
	if wait_ms < 0 then wait_ms = 0 end

	-- 触发强制模式：先置睡眠再写模式位（Bosch set_op_mode 时序）
	local ctrl = i2c_read_reg(fd, REG_CTRL_MEAS)
	if ctrl < 0 then
		return {
			result = "ERR",
			message = "BME688 not responding (read CTRL_MEAS failed)"
		}
	end
	local base = ctrl - (ctrl % 4)			-- 清模式位
	if ctrl % 4 ~= 0 then
		if not i2c_write_reg(fd, REG_CTRL_MEAS, base) then
			return {
				result = "ERR",
				message = "BME688 not responding (sleep write failed)"
			}
		end
	end
	if not i2c_write_reg(fd, REG_CTRL_MEAS, base + MODE_FORCED) then
		return {
			result = "ERR",
			message = "BME688 not responding (trigger write failed)"
		}
	end

	-- 轮询数据场 0 的 NEW_DATA 位
	local waited = 0
	local st
	while true do
		st = i2c_read_reg(fd, REG_FIELD0)
		if st < 0 then
			return {
				result = "ERR",
				message = "BME688 not responding (poll failed)"
			}
		end
		if st % 256 >= 128 then break end		-- bit7 NEW_DATA
		if waited >= wait_ms then
			return {
				result = "ERR",
				message = "BME688 conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)"
			}
		end
		milli_sleep(5)
		waited = waited + 5
	end

	-- 读 17 字节数据场
	local f = read_block(fd, REG_FIELD0, 17)
	if f == nil then
		return {
			result = "ERR",
			message = "BME688 not responding (read field failed)"
		}
	end

	local adc_pres = f[3] * 4096 + f[4] * 16 + math.floor(f[5] / 16)
	local adc_temp = f[6] * 4096 + f[7] * 16 + math.floor(f[8] / 16)
	local adc_hum  = f[9] * 256 + f[10]
	-- BME688 用高量程路（buff[15]/[16]），BME680 用低量程路（buff[13]/[14]）
	local gas_msb, gas_lsb
	if cfg_variant == VARIANT_688 then
		gas_msb, gas_lsb = f[16], f[17]
	else
		gas_msb, gas_lsb = f[14], f[15]
	end
	local adc_gas = gas_msb * 4 + math.floor(gas_lsb / 64)
	local gas_range = gas_lsb % 16
	local gas_ok = (math.floor(gas_lsb / 32) % 2 == 1) and (math.floor(gas_lsb / 16) % 2 == 1)

	local temp = calc_temperature(adc_temp, C)
	local pres = calc_pressure(adc_pres, C)
	local hum = calc_humidity(adc_hum, C)
	local gas
	if cfg_variant == VARIANT_688 then
		gas = calc_gas_high(adc_gas, gas_range)
	else
		gas = calc_gas_low(adc_gas, gas_range, C.range_sw_err)
	end

	return {
		result = "OK",
		T = temp,
		P = pres,
		H = hum,
		GAS = gas,
		GAS_OK = gas_ok and 1 or 0
	}

end

-- ==================== 销毁 ====================
-- 置睡眠模式（清 CTRL_MEAS 模式位），加热器停止；fd 归 I2C 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BME688 ender func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		local ctrl = i2c_read_reg(fd, REG_CTRL_MEAS)
		if ctrl >= 0 then
			i2c_write_reg(fd, REG_CTRL_MEAS, ctrl - (ctrl % 4))
		end
	end

	return {  result = "OK"  }

end

-- BME688.lua - 四合一环境传感器（温度/湿度/气压/气体）驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BME688_VIRT（2026-09-15 自 modules/lib/virtbus/bme688.lua
-- 迁入，单文件驱动+模型实验第四十一个 = 全部完成；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

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
local s8 = function(v) return bitc.s8(v % 256) end

local s16 = function(v) return bitc.s16(v % 65536) end

-- 分块读 n 字节（HAL 合并读上限 8 字节；寄存器自动增量跨块连续）
-- 分块读寄存器块（实现收敛至 drv_common.read_block_bytes，chunk 缺省 6，N-24）

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
	C.p8 = s16(b[20] * 256 + b[19])			-- API v4.4.8: par_p8 为 int16_t（曾漏符号）
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
require_driver("i2c", {
name = "BME688",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- BME688 builder func get a table --------", data)
	end

	-- 软复位 -> Chip ID -> 变体甄别
	if not i2c_write_reg(fd, REG_SOFT_RST, RST_CMD) then
		return err("BME688 not responding (soft reset failed, check address 0x76/0x77 and wiring)")
	end
	milli_sleep(10)
	local id = i2c_read_reg(fd, REG_CHIP_ID)
	if id < 0 then
		return err("BME688 not responding (read chip id failed)")
	end
	if id ~= CHIP_ID then
		return err(string.format("BME688 unexpected chip id 0x%02X (expect 0x61)", id))
	end
	local variant = i2c_read_reg(fd, REG_VARIANT)
	if variant ~= VARIANT_680 and variant ~= VARIANT_688 then
		return err(string.format("BME688 unexpected variant id 0x%02X (expect 0x00/0x01)", variant))
	end

	-- 读 42 字节校准（3 块）并解析
	local b1 = read_block_bytes(fd, REG_COEFF1, 23)
	local b2 = read_block_bytes(fd, REG_COEFF2, 14)
	local b3 = read_block_bytes(fd, REG_COEFF3, 5)
	if b1 == nil or b2 == nil or b3 == nil then
		return err("BME688 not responding (read calibration failed)")
	end
	local coeff = {}
	for i = 1, 23 do coeff[i] = b1[i] end
	for i = 1, 14 do coeff[23 + i] = b2[i] end
	for i = 1, 5 do coeff[37 + i] = b3[i] end
	C = parse_calib(coeff)

	-- 局部名用 emsg 而非 err：局部 err 会遮蔽 drv_common 的全局 err() 构造器
	-- 加热器三列经 num_or 而非 `tonumber(x) or 缺省`：'nan' 过 tonumber 出的是
	-- number（Lua 里 truthy），or 兜不住，而 NaN 与任何数比较都为假，下面四条
	-- 区间判定一律放行（amb_temp 更是完全没有区间判定）。NaN/inf 会一路传到
	-- calc_res_heat/calc_gas_wait，最后被 HAL 的 byte_of 挡成 nil 而报成
	-- "not responding (RES_HEAT0 write failed)"，把配置笔误误报成器件掉线。
	-- 下一行 wait 列早已是 finite_of，同一函数里两种口径正是防护漂移（审计 P3）。
	local emsg
	local heatr_temp = math.floor(num_or(data.heatr_temp, 320))
	if heatr_temp < 100 or heatr_temp > 400 then
		emsg = "Invalid Argument: heatr_temp '" .. tostring(data.heatr_temp) .. "' (range 100~400)"
	end
	if emsg then return err(emsg) end
	local heatr_dur = math.floor(num_or(data.heatr_dur, 150))
	if heatr_dur < 1 or heatr_dur > 4032 then
		return err("Invalid Argument: heatr_dur '" .. tostring(data.heatr_dur) .. "' (range 1~4032)")
	end
	local amb_temp = num_or(data.amb_temp, 25)
	local wait = finite_of(data.wait)
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
		return err(wfail)
	end

	cfg_variant = variant
	cfg_wait = math.floor(wait)

	print(string.format("BME688 init OK: addr=0x%02X variant=%s heatr=%dC/%dms t1=%d p1=%d h1=%d",
		addr, variant == VARIANT_688 and "BME688" or "BME680", heatr_temp, heatr_dur, C.t1, C.p1, C.h1))
	return {  result = "OK"  }

	end,

-- ==================== 调用 ====================
-- 触发一次强制模式转换（T+P+H+气体），等待完成后读场数据并补偿。
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- BME688 caller func get a table --------", data)
	end

	-- 经 num_or：'nan' 过 tonumber 出的是 number（Lua 里 truthy），两个 or 都
	-- 兜不住，而 `wait_ms < 0` 对 NaN 又为假，于是 NaN 会一路带到下面轮询循环的
	-- `if waited >= wait_ms then return err(...)`——NaN 与任何数比较都为假，
	-- **超时分支永不触发**：器件不就绪时循环永不退出，后端进程整个挂死。
	-- build 侧的 wait 列早已是 finite_of，call 侧漏了（防护漂移，审计 P3）。
	local wait_ms = num_or(data.wait, cfg_wait or 300)
	if wait_ms < 0 then wait_ms = 0 end

	-- 触发强制模式：先置睡眠再写模式位（Bosch set_op_mode 时序）
	local ctrl = i2c_read_reg(fd, REG_CTRL_MEAS)
	if ctrl < 0 then
		return err("BME688 not responding (read CTRL_MEAS failed)")
	end
	local base = ctrl - (ctrl % 4)			-- 清模式位
	if ctrl % 4 ~= 0 then
		if not i2c_write_reg(fd, REG_CTRL_MEAS, base) then
			return err("BME688 not responding (sleep write failed)")
		end
	end
	if not i2c_write_reg(fd, REG_CTRL_MEAS, base + MODE_FORCED) then
		return err("BME688 not responding (trigger write failed)")
	end

	-- 轮询数据场 0 的 NEW_DATA 位
	local waited = 0
	local st
	while true do
		st = i2c_read_reg(fd, REG_FIELD0)
		if st < 0 then
			return err("BME688 not responding (poll failed)")
		end
		if st % 256 >= 128 then break end		-- bit7 NEW_DATA
		if waited >= wait_ms then
			return err("BME688 conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)")
		end
		milli_sleep(5)
		waited = waited + 5
	end

	-- 读 17 字节数据场
	local f = read_block_bytes(fd, REG_FIELD0, 17)
	if f == nil then
		return err("BME688 not responding (read field failed)")
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

end,
destroy = function(ctx, data)
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		local ctrl = i2c_read_reg(fd, REG_CTRL_MEAS)
		if ctrl >= 0 then
			i2c_write_reg(fd, REG_CTRL_MEAS, ctrl - (ctrl % 4))
		end
	end
	return {  result = "OK"  }
end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】BME688_VIRT —— 2026-09-15 自 modules/lib/virtbus/bme688.lua
-- 整体迁入（单文件驱动+模型第四十一个 = 全部完成，守护 E2E 走 sensor_daemon
-- 回退路径）。约定同前四十者：① 生产路径零执行（new() 仅虚拟总线测试调用，
-- 纯闭包零外部依赖（blob 数据引用 modules/lib/bmi270_config.lua 的模式在此
-- 为 3 块 NVM 校准系数直接硬编码进模型）；模块级 M.BUS/常量/协议表全部移入
-- 段内、new() 内 `local M = BME688_VIRT` 绑定使模型体零改动移植）；② 工厂经
-- 全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载
-- 驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立
-- 实现，互证防假绿性质不变。M.BUS = "i2c"。
--
-- 定位：Bosch BME688 四合一环境传感器模型（温/压/湿/气）：3 块 42 字节 NVM
-- 校准系数（0x8A×23/0xE1×14/0x00×5 三块 burst、0xF0 变体选路；门限 = TPH
-- OSR 时长 + RUN_GAS/heat_off 使能的 GAS_WAIT）；0x1D 起 20 位 P/T + 16 位
-- H + 低/高两路 10 位气体，0xF0 变体选路；CHIP_ID/VARIANT 按 ROM 语义软复位
-- 不变以保住误挂甄别；32 拍离线码钉经独立 Bosch float 公式反解固化。纯闭包、
-- 纯算术无 bitcompat。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

BME688_VIRT = {
	_VERSION = "0.1.0",
	BUS = "i2c",
}

-- ==================== 协议常量 ====================
local R_FIELD      = 0x1D		-- 数据场 0 起（17 字节 0x1D..0x2D）
local R_IDAC0      = 0x50		-- 10 个 IDAC 0x50..0x59
local R_RES_HEAT0  = 0x5A		-- 10 个 RES_HEAT 0x5A..0x63
local R_GAS_WAIT0  = 0x64		-- 10 个 GAS_WAIT 0x64..0x6D
local R_CTRL_GAS0  = 0x70		-- bit3 heat_off（0=加热器使能）
local R_CTRL_GAS1  = 0x71		-- bit5:4 RUN_GAS，bit3:0 NBCONV
local R_CTRL_HUM   = 0x72		-- bit6 spi_mem_page，bit2:0 OSR_H
local R_CTRL_MEAS  = 0x74		-- bit7:5 OSR_T，bit4:2 OSR_P，bit1:0 模式
local R_CONFIG     = 0x75		-- bit4:2 IIR，bit0 spi3w
local R_CHIP_ID    = 0xD0
local R_VARIANT    = 0xF0		-- 0x00=BME680 低量程 / 0x01=BME688 高量程
local R_RESET      = 0xE0
local RST_CMD      = 0xB6

-- COEFF1 0x8A×23 / COEFF2 0xE1×14 / COEFF3 0x00×5（42 字节，1 基）
local C1_BASE, C1_LEN = 0x8A, 23
local C2_BASE, C2_LEN = 0xE1, 14
local C3_BASE, C3_LEN = 0x00, 5

-- OSR 码 → 测量周期数（bme68x_defs.h os_to_meas_cycles = {0,1,2,4,8,16}）
local OSC = { 0, 1, 2, 4, 8, 16, 16, 16 }

-- 42 字节 NVM 出厂种子（确定性校准组：t1=26280/p1=37103/h1=706 等，
-- 含 p8=-4000 的 s16 补码字节 b19=0x60,b20=0xF0 与 range_sw_err=2）。
-- 解析语义由驱动 parse_calib / 测试独立参考各自转录，模型只存字节。
local NVM = {
	137, 103, 4, 0,  239, 144, 176, 254, 88, 0,
	107, 12, 64, 0,  189, 45, 0, 0,  96, 240, 199, 247, 100,
	55, 178, 44, 0, 45, 236, 120, 156,
	168, 102, 190, 209, 228, 64,
	30, 0, 16, 0, 32,
}

-- virt_tick 32 拍离线码钉 {t20,p20,h16,gas10,gas_range}（每拍气体两路
-- 同码）。由独立 Bosch float 公式从物理目标反解（n0: 25.0°C/101844.6Pa/
-- 37.0%RH/12000Ω），回算误差 T<0.001°C、P<0.1Pa、H<0.002%RH、GAS<0.1%；
-- gas_range 12/13 为高量程路自动选档。测试组对 n0/n8/n24 复核原始码。
local TICK_RAWS = {
	{ 499588, 398974, 19950, 924, 12 },
	{ 501440, 399361, 19702, 132, 13 },
	{ 503221, 399843, 19563, 246, 13 },
	{ 504861, 400402, 19541, 377, 13 },
	{ 506300, 401017, 19636, 522, 13 },
	{ 507480, 401664, 19845, 668, 13 },
	{ 508357, 402320, 20156, 799, 13 },
	{ 508897, 402958, 20555, 891, 13 },
	{ 509080, 403555, 21025, 924, 13 },
	{ 508897, 404088, 21543, 891, 13 },
	{ 508357, 404535, 22089, 799, 13 },
	{ 507480, 404881, 22641, 668, 13 },
	{ 506300, 405110, 23177, 522, 13 },
	{ 504861, 405215, 23678, 377, 13 },
	{ 503221, 405190, 24127, 246, 13 },
	{ 501440, 405037, 24509, 132, 13 },
	{ 499588, 404762, 24811, 924, 12 },
	{ 497737, 404374, 25024, 766, 12 },
	{ 495956, 403889, 25141, 639, 12 },
	{ 494315, 403325, 25160, 538, 12 },
	{ 492877, 402705, 25079, 460, 12 },
	{ 491697, 402053, 24901, 402, 12 },
	{ 490819, 401393, 24632, 363, 12 },
	{ 490279, 400752, 24279, 339, 12 },
	{ 490097, 400155, 23854, 332, 12 },
	{ 490279, 399623, 23370, 339, 12 },
	{ 490819, 399179, 22845, 363, 12 },
	{ 491697, 398838, 22297, 402, 12 },
	{ 492877, 398613, 21747, 460, 12 },
	{ 494315, 398514, 21216, 538, 12 },
	{ 495956, 398542, 20725, 639, 12 },
	{ 497737, 398698, 20297, 766, 12 },
}

local function clamp(v, lo, hi)
	v = math.floor(tonumber(v) or 0)
	if v < lo then return lo elseif v > hi then return hi else return v end
end

function BME688_VIRT.new(opts)
	local M = BME688_VIRT	-- 模型体沿用原模块表引用（零改动移植）
	opts = opts or {}
	local d = {}

	-- 芯片侧状态
	local regs = {}			-- 稀疏寄存器（0..255，未定义地址读 0）
	local ptr = 0
	local clock_ms = 0
	local busy = false		-- forced 转换中
	local remaining = nil	-- 剩余门限 ms（外部时钟模式）
	local last_gate = 0
	local prearmed = false		-- virt_tick：触发即就绪（守护零真实睡眠）
	local never_ready = false	-- 门限永不到点（超时负路径）
	local new_data = false
	local meas_index = 0
	local reset_count = 0
	local write_count, read_count = 0, 0
	local frames = {}		-- 写事务副本（断言用）

	-- 身份 ROM（who 可覆写；reset/软复位回出厂 opts）
	local factory_chip = opts.chip or 0x61
	local factory_variant = opts.variant or 0x01
	local chip_id, variant = factory_chip, factory_variant

	-- 下一次转换完成时装入影子缓冲的原始码（注入 API 改，转换不改注入）
	local pend = {
		t = 524288, p = 300000, h = 30000,
		lo = { adc = 600, range = 8, valid = true, stab = true },
		hi = { adc = 600, range = 8, valid = true, stab = true },
	}

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- 寄存器初态 ----------------

	local function seed_field_por()
		-- datasheet POR：press_msb/temp_msb/hum_msb=0x80（跳过标记），余 0；
		-- 0x1D 状态位不落地（读时按状态机合成）
		regs[0x1F], regs[0x22], regs[0x25] = 0x80, 0x80, 0x80
	end

	local function seed_chip()
		-- 软复位：CHIP_ID/VARIANT 是 ROM 常量，真机软复位不变（who 覆写代表
		-- 误挂别的芯片，软复位不能「洗」回 0x61/0x01，否则误挂甄别被架空）；
		-- 身份回出厂只发生在上电 d:reset()
		regs = {}
		seed_field_por()
		busy, remaining, new_data = false, nil, false
		meas_index, clock_ms, last_gate = 0, 0, 0
	end

	-- ---------------- 转换状态机 ----------------

	-- TPHG 门限（ms）：TPH 时长按 OSR 现解码 + 使能时的 gas_wait
	local function cur_gate_ms()
		local cm = regs[R_CTRL_MEAS] or 0
		local ch = regs[R_CTRL_HUM] or 0
		local ct = OSC[math.floor(cm / 32) % 8 + 1]
		local cp = OSC[math.floor(cm / 4) % 8 + 1]
		local cH = OSC[(ch % 8) + 1]
		local us = (ct + cp + cH) * 1963 + 477 * 4 + 477 * 5 + 1000
		local tph = math.floor(us / 1000)
		if us % 1000 ~= 0 then tph = tph + 1 end
		local gasms = 0
		local g1, g0 = regs[R_CTRL_GAS1] or 0, regs[R_CTRL_GAS0] or 0
		if math.floor(g1 / 16) % 4 ~= 0 and math.floor(g0 / 8) % 2 == 0 then
			-- RUN_GAS 域 bit5:4 =01 低量程/10 高量程，且 heat_off bit3=0
			-- （域值 11 保留，按禁用处理）
			local v = regs[R_GAS_WAIT0 + (g1 % 16)] or 0
			gasms = (v % 64) * 4 ^ math.floor(v / 64)
		end
		return tph + gasms
	end

	local function pack_gas(into, g)
		local flags = (g.valid and 0x20 or 0) + (g.stab and 0x10 or 0)
		into.msb = math.floor(g.adc / 4) % 256
		into.lsb = (g.adc % 4) * 64 + flags + (g.range % 16)
	end

	local function fill_field()
		-- 转换结束：影子缓冲整体装入（防撕裂），meas_index 递增
		regs[0x1F] = math.floor(pend.p / 4096) % 256
		regs[0x20] = math.floor(pend.p / 16) % 256
		regs[0x21] = (pend.p % 16) * 16
		regs[0x22] = math.floor(pend.t / 4096) % 256
		regs[0x23] = math.floor(pend.t / 16) % 256
		regs[0x24] = (pend.t % 16) * 16
		regs[0x25] = math.floor(pend.h / 256) % 256
		regs[0x26] = pend.h % 256
		local gl, gh = {}, {}
		pack_gas(gl, pend.lo); pack_gas(gh, pend.hi)
		regs[0x2A], regs[0x2B] = gl.msb, gl.lsb
		regs[0x2C], regs[0x2D] = gh.msb, gh.lsb
		regs[0x1E] = meas_index
		meas_index = (meas_index + 1) % 256
	end

	local function finish_conv()
		busy, remaining = false, 0
		fill_field()
		new_data = true
	end

	local function start_conv()
		new_data = false
		last_gate = cur_gate_ms()
		if never_ready then
			busy, remaining = true, nil
		elseif prearmed then
			busy, remaining = true, 0
			finish_conv()
		else
			busy, remaining = true, last_gate
		end
	end

	-- 单测虚拟时钟：驱动 milli_sleep 桩转调；门限到点自动装场
	function d:advance(ms)
		clock_ms = clock_ms + math.max(0, math.floor(tonumber(ms) or 0))
		if busy and remaining ~= nil then
			remaining = remaining - math.max(0, math.floor(tonumber(ms) or 0))
			if remaining <= 0 then finish_conv() end
		end
		return self
	end

	-- ---------------- 地址解码（动态/ROM/寄存器） ----------------

	local function nvm_byte(a)
		if a >= C1_BASE and a < C1_BASE + C1_LEN then
			return NVM[a - C1_BASE + 1]
		end
		if a >= C2_BASE and a < C2_BASE + C2_LEN then
			return NVM[C1_LEN + (a - C2_BASE) + 1]
		end
		if a >= C3_BASE and a < C3_BASE + C3_LEN then
			return NVM[C1_LEN + C2_LEN + (a - C3_BASE) + 1]
		end
		return nil
	end

	-- 转换中读：门限惰性到点（advance 已推时钟时首次读即完成）
	local function check_due()
		if busy and remaining ~= nil and remaining <= 0 then finish_conv() end
	end

	local function byte_at(a)
		if a == R_FIELD then
			if busy then return 0x60 end		-- measuring+gas_measuring，index=0
			return new_data and 0x80 or 0x00
		end
		if a == R_CTRL_MEAS then
			return (regs[a] or 0) - ((regs[a] or 0) % 4) + (busy and 1 or 0)
		end
		if a == R_CHIP_ID then return chip_id end
		if a == R_VARIANT then return variant end
		local nb = nvm_byte(a)
		if nb ~= nil then return nb end
		return regs[a] or 0
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	local function is_byte(v)
		return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 255
	end

	local function is_ro(a)
		return (a >= R_FIELD and a <= 0x2D)
			or (a >= C1_BASE and a < C1_BASE + C1_LEN)
			or (a >= C2_BASE and a < C2_BASE + C2_LEN)
			or (a >= C3_BASE and a < C3_BASE + C3_LEN)
			or a == R_CHIP_ID or a == R_VARIANT
	end

	local function put_byte(a, v)
		if a == R_RESET then return end		-- 复位命令在帧层处理，不落盘
		if is_ro(a) then return end
		-- 测量中：控制/加热器寄存器写被器件忽略（datasheet 5.3.6.2）
		if busy and a >= 0x50 and a <= 0x75 then return end
		if a == R_CTRL_GAS0 then
			regs[a] = (math.floor(v / 8) % 2) * 8	-- 仅 bit3 heat_off 有定义
		elseif a == R_CTRL_GAS1 then
			regs[a] = v % 64				-- bit5:4 RUN_GAS + bit3:0 NBCONV
		elseif a == R_CTRL_HUM then
			regs[a] = (math.floor(v / 64) % 2) * 64 + (v % 8)	-- bit6 + OSR_H
		elseif a == R_CTRL_MEAS then
			regs[a] = v - (v % 4)	-- 模式位动态，不落地
		elseif a == R_CONFIG then
			regs[a] = (math.floor(v / 4) % 8) * 4 + (v % 2)	-- IIR bit4:2 + bit0
		else
			regs[a] = v
		end
	end

	function d.write(bytes)
		write_count = write_count + 1
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		for i = 1, #bytes do
			if not is_byte(bytes[i]) then return false end
		end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end

		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] end
		frames[#frames + 1] = cp

		if #bytes == 1 then
			ptr = bytes[1]
			return true
		end
		local base = bytes[1]
		for i = 2, #bytes do
			local a, v = (base + i - 2) % 256, bytes[i]
			if a == R_RESET and v == RST_CMD then
				-- 软复位：重种芯片态；注入码/预武装/故障钩子保留
				seed_chip()
				reset_count = reset_count + 1
			else
				put_byte(a, v)
			end
		end
		if (bytes[1] == R_CTRL_MEAS) and (not busy) and (bytes[2] % 4 == 1) then
			start_conv()
		end
		return true
	end

	function d.read(n)
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		check_due()
		local t, touched = {}, false
		for _ = 1, n do
			if ptr == R_FIELD then touched = true end
			t[#t + 1] = byte_at(ptr)
			ptr = (ptr + 1) % 256
		end
		-- 「new data, not already read-out」：含状态字节的读事务返回后清位
		if touched then new_data = false end
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 注入下一次转换的 T/P/H 原始码（nil 保持原值；T/P 20 位、H 16 位）
	function d:set_tph_raw(t, p, h)
		if t ~= nil then pend.t = clamp(t, 0, 0xFFFFF) end
		if p ~= nil then pend.p = clamp(p, 0, 0xFFFFF) end
		if h ~= nil then pend.h = clamp(h, 0, 0xFFFF) end
		return self
	end

	-- 注入某条气体路原始码：path="low"(0x2A/2B BME680) | "high"(0x2C/2D BME688)；
	-- nil 参数保持原值（故 set_gas_flags 可只改两标志）
	function d:set_gas_raw(path, adc, range, valid, stab)
		local g = path == "low" and pend.lo or pend.hi
		if adc ~= nil then g.adc = clamp(adc, 0, 1023) end
		if range ~= nil then g.range = clamp(range, 0, 15) end
		if valid ~= nil then g.valid = valid and true or false end
		if stab ~= nil then g.stab = stab and true or false end
		return self
	end

	function d:set_gas_flags(path, valid, stab)
		return self:set_gas_raw(path, nil, nil, valid, stab)
	end
	function d:set_meas_index(n)
		meas_index = clamp(n, 0, 255)
		return self
	end

	function d:set_never_ready(on)
		never_ready = on ~= false
		return self
	end

	function d:who(chip, v)
		if chip ~= nil then chip_id = math.floor(chip) % 256 end
		if v ~= nil then variant = math.floor(v) % 256 end
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil
		never_ready = false
		return self
	end

	function d:reset_logs()
		frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 上电复位：芯片态回出厂、注入回默认、预武装解除；故障钩子保留
	function d:reset()
		seed_chip()
		chip_id, variant = factory_chip, factory_variant
		reset_count, ptr = 0, 0
		pend = {
			t = 524288, p = 300000, h = 30000,
			lo = { adc = 600, range = 8, valid = true, stab = true },
			hi = { adc = 600, range = 8, valid = true, stab = true },
		}
		prearmed, never_ready = false, false
		frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 守护逐拍造数：装离线码钉 + 预武装（触发即就绪，零真实转换睡眠）
	function d:virt_tick(n)
		local row = TICK_RAWS[(math.floor(tonumber(n) or 0) % 32) + 1]
		pend.t, pend.p, pend.h = row[1], row[2], row[3]
		pend.lo.adc, pend.lo.range, pend.lo.valid, pend.lo.stab = row[4], row[5], true, true
		pend.hi.adc, pend.hi.range, pend.hi.valid, pend.hi.stab = row[4], row[5], true, true
		prearmed = true
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:pointer() return ptr end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:is_busy() return busy end
	function d:has_new_data() return new_data end
	function d:remaining_ms() return remaining end
	function d:reset_count() return reset_count end
	function d:meas_index() return meas_index	-- 下一场将装入的索引
	end
	function d:last_gate_ms() return last_gate end
	function d:chip_id() return chip_id end
	function d:variant() return variant end
	function d:is_prearmed() return prearmed end
	function d:regs() return regs end
	function d:frames() return frames end
	function d:nvm()
		local cp = {}
		for i = 1, #NVM do cp[i] = NVM[i] end
		return cp
	end
	function d:raw()
		return pend.t, pend.p, pend.h,
			pend.hi.adc, pend.hi.range, pend.hi.valid, pend.hi.stab,
			pend.lo.adc, pend.lo.range, pend.lo.valid, pend.lo.stab
	end
	-- 当前配置解码（OSR 码/气体使能/本拍 gas_wait ms）
	function d:config()
		local cm = regs[R_CTRL_MEAS] or 0
		local ch = regs[R_CTRL_HUM] or 0
		local g1, g0 = regs[R_CTRL_GAS1] or 0, regs[R_CTRL_GAS0] or 0
		local gw = 0
		if math.floor(g1 / 16) % 4 ~= 0 and math.floor(g0 / 8) % 2 == 0 then
			local v = regs[R_GAS_WAIT0 + (g1 % 16)] or 0
			gw = (v % 64) * 4 ^ math.floor(v / 64)
		end
		return {
			os_t = math.floor(cm / 32) % 8,
			os_p = math.floor(cm / 4) % 8,
			os_h = ch % 8,
			run_gas = math.floor(g1 / 16) % 4,
			heat_off = math.floor(g0 / 8) % 2,
			nb_conv = g1 % 16,
			iir = math.floor((regs[R_CONFIG] or 0) / 4) % 8,
			gas_wait_ms = gw,
		}
	end

	seed_chip()
	return d
end

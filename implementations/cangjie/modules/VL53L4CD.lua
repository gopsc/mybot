-- VL53L4CD ToF 激光测距 驱动模块（ST FlightSense，I2C 地址 0x29）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE VL53L4CD (
--       name    String,
--       I2C     String,
--       address String,
--       budget  String,
--       inter   String,
--       timeout String
--   );
--   INSERT INTO VL53L4CD (name, I2C, address)
--     VALUES ('tof0', 'i2c-1', '0x29');
--
-- 列说明（均可选，'-' 归缺省）：
--   budget  = 单次测量 timing budget ms（10~200，缺省 50，ST 初始化同款）
--   inter   = 测量间隔 ms：0 = 连续模式（缺省，背靠背测量）；
--             >budget = 自主低功耗模式（间隔必须大于 budget，否则报错）
--   timeout = build/call 等待 data-ready 的超时 ms（缺省 1000，ST 同款）
--
-- call 无需参数，返回：
--   { result, DIST_MM(毫米), STATUS(0 = 有效，其余为 ST 错误码), VALID(1/0),
--     SPAD_NB(有效 SPAD 数), SIGNAL_KCPS / AMBIENT_KCPS(信号/环境光速率)，
--     SIGMA_MM(标准差，测量质量) }
-- 接 sensor_daemon：fields=DIST_MM|STATUS|VALID|SIGNAL_KCPS
--   （interval >= budget；STATUS 非 0 / VALID=0 的样本在消费侧过滤——
--   强阳光直射、全黑目标会缩程或丢数据，靠质量字段识别）
--
-- build 流程（自 ST ULD vl53l4cd_api.c 逐行移植）：
--   软复位(0x0000=0x00->0x01) -> 等固件启动(0x00E5==3) ->
--   写默认配置流(0x2D~0x87 共 91 字节，单事务流写) -> VHV 预热测量
--   (0x0087=0x40，等 ready，清中断，停) -> VHV/OSC 配置三写 ->
--   SetRangeTiming(budget, inter) -> 启动测距(连续 0x21/自主 0x40) ->
--   等首个测量就绪 + 清中断（兼做全链路自检）
--
-- 实现要点：
--   1. 寄存器地址 16 位——走 HAL 的 i2c_write_reg16/i2c_read_reg16
--      （指针写与数据读合并为单次 I2C_RDWR 原子事务，避免指针竞态）
--   2. SetRangeTiming 预算编码逐行移植 ST 源码：整数除法、32 位回绕、
--      指数/尾数归一化循环均与 C 一致；1.055 系数 C 端为 float32，
--      本移植用 double，自主模式的间隔寄存器可能相差 1 tick（微秒级，无碍）
--   3. data-ready 判定含极性处理：0x0030 bit4 决定 0x0031 bit0 的有效极性
--   4. 从机地址固定 0x29，一条总线挂多只要 XSHUT 时序重分配地址，
--      本驱动按单只支持

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：测距高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（16 位地址，值大端） ====================
local REG_SOFT_RESET        = 0x0000		-- 0x00 复位保持 / 0x01 释放
local REG_OSC_FREQUENCY     = 0x0006		-- 振荡器频率（word）
local REG_VHV_LOOP_BOUND    = 0x0008
local REG_GPIO_HV_MUX_CTRL  = 0x0030		-- bit4：GPIO 中断极性
local REG_GPIO_TIO_HV_STATUS = 0x0031		-- bit0：data-ready（极性见上）
local REG_RANGE_CONFIG_A    = 0x005E		-- timing budget 编码 A
local REG_RANGE_CONFIG_B    = 0x0061		-- timing budget 编码 B
local REG_INTERMEASUREMENT_MS = 0x006C		-- 测量间隔（dword，0 = 连续）
local REG_SYSTEM_INTERRUPT_CLEAR = 0x0086	-- 写 0x01 清中断
local REG_SYSTEM_START      = 0x0087		-- 0x21 连续 / 0x40 自主 / 0x00 停
local REG_RESULT_RANGE_STATUS = 0x0089		-- bit[4:0] 原始状态
local REG_RESULT_SPAD_NB    = 0x008C		-- word，/256 = 有效 SPAD 数
local REG_RESULT_SIGNAL_RATE = 0x008E		-- word，x8 = kcps
local REG_RESULT_AMBIENT_RATE = 0x0090		-- word，x8 = kcps
local REG_RESULT_SIGMA      = 0x0092		-- word，/4 = mm
local REG_RESULT_DISTANCE   = 0x0096		-- word，毫米
local REG_OSC_CALIBRATE     = 0x00DE		-- bit[9:0] PLL 校准值
local REG_FIRMWARE_SYSTEM_STATUS = 0x00E5	-- ==3 固件就绪

-- ==================== 默认配置流（0x2D~0x87 共 91 字节） ====================
-- 自 ST ULD VL53L4CD_SensorInit 的 default config 表逐字节转录
local CONFIG_TABLE = {
	0x00, 0x01, 0x01, 0x11, 0x02, 0x00, 0x02, 0x08, 0x00, 0x08,		-- 0x2D~
	0x10, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x0F,		-- 0x37~
	0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x02,		-- 0x41~
	0x14, 0x21, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC8,		-- 0x4B~
	0x00, 0x00, 0x38, 0xFF, 0x01, 0x00, 0x08, 0x00, 0x00, 0x01,		-- 0x55~
	0xCC, 0x07, 0x01, 0xF1, 0x05, 0x00, 0xA0, 0x00, 0x80, 0x08,		-- 0x5F~
	0x38, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x89, 0x00, 0x00, 0x00,		-- 0x69~
	0x00, 0x00, 0x00, 0x00, 0x01, 0x07, 0x05, 0x06, 0x06, 0x00,		-- 0x73~
	0x00, 0x02, 0xC7, 0xFF, 0x9B, 0x00, 0x00, 0x00, 0x01, 0x00,		-- 0x7D~
	0x00,															-- 0x87
}

-- ==================== 状态映射 ====================
-- 原始状态(&0x1F) -> ST 状态码；映射值 0 = 测量有效（ST ULD status_rtn 表）
local STATUS_RTN = {
	255, 255, 255, 5, 2, 4, 1, 7, 3, 0,			-- 0x00~
	255, 255, 9, 13, 255, 255, 255, 255, 10, 6,	-- 0x0A~
	255, 255, 11, 12,							-- 0x14~
}

local DEF_BUDGET  = 50
local DEF_INTER   = 0
local DEF_TIMEOUT = 1000

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local poll_timeout

-- ==================== 底层辅助 ====================
-- 数值列 -> 钳到 [lo, hi] 的整数；非法/'-' 归缺省
local function int_of(v, def, lo, hi)
	local n = tonumber(v)
	if n == nil then return def end
	n = math.floor(n)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

-- 写 32 位大端值到 16 位指针寄存器，返回 0 = 成功
local function wr_reg32(fd, reg16, v)
	v = v % 4294967296
	return i2c_write_reg16(fd, reg16,
		math.floor(v / 16777216) % 256,
		math.floor(v / 65536) % 256,
		math.floor(v / 256) % 256,
		v % 256)
end

-- data-ready 查询（ST CheckForDataReady 语义，含极性处理）
-- 返回 true(就绪) / false(未就绪) / nil(总线失败)
local function check_data_ready(fd)
	local mux = i2c_read_reg16(fd, REG_GPIO_HV_MUX_CTRL, 1)
	if mux < 0 then return nil end
	local int_pol = (math.floor(mux / 16) % 2 == 1) and 0 or 1		-- bit4
	local tio = i2c_read_reg16(fd, REG_GPIO_TIO_HV_STATUS, 1)
	if tio < 0 then return nil end
	return (tio % 2) == int_pol										-- bit0
end

-- 轮询等待 data-ready：true 就绪 / false 超时 / nil 总线失败
local function wait_ready(fd, timeout_ms)
	local left = timeout_ms
	while left > 0 do
		local r = check_data_ready(fd)
		if r == nil then return nil end
		if r then return true end
		milli_sleep(1)
		left = left - 1
	end
	return false
end

-- ST ULD SetRangeTiming 逐行移植：整数除法与 32 位回绕同 C
-- （1.055 系数 C 端为 float32，此处 double，自主模式间隔可能差 1 tick，无碍）
-- 指数/尾数编码：值 >255 则循环右移，指数记在高位字节
local function encode_timeout(tb_us, tmp)
	local d = math.floor(tmp / 64)
	local ls = math.floor((tb_us + math.floor(d / 2)) / d) - 1
	local exp = 0
	while ls > 255 do
		ls = math.floor(ls / 2)
		exp = exp + 1
	end
	return exp * 256 + ls
end

local function set_range_timing(fd, budget_ms, inter_ms)
	if budget_ms < 10 or budget_ms > 200 then
		return nil, "Invalid timing budget (10~200ms)"
	end
	if inter_ms ~= 0 and inter_ms <= budget_ms then
		return nil, "Invalid inter-measurement (0 or > budget)"
	end

	local osc = i2c_read_reg16(fd, REG_OSC_FREQUENCY, 2)
	if osc <= 0 then
		return nil, "Failed to read oscillator frequency"
	end
	-- C: macro_period_us = (2304 * (0x40000000 / osc)) >> 6（uint32 乘法回绕）
	local macro = math.floor(2304 * math.floor(0x40000000 / osc)) % 4294967296
	macro = math.floor(macro / 64)

	local tb = budget_ms * 1000
	if inter_ms == 0 then
		-- 连续模式
		if wr_reg32(fd, REG_INTERMEASUREMENT_MS, 0) ~= 0 then
			return nil, "Failed to write inter-measurement"
		end
		tb = tb - 2500
	else
		-- 自主低功耗模式
		local cal = i2c_read_reg16(fd, REG_OSC_CALIBRATE, 2)
		if cal < 0 then
			return nil, "Failed to read oscillator calibrate value"
		end
		local clock_pll = cal % 1024						-- & 0x3FF
		local factor = math.floor(1.055 * inter_ms * clock_pll)
		if wr_reg32(fd, REG_INTERMEASUREMENT_MS, factor) ~= 0 then
			return nil, "Failed to write inter-measurement"
		end
		tb = tb - 4300
		tb = math.floor(tb / 2)
	end

	tb = tb * 4096										-- << 12
	local a = encode_timeout(tb, macro * 16)
	local b = encode_timeout(tb, macro * 12)
	if i2c_write_reg16(fd, REG_RANGE_CONFIG_A, math.floor(a / 256) % 256, a % 256) ~= 0 then
		return nil, "Failed to write range config A"
	end
	if i2c_write_reg16(fd, REG_RANGE_CONFIG_B, math.floor(b / 256) % 256, b % 256) ~= 0 then
		return nil, "Failed to write range config B"
	end
	return true
end

-- 【配置脚本】软复位 -> 等固件 -> 默认配置流 -> VHV 预热 -> 时序 -> 启动
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- VL53L4CD builder func get a table --------", data)
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

	local budget = int_of(data.budget, DEF_BUDGET, 10, 200)
	local inter = int_of(data.inter, DEF_INTER, 0, 2147483647)
	local timeout = int_of(data.timeout, DEF_TIMEOUT, 1, 10000)
	poll_timeout = timeout

	-----------------------------------------------------
	-- 软复位（0x00 保持 / 0x01 释放）
	if i2c_write_reg16(fd, REG_SOFT_RESET, 0x00) ~= 0 then
		return {  result = "ERR", message = "Failed to reset VL53L4CD"  }
	end
	milli_sleep(1)
	if i2c_write_reg16(fd, REG_SOFT_RESET, 0x01) ~= 0 then
		return {  result = "ERR", message = "Failed to release VL53L4CD reset"  }
	end
	milli_sleep(5)

	-- 等固件启动（0x00E5 == 3）
	local left = timeout
	while true do
		local boot = i2c_read_reg16(fd, REG_FIRMWARE_SYSTEM_STATUS, 1)
		if boot < 0 then
			return {  result = "ERR", message = "Failed to read firmware boot status"  }
		end
		if boot == 3 then break end
		if left <= 0 then
			return {  result = "ERR", message = string.format("VL53L4CD firmware boot timeout (%dms, status=%d)", timeout, boot)  }
		end
		milli_sleep(1)
		left = left - 1
	end

	-- 默认配置流（0x2D~0x87，91 字节单事务流写，器件指针自增）
	if i2c_write_reg16(fd, 0x002D, unpack(CONFIG_TABLE)) ~= 0 then
		return {  result = "ERR", message = "Failed to write default config"  }
	end

	-- VHV 预热测量：启动 -> 等 ready -> 清中断 -> 停
	if i2c_write_reg16(fd, REG_SYSTEM_START, 0x40) ~= 0 then
		return {  result = "ERR", message = "Failed to start VL53L4CD VHV"  }
	end
	local r = wait_ready(fd, timeout)
	if r == nil then
		return {  result = "ERR", message = "Failed to poll VL53L4CD data-ready"  }
	end
	if r == false then
		return {  result = "ERR", message = string.format("VL53L4CD VHV measurement ready timeout (%dms)", timeout)  }
	end
	if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
		return {  result = "ERR", message = "Failed to clear VL53L4CD interrupt"  }
	end
	if i2c_write_reg16(fd, REG_SYSTEM_START, 0x00) ~= 0 then
		return {  result = "ERR", message = "Failed to stop VL53L4CD VHV"  }
	end

	-- VHV/OSC 配置收尾（ST SensorInit 尾部三写）
	if i2c_write_reg16(fd, REG_VHV_LOOP_BOUND, 0x09) ~= 0 then
		return {  result = "ERR", message = "Failed to write VL53L4CD VHV config"  }
	end
	if i2c_write_reg16(fd, 0x000B, 0x00) ~= 0 then
		return {  result = "ERR", message = "Failed to write VL53L4CD 0x000B"  }
	end
	if i2c_write_reg16(fd, 0x0024, 0x05, 0x00) ~= 0 then
		return {  result = "ERR", message = "Failed to write VL53L4CD 0x0024"  }
	end

	-- 测量时序（budget/inter）
	local ok, err = set_range_timing(fd, budget, inter)
	if not ok then
		return {  result = "ERR", message = err  }
	end

	-- 启动测距（连续 0x21 / 自主 0x40）+ 等首个测量就绪（全链路自检）
	local startv = (inter == 0) and 0x21 or 0x40
	if i2c_write_reg16(fd, REG_SYSTEM_START, startv) ~= 0 then
		return {  result = "ERR", message = "Failed to start VL53L4CD ranging"  }
	end
	r = wait_ready(fd, timeout)
	if r == nil then
		return {  result = "ERR", message = "Failed to poll VL53L4CD data-ready"  }
	end
	if r == false then
		return {  result = "ERR", message = string.format("VL53L4CD first measurement timeout (%dms)", timeout)  }
	end
	if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
		return {  result = "ERR", message = "Failed to clear VL53L4CD interrupt"  }
	end

	print(string.format("VL53L4CD init OK: addr=0x%02X, budget=%dms, %s",
		addr, budget, inter == 0 and "continuous" or ("autonomous, inter=" .. inter .. "ms")))
	return {  result = "OK"  }

end

-- 【销毁VL53L4CD】停止测距（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		i2c_write_reg16(fd, REG_SYSTEM_START, 0x00)
	end

	return {  result = "OK"  }

end


-- 【调用VL53L4CD】等待本次测量就绪 -> 读结果 -> 清中断
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- VL53L4CD caller func get a table --------", data)
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
	-- 等本次测量就绪
	local r = wait_ready(fd, poll_timeout or DEF_TIMEOUT)
	if r == nil then
		return {
			result = "ERR",
			message = "Failed to poll VL53L4CD data-ready"
		}
	end
	if r == false then
		return {
			result = "ERR",
			message = string.format("VL53L4CD data-ready timeout (%dms)", poll_timeout or DEF_TIMEOUT)
		}
	end

	-- 读结果块（各寄存器独立原子读）
	local status_raw = i2c_read_reg16(fd, REG_RESULT_RANGE_STATUS, 1)
	local spad = i2c_read_reg16(fd, REG_RESULT_SPAD_NB, 2)
	local signal = i2c_read_reg16(fd, REG_RESULT_SIGNAL_RATE, 2)
	local ambient = i2c_read_reg16(fd, REG_RESULT_AMBIENT_RATE, 2)
	local sigma = i2c_read_reg16(fd, REG_RESULT_SIGMA, 2)
	local dist = i2c_read_reg16(fd, REG_RESULT_DISTANCE, 2)
	if status_raw < 0 or spad < 0 or signal < 0 or ambient < 0 or sigma < 0 or dist < 0 then
		return {
			result = "ERR",
			message = "Failed to read VL53L4CD range results"
		}
	end

	-- 清中断（读完再清，结果寄存器为锁存值）
	if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
		return {
			result = "ERR",
			message = "Failed to clear VL53L4CD interrupt"
		}
	end

	-- 状态映射：原始值 &0x1F 查表；有效 SPAD 为 0 视为无效（ST 同款守卫）
	local st = status_raw % 32
	local mapped = 255
	if st < 24 then mapped = STATUS_RTN[st + 1] end
	local spad_nb = math.floor(spad / 256)
	if spad_nb == 0 then mapped = 255 end

	local ret = {
		result = "OK",
		DIST_MM = dist,
		STATUS = mapped,
		VALID = (mapped == 0) and 1 or 0,
		SPAD_NB = spad_nb,
		SIGNAL_KCPS = signal * 8,
		AMBIENT_KCPS = ambient * 8,
		SIGMA_MM = sigma / 4
	}

	if DEBUG then
		print(string.format("VL53L4CD: dist=%dmm status=%d signal=%dkcps ambient=%dkcps sigma=%.2fmm",
			ret.DIST_MM, ret.STATUS, ret.SIGNAL_KCPS, ret.AMBIENT_KCPS, ret.SIGMA_MM))
	end

	return ret

end

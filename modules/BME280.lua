-- BME280 温湿度气压传感器 驱动模块（I2C，地址 0x76/0x77）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BME280_VIRT（2026-09-15 自 modules/lib/virtbus/bme280.lua
-- 迁入，单文件驱动+模型实验第十四个，regmap 底座；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .mt 或 .sql）：
--   @BME280
--        name    I2C   address;
--   bme280-0  i2c-1     0x76;
--   @
--
-- call 无需额外参数（元数据由框架自动合并传入），返回 { result, T(°C), P(Pa), H(%RH) }
--
-- 实现要点：
--   1. 寄存器写不逐条判 i2c_write_reg 的 true/false，关键配置一律回读复核
--      （回读可同时覆盖「写失败」与「器件未应用」两种情形）
--   2. HAL 合并读 i2c_read_multi 上限 6 字节（合并值超 2^53 丢精度；纯 Lua 算术
--      恒为非负，越界显式 -1）：校准区按 4 字节块读；湿度校准块 7 字节与
--      测量数据块 8 字节走字节表版 i2c_read_multi_bytes（长块读/单事务原子读的
--      HAL 指定路径，数据区单事务读防 forced 模式测量撕裂）
--   3. 软复位后须等状态寄存器 im_update 位（bit0）清零，才可读取校准系数
--   4. 校准区 0x88~0x9F 为小端，测量数据区 0xF7~0xFE 为大端
--   5. 补偿公式为数据手册附录 8.3 的浮点版
--   6. 过采样固定 x1/x1/x1（单次测量约 6~9ms），两次 call 建议间隔 > 1s

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

local REG_ID        = 0xD0   -- 芯片ID（BME280=0x60，BMP280=0x58）
local REG_RESET     = 0xE0   -- 软复位（写0xB6）
local REG_STATUS    = 0xF3   -- bit3=measuring，bit0=im_update
local REG_CTRL_HUM  = 0xF2   -- 湿度过采样（须在 ctrl_meas 之前写入才生效）
local REG_CTRL_MEAS = 0xF4   -- 温/压过采样与模式
local REG_CONFIG    = 0xF5   -- 待机时间/滤波（I2C下spi3w只读）
local REG_TP_CAL    = 0x88   -- 温度/气压校准系数块 0x88~0x9F（小端）
local REG_H1        = 0xA1   -- H1（8位）
local REG_H_CAL     = 0xE1   -- 湿度校准系数块 0xE1~0xE7
local REG_DATA      = 0xF7   -- 测量数据块 0xF7~0xFE（大端）：P(20bit) T(20bit) H(16bit)

-- ==================== 配置 ====================
local CHIP_ID_BME280   = 0x60
local RESET_CMD        = 0xB6
local STATUS_IM_UPDATE = 0x01                 -- NVM校准数据拷贝进行中
local STATUS_MEASURING = 0x08                 -- 测量进行中
local OSRS_H_X1        = 0x01                 -- 湿度过采样 x1
local CTRL_MEAS_BASE   = bitc.bor(bitc.lshift(0x01, 5), bitc.lshift(0x01, 2))  -- 温/压过采样 x1，mode=00
local MODE_SLEEP       = 0x00
local MODE_FORCED      = 0x01                 -- 单次触发

-- 调试开关：默认关闭逐次打印
local DEBUG = false

-- ==================== 校准系数（build 时读出） ====================
local dig_T1, dig_T2, dig_T3
local dig_P1, dig_P2, dig_P3, dig_P4, dig_P5, dig_P6, dig_P7, dig_P8, dig_P9
local dig_H1, dig_H2, dig_H3, dig_H4, dig_H5, dig_H6
local cal_ok = false

-- 校准块分块读（实现收敛至 drv_common.read_block_bytes，N-24）：BME280 沿用
-- 4 字节事务粒度，见调用点传 4。原地的 read_block / to_bytes 局部量随之移除。

-- 辅助：小端16位（校准系数：b[i]=LSB，b[i+1]=MSB）与符号扩展——
-- 收敛至 bitcompat 单点维护（全仓 ≥10 驱动曾各自内联同一实现），语义逐字不变
local u16le, s16le = bitc.u16le, bitc.s16le
local s12, s8 = bitc.s12, bitc.s8

require_driver("i2c", {
	name = "BME280",

	-- 【配置脚本】初始化BME280：校验ID、软复位、读校准系数、配置过采样
	build = function(ctx, data)
	    if DEBUG then
	        dbg_table("-------- BME280 builder func get a table --------", data)
	    end

	    local fd = ctx.fd

	    -- 校验芯片ID
	    local id = i2c_read_multi(fd, REG_ID, 1)
	    if id < 0 then
	        return err("Failed to read chip id")
	    end
	    if id ~= CHIP_ID_BME280 then
	        return err(string.format("Unexpected chip id: 0x%02X (BMP280?)", id))
	    end

	    -- 软复位，等待NVM校准数据拷贝完成（im_update位清零）
	    i2c_write_reg(fd, REG_RESET, RESET_CMD)
	    milli_sleep(3)
	    local copied = false
	    for _ = 1, 50 do
	        local st = i2c_read_multi(fd, REG_STATUS, 1)
	        if st >= 0 and bitc.band(st, STATUS_IM_UPDATE) == 0 then
	            copied = true
	            break
	        end
	        milli_sleep(1)
	    end
	    if not copied then
	        return err("Calibration copy timeout")
	    end

	    -- 校准系数：0x88~0x9F共24字节（小端），按4字节块读取
	    local b = read_block_bytes(fd, REG_TP_CAL, 24, 4)
	    if b == nil then
	        return err("Failed to read calibration")
	    end
	    dig_T1 = u16le(b, 1);  dig_T2 = s16le(b, 3);  dig_T3 = s16le(b, 5)
	    dig_P1 = u16le(b, 7);  dig_P2 = s16le(b, 9);  dig_P3 = s16le(b, 11)
	    dig_P4 = s16le(b, 13); dig_P5 = s16le(b, 15); dig_P6 = s16le(b, 17)
	    dig_P7 = s16le(b, 19); dig_P8 = s16le(b, 21); dig_P9 = s16le(b, 23)

	    local h1 = i2c_read_multi(fd, REG_H1, 1)
	    if h1 < 0 then
	        return err("Failed to read calibration")
	    end
	    dig_H1 = h1

	    -- H2(0xE1,s16) H3(0xE3,u8) H4(s12: E4<<4|E5低4位) H5(s12: E6<<4|E5高4位) H6(0xE7,s8)
	    -- 共7字节：HAL 合并读上限 6，走字节表版一次事务读全块（不合并、无 2^53 精度问题）
	    local e = i2c_read_multi_bytes(fd, REG_H_CAL, 7)
	    if e == nil then
	        return err("Failed to read calibration")
	    end
	    dig_H2 = s16le(e, 1)
	    dig_H3 = e[3]
	    dig_H4 = s12(bitc.bor(bitc.lshift(e[4], 4), bitc.band(e[5], 0x0F)))
	    dig_H5 = s12(bitc.bor(bitc.lshift(e[6], 4), bitc.rshift(e[5], 4)))
	    dig_H6 = s8(e[7])

	    -- 配置：滤波关闭 -> 湿度过采样 -> 温/压过采样，保持睡眠模式
	    i2c_write_reg(fd, REG_CONFIG, 0x00)
	    i2c_write_reg(fd, REG_CTRL_HUM, OSRS_H_X1)
	    i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP))

	    -- 写后回读寄存器，确认配置生效（覆盖写失败与器件未应用两种情形）
	    local chk_hum = i2c_read_multi(fd, REG_CTRL_HUM, 1)
	    local chk_meas = i2c_read_multi(fd, REG_CTRL_MEAS, 1)
	    if chk_hum ~= OSRS_H_X1 or chk_meas ~= (bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP)) then
	        return err("Failed to configure BME280")
	    end

	    cal_ok = true
	    print(string.format("BME280 init OK: addr=0x%02X, oversampling=x1/x1/x1", ctx.addr))
	    return { result = "OK" }
	end,

	-- 【销毁脚本】进入睡眠模式（非空：写寄存器 + 清 cal_ok 标记；缺 fd/addr 安全跳过）
	destroy = function(ctx, data)
	    local fd = tonumber(data.fd)
	    local addr = tonumber(data.address)
	    if fd ~= nil and fd >= 0 and addr ~= nil and i2c_set_addr(fd, addr) then
	        i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP))
	    end
	    cal_ok = false
	    return { result = "OK" }
	end,

	-- 【调用脚本】单次触发测量并返回 T(°C) / P(Pa) / H(%RH)
	call = function(ctx, data)
	    if not cal_ok then
	        return err("BME280 not initialized, run build first")
	    end

	    local fd = ctx.fd

	    -- 单次触发测量（forced模式，完成后自动回到睡眠）
	    -- 审计 #3：触发写必须判错——NACK 时 STATUS.measuring 本就为 0，轮询会
	    -- 立即通过并把上一次的陈旧数据以 result=OK 发布
	    if not i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_FORCED)) then
	        return err("Failed to trigger forced measurement")
	    end

	    -- x1过采样单次测量约6~9ms，先等5ms再轮询measuring位，最多再等100ms
	    milli_sleep(5)
	    local ready = false
	    for _ = 1, 100 do
	        local st = i2c_read_multi(fd, REG_STATUS, 1)
	        if st >= 0 and bitc.band(st, STATUS_MEASURING) == 0 then
	            ready = true
	            break
	        end
	        milli_sleep(1)
	    end
	    if not ready then
	        return err("Measurement timeout")
	    end

	    -- 数据区 0xF7~0xFE（大端）：P(20bit) T(20bit) H(16bit)，单事务 8 字节读
	    -- （C-L1：forced 模式下新测量可在两笔事务之间完成，分块读会撕裂 P/T/H；
	    -- 字节表版无 2^53 精度限制，8 字节单事务合法）
	    local b = i2c_read_multi_bytes(fd, REG_DATA, 8)
	    if b == nil then
	        return err("Failed to read measurement")
	    end

	    local adc_P = bitc.bor(bitc.bor(bitc.lshift(b[1], 12), bitc.lshift(b[2], 4)), bitc.rshift(b[3], 4))
	    local adc_T = bitc.bor(bitc.bor(bitc.lshift(b[4], 12), bitc.lshift(b[5], 4)), bitc.rshift(b[6], 4))
	    local adc_H = bitc.bor(bitc.lshift(b[7], 8), b[8])

	    if adc_T == 0x80000 then
	        return err("Invalid temperature reading")
	    end
	    if adc_H == 0x8000 then
	        return err("Invalid humidity reading")
	    end

	    -- 温度补偿（数据手册附录8.3浮点版），t_fine 供气压/湿度复用
	    local var1 = (adc_T / 16384.0 - dig_T1 / 1024.0) * dig_T2
	    local var2 = adc_T / 131072.0 - dig_T1 / 8192.0
	    var2 = var2 * var2 * dig_T3
	    local t_fine = var1 + var2
	    local T = t_fine / 5120.0

	    -- 气压补偿（Pa）
	    var1 = t_fine / 2.0 - 64000.0
	    var2 = var1 * var1 * dig_P6 / 32768.0
	    var2 = var2 + var1 * dig_P5 * 2.0
	    var2 = var2 / 4.0 + dig_P4 * 65536.0
	    var1 = (dig_P3 * var1 * var1 / 524288.0 + dig_P2 * var1) / 524288.0
	    var1 = (1.0 + var1 / 32768.0) * dig_P1
	    if var1 == 0 then
	        return err("Pressure compensation failed")
	    end
	    local p = 1048576.0 - adc_P
	    p = (p - var2 / 4096.0) * 6250.0 / var1
	    var1 = dig_P9 * p * p / 2147483648.0
	    var2 = p * dig_P8 / 32768.0
	    p = p + (var1 + var2 + dig_P7) / 16.0

	    -- 湿度补偿（%RH，钳位0~100）
	    local h = t_fine - 76800.0
	    h = (adc_H - (dig_H4 * 64.0 + dig_H5 / 16384.0 * h))
	        * (dig_H2 / 65536.0 * (1.0 + dig_H6 / 67108864.0 * h
	            * (1.0 + dig_H3 / 67108864.0 * h)))
	    h = h * (1.0 - dig_H1 * h / 524288.0)
	    if h > 100.0 then h = 100.0 elseif h < 0.0 then h = 0.0 end

	    if DEBUG then
	        print(string.format("BME280: T=%.2f C, P=%.2f Pa, H=%.2f %%RH", T, p, h))
	    end

	    return { result = "OK", T = T, P = p, H = h }
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】BME280_VIRT —— 2026-09-15 自 modules/lib/virtbus/bme280.lua
-- 整体迁入（单文件驱动+模型第十四个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十三者：① 生产路径零执行（new() 仅虚拟总线测试调用，regmap 底座
-- 延迟到 new() 内加载；寄存器表/校准组/ADC 基线/clamp 全部移入 new() 内，
-- 与上方驱动同名局部量避让）；② 工厂经全局表而非文件 return（生产侧
-- Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件
-- 返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 在通用寄存器组模型 regmap 之上固化 BME280 的寄存器事实（Bosch
-- BST-BME280 寄存器映射）：
--   0xD0        CHIP_ID，BME280=0x60（可改 0x58 模拟错挂 BMP280）
--   0xE0        软复位（写 0xB6，模型仅留痕：校准 NVM 恒为预置内容）
--   0xF3        STATUS，合成寄存器：bit0=im_update（NVM 拷贝中，由 nvm_stuck 置）
--               bit3=measuring（转换中，由转换状态机置）
--   0x88..0x9F  T/P 校准系数 24 字节（小端，s16/u16 混排）
--   0xA1        H1（u8）；0xE1..0xE7 湿度系数 7 字节（H4/H5 为 s12 位场拼装）
--   0xF2/0xF4/0xF5  CTRL_HUM/CTRL_MEAS/CONFIG（驱动 build 回读复核，直接可写）
--   0xF7..0xFE  数据块（大端）：P(20bit) T(20bit) H(16bit)，MSB 对齐
--
-- 转换状态机（复刻 forced 模式协议行为，供超时/轮询路径测试）：
--   写 CTRL_MEAS 且 mode 位=01 → 启动一次转换：
--     · 外部时钟模式（单测）：deadline = 虚拟时钟 + busy_ms（默认 6ms），
--       测试用 milli_sleep 桩调 m:advance(ms) 推进；到点自动填数据区；
--       meas_stuck=true 时 measuring 位恒 1（驱动轮询到 Measurement timeout）。
--     · 预武装模式（守护 E2E）：virt_tick 每拍先填好数据区，触发后首次读
--       STATUS 即 measuring=0（守护线程不驱动虚拟时钟）。
--
-- 用法：
--   vbus.load_driver("modules/BME280.lua")  -- 定义全局 build/call/destroy 与 BME280_VIRT
--   local bme = BME280_VIRT.new()           -- 默认 datasheet 示例校准组
--   bme:set_raw(519888, 415148, 30000)      -- T/P/H 原始 ADC 码（无符号）
--   vbus.attach("BME280@0x76", 0x76, bme)
--
--   bme:who(0x58)        -- 模拟错挂 BMP280
--   bme.nvm_stuck = true -- NVM 拷贝位恒 1（build 校准拷贝超时路径）
--   bme.nack_read = true -- 定向故障（regmap）：配置写可过、读 NACK
--
-- 【边界约定】模型只负责 NVM 布局/位场拼装/转换状态协议；温压湿补偿公式
-- （附录 8.3）只存在于驱动与测试的独立参考实现中，模型绝不转录——virt_tick
-- 直接在原始 ADC 码空间造确定性波形（中心点取 datasheet 示例工况），避免
-- 模型与驱动共用一份换算互证导致假绿。默认校准组即 datasheet 附录 8.3 示例
-- 系数（T=25.08°C / P=100653.3Pa / H=45.3%RH 示例工况），E2E 数值可据此断言。
-- =====================================================================

BME280_VIRT = { _VERSION = "0.1.0" }

function BME280_VIRT.new(opts)
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

	-- 寄存器地址
	local REG = {
		ID        = 0xD0,
		RESET     = 0xE0,
		CTRL_HUM  = 0xF2,
		STATUS    = 0xF3,
		CTRL_MEAS = 0xF4,
		CONFIG    = 0xF5,
		TP_CAL    = 0x88,
		H1        = 0xA1,
		H_CAL     = 0xE1,
		DATA      = 0xF7,
	}

	-- datasheet 附录 8.3 示例校准系数组（BME280 datasheet rev1.6，Table 43 工况：
	-- 补偿输出 T=25.08°C / P=100653.3Pa / H=45.3%RH）。注意 dig_H1 是 u8，
	-- 示例字节 0xA1=0x4B（75）——超 255 的值无法在字节寄存器中表达。
	local CAL_DEFAULT = {
		T1 = 27504, T2 = 26435, T3 = -1000,
		P1 = 36477, P2 = -10685, P3 = 3024, P4 = 2855, P5 = 140,
		P6 = -7, P7 = 15500, P8 = -14600, P9 = 6000,
		H1 = 75, H2 = 382, H3 = 0, H4 = 350, H5 = 0, H6 = 30,
	}

	-- 示例工况对应的 ADC 码（附录 8.3 同步给出：adc_T=519888 adc_P=415148）
	local ADC_DEFAULT_T, ADC_DEFAULT_P, ADC_DEFAULT_H = 519888, 415148, 30000

	local function clamp(v, lo, hi)
		v = math.floor(v)
		if v < lo then v = lo elseif v > hi then v = hi end
		return v
	end

	opts = opts or {}

	local m = regmap.new({ [REG.ID] = opts.who or 0x60 })

	-- ---------------- 器件状态 ----------------
	m.nvm_stuck = false		-- STATUS bit0 恒 1（NVM 拷贝卡死）
	m.meas_stuck = false		-- 触发后 STATUS bit3 恒 1（测量卡死）
	m.clock_ms = 0			-- 外部虚拟时钟（m:advance 推进）
	m.busy_ms = tonumber(opts.busy_ms) or 6
	m.conv = "idle"			-- "idle" | "busy"（虚拟时钟转换中）| "ready" | "stuck"
	m.prearmed = false		-- 数据已预武装（virt_tick 模式：触发即就绪）
	local adc_t, adc_p, adc_h = ADC_DEFAULT_T, ADC_DEFAULT_P, ADC_DEFAULT_H

	-- ---------------- NVM 校准区编码（协议层事实） ----------------

	-- 小端 16 位：负数自动取补码
	local function put16le(reg, v)
		v = v % 65536
		m:set(reg, v % 256)
		m:set(reg + 1, math.floor(v / 256) % 256)
	end

	function m:set_cal(c)
		c = c or CAL_DEFAULT
		put16le(0x88, c.T1); put16le(0x8A, c.T2); put16le(0x8C, c.T3)
		put16le(0x8E, c.P1); put16le(0x90, c.P2); put16le(0x92, c.P3)
		put16le(0x94, c.P4); put16le(0x96, c.P5); put16le(0x98, c.P6)
		put16le(0x9A, c.P7); put16le(0x9C, c.P8); put16le(0x9E, c.P9)
		self:set(REG.H1, c.H1 % 256)
		put16le(0xE1, c.H2)
		self:set(0xE3, c.H3 % 256)
		-- H4=s12 / H5=s12 共用 0xE5 高低 nibble：
		--   驱动 H4 = s12(E4<<4 | E5&0x0F)，H5 = s12(E6<<4 | E5>>4)
		local u4, u5 = c.H4 % 4096, c.H5 % 4096
		self:set(0xE4, math.floor(u4 / 16) % 256)
		self:set(0xE6, math.floor(u5 / 16) % 256)
		self:set(0xE5, (u5 % 16) * 16 + (u4 % 16))
		self:set(0xE7, c.H6 % 256)
		return self
	end

	-- ---------------- 测量数据区编码（0xF7..0xFE，大端，20/20/16bit） ----------------

	function m:fill_data()
		local p, t, h = adc_p, adc_t, adc_h
		self:set(0xF7, math.floor(p / 4096) % 256)
		self:set(0xF8, math.floor(p / 16) % 256)
		self:set(0xF9, (p % 16) * 16)
		self:set(0xFA, math.floor(t / 4096) % 256)
		self:set(0xFB, math.floor(t / 16) % 256)
		self:set(0xFC, (t % 16) * 16)
		self:set(0xFD, math.floor(h / 256) % 256)
		self:set(0xFE, h % 256)
		return self
	end

	-- 设置待转换的原始 ADC 码：T/P 为 20bit(0..0xFFFFF)、H 为 16bit(0..0xFFFF)
	-- （0x80000/0x8000 是驱动认定的无效读数，可显式注入测负路径）；nil 保持原值
	function m:set_raw(t, p, h)
		if t ~= nil then adc_t = clamp(t, 0, 0xFFFFF) end
		if p ~= nil then adc_p = clamp(p, 0, 0xFFFFF) end
		if h ~= nil then adc_h = clamp(h, 0, 0xFFFF) end
		return self
	end

	-- ---------------- 转换状态机 ----------------

	local function start_conv()
		if m.meas_stuck then
			m.conv = "stuck"
		elseif m.prearmed then
			m:fill_data()		-- 守护模式：数据已在 virt_tick 备好，触发即就绪
			m.conv = "ready"
		else
			m.conv = "busy"
			m.deadline_ms = m.clock_ms + m.busy_ms
		end
	end

	-- 单测虚拟时钟：驱动 milli_sleep 桩转调；转换到点自动填数据区
	function m:advance(ms)
		self.clock_ms = self.clock_ms + math.max(0, math.floor(tonumber(ms) or 0))
		if self.conv == "busy" and self.clock_ms >= self.deadline_ms then
			self:fill_data()
			self.conv = "ready"
		end
		return self
	end

	-- 合成 STATUS 字节（读 0xF3 时返回）：惰性完成到点的转换
	local function status_byte()
		if m.conv == "busy" and m.clock_ms >= m.deadline_ms then
			m:fill_data()
			m.conv = "ready"
		end
		local st = 0
		if m.nvm_stuck then st = st + 0x01 end
		if m.conv == "busy" or m.conv == "stuck" then st = st + 0x08 end
		return st
	end

	-- ---------------- 包装 regmap 事务（拦截复位/触发/STATUS） ----------------

	local reg_write, reg_read = m.write, m.read

	function m.write(bytes)
		local ok = reg_write(bytes)
		if ok == false then return false end
		if type(bytes) == "table" and #bytes >= 2 then
			if bytes[1] == REG.CTRL_MEAS and (bytes[2] % 4) == 1 then
				start_conv()	-- forced 模式（mode 位=01）触发单次转换
			end
			-- 0xE0 复位写仅留痕：NVM 恒为预置校准，im_update 由 nvm_stuck 决定
		end
		return true
	end

	function m.read(n)
		n = math.floor(tonumber(n) or 1)
		-- 驱动仅以 n=1 读 STATUS；burst 块均不跨越 0xF3
		if n == 1 and m.ptr == REG.STATUS then
			m.ptr = (m.ptr + 1) % 256
			return { status_byte() }
		end
		return reg_read(n)
	end

	-- ---------------- 留痕/身份/复位 ----------------

	function m:who(val)
		self:set(REG.ID, val)
		return self
	end

	-- build 写过的寄存器序列：从 write_log 取「>=2 字节」事务的 {reg,val}
	function m:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then out[#out + 1] = { reg = e[1], val = e[2] } end
		end
		return out
	end

	local reg_reset = m.reset
	function m:reset(new_init)
		reg_reset(self, new_init)
		self.nvm_stuck = false
		self.meas_stuck = false
		self.clock_ms = 0
		self.deadline_ms = nil
		self.conv = "idle"
		self.prearmed = false
		adc_t, adc_p, adc_h = ADC_DEFAULT_T, ADC_DEFAULT_P, ADC_DEFAULT_H
		self:who(opts.who or 0x60)
		self:set_cal(CAL_DEFAULT)
		self:fill_data()
		return self
	end

	-- ---------------- 守护仿真节拍（proto=virt 每拍调用） ----------------

	-- 确定性波形（无随机），直接在 ADC 码空间围绕 datasheet 示例工况正弦：
	--   T ±2500 码 ≈ ±0.79°C；P ±15000 码 ≈ ±2.6kPa；H ±3000 码 ≈ ±17%RH
	-- （灵敏度为附录 8.3 公式在该工况点的一阶量级，仅用于估幅；模型不含补偿）。
	-- 三通道互差 120°；预武装数据区，使守护触发后首轮询即就绪。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local th = n * 0.25
		local k = 2 * math.pi / 3
		self:set_raw(
			math.floor(ADC_DEFAULT_T + 2500 * math.sin(th)),
			math.floor(ADC_DEFAULT_P + 15000 * math.sin(th + k)),
			math.floor(ADC_DEFAULT_H + 3000 * math.sin(th + 2 * k)))
		self.prearmed = true
		self:fill_data()
		return self
	end

	m:set_cal(CAL_DEFAULT)
	m:fill_data()
	return m
end

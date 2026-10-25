-- bme280.lua —— BME280 温/压/湿环境传感器虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 在通用寄存器组模型 regmap 之上固化 BME280 的寄存器事实（与
-- modules/BME280.lua 驱动同源，Bosch BST-BME280 寄存器映射）：
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
--   local bmemod = dofile("modules/lib/virtbus/bme280.lua")
--   local bme = bmemod.new()                    -- 默认 datasheet 示例校准组
--   bme:set_raw(519888, 415148, 30000)          -- T/P/H 原始 ADC 码（无符号）
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

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

local bme280 = {}
bme280._VERSION = "0.1.0"

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

function bme280.new(opts)
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

return bme280

-- PCA9685 PWM控制板
-- 虚拟器件模型：内嵌本文件尾部 PCA9685_VIRT（2026-09-15 自 modules/lib/virtbus/pca9685.lua
-- 迁入，单文件驱动+模型实验；写-only 无测量值，守护 E2E 豁免）




-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 关键寄存器与模式位（PCA9685 数据手册 §7.3 寄存器映射）
local REG_MODE1    = 0x00	-- 模式寄存器1
local MODE1_RESTART= 0x80	-- 重启位：置 1 触发已排队的计数重启
local MODE1_SLEEP  = 0x10	-- 睡眠位：置 1 关闭振荡器，改 PRE_SCALE 前必须进入
local MODE1_AI     = 0x20	-- 地址自增位：置 1 使寄存器写自动递增
local REG_PRESCALE = 0xFE	-- 预分频寄存器（实际频率 = 25MHz / (4096 * (prescale+1))）
local LED0_ON_L    = 0x06	-- 通道 0 ON 计数低字节（后续通道每 4 字节步进）

-- 时基与脉宽换算常量（见 call/build）
local OSC_CLK_HZ     = 25000000	-- 板载 25MHz 振荡器
local PWM_RESOLUTION = 4096	-- 12 位分辨率（0~4095 计数）
local PERIOD_MS      = 20	-- 50Hz 周期（20ms）
local PULSE_0DEG_MS  = 0.5	-- 0 度对应脉宽
local PULSE_180DEG_MS= 2.5	-- 180 度对应脉宽




require_driver("i2c", {
	name = "PCA9685",

	-- 【配置脚本】
	build = function(ctx, data)
		dbg_table("-------- Lua builder func get a table --------", data)

		local fd = ctx.fd

		local freq = 50.0							-- 设置PWM频率
		local prescale_val = OSC_CLK_HZ / (PWM_RESOLUTION * freq) - 1.0
		local prescale = prescale_val + 0.5

		if not i2c_write_reg(fd, REG_MODE1, MODE1_RESTART) then
			return err("PCA9685 not responding (MODE1 write failed, check address and wiring)")
		end

		milli_sleep(5)			-- 等待振荡器启动

		if not i2c_write_reg(fd, REG_MODE1, MODE1_SLEEP) then
			return err("PCA9685 write failed: MODE1 (SLEEP)")
		end
		if not i2c_write_reg(fd, REG_PRESCALE, math.floor(prescale)) then
			return err("PCA9685 write failed: PRE_SCALE")
		end
		if not i2c_write_reg(fd, REG_MODE1, bitc.bor(MODE1_AI, MODE1_RESTART)) then
			return err("PCA9685 write failed: MODE1 (AI|RESTART)")
		end

		milli_sleep(5)			-- 等待振荡器启动

		return {  result = "OK"  }
	end,

	-- 【销毁PCA9685】尽力触发重启，失败不报错（M3 语义）
	destroy = function(ctx, data)
		dbg_table("-------- Lua ender func get a table --------", data)

		local fd, addr = tonumber(data.fd), tonumber(data.address)
		if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
			i2c_write_reg(fd, REG_MODE1, MODE1_RESTART)
		end

		return {  result = "OK"  }
	end,

	-- 【调用PCA9685】将一个舵机通道转动到一个角度
	call = function(ctx, data)
		dbg_table("-------- Lua caller func get a table --------", data)

		local fd = ctx.fd

		local channel = data.channel
		if channel == nil then
			return err("Invalid Argument: channel")
		end
		-- 26.3：finite_of 而非 tonumber——与下面 angle 列（同函数，早已 finite_of）
		-- 口径一致。非有限值过 tonumber 出的是 number（`== nil` 为假），而紧接的
		-- `channel < 0 or channel > 15` 对 NaN 恒假也一并放行（inf 由上界命中，
		-- 只有 NaN 逃得过），于是 reg = LED0_ON_L + 4*NaN 是 NaN 却仍返回
		-- result="OK"——越界通道「一个寄存器都不写」的既有契约在驱动层被破。
		-- 真机上后果被 hal/i2c.lua 的 byte_of 兜住（i2c_write_multi 返 -1），
		-- 故这是驱动契约/错误归属修复而非安全修复。
		channel = finite_of(channel)
		if channel == nil then
			return err("Invalid Argument: channel (not a number)")
		end
		channel = math.floor(channel)

		if channel < 0 or channel > 15 then
			return err("Invalid Argument: channel (out of range 0-15)")
		end

		local angle = finite_of(data.angle)
		if angle == nil then
			return err("Invalid Argument: angle (missing or not a finite number)")
		end
		if angle < 0 then angle = 0 end
		if angle > 180 then angle = 180 end

		if os.getenv("BOT4CJ_DEBUG") == "1" then
			print(string.format("Lua hardware drive set angle: %.2f", angle))
		end

		local min = PULSE_0DEG_MS
		local max = PULSE_180DEG_MS
		local width = min + (max - min) * (angle / 180.0)
		local offval = math.floor(width * PWM_RESOLUTION / PERIOD_MS)
		if offval < 0 then offval = 0 elseif offval > PWM_RESOLUTION - 1 then offval = PWM_RESOLUTION - 1 end
		local reg = LED0_ON_L + 4 * channel

		local off_lo = bitc.band(offval, 0xFF)
		local off_hi = bitc.band(bitc.rshift(offval, 8), 0xFF)
		if i2c_write_multi(fd, reg, 0x00, 0x00, off_lo, off_hi) ~= 0 then
			return err("PCA9685 write failed: PWM registers (channel " .. tostring(channel) .. ")")
		end

	 	return { result = "OK" }
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】PCA9685_VIRT —— 2026-09-15 自 modules/lib/virtbus/pca9685.lua
-- 整体迁入（单文件驱动+模型可行性实验）。三条约定：
--   * 生产路径零执行：new() 仅虚拟总线测试调用；regmap 底座延迟到 new() 内
--     加载，真机 build/call/destroy 不触碰 lib/virtbus/；
--   * 工厂经全局表暴露而非文件 return——生产侧 Lua.cj build_lua 以 LUA_MULTRET
--     pcall 加载驱动文件，成功路径无 settop，文件返回值会永久滞留 Lua 栈；
--   * 模型与驱动保持独立实现：模型自带寄存器表/位定义/换算常量（不引用上方
--     驱动局部量），测试侧另有独立 off_ref 公式交叉，避免同源错误互证假绿。
--
-- 在通用字节指针 regmap 底座上固化 PCA9685 的寄存器事实（NXP 数据手册 §7.3
-- 寄存器映射互证）。属「8 位寄存器指针 + burst」事务形态（regmap 包装族），
-- 但作为【纯输出器件】有四处个性必须照实：
--   ① MODE1(0x00) RESTART(bit7) 是特殊位：写 1 永不落盘——器件进入 SLEEP
--      （bit4 0→1、振荡器停）后硬件自动挂起重启请求，MODE1 读回 bit7=1；
--      之后写 bit7=1 才真正执行 RESTART（重启已排队的 PWM）并自清，
--           无挂起请求时写 1 整位忽略（ACK 但无效）。模型无 500µs 延时，
--      进 SLEEP 即刻挂起（驱动不读 MODE1，模型值非 datasheet 保证延时）。
--   ② EXTCLK(bit6) 粘滞：一旦置 1，普通写 0 清不掉，只有成功的 RESTART
--      （或上电复位）能切回内部时钟——重启写同时清 EXTCLK。
--   ③ PRE_SCALE(0xFE) 只能在 SLEEP=1 时写入（醒着写 ACK 但丢弃，另有
--      prescale_drop 计数），且 datasheet 最小值 0x03（更小值按 3 落盘）。
--   ④ burst 自增【完全由 MODE1 AI(bit5) 决定】（无 LPS22HB 那种地址 bit7）：
--      AI=0 时多字节写/连读全部落在同一寄存器；AI=1 才逐字节推进，0xFF
--      后算术回绕 0x00。驱动 build 倒数第二笔才开 AI，call 的 5B 原子帧
--      依赖它——这是配置顺序正确性的协议闸门。
--
-- LED 通道块（12 位小端字对 + FULL 位）：
--   0x06~0x09 LED0  ON_L/ON_H/OFF_L/OFF_H，每通道 4 字节，至 0x42~0x45 LED15；
--   0xFA~0xFD ALL_LED 同构。低字节在低地址；高字节 bit4 = LED_FULL（常通/
--   常断，第 13 位），[3:0] 是计数高半字节 → 计数 = lo + (hi%16)*256。
--   驱动 call 发单帧 {reg=0x06+4*ch, ON_L=0, ON_H=0, OFF_L, OFF_H}（ON 恒 0，
--   脉宽自周期起点起算），offval = floor(width_ms*4096/20)，范围 102~512。
--
-- POR（§7.3 默认值表，子地址是 7 位地址左移 1 的存放形式）：
--   MODE1=0x01(ALLCALL)、MODE2=0x04(OUTDRV)、SUBADR1=0xE2(0x71<<1)、
--   SUBADR2=0xE4、SUBADR3=0xE8、ALLCALLADR=0xE0(0x70<<1)、PRE_SCALE=0x1E(30，
--   约 196.9Hz)，LED/ALL_LED 计数块全 0。
--
-- 【边界约定】纯输出器件：无测量数据、无 virt_tick、无 advance，守护采样 E2E
-- （阶段 C）豁免。模型只存字节与模式位，角度→脉宽→OFF 码换算归驱动，避免
-- 模型与驱动共用一份理解互证假绿。地址由挂载点决定（0x40 缺省，引脚可配
-- 0x40~0x7F），ALLCALL/SUBADR 的多地址响应不建模（驱动不用）。
-- =====================================================================

PCA9685_VIRT = {
	_VERSION      = "0.1.0",
	I2C_ADDR      = 0x40,	-- 缺省（全部地址引脚接地）
	I2C_ADDR_MAX  = 0x7F,	-- 引脚全高
	ALLCALL_ADDR  = 0x70,
	REG = {
		MODE1      = 0x00,
		MODE2      = 0x01,
		SUBADR1    = 0x02,
		SUBADR2    = 0x03,
		SUBADR3    = 0x04,
		ALLCALLADR = 0x05,
		LED0       = 0x06,
		ALL_LED    = 0xFA,
		PRESCALE   = 0xFE,
	},
}

function PCA9685_VIRT.new(opts)
	local REG = PCA9685_VIRT.REG
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

	local BIT_RESTART = 0x80
	local BIT_EXTCLK  = 0x40
	local BIT_AI      = 0x20
	local BIT_SLEEP   = 0x10
	local BIT_ALLCALL = 0x01
	local MIN_PRESCALE = 3

	local OSC_CLK_HZ     = 25000000
	local PWM_RESOLUTION = 4096

	-- POR 种子（§7.3 默认值表）
	local POR_SEED = {
		[REG.MODE1]      = 0x01,	-- ALLCALL
		[REG.MODE2]      = 0x04,	-- OUTDRV
		[REG.SUBADR1]    = 0xE2,	-- 0x71 << 1
		[REG.SUBADR2]    = 0xE4,	-- 0x72 << 1
		[REG.SUBADR3]    = 0xE8,	-- 0x73 << 1
		[REG.ALLCALLADR] = 0xE0,	-- 0x70 << 1
		[REG.PRESCALE]   = 0x1E,	-- 30
	}

	local function led_base(ch)
		if type(ch) ~= "number" then return nil end
		ch = math.floor(ch)
		if ch < 0 or ch > 15 then return nil end
		return REG.LED0 + 4 * ch
	end

	opts = opts or {}

	local m = regmap.new(POR_SEED)
	local write_pred, read_pred

	-- 重启请求挂起标志：SLEEP 0→1 置 true，成功 RESTART 清 false
	local restart_pending = false
	local restart_count = 0
	local prescale_drop = 0		-- 醒着写 PRE_SCALE 被丢弃的次数

	local function reseed_body()
		for k in pairs(m.regs) do m.regs[k] = nil end
		for a, v in pairs(POR_SEED) do m.regs[a] = v end
		m.ptr = 0
		restart_pending = false
		-- 故障钩子与计数重置在 reset() 外层处理
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		m.write_log[#m.write_log + 1] = cp
	end

	local function ai_on()
		return math.floor((m.regs[REG.MODE1] or 0) / 32) % 2 == 1
	end
	local function sleeping()
		return math.floor((m.regs[REG.MODE1] or 0) / 16) % 2 == 1
	end

	-- MODE1 写解码：RESTART/EXTCLK/SLEEP 挂起三特殊语义，其余位照存
	local function write_mode1(val)
		val = math.floor(val) % 256
		local req_restart = math.floor(val / 128) % 2 == 1
		local slept_before = sleeping()

		-- 落盘候选先去掉 RESTART 位（bit7 永不落盘）
		local stored = val % 128
		local extclk_cleared = false

		if req_restart then
			if restart_pending then
				-- 有挂起请求：执行重启，自清并同时清 EXTCLK（软件复位路径）
				restart_count = restart_count + 1
				restart_pending = false
				stored = stored - (math.floor(stored / 64) % 2) * 64
				extclk_cleared = true
			end
			-- 无挂起请求：RESTART 位整位忽略，其余位正常落盘
		end

		-- EXTCLK 粘滞：已置 1 且本次非重启清零，普通写保位
		local extclk_now = math.floor((m.regs[REG.MODE1] or 0) / 64) % 2
		if extclk_now == 1 and not extclk_cleared
			and math.floor(stored / 64) % 2 == 0 then
			stored = stored + BIT_EXTCLK
		end

		m.regs[REG.MODE1] = stored % 256

		-- SLEEP 0→1：振荡器停，硬件挂起重启请求（MODE1 读回 bit7=1）
		if not slept_before and sleeping() then
			restart_pending = true
		end
	end

	-- PRE_SCALE 写：仅 SLEEP=1 接受，最小值钳 3
	local function write_prescale(val)
		val = math.floor(val) % 256
		if sleeping() then
			if val < MIN_PRESCALE then val = MIN_PRESCALE end
			m.regs[REG.PRESCALE] = val
		else
			prescale_drop = prescale_drop + 1
		end
	end

	-- ---------------- virtbus 点定义回调（总线无 self 调用，绝不能用冒号） ----------------

	m.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if m.nack or m.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes == 1 then
			m.ptr = bytes[1] % 256	-- 纯指针写，任意地址 ACK
			return true
		end
		local base = bytes[1] % 256
		local inc = ai_on()
		for i = 2, #bytes do
			local a = inc and (base + i - 2) % 256 or base
			local v = bytes[i] % 256
			if a == REG.MODE1 then
				write_mode1(v)
			elseif a == REG.PRESCALE then
				write_prescale(v)
			else
				m.regs[a] = v
			end
		end
		return true
	end

	local function read_byte(addr)
		if addr == REG.MODE1 then
			-- bit7 读时按重启挂起态动态合成，其余位读影子
			return ((m.regs[REG.MODE1] or 0) % 128)
			     + (restart_pending and BIT_RESTART or 0)
		end
		return m.regs[addr] or 0
	end

	m.read = function(n)
		if m.nack or m.nack_read then return nil end
		local nn = math.floor(tonumber(n) or 1)
		if read_pred and read_pred(m.ptr, nn) then return nil end
		if nn < 1 then nn = 1 end
		local inc = ai_on()
		local t = {}
		for _ = 1, nn do
			t[#t + 1] = read_byte(m.ptr)
			if inc then m.ptr = (m.ptr + 1) % 256 end
		end
		return t
	end

	-- ---------------- 配置/状态观察口 ----------------

	function m:mode1()       return read_byte(REG.MODE1) end
	function m:mode2()       return m.regs[REG.MODE2] or 0 end
	function m:sleep()       return sleeping() end
	function m:ai()          return ai_on() end
	function m:extclk()      return math.floor((m.regs[REG.MODE1] or 0) / 64) % 2 end
	function m:allcall()     return (m.regs[REG.MODE1] or 0) % 2 end
	function m:restart_pending() return restart_pending end
	function m:restart_count()   return restart_count end
	function m:prescale_drop()   return prescale_drop end

	function m:prescale()    return m.regs[REG.PRESCALE] or 0 end
	function m:freq_hz()
		return OSC_CLK_HZ / (PWM_RESOLUTION * ((self:prescale()) + 1))
	end
	function m:subadr(i)
		local r = ({ [1]=REG.SUBADR1, [2]=REG.SUBADR2,
		             [3]=REG.SUBADR3 })[tonumber(i)]
		return r and (m.regs[r] or 0) or nil
	end
	function m:allcall_adr() return m.regs[REG.ALLCALLADR] or 0 end
	function m:pointer()     return self.ptr end

	-- ---------------- LED 通道块小端字对编解码（含 FULL 位） ----------------

	local function decode_word(lo, hi)
		lo, hi = lo or 0, hi or 0
		return (lo + (hi % 16) * 256), math.floor(hi / 16) % 2
	end
	local function encode_word(count, full)
		count = math.floor(tonumber(count) or 0)
		if count < 0 then count = 0 end
		if count > 4095 then count = 4095 end
		local hi = count >= 256 and math.floor(count / 256) % 16 or 0
		if full then hi = hi + 16 end
		return count % 256, hi
	end

	-- 返 on, on_full, off, off_full；ch 越界返 nil
	function m:get_led(ch)
		local b = led_base(ch)
		if not b then return nil end
		local on, onf = decode_word(self.regs[b], self.regs[b + 1])
		local off, offf = decode_word(self.regs[b + 2], self.regs[b + 3])
		return on, onf, off, offf
	end

	function m:get_all_led()
		local b = REG.ALL_LED
		local on, onf = decode_word(self.regs[b], self.regs[b + 1])
		local off, offf = decode_word(self.regs[b + 2], self.regs[b + 3])
		return on, onf, off, offf
	end

	-- 注入通道码（测试构造用）；on_full/off_full 可省略
	function m:set_led(ch, on, off, on_full, off_full)
		local b = led_base(ch)
		if not b then return self end
		local onl, onh = encode_word(on, on_full)
		local fl, fh = encode_word(off, off_full)
		self.regs[b], self.regs[b + 1] = onl, onh
		self.regs[b + 2], self.regs[b + 3] = fl, fh
		return self
	end

	function m:set_all_led(on, off, on_full, off_full)
		local b = REG.ALL_LED
		local onl, onh = encode_word(on, on_full)
		local fl, fh = encode_word(off, off_full)
		self.regs[b], self.regs[b + 1] = onl, onh
		self.regs[b + 2], self.regs[b + 3] = fl, fh
		return self
	end

	-- ---------------- 配置写留痕 / 故障钩子 / 复位 ----------------

	function m:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then out[#out + 1] = { reg = e[1], val = e[2] } end
		end
		return out
	end

	function m:write_count()
		local n = 0
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then n = n + 1 end
		end
		return n
	end

	function m:fail_write(pred) write_pred = pred; return self end
	function m:fail_read(pred)  read_pred  = pred; return self end

	function m:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function m:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回 POR 态；保留故障钩子（族约定），清重启挂起/计数/丢弃计数/留痕
	function m:reset()
		reseed_body()
		self.write_log = {}
		restart_count = 0
		prescale_drop = 0
		return self
	end

	return m
end
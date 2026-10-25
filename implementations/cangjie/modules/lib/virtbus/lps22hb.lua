-- lps22hb.lua —— ST LPS22HB 高精度气压/温度传感器虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 在通用字节指针 regmap 底座上固化 LPS22HB 的寄存器事实（与 modules/LPS22HB.lua
-- 驱动同源，ST 寄存器映射 / Adafruit_LPS2X 与内核 st_pressure 互证）。属「8 位
-- 寄存器指针 + 连续 burst」事务形态（regmap 包装族），但有五处个性必须照实：
--   ① 数据区【小端 5B 连读】：0x28 起 XL,L,H（24 位气压）+ TL,TH（16 位温度），
--      LSB 在低地址（底座 set_word 是大端，本模型另给小端注入）；
--   ② 多字节访问的自动增量【由地址 bit7 控制】：驱动 burst 发 0x28|0x80=0xA8
--      当指针——bit7=1 地址连续自增；bit7=0 且 CTRL_REG2 IF_ADD_INC(bit3)=0 时
--      连读重复同一寄存器（POR 默认），IF_ADD_INC=1 全局放行；
--   ③ CTRL_REG2 有【三个自清零命令位】：bit7 BOOT（即时自清）、bit2 SWRESET
--      （复位过程中读回 1、结束回 0，驱动 build 以 1ms×20 轮询）、bit0 ONE_SHOT
--      （置位启动单次转换、转换中读 1、约 3ms 后自清并刷新 0x28~0x2C）；
--   ④ STATUS(0x27) 数据就绪位【读时动态合成】：转换完成置 P_DA/T_DA，读
--      PRESS_OUT_H(0x2A) 清 P_DA、读 TEMP_OUT_H(0x2C) 清 T_DA；
--   ⑤ CTRL_REG1 [6:4] ODR 非 0 进入连续模式（1/10/25/50/75Hz），advance 按
--      周期出样；ODR=000 是 power-down/单次模式（驱动只用此档），ODR 110/111
--      保留，odr_hz 观察口返 nil 不臆断。
--
-- 寄存器（驱动触碰区）：
--   0x0F WHO_AM_I    只读，上电 0xB1（0xBD=LPS25HB；用例可 who() 改模拟错挂）
--   0x10 CTRL_REG1   [6:4]ODR [3]EN_LPFP [2]LPFP_CFG [1]BDU [0]SIM，POR 0x00，
--                    build 写 0x02（BDU=1 防输出撕裂、ODR=000 单次/power-down）
--   0x11 CTRL_REG2   见 ③（落盘位仅 bit4 FIFO_EN / bit3 IF_ADD_INC）
--   0x27 STATUS      只读动态合成，bit1 T_DA / bit0 P_DA
--   0x28~0x2C 输出   只读小端补码；写 ACK 但丢弃（测量值只由注入/转换事件改变）
-- 单字节写 {reg}=读指针：任意地址（含只读/保留区）都 ACK 并移动指针，这是
-- I2C_RDWR 读操作的指针消息；>=2 字节写落只读区的数据字节才丢弃。
--
-- 用法：
--   local lmod = dofile("modules/lib/virtbus/lps22hb.lua")
--   local dev = lmod.new()                    -- WHO_AM_I 默认 0xB1
--   dev:set_press_raw(4149248)                -- 1013.0hPa 有符号 24 位码（小端存放）
--   dev:set_temp_raw(2345)                    -- 23.45°C 有符号 16 位码
--   vbus.attach("LPS22HB@0x5D", 0x5D, dev)
--
--   dev:advance(3)     -- 推虚拟时钟：单次转换 3ms 门 / SWRESET 2ms 门
--   dev:virt_tick(0)   -- 预武装：下条 SWRESET/ONE_SHOT 即时完成（守护零睡眠）
--   dev.nack_read = true
--
-- 【边界约定】SWRESET/ONE_SHOT 门限是模型值（2ms/3ms，驱动分别以 20ms/
-- cfg.wait(默认 50) 为上限 1ms 轮询，余量充裕，非 datasheet 保证值）；模型只
-- 存字节与状态机，P/4096、T/100 换算归驱动，避免模型与驱动共用一份理解互证
-- 假绿。滤波位（EN_LPFP/LPFP_CFG）照存照读，不模拟滤波对码值的影响。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

local lps22hb = {}
lps22hb._VERSION = "0.1.0"

lps22hb.I2C_ADDR     = 0x5D	-- 缺省（SA0 接高）
lps22hb.I2C_ADDR_ALT = 0x5C	-- 备选（SA0 接地）

-- 寄存器地址
lps22hb.REG = {
	WHOAMI   = 0x0F,
	CTRL1    = 0x10,
	CTRL2    = 0x11,
	STATUS   = 0x27,
	PRESS_XL = 0x28,
	PRESS_L  = 0x29,
	PRESS_H  = 0x2A,
	TEMP_L   = 0x2B,
	TEMP_H   = 0x2C,
}

lps22hb.DEVID      = 0xB1
lps22hb.LPS25HB_ID = 0xBD	-- 代际拦截参照，不做模型种子
lps22hb.LSB_PER_HPA = 4096.0
lps22hb.LSB_PER_C   = 100.0

-- CTRL_REG2 位
local BIT_BOOT     = 0x80
local BIT_FIFO_EN  = 0x10
local BIT_IF_INC   = 0x08
local BIT_SWRESET  = 0x04
local BIT_ONESHOT  = 0x01
local CTRL2_STORED = 0x18	-- 真正落盘的位：FIFO_EN / IF_ADD_INC

-- 模型门限（ms，非 datasheet 保证值；驱动轮询上限 20/50ms 余量充裕）
local RESET_MS = 2
local CONV_MS  = 3

-- CTRL_REG1 [6:4] ODR 码 → 周期 ms；码 0=power-down/单次，6/7 保留
local ODR_PERIOD_MS = { [1] = 1000, [2] = 100, [3] = 40, [4] = 20, [5] = 40 / 3 }

-- 只读地址（>=2 字节多字节写落此区的数据字节 ACK 但丢弃）
local READONLY = {
	[0x0F] = true,							-- WHO_AM_I
	[0x27] = true,							-- STATUS
	[0x28] = true, [0x29] = true, [0x2A] = true,
	[0x2B] = true, [0x2C] = true,			-- P/T 输出 5 字节
}

local function clamp_s24(v)
	v = math.floor(v + 0.5)
	if v > 8388607 then v = 8388607 end
	if v < -8388608 then v = -8388608 end
	return v
end

local function clamp_s16(v)
	v = math.floor(v + 0.5)
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function lps22hb.new(opts)
	opts = opts or {}
	local dev_id = opts.who or lps22hb.DEVID

	local m = regmap.new({
		[lps22hb.REG.WHOAMI] = dev_id,
	})
	local write_pred, read_pred

	-- 状态机
	local mode = "idle"		-- "idle"(ODR=000 power-down/单次) / "cont"
	local odr_code = 0
	local cont_period = nil	-- ms
	local cont_acc = 0		-- 连续模式累计时间
	local reset_busy = false
	local reset_left = nil
	local conv_busy = false
	local conv_left = nil
	local p_da = false
	local t_da = false
	local armed = false		-- virt_tick 预武装（命令位即时完成）
	local never_ready = false
	local pending = nil		-- 下次转换装载的 {p=,t=}（模型不自造测量值）
	local inc_bit = false	-- 最近指针写的地址 bit7
	local boot_count = 0

	local function reseed_body()
		for k in pairs(m.regs) do m.regs[k] = nil end
		m.regs[lps22hb.REG.WHOAMI] = dev_id
		m.ptr = 0
		inc_bit = false
		mode, odr_code, cont_period, cont_acc = "idle", 0, nil, 0
		reset_busy, reset_left = false, nil
		conv_busy, conv_left = false, nil
		p_da, t_da = false, false
		-- pending 注入是测试侧资产：SWRESET 不清（同 who/故障钩子族约定）
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		m.write_log[#m.write_log + 1] = cp
	end

	local function if_inc_global()
		return math.floor((m.regs[lps22hb.REG.CTRL2] or 0) / 8) % 2 == 1
	end

	local function load_sample()
		if pending then
			local p = pending.p % 0x1000000
			m.regs[0x28] = p % 256
			m.regs[0x29] = math.floor(p / 256) % 256
			m.regs[0x2A] = math.floor(p / 65536) % 256
			local t = pending.t % 0x10000
			m.regs[0x2B] = t % 256
			m.regs[0x2C] = math.floor(t / 256) % 256
		end
		p_da, t_da = true, true
	end

	local function finish_conv()
		conv_busy, conv_left = false, nil
		load_sample()
	end

	local function finish_reset()
		reseed_body()
	end

	-- CTRL_REG2 写解码（驱动恒 {0x11,val} 2B 写；多字节写流的每个数据字节
	-- 落到各自地址，这里按「写 0x11 的数据字节」处理）
	local function write_ctrl2(val)
		val = math.floor(val) % 256
		-- BOOT：硬件即时自清、重新装载出厂修调（模型无 NVM 修调可载，只计数）
		if math.floor(val / 128) % 2 == 1 then boot_count = boot_count + 1 end
		-- SWRESET：进入复位过程（读回 bit2=1 至结束）；其他位同写无意义
		if math.floor(val / 4) % 2 == 1 then
			reset_busy = true
			if armed and not never_ready then
				finish_reset()			-- 预武装：即时完成（武装不消费）
			else
				reset_left = RESET_MS
				m.regs[lps22hb.REG.CTRL2] = 0
			end
			return
		end
		-- 落盘位（仅 bit4 FIFO_EN / bit3 IF_ADD_INC；纯算术按位保留，勿用 %24）
		local stored = (math.floor(val / 16) % 2) * 16
		             + (math.floor(val / 8) % 2) * 8
		if mode == "idle" and (val % 2 == 1) and not reset_busy then
			-- ONE_SHOT：仅 power-down/单次模式有效（连续模式写它自清无效）
			if armed and not never_ready then
				m.regs[lps22hb.REG.CTRL2] = stored
				finish_conv()
				armed = false			-- 单次武装一次性消费
			else
				conv_busy, conv_left = true, CONV_MS
				m.regs[lps22hb.REG.CTRL2] = stored
			end
		else
			m.regs[lps22hb.REG.CTRL2] = stored
		end
	end

	-- CTRL_REG1 写：存字节并切 ODR 模式机
	local function write_ctrl1(val)
		val = math.floor(val) % 256
		m.regs[lps22hb.REG.CTRL1] = val
		odr_code = math.floor(val / 16) % 8
		cont_period = ODR_PERIOD_MS[odr_code]
		cont_acc = 0
		mode = cont_period and "cont" or "idle"
		if mode == "idle" then conv_busy, conv_left = false, nil end
	end

	-- ---------------- virtbus 点定义回调（总线无 self 调用，绝不能用冒号） ----------------

	m.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if m.nack or m.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes == 1 then
			m.ptr = bytes[1] % 128		-- 地址空间 7 位，bit7 是自动增量位
			inc_bit = bytes[1] >= 128
			return true
		end
		local base = bytes[1] % 128
		local winc = bytes[1] >= 128 or if_inc_global()
		for i = 2, #bytes do
			local a = winc and (base + i - 2) % 128 or base
			if not READONLY[a] then
				local v = bytes[i] % 256
				if a == lps22hb.REG.CTRL1 then
					write_ctrl1(v)
				elseif a == lps22hb.REG.CTRL2 then
					write_ctrl2(v)
				else
					m.regs[a] = v
				end
			end
		end
		return true
	end

	-- 动态寄存器读合成
	local function read_byte(addr)
		if addr == lps22hb.REG.CTRL2 then
			local v = m.regs[lps22hb.REG.CTRL2] or 0
			if reset_busy then v = v + BIT_SWRESET end
			if conv_busy then v = v + BIT_ONESHOT end
			return v % 256
		end
		if addr == lps22hb.REG.STATUS then
			return (p_da and 1 or 0) + (t_da and 2 or 0)
		end
		return m.regs[addr] or 0
	end

	m.read = function(n)
		if m.nack or m.nack_read then return nil end
		local nn = math.floor(tonumber(n) or 1)
		if read_pred and read_pred(m.ptr, nn) then return nil end
		if nn < 1 then nn = 1 end
		local inc = inc_bit or if_inc_global()
		local t = {}
		local last = m.ptr
		for i = 1, nn do
			local a = inc and (m.ptr + i - 1) % 128 or m.ptr
			t[i] = read_byte(a)
			last = a
			-- 高字节读后清对应 DA（datasheet：MSB 读清除）
			if a == lps22hb.REG.PRESS_H then p_da = false end
			if a == lps22hb.REG.TEMP_H  then t_da  = false end
		end
		m.ptr = inc and (last + 1) % 128 or m.ptr
		return t
	end

	-- ---------------- 配置/状态观察口 ----------------

	function m:who(val)
		if val ~= nil then
			dev_id = math.floor(val) % 256
			self.regs[lps22hb.REG.WHOAMI] = dev_id
		end
		return self
	end
	function m:devid()  return self.regs[lps22hb.REG.WHOAMI] or 0 end
	function m:ctrl1()  return self.regs[lps22hb.REG.CTRL1] or 0 end
	function m:status() return read_byte(lps22hb.REG.STATUS) end
	function m:ctrl2_dynamic() return read_byte(lps22hb.REG.CTRL2) end
	function m:resetting() return reset_busy end
	function m:busy()      return conv_busy end
	function m:p_ready()   return p_da end
	function m:t_ready()   return t_da end
	function m:armed_state() return armed end
	function m:mode_name() return mode end
	function m:boot_count() return boot_count end
	function m:autoinc_flag() return inc_bit end
	function m:pointer() return self.ptr end

	function m:bdu()        return math.floor(self:ctrl1() / 2) % 2 end
	function m:lpf_en()     return math.floor(self:ctrl1() / 8) % 2 end
	function m:lpf_cfg()    return math.floor(self:ctrl1() / 4) % 2 end
	function m:fifo_en()    return math.floor((self.regs[lps22hb.REG.CTRL2] or 0) / 16) % 2 end
	function m:if_add_inc() return math.floor((self.regs[lps22hb.REG.CTRL2] or 0) / 8) % 2 end
	function m:odr()        return odr_code end
	function m:odr_hz()
		local p = ODR_PERIOD_MS[odr_code]
		if p then return 1000 / p, odr_code end
		return nil, odr_code
	end

	-- ---------------- 小端输出区注入 ----------------

	function m:set_word24_le(reg, word)
		word = math.floor(word) % 0x1000000
		reg = math.floor(reg) % 128
		self.regs[reg] = word % 256
		self.regs[(reg + 1) % 128] = math.floor(word / 256) % 256
		self.regs[(reg + 2) % 128] = math.floor(word / 65536) % 256
		return self
	end

	function m:set_word_le(reg, word)
		word = math.floor(word) % 65536
		reg = math.floor(reg) % 128
		self.regs[reg] = word % 256
		self.regs[(reg + 1) % 128] = math.floor(word / 256) % 256
		return self
	end

	function m:get_word24_le(reg)
		reg = math.floor(reg) % 128
		return (self.regs[reg] or 0)
		     + (self.regs[(reg + 1) % 128] or 0) * 256
		     + (self.regs[(reg + 2) % 128] or 0) * 65536
	end

	function m:get_sword24_le(reg)
		local u = self:get_word24_le(reg)
		if u >= 0x800000 then u = u - 0x1000000 end
		return u
	end

	function m:get_word_le(reg)
		reg = math.floor(reg) % 128
		return (self.regs[reg] or 0) + (self.regs[(reg + 1) % 128] or 0) * 256
	end

	function m:get_sword_le(reg)
		local u = self:get_word_le(reg)
		if u >= 32768 then u = u - 65536 end
		return u
	end

	-- 气压/温度有符号原始码：直接写输出寄存器（burst 解码用）同时作为下一次
	-- 转换完成时装载的样本（oneshot/连续模式用）；nil 轴保持
	function m:set_press_raw(code)
		if code ~= nil then
			code = clamp_s24(code)
			self:set_word24_le(lps22hb.REG.PRESS_XL, code)
			pending = pending or {}
			pending.p = code
		end
		return self
	end

	function m:set_temp_raw(code)
		if code ~= nil then
			code = clamp_s16(code)
			self:set_word_le(lps22hb.REG.TEMP_L, code)
			pending = pending or {}
			pending.t = code
		end
		return self
	end

	function m:press_raw() return self:get_sword24_le(lps22hb.REG.PRESS_XL) end
	function m:temp_raw()  return self:get_sword_le(lps22hb.REG.TEMP_L) end

	-- ---------------- 物理量造样本（E2E/守护用） ----------------

	function m:set_press_hpa(h)
		if h ~= nil then self:set_press_raw(h * lps22hb.LSB_PER_HPA) end
		return self
	end

	function m:set_temp_c(t)
		if t ~= nil then self:set_temp_raw(t * lps22hb.LSB_PER_C) end
		return self
	end

	function m:press_hpa() return self:press_raw() / lps22hb.LSB_PER_HPA end
	function m:temp_c()   return self:temp_raw()  / lps22hb.LSB_PER_C end

	-- ---------------- 虚拟时钟（单次转换门/复位门/连续 ODR） ----------------

	function m:advance(ms)
		ms = tonumber(ms) or 0
		if reset_busy and not never_ready then
			reset_left = reset_left - ms
			if reset_left <= 0 then finish_reset() end
		end
		if conv_busy and not never_ready then
			conv_left = conv_left - ms
			if conv_left <= 0 then finish_conv() end
		end
		if mode == "cont" and cont_period and not never_ready then
			cont_acc = cont_acc + ms
			while cont_acc >= cont_period do
				cont_acc = cont_acc - cont_period
				load_sample()
			end
		end
		return self
	end

	-- 喂驱动 cfg.wait 超时：所有门/周期不再完成，预武装也无效
	function m:set_never_ready(v)
		never_ready = v ~= false
		return self
	end

	function m:never_ready_state() return never_ready end

	-- 预武装：下条 SWRESET/ONE_SHOT 命令即时完成（守护不推虚拟时钟）。
	-- 注意 SWRESET 不消费武装（build 复位后 call 仍须零睡眠，且守护每拍
	-- call 前都会重新 virt_tick，双保险）；武装跨 reset 保留。
	function m:arm() armed = true; return self end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用） ----------------

	-- 确定性合成波形（无随机，E2E 数值可复现）：32 拍周期，P 1013.25±5hPa、
	-- T 22±2°C 同相正弦（海平面常温环境）。
	--   n=0：1013.25hPa/22.0°C；n=8：1018.25/24.0（峰）；
	--   n=24：1008.25/20.0（谷）；n=32 回到 n=0。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local th = n * (2 * math.pi / 32)
		local s = math.sin(th)
		self:set_press_hpa(1013.25 + 5.0 * s)
		self:set_temp_c(22.0 + 2.0 * s)
		p_da, t_da = true, true
		armed = true
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

	-- 回 POR 态；保留 who 身份、pending 注入、故障钩子（族约定）
	function m:reset()
		reseed_body()
		self.write_log = {}
		boot_count = 0
		never_ready = false
		armed = false
		return self
	end

	return m
end

return lps22hb

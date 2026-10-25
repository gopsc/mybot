-- ina226.lua —— TI INA226 高边电流/功率监测计虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 【字寻址 16 位寄存器 I2C 器件】（与 ina219.lua 同族，绝不能套字节地址
-- regmap——寄存器号各代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回该字
-- hi/lo）。寄存器事实（与 modules/INA226.lua 同源，TI datasheet SBOS547）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[14]=保留恒 1
--                [13:12]=保留恒 0 [11:9]=AVG [8:6]=VBUSCT [5:3]=VSHCT
--                [2:0]=MODE；上电/复位默认 0x4127（AVG=1, 双 1.1ms, 连续）
--   0x01 SHUNT_VOLTAGE 16 位完整有符号、无移位、无 PGA，LSB 2.5µV，
--                      量程固定 ±81.92mV（INA219 是 10µV + PGA/8 ±320mV）
--   0x02 BUS_VOLTAGE   16 位无符号、【无移位】，LSB 1.25mV，码值直读
--                      （INA219 是 13 位左移 3 / 4mV，低 3 位 CNVR/OVF；
--                       INA226 标志在独立的 MASK/ENABLE 寄存器，总线字全是码）
--   0x03 POWER / 0x04 CURRENT / 0x05 CALIBRATION：本驱动不写校准、全软件换算
--      I=Vshunt/R、P=Vbus·I，协议上存在，照读照写（POR 0），模型不解释；
--      0x06 MASK/ENABLE（bit3=CVRF、bit2=OVF，本驱动不用）/0x07 ALERT_LIMIT 同
--   0xFE MANUFACTURER_ID 恒 0x5449（'TI'）、0xFF DIE_ID 恒 0x2260：
--      【真 ROM ID】（INA219 无 ID 寄存器，只靠复位默认值甄别），只读——
--      写 ACK 但丢弃，who() 可覆写喂 build 误挂负路径
--
-- 连续模式（MODE=111，驱动 build 固定）下结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个转换
-- 循环」（10ms 复位 + 2·ct·avg +2）只是 sleep，模型不计时。软复位是本模型
-- 唯一的写副作用：向 CONFIG 写 bit15=1 的字时 0x8000 不落盘，寄存器文件
-- 原地恢复上电态（RST 自清）。CONFIG 读出保留位按 datasheet 合成（bit14 恒
-- 1、bit13:12 恒 0）。
--
-- 用法：
--   local inmod = dofile("modules/lib/virtbus/ina226.lua")
--   local dev = inmod.new()                       -- 复位配置默认 0x4127 + ROM ID
--   dev:set_vip(12.0, 0.05)                       -- 总线 12V、分流压降 50mV
--   vbus.attach("INA226@0x40", 0x40, dev)
--
--   dev:who(0x0000, 0x2260)    -- 覆写厂商 ID 模拟误挂（build 甄别失败）
--   dev.nack_read = true       -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号/ROM ID 与软复位语义；
-- I=Vshunt/R、P=Vbus·I 的换算全在驱动，物理量注入 API（set_vip/
-- set_current_a）的常量仅为造样本，测试另做独立换算交叉。

local ina226 = {}
ina226._VERSION = "0.1.0"

ina226.REG = {
	CONFIG = 0x00,
	SHUNT  = 0x01,
	BUS    = 0x02,
	POWER  = 0x03,
	CURRENT= 0x04,
	CALIB  = 0x05,
	MASK   = 0x06,
	ALERT  = 0x07,
	MFG    = 0xFE,
	DIE    = 0xFF,
}

ina226.CFG_DEFAULT = 0x4127		-- 复位/上电默认（bit14=1, AVG=1, 双 1.1ms, 连续）
ina226.MFG_ID = 0x5449			-- 'TI'
ina226.DIE_ID = 0x2260
ina226.SHUNT_LSB_V = 2.5e-6		-- 分流寄存器 LSB 2.5µV（16 位有符号）
ina226.BUS_LSB_V   = 1.25e-3	-- 总线寄存器 LSB 1.25mV（16 位无符号无移位）
ina226.DEF_RSHUNT  = 0.1		-- CJMCU-226 板载 R100

local function clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function ina226.new(opts)
	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~255）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local mfg_id = opts.mfg_id or ina226.MFG_ID
	local die_id = opts.die_id or ina226.DIE_ID
	local reset_cfg = opts.reset_cfg or ina226.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ina226.REG.CONFIG] = reset_cfg
		regs[ina226.REG.MFG] = mfg_id
		regs[ina226.REG.DIE] = die_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- CONFIG 读出：保留位按事实合成（bit14 恒 1、bit13:12 恒 0），其余照存
	local function config_read()
		return (regs[ina226.REG.CONFIG] or ina226.CFG_DEFAULT) % 0x1000 + 0x4000
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 1 字节 {reg} = 纯指针写；恰 3 字节 {reg,hi,lo} = 写一个 16 位寄存器；
	-- 其余长度在本器件协议下不存在，NACK。
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		ptr = p
		if #bytes == 1 then return true end
		-- 写 CONFIG 且最高位 RST=1：0x8000 不落盘，原地系统复位、RST 自清。
		-- （datasheet：RST 写 1 即产生与上电相同的复位，同写其他位被忽略）
		if p == ina226.REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == ina226.REG.CONFIG then
			-- 保留位：bit14 读恒 1、bit13:12 读恒 0，写啥都被硬件归位
			regs[p] = word % 0x1000 + 0x4000
		elseif p == ina226.REG.MFG or p == ina226.REG.DIE then
			-- ROM ID 只读：写 ACK 但丢弃，不改身份
		else
			regs[p] = word
		end
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA226 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local wi = p + math.floor((i - 1) / 2)
			local word
			if wi == ina226.REG.CONFIG then
				word = config_read()
			else
				word = regs[wi] or 0
			end
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- SHUNT_VOLTAGE：16 位有符号 LSB（接受负码，自动补码），满码 ±32768/32767
	function d:set_shunt_raw(raw)
		regs[ina226.REG.SHUNT] = clampi(math.floor(raw + 0.5), -32768, 32767) % 65536
		return self
	end

	-- BUS_VOLTAGE：直接写 16 位无符号寄存器字（满码 65535 = 81.91875V）
	function d:set_bus_raw(word)
		regs[ina226.REG.BUS] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- POWER/CURRENT/CALIB/MASK/ALERT：驱动不解释的协议寄存器，留原始码注入口
	function d:set_word(reg, word)
		reg = clampi(math.floor(reg), 0, 255)
		regs[reg] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 总线电压 V（16 位无符号直读，LSB 1.25mV）
	function d:set_bus_v(v)
		local code = clampi(math.floor(v / ina226.BUS_LSB_V + 0.5), 0, 65535)
		return self:set_bus_raw(code)
	end

	-- 分流压降 V（有符号，固定量程 ±81.92mV）
	function d:set_shunt_v(v)
		return self:set_shunt_raw(math.floor(v / ina226.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐：总线电压 + 分流压降
	function d:set_vip(bus_v, shunt_v)
		self:set_bus_v(bus_v)
		if shunt_v ~= nil then self:set_shunt_v(shunt_v) end
		return self
	end

	-- 按电流造分流压降：Vshunt = I × R（r 缺省 0.1Ω，须与驱动 build 的 rshunt 一致）
	function d:set_current_a(a, r)
		r = tonumber(r) or ina226.DEF_RSHUNT
		return self:set_shunt_v(a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期：总线 12.0 ± 0.4V（11.6~12.4V）、电流 0.5 ± 0.3A（0.2~0.8A，
	-- 按板载 R100 反推分流压降 20~80mV，固定量程 ±81.92mV 内不削顶），同相位；
	-- 无随机，E2E 数值可复现。连续模式无武装概念，直接更新结果寄存器即可
	-- （守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_vip(12.0 + 0.4 * s, (0.5 + 0.3 * s) * ina226.DEF_RSHUNT)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写软复位后的 CONFIG 默认值（喂 build「Config after reset」失配路径；
	-- 立即把 CONFIG 置于该值，软复位后也是它；nil=不改）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[ina226.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 ROM ID（nil = 不改；软复位不恢复出厂值，喂 build 误挂甄别路径；
	-- 测试 section 须显式 who() 恢复，避免跨用例污染）
	function d:who(mfg, die)
		if mfg ~= nil then
			mfg_id = math.floor(mfg) % 65536
			regs[ina226.REG.MFG] = mfg_id
		end
		if die ~= nil then
			die_id = math.floor(die) % 65536
			regs[ina226.REG.DIE] = die_id
		end
		return self
	end

	-- 驱动 build 写过的寄存器字写：write_log 中恰 3 字节事务 {reg,hi,lo}；
	-- 1 字节事务是读寄存器指针。
	function d:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e == 3 then
				out[#out + 1] = { reg = e[1], hi = e[2], lo = e[3],
				                  word = e[2] * 256 + e[3] }
			end
		end
		return out
	end

	function d:reset_count() return reset_count end
	function d:pointer() return ptr end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回上电态（保留故障钩子，与 ads1256/sgp30 约定一致：复位不得解除测试钩子；
	-- who() 覆写的身份同样保留——与 cht8305 约定一致，测试须显式恢复）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config()    return config_read() end
	function d:mfg()       return regs[ina226.REG.MFG] or 0 end
	function d:die()       return regs[ina226.REG.DIE] or 0 end
	function d:shunt_raw()
		local v = regs[ina226.REG.SHUNT] or 0
		if v >= 0x8000 then v = v - 0x10000 end
		return v
	end
	function d:bus_raw()   return regs[ina226.REG.BUS] or 0 end
	function d:word(reg)   return regs[reg] or 0 end
	function d:shunt_v()   return self:shunt_raw() * ina226.SHUNT_LSB_V end
	function d:bus_v()     return self:bus_raw() * ina226.BUS_LSB_V end
	function d:current_a(r) return self:shunt_v() / (tonumber(r) or ina226.DEF_RSHUNT) end
	function d:power_w(r)  return self:bus_v() * self:current_a(r) end

	return d
end

return ina226

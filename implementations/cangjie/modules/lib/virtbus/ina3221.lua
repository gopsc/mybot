-- ina3221.lua —— TI INA3221 三通道高边电流/电压监测计虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 【字寻址 16 位寄存器 I2C 器件】（与 ina219/ina226 同族，绝不能套字节地址
-- regmap——寄存器号各代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回该字
-- hi/lo）。与单通道 INA226 的协议事实差异逐条独立（勿互抄常数）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[14:12]=通道使能
--                （ch1=bit14/ch2=13/ch3=12）[11:9]=AVG [8:6]=VBUSCT
--                [5:3]=VSHCT [2:0]=MODE；上电/复位默认 0x7127（3 通道全使能、
--                AVG=1、双 1.1ms、连续）。【全 16 位均有定义、无保留位】
--                （INA226 bit14 恒 1/bit13:12 恒 0，读出需合成）
--   0x01/0x02   通道1 SHUNT/BUS，0x03/0x04 通道2，0x05/0x06 通道3：
--                分流/总线【同为 13 位有效、左移 3 位存放】（低 3 位恒 0），
--                驱动读后 >>3；分流 s13 有符号 LSB 40µV（量程 ±163.84mV，
--                INA226 是 16 位完整有符号 2.5µV ±81.92mV），总线 u13 无符号
--                LSB 8mV（满码 8191 = 65.528V；INA226 是 16 位直读 1.25mV）
--   0x07~0x0E   各通道 CRITICAL/WARNING 告警限、分流和/和限（驱动不用，
--                协议存在照存）；0x0F MASK/ENABLE（bit0=CVRF，驱动不读不写）；
--                0x10/0x11 POWER-VALID 上下限同
--   0xFE MANUFACTURER_ID 恒 0x5449（'TI'）、0xFF DIE_ID 恒 0x3220：真 ROM ID，
--                只读——写 ACK 但丢弃，who() 可覆写喂 build 误挂负路径。
--                注意与 INA226（DIE=0x2260）不同
--
-- 连续模式（MODE=111，驱动 build 固定）下六个结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个完整
-- 转换循环」（10ms 复位 + ceil(3·(1.1+1.1)·avg)+2）只是 sleep，模型不计时。
-- 通道使能位只照存，模型不模拟转换引擎（驱动恒使能三通道）。软复位是本模型
-- 唯一的写副作用：向 CONFIG 写 bit15=1 的字时 0x8000 不落盘，寄存器文件
-- 原地恢复上电态（RST 自清）。
--
-- 用法：
--   local inmod = dofile("modules/lib/virtbus/ina3221.lua")
--   local dev = inmod.new()                    -- 复位配置默认 0x7127 + ROM ID
--   dev:set_vi(1, 12.0, 0.005)                 -- 通道1：总线 12V、分流压降 5mV
--   vbus.attach("INA3221@0x40", 0x40, dev)
--
--   dev:who(0x0000, 0x3220)    -- 覆写厂商 ID 模拟误挂（build 甄别失败）
--   dev.nack_read = true       -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号/左移 3/ROM ID 与软复位语义；
-- I=Vshunt/R 换算全在驱动（芯片内无电流/功率寄存器），物理量注入 API
-- （set_vi/set_current_a）的常量仅为造样本，测试另做独立换算交叉。

local ina3221 = {}
ina3221._VERSION = "0.1.0"

ina3221.REG = {
	CONFIG = 0x00,
	SHUNT  = { 0x01, 0x03, 0x05 },	-- 通道 1/2/3 分流电压
	BUS    = { 0x02, 0x04, 0x06 },	-- 通道 1/2/3 总线电压
	MASK   = 0x0F,
	MFG    = 0xFE,
	DIE    = 0xFF,
}

ina3221.CFG_DEFAULT = 0x7127		-- 复位/上电默认（3ch 全使能、AVG=1、双 1.1ms、连续）
ina3221.MFG_ID = 0x5449			-- 'TI'
ina3221.DIE_ID = 0x3220
ina3221.SHUNT_LSB_V = 40e-6		-- 分流 13 位有符号（>>3 后）LSB 40µV
ina3221.BUS_LSB_V   = 0.008		-- 总线 13 位无符号（>>3 后）LSB 8mV
ina3221.DEF_RSHUNT  = 0.01		-- CJMCU-3221 板载 10mΩ

local function clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- 13 位有符号还原（与驱动 s13 同款：寄存器字 >>3 后调用）
local function s13(v)
	if v >= 0x1000 then v = v - 0x2000 end
	return v
end

function ina3221.new(opts)
	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~255）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local mfg_id = opts.mfg_id or ina3221.MFG_ID
	local die_id = opts.die_id or ina3221.DIE_ID
	local reset_cfg = opts.reset_cfg or ina3221.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ina3221.REG.CONFIG] = reset_cfg
		regs[ina3221.REG.MFG] = mfg_id
		regs[ina3221.REG.DIE] = die_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- 通道号 1/2/3 → 该类寄存器字地址；非法通道返回 nil
	local function ch_reg(tab, ch)
		ch = math.floor(tonumber(ch) or 0)
		if ch >= 1 and ch <= 3 then return tab[ch] end
		return nil
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
		if p == ina3221.REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == ina3221.REG.MFG or p == ina3221.REG.DIE then
			-- ROM ID 只读：写 ACK 但丢弃，不改身份
		else
			-- CONFIG 全 16 位有定义（无保留位），其余寄存器照存
			regs[p] = word
		end
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA3221 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local wi = p + math.floor((i - 1) / 2)
			local word = regs[wi] or 0
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------
	-- 码域 = 驱动 >>3 之后的 13 位码；模型按器件事实左移 3 存放。

	-- 通道 ch 分流码：s13 有符号 -4096~4095（接受负码，自动补码左移）
	function d:set_shunt_raw(ch, code)
		local reg = ch_reg(ina3221.REG.SHUNT, ch)
		if reg then
			regs[reg] = (clampi(math.floor(code + 0.5), -4096, 4095) * 8) % 65536
		end
		return self
	end

	-- 通道 ch 总线码：u13 无符号 0~8191
	function d:set_bus_raw(ch, code)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if reg then
			regs[reg] = clampi(math.floor(code), 0, 8191) * 8
		end
		return self
	end

	-- 告警限/MASK/POWER-VALID 等驱动不解释的协议寄存器，留原始 16 位码注入口
	function d:set_word(reg, word)
		reg = clampi(math.floor(reg), 0, 255)
		regs[reg] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 通道 ch 总线电压 V（u13，LSB 8mV，满码 65.528V）
	function d:set_bus_v(ch, v)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if reg then
			local code = clampi(math.floor(v / ina3221.BUS_LSB_V + 0.5), 0, 8191)
			regs[reg] = code * 8
		end
		return self
	end

	-- 通道 ch 分流压降 V（s13，LSB 40µV，量程 ±163.84mV）
	function d:set_shunt_v(ch, v)
		return self:set_shunt_raw(ch, math.floor(v / ina3221.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐一个通道：总线电压 + 分流压降
	function d:set_vi(ch, bus_v, shunt_v)
		self:set_bus_v(ch, bus_v)
		if shunt_v ~= nil then self:set_shunt_v(ch, shunt_v) end
		return self
	end

	-- 按电流造通道分流压降：Vshunt = I × R（r 缺省 0.01Ω，须与 build 的 rshuntN 一致）
	function d:set_current_a(ch, a, r)
		r = tonumber(r) or ina3221.DEF_RSHUNT
		return self:set_shunt_v(ch, a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期，三条典型母线/负载（均按板载 10mΩ 反推分流压降，远在
	-- ±163.84mV 量程内不削顶），无随机、E2E 数值可复现：
	--   ch1 12.0±0.4V、0.5±0.3A（分流 2~8mV）
	--   ch2 12.0±0.4V、1.0±0.4A（分流 6~14mV）
	--   ch3  5.0±0.2V、0.3±0.15A（分流 1.5~4.5mV）
	-- 三通道同相；连续模式无武装概念，直接更新结果寄存器（守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		local R = ina3221.DEF_RSHUNT
		self:set_vi(1, 12.0 + 0.4 * s, (0.5 + 0.3 * s) * R)
		self:set_vi(2, 12.0 + 0.4 * s, (1.0 + 0.4 * s) * R)
		self:set_vi(3, 5.0 + 0.2 * s, (0.3 + 0.15 * s) * R)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写软复位后的 CONFIG 默认值（立即把 CONFIG 置于该值，软复位后也是它；
	-- nil=不改。INA3221 驱动 build 不读回配置，此口供模型级复位事实测试）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[ina3221.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 ROM ID（nil = 不改；软复位不恢复出厂值，喂 build 误挂甄别路径；
	-- 测试 section 须显式 who() 恢复，避免跨用例污染）
	function d:who(mfg, die)
		if mfg ~= nil then
			mfg_id = math.floor(mfg) % 65536
			regs[ina3221.REG.MFG] = mfg_id
		end
		if die ~= nil then
			die_id = math.floor(die) % 65536
			regs[ina3221.REG.DIE] = die_id
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

	-- 回上电态（保留故障钩子：复位不得解除测试钩子；who() 覆写身份同样
	-- 保留——测试须显式恢复）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config() return regs[ina3221.REG.CONFIG] or 0 end
	function d:mfg()    return regs[ina3221.REG.MFG] or 0 end
	function d:die()    return regs[ina3221.REG.DIE] or 0 end
	function d:word(reg) return regs[reg] or 0 end

	-- 通道 ch 分流寄存器字 → >>3 → s13 有符号码
	function d:shunt_raw(ch)
		local reg = ch_reg(ina3221.REG.SHUNT, ch)
		if not reg then return nil end
		return s13(math.floor((regs[reg] or 0) / 8))
	end

	-- 通道 ch 总线寄存器字 → >>3（u13 无符号）
	function d:bus_raw(ch)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if not reg then return nil end
		return math.floor((regs[reg] or 0) / 8)
	end

	function d:shunt_v(ch)  return self:shunt_raw(ch) * ina3221.SHUNT_LSB_V end
	function d:bus_v(ch)    return self:bus_raw(ch) * ina3221.BUS_LSB_V end
	function d:current_a(ch, r)
		return self:shunt_v(ch) / (tonumber(r) or ina3221.DEF_RSHUNT)
	end

	return d
end

return ina3221

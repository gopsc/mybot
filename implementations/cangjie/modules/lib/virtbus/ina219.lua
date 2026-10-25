-- ina219.lua —— TI INA219 高边电流/功率监测计虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 【首个字寻址 16 位寄存器 I2C 器件】（不用 regmap——regmap 底座是字节地址
-- burst，适配 MPU6050/BME280 类「每字节一个寄存器号」器件；INA219 的寄存器号
-- 0x00~0x05 各自代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回的是该字的
-- hi/lo，不是字节地址 ptr、ptr+1——直接套 regmap 会把相邻寄存器的高低字节
-- 串读出来）。寄存器事实（与 modules/INA219.lua 同源，TI datasheet SBOS448）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[13]=BRNG [12:11]=PGA
--                [10:7]=BADC [6:3]=SADC [2:0]=MODE；上电/复位默认 0x399F
--                （INA226 默认 0x4127——本器件无 ID 寄存器，驱动就靠复位后
--                  读回 0x399F 做芯片甄别，可用 set_reset_id 模拟错挂）
--   0x01 SHUNT_VOLTAGE 16 位完整有符号、无移位，LSB 10µV（PGA=/8 量程 ±320mV）
--   0x02 BUS_VOLTAGE   13 位有效左移 3 位存放（读后 >>3），LSB 4mV；
--                      bit1=CNVR、bit0=OVF 标志位（驱动不用，保留可注入）
--   0x03 POWER / 0x04 CURRENT / 0x05 CALIBRATION：本驱动不写校准、全软件换算，
--      协议上存在，照读照写（未预置读 0），模型不解释
--
-- 连续模式（MODE=111，驱动 build 固定）下结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个转换
-- 循环」只是 sleep，模型不计时。软复位是本模型唯一的写副作用：向 CONFIG
-- 写 bit15=1 的字时，0x8000 不落盘，寄存器文件原地恢复上电态（RST 自清）。
--
-- 用法：
--   local inmod = dofile("modules/lib/virtbus/ina219.lua")
--   local dev = inmod.new()                       -- 复位配置默认 0x399F
--   dev:set_vip(12.0, 0.1)                        -- 总线 12V、分流压降 100mV
--   vbus.attach("INA219@0x40", 0x40, dev)
--
--   dev:set_reset_id(0x4127)  -- 模拟错挂 INA226（复位读回不符即甄别失败）
--   dev.nack_read = true      -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号与软复位语义；I=Vshunt/R、
-- P=Vbus·I 的换算全在驱动，物理量注入 API（set_vip/set_current_a）的常量
-- 仅为造样本，测试另做独立换算交叉，避免模型与驱动共用一份理解互证假绿。

local ina219 = {}
ina219._VERSION = "0.1.0"

ina219.REG = {
	CONFIG = 0x00,
	SHUNT  = 0x01,
	BUS    = 0x02,
	POWER  = 0x03,
	CURRENT= 0x04,
	CALIB  = 0x05,
}

ina219.CFG_DEFAULT = 0x399F		-- 复位/上电默认（BRNG=32V,PGA=/8,双 12 位,连续）
ina219.SHUNT_LSB_V = 10e-6		-- 分流寄存器 LSB 10µV（PGA=/8）
ina219.BUS_LSB_V   = 0.004		-- 总线寄存器 LSB 4mV（13 位）
ina219.DEF_RSHUNT  = 0.1		-- CJMCU-219 板载 R100

local function clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function ina219.new(opts)
	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~5）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local reset_id = opts.reset_id or ina219.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ina219.REG.CONFIG] = reset_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
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
		if p == ina219.REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		regs[p] = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA219 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local within = (i - 1) % 2
			local word = regs[p + math.floor((i - 1) / 2)] or 0
			out[i] = within == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- SHUNT_VOLTAGE：16 位有符号 LSB（接受负码，自动补码）
	function d:set_shunt_raw(raw)
		regs[ina219.REG.SHUNT] = clampi(math.floor(raw + 0.5), -32000, 32000) % 65536
		return self
	end

	-- BUS_VOLTAGE：直接写 16 位寄存器字（含低 3 位标志，调用方自行布局）
	function d:set_bus_raw(word)
		regs[ina219.REG.BUS] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- 注入总线低 3 位标志（bit1=CNVR、bit0=OVF），不影响高 13 位电压码
	function d:set_bus_flags(cnvr, ovf)
		local w = regs[ina219.REG.BUS] or 0
		local code = w - (w % 8)
		if cnvr then code = code + 2 end
		if ovf then code = code + 1 end
		return self:set_bus_raw(code)
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 总线电压 V（13 位码 <<3 存放，0~32.764V；额定 26V 以上为器件超额定区）
	function d:set_bus_v(v)
		local code = clampi(math.floor(v / ina219.BUS_LSB_V + 0.5), 0, 8191)
		return self:set_bus_raw(code * 8)
	end

	-- 分流压降 V（有符号，PGA=/8 量程 ±320mV）
	function d:set_shunt_v(v)
		return self:set_shunt_raw(math.floor(v / ina219.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐：总线电压 + 分流压降
	function d:set_vip(bus_v, shunt_v)
		self:set_bus_v(bus_v)
		if shunt_v ~= nil then self:set_shunt_v(shunt_v) end
		return self
	end

	-- 按电流造分流压降：Vshunt = I × R（r 缺省 0.1Ω，须与驱动 build 的 rshunt 一致）
	function d:set_current_a(a, r)
		r = tonumber(r) or ina219.DEF_RSHUNT
		return self:set_shunt_v(a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期：总线 12.0 ± 0.4V（11.6~12.4V）、电流 1.0 ± 0.6A（0.4~1.6A，
	-- 按板载 R100 反推分流压降 40~160mV），同相位；无随机，E2E 数值可复现。
	-- 连续模式无武装概念，直接更新结果寄存器即可（守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_vip(12.0 + 0.4 * s, (1.0 + 0.6 * s) * ina219.DEF_RSHUNT)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 改复位后读回的配置默认值（0x4127 模拟 INA226 错挂，喂 build 甄别路径）；
	-- 立即把 CONFIG 置于该值（build 首笔 RST 写后 reseed 也是它）
	function d:set_reset_id(word)
		reset_id = math.floor(word) % 65536
		regs[ina219.REG.CONFIG] = reset_id
		return self
	end

	-- 驱动 build 写过的寄存器写：write_log 中恰 3 字节事务 {reg,hi,lo}；
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

	-- 回上电态（保留故障钩子，与 ads1256/sgp30 约定一致：复位不得解除测试钩子）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config()    return regs[ina219.REG.CONFIG] or 0 end
	function d:shunt_raw()
		local v = regs[ina219.REG.SHUNT] or 0
		if v >= 0x8000 then v = v - 0x10000 end
		return v
	end
	function d:bus_raw()   return regs[ina219.REG.BUS] or 0 end
	function d:shunt_v()   return self:shunt_raw() * ina219.SHUNT_LSB_V end
	function d:bus_v()     return math.floor(self:bus_raw() / 8) * ina219.BUS_LSB_V end
	function d:current_a(r) return self:shunt_v() / (tonumber(r) or ina219.DEF_RSHUNT) end
	function d:power_w(r)  return self:bus_v() * self:current_a(r) end

	return d
end

return ina219

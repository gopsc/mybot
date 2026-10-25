-- modules/lib/virtbus/ltc2944.lua —— LTC2944 多节电池电量计虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【8 位字节指针 + 16 位大端寄存器对、指针自增模 26 回绕】样板
-- （ADI LTC2944，I2C 固定地址 0x64；纯闭包、纯算术无 bitcompat）。
-- 协议事实与 modules/LTC2944.lua 驱动同源（ADI 手册 / Linduino LTC2944.cpp）：
--   1) 寄存器文件 0x00~0x19 共 26 字节，8 位寄存器指针；write 首字节=指针，
--      其后数据字节从该址逐字节落位（指针自增，越过 0x19 回绕 0x00），单字节
--      写=纯指针写；read(n) 从当前指针连续读、每字节后指针自增（模 26）。
--      保留地址 0x1A~0xFF 不建模（写指针按模 26 折回文件内）。
--      寄存器对（MSB 偶址 / LSB 奇址，大端）：
--        0x00 STATUS(8)      0x01 CONTROL(8，[7:6]模式 [5:3]预分频码 [0]关断)
--        0x02/03 累计电荷 u16（可主机写，用于清零/预置累计）
--        0x04/05·06/07 电荷阈值高/低（驱动不碰）
--        0x08/09 电压 u16（V = raw/65535×70.8）
--        0x0A/0B·0C/0D 电压阈值
--        0x0E/0F 电流偏移二进制（中点 0x7FFF=0A，A=(raw-0x7FFF)/0x7FFF×0.064/rsense）
--        0x10/11·12/13 电流阈值
--        0x14/15 温度 u16（K：raw/65535×510，°C 再减 273.15）
--        0x16/17·18/19 温度阈值
--   2) 【charge_msb_clobbered 哨兵协议基础】CONTROL(0x01) 是 8 位寄存器：
--      正确写帧恰 2 字节 {0x01,ctrl}；若发 3 字节 {0x01,0x00,ctrl}，指针自增
--      会把 0x00 落进 CONTROL（[7:6]=00 休眠）、ctrl 落进 CHG_MSB(0x02) 毁掉
--      累计电荷。模型忠实按指针自增落位，由测试断言驱动永不发越界 3 字节帧。
--   3) 无 ID 寄存器：build 的存在性检查 = 指针读 STATUS(0x00) 2 字节 ACK
--      （连带读回 CONTROL，驱动只看 <0）。连续测量模式结果常驻寄存器，
--      模型不模拟 ADC 转换过程/无转换门（同 INA219 族），测量值只由注入 API
--      改变，virt_tick 直接装载寄存器。
--   4) virt_tick 供守护逐拍造数：32 拍确定性正弦 V 12.0±0.4V、I 0.8±0.4A
--      （充电为正；50mΩ rsense 满量程 ±1.28A，峰值 1.2A 留余量不削顶）、
--      T 30±5°C 同相；累计电荷单调爬坡（200 code/拍，0xFFFF 回绕）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。

local M = {}
M._VERSION = "0.1.0"

local MAP_N = 0x1A -- 寄存器文件 0x00~0x19 共 26 字节

local R = {
	STATUS = 0x00, CONTROL = 0x01,
	CHG = 0x02, V = 0x08, I = 0x0E, T = 0x14,
}

-- 驱动换算同源常数（仅物理量逆注入用，正算归驱动）
local FS_VOLTAGE_V = 70.8
local FS_SENSE_V   = 0.064
local FS_TEMP_K    = 510.0
local ZERO_K       = 273.15
local CHARGE_LSB_AH = 0.34e-6

local function bytev(v)
	v = tonumber(v)
	if v == nil or v ~= math.floor(v) or v < 0 or v > 255 then return nil end
	return v
end

local function u16v(v)
	v = tonumber(v)
	if v == nil or v ~= math.floor(v) or v < 0 or v > 65535 then return nil end
	return v
end

local function clamp_u16(x)
	x = math.floor(x + 0.5)
	if x < 0 then return 0 end
	if x > 65535 then return 65535 end
	return x
end

function M.new(opts)
	opts = opts or {}
	local d = {}

	local regs = {}				-- 稀疏字节影子 0x00~0x19
	local ptr = 0				-- 当前寄存器指针
	local wr_frames = {}		-- 每笔写事务的字节表副本
	local write_count, read_count = 0, 0

	-- 故障钩子（d:reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- POR / 播种 ----------------

	local function por_seed()
		regs = {}
		ptr = 0
		-- POR：STATUS/CONTROL/各测量与阈值寄存器模型取 0
		-- （CONTROL=0x00 非自动模式；驱动 build 必写 0xC0|码，测量值只由注入改）
		local c = bytev(opts.control) or 0
		local s = bytev(opts.status) or 0
		regs[R.STATUS] = s
		regs[R.CONTROL] = c
		local pairs = {
			{ R.CHG, u16v(opts.charge) or 0 },
			{ R.V, u16v(opts.voltage) or 0 },
			{ R.I, u16v(opts.current) or 0 },
			{ R.T, u16v(opts.temp) or 0 },
		}
		for _, p in ipairs(pairs) do
			regs[p[1]] = math.floor(p[2] / 256) % 256
			regs[p[1] + 1] = p[2] % 256
		end
	end
	por_seed()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end
		local frame = {}
		for i = 1, #bytes do
			local b = bytev(bytes[i])
			if b == nil then return false end	-- 非字节：整笔 NACK，寄存器不动
			frame[i] = b
		end
		local p = frame[1] % MAP_N				-- 首字节=指针
		for i = 2, #frame do
			regs[p] = frame[i]					-- 数据逐字节落位、指针自增
			p = (p + 1) % MAP_N
		end
		ptr = p									-- 纯指针写则停在该址，多字节则停末址+1
		wr_frames[#wr_frames + 1] = frame
		write_count = write_count + 1
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(ptr, n) then return nil end
		local t = {}
		for _ = 1, n do
			t[#t + 1] = regs[ptr] or 0			-- 未播种/保留位读 0
			ptr = (ptr + 1) % MAP_N				-- 0x19 后回绕 0x00
		end
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	function d:set(reg, v)
		reg = math.floor(tonumber(reg) or -1)
		v = bytev(v)
		if reg >= 0 and reg < MAP_N and v ~= nil then regs[reg] = v end
		return self
	end

	function d:set_word(reg, word)
		reg = math.floor(tonumber(reg) or -1)
		word = u16v(word)
		if reg >= 0 and reg < MAP_N and word ~= nil then
			regs[reg] = math.floor(word / 256) % 256
			regs[(reg + 1) % MAP_N] = word % 256
		end
		return self
	end

	function d:set_status(b) return self:set(R.STATUS, b) end
	function d:set_control(b) return self:set(R.CONTROL, b) end
	function d:set_charge_raw(code) return self:set_word(R.CHG, code) end
	function d:set_voltage_raw(code) return self:set_word(R.V, code) end
	function d:set_current_raw(code) return self:set_word(R.I, code) end
	function d:set_temp_raw(code) return self:set_word(R.T, code) end

	-- 物理量逆注入（常量与驱动换算同源；仅供造数，不抄进正算链路）
	function d:set_voltage_v(v)
		v = tonumber(v)
		if v then self:set_voltage_raw(clamp_u16(v / FS_VOLTAGE_V * 65535)) end
		return self
	end
	function d:set_current_a(a, rsense)
		a = tonumber(a)
		rsense = tonumber(rsense) or 0.05
		if a and rsense > 0 then
			self:set_current_raw(clamp_u16(0x7FFF + a * rsense / FS_SENSE_V * 0x7FFF))
		end
		return self
	end
	function d:set_temp_c(t)
		t = tonumber(t)
		if t then self:set_temp_raw(clamp_u16((t + ZERO_K) / FS_TEMP_K * 65535)) end
		return self
	end
	-- mAh → code：code = mAh×rsense×4096 / (0.34e-3×1000×M×0.05)
	function d:set_charge_mah(mah, m, rsense)
		mah = tonumber(mah)
		m = tonumber(m) or 4096
		rsense = tonumber(rsense) or 0.05
		if mah and m > 0 and rsense > 0 then
			self:set_charge_raw(clamp_u16(mah * rsense * 4096 / (CHARGE_LSB_AH * 1000 * m * 0.05)))
		end
		return self
	end

	-- 守护逐拍造数：32 拍同相正弦 + 电荷单调爬坡；直接装载寄存器（绕过任何门）
	function d:virt_tick(n)
		n = math.floor(tonumber(n) or 0)
		local s = math.sin(2 * math.pi * (n % 32) / 32)
		self:set_voltage_v(12.0 + 0.4 * s)
		self:set_current_a(0.8 + 0.4 * s, 0.05)
		self:set_temp_c(30.0 + 5.0 * s)
		self:set_charge_raw((10000 + 200 * n) % 65536)
		return self
	end

	-- ---------------- 故障 / 复位 ----------------

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		return self
	end

	function d:reset_logs()
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 重新上电：寄存器回 POR、指针归零、留痕清空；故障钩子保留
	function d:reset()
		por_seed()
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a)
		a = math.floor(tonumber(a) or 0) % MAP_N
		return regs[a] or 0
	end
	function d:word(reg)
		reg = math.floor(tonumber(reg) or 0) % MAP_N
		return (regs[reg] or 0) * 256 + (regs[(reg + 1) % MAP_N] or 0)
	end
	function d:ptr() return ptr end
	function d:status() return regs[R.STATUS] or 0 end
	function d:control() return regs[R.CONTROL] or 0 end
	function d:charge_raw() return self:word(R.CHG) end
	function d:voltage_raw() return self:word(R.V) end
	function d:current_raw() return self:word(R.I) end
	function d:temp_raw() return self:word(R.T) end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:frames() return wr_frames end

	return d
end

return M

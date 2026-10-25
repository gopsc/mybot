-- virtbus/ad9833.lua —— AD9833 DDS 波形发生器的虚拟 SPI 器件模型（写-only）
-- bot4cj 仓颉机器人框架
--
-- 对应真实驱动 modules/AD9833.lua（SPI Mode 2，每 16 位字一个独立 CS 帧）。
-- 器件无 SDO/读回能力，模型只做 MOSI 侧的「16 位字解码状态机」：把驱动写下
-- 的帧还原成频率寄存器/相位寄存器/控制位，测试可直接读出 freq_hz()/wave()/
-- muted() 验证调谐字拼接（低 14 位在前的两段加载顺序反了立即暴露）。
--
-- 挂载（SPI 路径即片选身份）：
--   local ddsmod = dofile("modules/lib/virtbus/ad9833.lua")
--   local dds = ddsmod.new()                 -- 默认 MCLK=25MHz（模块板载晶振）
--   vbus.attach_spi("AD9833", "/dev/spidev0.0", dds)
--
-- 16 位字顶 2 位选择目标（每字大端：帧 tx={hi, lo}，w=hi*256+lo）：
--   00 = 控制寄存器；01 = FREQ0（14 位）；10 = FREQ1（14 位）；11 = PHASE（12 位）
-- B28(bit13)=1 时频率寄存器须连续两字加载：先低 14 位后高 14 位（模型用
-- per-register latch 拼 28 位）；B28=0 时 HLB(bit12) 选只写高/低半字。
-- 控制位：B28=0x2000 HLB=0x1000 FSELECT=0x0800 PSELECT=0x0400 RESET=0x0100
--         SLEEP1=0x0080 SLEEP12=0x0040 OPBITEN=0x0020 DIV2=0x0008 MODE=0x0002
-- 波形：sine   = OPBITEN0/MODE0；triangle = OPBITEN0/MODE1；
--       square = OPBITEN1/DIV2=1；RESET=1 输出中点电平（mute）。
-- 模型不抄驱动的调谐字公式做反向断言，只按 datasheet 的 f=raw·MCLK/2^28
-- 提供换算（事实层），正向公式仍以驱动为准。
local bitc = nil
local ok_bc, mpath = pcall(dofile, "modules/lib/mpath.lua")
if ok_bc then
	local ok2, mod = pcall(dofile, mpath.resolve("bitcompat.lua"))
	if ok2 then bitc = mod end
end
local band, bor
if bitc then
	band, bor = bitc.band, bitc.bor
else
	-- 理论兜底：必须用 Lua 5.1 语法（LuaJIT 解析期不认 &/|）
	local function b_and(a, b)
		local r, p = 0, 1
		while a > 0 and b > 0 do
			if a % 2 == 1 and b % 2 == 1 then r = r + p end
			a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
		end
		return r
	end
	local function b_or(a, b)
		local r, p = 0, 1
		while a > 0 or b > 0 do
			if a % 2 == 1 or b % 2 == 1 then r = r + p end
			a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
		end
		return r
	end
	band, bor = b_and, b_or
end

local dds = {}
dds.BUS = "spi"		-- 供 sensor_daemon proto=virt 区分挂载类型（写-only 器件无守护 E2E）

local DEFAULT_MCLK = 25000000
local POW2_28 = 268435456

-- 控制字位掩码
local B_B28, B_HLB     = 0x2000, 0x1000
local B_FSEL, B_PSEL   = 0x0800, 0x0400
local B_RESET          = 0x0100
local B_OPBITEN, B_DIV2, B_MODE = 0x0020, 0x0008, 0x0002

function dds.new(opts)
	opts = opts or {}
	local self = {}
	local mclk = tonumber(opts.mclk) or DEFAULT_MCLK

	-- 器件状态
	local ctrl = 0x0000
	local freq = { [0] = 0, [1] = 0 }	-- FREQ0/FREQ1 28 位调谐字
	local phase = { [0] = 0, [1] = 0 }	-- PHASE0/PHASE1 12 位
	local latch = { [0] = nil, [1] = nil }	-- B28 两段加载的低半字挂起值
	local words = {}
	local fail_pred = nil

	-- ===================== 状态/留痕 API =====================

	function self:ctrl() return ctrl end
	function self:freq_raw(reg) return freq[tonumber(reg) == 1 and 1 or 0] end
	function self:phase_raw(preg) return phase[tonumber(preg) == 1 and 1 or 0] end

	-- 当前输出选用的频率/相位寄存器（FSELECT/PSELECT 位）
	function self:active_freq_reg() return band(ctrl, B_FSEL) ~= 0 and 1 or 0 end
	function self:active_phase_reg() return band(ctrl, B_PSEL) ~= 0 and 1 or 0 end

	-- 输出频率 Hz（按 datasheet f = raw · MCLK / 2^28；active 寄存器）
	function self:freq_hz()
		return freq[self:active_freq_reg()] * mclk / POW2_28
	end
	-- 输出相位度（active 相位寄存器）
	function self:phase_deg()
		return phase[self:active_phase_reg()] * 360 / 4096
	end

	function self:muted() return band(ctrl, B_RESET) ~= 0 end
	function self:sleep_dac() return band(ctrl, 0x0040) ~= 0 end	-- SLEEP12：DAC 断电
	function self:sleep_mclk() return band(ctrl, 0x0080) ~= 0 end	-- SLEEP1：内部时钟停

	-- 波形名（仅复刻 datasheet 位组合，非法组合给 "unknown"）
	function self:wave()
		local op, div2, mode = band(ctrl, B_OPBITEN) ~= 0,
			band(ctrl, B_DIV2) ~= 0, band(ctrl, B_MODE) ~= 0
		if op and div2 and not mode then return "square" end
		if not op and mode then return "triangle" end
		if not op and not mode then return "sine" end
		return "unknown"
	end

	function self:word_log() return words end
	function self:reset_logs() words = {}; return self end

	-- 状态机复位（等价器件上电/RESET 状态；不清测试故障钩子）
	function self:reset()
		ctrl = 0x0000
		freq[0], freq[1] = 0, 0
		phase[0], phase[1] = 0, 0
		latch[0], latch[1] = nil, nil
		words = {}
		return self
	end

	-- ---- 故障注入钩子：pred(tx 字节表) 命中的帧传输失败 ----
	function self:fail_when(pred) fail_pred = pred; return self end
	function self:clear_fail() fail_pred = nil; return self end

	-- ===================== 全双工帧核心 =====================

	-- 频率字半写：reg=0/1，payload=14 位；按 B28/HLB 控制位拼装
	local function apply_freq_word(reg, payload)
		payload = band(payload, 0x3FFF)
		if band(ctrl, B_B28) ~= 0 then
			if latch[reg] == nil then
				latch[reg] = payload		-- 先收低 14 位
			else
				freq[reg] = latch[reg] + payload * 0x4000	-- 后收高 14 位
				latch[reg] = nil
			end
		elseif band(ctrl, B_HLB) ~= 0 then
			-- 只写高 14 位：保留低半字
			freq[reg] = band(freq[reg], 0x3FFF) + payload * 0x4000
		else
			-- 只写低 14 位：保留高半字（28 位中 14 位以上部分）
			freq[reg] = payload + band(freq[reg], 0xFFFC000)
		end
	end

	-- xfer(tx)：点定义、无 self 参数（virtbus attach_spi 动态委托契约）。
	-- 帧 = 若干字节；每 2 字节一个大端 16 位字（驱动恒发 2 字节整帧），
	-- 奇数尾字节按半字处理（真实硬件移位如此，模型不计入字日志）。
	local function xfer(tx)
		if type(fail_pred) == "function" and fail_pred(tx) then return nil end
		local n = #tx
		local rx = {}
		for i = 1, n do rx[i] = 0 end

		local i = 1
		while i + 1 <= n do
			local w = tx[i] * 256 + tx[i + 1]
			local sel = math.floor(w / 0x4000)	-- 顶 2 位
			local kind
			if sel == 0 then
				ctrl = w
				kind = "ctrl"
				-- 真机语义：任何控制寄存器写都终止挂起的 B28 两段序列
				-- （半截失败后下一次频率更新不能承接旧低半字，否则错位拼字）
				latch[0], latch[1] = nil, nil
			elseif sel == 1 then
				apply_freq_word(0, band(w, 0x3FFF))
				kind = "freq0"
			elseif sel == 2 then
				apply_freq_word(1, band(w, 0x3FFF))
				kind = "freq1"
			else
				-- 3 = PHASE：bit13 选 PHASE0/PHASE1（驱动恒写 PHASE0）
				local preg = band(w, 0x2000) ~= 0 and 1 or 0
				phase[preg] = band(w, 0x0FFF)
				kind = preg == 1 and "phase1" or "phase0"
			end
			words[#words + 1] = { w = w, hi = tx[i], lo = tx[i + 1], kind = kind }
			i = i + 2
		end
		return rx
	end
	self.xfer = xfer

	return self
end

return dds

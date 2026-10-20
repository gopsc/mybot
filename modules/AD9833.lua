-- AD9833 DDS 可编程波形发生器 驱动模块（SPI，写-only，信号源/激励输出）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 AD9833_VIRT（2026-09-15 自 modules/lib/virtbus/ad9833.lua
-- 迁入，单文件驱动+模型实验第七个；无硬件单测共用；写-only 无测量值，守护 E2E 豁免）
-- Analog Devices，SPI-only（无 I2C）：每字 16 位一帧 CS，模块板载 25MHz 时钟，
-- 28 位频率分辨率（0.0931Hz/码），输出正弦/三角/方波（VOUT ~0.65Vpp，模块约 1Vpp）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SPI (
--       name String, path String, spi_mode String, bits String, speed String, delay String
--   );
--   INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
--     VALUES ('spi-0', '/dev/spidev0.0', '2', '8', '1000000', '0');
--   CREATE TABLE AD9833 (
--       name  String,
--       SPI   String,
--       freq  String,
--       wave  String,
--       phase String
--   );
--   INSERT INTO AD9833 (name, SPI, freq, wave, phase)
--     VALUES ('sig0', 'spi-0', '1000', 'sine', '0');
-- @SPI 的 spi_mode 必须配 2（CPOL=0/CPHA=1，MD_AD9833 同款），bits 配 8，
--   时钟 1MHz 起步（器件上限 14MHz 传输率）；
-- freq  = 输出频率 Hz（0.1~12500000 = f_MCLK/2 上限，超出报错）
-- wave  = 'sine' | 'triangle' | 'square'（缺省 sine）
-- phase = 输出相位 0~360°（缺省 0，12 位相位寄存器 4096 码/周）
-- 各列写 '-' 按缺省值处理
--
-- call 契约（按需更新，键可任意组合；无键则仅回显状态不发字）：
--   call({freq=N, wave='triangle', phase=180, mute=0/1})
--   返回 { result, freq, wave, phase, mute }
--   freq 变更经 B28 两段字原子加载（不静音、无毛刺）；mute=1 输出保持中点
--   电平（静音），mute=0 放行；接守护时 fields=freq|phase（wave 为字符串
--   仅直连路径可读）
--
-- 实现要点（控制位/事务序依 MajicDesigns MD_AD9833 库核实，MIT）：
--   1. SPI 模式 2（CPOL=0/CPHA=1）、MSB 先行、每 16 位字一个独立 CS 帧——
--      一个字必须一帧内发完（HAL spi_write_multi {hi, lo}），不可拆两次写
--   2. 控制字位域：B28=bit13 HLB=12 FSELECT=11 PSELECT=10 RESET=8
--      SLEEP1=7 SLEEP12=6 OPBITEN=5 DIV2=3 MODE=1
--   3. 频率字写入序：B28=1 后连续两字 = 01<<14|低14位、01<<14|高14位——
--      【低 14 位在前]（顺序反了频率即错）；FREQ1 选择码为 10<<14
--   4. 调谐字 = floor(freq x 2^28 / 25e6 + 0.5)（f = FREQREG x MCLK / 2^28，
--      数据手册 DDS 方程；模块 MCLK=25MHz）
--   5. 波形组合：正弦 = OPBITEN0/MODE0；三角 = OPBITEN0/MODE1；
--      方波 = OPBITEN1/DIV2 1（DIV2=0 为 f_MCLK/2 半频方波，不用）
--   6. RESET=1 输出保持中点电平（静音）；build 时序：RESET|B28 -> 频率
--      两字 -> 相位字 -> 波形位清 RESET 放行输出
--   7. 相位字 = 11<<14 | floor(deg x 4096/360 + 0.5)（12 位）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：信号源一般配置后长跑，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 控制字位域 ====================
local BIT_B28     = 0x2000		-- bit13：两段连续写加载 28 位频率字
local BIT_RESET   = 0x0100		-- bit8：输出保持中点（静音）
local BIT_OPBITEN = 0x0020		-- bit5：DAC 输出切方波通路
local BIT_DIV2    = 0x0008		-- bit3：方波二分频开关
local BIT_MODE    = 0x0002		-- bit1：SIN ROM 旁路（三角波）

local SEL_FREQ0   = 0x4000		-- 01<<14：频率寄存器 0
local SEL_PHASE   = 0xC000		-- 11<<14：相位寄存器

local WAVE_BITS   = { sine = 0x0000, triangle = 0x0002, square = 0x0028 }
local WAVE_MAX_F  = 12500000	-- f_MCLK/2（25MHz 时钟）
local MCLK        = 25000000
local POW2_28     = 268435456

-- 模块级状态（build/call 写入，跨 call 保持于状态机内存，destroy 后废弃）
local freq_hz   = 1000
local wave_str  = "sine"
local phase_deg = 0
local muted     = false

-- 16 位字 -> 一帧 CS 两字节
local function send16(fd, w)
	return spi_write_multi(fd, { math.floor(w / 256) % 256, w % 256 }) == 0
end

-- 频率 Hz -> 28 位调谐字
local function tuning_word(f)
	return math.floor(f * POW2_28 / MCLK + 0.5)
end

-- 相位 deg -> 12 位相位字
local function phase_word(d)
	return math.floor(d * 4096 / 360 + 0.5) % 4096
end

-- 波形名 -> 控制位组合；非法返回 nil
local function wave_bits_of(name)
	local w = string.lower(tostring(name or ""))
	return WAVE_BITS[w], w
end

-- 静音/放行/波形位共用的运行控制字（B28 恒 1，RESET 按静音态）
local function run_ctrl(wbits)
	return bitc.bor(BIT_B28, wbits, muted and BIT_RESET or 0)
end

-- 【配置脚本】RESET|B28 -> 频率两字 -> 相位字 -> 波形位清 RESET 放行
require_driver("spi", {
name = "AD9833",
build = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- AD9833 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-- 列配置（缺省 1kHz / sine / 0°，MD_AD9833 同款缺省频率）；
	-- 全部校验通过后才落模块状态（失败半途不得污染跨 call 状态）
	-- 数值列经 num_or 而非 `tonumber(x) or 缺省`：'nan' 过 tonumber 出的是
	-- number（Lua 里 truthy），or 兜不住，而 NaN 与任何数比较都为假，下面两条
	-- 区间判定一律放行——freq_hz/phase_deg 会先被落成 NaN（正好违反上一行的
	-- 不变式），再因 tuning_word(NaN) 的字节被 HAL 挡成 nil 而报 SPI 发送失败，
	-- 把配置笔误误报成总线故障（审计 P3 的 finite_of 口径）。
	local f = num_or(data.freq, 1000)
	if f <= 0 or f > WAVE_MAX_F then
		return err(string.format("Invalid freq: %s (expect 0 < f <= %d Hz)",
				tostring(data.freq), WAVE_MAX_F))
	end
	local wbits, wname = wave_bits_of(data.wave or "sine")
	if wbits == nil then
		return err("Invalid wave: '" .. tostring(data.wave) .. "' (expect sine/triangle/square)")
	end
	local d = num_or(data.phase, 0)
	if d < 0 or d >= 360 then
		return err("Invalid phase: " .. tostring(data.phase) .. " (expect 0 ~ 360)")
	end
	freq_hz, wave_str, phase_deg = f, wname, d
	muted = false

	-----------------------------------------------------
	-- 复位静音 + B28
	if not send16(fd, bitc.bor(BIT_RESET, BIT_B28)) then
		return err("Failed to send AD9833 control word")
	end

	-- 频率字两段（低 14 位在前，B28 原子加载）
	local tw = tuning_word(freq_hz)
	if not send16(fd, SEL_FREQ0 + (tw % 0x4000)) then
		return err("Failed to send AD9833 freq LSBs")
	end
	if not send16(fd, SEL_FREQ0 + (math.floor(tw / 0x4000) % 0x4000)) then
		return err("Failed to send AD9833 freq MSBs")
	end

	-- 相位字
	if not send16(fd, SEL_PHASE + phase_word(phase_deg)) then
		return err("Failed to send AD9833 phase word")
	end

	-- 波形位 + 清 RESET，放行输出
	if not send16(fd, run_ctrl(wbits)) then
		return err("Failed to send AD9833 waveform word")
	end

	print(string.format("AD9833 init OK: freq=%.3fHz, wave=%s, phase=%g deg",
		freq_hz, wave_str, phase_deg))
	return {  result = "OK"  }

end,


-- 【调用AD9833】按需更新输出（键任意组合；无键仅回显状态不发字）
-- NOTE: 接收一个参数（表），返回一个结果（表）
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- AD9833 caller func get a table --------", data)
	end

	-----------------------------------------------------
	-- mute：静音/放行（置/清 RESET 位）——立即下发控制字才生效
	-- 经 finite_of：'nan' 过 tonumber 出的是 number（Lua 里 truthy），`~= nil`
	-- 挡不住，而 NaN ~= 0 又为真，于是 mute='nan' 会**静默把 DDS 静音**——调用方
	-- 从未要求静音。同列写 'abc' 走的是整块跳过、零发字（审计 P3 口径）。
	local mute_v = finite_of(data.mute)
	if mute_v ~= nil then
		muted = (mute_v ~= 0)
		if not send16(fd, run_ctrl(WAVE_BITS[wave_str])) then
			return err("Failed to send AD9833 control word")
		end
	end

	-- wave：波形位（组合控制字重发）
	if data.wave ~= nil then
		local wbits, wname = wave_bits_of(data.wave)
		if wbits == nil then
			return err("Invalid wave: '" .. tostring(data.wave) .. "' (expect sine/triangle/square)")
		end
		wave_str = wname
		if not send16(fd, run_ctrl(wbits)) then
			return err("Failed to send AD9833 waveform word")
		end
	end

	-- freq：B28 + 两段频率字（不静音原子加载；静音态保持 RESET）
	if data.freq ~= nil then
		-- 经 finite_of：NaN 会让 `f == nil` 与两条区间判定同时失效，freq_hz 先被
		-- 落成 NaN 再报 SPI 发送失败（同 build 侧的口径）
		local f = finite_of(data.freq)
		if f == nil or f <= 0 or f > WAVE_MAX_F then
			return err(string.format("Invalid freq: %s (expect 0 < f <= %d Hz)",
					tostring(data.freq), WAVE_MAX_F))
		end
		freq_hz = f
		local tw = tuning_word(freq_hz)
		-- B28 + 当前波形位（静音态保持 RESET）：两段频率字原子加载
		if not send16(fd, run_ctrl(WAVE_BITS[wave_str])) then
			return err("Failed to send AD9833 control word")
		end
		if not send16(fd, SEL_FREQ0 + (tw % 0x4000)) then
			return err("Failed to send AD9833 freq LSBs")
		end
		if not send16(fd, SEL_FREQ0 + (math.floor(tw / 0x4000) % 0x4000)) then
			return err("Failed to send AD9833 freq MSBs")
		end
	end

	-- phase：相位字（12 位）
	if data.phase ~= nil then
		local d = finite_of(data.phase)	-- NaN 同理，见上 freq 列
		if d == nil or d < 0 or d >= 360 then
			return err("Invalid phase: " .. tostring(data.phase) .. " (expect 0 ~ 360)")
		end
		phase_deg = d
		if not send16(fd, SEL_PHASE + phase_word(phase_deg)) then
			return err("Failed to send AD9833 phase word")
		end
	end

	dbg(string.format("AD9833: freq=%.3fHz wave=%s phase=%g deg mute=%s",
		freq_hz, wave_str, phase_deg, tostring(muted)))

	return {
		result = "OK",
		freq   = freq_hz,
		wave   = wave_str,
		phase  = phase_deg,
		mute   = muted and 1 or 0
	}

end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】AD9833_VIRT —— 2026-09-15 自 modules/lib/virtbus/ad9833.lua
-- 整体迁入（单文件驱动+模型第七个，write-only SPI）。约定同前六者：
-- ① 生产路径零执行（new() 仅虚拟总线测试调用；位运算经本文件 mpath 上值
-- 独立 dofile bitcompat、失败退化纯算术——不共用驱动的 bitc 局部量；常量
-- 移入 new() 内避让）；② 工厂经全局表而非文件 return（生产侧 Lua.cj
-- build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值
-- 会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 工厂表带 BUS="spi"（写-only 无守护 E2E，字段仅备分派）。
--
-- 对应真实驱动 modules/AD9833.lua（SPI Mode 2，每 16 位字一个独立 CS 帧）。
-- 器件无 SDO/读回能力，模型只做 MOSI 侧的「16 位字解码状态机」：把驱动写下
-- 的帧还原成频率寄存器/相位寄存器/控制位，测试可直接读出 freq_hz()/wave()/
-- muted() 验证调谐字拼接（低 14 位在前的两段加载顺序反了立即暴露）。
--
-- 挂载（SPI 路径即片选身份）：
--   vbus.load_driver("modules/AD9833.lua")  -- 定义全局 build/call/destroy 与 AD9833_VIRT
--   local dds = AD9833_VIRT.new()           -- 默认 MCLK=25MHz（模块板载晶振）
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
-- =====================================================================

AD9833_VIRT = { _VERSION = "0.1.0", BUS = "spi" }

function AD9833_VIRT.new(opts)
	local DEFAULT_MCLK = 25000000
	local POW2_28 = 268435456

	-- 控制字位掩码
	local B_B28, B_HLB     = 0x2000, 0x1000
	local B_FSEL, B_PSEL   = 0x0800, 0x0400
	local B_RESET          = 0x0100
	local B_OPBITEN, B_DIV2, B_MODE = 0x0020, 0x0008, 0x0002

	-- 位运算：独立 dofile bitcompat（不经驱动的 bitc 局部量，保互证独立）；
	-- 失败退化为纯算术兜底（必须 Lua 5.1 语法，LuaJIT 解析期不认 &/|）。
	local band, bor
	local ok_bc, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
	if ok_bc then
		band, bor = bc.band, bc.bor
	end
	if not band then
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

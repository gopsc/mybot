-- AD9833 DDS 可编程波形发生器 驱动模块（SPI，写-only，信号源/激励输出）
-- bot4cj 仓颉语言机器人框架
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

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
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
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AD9833 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-- 列配置（缺省 1kHz / sine / 0°，MD_AD9833 同款缺省频率）；
	-- 全部校验通过后才落模块状态（失败半途不得污染跨 call 状态）
	local f = tonumber(data.freq) or 1000
	if f <= 0 or f > WAVE_MAX_F then
		return {
			result = "ERR",
			message = string.format("Invalid freq: %s (expect 0 < f <= %d Hz)",
				tostring(data.freq), WAVE_MAX_F)
		}
	end
	local wbits, wname = wave_bits_of(data.wave or "sine")
	if wbits == nil then
		return {
			result = "ERR",
			message = "Invalid wave: '" .. tostring(data.wave) .. "' (expect sine/triangle/square)"
		}
	end
	local d = tonumber(data.phase) or 0
	if d < 0 or d >= 360 then
		return {
			result = "ERR",
			message = "Invalid phase: " .. tostring(data.phase) .. " (expect 0 ~ 360)"
		}
	end
	freq_hz, wave_str, phase_deg = f, wname, d
	muted = false

	-----------------------------------------------------
	-- 复位静音 + B28
	if not send16(fd, bitc.bor(BIT_RESET, BIT_B28)) then
		return {
			result = "ERR",
			message = "Failed to send AD9833 control word"
		}
	end

	-- 频率字两段（低 14 位在前，B28 原子加载）
	local tw = tuning_word(freq_hz)
	if not send16(fd, SEL_FREQ0 + (tw % 0x4000)) then
		return {
			result = "ERR",
			message = "Failed to send AD9833 freq LSBs"
		}
	end
	if not send16(fd, SEL_FREQ0 + (math.floor(tw / 0x4000) % 0x4000)) then
		return {
			result = "ERR",
			message = "Failed to send AD9833 freq MSBs"
		}
	end

	-- 相位字
	if not send16(fd, SEL_PHASE + phase_word(phase_deg)) then
		return {
			result = "ERR",
			message = "Failed to send AD9833 phase word"
		}
	end

	-- 波形位 + 清 RESET，放行输出
	if not send16(fd, run_ctrl(wbits)) then
		return {
			result = "ERR",
			message = "Failed to send AD9833 waveform word"
		}
	end

	print(string.format("AD9833 init OK: freq=%.3fHz, wave=%s, phase=%g deg",
		freq_hz, wave_str, phase_deg))
	return {  result = "OK"  }

end

-- 【销毁AD9833】无资源需要释放（输出状态维持，总线归 SPI 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用AD9833】按需更新输出（键任意组合；无键仅回显状态不发字）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AD9833 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	-- mute：静音/放行（置/清 RESET 位）——立即下发控制字才生效
	local mute_v = tonumber(data.mute)
	if mute_v ~= nil then
		muted = (mute_v ~= 0)
		if not send16(fd, run_ctrl(WAVE_BITS[wave_str])) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 control word"
			}
		end
	end

	-- wave：波形位（组合控制字重发）
	if data.wave ~= nil then
		local wbits, wname = wave_bits_of(data.wave)
		if wbits == nil then
			return {
				result = "ERR",
				message = "Invalid wave: '" .. tostring(data.wave) .. "' (expect sine/triangle/square)"
			}
		end
		wave_str = wname
		if not send16(fd, run_ctrl(wbits)) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 waveform word"
			}
		end
	end

	-- freq：B28 + 两段频率字（不静音原子加载；静音态保持 RESET）
	if data.freq ~= nil then
		local f = tonumber(data.freq)
		if f == nil or f <= 0 or f > WAVE_MAX_F then
			return {
				result = "ERR",
				message = string.format("Invalid freq: %s (expect 0 < f <= %d Hz)",
					tostring(data.freq), WAVE_MAX_F)
			}
		end
		freq_hz = f
		local tw = tuning_word(freq_hz)
		-- B28 + 当前波形位（静音态保持 RESET）：两段频率字原子加载
		if not send16(fd, run_ctrl(WAVE_BITS[wave_str])) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 control word"
			}
		end
		if not send16(fd, SEL_FREQ0 + (tw % 0x4000)) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 freq LSBs"
			}
		end
		if not send16(fd, SEL_FREQ0 + (math.floor(tw / 0x4000) % 0x4000)) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 freq MSBs"
			}
		end
	end

	-- phase：相位字（12 位）
	if data.phase ~= nil then
		local d = tonumber(data.phase)
		if d == nil or d < 0 or d >= 360 then
			return {
				result = "ERR",
				message = "Invalid phase: " .. tostring(data.phase) .. " (expect 0 ~ 360)"
			}
		end
		phase_deg = d
		if not send16(fd, SEL_PHASE + phase_word(phase_deg)) then
			return {
				result = "ERR",
				message = "Failed to send AD9833 phase word"
			}
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

end

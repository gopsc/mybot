-- ads1015.lua —— TI ADS1015 12 位 4 通道 ADC 虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 【字寻址 16 位寄存器 + oneshot 转换门/OS 就绪握手器件】（骨架与 ads1115
-- 完全同族：寄存器号 0x00~0x03 各代表一个 16 位字，绝不能套字节地址 regmap）：
--   0x00 CONVERSION  转换结果，12 位有符号码【左对齐】放 16 位——低 4 位恒 0，
--                    驱动读出后算术右移 4 位（sign_extend(raw>>4,11)）；
--                    有效码 -2048~2047（单端正满 2047）。这是与 ADS1115
--                    （16 位直接编码、±32768）唯一的数据面差异
--   0x01 CONFIG      [15]OS [14:12]MUX [11:9]PGA [8]MODE [7:5]DR [4:0]比较器
--   0x02 LO_THRESH / 0x03 HI_THRESH（驱动不用，POR 0x8000/0x7FFF，照读照写）
--
-- 位布局与 ADS1115 相同，故 build 默认字同为 0x4583（MUX=AIN0/PGA=2/
-- MODE=1/DR 位=100/CQUE=11）——但 DR 位 100 在 ADS1015 是 1600SPS
-- （ADS1115 是 128SPS）。数据率表（内核 ti-ads1015 IIO）：
-- 128/250/490/920/1600/2400/3300/3300 SPS（110/111 同 3300），单次转换
-- 周期精确取 1000/SPS：7.8125/4/2.0408/1.0870/0.625/0.4167/0.3030/0.3030ms
-- （独立于驱动 1ms 步进轮询，别抄 ceil 预算）。
--
-- OS 位是模型核心（datasheet 8.6.3）：写 1 在单次模式（MODE=1）下=启动一次
-- 转换；读语义与写相反——转换中读 0、空闲/完成读 1。故 OS 位不能静态落盘：
-- shadow 保存驱动写入值，读 CONFIG 时 bit15 按转换状态机【动态合成】。
-- 转换完成瞬间把当前 MUX 通道的注入 12 位码左移 4 位装入 CONVERSION。
-- 连续模式（MODE=0）OS 位读恒 0、结果立即可用（驱动不用，仅协议完整性）。
--
-- 守护不驱动虚拟时钟（不注 milli_sleep 桩），靠 virt_tick 的【预武装】：
-- 每拍 virt_tick(n) 注入该拍电压并置 armed——下一次 OS=1 启动写立即完成
-- （首读 OS 即 1、结果已装载），驱动 1ms 轮询零真实睡眠；armed 一次性，
-- 启动写时消费。未武装的测试路径走真实 remaining/advance 节拍。
--
-- 用法：
--   local m = dofile("modules/lib/virtbus/ads1015.lua")
--   local dev = m.new()                    -- POR CONFIG 0x8583、阈值 0x8000/0x7FFF
--   dev:set_single(0, 1.5, 2)              -- AIN0 注入 1.5V（PGA=2 即 ±2.048V）
--   vbus.attach("ADS1015@0x48", 0x48, dev)
--
--   dev:set_never_ready(true)  -- 转换卡死，喂驱动 100 次 1ms 轮询超时
--   dev.nack_read = true       -- 定向故障
--
-- 【边界约定】模型只固化字寻址布局/位域/OS 读写相反语义/12 位左对齐/转换
-- 周期；V=raw12*FS/2048 换算归驱动，物理量注入 API 的 PGA 常量仅造样本，
-- 测试另做独立换算交叉，避免模型与驱动共用一份理解互证假绿。

local ads1015 = {}
ads1015._VERSION = "0.1.0"

ads1015.REG = {
	CONVERSION = 0x00,
	CONFIG     = 0x01,
	LO_THRESH  = 0x02,
	HI_THRESH  = 0x03,
}

ads1015.POR_CONFIG = 0x8583		-- OS=1 MUX=100 PGA=010 MODE=1 DR=100 CQUE=11（DR=100→1600SPS）
ads1015.POR_LO     = 0x8000
ads1015.POR_HI     = 0x7FFF

-- PGA 增益 → 满量程（V）；索引 6/7 为 datasheet 冗余编码，同 5（±0.256V）
ads1015.PGA_FS = { [0] = 6.144, 4.096, 2.048, 1.024, 0.512, 0.256 }
-- 数据速率 SPS（Linux 内核 ti-ads1015 IIO 表；110/111 同为 3300）
ads1015.DR_SPS = { [0] = 128, 250, 490, 920, 1600, 2400, 3300, 3300 }
-- 精确单次转换周期 1000/SPS（独立于驱动 1ms 轮询，别抄驱动预算）
ads1015.CONV_MS = { [0] = 1000/128, [1] = 1000/250, [2] = 1000/490, [3] = 1000/920,
                    [4] = 1000/1600, [5] = 1000/2400, [6] = 1000/3300, [7] = 1000/3300 }

local OS_BIT   = 0x8000
local MODE_BIT = 0x0100

local function clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- 12 位有符号码 → 16 位左对齐存储（低 4 位恒 0）
local function encode12(raw)
	local v = clampi(math.floor(raw + 0.5), -2048, 2047)
	return (v % 4096) * 16
end

-- 16 位左对齐存储 → 12 位有符号码（算术右移 4，与驱动 raw12_of 同源事实）
local function decode12(raw16)
	return math.floor((raw16 >= 0x8000 and raw16 - 0x10000 or raw16) / 16)
end

function ads1015.new(opts)
	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~3）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local shadow				-- CONFIG 驱动写入值（含 OS 写位，读时动态合成 bit15）
	local remaining				-- oneshot 转换剩余 ms；nil=空闲
	local active_mux = 4		-- 最近一次启动转换的 MUX（POR MUX=100=AIN0）
	local results = {}			-- mux(0~7) → s12 注入码
	local armed = false			-- 预武装：下次启动立即完成（守护零睡眠）
	local never_ready = false	-- 卡死：转换永不完成（喂轮询超时）
	local start_count = 0
	local write_pred, read_pred
	d.write_log = {}

	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ads1015.REG.CONVERSION] = 0	-- 左对齐零码（低 4 位 0）
		regs[ads1015.REG.LO_THRESH]  = ads1015.POR_LO
		regs[ads1015.REG.HI_THRESH]  = ads1015.POR_HI
		shadow = ads1015.POR_CONFIG
		remaining = nil
		active_mux = 4
		start_count = 0
		armed = false
		ptr = 0
	end
	reseed()

	-- 转换完成：把启动时 MUX 通道的注入码【左对齐】装入 CONVERSION
	local function finish_conv()
		regs[ads1015.REG.CONVERSION] = encode12(results[active_mux] or 0)
		remaining = nil
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- CONFIG 读回字：bit15 按状态动态合成（OS 读写语义相反）
	local function config_read_word()
		local w = shadow % 0x8000			-- 落盘的低 15 位
		if (math.floor(shadow / MODE_BIT) % 2) == 0 then
			return w						-- 连续模式：OS 位读恒 0
		end
		if remaining == nil then return w + OS_BIT end	-- 单次空闲/完成：OS=1
		return w							-- 单次转换中：OS=0
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 恰 1 字节 {reg}=纯指针写；恰 3 字节 {reg,hi,lo}=字写；其余 NACK
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		if p > 0x03 then return false end
		ptr = p
		if #bytes == 1 then return true end

		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p ~= ads1015.REG.CONFIG then
			regs[p] = word
			return true
		end

		-- CONFIG 写：shadow 落全字（含 OS 写位），按 OS/MODE 驱动状态机
		shadow = word
		local os_bit   = word >= OS_BIT
		local single   = (math.floor(word / MODE_BIT) % 2) == 1
		local mux      = math.floor(word / 0x1000) % 8
		local dr       = math.floor(word / 32) % 8
		if single then
			-- 单次模式：OS=0 无作用（不启动）；OS=1 启动一次转换
			if os_bit then
				start_count = start_count + 1
				active_mux = mux
				if armed and not never_ready then
					armed = false			-- 武装一次性消费
					finish_conv()			-- 启动即完成（守护零睡眠）
				else
					remaining = ads1015.CONV_MS[dr]
				end
			end
		else
			-- 连续模式：OS 写位忽略，持续转换，结果立即可用
			active_mux = mux
			finish_conv()
		end
		return true
	end

	-- 读 n 字节：从当前指针字取 hi/lo；n>2 按字自增续读、奇数尾补 0
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local idx = p + math.floor((i - 1) / 2)
			local word = idx == ads1015.REG.CONFIG and config_read_word()
			        or (regs[idx] or 0)
			out[i] = (i % 2 == 1) and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- 按 MUX 码注入 12 位有符号转换结果：0~3 差分对，4~7 单端 AIN0~3。
	-- 只入注入表——CONVERSION 寄存器仅由「转换完成」事件改变（oneshot
	-- finish_conv / 连续写 CONFIG），空闲注入不得提前出现在结果寄存器。
	function d:set_result(mux, raw)
		results[clampi(math.floor(mux), 0, 7)] =
			clampi(math.floor(raw + 0.5), -2048, 2047)
		return self
	end

	-- ---------------- 物理量造样本（PGA 常量仅造样本，与驱动独立） ----------------

	-- 单端通道 ch(0~3) 注入电压 V，pga 为 PGA 索引（缺省 2=±2.048V）
	function d:set_single(ch, v, pga)
		local fs = ads1015.PGA_FS[clampi(tonumber(pga) or 2, 0, 5)]
		return self:set_result(4 + clampi(math.floor(ch), 0, 3),
		                       math.floor(v * 2048 / fs + 0.5))
	end

	-- 差分注入：mux 0~3（0=AIN0-AIN1,1=AIN0-AIN3,2=AIN1-AIN3,3=AIN2-AIN3）
	function d:set_diff(mux, v, pga)
		local fs = ads1015.PGA_FS[clampi(tonumber(pga) or 2, 0, 5)]
		return self:set_result(clampi(math.floor(mux), 0, 3),
		                       math.floor(v * 2048 / fs + 0.5))
	end

	-- ---------------- 虚拟时钟 / 守护节拍 ----------------

	-- 推进转换时钟 ms（测试 milli_sleep 桩转调；守护不调）
	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil and not never_ready then
			remaining = remaining - ms
			if remaining <= 0 then finish_conv() end
		end
		return self
	end

	-- 32 拍确定性正弦造样本：AIN0 单端 1.65 ± 0.25V（1.40~1.90V，PGA=2
	-- ±2.048V 量程内），同时预武装——守护本拍随后的 call 启动转换首读即就绪，
	-- 1ms 轮询零真实睡眠。无随机，E2E 数值可复现。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local v = 1.65 + 0.25 * math.sin(n * (2 * math.pi / 32))
		self:set_single(0, v, 2)
		armed = true
		return self
	end

	-- ---------------- 故障/留痕/复位 ----------------

	-- 转换卡死：启动后 OS 恒读 0、advance 不推进（喂驱动 100ms 超时），
	-- 且武装无效
	function d:set_never_ready(on) never_ready = on ~= false; return self end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		never_ready = false
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs() self.write_log = {}; return self end

	-- 回 POR 态（保留故障钩子，与全系列约定一致）
	function d:reset()
		reseed()
		self.write_log = {}
		return self
	end

	-- 驱动写过的字写事务（write_log 中恰 3 字节）：{reg,hi,lo,word}
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

	-- ---------------- 观察口 ----------------

	function d:pointer() return ptr end
	function d:busy() return remaining ~= nil end
	function d:remaining_ms() return remaining end
	function d:start_count() return start_count end
	function d:active_mux() return active_mux end
	function d:armed() return armed end
	function d:config_shadow() return shadow end	-- 驱动写入的原字（含 OS 写位）
	function d:config() return config_read_word() end	-- 读回字（OS 动态合成）
	-- CONVERSION 的 16 位左对齐原字（低 4 位恒 0）
	function d:conversion_word() return regs[ads1015.REG.CONVERSION] or 0 end
	-- CONVERSION 解码后的 12 位有符号码（驱动口径）
	function d:conversion_raw() return decode12(regs[ads1015.REG.CONVERSION] or 0) end
	function d:lo_thresh() return regs[ads1015.REG.LO_THRESH] end
	function d:hi_thresh() return regs[ads1015.REG.HI_THRESH] end
	-- 注入码反推电压（观察用，pga 缺省回读 shadow 的 PGA 字段，6/7→5）
	function d:voltage(mux, pga)
		local pi = pga or (math.floor(shadow / 512) % 8)
		if pi > 5 then pi = 5 end
		local raw = results[clampi(tonumber(mux) or active_mux, 0, 7)] or 0
		return raw * ads1015.PGA_FS[pi] / 2048
	end

	return d
end

return ads1015

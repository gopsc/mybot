-- virtbus/ads1256.lua —— ADS1256 24bit ΣΔ ADC 的虚拟 SPI 器件模型
-- bot4cj 仓颉语言机器人框架
--
-- 对应真实驱动 modules/ADS1256.lua（SPI Mode 1）。协议只建模到驱动实际用到的
-- 事实层：命令字节、WREG/RREG 寄存器访问、RDATAC 连续读模式下的 24bit 样本帧；
-- 电压换算（raw*2*VREF/2^23/PGA）只存在于真实驱动，本模型给有符号原始码。
--
-- 挂载（SPI 路径即片选身份）：
--   local ads = dofile("modules/lib/virtbus/ads1256.lua")
--   local dev = ads.new()
--   vbus.attach_spi("ADS1256", "/dev/spidev0.0", dev)
--
-- 驱动事务形态（一次 HAL 传输 = 一个 CS 帧，全双工）：
--   build: [FE]RESET [00]WAKEUP [50 00 14]WREG STATUS [51 00 mux]WREG MUX
--          [52 00 pga]WREG ADCON [53 00 drate]WREG DRATE [F0]SELFCAL [03]RDATAC
--   call : [0F]SDATAC [51 00 mux]WREG MUX [FC]SYNC [00]WAKEUP [03]RDATAC
--          然后一帧 4 个 dummy 字节，MISO 前 3 字节为 24bit 样本（MSB 优先），
--          第 4 字节被驱动丢弃（rshift 8）；destroy: [0F]SDATAC
--
-- 模型不模拟 DRDY 引脚时序（驱动只按 drate sleep，不轮询引脚），样本在 RDATAC
-- 模式下随时可读；milli_sleep 由测试桩累计推进，无需虚拟时钟参与读就绪。
local bitc = nil
-- bitcompat 在测试进程与守护 lua_State 都可经 modules 路径拿到；失败则退化为
-- 纯算术（模型只用到 band/bor/shift，用内置位运算的 Lua 5.4 环境下 bitc 缺失时
-- 走下面的 fallback 函数）。
local ok_bc, mpath = pcall(dofile, "modules/lib/mpath.lua")
if ok_bc then
	local ok2, mod = pcall(dofile, mpath.resolve("bitcompat.lua"))
	if ok2 then bitc = mod end
end
local band, bor, lshift, rshift
if bitc then
	band, bor, lshift, rshift = bitc.band, bitc.bor, bitc.lshift, bitc.rshift
else
	-- 理论兜底（本仓库测试/守护均能加载 bitcompat）：必须用 Lua 5.1 语法，
	-- 不能写 &/|/<<（LuaJIT 解析期即报错，即使分支不执行）。
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
	band = b_and
	bor = b_or
	lshift = function(a, n) return a * 2 ^ n end
	rshift = function(a, n) return math.floor(a / 2 ^ n) end
end

local ads = {}
ads.BUS = "spi"		-- 供 sensor_daemon proto=virt 区分 I2C/SPI 挂载路径
local unpack = table.unpack or unpack	-- LuaJIT 全局 / Lua5.4 table.unpack

-- ==================== 命令 / 寄存器（与驱动一致）====================
local CMD_WAKEUP  = 0x00
local CMD_RDATA   = 0x01
local CMD_RDATAC  = 0x03
local CMD_SDATAC  = 0x0F
local CMD_RREG    = 0x10
local CMD_WREG    = 0x50
local CMD_SELFCAL = 0xF0
local CMD_SYNC    = 0xFC
local CMD_RESET   = 0xFE

local REG_STATUS, REG_MUX, REG_ADCON, REG_DRATE = 0x00, 0x01, 0x02, 0x03

-- DRATE 寄存器值 → SPS（与驱动 drate_tab 同一张表；模型据此回读速率）
local DRATE_SPS = {
	[0xF0] = 30000, [0xE0] = 15000, [0xD0] = 7500,  [0xC0] = 3750,
	[0xB0] = 2000,  [0xA0] = 1000,  [0x90] = 500,   [0x80] = 100,
	[0x70] = 60,    [0x60] = 50,    [0x50] = 30,    [0x40] = 25,
	[0x30] = 15,    [0x20] = 10,    [0x10] = 5,
}
local PGA_GAIN = { 1, 2, 4, 8, 16, 32, 64 }
local VREF = 2.5	-- 仅 set_voltage 便捷 API 用，常量必须与驱动一致

local RAW_MIN, RAW_MAX = -0x800000, 0x7FFFFF

function ads.new(opts)
	opts = opts or {}
	local self = {}

	-- ---- 器件状态 ----
	-- 寄存器初值：驱动不读 STATUS，MUX/ADCON/DRATE 在 build 必写；
	-- 这里只给自洽的复位级初值（不声称是未经驱动验证的硬件事实）。
	local regs = { [0] = 0x01, [1] = 0x01, [2] = 0x00, [3] = 0x00 }
	local datac = false		-- RDATAC 连续读模式
	local raw_u = 0			-- 当前样本（24bit 无符号）
	local clock_ms = 0		-- 虚拟时钟（milli_sleep 桩经 advance 推进）
	local cmds = {}			-- 解析出的命令流水：{name=, bytes=}
	local reg_writes = {}	-- WREG 流水：{reg=, val=}
	local pending_rreg = nil -- RREG 命令后待回填的 {next_reg=, left=}
	local pending_rdata = false -- RDATA 单次模式下一帧 dummy 出数

	-- 故障注入
	local fail_pred = nil	-- function(tx) → true 则本帧传输失败（返 nil）
	local data_fail = false -- 下一帧/持续的数据帧失败

	-- ===================== 样本注入 API =====================

	-- 注入有符号 24bit 原始码（量化为整数并 clamp 到 -2^23..2^23-1）。
	-- 主测试输入用这个；必须 floor，否则 set_voltage 反解的浮点码会让
	-- virt_tick 周期点（如 sin(2π)≈-2e-16 的尾巴）读不回同一整数。
	function self:set_raw(v)
		v = math.floor(tonumber(v) or 0)
		if v < RAW_MIN then v = RAW_MIN elseif v > RAW_MAX then v = RAW_MAX end
		raw_u = (v < 0) and (v + 0x1000000) or v
		return self
	end

	-- 读回当前有符号原始码
	function self:raw()
		return raw_u >= 0x800000 and raw_u - 0x1000000 or raw_u
	end

	-- 便捷 API（守护/E2E 造样本）：按物理电压反推原始码。
	-- 驱动换算 voltage = raw * 2 * VREF / 2^23 / gain，反解之。
	-- pga_idx 与驱动 pga 参数同义（0~6）；默认 ×1。
	function self:set_voltage(v, pga_idx)
		v = tonumber(v) or 0
		local gain = PGA_GAIN[(tonumber(pga_idx) or 0) + 1] or 1
		self:set_raw(v * 0x800000 / (2 * VREF) * gain)
		return self
	end

	-- ===================== 状态/留痕 API =====================

	function self:advance(ms)
		clock_ms = clock_ms + (tonumber(ms) or 0)
		return self
	end
	function self:clock() return clock_ms end
	function self:in_datac() return datac end

	-- 当前配置（寄存器解码）
	function self:config()
		local mux = regs[REG_MUX]
		return {
			status = regs[REG_STATUS],
			mux = mux,
			adcon = regs[REG_ADCON],
			drate = regs[REG_DRATE],
			sps = DRATE_SPS[band(regs[REG_DRATE], 0xF0)],
			pga_idx = band(regs[REG_ADCON], 0x07),
			gain = PGA_GAIN[band(regs[REG_ADCON], 0x07) + 1],
			-- MUX：低 4 位 0x08=AINCOM 表示单端；否则差分 (pos,neg)
			single = band(mux, 0x0F) == 0x08,
			channel = rshift(mux, 4),
			pos = rshift(mux, 4),
			neg = band(mux, 0x0F),
		}
	end

	function self:cmd_log() return cmds end
	function self:reg_writes() return reg_writes end
	function self:reset_logs()
		cmds, reg_writes = {}, {}
		return self
	end

	-- 状态机复位（等价硬件 RESET 命令，也供测试 section 重置）。
	-- 注意：不清 fail_pred/data_fail——故障注入是测试侧钩子，硬件 RESET
	-- 语义上也不可能「修复」总线故障；若让 RESET 清钩子，build 失败路径
	-- 里第一帧 RESET 会把后续命令的故障条件一并解除，负路径全假绿。
	function self:reset()
		regs = { [0] = 0x01, [1] = 0x01, [2] = 0x00, [3] = 0x00 }
		datac = false
		pending_rreg, pending_rdata = nil, false
		raw_u = 0
		clock_ms = 0
		cmds, reg_writes = {}, {}
		return self
	end

	-- ---- 故障注入钩子 ----
	-- pred(tx 字节表) 返回 true 的帧一律传输失败（xfer 返 nil，HAL 传输族返 -1）
	function self:fail_when(pred) fail_pred = pred; return self end
	function self:fail_data(on) data_fail = (on ~= false); return self end
	function self:clear_fail() fail_pred, data_fail = nil, false; return self end

	-- ===================== 全双工帧核心 =====================

	local function log_cmd(name, tx, i, consumed)
		cmds[#cmds + 1] = { name = name, bytes = { unpack(tx, i, i + consumed - 1) } }
	end

	-- 组装一帧样本：[MSB, mid, LSB, 丢弃字节]；驱动只读前 3 字节，第 4 给 0。
	local function sample_frame(n)
		local t = {
			band(rshift(raw_u, 16), 0xFF),
			band(rshift(raw_u, 8), 0xFF),
			band(raw_u, 0xFF),
		}
		while #t < n do t[#t + 1] = 0 end
		return t
	end

	-- xfer(tx)：点定义、无 self 参数（virtbus attach 动态委托契约）。
	-- 逐字节状态机解析一帧内可能合并的多字节命令（WREG/RREG 为 2+ 字节）。
	local function xfer(tx)
		if type(fail_pred) == "function" and fail_pred(tx) then return nil end
		local n = #tx
		local rx = {}
		for i = 1, n do rx[i] = 0 end

		-- RDATAC 数据帧：模式内整帧 dummy（MOSI 全 0，真机 tx_buf=NULL/读命令流）
		-- 且长度 ≥3（WAKEUP 单字节 0x00 不会出现在 datac 内，长度也不同）。
		if datac then
			local allzero = true
			for i = 1, n do if tx[i] ~= 0 then allzero = false break end end
			if allzero and n >= 3 then
				if data_fail then return nil end
				return sample_frame(n)
			end
		end

		local i = 1
		while i <= n do
			local b = tx[i]
			-- pending 的 RREG/RDATA 读窗口优先：窗口内 MOSI 是 dummy（任意值，
			-- 0x00 也不能再当 WAKEUP 解释），MISO 回填寄存器/样本。
			-- 真实芯片 RREG 命令帧后隔 t6 才进入读窗口，模型把「命令之后的
			-- 后续 dummy 字节」当作窗口（驱动当前不用 RREG，时序近似无害）。
			if pending_rreg ~= nil and pending_rreg.left > 0 then
				rx[i] = regs[pending_rreg.next_reg] or 0
				pending_rreg.next_reg = pending_rreg.next_reg + 1
				pending_rreg.left = pending_rreg.left - 1
				if pending_rreg.left == 0 then pending_rreg = nil end
				i = i + 1
			elseif pending_rdata then
				local f = sample_frame(n - i + 1)
				for k = 1, #f do rx[i + k - 1] = f[k] end
				pending_rdata = false
				break
			elseif b == CMD_RESET then
				self.reset()
				-- reset 已清 cmds；本命令自身重新记一条
				cmds[#cmds + 1] = { name = "RESET", bytes = { b } }
				rx[i] = 0xFF
				i = i + 1
			elseif b == CMD_WAKEUP then
				cmds[#cmds + 1] = { name = "WAKEUP", bytes = { b } }; i = i + 1
			elseif b == CMD_RDATAC then
				datac = true
				cmds[#cmds + 1] = { name = "RDATAC", bytes = { b } }; i = i + 1
			elseif b == CMD_SDATAC then
				datac = false
				cmds[#cmds + 1] = { name = "SDATAC", bytes = { b } }; i = i + 1
			elseif b == CMD_SYNC then
				cmds[#cmds + 1] = { name = "SYNC", bytes = { b } }; i = i + 1
			elseif b == CMD_SELFCAL then
				cmds[#cmds + 1] = { name = "SELFCAL", bytes = { b } }; i = i + 1
			elseif b == CMD_RDATA then
				pending_rdata = true
				cmds[#cmds + 1] = { name = "RDATA", bytes = { b } }; i = i + 1
			elseif band(b, 0xF0) == CMD_WREG then
				-- WREG：[0x50|reg, count, data1..]（驱动恒 count=0 单寄存器，
				-- 一次 write3 一帧发完；模型仍按 count 支持多寄存器）
				local reg = band(b, 0x0F)
				local cnt = tx[i + 1] or 0
				local how = 2 + cnt + 1
				for k = 1, cnt + 1 do
					local val = tx[i + 1 + k]
					if val ~= nil then
						regs[reg + k - 1] = val
						reg_writes[#reg_writes + 1] = { reg = reg + k - 1, val = val }
					end
				end
				cmds[#cmds + 1] = {
					name = "WREG", bytes = { unpack(tx, i, math.min(i + how - 1, n)) },
				}
				i = i + how
			elseif band(b, 0xF0) == CMD_RREG then
				-- RREG：[0x10|reg, count]，随后 dummy 读帧回填寄存器值。
				-- 真实硬件命令帧与数据帧之间隔 t6；模型在「后续 dummy 字节」回填，
				-- 驱动当前不用 RREG（build/call 无寄存器回读），此处仅保证协议完整。
				pending_rreg = { next_reg = band(b, 0x0F), left = (tx[i + 1] or 0) + 1 }
				cmds[#cmds + 1] = { name = "RREG", bytes = { b, tx[i + 1] or 0 } }
				i = i + 2
			else
				-- 未识别命令字节：MISO 保持 0
				i = i + 1
			end
		end
		return rx
	end
	self.xfer = xfer

	-- ===================== 守护节拍（确定性合成波形）====================
	-- 以 PGA=×1（±5V 量程）为基准：中心 1.25V、幅度 1.0V、32 拍周期的正弦，
	-- 确定无随机；守护 build 默认 channel=0/pga=0，与 set_voltage 的 gain 一致。
	-- 无需预武装/就绪态：样本随时可读（驱动只 sleep 不轮询 DRDY）。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local m = n % 32 -- 周期归一拍号
		-- 周期零点特判：sin(2π) 浮点尾巴（≈-2e-16）经 set_raw floor 量化后
		-- 会让第 32 拍与第 0 拍差 1 LSB，破坏「32 拍严格重复」的确定性。
		local s = (m == 0) and 0 or math.sin(2 * math.pi * m / 32)
		local v = 1.25 + 1.0 * s
		self:set_voltage(v, 0)
		return self
	end

	return self
end

return ads

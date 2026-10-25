-- modules/lib/virtbus/max30102.lua —— MAX30102 心率/血氧 PPG 传感器虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个「环形 FIFO + 读写指针/溢出计数 + rollover + 18 位样本块读」
-- I2C 器件】（Maxim MAX30102，地址固定 0x57；纯闭包、纯算术无 bitcompat）。
-- 寄存器是普通 8 位指针（i2c_read_reg = 写 1B 指针 + 读 1B；i2c_read_multi
-- = 写指针 + 连续读 nB），核心协议事实全在 FIFO 状态机：
--
--   1) 三个 5 位 FIFO 指针（0x04 WR / 0x05 OVF / 0x06 RD，均可写——build 写 0
--      清队列），32 深环形缓冲，可用样本数 = (WR-RD) mod 32（0 既可能是空也
--      可能是满，满状态靠 OVF/物理槽位区分；驱动纯轮询不使能中断，积压整圈
--      后指针差回绕、avail 被低估为 0 是真实硬件行为）。
--   2) FIFO_DATA 0x07 是流式数据口：读自动步进内部字节位置；HR 模式（MODE=2）
--      每样本 3 字节（仅 RED），SpO2 模式（MODE=3）每样本 6 字节（RED+IR）；
--      读满一个样本的全部字节 FIFO_RD_PTR 才硬件自增，半样本事务结束后重新
--      寻址 0x07 仍从同一槽位读起。空 FIFO 读返回 0x00 且 RD 不动。
--   3) 每通道 18 位样本 MSB 对齐在 3 字节帧里（低 6 位恒 0）：
--      b0=[17:10] b1=[9:2] b2[7:6]=[1:0]，即 24 位帧 = sample<<6；
--      驱动解码 red=b0*1024+b1*4+floor(b2/64)。满码 0x3FFFF=262143 即 SAT。
--   4) FIFO_CFG 0x08 = SMP_AVE[6:4] | ROLLOVER_EN[3] | A_FULL[3:0]：rollover
--      关（POR）时满 32 后新样本丢弃、OVF_COUNTER++（饱和 31）、WR 停住；
--      rollover 开（驱动 build 固定置 bit3）时新样本覆盖最旧槽并把 RD 自动推
--      进、OVF 不增。SPO2_CFG 0x0A = ADC_RGE[6:5] | SR[4:2] | PW[1:0]；
--      有效输出样本周期 = 1000×2^SMP_AVE / SR 毫秒（SR 码 50~3200sps）。
--   5) MODE 0x09 = SHDN[7] | RESET[6] | MODE[2:0]（2=HR 3=SpO2）：RESET 位
--      自清除不落盘，写后全部寄存器回 POR、FIFO/指针清空（约 1ms，驱动实睡
--      5ms）；SHDN 位置 1 停采样（配置保留）；写有效模式即启动，首个样本在
--      一个输出周期后才可用——advance(ms) 按周期向 FIFO 产样（测试 wait
--      轮询的 milli_sleep 桩转调它），virt_tick 则直接推入一拍合成样本
--      （守护每拍先 tick 后 call，FIFO 恒有新鲜样本、零真实睡眠）。
--   6) PART_ID 0xFF 固定 0x15（build 先读它在位甄别，再 RESET）；温度
--      0x1F/0x20 与中断寄存器真实驱动不访问，本模型只照存照读 0，不实现。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")

local M = {}
M._VERSION = "0.1.0"

-- ==================== 寄存器地址 ====================
local REG_WR, REG_OVF, REG_RD, REG_DATA = 0x04, 0x05, 0x06, 0x07
local REG_FCFG, REG_MODE, REG_SPO2 = 0x08, 0x09, 0x0A
local REG_LED1, REG_LED2, REG_PART = 0x0C, 0x0D, 0xFF

local PART_ID = 0x15
local BIT_SHDN, BIT_RESET = 0x80, 0x40
local DEPTH = 32				-- FIFO 样本深度
local FULL = 0x3FFFF			-- 18 位满码（SAT 特征）
local MODE_HR, MODE_SPO2 = 0x02, 0x03

-- SR[4:2] 编码 -> 采样率 sps
local SPS = { 50, 100, 200, 400, 800, 1000, 1600, 3200 }

-- virt_tick 确定性 PPG 正弦（计数，远低于 0x3FFFF 满码，SAT 恒 0）
local TICK_RED_BASE, TICK_RED_AMP = 50000, 18000	-- n0=50000 n8=68000 n24=32000
local TICK_IR_BASE,  TICK_IR_AMP  = 60000, 22000	-- n0=60000 n8=82000 n24=38000

local function clamp18(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > FULL then return FULL else return v end
end

-- 确定性 PPG 波形（32 拍周期）：RED/IR 原始计数
local function wave(n)
	n = (math.floor(tonumber(n) or 0)) % 32
	local ph = 2 * math.pi * n / 32
	return clamp18(TICK_RED_BASE + TICK_RED_AMP * math.sin(ph)),
	       clamp18(TICK_IR_BASE  + TICK_IR_AMP  * math.sin(ph))
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 普通寄存器影子（稀疏，缺省读 0）
	local slots = {}			-- FIFO 环形槽 [0..31] = {r=red, i=ir}（HR 无 i）
	local wr, rd, ovf = 0, 0, 0	-- 三个 5 位指针
	local count = 0				-- 物理占用槽数（区分空/满，avail 给驱动公式值）
	local byte_idx = 0			-- 当前样本内已读字节位置（0..size-1）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此分派）
	local remaining = nil		-- 自动采样：距下一个产出的 ms（nil=未启动/停采）
	local produced = 0			-- 启动后自动产出的样本总数（波形相位）
	local reset_count = 0		-- RESET 位次数
	local part_id = PART_ID
	local prod_queue = {}		-- advance 自动产出时优先注入的样本队列

	-- 故障钩子（硬件 RESET 保留，clear_faults/d:reset 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_sample = false	-- advance 不自动产出（喂驱动 wait 耗尽路径）

	-- ---------------- 派生 ----------------

	local function sample_size()
		return (regs[REG_MODE] % 8) == MODE_HR and 3 or 6
	end
	local function is_spo2() return sample_size() == 6 end
	local function mode_bits() return regs[REG_MODE] % 8 end
	local function shdn_on() return math.floor(regs[REG_MODE] / 128) % 2 == 1 end
	local function active()
		local m = mode_bits()
		return (m == MODE_HR or m == MODE_SPO2) and not shdn_on()
	end
	local function rollover_on() return math.floor(regs[REG_FCFG] / 8) % 2 == 1 end
	local function avg_code() return math.floor(regs[REG_FCFG] / 16) % 8 end
	local function rate_code() return math.floor(regs[REG_SPO2] / 4) % 8 end
	-- 有效输出周期：SMP_AVE 个 SR 样本平均成 1 个 FIFO 输出
	local function period_ms()
		return 1000 * 2 ^ avg_code() / SPS[rate_code() + 1]
	end

	-- ---------------- FIFO 入队/出字节 ----------------

	-- 样本入队（按当前模式：HR 3B 仅 RED，SpO2 6B RED+IR）。
	-- rollover 关且满：新样本丢弃、OVF++（饱和 31）、WR 停住；
	-- rollover 开且满：覆盖最旧槽（=WR 位置），WR/RD 同进、OVF 不增。
	local function push_raw(red, ir)
		red = clamp18(red)
		local s = { r = red }
		if is_spo2() then s.i = clamp18(ir or 0) end
		if count >= DEPTH then
			if rollover_on() then
				slots[rd] = nil
				rd = (rd + 1) % DEPTH
				count = count - 1	-- 覆盖最旧：逻辑占用减一，下面再计入新样本
			else
				ovf = math.min(ovf + 1, 31)
				return false
			end
		end
		slots[wr] = s
		wr = (wr + 1) % DEPTH
		count = count + 1
		return true
	end

	-- FIFO_DATA 流式取下一字节；样本字节读满后 RD 硬件自增、槽位释放。
	-- 空槽读返回 0 且 RD/字节位置不动（datasheet 空读 FIFO_DATA = 0x00）。
	local function next_byte()
		local s = slots[rd]
		if s == nil then return 0 end
		local size, b
		if byte_idx < 3 then
			local v = s.r
			if byte_idx == 0 then b = math.floor(v / 1024) % 256
			elseif byte_idx == 1 then b = math.floor(v / 4) % 256
			else b = (v % 4) * 64 end
		else
			size = 6
			local v = s.i or 0
			local j = byte_idx - 3
			if j == 0 then b = math.floor(v / 1024) % 256
			elseif j == 1 then b = math.floor(v / 4) % 256
			else b = (v % 4) * 64 end
		end
		size = size or sample_size()
		byte_idx = byte_idx + 1
		if byte_idx >= size then
			slots[rd] = nil
			rd = (rd + 1) % DEPTH
			count = count - 1
			byte_idx = 0
		end
		return b
	end

	-- 自动采样产出一拍：注入队列优先，否则确定性 PPG 正弦
	local function produce_one()
		local red, ir
		local q = table.remove(prod_queue, 1)
		if type(q) == "table" then
			red, ir = q.red or q.r, q.ir or q.i
		else
			red, ir = wave(produced)
		end
		produced = produced + 1
		push_raw(red, ir)			-- 满丢弃也占一个产出周期
	end

	-- ---------------- POR / RESET ----------------

	local function seed_regs()
		regs = {}
		regs[REG_FCFG] = 0x00		-- POR：rollover 关、SMP_AVE=0、A_FULL=0
		regs[REG_MODE] = 0x00
		regs[REG_SPO2] = 0x00
		regs[REG_LED1] = 0x00
		regs[REG_LED2] = 0x00
	end

	local function fifo_clear()
		for k in pairs(slots) do slots[k] = nil end
		wr, rd, ovf, count, byte_idx = 0, 0, 0, 0, 0
	end

	-- RESET 位：寄存器回 POR、FIFO/指针/采样态全清；
	-- part_id/注入队列/故障钩子保留（硬件复位不清激励、防负路径假解除）
	local function reseed()
		seed_regs()
		fifo_clear()
		read_ptr = nil
		remaining, produced = nil, 0
	end

	seed_regs()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 or nb > 2 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）
			if bytes[1] > 0xFF then return false end
			read_ptr = bytes[1]
			if read_ptr == REG_DATA then byte_idx = 0 end
			return true
		end
		local reg, val = bytes[1], bytes[2] % 256
		-- RESET 位自清除：回 POR 且该位不落盘（同写其他位忽略）
		if reg == REG_MODE and math.floor(val / 64) % 2 == 1 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		if reg == REG_WR then
			wr = val % DEPTH			-- 5 位指针（DEPTH=32=2^5，取模即掩低 5 位）
		elseif reg == REG_OVF then
			ovf = val % DEPTH
		elseif reg == REG_RD then
			rd = val % DEPTH
			byte_idx = 0
		elseif reg == REG_DATA then
			-- FIFO_DATA 只读：写忽略（ACK，不改任何状态）
		else
			regs[reg] = val
		end
		if reg == REG_MODE then
			-- 写有效模式即（重新）启动采样；SHDN/非采样模式停转
			if active() then remaining = period_ms() else remaining = nil end
		end
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_ptr == nil then return nil end	-- 无指针纯读：NACK
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		local t = {}
		for i = 1, n do
			local b
			if read_ptr == REG_WR then
				b = wr
			elseif read_ptr == REG_OVF then
				b = ovf
			elseif read_ptr == REG_RD then
				b = rd
			elseif read_ptr == REG_DATA then
				b = next_byte()			-- 仅数据口随字节位置推进
			elseif read_ptr == REG_PART then
				b = part_id
			else
				b = regs[read_ptr] or 0
			end
			t[i] = b
		end
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 立即向 FIFO 推入一个注入样本（SpO2 双通道；HR 模式 ir 忽略）
	function d:push_sample(red, ir)
		push_raw(red, ir)
		return self
	end

	-- 批量推入：list 元素 {red=, ir=}（或 r/i 键）
	function d:push_samples(list)
		if type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" then push_raw(s.red or s.r, s.ir or s.i) end
			end
		end
		return self
	end

	-- 排队自动产出注入（advance 到点时按序使用，先于正弦）
	function d:queue_sample(red, ir)
		prod_queue[#prod_queue + 1] = { red = red, ir = ir }
		return self
	end
	function d:queue_samples(list)
		if type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" then
					prod_queue[#prod_queue + 1] = { red = s.red or s.r, ir = s.ir or s.i }
				end
			end
		end
		return self
	end

	function d:clear_fifo()
		fifo_clear()
		return self
	end

	function d:set_part_id(v)
		part_id = math.floor(tonumber(v) or PART_ID) % 256
		return self
	end

	-- 自动采样门停摆（advance 不产出，喂驱动 wait 轮询耗尽；不影响显式 push/virt_tick）
	function d:set_never_sample(on) never_sample = on ~= false; return self end

	-- 推虚拟时钟：active 时按输出周期向 FIFO 产样（可一次跨多拍）
	function d:advance(ms)
		ms = tonumber(ms) or 0
		if active() and remaining ~= nil and not never_sample then
			remaining = remaining - ms
			while remaining <= 0 do
				produce_one()
				remaining = remaining + period_ms()
			end
		end
		return self
	end

	-- 守护逐拍造数：直接推入一拍确定性 PPG 正弦（不经周期门），
	-- 保证 call 读指针即有样本、零真实睡眠；rollover 下也恒取最新数据
	function d:virt_tick(n)
		push_raw(wave(n))
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_sample = false
		return self
	end

	function d:reset_logs()
		reset_count, produced = 0, 0
		return self
	end

	-- 重新上电：全状态回 POR（含身份/注入队列）；故障钩子保留
	function d:reset()
		part_id = PART_ID
		prod_queue = {}
		seed_regs()
		fifo_clear()
		read_ptr = nil
		remaining, produced, reset_count = nil, 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:wr_ptr() return wr end
	function d:rd_ptr() return rd end
	function d:ovf_counter() return ovf end
	-- 驱动口径可用数（(WR-RD) mod 32；积压整圈回绕后与物理占用不符，真实行为）
	function d:avail() return (wr - rd) % DEPTH end
	function d:occupied() return count end
	function d:slot(i)
		local s = slots[math.floor(tonumber(i) or 0) % DEPTH]
		return s and s.r or nil, s and s.i
	end
	function d:rollover_en() return rollover_on() end
	function d:is_active() return active() end
	function d:mode() return mode_bits() end
	function d:shdn() return shdn_on() end
	function d:spo2_mode() return is_spo2() end
	function d:period_ms() return active() and period_ms() or nil end
	function d:remaining_ms() return remaining end
	function d:produced() return produced end
	function d:reset_count() return reset_count end
	function d:part_id() return part_id end
	function d:reg(a) return regs[math.floor(tonumber(a) or 0)] or 0 end

	return d
end

return M

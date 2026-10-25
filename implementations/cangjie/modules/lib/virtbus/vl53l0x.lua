-- virtbus/vl53l0x.lua —— VL53L0X ToF 激光测距的虚拟 I2C 器件模型
-- bot4cj 仓颉机器人框架
--
-- 对应真实驱动 modules/VL53L0X.lua（地址固定 0x29）。注意 VL53L0X 是
-- 「8 位寄存器指针 + 0xFF 页切换」的分页器件（16 位指针的是 VL53L4CD，
-- 别混用 regmap ptr16）：同一个寄存器号在不同页是不同物理寄存器，模型
-- 按 regs[页][号] 分页存储。
--
-- 建模范围（协议层事实，序列锁定 Pololu VL53L0X.cpp / ESPHome 三方对照）：
--   * 0xC0 = 0xEE 器件 ID（who() 可改错挂）；0x89 VHV、0x84 GPIO 极性初值
--   * 0x91（page 1）stop_variable DataInit 舞步取/回写
--   * getSpadInfo：page6 的 0x83 RMW、page7 的 0x83 轮询（0x00 等待→非 0）、
--     page7 的 0x92 SPAD 数/类型（bit7=光圈型，低 7 位=数量）
--   * page0 0x00 SYSRANGE 模式机：0x02 背靠背连续（5ms 虚拟转换倒计时）、
--     0x01/0x41 参考校准启动（立即就绪）、0x00 停
--   * 0x13 bit[2:0] data-ready；0x0B=0x01 清中断（连续模式重新计时）
--   * 0x14~0x1F 12 字节结果块（状态/SPAD 8.8/信号 9.7/环境 9.7/毫米距离）
-- 模型不实现 ST 状态查表与定点换算（那是驱动的事），只提供结果区位场。
--
-- 挂载：
--   local vlmod = dofile("modules/lib/virtbus/vl53l0x.lua")
--   local tof = vlmod.new()
--   vbus.attach("VL53L0X@0x29", 0x29, tof)
--   tof:inject_result({ st = 0x58, dist = 300, signal = 0x0C80, ... })
--   tof:virt_tick(n)   -- 守护逐拍确定性合成样本（预武装，首次轮询即就绪）

local vl = {}

local MODEL_ID = 0xEE
local STOP_VAR = 0x2B
local REG_PAGE = 0xFF
local REG_SYSRANGE = 0x00
local REG_INT_CLEAR = 0x0B
local REG_RESULT_INT = 0x13
local REG_RESULT_RANGE = 0x14
local CONV_MS = 5			-- 背靠背单帧约 33ms；旧桩/测试按 5ms 倒计时推进

function vl.new(opts)
	opts = opts or {}
	local self = {}

	-- ---- 器件状态 ----
	local regs = {}				-- regs[page][reg] = byte
	local page = 0				-- 当前页（0xFF 页选择）
	local ptr, ptr_page = 0, 0		-- 最近一次指针写（读事务跟随）
	local model_id = MODEL_ID
	local stop_var = STOP_VAR
	local spad92 = 0x18			-- 默认 24 SPAD 非光圈
	local continuous = false
	local armed = false			-- data-ready（0x13 低 3 位非 0）
	local countdown = 0			-- 连续模式虚拟转换倒计时 ms
	local spad_pending = false		-- page7 0x83=0x00 后等待非 0

	-- ---- 故障钩子（public 字段，attach 后置位即时生效；reset 不清，负路径护栏） ----
	self.nack = false			-- 读写全断（器件掉线）
	self.nack_read = false
	self.nack_write = false
	local never_ready, spad_stuck, refcal_stuck = false, false, false
	local fail_read_set = {}		-- "page:reg" -> true
	local write_pred = nil		-- 定向写故障：pred(字节表) 命中的写 NACK

	-- ---- 事务留痕 ----
	local wlog = {}			-- {p=页, reg=, vals={...}, multi=}
	local sysrange_vals = {}	-- page0 写 0x00 的模式值序列
	local sig_writes = {}		-- 0x44 multi 写（信号率门限 Q9.7）
	local map_writes = {}		-- 0xB0 multi 写（SPAD 使能图 6 字节）
	local reads_91 = 0
	local reads_83 = {}		-- 每次 0x83 读所在页
	local clears = 0

	local function page_regs(p)
		local t = regs[p]
		if t == nil then t = {}; regs[p] = t end
		return t
	end

	local function init_device()
		regs = {}
		local p0 = page_regs(0)
		p0[0x89] = 0x00			-- VHV EXTSUP_HV（驱动 RMW 置 bit0）
		p0[0x84] = 0x12			-- GPIO HV MUX，bit4=1 验证 RMW 清除
		for r = 0xB0, 0xB5 do p0[r] = 0xFF end	-- 上电参考 SPAD 图全 1
		page = 0
		ptr, ptr_page = 0, 0
		model_id = MODEL_ID
		stop_var = STOP_VAR
		spad92 = 0x18
		continuous = false
		armed = false
		countdown = 0
		spad_pending = false
	end

	local function reset_logs()
		wlog = {}
		sysrange_vals = {}
		sig_writes = {}
		map_writes = {}
		reads_91 = 0
		reads_83 = {}
		clears = 0
	end

	init_device()

	-- ===================== 状态/留痕 API（冒号定义） =====================

	function self:page() return page end
	function self:continuous() return continuous end
	function self:armed() return armed end
	function self:get_reg(reg, p) return regs[p or 0] and regs[p or 0][reg] or 0 end
	function self:write_log() return wlog end
	function self:sysrange_log() return sysrange_vals end
	function self:sig_writes() return sig_writes end
	function self:map_writes() return map_writes end
	function self:reads_91() return reads_91 end
	function self:reads_83_pages() return reads_83 end
	function self:clear_count() return clears end
	function self:reset_logs() reset_logs(); return self end

	-- 单字节写序列中某寄存器的值序列（默认 page0）
	function self:write_values(reg, p)
		local t = {}
		for _, w in ipairs(wlog) do
			if w.reg == reg and w.p == (p or 0) and not w.multi then
				t[#t + 1] = w.vals[1]
			end
		end
		return t
	end

	-- ---- 配置注入 ----
	function self:who(id) model_id = id; return self end
	function self:set_stop_variable(v) stop_var = math.floor(v) % 256; return self end

	-- count 1~127；aperture=true 置 bit7（光圈型，参考 SPAD 跳前 12）
	function self:set_spad(count, aperture)
		count = math.floor(count) % 128
		spad92 = count + (aperture and 0x80 or 0)
		return self
	end

	-- 注入 12 字节结果块（0x14~0x1F）：原始定点码，换算由驱动做
	--   st 状态字节；spad 8.8；signal/ambient 9.7；dist 毫米
	-- 连续模式下注入即武装（驱动首次轮询直接就绪，无需虚拟转换等待）
	function self:inject_result(o)
		local p0 = page_regs(0)
		local function put16(reg, raw)
			raw = math.floor(raw) % 65536
			p0[reg] = math.floor(raw / 256) % 256
			p0[reg + 1] = raw % 256
		end
		p0[0x14] = math.floor(o.st or 0) % 256
		p0[0x15] = 0x00
		put16(0x16, o.spad or 0)
		put16(0x18, 0)
		put16(0x1A, o.signal or 0)
		put16(0x1C, o.ambient or 0)
		put16(0x1E, o.dist or 0)
		if continuous then armed = true; countdown = 0 end
		return self
	end

	-- 测试用：外部虚拟时钟（milli_sleep 桩调用）；连续模式到点自动就绪
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if continuous and not armed then
			countdown = countdown - ms
			if countdown <= 0 then armed = true end
		end
		return self
	end

	-- ---- 故障注入 ----
	function self:fail_read(reg, p, on)
		fail_read_set[string.format("%d:%d", p or 0, reg)] = on and true or nil
		return self
	end
	-- 定向写故障（含指针写）：pred(bytes) 返回 true 的写事务 NACK。
	-- 典型用途：只让 0x0B 清中断写失败而不影响之前的读指针。
	function self:fail_write(pred) write_pred = pred; return self end
	function self:set_spad_stuck(on) spad_stuck = on and true or false; return self end
	function self:set_refcal_stuck(on) refcal_stuck = on and true or false; return self end
	function self:set_never_ready(on) never_ready = on and true or false; return self end
	function self:clear_faults()
		self.nack, self.nack_read, self.nack_write = false, false, false
		never_ready, spad_stuck, refcal_stuck = false, false, false
		fail_read_set = {}
		write_pred = nil
		return self
	end

	-- 状态机复位（等价重新上电；故障钩子保留）
	function self:reset()
		init_device()
		reset_logs()
		return self
	end

	-- ===================== 总线接口（点定义闭包，无 self） =====================

	-- 写事务：1 字节 = 寄存器指针（读消息前导）；2+ 字节 = 寄存器写
	-- （首字节寄存器号，后续数据）。return false = NACK。
	self.write = function(bytes)
		if self.nack or self.nack_write then return false end
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if write_pred ~= nil and write_pred(bytes) then return false end
		if #bytes == 1 then
			ptr, ptr_page = bytes[1], page
			return true
		end

		local reg = bytes[1]
		-- 页切换：本事务只做页选
		if reg == REG_PAGE then
			page = bytes[2] % 256
			wlog[#wlog + 1] = { p = page, reg = REG_PAGE, vals = { bytes[2] }, multi = false }
			return true
		end

		local p = page
		local pr = page_regs(p)
		local vals = {}
		for i = 2, #bytes do
			local v = bytes[i] % 256
			vals[#vals + 1] = v
			pr[reg + i - 2] = v
		end
		local multi = #vals > 1
		wlog[#wlog + 1] = { p = p, reg = reg, vals = vals, multi = multi }
		if reg == 0x44 and multi then sig_writes[#sig_writes + 1] = vals end
		if reg == 0xB0 and multi then map_writes[#map_writes + 1] = vals end

		-- SYSRANGE 模式机（仅 page0）
		if reg == REG_SYSRANGE and p == 0 then
			local v = vals[1]
			sysrange_vals[#sysrange_vals + 1] = v
			if v == 0x02 then
				continuous = true
				armed = false
				countdown = CONV_MS
			elseif v == 0x00 then
				continuous = false
			elseif v == 0x01 or v == 0x41 then
				if not refcal_stuck then armed = true end
			end
		end

		-- 清中断
		if reg == REG_INT_CLEAR and vals[1] == 0x01 then
			clears = clears + 1
			armed = false
			if continuous then countdown = CONV_MS end
		end

		-- page7 的 0x83 SPAD 就绪握手
		if reg == 0x83 and p == 7 then
			if vals[1] == 0x00 then spad_pending = true
			elseif vals[1] == 0x01 then spad_pending = false end
		end
		return true
	end

	-- 读事务：n 字节，从最近指针写指定的（页, 寄存器）起 burst；nil = NACK。
	self.read = function(n)
		if self.nack or self.nack_read then return nil end
		if fail_read_set[string.format("%d:%d", ptr_page, ptr)] then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end

		local out = {}

		local function fill_special(first)
			out[1] = first % 256
			for i = 2, n do out[i] = 0 end
		end

		if ptr == 0xC0 then
			fill_special(model_id)
		elseif ptr == 0x91 and ptr_page == 1 then
			reads_91 = reads_91 + 1
			fill_special(stop_var)
		elseif ptr == 0x92 and ptr_page == 7 then
			fill_special(spad92)
		elseif ptr == 0x83 then
			reads_83[#reads_83 + 1] = ptr_page
			if ptr_page == 7 and spad_pending then
				fill_special(spad_stuck and 0x00 or 0x01)
			else
				fill_special(regs[ptr_page] and regs[ptr_page][0x83] or 0)
			end
		elseif ptr == REG_RESULT_INT then
			if never_ready then fill_special(0x00)
			elseif armed then fill_special(0x07)
			else fill_special(0x00) end
		else
			local pr = regs[ptr_page] or {}
			for i = 0, n - 1 do out[i + 1] = pr[ptr + i] or 0 end
		end
		return out
	end

	-- ===================== 守护合成样本（阶段 C） =====================
	-- 确定性正弦距离 100~1100mm（32 拍周期），恒为有效帧：
	-- st=0x58（内部码 11）、2.0 SPAD、25 MCPS 信号、6 MCPS 环境光。
	-- 预武装——守护 call 的首次 0x13 轮询即就绪，不依赖 milli_sleep。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local phase = math.sin(n * (2 * math.pi / 32)) * 0.5 + 0.5
		local dist = 100 + math.floor(phase * 1000 + 0.5)
		self:inject_result({
			st = 0x58, spad = 0x0200, signal = 0x0C80, ambient = 0x0300,
			dist = dist,
		})
		return self
	end

	return self
end

return vl

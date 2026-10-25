-- modules/lib/virtbus/pcf8574.lua —— PCF8574 8 位准双向 I2C IO 扩展器虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【无寄存器图 · 单字节 P 口写 + 无指针纯读】极简样板（NXP PCF8574 /
-- PCF8574A，地址族 0x20~0x27 / 0x38~0x3F；纯闭包、纯算术无 bitcompat）。
-- 协议事实与 modules/PCF8574.lua 驱动同源（NXP 手册）：
--   1) 没有寄存器指针/寄存器地图：写事务的每个数据字节直接进 P 口输出锁存
--      （每字节都 ACK、逐字节传送到 P 口，驱动永远只写 1 字节，末字节留口）；
--      读事务是无指针纯读，每字节 = P 口引脚即时电平（连续读重复返回当前
--      引脚态，n 钳 1~16）。
--   2) 准双向、无方向寄存器：锁存写 1 = 弱上拉（可作输入，外部可拉低），
--      写 0 = 强驱动低。引脚读值 = latch & ~pull_low——外部低电平恒胜过
--      弱上拉，强驱动低位恒读 0。POR 锁存 = 0xFF（全弱上拉/输入态）。
--      pull_low 是测试侧的「外部激励」（按键/开漏器件），只能由注入 API 设置；
--      模型不臆造引脚电平。
--   3) 无 ID 寄存器：build 的在位甄别就是一次纯读 ACK；地址族校验在驱动侧。
--   4) virt_tick 供守护逐拍造数：walking 低电平位（8 拍周期循环拉低 P0~P7，
--      模拟按键轮询），build 前 virt_tick(0) 预武装、call 纯读引脚随拍变化。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。

local M = {}
M._VERSION = "0.1.0"

local POR_LATCH = 0xFF

-- 8 位按位与（纯算术，模型不引 bitcompat）
local function band8(a, b)
	a = a % 256
	b = b % 256
	local r, p = 0, 1
	for _ = 1, 8 do
		if a % 2 == 1 and b % 2 == 1 then r = r + p end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		p = p * 2
	end
	return r
end

local function bytev(v)
	v = tonumber(v)
	if v == nil or v ~= math.floor(v) or v < 0 or v > 255 then return nil end
	return v
end

function M.new(opts)
	opts = opts or {}
	local d = {}

	-- 芯片侧状态
	local latch = bytev(opts.latch) or POR_LATCH	-- P 口输出锁存（POR 0xFF）
	local pull_low = bytev(opts.pull_low) or 0	-- 外部拉低掩码（测试激励，非芯片寄存器）

	-- 事务留痕（txlog 之外的模型级计数/帧表）
	local wr_frames = {}				-- 每笔写事务的字节表副本
	local write_count, read_count = 0, 0

	-- 故障钩子（d:reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- 派生 ----------------

	-- 引脚即时电平：强驱动低位恒 0；弱上拉位被外部拉低则读 0
	local function pins()
		return band8(latch, 255 - pull_low)
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end
		local frame = {}
		for i = 1, #bytes do
			local b = bytev(bytes[i])
			if b == nil then return false end	-- 非字节：整笔 NACK，锁存不动
			frame[i] = b
			latch = b				-- 逐字节传送 P 口，末字节留口
		end
		wr_frames[#wr_frames + 1] = frame
		write_count = write_count + 1
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(n) then return nil end
		local p = pins()
		local t = {}
		for i = 1, n do t[i] = p end		-- 连续读重复返回当前引脚态
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 直接置输出锁存（正常路径由总线写改变；仅供特殊注入/重开电场景）
	function d:set_latch(v)
		v = bytev(v)
		if v ~= nil then latch = v end
		return self
	end

	-- 外部激励：8 位掩码，置 1 的位被外部强拉低（按键/开漏）
	function d:set_pull_low(mask)
		mask = bytev(mask)
		if mask ~= nil then pull_low = mask end
		return self
	end
	function d:pull(i)			-- 单脚外部拉低
		i = math.floor(tonumber(i) or -1)
		if i >= 0 and i <= 7 and band8(pull_low, 2 ^ i) == 0 then
			pull_low = pull_low + 2 ^ i
		end
		return self
	end
	function d:release(i)			-- 单脚外部释放
		i = math.floor(tonumber(i) or -1)
		if i >= 0 and i <= 7 and band8(pull_low, 2 ^ i) ~= 0 then
			pull_low = pull_low - 2 ^ i
		end
		return self
	end
	function d:release_all() pull_low = 0; return self end

	-- 守护逐拍造数：walking 低电平位，8 拍周期（模拟 P0~P7 轮询按键）
	function d:virt_tick(n)
		local k = math.floor(tonumber(n) or 0) % 8
		pull_low = 2 ^ k
		return self
	end

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

	-- 重新上电：锁存回 POR 0xFF、外部激励清空、留痕清零；故障钩子保留
	function d:reset()
		latch = POR_LATCH
		pull_low = 0
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:latch() return latch end
	function d:pins() return pins() end
	function d:pull_low() return pull_low end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:frames() return wr_frames end
	function d:last_write()
		local f = wr_frames[#wr_frames]
		return f and f[#f] or nil
	end

	return d
end

return M

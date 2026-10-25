-- modules/lib/virtbus/sht3x.lua —— SHT3X（SHT30/31/35）温湿度虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个 16 位命令字 + 每数据字 CRC-8 的命令式 I2C 器件】——没有
-- 寄存器指针：每笔总线写恰为 2 字节命令大端字（驱动借 i2c_write_reg(fd,hi,lo)
-- 的 2 字节原子写发送），测量/状态从总线【纯读】（i2c_read，无前置指针写）。
-- 与 BH1750（单字节 opcode）同族但命令宽一倍，且读回帧每 2 字节带 1 字节
-- CRC-8（多项式 0x31、初值 0xFF，校验向量 0xBEEF→0x92），模型必须按
-- datasheet 真算 CRC 而不是常量占位——驱动 build 校验状态 CRC、call 报告
-- CRC_OK，坏 CRC 是必须能注入的真实故障面。
--
-- 只复刻协议层事实（Sensirion SHT3x datasheet，以真实驱动
-- modules/SHT3X.lua 实际访问为准）：
--   1) 软复位 0x30A2：约 1.5ms 后就绪，状态回上电值 bit4=1（复位检测）、
--      加热器关、测量态清空；清状态 0x3041 只清标志位（保留 bit12 加热器）。
--   2) 状态寄存器（读命令 0xF32D，纯读 3 字节 status_MSB/LSB/CRC）：
--      bit0=上次写数据校验和状态、bit1=上命令未处理/非法、bit4=复位检测、
--      bit12=加热器；bit0/bit1 为读后清零（read-to-clear）。非法命令字
--      被器件拒绝（NACK）并置 bit1。
--   3) 单次测量（轮询 0x2400/0x240B/0x2416，时钟拉伸 0x2C06/0x2C0D/
--      0x2C10）：转换未完成前纯读 6 字节被 NACK（轮询模式语义），
--      advance(ms) 推进转换（测试 milli_sleep 桩转调，驱动高重复性固定
--      等 16ms ≥ datasheet max 15.5ms）；6 字节 = T_MSB T_LSB CRC |
--      RH_MSB RH_LSB CRC，单次结果读后即失效（再读 NACK）。
--   4) 周期模式 15 个启动字 + 0x3093 break + 0xE000 fetch（驱动不用，
--      模型识别留痕，周期数据可重复 fetch）；加热器 0x306D/0x3066 改
--      bit12。出厂无校准系数表：raw→T=-45+175·raw/65535、RH=100·raw/65535
--      是驱动侧换算，模型只按 16 位宽度存储（set_raw），set_sample 物理量
--      API 仅供守护 virt_tick 造样本。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local bitc = dofile(mpath.resolve("bitcompat.lua"))

local M = {}
M._VERSION = "0.1.0"

-- CRC-8（多项式 0x31、初值 0xFF；datasheet 校验向量 0xBEEF → 0x92）
local function crc8(word)
	local crc = 0xFF
	for _, b in ipairs({ math.floor(word / 256) % 256, word % 256 }) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.band(bitc.bxor(bitc.lshift(crc, 1), 0x31), 0xFF)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end
M.crc8 = crc8

-- 状态寄存器位（datasheet Table 18）
local F_WRITE_CRC = 0x0001	-- bit0：上次写数据校验和失败（读后清）
local F_CMD_BAD   = 0x0002	-- bit1：上命令未处理/非法（读后清）
local F_RESET     = 0x0010	-- bit4：发生过复位（上电/软/硬）
local F_HEATER    = 0x1000	-- bit12：加热器开关（清状态命令保留）

-- 单次测量字 → 转换时间上限 ms（向上取整：15.5/6.5/4.5）
local SINGLE_WAIT = {
	[0x2400] = 16, [0x240B] = 7, [0x2416] = 5,	-- 轮询（不拉伸时钟）
	[0x2C06] = 16, [0x2C0D] = 7, [0x2C10] = 5,	-- 时钟拉伸（片内等待，同上限）
}
-- 周期测量启动字（mps × 重复性，共 15 个；驱动不用，识别留痕即可）
local PERIODIC_START = {
	[0x2032] = true, [0x2024] = true, [0x202F] = true,	-- 0.5 mps
	[0x2130] = true, [0x2126] = true, [0x212D] = true,	-- 1 mps
	[0x2236] = true, [0x2220] = true, [0x222B] = true,	-- 2 mps
	[0x2334] = true, [0x2322] = true, [0x2329] = true,	-- 4 mps
	[0x2737] = true, [0x2721] = true, [0x272A] = true,	-- 10 mps
}

local SOFT_RESET, CLEAR_STATUS, READ_STATUS = 0x30A2, 0x3041, 0xF32D
local HEATER_ON, HEATER_OFF, BREAK, FETCH = 0x306D, 0x3066, 0x3093, 0xE000

local function clamp_word(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end

-- 25°C / 50%RH 的上电种子原始值（set_sample 同款编码，仅为静态初值合理）
local function seed_data()
	return math.floor((25 + 45) * 65535 / 175 + 0.5),
	       math.floor(50 * 65535 / 100 + 0.5)
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local status = F_RESET			-- 上电即置复位检测位
	local t_raw, rh_raw = seed_data()
	local pending = nil			-- nil | "status" | "meas"（最近命令待读）
	local consume = false			-- 单次结果读后失效；周期 fetch 可重复读
	local remaining, ready = nil, false
	local periodic = false
	local prearmed = false			-- virt_tick 预武装：下一单次命令零转换
	local cmds, bad_cmds = {}, {}		-- 识别命令字序列 / 非法命令字序列

	-- 故障钩子（reset 保留，clear_faults 解除）
	-- 三个 nack 为表字段（外部直接 d.nack=true，与 bh1750 等模型一致）；
	-- 定向谓词/坏 CRC/卡死/状态覆写为 local，由方法设置
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local bad_crc = false			-- 破坏所有输出帧 CRC（状态+测量）
	local meas_stuck = false		-- 转换永不完成（轮询读恒 NACK）
	local status_override = nil		-- 强制状态字（注入坏标志位组合）

	local function flag(f, on)
		local set = math.floor(status / f) % 2 == 1
		if on and not set then status = status + f
		elseif not on and set then status = status - f end
	end

	local function start_single(word)
		pending, consume = "meas", true
		periodic = false
		if prearmed then
			remaining, ready = 0, true
		else
			remaining, ready = SINGLE_WAIT[word], false
		end
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		-- SHT3x 只有 16 位命令：非 2 字节写视为非法帧 NACK
		if #bytes ~= 2 then return false end
		local word = bytes[1] * 256 + bytes[2]
		if write_pred and write_pred(word, bytes) then return false end

		if word == SOFT_RESET then
			status = F_RESET
			pending, consume = nil, false
			remaining, ready, periodic = nil, false, false
		elseif word == CLEAR_STATUS then
			-- 清所有标志位，保留加热器在位状态（bit12）
			status = math.floor(status / F_HEATER) % 2 == 1 and F_HEATER or 0
			-- 清状态不改变待读语义（datasheet 不产生数据）
		elseif word == READ_STATUS then
			pending = "status"
		elseif SINGLE_WAIT[word] then
			start_single(word)
		elseif PERIODIC_START[word] then
			periodic = true
			pending, remaining, ready = nil, nil, false
		elseif word == BREAK then
			periodic = false
			pending = nil
		elseif word == FETCH then
			-- 仅周期模式有数据缓冲；空闲 fetch 无数据（随后读 NACK）
			if periodic then pending, consume, ready = "meas", false, true end
		elseif word == HEATER_ON then
			flag(F_HEATER, true)
		elseif word == HEATER_OFF then
			flag(F_HEATER, false)
		else
			-- 非法命令：器件拒绝并置命令状态位（datasheet bit1）
			flag(F_CMD_BAD, true)
			bad_cmds[#bad_cmds + 1] = word
			return false
		end
		cmds[#cmds + 1] = word
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(pending, consume, n) then return nil end
		if pending == "status" and n == 3 then
			local w = status_override or status
			local crc = bad_crc and (crc8(w) ~= 0xFF and 0xFF or 0x00) or crc8(w)
			-- bit0/bit1 读后清零（bit4/bit12 保持；override 不改真实 status）
			if math.floor(status / F_WRITE_CRC) % 2 == 1 then status = status - F_WRITE_CRC end
			if math.floor(status / F_CMD_BAD) % 2 == 1 then status = status - F_CMD_BAD end
			pending = nil
			return { math.floor(w / 256) % 256, w % 256, crc }
		end
		if pending == "meas" and n == 6 then
			if meas_stuck or not ready then return nil end
			local tc = bad_crc and (crc8(t_raw) ~= 0xFF and 0xFF or 0x00) or crc8(t_raw)
			local rc = bad_crc and (crc8(rh_raw) ~= 0xFF and 0xFF or 0x00) or crc8(rh_raw)
			if consume then pending = nil end	-- 单次结果读后失效
			return { math.floor(t_raw / 256) % 256, t_raw % 256, tc,
			         math.floor(rh_raw / 256) % 256, rh_raw % 256, rc }
		end
		-- 空闲/未触发转换/长度不符：无数据可读，NACK（真机轮询语义）
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining, ready = 0, true end
		end
		return self
	end

	-- 注入测量原始值（16 位无符号宽度；换算公式归驱动，模型不抄）
	function d:set_raw(t, rh)
		t_raw, rh_raw = clamp_word(t), clamp_word(rh)
		return self
	end

	-- 物理量注入（仅供守护/E2E 造样本；常量与驱动换算同源同量程）
	function d:set_sample(t_c, rh_pct)
		t_raw = clamp_word((t_c + 45) * 65535 / 175)
		rh_raw = clamp_word(rh_pct * 65535 / 100)
		return self
	end

	-- 强制状态寄存器上报值（build 负路径注入：坏标志位但 CRC 正确）
	function d:set_status_word(w)
		status_override = w and clamp_word(w) or nil
		return self
	end

	function d:fail_cmd(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_crc(on) bad_crc = on ~= false; return self end
	function d:set_meas_stuck(on) meas_stuck = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		bad_crc, meas_stuck, status_override = false, false, nil
		return self
	end

	function d:reset_logs()
		cmds, bad_cmds = {}, {}
		return self
	end

	-- 上电复位：芯片状态回种子；故障钩子保留（防负路径假解除）
	function d:reset()
		status = F_RESET
		t_raw, rh_raw = seed_data()
		pending, consume = nil, false
		remaining, ready, periodic, prearmed = nil, false, false, false
		cmds, bad_cmds = {}, {}
		return self
	end

	-- 守护逐拍造数：确定性温湿度正弦（T 20~30°C，RH 30~70%），
	-- 并预武装——驱动每拍新写单次命令，守护不驱动 advance，
	-- 必须让命令下发时转换即完成（真实 16ms milli_sleep 在守护里照常睡）。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_sample(25 + 5 * math.sin(ph),
		                50 + 20 * math.sin(ph + math.pi / 4))
		prearmed = true
		return self
	end

	-- 只读观察口
	function d:current_status() return status_override or status end
	function d:is_periodic() return periodic end
	function d:is_ready() return ready end
	function d:remaining_ms() return remaining end
	function d:pending() return pending end
	function d:cmd_count() return #cmds end
	function d:commands() return cmds end
	function d:bad_commands() return bad_cmds end

	return d
end

return M

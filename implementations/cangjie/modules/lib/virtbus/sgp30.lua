-- modules/lib/virtbus/sgp30.lua —— SGP30 金属氧化物空气质量传感器虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【16 位命令字 + 每数据字 CRC-8 的命令式 I2C，且命令带读写数据载荷】
-- 的器件样板（Sensirion SGP30，I2C 地址固定 0x58）——无寄存器指针，写流首两
-- 字节恒为 0x20xx 命令大端字（驱动借 i2c_write_reg(fd,0x20,lo) 发无载荷命令、
-- i2c_write_multi(fd,0x20,lo,...) 发带载荷命令），应答全部【无指针纯读】
--（i2c_read，不写任何指针字节）。同族是 sht3x.lua（CRC-8 poly 0x31/init
-- 0xFF，校验向量 0xBEEF→0x92），SGP30 的新增协议面：
--   1) 命令带「写数据」：Set_absolute_humidity 0x2061 帧长恰 5 字节
--      （hi,lo, AH_MSB,AH_LSB,CRC）、Set_baseline 0x201E 恰 8 字节
--      （hi,lo, w1h,w1l,crc1, w2h,w2l,crc2）——器件逐字校验内嵌 CRC，
--      坏 CRC 字节在真机上被 NACK，模型照此拒绝整笔且不更新状态。
--   2) 三种待读应答按最后命令区分：Measure_test 0x2032（自检，≤220ms，
--      3 字节固定 0xD400+CRC，build 兼在位探测）、Measure_air_quality
--      0x2008（≤12ms，6 字节 CO2eq+crc | TVOC+crc）、Get_baseline
--      0x2015（≤10ms，6 字节两基线字）；读完待读即失效（再纯读 NACK）。
--   3) IAQ 启动相：Init_air_quality 0x2003 后前 15s 测量输出恒为
--      CO2eq=400/TVOC=0（datasheet 启动相），虚拟时钟由 advance 驱动；
--      守护 virt_tick 以 warm 模式模拟已度过启动相的部署态（同预武装
--      惯例，守护不驱动虚拟时钟）。
--   4) 模型只复刻协议：基线两字可被 set/get 交叉验证（驱动另有 HAL.sys
--      六字节文件持久化，属文件系统而非总线，测试侧 mock HAL.sys）；
--      CO2eq/TVOC 无换算公式（器件直接输出工程值），测量值由用例注入。
--
-- 未建模命令（0x3682 序列号/0x202F feature set/0x0006 软复位等驱动不用）
-- 一律 NACK 并入 bad_commands；模型范围以真实驱动 modules/SGP30.lua 为准。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

local M = {}
M._VERSION = "0.1.0"

-- CRC-8（多项式 0x31、初值 0xFF；Sensirion 同族，校验向量 0xBEEF → 0x92）
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

-- 命令字（高字节恒 0x20）
local CMD_INIT      = 0x2003
local CMD_MEASURE   = 0x2008
local CMD_GET_BASE  = 0x2015
local CMD_SET_BASE  = 0x201E
local CMD_SELFTEST  = 0x2032
local CMD_SET_AH    = 0x2061

-- 各命令帧长（含两字节命令头）
local FRAME_LEN = {
	[CMD_INIT] = 2, [CMD_MEASURE] = 2, [CMD_GET_BASE] = 2,
	[CMD_SELFTEST] = 2, [CMD_SET_AH] = 5, [CMD_SET_BASE] = 8,
}

-- datasheet 最大转换时长（ms）→ 有应答的命令的读门限（驱动等待含 2ms 余量）
local GATE_MS = {
	selftest = 220,		-- Measure_test ≤220ms，驱动睡 222
	measure  = 12,		-- Measure_air_quality ≤12ms，驱动睡 14
	baseline = 10,		-- Get_baseline ≤10ms，驱动睡 12
}
local STARTUP_MS = 15000	-- Init 后启动相：前 15s 输出恒 400/0
local STARTUP_CO2, STARTUP_TVOC = 400, 0
local SELFTEST_MAGIC = 0xD400

local function clamp_word(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end

local function hi(w) return math.floor(w / 256) % 256 end
local function lo(w) return w % 256 end

function M.new()
	local d = {}

	-- 芯片侧状态
	local selftest_word = SELFTEST_MAGIC
	local co2_raw, tvoc_raw = STARTUP_CO2, STARTUP_TVOC
	local base1, base2 = 0x1234, 0x5678	-- 非零学习完成态种子（全 0 有专门语义）
	local ah_word = nil			-- 最近一次 Set_absolute_humidity 的字
	local iaq = false			-- 是否已 Init_air_quality
	local iaq_ms = 0			-- Init 后虚拟运行时长（advance 累积）
	local pending = nil			-- nil | "selftest" | "measure" | "baseline"
	local remaining, ready = nil, false
	local prearmed, warm = false, false	-- virt_tick：零转换门 / 已度过启动相
	local cmds, bad_cmds = {}, {}		-- 识别命令序列（含载荷日志）/ 非法字序列
	local bad_write_crc = 0			-- 写数据内嵌 CRC 被拒次数

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local cmd_pred, read_pred
	local bad_crc = false			-- 翻转所有应答帧 CRC（自检/测量/基线）

	local function start_pending(kind)
		pending = kind
		if prearmed then
			remaining, ready = 0, true
		else
			remaining, ready = GATE_MS[kind], false
		end
	end

	local function frame_crc_bad(bytes, i0)
		-- i0 指向某字的高字节：i0,i0+1 数据，i0+2 CRC
		local w = bytes[i0] * 256 + bytes[i0 + 1]
		return crc8(w) ~= bytes[i0 + 2]
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes < 2 then return false end
		if d.nack or d.nack_write then return false end
		local word = bytes[1] * 256 + bytes[2]
		if cmd_pred and cmd_pred(word, bytes) then return false end

		local want = FRAME_LEN[word]
		if want == nil or bytes[1] ~= 0x20 then
			-- 未建模/非 0x20 族命令：器件 NACK（模型只覆盖驱动使用的命令子集）
			bad_cmds[#bad_cmds + 1] = word
			return false
		end
		if #bytes ~= want then return false end	-- 载荷长度不符（含多余字节）

		if word == CMD_SELFTEST then
			start_pending("selftest")
		elseif word == CMD_MEASURE then
			start_pending("measure")
		elseif word == CMD_GET_BASE then
			start_pending("baseline")
		elseif word == CMD_INIT then
			iaq, iaq_ms = true, 0
			pending, remaining, ready = nil, nil, false
		elseif word == CMD_SET_AH then
			if frame_crc_bad(bytes, 3) then bad_write_crc = bad_write_crc + 1; return false end
			ah_word = bytes[3] * 256 + bytes[4]
		elseif word == CMD_SET_BASE then
			if frame_crc_bad(bytes, 3) or frame_crc_bad(bytes, 6) then
				bad_write_crc = bad_write_crc + 1
				return false
			end
			base1 = bytes[3] * 256 + bytes[4]
			base2 = bytes[6] * 256 + bytes[7]
		end
		cmds[#cmds + 1] = { word = word, payload = { unpack(bytes, 3) } }
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(pending, n) then return nil end

		if pending == "selftest" and n == 3 then
			if not ready then return nil end
			local c = bad_crc and bitc.bxor(crc8(selftest_word), 0xFF) or crc8(selftest_word)
			pending = nil
			return { hi(selftest_word), lo(selftest_word), c }
		end
		if pending == "baseline" and n == 6 then
			if not ready then return nil end
			local c1 = bad_crc and bitc.bxor(crc8(base1), 0xFF) or crc8(base1)
			local c2 = bad_crc and bitc.bxor(crc8(base2), 0xFF) or crc8(base2)
			pending = nil
			return { hi(base1), lo(base1), c1, hi(base2), lo(base2), c2 }
		end
		if pending == "measure" and n == 6 then
			if not ready then return nil end
			-- 启动相输出（Init 后前 15s）；warm 模拟部署态；之后报注入值
			local co2, tvoc = co2_raw, tvoc_raw
			if iaq and not warm and iaq_ms < STARTUP_MS then
				co2, tvoc = STARTUP_CO2, STARTUP_TVOC
			end
			local c1 = bad_crc and bitc.bxor(crc8(co2), 0xFF) or crc8(co2)
			local c2 = bad_crc and bitc.bxor(crc8(tvoc), 0xFF) or crc8(tvoc)
			pending = nil
			return { hi(co2), lo(co2), c1, hi(tvoc), lo(tvoc), c2 }
		end
		-- 无待读/长度不符：NACK（真机无命令时纯读无数据）
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining, ready = 0, true end
		end
		if iaq then iaq_ms = iaq_ms + ms end
		return self
	end

	-- 注入测量工程值（CO2eq ppm / TVOC ppb，器件直出工程值无驱动换算）
	function d:set_raw(co2, tvoc)
		co2_raw, tvoc_raw = clamp_word(co2), clamp_word(tvoc)
		return self
	end

	-- 注入基线两字（Get_baseline 应答 / set→get 交叉验证）
	function d:set_baseline(w1, w2)
		base1, base2 = clamp_word(w1), clamp_word(w2)
		return self
	end

	-- 注入自检回读字（build 负路径：非 0xD400）
	function d:set_selftest_word(w)
		selftest_word = clamp_word(w)
		return self
	end

	function d:fail_cmd(pred) cmd_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_crc(on) bad_crc = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		cmd_pred, read_pred = nil, nil
		bad_crc = false
		return self
	end

	function d:reset_logs()
		cmds, bad_cmds = {}, {}
		bad_write_crc = 0
		return self
	end

	-- 上电复位：芯片状态回种子；故障钩子保留（防负路径假解除）
	function d:reset()
		selftest_word = SELFTEST_MAGIC
		co2_raw, tvoc_raw = STARTUP_CO2, STARTUP_TVOC
		base1, base2 = 0x1234, 0x5678
		ah_word = nil
		iaq, iaq_ms = false, 0
		pending, remaining, ready = nil, nil, false
		prearmed, warm = false, false
		cmds, bad_cmds = {}, {}
		bad_write_crc = 0
		return self
	end

	-- 守护逐拍造数：确定性 IAQ 正弦（CO2eq 400~700ppm、TVOC 40~200ppb，
	-- 32 拍周期），warm=已度过 15s 启动相、prearmed=命令下发即就绪；
	-- 驱动真实 milli_sleep（222ms build / 14ms call）在守护里照常睡。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_raw(math.floor(550 + 150 * math.sin(ph) + 0.5),
		             math.floor(120 + 80 * math.sin(ph + math.pi / 2) + 0.5))
		warm, prearmed = true, true
		return self
	end

	-- 只读观察口
	function d:pending() return pending end
	function d:remaining_ms() return remaining end
	function d:is_ready() return ready end
	function d:iaq_elapsed_ms() return iaq_ms end
	function d:in_startup() return iaq and not warm and iaq_ms < STARTUP_MS end
	function d:is_warm() return warm end
	function d:ah_word() return ah_word end
	function d:baseline() return base1, base2 end
	function d:selftest_word() return selftest_word end
	function d:raw() return co2_raw, tvoc_raw end
	function d:bad_write_crc_count() return bad_write_crc end
	function d:cmd_count() return #cmds end
	function d:commands()
		local out = {}
		for _, e in ipairs(cmds) do out[#out + 1] = e.word end
		return out
	end
	function d:cmd_log() return cmds end
	function d:bad_commands() return bad_cmds end
	-- 最后一次某命令的载荷（1 基，不含命令头）
	function d:payload_of(word)
		local p
		for _, e in ipairs(cmds) do
			if e.word == word then p = e.payload end
		end
		return p
	end

	return d
end

return M

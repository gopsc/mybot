-- modules/lib/virtbus/mcp4725.lua —— MCP4725 12 位 I2C DAC 虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个 I2C 命令位嵌入式输出器件】——器件没有寄存器地图也没有寄存器
-- 指针：命令类型嵌在写流首字节高 3 位（C2..C0），读是无指针纯读
-- （i2c_read(fd,n) 直接出字节，同 BH1750 测量读）。写-only 程度低于
-- TPL0501：有 5 字节读回（DAC 易失码 + EEPROM 保存码 + 掉电位 + RDY）。
--
-- 只复刻协议层事实（命令位布局与 Microchip DS20002039H / Adafruit 库核实，
-- 以真实驱动 modules/MCP4725.lua 的编/解码为准）：
--   1) 快速写（C2C1=00，2+ 字节）：b0 = 00 PD1 PD0 D11 D10 D9 D8
--      （PD 在 b0 bits5:4，高 4 位数据在低半字节），b1 = D7..D0；只更新
--      易失 DAC 与当前掉电位，不碰 EEPROM、无写周期等待。
--   2) 写 DAC+EEPROM（C2C1C0=011，3 字节）：b0 = 0110 PD1 PD0 00
--           （驱动帧 0x60|PD<<1，PD 在 bits2:1——读回状态字节里 PD 位于
--      bits5:4，命令帧与读回帧的 PD 布局不同，这是硅片事实），
--      b1 = D11..D4，b2 = D3..D0<<4；同时更新 DAC/EEPROM/掉电位并进入
--      EEPROM 写周期（典型 25ms），期间读回 bit7 RDY=0。
--   3) 读回（无指针，5 字节）：b0 bit7=RDY（1=空闲/完成，0=EEPROM 忙）、
--      bits5:4=PD；b1/b2 拼 DAC（(b1<<4|b2>>4)&0xFFF）；
--      b3 低 4 位/b4 拼 EEPROM（(b3&0xF)<<8|b4）。1 字节读只用于轮询 b0。
--
-- 测量值注入不适用（输出器件）：状态由驱动写下的命令帧驱动，测试可用
-- set_dac/set_eeprom 预置上电状态（build 在位读回要非默认值时）。
-- EEPROM 忙等用 advance(ms) 虚拟时钟（测试 milli_sleep 桩转调）；
-- 输出器件无 virt_tick、阶段 C 守护采样 E2E 豁免。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：禁用 Lua5.4 位运算符。

local M = {}

local EEP_TYP_MS = 25	-- EEPROM 写周期典型值（datasheet 25ms，max 50ms；驱动 50ms 步进）

local function new_state()
	return {
		dac = 0,          -- 易失 DAC 码 0~4095
		eeprom = 0,       -- EEPROM 保存码 0~4095
		pd = 0,           -- 当前掉电位 0~3
		busy = false,     -- EEPROM 写周期进行中
		left = 0,         -- 写周期剩余 ms
	}
end

function M.new()
	local st = new_state()

	-- 留痕
	local wlog = {}    -- 写事务：{cmd, bytes, code, pd}
	local rlog = {}    -- 读事务：{n, bytes}
	local polls = 0    -- 1 字节 RDY 轮询次数

	-- 故障钩子（public 字段：attach 后置位即时生效，bh1750 惯例；reset 不清）
	-- local 谓词：定向故障（clear_faults 清）
	local read_pred, write_pred

	local self = {}
	self.nack = false        -- 读写全断
	self.nack_read = false   -- 读全断
	self.nack_write = false  -- 写全断
	self.eep_stuck = false   -- EEPROM 写永不就绪（RDY 恒 0）

	-- ---- 读回组帧 ----
	local function status_byte()
		-- bit7 RDY（不忙=1）；bit6 POR 不建模（驱动不解码）；bits5:4=PD
		return (st.busy and 0 or 0x80) + st.pd * 16
	end

	local function readback(n)
		local full = {
			status_byte(),
			math.floor(st.dac / 16) % 256,       -- b1 = D11..D4
			(st.dac % 16) * 16,                  -- b2 = D3..D0 高半字节
			math.floor(st.eeprom / 256) % 16,    -- b3 低 4 位 = D11..D8
			st.eeprom % 256,                     -- b4 = D7..D0
		}
		local t = {}
		for i = 1, n do t[i] = full[i] or 0 end
		return t
	end

	-- ---- 总线写：命令嵌在首字节 ----
	self.write = function(bytes)
		if self.nack or self.nack_write then return false end
		if type(bytes) ~= "table" or #bytes < 1 then return false end
		if write_pred and write_pred(bytes) then return false end

		local b0 = bytes[1]
		local entry = { bytes = bytes, cmd = "unknown" }

		if b0 < 0x40 then
			-- 快速写 C2C1=00（至少 2 字节；短帧真机在缺字节位置 NACK）
			if #bytes < 2 then return false end
			-- 00 PD1 PD0 D11 D10 D9 D8 | D7..D0
			local code = (b0 % 16) * 256 + bytes[2]
			local p = math.floor(b0 / 16) % 4
			st.dac, st.pd = code, p
			entry.cmd, entry.code, entry.pd = "fast", code, p
		elseif b0 < 0x80 then
			-- C2C1=01x 均为 3 字节命令（010 只写 DAC 驱动未用 / 011 写 EEPROM）
			if #bytes < 3 then return false end
			if math.floor(b0 / 32) == 3 then
				-- 0110 PD1 PD0 00 | D11..D4 | D3..D0<<4
				local code = (bytes[2] * 16 + math.floor(bytes[3] / 16)) % 4096
				local p = math.floor(b0 / 2) % 4
				st.dac, st.eeprom, st.pd = code, code, p
				-- 进入 EEPROM 写周期（stuck 钩子下保持忙直到 clear/reset）
				st.busy = true
				st.left = EEP_TYP_MS
				entry.cmd, entry.code, entry.pd = "eep", code, p
			end
			-- 010：合法帧 ACK、留痕 unknown，模型不改状态
		end
		-- b0>=0x80（C2=1 保留）与其他未知命令：合法帧照 ACK，仅留痕
		wlog[#wlog + 1] = entry
		return true
	end

	-- ---- 总线读：无指针纯读（n=1 轮询 RDY，n=5 完整读回） ----
	self.read = function(n)
		if self.nack or self.nack_read then return nil end
		n = tonumber(n) or 0
		if n < 1 then return nil end
		if read_pred and read_pred(n) then return nil end

		local t = readback(n)
		if n == 1 then polls = polls + 1 end
		rlog[#rlog + 1] = { n = n, bytes = t }
		return t
	end

	-- ---- 虚拟时钟：推进 EEPROM 写周期 ----
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if st.busy and not self.eep_stuck then
			st.left = st.left - ms
			if st.left <= 0 then st.busy = false end
		end
		return self
	end

	-- ---- 状态读取（冒号 API） ----
	function self:level() return st.dac end
	function self:eeprom_code() return st.eeprom end
	function self:pd() return st.pd end
	function self:busy() return st.busy end
	function self:rdy() return not st.busy end

	-- 预置状态（build 在位读回非默认值；模拟真板 EEPROM 已被写过）
	function self:set_dac(code)
		st.dac = math.max(0, math.min(4095, math.floor(tonumber(code) or 0)))
		return self
	end
	function self:set_eeprom(code)
		st.eeprom = math.max(0, math.min(4095, math.floor(tonumber(code) or 0)))
		return self
	end
	function self:set_pd(p)
		st.pd = math.max(0, math.min(3, math.floor(tonumber(p) or 0)))
		return self
	end
	-- 直接让器件进入/退出 EEPROM 忙态（无需写命令的异常构造）
	function self:set_busy(on, ms)
		st.busy = on and true or false
		st.left = on and (tonumber(ms) or EEP_TYP_MS) or 0
		return self
	end

	-- ---- 留痕访问 ----
	function self:write_log() return wlog end
	function self:read_log() return rlog end
	function self:rdy_polls() return polls end
	function self:fast_writes()
		local t = {}
		for _, e in ipairs(wlog) do if e.cmd == "fast" then t[#t + 1] = e end end
		return t
	end
	function self:eep_writes()
		local t = {}
		for _, e in ipairs(wlog) do if e.cmd == "eep" then t[#t + 1] = e end end
		return t
	end

	-- ---- 定向故障钩子 ----
	function self:fail_read(pred) read_pred = pred; return self end
	function self:fail_write(pred) write_pred = pred; return self end
	function self:set_eep_stuck(on) self.eep_stuck = on and true or false; return self end

	function self:clear_faults()
		self.nack, self.nack_read, self.nack_write = false, false, false
		self.eep_stuck = false
		read_pred, write_pred = nil, nil
		return self
	end

	function self:reset_logs()
		wlog, rlog, polls = {}, {}, 0
		return self
	end

	-- reset = 换新器件（钩子保留，同 ads1256/vl53l0x 惯例）
	function self:reset()
		st = new_state()
		wlog, rlog, polls = {}, {}, 0
		return self
	end

	return self
end

return M

-- MCP4725 12 位 I2C DAC 驱动模块（模拟量输出，EEPROM 断电保持）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MCP4725_VIRT（2026-09-15 自 modules/lib/virtbus/mcp4725.lua
-- 迁入，单文件驱动+模型实验第八个，write-only I2C 收尾；无硬件单测共用；写-only 无测量值，守护 E2E 豁免）
-- Microchip，I2C 地址 0x62（A0=GND）/0x63（A0=VDD），12 位 0~VDD 输出
-- （VDD 即参考电压），轨到轨输出，建立时间 6µs
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MCP4725 (
--       name    String,
--       I2C     String,
--       address String,
--       vref    String
--   );
--   INSERT INTO MCP4725 (name, I2C, address, vref)
--     VALUES ('dac0', 'i2c-1', '-', '-');
-- address = 0x62/0x63（A0 引脚，'-' 缺省 0x62）
-- vref    = 参考电压 V（=VDD，volt 列换算用，'-' 缺省 5.0）
--
-- call 契约（双用，同 EMC2101）：
--   带参设置（优先级 level > volt > percent）：
--     level 0~4095 原始码 | volt 输出电压 V（0~vref 钳位）| percent 0~100
--     eep =1 时走"写 DAC+EEPROM"并轮询 RDY（断电保持）；缺省快速写（易失，
--     2 字节事务，适合高频更新）
--   无参读回（MCP4725 有读回能力，比 TPL0501 强）：
--     { result, level(DAC 当前码), eeprom(EEPROM 保存码), pd(掉电位), volt }
-- 接 sensor_daemon：fields=level|eeprom（整数；读回路径无需参数）
--
-- 实现要点（命令位布局依 Adafruit CircuitPython MCP4725 库核实，MIT）：
--   1. 无寄存器地图——命令嵌在 I2C 写流首字节高 3 位（C2..C0）
--   2. 快速写 2 字节：[0x00 | 值>>8, 值 & 0xFF]（C2..C0=000，仅更新 DAC）
--   3. 写 DAC+EEPROM 3 字节：[0x60, 值>>4 & 0xFF, 值<<4 & 0xFF]（C2..C0=011）；
--      EEPROM 写周期约 25ms，期间读回首字节 bit7=RDY（0=忙 1=完成），
--      50ms 步进轮询 500ms 超时
--   4. 读回 5 字节：byte0 = RDY+掉电位回显，byte1/2 = DAC 值
--      （(b1<<4 | b2>>4) & 0xFFF），byte3/4 = EEPROM 值（(b3&0xF)<<8 | b4）
--   5. 换算：volt -> 码 = floor(volt x 4096 / vref + 0.5)（数据手册传递
--      函数 VOUT = VREF x 码/4096；volt=vref 时码钳 4095）；percent ->
--      码 = floor(pct x 4095 / 100 + 0.5)（100% = 满码）
--   6. 通用呼叫复位（地址 0x00 + 0x06，模拟上电重载 EEPROM）本驱动未用；
--      掉电模式（PD1:0）亦未暴露

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
dofile((__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
	.resolve("lib/drv_common.lua"))

-- 调试开关：DAC 一般配置后长跑，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 命令字 ====================
local CMD_FAST       = 0x00		-- 快速写（C2..C0=000，仅 DAC）
local CMD_DAC_EEPROM = 0x60		-- 写 DAC+EEPROM（C2..C0=011）

local RDY_MASK       = 0x80		-- 读回 byte0 bit7：EEPROM 写完成
local EEPROM_TIMEOUT_MS = 500
local EEPROM_POLL_MS = 50

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local vref = 5.0

-- 读回 5 字节 -> {pd, level, eeprom}（字节布局见头注释）
local function decode_readback(v)
	local b0 = math.floor(v / 256 ^ 4) % 256
	local b1 = math.floor(v / 256 ^ 3) % 256
	local b2 = math.floor(v / 256 ^ 2) % 256
	local b3 = math.floor(v / 256) % 256
	local b4 = v % 256
	return {
		pd = math.floor(b0 / 16) % 4,
		level = (b1 * 16 + math.floor(b2 / 16)) % 4096,
		eeprom = (b3 % 16) * 256 + b4,
		rdy = (b0 % 256) >= 0x80
	}
end

require_driver("i2c", {
	name = "MCP4725",

	-- 【配置脚本】读回一次作为在位验证（无寄存器可校验器件，读通即在）
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- MCP4725 builder func get a table --------", data)
		end

		-----------------------------------------------------
		-- 参考电压列（'-' 缺省 5.0；非正数同缺省，防除零）
		-- 经 finite_of：'nan'/'inf' 过 tonumber 出的是 number（Lua 里 truthy），
		-- `v <= 0` 对 NaN 恒假、对 +inf 也假，非有限值会原样存进 vref 这个模块级
		-- upvalue，污染此后每一次 call 的电压换算（审计 P3 口径）。
		local v = finite_of(data.vref)
		if v == nil or v <= 0 then v = 5.0 end
		vref = v

		-----------------------------------------------------
		local r = i2c_read(fd, 5)
		if r < 0 then
			return err("Failed to read MCP4725 (device presence check)")
		end
		local rb = decode_readback(r)

		print(string.format("MCP4725 init OK: addr=0x%02X, vref=%.2fV, DAC=%d, EEPROM=%d",
			addr, vref, rb.level, rb.eeprom))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 MCP4725 destroy 仅 arg_table + return OK，等价）


	-- 【调用MCP4725】双用：带参设置输出（level/volt/percent，eep 持久化），
	-- 无参读回当前 DAC/EEPROM 码
	-- NOTE: 接收一个参数（表），返回一个结果（表）
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- MCP4725 caller func get a table --------", data)
		end

		-----------------------------------------------------
		-- 无参：读回
		-- 三列改经 finite_of、eep 列改经 num_or：'nan' 过 tonumber 出的是 number
		-- （Lua 里 truthy），只判 `== nil` 挡不住——NaN 会绕过读回分支，
		-- code = math.floor(NaN) 仍是 NaN，两条钳位对 NaN 恒假放行，最后被 HAL
		-- 的 byte_of 挡成 nil 而报 "Failed to write MCP4725 DAC"，把配置笔误误报
		-- 成总线故障。eep 列后果更重：`(tonumber(x) or 0) ~= 0` 对 NaN 为真，
		-- 会在调用方从未要求持久化时走**有擦写寿命上限**的 EEPROM 写路径。
		-- 非有限值一律与同列的非数字串（'abc'/'-'）同结论（审计 P3 口径）。
		local level = finite_of(data.level)
		local volt = finite_of(data.volt)
		local percent = finite_of(data.percent)
		local eep = num_or(data.eep, 0) ~= 0

		if level == nil and volt == nil and percent == nil then
			local r = i2c_read(fd, 5)
			if r < 0 then
				return err("Failed to read MCP4725")
			end
			local rb = decode_readback(r)
			return {
				result  = "OK",
				level   = rb.level,
				eeprom  = rb.eeprom,
				pd      = rb.pd,
				volt    = rb.level * vref / 4096,
				rdy     = rb.rdy and 1 or 0
			}
		end

		-----------------------------------------------------
		-- 带参：按优先级 level > volt > percent 换算目标码
		local code
		if level ~= nil then
			code = math.floor(level)
		elseif volt ~= nil then
			code = math.floor(volt * 4096 / vref + 0.5)
		else
			code = math.floor(percent * 4095 / 100 + 0.5)
		end
		if code < 0 then code = 0 end
		if code > 4095 then code = 4095 end

		if eep then
			-- 写 DAC+EEPROM（3 字节，C2..C0=011）
			if i2c_write_multi(fd, CMD_DAC_EEPROM,
				math.floor(code / 16) % 256, (code * 16) % 256) ~= 0 then
				return err("Failed to write MCP4725 DAC+EEPROM")
			end
			-- 轮询 RDY（50ms 步进 500ms 超时；1 字节读的合并值即 byte0）
			for _ = 1, 10 do
				milli_sleep(EEPROM_POLL_MS)
				local r = i2c_read(fd, 1)
				-- 总线读失败（-1）必须与"未就绪"区分：断线误报成
				-- "EEPROM 写超时"会把排障引向错误方向（2026-09 审计）
				if r < 0 then
					return err("MCP4725 EEPROM write: bus read failed while polling RDY")
				end
				if r >= RDY_MASK then
					dbg(string.format("MCP4725 EEPROM write done: code=%d", code))
					return {
						result  = "OK",
						level   = code,
						volt    = code * vref / 4096,
						percent = code * 100 / 4095,
						eeprom  = 1
					}
				end
			end
			return err("MCP4725 EEPROM write timeout (RDY not set in 500ms)")
		end

		-- 快速写（2 字节，仅 DAC，适合高频更新）
		if i2c_write_multi(fd, CMD_FAST + math.floor(code / 256) % 256, code % 256) ~= 0 then
			return err("Failed to write MCP4725 DAC")
		end

		dbg(string.format("MCP4725 set: code=%d", code))
		return {
			result  = "OK",
			level   = code,
			volt    = code * vref / 4096,
			percent = code * 100 / 4095,
			eeprom  = 0
		}
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MCP4725_VIRT —— 2026-09-15 自 modules/lib/virtbus/mcp4725.lua
-- 整体迁入（单文件驱动+模型第八个，write-only I2C 收尾）。约定同前七者：
-- ① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零外部依赖）；
-- ② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET
-- pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与
-- 驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C（addr 挂载）。
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
-- =====================================================================

MCP4725_VIRT = { _VERSION = "0.1.0" }

local MCP4725_EEP_TYP_MS = 25	-- EEPROM 写周期典型值（datasheet 25ms，max 50ms；驱动 50ms 步进）

local function mcp4725_new_state()
	return {
		dac = 0,          -- 易失 DAC 码 0~4095
		eeprom = 0,       -- EEPROM 保存码 0~4095
		pd = 0,           -- 当前掉电位 0~3
		busy = false,     -- EEPROM 写周期进行中
		left = 0,         -- 写周期剩余 ms
	}
end

function MCP4725_VIRT.new()
	local st = mcp4725_new_state()

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
				st.left = MCP4725_EEP_TYP_MS
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
		st.left = on and (tonumber(ms) or MCP4725_EEP_TYP_MS) or 0
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
		st = mcp4725_new_state()
		wlog, rlog, polls = {}, {}, 0
		return self
	end

	return self
end

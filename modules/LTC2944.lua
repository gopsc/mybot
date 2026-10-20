-- LTC2944 多节电池电量计 驱动模块（I2C，地址固定 0x64）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 LTC2944_VIRT（2026-09-15 自 modules/lib/virtbus/ltc2944.lua
-- 迁入，单文件驱动+模型实验第十五个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LTC2944 (
--       name      String,
--       I2C       String,
--       address   String,
--       rsense    String,
--       prescaler String
--   );
--   INSERT INTO LTC2944 (name, I2C, address, rsense, prescaler)
--     VALUES ('gauge-0', 'i2c-1', '0x64', '0.05', '4096');
-- rsense = 分流电阻（Ω），缺省 0.05（50mΩ）——电荷量程与它成正比：
--   50mΩ 时最大可累计约 22.3mAh（M=4096），大容量电池组须换小阻值
--   （1mΩ -> 约 1.1Ah），勿写 '-'（占位符归一为 0 会使电流除零）
-- prescaler = 库仑计预分频 M（1/4/16/64/256/1024/4096，非法值归 4096 最大量程）
--
-- call 无需额外参数，返回
--   { result, CHARGE(累计电荷 mAh，自上电/配置起), V(电池电压 V),
--     I(电流 A，充电为正), T(温度 °C) }
-- 接 sensor_daemon：fields=CHARGE|V|I|T（浮点，勿配 sign）
--
-- 实现要点（换算经 ADI Linduino LTC2944.cpp 与内核 ltc2941-battery-gauge.c 双源核对）：
--   1. 寄存器地址与 LTC2943 不同：电压 0x08、电流 0x0E、温度 0x14（0x02 起为
--      电荷与阈值），勿照搬 LTC2943 驱动
--   2. 电压：16 位无符号，V = raw / 65535 x 70.8（满量程 70.8V，工作范围 3.6~60V）
--   3. 电流：偏移二进制（中点 0x7FFF = 0A），A = (raw - 0x7FFF)/0x7FFF x 0.064 / rsense
--      （ΔSENSE 满量程 ±64mV；LTC2943 为 ±60mV，勿混用）
--   4. 温度：°C = raw / 65535 x 510 - 273.15（满量程 510K）
--   5. 电荷：16 位无符号自上电/配置起累计，0xFFFF 回绕需上层处理；
--      mAh = code x 0.34e-3 x (M x 0.05) / (rsense x 4096)
--   6. 控制寄存器（0x01）：[7:6]=ADC 模式（0xC0 自动连续）、[5:3]=预分频码、
--      [0]=关断。本驱动配置为自动模式连续测量
--   7. 无 ID 寄存器；STATUS（0x00）仅作存在性检查（读不到 = 器件不在）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：电量计读取频率低，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_STATUS  = 0x00		-- 状态（存在性检查）
local REG_CONTROL = 0x01		-- 控制：[7:6]模式 [5:3]预分频 [0]关断
local REG_CHG_MSB = 0x02		-- 累计电荷
local REG_CHG_LSB = 0x03
local REG_V_MSB   = 0x08		-- 电池电压
local REG_V_LSB   = 0x09
local REG_I_MSB   = 0x0E		-- 电流（偏移二进制）
local REG_I_LSB   = 0x0F
local REG_T_MSB   = 0x14		-- 温度
local REG_T_LSB   = 0x15

-- ==================== 换算常数 ====================
local FS_VOLTAGE_V = 70.8			-- 电压满量程（V）
local FS_SENSE_V   = 0.064			-- ΔSENSE 满量程（±64mV）
local FS_TEMP_K    = 510.0			-- 温度满量程（K）
local CHARGE_LSB_AH = 0.34e-6		-- 电荷 LSB = 0.34e-3 mAh（= 0.34e-6 Ah，M=4096, 50mΩ）
					-- 单一事实源：mAh 形态 0.34e-3 由 :34 公式直接给出，
					-- Ah 形态 0.34e-6 仅在乘 1000 换算处使用，勿混用单位

-- ==================== 预分频 M -> 控制码（[5:3]） ====================
local presc_tab  = { 1, 4, 16, 64, 256, 1024, 4096 }

local DEF_RSENSE = 0.05			-- 缺省分流电阻 50mΩ

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rsense, presc_m

-- 读 16 位寄存器原始值；失败（-1）返回 nil（2 字节合并恒为正且精确，无回绕）
local function read_reg16(fd, reg)
	local v = i2c_read_multi(fd, reg, 2)
	if v < 0 then return nil end
	return v
end

-- 注意：CONTROL(0x01) 是 8 位寄存器，必须单字节写。若像 16 位寄存器一样
-- 发 [0x01, 0x00, ctrl] 三字节，器件寄存器指针自增会把 0x00 写进 CONTROL
-- （[7:6]=00 = Sleep 模式，器件不再转换）、把 ctrl 写进 CHG_MSB(0x02) 破坏累计电荷。

-- 预分频列 -> (M 值, 控制码)；非法/'-' 归一值落最大量程 4096
local function presc_code_of(v)
	local m = tonumber(v)
	if m ~= nil then
		for i = #presc_tab, 1, -1 do
			if m >= presc_tab[i] then return presc_tab[i], i - 1 end
		end
	end
	return 4096, 6
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rsense_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSENSE end
	return r
end

-- 【配置脚本】存在性检查 + 写控制（自动模式 + 预分频）
require_driver("i2c", {
name = "LTC2944",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		print("-------- LTC2944 builder func get a table --------")
		print_table(data)
		print("--------------------------------------------------")
	end

	-- 模块级配置：跨 call 保持
	rsense = rsense_of(data.rsense)
	presc_m = presc_code_of(data.prescaler)

	-----------------------------------------------------
	-- 存在性检查（无 ID 寄存器，读不到即失败）
	local status = read_reg16(fd, REG_STATUS)
	if status == nil then
		return err("Failed to read LTC2944 status")
	end

	-- 控制字：自动模式（[7:6]=11）| 预分频码（[5:3]）
	-- 预分频码经 presc_code_of 返回的 M 反查：码 = log4(M)
	local code
	for i = 1, #presc_tab do
		if presc_tab[i] == presc_m then code = i - 1 end
	end
	local control = bitc.bor(0xC0, bitc.lshift(code, 3))
	if not i2c_write_reg(fd, REG_CONTROL, control) then
		return err("Failed to write LTC2944 control")
	end

	print(string.format("LTC2944 init OK: addr=0x%02X, rsense=%.4f Ω, prescaler M=%d, status=0x%04X",
		addr, rsense, presc_m, status))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		print("-------- LTC2944 caller func get a table --------")
		print_table(data)
		print("-------------------------------------------------")
	end

	-- build 前置守卫：rsense/presc_m 仅 build 赋值，未 build 先 call 会做 nil 算术
	if rsense == nil or presc_m == nil then
		return err("LTC2944 not initialized (build first)")
	end

	-----------------------------------------------------
	local chg = read_reg16(fd, REG_CHG_MSB)
	if chg == nil then
		return err("Failed to read LTC2944 charge")
	end
	local vraw = read_reg16(fd, REG_V_MSB)
	if vraw == nil then
		return err("Failed to read LTC2944 voltage")
	end
	local iraw = read_reg16(fd, REG_I_MSB)
	if iraw == nil then
		return err("Failed to read LTC2944 current")
	end
	local traw = read_reg16(fd, REG_T_MSB)
	if traw == nil then
		return err("Failed to read LTC2944 temperature")
	end

	-----------------------------------------------------
	local ret = {
		result = "OK",
		CHARGE = chg * CHARGE_LSB_AH * 1000 * (presc_m * 0.05) / (rsense * 4096),
		V = vraw / 65535.0 * FS_VOLTAGE_V,
		I = (iraw - 0x7FFF) / 0x7FFF * FS_SENSE_V / rsense,
		T = traw / 65535.0 * FS_TEMP_K - 273.15
	}

	if DEBUG then
		print(string.format("LTC2944: charge=%.2fmAh V=%.3fV I=%.3fA T=%.2fC",
			ret.CHARGE, ret.V, ret.I, ret.T))
	end

	return ret

	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】LTC2944_VIRT —— 2026-09-15 自 modules/lib/virtbus/ltc2944.lua
-- 整体迁入（单文件驱动+模型第十五个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十四者：① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零
-- 外部依赖；寄存器映射表/满量程常数/bytev 系 helper 全部移入 new() 内，
-- 与上方驱动同名局部量避让）；② 工厂经全局表而非文件 return（生产侧
-- Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件
-- 返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 定位：【8 位字节指针 + 16 位大端寄存器对、指针自增模 26 回绕】样板
-- （ADI LTC2944，I2C 固定地址 0x64；纯闭包、纯算术无 bitcompat）。
-- 协议事实（ADI 手册 / Linduino LTC2944.cpp）：
--   1) 寄存器文件 0x00~0x19 共 26 字节，8 位寄存器指针；write 首字节=指针，
--      其后数据字节从该址逐字节落位（指针自增，越过 0x19 回绕 0x00），单字节
--      写=纯指针写；read(n) 从当前指针连续读、每字节后指针自增（模 26）。
--      保留地址 0x1A~0xFF 不建模（写指针按模 26 折回文件内）。
--      寄存器对（MSB 偶址 / LSB 奇址，大端）：
--        0x00 STATUS(8)      0x01 CONTROL(8，[7:6]模式 [5:3]预分频码 [0]关断)
--        0x02/03 累计电荷 u16（可主机写，用于清零/预置累计）
--        0x04/05·06/07 电荷阈值高/低（驱动不碰）
--        0x08/09 电压 u16（V = raw/65535×70.8）
--        0x0A/0B·0C/0D 电压阈值
--        0x0E/0F 电流偏移二进制（中点 0x7FFF=0A，A=(raw-0x7FFF)/0x7FFF×0.064/rsense）
--        0x10/11·12/13 电流阈值
--        0x14/15 温度 u16（K：raw/65535×510，°C 再减 273.15）
--        0x16/17·18/19 温度阈值
--   2) 【charge_msb_clobbered 哨兵协议基础】CONTROL(0x01) 是 8 位寄存器：
--      正确写帧恰 2 字节 {0x01,ctrl}；若发 3 字节 {0x01,0x00,ctrl}，指针自增
--      会把 0x00 落进 CONTROL（[7:6]=00 休眠）、ctrl 落进 CHG_MSB(0x02) 毁掉
--      累计电荷。模型忠实按指针自增落位，由测试断言驱动永不发越界 3 字节帧。
--   3) 无 ID 寄存器：build 的存在性检查 = 指针读 STATUS(0x00) 2 字节 ACK
--      （连带读回 CONTROL，驱动只看 <0）。连续测量模式结果常驻寄存器，
--      模型不模拟 ADC 转换过程/无转换门（同 INA219 族），测量值只由注入 API
--      改变，virt_tick 直接装载寄存器。
--   4) virt_tick 供守护逐拍造数：32 拍确定性正弦 V 12.0±0.4V、I 0.8±0.4A
--      （充电为正；50mΩ rsense 满量程 ±1.28A，峰值 1.2A 留余量不削顶）、
--      T 30±5°C 同相；累计电荷单调爬坡（200 code/拍，0xFFFF 回绕）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

LTC2944_VIRT = { _VERSION = "0.1.0" }

function LTC2944_VIRT.new(opts)
	local MAP_N = 0x1A -- 寄存器文件 0x00~0x19 共 26 字节

	local R = {
		STATUS = 0x00, CONTROL = 0x01,
		CHG = 0x02, V = 0x08, I = 0x0E, T = 0x14,
	}

	-- 驱动换算同源常数（仅物理量逆注入用，正算归驱动）
	local FS_VOLTAGE_V = 70.8
	local FS_SENSE_V   = 0.064
	local FS_TEMP_K    = 510.0
	local ZERO_K       = 273.15
local CHARGE_LSB_AH = 0.34e-6		-- 与驱动侧同源（仅逆注入用，正算归驱动）

	local function bytev(v)
		v = tonumber(v)
		if v == nil or v ~= math.floor(v) or v < 0 or v > 255 then return nil end
		return v
	end

	local function u16v(v)
		v = tonumber(v)
		if v == nil or v ~= math.floor(v) or v < 0 or v > 65535 then return nil end
		return v
	end

	local function clamp_u16(x)
		x = math.floor(x + 0.5)
		if x < 0 then return 0 end
		if x > 65535 then return 65535 end
		return x
	end

	opts = opts or {}
	local d = {}

	local regs = {}				-- 稀疏字节影子 0x00~0x19
	local ptr = 0				-- 当前寄存器指针
	local wr_frames = {}		-- 每笔写事务的字节表副本
	local write_count, read_count = 0, 0

	-- 故障钩子（d:reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- POR / 播种 ----------------

	local function por_seed()
		regs = {}
		ptr = 0
		-- POR：STATUS/CONTROL/各测量与阈值寄存器模型取 0
		-- （CONTROL=0x00 非自动模式；驱动 build 必写 0xC0|码，测量值只由注入改）
		local c = bytev(opts.control) or 0
		local s = bytev(opts.status) or 0
		regs[R.STATUS] = s
		regs[R.CONTROL] = c
		local pairs = {
			{ R.CHG, u16v(opts.charge) or 0 },
			{ R.V, u16v(opts.voltage) or 0 },
			{ R.I, u16v(opts.current) or 0 },
			{ R.T, u16v(opts.temp) or 0 },
		}
		for _, p in ipairs(pairs) do
			regs[p[1]] = math.floor(p[2] / 256) % 256
			regs[p[1] + 1] = p[2] % 256
		end
	end
	por_seed()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end
		local frame = {}
		for i = 1, #bytes do
			local b = bytev(bytes[i])
			if b == nil then return false end	-- 非字节：整笔 NACK，寄存器不动
			frame[i] = b
		end
		local p = frame[1] % MAP_N				-- 首字节=指针
		for i = 2, #frame do
			regs[p] = frame[i]					-- 数据逐字节落位、指针自增
			p = (p + 1) % MAP_N
		end
		ptr = p									-- 纯指针写则停在该址，多字节则停末址+1
		wr_frames[#wr_frames + 1] = frame
		write_count = write_count + 1
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(ptr, n) then return nil end
		local t = {}
		for _ = 1, n do
			t[#t + 1] = regs[ptr] or 0			-- 未播种/保留位读 0
			ptr = (ptr + 1) % MAP_N				-- 0x19 后回绕 0x00
		end
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	function d:set(reg, v)
		reg = math.floor(tonumber(reg) or -1)
		v = bytev(v)
		if reg >= 0 and reg < MAP_N and v ~= nil then regs[reg] = v end
		return self
	end

	function d:set_word(reg, word)
		reg = math.floor(tonumber(reg) or -1)
		word = u16v(word)
		if reg >= 0 and reg < MAP_N and word ~= nil then
			regs[reg] = math.floor(word / 256) % 256
			regs[(reg + 1) % MAP_N] = word % 256
		end
		return self
	end

	function d:set_status(b) return self:set(R.STATUS, b) end
	function d:set_control(b) return self:set(R.CONTROL, b) end
	function d:set_charge_raw(code) return self:set_word(R.CHG, code) end
	function d:set_voltage_raw(code) return self:set_word(R.V, code) end
	function d:set_current_raw(code) return self:set_word(R.I, code) end
	function d:set_temp_raw(code) return self:set_word(R.T, code) end

	-- 物理量逆注入（常量与驱动换算同源；仅供造数，不抄进正算链路）
	function d:set_voltage_v(v)
		v = tonumber(v)
		if v then self:set_voltage_raw(clamp_u16(v / FS_VOLTAGE_V * 65535)) end
		return self
	end
	function d:set_current_a(a, rsense)
		a = tonumber(a)
		rsense = tonumber(rsense) or 0.05
		if a and rsense > 0 then
			self:set_current_raw(clamp_u16(0x7FFF + a * rsense / FS_SENSE_V * 0x7FFF))
		end
		return self
	end
	function d:set_temp_c(t)
		t = tonumber(t)
		if t then self:set_temp_raw(clamp_u16((t + ZERO_K) / FS_TEMP_K * 65535)) end
		return self
	end
	-- mAh → code：code = mAh×rsense×4096 / (CHARGE_LSB_AH×1000×M×0.05)
	--               = mAh×rsense×4096 / (0.34e-3×M×0.05)
	function d:set_charge_mah(mah, m, rsense)
		mah = tonumber(mah)
		m = tonumber(m) or 4096
		rsense = tonumber(rsense) or 0.05
		if mah and m > 0 and rsense > 0 then
			self:set_charge_raw(clamp_u16(mah * rsense * 4096 / (CHARGE_LSB_AH * 1000 * m * 0.05)))
		end
		return self
	end

	-- 守护逐拍造数：32 拍同相正弦 + 电荷单调爬坡；直接装载寄存器（绕过任何门）
	function d:virt_tick(n)
		n = math.floor(tonumber(n) or 0)
		local s = math.sin(2 * math.pi * (n % 32) / 32)
		self:set_voltage_v(12.0 + 0.4 * s)
		self:set_current_a(0.8 + 0.4 * s, 0.05)
		self:set_temp_c(30.0 + 5.0 * s)
		self:set_charge_raw((10000 + 200 * n) % 65536)
		return self
	end

	-- ---------------- 故障 / 复位 ----------------

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

	-- 重新上电：寄存器回 POR、指针归零、留痕清空；故障钩子保留
	function d:reset()
		por_seed()
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a)
		a = math.floor(tonumber(a) or 0) % MAP_N
		return regs[a] or 0
	end
	function d:word(reg)
		reg = math.floor(tonumber(reg) or 0) % MAP_N
		return (regs[reg] or 0) * 256 + (regs[(reg + 1) % MAP_N] or 0)
	end
	function d:ptr() return ptr end
	function d:status() return regs[R.STATUS] or 0 end
	function d:control() return regs[R.CONTROL] or 0 end
	function d:charge_raw() return self:word(R.CHG) end
	function d:voltage_raw() return self:word(R.V) end
	function d:current_raw() return self:word(R.I) end
	function d:temp_raw() return self:word(R.T) end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:frames() return wr_frames end

	return d
end

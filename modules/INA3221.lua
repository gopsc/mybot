-- INA3221 三通道高边电流/电压监测计 驱动模块（I2C，地址 0x40~0x43）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 INA3221_VIRT（2026-09-15 自 modules/lib/virtbus/ina3221.lua
-- 迁入，单文件驱动+模型实验第二十八个，字寻址三通道族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA3221 (
--       name    String,
--       I2C     String,
--       address String,
--       avg     String,
--       rshunt1 String,
--       rshunt2 String,
--       rshunt3 String
--   );
--   INSERT INTO INA3221 (name, I2C, address, avg, rshunt1, rshunt2, rshunt3)
--     VALUES ('ina3221-0', 'i2c-1', '0x40', '16', '0.01', '0.01', '0.01');
-- avg = 每次测量的平均样本数（1/4/16/64/128/256/512/1024，非法值归 16）
-- rshuntN = 通道 N 分流电阻阻值（欧姆），缺省/非法按 0.01Ω（10mΩ，CJMCU 模块板载值）
-- 注意：rshuntN 勿写 '-'（占位符归一为 0 会使电流除零，与 ADS1115 pga/dr 同理）
--
-- call 无需额外参数，一次读全三通道，返回
--   { result, V1, I1, V2, I2, V3, I3 }（总线电压 V；电流 A，反流为负）
-- 接 sensor_daemon：fields=V1|I1|V2|I2|V3|I3（浮点，勿配 sign）
--
-- 实现要点（换算依 Linux 内核 drivers/hwmon/ina3221.c 钉死）：
--   1. 分流/总线寄存器同为 13 位有效、左移 3 位存放，读取后 >> 3；
--      分流为有符号（补码），LSB 40µV；总线无符号，LSB 8mV
--      （INA219 移植陷阱：两颗芯片对齐方向与 LSB 均不同，勿照搬 Arduino INA219 库）
--   2. 连续模式（MODE=111）下寄存器始终保有最近一次完成的转换值，call 直接读；
--      build 后等待一个完整转换循环（通道数 x (总线CT+分流CT) x 平均次数）再返回，
--      避免首拍读到复位零值
--   3. 一个芯片 = 一个硬件变量：配置寄存器是芯片级的，勿按通道拆变量互相覆盖
--   4. 电流 = 分流压降 / Rshunt，有符号；芯片内无电流/功率寄存器（INA219 的
--      校准寄存器在 INA3221 上已取消），换算全在驱动侧
--   5. build 校验制造商/芯片 ID：0xFE=0x5449("TI")、0xFF=0x3220

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_CONFIG  = 0x00
local REG_SHUNT1  = 0x01		-- 通道1 分流电压
local REG_BUS1    = 0x02		-- 通道1 总线电压
local REG_SHUNT2  = 0x03
local REG_BUS2    = 0x04
local REG_SHUNT3  = 0x05
local REG_BUS3    = 0x06
local REG_MASK    = 0x0F		-- 标志/使能（bit0 = CVRF 转换就绪）
local REG_MANUF   = 0xFE			-- 制造商 ID：0x5449("TI")
local REG_DIE     = 0xFF			-- 芯片 ID：0x3220

local ID_MANUF    = 0x5449
local ID_DIE      = 0x3220

-- ==================== 配置位（内核 ina3221.c 同款布局） ====================
-- [15]=RST [14:12]=通道使能(ch1=bit14,ch2=13,ch3=12) [11:9]=AVG
-- [8:6]=总线CT [5:3]=分流CT [2:0]=MODE(bit0 分流/bit1 总线/bit2 连续)
local CFG_RST        = 0x8000
local CFG_CH_ALL     = bitc.lshift(0x7, 12)	-- 0x7<<12（3 通道全使能）
local CFG_MODE_CONT  = 0x7			-- 连续 + 分流 + 总线
local CT_1100US      = 4			-- CT 代码 100 = 1.1ms

-- 平均样本数 -> AVG 代码（000~111）
local avg_tab = { 1, 4, 16, 64, 128, 256, 512, 1024 }

local DEF_RSHUNT = 0.01			-- 缺省分流电阻 10mΩ

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt1, rshunt2, rshunt3

-- 换算常数
local SHUNT_LSB_V = 40e-6			-- 分流寄存器 LSB：40µV（>>3 后有符号 13 位）
local BUS_LSB_V   = 0.008			-- 总线寄存器 LSB：8mV（>>3 后无符号 13 位）

-- 13 位有符号还原（分流寄存器 >>3 后使用）
local function s13(v)
	if v >= 0x1000 then v = v - 0x2000 end
	return v
end

-- 读 16 位寄存器原始值；失败（-1）返回 nil（2 字节合并恒为正且精确，无回绕）
local function read_reg16(fd, reg)
	local v = i2c_read_multi(fd, reg, 2)
	if v < 0 then return nil end
	return v
end

-- 写 16 位寄存器（i2c_write_multi 返回 0 = 成功）
local function write_reg16(fd, reg, val16)
	local hi = math.floor(val16 / 256) % 256
	local lo = val16 % 256
	return i2c_write_multi(fd, reg, hi, lo) == 0
end

-- 平均样本数列 -> AVG 代码（非法/占位归一值落到最近的合法档，缺省 16）
local function avg_code_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return 2, 16 end		-- 代码 2 = 16 次
	for i = #avg_tab, 1, -1 do
		if n >= avg_tab[i] then return i - 1, avg_tab[i] end
	end
	return 2, 16
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

-- 【配置脚本】校验 ID -> 软复位 -> 写配置（连续模式/三通道/平均）-> 等待首拍就绪
require_driver("i2c", {
name = "INA3221",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- INA3221 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-- 模块级配置：跨 call 保持
	local avg_idx, avg_n = avg_code_of(data.avg)
	rshunt1 = rshunt_of(data.rshunt1)
	rshunt2 = rshunt_of(data.rshunt2)
	rshunt3 = rshunt_of(data.rshunt3)

	-----------------------------------------------------
	-- 校验芯片身份
	local manuf = read_reg16(fd, REG_MANUF)
	local die = read_reg16(fd, REG_DIE)
	if manuf == nil or die == nil then
		return err("Failed to read INA3221 IDs")
	end
	if manuf ~= ID_MANUF or die ~= ID_DIE then
		return err(string.format("Unexpected IDs: manuf=0x%04X die=0x%04X (not INA3221?)", manuf, die))
	end

	-- 软复位，随后写入工作配置
	if not write_reg16(fd, REG_CONFIG, CFG_RST) then
		return err("Failed to write INA3221 reset")
	end
	milli_sleep(10)

	-- 连续模式 + 三通道使能 + 平均 + 1.1ms 转换时间
	local config = bitc.bor(CFG_CH_ALL,
		bitc.bor(bitc.lshift(avg_idx, 9),
		bitc.bor(bitc.lshift(CT_1100US, 6),
		bitc.bor(bitc.lshift(CT_1100US, 3), CFG_MODE_CONT))))
	if not write_reg16(fd, REG_CONFIG, config) then
		return err("Failed to write INA3221 config")
	end

	-- 等待一个完整转换循环（3 通道 x (总线CT+分流CT) x 平均次数），首拍数据就绪
	local loop_ms = math.ceil(3 * (1.1 + 1.1) * avg_n) + 2
	milli_sleep(loop_ms)

	print(string.format("INA3221 init OK: addr=0x%02X, avg=%d, rshunt=%.4f/%.4f/%.4f Ω",
		addr, avg_n, rshunt1, rshunt2, rshunt3))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- INA3221 caller func get a table --------", data)
	end

	-----------------------------------------------------

	-- build 前置守卫：rshunt1..3 仅 build 赋值，未 build 先 call 会做 nil 除法
	-- 裸 error（与 INA219 的守卫对齐）
	if rshunt1 == nil or rshunt2 == nil or rshunt3 == nil then
		return err("INA3221 not built (build first)")
	end

	-----------------------------------------------------
	local regs = { REG_SHUNT1, REG_BUS1, REG_SHUNT2, REG_BUS2, REG_SHUNT3, REG_BUS3 }
	local raw = {}
	for i, reg in ipairs(regs) do
		raw[i] = read_reg16(fd, reg)
		if raw[i] == nil then
			return err("Failed to read INA3221 register 0x" .. string.format("%02X", reg))
		end
	end

	local rsh = { rshunt1, rshunt2, rshunt3 }
	local ret = {  result = "OK"  }
	for ch = 1, 3 do
		local s = raw[2 * ch - 1]
		local b = raw[2 * ch]
		local shunt_v = s13(bitc.rshift(s, 3)) * SHUNT_LSB_V		-- 分流压降（V，有符号）
		local bus_v = bitc.rshift(b, 3) * BUS_LSB_V				-- 总线电压（V）
		-- 返回字典：Vn = 总线电压，In = 电流（可负）
		ret["V" .. ch] = bus_v
		ret["I" .. ch] = shunt_v / rsh[ch]
	end

	if DEBUG then
		print(string.format(
			"INA3221: ch1 %.3fV %.3fA | ch2 %.3fV %.3fA | ch3 %.3fV %.3fA",
			ret.V1, ret.I1, ret.V2, ret.I2, ret.V3, ret.I3))
	end

	return ret

	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】INA3221_VIRT —— 2026-09-15 自 modules/lib/virtbus/ina3221.lua
-- 整体迁入（单文件驱动+模型第二十八个，字寻址三通道族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前二十七者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，自包含字寻址实现；截幅 helper/s13 移入段内加 ina3221_
-- 前缀避让（驱动文件级有同名 s13——三方独立换算互证设计）；new() 内
-- `local ina3221 = INA3221_VIRT` 绑定使模型体零改动移植）；② 工厂经全局表
-- 而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且
-- 成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现。
-- 无 BUS 字段 = I2C。
--
-- 【字寻址 16 位寄存器 I2C 器件】（与 ina219/ina226 同族，绝不能套字节地址
-- regmap——寄存器号各代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回该字
-- hi/lo）。与单通道 INA226 的协议事实差异逐条独立（勿互抄常数）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[14:12]=通道使能
--                （ch1=bit14/ch2=13/ch3=12）[11:9]=AVG [8:6]=VBUSCT
--                [5:3]=VSHCT [2:0]=MODE；上电/复位默认 0x7127（3 通道全使能、
--                AVG=1、双 1.1ms、连续）。【全 16 位均有定义、无保留位】
--                （INA226 bit14 恒 1/bit13:12 恒 0，读出需合成）
--   0x01/0x02   通道1 SHUNT/BUS，0x03/0x04 通道2，0x05/0x06 通道3：
--                分流/总线【同为 13 位有效、左移 3 位存放】（低 3 位恒 0），
--                驱动读后 >>3；分流 s13 有符号 LSB 40µV（量程 ±163.84mV），
--                总线 u13 无符号 LSB 8mV（满码 8191 = 65.528V）
--   0x07~0x0E   各通道 CRITICAL/WARNING 告警限、分流和/和限（驱动不用，
--                协议存在照存）；0x0F MASK/ENABLE（bit0=CVRF，驱动不读不写）；
--                0x10/0x11 POWER-VALID 上下限同
--   0xFE MANUFACTURER_ID 恒 0x5449（'TI'）、0xFF DIE_ID 恒 0x3220：真 ROM ID，
--                只读——写 ACK 但丢弃，who() 可覆写喂 build 误挂负路径。
--                注意与 INA226（DIE=0x2260）不同
--
-- 连续模式（MODE=111，驱动 build 固定）下六个结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个完整
-- 转换循环」只是 sleep，模型不计时。通道使能位只照存，模型不模拟转换引擎。
-- 软复位是本模型唯一的写副作用：向 CONFIG 写 bit15=1 的字时 0x8000 不落盘，
-- 寄存器文件原地恢复上电态（RST 自清）。
--
-- 用法：
--   vbus.load_driver("modules/INA3221.lua")  -- 定义全局 build/call/destroy 与 INA3221_VIRT
--   local dev = INA3221_VIRT.new()           -- 复位配置默认 0x7127 + ROM ID
--   dev:set_vi(1, 12.0, 0.005)               -- 通道1：总线 12V、分流压降 5mV
--   vbus.attach("INA3221@0x40", 0x40, dev)
--
--   dev:who(0x0000, 0x3220)    -- 覆写厂商 ID 模拟误挂（build 甄别失败）
--   dev.nack_read = true       -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号/左移 3/ROM ID 与软复位语义；
-- I=Vshunt/R 换算全在驱动（芯片内无电流/功率寄存器），物理量注入 API
-- （set_vi/set_current_a）的常量仅为造样本，测试另做独立换算交叉。
-- =====================================================================

INA3221_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		CONFIG = 0x00,
		SHUNT  = { 0x01, 0x03, 0x05 },	-- 通道 1/2/3 分流电压
		BUS    = { 0x02, 0x04, 0x06 },	-- 通道 1/2/3 总线电压
		MASK   = 0x0F,
		MFG    = 0xFE,
		DIE    = 0xFF,
	}
}

-- 标量常数（逐条挂工厂表）


INA3221_VIRT.CFG_DEFAULT = 0x7127		-- 复位/上电默认（3ch 全使能、AVG=1、双 1.1ms、连续）
INA3221_VIRT.MFG_ID = 0x5449			-- 'TI'
INA3221_VIRT.DIE_ID = 0x3220
INA3221_VIRT.SHUNT_LSB_V = 40e-6		-- 分流 13 位有符号（>>3 后）LSB 40µV
INA3221_VIRT.BUS_LSB_V   = 0.008		-- 总线 13 位无符号（>>3 后）LSB 8mV
INA3221_VIRT.DEF_RSHUNT  = 0.01		-- CJMCU-3221 板载 10mΩ

-- 13 位有符号还原（与驱动 s13 同款：寄存器字 >>3 后调用；独立实现）
local function ina3221_s13(v)
	if v >= 0x1000 then v = v - 0x2000 end
	return v
end

function INA3221_VIRT.new(opts)
	local ina3221 = INA3221_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local function s13(v) return ina3221_s13(v) end

	local d = {}
	local regs = {}				-- 字地址（0~255）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local mfg_id = opts.mfg_id or ina3221.MFG_ID
	local die_id = opts.die_id or ina3221.DIE_ID
	local reset_cfg = opts.reset_cfg or ina3221.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ina3221.REG.CONFIG] = reset_cfg
		regs[ina3221.REG.MFG] = mfg_id
		regs[ina3221.REG.DIE] = die_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- 通道号 1/2/3 → 该类寄存器字地址；非法通道返回 nil
	local function ch_reg(tab, ch)
		ch = math.floor(tonumber(ch) or 0)
		if ch >= 1 and ch <= 3 then return tab[ch] end
		return nil
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 1 字节 {reg} = 纯指针写；恰 3 字节 {reg,hi,lo} = 写一个 16 位寄存器；
	-- 其余长度在本器件协议下不存在，NACK。
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		ptr = p
		if #bytes == 1 then return true end
		-- 写 CONFIG 且最高位 RST=1：0x8000 不落盘，原地系统复位、RST 自清。
		-- （datasheet：RST 写 1 即产生与上电相同的复位，同写其他位被忽略）
		if p == ina3221.REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == ina3221.REG.MFG or p == ina3221.REG.DIE then
			-- ROM ID 只读：写 ACK 但丢弃，不改身份
		else
			-- CONFIG 全 16 位有定义（无保留位），其余寄存器照存
			regs[p] = word
		end
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA3221 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local wi = p + math.floor((i - 1) / 2)
			local word = regs[wi] or 0
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------
	-- 码域 = 驱动 >>3 之后的 13 位码；模型按器件事实左移 3 存放。

	-- 通道 ch 分流码：s13 有符号 -4096~4095（接受负码，自动补码左移）
	function d:set_shunt_raw(ch, code)
		local reg = ch_reg(ina3221.REG.SHUNT, ch)
		if reg then
			regs[reg] = (clampi(math.floor(code + 0.5), -4096, 4095) * 8) % 65536
		end
		return self
	end

	-- 通道 ch 总线码：u13 无符号 0~8191
	function d:set_bus_raw(ch, code)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if reg then
			regs[reg] = clampi(math.floor(code), 0, 8191) * 8
		end
		return self
	end

	-- 告警限/MASK/POWER-VALID 等驱动不解释的协议寄存器，留原始 16 位码注入口
	function d:set_word(reg, word)
		reg = clampi(math.floor(reg), 0, 255)
		regs[reg] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 通道 ch 总线电压 V（u13，LSB 8mV，满码 65.528V）
	function d:set_bus_v(ch, v)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if reg then
			local code = clampi(math.floor(v / ina3221.BUS_LSB_V + 0.5), 0, 8191)
			regs[reg] = code * 8
		end
		return self
	end

	-- 通道 ch 分流压降 V（s13，LSB 40µV，量程 ±163.84mV）
	function d:set_shunt_v(ch, v)
		return self:set_shunt_raw(ch, math.floor(v / ina3221.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐一个通道：总线电压 + 分流压降
	function d:set_vi(ch, bus_v, shunt_v)
		self:set_bus_v(ch, bus_v)
		if shunt_v ~= nil then self:set_shunt_v(ch, shunt_v) end
		return self
	end

	-- 按电流造通道分流压降：Vshunt = I × R（r 缺省 0.01Ω，须与 build 的 rshuntN 一致）
	function d:set_current_a(ch, a, r)
		r = tonumber(r) or ina3221.DEF_RSHUNT
		return self:set_shunt_v(ch, a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期，三条典型母线/负载（均按板载 10mΩ 反推分流压降，远在
	-- ±163.84mV 量程内不削顶），无随机、E2E 数值可复现：
	--   ch1 12.0±0.4V、0.5±0.3A（分流 2~8mV）
	--   ch2 12.0±0.4V、1.0±0.4A（分流 6~14mV）
	--   ch3  5.0±0.2V、0.3±0.15A（分流 1.5~4.5mV）
	-- 三通道同相；连续模式无武装概念，直接更新结果寄存器（守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		local R = ina3221.DEF_RSHUNT
		self:set_vi(1, 12.0 + 0.4 * s, (0.5 + 0.3 * s) * R)
		self:set_vi(2, 12.0 + 0.4 * s, (1.0 + 0.4 * s) * R)
		self:set_vi(3, 5.0 + 0.2 * s, (0.3 + 0.15 * s) * R)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写软复位后的 CONFIG 默认值（立即把 CONFIG 置于该值，软复位后也是它；
	-- nil=不改。INA3221 驱动 build 不读回配置，此口供模型级复位事实测试）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[ina3221.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 ROM ID（nil = 不改；软复位不恢复出厂值，喂 build 误挂甄别路径；
	-- 测试 section 须显式 who() 恢复，避免跨用例污染）
	function d:who(mfg, die)
		if mfg ~= nil then
			mfg_id = math.floor(mfg) % 65536
			regs[ina3221.REG.MFG] = mfg_id
		end
		if die ~= nil then
			die_id = math.floor(die) % 65536
			regs[ina3221.REG.DIE] = die_id
		end
		return self
	end

	-- 驱动 build 写过的寄存器字写：write_log 中恰 3 字节事务 {reg,hi,lo}；
	-- 1 字节事务是读寄存器指针。
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

	function d:reset_count() return reset_count end
	function d:pointer() return ptr end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回上电态（保留故障钩子：复位不得解除测试钩子；who() 覆写身份同样
	-- 保留——测试须显式恢复）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config() return regs[ina3221.REG.CONFIG] or 0 end
	function d:mfg()    return regs[ina3221.REG.MFG] or 0 end
	function d:die()    return regs[ina3221.REG.DIE] or 0 end
	function d:word(reg) return regs[reg] or 0 end

	-- 通道 ch 分流寄存器字 → >>3 → s13 有符号码
	function d:shunt_raw(ch)
		local reg = ch_reg(ina3221.REG.SHUNT, ch)
		if not reg then return nil end
		return s13(math.floor((regs[reg] or 0) / 8))
	end

	-- 通道 ch 总线寄存器字 → >>3（u13 无符号）
	function d:bus_raw(ch)
		local reg = ch_reg(ina3221.REG.BUS, ch)
		if not reg then return nil end
		return math.floor((regs[reg] or 0) / 8)
	end

	function d:shunt_v(ch)  return self:shunt_raw(ch) * ina3221.SHUNT_LSB_V end
	function d:bus_v(ch)    return self:bus_raw(ch) * ina3221.BUS_LSB_V end
	function d:current_a(ch, r)
		return self:shunt_v(ch) / (tonumber(r) or ina3221.DEF_RSHUNT)
	end

	return d
end

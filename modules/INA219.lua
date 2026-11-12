-- INA219 单通道高边电流/功率监测计 驱动模块（I2C，地址 0x40~0x4F）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 INA219_VIRT（2026-09-15 自 modules/lib/virtbus/ina219.lua
-- 迁入，单文件驱动+模型实验第十三个，字寻址 16 位寄存器族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA219 (
--       name    String,
--       I2C     String,
--       address String,
--       rshunt  String,
--       avg     String
--   );
--   INSERT INTO INA219 (name, I2C, address, rshunt, avg)
--     VALUES ('ina219-0', 'i2c-1', '0x40', '0.1', '16');
-- rshunt = 分流电阻阻值（欧姆）。CJMCU-219 模块板载 R100 = 0.1Ω（缺省值），
--   量程 ±320mV -> 约 ±3.2A；动力电堵转电流大时注意换小阻值或改用 INA3221（10mΩ）
-- avg = 每次测量的平均样本数（1/2/4/8/16/32/64/128，非法值归 16）
-- 注意：rshunt 勿写 '-'（占位符归一为 0 会使电流除零，与 ADS1115 pga/dr 同理）
--
-- call 无需额外参数，返回 { result, V(总线电压 V), I(电流 A，反流为负), P(功率 W) }
-- 接 sensor_daemon：fields=V|I|P（浮点，勿配 sign）
--
-- 实现要点（换算依 Linux 内核 drivers/iio/adc/ina2xx-adc.c 钉死）：
--   1. 分流寄存器 16 位完整有符号、无移位，LSB 10µV（PGA=/8 时量程 ±320mV）；
--      总线寄存器 13 位有效、左移 3 位（读后 >>3），LSB 4mV
--      （INA3221 是 13 位左移 3 / LSB 40µV，两颗芯片对齐与 LSB 均不同，勿照搬）
--   2. INA219 没有 ID 寄存器（INA3221 的 0xFE/0xFF 在此不存在）：
--      build 以「软复位后读回配置默认值 0x399F」做芯片甄别
--      （INA226 默认 0x4127，可区分；INA226 本身有 0xFE/0xFF ID 寄存器，无需此法）
--   3. 电流/功率寄存器（0x04/0x03）需写校准寄存器才有效——本驱动不写校准，
--      全软件换算：I = 分流压降 / Rshunt，P = V x I（与内核 ina2xx 驱动同思路，
--      省去 Current_LSB/校准公式换算链）
--   4. 连续模式（MODE=111）下寄存器始终保有最近完成的转换值，call 直接读；
--      build 后等一个转换循环（总线+分流 各 532µs x 平均次数）再返回
--   5. BRNG=1（32V 档）+ PGA=/8，器件额定测量范围仍为 0~26V

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
local REG_SHUNT   = 0x01		-- 分流电压（16 位有符号）
local REG_BUS     = 0x02		-- 总线电压（13 位左移 3，无符号）
local REG_MASK    = 0x06		-- 标志：bit1=CNVR 转换就绪，bit0=OVF 溢出

-- 配置默认值（软复位后读回应等于此值，作为芯片甄别）
local CFG_DEFAULT = 0x399F		-- BRNG=32V, PGA=/8, 双 ADC 12 位, 连续模式

-- ==================== 配置位 ====================
-- [15]=RST [13]=BRNG [12:11]=PGA [10:7]=BADC [6:3]=SADC [2:0]=MODE
local CFG_RST      = 0x8000
local CFG_BRNG_32V = bitc.lshift(1, 13)	-- 1<<13（LuaJIT 5.1 无 <<，走 bitcompat）
local CFG_PGA_DIV8 = bitc.lshift(3, 11)	-- 3<<11（分流量程 ±320mV）
local CFG_MODE_CONT = 0x7			-- 连续 + 分流 + 总线

local IT_532US_US = 532			-- 12 位单次转换时间（µs），平均模式的基时

-- 平均样本数 -> SADC/BADC 代码。datasheet 表：3=12 位单次 532µs、
-- 9=2 次、10=4、11=8、12=16、13=32、14=64、15=128 次平均
-- （8 是 12 位单次的别名码，不是"2 次平均"——旧表把 2 次映射到 8 使
-- avg≥2 的每一档实际平均次数减半，2026-09 审计 S3 已修）
local avg_tab  = { 1, 2, 4, 8, 16, 32, 64, 128 }
local avg_code = { 3, 9, 10, 11, 12, 13, 14, 15 }

local DEF_RSHUNT = 0.1			-- 缺省分流电阻 100mΩ（CJMCU-219 板载 R100）

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt

-- 换算常数
local SHUNT_LSB_V = 10e-6			-- 分流寄存器 LSB：10µV（16 位有符号）
local BUS_LSB_V   = 0.004			-- 总线寄存器 LSB：4mV（>>3 后 13 位无符号）

-- 16 位有符号还原（分流寄存器用）
local s16 = bitc.s16

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

-- 平均样本数列 -> 代码（非法/'-' 归一值落到最近的合法档，缺省 16 次 = code 12）
local function avg_code_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return 12, 16 end
	for i = #avg_tab, 1, -1 do
		if n >= avg_tab[i] then return avg_code[i], avg_tab[i] end
	end
	return 12, 16
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

require_driver("i2c", {
	name = "INA219",

	-- 【配置脚本】软复位 -> 配置默认值甄别芯片 -> 写工作配置 -> 等待首拍就绪
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- INA219 builder func get a table --------", data)
		end

		local fd = ctx.fd

		-- 模块级配置：跨 call 保持
		local avg_code_v, avg_n = avg_code_of(data.avg)
		rshunt = rshunt_of(data.rshunt)

		-----------------------------------------------------
		-- 软复位
		if not write_reg16(fd, REG_CONFIG, CFG_RST) then
			return err("Failed to write INA219 reset")
		end
		milli_sleep(10)

		-- 无 ID 寄存器：读回配置默认值甄别芯片（INA3221 的 0xFE/0xFF 手段在此不存在）
		local cfg = read_reg16(fd, REG_CONFIG)
		if cfg == nil then
			return err("Failed to read INA219 config")
		end
		if cfg ~= CFG_DEFAULT then
			return err(string.format("Config after reset = 0x%04X (expect 0x%04X, not INA219?)", cfg, CFG_DEFAULT))
		end

		-- 写工作配置：32V 档 + PGA /8 + 平均 + 连续模式
		local config = bitc.bor(CFG_BRNG_32V,
			bitc.bor(CFG_PGA_DIV8,
			bitc.bor(bitc.lshift(avg_code_v, 7),
			bitc.bor(bitc.lshift(avg_code_v, 3), CFG_MODE_CONT))))
		if not write_reg16(fd, REG_CONFIG, config) then
			return err("Failed to write INA219 config")
		end

		-- 等待一个转换循环（总线 + 分流 各 532µs x 平均次数），首拍数据就绪
		local loop_ms = math.ceil(2 * IT_532US_US * avg_n / 1000) + 2
		milli_sleep(loop_ms)

		print(string.format("INA219 init OK: addr=0x%02X, avg=%d, rshunt=%.4f Ω", ctx.addr, avg_n, rshunt))
		return {  result = "OK"  }
	end,

	-- 【调用INA219】读单通道：总线电压（V）、电流（A，反流为负）、功率（W）
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- INA219 caller func get a table --------", data)
		end

		-- build 前调用时 rshunt 为 nil，除法会抛裸 Lua error（pcall 兜底信息难看）
		if rshunt == nil then
			return err("INA219 not built (build first)")
		end

		local fd = ctx.fd

		-----------------------------------------------------
		local s = read_reg16(fd, REG_SHUNT)
		if s == nil then
			return err("Failed to read INA219 shunt voltage")
		end
		local b = read_reg16(fd, REG_BUS)
		if b == nil then
			return err("Failed to read INA219 bus voltage")
		end

		-----------------------------------------------------
		local shunt_v = s16(s) * SHUNT_LSB_V			-- 分流压降（V，有符号）
		local bus_v = bitc.rshift(b, 3) * BUS_LSB_V	-- 总线电压（V）

		local ret = {
			result = "OK",
			V = bus_v,						-- 总线电压（V）
			I = shunt_v / rshunt,				-- 电流（A，可负）
			P = bus_v * shunt_v / rshunt		-- 功率（W，软件计算）
		}

		if DEBUG then
			print(string.format("INA219: V=%.3fV I=%.3fA P=%.3fW", ret.V, ret.I, ret.P))
		end

		return ret
	end,

	-- destroy 缺省 = 空操作（原 INA219 destroy 仅 arg_table + return OK，等价）
})


-- =====================================================================
-- 【内嵌虚拟器件模型】INA219_VIRT —— 2026-09-15 自 modules/lib/virtbus/ina219.lua
-- 整体迁入（单文件驱动+模型第十三个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十二者：① 生产路径零执行（new() 仅虚拟总线测试调用，自包含
-- 字寻址实现、无 regmap；截幅辅助改名 ina219_clampi 保文件级唯一）；
-- ② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET
-- pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与
-- 驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 【首个字寻址 16 位寄存器 I2C 器件】（不用 regmap——regmap 底座是字节地址
-- burst，适配 MPU6050/BME280 类「每字节一个寄存器号」器件；INA219 的寄存器号
-- 0x00~0x05 各自代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回的是该字的
-- hi/lo，不是字节地址 ptr、ptr+1——直接套 regmap 会把相邻寄存器的高低字节
-- 串读出来）。寄存器事实（TI datasheet SBOS448）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[13]=BRNG [12:11]=PGA
--                [10:7]=BADC [6:3]=SADC [2:0]=MODE；上电/复位默认 0x399F
--                （INA226 默认 0x4127——本器件无 ID 寄存器，驱动就靠复位后
--                  读回 0x399F 做芯片甄别，可用 set_reset_id 模拟错挂）
--   0x01 SHUNT_VOLTAGE 16 位完整有符号、无移位，LSB 10µV（PGA=/8 量程 ±320mV）
--   0x02 BUS_VOLTAGE   13 位有效左移 3 位存放（读后 >>3），LSB 4mV；
--                      bit1=CNVR、bit0=OVF 标志位（驱动不用，保留可注入）
--   0x03 POWER / 0x04 CURRENT / 0x05 CALIBRATION：本驱动不写校准、全软件换算，
--      协议上存在，照读照写（未预置读 0），模型不解释
--
-- 连续模式（MODE=111，驱动 build 固定）下结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个转换
-- 循环」只是 sleep，模型不计时。软复位是本模型唯一的写副作用：向 CONFIG
-- 写 bit15=1 的字时，0x8000 不落盘，寄存器文件原地恢复上电态（RST 自清）。
--
-- 用法：
--   vbus.load_driver("modules/INA219.lua")  -- 定义全局 build/call/destroy 与 INA219_VIRT
--   local dev = INA219_VIRT.new()           -- 复位配置默认 0x399F
--   dev:set_vip(12.0, 0.1)                  -- 总线 12V、分流压降 100mV
--   vbus.attach("INA219@0x40", 0x40, dev)
--
--   dev:set_reset_id(0x4127)  -- 模拟错挂 INA226（复位读回不符即甄别失败）
--   dev.nack_read = true      -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号与软复位语义；I=Vshunt/R、
-- P=Vbus·I 的换算全在驱动，物理量注入 API（set_vip/set_current_a）的常量
-- 仅为造样本，测试另做独立换算交叉，避免模型与驱动共用一份理解互证假绿。
-- =====================================================================

INA219_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		CONFIG = 0x00,
		SHUNT  = 0x01,
		BUS    = 0x02,
		POWER  = 0x03,
		CURRENT= 0x04,
		CALIB  = 0x05,
	},
	CFG_DEFAULT = 0x399F,		-- 复位/上电默认（BRNG=32V,PGA=/8,双 12 位,连续）
	SHUNT_LSB_V = 10e-6,		-- 分流寄存器 LSB 10µV（PGA=/8）
	BUS_LSB_V   = 0.004,		-- 总线寄存器 LSB 4mV（13 位）
	DEF_RSHUNT  = 0.1,		-- CJMCU-219 板载 R100
}

local function ina219_clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function INA219_VIRT.new(opts)
	local REG = INA219_VIRT.REG
	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~5）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local reset_id = opts.reset_id or INA219_VIRT.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[REG.CONFIG] = reset_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
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
		if p == REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		regs[p] = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA219 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local within = (i - 1) % 2
			local word = regs[p + math.floor((i - 1) / 2)] or 0
			out[i] = within == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- SHUNT_VOLTAGE：16 位有符号 LSB（接受负码，自动补码）
	function d:set_shunt_raw(raw)
		regs[REG.SHUNT] = ina219_clampi(math.floor(raw + 0.5), -32000, 32000) % 65536
		return self
	end

	-- BUS_VOLTAGE：直接写 16 位寄存器字（含低 3 位标志，调用方自行布局）
	function d:set_bus_raw(word)
		regs[REG.BUS] = ina219_clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- 注入总线低 3 位标志（bit1=CNVR、bit0=OVF），不影响高 13 位电压码
	function d:set_bus_flags(cnvr, ovf)
		local w = regs[REG.BUS] or 0
		local code = w - (w % 8)
		if cnvr then code = code + 2 end
		if ovf then code = code + 1 end
		return self:set_bus_raw(code)
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 总线电压 V（13 位码 <<3 存放，0~32.764V；额定 26V 以上为器件超额定区）
	function d:set_bus_v(v)
		local code = ina219_clampi(math.floor(v / INA219_VIRT.BUS_LSB_V + 0.5), 0, 8191)
		return self:set_bus_raw(code * 8)
	end

	-- 分流压降 V（有符号，PGA=/8 量程 ±320mV）
	function d:set_shunt_v(v)
		return self:set_shunt_raw(math.floor(v / INA219_VIRT.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐：总线电压 + 分流压降
	function d:set_vip(bus_v, shunt_v)
		self:set_bus_v(bus_v)
		if shunt_v ~= nil then self:set_shunt_v(shunt_v) end
		return self
	end

	-- 按电流造分流压降：Vshunt = I × R（r 缺省 0.1Ω，须与驱动 build 的 rshunt 一致）
	function d:set_current_a(a, r)
		r = tonumber(r) or INA219_VIRT.DEF_RSHUNT
		return self:set_shunt_v(a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期：总线 12.0 ± 0.4V（11.6~12.4V）、电流 1.0 ± 0.6A（0.4~1.6A，
	-- 按板载 R100 反推分流压降 40~160mV），同相位；无随机，E2E 数值可复现。
	-- 连续模式无武装概念，直接更新结果寄存器即可（守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_vip(12.0 + 0.4 * s, (1.0 + 0.6 * s) * INA219_VIRT.DEF_RSHUNT)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 改复位后读回的配置默认值（0x4127 模拟 INA226 错挂，喂 build 甄别路径）；
	-- 立即把 CONFIG 置于该值（build 首笔 RST 写后 reseed 也是它）
	function d:set_reset_id(word)
		reset_id = math.floor(word) % 65536
		regs[REG.CONFIG] = reset_id
		return self
	end

	-- 驱动 build 写过的寄存器写：write_log 中恰 3 字节事务 {reg,hi,lo}；
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

	-- 回上电态（保留故障钩子，与 ads1256/sgp30 约定一致：复位不得解除测试钩子）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config()    return regs[REG.CONFIG] or 0 end
	function d:shunt_raw()
		local v = regs[REG.SHUNT] or 0
		if v >= 0x8000 then v = v - 0x10000 end
		return v
	end
	function d:bus_raw()   return regs[REG.BUS] or 0 end
	function d:shunt_v()   return self:shunt_raw() * INA219_VIRT.SHUNT_LSB_V end
	function d:bus_v()     return math.floor(self:bus_raw() / 8) * INA219_VIRT.BUS_LSB_V end
	function d:current_a(r) return self:shunt_v() / (tonumber(r) or INA219_VIRT.DEF_RSHUNT) end
	function d:power_w(r)  return self:bus_v() * self:current_a(r) end

	return d
end

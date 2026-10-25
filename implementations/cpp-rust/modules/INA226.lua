-- INA226 单通道高边电流/功率监测计 驱动模块（I2C，地址 0x40~0x4F）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 INA226_VIRT（2026-09-15 自 modules/lib/virtbus/ina226.lua
-- 迁入，单文件驱动+模型实验第二十五个，字寻址 16 位寄存器族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE INA226 (
--       name    String,
--       I2C     String,
--       address String,
--       rshunt  String,
--       avg     String,
--       ct      String
--   );
--   INSERT INTO INA226 (name, I2C, address, rshunt, avg, ct)
--     VALUES ('ina226-0', 'i2c-1', '0x40', '0.1', '16', '1100');
-- rshunt = 分流电阻阻值（欧姆）。CJMCU-226 模块板载 R100 = 0.1Ω（缺省值），
--   但分流量程固定 ±81.92mV -> 0.1Ω 仅约 ±0.82A；动力电监测建议换小阻值
--   外置分流（10mΩ -> ±8.19A），INA226 精度（0.1% 增益 / 2.5µV LSB）为 INA219 的 4 倍
-- avg = 每次测量的平均样本数（1/4/16/64/128/256/512/1024，非法值向下降档，缺省 16）
-- ct  = 单次转换时间 µs（140/204/332/588/1100/2116/4156/8244，非法值向下降档，缺省 1100）
--   注意 avg=1024 且 ct=8244 时一个转换循环约 17s，build 会等满一循环才返回
-- 各列写 '-' 按缺省值处理（直接引用路径跳过该列，守护路径 tonumber('-')=nil，均走缺省分支）
--
-- call 无需额外参数，返回 { result, V(总线电压 V), I(电流 A，反流为负), P(功率 W) }
-- 接 sensor_daemon：fields=V|I|P（浮点，勿配 sign）
--
-- 实现要点（换算依 TI datasheet SBOS547 + Linux 内核 ina2xx 钉死）：
--   1. INA226 与 INA219 寄存器布局同构（0x00 Config/0x01 Shunt/0x02 Bus/0x03 Power），
--      但换算完全不同，勿照搬：
--      分流寄存器 16 位完整有符号、无移位，LSB 2.5µV（量程固定 ±81.92mV，无 PGA）；
--      总线寄存器 16 位无符号、无移位，LSB 1.25mV（INA219 是 13 位左移 3 / LSB 4mV）
--   2. 有真 ID 寄存器（INA219 没有）：0xFE 厂商 ID 恒 0x5449（'TI'）、
--      0xFF 芯片 ID 恒 0x2260，build 据此甄别芯片；
--      软复位后配置默认值 0x4127（AVG=1, 双通道 1.1ms, 连续模式）作辅助校验
--   3. 无校准寄存器（0x05 是 Alert Limit）：芯片不输出电流值，本驱动全软件换算
--      I = 分流压降 / Rshunt，P = V x I；0x03 Power 寄存器（LSB=31.25mW=25x总线LSB）不用
--   4. 连续模式（MODE=111）下寄存器始终保有最近完成的转换值，call 直接读；
--      build 后等一个转换循环（总线+分流 各 ct x 平均次数）再返回
--   5. config 位布局与 INA219 不同：[15]=RST [14]=保留(恒1) [11:9]=AVG
--      [8:6]=VBUSCT [5:3]=VSHCT [2:0]=MODE（INA219 是 BRNG/PGA/SADC/BADC）
--   6. Mask/Enable（0x04）标志位也与 INA219（0x06）不同：bit3=CVRF 转换就绪、
--      bit2=OVF 溢出（本驱动连续模式直接读，不轮询标志）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_CONFIG = 0x00
local REG_SHUNT  = 0x01		-- 分流电压（16 位有符号，LSB 2.5µV）
local REG_BUS    = 0x02		-- 总线电压（16 位无符号，LSB 1.25mV）
local REG_MASK   = 0x04		-- 标志：bit3=CVRF 转换就绪，bit2=OVF 溢出
local REG_MFG    = 0xFE		-- 厂商 ID，恒 0x5449（'TI'）
local REG_DIE    = 0xFF		-- 芯片 ID，恒 0x2260

-- 配置默认值（软复位后读回应等于此值，辅助校验）
local CFG_DEFAULT = 0x4127		-- AVG=1, 双通道 1.1ms, 连续模式

-- ==================== 配置位 ====================
-- [15]=RST [14]=保留(恒1) [11:9]=AVG [8:6]=VBUSCT [5:3]=VSHCT [2:0]=MODE
local CFG_RST         = 0x8000
local CFG_RESERVED_14 = 0x4000		-- bit14 保留位，复位即 1，写配置时保持
local CFG_MODE_CONT   = 0x7			-- 连续 + 分流 + 总线

-- 平均样本数档（代码 0~7）
local avg_tab = { 1, 4, 16, 64, 128, 256, 512, 1024 }

-- 单次转换时间档 µs（代码 0~7，VBUSCT/VSHCT 同档）
local ct_tab = { 140, 204, 332, 588, 1100, 2116, 4156, 8244 }

local DEF_RSHUNT = 0.1			-- 缺省分流电阻 100mΩ（CJMCU-226 板载 R100）
local DEF_AVG_IDX = 3			-- 缺省平均 16 次（avg_tab 下标）
local DEF_CT_IDX  = 5			-- 缺省转换 1.1ms（ct_tab 下标）

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rshunt

-- 换算常数
local SHUNT_LSB_V = 2.5e-6			-- 分流寄存器 LSB：2.5µV（16 位有符号）
local BUS_LSB_V   = 1.25e-3			-- 总线寄存器 LSB：1.25mV（16 位无符号）

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

-- 数值列 -> 档位下标：向下降档到不大于 n 的最大合法档；非法/非正数归缺省档
-- （'-' 占位符经 tonumber 为 nil，同样归缺省档）
local function snap_idx(v, tab, def_idx)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_idx end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_idx
end

-- 平均样本数列 -> （代码, 实际样本数）
local function avg_code_of(v)
	local i = snap_idx(v, avg_tab, DEF_AVG_IDX)
	return i - 1, avg_tab[i]
end

-- 转换时间列 -> （代码, 实际 µs）
local function ct_code_of(v)
	local i = snap_idx(v, ct_tab, DEF_CT_IDX)
	return i - 1, ct_tab[i]
end

-- 分流电阻列 -> 欧姆（非法/'-' 归一值/非正数按缺省，防除零）
local function rshunt_of(v)
	local r = tonumber(v)
	if r == nil or r <= 0 then return DEF_RSHUNT end
	return r
end

-- 【配置脚本】软复位 -> ID 寄存器甄别芯片 -> 写工作配置 -> 等待首拍就绪
require_driver("i2c", {
name = "INA226",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- INA226 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-- 模块级配置：跨 call 保持
	local avg_code_v, avg_n = avg_code_of(data.avg)
	local ct_code_v, ct_us = ct_code_of(data.ct)
	rshunt = rshunt_of(data.rshunt)

	-----------------------------------------------------
	-- 软复位
	if not write_reg16(fd, REG_CONFIG, CFG_RST) then
		return err("Failed to write INA226 reset")
	end
	milli_sleep(10)

	-- ID 寄存器甄别芯片（INA219 没有的手段，INA3221 同款）
	local mfg = read_reg16(fd, REG_MFG)
	if mfg == nil then
		return err("Failed to read INA226 manufacturer ID")
	end
	if mfg ~= 0x5449 then
		return err(string.format("Manufacturer ID = 0x%04X (expect 0x5449 'TI', not INA226?)", mfg))
	end
	local die = read_reg16(fd, REG_DIE)
	if die == nil then
		return err("Failed to read INA226 die ID")
	end
	if die ~= 0x2260 then
		return err(string.format("Die ID = 0x%04X (expect 0x2260, not INA226?)", die))
	end

	-- 辅助校验：软复位后配置默认值
	local cfg = read_reg16(fd, REG_CONFIG)
	if cfg == nil then
		return err("Failed to read INA226 config")
	end
	if cfg ~= CFG_DEFAULT then
		return err(string.format("Config after reset = 0x%04X (expect 0x%04X)", cfg, CFG_DEFAULT))
	end

	-- 写工作配置：保留位 + 平均 + 双通道转换时间 + 连续模式
	local config = bitc.bor(CFG_RESERVED_14,
		bitc.bor(bitc.lshift(avg_code_v, 9),
		bitc.bor(bitc.lshift(ct_code_v, 6),
		bitc.bor(bitc.lshift(ct_code_v, 3), CFG_MODE_CONT))))
	if not write_reg16(fd, REG_CONFIG, config) then
		return err("Failed to write INA226 config")
	end

	-- 等待一个转换循环（总线 + 分流 各 ct x 平均次数），首拍数据就绪
	local loop_ms = math.ceil(2 * ct_us * avg_n / 1000) + 2
	milli_sleep(loop_ms)

	print(string.format("INA226 init OK: addr=0x%02X, avg=%d, ct=%dµs, rshunt=%.4f Ω", addr, avg_n, ct_us, rshunt))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- INA226 caller func get a table --------", data)
	end

	-----------------------------------------------------

	-- build 前置守卫：rshunt 仅 build 赋值，未 build 先 call 会做 nil 除法
	-- 裸 error（与 INA219 的守卫对齐）
	if rshunt == nil then
		return err("INA226 not built (build first)")
	end

	-----------------------------------------------------
	local s = read_reg16(fd, REG_SHUNT)
	if s == nil then
		return err("Failed to read INA226 shunt voltage")
	end
	local b = read_reg16(fd, REG_BUS)
	if b == nil then
		return err("Failed to read INA226 bus voltage")
	end

	-----------------------------------------------------
	local shunt_v = s16(s) * SHUNT_LSB_V			-- 分流压降（V，有符号）
	local bus_v = b * BUS_LSB_V						-- 总线电压（V，16 位无符号无移位）

	local ret = {
		result = "OK",
		V = bus_v,						-- 总线电压（V）
		I = shunt_v / rshunt,				-- 电流（A，可负）
		P = bus_v * shunt_v / rshunt		-- 功率（W，软件计算）
	}

	if DEBUG then
		print(string.format("INA226: V=%.3fV I=%.3fA P=%.3fW", ret.V, ret.I, ret.P))
	end

	return ret

	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】INA226_VIRT —— 2026-09-15 自 modules/lib/virtbus/ina226.lua
-- 整体迁入（单文件驱动+模型第二十五个，字寻址 16 位寄存器族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前二十四者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，自包含字寻址实现；截幅 helper 移入段内加 ina226_ 前缀
-- 避让；new() 内 `local ina226 = INA226_VIRT` 绑定使模型体零改动移植）；
-- ② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET
-- pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与
-- 驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 【字寻址 16 位寄存器 I2C 器件】（与 ina219.lua 同族，绝不能套字节地址
-- regmap——寄存器号各代表一个 16 位字：写 {ptr,hi,lo}，读 2 字节返回该字
-- hi/lo）。寄存器事实（TI datasheet SBOS547）：
--   0x00 CONFIG  [15]=RST（写 1 触发系统复位、位自清）[14]=保留恒 1
--                [13:12]=保留恒 0 [11:9]=AVG [8:6]=VBUSCT [5:3]=VSHCT
--                [2:0]=MODE；上电/复位默认 0x4127（AVG=1, 双 1.1ms, 连续）
--   0x01 SHUNT_VOLTAGE 16 位完整有符号、无移位、无 PGA，LSB 2.5µV，
--                      量程固定 ±81.92mV（INA219 是 10µV + PGA/8 ±320mV）
--   0x02 BUS_VOLTAGE   16 位无符号、【无移位】，LSB 1.25mV，码值直读
--                      （INA219 是 13 位左移 3 / 4mV，低 3 位 CNVR/OVF；
--                       INA226 标志在独立的 MASK/ENABLE 寄存器，总线字全是码）
--   0x03 POWER / 0x04 CURRENT / 0x05 CALIBRATION：本驱动不写校准、全软件换算
--      I=Vshunt/R、P=Vbus·I，协议上存在，照读照写（POR 0），模型不解释；
--      0x06 MASK/ENABLE（bit3=CVRF、bit2=OVF，本驱动不用）/0x07 ALERT_LIMIT 同
--   0xFE MANUFACTURER_ID 恒 0x5449（'TI'）、0xFF DIE_ID 恒 0x2260：
--      【真 ROM ID】（INA219 无 ID 寄存器，只靠复位默认值甄别），只读——
--      写 ACK 但丢弃，who() 可覆写喂 build 误挂负路径
--
-- 连续模式（MODE=111，驱动 build 固定）下结果寄存器恒保最近一次转换值，
-- call 直接读——无转换门/无 pending、不需要 advance；build 的「等一个转换
-- 循环」（10ms 复位 + 2·ct·avg +2）只是 sleep，模型不计时。软复位是本模型
-- 唯一的写副作用：向 CONFIG 写 bit15=1 的字时 0x8000 不落盘，寄存器文件
-- 原地恢复上电态（RST 自清）。CONFIG 读出保留位按 datasheet 合成（bit14 恒
-- 1、bit13:12 恒 0）。
--
-- 用法：
--   vbus.load_driver("modules/INA226.lua")  -- 定义全局 build/call/destroy 与 INA226_VIRT
--   local dev = INA226_VIRT.new()           -- 复位配置默认 0x4127 + ROM ID
--   dev:set_vip(12.0, 0.05)                 -- 总线 12V、分流压降 50mV
--   vbus.attach("INA226@0x40", 0x40, dev)
--
--   dev:who(0x0000, 0x2260)    -- 覆写厂商 ID 模拟误挂（build 甄别失败）
--   dev.nack_read = true       -- 定向故障：测量读 NACK
--
-- 【边界约定】模型只固化字寻址布局/位宽/有符号/ROM ID 与软复位语义；
-- I=Vshunt/R、P=Vbus·I 的换算全在驱动，物理量注入 API（set_vip/
-- set_current_a）的常量仅为造样本，测试另做独立换算交叉。
-- =====================================================================

INA226_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		CONFIG = 0x00,
		SHUNT  = 0x01,
		BUS    = 0x02,
		POWER  = 0x03,
		CURRENT= 0x04,
		CALIB  = 0x05,
		MASK   = 0x06,
		ALERT  = 0x07,
		MFG    = 0xFE,
		DIE    = 0xFF,
	}
}

-- 标量常数（逐条挂工厂表）


INA226_VIRT.CFG_DEFAULT = 0x4127		-- 复位/上电默认（bit14=1, AVG=1, 双 1.1ms, 连续）
INA226_VIRT.MFG_ID = 0x5449			-- 'TI'
INA226_VIRT.DIE_ID = 0x2260
INA226_VIRT.SHUNT_LSB_V = 2.5e-6		-- 分流寄存器 LSB 2.5µV（16 位有符号）
INA226_VIRT.BUS_LSB_V   = 1.25e-3	-- 总线寄存器 LSB 1.25mV（16 位无符号无移位）
INA226_VIRT.DEF_RSHUNT  = 0.1		-- CJMCU-226 板载 R100

function INA226_VIRT.new(opts)
	local ina226 = INA226_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local d = {}
	local regs = {}				-- 字地址（0~255）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local mfg_id = opts.mfg_id or ina226.MFG_ID
	local die_id = opts.die_id or ina226.DIE_ID
	local reset_cfg = opts.reset_cfg or ina226.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ina226.REG.CONFIG] = reset_cfg
		regs[ina226.REG.MFG] = mfg_id
		regs[ina226.REG.DIE] = die_id
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- CONFIG 读出：保留位按事实合成（bit14 恒 1、bit13:12 恒 0），其余照存
	local function config_read()
		return (regs[ina226.REG.CONFIG] or ina226.CFG_DEFAULT) % 0x1000 + 0x4000
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
		if p == ina226.REG.CONFIG and (bytes[2] % 256) >= 0x80 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == ina226.REG.CONFIG then
			-- 保留位：bit14 读恒 1、bit13:12 读恒 0，写啥都被硬件归位
			regs[p] = word % 0x1000 + 0x4000
		elseif p == ina226.REG.MFG or p == ina226.REG.DIE then
			-- ROM ID 只读：写 ACK 但丢弃，不改身份
		else
			regs[p] = word
		end
		return true
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时按字自增续读（模型约定，INA226 驱动从不发跨字读），奇数尾补 0。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local wi = p + math.floor((i - 1) / 2)
			local word
			if wi == ina226.REG.CONFIG then
				word = config_read()
			else
				word = regs[wi] or 0
			end
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- SHUNT_VOLTAGE：16 位有符号 LSB（接受负码，自动补码），满码 ±32768/32767
	function d:set_shunt_raw(raw)
		regs[ina226.REG.SHUNT] = clampi(math.floor(raw + 0.5), -32768, 32767) % 65536
		return self
	end

	-- BUS_VOLTAGE：直接写 16 位无符号寄存器字（满码 65535 = 81.91875V）
	function d:set_bus_raw(word)
		regs[ina226.REG.BUS] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- POWER/CURRENT/CALIB/MASK/ALERT：驱动不解释的协议寄存器，留原始码注入口
	function d:set_word(reg, word)
		reg = clampi(math.floor(reg), 0, 255)
		regs[reg] = clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 总线电压 V（16 位无符号直读，LSB 1.25mV）
	function d:set_bus_v(v)
		local code = clampi(math.floor(v / ina226.BUS_LSB_V + 0.5), 0, 65535)
		return self:set_bus_raw(code)
	end

	-- 分流压降 V（有符号，固定量程 ±81.92mV）
	function d:set_shunt_v(v)
		return self:set_shunt_raw(math.floor(v / ina226.SHUNT_LSB_V + 0.5))
	end

	-- 一次造齐：总线电压 + 分流压降
	function d:set_vip(bus_v, shunt_v)
		self:set_bus_v(bus_v)
		if shunt_v ~= nil then self:set_shunt_v(shunt_v) end
		return self
	end

	-- 按电流造分流压降：Vshunt = I × R（r 缺省 0.1Ω，须与驱动 build 的 rshunt 一致）
	function d:set_current_a(a, r)
		r = tonumber(r) or ina226.DEF_RSHUNT
		return self:set_shunt_v(a * r)
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期：总线 12.0 ± 0.4V（11.6~12.4V）、电流 0.5 ± 0.3A（0.2~0.8A，
	-- 按板载 R100 反推分流压降 20~80mV，固定量程 ±81.92mV 内不削顶），同相位；
	-- 无随机，E2E 数值可复现。连续模式无武装概念，直接更新结果寄存器即可
	-- （守护不驱动虚拟时钟）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_vip(12.0 + 0.4 * s, (0.5 + 0.3 * s) * ina226.DEF_RSHUNT)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写软复位后的 CONFIG 默认值（喂 build「Config after reset」失配路径；
	-- 立即把 CONFIG 置于该值，软复位后也是它；nil=不改）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[ina226.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 ROM ID（nil = 不改；软复位不恢复出厂值，喂 build 误挂甄别路径；
	-- 测试 section 须显式 who() 恢复，避免跨用例污染）
	function d:who(mfg, die)
		if mfg ~= nil then
			mfg_id = math.floor(mfg) % 65536
			regs[ina226.REG.MFG] = mfg_id
		end
		if die ~= nil then
			die_id = math.floor(die) % 65536
			regs[ina226.REG.DIE] = die_id
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

	-- 回上电态（保留故障钩子，与 ads1256/sgp30 约定一致：复位不得解除测试钩子；
	-- who() 覆写的身份同样保留——与 cht8305 约定一致，测试须显式恢复）
	function d:reset()
		reseed()
		reset_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:config()    return config_read() end
	function d:mfg()       return regs[ina226.REG.MFG] or 0 end
	function d:die()       return regs[ina226.REG.DIE] or 0 end
	function d:shunt_raw()
		local v = regs[ina226.REG.SHUNT] or 0
		if v >= 0x8000 then v = v - 0x10000 end
		return v
	end
	function d:bus_raw()   return regs[ina226.REG.BUS] or 0 end
	function d:word(reg)   return regs[reg] or 0 end
	function d:shunt_v()   return self:shunt_raw() * ina226.SHUNT_LSB_V end
	function d:bus_v()     return self:bus_raw() * ina226.BUS_LSB_V end
	function d:current_a(r) return self:shunt_v() / (tonumber(r) or ina226.DEF_RSHUNT) end
	function d:power_w(r)  return self:bus_v() * self:current_a(r) end

	return d
end

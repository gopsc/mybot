-- EMC2101 智能风扇控制器 驱动模块（温度监测 + PWM 转速闭环 + 转速反馈）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 EMC2101_VIRT（2026-09-15 自 modules/lib/virtbus/emc2101.lua
-- 迁入，单文件驱动+模型实验第三十六个，PWM+测量反馈混合族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Microchip（原 SMSC），I2C 地址 0x4C（模块可跳线变体，真机 i2cdetect 确认）
-- 1 路外部二极管测温（贴被散热芯片）+ 1 路内部测温 + TACH 转速反馈
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE EMC2101 (
--       name    String,
--       I2C     String,
--       address String,
--       duty    String,
--       lut     String
--   );
--   INSERT INTO EMC2101 (name, I2C, address, duty, lut)
--     VALUES ('fan0', 'i2c-1', '0x4C', '50', '-');
--   片上自主温控示例（LUT 模式，build 编好后芯片脱离 CPU 自闭环）：
--     VALUES ('fan0', 'i2c-1', '0x4C', '-', '40:0,50:30,60:60,70:100');
-- duty = 手动模式初始占空比 %（0~100，缺省 0=停转；lut 缺省时生效）
-- lut  = 片上查找表，逗号分隔 temp:duty 对（≤8 项，temp 0~127 整数 °C，
--        duty 0~100%），build 时写入芯片并启用——此后温控完全在片内闭环，
--        不占框架节拍；call 带 duty 参数可随时切回手动模式
--
-- call 契约（两用）：
--   call({duty=N})  -> 切手动模式并设占空比（自动禁用 LUT），返回 {result, duty, lsb}
--   call({...})     -> 采样：{result, TEMP_IN(°C 整数), TEMP_EXT(°C 浮点
--                      |nil=二极管故障), RPM(转速), STATUS(状态位掩码)}
--   采样无需参数；守护接 fields=TEMP_IN|TEMP_EXT|RPM（勿配 sign，浮点透传）
--   STATUS 位（0x02）：0x80 忙 0x40 内部高温 0x10 外部高温 0x08 外部低温
--   0x04 二极管故障 0x02 TCRIT 0x01 转速异常
--
-- 实现要点（寄存器/语义依 Adafruit CircuitPython EMC2101 库核实，MIT）：
--   1. 甄别双 Part ID：0xFD = 0x16（EMC2101）或 0x28（EMC2101-R），
--      厂商 ID 0xFE = 0x5D（SMSC），两者都要验
--   2. 占空比换算的关键：FAN_SETTING(0x4C) 的 100% 对应值不是 63，而是
--      2 x max(1, PWM_F)，PWM_F 为 0x4D 寄存器（5 位，本驱动保持复位默认
--      不配置——Hz 公式未核实不暴露），build 现读现算 full_lsb
--   3. 读序锁存坑（datasheet §6.1 Data Read Interlock，两路方向相反）：
--      外部温度【先读 MSB 0x01 锁存 LSB 0x10】再读 LSB；TACH 恰好相反，
--      必须【先读 LSB 0x46 锁存 MSB 0x47】再读 MSB。顺序反了可能撕裂
--      （Adafruit Arduino/CircuitPython 两库 TACH 均明确 LSB first）
--   4. 外部温度 11 位二进制补码（8 整数位 + 3 位 1/8°C 分数），0x3F8 =
--      二极管开路、0x3FF = 短路的特征码（返回 TEMP_EXT=nil + STATUS.0x04）
--   5. LUT 编程期间必须先禁用（FAN_CONFIG(0x4A) bit5=1），写完再启用；
--      手动模式则保持 bit5=1。空槽填 [0x7F, 0x3F]（Adafruit 同款兜底：
--      温度到达 127°C 前 LUT 尾项一直生效）
--   6. RPM = 5,400,000 / TACH 计数（数据手册 §6.14，常数已含每转脉冲数；
--      计数 0 = 停转/未接，返回 RPM=0 而非除零）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_INT_TEMP  = 0x00		-- 内部温度（8 位二进制补码，整数 °C）
local REG_EXT_MSB   = 0x01		-- 外部温度 MSB（先读锁存 LSB）
local REG_STATUS    = 0x02		-- 状态位（见头注释）
local REG_EXT_LSB   = 0x10		-- 外部温度 LSB（高 3 位有效）
local REG_TACH_LSB  = 0x46		-- TACH LSB（先读锁存 MSB）
local REG_TACH_MSB  = 0x47		-- TACH MSB（必须在 LSB 之后读）
local REG_FAN_CFG   = 0x4A		-- bit5 = LUT 禁用/编程模式
local REG_FAN_SET   = 0x4C		-- 手动占空比（0 ~ 2xPWM_F）
local REG_PWM_F     = 0x4D		-- PWM_F（5 位），100% 对应 2 x max(1, PWM_F)
local REG_LUT_BASE  = 0x50		-- LUT 8 项 x 2 字节（temp, duty 交错）
local REG_PART_ID   = 0xFD
local REG_MFG_ID    = 0xFE

local MFG_ID_SMSC   = 0x5D
local PART_IDS      = { [0x16] = "EMC2101", [0x28] = "EMC2101-R" }

local FAN_CFG_LUT_DIS = 0x20		-- FAN_CONFIG bit5：1 = LUT 禁用（编程/手动模式）
local LUT_MAX_TEMP    = 0x7F		-- 空槽兜底温度
local LUT_MAX_SPEED   = 0x3F		-- 空槽兜底占空比（寄存器满值）
local RPM_DIVISOR     = 5400000.0	-- 数据手册 §6.14
local EXT_OPEN        = 0x3F8		-- 外部温度特征码：开路
local EXT_SHORT       = 0x3FF		-- 外部温度特征码：短路

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local full_lsb = 63				-- 100% 对应的 FAN_SETTING 值（build 按 PWM_F 现算）

-- 8 位二进制补码还原（内部温度）
local s8 = bitc.s8

-- 11 位二进制补码还原（外部温度）
local function s11(v)
	if v >= 0x400 then v = v - 0x800 end
	return v
end

-- 占空比 % -> FAN_SETTING 寄存器值
local function duty_to_lsb(pct)
	return math.floor(pct * full_lsb / 100.0 + 0.5)
end

-- FAN_CONFIG 的 LUT 禁用位置 1 / 清 0（bitcompat 无 bnot，清位用字面掩码）
local function lut_disable(fd)
	local v = i2c_read_reg(fd, REG_FAN_CFG)
	if v < 0 then return false end
	return i2c_write_reg(fd, REG_FAN_CFG, bitc.bor(v, FAN_CFG_LUT_DIS))
end

local function lut_enable(fd)
	local v = i2c_read_reg(fd, REG_FAN_CFG)
	if v < 0 then return false end
	return i2c_write_reg(fd, REG_FAN_CFG, bitc.band(v, 0xDF))	-- 清 bit5
end

-- 解析 lut 列 "40:0,50:30,..." -> {{temp, lsb}...}（按温度升序），非法返回 nil+原因
local function parse_lut(s)
	if type(s) ~= "string" or s == "" then return nil, "empty" end
	local entries, n = {}, 0
	for pair in string.gmatch(s, "[^,]+") do
		local t, d = string.match(pair, "^%s*(%d+)%s*:%s*(%d+)%s*$")
		if not t then return nil, "bad pair '" .. pair .. "' (expect temp:duty)" end
		t, d = tonumber(t), tonumber(d)
		if t > 127 then return nil, "temp " .. t .. " > 127 (7-bit)" end
		if d > 100 then return nil, "duty " .. d .. " > 100%" end
		n = n + 1
		if n > 8 then return nil, "more than 8 entries" end
		entries[n] = { t, d }
	end
	if n == 0 then return nil, "empty" end
	table.sort(entries, function(a, b) return a[1] < b[1] end)
	return entries
end

-- 【配置脚本】甄别 -> 现算 full_lsb -> LUT 编程 或 手动占空比
require_driver("i2c", {
name = "EMC2101",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- EMC2101 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-----------------------------------------------------
	-- 身份甄别：双 Part ID + SMSC 厂商 ID
	local part = i2c_read_reg(fd, REG_PART_ID)
	local mfg = i2c_read_reg(fd, REG_MFG_ID)
	if part < 0 or mfg < 0 then
		return err("Failed to read EMC2101 ID registers")
	end
	if not PART_IDS[part] or mfg ~= MFG_ID_SMSC then
		return err(string.format("Not EMC2101: PART_ID=0x%02X (expect 0x16/0x28), MFG_ID=0x%02X (expect 0x5D)",
				part, mfg))
	end

	-- 100% 占空比对应值 = 2 x max(1, PWM_F)（PWM_F 保持芯片复位默认）
	local pwm_f = i2c_read_reg(fd, REG_PWM_F)
	if pwm_f < 0 then
		return err("Failed to read EMC2101 PWM_F")
	end
	if pwm_f == 0 then pwm_f = 1 end
	full_lsb = 2 * pwm_f

	-----------------------------------------------------
	local mode
	if data.lut ~= nil and data.lut ~= "-" and data.lut ~= "" then
		-- LUT 自主模式：解析 -> 禁 LUT -> 写 8 槽 -> 启用
		local entries, why = parse_lut(data.lut)
		if entries == nil then
			return err("Invalid lut column: " .. why)
		end
		if not lut_disable(fd) then
			return err("Failed to disable EMC2101 LUT")
		end
		local regs16 = {}
		for i = 1, 8 do
			local e = entries[i]
			if e then
				regs16[#regs16 + 1] = e[1]
				regs16[#regs16 + 1] = duty_to_lsb(e[2])
			else
				regs16[#regs16 + 1] = LUT_MAX_TEMP
				regs16[#regs16 + 1] = LUT_MAX_SPEED
			end
		end
		if i2c_write_multi(fd, REG_LUT_BASE, unpack(regs16)) ~= 0 then
			return err("Failed to write EMC2101 LUT")
		end
		if not lut_enable(fd) then
			return err("Failed to enable EMC2101 LUT")
		end
		mode = string.format("LUT(%d 项)", #entries)
	else
		-- 手动模式：禁 LUT + 写初始占空比（缺省 0 = 停转）
		-- 经 num_or：'nan' 过 tonumber 出的是 number（Lua 里 truthy），`or 0`
		-- 兜不住，而 `< 0`/`> 100` 两条钳位对 NaN 恒假放行，duty_to_lsb(NaN)
		-- 仍是 NaN，最后被 HAL 的 byte_of 挡成 nil 而报「Failed to write
		-- EMC2101 fan setting」——把配置笔误误报成 I2C 故障（审计 P3 口径）。
		local duty = num_or(data.duty, 0)
		if duty < 0 then duty = 0 end
		if duty > 100 then duty = 100 end
		if not lut_disable(fd) then
			return err("Failed to disable EMC2101 LUT")
		end
		local lsb = duty_to_lsb(duty)
		if not i2c_write_reg(fd, REG_FAN_SET, lsb) then
			return err("Failed to write EMC2101 fan setting")
		end
		mode = string.format("手动 %g%% (lsb=%d/%d)", duty, lsb, full_lsb)
	end

	print(string.format("EMC2101 init OK: addr=0x%02X, part=%s, mode=%s",
		addr, PART_IDS[part], mode))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- EMC2101 caller func get a table --------", data)
	end

	-----------------------------------------------------
	-- 带 duty：切手动模式（禁 LUT）+ 设占空比
	local duty = finite_of(data.duty)	-- NaN 同 build 侧口径，见上注
	if duty ~= nil then
		if duty < 0 then duty = 0 end
		if duty > 100 then duty = 100 end
		if not lut_disable(fd) then
			return err("Failed to disable EMC2101 LUT")
		end
		local lsb = duty_to_lsb(duty)
		if not i2c_write_reg(fd, REG_FAN_SET, lsb) then
			return err("Failed to write EMC2101 fan setting")
		end
		dbg(string.format("EMC2101 manual duty: %g%% -> lsb=%d/%d", duty, lsb, full_lsb))
		return {
			result = "OK",
			duty = duty,
			lsb = lsb
		}
	end

	-----------------------------------------------------
	-- 采样：状态 + 内部温度 + 外部温度（先 MSB 锁存 LSB）
	--       + TACH（先 LSB 锁存 MSB，§6.1 两路方向相反）
	local status = i2c_read_reg(fd, REG_STATUS)
	if status < 0 then
		return err("Failed to read EMC2101 status")
	end

	local tin = i2c_read_reg(fd, REG_INT_TEMP)
	if tin < 0 then
		return err("Failed to read EMC2101 internal temperature")
	end

	local msb = i2c_read_reg(fd, REG_EXT_MSB)		-- 先读 MSB 锁存 LSB
	if msb < 0 then
		return err("Failed to read EMC2101 external temperature")
	end
	local lsb = i2c_read_reg(fd, REG_EXT_LSB)
	if lsb < 0 then
		return err("Failed to read EMC2101 external temperature")
	end
	-- 16 位原始 = 11 位补码温度 <<5 | 低 5 位标志，先读 MSB 拼字再右移 5 位
	local raw11 = bitc.band(bitc.rshift(bitc.bor(bitc.lshift(msb, 8), lsb), 5), 0x7FF)
	local temp_ext
	if raw11 == EXT_OPEN or raw11 == EXT_SHORT then
		temp_ext = nil			-- 二极管开路/短路：特征码不换算，STATUS.0x04 可查
	else
		temp_ext = s11(raw11) * 0.125
	end

	local tlsb = i2c_read_reg(fd, REG_TACH_LSB)		-- §6.1：先读 LSB 锁存 MSB
	if tlsb < 0 then
		return err("Failed to read EMC2101 TACH")
	end
	local tmsb = i2c_read_reg(fd, REG_TACH_MSB)
	if tmsb < 0 then
		return err("Failed to read EMC2101 TACH")
	end
	local count = bitc.bor(bitc.lshift(tmsb, 8), tlsb)
	local rpm = 0
	if count >= 1 then
		rpm = RPM_DIVISOR / count
	end

	if DEBUG then
		print(string.format("EMC2101: Tin=%dC Text=%s RPM=%.1f status=0x%02X",
			s8(tin), tostring(temp_ext), rpm, status))
	end

	return {
		result   = "OK",
		TEMP_IN  = s8(tin),
		TEMP_EXT = temp_ext,
		RPM      = rpm,
		STATUS   = status
	}

	end,
})

-- =====================================================================
-- 【内嵌虚拟器件模型】EMC2101_VIRT —— 2026-09-15 自 modules/lib/virtbus/emc2101.lua
-- 整体迁入（单文件驱动+模型第三十六个，PWM 输出 + 测量反馈混合族，守护 E2E
-- 走 sensor_daemon 回退路径）。约定同前三十五者：① 生产路径零执行（new()
-- 仅虚拟总线测试调用，纯闭包零外部依赖；寄存器地址/POR 表/clamp/s11 全部
-- 移入 new() 内避让；new() 内 `local M = EMC2101_VIRT` 绑定使模型体零改动
-- 移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 原 SMSC EMC2101，固定 I2C 0x4C，纯闭包、纯算术无 bitcompat。混合器件：
-- PWM 输出（FAN_CFG PROG 位硬件门、手动占空比 FAN_SETTING 与 8 槽 LUT
-- 片上温控自主两模式）+ 测量反馈（内温 s8、外温 11 位补码 1/8°C 双字节
-- interlock 读序 MSB 先、TACH 16 位小端 interlock 方向相反 LSB 先，
-- 模型影子锁存可观测撕裂防护）+ 双 Part ID 0x16/0x28+MFG 0x5D 甄别 +
-- PWM_F POR 0x17 现算 full_lsb=46 + 二极管开路/短路特征码 + RPM 换算
-- 5,400,000/count 归驱动。连续测量无转换门，测量值只由注入 API 改变，
-- 模型绝不自造数据；virt_tick 32 拍确定性温度/TACH 波形直接装寄存器。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

EMC2101_VIRT = { _VERSION = "0.1.0" }

function EMC2101_VIRT.new()
-- ==================== 寄存器地址 / 常量 ====================
local REG_INT_TEMP  = 0x00		-- 内部温度 s8（只读测量）
local REG_EXT_MSB   = 0x01		-- 外部温度高字节（先读锁存 0x10）
local REG_STATUS    = 0x02		-- 状态位（只读）
local REG_EXT_LSB   = 0x10		-- 外部温度低字节（高 3 位分数）
local REG_TACH_LSB  = 0x46		-- TACH 低字节（先读锁存 0x47）
local REG_TACH_MSB  = 0x47		-- TACH 高字节
local REG_FAN_CFG   = 0x4A		-- bit5 PROG：1=手动/可编程，0=LUT 激活
local REG_FAN_SPIN  = 0x4B		-- 自旋启动配置（驱动不碰，POR 0x3F）
local REG_FAN_SET   = 0x4C		-- 手动占空比（低 6 位）
local REG_PWM_F     = 0x4D		-- PWM_F 低 5 位
local REG_PWM_DIV   = 0x4E		-- PWM 分频（驱动不碰，POR 0x01）
local REG_LUT_HYST  = 0x4F		-- LUT 迟滞（低 5 位，POR 0x04）
local REG_LUT_BASE  = 0x50		-- LUT 8×(temp,duty) 至 0x5F
local REG_PART_ID   = 0xFD
local REG_MFG_ID    = 0xFE
local REG_REV       = 0xFF

local FAN_CFG_PROG  = 0x20		-- PROG 位权
local MFG_ID_SMSC   = 0x5D
local PART_ID       = 0x16		-- EMC2101-R 为 0x28（who 覆写喂甄别）
local REV_ID        = 0x01

local RPM_DIVISOR   = 5400000.0	-- §6.14 式 [3]
local EXT_OPEN      = 0x3F8		-- 外温特征码：二极管开路
local EXT_SHORT     = 0x3FF		-- 外温特征码：二极管短路

-- POR 默认值（Datasheet Rev.2.54 Table 6.1/6.18/6.23/6.24/6.25）
local POR_FAN_CFG   = 0x20		-- PROG=1（上电即手动/可编程态）
local POR_FAN_SPIN  = 0x3F
local POR_FAN_SET   = 0x00
local POR_PWM_F     = 0x17		-- 23 → 100% 对应 lsb 46
local POR_PWM_DIV   = 0x01
local POR_LUT_HYST  = 0x04
local POR_TACH      = 0xFF		-- TACH 两字节均 FF
local POR_LUT_TEMP  = 0x7F		-- LUT 空槽兜底
local POR_LUT_DUTY  = 0x3F

-- 11 位二进制补码还原（外部温度）
local function s11(v)
	if v >= 0x400 then v = v - 0x800 end
	return v
end

	local M = EMC2101_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 字节寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此起 burst）
	local ext_shadow = 0		-- 读 0x01 锁存的外温低字节
	local tach_shadow = 0xFF	-- 读 0x46 锁存的 TACH 高字节（POR 影子 FF）
	local part_id = PART_ID
	local mfg_id = MFG_ID_SMSC
	local write_count = 0		-- ≥2B 写事务笔数
	local write_log = {}		-- ≥2B 写事务 {reg=首地址, bytes=...}

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- POR / 重新上电 ----------------

	local function seed_body()
		regs = {}
		-- 测量区 POR 全 00h（TACH 为 FFFFh）
		regs[REG_INT_TEMP], regs[REG_EXT_MSB], regs[REG_STATUS] = 0, 0, 0
		regs[REG_EXT_LSB] = 0
		regs[REG_TACH_LSB], regs[REG_TACH_MSB] = POR_TACH, POR_TACH
		-- 风扇控制块
		regs[REG_FAN_CFG] = POR_FAN_CFG
		regs[REG_FAN_SPIN] = POR_FAN_SPIN
		regs[REG_FAN_SET] = POR_FAN_SET
		regs[REG_PWM_F] = POR_PWM_F
		regs[REG_PWM_DIV] = POR_PWM_DIV
		regs[REG_LUT_HYST] = POR_LUT_HYST
		-- LUT 8 槽兜底 [0x7F,0x3F]
		for i = 0, 7 do
			regs[REG_LUT_BASE + 2 * i] = POR_LUT_TEMP
			regs[REG_LUT_BASE + 2 * i + 1] = POR_LUT_DUTY
		end
		-- ROM 身份
		regs[REG_PART_ID] = part_id
		regs[REG_MFG_ID] = mfg_id
		regs[REG_REV] = REV_ID
		-- 锁存影子回 POR
		ext_shadow, tach_shadow = 0, 0xFF
	end

	seed_body()

	-- ---------------- 协议语义 ----------------

	local function prog1()
		return math.floor((regs[REG_FAN_CFG] or 0) / FAN_CFG_PROG) % 2 == 1
	end

	-- 单字节落盘（地址已按自增折入 0x00~0xFF）
	local function write_byte(a, v)
		v = v % 256
		if a == REG_INT_TEMP or a == REG_EXT_MSB or a == REG_STATUS
			or a == REG_EXT_LSB or a == REG_TACH_LSB or a == REG_TACH_MSB
			or a == REG_PART_ID or a == REG_MFG_ID or a == REG_REV then
			return						-- 测量/ROM 只读：写 ACK 丢弃
		elseif a == REG_FAN_CFG then
			regs[a] = v % 0x80			-- bit7 无定义读 0
		elseif a == REG_FAN_SPIN then
			regs[a] = v % 0x40			-- bit[7:6] 无定义
		elseif a == REG_FAN_SET then
			if prog1() then regs[a] = v % 0x40 end	-- PROG=0 只读，写丢弃
		elseif a == REG_PWM_F then
			regs[a] = v % 0x20			-- 仅低 5 位
		elseif a == REG_PWM_DIV then
			regs[a] = v
		elseif a == REG_LUT_HYST then
			regs[a] = v % 0x20			-- 仅低 5 位
		elseif a >= REG_LUT_BASE and a <= 0x5F then
			if prog1() then
				-- 仅 PROG=1 可编程；偶址温度槽 7 位、奇址风速槽 6 位
				if a % 2 == 0 then regs[a] = v % 0x80
				else regs[a] = v % 0x40 end
			end
		end
		-- 其余未定义地址：ACK 丢弃（datasheet：未定义寄存器读 0）
	end

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）：0x00..0xFF ACK 设 ptr
			if bytes[1] > 0xFF then return false end
			read_ptr = bytes[1]
			return true
		end
		if bytes[1] > 0xFF then return false end
		for i = 2, nb do
			local b = bytes[i]
			if type(b) ~= "number" or b < 0 or b > 0xFF then return false end
			write_byte((bytes[1] + i - 2) % 256, b)
		end
		write_count = write_count + 1
		local copy = { bytes[1] }
		for i = 2, nb do copy[i] = bytes[i] end
		write_log[#write_log + 1] = { reg = bytes[1], bytes = copy }
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_ptr == nil then return nil end	-- 无指针纯读：NACK
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		local t = {}
		for i = 1, n do
			local a = read_ptr
			if a == REG_EXT_MSB then
				-- 读外温高字节：把当前低字节拍进影子
				ext_shadow = regs[REG_EXT_LSB] or 0
				t[i] = regs[REG_EXT_MSB] or 0
			elseif a == REG_EXT_LSB then
				t[i] = ext_shadow		-- 出锁存值，不直接出活值
			elseif a == REG_TACH_LSB then
				-- 读 TACH 低字节：把当前高字节拍进影子
				tach_shadow = regs[REG_TACH_MSB] or 0
				t[i] = regs[REG_TACH_LSB] or 0
			elseif a == REG_TACH_MSB then
				t[i] = tach_shadow		-- 出锁存值，不直接出活值
			else
				t[i] = regs[a] or 0		-- 稀疏影子，未定义读 0
			end
			read_ptr = (read_ptr + 1) % 256	-- burst 自增、0xFF 算术回绕
		end
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	-- 内部温度（整数 °C，s8 码域 -128~127）
	function d:set_internal_temp_c(t)
		t = clampi(t, -128, 127)
		regs[REG_INT_TEMP] = t % 256
		return self
	end

	-- 外部温度直接装 11 位有符号码（-1024~1023）
	function d:set_external_raw(code)
		code = clampi(code, -1024, 1023) % 0x800
		regs[REG_EXT_MSB] = math.floor(code / 8) % 256		-- code>>3
		regs[REG_EXT_LSB] = (code % 8) * 0x20				-- 低 3 位置 bit7:5
		return self
	end

	-- 外部温度物理量（°C，1/8°C 量化），返回量化后实际值
	function d:set_external_temp_c(x)
		x = tonumber(x) or 0
		local code = clampi(math.floor(x * 8 + 0.5), -1024, 1023)
		d:set_external_raw(code)
		return s11(code) * 0.125
	end

	-- 二极管故障特征码："open"/"short"（只装测量码，STATUS 由 set_status 另注）
	function d:set_diode_fault(which)
		if which == "open" then
			d:set_external_raw(EXT_OPEN)
		elseif which == "short" then
			d:set_external_raw(EXT_SHORT)
		end
		return self
	end

	-- 状态寄存器原始字节（BUSY/告警/FAULT/TACH 等位由测试侧显式注入）
	function d:set_status(s)
		regs[REG_STATUS] = clampi(s, 0, 255)
		return self
	end

	-- TACH 16 位计数直接装（0=停转；POR FFFF=低速特征）
	function d:set_tach_count(c)
		c = clampi(c, 0, 65535)
		regs[REG_TACH_LSB] = c % 256
		regs[REG_TACH_MSB] = math.floor(c / 256) % 256
		return self
	end

	-- 物理逆注入：按 RPM 反推 TACH 计数（与驱动常数同源）；rpm<=0→计数 0
	function d:set_rpm(rpm)
		rpm = tonumber(rpm) or 0
		if rpm <= 0 then
			d:set_tach_count(0)
		else
			d:set_tach_count(clampi(math.floor(RPM_DIVISOR / rpm + 0.5), 1, 65535))
		end
		return self
	end

	-- 覆写 ROM 身份喂 build 甄别负路径（nil=不改；完整 reset 恢复出厂）
	function d:who(part, mfg)
		if part ~= nil then
			part_id = clampi(part, 0, 255)
			regs[REG_PART_ID] = part_id
		end
		if mfg ~= nil then
			mfg_id = clampi(mfg, 0, 255)
			regs[REG_MFG_ID] = mfg_id
		end
		return self
	end

	-- 守护逐拍造数：内温 35±5°C 整数、外温 42±6°C（1/8 量化）、
	-- 转速 3000±1200 RPM（恒四位数 1800~4200，count 反推装码）；
	-- STATUS 恒清 0。连续测量器件：tick 直接装码，守护 call 零睡眠。
	function d:virt_tick(n)
		n = math.floor(tonumber(n) or 0)
		local s = math.sin(2 * math.pi * n / 32)
		d:set_status(0)
		d:set_internal_temp_c(math.floor(35 + 5 * s + 0.5))
		d:set_external_temp_c(42 + 6 * s)
		d:set_rpm(3000 + 1200 * s)
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
		write_count = 0
		write_log = {}
		return self
	end

	-- 重新上电：全状态回 POR（身份覆写/日志清零）；故障钩子保留
	function d:reset()
		part_id = PART_ID
		mfg_id = MFG_ID_SMSC
		write_count = 0
		write_log = {}
		read_ptr = nil
		seed_body()
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a) return regs[math.floor(tonumber(a) or 0) % 256] end
	function d:ptr() return read_ptr end
	function d:prog() return prog1() end

	function d:internal_c()
		local v = regs[REG_INT_TEMP] or 0
		if v >= 0x80 then v = v - 0x100 end
		return v
	end

	-- 外温 11 位原始码（从寄存器字节重组，与驱动同布局）
	function d:ext_code()
		local msb, lsb = regs[REG_EXT_MSB] or 0, regs[REG_EXT_LSB] or 0
		return math.floor((msb * 256 + lsb) / 32) % 0x800
	end

	-- 外温 °C；开路/短路特征码返 nil
	function d:ext_temp_c()
		local code = d:ext_code()
		if code == EXT_OPEN or code == EXT_SHORT then return nil end
		return s11(code) * 0.125
	end

	function d:status() return regs[REG_STATUS] or 0 end

	function d:tach_count()
		return (regs[REG_TACH_MSB] or 0) * 256 + (regs[REG_TACH_LSB] or 0)
	end

	function d:rpm()
		local c = d:tach_count()
		if c >= 1 then return RPM_DIVISOR / c end
		return 0
	end

	function d:pwm_f() return (regs[REG_PWM_F] or 0) % 0x20 end
	function d:full_lsb() return 2 * math.max(1, d:pwm_f()) end
	function d:fan_setting() return regs[REG_FAN_SET] or 0 end

	-- LUT 8 槽 {{temp=,duty=}...}（按槽位顺序，未排序）
	function d:lut()
		local t = {}
		for i = 0, 7 do
			t[i + 1] = {
				temp = regs[REG_LUT_BASE + 2 * i] or 0,
				duty = regs[REG_LUT_BASE + 2 * i + 1] or 0,
			}
		end
		return t
	end

	function d:part_id() return regs[REG_PART_ID] or 0 end
	function d:mfg_id() return regs[REG_MFG_ID] or 0 end
	function d:rev() return regs[REG_REV] or 0 end
	function d:write_count() return write_count end
	function d:writes() return write_log end

	return d
end

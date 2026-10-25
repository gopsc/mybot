-- EMC2101 智能风扇控制器 驱动模块（温度监测 + PWM 转速闭环 + 转速反馈）
-- bot4cj 仓颉语言机器人框架
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
--   3. 读序锁存坑：外部温度（0x01 MSB + 0x10 LSB）与 TACH（0x47 MSB +
--      0x46 LSB）都必须【先读 MSB 锁存 LSB]，再读 LSB，顺序反了可能撕裂
--   4. 外部温度 11 位二进制补码（8 整数位 + 3 位 1/8°C 分数），0x3F8 =
--      二极管开路、0x3FF = 短路的特征码（返回 TEMP_EXT=nil + STATUS.0x04）
--   5. LUT 编程期间必须先禁用（FAN_CONFIG(0x4A) bit5=1），写完再启用；
--      手动模式则保持 bit5=1。空槽填 [0x7F, 0x3F]（Adafruit 同款兜底：
--      温度到达 127°C 前 LUT 尾项一直生效）
--   6. RPM = 5,400,000 / TACH 计数（数据手册 §6.14，常数已含每转脉冲数；
--      计数 0 = 停转/未接，返回 RPM=0 而非除零）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
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
local REG_TACH_LSB  = 0x46		-- TACH LSB（必须在 MSB 之后读）
local REG_TACH_MSB  = 0x47		-- TACH MSB（先读锁存 LSB）
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
local function s8(v)
	if v >= 0x80 then v = v - 0x100 end
	return v
end

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
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- EMC2101 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 身份甄别：双 Part ID + SMSC 厂商 ID
	local part = i2c_read_reg(fd, REG_PART_ID)
	local mfg = i2c_read_reg(fd, REG_MFG_ID)
	if part < 0 or mfg < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 ID registers"
		}
	end
	if not PART_IDS[part] or mfg ~= MFG_ID_SMSC then
		return {
			result = "ERR",
			message = string.format("Not EMC2101: PART_ID=0x%02X (expect 0x16/0x28), MFG_ID=0x%02X (expect 0x5D)",
				part, mfg)
		}
	end

	-- 100% 占空比对应值 = 2 x max(1, PWM_F)（PWM_F 保持芯片复位默认）
	local pwm_f = i2c_read_reg(fd, REG_PWM_F)
	if pwm_f < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 PWM_F"
		}
	end
	if pwm_f == 0 then pwm_f = 1 end
	full_lsb = 2 * pwm_f

	-----------------------------------------------------
	local mode
	if data.lut ~= nil and data.lut ~= "-" and data.lut ~= "" then
		-- LUT 自主模式：解析 -> 禁 LUT -> 写 8 槽 -> 启用
		local entries, why = parse_lut(data.lut)
		if entries == nil then
			return {
				result = "ERR",
				message = "Invalid lut column: " .. why
			}
		end
		if not lut_disable(fd) then
			return {
				result = "ERR",
				message = "Failed to disable EMC2101 LUT"
			}
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
			return {
				result = "ERR",
				message = "Failed to write EMC2101 LUT"
			}
		end
		if not lut_enable(fd) then
			return {
				result = "ERR",
				message = "Failed to enable EMC2101 LUT"
			}
		end
		mode = string.format("LUT(%d 项)", #entries)
	else
		-- 手动模式：禁 LUT + 写初始占空比（缺省 0 = 停转）
		local duty = tonumber(data.duty) or 0
		if duty < 0 then duty = 0 end
		if duty > 100 then duty = 100 end
		if not lut_disable(fd) then
			return {
				result = "ERR",
				message = "Failed to disable EMC2101 LUT"
			}
		end
		local lsb = duty_to_lsb(duty)
		if not i2c_write_reg(fd, REG_FAN_SET, lsb) then
			return {
				result = "ERR",
				message = "Failed to write EMC2101 fan setting"
			}
		end
		mode = string.format("手动 %g%% (lsb=%d/%d)", duty, lsb, full_lsb)
	end

	print(string.format("EMC2101 init OK: addr=0x%02X, part=%s, mode=%s",
		addr, PART_IDS[part], mode))
	return {  result = "OK"  }

end

-- 【销毁EMC2101】无资源需要释放（风扇状态维持，总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用EMC2101】两用：带 duty 参数 = 设手动占空比；否则 = 采样
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- EMC2101 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 带 duty：切手动模式（禁 LUT）+ 设占空比
	local duty = tonumber(data.duty)
	if duty ~= nil then
		if duty < 0 then duty = 0 end
		if duty > 100 then duty = 100 end
		if not lut_disable(fd) then
			return {
				result = "ERR",
				message = "Failed to disable EMC2101 LUT"
			}
		end
		local lsb = duty_to_lsb(duty)
		if not i2c_write_reg(fd, REG_FAN_SET, lsb) then
			return {
				result = "ERR",
				message = "Failed to write EMC2101 fan setting"
			}
		end
		dbg(string.format("EMC2101 manual duty: %g%% -> lsb=%d/%d", duty, lsb, full_lsb))
		return {
			result = "OK",
			duty = duty,
			lsb = lsb
		}
	end

	-----------------------------------------------------
	-- 采样：状态 + 内部温度 + 外部温度（先 MSB 锁存）+ TACH（先 MSB 锁存）
	local status = i2c_read_reg(fd, REG_STATUS)
	if status < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 status"
		}
	end

	local tin = i2c_read_reg(fd, REG_INT_TEMP)
	if tin < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 internal temperature"
		}
	end

	local msb = i2c_read_reg(fd, REG_EXT_MSB)		-- 先读 MSB 锁存 LSB
	if msb < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 external temperature"
		}
	end
	local lsb = i2c_read_reg(fd, REG_EXT_LSB)
	if lsb < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 external temperature"
		}
	end
	-- 16 位原始 = 11 位补码温度 <<5 | 低 5 位标志，先读 MSB 拼字再右移 5 位
	local raw11 = bitc.band(bitc.rshift(bitc.bor(bitc.lshift(msb, 8), lsb), 5), 0x7FF)
	local temp_ext
	if raw11 == EXT_OPEN or raw11 == EXT_SHORT then
		temp_ext = nil			-- 二极管开路/短路：特征码不换算，STATUS.0x04 可查
	else
		temp_ext = s11(raw11) * 0.125
	end

	local tmsb = i2c_read_reg(fd, REG_TACH_MSB)		-- 先读 MSB 锁存 LSB
	if tmsb < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 TACH"
		}
	end
	local tlsb = i2c_read_reg(fd, REG_TACH_LSB)
	if tlsb < 0 then
		return {
			result = "ERR",
			message = "Failed to read EMC2101 TACH"
		}
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

end

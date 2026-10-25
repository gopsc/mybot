-- AS3935 闪电传感器 驱动模块（ams Franklin Lightning Sensor，I2C 地址 0x01~0x03）
-- bot4cj 仓颉语言机器人框架
--
-- 事件型器件（区别于连续采样型）：平时无"数据"，检测到事件（噪声过高/干扰源/
-- 闪电）后锁存中断原因，call 读取并返回最近一次事件。适合 @Daemon 低频轮询
-- （250ms~1s）或 Monitor 消费决策（如户外机器人检测到近距离雷暴提前收工）。
-- 模块：SparkFun SEN-15441 / DFRobot SEN0290 / GY-AS3935 等（板载 500kHz 谐振天线）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE AS3935 (
--       name      String,
--       I2C       String,
--       address   String,
--       indoor    String,
--       nf        String,
--       wdth      String,
--       srej      String,
--       min_lig   String,
--       mask_dist String,
--       tun_cap   String
--   );
--   INSERT INTO AS3935 (name, I2C, address, indoor)
--     VALUES ('as3935-0', 'i2c-1', '0x03', '-');
--
-- 列说明（均可选，'-' 归缺省）：
--   indoor    = '1' 室内增益（缺省）/ '0' 室外增益
--   nf        = 噪声底 0~7（缺省 2；电机/舵机旁需调高）
--   wdth      = 看门狗阈值 0~10（缺省 2）
--   srej      = 尖峰抑制 0~15（缺省 2）
--   min_lig   = 确认一次闪电的最少 strikes（1/5/9/16，非法值向下取合法档，缺省 1）
--   mask_dist = '1' 屏蔽干扰源事件（误报排查利器，缺省 '0'）
--   tun_cap   = 天线调谐电容 pF，0~120（8pF 步进截断，缺省 0；模块一般预调好）
--
-- call 无需参数，返回：
--   { result, EVENT("none"|"noise"|"disturber"|"lightning"), CODE(0~3),
--     DIST_KM(闪电时 1~40km；非闪电/未知/超范围 = -1),
--     ENERGY(闪电相对能量 0~2^21，非闪电 = 0) }
-- 接 sensor_daemon：fields=CODE|DIST_KM|ENERGY（数值字段；CODE=3 即闪电）
--
-- build 流程：软复位（0x3C=0x96）-> 在位甄别（复位默认 AFE_GB 应为室内增益）
--   -> 写环境配置（逐字段读-改-写）-> RCO 校准（0x3D=0x96，0x3A/0x3B 的
--   bit6=0 为通过）。天线谐振调谐的严格做法需经 IRQ 引脚测 LCO 频率，
--   本驱动未接 IRQ：tun_cap 按模块手册静态配置即可。
--
-- 协议依据：SparkFun_AS3935_Arduino_Library 与 ESPHome as3935 组件交叉一致，
--   距离特殊值（0x3F=超范围、1=头顶）依 datasheet S_DIST 编码表。
-- 部署提醒：电机/舵机/开关电源是强干扰源——天线远离动力线；误报频繁先
--   mask_dist='1' 验证链路，再逐项放开；地址 0x03 在 I2C 保留区，
--   i2cdetect 默认扫不到（勿误判模块损坏）。
-- 已知兼容性坑：个别模块（DFRobot SEN0290）中断锁存经 I2C 清除不干净
--   （ESPHome #17581），若同一事件反复上报，在消费侧按 CODE 去重。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：事件轮询频率不高，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_AFE_GAIN   = 0x00		-- bit0=PWD，[5:1]=AFE_GB（室内/室外增益）
local REG_THRESHOLD  = 0x01		-- [6:4]=NF_LEV 噪声底，[3:0]=WDTH 看门狗
local REG_LIGHTNING  = 0x02		-- [5:4]=MIN_NUM_LIG，[3:0]=SREJ 尖峰抑制
local REG_INT        = 0x03		-- [3:0]=INT 事件码（读后清锁存），bit5=MASK_DIST
local REG_EGY_LSB    = 0x04		-- 闪电能量 LSB
local REG_EGY_MSB    = 0x05		-- 闪电能量 MSB
local REG_EGY_MMSB   = 0x06		-- 闪电能量最高 5 位
local REG_DISTANCE   = 0x07		-- [5:0]=S_DIST 雷暴距离估计
local REG_FDISP      = 0x08		-- [3:0]=TUN_CAP（pF/8），[7:6]=SRCO/TRCO 显示位
local REG_CALIB_TRCO = 0x3A		-- bit6：TRCO 校准状态（1 = 未通过）
local REG_CALIB_SRCO = 0x3B		-- bit6：SRCO 校准状态（1 = 未通过）
local REG_RESET      = 0x3C		-- 写 0x96 = 软复位/恢复默认
local REG_CALIB_RCO  = 0x3D		-- 写 0x96 = RCO 校准命令

-- ==================== 常量 ====================
local INDOOR_GB  = 0x12			-- AFE_GB 室内增益
local OUTDOOR_GB = 0x0E			-- AFE_GB 室外增益

local EVT_NONE      = 0x00
local EVT_NOISE     = 0x01
local EVT_DISTURBER = 0x04
local EVT_LIGHTNING = 0x08

local CMD_DATA  = 0x96			-- 0x3C 复位 / 0x3D 校准 共用的命令数据
local CALIB_NOK = 0x40			-- 0x3A/0x3B bit6：置位 = 校准未通过

local DIST_OOR = 0x3F			-- S_DIST 超出量程特殊值（1 = 雷暴在头顶）

local T_RESET_MS = 2			-- 复位生效等待
local T_CALIB_MS = 2			-- 校准状态更新等待（显示位强制刷新窗口）

-- 缺省配置（datasheet 复位默认值）
local DEF_NF      = 2
local DEF_WDTH    = 2
local DEF_SREJ    = 2
local DEF_TUN_CAP = 0

-- ==================== 解析辅助 ====================
-- 数值列 -> 钳到 [lo, hi] 的整数；非法/'-' 归缺省
local function int_of(v, def, lo, hi)
	local n = tonumber(v)
	if n == nil then return def end
	n = math.floor(n)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

-- min_lig 列 -> MIN_NUM_LIG 编码：1/5/9/16 四档，非法值向下取合法档
local function min_lig_code(v)
	local n = tonumber(v)
	if n == nil then n = 1 end
	n = math.floor(n)
	if n >= 16 then return 3 elseif n >= 9 then return 2
	elseif n >= 5 then return 1 else return 0 end
end

-- 读-改-写寄存器位域：keep_mask = 保留位掩码（1 保留），value 写到 pos 起的字段
-- 成功返回 true（任一步总线失败返回 false）
local function modify_reg(fd, reg, keep_mask, value, pos)
	local cur = i2c_read_reg(fd, reg)
	if cur == nil or cur < 0 then return false end
	local field_mask = bitc.bxor(keep_mask, 0xFF)
	local newv = bitc.bor(bitc.band(cur, keep_mask),
		bitc.band(bitc.lshift(value, pos), field_mask))
	return i2c_write_reg(fd, reg, newv)
end

-- 【配置脚本】软复位 -> 在位甄别 -> 写环境配置 -> RCO 校准
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AS3935 builder func get a table --------", data)
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

	-- 配置列解析
	local indoor = (tonumber(data.indoor) or 1) ~= 0
	local nf     = int_of(data.nf, DEF_NF, 0, 7)
	local wdth   = int_of(data.wdth, DEF_WDTH, 0, 10)
	local srej   = int_of(data.srej, DEF_SREJ, 0, 15)
	local lig_c  = min_lig_code(data.min_lig)
	local mask   = (tonumber(data.mask_dist) or 0) ~= 0
	local cap_pF = int_of(data.tun_cap, DEF_TUN_CAP, 0, 120)

	-----------------------------------------------------
	-- 软复位（恢复默认配置）
	if not i2c_write_reg(fd, REG_RESET, CMD_DATA) then
		return {
			result = "ERR",
			message = "Failed to reset AS3935"
		}
	end
	milli_sleep(T_RESET_MS)

	-- 在位甄别：复位默认 AFE_GB 应为室内增益 0x12（读-改-写前的身份校验）
	local afe = i2c_read_reg(fd, REG_AFE_GAIN)
	if afe == nil or afe < 0 then
		return {
			result = "ERR",
			message = "Failed to read AS3935 AFE_GAIN"
		}
	end
	if bitc.band(bitc.rshift(afe, 1), 0x1F) ~= INDOOR_GB then
		return {
			result = "ERR",
			message = string.format("AFE_GAIN after reset = 0x%02X (expect INDOOR default, not AS3935? wiring/address issue?)", afe)
		}
	end

	-- 写环境配置（逐字段读-改-写，不扰动其他位）
	if not modify_reg(fd, REG_AFE_GAIN, 0xC1, indoor and INDOOR_GB or OUTDOOR_GB, 1) then
		return {  result = "ERR", message = "Failed to write AS3935 AFE gain"  }
	end
	if not modify_reg(fd, REG_THRESHOLD, 0x8F, nf, 4) then
		return {  result = "ERR", message = "Failed to write AS3935 noise floor"  }
	end
	if not modify_reg(fd, REG_THRESHOLD, 0xF0, wdth, 0) then
		return {  result = "ERR", message = "Failed to write AS3935 watchdog threshold"  }
	end
	if not modify_reg(fd, REG_LIGHTNING, 0xCF, lig_c, 4) then
		return {  result = "ERR", message = "Failed to write AS3935 min lightning"  }
	end
	if not modify_reg(fd, REG_LIGHTNING, 0xF0, srej, 0) then
		return {  result = "ERR", message = "Failed to write AS3935 spike rejection"  }
	end
	if not modify_reg(fd, REG_INT, 0xDF, mask and 1 or 0, 5) then
		return {  result = "ERR", message = "Failed to write AS3935 disturber mask"  }
	end
	if not modify_reg(fd, REG_FDISP, 0xF0, math.floor(cap_pF / 8), 0) then
		return {  result = "ERR", message = "Failed to write AS3935 tuning capacitor"  }
	end

	-----------------------------------------------------
	-- RCO 校准（内部 RC 振荡器，事件计时的时基）
	if not i2c_write_reg(fd, REG_CALIB_RCO, CMD_DATA) then
		return {
			result = "ERR",
			message = "Failed to send AS3935 RCO calibration command"
		}
	end
	-- 置 SRCO/TRCO 显示位强制校准状态刷新，等一拍后清除
	if not modify_reg(fd, REG_FDISP, 0x3F, 0x03, 6) then
		return {  result = "ERR", message = "Failed to set AS3935 calib display bits"  }
	end
	milli_sleep(T_CALIB_MS)
	if not modify_reg(fd, REG_FDISP, 0x3F, 0x00, 6) then
		return {  result = "ERR", message = "Failed to clear AS3935 calib display bits"  }
	end

	-- 校准状态：SRCO/TRCO 两个状态位都必须为 0（bit6=1 即校准未通过）
	local srco = i2c_read_reg(fd, REG_CALIB_SRCO)
	local trco = i2c_read_reg(fd, REG_CALIB_TRCO)
	if srco == nil or srco < 0 or trco == nil or trco < 0 then
		return {
			result = "ERR",
			message = "Failed to read AS3935 calibration status"
		}
	end
	if bitc.band(srco, CALIB_NOK) ~= 0 or bitc.band(trco, CALIB_NOK) ~= 0 then
		return {
			result = "ERR",
			message = string.format("AS3935 RCO calibration failed (SRCO=0x%02X TRCO=0x%02X, NOK bit set)", srco, trco)
		}
	end

	print(string.format("AS3935 init OK: addr=0x%02X, %s, nf=%d, wdth=%d, srej=%d, min_lig_c=%d, mask_dist=%s, tun_cap=%dpF",
		addr, indoor and "indoor" or "outdoor", nf, wdth, srej, lig_c, tostring(mask), cap_pF))
	return {  result = "OK"  }

end

-- 【销毁AS3935】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用AS3935】读取最近一次锁存事件（读 INT 寄存器会清锁存）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AS3935 caller func get a table --------", data)
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

	-- 与参考实现一致：事件锁存稳定后再读（IRQ 触发后约 2ms 才可读）
	milli_sleep(2)

	local intv = i2c_read_reg(fd, REG_INT)
	if intv == nil or intv < 0 then
		return {
			result = "ERR",
			message = "Failed to read AS3935 interrupt register"
		}
	end
	intv = intv % 16		-- INT 位域 [3:0]

	local ret = {
		result = "OK",
		EVENT = "none", CODE = 0, DIST_KM = -1, ENERGY = 0
	}

	-----------------------------------------------------
	-- 按位判定（比精确相等更稳：个别模块 INT 位域外可能有杂散位）
	if bitc.band(intv, EVT_LIGHTNING) ~= 0 then
		ret.EVENT = "lightning"
		ret.CODE = 3

		local dist = i2c_read_reg(fd, REG_DISTANCE)
		if dist == nil or dist < 0 then
			return {
				result = "ERR",
				message = "Failed to read AS3935 distance"
			}
		end
		dist = dist % 64		-- S_DIST 位域 [5:0]
		-- 1 = 雷暴在头顶/极近，2~62 = 公里数，0x3F = 超出量程，0 = 未知
		if dist >= 1 and dist <= 62 then
			ret.DIST_KM = dist
		end

		local lsb = i2c_read_reg(fd, REG_EGY_LSB)
		local msb = i2c_read_reg(fd, REG_EGY_MSB)
		local mmsb = i2c_read_reg(fd, REG_EGY_MMSB)
		if lsb == nil or lsb < 0 or msb == nil or msb < 0 or mmsb == nil or mmsb < 0 then
			return {
				result = "ERR",
				message = "Failed to read AS3935 energy"
			}
		end
		ret.ENERGY = bitc.band(mmsb, 0x1F) * 65536 + msb * 256 + lsb

	elseif bitc.band(intv, EVT_DISTURBER) ~= 0 then
		ret.EVENT = "disturber"
		ret.CODE = 2
	elseif bitc.band(intv, EVT_NOISE) ~= 0 then
		ret.EVENT = "noise"
		ret.CODE = 1
	end

	if DEBUG and ret.CODE ~= 0 then
		print(string.format("AS3935: event=%s dist=%skm energy=%d",
			ret.EVENT, tostring(ret.DIST_KM), ret.ENERGY))
	end

	return ret

end

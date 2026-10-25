-- MAX17048 单节锂电池电量计 驱动模块（I2C，地址固定 0x36）
-- bot4cj 仓颉语言机器人框架
-- Maxim/ADI ModelGauge：靠电池模型从电压推算 SOC，无需分流电阻；
-- MAX17048 = 仓库 MAX17043 驱动的换代芯片（寄存器图扩展、VCELL 换算不同，
-- 两代不可共用驱动）；同总线同地址（0x36）只能挂一颗。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MAX17048 (
--       name       String,
--       I2C        String,
--       address    String,
--       valrt_max  String,   -- 过压告警阈值 V（20mV 步进；'-' = 保持 POR 值 5.1V）
--       valrt_min  String,   -- 欠压告警阈值 V（20mV 步进；'-' = 保持 POR 值 0V）
--       athd       String,   -- SOC 低电告警阈值 % 1~32（CONFIG ATHD；'-' = 不改）
--       quickstart String    -- '1' = build 时发 QuickStart（换电池后快速重新收敛）
--   );
--   INSERT INTO MAX17048 (name, I2C, address, valrt_max, valrt_min, athd, quickstart)
--     VALUES ('fuel-0', 'i2c-1', '0x36', '-', '3.3', '10', '-');
--
-- call 返回
--   { result, VCELL(V), SOC(%), CRATE(%/hr，充电为正), STATUS(6 位告警掩码) }
--   STATUS 位（清零=正常）：bit0 RI 复位指示 bit1 VH 过压 bit2 VL 欠压
--   bit3 VR 电压复位 bit4 HD SOC 变化 bit5 SC 1% SOC 变化；
--   传 clear=1 读取后清除告警位（默认只读不清）。
-- 接 sensor_daemon：fields=VCELL|SOC（浮点，勿配 sign）；
--   低电急停：Monitor 引用本变量判 SOC <= 阈值后经 controller 转发执行器。
--
-- 实现要点（寄存器语义与换算经 SparkFun MAX1704x 库全源核对，内核
-- max17042_battery.c 同图互证；与 MAX17043.lua 的差异点均已注明）：
--   1. VERSION（0x08）自检：0x0012=MAX17048（78.125uV/LSB，满量程 5.12V）、
--      0x0013=MAX17049 双节（156.25uV/LSB）；0x001E/0x001F 是 MAX17043/44，
--      报错引导用 MAX17043 驱动
--   2. VCELL（0x02）：16 位直读（无 17043 的左移 4）
--   3. SOC（0x04）：高字节整数 % + 低字节 /256
--   4. CRATE（0x16）：16 位带符号，0.208%/hr 每 LSB
--   5. STATUS（0x1A）：告警位在高字节 bit0~5，清除=写 0（保留 bit14 EnVR）
--   6. VALRT（0x14）：高字节 MAX 低字节 MIN，20mV/LSB，POR 0x00FF
--   7. ATHD：CONFIG（0x0C）低 5 位，值 = 32 - 阈值%（00000=32%）
--   8. QuickStart：MODE（0x06）写 0x4000（本驱动仅在 build 配置时发一次）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：电量计读取频率低，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（SparkFun MAX1704x 命名） ====================
local REG_VCELL   = 0x02		-- 电池电压 16 位
local REG_SOC     = 0x04		-- 剩余电量（高字节 %，低字节 /256）
local REG_MODE    = 0x06		-- QuickStart 0x4000
local REG_VER     = 0x08		-- 版本号：0x0012/0x0013 = 17048/49
local REG_CONFIG  = 0x0C		-- [15:8]RCOMP [4:0]ATHD
local REG_VALRT   = 0x14		-- [15:8]MAX [7:0]MIN，20mV/LSB
local REG_CRATE   = 0x16		-- 充放电速率（带符号，0.208%/hr）
local REG_STATUS  = 0x1A		-- 告警标志（高字节 bit0~5），EnVR=bit14

local VER_17048   = 0x0012
local VER_17049   = 0x0013
local VER_17043   = 0x001E
local VER_17044   = 0x001F

local MODE_QUICKSTART = 0x4000
local STATUS_FLAGS    = 0x3F00	-- 高字节 bit0~5 的 16 位掩码
local STATUS_ENVR     = 0x4000

-- ==================== 工具 ====================
local function s16(v)
	v = v % 65536
	if v >= 32768 then v = v - 65536 end
	return v
end

-- ==================== 模块级配置 ====================
local cfg_lsb_v		-- VCELL 每 LSB 伏特（17048: 78.125uV / 17049: 156.25uV）
local cfg_variant	-- 器件名（横幅/报错用）

-- ==================== 配置脚本 ====================
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MAX17048 builder func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-- VERSION 自检（家族地址相同，插错芯片在这里拦下）
	local ver = i2c_read_multi(fd, REG_VER, 2)
	if ver < 0 then
		return {
			result = "ERR",
			message = "MAX17048 not responding (read version failed, check address 0x36 and wiring)"
		}
	end
	if ver == VER_17043 or ver == VER_17044 then
		return {
			result = "ERR",
			message = string.format("MAX17048 wrong chip: version 0x%04X is MAX17043/44, use the MAX17043 driver", ver)
		}
	end
	if ver ~= VER_17048 and ver ~= VER_17049 then
		return {
			result = "ERR",
			message = string.format("MAX17048 unexpected version 0x%04X (expect 0x0012/0x0013)", ver)
		}
	end
	cfg_variant = (ver == VER_17048) and "MAX17048" or "MAX17049"
	cfg_lsb_v = (ver == VER_17048) and 78.125e-6 or 156.25e-6

	-- QuickStart（可选）：换电池/上电后跳过慢收敛
	if tostring(data.quickstart) == "1" then
		if i2c_write_multi(fd, REG_MODE, 0x40, 0x00) ~= 0 then
			return {
				result = "ERR",
				message = "MAX17048 not responding (quickstart write failed)"
			}
		end
		milli_sleep(5)
	end

	-- VALRT 过压/欠压阈值（20mV/LSB，读改写保留另一侧）
	local vmax = tonumber(data.valrt_max)
	local vmin = tonumber(data.valrt_min)
	if vmax ~= nil or vmin ~= nil then
		local cur = i2c_read_multi(fd, REG_VALRT, 2)
		if cur < 0 then
			return {
				result = "ERR",
				message = "MAX17048 not responding (read VALRT failed)"
			}
		end
		local hi = math.floor(cur / 256) % 256
		local lo = cur % 256
		if vmax ~= nil then
			if vmax < 0 or vmax > 5.1 then
				return {
					result = "ERR",
					message = "Invalid Argument: valrt_max '" .. tostring(data.valrt_max) .. "' (range 0~5.1V)"
				}
			end
			hi = math.floor(vmax / 0.02 + 0.5)
			if hi > 255 then hi = 255 end
		end
		if vmin ~= nil then
			if vmin < 0 or vmin > 5.1 then
				return {
					result = "ERR",
					message = "Invalid Argument: valrt_min '" .. tostring(data.valrt_min) .. "' (range 0~5.1V)"
				}
			end
			lo = math.floor(vmin / 0.02 + 0.5)
			if lo > 255 then lo = 255 end
		end
		if i2c_write_multi(fd, REG_VALRT, hi, lo) ~= 0 then
			return {
				result = "ERR",
				message = "MAX17048 not responding (VALRT write failed)"
			}
		end
	end

	-- ATHD SOC 低电告警阈值（CONFIG 低 5 位，读改写保留 RCOMP）
	local athd = tonumber(data.athd)
	if athd ~= nil then
		if athd < 1 or athd > 32 then
			return {
				result = "ERR",
				message = "Invalid Argument: athd '" .. tostring(data.athd) .. "' (range 1~32%)"
			}
		end
		local cur = i2c_read_multi(fd, REG_CONFIG, 2)
		if cur < 0 then
			return {
				result = "ERR",
				message = "MAX17048 not responding (read CONFIG failed)"
			}
		end
		-- 低字节 bit7:5（SLEEP/ALSC/ETHRM）保留，仅替换 bit4:0 的 ATHD
		local lo = (cur % 256) - (cur % 32) + (32 - math.floor(athd))
		local hi = math.floor(cur / 256) % 256
		if i2c_write_multi(fd, REG_CONFIG, hi, lo % 256) ~= 0 then
			return {
				result = "ERR",
				message = "MAX17048 not responding (CONFIG write failed)"
			}
		end
	end

	-- 读一次状态做横幅（复位指示 RI 常见于上电后首次读取）
	local st = i2c_read_multi(fd, REG_STATUS, 2)
	local flags = (st >= 0) and math.floor(st / 256) % 64 or 0

	print(string.format("%s init OK: addr=0x%02X ver=0x%04X status=0x%02X lsb=%.2fuV",
		cfg_variant, addr, ver, flags, cfg_lsb_v * 1e6))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 读电压/SOC/速率/告警标志；clear=1 时读取后清除告警位
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MAX17048 caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-----------------------------------------------------
	local vraw = i2c_read_multi(fd, REG_VCELL, 2)
	if vraw < 0 then
		return {
			result = "ERR",
			message = "MAX17048 not responding (read VCELL failed)"
		}
	end
	local sraw = i2c_read_multi(fd, REG_SOC, 2)
	if sraw < 0 then
		return {
			result = "ERR",
			message = "MAX17048 not responding (read SOC failed)"
		}
	end
	local craw = i2c_read_multi(fd, REG_CRATE, 2)
	if craw < 0 then
		return {
			result = "ERR",
			message = "MAX17048 not responding (read CRATE failed)"
		}
	end
	local straw = i2c_read_multi(fd, REG_STATUS, 2)
	if straw < 0 then
		return {
			result = "ERR",
			message = "MAX17048 not responding (read STATUS failed)"
		}
	end

	-- clear=1：按位清除告警标志（高字节 bit0~5；保留 bit6 EnVR 等）
	if tostring(data.clear) == "1" then
		local hi = math.floor(straw / 256) % 256
		if hi % 64 ~= 0 then		-- 告警位有置位才写
			i2c_write_multi(fd, REG_STATUS, hi - (hi % 64), straw % 256)
		end
	end

	return {
		result = "OK",
		VCELL = vraw * (cfg_lsb_v or 78.125e-6),
		SOC = math.floor(sraw / 256) + (sraw % 256) / 256.0,
		CRATE = s16(craw) * 0.208,
		STATUS = math.floor(straw / 256) % 64
	}

end

-- ==================== 销毁 ====================
-- 无关断寄存器（休眠经 HIBRT 自行配置，本驱动不触碰）；fd 归 I2C 硬件变量所有
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end

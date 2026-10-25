-- TPL0501 256 抽头数字电位器 驱动模块（SPI，写-only）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SPI (
--       name String, path String, spi_mode String, bits String, speed String, delay String
--   );
--   INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
--     VALUES ('spi-0', '/dev/spidev0.0', '0', '8', '1000000', '0');
--   CREATE TABLE TPL0501 (
--       name    String,
--       SPI     String,
--       rtotal  String
--   );
--   INSERT INTO TPL0501 (name, SPI, rtotal) VALUES ('dpot-0', 'spi-0', '100000');
-- @SPI 的 spi_mode 配 0（模式 0，MSB 先行，CS 低有效）；bits 配 8；
-- 时钟上限 10MHz（数据手册），接线长时建议 1MHz 起步
-- rtotal = 端到端电阻（Ω）：100000 = TPL0501-100，10000 = TPL0501-10
--
-- call 参数（三选一，优先级 level > percent > ohms）：
--   level   0~255 抽头原始值
--   percent 0~100 抽头百分比（按 255 折算）
--   ohms    目标电阻（W-L 之间，Ω；需 rtotal 列，滑动端电阻 ~70Ω 另计入实际电路）
-- 返回 { result, level, ohms }（ohms 为按 rtotal 折算的实际阻值）
--
-- 实现要点（依 TI 数据手册 SLIS151）：
--   1. 协议即一个 SPI 字节：CS 低 -> 移入 8 位抽头值 -> CS 高，无命令字、
--      无寄存器地址、无读回能力（引脚无 SDO）——故 build 无事可做，
--      写失败只能靠 HAL spi_write 的返回值（0/-1）报告传输成败
--   2. 抽头易失：上电默认中点 0x7F（127），掉电不保存——动作序列
--      勿假设抽头从 0 开始，build 亦不做任何写操作
--   3. 量化：100k 型每步约 390Ω，10k 型每步约 39Ω
--   4. fd/delay 经元数据引用机制从 @SPI 变量流入（同 ADS1256 的模式）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：电位器一般低频调节，默认关闭逐次打印
local DEBUG = false

local WIPER_MAX = 255			-- 256 抽头（0~255）
local DEF_RTOTAL = 100000		-- 缺省按 TPL0501-100（100kΩ）

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local rtotal

-- 抽头位置 -> W-L 实际阻值（Ω）
local function level_to_ohms(level)
	return level / WIPER_MAX * (rtotal or DEF_RTOTAL)
end

-- 【配置脚本】写-only 器件无寄存器可校验，仅记录换算配置
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- TPL0501 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	local rt = tonumber(data.rtotal)
	if rt ~= nil and rt > 0 then rtotal = rt else rtotal = DEF_RTOTAL end

	print(string.format(
		"TPL0501 init OK: rtotal=%d Ω（上电抽头为中点 127，非 0）", rtotal))
	return {  result = "OK"  }

end

-- 【销毁TPL0501】无资源需要释放（总线归 SPI 硬件变量所有；抽头掉电即失）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用TPL0501】设置抽头位置（level/percent/ohms 三选一）
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- TPL0501 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	-- 三选一换算（优先级 level > percent > ohms）
	local level
	if data.level ~= nil then
		level = tonumber(data.level)
		if level == nil then
			return {
				result = "ERR",
				message = "Invalid Argument: level (not a number)"
			}
		end
	elseif data.percent ~= nil then
		local pct = tonumber(data.percent)
		if pct == nil then
			return {
				result = "ERR",
				message = "Invalid Argument: percent (not a number)"
			}
		end
		level = math.floor(pct / 100.0 * WIPER_MAX + 0.5)
	elseif data.ohms ~= nil then
		local ohms = tonumber(data.ohms)
		if ohms == nil then
			return {
				result = "ERR",
				message = "Invalid Argument: ohms (not a number)"
			}
		end
		level = math.floor(ohms / (rtotal or DEF_RTOTAL) * WIPER_MAX + 0.5)
	else
		return {
			result = "ERR",
			message = "Invalid Argument: need level / percent / ohms"
		}
	end

	-- 限幅到 0~255
	if level < 0 then level = 0 end
	if level > WIPER_MAX then level = WIPER_MAX end
	level = math.floor(level)

	-----------------------------------------------------
	-- 写抽头：一个 SPI 字节即完整操作；delay 经元数据从 @SPI 流入
	if spi_write(fd, level, tonumber(data.delay)) ~= 0 then
		return {
			result = "ERR",
			message = "Failed to write TPL0501 wiper"
		}
	end

	if DEBUG then
		print(string.format("TPL0501: level=%d (≈%.0f Ω)", level, level_to_ohms(level)))
	end

	return {
		result = "OK",
		level  = level,
		ohms   = level_to_ohms(level)
	}

end

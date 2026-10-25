-- BH1750 环境光传感器（I2C，数字光照强度）驱动模块
-- bot4cj 仓颉语言机器人框架
--
-- 特点：
--   - 二线命令式协议：指令为单字节 opcode（无寄存器指针），
--     测量结果从数据寄存器【纯读】（0x00 是 Power Down 命令，写指针会破坏状态，
--     故不用 i2c_read_multi_bytes，必须走 HAL 的 i2c_read 纯读路径）
--   - 器件无 ID 寄存器可甄别，build 以「上电 + 模式命令写成功」作为在位判定
--   - 连续模式由器件自主刷新，call 每次读当前值（读太频繁只是值滞后）
--   - 地址：ADDR=Low -> 0x23，ADDR=High -> 0x5C（一总线可挂 2 颗）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BH1750 (
--       name    String,
--       I2C     String,
--       address String,
--       mode    String,   -- 可选：H（缺省，连续 1lx/0.5lx sensing）| H2 | L
--       once    String,   -- 可选：1 = 单次测量（每 call 发命令+等待），缺省连续
--       mtreg   String    -- 可选：测量时间/灵敏度 31~254（缺省 69，越大越灵敏越慢）
--   );
--   INSERT INTO BH1750 (name, I2C, address) VALUES ('light0', 'i2c-1', '0x23');
--
-- call 无需参数，返回 { result, LUX(单位 lux，浮点) }
-- 换算（含 MTreg 归一）：LUX = count x LSB_LUX x 69 / (1.2 x mtreg)
--   mode=H ：LSB=1.0（1lx/LSB，mt=69 时 LUX = count/1.2，一帧约 120ms）
--   mode=H2：LSB=0.5（0.5lx/LSB，LUX = count/2.4）
--   mode=L ：LSB=4.0（4lx/LSB，LUX = count/0.3，一帧约 16ms）
--
-- 接 sensor_daemon：fields=LUX（浮点，勿配 sign）；连续模式下 interval 建议
-- >= 一帧时间（H/H2 约 120ms、L 约 16ms）以求逐帧新值。
--
-- 实现要点（协议与换算经官方罗姆 ROHM 手册 + Adafruit/Claws BH1750 双源互证）：
--   1. 模式命令 0x10/0x11/0x13 连续，0x20/0x21/0x23 单次
--   2. MTreg 设置需连写两字节命令：0x40|(mt>>5)&7 与 0x60|mt&0x1F
--      （先高比特再低比特；MTreg 增大测量时间与灵敏度均按比例提升）
--   3. 返回值最大 65535 counts；H2 档约 27306 lx、H 档约 54612 lx 封顶

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：光照高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令 opcode ====================
local CMD_POWER_DOWN = 0x00		-- 掉电（唤醒需再 Power On）
local CMD_POWER_ON   = 0x01		-- 上电待机
local CMD_CONT_H     = 0x10		-- 连续 H 分辨率（1lx）
local CMD_CONT_H2    = 0x11		-- 连续 H2 分辨率（0.5lx）
local CMD_CONT_L     = 0x13		-- 连续 L 分辨率（4lx）
local CMD_ONCE_H     = 0x20		-- 单次 H
local CMD_ONCE_H2    = 0x21		-- 单次 H2
local CMD_ONCE_L     = 0x23		-- 单次 L
local CMD_MT_HIGH    = 0x40		-- MTreg 高比特基址
local CMD_MT_LOW     = 0x60		-- MTreg 低比特基址

local MTREG_DEFAULT  = 69		-- 出厂测量时间基准
local MTREG_MIN      = 31
local MTREG_MAX      = 254
local FRAME_MS_H     = 120		-- H/H2 一帧（mt=69 时）
local FRAME_MS_L     = 16		-- L 一帧

-- 每档位每 LSB 的 lux 数（换算基准，见头部公式）
local MODE_T = {
	H  = { cont = CMD_CONT_H,  once = CMD_ONCE_H,  lsb = 1.0, frame = FRAME_MS_H },
	H2 = { cont = CMD_CONT_H2, once = CMD_ONCE_H2, lsb = 0.5, frame = FRAME_MS_H },
	L  = { cont = CMD_CONT_L,  once = CMD_ONCE_L,  lsb = 4.0, frame = FRAME_MS_L },
}
local MODE_DEFAULT = "H"

-- ==================== 模块级配置 ====================
local mode_t = MODE_T[MODE_DEFAULT]
local once   = false
local mtreg  = MTREG_DEFAULT

-- 单字节命令写（BH1750 无寄存器指针，opcode 即整帧）
local function send_cmd(fd, cmd)
	return i2c_write_multi(fd, cmd) == 0
end

-- MTreg 测量时间/灵敏度设置：连写高比特 + 低比特两字节命令
local function set_mtreg(fd)
	if mtreg == MTREG_DEFAULT then return true end
	local hi = bitc.bor(CMD_MT_HIGH, math.floor(mtreg / 32) % 8)	-- 0x40|(mt>>5)&7
	local lo = bitc.bor(CMD_MT_LOW,  mtreg % 32)					-- 0x60|mt&0x1F（MT[4:0]）
	return send_cmd(fd, hi) and send_cmd(fd, lo)
end

-- 测量模式命令 + 单帧时间
local function mode_cmd()
	return once and mode_t.once or mode_t.cont
end

-- ==================== 配置脚本 ====================
-- 上电 +（可选）MTreg + 测量模式；连续/单次模式均等待一帧让首发有效
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BH1750 builder func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	-- 列参数：mode（H/H2/L）、once（1/0）、mtreg（31~254）
	local m = tostring(data.mode or MODE_DEFAULT):upper()
	if MODE_T[m] == nil then
		return err("Invalid mode '" .. tostring(data.mode) .. "' (H|H2|L)")
	end
	mode_t = MODE_T[m]
	once   = (tostring(data.once) == "1" or tostring(data.once) == "true")

	mtreg = tonumber(data.mtreg) or MTREG_DEFAULT
	if mtreg < MTREG_MIN then mtreg = MTREG_MIN end
	if mtreg > MTREG_MAX then mtreg = MTREG_MAX end

	-- 在位判定：Power On + 模式命令写成功（器件无 ID 寄存器可读）
	if not send_cmd(fd, CMD_POWER_ON) then
		return err("BH1750 not responding (power on failed, check address 0x23/0x5C and wiring)")
	end
	if not set_mtreg(fd) then
		return err("BH1750 not responding (MTreg write failed)")
	end
	if not send_cmd(fd, mode_cmd()) then
		return err("BH1750 not responding (mode command failed)")
	end

	-- 等待一帧（连续模式让首发即时有效；单次模式该命令即本帧）
	milli_sleep(mode_t.frame * mtreg / MTREG_DEFAULT)

	print(string.format("BH1750 init OK: addr=0x%02X mode=%s once=%s mtreg=%d",
		addr, m, tostring(once), mtreg))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 读当前光照（连续模式读最新帧；单次模式发命令 + 等一帧再读）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BH1750 caller func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	if once then
		if not send_cmd(fd, mode_cmd()) then
			return err("BH1750 not responding (one-shot command failed)")
		end
		milli_sleep(mode_t.frame * mtreg / MTREG_DEFAULT)
	end

	-- 纯读 2 字节（不能用 i2c_read_multi_bytes：写指针 0x00 = Power Down 命令）
	local raw = i2c_read(fd, 2)
	if raw < 0 then
		return err("BH1750 not responding (read measurement failed)")
	end
	local count = raw % 65536

	-- LUX = count x LSB x 69 / (1.2 x mtreg)
	local lux = count * mode_t.lsb * MTREG_DEFAULT / (1.2 * mtreg)

	return {  result = "OK",  LUX = lux  }

end

-- ==================== 销毁 ====================
-- 发 Power Down 进入最低功耗；失败不致命（返回 OK）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- BH1750 ender func get a table --------", data)
	end

	local fd, addr, ek = i2c_pair(data)
	if fd == nil then
		return ek
	end

	if not send_cmd(fd, CMD_POWER_DOWN) then
		print("BH1750 destroy: power down write failed (ignored)")
	end

	return {  result = "OK"  }

end
-- BH1745NUC 四通道颜色传感器 驱动模块（红/绿/蓝/透明）
-- bot4cj 仓颉语言机器人框架
-- ROHM，I2C 地址 0x38/0x39（ADRSEL 引脚），16 位 ADC x 4 通道
-- 注意：是颜色传感器（RGB 光谱比值），不是 BH1750 照度计
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BH1745 (
--       name    String,
--       I2C     String,
--       address String,
--       mt      String,
--       gain    String
--   );
--   INSERT INTO BH1745 (name, I2C, address, mt, gain)
--     VALUES ('colour0', 'i2c-1', '0x38', '-', '-');
-- mt   = 测量时间 ms（160/320/640/1280/2560/5120，非法值向下降档，缺省 160）
-- gain = ADC 增安比？增益（1/2/16，非法值向下降档，缺省 1）；暗光可开 16，
--        强光下高增益会饱和（通道读数顶到 0xFFFF）
-- 各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回 { result, R, G, B, C }（各通道 16 位原始计
-- 数，无符号；通道间比值才是颜色信息，绝对值受积分时间/增益/光源影响）
-- 接 sensor_daemon：fields=R|G|B|C（无符号，勿配 sign；interval >= mt）
--
-- 实现要点（寄存器/语义依 Pimoroni BH1745-python 库核实，MIT）：
--   1. 甄别双 ID：SYSTEM_CONTROL(0x40)[5:0] Part ID = 0x0B（0b001011）、
--      MANUFACTURER(0x92) = 0xE0，build 软复位后验证
--   2. 寄存器基址 0x40 起（网上老示例按 0x80 起的写法是别的芯片，勿照搬）
--   3. 颜色数据【大端】：COLOUR_DATA(0x50) 起 8 字节 = R/G/B/C 四通道
--      每通道 MSB 在前——与 ST/Bosch IMU 的小端相反；i2c_read_multi 的
--      合并读恰好按大端拼字，8 字节一次原子读后按 16 位逐对拆分
--   4. 配置分工与直觉不同：MODE_CONTROL1(0x41) 只有测量时间 [2:0]，
--      ADC 增益在 MODE_CONTROL2(0x42)[1:0]（只有 x1/x2/x16 三档，0b11 保留），
--      测量启动 = MODE_CONTROL2 bit4 (RGBC_EN)，数据有效 = bit7 (VALID)
--   5. MODE_CONTROL3(0x44) 写 0x02 启用通道有效判别（Pimoroni 同款）；
--      build 后等一个完整测量时间首拍数据才就绪
--   6. 中断/阈值/持久化（0x60~0x65）本驱动未用（守护周期采样路径不需要）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_SYS_CTRL  = 0x40		-- bit7=sw_reset bit6=int_reset [5:0]=part_id
local REG_MODE1     = 0x41		-- [2:0] 测量时间
local REG_MODE2     = 0x42		-- bit7=VALID bit4=RGBC_EN [1:0]=ADC 增益
local REG_MODE3     = 0x44		-- 写 0x02 = 通道有效判别开启
local REG_DATA      = 0x50		-- 8 字节：R/G/B/C 四通道 16 位，MSB 在前
local REG_MFR_ID    = 0x92

local PART_ID       = 0x0B		-- 0b001011
local MFR_ID        = 0xE0
local SW_RESET      = 0x80
local RGBC_EN       = 0x10

-- 测量时间档 ms（MODE1 代码 0..5），缺省 160
local mt_tab = { 160, 320, 640, 1280, 2560, 5120 }
-- ADC 增益（MODE2 代码 0..2），缺省 x1
local gain_tab = { 1, 2, 16 }

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local mt_ms = 160

-- 向下取档：不大于 n 的最大合法档；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

local function mt_code_of(v)
	local i = snap_down(v, mt_tab, 1)
	return i - 1, mt_tab[i]
end

local function gain_code_of(v)
	local i = snap_down(v, gain_tab, 1)
	return i - 1, gain_tab[i]
end

-- 【配置脚本】软复位 -> 双 ID 甄别 -> 测量时间/增益 -> 启动测量 -> 等首拍
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BH1745 builder func get a table --------", data)
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

	-- 列配置
	local mt_code_v, mt_n = mt_code_of(data.mt)
	local gain_code_v, gain_n = gain_code_of(data.gain)
	mt_ms = mt_n

	-----------------------------------------------------
	-- 软复位（bit7 自清，随后系统控制仅剩 Part ID）
	if not i2c_write_reg(fd, REG_SYS_CTRL, SW_RESET) then
		return {
			result = "ERR",
			message = "Failed to write BH1745 soft reset"
		}
	end
	milli_sleep(5)

	-- 双 ID 甄别
	local sys = i2c_read_reg(fd, REG_SYS_CTRL)
	local mfr = i2c_read_reg(fd, REG_MFR_ID)
	if sys < 0 or mfr < 0 then
		return {
			result = "ERR",
			message = "Failed to read BH1745 ID registers"
		}
	end
	local part = sys % 64		-- [5:0] Part ID（算术取低位）
	if part ~= PART_ID or mfr ~= MFR_ID then
		return {
			result = "ERR",
			message = string.format("Not BH1745: PART_ID=0x%02X (expect 0x0B), MFR_ID=0x%02X (expect 0xE0)",
				part, mfr)
		}
	end

	-- 测量时间（MODE1 [2:0]）+ 增益（MODE2 [1:0]）+ 启动测量（bit4）
	if not i2c_write_reg(fd, REG_MODE1, mt_code_v) then
		return {
			result = "ERR",
			message = "Failed to write BH1745 mode control 1"
		}
	end
	if not i2c_write_reg(fd, REG_MODE2, bitc.bor(RGBC_EN, gain_code_v)) then
		return {
			result = "ERR",
			message = "Failed to write BH1745 mode control 2"
		}
	end
	if not i2c_write_reg(fd, REG_MODE3, 0x02) then
		return {
			result = "ERR",
			message = "Failed to write BH1745 mode control 3"
		}
	end

	-- 等一个完整测量时间，首拍数据就绪
	milli_sleep(mt_n + 2)

	print(string.format("BH1745 init OK: addr=0x%02X, mt=%dms, gain=x%d", addr, mt_n, gain_n))
	return {  result = "OK"  }

end

-- 【销毁BH1745】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用BH1745】读四通道原始计数
-- NOTE: 数据大端（MSB 在前，与 IMU 小端相反）；一次 8 字节原子读
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- BH1745 caller func get a table --------", data)
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
	-- 8 字节一次原子读（字节表接口：合并数值接口 6 字节以上超 Lua number 精度）
	local b = i2c_read_multi_bytes(fd, REG_DATA, 8)
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read BH1745 colour data"
		}
	end

	-- 8 字节按大端拆 4 个 16 位通道：R/G/B/C
	local ret = {
		result = "OK",
		R = b[1] * 256 + b[2],
		G = b[3] * 256 + b[4],
		B = b[5] * 256 + b[6],
		C = b[7] * 256 + b[8]
	}

	if DEBUG then
		print(string.format("BH1745: R=%d G=%d B=%d C=%d", ret.R, ret.G, ret.B, ret.C))
	end

	return ret

end

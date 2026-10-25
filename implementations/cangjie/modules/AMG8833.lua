-- AMG8833 8x8 红外热电堆阵列 驱动模块（Grid-EYE，热像聚合输出）
-- bot4cj 仓颉语言机器人框架
-- Panasonic，I2C 地址 0x69（AD_SELECT 缺省）/0x68（拉高），64 像素
-- 0~80°C @0.25°C/LSB，帧率 10/1Hz，基板热敏电阻 0.0625°C/LSB
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE AMG8833 (
--       name    String,
--       I2C     String,
--       address String,
--       fps     String
--   );
--   INSERT INTO AMG8833 (name, I2C, address, fps)
--     VALUES ('cam0', 'i2c-1', '-', '-');
-- address = 0x69/0x68（'-' 缺省 0x69）
-- fps     = 1 -> 1Hz；其余/'-' 缺省 10Hz
--
-- call 无需额外参数，返回聚合标量（框架桥 call_lua 只回传标量、守护槽
-- 上限 16 值——64 像素原始数据流不过桥，故输出机器人可直接消费的聚合）：
--   { result, MAXT, MINT, AVGT, MAXR, MAXC, THERM }
--   MAXT/MINT/AVGT = 全阵列最高/最低/平均温度 °C
--   MAXR/MAXC      = 热点行列 0~7（行 0 靠近丝印侧）
--   THERM          = 基板热敏电阻温度 °C
-- 接 sensor_daemon：fields=MAXT|AVGT|MAXR|MAXC|THERM（浮点透传，勿配 sign）
--
-- 实现要点（寄存器/语义依 Adafruit CircuitPython AMG88xx 库核实，MIT）：
--   1. 像素数据 0x80 起 64 x 2 字节，12 位补码、小端（LSB 在偶地址），
--      0.25°C/LSB；热敏电阻 0x0E/0x0F，12 位补码，0.0625°C/LSB
--   2. 像素读法：8 次 16 字节块读（i2c_read_multi_bytes，I2C_RDWR 原子
--      事务）——Adafruit 参考实现逐像素 64 次事务，块读快一个量级；
--      块读跨帧界混合风险在 10Hz 周期 100ms 下可忽略（8 次事务 <2ms）
--   3. build 时序：normal 模式 -> 初始复位 0x3F -> 关中断 -> 帧率 ->
--      等一个帧周期首拍就绪（10Hz=120ms / 1Hz=1020ms）
--   4. 像素阈值中断组（0x08~0x0D + 中断表）与滑动平均（隐形寄存器 0x1F
--      魔术序列，本核实源未实现）v1 不接，守护轮询路径不需要
--   5. HAL 字节表读上限 16 字节，128 字节像素区拆 8 块正好对齐行边界

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：热像高频采样，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_PCTL  = 0x00		-- Power Control
local REG_RST   = 0x01		-- Reset
local REG_FPSC  = 0x02		-- bit0：帧率（0=10Hz 1=1Hz）
local REG_INTC  = 0x03		-- 中断控制
local REG_THERM = 0x0E		-- 热敏电阻 LSB（12 位补码，0.0625°C/LSB）
local REG_DATA  = 0x80		-- 像素数据 64 x 2 字节（12 位补码 LE，0.25°C/LSB）

local NORMAL_MODE   = 0x00
local INITIAL_RESET = 0x3F

local PIXEL_CHUNK   = 16		-- 每块 8 像素（HAL 字节表读上限 16）
local PIXEL_COUNT   = 64

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local fps_1hz = false

-- 12 位二进制补码还原（像素/热敏电阻共用）
local function s12(v)
	v = v % 0x1000
	if v >= 0x800 then v = v - 0x1000 end
	return v
end

-- 【配置脚本】normal -> 初始复位 -> 关中断 -> 帧率 -> 等首拍
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AMG8833 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-- 地址列 '-'/缺省按器件缺省 0x69（AD_SELECT 拉低）
	local addr = tonumber(data.address) or 0x69
	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-- 帧率列：1 -> 1Hz，其余/'-' 缺省 10Hz
	fps_1hz = (tonumber(data.fps) == 1)

	-----------------------------------------------------
	-- 进入 normal 模式 -> 初始复位 -> 关中断 -> 帧率（Adafruit 参考顺序）
	if not i2c_write_reg(fd, REG_PCTL, NORMAL_MODE) then
		return {
			result = "ERR",
			message = "Failed to write AMG8833 power control"
		}
	end
	if not i2c_write_reg(fd, REG_RST, INITIAL_RESET) then
		return {
			result = "ERR",
			message = "Failed to write AMG8833 initial reset"
		}
	end
	milli_sleep(5)
	if not i2c_write_reg(fd, REG_INTC, 0x00) then
		return {
			result = "ERR",
			message = "Failed to write AMG8833 interrupt control"
		}
	end
	if not i2c_write_reg(fd, REG_FPSC, fps_1hz and 0x01 or 0x00) then
		return {
			result = "ERR",
			message = "Failed to write AMG8833 frame rate"
		}
	end

	-- 等一个完整帧周期，首拍数据就绪
	local wait_ms = (fps_1hz and 1000 or 100) + 20
	milli_sleep(wait_ms)

	print(string.format("AMG8833 init OK: addr=0x%02X, fps=%dHz, pixels=64 (0.25°C/LSB)",
		addr, fps_1hz and 1 or 10))
	return {  result = "OK"  }

end

-- 【销毁AMG8833】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用AMG8833】读 64 像素聚合 + 基板温度
-- NOTE: 12 位补码小端拆字；输出聚合标量（MAXT/MINT/AVGT/MAXR/MAXC/THERM）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AMG8833 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address) or 0x69	-- 与 build 同款缺省（AD_SELECT 拉低）
	if fd == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-- 共享总线 fd 的从地址是 per-fd 状态：每次 call 显式 set_addr，
	-- 否则两次 call 之间别的器件寻址会把本器件读数打到错误从地址
	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 基板热敏电阻（12 位补码，0.0625°C/LSB）
	local tb = i2c_read_multi_bytes(fd, REG_THERM, 2)
	if tb == nil then
		return {
			result = "ERR",
			message = "Failed to read AMG8833 thermistor"
		}
	end
	local therm = s12((tb[2] % 0x10) * 256 + tb[1]) * 0.0625

	-- 64 像素：8 次 16 字节块读（8 像素/块），同时聚合
	local sum = 0
	local maxt, mint = -999, 999
	local max_idx = 0
	for chunk = 0, 7 do
		local b = i2c_read_multi_bytes(fd, REG_DATA + chunk * PIXEL_CHUNK, PIXEL_CHUNK)
		if b == nil then
			return {
				result = "ERR",
				message = "Failed to read AMG8833 pixels (chunk " .. chunk .. ")"
			}
		end
		for p = 0, 7 do
			local raw = s12((b[p * 2 + 2] % 0x10) * 256 + b[p * 2 + 1])
			local t = raw * 0.25
			sum = sum + t
			local idx = chunk * 8 + p
			if t > maxt then maxt = t; max_idx = idx end
			if t < mint then mint = t end
		end
	end
	local avgt = sum / PIXEL_COUNT

	local ret = {
		result = "OK",
		MAXT   = maxt,
		MINT   = mint,
		AVGT   = avgt,
		MAXR   = math.floor(max_idx / 8),
		MAXC   = max_idx % 8,
		THERM  = therm
	}

	if DEBUG then
		print(string.format("AMG8833: MAXT=%.2f MINT=%.2f AVGT=%.2f @[%d][%d] THERM=%.3f",
			ret.MAXT, ret.MINT, ret.AVGT, ret.MAXR, ret.MAXC, ret.THERM))
	end

	return ret

end

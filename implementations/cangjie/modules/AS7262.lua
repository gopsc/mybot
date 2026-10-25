-- AS7262 六通道可见光光谱传感器 驱动模块（ams，I2C 地址 0x49）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE AS7262 (
--       name    String,
--       I2C     String,
--       address String,
--       gain    String,
--       integ   String,
--       timeout String
--   );
--   INSERT INTO AS7262 (name, I2C, address)
--     VALUES ('spec0', 'i2c-1', '0x49');
--
-- 列说明（均可选，'-' 归缺省）：
--   gain    = 增益倍数 1/3.7/16/64（就近吸附，缺省 64；强光下 64x 易饱和，
--             看原始计数是否顶格 0xFFFF 判断）
--   integ   = 积分时间寄存器值 0~255（每单位 2.8ms；连续全通道模式下
--             一轮 = 2 x 该值 x 2.8ms，缺省 50 -> 每轮约 280ms）
--   timeout = call 等待 DATA_RDY 超时 ms（缺省自动 = 2 x 轮时间 + 500）
--
-- call 无需参数，返回：
--   { result, V/B/G/Y/O/R(六通道 16 位原始计数),
--     TEMP_C(片上温度 °C，精度约 ±8.5°C) }
-- 接 sensor_daemon：fields=V|B|G|Y|O|R（interval >= 一轮积分时间）
--
-- 协议（间接寄存器访问，SparkFun AS726X 库同款时序）：
--   I2C 只暴露 3 个硬件寄存器：状态 0x00（bit1=TX_VALID、bit0=RX_VALID）、
--   写口 0x01、读口 0x02。访问任意虚拟寄存器都要握手：
--   读 = 等 TX 空 -> 写虚拟地址(bit7=0) -> 等 RX 置位 -> 读数据；
--   写 = 等 TX 空 -> 写虚拟地址(bit7=1) -> 再等 TX 空 -> 写数据。
--   握手是芯片侧状态，禁止并发访问同一器件（沿用一器件一消费者约定）。
--
-- build 流程：软复位（RST 位，等 1s，SparkFun 同款无启动轮询）->
--   器件甄别（虚拟寄存器 0x00 应为 0x3E）-> 写积分时间 ->
--   配增益与模式 2（连续全通道，上电默认同款）。
--   LED（指示/照明）未实现，供电默认关闭；六通道地址：
--   V 0x08 / B 0x0A / G 0x0C / Y 0x0E / O 0x10 / R 0x12（MSB 在偶地址）。
-- 应用提示：六通道模式一次测量 ~2 x 积分时间，采样率受此限制；
--   各通道可直接挂 Ema/Kalman 滤波链做平滑光谱。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：光谱高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 硬件寄存器（间接访问口） ====================
local HW_STATUS = 0x00			-- bit1=TX_VALID（写缓冲占用）、bit0=RX_VALID（读就绪）
local HW_WRITE  = 0x01
local HW_READ   = 0x02
local TX_VALID  = 0x02
local RX_VALID  = 0x01

-- ==================== 虚拟寄存器 ====================
local V_DEVICE_TYPE    = 0x00	-- 0x3E = AS7262（0x3D=AS7261，0x3F=AS7263）
local V_HW_VERSION     = 0x01
local V_CONTROL_SETUP  = 0x04	-- bit7=RST、[5:4]=GAIN、[3:2]=BANK、bit1=DATA_RDY
local V_INT_T          = 0x05	-- 积分时间，每单位 2.8ms
local V_DEVICE_TEMP    = 0x06	-- 片上温度（二进制补码 °C）
local V_V, V_B, V_G, V_Y, V_O, V_R = 0x08, 0x0A, 0x0C, 0x0E, 0x10, 0x12

-- ==================== 常量 ====================
local DEV_TYPE_AS7262 = 0x3E

local BANK_ALL_CONT = 0x02		-- 模式 2：连续全通道（上电默认同款）
local MASK_GAIN     = 0xCF		-- 清 [5:4]
local MASK_BANK     = 0xF3		-- 清 [3:2]
local BIT_DATA_RDY  = 0x02
local BIT_RST       = 0x80

local T_RESET_MS = 1000			-- RST 后等待（SparkFun 同款，无启动轮询）
local POLL_MS    = 5			-- 握手/就绪轮询步长
local HS_TRIES   = 50			-- 单次握手步上限（x POLL_MS = 250ms 预算）

local GAIN_TAB = { { 1, 0 }, { 3.7, 1 }, { 16, 2 }, { 64, 3 } }	-- {倍数, 代码}

local DEF_GAIN_CODE  = 3		-- 缺省 64x
local DEF_INTEG      = 50		-- 2.8ms x 50 = 140ms/库
local CHANS = { { "V", V_V }, { "B", V_B }, { "G", V_G },
                { "Y", V_Y }, { "O", V_O }, { "R", V_R } }

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local poll_timeout

-- ==================== 底层辅助 ====================
-- 数值列 -> 钳到 [lo, hi] 的整数；非法/'-' 归缺省
local function int_of(v, def, lo, hi)
	local n = tonumber(v)
	if n == nil then return def end
	n = math.floor(n)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

-- 增益列 -> 代码：按倍数就近吸附到 1/3.7/16/64；非法/'-' 归缺省
local function gain_code_of(v)
	local n = tonumber(v)
	if n == nil then return DEF_GAIN_CODE end
	local best, best_d = DEF_GAIN_CODE, math.huge
	for _, g in ipairs(GAIN_TAB) do
		local d = math.abs(n - g[1])
		if d < best_d then best, best_d = g[2], d end
	end
	return best
end

-- 等状态寄存器某位清零/置位；ok(v) 返回 true 即退出
-- 超出重试预算返回 nil（总线失败），false（超时）
local function wait_status(fd, ok)
	local tries = 0
	while true do
		local st = i2c_read_reg(fd, HW_STATUS)
		if st < 0 then return nil end
		if ok(st) then return true end
		tries = tries + 1
		if tries > HS_TRIES then return false end
		milli_sleep(POLL_MS)
	end
end

-- 读虚拟寄存器（SparkFun virtualReadRegister 同款时序），失败返回 nil
local function virtual_read(fd, vaddr)
	-- 预冲刷：RX_VALID 置位说明有滞留字节，读走丢弃
	local st = i2c_read_reg(fd, HW_STATUS)
	if st < 0 then return nil end
	if bitc.band(st, RX_VALID) ~= 0 then
		i2c_read_reg(fd, HW_READ)
	end
	-- 等 TX 空
	local r = wait_status(fd, function(s) return bitc.band(s, TX_VALID) == 0 end)
	if r ~= true then return nil end
	-- 写虚拟地址（bit7=0 = 读命令）
	if not i2c_write_reg(fd, HW_WRITE, vaddr % 256) then return nil end
	-- 等 RX 有效
	r = wait_status(fd, function(s) return bitc.band(s, RX_VALID) ~= 0 end)
	if r ~= true then return nil end
	return i2c_read_reg(fd, HW_READ)
end

-- 写虚拟寄存器（SparkFun virtualWriteRegister 同款时序），失败返回 nil
local function virtual_write(fd, vaddr, val)
	-- 等 TX 空
	local r = wait_status(fd, function(s) return bitc.band(s, TX_VALID) == 0 end)
	if r ~= true then return nil end
	-- 写虚拟地址（bit7=1 = 写命令）
	if not i2c_write_reg(fd, HW_WRITE, (vaddr % 256) + 0x80) then return nil end
	-- 再等 TX 空
	r = wait_status(fd, function(s) return bitc.band(s, TX_VALID) == 0 end)
	if r ~= true then return nil end
	-- 写数据
	if not i2c_write_reg(fd, HW_WRITE, val % 256) then return nil end
	return true
end

-- 读 16 位通道数据（MSB 在偶地址，LSB +1），失败返回 nil
local function read_channel(fd, vaddr)
	local hi = virtual_read(fd, vaddr)
	local lo = virtual_read(fd, vaddr + 1)
	if hi == nil or lo == nil or hi < 0 or lo < 0 then return nil end
	return hi * 256 + lo
end

-- 【配置脚本】软复位 -> 器件甄别 -> 积分/增益/模式 2
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AS7262 builder func get a table --------", data)
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

	-- 配置列
	local gain = gain_code_of(data.gain)
	local integ = int_of(data.integ, DEF_INTEG, 0, 255)
	local to = tonumber(data.timeout)
	if to == nil or to < 1 then
		-- 自动超时：2 x 一轮积分(2 x integ x 2.8ms) + 500ms
		to = math.floor(integ * 11.2) + 500
	end
	poll_timeout = math.floor(to)

	-----------------------------------------------------
	-- 软复位（RST 位，自清除；SparkFun 同款等 1s 不轮询启动）
	local ctl = virtual_read(fd, V_CONTROL_SETUP)
	if ctl == nil then
		return {  result = "ERR", message = "Failed to read AS7262 CONTROL_SETUP"  }
	end
	if virtual_write(fd, V_CONTROL_SETUP, bitc.bor(ctl % 256, BIT_RST)) == nil then
		return {  result = "ERR", message = "Failed to reset AS7262"  }
	end
	milli_sleep(T_RESET_MS)

	-- 器件甄别（虚拟寄存器 0x00 = 0x3E）
	local dtype = virtual_read(fd, V_DEVICE_TYPE)
	if dtype == nil then
		return {  result = "ERR", message = "Failed to read AS7262 device type"  }
	end
	if dtype ~= DEV_TYPE_AS7262 then
		return {
			result = "ERR",
			message = string.format("Device type = 0x%02X (expect 0x3E AS7262, not AS7262?)", dtype)
		}
	end

	-- 积分时间
	if virtual_write(fd, V_INT_T, integ) == nil then
		return {  result = "ERR", message = "Failed to write AS7262 integration time"  }
	end

	-- 增益（[5:4]）与模式 2 连续全通道（[3:2]），读-改-写合并一次
	ctl = virtual_read(fd, V_CONTROL_SETUP)
	if ctl == nil then
		return {  result = "ERR", message = "Failed to read AS7262 CONTROL_SETUP"  }
	end
	local v = bitc.band(ctl % 256, bitc.band(MASK_GAIN, MASK_BANK))
	v = bitc.bor(v, bitc.bor(bitc.lshift(gain, 4), bitc.lshift(BANK_ALL_CONT, 2)))
	if virtual_write(fd, V_CONTROL_SETUP, v) == nil then
		return {  result = "ERR", message = "Failed to write AS7262 gain/mode"  }
	end

	print(string.format("AS7262 init OK: addr=0x%02X, gain=%dx, integ=%d (每轮约%.0fms), timeout=%dms",
		addr, GAIN_TAB[gain + 1][1], integ, integ * 2.8 * 2, poll_timeout))
	return {  result = "OK"  }

end

-- 【销毁AS7262】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用AS7262】等 DATA_RDY -> 读六通道 + 温度 -> 清 DATA_RDY
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- AS7262 caller func get a table --------", data)
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
	-- 等 DATA_RDY（连续模式自动转换）
	local left = poll_timeout or 1000
	while true do
		local ctl = virtual_read(fd, V_CONTROL_SETUP)
		if ctl == nil then
			return {  result = "ERR", message = "Failed to poll AS7262 data-ready"  }
		end
		if bitc.band(ctl % 256, BIT_DATA_RDY) ~= 0 then break end
		if left <= 0 then
			return {
				result = "ERR",
				message = string.format("AS7262 data-ready timeout (%dms)", poll_timeout or 1000)
			}
		end
		milli_sleep(POLL_MS)
		left = left - POLL_MS
	end

	-- 读六通道
	local vals = {}
	for _, ch in ipairs(CHANS) do
		local v = read_channel(fd, ch[2])
		if v == nil then
			return {  result = "ERR", message = "Failed to read AS7262 channel " .. ch[1]  }
		end
		vals[ch[1]] = v
	end

	-- 片上温度（二进制补码）
	local tb = virtual_read(fd, V_DEVICE_TEMP)
	if tb == nil or tb < 0 then
		return {  result = "ERR", message = "Failed to read AS7262 temperature"  }
	end
	local temp_c = tb
	if temp_c >= 128 then temp_c = temp_c - 256 end

	-- 清 DATA_RDY（SparkFun 同款 RMW 清位；连续模式下芯片随即开始下一轮）
	local ctl = virtual_read(fd, V_CONTROL_SETUP)
	if ctl == nil then
		return {  result = "ERR", message = "Failed to read AS7262 CONTROL_SETUP"  }
	end
	if virtual_write(fd, V_CONTROL_SETUP, bitc.band(ctl % 256, bitc.bxor(BIT_DATA_RDY, 0xFF))) == nil then
		return {  result = "ERR", message = "Failed to clear AS7262 data-ready"  }
	end

	local ret = {
		result = "OK",
		V = vals.V, B = vals.B, G = vals.G,
		Y = vals.Y, O = vals.O, R = vals.R,
		TEMP_C = temp_c
	}

	if DEBUG then
		print(string.format("AS7262: V=%d B=%d G=%d Y=%d O=%d R=%d T=%d°C",
			ret.V, ret.B, ret.G, ret.Y, ret.O, ret.R, ret.TEMP_C))
	end

	return ret

end

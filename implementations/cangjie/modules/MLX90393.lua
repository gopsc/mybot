-- MLX90393 三轴磁力计 驱动模块（Melexis Triaxis Hall，I2C 地址 0x0C~0x0F）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MLX90393 (
--       name    String,
--       I2C     String,
--       address String,
--       gain    String,
--       timeout String
--   );
--   INSERT INTO MLX90393 (name, I2C, address, gain, timeout)
--     VALUES ('mlx0', 'i2c-1', '0x0C', '-', '-');
--
-- 列说明：
--   gain    = GAIN_SEL 0~7（0=5x 最高增益，7=0.2x 最低增益），非法值钳到界内，缺省 0
--   timeout = 单次测量就绪轮询超时 ms（缺省 50；就绪位轮不到即报 ERR）
--   各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回：
--   { result, X/Y/Z(µT，浮点), T(°C), XR/YR/ZR/TR(有符号原始计数), status(状态字节) }
-- 接 sensor_daemon：fields=X|Y|Z|T（驱动内已做补码还原，勿配 sign）
--
-- 协议要点（命令式，非寄存器地图；每条命令的应答以 1 字节 status 收尾）：
--   命令：0x00 NOP | 0x30+flags 启动单次测量 | 0x40+flags 读结果 |
--         0x50 读寄存器 | 0x60 写寄存器 | 0xD0 Memory Recall | 0xF0 复位
--   flags：bit0=T bit1=X bit2=Y bit3=Z，故 0x3F=启动 XYZT、0x4F=读 XYZT
--   WR 格式：[0x60, 字高 8 位, 字低 8 位]，16 位字 = 寄存器地址[15:12] + 数据[11:0]
--   RR 格式：[0x50, 寄存器地址<<2]，应答 3 字节 = 16 位数据 + status
--   status：bit7=ERROR、bit6=SM_DONE（单次测量完成）
--   读结果应答 9 字节，超出 i2c_read 大端合并的 2^53 精度线，走 HAL.i2c_read_bytes
--
-- build 流程（自检链路）：复位 -> Memory Recall（TRIM 出厂校准必须恢复，否则
--   数据无效）-> 写 GAIN_SEL（读-改-写 + 回读校验）-> 试测一帧并丢弃（甄别在位、
--   打通 触发/轮询/读回 全链路）
--
-- 【对 datasheet 复核项】离线开发无法上网核对，协议中不确定的细节全部收敛为
--   常量，真机数据异常时按序核对（每项都是一行改动）：
--   1. 读结果字节序按 [T Z Y X] 解析（MSB 在前、status 收尾）。若轴对调/T 位置
--      不对，改下方 OFF_T/Z/Y/X 偏移表（另一常见候选序 [X Y Z T]）
--   2. 灵敏度基准：GAIN_SEL=0、16 位时 XY=0.751 / Z=1.210 µT/LSB（Z 与 XY 不同），
--      其余增益按增益倍数反比换算；上真机前建议对照 datasheet 的
--      Sensitivity vs GAIN_SEL/RES 表复核，或用地磁场（水平 ~50µT）标定
--   3. T[°C] = TR / 32（16 位；实测偏差大则查 T 灵敏度定义）
--   4. SM_DONE 取 bit6（0x40）：若真机每次都报测量超时，优先改 ST_SMDONE
--   5. 默认 RES=0（16 位）假设：灵敏度表按 16 位给出，改过 RES 的器件需另配

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令与状态 ====================
local CMD_NOP    = 0x00
local CMD_SINGLE = 0x30		-- 启动单次测量（低 4 位 flags）
local CMD_READ   = 0x40		-- 读测量结果（低 4 位 flags）
local CMD_RR     = 0x50		-- 读寄存器
local CMD_WR     = 0x60		-- 写寄存器
local CMD_RECALL = 0xD0		-- Memory Recall（恢复出厂 TRIM）
local CMD_RESET  = 0xF0		-- 复位

local FLAG_T = 0x01
local FLAG_X = 0x02
local FLAG_Y = 0x04
local FLAG_Z = 0x08

local ST_ERROR  = 0x80		-- status bit7：错误
local ST_SMDONE = 0x40		-- status bit6：单次测量完成（见头注释复核项 4）

local CMD_XYZT  = CMD_SINGLE + FLAG_T + FLAG_X + FLAG_Y + FLAG_Z	-- 0x3F
local READ_XYZT = CMD_READ  + FLAG_T + FLAG_X + FLAG_Y + FLAG_Z	-- 0x4F
local RESP_N    = 9			-- 0x4F 应答：T/Z/Y/X 各 2 字节 + status

local REG_GAIN = 0x02		-- GAIN 寄存器：[6:4]=GAIN_SEL，[1:0]=GAIN_ADDR

-- ==================== 时序常量 ====================
-- 复位/Memory Recall 完成时间（datasheet 数量级 + 余量）
local T_RESET_MS  = 5
local T_RECALL_MS = 2
local POLL_MS     = 1		-- 就绪轮询步长

-- ==================== 读结果解析（见头注释复核项 1） ====================
-- 按 [T Z Y X] + status 收尾解析（1 基字节偏移；每轴 MSB 在前）
local OFF_T = 1
local OFF_Z = 3
local OFF_Y = 5
local OFF_X = 7

-- ==================== 灵敏度换算（见头注释复核项 2） ====================
-- GAIN_SEL=0（5x）、16 位基准：µT/LSB；其余增益按 GAIN_TAB 反比换算
local SENS_XY_0 = 0.751
local SENS_Z_0  = 1.210
local GAIN_BASE = 5
local GAIN_TAB  = { 5, 4, 3, 2.5, 2, 1.5, 1, 0.2 }		-- GAIN_SEL 0~7 的增益倍数

-- T 换算（见头注释复核项 3）：°C = TR / T_LSB_DIV
local T_LSB_DIV = 32

local DEF_GAIN    = 0
local DEF_TIMEOUT = 50		-- ms

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local sens_xy			-- XY 轴 µT/LSB
local sens_z			-- Z 轴 µT/LSB
local poll_timeout_ms	-- 就绪轮询超时 ms

-- 16 位有符号还原
local function s16(v)
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end

-- 发送 1 字节命令，成功返回 true
local function send_cmd(fd, cmd)
	return i2c_write_multi(fd, cmd) == 0
end

-- 读 status：NOP 查询（命令本身无副作用），返回 0~255；失败返回 nil
local function read_status(fd)
	if not send_cmd(fd, CMD_NOP) then return nil end
	local v = i2c_read(fd, 1)
	if v < 0 then return nil end
	return v
end

-- 写寄存器：地址 4 位 + 数据 12 位打包为 16 位字（地址在 [15:12]）
local function write_reg(fd, addr4, data12)
	local w = addr4 * 4096 + data12
	return i2c_write_multi(fd, CMD_WR, math.floor(w / 256) % 256, w % 256) == 0
end

-- 读 16 位寄存器（RR：[0x50, addr<<2] -> 3 字节应答），返回 16 位值；失败返回 nil
local function read_reg16(fd, addr4)
	if i2c_write_multi(fd, CMD_RR, addr4 * 4) ~= 0 then return nil end
	local b = i2c_read_bytes(fd, 3)
	if b == nil then return nil end
	return b[1] * 256 + b[2]
end

-- 单次测量：触发 -> 轮询就绪 -> 读 9 字节应答。成功返回字节数组，失败返回 nil + 错误信息
local function measure_once(fd)
	if not send_cmd(fd, CMD_XYZT) then
		return nil, "Failed to start MLX90393 single measurement"
	end

	local left = poll_timeout_ms
	while left > 0 do
		milli_sleep(POLL_MS)
		left = left - POLL_MS

		local st = read_status(fd)
		if st == nil then
			return nil, "Failed to poll MLX90393 status"
		end
		if bitc.band(st, ST_ERROR) ~= 0 then
			return nil, string.format("MLX90393 status ERROR (0x%02X)", st)
		end
		if bitc.band(st, ST_SMDONE) ~= 0 then
			if not send_cmd(fd, READ_XYZT) then
				return nil, "Failed to send MLX90393 read command"
			end
			local b = i2c_read_bytes(fd, RESP_N)
			if b == nil then
				return nil, "Failed to read MLX90393 measurement"
			end
			return b
		end
	end
	return nil, string.format("MLX90393 measurement timeout (%dms, SM_DONE never set; check wiring or ST_SMDONE def)", poll_timeout_ms)
end

-- 解析 9 字节应答并换算，返回结果表
local function parse_response(b)
	local tr = s16(b[OFF_T] * 256 + b[OFF_T + 1])
	local zr = s16(b[OFF_Z] * 256 + b[OFF_Z + 1])
	local yr = s16(b[OFF_Y] * 256 + b[OFF_Y + 1])
	local xr = s16(b[OFF_X] * 256 + b[OFF_X + 1])

	local ret = {
		result = "OK",
		X = xr * sens_xy,				-- µT（浮点）
		Y = yr * sens_xy,
		Z = zr * sens_z,
		T = tr / T_LSB_DIV,				-- °C
		XR = xr, YR = yr, ZR = zr, TR = tr,	-- 有符号原始计数
		status = b[RESP_N]
	}

	if DEBUG then
		print(string.format("MLX90393: X=%.2fµT Y=%.2fµT Z=%.2fµT T=%.2f°C", ret.X, ret.Y, ret.Z, ret.T))
	end

	return ret
end

-- 【配置脚本】复位 -> Memory Recall -> 写 GAIN_SEL -> 试测一帧自检
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MLX90393 builder func get a table --------", data)
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

	-- gain 列 -> GAIN_SEL：取整后钳到 0~7（非法/'-' 归缺省 0）
	local gain = tonumber(data.gain)
	if gain == nil then gain = DEF_GAIN end
	gain = math.floor(gain)
	if gain < 0 then gain = 0 end
	if gain > 7 then gain = 7 end

	-- timeout 列 -> 轮询超时 ms（非法/非正数归缺省）
	local to = tonumber(data.timeout)
	if to == nil or to < 1 then to = DEF_TIMEOUT end
	poll_timeout_ms = math.floor(to)

	-- 灵敏度按增益反比换算
	sens_xy = SENS_XY_0 * GAIN_BASE / GAIN_TAB[gain + 1]
	sens_z  = SENS_Z_0  * GAIN_BASE / GAIN_TAB[gain + 1]

	-----------------------------------------------------
	-- 复位（寄存器被清零）
	if not send_cmd(fd, CMD_RESET) then
		return {
			result = "ERR",
			message = "Failed to reset MLX90393"
		}
	end
	milli_sleep(T_RESET_MS)

	-- Memory Recall：恢复出厂 TRIM 校准（复位后必须做，否则测量数据无效）
	if not send_cmd(fd, CMD_RECALL) then
		return {
			result = "ERR",
			message = "Failed to recall MLX90393 TRIM"
		}
	end
	milli_sleep(T_RECALL_MS)

	-- 写 GAIN_SEL（读-改-写：保留 GAIN 寄存器其余位，只改 [6:4]）
	local g = read_reg16(fd, REG_GAIN)
	if g == nil then
		return {
			result = "ERR",
			message = "Failed to read MLX90393 GAIN register"
		}
	end
	local newg = bitc.bor(bitc.band(g, 0xFF8F), bitc.lshift(gain, 4))
	if not write_reg(fd, REG_GAIN, newg) then
		return {
			result = "ERR",
			message = "Failed to write MLX90393 GAIN register"
		}
	end
	-- 回读校验
	local g2 = read_reg16(fd, REG_GAIN)
	if g2 ~= newg then
		return {
			result = "ERR",
			message = string.format("MLX90393 GAIN verify failed: wrote 0x%04X, read back 0x%04X", newg, g2 or 0)
		}
	end

	-- 试测一帧并丢弃：甄别在位 + 打通 触发/轮询/读回 全链路
	local b, err = measure_once(fd)
	if b == nil then
		return {
			result = "ERR",
			message = err
		}
	end

	print(string.format("MLX90393 init OK: addr=0x%02X, gain=%d, sens_xy=%.4f sens_z=%.4f µT/LSB, timeout=%dms",
		addr, gain, sens_xy, sens_z, poll_timeout_ms))
	return {  result = "OK"  }

end

-- 【销毁MLX90393】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用MLX90393】单次测量：X/Y/Z（µT）、T（°C）+ 有符号原始计数 + 状态字节
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MLX90393 caller func get a table --------", data)
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

	-- build 前置守卫：poll_timeout_ms/sens_xy 仅 build 赋值，
	-- 未 build 先 call 会对 nil 做比较/算术裸 error（与 INA219/LTC2944 对齐）
	if poll_timeout_ms == nil or sens_xy == nil then
		return {
			result = "ERR",
			message = "MLX90393 not built (build first)"
		}
	end

	-----------------------------------------------------
	local b, err = measure_once(fd)
	if b == nil then
		return {
			result = "ERR",
			message = err
		}
	end

	return parse_response(b)

end

-- MH-Z19B NDIR CO₂ 传感器 驱动模块（UART 串口，首个串口设备参考实现）
-- bot4cj 仓颉语言机器人框架
-- Winsen MH-Z19B：9600 8N1，请求-应答定长帧协议（9 字节 + 累加和校验），
-- 量程 400~5000ppm（或 0~10000 视型号），预热约 3 分钟
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE UART (
--       name String, path String, baud String
--   );
--   INSERT INTO UART (name, path, baud)
--     VALUES ('uart-0', '/dev/serial0', '9600');
--   CREATE TABLE MHZ19 (
--       name String,
--       UART String
--   );
--   INSERT INTO MHZ19 (name, UART) VALUES ('co2-0', 'uart-0');
-- @UART 的 baud 必须 9600（MH-Z19 固定）；UART 列引用 uart-0，
-- fd 经引用机制从 @UART 的 call 流入（与 I2C/SPI 设备同款模式）
--
-- call 无需额外参数，返回 { result, CO2(ppm), TEMP(°C 近似), S(状态字节) }
-- TEMP 为响应帧温度字节 - 40 的近似内部温度（非计量值）；
-- 接 sensor_daemon：fields=CO2（守护路径需 sensor_daemon 支持 proto=uart）
--
-- 实现要点（协议依 Winsen MH-Z19B 数据手册与社区通用实现）：
--   1. 请求帧 9 字节：FF 01 86 00 00 00 00 00 79（读 CO₂），
--      校验和 = (~(b1+..+b7)) + 1 & 0xFF，即 (0x100 - 累加和) & 0xFF
--   2. 应答帧 9 字节：FF 86 HI LO TEMP S U1 U2 CS；CS 校验同上
--      （b1=0x86 起）；CO₂ = HI x 256 + LO
--   3. 读序：发帧前先清输入缓冲（uart_flush，丢弃陈旧字节），
--      发后多轮累积聚合读（同 SDS011.read_frame）：uart_read 单次最多
--      返回 n 字节，帧前有噪声字节时完整帧跨轮到达——只读一轮 9 字节
--      再做帧头扫描在数学上不可达（帧头移位后 9 字节装不下整帧，
--      2026-09 审计 S4 已修）；扫描 + 校验和兜底
--   4. 字节流可能分片到达，uart_read 轮询聚合由 HAL 承担
--   5. 校验和错误/短读/写失败均报 ERR（halt-on-error 链路可用）

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 协议常量 ====================
local FRAME_LEN    = 9
local CMD_READ_CO2 = 0x86
local READ_TIMEOUT_MS = 300		-- 应答帧通常 <50ms 到达，300ms 余量

local RESP_HEAD    = 0xFF
local RESP_CMD     = 0x86

-- MH-Z19 校验和：~(b1+..+b7) + 1（模 256），即 (0x100 - 累加和) & 0xFF
local function checksum(frame, from, to)
	local sum = 0
	for i = from, to do sum = sum + frame[i] end
	return (0x100 - (sum % 0x100)) % 0x100
end

-- 读一帧应答（FF 86 开头 + 校验和），容忍前导噪声：聚合扫描，最多 3 轮。
-- uart_read 单次最多返回 n 字节，噪声字节后完整帧跨轮到达——逐轮累计，
-- 每轮对全部窗口扫描帧头 + 校验和。返回 9 字节 1 基表；失败返回 nil, 原因。
local function read_frame(fd, timeout_ms)
	local acc = {}
	for _ = 1, 3 do
		local chunk = uart_read(fd, FRAME_LEN, timeout_ms)
		if chunk == nil then return nil, "read error" end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		for i = 1, (#acc >= FRAME_LEN) and (#acc - FRAME_LEN + 1) or 0 do
			if acc[i] == RESP_HEAD and acc[i + 1] == RESP_CMD then
				local f = {}
				for k = 0, FRAME_LEN - 1 do f[k + 1] = acc[i + k] end
				local cs = checksum(f, 2, 8)
				if f[9] == cs then return f, nil end
			end
		end
	end
	if #acc == 0 then return nil, "timeout (no bytes)" end
	return nil, "no valid frame (head FF 86 + checksum)"
end

-- 【配置脚本】校验句柄，清输入缓冲（无寄存器可校验器件）
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MHZ19 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "Invalid Argument: fd (UART 列是否引用了 @UART 变量?)"
		}
	end

	-- 丢弃上电以来的陈旧字节
	uart_flush(fd)

	print(string.format("MHZ19 init OK: fd=%d (9600 8N1，预热约 3 分钟后读数稳定)", fd))
	return {  result = "OK"  }

end

-- 【销毁MHZ19】无资源需要释放（串口归 @UART 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用MHZ19】请求-应答读 CO₂ 浓度
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MHZ19 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	-- 请求帧：FF 01 86 00 00 00 00 00 79
	local req = { 0xFF, 0x01, CMD_READ_CO2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
	req[FRAME_LEN] = checksum(req, 2, 8)

	uart_flush(fd)		-- 丢弃陈旧字节，防止旧应答错位
	local wn = uart_write(fd, req)
	if wn ~= FRAME_LEN then
		return {
			result = "ERR",
			message = "Failed to write MHZ19 request (" .. tostring(wn) .. ")"
		}
	end

	-- 多轮累积聚合读：容忍前导噪声与跨轮分片（校验和在 read_frame 内兜底）
	local f, ferr = read_frame(fd, READ_TIMEOUT_MS)
	if f == nil then
		return {
			result = "ERR",
			message = "MHZ19 no valid response: " .. tostring(ferr)
		}
	end

	local co2 = f[3] * 256 + f[4]

	if DEBUG then
		print(string.format("MHZ19: CO2=%dppm TEMP=%d S=%d", co2, f[5] - 40, f[6]))
	end

	return {
		result = "OK",
		CO2    = co2,
		TEMP   = f[5] - 40,		-- 近似内部温度（非计量值）
		S      = f[6]
	}

end

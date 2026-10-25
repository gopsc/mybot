-- SDS011 激光 PM2.5/PM10 粉尘传感器 驱动模块（UART 9600 8N1，Nova Fitness）
-- bot4cj 仓颉语言机器人框架
-- 激光散射颗粒物传感器，内置风扇主动吸气。本驱动切【被动查询模式】工作
-- （上电默认主动推送，build 期切换），call 一次查询取一对 PM 值——
-- 请求-应答节奏与 MHZ19.lua 一致，无主动数据流错帧问题。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE UART (
--       name String, path String, baud String
--   );
--   INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/ttyUSB0', '9600');
--   CREATE TABLE SDS011 (
--       name    String,
--       UART    String,
--       timeout String    -- 应答超时 ms（默认 300）
--   );
--   INSERT INTO SDS011 (name, UART, timeout) VALUES ('pm-0', 'uart-0', '-');
--
-- call 返回 { result, PM25, PM10 }（µg/m³，浮点）：
--   传 power="sleep"/"work" 控制风扇停转/工作（风扇寿命约 8000h，间歇采样
--   可延长；注意 work 后需 5~10s 风扇起转才能出有效读数）。
-- 接 sensor_daemon：fields=PM25|PM10（浮点，勿配 sign），interval >= 1s
--   （传感器测量周期约 1s，查询过快得到重复值）。
--
-- 帧格式（py-sds011 与 ricki-z/SDS011 两实现互证）：
--   请求 19 字节：AA B4 | CMD | 12 x 数据 | ID1 ID2 | CS | AB
--     CS = (CMD + 数据 + ID) 累加和 mod 256；设备 ID 用 FF FF 广播
--   应答 10 字节：AA C5 | PM25低 PM25高 PM10低 PM10高 | ID1 ID2 | CS | AB
--     CS = 前 6 字节累加和 mod 256；PM = 小端 16 位 / 10 (µg/m³)
--   命令：02 上报模式（0 主动/1 被动）04 查询 06 睡眠(0)/工作(1)
--     07 固件版本（读）
--   前导噪声容忍：应答帧做 AA C5 扫描 + 校验和兜底（同 MHZ19 的帧头扫描）

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
local FRAME_LEN = 19			-- 请求帧
local RESP_LEN  = 10			-- 应答帧
local RESP_CMD  = 0xC5			-- 应答命令字节
local TAIL      = 0xAB

local CMD_REPORT  = 0x02		-- 上报模式（D0: 0 主动 / 1 被动）
local CMD_QUERY   = 0x04		-- 查询一次读数
local CMD_SLEEP   = 0x06		-- 睡眠（D0=0）/ 工作（D0=1）
local CMD_VERSION = 0x07		-- 固件版本（读）

local READ_TIMEOUT_MS = 300

-- 构造请求帧：AA B4 | CMD | D0..D11 | FF FF | CS | AB
local function make_frame(cmd, d0)
	local f = { 0xAA, 0xB4, cmd }
	for _ = 1, 12 do f[#f + 1] = d0 or 0 end		-- D0..D11
	f[#f + 1] = 0xFF		-- ID1（广播）
	f[#f + 1] = 0xFF		-- ID2
	local sum = 0
	for i = 3, #f do sum = sum + f[i] end			-- CMD 起（含 ID）累加
	f[#f + 1] = sum % 256
	f[#f + 1] = TAIL
	return f
end

-- 读一帧应答（AA C5 开头 + 校验和），容忍前导噪声：聚合扫描，最多 3 轮
-- 返回 10 字节 1 基表；无帧/校验和不过返回 nil
local function read_frame(fd, timeout_ms)
	local acc = {}
	for _ = 1, 3 do
		local chunk = uart_read(fd, RESP_LEN, timeout_ms)
		if chunk == nil then return nil end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		for i = 1, (#acc >= RESP_LEN) and (#acc - RESP_LEN + 1) or 0 do
			if acc[i] == 0xAA and acc[i + 1] == RESP_CMD then
				local sum = 0
				for k = i + 2, i + 7 do sum = sum + acc[k] end
				if acc[i + 8] == sum % 256 then
					local f = {}
					for k = 0, RESP_LEN - 1 do f[k + 1] = acc[i + k] end
					return f
				end
			end
		end
	end
	return nil
end

-- 发命令并收应答（校验和由 read_frame 兜底）
local function exec(fd, cmd, d0, timeout_ms)
	uart_flush(fd)
	local wn = uart_write(fd, make_frame(cmd, d0))
	if wn ~= FRAME_LEN then
		return nil, "write failed (" .. tostring(wn) .. ")"
	end
	local f = read_frame(fd, timeout_ms)
	if f == nil then
		return nil, "no valid response"
	end
	return f
end

-- ==================== 模块级配置 ====================
local cfg_timeout

-- ==================== 配置脚本 ====================
-- 切被动查询模式 + 读固件版本（顺带在位探测）
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- SDS011 builder func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "Invalid Argument: fd (UART 列是否引用了 @UART 变量?)"
		}
	end

	local timeout = tonumber(data.timeout)
	if timeout == nil or timeout < 0 then timeout = READ_TIMEOUT_MS end
	cfg_timeout = math.floor(timeout)

	-- 切被动模式（器件 ACK 应答回读校验）
	local f, err = exec(fd, CMD_REPORT, 0x01, cfg_timeout)
	if f == nil then
		return {
			result = "ERR",
			message = "SDS011 not responding (set passive mode: " .. err .. ")"
		}
	end
	if f[3] ~= CMD_REPORT or f[4] ~= 0x01 then
		return {
			result = "ERR",
			message = "SDS011 passive mode rejected"
		}
	end

	-- 固件版本（横幅展示，同时确认查询链路）
	local v, verr = exec(fd, CMD_VERSION, 0x00, cfg_timeout)
	local fw = "?"
	if v ~= nil then
		fw = string.format("%d.%d", v[3], v[4])
	else
		dbg("SDS011 version read failed: " .. tostring(verr))
	end

	print(string.format("SDS011 init OK: fd=%d firmware=%s (passive mode)", fd, fw))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 默认查询一次读数；power="sleep"/"work" 控制风扇
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- SDS011 caller func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	if fd == nil or fd <= 0 then
		return {
			result = "ERR",
			message = "Invalid Argument: fd"
		}
	end

	-----------------------------------------------------
	-- 风扇电源控制
	local power = data.power
	if power ~= nil then
		local d0
		if tostring(power) == "sleep" then d0 = 0
		elseif tostring(power) == "work" then d0 = 1
		else
			return {
				result = "ERR",
				message = "Invalid Argument: power '" .. tostring(power) .. "' (sleep|work)"
			}
		end
		local f, err = exec(fd, CMD_SLEEP, d0, cfg_timeout or READ_TIMEOUT_MS)
		if f == nil then
			return {
				result = "ERR",
				message = "SDS011 not responding (power: " .. err .. ")"
			}
		end
		return {
			result = "OK",
			POWER = tostring(power)
		}
	end

	-----------------------------------------------------
	-- 查询读数
	local f, err = exec(fd, CMD_QUERY, nil, cfg_timeout or READ_TIMEOUT_MS)
	if f == nil then
		return {
			result = "ERR",
			message = "SDS011 not responding (query: " .. err .. ")"
		}
	end

	local pm25 = (f[3] + f[4] * 256) / 10.0
	local pm10 = (f[5] + f[6] * 256) / 10.0

	return {
		result = "OK",
		PM25 = pm25,
		PM10 = pm10
	}

end

-- ==================== 销毁 ====================
-- 无资源需要释放（串口归 @UART 硬件变量所有；保持被动模式）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end

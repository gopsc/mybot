-- MCP3421.lua - 18 位差分模数转换器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- Microchip MCP3421：单通道差分 ΔΣ ADC，I2C 地址固定 0x68，PGA ×1~×8，
-- 分辨率/速率绑定档位：18bit@3.75SPS、16bit@15SPS、14bit@60SPS、12bit@240SPS。
-- 无寄存器指针：写 = 单字节配置；读 = 纯读数据流。内部基准 2.048V。
--
-- 用法（结构脚本 .sql，直连路径）：
--   CREATE TABLE MCP3421 (
--       name    String,
--       I2C     String,
--       address String,
--       res     String,   -- 分辨率 12/14/16/18（默认 18；对应 240/60/15/3.75 SPS）
--       pga     String,   -- 增益 1/2/4/8（默认 1；满量程 ±2.048V/pga）
--       opmode  String,   -- 'cont'(默认) | 'oneshot'（转换完进低功耗，省电用）
--       wait    String    -- 等新数据就绪 ms（默认 = 转换周期 + 20 余量；可 call 传参覆盖）
--   );
--   INSERT INTO MCP3421 (name, I2C, address, res, pga, opmode, wait)
--     VALUES ('adc18-0', 'i2c-1', '0x68', '18', '1', 'cont', '-');
--
-- 守护路径：interval 建议 >= 转换周期（18bit 档 >= 270ms），这样每拍数据恰好
--   就绪、call 不必等待；fields 取 "voltage"（伏特浮点）或 "raw"（有符号码值）：
--   INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, res, pga)
--     VALUES ('adc18-0', 'lib/sensor_daemon.lua', 'MCP3421', 'i2c',
--             '/dev/i2c-1', '0x68', '270', 'voltage', '-', '18', '1');
--
-- call 返回契约（键名与 ADS1115 对齐）：{ result, raw, voltage }。
--   数据未就绪（转换中/已被读走）时轮询等待至 wait 超时，仍无新数据返回 ERR
--   （守护 daemon_tick 跳拍不发布；interval >= 转换周期时不会发生）。
--   18 位档读 4 字节（3 数据 + 配置回显，右对齐），其余档读 3 字节（2 数据 + 回显，
--   顶部为重复符号位，按 int16 解释即为该分辨率的有符号码值）。
--   注意与同总线的 MPU6050（默认 0x68）地址冲突，本驱动不做处理。
--
-- build 流程：写配置 -> 读回回显校验（MCP3421 无 ID 寄存器，回显比对兼做在位
--   探测与配置确认；仅比对 O/C+S+G 六位，RDY 位随转换状态浮动不比对）。
--   destroy 写 O/C=0 使器件在当前转换后进入低功耗待机（保留速率/增益配置）。
--
-- 寄存器事实来源：数据手册 DS22003E；位域与数据格式经 Linux 内核 mcp3422 IIO
--   驱动、libdriver/mcp3421、Adafruit_MCP3421 三方实现交叉验证。
--   单次触发极性（写 RDY=1 启动转换）沿用两套参考库的实现。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 配置寄存器位域（bit7..0） ====================
-- [7]=RDY  [6:5]=通道（MCP3422/3/4 用，本芯片恒 0）  [4]=O/C  [3:2]=S1S0  [1:0]=G1G0
local BIT_RDY       = 0x80		-- 写 1 启动单次转换；读 0 = 新数据就绪（1 = 转换中/已被读走）
local BIT_CONT      = 0x10		-- 1 = 连续转换，0 = 单次（转换完进低功耗）
local MASK_RATE     = 0x0C
local MASK_GAIN     = 0x03
local MASK_ECHO     = 0x3F		-- 回显比对范围：O/C + 速率 + 增益（RDY 随状态浮动不比对）

-- 分辨率 -> 速率编码 / 转换周期 ms（数据手册 1/SPS，向上取整）
local RES_CODE = { [12]=0, [14]=1, [16]=2, [18]=3 }
local RES_SPS  = { [12]=240, [14]=60, [16]=15, [18]=3.75 }
local T_CONV_MS = { [12]=5, [14]=17, [16]=67, [18]=267 }
local PGA_CODE = { [1]=0, [2]=1, [4]=2, [8]=3 }

-- 模块级配置（build 写入，跨 call 保持于本变量独立状态机，destroy 后废弃）
local cfg_res			-- 分辨率（12/14/16/18）
local cfg_lsb_v			-- 每 LSB 伏特（2.048 / 2^(res-1) / pga）
local cfg_nbytes		-- 单次读取字节数（18bit=4，其余=3）
local cfg_cont			-- true=连续模式
local cfg_trigger		-- call 触发用的配置字节（oneshot 用，RDY=1）
local cfg_wait			-- 等新数据超时 ms（默认转换周期 + 余量）

-- ==================== 配置解析 ====================
local function cfg_num(v, default, valid, label)
	if v == nil or v == "-" or v == "" then return default end
	local n = math.floor(tonumber(v) or -1)
	if valid[n] == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "'"
	end
	return n
end

-- ==================== 数据解码 ====================
-- v 为大端合并的原始读数（i2c_read 返回）。返回有符号码值与回显字节。
local function decode(v)
	local echo = v % 256
	local raw
	if cfg_res == 18 then
		-- 4 字节：D[17:16] 在首字节低 2 位（高 6 位未用），D[15:8]，D[7:0]，回显
		local b0 = math.floor(v / 256 ^ 3) % 4
		local b1 = math.floor(v / 256 ^ 2) % 256
		local b2 = math.floor(v / 256) % 256
		raw = b0 * 65536 + b1 * 256 + b2
		if raw >= 0x20000 then raw = raw - 0x40000 end		-- 18 位二补码
	else
		-- 3 字节：16 位字（顶部为重复符号位）+ 回显；int16 即该分辨率有符号值
		local w = math.floor(v / 256) % 65536
		if w >= 0x8000 then w = w - 0x10000 end
		raw = w
	end
	return raw, echo
end

-- ==================== 配置脚本 ====================
-- 写配置 -> 读回回显校验（兼在位探测）
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MCP3421 builder func get a table --------", data)
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
	-- 解析配置
	local res, e1 = cfg_num(data.res, 18, RES_CODE, "res(bits)")
	if e1 then return { result = "ERR", message = e1 } end

	local pga, e2 = cfg_num(data.pga, 1, PGA_CODE, "pga(gain)")
	if e2 then return { result = "ERR", message = e2 } end

	local opmode_s = data.opmode
	if opmode_s == nil or opmode_s == "-" or opmode_s == "" then opmode_s = "cont" end
	opmode_s = tostring(opmode_s)
	local cont
	if opmode_s == "cont" then cont = true
	elseif opmode_s == "oneshot" then cont = false
	else
		return {
			result = "ERR",
			message = "Invalid Argument: opmode '" .. opmode_s .. "' (cont|oneshot)"
		}
	end

	local wait = tonumber(data.wait)
	if wait == nil or wait < 0 then wait = T_CONV_MS[res] + 20 end

	-- 配置字节：RDY=1（连续模式下启动转换流；单次模式下触发首次转换）
	local g_code = PGA_CODE[pga]
	local cfg = BIT_RDY + (cont and BIT_CONT or 0) + RES_CODE[res] * 4 + g_code

	-----------------------------------------------------
	-- 写配置（MCP3421 无寄存器指针：单字节写入即配置）
	if i2c_write_multi(fd, cfg) ~= 0 then
		return {
			result = "ERR",
			message = "MCP3421 not responding (config write failed, check address 0x68 and wiring)"
		}
	end

	-- 读回回显校验（兼在位探测）：RDY 位随转换状态浮动，仅比对低 6 位
	-- （回显在末字节，与分辨率档位无关，直接取 v 的最低字节）
	local nbytes = (res == 18) and 4 or 3
	local v = i2c_read(fd, nbytes)
	if v < 0 then
		return {
			result = "ERR",
			message = "MCP3421 not responding (echo read failed)"
		}
	end
	local echo = v % 256
	if echo % 64 ~= cfg % 64 then
		return {
			result = "ERR",
			message = string.format("MCP3421 config echo mismatch: got 0x%02X (expect 0x%02X masked 0x%02X)", echo, cfg, MASK_ECHO)
		}
	end

	cfg_res = res
	cfg_lsb_v = 2.048 / 2 ^ (res - 1) / pga
	cfg_nbytes = nbytes
	cfg_cont = cont
	cfg_trigger = cfg				-- RDY=1 的配置字节，oneshot 每次 call 重写触发
	cfg_wait = math.floor(wait)

	print(string.format("MCP3421 init OK: addr=0x%02X res=%dbit pga=x%d mode=%s (%gSPS, LSB=%.4guV)",
		addr, res, pga, opmode_s, RES_SPS[res], cfg_lsb_v * 1e6))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 取一次转换结果。数据未就绪时轮询等待（wait 超时仍无新数据则 ERR）。
-- 返回 { result, raw, voltage }，键名与 ADS1115 驱动对齐。
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MCP3421 caller func get a table --------", data)
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
	local wait_ms = tonumber(data.wait) or cfg_wait or 0
	if wait_ms < 0 then wait_ms = 0 end

	-- 单次模式：每次 call 重写配置触发新转换；连续模式芯片自行持续转换
	if not cfg_cont then
		if i2c_write_multi(fd, cfg_trigger) ~= 0 then
			return {
				result = "ERR",
				message = "MCP3421 not responding (trigger write failed)"
			}
		end
	end

	-- 轮询回显 RDY 位：0 = 新数据就绪（1 = 转换中 / 上一结果已被读走）
	local waited = 0
	while true do
		local v = i2c_read(fd, cfg_nbytes)
		if v < 0 then
			return {
				result = "ERR",
				message = "MCP3421 not responding (read failed)"
			}
		end
		local raw, echo = decode(v)
		if math.floor(echo / 128) % 2 == 0 then
			return {
				result = "OK",
				raw = raw,
				voltage = raw * cfg_lsb_v
			}
		end
		if waited >= wait_ms then
			return {
				result = "ERR",
				message = "MCP3421 conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)"
			}
		end
		milli_sleep(5)
		waited = waited + 5
	end

end

-- ==================== 销毁 ====================
-- 写 O/C=0（RDY=0 不触发）：当前转换完成后器件进入低功耗待机，保留速率/增益
-- 配置；总线 fd 归 I2C 硬件变量所有，不 close。
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MCP3421 ender func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) and cfg_trigger then
		-- 仅保留速率+增益位（低 4 位）：RDY=0 不触发、O/C=0 单次 -> 转换完即待机
		i2c_write_multi(fd, cfg_trigger % 16)
	end

	return {  result = "OK"  }

end

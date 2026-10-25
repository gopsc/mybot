-- SGP30 空气质量传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 金属氧化物（MOX）气体传感器，I2C 地址固定 0x58，输出 TVOC(ppb) 与 CO2eq(ppm)
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SGP30 (
--       name     String,
--       I2C      String,
--       address  String,
--       baseline String,
--       sht      String,
--       t_field  String,
--       rh_field String
--   );
--   INSERT INTO SGP30 (name, I2C, address, baseline, sht, t_field, rh_field)
--     VALUES ('sgp30-0', 'i2c-1', '0x58', '-', '-', '-', '-');
--
-- 列说明：
--   baseline = 基线持久化文件路径（'-' 或缺省 = 不持久化，向后兼容）。
--     build 自检通过后若文件存在且 CRC 合法则 Set_baseline 恢复（免约 12h
--     重学习）；call 期间每 3600s 自动 Get_baseline 存盘一次，destroy 再存
--     一次；两字均 0（尚未学习）不存盘。NOTE: 框架沙箱中和的是 Lua stdlib
--     的 io.*，本驱动经 HAL.sys（ffi open/read/write，HAL 本就 cdef 了这批
--     原语，走同一间接层可离线 mock）读写该 6 字节小文件——能力层级与总线
--     访问相同，路径属结构脚本配置，可信度同 I2C 的 /dev/i2c-N。
--   sht/t_field/rh_field = 湿度补偿（可选）：sht 填另一硬件变量名（通常是
--     SHT3X 守护），经引用机制每次 play 注入其实时快照；t_field/rh_field
--     填快照里的温度(°C)/相对湿度(%)键名（守护发布为 v0/v1...）。齐备时
--     call 先按 Sensirion 公式算绝对湿度再 Set_absolute_humidity(0x2061)。
--     注意：引用机制只在直连路径生效；sensor_daemon 的 DAEMON_CONFIG 是
--     原始串不走引用，守护采样路径下湿度补偿不可用（基线持久化可用）。
--
-- build 流程：Measure_test 自检（0x2032，期望 0xD400 + CRC，约 220ms，
--   兼做在位探测）-> Init_air_quality(0x2003) -> （可选）恢复基线
-- 上电后前 15s 读数固定 CO2eq=400/TVOC=0；测量间隔不得小于 1s，否则内部
--   基线算法失效（节拍由 @Action/守护 interval 保证，测试对已按 1s 配）
-- CO2eq 由 H2 信号等效换算：对呼吸类 VOC 响应快，对燃烧类 CO2 迟钝，
--   适合做通风指示，不适合精确浓度测量

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 同时持有 HAL 表：基线文件读写走 HAL.sys 间接层（可离线 mock）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local HAL = dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local ffi = require("ffi")		-- 基线文件缓冲区（HAL 已完成 cdef）
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 命令（16 位，写 [hi, lo, 数据...]） ====================
local CMD_INIT     = 0x03		-- Init_air_quality，<=10ms
local CMD_MEASURE  = 0x08		-- Measure_air_quality，<=12ms
local CMD_GET_BASE = 0x15		-- Get_baseline，<=10ms
local CMD_SET_BASE = 0x1E		-- Set_baseline，<=10ms
local CMD_SELFTEST = 0x32		-- Measure_test，<=220ms，期望 0xD400
local CMD_SET_AH   = 0x61		-- Set_absolute_humidity，<=10ms
local CMD_PREFIX   = 0x20		-- 上述命令的高字节

local SELFTEST_MAGIC = 0xD400

-- 数据手册最大时长 + 2ms 余量（usleep 可能被信号提前唤醒）
local T_INIT_MS     = 12
local T_MEASURE_MS  = 14
local T_BASE_MS     = 12
local T_SELFTEST_MS = 222

-- 基线存盘节拍（Sensirion 建议 >= 每小时一次）
local SAVE_PERIOD_S = 3600

-- 基线文件 open 参数：O_WRONLY|O_CREAT|O_TRUNC（Linux），权限 0644
local O_RDONLY = 0
local O_WRONLY_CREAT_TRUNC = 1 + 0x40 + 0x200
local FILE_MODE = 0x1A4

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local baseline_path		-- 基线文件路径（nil = 不持久化）
local last_save_s		-- 上次存盘时刻（os.time 秒）
local last_ah_ticks		-- 上次下发的绝对湿度 ticks（nil = 尚未下发）

-- ==================== CRC8（多项式 0x31，初值 0xFF） ====================
local function crc8(word)
	local crc = 0xFF
	local hi = math.floor(word / 256) % 256
	local lo = word % 256
	for _, b in ipairs({hi, lo}) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.band(bitc.bxor(bitc.lshift(crc, 1), 0x31), 0xFF)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end

-- 发送命令（可带数据字节，数据按 Sensirion 约定逐字附 CRC）
local function send_cmd(fd, lo, data_bytes)
	if data_bytes == nil then
		return i2c_write_reg(fd, CMD_PREFIX, lo)
	end
	local all = { lo }
	for _, b in ipairs(data_bytes) do all[#all + 1] = b end
	return i2c_write_multi(fd, CMD_PREFIX, unpack(all)) == 0
end

-- 读 n 字节原始应答，拆为 1 基字节数组；失败返回 nil
local function read_bytes(fd, n)
	local raw = i2c_read(fd, n)
	if raw < 0 then return nil end
	local b = {}
	for i = 0, n - 1 do
		b[i + 1] = math.floor(raw / 256 ^ (n - 1 - i)) % 256
	end
	return b
end

-- ==================== 基线持久化 ====================
-- 读回当前基线（6 字节：word+crc, word+crc），CRC 不合法返回 nil
local function baseline_get_raw(fd)
	if not send_cmd(fd, CMD_GET_BASE) then return nil end
	milli_sleep(T_BASE_MS)
	local b = read_bytes(fd, 6)
	if b == nil then return nil end
	local w1 = b[1] * 256 + b[2]
	local w2 = b[4] * 256 + b[5]
	if crc8(w1) ~= b[3] or crc8(w2) ~= b[6] then return nil end
	return b, w1, w2
end

-- 存盘（call 周期 + destroy 调用）：两字均 0 不存，避免空基线覆盖旧文件
local function baseline_save(fd)
	if not baseline_path then return end
	local b, w1, w2 = baseline_get_raw(fd)
	if b == nil then dbg("SGP30 baseline: read failed, skip save") return end
	if w1 == 0 and w2 == 0 then dbg("SGP30 baseline: all-zero, skip save") return end
	local ffd = HAL.sys.open(baseline_path, O_WRONLY_CREAT_TRUNC, FILE_MODE)
	if ffd < 0 then dbg("SGP30 baseline: open for write failed") return end
	local buf = ffi.new("uint8_t[6]")
	for i = 0, 5 do buf[i] = b[i + 1] end
	local n = HAL.sys.write(ffd, buf, 6)
	HAL.sys.close(ffd)
	if n == 6 then
		last_save_s = os.time()
		dbg("SGP30 baseline saved: " .. baseline_path)
	else
		dbg("SGP30 baseline: short write (" .. tostring(n) .. ")")
	end
end

-- 恢复（build 调用）：文件不存在/短文件/CRC 不合法/全 0 都安全跳过
local function baseline_restore(fd)
	local ffd = HAL.sys.open(baseline_path, O_RDONLY)
	if ffd < 0 then return "no file" end
	local buf = ffi.new("uint8_t[6]")
	local n = HAL.sys.read(ffd, buf, 6)
	HAL.sys.close(ffd)
	if n ~= 6 then return "no/bad file" end
	local b = {}
	for i = 0, 5 do b[i + 1] = tonumber(buf[i]) end
	local w1 = b[1] * 256 + b[2]
	local w2 = b[4] * 256 + b[5]
	if crc8(w1) ~= b[3] or crc8(w2) ~= b[6] then return "bad CRC" end
	if w1 == 0 and w2 == 0 then return "zero baseline" end
	if not send_cmd(fd, CMD_SET_BASE, b) then return "send failed" end
	milli_sleep(T_BASE_MS)
	return "restored"
end

-- ==================== 湿度补偿 ====================
-- Sensirion 公式：AH(g/m3) = 216.7 x (RH/100 x 6.112 x
--   exp(17.62T/(243.12+T)) / (273.15+T))；下发 ticks = AH x 256
local function ah_ticks_of(t, rh)
	local ah = 216.7 * (rh / 100.0 * 6.112 * math.exp(17.62 * t / (243.12 + t)) / (273.15 + t))
	local ticks = math.floor(ah * 256 + 0.5)
	if ticks < 0 then ticks = 0 end
	if ticks > 0xFFFF then ticks = 0xFFFF end
	return ticks
end

-- 从元数据/参数里解析补偿输入：t_field/rh_field 指明快照键名，输入异常返回 nil
local function compensation_ticks(data)
	local tk, rk = data.t_field, data.rh_field
	if tk == nil or rk == nil then return nil end
	local t = tonumber(data[tk])
	local rh = tonumber(data[rk])
	if t == nil or rh == nil or rh < 0 or rh > 100 then return nil end
	return ah_ticks_of(t, rh)
end

-- 【配置脚本】自检 -> Init -> （可选）恢复基线
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- SGP30 builder func get a table --------", data)
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

	-- 基线持久化配置（'-' 占位符/缺省 = 关闭）
	local bp = data.baseline
	baseline_path = (bp ~= nil and bp ~= "-" and bp ~= "") and bp or nil
	last_save_s = nil
	last_ah_ticks = nil

	-----------------------------------------------------
	-- 在位探测 + 完整性自检（0x2032 -> 0xD400，约 220ms）
	if not send_cmd(fd, CMD_SELFTEST) then
		return {
			result = "ERR",
			message = "SGP30 not responding (selftest write failed, check address 0x58 and wiring)"
		}
	end
	milli_sleep(T_SELFTEST_MS)
	local st = read_bytes(fd, 3)
	if st == nil then
		return {
			result = "ERR",
			message = "Failed to read SGP30 selftest"
		}
	end
	local st_word = st[1] * 256 + st[2]
	if st_word ~= SELFTEST_MAGIC or crc8(st_word) ~= st[3] then
		return {
			result = "ERR",
			message = string.format("SGP30 selftest failed: got 0x%04X (expect 0x%04X + valid CRC)",
				st_word, SELFTEST_MAGIC)
		}
	end

	-- 进入持续测量模式
	if not send_cmd(fd, CMD_INIT) then
		return {
			result = "ERR",
			message = "Failed to send SGP30 Init_air_quality"
		}
	end
	milli_sleep(T_INIT_MS)

	-- 恢复基线（可选）：免约 12h 重学习
	local base_state = "off"
	if baseline_path then
		base_state = baseline_restore(fd)
	end

	print(string.format("SGP30 init OK: addr=0x%02X, selftest=OK, baseline=%s",
		addr, base_state))
	return {  result = "OK"  }

end

-- 【销毁SGP30】存一次基线后交还总线（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- SGP30 ender func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		baseline_save(fd)		-- 退出前存一次最新基线
	end

	return {  result = "OK"  }

end


-- 【调用SGP30】测量一次空气质量
-- 返回CO2eq(ppm)与TVOC(ppb)，命令式协议：写命令 -> 等待 -> 纯读
-- NOTE(20260902-qing): 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- SGP30 caller func get a table --------", data)
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
	-- 湿度补偿（可选）：输入变化才下发，省一次命令往返
	local ah = compensation_ticks(data)
	if ah ~= nil and ah ~= last_ah_ticks then
		if send_cmd(fd, CMD_SET_AH, { math.floor(ah / 256) % 256, ah % 256, crc8(ah) }) then
			milli_sleep(T_BASE_MS)
			last_ah_ticks = ah
			dbg(string.format("SGP30 absolute humidity set: %d ticks", ah))
		end
	end

	if not send_cmd(fd, CMD_MEASURE) then
		return {
			result = "ERR",
			message = "SGP30 not responding (measure write failed)"
		}
	end

	milli_sleep(T_MEASURE_MS)	-- 等待测量完成（数据手册最大 12ms + 余量）

	local b = read_bytes(fd, 6)	-- 纯读6字节（不写任何指针字节）
	if b == nil then
		return {
			result = "ERR",
			message = "Failed to read SGP30"
		}
	end

	-- 6 字节（大端）：CO2eq + CRC, TVOC + CRC
	local co2  = bitc.bor(bitc.lshift(b[1], 8), b[2])
	local tvoc = bitc.bor(bitc.lshift(b[4], 8), b[5])

	-- CRC校验（不合法不报 ERR，返回标志交消费者决策，兼容旧契约）
	local crc_ok = (crc8(co2) == b[3]) and (crc8(tvoc) == b[6])

	-- 周期性基线存盘（Sensirion 建议 >= 每小时）
	if baseline_path then
		local now = os.time()
		if last_save_s == nil or now - last_save_s >= SAVE_PERIOD_S then
			baseline_save(fd)
		end
	end

	-- 返回字典
 	return {
		result = "OK",
		CO2EQ  = co2,
		TVOC   = tvoc,
		CRC_OK = crc_ok and 1 or 0
	}

end

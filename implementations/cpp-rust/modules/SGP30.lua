-- SGP30 空气质量传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 SGP30_VIRT（2026-09-15 自 modules/lib/virtbus/sgp30.lua
-- 迁入，单文件驱动+模型实验第二十个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local HAL = dofile(mpath.resolve("lib/HAL.lua"))
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
-- CRC 判据单点在 bitcompat.crc8（D1 收敛，2026-09-25）：Sensirion 词 CRC
-- = poly 0x31、init 0xFF、16 位词按 hi/lo 两字节展开——器件约定留在调用方。
local function crc8(word)
	return bitc.crc8(0xFF, 0x31, { math.floor(word / 256) % 256, word % 256 })
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
	local ffd = HAL.sys.open(baseline_path, O_WRONLY_CREAT_TRUNC + HAL.O_CLOEXEC, FILE_MODE)
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
	local ffd = HAL.sys.open(baseline_path, O_RDONLY + HAL.O_CLOEXEC)
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
	-- 审计 P3：finite_of 而非 tonumber。NaN 会让下面的区间检查恒假，
	-- ah_ticks_of 里的 0..0xFFFF 钳位同样拦不住 NaN，一路走到 send_cmd
	-- 才在 HAL 的 byte_of 处炸——末态是对的（不会写坏字节），但报错落在
	-- 总线层、看不出是补偿输入非法。本函数的契约就是「输入异常返回 nil」，
	-- 让它在正确的层返回（调用方跳过补偿，不影响主测量）。
	local t = finite_of(data[tk])
	local rh = finite_of(data[rk])
	if t == nil or rh == nil or rh < 0 or rh > 100 then return nil end
	return ah_ticks_of(t, rh)
end

require_driver("i2c", {
	name = "SGP30",

	-- 【配置脚本】自检 -> Init -> （可选）恢复基线
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- SGP30 builder func get a table --------", data)
		end

		-- 基线持久化配置（'-' 占位符/缺省 = 关闭）
		local bp = data.baseline
		baseline_path = (bp ~= nil and bp ~= "-" and bp ~= "") and bp or nil
		last_save_s = nil
		last_ah_ticks = nil

		-----------------------------------------------------
		-- 在位探测 + 完整性自检（0x2032 -> 0xD400，约 220ms）
		if not send_cmd(fd, CMD_SELFTEST) then
			return err("SGP30 not responding (selftest write failed, check address 0x58 and wiring)")
		end
		milli_sleep(T_SELFTEST_MS)
		local st = read_bytes(fd, 3)
		if st == nil then
			return err("Failed to read SGP30 selftest")
		end
		local st_word = st[1] * 256 + st[2]
		if st_word ~= SELFTEST_MAGIC or crc8(st_word) ~= st[3] then
			return err(string.format("SGP30 selftest failed: got 0x%04X (expect 0x%04X + valid CRC)",
					st_word, SELFTEST_MAGIC))
		end

		-- 进入持续测量模式
		if not send_cmd(fd, CMD_INIT) then
			return err("Failed to send SGP30 Init_air_quality")
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
	end,

	-- 【调用SGP30】测量一次空气质量
	-- 返回CO2eq(ppm)与TVOC(ppb)，命令式协议：写命令 -> 等待 -> 纯读
	-- NOTE(20260902-qing): 接收一个参数（表），返回一个结果（表）
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- SGP30 caller func get a table --------", data)
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
			return err("SGP30 not responding (measure write failed)")
		end

		milli_sleep(T_MEASURE_MS)	-- 等待测量完成（数据手册最大 12ms + 余量）

		local b = read_bytes(fd, 6)	-- 纯读6字节（不写任何指针字节）
		if b == nil then
			return err("Failed to read SGP30")
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
	end,

	-- 【销毁SGP30】存一次基线后交还总线（总线归 I2C 硬件变量所有）
	destroy = function(ctx, data)
		if DEBUG then
			dbg_table("-------- SGP30 ender func get a table --------", data)
		end

		local fd = tonumber(data.fd)
		local addr = tonumber(data.address)
		if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
			baseline_save(fd)		-- 退出前存一次最新基线
		end

		return {  result = "OK"  }
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】SGP30_VIRT —— 2026-09-15 自 modules/lib/virtbus/sgp30.lua
-- 整体迁入（单文件驱动+模型第二十个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十九者：① 生产路径零执行（new() 仅虚拟总线测试调用；位运算经
-- 本文件 mpath 上值惰性 dofile bitcompat 并缓存，不共用驱动 bitc；CRC-8
-- 公开在 SGP30_VIRT.crc8 表字段——三方独立实现交叉；常量/clamp/hi-lo 移入
-- new() 内避让）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua
-- 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua
-- 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【16 位命令字 + 每数据字 CRC-8 的命令式 I2C，且命令带读写数据载荷】
-- 的器件样板（Sensirion SGP30，I2C 地址固定 0x58）——无寄存器指针，写流首两
-- 字节恒为 0x20xx 命令大端字（驱动借 i2c_write_reg(fd,0x20,lo) 发无载荷命令、
-- i2c_write_multi(fd,0x20,lo,...) 发带载荷命令），应答全部【无指针纯读】
--（i2c_read，不写任何指针字节）。同族是 sht3x.lua（CRC-8 poly 0x31/init
-- 0xFF，校验向量 0xBEEF→0x92），SGP30 的新增协议面：
--   1) 命令带「写数据」：Set_absolute_humidity 0x2061 帧长恰 5 字节
--      （hi,lo, AH_MSB,AH_LSB,CRC）、Set_baseline 0x201E 恰 8 字节
--      （hi,lo, w1h,w1l,crc1, w2h,w2l,crc2）——器件逐字校验内嵌 CRC，
--      坏 CRC 字节在真机上被 NACK，模型照此拒绝整笔且不更新状态。
--   2) 三种待读应答按最后命令区分：Measure_test 0x2032（自检，≤220ms，
--      3 字节固定 0xD400+CRC，build 兼在位探测）、Measure_air_quality
--      0x2008（≤12ms，6 字节 CO2eq+crc | TVOC+crc）、Get_baseline
--      0x2015（≤10ms，6 字节两基线字）；读完待读即失效（再纯读 NACK）。
--   3) IAQ 启动相：Init_air_quality 0x2003 后前 15s 测量输出恒为
--      CO2eq=400/TVOC=0（datasheet 启动相），虚拟时钟由 advance 驱动；
--      守护 virt_tick 以 warm 模式模拟已度过启动相的部署态（同预武装
--      惯例，守护不驱动虚拟时钟）。
--   4) 模型只复刻协议：基线两字可被 set/get 交叉验证（驱动另有 HAL.sys
--      六字节文件持久化，属文件系统而非总线，测试侧 mock HAL.sys）；
--      CO2eq/TVOC 无换算公式（器件直接输出工程值），测量值由用例注入。
--
-- 未建模命令（0x3682 序列号/0x202F feature set/0x0006 软复位等驱动不用）
-- 一律 NACK 并入 bad_commands；模型范围以真实驱动 modules/SGP30.lua 为准。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。
-- =====================================================================

SGP30_VIRT = { _VERSION = "0.1.0" }

-- 位运算惰性装载：首次 crc8 计算时 dofile bitcompat 并缓存
local sgp30_ops_cache = nil
local function sgp30_ops()
	if sgp30_ops_cache == nil then
		local ok, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
		sgp30_ops_cache = (ok and bc) or false
	end
	return sgp30_ops_cache
end

-- CRC-8（多项式 0x31、初值 0xFF；Sensirion 同族，校验向量 0xBEEF → 0x92）。
-- 公开在工厂表字段：模型/驱动/测试三方独立实现交叉。
local function sgp30_crc8(word)
	local bitc = sgp30_ops()
	local crc = 0xFF
	for _, b in ipairs({ math.floor(word / 256) % 256, word % 256 }) do
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
SGP30_VIRT.crc8 = sgp30_crc8

function SGP30_VIRT.new()
	local crc8 = sgp30_crc8
	local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

	-- 命令字（高字节恒 0x20）
	local CMD_INIT      = 0x2003
	local CMD_MEASURE   = 0x2008
	local CMD_GET_BASE  = 0x2015
	local CMD_SET_BASE  = 0x201E
	local CMD_SELFTEST  = 0x2032
	local CMD_SET_AH    = 0x2061

	-- 各命令帧长（含两字节命令头）
	local FRAME_LEN = {
		[CMD_INIT] = 2, [CMD_MEASURE] = 2, [CMD_GET_BASE] = 2,
		[CMD_SELFTEST] = 2, [CMD_SET_AH] = 5, [CMD_SET_BASE] = 8,
	}

	-- datasheet 最大转换时长（ms）→ 有应答的命令的读门限（驱动等待含 2ms 余量）
	local GATE_MS = {
		selftest = 220,		-- Measure_test ≤220ms，驱动睡 222
		measure  = 12,		-- Measure_air_quality ≤12ms，驱动睡 14
		baseline = 10,		-- Get_baseline ≤10ms，驱动睡 12
	}
	local STARTUP_MS = 15000	-- Init 后启动相：前 15s 输出恒 400/0
	local STARTUP_CO2, STARTUP_TVOC = 400, 0
	local SELFTEST_MAGIC = 0xD400

	local function clamp_word(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
	end

	local function hi(w) return math.floor(w / 256) % 256 end
	local function lo(w) return w % 256 end

	local d = {}

	-- 芯片侧状态
	local selftest_word = SELFTEST_MAGIC
	local co2_raw, tvoc_raw = STARTUP_CO2, STARTUP_TVOC
	local base1, base2 = 0x1234, 0x5678	-- 非零学习完成态种子（全 0 有专门语义）
	local ah_word = nil			-- 最近一次 Set_absolute_humidity 的字
	local iaq = false			-- 是否已 Init_air_quality
	local iaq_ms = 0			-- Init 后虚拟运行时长（advance 累积）
	local pending = nil			-- nil | "selftest" | "measure" | "baseline"
	local remaining, ready = nil, false
	local prearmed, warm = false, false	-- virt_tick：零转换门 / 已度过启动相
	local cmds, bad_cmds = {}, {}		-- 识别命令序列（含载荷日志）/ 非法字序列
	local bad_write_crc = 0			-- 写数据内嵌 CRC 被拒次数

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local cmd_pred, read_pred
	local bad_crc = false			-- 翻转所有应答帧 CRC（自检/测量/基线）

	local function start_pending(kind)
		pending = kind
		if prearmed then
			remaining, ready = 0, true
		else
			remaining, ready = GATE_MS[kind], false
		end
	end

	local function frame_crc_bad(bytes, i0)
		-- i0 指向某字的高字节：i0,i0+1 数据，i0+2 CRC
		local w = bytes[i0] * 256 + bytes[i0 + 1]
		return crc8(w) ~= bytes[i0 + 2]
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes < 2 then return false end
		if d.nack or d.nack_write then return false end
		local word = bytes[1] * 256 + bytes[2]
		if cmd_pred and cmd_pred(word, bytes) then return false end

		local want = FRAME_LEN[word]
		if want == nil or bytes[1] ~= 0x20 then
			-- 未建模/非 0x20 族命令：器件 NACK（模型只覆盖驱动使用的命令子集）
			bad_cmds[#bad_cmds + 1] = word
			return false
		end
		if #bytes ~= want then return false end	-- 载荷长度不符（含多余字节）

		if word == CMD_SELFTEST then
			start_pending("selftest")
		elseif word == CMD_MEASURE then
			start_pending("measure")
		elseif word == CMD_GET_BASE then
			start_pending("baseline")
		elseif word == CMD_INIT then
			iaq, iaq_ms = true, 0
			pending, remaining, ready = nil, nil, false
		elseif word == CMD_SET_AH then
			if frame_crc_bad(bytes, 3) then bad_write_crc = bad_write_crc + 1; return false end
			ah_word = bytes[3] * 256 + bytes[4]
		elseif word == CMD_SET_BASE then
			if frame_crc_bad(bytes, 3) or frame_crc_bad(bytes, 6) then
				bad_write_crc = bad_write_crc + 1
				return false
			end
			base1 = bytes[3] * 256 + bytes[4]
			base2 = bytes[6] * 256 + bytes[7]
		end
		cmds[#cmds + 1] = { word = word, payload = { unpack(bytes, 3) } }
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(pending, n) then return nil end

		if pending == "selftest" and n == 3 then
			if not ready then return nil end
			local c = bad_crc and bitc.bxor(crc8(selftest_word), 0xFF) or crc8(selftest_word)
			pending = nil
			return { hi(selftest_word), lo(selftest_word), c }
		end
		if pending == "baseline" and n == 6 then
			if not ready then return nil end
			local c1 = bad_crc and bitc.bxor(crc8(base1), 0xFF) or crc8(base1)
			local c2 = bad_crc and bitc.bxor(crc8(base2), 0xFF) or crc8(base2)
			pending = nil
			return { hi(base1), lo(base1), c1, hi(base2), lo(base2), c2 }
		end
		if pending == "measure" and n == 6 then
			if not ready then return nil end
			-- 启动相输出（Init 后前 15s）；warm 模拟部署态；之后报注入值
			local co2, tvoc = co2_raw, tvoc_raw
			if iaq and not warm and iaq_ms < STARTUP_MS then
				co2, tvoc = STARTUP_CO2, STARTUP_TVOC
			end
			local c1 = bad_crc and bitc.bxor(crc8(co2), 0xFF) or crc8(co2)
			local c2 = bad_crc and bitc.bxor(crc8(tvoc), 0xFF) or crc8(tvoc)
			pending = nil
			return { hi(co2), lo(co2), c1, hi(tvoc), lo(tvoc), c2 }
		end
		-- 无待读/长度不符：NACK（真机无命令时纯读无数据）
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining, ready = 0, true end
		end
		if iaq then iaq_ms = iaq_ms + ms end
		return self
	end

	-- 注入测量工程值（CO2eq ppm / TVOC ppb，器件直出工程值无驱动换算）
	function d:set_raw(co2, tvoc)
		co2_raw, tvoc_raw = clamp_word(co2), clamp_word(tvoc)
		return self
	end

	-- 注入基线两字（Get_baseline 应答 / set→get 交叉验证）
	function d:set_baseline(w1, w2)
		base1, base2 = clamp_word(w1), clamp_word(w2)
		return self
	end

	-- 注入自检回读字（build 负路径：非 0xD400）
	function d:set_selftest_word(w)
		selftest_word = clamp_word(w)
		return self
	end

	function d:fail_cmd(pred) cmd_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_crc(on) bad_crc = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		cmd_pred, read_pred = nil, nil
		bad_crc = false
		return self
	end

	function d:reset_logs()
		cmds, bad_cmds = {}, {}
		bad_write_crc = 0
		return self
	end

	-- 上电复位：芯片状态回种子；故障钩子保留（防负路径假解除）
	function d:reset()
		selftest_word = SELFTEST_MAGIC
		co2_raw, tvoc_raw = STARTUP_CO2, STARTUP_TVOC
		base1, base2 = 0x1234, 0x5678
		ah_word = nil
		iaq, iaq_ms = false, 0
		pending, remaining, ready = nil, nil, false
		prearmed, warm = false, false
		cmds, bad_cmds = {}, {}
		bad_write_crc = 0
		return self
	end

	-- 守护逐拍造数：确定性 IAQ 正弦（CO2eq 400~700ppm、TVOC 40~200ppb，
	-- 32 拍周期），warm=已度过 15s 启动相、prearmed=命令下发即就绪；
	-- 驱动真实 milli_sleep（222ms build / 14ms call）在守护里照常睡。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_raw(math.floor(550 + 150 * math.sin(ph) + 0.5),
		             math.floor(120 + 80 * math.sin(ph + math.pi / 2) + 0.5))
		warm, prearmed = true, true
		return self
	end

	-- 只读观察口
	function d:pending() return pending end
	function d:remaining_ms() return remaining end
	function d:is_ready() return ready end
	function d:iaq_elapsed_ms() return iaq_ms end
	function d:in_startup() return iaq and not warm and iaq_ms < STARTUP_MS end
	function d:is_warm() return warm end
	function d:ah_word() return ah_word end
	function d:baseline() return base1, base2 end
	function d:selftest_word() return selftest_word end
	function d:raw() return co2_raw, tvoc_raw end
	function d:bad_write_crc_count() return bad_write_crc end
	function d:cmd_count() return #cmds end
	function d:commands()
		local out = {}
		for _, e in ipairs(cmds) do out[#out + 1] = e.word end
		return out
	end
	function d:cmd_log() return cmds end
	function d:bad_commands() return bad_cmds end
	-- 最后一次某命令的载荷（1 基，不含命令头）
	function d:payload_of(word)
		local p
		for _, e in ipairs(cmds) do
			if e.word == word then p = e.payload end
		end
		return p
	end

	return d
end

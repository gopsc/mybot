-- VL53L0X ToF 激光测距 驱动模块（ST FlightSense 第一代，I2C 地址 0x29）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE VL53L0X (
--       name    String,
--       I2C     String,
--       address String,
--       sig     String,
--       long    String,
--       timeout String
--   );
--   INSERT INTO VL53L0X (name, I2C, address)
--     VALUES ('tof0', 'i2c-1', '0x29');
--
-- 列说明（均可选，'-' 归缺省）：
--   sig     = final range 信号率门限 MCPS（0~511.99，缺省 0.25，Pololu 同款）；
--             越小越能收到弱反射（远处/低反射率目标），越大越抗串扰
--   long    = 长距模式（1/true 生效，ESPHome 同款）：改三处 tuning 寄存器
--             换取约 2m 量程，信号率门限缺省改 0.1；sig 列显式给出时以 sig 为准
--   timeout = build/call 等待 data-ready 的超时 ms（缺省 500，单帧约 33ms）
--
-- call 无需参数，返回：
--   { result, DIST_MM(毫米), STATUS(0 = 有效，255 = 无更新，1~5 为 ST 错误码),
--     VALID(1/0), SPAD_NB(有效返回 SPAD 数 8.8 定点), 
--     SIGNAL_MCPS / AMBIENT_MCPS(信号/环境光速率，9.7 定点 -> MCPS) }
-- 接 sensor_daemon：fields=DIST_MM|STATUS|VALID|SIGNAL_MCPS
--   （interval >= 50ms；STATUS 非 0 / VALID=0 的样本在消费侧过滤——
--   强阳光直射、全黑目标会缩程或丢数据；DIST_MM >= 8190 视为越界）
--
-- build 流程（寄存器级序列三方交叉核对：Pololu VL53L0X 库逐行对照
--   ESPHome vl53l0x_sensor.cpp，状态映射自 ST ULD vl53l0x_api.cpp）：
--   器件甄别(0xC0==0xEE) -> VHV EXTSUP_HV 置位 -> DataInit 舞步
--   (页 0xFF 切换 + 0x91 取 stop_variable) -> MSRC 限值检查关闭 ->
--   写信号率门限(0x44, Q9.7) -> 使能全部时序步(0x01=0xFF) -> SPAD 信息
--   (页 6/7 魔数序列 + 0x83 轮询) -> 参考.SPAD 管理(0xB0 六字节图重排) ->
--   默认 tuning 表(约 90 条寄存器写，长距模式覆写 0x30/0x57/0x48) ->
--   GPIO 中断配置(0x0A/0x84/0x0B) -> 关 MSRC/TCC(0x01=0xE8) ->
--   参考校准(VHV 0x40 + phase 0x00 两轮单次测量) -> DataInit 舞步重放 ->
--   启动背靠背连续测距(0x00=0x02)
--
-- 实现要点：
--   1. 寄存器地址 8 位（区别于 VL53L4CD 的 16 位指针），走 HAL 的
--      i2c_read_reg/i2c_write_reg 单字节与 i2c_write_multi/i2c_read_multi_bytes
--      块读写；0xFF 是页选择寄存器，tuning/SPAD/舞步序列必须整段连续执行，
--      禁止与其它消费者并发访问同一器件（沿用一器件一消费者约定）
--   2. 单帧约 33ms（tuning 默认预算，本驱动不移植 ST 的 budget 重编码管线，
--      Pololu/ESPHome 的 encode/decode 仅在改预算时才需要）
--   3. 状态映射：原始状态字节 (b & 0x78)>>3 得内部码 0~15，ST API 同款查表：
--      11 = 有效；0/5/7/12~15 = 无更新(255)；1~3 = 硬件失败(5)；
--      4 = 信号失败(2)；6/9 = 相位失败(4)；8/10 = 最小量程(3)。
--      ST 的 sigma 限值精细化检查依赖片上统计量估算，未移植——质量
--      判断用 SIGNAL_MCPS/SPAD_NB/AMBIENT_MCPS 自行过滤
--   4. 从机地址固定 0x29，一条总线挂多只要 XSHUT 时序重分配地址
--      （写 0x8A），本驱动按单只支持；Linux i2c-dev 无时钟拉伸问题

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：测距高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（8 位地址） ====================
local REG_SYSRANGE_START  = 0x00		-- mode[1:0]：1 单次 / 2 背靠背连续 / 0 停
local REG_SEQ_CONFIG      = 0x01		-- 时序步使能位图（FF 全开 / E8 关 MSRC+TCC）
local REG_INT_CLEAR       = 0x0B		-- 写 0x01 清中断
local REG_INT_CONFIG_GPIO = 0x0A		-- GPIO1 中断条件（0x04 = 新样本就绪）
local REG_RESULT_INT      = 0x13		-- bit[2:0] 中断状态（非 0 = data-ready）
local REG_RESULT_RANGE    = 0x14		-- 12 字节结果块起始（0x14~0x1F）
local REG_MSRC_CONFIG     = 0x60		-- bit1/bit4 = MSRC/预距信号率限值检查
local REG_FINAL_MIN_RATE  = 0x44		-- 16 位 Q9.7 信号率门限
local REG_GPIO_HV_MUX     = 0x84		-- bit4 = GPIO 极性（本驱动清 0 低有效）
local REG_VHV_EXTSUP_HV   = 0x89		-- bit0 = SCL/SDA 焊盘高压供电
local REG_SPAD_ENABLES    = 0xB0		-- 参考 SPAD 使能图 6 字节
local REG_MODEL_ID        = 0xC0		-- 0xEE = VL53L0X

-- ==================== 默认 tuning 表（ST DefaultTuningSettings 扁平对） ====================
-- 自 Pololu VL53L0X.cpp / ESPHome vl53l0x_sensor.cpp 双源逐条核对一致；
-- 长距模式的三处覆写（0x30/0x57/0x48）由 build 在本表之后执行
local TUNING = {
	0xFF, 0x01,  0x00, 0x00,
	0xFF, 0x00,  0x09, 0x00,  0x10, 0x00,  0x11, 0x00,
	0x24, 0x01,  0x25, 0xFF,  0x75, 0x00,
	0xFF, 0x01,  0x4E, 0x2C,  0x48, 0x00,  0x30, 0x20,
	0xFF, 0x00,
	0x30, 0x09,  0x54, 0x00,  0x31, 0x04,  0x32, 0x03,
	0x40, 0x83,  0x46, 0x25,  0x60, 0x00,  0x27, 0x00,
	0x50, 0x06,  0x51, 0x00,  0x52, 0x96,  0x56, 0x08,
	0x57, 0x30,  0x61, 0x00,  0x62, 0x00,  0x64, 0x00,
	0x65, 0x00,  0x66, 0xA0,
	0xFF, 0x01,  0x22, 0x32,  0x47, 0x14,  0x49, 0xFF,  0x4A, 0x00,
	0xFF, 0x00,  0x7A, 0x0A,  0x7B, 0x00,  0x78, 0x21,
	0xFF, 0x01,  0x23, 0x34,  0x42, 0x00,  0x44, 0xFF,  0x45, 0x26,
	0x46, 0x05,  0x40, 0x40,  0x0E, 0x06,  0x20, 0x1A,  0x43, 0x40,
	0xFF, 0x00,  0x34, 0x03,  0x35, 0x44,
	0xFF, 0x01,  0x31, 0x04,  0x4B, 0x09,  0x4C, 0x05,  0x4D, 0x04,
	0xFF, 0x00,
	0x44, 0x00,  0x45, 0x20,  0x47, 0x08,  0x48, 0x28,
	0x67, 0x00,  0x70, 0x04,  0x71, 0x01,  0x72, 0xFE,
	0x76, 0x00,  0x77, 0x00,
	0xFF, 0x01,  0x0D, 0x01,
	0xFF, 0x00,  0x80, 0x01,  0x01, 0xF8,
	0xFF, 0x01,  0x8E, 0x01,  0x00, 0x01,
	0xFF, 0x00,  0x80, 0x00,
}

-- 长距模式覆写（ESPHome long_range 同款：0x30=0x07 / 0x57=0x50 / 0x48=0x48）
local TUNING_LONG = { 0x30, 0x07, 0x57, 0x50, 0x48, 0x48 }

-- ==================== 状态映射 ====================
-- 原始状态字节 (b & 0x78)>>3 得内部码 -> ST 状态码（vl53l0x_api.cpp
-- get_pal_range_status 查表）：11 = 有效(0)，其余见下；255 = 无更新
local STATUS_RTN = {
	255, 5, 5, 5, 2, 255, 4, 255,			-- 内部码 0x0~
	3, 4, 3, 0, 255, 255, 255, 255,			-- 内部码 0x8~（11 = 有效）
}

local DEF_SIG      = 0.25
local DEF_SIG_LONG = 0.1
local DEF_TIMEOUT  = 500
local POLL_MS      = 1					-- 就绪轮询步长
local DIST_OOR     = 8190				-- >= 此值视为越界（ESPHome 同款判据）

-- 模块级状态（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local poll_timeout
local stop_variable					-- DataInit 舞步取出的关键单次测量参数

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

-- long 列 -> 布尔：数值非 0 / 常见真值串生效
local function truthy_of(v)
	if v == nil or v == "" or v == "-" then return false end
	local n = tonumber(v)
	if n ~= nil then return n ~= 0 end
	local s = tostring(v):lower()
	return s == "true" or s == "yes" or s == "on" or s == "long"
end

-- 轮询等待 reg 的某判定成立；ok(v) 返回 true 即退出
-- 超出超时返回 nil（总线失败），false（超时）
local function wait_reg(fd, reg, ok, timeout_ms)
	local left = timeout_ms
	while true do
		local v = i2c_read_reg(fd, reg)
		if v < 0 then return nil end
		if ok(v) then return true end
		if left <= 0 then return false end
		milli_sleep(POLL_MS)
		left = left - POLL_MS
	end
end

-- DataInit/启动前舞步（Pololu 同款：页切换 + 取/回写 stop_variable）
-- mode = "read"（取出 stop_variable）或 "write"（回写后启动）
local function start_stop_dance(fd, mode)
	if not i2c_write_reg(fd, 0x80, 0x01) then return nil end
	if not i2c_write_reg(fd, 0xFF, 0x01) then return nil end
	if not i2c_write_reg(fd, 0x00, 0x00) then return nil end
	if mode == "read" then
		local sv = i2c_read_reg(fd, 0x91)
		if sv < 0 then return nil end
		stop_variable = sv
	else
		if not i2c_write_reg(fd, 0x91, stop_variable or 0x2B) then return nil end
	end
	if not i2c_write_reg(fd, 0x00, 0x01) then return nil end
	if not i2c_write_reg(fd, 0xFF, 0x00) then return nil end
	if not i2c_write_reg(fd, 0x80, 0x00) then return nil end
	return true
end

-- 参考校准单轮（Pololu performSingleRefCalibration 同款）
local function ref_calibration(fd, vhv_init, timeout_ms)
	if not i2c_write_reg(fd, REG_SYSRANGE_START, bitc.bor(0x01, vhv_init)) then
		return nil, "Failed to start VL53L0X ref calibration"
	end
	local r = wait_reg(fd, REG_RESULT_INT, function(v)
		return bitc.band(v, 0x07) ~= 0
	end, timeout_ms)
	if r == nil then return nil, "Failed to poll VL53L0X ref calibration"  end
	if r == false then
		return nil, string.format("VL53L0X ref calibration timeout (%dms)", timeout_ms)
	end
	if not i2c_write_reg(fd, REG_INT_CLEAR, 0x01) then
		return nil, "Failed to clear VL53L0X interrupt"
	end
	if not i2c_write_reg(fd, REG_SYSRANGE_START, 0x00) then
		return nil, "Failed to stop VL53L0X ref calibration"
	end
	return true
end

-- 【配置脚本】器件甄别 -> DataInit -> SPAD -> tuning -> 校准 -> 连续启动
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- VL53L0X builder func get a table --------", data)
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

	local long_range = truthy_of(data.long)
	local sig = tonumber(data.sig)
	if sig == nil then sig = long_range and DEF_SIG_LONG or DEF_SIG end
	if sig < 0 then sig = 0 end
	if sig > 511.99 then sig = 511.99 end
	local timeout = int_of(data.timeout, DEF_TIMEOUT, 1, 10000)
	poll_timeout = timeout

	-----------------------------------------------------
	-- 器件甄别（0xC0 = 0xEE）
	local mid = i2c_read_reg(fd, REG_MODEL_ID)
	if mid < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X model ID"  }
	end
	if mid ~= 0xEE then
		return {
			result = "ERR",
			message = string.format("Device type = 0x%02X (expect 0xEE VL53L0X, not VL53L0X?)", mid)
		}
	end

	-- VHV：SCL/SDA 焊盘高压供电（3.3V 主机侧，Pololu/ESPHome 同款置位）
	local vhv = i2c_read_reg(fd, REG_VHV_EXTSUP_HV)
	if vhv < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X VHV config"  }
	end
	if not i2c_write_reg(fd, REG_VHV_EXTSUP_HV, bitc.bor(vhv % 256, 0x01)) then
		return {  result = "ERR", message = "Failed to write VL53L0X VHV config"  }
	end

	-- "Set I2C standard mode"
	if not i2c_write_reg(fd, 0x88, 0x00) then
		return {  result = "ERR", message = "Failed to set VL53L0X I2C standard mode"  }
	end

	-- DataInit 舞步（取出 stop_variable）
	if start_stop_dance(fd, "read") == nil then
		return {  result = "ERR", message = "Failed to run VL53L0X data-init sequence"  }
	end

	-- 关 MSRC(bit1)/预距(bit4) 信号率限值检查
	local msrc = i2c_read_reg(fd, REG_MSRC_CONFIG)
	if msrc < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X MSRC config"  }
	end
	if not i2c_write_reg(fd, REG_MSRC_CONFIG, bitc.bor(msrc % 256, 0x12)) then
		return {  result = "ERR", message = "Failed to write VL53L0X MSRC config"  }
	end

	-- 信号率门限（Q9.7 定点，16 位；截断与 Pololu float 语义一致）
	local q = math.floor(sig * 128)
	if i2c_write_multi(fd, REG_FINAL_MIN_RATE, math.floor(q / 256) % 256, q % 256) ~= 0 then
		return {  result = "ERR", message = "Failed to write VL53L0X signal rate limit"  }
	end

	-- 使能全部时序步
	if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xFF) then
		return {  result = "ERR", message = "Failed to write VL53L0X sequence config"  }
	end

	-----------------------------------------------------
	-- getSpadInfo：页 6/7 魔数序列 -> 0x83 轮询 -> 0x92 取 SPAD 数/类型
	if not i2c_write_reg(fd, 0x80, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x00, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x06) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	local p83 = i2c_read_reg(fd, 0x83)		-- 0x83 读改写必须在 page 6 上
	if p83 < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X spad status"  }
	end
	if not i2c_write_reg(fd, 0x83, bitc.bor(p83 % 256, 0x04)) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x07) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x81, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x80, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x94, 0x6B) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x83, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	local r = wait_reg(fd, 0x83, function(v) return v ~= 0 end, timeout)
	if r == nil then
		return {  result = "ERR", message = "Failed to poll VL53L0X spad status"  }
	end
	if r == false then
		return {  result = "ERR", message = string.format("VL53L0X spad info timeout (%dms)", timeout)  }
	end
	if not i2c_write_reg(fd, 0x83, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	local spad92 = i2c_read_reg(fd, 0x92)
	if spad92 < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X spad info"  }
	end
	local spad_count = bitc.band(spad92 % 256, 0x7F)
	local spad_aperture = bitc.band(spad92 % 256, 0x80) ~= 0
	if not i2c_write_reg(fd, 0x81, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x06) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	p83 = i2c_read_reg(fd, 0x83)
	if p83 < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X spad status"  }
	end
	if not i2c_write_reg(fd, 0x83, bitc.band(p83 % 256, 0xFB)) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x00, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end
	if not i2c_write_reg(fd, 0x80, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad info sequence"  }
	end

	-- 参考 SPAD 管理：读原使能图 -> 只保留前 spad_count 个（光圈型跳过前 12）
	local map = i2c_read_multi_bytes(fd, REG_SPAD_ENABLES, 6)
	if map == nil then
		return {  result = "ERR", message = "Failed to read VL53L0X spad enable map"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x01) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad setup"  }
	end
	if not i2c_write_reg(fd, 0x4F, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad setup"  }
	end
	if not i2c_write_reg(fd, 0x4E, 0x2C) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad setup"  }
	end
	if not i2c_write_reg(fd, 0xFF, 0x00) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad setup"  }
	end
	if not i2c_write_reg(fd, 0xB6, 0xB4) then
		return {  result = "ERR", message = "Failed to run VL53L0X spad setup"  }
	end
	local first_spad = spad_aperture and 12 or 0
	local enabled = 0
	local newmap = {}
	for i = 0, 47 do
		local byte_idx = math.floor(i / 8) + 1		-- 1 基
		local mask = math.floor(2 ^ (i % 8))
		if i < first_spad or enabled == spad_count then
			-- 原位累积清位（Pololu ref_spad_map[i/8] &= ~... 同款）
			newmap[byte_idx] = bitc.band(newmap[byte_idx] or map[byte_idx] or 0,
				bitc.bxor(mask, 0xFF))
		elseif bitc.band(map[byte_idx] or 0, mask) ~= 0 then
			enabled = enabled + 1
		end
	end
	-- 补齐未触达字节（first_spad=0 且 spad_count=0 等极端情形）
	for b = 1, 6 do newmap[b] = newmap[b] or map[b] or 0 end
	if i2c_write_multi(fd, REG_SPAD_ENABLES,
			newmap[1], newmap[2], newmap[3], newmap[4], newmap[5], newmap[6]) ~= 0 then
		return {  result = "ERR", message = "Failed to write VL53L0X spad enable map"  }
	end

	-----------------------------------------------------
	-- 默认 tuning 表（整段连续写；结束后页已归 0）
	for i = 1, #TUNING, 2 do
		if not i2c_write_reg(fd, TUNING[i], TUNING[i + 1]) then
			return {
				result = "ERR",
				message = string.format("Failed to write VL53L0X tuning 0x%02X", TUNING[i])
			}
		end
	end
	if long_range then
		for i = 1, #TUNING_LONG, 2 do
			if not i2c_write_reg(fd, TUNING_LONG[i], TUNING_LONG[i + 1]) then
				return {
					result = "ERR",
					message = string.format("Failed to write VL53L0X long-range tuning 0x%02X", TUNING_LONG[i])
				}
			end
		end
	end

	-- GPIO 中断：新样本就绪 + 低有效 + 清挂起
	if not i2c_write_reg(fd, REG_INT_CONFIG_GPIO, 0x04) then
		return {  result = "ERR", message = "Failed to write VL53L0X GPIO config"  }
	end
	local mux = i2c_read_reg(fd, REG_GPIO_HV_MUX)
	if mux < 0 then
		return {  result = "ERR", message = "Failed to read VL53L0X GPIO polarity"  }
	end
	if not i2c_write_reg(fd, REG_GPIO_HV_MUX, bitc.band(mux % 256, 0xEF)) then
		return {  result = "ERR", message = "Failed to write VL53L0X GPIO polarity"  }
	end
	if not i2c_write_reg(fd, REG_INT_CLEAR, 0x01) then
		return {  result = "ERR", message = "Failed to clear VL53L0X interrupt"  }
	end

	-- 关 MSRC/TCC 时序步（Pololu/ESPHome 同款缺省）
	if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xE8) then
		return {  result = "ERR", message = "Failed to write VL53L0X sequence config"  }
	end

	-- 参考校准两轮（VHV 0x40 / phase 0x00）
	if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0x01) then
		return {  result = "ERR", message = "Failed to write VL53L0X sequence config"  }
	end
	local ok, err = ref_calibration(fd, 0x40, timeout)
	if ok == nil then return {  result = "ERR", message = err  } end
	if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0x02) then
		return {  result = "ERR", message = "Failed to write VL53L0X sequence config"  }
	end
	ok, err = ref_calibration(fd, 0x00, timeout)
	if ok == nil then return {  result = "ERR", message = err  } end
	if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xE8) then
		return {  result = "ERR", message = "Failed to write VL53L0X sequence config"  }
	end

	-----------------------------------------------------
	-- 启动背靠背连续测距：舞步重放（回写 stop_variable）+ 0x00=0x02
	if start_stop_dance(fd, "write") == nil then
		return {  result = "ERR", message = "Failed to run VL53L0X start sequence"  }
	end
	if not i2c_write_reg(fd, REG_SYSRANGE_START, 0x02) then
		return {  result = "ERR", message = "Failed to start VL53L0X ranging"  }
	end

	print(string.format(
		"VL53L0X init OK: addr=0x%02X, sig=%.2fMCPS, %s, timeout=%dms",
		addr, sig, long_range and "long-range" or "standard", timeout))
	return {  result = "OK"  }

end

-- 【销毁VL53L0X】停止测距（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		i2c_write_reg(fd, REG_SYSRANGE_START, 0x00)
	end

	return {  result = "OK"  }

end


-- 【调用VL53L0X】等待中断状态 -> 读 12 字节结果块 -> 清中断
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- VL53L0X caller func get a table --------", data)
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
	-- 等 data-ready（背靠背连续模式自动开始下一帧）
	local r = wait_reg(fd, REG_RESULT_INT, function(v)
		return bitc.band(v, 0x07) ~= 0
	end, poll_timeout or DEF_TIMEOUT)
	if r == nil then
		return {
			result = "ERR",
			message = "Failed to poll VL53L0X data-ready"
		}
	end
	if r == false then
		return {
			result = "ERR",
			message = string.format("VL53L0X data-ready timeout (%dms)", poll_timeout or DEF_TIMEOUT)
		}
	end

	-- 结果块 0x14~0x1F（ST GetRangingMeasurementData 同款 12 字节）：
	-- [1]=状态字节 [3..4]=有效SPAD(8.8) [7..8]=信号率 [9..10]=环境率(9.7)
	-- [11..12]=毫米距离
	local blk = i2c_read_multi_bytes(fd, REG_RESULT_RANGE, 12)
	if blk == nil then
		return {
			result = "ERR",
			message = "Failed to read VL53L0X range results"
		}
	end

	-- 清中断（读完再清，结果寄存器为锁存值；背靠背随即开下一帧）
	if not i2c_write_reg(fd, REG_INT_CLEAR, 0x01) then
		return {
			result = "ERR",
			message = "Failed to clear VL53L0X interrupt"
		}
	end

	-- 状态映射：内部码 = (b & 0x78)>>3，查 STATUS_RTN
	local internal = bitc.band(blk[1], 0x78) / 8
	local status = STATUS_RTN[internal + 1] or 255
	local dist = blk[11] * 256 + blk[12]
	local ret = {
		result = "OK",
		DIST_MM = dist,
		STATUS = status,
		VALID = (status == 0 and dist < DIST_OOR) and 1 or 0,
		SPAD_NB = (blk[3] * 256 + blk[4]) / 256,
		SIGNAL_MCPS = (blk[7] * 256 + blk[8]) / 128,
		AMBIENT_MCPS = (blk[9] * 256 + blk[10]) / 128
	}

	if DEBUG then
		print(string.format("VL53L0X: dist=%dmm status=%d signal=%.2f ambient=%.2f spad=%.2f",
			ret.DIST_MM, ret.STATUS, ret.SIGNAL_MCPS, ret.AMBIENT_MCPS, ret.SPAD_NB))
	end

	return ret

end

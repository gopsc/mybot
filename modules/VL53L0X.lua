-- VL53L0X ToF 激光测距 驱动模块（ST FlightSense 第一代，I2C 地址 0x29）
-- bot4cj 仓颉语言机器人框架
--
-- 【单消费者声明】本器件是四个 ToF/光谱类驱动里状态最重的一个：**8 位指针 +
-- 分页族**。0xFF 是页选择寄存器，start_stop_dance 要在页 1 / 页 0 之间来回切换
-- 写 0x80 / 0x00 / 0x91；一次测距还要写 REG_SYSRANGE_START、轮询 REG_RESULT_INT
-- 等 data-ready、再写 REG_INT_CLEAR 清中断。页相位与测距状态机都在**器件侧**、
-- 跨多个事务，第二个消费者插进来会让两者同时错乱：轻则 wait_reg 超时，
-- 重则对方在页 0 的写入落到页 1 的寄存器上（写坏配置且不报错）。
-- 结果读虽然是 i2c_read_multi_bytes 的单事务原子读，但**原子单位是一个事务**，
-- 覆盖不了整条 start→poll→clear→read 序列。
-- 装配期判据见 src/hw_factory.cpp 的 checkSingleConsumer；正道是让 @Daemon 做
-- 唯一采样者、主线程经 '$' 引用读快照。标记必须写在**行首**。
SINGLE_CONSUMER = "分页族（0xFF 页选择）+ 测距状态机：页相位与就绪标志都在器件侧，跨多事务"
-- 虚拟器件模型：内嵌本文件尾部 VL53L0X_VIRT（2026-09-15 自 modules/lib/virtbus/vl53l0x.lua
-- 迁入，单文件驱动+模型实验第二十六个，8 位指针 + 分页族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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
-- （实现收敛至 drv_common.int_of，N-24）

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

require_driver("i2c", {
	name = "VL53L0X",

	-- 【配置脚本】器件甄别 -> DataInit -> SPAD -> tuning -> 校准 -> 连续启动
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- VL53L0X builder func get a table --------", data)
		end

		local fd = ctx.fd

		local long_range = truthy_of(data.long)
		-- 26.3 盘点：**评估后不改**。本列契约是「钳制」（sig='-5' 钳 0、越上界钳
		-- 511.99，既有单测钉住），而钳制对 inf 是**正确**的——inf > 511.99 为真，
		-- 归到 511.99 正是「门限放到最宽」的合理读法。改用 num_or 会把这条能用的
		-- 路径一起打成缺省值，是退步。只有 NaN 逃得过两道钳位（比较恒假），而它
		-- 在下一层被兜住：q = math.floor(NaN*128) 仍是 NaN，i2c_write_multi 的
		-- byte_of 返 nil → 返 -1 → 报 ERR "Failed to write ... signal rate limit"，
		-- fail-closed 且不触硬件。同列的 timeout 走 int_or（钳制语义，同上）。
		local sig = tonumber(data.sig)
		if sig == nil then sig = long_range and DEF_SIG_LONG or DEF_SIG end
		if sig < 0 then sig = 0 end
		if sig > 511.99 then sig = 511.99 end
		local timeout = int_or(data.timeout, DEF_TIMEOUT, 1, 10000)
		poll_timeout = timeout

		-----------------------------------------------------
		-- 器件甄别（0xC0 = 0xEE）
		local mid = i2c_read_reg(fd, REG_MODEL_ID)
		if mid < 0 then
			return err("Failed to read VL53L0X model ID")
		end
		if mid ~= 0xEE then
			return err(string.format("Device type = 0x%02X (expect 0xEE VL53L0X, not VL53L0X?)", mid))
		end

		-- VHV
		local vhv = i2c_read_reg(fd, REG_VHV_EXTSUP_HV)
		if vhv < 0 then
			return err("Failed to read VL53L0X VHV config")
		end
		if not i2c_write_reg(fd, REG_VHV_EXTSUP_HV, bitc.bor(vhv % 256, 0x01)) then
			return err("Failed to write VL53L0X VHV config")
		end

		if not i2c_write_reg(fd, 0x88, 0x00) then
			return err("Failed to set VL53L0X I2C standard mode")
		end

		if start_stop_dance(fd, "read") == nil then
			return err("Failed to run VL53L0X data-init sequence")
		end

		local msrc = i2c_read_reg(fd, REG_MSRC_CONFIG)
		if msrc < 0 then
			return err("Failed to read VL53L0X MSRC config")
		end
		if not i2c_write_reg(fd, REG_MSRC_CONFIG, bitc.bor(msrc % 256, 0x12)) then
			return err("Failed to write VL53L0X MSRC config")
		end

		local q = math.floor(sig * 128)
		if i2c_write_multi(fd, REG_FINAL_MIN_RATE, math.floor(q / 256) % 256, q % 256) ~= 0 then
			return err("Failed to write VL53L0X signal rate limit")
		end

		if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xFF) then
			return err("Failed to write VL53L0X sequence config")
		end

		-----------------------------------------------------
		-- getSpadInfo
		if not i2c_write_reg(fd, 0x80, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x00, 0x00) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x06) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		local p83 = i2c_read_reg(fd, 0x83)
		if p83 < 0 then
			return err("Failed to read VL53L0X spad status")
		end
		if not i2c_write_reg(fd, 0x83, bitc.bor(p83 % 256, 0x04)) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x07) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x81, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x80, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x94, 0x6B) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x83, 0x00) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		local r = wait_reg(fd, 0x83, function(v) return v ~= 0 end, timeout)
		if r == nil then
			return err("Failed to poll VL53L0X spad status")
		end
		if r == false then
			return err(string.format("VL53L0X spad info timeout (%dms)", timeout))
		end
		if not i2c_write_reg(fd, 0x83, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		local spad92 = i2c_read_reg(fd, 0x92)
		if spad92 < 0 then
			return err("Failed to read VL53L0X spad info")
		end
		local spad_count = bitc.band(spad92 % 256, 0x7F)
		local spad_aperture = bitc.band(spad92 % 256, 0x80) ~= 0
		if not i2c_write_reg(fd, 0x81, 0x00) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x06) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		p83 = i2c_read_reg(fd, 0x83)
		if p83 < 0 then
			return err("Failed to read VL53L0X spad status")
		end
		if not i2c_write_reg(fd, 0x83, bitc.band(p83 % 256, 0xFB)) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x00, 0x01) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0xFF, 0x00) then
			return err("Failed to run VL53L0X spad info sequence")
		end
		if not i2c_write_reg(fd, 0x80, 0x00) then
			return err("Failed to run VL53L0X spad info sequence")
		end

		-- 参考 SPAD 管理
		local map = i2c_read_multi_bytes(fd, REG_SPAD_ENABLES, 6)
		if map == nil then
			return err("Failed to read VL53L0X spad enable map")
		end
		if not i2c_write_reg(fd, 0xFF, 0x01) then
			return err("Failed to run VL53L0X spad setup")
		end
		if not i2c_write_reg(fd, 0x4F, 0x00) then
			return err("Failed to run VL53L0X spad setup")
		end
		if not i2c_write_reg(fd, 0x4E, 0x2C) then
			return err("Failed to run VL53L0X spad setup")
		end
		if not i2c_write_reg(fd, 0xFF, 0x00) then
			return err("Failed to run VL53L0X spad setup")
		end
		if not i2c_write_reg(fd, 0xB6, 0xB4) then
			return err("Failed to run VL53L0X spad setup")
		end
		local first_spad = spad_aperture and 12 or 0
		local enabled = 0
		local newmap = {}
		for i = 0, 47 do
			local byte_idx = math.floor(i / 8) + 1
			local mask = math.floor(2 ^ (i % 8))
			if i < first_spad or enabled == spad_count then
				newmap[byte_idx] = bitc.band(newmap[byte_idx] or map[byte_idx] or 0,
					bitc.bxor(mask, 0xFF))
			elseif bitc.band(map[byte_idx] or 0, mask) ~= 0 then
				enabled = enabled + 1
			end
		end
		for b = 1, 6 do newmap[b] = newmap[b] or map[b] or 0 end
		if i2c_write_multi(fd, REG_SPAD_ENABLES,
				newmap[1], newmap[2], newmap[3], newmap[4], newmap[5], newmap[6]) ~= 0 then
			return err("Failed to write VL53L0X spad enable map")
		end

		-----------------------------------------------------
		-- 默认 tuning 表
		for i = 1, #TUNING, 2 do
			if not i2c_write_reg(fd, TUNING[i], TUNING[i + 1]) then
				return err(string.format("Failed to write VL53L0X tuning 0x%02X", TUNING[i]))
			end
		end
		if long_range then
			for i = 1, #TUNING_LONG, 2 do
				if not i2c_write_reg(fd, TUNING_LONG[i], TUNING_LONG[i + 1]) then
					return err(string.format("Failed to write VL53L0X long-range tuning 0x%02X", TUNING_LONG[i]))
				end
			end
		end

		-- GPIO 中断
		if not i2c_write_reg(fd, REG_INT_CONFIG_GPIO, 0x04) then
			return err("Failed to write VL53L0X GPIO config")
		end
		local mux = i2c_read_reg(fd, REG_GPIO_HV_MUX)
		if mux < 0 then
			return err("Failed to read VL53L0X GPIO polarity")
		end
		if not i2c_write_reg(fd, REG_GPIO_HV_MUX, bitc.band(mux % 256, 0xEF)) then
			return err("Failed to write VL53L0X GPIO polarity")
		end
		if not i2c_write_reg(fd, REG_INT_CLEAR, 0x01) then
			return err("Failed to clear VL53L0X interrupt")
		end

		if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xE8) then
			return err("Failed to write VL53L0X sequence config")
		end

		-- 参考校准两轮
		if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0x01) then
			return err("Failed to write VL53L0X sequence config")
		end
		local ok, calib_err = ref_calibration(fd, 0x40, timeout)
		if ok == nil then return err(calib_err) end
		if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0x02) then
			return err("Failed to write VL53L0X sequence config")
		end
		ok, calib_err = ref_calibration(fd, 0x00, timeout)
		if ok == nil then return err(calib_err) end
		if not i2c_write_reg(fd, REG_SEQ_CONFIG, 0xE8) then
			return err("Failed to write VL53L0X sequence config")
		end

		-----------------------------------------------------
		-- 启动背靠背连续测距
		if start_stop_dance(fd, "write") == nil then
			return err("Failed to run VL53L0X start sequence")
		end
		if not i2c_write_reg(fd, REG_SYSRANGE_START, 0x02) then
			return err("Failed to start VL53L0X ranging")
		end

		print(string.format(
			"VL53L0X init OK: addr=0x%02X, sig=%.2fMCPS, %s, timeout=%dms",
			ctx.addr, sig, long_range and "long-range" or "standard", timeout))
		return {  result = "OK"  }
	end,

	-- 【销毁VL53L0X】停止测距（缺 fd/addr 安全跳过）
	destroy = function(ctx, data)
		local fd = tonumber(data.fd)
		local addr = tonumber(data.address)
		if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
			i2c_write_reg(fd, REG_SYSRANGE_START, 0x00)
		end
		return {  result = "OK"  }
	end,

	-- 【调用VL53L0X】等待中断状态 -> 读 12 字节结果块 -> 清中断
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- VL53L0X caller func get a table --------", data)
		end

		local fd = ctx.fd

		local r = wait_reg(fd, REG_RESULT_INT, function(v)
			return bitc.band(v, 0x07) ~= 0
		end, poll_timeout or DEF_TIMEOUT)
		if r == nil then
			return err("Failed to poll VL53L0X data-ready")
		end
		if r == false then
			return err(string.format("VL53L0X data-ready timeout (%dms)", poll_timeout or DEF_TIMEOUT))
		end

		local blk = i2c_read_multi_bytes(fd, REG_RESULT_RANGE, 12)
		if blk == nil then
			return err("Failed to read VL53L0X range results")
		end

		if not i2c_write_reg(fd, REG_INT_CLEAR, 0x01) then
			return err("Failed to clear VL53L0X interrupt")
		end

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
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】VL53L0X_VIRT —— 2026-09-15 自 modules/lib/virtbus/vl53l0x.lua
-- 整体迁入（单文件驱动+模型第二十六个，8 位指针 + 0xFF 分页族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前二十五者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，自包含分页实现；常量移入 new() 内避让；new() 内
-- `local vl = VL53L0X_VIRT` 绑定使模型体零改动移植）；② 工厂经全局表而非
-- 文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功
-- 路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，
-- 互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 对应真实驱动 modules/VL53L0X.lua（地址固定 0x29）。注意 VL53L0X 是
-- 「8 位寄存器指针 + 0xFF 页切换」的分页器件（16 位指针的是 VL53L4CD，
-- 别混用 regmap ptr16）：同一个寄存器号在不同页是不同物理寄存器，模型
-- 按 regs[页][号] 分页存储。
--
-- 建模范围（协议层事实，序列锁定 Pololu VL53L0X.cpp / ESPHome 三方对照）：
--   * 0xC0 = 0xEE 器件 ID（who() 可改错挂）；0x89 VHV、0x84 GPIO 极性初值
--   * 0x91（page 1）stop_variable DataInit 舞步取/回写
--   * getSpadInfo：page6 的 0x83 RMW、page7 的 0x83 轮询（0x00 等待→非 0）、
--     page7 的 0x92 SPAD 数/类型（bit7=光圈型，低 7 位=数量）
--   * page0 0x00 SYSRANGE 模式机：0x02 背靠背连续（5ms 虚拟转换倒计时）、
--     0x01/0x41 参考校准启动（立即就绪）、0x00 停
--   * 0x13 bit[2:0] data-ready；0x0B=0x01 清中断（连续模式重新计时）
--   * 0x14~0x1F 12 字节结果块（状态/SPAD 8.8/信号 9.7/环境 9.7/毫米距离）
-- 模型不实现 ST 状态查表与定点换算（那是驱动的事），只提供结果区位场。
--
-- 挂载：
--   vbus.load_driver("modules/VL53L0X.lua")  -- 定义全局 build/call/destroy 与 VL53L0X_VIRT
--   local tof = VL53L0X_VIRT.new()
--   vbus.attach("VL53L0X@0x29", 0x29, tof)
--   tof:inject_result({ st = 0x58, dist = 300, signal = 0x0C80, ... })
--   tof:virt_tick(n)   -- 守护逐拍确定性合成样本（预武装，首次轮询即就绪）
-- =====================================================================

VL53L0X_VIRT = { _VERSION = "0.1.0" }

function VL53L0X_VIRT.new(opts)
	local vl = VL53L0X_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	local MODEL_ID = 0xEE
	local STOP_VAR = 0x2B
	local REG_PAGE = 0xFF
	local REG_SYSRANGE = 0x00
	local REG_INT_CLEAR = 0x0B
	local REG_RESULT_INT = 0x13
	local REG_RESULT_RANGE = 0x14
	local CONV_MS = 5			-- 背靠背单帧约 33ms；旧桩/测试按 5ms 倒计时推进

	local self = {}

	-- ---- 器件状态 ----
	local regs = {}				-- regs[page][reg] = byte
	local page = 0				-- 当前页（0xFF 页选择）
	local ptr, ptr_page = 0, 0		-- 最近一次指针写（读事务跟随）
	local model_id = MODEL_ID
	local stop_var = STOP_VAR
	local spad92 = 0x18			-- 默认 24 SPAD 非光圈
	local continuous = false
	local armed = false			-- data-ready（0x13 低 3 位非 0）
	local countdown = 0			-- 连续模式虚拟转换倒计时 ms
	local spad_pending = false		-- page7 0x83=0x00 后等待非 0

	-- ---- 故障钩子（public 字段，attach 后置位即时生效；reset 不清，负路径护栏） ----
	self.nack = false			-- 读写全断（器件掉线）
	self.nack_read = false
	self.nack_write = false
	local never_ready, spad_stuck, refcal_stuck = false, false, false
	local fail_read_set = {}		-- "page:reg" -> true
	local write_pred = nil		-- 定向写故障：pred(字节表) 命中的写 NACK

	-- ---- 事务留痕 ----
	local wlog = {}			-- {p=页, reg=, vals={...}, multi=}
	local sysrange_vals = {}	-- page0 写 0x00 的模式值序列
	local sig_writes = {}		-- 0x44 multi 写（信号率门限 Q9.7）
	local map_writes = {}		-- 0xB0 multi 写（SPAD 使能图 6 字节）
	local reads_91 = 0
	local reads_83 = {}		-- 每次 0x83 读所在页
	local clears = 0

	local function page_regs(p)
		local t = regs[p]
		if t == nil then t = {}; regs[p] = t end
		return t
	end

	local function init_device()
		regs = {}
		local p0 = page_regs(0)
		p0[0x89] = 0x00			-- VHV EXTSUP_HV（驱动 RMW 置 bit0）
		p0[0x84] = 0x12			-- GPIO HV MUX，bit4=1 验证 RMW 清除
		for r = 0xB0, 0xB5 do p0[r] = 0xFF end	-- 上电参考 SPAD 图全 1
		page = 0
		ptr, ptr_page = 0, 0
		model_id = MODEL_ID
		stop_var = STOP_VAR
		spad92 = 0x18
		continuous = false
		armed = false
		countdown = 0
		spad_pending = false
	end

	local function reset_logs()
		wlog = {}
		sysrange_vals = {}
		sig_writes = {}
		map_writes = {}
		reads_91 = 0
		reads_83 = {}
		clears = 0
	end

	init_device()

	-- ===================== 状态/留痕 API（冒号定义） =====================

	function self:page() return page end
	function self:continuous() return continuous end
	function self:armed() return armed end
	function self:get_reg(reg, p) return regs[p or 0] and regs[p or 0][reg] or 0 end
	function self:write_log() return wlog end
	function self:sysrange_log() return sysrange_vals end
	function self:sig_writes() return sig_writes end
	function self:map_writes() return map_writes end
	function self:reads_91() return reads_91 end
	function self:reads_83_pages() return reads_83 end
	function self:clear_count() return clears end
	function self:reset_logs() reset_logs(); return self end

	-- 单字节写序列中某寄存器的值序列（默认 page0）
	function self:write_values(reg, p)
		local t = {}
		for _, w in ipairs(wlog) do
			if w.reg == reg and w.p == (p or 0) and not w.multi then
				t[#t + 1] = w.vals[1]
			end
		end
		return t
	end

	-- ---- 配置注入 ----
	function self:who(id) model_id = id; return self end
	function self:set_stop_variable(v) stop_var = math.floor(v) % 256; return self end

	-- count 1~127；aperture=true 置 bit7（光圈型，参考 SPAD 跳前 12）
	function self:set_spad(count, aperture)
		count = math.floor(count) % 128
		spad92 = count + (aperture and 0x80 or 0)
		return self
	end

	-- 注入 12 字节结果块（0x14~0x1F）：原始定点码，换算由驱动做
	--   st 状态字节；spad 8.8；signal/ambient 9.7；dist 毫米
	-- 连续模式下注入即武装（驱动首次轮询直接就绪，无需虚拟转换等待）
	function self:inject_result(o)
		local p0 = page_regs(0)
		local function put16(reg, raw)
			raw = math.floor(raw) % 65536
			p0[reg] = math.floor(raw / 256) % 256
			p0[reg + 1] = raw % 256
		end
		p0[0x14] = math.floor(o.st or 0) % 256
		p0[0x15] = 0x00
		put16(0x16, o.spad or 0)
		put16(0x18, 0)
		put16(0x1A, o.signal or 0)
		put16(0x1C, o.ambient or 0)
		put16(0x1E, o.dist or 0)
		if continuous then armed = true; countdown = 0 end
		return self
	end

	-- 测试用：外部虚拟时钟（milli_sleep 桩调用）；连续模式到点自动就绪
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if continuous and not armed then
			countdown = countdown - ms
			if countdown <= 0 then armed = true end
		end
		return self
	end

	-- ---- 故障注入 ----
	function self:fail_read(reg, p, on)
		fail_read_set[string.format("%d:%d", p or 0, reg)] = on and true or nil
		return self
	end
	-- 定向写故障（含指针写）：pred(bytes) 返回 true 的写事务 NACK。
	-- 典型用途：只让 0x0B 清中断写失败而不影响之前的读指针。
	function self:fail_write(pred) write_pred = pred; return self end
	function self:set_spad_stuck(on) spad_stuck = on and true or false; return self end
	function self:set_refcal_stuck(on) refcal_stuck = on and true or false; return self end
	function self:set_never_ready(on) never_ready = on and true or false; return self end
	function self:clear_faults()
		self.nack, self.nack_read, self.nack_write = false, false, false
		never_ready, spad_stuck, refcal_stuck = false, false, false
		fail_read_set = {}
		write_pred = nil
		return self
	end

	-- 状态机复位（等价重新上电；故障钩子保留）
	function self:reset()
		init_device()
		reset_logs()
		return self
	end

	-- ===================== 总线接口（点定义闭包，无 self） =====================

	-- 写事务：1 字节 = 寄存器指针（读消息前导）；2+ 字节 = 寄存器写
	-- （首字节寄存器号，后续数据）。return false = NACK。
	self.write = function(bytes)
		if self.nack or self.nack_write then return false end
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if write_pred ~= nil and write_pred(bytes) then return false end
		if #bytes == 1 then
			ptr, ptr_page = bytes[1], page
			return true
		end

		local reg = bytes[1]
		-- 页切换：本事务只做页选
		if reg == REG_PAGE then
			page = bytes[2] % 256
			wlog[#wlog + 1] = { p = page, reg = REG_PAGE, vals = { bytes[2] }, multi = false }
			return true
		end

		local p = page
		local pr = page_regs(p)
		local vals = {}
		for i = 2, #bytes do
			local v = bytes[i] % 256
			vals[#vals + 1] = v
			pr[reg + i - 2] = v
		end
		local multi = #vals > 1
		wlog[#wlog + 1] = { p = p, reg = reg, vals = vals, multi = multi }
		if reg == 0x44 and multi then sig_writes[#sig_writes + 1] = vals end
		if reg == 0xB0 and multi then map_writes[#map_writes + 1] = vals end

		-- SYSRANGE 模式机（仅 page0）
		if reg == REG_SYSRANGE and p == 0 then
			local v = vals[1]
			sysrange_vals[#sysrange_vals + 1] = v
			if v == 0x02 then
				continuous = true
				armed = false
				countdown = CONV_MS
			elseif v == 0x00 then
				continuous = false
			elseif v == 0x01 or v == 0x41 then
				if not refcal_stuck then armed = true end
			end
		end

		-- 清中断
		if reg == REG_INT_CLEAR and vals[1] == 0x01 then
			clears = clears + 1
			armed = false
			if continuous then countdown = CONV_MS end
		end

		-- page7 的 0x83 SPAD 就绪握手
		if reg == 0x83 and p == 7 then
			if vals[1] == 0x00 then spad_pending = true
			elseif vals[1] == 0x01 then spad_pending = false end
		end
		return true
	end

	-- 读事务：n 字节，从最近指针写指定的（页, 寄存器）起 burst；nil = NACK。
	self.read = function(n)
		if self.nack or self.nack_read then return nil end
		if fail_read_set[string.format("%d:%d", ptr_page, ptr)] then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end

		local out = {}

		local function fill_special(first)
			out[1] = first % 256
			for i = 2, n do out[i] = 0 end
		end

		if ptr == 0xC0 then
			fill_special(model_id)
		elseif ptr == 0x91 and ptr_page == 1 then
			reads_91 = reads_91 + 1
			fill_special(stop_var)
		elseif ptr == 0x92 and ptr_page == 7 then
			fill_special(spad92)
		elseif ptr == 0x83 then
			reads_83[#reads_83 + 1] = ptr_page
			if ptr_page == 7 and spad_pending then
				fill_special(spad_stuck and 0x00 or 0x01)
			else
				fill_special(regs[ptr_page] and regs[ptr_page][0x83] or 0)
			end
		elseif ptr == REG_RESULT_INT then
			if never_ready then fill_special(0x00)
			elseif armed then fill_special(0x07)
			else fill_special(0x00) end
		else
			local pr = regs[ptr_page] or {}
			for i = 0, n - 1 do out[i + 1] = pr[ptr + i] or 0 end
		end
		return out
	end

	-- ===================== 守护合成样本（阶段 C） =====================
	-- 确定性正弦距离 100~1100mm（32 拍周期），恒为有效帧：
	-- st=0x58（内部码 11）、2.0 SPAD、25 MCPS 信号、6 MCPS 环境光。
	-- 预武装——守护 call 的首次 0x13 轮询即就绪，不依赖 milli_sleep。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local phase = math.sin(n * (2 * math.pi / 32)) * 0.5 + 0.5
		local dist = 100 + math.floor(phase * 1000 + 0.5)
		self:inject_result({
			st = 0x58, spad = 0x0200, signal = 0x0C80, ambient = 0x0300,
			dist = dist,
		})
		return self
	end

	return self
end

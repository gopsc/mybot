-- VL53L4CD ToF 激光测距 驱动模块（ST FlightSense，I2C 地址 0x29）
-- bot4cj 仓颉语言机器人框架
--
-- 【单消费者声明】16 位指针族，一次测距是**多事务状态机**：写 REG_SYSTEM_START
-- （0x21 连续 / 0x40 自主 / 0x00 停）→ wait_ready 轮询 HV mux 与 TIO 状态位 →
-- 读结果块；build 侧另有软复位、量程配置 A/B 与 91 字节配置流。
-- 测距状态机与 data-ready 标志都在**器件侧**：第二个消费者写 SYSTEM_START 或
-- 抢先读走就绪标志，会让对方 wait_ready 超时、或把上一帧结果当新帧读走
-- （数值合法、时间戳错，看不出来）。结果读本身是单事务原子读，但原子单位是
-- 一个事务，覆盖不了整条序列。
-- 装配期判据见 src/hw_factory.cpp 的 checkSingleConsumer；正道是让 @Daemon 做
-- 唯一采样者、主线程经 '$' 引用读快照。标记必须写在**行首**。
SINGLE_CONSUMER = "测距状态机：SYSTEM_START + 就绪标志在器件侧，一次测距跨多个事务"
-- 虚拟器件模型：内嵌本文件尾部 VL53L4CD_VIRT（2026-09-15 自 modules/lib/virtbus/vl53l4cd.lua
-- 迁入，单文件驱动+模型实验第十个，16 位指针族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE VL53L4CD (
--       name    String,
--       I2C     String,
--       address String,
--       budget  String,
--       inter   String,
--       timeout String
--   );
--   INSERT INTO VL53L4CD (name, I2C, address)
--     VALUES ('tof0', 'i2c-1', '0x29');
--
-- 列说明（均可选，'-' 归缺省）：
--   budget  = 单次测量 timing budget ms（10~200，缺省 50，ST 初始化同款）
--   inter   = 测量间隔 ms：0 = 连续模式（缺省，背靠背测量）；
--             >budget = 自主低功耗模式（间隔必须大于 budget，否则报错）
--   timeout = build/call 等待 data-ready 的超时 ms（缺省 1000，ST 同款）
--
-- call 无需参数，返回：
--   { result, DIST_MM(毫米), STATUS(0 = 有效，其余为 ST 错误码), VALID(1/0),
--     SPAD_NB(有效 SPAD 数), SIGNAL_KCPS / AMBIENT_KCPS(信号/环境光速率)，
--     SIGMA_MM(标准差，测量质量) }
-- 接 sensor_daemon：fields=DIST_MM|STATUS|VALID|SIGNAL_KCPS
--   （interval >= budget；STATUS 非 0 / VALID=0 的样本在消费侧过滤——
--   强阳光直射、全黑目标会缩程或丢数据，靠质量字段识别）
--
-- build 流程（自 ST ULD vl53l4cd_api.c 逐行移植）：
--   软复位(0x0000=0x00->0x01) -> 等固件启动(0x00E5==3) ->
--   写默认配置流(0x2D~0x87 共 91 字节，单事务流写) -> VHV 预热测量
--   (0x0087=0x40，等 ready，清中断，停) -> VHV/OSC 配置三写 ->
--   SetRangeTiming(budget, inter) -> 启动测距(连续 0x21/自主 0x40) ->
--   等首个测量就绪 + 清中断（兼做全链路自检）
--
-- 实现要点：
--   1. 寄存器地址 16 位——走 HAL 的 i2c_write_reg16/i2c_read_reg16
--      （指针写与数据读合并为单次 I2C_RDWR 原子事务，避免指针竞态）
--   2. SetRangeTiming 预算编码逐行移植 ST 源码：整数除法、32 位回绕、
--      指数/尾数归一化循环均与 C 一致；1.055 系数 C 端为 float32，
--      本移植用 double，自主模式的间隔寄存器可能相差 1 tick（微秒级，无碍）
--   3. data-ready 判定含极性处理：0x0030 bit4 决定 0x0031 bit0 的有效极性
--   4. 从机地址固定 0x29，一条总线挂多只要 XSHUT 时序重分配地址，
--      本驱动按单只支持

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：测距高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（16 位地址，值大端） ====================
local REG_SOFT_RESET        = 0x0000		-- 0x00 复位保持 / 0x01 释放
local REG_OSC_FREQUENCY     = 0x0006		-- 振荡器频率（word）
local REG_VHV_LOOP_BOUND    = 0x0008
local REG_GPIO_HV_MUX_CTRL  = 0x0030		-- bit4：GPIO 中断极性
local REG_GPIO_TIO_HV_STATUS = 0x0031		-- bit0：data-ready（极性见上）
local REG_RANGE_CONFIG_A    = 0x005E		-- timing budget 编码 A
local REG_RANGE_CONFIG_B    = 0x0061		-- timing budget 编码 B
local REG_INTERMEASUREMENT_MS = 0x006C		-- 测量间隔（dword，0 = 连续）
local REG_SYSTEM_INTERRUPT_CLEAR = 0x0086	-- 写 0x01 清中断
local REG_SYSTEM_START      = 0x0087		-- 0x21 连续 / 0x40 自主 / 0x00 停
local REG_RESULT_RANGE_STATUS = 0x0089		-- bit[4:0] 原始状态
local REG_RESULT_SPAD_NB    = 0x008C		-- word，/256 = 有效 SPAD 数
local REG_RESULT_SIGNAL_RATE = 0x008E		-- word，x8 = kcps
local REG_RESULT_AMBIENT_RATE = 0x0090		-- word，x8 = kcps
local REG_RESULT_SIGMA      = 0x0092		-- word，/4 = mm
local REG_RESULT_DISTANCE   = 0x0096		-- word，毫米
local REG_OSC_CALIBRATE     = 0x00DE		-- bit[9:0] PLL 校准值
local REG_FIRMWARE_SYSTEM_STATUS = 0x00E5	-- ==3 固件就绪

-- ==================== 默认配置流（0x2D~0x87 共 91 字节） ====================
-- 自 ST ULD VL53L4CD_SensorInit 的 default config 表逐字节转录
local CONFIG_TABLE = {
	0x00, 0x01, 0x01, 0x11, 0x02, 0x00, 0x02, 0x08, 0x00, 0x08,		-- 0x2D~
	0x10, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x0F,		-- 0x37~
	0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x02,		-- 0x41~
	0x14, 0x21, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC8,		-- 0x4B~
	0x00, 0x00, 0x38, 0xFF, 0x01, 0x00, 0x08, 0x00, 0x00, 0x01,		-- 0x55~
	0xCC, 0x07, 0x01, 0xF1, 0x05, 0x00, 0xA0, 0x00, 0x80, 0x08,		-- 0x5F~
	0x38, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x89, 0x00, 0x00, 0x00,		-- 0x69~
	0x00, 0x00, 0x00, 0x00, 0x01, 0x07, 0x05, 0x06, 0x06, 0x00,		-- 0x73~
	0x00, 0x02, 0xC7, 0xFF, 0x9B, 0x00, 0x00, 0x00, 0x01, 0x00,		-- 0x7D~
	0x00,															-- 0x87
}

-- ==================== 状态映射 ====================
-- 原始状态(&0x1F) -> ST 状态码；映射值 0 = 测量有效（ST ULD status_rtn 表）
local STATUS_RTN = {
	255, 255, 255, 5, 2, 4, 1, 7, 3, 0,			-- 0x00~
	255, 255, 9, 13, 255, 255, 255, 255, 10, 6,	-- 0x0A~
	255, 255, 11, 12,							-- 0x14~
}

local DEF_BUDGET  = 50
local DEF_INTER   = 0
local DEF_TIMEOUT = 1000

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local poll_timeout

-- ==================== 底层辅助 ====================
-- 数值列 -> 钳到 [lo, hi] 的整数；非法/'-' 归缺省
-- （实现收敛至 drv_common.int_of，N-24）

-- 写 32 位大端值到 16 位指针寄存器，返回 0 = 成功
local function wr_reg32(fd, reg16, v)
	v = v % 4294967296
	return i2c_write_reg16(fd, reg16,
		math.floor(v / 16777216) % 256,
		math.floor(v / 65536) % 256,
		math.floor(v / 256) % 256,
		v % 256)
end

-- data-ready 查询（ST CheckForDataReady 语义，含极性处理）
-- 返回 true(就绪) / false(未就绪) / nil(总线失败)
local function check_data_ready(fd)
	local mux = i2c_read_reg16(fd, REG_GPIO_HV_MUX_CTRL, 1)
	if mux < 0 then return nil end
	local int_pol = (math.floor(mux / 16) % 2 == 1) and 0 or 1		-- bit4
	local tio = i2c_read_reg16(fd, REG_GPIO_TIO_HV_STATUS, 1)
	if tio < 0 then return nil end
	return (tio % 2) == int_pol										-- bit0
end

-- 轮询等待 data-ready：true 就绪 / false 超时 / nil 总线失败
local function wait_ready(fd, timeout_ms)
	local left = timeout_ms
	while left > 0 do
		local r = check_data_ready(fd)
		if r == nil then return nil end
		if r then return true end
		milli_sleep(1)
		left = left - 1
	end
	return false
end

-- ST ULD SetRangeTiming 逐行移植：整数除法与 32 位回绕同 C
-- （1.055 系数 C 端为 float32，此处 double，自主模式间隔可能差 1 tick，无碍）
-- 指数/尾数编码：值 >255 则循环右移，指数记在高位字节
-- 防线：tmp 由器件寄存器读回的振荡频率推导，可精确为 0（见 set_range_timing），
-- 此时 d=0 → tb/0 = +inf → 下面的降位循环永不收敛，build() 挂死在主线程/守护
-- 线程里且 lua_pcall 无法救援（pcall 只兜 error，不兜死循环）。故显式拒绝退化
-- 入参，由调用方转成 ERR 契约。
local function encode_timeout(tb_us, tmp)
	local d = math.floor(tmp / 64)
	if d <= 0 then return nil end
	local ls = math.floor((tb_us + math.floor(d / 2)) / d) - 1
	local exp = 0
	while ls > 255 do
		ls = math.floor(ls / 2)
		exp = exp + 1
	end
	return exp * 256 + ls
end

local function set_range_timing(fd, budget_ms, inter_ms)
	if budget_ms < 10 or budget_ms > 200 then
		return nil, "Invalid timing budget (10~200ms)"
	end
	if inter_ms ~= 0 and inter_ms <= budget_ms then
		return nil, "Invalid inter-measurement (0 or > budget)"
	end

	local osc = i2c_read_reg16(fd, REG_OSC_FREQUENCY, 2)
	if osc <= 0 then
		return nil, "Failed to read oscillator frequency"
	end
	-- C: macro_period_us = (2304 * (0x40000000 / osc)) >> 6（uint32 乘法回绕）
	local macro = math.floor(2304 * math.floor(0x40000000 / osc)) % 4294967296
	macro = math.floor(macro / 64)
	-- 防线：2304 = 256*9 使 macro 恒为 4 的倍数，且 osc ∈ {1,2,4,8,16,32,64}
	-- （半接线、错地址、器件异常时读回的小 2 的幂）会让 0x40000000/osc 把
	-- 2^32 因子全部消化掉 → macro 精确为 0 → 下游 encode_timeout 除零死循环。
	if macro <= 0 then
		return nil, "Unreasonable oscillator frequency " .. tostring(osc)
			.. " (macro period is zero)"
	end

	local tb = budget_ms * 1000
	if inter_ms == 0 then
		-- 连续模式
		if wr_reg32(fd, REG_INTERMEASUREMENT_MS, 0) ~= 0 then
			return nil, "Failed to write inter-measurement"
		end
		tb = tb - 2500
	else
		-- 自主低功耗模式
		local cal = i2c_read_reg16(fd, REG_OSC_CALIBRATE, 2)
		if cal < 0 then
			return nil, "Failed to read oscillator calibrate value"
		end
		local clock_pll = cal % 1024						-- & 0x3FF
		local factor = math.floor(1.055 * inter_ms * clock_pll)
		if wr_reg32(fd, REG_INTERMEASUREMENT_MS, factor) ~= 0 then
			return nil, "Failed to write inter-measurement"
		end
		tb = tb - 4300
		tb = math.floor(tb / 2)
	end

	tb = tb * 4096										-- << 12
	local a = encode_timeout(tb, macro * 16)
	local b = encode_timeout(tb, macro * 12)
	if a == nil or b == nil then
		return nil, "Timeout encoding failed (degenerate timing parameters)"
	end
	if i2c_write_reg16(fd, REG_RANGE_CONFIG_A, math.floor(a / 256) % 256, a % 256) ~= 0 then
		return nil, "Failed to write range config A"
	end
	if i2c_write_reg16(fd, REG_RANGE_CONFIG_B, math.floor(b / 256) % 256, b % 256) ~= 0 then
		return nil, "Failed to write range config B"
	end
	return true
end

require_driver("i2c", {
	name = "VL53L4CD",

	-- 【配置脚本】软复位 -> 等固件 -> 默认配置流 -> VHV 预热 -> 时序 -> 启动
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- VL53L4CD builder func get a table --------", data)
		end

		local fd = ctx.fd

		local budget = int_or(data.budget, DEF_BUDGET, 10, 200)
		local inter = int_or(data.inter, DEF_INTER, 0, 2147483647)
		local timeout = int_or(data.timeout, DEF_TIMEOUT, 1, 10000)
		poll_timeout = timeout

		-----------------------------------------------------
		-- 软复位
		if i2c_write_reg16(fd, REG_SOFT_RESET, 0x00) ~= 0 then
			return err("Failed to reset VL53L4CD")
		end
		milli_sleep(1)
		if i2c_write_reg16(fd, REG_SOFT_RESET, 0x01) ~= 0 then
			return err("Failed to release VL53L4CD reset")
		end
		milli_sleep(5)

		-- 等固件启动
		local left = timeout
		while true do
			local boot = i2c_read_reg16(fd, REG_FIRMWARE_SYSTEM_STATUS, 1)
			if boot < 0 then
				return err("Failed to read firmware boot status")
			end
			if boot == 3 then break end
			if left <= 0 then
				return err(string.format("VL53L4CD firmware boot timeout (%dms, status=%d)", timeout, boot))
			end
			milli_sleep(1)
			left = left - 1
		end

		-- 默认配置流
		if i2c_write_reg16(fd, 0x002D, unpack(CONFIG_TABLE)) ~= 0 then
			return err("Failed to write default config")
		end

		-- VHV 预热测量
		if i2c_write_reg16(fd, REG_SYSTEM_START, 0x40) ~= 0 then
			return err("Failed to start VL53L4CD VHV")
		end
		local r = wait_ready(fd, timeout)
		if r == nil then
			return err("Failed to poll VL53L4CD data-ready")
		end
		if r == false then
			return err(string.format("VL53L4CD VHV measurement ready timeout (%dms)", timeout))
		end
		if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
			return err("Failed to clear VL53L4CD interrupt")
		end
		if i2c_write_reg16(fd, REG_SYSTEM_START, 0x00) ~= 0 then
			return err("Failed to stop VL53L4CD VHV")
		end

		-- VHV/OSC 配置收尾
		if i2c_write_reg16(fd, REG_VHV_LOOP_BOUND, 0x09) ~= 0 then
			return err("Failed to write VL53L4CD VHV config")
		end
		if i2c_write_reg16(fd, 0x000B, 0x00) ~= 0 then
			return err("Failed to write VL53L4CD 0x000B")
		end
		if i2c_write_reg16(fd, 0x0024, 0x05, 0x00) ~= 0 then
			return err("Failed to write VL53L4CD 0x0024")
		end

		-- 测量时序
		local ok, emsg = set_range_timing(fd, budget, inter)
		if not ok then
			return err(emsg)
		end

		-- 启动测距
		local startv = (inter == 0) and 0x21 or 0x40
		if i2c_write_reg16(fd, REG_SYSTEM_START, startv) ~= 0 then
			return err("Failed to start VL53L4CD ranging")
		end
		r = wait_ready(fd, timeout)
		if r == nil then
			return err("Failed to poll VL53L4CD data-ready")
		end
		if r == false then
			return err(string.format("VL53L4CD first measurement timeout (%dms)", timeout))
		end
		if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
			return err("Failed to clear VL53L4CD interrupt")
		end

		print(string.format("VL53L4CD init OK: addr=0x%02X, budget=%dms, %s",
			ctx.addr, budget, inter == 0 and "continuous" or ("autonomous, inter=" .. inter .. "ms")))
		return {  result = "OK"  }
	end,

	-- 【销毁VL53L4CD】停止测距（缺 fd/addr 安全跳过）
	destroy = function(ctx, data)
		local fd = tonumber(data.fd)
		local addr = tonumber(data.address)
		if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
			i2c_write_reg16(fd, REG_SYSTEM_START, 0x00)
		end
		return {  result = "OK"  }
	end,

	-- 【调用VL53L4CD】等待本次测量就绪 -> 读结果 -> 清中断
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- VL53L4CD caller func get a table --------", data)
		end

		local fd = ctx.fd

		local r = wait_ready(fd, poll_timeout or DEF_TIMEOUT)
		if r == nil then
			return err("Failed to poll VL53L4CD data-ready")
		end
		if r == false then
			return err(string.format("VL53L4CD data-ready timeout (%dms)", poll_timeout or DEF_TIMEOUT))
		end

		local status_raw = i2c_read_reg16(fd, REG_RESULT_RANGE_STATUS, 1)
		local spad = i2c_read_reg16(fd, REG_RESULT_SPAD_NB, 2)
		local signal = i2c_read_reg16(fd, REG_RESULT_SIGNAL_RATE, 2)
		local ambient = i2c_read_reg16(fd, REG_RESULT_AMBIENT_RATE, 2)
		local sigma = i2c_read_reg16(fd, REG_RESULT_SIGMA, 2)
		local dist = i2c_read_reg16(fd, REG_RESULT_DISTANCE, 2)
		if status_raw < 0 or spad < 0 or signal < 0 or ambient < 0 or sigma < 0 or dist < 0 then
			return err("Failed to read VL53L4CD range results")
		end

		if i2c_write_reg16(fd, REG_SYSTEM_INTERRUPT_CLEAR, 0x01) ~= 0 then
			return err("Failed to clear VL53L4CD interrupt")
		end

		local st = status_raw % 32
		local mapped = 255
		if st < 24 then mapped = STATUS_RTN[st + 1] end
		local spad_nb = math.floor(spad / 256)
		if spad_nb == 0 then mapped = 255 end

		local ret = {
			result = "OK",
			DIST_MM = dist,
			STATUS = mapped,
			VALID = (mapped == 0) and 1 or 0,
			SPAD_NB = spad_nb,
			SIGNAL_KCPS = signal * 8,
			AMBIENT_KCPS = ambient * 8,
			SIGMA_MM = sigma / 4
		}

		if DEBUG then
			print(string.format("VL53L4CD: dist=%dmm status=%d signal=%dkcps ambient=%dkcps sigma=%.2fmm",
				ret.DIST_MM, ret.STATUS, ret.SIGNAL_KCPS, ret.AMBIENT_KCPS, ret.SIGMA_MM))
		end

		return ret
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】VL53L4CD_VIRT —— 2026-09-15 自 modules/lib/virtbus/vl53l4cd.lua
-- 整体迁入（单文件驱动+模型第十个，16 位指针族，守护 E2E 走 sensor_daemon
-- 回退路径）。约定同前九者：① 生产路径零执行（new() 仅虚拟总线测试调用，
-- regmap ptr16 底座延迟到 new() 内加载；转换时常量改名 VL53L4CD_CONV_MS、
-- 种子函数改名 vl53l4cd_seed_table 保文件级唯一）；② 工厂经全局表而非文件
-- return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径
-- 无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防
-- 假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【首个 16 位寄存器指针（regmap ptr16）真实器件】——与同系列
-- VL53L0X（8 位指针 + 0xFF 分页）刻意对照：VL53L4CD 寄存器窗直接用
-- 16 位地址线性寻址（0x0000~0x00FF），指针事务为 2 字节大端地址，
-- 多字节写按地址自增（91 字节默认配置流就是一笔 0x002D 起的流写）。
-- 底座用 regmap.new(init, {ptr16=true})，本段用包装法（链接原
-- write/read 后覆盖同表字段）加器件状态机，保留 regmap 全部能力。
--
-- 只复刻协议层事实（ST ULD vl53l4cd_api，以真实驱动 modules/VL53L4CD.lua
-- 的实际访问为准）：
--   1) 软复位：0x0000 写 0x00 保持 / 写 0x01 释放——释放后器件寄存器
--      回到上电种子（振荡器频率 0x0006=10000、PLL 校准 0x00DE=512、
--      固件状态 0x00E5=3），芯片侧状态全新（启动序列/清中断计数清零）。
--   2) data-ready 极性链：0x0030 bit4 决定有效极性 int_pol（bit4=1→0，
--      否则→1），0x0031 bit0 == int_pol 即就绪（驱动 check_data_ready）。
--      模型动态合成 0x0031 bit0（bit1 保留位读 1），极性随 0x0030 翻转
--      自动跟随；never_ready 钩子强制反极性电平。
--   3) 测量状态机：0x0087 写 0x40（VHV 预热/自主）或 0x21（连续）启动，
--      写 0x00 停；启动即预武装一帧（skill 惯例：守护不驱动 milli_sleep，
--      build 的 VHV/首测量自检首次轮询必须直接就绪）。0x0086=0x01 清中断：
--      运行态下解除武装并进入 5ms 转换倒计时，advance(ms) 虚拟时钟推进
--      （测试 milli_sleep 桩转调；连续两拍 call 之间自然走完倒计时）。
--   4) 结果块固定地址（各为独立原子读，非 burst）：0x0089 状态原始码
--      （&0x1F 查 STATUS_RTN）、0x008C SPAD word(/256)、0x008E 信号率
--      word(×8 kcps)、0x0090 环境光率、0x0092 sigma(/4 mm)、0x0096
--      距离 word（mm）。inject_result 按字节宽度写入，不抄驱动换算。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。
-- =====================================================================

VL53L4CD_VIRT = { _VERSION = "0.1.0" }

local VL53L4CD_CONV_MS = 5	-- 清中断到下一帧就绪的虚拟转换时间

-- 上电种子（释放软复位后同样回到这组值）
local function vl53l4cd_seed_table()
	return {
		[0x0006] = 0x27, [0x0007] = 0x10,	-- OSC_FREQUENCY word = 10000
		[0x00DE] = 0x02, [0x00DF] = 0x00,	-- OSC_CALIBRATE word = 512
		[0x00E5] = 0x03,					-- 固件就绪
	}
end

function VL53L4CD_VIRT.new()
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))
	local base = regmap.new(vl53l4cd_seed_table(), { ptr16 = true })

	-- 芯片侧状态
	local running = false		-- 0x0087 启动后处于测距态
	local armed = true			-- 上电/启动即有一帧（预武装）
	local countdown = 0			-- 清中断后的转换剩余 ms
	local start_log = {}		-- 写入 0x0087 的值序列（软复位清零）
	local clear_count = 0		-- 0x0086=0x01 次数（软复位清零）
	local boot_releases = 0		-- 0x0000=0x01 次数（累计，调试用）

	-- 故障钩子（reset 保留，clear_faults 解除）
	local read_pred, write_pred
	local never_ready, boot_stuck = false, false

	local self = {}
	-- 注意：浅拷贝后 self.nack 与底座 m.nack 是两个字段，外部置 d.nack
	-- 不会被 old_write 看到，故三个 nack 由包装层自持自判（底座恒不挂故障）。
	for k, v in pairs(base) do self[k] = v end
	self.nack, self.nack_read, self.nack_write = false, false, false
	local old_write, old_read = base.write, base.read

	-- 把一笔失败写也留进 regmap write_log（与 nack 路径先 log 后拒一致）
	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] end
		base.write_log[#base.write_log + 1] = cp
	end

	local function reseed(boot_value)
		-- 原地清空：包装表 d.regs 与底座共享同一表引用，不能换表
		-- （否则 d:set_word 走 self.regs 会写到复位前的旧表）
		for k in pairs(base.regs) do base.regs[k] = nil end
		for k, v in pairs(vl53l4cd_seed_table()) do base.regs[k] = v end
		base.ptr = 0
		if boot_value then base.regs[0x00E5] = boot_value end
		start_log = {}
		clear_count = 0
		running, armed, countdown = false, false, 0
	end

	-- ---- 总线写：包装层先判故障并留痕，通过后走 regmap（ptr16 存储） ----
	self.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if self.nack or self.nack_write or (write_pred and write_pred(bytes)) then
			log_copy(bytes)
			return false
		end
		local ok = old_write(bytes)
		if not ok then return false end

		if #bytes >= 3 then
			local p = (bytes[1] % 256) * 256 + (bytes[2] % 256)
			local v = bytes[3] % 256
			if p == 0x0000 then
				if v == 0x01 then
					-- 释放复位：芯片全新启动（固件状态看 stuck 钩子）
					boot_releases = boot_releases + 1
					reseed(boot_stuck and 0x00 or 0x03)
				end
				-- v==0x00 复位保持：无副作用（驱动只要求写成功）
			elseif p == 0x0087 then
				start_log[#start_log + 1] = v
				if v == 0x40 or v == 0x21 then
					-- 启动：预武装一帧（build 自检/守护首次轮询即就绪）
					running, armed, countdown = true, true, 0
				elseif v == 0x00 then
					running, armed, countdown = false, false, 0
				end
			elseif p == 0x0086 and v == 0x01 then
				clear_count = clear_count + 1
				-- 结果寄存器锁存到下一次清中断；运行态重新走转换倒计时
				if running then armed, countdown = false, VL53L4CD_CONV_MS end
			end
		end
		return true
	end

	-- ---- 总线读：包装层先判故障，通过后走 regmap（ptr16 burst）+合成就绪位 ----
	self.read = function(n)
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end
		local p0 = base.ptr	-- old_read 会推进指针，先存首地址
		if self.nack or self.nack_read or (read_pred and read_pred(p0, n)) then
			return nil
		end
		local t = old_read(n)
		if t and p0 == 0x0031 then
			local mux = base.regs[0x0030] or 0
			local int_pol = (math.floor(mux / 16) % 2 == 1) and 0 or 1
			local lvl = (armed and not never_ready) and int_pol or (1 - int_pol)
			t[1] = 0x02 + lvl	-- bit1 保留位读 1，bit0 为合成就绪电平
		end
		return t
	end

	-- ---- 虚拟时钟：推进转换倒计时 ----
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if running and not armed and not never_ready then
			countdown = countdown - ms
			if countdown <= 0 then armed = true end
		end
		return self
	end

	-- ---- 结果块注入（固定地址，字节宽度编码；换算不进模型） ----
	function self:inject_result(t)
		t = t or {}
		base:set(0x0089, t.st or 0x09)						-- 原始状态码
		self:set_word(0x008C, t.spad or 0x0200)				-- word /256 = SPAD 数
		self:set_word(0x008E, t.signal or 0x0064)			-- word ×8 = kcps
		self:set_word(0x0090, t.ambient or 0x0032)
		self:set_word(0x0092, t.sigma or 0x0008)			-- word /4 = mm
		self:set_word(0x0096, t.dist or 300)				-- word mm
		return self
	end

	-- ---- 守护造样本：32 拍确定性正弦 100~1100mm，预武装触发即就绪 ----
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local dist = 100 + math.floor((math.sin(2 * math.pi * n / 32) * 0.5 + 0.5) * 1000 + 0.5)
		self:inject_result({ st = 0x09, spad = 0x0200, signal = 0x0064,
			ambient = 0x0032, sigma = 0x0008, dist = dist })
		if running then armed, countdown = true, 0 end
		return self
	end

	-- ---- 状态/留痕访问 ----
	function self:running() return running end
	function self:armed() return armed end
	function self:start_writes() return start_log end
	function self:clear_count() return clear_count end
	function self:boot_releases() return boot_releases end

	-- ---- 故障钩子 ----
	function self:fail_read(pred) read_pred = pred; return self end
	function self:fail_write(pred) write_pred = pred; return self end
	function self:set_never_ready(on) never_ready = on and true or false; return self end
	function self:set_boot_stuck(on)
		boot_stuck = on and true or false
		base.regs[0x00E5] = boot_stuck and 0x00 or 0x03
		return self
	end
	-- 直接置固件状态值（异常构造，如停在 1/2）
	function self:set_boot_status(v) base.regs[0x00E5] = math.floor(v) % 256; return self end

	function self:clear_faults()
		self.nack, self.nack_read, self.nack_write = false, false, false
		read_pred, write_pred = nil, nil
		never_ready, boot_stuck = false, false
		return self
	end

	function self:reset_logs()
		base:clear_log()
		return self
	end

	-- 换新器件：寄存器/状态/日志全清；故障钩子保留（ads1256/vl53l0x 惯例）
	function self:reset()
		base:clear_log()
		reseed(boot_stuck and 0x00 or 0x03)
		return self
	end

	return self
end

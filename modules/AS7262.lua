-- AS7262 六通道可见光光谱传感器 驱动模块（ams，I2C 地址 0x49）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 AS7262_VIRT（2026-09-15 自 modules/lib/virtbus/as7262.lua
-- 迁入，单文件驱动+模型实验第三十五个，间接窗口 + 握手族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 【单消费者声明】间接寄存器访问的**地址相位存在器件侧**：读一个虚拟寄存器要
-- poll HW_STATUS → 写 HW_WRITE=vaddr → poll TX 就绪 → 读 HW_READ，跨 3~4 个
-- 独立 I2C 事务。第二个消费者（如 @Daemon 同址采样）插进来就会改掉地址相位，
-- 双方各自读到对方的寄存器，且都看不出被踩。HAL 的单事务原子性（I2C_RDWR 把
-- 指针写与数据读合并）在这里帮不上忙——原子单位是「一个事务」，而本驱动的
-- 一次访问跨多个事务。装配期据此按 (总线路径, 地址) 判重，
-- 见 src/hw_factory.cpp 的 checkSingleConsumer。
-- 标记必须写在**行首**（宿主是纯文本扫描、不执行 Lua）；值只是给人看的原因。
SINGLE_CONSUMER = "间接窗口 + 握手：地址相位在器件侧，一次访问跨多个 I2C 事务"
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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
-- （实现收敛至 drv_common.int_of，N-24）

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

require_driver("i2c", {
	name = "AS7262",

	-- 【配置脚本】软复位 -> 器件甄别 -> 积分/增益/模式 2
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- AS7262 builder func get a table --------", data)
		end

		local fd = ctx.fd

		-- 配置列
		local gain = gain_code_of(data.gain)
		local integ = int_or(data.integ, DEF_INTEG, 0, 255)
		local to = finite_of(data.timeout)
		if to == nil or to < 1 then
			to = math.floor(integ * 11.2) + 500
		end
		poll_timeout = math.floor(to)

		-----------------------------------------------------
		-- 软复位（RST 位，自清除；SparkFun 同款等 1s 不轮询启动）
		local ctl = virtual_read(fd, V_CONTROL_SETUP)
		if ctl == nil then
			return err("Failed to read AS7262 CONTROL_SETUP")
		end
		if virtual_write(fd, V_CONTROL_SETUP, bitc.bor(ctl % 256, BIT_RST)) == nil then
			return err("Failed to reset AS7262")
		end
		milli_sleep(T_RESET_MS)

		-- 器件甄别（虚拟寄存器 0x00 = 0x3E）
		local dtype = virtual_read(fd, V_DEVICE_TYPE)
		if dtype == nil then
			return err("Failed to read AS7262 device type")
		end
		if dtype ~= DEV_TYPE_AS7262 then
			return err(string.format("Device type = 0x%02X (expect 0x3E AS7262, not AS7262?)", dtype))
		end

		-- 积分时间
		if virtual_write(fd, V_INT_T, integ) == nil then
			return err("Failed to write AS7262 integration time")
		end

		-- 增益（[5:4]）与模式 2 连续全通道（[3:2]），读-改-写合并一次
		ctl = virtual_read(fd, V_CONTROL_SETUP)
		if ctl == nil then
			return err("Failed to read AS7262 CONTROL_SETUP")
		end
		local v = bitc.band(ctl % 256, bitc.band(MASK_GAIN, MASK_BANK))
		v = bitc.bor(v, bitc.bor(bitc.lshift(gain, 4), bitc.lshift(BANK_ALL_CONT, 2)))
		if virtual_write(fd, V_CONTROL_SETUP, v) == nil then
			return err("Failed to write AS7262 gain/mode")
		end

		print(string.format("AS7262 init OK: addr=0x%02X, gain=%dx, integ=%d (每轮约%.0fms), timeout=%dms",
			ctx.addr, GAIN_TAB[gain + 1][1], integ, integ * 2.8 * 2, poll_timeout))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 AS7262 destroy 仅 arg_table + return OK，等价）

	-- 【调用AS7262】等 DATA_RDY -> 读六通道 + 温度 -> 清 DATA_RDY
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- AS7262 caller func get a table --------", data)
		end

		local fd = ctx.fd

		-----------------------------------------------------
		-- 等 DATA_RDY（连续模式自动转换）
		local left = poll_timeout or 1000
		while true do
			local ctl = virtual_read(fd, V_CONTROL_SETUP)
			if ctl == nil then
				return err("Failed to poll AS7262 data-ready")
			end
			if bitc.band(ctl % 256, BIT_DATA_RDY) ~= 0 then break end
			if left <= 0 then
				return err(string.format("AS7262 data-ready timeout (%dms)", poll_timeout or 1000))
			end
			milli_sleep(POLL_MS)
			left = left - POLL_MS
		end

		-- 读六通道
		local vals = {}
		for _, ch in ipairs(CHANS) do
			local v = read_channel(fd, ch[2])
			if v == nil then
				return err("Failed to read AS7262 channel " .. ch[1])
			end
			vals[ch[1]] = v
		end

		-- 片上温度（二进制补码）
		local tb = virtual_read(fd, V_DEVICE_TEMP)
		if tb == nil or tb < 0 then
			return err("Failed to read AS7262 temperature")
		end
		local temp_c = bitc.s8(tb)

		-- 清 DATA_RDY（SparkFun 同款 RMW 清位；连续模式下芯片随即开始下一轮）
		local ctl = virtual_read(fd, V_CONTROL_SETUP)
		if ctl == nil then
			return err("Failed to read AS7262 CONTROL_SETUP")
		end
		if virtual_write(fd, V_CONTROL_SETUP, bitc.band(ctl % 256, bitc.bxor(BIT_DATA_RDY, 0xFF))) == nil then
			return err("Failed to clear AS7262 data-ready")
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
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】AS7262_VIRT —— 2026-09-15 自 modules/lib/virtbus/as7262.lua
-- 整体迁入（单文件驱动+模型第三十五个，虚拟寄存器间接窗口 + TX/RX 握手族，
-- 守护 E2E 走 sensor_daemon 回退路径）。约定同前三十四者：① 生产路径零执行
-- （new() 仅虚拟总线测试调用，纯闭包零外部依赖；硬件/虚拟寄存器表/TICK 波形
-- /helper 全部移入 new() 内避让；new() 内 `local M = AS7262_VIRT` 绑定使模型
-- 体零改动移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【首个「硬件仅 3 寄存器 + 虚拟寄存器间接窗口 + TX/RX 就绪握手」
-- I2C 器件】（ams AS7262，地址 0x49；纯闭包、纯算术无 bitcompat）。I2C 总线
-- 上只能看到 3 个硬件寄存器：STATUS 0x00（bit1=TX_VALID 写口忙、
-- bit0=RX_VALID 读口有数据）、写口 WRITE 0x01、读口 READ 0x02；DEVICE_TYPE/
-- CONTROL/INT_T/六通道等全部虚拟寄存器（0x00~0x13）都不能直接寻址，必须走
-- SparkFun 同款握手时序（真实驱动 modules/AS7262.lua 同款）：
--   读虚拟 = 预冲刷滞留 RX -> 等 STATUS.TX=0 -> 写口发地址(bit7=0)
--           -> 等 STATUS.RX=1 -> 读读口；
--   写虚拟 = 等 STATUS.TX=0 -> 写口发 地址|0x80 -> 再等 TX=0 -> 写口发数据。
--
-- 协议层事实（AS7262 datasheet / SparkFun AS726X，以真实驱动访问为准）：
--   1) 零延迟握手：TX_VALID 正常恒读 0（驱动 5ms 步进轮询第一次即通过）、
--      读命令锁存后 RX_VALID 立即置 1、读口消费后清 0；tx_stuck/rx_stuck
--      分别喂驱动两段 250ms 握手超时。
--   2) 写口字节按状态机位置解释，不按 bit7 区分命令/数据（数据可 >=0x80）。
--   3) 虚拟寄存器：0x00 DEVICE_TYPE=0x3E、0x04 CONTROL_SETUP（bit7=RST
--      自清、[5:4]=GAIN、[3:2]=BANK、bit1=DATA_RDY 读时动态合成）、
--      0x05 INT_T（2.8ms/单位）、0x06 DEVICE_TEMP、六通道 MSB 偶地址
--      V 0x08/B 0x0A/G 0x0C/Y 0x0E/O 0x10/R 0x12。POR：TYPE=0x3E、
--      CONTROL=0x08、INT_T=0x00、TEMP=24、通道全 0。
--   4) 连续全通道（BANK=2）一轮 = 2×INT_T×2.8ms，完成置 DATA_RDY 并锁存
--      六通道；通道数据寄存器只由转换完成事件/virt_tick 改变，set_result
--      只入注入表不提前同步。
--   5) 守护零睡眠：virt_tick(n) 直接装六通道+温度并置 DATA_RDY（预武装），
--      call 首次轮询即就绪；build 含 RST 后 1000ms 硬睡，E2E 首行预热须容纳。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

AS7262_VIRT = { _VERSION = "0.1.0" }

function AS7262_VIRT.new()
-- ==================== 硬件寄存器（I2C 直接可见） ====================
local HW_STATUS, HW_WRITE, HW_READ = 0x00, 0x01, 0x02
local F_TX_VALID, F_RX_VALID = 0x02, 0x01

-- ==================== 虚拟寄存器 ====================
local V_DEVICE_TYPE   = 0x00	-- 0x3E=AS7262 / 0x3D=AS7261 / 0x3F=AS7263
local V_CONTROL_SETUP = 0x04	-- bit7=RST [5:4]=GAIN [3:2]=BANK bit1=DATA_RDY
local V_INT_T         = 0x05
local V_DEVICE_TEMP   = 0x06

local NAMES = { "V", "B", "G", "Y", "O", "R" }
local CHAN_ADDR = { V = 0x08, B = 0x0A, G = 0x0C, Y = 0x0E, O = 0x10, R = 0x12 }

local DEV_TYPE_AS7262 = 0x3E
local BIT_RST, BIT_DATA_RDY = 0x80, 0x02

-- virt_tick 六通道确定性正弦基线/幅值（计数，0~65535 量程内）
local TICK_BASE = { 9000, 14000, 22000, 26000, 19000, 11000 }
local TICK_AMP  = { 3000, 4000, 6000, 5000, 4500, 3500 }

local function clamp_u16(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end

-- 通道名/序号 -> {地址, 名字}
local function ch_resolve(ch)
	if type(ch) == "string" then
		local name = ch:upper()
		local addr = CHAN_ADDR[name]
		if addr then return addr, name end
		return nil
	end
	local i = tonumber(ch)
	if i and i == math.floor(i) and i >= 1 and i <= 6 then
		return 0x08 + (i - 1) * 2, NAMES[i]
	end
	return nil
end

	local M = AS7262_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	local d = {}

	-- 芯片侧状态
	local vregs = {}			-- 虚拟寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil			-- 最近一笔硬件指针写（0x00/0x01/0x02）
	local rx_addr = nil			-- 读口待取的虚拟地址（nil=RX_VALID=0）
	local wstate = nil			-- nil | "data"（写口等数据相位）
	local waddr = nil
	local data_rdy = false		-- CONTROL bit1（只读状态，读时合成）
	local remaining = nil		-- 连续模式距下一轮完成的 ms
	local results = {}			-- 六通道待转换注入值（完成事件才进 vregs）
	local dev_type = DEV_TYPE_AS7262

	-- 计数/日志
	local vread_cmds = 0		-- 写口收到的读地址命令次数
	local vwrite_cmds = 0		-- 完成的虚拟寄存器写次数
	local reset_count = 0		-- RST 位软复位次数

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_ready = false	-- DATA_RDY 永不置位（advance/武装均无效）
	local tx_stuck = false		-- STATUS.TX_VALID 恒 1（等 TX 空超时）
	local rx_stuck = false		-- 读命令不置 RX（等 RX 有效超时）

	-- ---------------- 上电种子 / 复位 ----------------

	local function seed_vregs()
		vregs = {}
		vregs[0x00] = dev_type
		vregs[0x01] = 0x40			-- HW version 占位（驱动不读）
		vregs[0x04] = 0x08			-- BANK=2 连续全通道、GAIN=0(1x)、RDY=0
		vregs[0x05] = 0x00			-- INT_T POR=0（build 写缺省 50）
		vregs[0x06] = 24			-- 片上温度占位
		vregs[0x07] = 0x00
		for a = 0x08, 0x13 do vregs[a] = 0 end
	end

	local function chip_state_clear()
		read_ptr = nil
		rx_addr, wstate, waddr = nil, nil, nil
		data_rdy, remaining = false, nil
	end

	-- RST 位/软复位：寄存器回 POR、清芯片侧握手与转换态；
	-- 外部注入（results）与故障钩子保留（复位不清激励、防负路径假解除）
	local function reseed()
		seed_vregs()
		chip_state_clear()
		-- 上电即连续全通道运转，排第一轮（INT_T=0 时周期 0，advance 即完成）
		remaining = 0
	end

	seed_vregs()
	remaining = 0

	-- ---------------- 派生/合成 ----------------

	local function gain_of()		return math.floor(vregs[V_CONTROL_SETUP] / 0x10) % 4 end
	local function bank_of()		return math.floor(vregs[V_CONTROL_SETUP] / 0x04) % 4 end
	local function cycle_ms()		return (vregs[V_INT_T] or 0) * 5.6 end	-- 2×2.8ms

	-- CONTROL 读回：配置影子 + DATA_RDY 动态合成（RST 位永不落盘）。
	-- 影子的 bit1/bit7 由写入侧保证恒 0（只读位/自清除位不入库），直接加成就位；
	-- 不能用 shadow % 0xFD 一类取模清位——0xFD 非 2 的幂，取模不等于按位与。
	local function control_read()
		return vregs[V_CONTROL_SETUP] + (data_rdy and BIT_DATA_RDY or 0)
	end

	local function read_vreg(a)
		if a == V_CONTROL_SETUP then return control_read() end
		return vregs[a] or 0
	end

	local function status_byte()
		return (rx_addr ~= nil and F_RX_VALID or 0)
		     + (tx_stuck and F_TX_VALID or 0)
	end

	-- 一轮转换完成：锁存注入结果到通道数据寄存器、置 DATA_RDY；
	-- 下一轮等驱动 RMW 清 DATA_RDY 后再排（连续模式时序确定）
	local function finish_cycle()
		if never_ready then return end
		for i = 1, 6 do
			local raw = results[NAMES[i]] or 0
			local a = 0x08 + (i - 1) * 2
			vregs[a] = math.floor(raw / 256) % 256
			vregs[a + 1] = raw % 256
		end
		data_rdy, remaining = true, nil
	end

	-- ---------------- 虚拟寄存器写副作用 ----------------

	local function write_vreg(addr, val)
		vwrite_cmds = vwrite_cmds + 1
		val = val % 256
		if addr == V_CONTROL_SETUP then
			if math.floor(val / 0x80) % 2 == 1 then
				-- bit7=RST：软复位，自清除不落盘
				reseed()
				reset_count = reset_count + 1
				return
			end
			-- DATA_RDY 只读：bit1 写 0 清除（写 1 无效，保持原状态）
			local rdy_written = math.floor(val / 2) % 2 == 1
			if not rdy_written then
				data_rdy = false
			end
			-- 落配置位：bit7(RST) 已在上方分支返回；只读 bit1(DATA_RDY) 用减法
			-- 剔除后再入影子。严禁 val % 0x7D——0x7D 非 2 的幂，取模不清位，
			-- 会让驱动 RMW 写回的就绪位残留（读回再加成就位会进位出错）。
			local cfg = val
			if rdy_written then cfg = cfg - 0x02 end
			vregs[V_CONTROL_SETUP] = cfg
			-- 连续全通道：清位后芯片随即开始下一轮；其他 BANK 暂停转换
			if bank_of() == 0x02 then
				if not data_rdy and remaining == nil then remaining = cycle_ms() end
			else
				remaining = nil
			end
			return
		end
		vregs[addr] = val
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		if #bytes == 1 then
			-- 纯硬件寄存器指针写（i2c_read_reg 的指针相位）
			if bytes[1] > HW_READ then return false end
			read_ptr = bytes[1]
			return true
		end
		if #bytes ~= 2 then return false end
		if write_pred and write_pred(bytes) then return false end
		local reg, val = bytes[1], bytes[2]
		if reg ~= HW_WRITE then
			-- STATUS/READ 只读；0x03+ 硬件地址不存在
			return false
		end
		if wstate == "data" then
			-- 数据相位：字节按位置解释（即使 >=0x80，如 RST 0x88）
			wstate = nil
			write_vreg(waddr, val)
		elseif val >= 0x80 then
			-- 写地址相位（bit7=1），芯片锁存后瞬时就绪（TX 不置忙）
			waddr, wstate = val - 0x80, "data"
		else
			-- 读地址相位（bit7=0）：RX 瞬时有效；rx_stuck 时芯片不应答数据
			vread_cmds = vread_cmds + 1
			if not rx_stuck then rx_addr = val end
		end
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = tonumber(n) or 1
		n = math.floor(n)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		local b
		if read_ptr == HW_STATUS then
			b = status_byte()
		elseif read_ptr == HW_READ then
			if rx_addr ~= nil then
				b = read_vreg(rx_addr)
				rx_addr = nil			-- 读口消费，RX_VALID 清 0
			else
				b = 0				-- 空读（协议上驱动不会在此刻读）
			end
		else
			return nil				-- 无指针/写口 0x01 不可读
		end
		local t = { b }
		for i = 2, n do t[i] = 0 end
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil and bank_of() == 0x02 and not never_ready then
			remaining = remaining - ms
			if remaining <= 0 then finish_cycle() end
		end
		return self
	end

	-- 注入下一轮转换结果（16 位无符号计数；只入注入表，完成事件才进数据寄存器）
	function d:set_result(ch, raw)
		local _, name = ch_resolve(ch)
		if name then results[name] = clamp_u16(raw) end
		return self
	end

	function d:set_results(t)
		if type(t) == "table" then
			for k, v in pairs(t) do self:set_result(k, v) end
		end
		return self
	end

	-- 直接写通道数据寄存器（静态读回/模型事实用，绕过转换事件）
	function d:set_channel_raw(ch, raw)
		local addr = ch_resolve(ch)
		if addr then
			raw = clamp_u16(raw)
			vregs[addr] = math.floor(raw / 256) % 256
			vregs[addr + 1] = raw % 256
		end
		return self
	end

	-- 片上温度（有符号补码 °C，-128~127）
	function d:set_temp(c)
		c = math.floor(tonumber(c) or 0)
		if c < -128 then c = -128 elseif c > 127 then c = 127 end
		vregs[V_DEVICE_TEMP] = c < 0 and c + 256 or c
		return self
	end

	function d:set_device_type(t)
		t = math.floor(tonumber(t) or DEV_TYPE_AS7262) % 256
		dev_type = t
		vregs[V_DEVICE_TYPE] = t
		return self
	end

	-- DATA_RDY 永不置位（喂 call 就绪超时；advance 不推、virt_tick 不武装）
	function d:set_never_ready(on) never_ready = on ~= false; return self end
	-- 握手卡死：TX 恒忙（等 TX 空超时）/读命令不置 RX（等 RX 有效超时）
	function d:set_tx_stuck(on) tx_stuck = on ~= false; return self end
	function d:set_rx_stuck(on) rx_stuck = on ~= false; return self end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_ready, tx_stuck, rx_stuck = false, false, false
		return self
	end

	function d:reset_logs()
		vread_cmds, vwrite_cmds = 0, 0
		return self
	end

	-- 重新上电：全状态回 POR、注入/计数清空；故障钩子保留
	function d:reset()
		dev_type = DEV_TYPE_AS7262
		results = {}
		seed_vregs()
		chip_state_clear()
		remaining = 0
		vread_cmds, vwrite_cmds, reset_count = 0, 0, 0
		return self
	end

	-- 守护逐拍造数：确定性六通道光谱正弦 + 温度，并预武装（直接置
	-- DATA_RDY 且把样本锁入数据寄存器——守护不驱动 advance，call 首读
	-- CONTROL 即就绪、随后读到本拍值；never_ready 时武装失效）
	function d:virt_tick(n)
		local ph = 2 * math.pi * ((tonumber(n) or 0) % 32) / 32
		for i = 1, 6 do
			local raw = TICK_BASE[i] + TICK_AMP[i] * math.sin(ph + (i - 1) * math.pi / 6)
			raw = clamp_u16(raw)
			results[NAMES[i]] = raw
			local a = 0x08 + (i - 1) * 2
			vregs[a] = math.floor(raw / 256) % 256
			vregs[a + 1] = raw % 256
		end
		self:set_temp(math.floor(25 + 4 * math.sin(ph) + 0.5))
		if not never_ready then
			data_rdy, remaining = true, nil
		end
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:status() return status_byte() end
	function d:vreg(a) return read_vreg(math.floor(tonumber(a) or 0)) end
	function d:vreg_shadow(a) return vregs[math.floor(tonumber(a) or 0)] end
	function d:control() return control_read() end
	function d:control_shadow() return vregs[V_CONTROL_SETUP] end
	function d:int_t() return vregs[V_INT_T] or 0 end
	function d:gain() return gain_of() end
	function d:bank() return bank_of() end
	function d:data_ready() return data_rdy end
	function d:remaining_ms() return remaining end
	function d:cycle_ms() return cycle_ms() end
	function d:reset_count() return reset_count end
	function d:vread_count() return vread_cmds end
	function d:vwrite_count() return vwrite_cmds end
	function d:rx_pending() return rx_addr end
	function d:write_pending() return wstate == "data" and waddr or nil end
	function d:device_type() return vregs[V_DEVICE_TYPE] end

	function d:temp_c()
		local b = vregs[V_DEVICE_TEMP] or 0
		return b >= 128 and b - 256 or b
	end

	function d:channel(ch)
		local addr = ch_resolve(ch)
		if not addr then return nil end
		return (vregs[addr] or 0) * 256 + (vregs[addr + 1] or 0)
	end

	function d:result(ch)
		local _, name = ch_resolve(ch)
		return name and results[name] or nil
	end

	return d
end

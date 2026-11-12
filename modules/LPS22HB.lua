-- LPS22HB 高精度气压计 驱动模块（I2C，ST MEMS）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 LPS22HB_VIRT（2026-09-15 自 modules/lib/virtbus/lps22hb.lua
-- 迁入，单文件驱动+模型实验第四十个，7 位地址 + 命令位自清族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- 260~1260 hPa 绝对气压，24 位气压 + 16 位温度输出，片内温补。
-- 本驱动用单次（one-shot）模式：call 触发一次转换并等待完成，低功耗且
-- 每次读到的是新鲜样本（机器人的低频气压轮询/海拔测量场景）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE LPS22HB (
--       name    String,
--       I2C     String,
--       address String,
--       wait    String    -- 单次转换超时 ms（默认 50，转换约 3ms）
--   );
--   INSERT INTO LPS22HB (name, I2C, address, wait) VALUES ('baro-0', 'i2c-1', '0x5D', '-');
-- 地址 0x5D（SA0 接高）或 0x5C（SA0 接地）；一条总线两颗（SA0 各异）。
--
-- call 返回 { result, P(hPa), T(°C) }，换算（数据手册）：
--   P = 24 位原始值 / 4096；T = 16 位原始值 / 100
-- 接 sensor_daemon：fields=P|T（浮点，勿配 sign），interval >= wait。
--
-- 实现要点（寄存器语义经 Adafruit_LPS2X 库全源核对，内核 st_pressure 家族
-- 驱动同源互证）：
--   1. WHO_AM_I（0x0F）= 0xB1（LPS25HB 为 0xBD，插错代际在此拦下）
--   2. 多字节读须带自动增量位：0x28|0x80 起 5 字节（3 气压 + 2 温度，
--      小端）；HAL 合并读 5 字节在 2^40 内，精度无虞
--   3. CTRL_REG1（0x10）= BDU（bit1）+ ODR=000（单次/power-down）；
--      BDU 置位保证输出寄存器读期间不被刷新撕裂
--   4. 单次转换：CTRL_REG2（0x11）bit0 硬件自清零，轮询其为完成标志
--   5. 补码：气压 24 位（负值减 0x1000000）、温度 16 位
--      （Adafruit 实现减 0xFFFFFF 少 1，本驱动按标准补码修正）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：气压计低频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_WHOAMI   = 0x0F
local REG_CTRL1    = 0x10		-- [6:4]ODR [3]EN_LPFP [2]LPFP_CFG [1]BDU [0]SIM
local REG_CTRL2    = 0x11		-- [7]BOOT [4]FIFO_EN [2]SWRESET [1?] [0]ONE_SHOT
local REG_PRESS    = 0xA8		-- 0x28|0x80（自动增量）起 5 字节

local CHIP_ID      = 0xB1
local CTRL1_VALUE  = 0x02		-- BDU 置位，ODR=000（单次模式）
local BIT_SWRESET  = 0x04
local BIT_ONESHOT  = 0x01

local wait_default = 50

-- ==================== 模块级配置 ====================
local cfg_wait

require_driver("i2c", {
	name = "LPS22HB",

	-- ==================== 配置脚本 ====================
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- LPS22HB builder func get a table --------", data)
		end

		-- WHO_AM_I 自检
		local id = i2c_read_reg(fd, REG_WHOAMI)
		if id < 0 then
			return err("LPS22HB not responding (read WHO_AM_I failed, check address 0x5C/0x5D and wiring)")
		end
		if id ~= CHIP_ID then
			return err(string.format("LPS22HB unexpected WHO_AM_I 0x%02X (expect 0xB1; 0xBD=LPS25HB)", id))
		end

		-- 软复位（SWRESET 自清零），轮询至完成
		if not i2c_write_reg(fd, REG_CTRL2, BIT_SWRESET) then
			return err("LPS22HB not responding (soft reset write failed)")
		end
		local waited = 0
		while waited < 20 do
			local c2 = i2c_read_reg(fd, REG_CTRL2)
			if c2 < 0 then
				return err("LPS22HB not responding (reset poll failed)")
			end
			if math.floor(c2 / 4) % 2 == 0 then break end
			milli_sleep(1)
			waited = waited + 1
		end

		-- 单次模式 + BDU（输出寄存器读期间不刷新，防撕裂）
		if not i2c_write_reg(fd, REG_CTRL1, CTRL1_VALUE) then
			return err("LPS22HB not responding (CTRL_REG1 write failed)")
		end

		-- 审计 2026-09-20（中）：非有限入参必须回落缺省——`wait < 0` 对 NaN/inf 恒假，
		-- NaN 会一路带到下方 `waited >= wait_ms` 的轮询条件（恒假）→ 无界轮询挂死。
		local wait = finite_of(data.wait)
		if wait == nil or wait < 0 then wait = wait_default end
		cfg_wait = math.floor(wait)

		print(string.format("LPS22HB init OK: addr=0x%02X id=0xB1 mode=oneshot wait=%dms", addr, cfg_wait))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 LPS22HB destroy 仅 arg_table + return OK，等价）

	-- ==================== 调用 ====================
	-- 触发单次转换 -> 轮询完成 -> 5 字节突发读 -> 换算 P/T
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- LPS22HB caller func get a table --------", data)
		end

		-- 审计 2026-09-20（中）：同 build —— NaN/inf 会让下方转换完成轮询无界挂死。
		local wait_ms = finite_of(data.wait)
		if wait_ms == nil then wait_ms = cfg_wait or wait_default end
		if wait_ms < 0 then wait_ms = 0 end

		-- 触发单次转换（读改写保留其余位；ONE_SHOT 硬件自清零）
		local c2 = i2c_read_reg(fd, REG_CTRL2)
		if c2 < 0 then
			return err("LPS22HB not responding (read CTRL_REG2 failed)")
		end
		if not i2c_write_reg(fd, REG_CTRL2, c2 - c2 % 2 + BIT_ONESHOT) then
			return err("LPS22HB not responding (trigger write failed)")
		end

		-- 轮询 ONE_SHOT 位清零（转换完成）
		local waited = 0
		while true do
			local v = i2c_read_reg(fd, REG_CTRL2)
			if v < 0 then
				return err("LPS22HB not responding (poll failed)")
			end
			if v % 2 == 0 then break end
			if waited >= wait_ms then
				return err("LPS22HB conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)")
			end
			milli_sleep(1)
			waited = waited + 1
		end

		-- 5 字节突发读：气压 24 位（小端）+ 温度 16 位（小端）
		local v = i2c_read_multi(fd, REG_PRESS, 5)
		if v < 0 then
			return err("LPS22HB not responding (read data failed)")
		end
		local b = {}
		for i = 0, 4 do b[i + 1] = math.floor(v / 256 ^ (4 - i)) % 256 end
		local pres = b[1] + b[2] * 256 + b[3] * 65536
		if pres >= 0x800000 then pres = pres - 0x1000000 end		-- 24 位补码
		local temp = b[4] + b[5] * 256
		temp = bitc.s16(temp)			-- 16 位补码

		return {
			result = "OK",
			P = pres / 4096.0,
			T = temp / 100.0
		}
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】LPS22HB_VIRT —— 2026-09-15 自 modules/lib/virtbus/lps22hb.lua
-- 整体迁入（单文件驱动+模型第四十个，7 位地址空间 + 地址 bit7 自增 + 命令位
-- 自清族，守护 E2E 走 sensor_daemon 回退路径）。约定同前三十九者：① 生产
-- 路径零执行（new() 仅虚拟总线测试调用；regmap 底座延迟到 new() 内加载——
-- 与驱动共享 regmap.lua 单一实现，lps22hb/regmap 命名空间本就一致，无需
-- 改名避让；new() 内 `local lps22hb = LPS22HB_VIRT` 绑定使模型体零改动
-- 移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：ST LPS22HB 高精度气压/温度传感器（0x5D 缺省/0x5C 备选，与
-- mpu6050/adxl345 同为 regmap.new 底座薄包装，但五处个性必须照实）：
--   ① **地址是 7 位空间**——指针 bytes[1]%128、地址 **bit7=本次访问自动
--      增量位**（驱动 5B burst 发 0xA8=0x28|0x80），读回绕模 128；另有
--      CTRL_REG2 bit3 全局 IF_ADD_INC，两者 OR 决定 burst 是否自增；
--   ② **数据区小端 5B**——0x28 起 XL,L,H 气压 24 位补码 + L,H 温度 16 位
--      补码（LSB 在低地址，另有 set_word24_le/get_sword24_le/set_word_le/
--      get_word_le/get_sword_le，底座 set_word 是大端）；
--   ③ CTRL_REG2(0x11) **三个自清零命令位**——bit7 BOOT 即时自清仅
--      boot_count++、bit2 SWRESET 进 2ms 复位门（门内读回动态合成 bit2=1、
--      结束 reseed_body 回 POR，驱动 1ms×20 轮询耗尽也不致命）、bit0
--      ONE_SHOT 仅 idle（ODR=000）模式启动 3ms 转换门（连续模式写它自清
--      无效），**真正落盘位仅 bit4 FIFO_EN/bit3 IF_ADD_INC，用纯算术
--      (floor(val/16)%2)*16+(floor(val/8)%2)*8 保留**；
--   ④ STATUS(0x27) **动态合成** bit0 P_DA/bit1 T_DA，转换完成置双 DA、
--      读 PRESS_H(0x2A) 清 P_DA、读 TEMP_H(0x2C) 清 T_DA（MSB 读清除）；
--   ⑤ CTRL_REG1(0x10) [6:4] ODR 非 0 进连续模式——码 1..5 周期
--      1000/100/40/20/(40/3)ms（1/10/25/50/75Hz）由 advance(ms) 按周期
--      load_sample，码 6/7 保留 odr_hz 返 nil 不臆断，码 0=power-down/单次。
--   寄存器仅播种 WHO_AM_I=**0xB1**（0xBD=LPS25HB 代际参照，who() 可覆写
--   喂错挂），CTRL_REG1/2 与输出区不播种读 0；只读白名单（0x0F/0x27/
--   0x28~0x2C）≥2B 写 ACK 但丢弃，1B 纯指针写任意地址 ACK 设 ptr。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

LPS22HB_VIRT = { _VERSION = "0.1.0" }

local lps22hb = LPS22HB_VIRT

lps22hb.I2C_ADDR     = 0x5D	-- 缺省（SA0 接高）
lps22hb.I2C_ADDR_ALT = 0x5C	-- 备选（SA0 接地）

-- 寄存器地址
lps22hb.REG = {
	WHOAMI   = 0x0F,
	CTRL1    = 0x10,
	CTRL2    = 0x11,
	STATUS   = 0x27,
	PRESS_XL = 0x28,
	PRESS_L  = 0x29,
	PRESS_H  = 0x2A,
	TEMP_L   = 0x2B,
	TEMP_H   = 0x2C,
}

lps22hb.DEVID      = 0xB1
lps22hb.LPS25HB_ID = 0xBD	-- 代际拦截参照，不做模型种子
lps22hb.LSB_PER_HPA = 4096.0
lps22hb.LSB_PER_C   = 100.0

-- CTRL_REG2 位
local BIT_BOOT     = 0x80
local BIT_FIFO_EN  = 0x10
local BIT_IF_INC   = 0x08
local BIT_SWRESET  = 0x04
local BIT_ONESHOT  = 0x01
local CTRL2_STORED = 0x18	-- 真正落盘的位：FIFO_EN / IF_ADD_INC

-- 模型门限（ms，非 datasheet 保证值；驱动轮询上限 20/50ms 余量充裕）
local RESET_MS = 2
local CONV_MS  = 3

-- CTRL_REG1 [6:4] ODR 码 → 周期 ms；码 0=power-down/单次，6/7 保留
local ODR_PERIOD_MS = { [1] = 1000, [2] = 100, [3] = 40, [4] = 20, [5] = 40 / 3 }

-- 只读地址（>=2 字节多字节写落此区的数据字节 ACK 但丢弃）
local READONLY = {
	[0x0F] = true,							-- WHO_AM_I
	[0x27] = true,							-- STATUS
	[0x28] = true, [0x29] = true, [0x2A] = true,
	[0x2B] = true, [0x2C] = true,			-- P/T 输出 5 字节
}

local function clamp_s24(v)
	v = math.floor(v + 0.5)
	if v > 8388607 then v = 8388607 end
	if v < -8388608 then v = -8388608 end
	return v
end

local function clamp_s16(v)
	v = math.floor(v + 0.5)
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function LPS22HB_VIRT.new(opts)
	local lps22hb = LPS22HB_VIRT	-- 模型体沿用原模块表引用（零改动移植）
	-- 懒加载：regmap 底座只在虚拟路径真正 new() 时读盘（与 ADXL345/BME280/
	-- MPU6050/PCA9685/VL53L4CD 五个模型同形），生产路径零 I/O。
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

	opts = opts or {}
	local dev_id = opts.who or lps22hb.DEVID

	local m = regmap.new({
		[lps22hb.REG.WHOAMI] = dev_id,
	})
	local write_pred, read_pred

	-- 状态机
	local mode = "idle"		-- "idle"(ODR=000 power-down/单次) / "cont"
	local odr_code = 0
	local cont_period = nil	-- ms
	local cont_acc = 0		-- 连续模式累计时间
	local reset_busy = false
	local reset_left = nil
	local conv_busy = false
	local conv_left = nil
	local p_da = false
	local t_da = false
	local armed = false		-- virt_tick 预武装（命令位即时完成）
	local never_ready = false
	local pending = nil		-- 下次转换装载的 {p=,t=}（模型不自造测量值）
	local inc_bit = false	-- 最近指针写的地址 bit7
	local boot_count = 0

	local function reseed_body()
		for k in pairs(m.regs) do m.regs[k] = nil end
		m.regs[lps22hb.REG.WHOAMI] = dev_id
		m.ptr = 0
		inc_bit = false
		mode, odr_code, cont_period, cont_acc = "idle", 0, nil, 0
		reset_busy, reset_left = false, nil
		conv_busy, conv_left = false, nil
		p_da, t_da = false, false
		-- pending 注入是测试侧资产：SWRESET 不清（同 who/故障钩子族约定）
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		m.write_log[#m.write_log + 1] = cp
	end

	local function if_inc_global()
		return math.floor((m.regs[lps22hb.REG.CTRL2] or 0) / 8) % 2 == 1
	end

	local function load_sample()
		if pending then
			local p = pending.p % 0x1000000
			m.regs[0x28] = p % 256
			m.regs[0x29] = math.floor(p / 256) % 256
			m.regs[0x2A] = math.floor(p / 65536) % 256
			local t = pending.t % 0x10000
			m.regs[0x2B] = t % 256
			m.regs[0x2C] = math.floor(t / 256) % 256
		end
		p_da, t_da = true, true
	end

	local function finish_conv()
		conv_busy, conv_left = false, nil
		load_sample()
	end

	local function finish_reset()
		reseed_body()
	end

	-- CTRL_REG2 写解码（驱动恒 {0x11,val} 2B 写；多字节写流的每个数据字节
	-- 落到各自地址，这里按「写 0x11 的数据字节」处理）
	local function write_ctrl2(val)
		val = math.floor(val) % 256
		-- BOOT：硬件即时自清、重新装载出厂修调（模型无 NVM 修调可载，只计数）
		if math.floor(val / 128) % 2 == 1 then boot_count = boot_count + 1 end
		-- SWRESET：进入复位过程（读回 bit2=1 至结束）；其他位同写无意义
		if math.floor(val / 4) % 2 == 1 then
			reset_busy = true
			if armed and not never_ready then
				finish_reset()			-- 预武装：即时完成（武装不消费）
			else
				reset_left = RESET_MS
				m.regs[lps22hb.REG.CTRL2] = 0
			end
			return
		end
		-- 落盘位（仅 bit4 FIFO_EN / bit3 IF_ADD_INC；纯算术按位保留，勿用 %24）
		local stored = (math.floor(val / 16) % 2) * 16
		             + (math.floor(val / 8) % 2) * 8
		if mode == "idle" and (val % 2 == 1) and not reset_busy then
			-- ONE_SHOT：仅 power-down/单次模式有效（连续模式写它自清无效）
			if armed and not never_ready then
				m.regs[lps22hb.REG.CTRL2] = stored
				finish_conv()
				armed = false			-- 单次武装一次性消费
			else
				conv_busy, conv_left = true, CONV_MS
				m.regs[lps22hb.REG.CTRL2] = stored
			end
		else
			m.regs[lps22hb.REG.CTRL2] = stored
		end
	end

	-- CTRL_REG1 写：存字节并切 ODR 模式机
	local function write_ctrl1(val)
		val = math.floor(val) % 256
		m.regs[lps22hb.REG.CTRL1] = val
		odr_code = math.floor(val / 16) % 8
		cont_period = ODR_PERIOD_MS[odr_code]
		cont_acc = 0
		mode = cont_period and "cont" or "idle"
		if mode == "idle" then conv_busy, conv_left = false, nil end
	end

	-- ---------------- virtbus 点定义回调（总线无 self 调用，绝不能用冒号） ----------------

	m.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if m.nack or m.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes == 1 then
			m.ptr = bytes[1] % 128		-- 地址空间 7 位，bit7 是自动增量位
			inc_bit = bytes[1] >= 128
			return true
		end
		local base = bytes[1] % 128
		local winc = bytes[1] >= 128 or if_inc_global()
		for i = 2, #bytes do
			local a = winc and (base + i - 2) % 128 or base
			if not READONLY[a] then
				local v = bytes[i] % 256
				if a == lps22hb.REG.CTRL1 then
					write_ctrl1(v)
				elseif a == lps22hb.REG.CTRL2 then
					write_ctrl2(v)
				else
					m.regs[a] = v
				end
			end
		end
		return true
	end

	-- 动态寄存器读合成
	local function read_byte(addr)
		if addr == lps22hb.REG.CTRL2 then
			local v = m.regs[lps22hb.REG.CTRL2] or 0
			if reset_busy then v = v + BIT_SWRESET end
			if conv_busy then v = v + BIT_ONESHOT end
			return v % 256
		end
		if addr == lps22hb.REG.STATUS then
			return (p_da and 1 or 0) + (t_da and 2 or 0)
		end
		return m.regs[addr] or 0
	end

	m.read = function(n)
		if m.nack or m.nack_read then return nil end
		local nn = math.floor(tonumber(n) or 1)
		if read_pred and read_pred(m.ptr, nn) then return nil end
		if nn < 1 then nn = 1 end
		local inc = inc_bit or if_inc_global()
		local t = {}
		local last = m.ptr
		for i = 1, nn do
			local a = inc and (m.ptr + i - 1) % 128 or m.ptr
			t[i] = read_byte(a)
			last = a
			-- 高字节读后清对应 DA（datasheet：MSB 读清除）
			if a == lps22hb.REG.PRESS_H then p_da = false end
			if a == lps22hb.REG.TEMP_H  then t_da  = false end
		end
		m.ptr = inc and (last + 1) % 128 or m.ptr
		return t
	end

	-- ---------------- 配置/状态观察口 ----------------

	function m:who(val)
		if val ~= nil then
			dev_id = math.floor(val) % 256
			self.regs[lps22hb.REG.WHOAMI] = dev_id
		end
		return self
	end
	function m:devid()  return self.regs[lps22hb.REG.WHOAMI] or 0 end
	function m:ctrl1()  return self.regs[lps22hb.REG.CTRL1] or 0 end
	function m:status() return read_byte(lps22hb.REG.STATUS) end
	function m:ctrl2_dynamic() return read_byte(lps22hb.REG.CTRL2) end
	function m:resetting() return reset_busy end
	function m:busy()      return conv_busy end
	function m:p_ready()   return p_da end
	function m:t_ready()   return t_da end
	function m:armed_state() return armed end
	function m:mode_name() return mode end
	function m:boot_count() return boot_count end
	function m:autoinc_flag() return inc_bit end
	function m:pointer() return self.ptr end

	function m:bdu()        return math.floor(self:ctrl1() / 2) % 2 end
	function m:lpf_en()     return math.floor(self:ctrl1() / 8) % 2 end
	function m:lpf_cfg()    return math.floor(self:ctrl1() / 4) % 2 end
	function m:fifo_en()    return math.floor((self.regs[lps22hb.REG.CTRL2] or 0) / 16) % 2 end
	function m:if_add_inc() return math.floor((self.regs[lps22hb.REG.CTRL2] or 0) / 8) % 2 end
	function m:odr()        return odr_code end
	function m:odr_hz()
		local p = ODR_PERIOD_MS[odr_code]
		if p then return 1000 / p, odr_code end
		return nil, odr_code
	end

	-- ---------------- 小端输出区注入 ----------------

	function m:set_word24_le(reg, word)
		word = math.floor(word) % 0x1000000
		reg = math.floor(reg) % 128
		self.regs[reg] = word % 256
		self.regs[(reg + 1) % 128] = math.floor(word / 256) % 256
		self.regs[(reg + 2) % 128] = math.floor(word / 65536) % 256
		return self
	end

	function m:set_word_le(reg, word)
		word = math.floor(word) % 65536
		reg = math.floor(reg) % 128
		self.regs[reg] = word % 256
		self.regs[(reg + 1) % 128] = math.floor(word / 256) % 256
		return self
	end

	function m:get_word24_le(reg)
		reg = math.floor(reg) % 128
		return (self.regs[reg] or 0)
		     + (self.regs[(reg + 1) % 128] or 0) * 256
		     + (self.regs[(reg + 2) % 128] or 0) * 65536
	end

	function m:get_sword24_le(reg)
		local u = self:get_word24_le(reg)
		if u >= 0x800000 then u = u - 0x1000000 end
		return u
	end

	function m:get_word_le(reg)
		reg = math.floor(reg) % 128
		return (self.regs[reg] or 0) + (self.regs[(reg + 1) % 128] or 0) * 256
	end

	function m:get_sword_le(reg)
		local u = self:get_word_le(reg)
		if u >= 32768 then u = u - 65536 end
		return u
	end

	-- 气压/温度有符号原始码：直接写输出寄存器（burst 解码用）同时作为下一次
	-- 转换完成时装载的样本（oneshot/连续模式用）；nil 轴保持
	function m:set_press_raw(code)
		if code ~= nil then
			code = clamp_s24(code)
			self:set_word24_le(lps22hb.REG.PRESS_XL, code)
			pending = pending or {}
			pending.p = code
		end
		return self
	end

	function m:set_temp_raw(code)
		if code ~= nil then
			code = clamp_s16(code)
			self:set_word_le(lps22hb.REG.TEMP_L, code)
			pending = pending or {}
			pending.t = code
		end
		return self
	end

	function m:press_raw() return self:get_sword24_le(lps22hb.REG.PRESS_XL) end
	function m:temp_raw()  return self:get_sword_le(lps22hb.REG.TEMP_L) end

	-- ---------------- 物理量造样本（E2E/守护用） ----------------

	function m:set_press_hpa(h)
		if h ~= nil then self:set_press_raw(h * lps22hb.LSB_PER_HPA) end
		return self
	end

	function m:set_temp_c(t)
		if t ~= nil then self:set_temp_raw(t * lps22hb.LSB_PER_C) end
		return self
	end

	function m:press_hpa() return self:press_raw() / lps22hb.LSB_PER_HPA end
	function m:temp_c()   return self:temp_raw()  / lps22hb.LSB_PER_C end

	-- ---------------- 虚拟时钟（单次转换门/复位门/连续 ODR） ----------------

	function m:advance(ms)
		ms = tonumber(ms) or 0
		if reset_busy and not never_ready then
			reset_left = reset_left - ms
			if reset_left <= 0 then finish_reset() end
		end
		if conv_busy and not never_ready then
			conv_left = conv_left - ms
			if conv_left <= 0 then finish_conv() end
		end
		if mode == "cont" and cont_period and not never_ready then
			cont_acc = cont_acc + ms
			while cont_acc >= cont_period do
				cont_acc = cont_acc - cont_period
				load_sample()
			end
		end
		return self
	end

	-- 喂驱动 cfg.wait 超时：所有门/周期不再完成，预武装也无效
	function m:set_never_ready(v)
		never_ready = v ~= false
		return self
	end

	function m:never_ready_state() return never_ready end

	-- 预武装：下条 SWRESET/ONE_SHOT 命令即时完成（守护不推虚拟时钟）。
	-- 注意 SWRESET 不消费武装（build 复位后 call 仍须零睡眠，且守护每拍
	-- call 前都会重新 virt_tick，双保险）；武装跨 reset 保留。
	function m:arm() armed = true; return self end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用） ----------------

	-- 确定性合成波形（无随机，E2E 数值可复现）：32 拍周期，P 1013.25±5hPa、
	-- T 22±2°C 同相正弦（海平面常温环境）。
	--   n=0：1013.25hPa/22.0°C；n=8：1018.25/24.0（峰）；
	--   n=24：1008.25/20.0（谷）；n=32 回到 n=0。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local th = n * (2 * math.pi / 32)
		local s = math.sin(th)
		self:set_press_hpa(1013.25 + 5.0 * s)
		self:set_temp_c(22.0 + 2.0 * s)
		p_da, t_da = true, true
		armed = true
		return self
	end

	-- ---------------- 配置写留痕 / 故障钩子 / 复位 ----------------

	function m:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then out[#out + 1] = { reg = e[1], val = e[2] } end
		end
		return out
	end

	function m:write_count()
		local n = 0
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then n = n + 1 end
		end
		return n
	end

	function m:fail_write(pred) write_pred = pred; return self end
	function m:fail_read(pred)  read_pred  = pred; return self end

	function m:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function m:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回 POR 态；保留 who 身份、pending 注入、故障钩子（族约定）
	function m:reset()
		reseed_body()
		self.write_log = {}
		boot_count = 0
		never_ready = false
		armed = false
		return self
	end

	return m
end

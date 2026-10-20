-- ADXL345 三轴加速度计 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 ADXL345_VIRT（2026-09-15 自 modules/lib/virtbus/adxl345.lua
-- 迁入，单文件驱动+模型实验第十九个，regmap 底座；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Analog Devices，I2C 地址 0x53/0x1D（ALT ADDRESS 引脚，模块缺省 0x53），
-- ±2/4/8/16g，13 位 @ ±16g，输出三轴原始码：ACCEL_X/Y/Z
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE ADXL345 (
--       name    String,
--       I2C     String,
--       address String,
--       range   String,
--       odr     String
--   );
--   INSERT INTO ADXL345 (name, I2C, address, range, odr)
--     VALUES ('acc0', 'i2c-1', '0x53', '-', '-');
-- range = 量程 g（2/4/8/16，非法值向下降档，缺省 8）
-- odr   = 输出数据率 Hz（12.5/25/50/100/200/400/800/1600/3200，取最近档，
--         平手取低，缺省 100；低功耗降带宽档 0x0~0x6 本驱动不使用）
-- 各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回 { result, ACCEL_X, ACCEL_Y, ACCEL_Z }
-- （16 位补码语义的原始无符号码，与 MPU6050/BMI270/LSM6DSV 驱动同约定，
-- 负值由守护 sign='16' 展开）
-- 接 sensor_daemon：fields=ACCEL_X|ACCEL_Y|ACCEL_Z，sign='16'
--
-- 实现要点（寄存器/语义依 Adafruit CircuitPython ADXL34x 库核实，MIT）：
--   1. 甄别：DEVID(0x00) = 0xE5
--   2. DATA_FORMAT(0x31) 恒置 FULL_RES（bit3）：全量程灵敏度恒定
--      3.9mg/LSB（256 LSB/g）、数据 16 位左对齐——量程列只改削顶电平
--      （Adafruit 同款策略，非 FULL_RES 的 10 位逐档灵敏度模式不用）
--   3. 启动：POWER_CTL(0x2D) 写 0x08（Measure 位；芯片复位后为待机态，
--      写前先清 bit4 Sleep/bit5 Link——与 Adafruit 参考一致）
--   4. 数据寄存器小端：DATAX0(0x32) 起 6 字节 = X_LSB,X_MSB,Y_LSB,...
--      （与 BMI270/LSM6DSV 同，与 MPU6050 相反）
--   5. BW_RATE(0x2C) 低 4 位速率码：12.5Hz=0x7 线性到 3200Hz=0xF；
--      高性能区外还有低功耗降带宽档 0x0~0x6（不使用）
--   6. 敲击/自由落体/活动检测引擎（0x1D~0x30 中断组）本驱动未接——
--      框架为守护轮询路径，中断型事件驱动待框架支持后再扩展

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：高频采样，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_DEVID       = 0x00
local REG_BW_RATE     = 0x2C		-- bit4=低功耗 [3:0]=速率码
local REG_POWER_CTL   = 0x2D		-- bit3=Measure
local REG_DATA_FORMAT = 0x31		-- bit3=FULL_RES [1:0]=量程
local REG_DATAX0      = 0x32		-- 三轴数据 6 字节（小端）

local DEVID       = 0xE5
local FULL_RES    = 0x08
local MEASURE     = 0x08

-- 量程档 g（DATA_FORMAT 代码 0..3），缺省 ±8g
local acc_tab = { 2, 4, 8, 16 }
-- 数据率档 Hz（BW_RATE 代码 7..F），缺省 100Hz
local odr_tab  = { 12.5, 25, 50, 100, 200, 400, 800, 1600, 3200 }

-- 向下取档：不大于 n 的最大合法档（量程类）；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

-- 最近取档：差值最小档（ODR 类），平手取低
local function snap_near(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	local best, bd = def_i, math.huge
	for i = 1, #tab do
		local d = math.abs(n - tab[i])
		if d < bd then best, bd = i, d end
	end
	return best
end

local function range_code_of(v)
	local i = snap_down(v, acc_tab, 3)
	return i - 1, acc_tab[i]
end

local function odr_code_of(v)
	local i = snap_near(v, odr_tab, 4)
	return 6 + i, odr_tab[i]		-- 12.5Hz=0x7 起
end

-- 读 6 字节并拆 1 基字节数组；失败返回 nil
local function read_bytes6(fd, reg)
	local raw = i2c_read_multi(fd, reg, 6)
	if raw < 0 then return nil end
	local b = {}
	for i = 0, 5 do
		b[i + 1] = math.floor(raw / 256 ^ (5 - i)) % 256
	end
	return b
end

require_driver("i2c", {
	name = "ADXL345",

	-- 【配置脚本】DEVID 甄别 -> FULL_RES+量程 -> 速率 -> 测量模式
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- ADXL345 builder func get a table --------", data)
		end

		-- 列配置
		local range_v, range_g = range_code_of(data.range)
		local odr_code_v, odr_hz = odr_code_of(data.odr)

		-----------------------------------------------------
		-- 芯片甄别
		local id = i2c_read_reg(fd, REG_DEVID)
		if id < 0 then
			return err("Failed to read ADXL345 DEVID")
		end
		if id ~= DEVID then
			return err(string.format("DEVID = 0x%02X (expect 0xE5, not ADXL345?)", id))
		end

		-- 数据格式：保留高位、置 FULL_RES + 量程
		local df = i2c_read_reg(fd, REG_DATA_FORMAT)
		if df < 0 then
			return err("Failed to read ADXL345 DATA_FORMAT")
		end
		if not i2c_write_reg(fd, REG_DATA_FORMAT,
			bitc.bor(bitc.band(df, 0xF0), bitc.bor(FULL_RES, range_v))) then
			return err("Failed to write ADXL345 DATA_FORMAT")
		end

		-- 数据率（高性能档，清低功耗位）
		if not i2c_write_reg(fd, REG_BW_RATE, odr_code_v) then
			return err("Failed to write ADXL345 BW_RATE")
		end

		-- 进入测量模式（清 Sleep/Link 位，同 Adafruit 参考）
		if not i2c_write_reg(fd, REG_POWER_CTL, MEASURE) then
			return err("Failed to write ADXL345 POWER_CTL")
		end

		-- 等两个测量周期，首拍数据就绪
		local wait_ms = math.ceil(2 * 1000 / odr_hz) + 2
		milli_sleep(wait_ms)

		print(string.format("ADXL345 init OK: addr=0x%02X, ±%dg, odr=%gHz (FULL_RES 3.9mg/LSB)",
			addr, range_g, odr_hz))
		return {  result = "OK"  }

	end,

	-- destroy 缺省 = 空操作（原 ADXL345 destroy 仅 arg_table + return OK，等价）

	-- 【调用ADXL345】读三轴原始码
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- ADXL345 caller func get a table --------", data)
		end

		-----------------------------------------------------
		local b = read_bytes6(fd, REG_DATAX0)
		if b == nil then
			return err("Failed to read ADXL345 accel data")
		end

		local ret = {
			result  = "OK",
			ACCEL_X = bitc.bor(bitc.lshift(b[2], 8), b[1]),
			ACCEL_Y = bitc.bor(bitc.lshift(b[4], 8), b[3]),
			ACCEL_Z = bitc.bor(bitc.lshift(b[6], 8), b[5])
		}

		if DEBUG then
			print(string.format("ADXL345: X=%d Y=%d Z=%d", ret.ACCEL_X, ret.ACCEL_Y, ret.ACCEL_Z))
		end

		return ret

	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】ADXL345_VIRT —— 2026-09-15 自 modules/lib/virtbus/adxl345.lua
-- 整体迁入（单文件驱动+模型第十九个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十八者：① 生产路径零执行（new() 仅虚拟总线测试调用，regmap 底座
-- 延迟到 new() 内加载；只读区表/clamp 移入段内加 adxl345_ 前缀避让）；
-- ② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET
-- pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与
-- 驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 在通用字节指针 regmap 底座上固化 ADXL345 的寄存器事实（Adafruit ADXL34x
-- 寄存器映射）。标准「8 位寄存器指针 + 连续 burst」事务形态（regmap 包装族，
-- 与 mpu6050.lua 骨架同型），但四处勿抄错：
--   ① 数据区【小端】：DATAX0(0x32) 起 6 字节 = X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,
--      Z_MSB（LSB 在低地址，与 MPU6050 大端相反）——底座 set_word 是大端，
--      本模型另给 set_word_le/小端数据注入；
--   ② FULL_RES（DATA_FORMAT bit3）下灵敏度【全量程恒定 256 LSB/g】（3.9mg/LSB），
--      数据 16 位左对齐，量程列只改削顶电平（MPU6050 ±8g 是 4096 LSB/g）；
--   ③ build 对 DATA_FORMAT 是【先读回再 RMW】：(df & 0xF0) | FULL_RES | range
--      （保高 4 位，MPU6050 直接写）；
--   ④ build 的等待是【等两个测量周期】ceil(2000/odr)+2 ms（默认 odr=100→22ms，
--      MPU6050 是固定 100ms）。
--
-- 寄存器（8 位字节指针，驱动触碰区）：
--   0x00 DEVID         只读，上电 0xE5（用例可 who() 改，模拟错挂器件）
--   0x2C BW_RATE       bit4=低功耗档（驱动不用）、[3:0]=速率码，POR 0x0A（100Hz）
--   0x2D POWER_CTL     bit3=Measure，build 写 0x08
--   0x31 DATA_FORMAT   bit3=FULL_RES、[1:0]=量程码 0..3（±2/4/8/16g），POR 0x00
--   0x32~0x37 三轴数据 只读，小端补码；写 ACK 但丢弃（协议层只读事实）
-- 单字节写 {reg}=读指针：任意地址（含只读/保留区）都 ACK 并移动指针，这是
-- I2C_RDWR 读操作的指针消息；>=2 字节写落只读区的数据字节才丢弃。
--
-- 用法：
--   vbus.load_driver("modules/ADXL345.lua")  -- 定义全局 build/call/destroy 与 ADXL345_VIRT
--   local dev = ADXL345_VIRT.new()           -- DEVID 默认 0xE5
--   dev:set_accel_raw(4096, -1, -1024)       -- 有符号原始 LSB（小端存放）
--   dev:set_accel_g(0.3, -0.15, 1.0)         -- 或以 g 造样本（256 LSB/g）
--   vbus.attach("ADXL345@0x53", 0x53, dev)
--
--   dev:config_writes()  -- build 写过的 {reg=,val=} 序列（驱动配置序列断言）
--   dev.nack_read = true -- 定向故障：配置写成功、数据 burst 读失败
--   dev:who(0xE7)        -- 模拟错挂器件（DEVID 不符）
--
-- 【边界约定】驱动 call 返回未符号扩展的无符号原始码（负值由守护 sign='16'
-- 展开），故本模型以「原始 LSB」为主输入，符号扩展归守护/测试独立断言；量程
-- 取档（snap_down）/速率取档（snap_near 平手取低）/睡眠预算都归驱动，模型只
-- 存寄存器字节并提供观察口，避免模型与驱动共用一份取档理解互证假绿。
-- =====================================================================

ADXL345_VIRT = {
	_VERSION = "0.1.0",
	I2C_ADDR      = 0x53,	-- 缺省（ALT ADDRESS 引脚低）
	I2C_ADDR_ALT  = 0x1D,	-- 备选（ALT ADDRESS 引脚高）
	REG = {
		DEVID       = 0x00,
		BW_RATE     = 0x2C,
		POWER_CTL   = 0x2D,
		DATA_FORMAT = 0x31,
		DATAX0      = 0x32,
	},
	DEVID        = 0xE5,
	LSB_PER_G    = 256.0,	-- FULL_RES 恒定 3.9mg/LSB，与量程无关
	RANGE_G      = { 2, 4, 8, 16 },		-- DATA_FORMAT [1:0] 代码 0..3
	-- BW_RATE [3:0] 高性能档速率码 0x7..0xF 对应 ODR（低功耗档 0x0~0x6 驱动不用）
	ODR_CODE_BASE = 7,
	ODR_HZ       = { 12.5, 25, 50, 100, 200, 400, 800, 1600, 3200 },
	POR_BW_RATE  = 0x0A,	-- datasheet POR：100Hz
}

-- 只读地址（>=2 字节多字节写落此区的数据字节 ACK 但丢弃）
local adxl345_READONLY = {
	[0x00] = true,				-- DEVID
	[0x32] = true, [0x33] = true, [0x34] = true,
	[0x35] = true, [0x36] = true, [0x37] = true,	-- DATAX0..DATAZ1
}

local function adxl345_clamp_s16(v)
	v = math.floor(v + 0.5)	-- 物理量造样本时四舍五入到最近 LSB
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function ADXL345_VIRT.new(opts)
	local REG = ADXL345_VIRT.REG
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

	opts = opts or {}
	local dev_id = opts.who or ADXL345_VIRT.DEVID

	local m = regmap.new({
		[REG.DEVID]   = dev_id,
		[REG.BW_RATE] = ADXL345_VIRT.POR_BW_RATE,
	})
	local write_pred, read_pred

	local function reseed()
		for k in pairs(m.regs) do m.regs[k] = nil end
		m.regs[REG.DEVID]   = dev_id
		m.regs[REG.BW_RATE] = ADXL345_VIRT.POR_BW_RATE
		m.ptr = 0
		m.write_log = {}
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		m.write_log[#m.write_log + 1] = cp
	end

	-- 底座读闭包（包一层仅为加 read_pred；nack 由包装与底座双判）
	local base_read = m.read

	-- ---------------- virtbus 点定义回调（总线无 self 调用，绝不能用冒号） ----------------

	-- 覆盖底座 write：在「8 位指针 + 连续写」语义上加只读区丢弃与 write_pred。
	-- 留痕先于故障判定（与 virtbus do_write 先 log_tx 后判 NACK 一致）。
	m.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if m.nack or m.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes == 1 then
			m.ptr = bytes[1] % 256	-- 纯读指针：任意地址 ACK 并移动指针
			return true
		end
		local base = bytes[1] % 256
		for i = 2, #bytes do
			local a = (base + i - 2) % 256
			if not adxl345_READONLY[a] then m.regs[a] = bytes[i] % 256 end
		end
		return true
	end

	-- 覆盖底座 read：加 read_pred(ptr,n)（在指针推进前判定），余交底座 burst
	m.read = function(n)
		if m.nack or m.nack_read then return nil end
		local nn = math.floor(tonumber(n) or 1)
		if read_pred and read_pred(m.ptr, nn) then return nil end
		return base_read(n)
	end

	-- ---------------- 身份/配置观察口 ----------------

	-- 改 DEVID 身份值（如 0xE7 模拟错挂）；reset 不恢复出厂身份（族约定）
	function m:who(val)
		if val ~= nil then
			dev_id = math.floor(val) % 256
			self.regs[REG.DEVID] = dev_id
		end
		return self
	end

	function m:devid() return self.regs[REG.DEVID] or 0 end
	function m:df()    return self.regs[REG.DATA_FORMAT] or 0 end
	function m:bw()    return self.regs[REG.BW_RATE] or 0 end
	function m:power() return self.regs[REG.POWER_CTL] or 0 end

	function m:range_code() return self:df() % 4 end
	function m:range_g()    return ADXL345_VIRT.RANGE_G[self:range_code() + 1] end
	function m:full_res()   return math.floor(self:df() / 8) % 2 end
	function m:measure()    return math.floor(self:power() / 8) % 2 end
	function m:low_power()  return math.floor(self:bw() / 16) % 2 end

	-- BW_RATE 低 4 位速率码；仅高性能档 0x7..0x0F 映射 ODR，其余（低功耗档）
	-- 返回 nil（驱动不使用，模型不臆断其频率）
	function m:odr_code() return self:bw() % 16 end
	function m:odr_hz()
		local c = self:odr_code()
		local idx = c - ADXL345_VIRT.ODR_CODE_BASE + 1
		if idx >= 1 and idx <= #ADXL345_VIRT.ODR_HZ then
			return ADXL345_VIRT.ODR_HZ[idx], c
		end
		return nil, c
	end

	-- ---------------- 小端数据区注入（与底座大端 set_word 成对侧） ----------------

	-- 预置/读取小端 16 位值（LSB 在低地址）；set_word_le 接受有符号整数（转补码）
	function m:set_word_le(reg, word)
		word = math.floor(word) % 65536
		reg = math.floor(reg) % 256
		self.regs[reg] = word % 256
		self.regs[(reg + 1) % 256] = math.floor(word / 256) % 256
		return self
	end

	function m:get_word_le(reg)
		reg = math.floor(reg) % 256
		return (self.regs[reg] or 0) + (self.regs[(reg + 1) % 256] or 0) * 256
	end

	function m:get_sword_le(reg)
		local u = self:get_word_le(reg)
		if u >= 32768 then u = u - 65536 end
		return u
	end

	-- 加速度三轴有符号原始 LSB；参数可省略（nil 轴保持原值）
	function m:set_accel_raw(x, y, z)
		if x ~= nil then self:set_word_le(REG.DATAX0,     adxl345_clamp_s16(x)) end
		if y ~= nil then self:set_word_le(REG.DATAX0 + 2, adxl345_clamp_s16(y)) end
		if z ~= nil then self:set_word_le(REG.DATAX0 + 4, adxl345_clamp_s16(z)) end
		return self
	end

	function m:accel_raw()
		return self:get_sword_le(REG.DATAX0),
		       self:get_sword_le(REG.DATAX0 + 2),
		       self:get_sword_le(REG.DATAX0 + 4)
	end

	-- ---------------- 物理量造样本（E2E/守护用，256 LSB/g 常量仅造样本） ----------------

	function m:set_accel_g(gx, gy, gz)
		local k = ADXL345_VIRT.LSB_PER_G
		return self:set_accel_raw(
			gx ~= nil and gx * k or nil,
			gy ~= nil and gy * k or nil,
			gz ~= nil and gz * k or nil)
	end

	function m:accel_g()
		local x, y, z = self:accel_raw()
		local k = ADXL345_VIRT.LSB_PER_G
		return x / k, y / k, z / k
	end

	-- ---------------- 守护仿真节拍（proto=virt 的 sensor_daemon 每拍调用） ----------------

	-- 确定性合成波形（无随机，E2E 数值可复现/可断言）：32 拍周期，三轴互差 120°。
	-- X/Y 为 ±0.30g 小幅晃动（±77 码），Z 为 1g 重力 + ±0.05g 起伏（245~262 码，
	-- 全程为正），均远在最小 ±2g 削顶（±512 码）内。
	--   n=0：X=0、Y=67、Z=245；n=8：X=77、Y=-38、Z=250；n=24：X=-77、Z=262。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local th = n * (2 * math.pi / 32)
		local twopi3 = 2 * math.pi / 3
		self:set_accel_g(
			0.30 * math.sin(th),
			0.30 * math.sin(th + twopi3),
			1.0 + 0.05 * math.sin(th + 2 * twopi3))
		return self
	end

	-- ---------------- 配置写留痕 / 故障钩子 / 复位 ----------------

	-- 驱动 build 写过的寄存器：write_log 中 >=2 字节事务（1 字节是读指针）。
	-- 返回 { {reg=, val=}, ... }，顺序与总线一致（驱动恒单寄存器 2 字节写）。
	function m:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then
				out[#out + 1] = { reg = e[1], val = e[2] }
			end
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

	function m:pointer() return self.ptr end

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

	-- 回 POR 态（DEVID/BW_RATE 种子、指针、留痕清零）；保留故障钩子与 who 身份，
	-- 与全系列约定一致（钩子用 clear_faults 显式解除）
	function m:reset()
		reseed()
		return self
	end

	return m
end

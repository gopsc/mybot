-- adxl345.lua —— ADI ADXL345 三轴加速度计虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 在通用字节指针 regmap 底座上固化 ADXL345 的寄存器事实（与 modules/ADXL345.lua
-- 驱动同源，Adafruit ADXL34x 寄存器映射）。标准「8 位寄存器指针 + 连续 burst」
-- 事务形态（regmap 包装族，与 mpu6050.lua 骨架同型），但四处勿抄错：
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
--   local amod = dofile("modules/lib/virtbus/adxl345.lua")
--   local dev = amod.new()                    -- DEVID 默认 0xE5
--   dev:set_accel_raw(4096, -1, -1024)        -- 有符号原始 LSB（小端存放）
--   dev:set_accel_g(0.3, -0.15, 1.0)          -- 或以 g 造样本（256 LSB/g）
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

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

local adxl345 = {}
adxl345._VERSION = "0.1.0"

adxl345.I2C_ADDR      = 0x53	-- 缺省（ALT ADDRESS 引脚低）
adxl345.I2C_ADDR_ALT  = 0x1D	-- 备选（ALT ADDRESS 引脚高）

-- 寄存器地址
adxl345.REG = {
	DEVID       = 0x00,
	BW_RATE     = 0x2C,
	POWER_CTL   = 0x2D,
	DATA_FORMAT = 0x31,
	DATAX0      = 0x32,
}

adxl345.DEVID        = 0xE5
adxl345.LSB_PER_G    = 256.0	-- FULL_RES 恒定 3.9mg/LSB，与量程无关
adxl345.RANGE_G      = { 2, 4, 8, 16 }		-- DATA_FORMAT [1:0] 代码 0..3
-- BW_RATE [3:0] 高性能档速率码 0x7..0xF 对应 ODR（低功耗档 0x0~0x6 驱动不用）
adxl345.ODR_CODE_BASE = 7
adxl345.ODR_HZ       = { 12.5, 25, 50, 100, 200, 400, 800, 1600, 3200 }
adxl345.POR_BW_RATE  = 0x0A	-- datasheet POR：100Hz

-- 只读地址（>=2 字节多字节写落此区的数据字节 ACK 但丢弃）
local READONLY = {
	[0x00] = true,				-- DEVID
	[0x32] = true, [0x33] = true, [0x34] = true,
	[0x35] = true, [0x36] = true, [0x37] = true,	-- DATAX0..DATAZ1
}

local function clamp_s16(v)
	v = math.floor(v + 0.5)	-- 物理量造样本时四舍五入到最近 LSB
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function adxl345.new(opts)
	opts = opts or {}
	local dev_id = opts.who or adxl345.DEVID

	local m = regmap.new({
		[adxl345.REG.DEVID]   = dev_id,
		[adxl345.REG.BW_RATE] = adxl345.POR_BW_RATE,
	})
	local write_pred, read_pred

	local function reseed()
		for k in pairs(m.regs) do m.regs[k] = nil end
		m.regs[adxl345.REG.DEVID]   = dev_id
		m.regs[adxl345.REG.BW_RATE] = adxl345.POR_BW_RATE
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
			if not READONLY[a] then m.regs[a] = bytes[i] % 256 end
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
			self.regs[adxl345.REG.DEVID] = dev_id
		end
		return self
	end

	function m:devid() return self.regs[adxl345.REG.DEVID] or 0 end
	function m:df()    return self.regs[adxl345.REG.DATA_FORMAT] or 0 end
	function m:bw()    return self.regs[adxl345.REG.BW_RATE] or 0 end
	function m:power() return self.regs[adxl345.REG.POWER_CTL] or 0 end

	function m:range_code() return self:df() % 4 end
	function m:range_g()    return adxl345.RANGE_G[self:range_code() + 1] end
	function m:full_res()   return math.floor(self:df() / 8) % 2 end
	function m:measure()    return math.floor(self:power() / 8) % 2 end
	function m:low_power()  return math.floor(self:bw() / 16) % 2 end

	-- BW_RATE 低 4 位速率码；仅高性能档 0x7..0x0F 映射 ODR，其余（低功耗档）
	-- 返回 nil（驱动不使用，模型不臆断其频率）
	function m:odr_code() return self:bw() % 16 end
	function m:odr_hz()
		local c = self:odr_code()
		local idx = c - adxl345.ODR_CODE_BASE + 1
		if idx >= 1 and idx <= #adxl345.ODR_HZ then
			return adxl345.ODR_HZ[idx], c
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

	local R = adxl345.REG

	-- 加速度三轴有符号原始 LSB；参数可省略（nil 轴保持原值）
	function m:set_accel_raw(x, y, z)
		if x ~= nil then self:set_word_le(R.DATAX0,     clamp_s16(x)) end
		if y ~= nil then self:set_word_le(R.DATAX0 + 2, clamp_s16(y)) end
		if z ~= nil then self:set_word_le(R.DATAX0 + 4, clamp_s16(z)) end
		return self
	end

	function m:accel_raw()
		return self:get_sword_le(R.DATAX0),
		       self:get_sword_le(R.DATAX0 + 2),
		       self:get_sword_le(R.DATAX0 + 4)
	end

	-- ---------------- 物理量造样本（E2E/守护用，256 LSB/g 常量仅造样本） ----------------

	function m:set_accel_g(gx, gy, gz)
		local k = adxl345.LSB_PER_G
		return self:set_accel_raw(
			gx ~= nil and gx * k or nil,
			gy ~= nil and gy * k or nil,
			gz ~= nil and gz * k or nil)
	end

	function m:accel_g()
		local x, y, z = self:accel_raw()
		local k = adxl345.LSB_PER_G
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

return adxl345

-- mpu6050.lua —— MPU6050 六轴 IMU 虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 在通用寄存器组模型 regmap 之上固化 MPU6050 的寄存器事实（与
-- modules/MPU6050.lua 驱动同源，InvenSense 寄存器映射表）：
--   0x75        WHO_AM_I，上电身份值 0x68（用例可改，模拟错挂 0x71 器件）
--   0x6B        PWR_MGMT_1（build 写 0x00 退睡眠）
--   0x1B/0x1C   GYRO_CONFIG/ACCEL_CONFIG（驱动 build 固定 ±500°/s、±8g）
--   0x3B..0x40  ACCEL_X/Y/Z 高低字节（大端补码）
--   0x41..0x42  TEMP_OUT（大端补码，°C = raw/340 + 36.53）
--   0x43..0x48  GYRO_X/Y/Z 高低字节
-- call 的 14 字节 burst（0x3B 起）由 regmap 的指针+burst 语义自然支持。
--
-- 用法：
--   local mpmod = dofile("modules/lib/virtbus/mpu6050.lua")
--   local imu = mpmod.new()                       -- WHO_AM_I 默认 0x68
--   imu:set_accel(1, 2, 3):set_gyro(-4, -3, -2)  -- 有符号原始 LSB
--   imu:set_temp_raw(340)                          -- 或 set_temp_c(37.53)
--   vbus.attach("MPU6050@0x68", 0x68, imu)
--
--   imu:config_writes()  -- build 写过的 {reg=,val=} 序列（驱动配置序列断言）
--   imu.nack_read = true -- 定向故障：配置写成功、测量 burst NACK
--   imu:who(0x71)       -- 模拟错挂器件
--
-- 【边界约定】驱动 call 返回的是未换算的有符号原始值，故本模型以「原始 LSB」
-- 为主输入（set_accel/set_gyro/set_temp_raw），驱动的符号扩展/温度换算由测试
-- 独立断言，避免模型与驱动共用一份换算逻辑互证。set_accel_g/set_gyro_dps/
-- set_temp_c 仅供守护/E2E 测试以物理量造样本，灵敏度常量按驱动 build 选定的
-- ±8g（4096 LSB/g）、±500°/s（65.5 LSB/°/s），改量程需同步改这里。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

local mpu6050 = {}
mpu6050._VERSION = "0.1.0"

-- 寄存器地址
mpu6050.REG = {
	WHO_AM_I    = 0x75,
	PWR_MGMT_1  = 0x6B,
	GYRO_CONFIG = 0x1B,
	ACCEL_CONFIG= 0x1C,
	ACCEL_XH    = 0x3B,
	TEMP_H      = 0x41,
	GYRO_XH     = 0x43,
}

-- datasheet 换算常量
mpu6050.ACCEL_LSB_PER_G   = 4096.0	-- ±8g（AFS_SEL=3，驱动 build 固定）
mpu6050.GYRO_LSB_PER_DPS  = 65.5	-- ±500°/s（FS_SEL=1，驱动 build 固定）
mpu6050.TEMP_LSB_PER_DEG  = 340.0
mpu6050.TEMP_OFFSET_DEG   = 36.53

local function clamp_word(v)
	v = math.floor(v + 0.5)	-- 物理量造样本时四舍五入到最近 LSB
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function mpu6050.new(opts)
	opts = opts or {}
	local m = regmap.new({ [mpu6050.REG.WHO_AM_I] = opts.who or 0x68 })

	-- ---------------- 测量值注入（有符号原始 LSB） ----------------

	-- 加速度三轴；参数可省略（nil 轴保持原值）
	function m:set_accel(x, y, z)
		local R = mpu6050.REG
		if x ~= nil then self:set_word(R.ACCEL_XH, clamp_word(x)) end
		if y ~= nil then self:set_word(R.ACCEL_XH + 2, clamp_word(y)) end
		if z ~= nil then self:set_word(R.ACCEL_XH + 4, clamp_word(z)) end
		return self
	end

	function m:set_gyro(x, y, z)
		local R = mpu6050.REG
		if x ~= nil then self:set_word(R.GYRO_XH, clamp_word(x)) end
		if y ~= nil then self:set_word(R.GYRO_XH + 2, clamp_word(y)) end
		if z ~= nil then self:set_word(R.GYRO_XH + 4, clamp_word(z)) end
		return self
	end

	-- TEMP_OUT 有符号原始值
	function m:set_temp_raw(raw)
		self:set_word(mpu6050.REG.TEMP_H, clamp_word(raw))
		return self
	end

	-- 一次 call 的 14 字节样本：{ax=,ay=,az=,gx=,gy=,gz=,temp=}（原始 LSB，均可缺省）
	function m:sample(s)
		s = s or {}
		self:set_accel(s.ax, s.ay, s.az)
		self:set_gyro(s.gx, s.gy, s.gz)
		if s.temp ~= nil then self:set_temp_raw(s.temp) end
		return self
	end

	-- ---------------- 物理量造样本（E2E/守护测试用） ----------------

	function m:set_accel_g(gx, gy, gz)
		local k = mpu6050.ACCEL_LSB_PER_G
		return self:set_accel(
			gx ~= nil and gx * k or nil,
			gy ~= nil and gy * k or nil,
			gz ~= nil and gz * k or nil)
	end

	function m:set_gyro_dps(dx, dy, dz)
		local k = mpu6050.GYRO_LSB_PER_DPS
		return self:set_gyro(
			dx ~= nil and dx * k or nil,
			dy ~= nil and dy * k or nil,
			dz ~= nil and dz * k or nil)
	end

	function m:set_temp_c(degC)
		return self:set_temp_raw((degC - mpu6050.TEMP_OFFSET_DEG) * mpu6050.TEMP_LSB_PER_DEG)
	end

	-- ---------------- 守护仿真节拍（proto=virt 的 sensor_daemon 每拍调用） ----------------

	-- 确定性合成波形（无随机，E2E 数值可复现/可断言）：n 为守护采样序号。
	-- 加速度三轴互差 120° 正弦、陀螺三轴同相位余弦，幅值均在驱动选定量程内
	-- （accel ±20000 LSB≈±4.9g @±8g；gyro ±10000 LSB≈±153dps @±500dps）；
	-- 温度在约 41°C 慢漂（raw=1530 → 41.03°C）。守护 10ms/拍时角速度 ≈4.8Hz，
	-- 50ms 消费节拍下 20 拍可观察到 EMA 的平滑与相位滞后。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local th = n * 0.30
		local twopi3 = 2 * math.pi / 3
		self:set_accel(
			20000 * math.sin(th),
			20000 * math.sin(th + twopi3),
			20000 * math.sin(th + 2 * twopi3))
		self:set_gyro(
			10000 * math.cos(th),
			10000 * math.cos(th + twopi3),
			10000 * math.cos(th + 2 * twopi3))
		self:set_temp_raw(1530 + 170 * math.sin(th * 0.08))
		return self
	end

	-- ---------------- 配置/身份留痕（build 序列断言） ----------------

	-- 改 WHO_AM_I 身份值（如 0x71 模拟 MPU6500/9250 错挂）
	function m:who(val)
		self:set(mpu6050.REG.WHO_AM_I, val)
		return self
	end

	-- 驱动 build 写过的寄存器序列：从 regmap 写事务留痕里取「>=2 字节」的
	-- {reg,val,...}（1 字节事务是读操作的寄存器指针，非配置写）。
	-- 返回 { {reg=, val=}, ... }，顺序与总线一致。
	function m:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then
				out[#out + 1] = { reg = e[1], val = e[2] }
			end
		end
		return out
	end

	return m
end

return mpu6050

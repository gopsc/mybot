-- MPU6050 陀螺仪与加速度计 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MPU6050_VIRT（2026-09-15 自 modules/lib/virtbus/mpu6050.lua
-- 迁入，单文件驱动+模型实验第三个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）


-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))


local ADDR_0		= 0x68	-- 默认地址
local ADDR_1		= 0x69	-- 额外地址
local REG_WHO_AM_I	= 0x75	-- 身份寄存器（只读）
local WHO_AM_I_VAL	= 0x68	-- MPU6050 身份值（bit0 恒 0）
local PWR_MGMT_1	= 0x6B	-- 电源管理寄存器1
local PWR_NOSLEEP	= 0x00	-- 电源管理 - 非睡眠模式
local GYRO_CONF_REG	= 0x1B	-- 陀螺仪配置寄存器
local GYRO_FS_500DPS	= 0x08	-- 陀螺仪量程 - 正负500度/秒
local GYRO_REG_X_HIGH	= 0x43	-- x 陀螺仪轴 高字节
local GYRO_REG_X_LOW	= 0x44	--
local GYRO_REG_Y_HIGH	= 0x45	-- y
local GYRO_REG_Y_LOW	= 0x46	--
local GYRO_REG_Z_HIGH	= 0x47	-- z
local GYRO_REG_Z_LOW	= 0x48	--
local ACCEL_CONF_REG	= 0x1C	-- 加速度计配置的寄存器
local ACCEL_FS_8g	= 0x10	-- 加速度计量程 正负8g
local ACCEL_REG_X_HIGH	= 0x3B	-- x
local ACCEL_REG_X_LOW	= 0x3C	--
local ACCEL_REG_Y_HIGH	= 0x3D	-- y
local ACCEL_REG_Y_LOW	= 0x3E	--
local ACCEL_REG_Z_HIGH	= 0x3F	-- Z
local ACCEL_REG_Z_LOW	= 0x40	--
-- 温度寄存器 0x41/0x42 位于 14 字节 burst 的 t[7]/t[8]
local TEMP_LSB_PER_DEG	= 340.0	-- 温度灵敏度 340 LSB/°C（datasheet 寄存器映射表）
local TEMP_OFFSET_DEG	= 36.53	-- raw=0 对应 36.53°C（片上温度，非环境温度精确量）

require_driver("i2c", {
	name = "MPU6050",

	-- 【配置脚本】
	build = function(ctx, data)
		dbg_table("-------- Lua builder func get a table --------", data)

		local fd = ctx.fd

		milli_sleep(1)			--

		if not i2c_write_reg(fd, PWR_MGMT_1, PWR_NOSLEEP) then		-- 退出睡眠
			return err("MPU6050 not responding (PWR_MGMT_1 write failed, check address and wiring)")
		end

		-- WHO_AM_I 甄别：总线上任意会 ACK 的器件（或错地址）都能通过纯写配置的
		-- build——读身份寄存器把错挂器件挡在 build 期（同批 IMU 均已甄别）
		local who = i2c_read_reg(fd, REG_WHO_AM_I)
		if who < 0 then
			return err("MPU6050 not responding (WHO_AM_I read failed, check address and wiring)")
		end
		if who ~= WHO_AM_I_VAL then
			return err(string.format("MPU6050 WHO_AM_I = 0x%02X (expect 0x68, not MPU6050?)", who))
		end

		if not i2c_write_reg(fd, GYRO_CONF_REG, GYRO_FS_500DPS) then	-- 设陀螺仪量程
			return err("MPU6050 write failed: GYRO_CONFIG")
		end
		if not i2c_write_reg(fd, ACCEL_CONF_REG, ACCEL_FS_8g) then	-- 设加速度计量程
			return err("MPU6050 write failed: ACCEL_CONFIG")
		end

		milli_sleep(100)		-- 等待稳定

		return {  result = "OK"  }	-- 返回成功信号
	end,

	-- 【重置MPU6050的脚本】需 i2c_pair 校验（测试期望缺 fd 报错）
	destroy = function(ctx, data)
		dbg_table("-------- Lua ender func get a table --------", data)

		local fd, addr, ek = i2c_pair(data)
		if fd == nil then return ek end

		return {  result = "OK"  }
	end,

	-- 【调用MPU6050】
	call = function(ctx, data)
		dbg_table("-------- Lua caller func get a table --------", data)

		local fd = ctx.fd

		-- 16 位补码符号扩展：高/低字节合并成有符号数
		local function s16(hi, lo)
			local v = bitc.bor(bitc.lshift(hi, 8), lo)
			v = bitc.s16(v)	-- 负值还原
			return v
		end

		-- 六轴 burst read：0x3B 起 14 字节单次原子事务（ACCEL 6B + TEMP 2B + GYRO 6B）。
		local t = i2c_read_multi_bytes(fd, ACCEL_REG_X_HIGH, 14)
		if t == nil then
			return err("MPU6050 read failed (burst 0x3B..0x48, check wiring)")
		end

		-- 温度：t[7]/t[8] 为 TEMP_OUT（0x41/0x42）有符号原始值
		local tempRaw = s16(t[7], t[8])
		local tempC   = tempRaw / TEMP_LSB_PER_DEG + TEMP_OFFSET_DEG

		-- 返回字典：六轴为有符号 16 位原始值，TEMP 为摄氏度浮点
	 	return {
	 		result  = "OK",
	 		ACCEL_X = s16(t[1],  t[2]),
	 		ACCEL_Y = s16(t[3],  t[4]),
	 		ACCEL_Z = s16(t[5],  t[6]),
	 		GYRO_X  = s16(t[9],  t[10]),
	 		GYRO_Y  = s16(t[11], t[12]),
	 		GYRO_Z  = s16(t[13], t[14]),
	 		TEMP    = tempC,
	 		TEMP_RAW = tempRaw
	 	}
	end,
})

-- =====================================================================
-- 【内嵌虚拟器件模型】MPU6050_VIRT —— 2026-09-15 自 modules/lib/virtbus/mpu6050.lua
-- 整体迁入（单文件驱动+模型第三个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同 PCA9685_VIRT/BH1750_VIRT：① 生产路径零执行（new() 仅虚拟总线测试
-- 调用，regmap 底座延迟到 new() 内加载）；② 工厂经全局表而非文件 return
-- （生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，
-- 文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现（模型自带寄存器表/
-- 灵敏度常量，不引用上方驱动局部量），互证防假绿性质不变。
--
-- 在通用寄存器组模型 regmap 之上固化 MPU6050 的寄存器事实（InvenSense 寄存器
-- 映射表）：
--   0x75        WHO_AM_I，上电身份值 0x68（用例可改，模拟错挂 0x71 器件）
--   0x6B        PWR_MGMT_1（build 写 0x00 退睡眠）
--   0x1B/0x1C   GYRO_CONFIG/ACCEL_CONFIG（驱动 build 固定 ±500°/s、±8g）
--   0x3B..0x40  ACCEL_X/Y/Z 高低字节（大端补码）
--   0x41..0x42  TEMP_OUT（大端补码，°C = raw/340 + 36.53）
--   0x43..0x48  GYRO_X/Y/Z 高低字节
-- call 的 14 字节 burst（0x3B 起）由 regmap 的指针+burst 语义自然支持。
--
-- 用法：
--   vbus.load_driver("modules/MPU6050.lua")    -- 定义全局 build/call/destroy 与 MPU6050_VIRT
--   local imu = MPU6050_VIRT.new()             -- WHO_AM_I 默认 0x68
--   imu:set_accel(1, 2, 3):set_gyro(-4, -3, -2)-- 有符号原始 LSB
--   imu:set_temp_raw(340)                      -- 或 set_temp_c(37.53)
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
-- =====================================================================

MPU6050_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		WHO_AM_I    = 0x75,
		PWR_MGMT_1  = 0x6B,
		GYRO_CONFIG = 0x1B,
		ACCEL_CONFIG= 0x1C,
		ACCEL_XH    = 0x3B,
		TEMP_H      = 0x41,
		GYRO_XH     = 0x43,
	},
	ACCEL_LSB_PER_G   = 4096.0,	-- ±8g（AFS_SEL=3，驱动 build 固定）
	GYRO_LSB_PER_DPS  = 65.5,	-- ±500°/s（FS_SEL=1，驱动 build 固定）
	TEMP_LSB_PER_DEG  = 340.0,
	TEMP_OFFSET_DEG   = 36.53,
}

local function mpu6050_clamp_word(v)
	v = math.floor(v + 0.5)	-- 物理量造样本时四舍五入到最近 LSB
	if v > 32767 then v = 32767 end
	if v < -32768 then v = -32768 end
	return v
end

function MPU6050_VIRT.new(opts)
	local REG = MPU6050_VIRT.REG
	local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

	opts = opts or {}
	local m = regmap.new({ [REG.WHO_AM_I] = opts.who or 0x68 })

	-- ---------------- 测量值注入（有符号原始 LSB） ----------------

	-- 加速度三轴；参数可省略（nil 轴保持原值）
	function m:set_accel(x, y, z)
		if x ~= nil then self:set_word(REG.ACCEL_XH, mpu6050_clamp_word(x)) end
		if y ~= nil then self:set_word(REG.ACCEL_XH + 2, mpu6050_clamp_word(y)) end
		if z ~= nil then self:set_word(REG.ACCEL_XH + 4, mpu6050_clamp_word(z)) end
		return self
	end

	function m:set_gyro(x, y, z)
		if x ~= nil then self:set_word(REG.GYRO_XH, mpu6050_clamp_word(x)) end
		if y ~= nil then self:set_word(REG.GYRO_XH + 2, mpu6050_clamp_word(y)) end
		if z ~= nil then self:set_word(REG.GYRO_XH + 4, mpu6050_clamp_word(z)) end
		return self
	end

	-- TEMP_OUT 有符号原始值
	function m:set_temp_raw(raw)
		self:set_word(REG.TEMP_H, mpu6050_clamp_word(raw))
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
		local k = MPU6050_VIRT.ACCEL_LSB_PER_G
		return self:set_accel(
			gx ~= nil and gx * k or nil,
			gy ~= nil and gy * k or nil,
			gz ~= nil and gz * k or nil)
	end

	function m:set_gyro_dps(dx, dy, dz)
		local k = MPU6050_VIRT.GYRO_LSB_PER_DPS
		return self:set_gyro(
			dx ~= nil and dx * k or nil,
			dy ~= nil and dy * k or nil,
			dz ~= nil and dz * k or nil)
	end

	function m:set_temp_c(degC)
		return self:set_temp_raw((degC - MPU6050_VIRT.TEMP_OFFSET_DEG) * MPU6050_VIRT.TEMP_LSB_PER_DEG)
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
		self:set(REG.WHO_AM_I, val)
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

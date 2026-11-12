-- regmap.lua —— 通用「寄存器指针 + burst」虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- 覆盖绝大多数 I2C 传感器的事务形态（MPU6050/BME280/ADS1115/INA226…）：
--   write {reg}          设置读指针（随后的读事务从该寄存器连续 burst）
--   write {reg, v...}    写连续寄存器
--   read(n)              从当前指针 burst n 字节，读后指针自增（边界回绕）
-- 16 位寄存器指针器件（ST VL53Lx 族）构造时传 { ptr16 = true }：
--   write {hi, lo}       设置 16 位读指针
--   write {hi, lo, v...} 写 16 位指针寄存器
--
-- 纯 Lua，不依赖 ffi；既可挂到 vbus.attach 跑真实驱动，也可脱离总线直接单测。
--
-- 用法：
--   local regmap = dofile("modules/lib/virtbus/regmap.lua")
--   local imu = regmap.new({ [0x75] = 0x68 })   -- 初始寄存器内容（地址→字节）
--   imu:set_word(0x3B, -1234)                    -- 预置大端 16 位补码
--   vbus.attach("MPU6050@0x68", 0x68, imu)
--
--   imu.nack = true       -- 故障注入：读写全 NACK
--   imu.nack_write = true -- 定向故障：仅写 NACK（读仍正常，模拟只读方向异常）
--   imu.nack_read = true  -- 定向故障：仅读 NACK（配置写可过、测量读失败）
--   imu:set(0x3B, 0x12)   -- 用例中动态改寄存器，模拟实测数据变化
--
-- 【边界约定】模型只复现协议层事实（寄存器地址、字节序、burst 自增），不实现
-- 芯片测量逻辑——"实测值"由测试显式 set 注入，避免模型与驱动按同一错误理解
-- 互证导致假绿。器件特有的换算/语义请建独立模型文件（参考 bh1750.lua）。

local regmap = {}
regmap._VERSION = "0.1.0"

function regmap.new(init, opts)
	opts = opts or {}
	local ptr_mod = opts.ptr16 and 65536 or 256

	local m = {}
	m.regs = {}			-- 寄存器地址（0~ptr_mod-1）→ 字节值
	m.ptr = 0			-- 当前读指针
	m.nack = false		-- 故障注入：读写全 NACK
	m.nack_write = false-- 定向故障：仅写 NACK（读仍正常）
	m.nack_read = false	-- 定向故障：仅读 NACK（配置写可过、测量读失败）
	m.write_log = {}	-- 收到的全部写事务（字节表副本），供断言

	local function seed(src)
		for k, v in pairs(src or {}) do
			m.regs[math.floor(k) % ptr_mod] = math.floor(v) % 256
		end
	end
	seed(init)

	local function log_write(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] end
		m.write_log[#m.write_log + 1] = cp
	end

	-- virtbus 设备接口：注意总线以 dev.write(bytes) 无 self 形式调用，
	-- 故用点定义为闭包（: 方法仅供测试代码显式调用）。
	function m.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_write(bytes)
		if m.nack or m.nack_write then return false end

		if opts.ptr16 then
			if #bytes < 2 then return false end
			local p = (bytes[1] % 256) * 256 + (bytes[2] % 256)
			if #bytes == 2 then
				m.ptr = p	-- 纯指针
			else
				-- 16 位指针 + 数据：指针按器件自增连续写
				for i = 3, #bytes do
					m.regs[(p + i - 3) % 65536] = bytes[i] % 256
				end
			end
		else
			if #bytes == 1 then
				m.ptr = bytes[1] % 256	-- 纯指针
			else
				local base = bytes[1] % 256
				for i = 2, #bytes do
					m.regs[(base + i - 2) % 256] = bytes[i] % 256
				end
			end
		end
		return true
	end

	function m.read(n)
		if m.nack or m.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end
		local t = {}
		for _ = 1, n do
			t[#t + 1] = m.regs[m.ptr] or 0	-- 未预置的寄存器读 0（与多数上电态一致）
			m.ptr = (m.ptr + 1) % ptr_mod
		end
		return t
	end

	-- ---------------- 测试辅助 ----------------

	-- 置单个寄存器字节；返回 self 便于链式调用
	function m:set(reg, val)
		self.regs[math.floor(reg) % ptr_mod] = math.floor(val) % 256
		return self
	end

	function m:get(reg)
		return self.regs[math.floor(reg) % ptr_mod]
	end

	-- 预置/读取大端 16 位值；set_word 接受有符号整数（自动转补码）
	function m:set_word(reg, word)
		word = math.floor(word) % 65536
		reg = math.floor(reg) % ptr_mod
		self.regs[reg] = math.floor(word / 256) % 256
		self.regs[(reg + 1) % ptr_mod] = word % 256
		return self
	end

	function m:get_word(reg)
		reg = math.floor(reg) % ptr_mod
		return (self.regs[reg] or 0) * 256 + (self.regs[(reg + 1) % ptr_mod] or 0)
	end

	-- 读回并按 16 位补码解释为有符号整数
	function m:get_sword(reg)
		local u = self:get_word(reg)
		if u >= 32768 then u = u - 65536 end
		return u
	end

	function m:clear_log()
		self.write_log = {}
		return self
	end

	-- 回到构造态：寄存器重新种子、指针归零、故障清除
	function m:reset(new_init)
		self.regs = {}
		seed(new_init or init)
		self.ptr = 0
		self.nack = false
		self.nack_write = false
		self.nack_read = false
		self.write_log = {}
		return self
	end

	return m
end

return regmap

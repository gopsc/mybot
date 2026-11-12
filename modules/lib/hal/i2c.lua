-- hal/i2c.lua —— HAL 的 I2C 域（含 16 位寄存器指针器件）
-- bot4cj 仓颉语言机器人框架
--
-- 本文件是 modules/lib/HAL.lua 的**分块**，不是可独立加载的模块：由门面按序
-- loadfile 后以 ctx 表传入共享上下文（见门面「各总线域加载」段）。
-- 正文自 HAL.lua 逐字搬迁（26.2 按域拆分），注释与错误文案未改写。
local ctx = assert(..., "hal/i2c.lua 须由 modules/lib/HAL.lua 聚合加载（不支持单独 dofile）")
local HAL, ffi, bus, byte_of = ctx.HAL, ctx.ffi, ctx.bus, ctx.byte_of
local uint_of, bus_quiesced, O_RDWR = ctx.uint_of, ctx.bus_quiesced, ctx.O_RDWR

------------------------------------------------------------------
-- I2C（fd 为真实内核句柄，跨 Lua 状态机有效）
------------------------------------------------------------------

-- 打开 I2C 总线，成功返回 fd（>=0），失败返回 -1
function i2c_open(path)
	if not bus.i2c_path_ok(path) then
		print("HAL: invalid i2c path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, O_RDWR + HAL.O_CLOEXEC))
	if fd == nil or fd < 0 then
		print("HAL: failed to open i2c bus: " .. path)
		return -1
	end
	return fd
end

function i2c_close(fd)
	fd = tonumber(fd)
	if fd ~= nil and fd >= 0 then
		HAL.sys.close(fd)
		HAL.i2c_addr[fd] = nil
	end
end

-- 设置从设备地址：仅记录到 per-fd 地址表。
-- I2C_RDWR 每条消息自带地址，无需 I2C_SLAVE ioctl，也就没有 EBUSY/地址被占用问题。
--
-- 【26.3 盘点留档：下面 `fd < 0` 这道守卫是九个驱动 destroy 回调的唯一防线】
-- ADS1015/APDS9900/BME688/MAX30102/MCP3421/PCA9685/SGP30/VL53L0X/VL53L4CD 的
-- destroy 写的是 `fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr)`，而
-- BME280 的 destroy 多写一道 `fd >= 0`。评估后**不给那九处补校验**：destroy 的
-- data.fd / data.address 来自宿主的引用列快照（src/luavar.cpp 的 getMetadata_(true)，
-- 取自 `$i2c-N` 总线变量），恒为 open() 返回的整数，'nan'/'-' 之类非有限值到不了
-- 这里；唯一可达的坏值 -1（open 失败）由本守卫挡下，两种写法结论逐字相同。
-- 给不可达分支加校验只会模糊「真防线在哪一层」。
-- 反向约束：改动本守卫前先读这段——那九处的安全性以它为前提。
function i2c_set_addr(fd, addr)
	fd = tonumber(fd)
	addr = uint_of(addr)
	-- 审计 #10：fd<0（open 失败返回 -1）不得登记进地址表，否则后续误用
	-- 该句柄时排查困难——在登记处就拒绝
	if fd == nil or fd < 0 or addr == nil or addr > 0x7F then
		print("HAL: i2c_set_addr invalid args: " .. tostring(fd) .. ", " .. tostring(addr))
		return false
	end
	HAL.i2c_addr[fd] = addr
	return true
end

-- 内部：执行一次 I2C_RDWR 原子事务（msgs 为 cj_i2c_msg[n]），返回内核传输数或负值
-- 2026-09-30 方案 A 重构：组装 cj_i2c_rdwr 结构 + ioctl 下沉到后端原语
local function i2c_rdwr(fd, msgs, nmsgs)
	if bus_quiesced() then return -1 end
	return HAL.sys.i2c_rdwr(fd, msgs, nmsgs)
end

-- 内部：读缓冲区 n 字节按大端合并
local function be_merge(buf, n)
	local v = 0
	for i = 0, n - 1 do v = v * 256 + tonumber(buf[i]) end
	return v
end

-- 写寄存器（单条写消息 {reg,val}，原子），成功返回 true
function i2c_write_reg(fd, reg, val)
	fd = tonumber(fd)
	reg, val = byte_of(reg), byte_of(val)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg == nil or val == nil or addr == nil then return false end
	local buf = ffi.new("uint8_t[2]", reg, val)
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = 0; msgs[0].len = 2; msgs[0].buf = buf
	return i2c_rdwr(fd, msgs, 1) >= 0
end

-- 读寄存器（写指针 + 读 合并为单次原子事务），返回 0~255；失败返回 -1
function i2c_read_reg(fd, reg)
	fd = tonumber(fd)
	reg = byte_of(reg)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg == nil or addr == nil then return -1 end
	local wb = ffi.new("uint8_t[1]", reg)
	local rb = ffi.new("uint8_t[1]")
	local msgs = ffi.new("cj_i2c_msg[2]")
	msgs[0].addr = addr; msgs[0].flags = 0;            msgs[0].len = 1; msgs[0].buf = wb
	msgs[1].addr = addr; msgs[1].flags = HAL.I2C_M_RD; msgs[1].len = 1; msgs[1].buf = rb
	if i2c_rdwr(fd, msgs, 2) < 0 then return -1 end
	return tonumber(rb[0])
end

-- 写寄存器+多字节数据（单条写消息，原子），返回 0 = 成功，-1 = 失败
function i2c_write_multi(fd, reg, ...)
	fd = tonumber(fd)
	reg = byte_of(reg)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg == nil or addr == nil then return -1 end
	local data = { reg }
	for _, v in ipairs({ ... }) do
		local b = byte_of(v)
		if b == nil then return -1 end
		data[#data + 1] = b
	end
	-- 数据字节上限（不含寄存器指针）：超长即拒绝，避免打包超大 buf 后
	-- 发往内核被静默截断/报 EINVAL（I2C_IO_MAX_BYTES，见 bus_contract）。
	if #data - 1 > bus.I2C_IO_MAX_BYTES then return -1 end
	local buf = ffi.new("uint8_t[?]", #data)
	for i, b in ipairs(data) do buf[i - 1] = b end
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = 0; msgs[0].len = #data; msgs[0].buf = buf
	if i2c_rdwr(fd, msgs, 1) >= 0 then return 0 end
	return -1
end

-- 写指针后读 n 字节（合并为单次原子事务），返回 1 基字节表 {b0, b1, ...}；
-- 失败返回 nil。与 i2c_read_multi 同一内核事务，但返回字节表、不受 Lua
-- number 2^53 精度限制——多字节块读（BH1745 颜色 8B / BMI270 六轴 12B 等）
-- 请用此接口。n 钳制 1~16。
function i2c_read_multi_bytes(fd, reg, n)
	fd = tonumber(fd)
	reg = byte_of(reg)
	n = uint_of(n)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg == nil or n == nil or addr == nil then return nil end
	if n < 1 then n = 1 end
	if n > bus.BYTES_READ_MAX then n = bus.BYTES_READ_MAX end
	local wb = ffi.new("uint8_t[1]", reg)
	local rb = ffi.new("uint8_t[?]", n)
	local msgs = ffi.new("cj_i2c_msg[2]")
	msgs[0].addr = addr; msgs[0].flags = 0;            msgs[0].len = 1; msgs[0].buf = wb
	msgs[1].addr = addr; msgs[1].flags = HAL.I2C_M_RD; msgs[1].len = n; msgs[1].buf = rb
	if i2c_rdwr(fd, msgs, 2) < 0 then return nil end
	local t = {}
	for i = 0, n - 1 do t[i + 1] = tonumber(rb[i]) end
	return t
end

-- 写指针后读 n 字节（合并为单次原子事务），返回大端合并值；失败返回 -1。
-- 注意合并值为 Lua number：6 字节以上（2^48）将超 2^53 精度被静默截断，
-- 因此 n 有效范围 1~6，越界（含非法值）显式返回 -1——静默钳到 1 字节会把
-- 长度错位放大成错误合并值；更长块读请用 i2c_read_multi_bytes。
function i2c_read_multi(fd, reg, n)
	n = uint_of(n)
	if n == nil or n < 1 or n > bus.MERGED_READ_MAX then return -1 end
	local t = i2c_read_multi_bytes(fd, reg, n)
	if t == nil then return -1 end
	local v = 0
	for i = 1, #t do v = v * 256 + t[i] end
	return v
end

-- 纯读 n 字节（单条读消息，不写指针，SGP30 这类命令式传感器用），大端合并；失败返回 -1
-- n 有效范围 1~6（2^53 精度上限，同 i2c_read_multi：7 字节起大端合并值可能
-- 超 2^53 被静默截断），越界（含非法值）显式返回 -1：静默钳制会被调用方的
-- 拆字节数学放大成错误数据；更长纯读请用 i2c_read_bytes（字节表不受精度限制）
function i2c_read(fd, n)
	fd = tonumber(fd)
	n = uint_of(n)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or n == nil or addr == nil then return -1 end
	if n < 1 or n > bus.MERGED_READ_MAX then return -1 end
	local rb = ffi.new("uint8_t[?]", n)
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = HAL.I2C_M_RD; msgs[0].len = n; msgs[0].buf = rb
	if i2c_rdwr(fd, msgs, 1) < 0 then return -1 end
	return be_merge(rb, n)
end

------------------------------------------------------------------
-- 16 位寄存器指针器件（ST VL53Lx ToF 族：寄存器地址 16 位、值大端多字节）。
-- 「写 2 字节指针 + 读数据」合并为单次 I2C_RDWR 原子事务——若拆成两段事务，
-- 会重新引入同器件并发访问时的寄存器指针竞态（见本文件 I2C_RDWR 注释）。
------------------------------------------------------------------

-- 写 16 位指针寄存器 + 数据字节（单条写消息，原子），返回 0 = 成功，-1 = 失败
-- 用法：i2c_write_reg16(fd, 0x0087, 0x21) 单字节；
--       i2c_write_reg16(fd, 0x002D, b1, b2, ...) 连续流写（器件指针自增）
function i2c_write_reg16(fd, reg16, ...)
	fd = tonumber(fd)
	reg16 = uint_of(reg16)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg16 == nil or reg16 > 0xFFFF or addr == nil then return -1 end
	local data = {}
	for _, v in ipairs({ ... }) do
		local b = byte_of(v)
		if b == nil then return -1 end
		data[#data + 1] = b
	end
	-- 数据字节上限（不含 2 字节寄存器指针）：超长即拒绝（I2C_IO_MAX_BYTES）。
	if #data > bus.I2C_IO_MAX_BYTES then return -1 end
	local buf = ffi.new("uint8_t[?]", #data + 2)
	buf[0] = math.floor(reg16 / 256) % 256
	buf[1] = reg16 % 256
	for i, b in ipairs(data) do buf[i + 1] = b end
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = 0; msgs[0].len = #data + 2; msgs[0].buf = buf
	if i2c_rdwr(fd, msgs, 1) >= 0 then return 0 end
	return -1
end

-- 写 16 位指针后读 n 字节（合并为单次原子事务），返回大端合并值；失败返回 -1。
-- n 有效范围 1~6（2^53 精度上限，同 i2c_read_multi；本族寄存器最长 dword=4），
-- 越界显式返回 -1（静默钳制危害同 i2c_read_multi）
function i2c_read_reg16(fd, reg16, n)
	fd = tonumber(fd)
	reg16 = uint_of(reg16)
	n = uint_of(n)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or reg16 == nil or reg16 > 0xFFFF or n == nil or addr == nil then return -1 end
	if n < 1 or n > bus.MERGED_READ_MAX then return -1 end
	local wb = ffi.new("uint8_t[2]", math.floor(reg16 / 256) % 256, reg16 % 256)
	local rb = ffi.new("uint8_t[?]", n)
	local msgs = ffi.new("cj_i2c_msg[2]")
	msgs[0].addr = addr; msgs[0].flags = 0;            msgs[0].len = 2; msgs[0].buf = wb
	msgs[1].addr = addr; msgs[1].flags = HAL.I2C_M_RD; msgs[1].len = n; msgs[1].buf = rb
	if i2c_rdwr(fd, msgs, 2) < 0 then return -1 end
	return be_merge(rb, n)
end

-- 纯读 n 字节（单条读消息），逐字节返回 1 基表 { b1, b2, ... }；失败返回 nil
-- 与 i2c_read 的区别：不按大端合并——合并值超过 2^53（约 7 字节）后 double
-- 精度不保，命令式器件的长应答（如 MLX90393 的 XYZT+status 共 9 字节）
-- 必须逐字节取。n 钳制 1~16（对齐 i2c_read_multi_bytes；字节表版保留钳制
-- 的理由同 0.3.1 决策——表长对调用方可见。原实现 n<1 反向钳到 16，
-- 请求 0 字节反而读出 16 字节超长表）
function i2c_read_bytes(fd, n)
	fd = tonumber(fd)
	n = uint_of(n)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or n == nil or addr == nil then return nil end
	if n < 1 then n = 1 end
	if n > bus.BYTES_READ_MAX then n = bus.BYTES_READ_MAX end
	local rb = ffi.new("uint8_t[?]", n)
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = HAL.I2C_M_RD; msgs[0].len = n; msgs[0].buf = rb
	if i2c_rdwr(fd, msgs, 1) < 0 then return nil end
	local b = {}
	for i = 0, n - 1 do b[i + 1] = tonumber(rb[i]) end
	return b
end

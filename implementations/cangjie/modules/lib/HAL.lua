-- HAL.lua - 基层硬件抽象层（LuaJIT ffi，位于 modules/lib/）
-- bot4cj 仓颉语言机器人框架
--
-- issue #14：完全解耦的基层硬件应用层驱动——不再依赖仓颉注册的 cfunc。
--
-- 【运行环境】仅支持 LuaJIT：经 ffi 直调 glibc（open/ioctl/read/write/close/usleep），
-- 原生性能，fd 为真实内核句柄，跨 Lua 状态机天然有效。
-- （原 i2c-tools/spi-tools shell-out 降级后端 HAL_shell.lua 已移除。）
--
-- 【安全】设备路径经白名单模式校验；所有数值参数 tonumber + 范围校验后才进入
-- ioctl/缓冲区，无 shell 参与。
--
-- 【可测试性】系统调用统一走 HAL.sys.* 间接层，离线单测（test/test_hal_ffi.lua）
-- 注入 mock 即可验证调用序列与缓冲区内容。
--
-- 【delay 说明】delay_usecs 是逐次传输参数，内核无 per-fd 持久化 ioctl；
-- 需要延时的驱动经传输函数的 delay_us 尾参显式传入（参考 ADS1256.lua：
-- delay 配置在 @SPI 矩阵，由 SPI.lua 的 call() 随 fd 一并返回，
-- 经元数据引用机制流入设备驱动，驱动统一附带在每次传输上）。

-- 重复加载保护：同一状态机内只初始化一次
if _G.__BOT4CJ_HAL ~= nil then return _G.__BOT4CJ_HAL end

-- 环境检查：必须有 ffi（LuaJIT）；shell 降级后端已移除
local has_ffi, ffi = false, nil
if rawget(_G, "jit") ~= nil then
	has_ffi, ffi = pcall(require, "ffi")
end
if not has_ffi then
	error("HAL requires LuaJIT with ffi (the shell-out fallback backend has been removed)")
end

------------------------------------------------------------------
-- ffi 声明（glibc + Linux spidev ABI）
------------------------------------------------------------------
ffi.cdef[[
int  open(const char *pathname, int flags, ...);
int  close(int fd);
int  ioctl(int fd, unsigned long request, ...);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int  usleep(unsigned int usec);

/* /usr/include/linux/spi/spidev.h（内核 6.18），共 32 字节 */
typedef struct {
	unsigned long long tx_buf;
	unsigned long long rx_buf;
	unsigned int       len;
	unsigned int       speed_hz;
	unsigned short     delay_usecs;
	unsigned char      bits_per_word;
	unsigned char      cs_change;
	unsigned char      tx_nbits;
	unsigned char      rx_nbits;
	unsigned char      word_delay_usecs;
	unsigned char      pad;
} spi_ioc_transfer;

/* /usr/include/linux/i2c.h：I2C_RDWR 原子事务（写指针+读合并为单次内核传输） */
typedef struct {
	unsigned short  addr;
	unsigned short  flags;
	unsigned short  len;
	unsigned char  *buf;
} cj_i2c_msg;
typedef struct {
	cj_i2c_msg   *msgs;
	unsigned int  nmsgs;
} cj_i2c_rdwr;
]]

-- 布局自检：结构体尺寸与内核头文件不符则立即失败（防止静默内存越界）
assert(ffi.sizeof("spi_ioc_transfer") == 32,
	"spi_ioc_transfer size mismatch: expect 32, got " .. ffi.sizeof("spi_ioc_transfer"))
assert(ffi.sizeof("cj_i2c_msg") == 16,
	"cj_i2c_msg size mismatch: expect 16, got " .. ffi.sizeof("cj_i2c_msg"))

local HAL = {}
_G.__BOT4CJ_HAL = HAL
HAL.backend = "ffi"

------------------------------------------------------------------
-- 常量
------------------------------------------------------------------
local O_RDWR = 2
HAL.I2C_RDWR = 0x0707		-- i2c-dev 原子多消息事务
HAL.I2C_M_RD = 0x0001		-- i2c_msg.flags：读（0 为写）
HAL.i2c_addr = {}		-- fd -> 7位从地址（per-state；每条 i2c_msg 自带地址，无需 I2C_SLAVE ioctl）

-- ioctl 编号按 _IOC(dir=WRITE(1)<<30 | size<<16 | type('k'=0x6b)<<8 | nr) 计算
HAL.SPI_IOC_WR_MODE          = 0x40016b01	-- _IOW('k', 1, __u8)
HAL.SPI_IOC_WR_BITS_PER_WORD = 0x40016b03	-- _IOW('k', 3, __u8)
HAL.SPI_IOC_WR_MAX_SPEED_HZ  = 0x40046b04	-- _IOW('k', 4, __u32)
HAL.SPI_IOC_MESSAGE_1        = 0x40206b00	-- _IOW('k', 0, spi_ioc_transfer[1])

------------------------------------------------------------------
-- 系统调用间接层（离线单测在此注入 mock）
------------------------------------------------------------------
HAL.sys = {
	-- mode：可选的 open 第三参（O_CREAT 场景的权限位，如 0x1A4=0644），
	-- 变参显式 cast 理由同下 ioctl_i
	open    = function(path, flags, mode)
		if mode ~= nil then
			return ffi.C.open(path, flags, ffi.cast("unsigned int", mode))
		end
		return ffi.C.open(path, flags)
	end,
	close   = function(fd)          return ffi.C.close(fd) end,
	-- 变参必须显式 cast：JIT 编译后 Lua number 会以 double 位模式传入变参
	-- （ioctl 收到 0x4050... > 0x7f → EINVAL），解释执行却传 int——
	-- cast 为 unsigned long cdata 后两种执行路径 ABI 一致（第 58 次调用起复现）
	ioctl_i = function(fd, req, val)
		return ffi.C.ioctl(fd, req, ffi.cast("unsigned long", val))
	end,
	ioctl_p = function(fd, req, ptr) return ffi.C.ioctl(fd, req, ptr) end,
	read    = function(fd, buf, n)  return tonumber(ffi.C.read(fd, buf, n)) end,
	write   = function(fd, buf, n)  return tonumber(ffi.C.write(fd, buf, n)) end,
	usleep  = function(us)          return ffi.C.usleep(us) end,
	errno   = function()            return ffi.errno() end,
	-- UART termios（glibc 直接调用；termios 以 void* 传递避免分架构布局差异）
	tcgetattr = function(fd, ptr)   return ffi.C.tcgetattr(fd, ptr) end,
	tcsetattr = function(fd, act, ptr) return ffi.C.tcsetattr(fd, act, ptr) end,
	cfmakeraw = function(ptr)       ffi.C.cfmakeraw(ptr) end,
	cfsetispeed = function(ptr, baud) return ffi.C.cfsetispeed(ptr, baud) end,
	cfsetospeed = function(ptr, baud) return ffi.C.cfsetospeed(ptr, baud) end,
	tcflush   = function(fd, q)     return ffi.C.tcflush(fd, q) end,
}

------------------------------------------------------------------
-- 参数归一化
------------------------------------------------------------------
-- 归一化为 0~255 的整数，非法返回 nil
local function byte_of(v)
	local n = tonumber(v)
	if n == nil then return nil end
	n = math.floor(n)
	if n < 0 or n > 255 then return nil end
	return n
end

-- 归一化为非负整数，非法返回 nil
local function uint_of(v)
	local n = tonumber(v)
	if n == nil then return nil end
	n = math.floor(n)
	if n < 0 then return nil end
	return n
end

------------------------------------------------------------------
-- I2C（fd 为真实内核句柄，跨 Lua 状态机有效）
------------------------------------------------------------------

-- 打开 I2C 总线，成功返回 fd（>=0），失败返回 -1
function i2c_open(path)
	if type(path) ~= "string" then return -1 end
	if string.match(path, "^/dev/i2c%-%d+$") == nil then
		print("HAL: invalid i2c path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, O_RDWR))
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
function i2c_set_addr(fd, addr)
	fd = tonumber(fd)
	addr = uint_of(addr)
	if fd == nil or addr == nil or addr > 0x7F then
		print("HAL: i2c_set_addr invalid args: " .. tostring(fd) .. ", " .. tostring(addr))
		return false
	end
	HAL.i2c_addr[fd] = addr
	return true
end

-- 内部：执行一次 I2C_RDWR 原子事务（msgs 为 cj_i2c_msg[n]），返回内核传输数或负值
local function i2c_rdwr(fd, msgs, nmsgs)
	local data = ffi.new("cj_i2c_rdwr[1]")
	data[0].msgs = msgs
	data[0].nmsgs = nmsgs
	return HAL.sys.ioctl_p(fd, HAL.I2C_RDWR, data)
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
	if n > 16 then n = 16 end
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
	if n == nil or n < 1 or n > 6 then return -1 end
	local t = i2c_read_multi_bytes(fd, reg, n)
	if t == nil then return -1 end
	local v = 0
	for i = 1, #t do v = v * 256 + t[i] end
	return v
end

-- 纯读 n 字节（单条读消息，不写指针，SGP30 这类命令式传感器用），大端合并；失败返回 -1
-- n 有效范围 1~8，越界（含非法值）显式返回 -1：静默钳到 1 字节会被调用方的
-- 拆字节数学放大成错误数据；更长纯读请用 i2c_read_bytes
function i2c_read(fd, n)
	fd = tonumber(fd)
	n = uint_of(n)
	local addr = HAL.i2c_addr[fd]
	if fd == nil or n == nil or addr == nil then return -1 end
	if n < 1 or n > 8 then return -1 end
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
	if n < 1 or n > 6 then return -1 end
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
	if n > 16 then n = 16 end
	local rb = ffi.new("uint8_t[?]", n)
	local msgs = ffi.new("cj_i2c_msg[1]")
	msgs[0].addr = addr; msgs[0].flags = HAL.I2C_M_RD; msgs[0].len = n; msgs[0].buf = rb
	if i2c_rdwr(fd, msgs, 1) < 0 then return nil end
	local b = {}
	for i = 0, n - 1 do b[i + 1] = tonumber(rb[i]) end
	return b
end

------------------------------------------------------------------
-- 延时
------------------------------------------------------------------
-- 毫秒级延时（usleep，零 fork）
function milli_sleep(ms)
	ms = tonumber(ms)
	if ms == nil or ms <= 0 then return end
	HAL.sys.usleep(math.floor(ms * 1000))
end

------------------------------------------------------------------
-- SPI（spidev ioctl；fd 为真实内核句柄）
------------------------------------------------------------------

-- 打开 SPI 设备，成功返回 fd（>=0），失败返回 -1
function spi_open(path)
	if type(path) ~= "string" then return -1 end
	if string.match(path, "^/dev/spidev%d+%.%d+$") == nil then
		print("HAL: invalid spi path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, O_RDWR))
	if fd == nil or fd < 0 then
		print("HAL: failed to open spi device: " .. path)
		return -1
	end
	return fd
end

function spi_close(fd)
	fd = tonumber(fd)
	if fd ~= nil and fd >= 0 then HAL.sys.close(fd) end
end

-- 配置 SPI 设备，返回 0 = 成功，-1 = 失败
-- mode/bits/speed 经 ioctl 持久化到 fd（跨状态机有效）；
-- delay 无 per-fd 持久化途径：请由驱动在每次传输时经 delay_us 尾参显式传入
-- （spi_write/spi_read/spi_write3/spi_read_multi 均支持）。
function spi_setup(fd, mode, bits, speed, delay)
	fd = tonumber(fd)
	mode, bits, speed = uint_of(mode), uint_of(bits), uint_of(speed)
	if fd == nil or mode == nil or mode > 3
	   or bits == nil or bits < 7 or bits > 16
	   or speed == nil or speed <= 0 then
		print("HAL: spi_setup invalid args: mode=" .. tostring(mode) ..
		      " bits=" .. tostring(bits) .. " speed=" .. tostring(speed))
		return -1
	end
	if tonumber(delay) ~= nil and tonumber(delay) > 0 then
		print("HAL: spi_setup delay cannot persist on fd; pass delay_us per transfer instead")
	end

	local m8 = ffi.new("uint8_t[1]", mode)
	if HAL.sys.ioctl_p(fd, HAL.SPI_IOC_WR_MODE, m8) ~= 0 then return -1 end
	local b8 = ffi.new("uint8_t[1]", bits)
	if HAL.sys.ioctl_p(fd, HAL.SPI_IOC_WR_BITS_PER_WORD, b8) ~= 0 then return -1 end
	local s32 = ffi.new("uint32_t[1]", speed)
	if HAL.sys.ioctl_p(fd, HAL.SPI_IOC_WR_MAX_SPEED_HZ, s32) ~= 0 then return -1 end
	return 0
end

-- 内部：单次 SPI 事务（一条 message，CS 保持低）。
-- tx/rx 为 uint8_t 缓冲区 cdata（nil 表示该方向不使用）；len 为字节数。
-- speed_hz/bits_per_word 填 0：内核自动沿用 fd 上 spi_setup 配置的值。
-- delay_us：可选，本次传输最后一位之后、CS 拉高之前的等待微秒数
-- （内核无 per-fd 持久化途径，由驱动逐次显式传入，__u16 钳制到 65535）。
local function spi_xfer(fd, tx, rx, len, delay_us)
	local msg = ffi.new("spi_ioc_transfer[1]")	-- ffi.new 零初始化
	msg[0].len = len
	delay_us = uint_of(delay_us)
	if delay_us ~= nil then
		if delay_us > 65535 then delay_us = 65535 end
		msg[0].delay_usecs = delay_us
	end
	if tx ~= nil then
		msg[0].tx_buf = ffi.cast("unsigned long long", ffi.cast("const uint8_t *", tx))
	end
	if rx ~= nil then
		msg[0].rx_buf = ffi.cast("unsigned long long", ffi.cast("uint8_t *", rx))
	end
	local r = HAL.sys.ioctl_p(fd, HAL.SPI_IOC_MESSAGE_1, msg)
	return r ~= nil and r >= 0
end

-- 写 1 字节，返回 0 = 成功，-1 = 失败；delay_us 可选（CS 拉高前等待）
function spi_write(fd, val, delay_us)
	fd = tonumber(fd)
	val = byte_of(val)
	if fd == nil or val == nil then return -1 end
	local buf = ffi.new("uint8_t[1]", val)
	if spi_xfer(fd, buf, nil, 1, delay_us) then return 0 end
	return -1
end

-- 读 1 字节（发一个 dummy 字节），返回 0~255；失败返回 -1；delay_us 可选
function spi_read(fd, delay_us)
	fd = tonumber(fd)
	if fd == nil then return -1 end
	local buf = ffi.new("uint8_t[1]")
	if not spi_xfer(fd, nil, buf, 1, delay_us) then return -1 end
	return tonumber(buf[0])
end

-- 一次写 3 字节（单次传输，CS 保持低），返回 0 = 成功，-1 = 失败；delay_us 可选
function spi_write3(fd, b0, b1, b2, delay_us)
	fd = tonumber(fd)
	b0, b1, b2 = byte_of(b0), byte_of(b1), byte_of(b2)
	if fd == nil or b0 == nil or b1 == nil or b2 == nil then return -1 end
	local buf = ffi.new("uint8_t[3]", b0, b1, b2)
	if spi_xfer(fd, buf, nil, 3, delay_us) then return 0 end
	return -1
end

-- 一次写一帧任意长度字节（单次传输，CS 保持低），返回 0 = 成功，-1 = 失败；
-- delay_us 可选。data 为 1 基字节值表（如 {0x21, 0x00}）——以表传参避免与
-- spi_write3 的尾参 delay_us 语义冲突。16 位字帧器件（AD9833 等）用此接口。
function spi_write_multi(fd, data, delay_us)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return -1 end
	if #data > 64 then return -1 end
	local buf = ffi.new("uint8_t[?]", #data)
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		buf[i - 1] = b
	end
	if spi_xfer(fd, buf, nil, #data, delay_us) then return 0 end
	return -1
end

-- 一次读 n 字节（单次传输），返回大端合并值；失败返回 -1（n 有效范围 1~8，
-- 越界显式返回 -1，静默钳制危害同 i2c_read_multi）；delay_us 可选
function spi_read_multi(fd, n, delay_us)
	fd = tonumber(fd)
	n = uint_of(n)
	if fd == nil or n == nil then return -1 end
	if n < 1 or n > 8 then return -1 end
	local buf = ffi.new("uint8_t[?]", n)
	if not spi_xfer(fd, nil, buf, n, delay_us) then return -1 end
	local v = 0
	for i = 0, n - 1 do
		v = v * 256 + tonumber(buf[i])
	end
	return v
end

------------------------------------------------------------------
-- GPIO（gpiod uAPI ABI v1：/dev/gpiochipN ioctl）
------------------------------------------------------------------
-- 内核标准接口（>= 4.8），跨 SoC 通用：树莓派/瑞芯微/全志等仅路径与
-- 线号不同。结构体全部定宽字段，x86_64/aarch64 布局一致。
-- ioctl 编号经 test/test_ioctl_nums.c 与系统头文件实证。

HAL.GPIO_GET_LINEHANDLE         = 0xC16CB403	-- _IOWR(0xB4, 0x03, gpiohandle_request)
HAL.GPIOHANDLE_GET_LINE_VALUES  = 0xC040B408	-- _IOWR(0xB4, 0x08, gpiohandle_data)
HAL.GPIOHANDLE_SET_LINE_VALUES  = 0xC040B409	-- _IOWR(0xB4, 0x09, gpiohandle_data)
-- 注意：HAL 运行于 LuaJIT（5.1），无 << 运算符，标志位用字面量（INPUT=1<<0 等）
HAL.GPIOHANDLE_REQUEST_INPUT      = 1
HAL.GPIOHANDLE_REQUEST_OUTPUT     = 2
HAL.GPIOHANDLE_REQUEST_ACTIVE_LOW = 4

ffi.cdef[[
/* /usr/include/linux/gpio.h（ABI v1，deprecated 但全内核支持；uAPI v2 结构含
 * __u64 对齐字段与位掩码语义，对 Lua 侧过重，基础输入输出用 v1 足够） */
typedef struct {
	unsigned int lineoffsets[64];
	unsigned int flags;
	unsigned char default_values[64];
	char consumer_label[32];
	unsigned int lines;
	int fd;
} cj_gpiohandle_request;
typedef struct {
	unsigned char values[64];
} cj_gpiohandle_data;
]]

-- 结构体尺寸自检（防 ABI 静默漂移；字段全定宽，两架构同值）
assert(ffi.sizeof("cj_gpiohandle_request") == 364,
	"gpiohandle_request size mismatch: expect 364, got " .. ffi.sizeof("cj_gpiohandle_request"))
assert(ffi.sizeof("cj_gpiohandle_data") == 64,
	"gpiohandle_data size mismatch: expect 64, got " .. ffi.sizeof("cj_gpiohandle_data"))

-- 请求一条 GPIO 线，返回句柄 fd（供 set/get 使用）；失败返回 -1
-- direction: "out" | "in"；default_value：输出模式的上电值（0/1）
-- active_low：true = 低电平有效（可选）
function gpio_request_line(chip_path, offset, direction, default_value, active_low)
	if type(chip_path) ~= "string" then return -1 end
	if string.match(chip_path, "^/dev/gpiochip%d+$") == nil then
		print("HAL: invalid gpiochip path: " .. tostring(chip_path))
		return -1
	end
	offset = tonumber(offset)
	if offset == nil or offset < 0 or offset > 0xFFFFFFFF then return -1 end

	local chipfd = tonumber(HAL.sys.open(chip_path, O_RDWR))
	if chipfd == nil or chipfd < 0 then
		print("HAL: failed to open gpiochip: " .. chip_path)
		return -1
	end

	local flags
	if direction == "out" then
		flags = HAL.GPIOHANDLE_REQUEST_OUTPUT
	else
		flags = HAL.GPIOHANDLE_REQUEST_INPUT
	end
	if active_low then
		flags = flags + HAL.GPIOHANDLE_REQUEST_ACTIVE_LOW		-- 位不重叠，算术加即可（HAL 不加载位库）
	end

	local req = ffi.new("cj_gpiohandle_request")	-- ffi.new 零初始化
	req.lineoffsets[0] = offset
	req.flags = flags
	if direction == "out" then
		local dv = tonumber(default_value) or 0
		req.default_values[0] = (dv ~= 0) and 1 or 0	-- 内核语义：非 0 即有效电平
	end
	req.consumer_label = "bot4cj"
	req.lines = 1

	if HAL.sys.ioctl_p(chipfd, HAL.GPIO_GET_LINEHANDLE, req) ~= 0 or req.fd < 0 then
		print("HAL: failed to request gpio line " .. tostring(offset) ..
		      " on " .. chip_path)
		HAL.sys.close(chipfd)
		return -1
	end

	local hfd = tonumber(req.fd)
	HAL.sys.close(chipfd)		-- 取得句柄后 chip fd 即可关闭（内核 uAPI 约定）
	return hfd
end

-- 设置输出值（非 0 归一为 1，内核把非 0 一律当有效电平），成功返回 true
function gpio_set_value(hfd, v)
	hfd = tonumber(hfd)
	if hfd == nil or hfd < 0 then return false end
	local data = ffi.new("cj_gpiohandle_data")
	local n = tonumber(v) or 0
	data.values[0] = (n ~= 0) and 1 or 0
	return HAL.sys.ioctl_p(hfd, HAL.GPIOHANDLE_SET_LINE_VALUES, data) == 0
end

-- 读取输入值，返回 0/1；失败返回 -1
function gpio_get_value(hfd)
	hfd = tonumber(hfd)
	if hfd == nil or hfd < 0 then return -1 end
	local data = ffi.new("cj_gpiohandle_data")
	if HAL.sys.ioctl_p(hfd, HAL.GPIOHANDLE_GET_LINE_VALUES, data) ~= 0 then return -1 end
	return tonumber(data.values[0])
end

-- 释放 GPIO 句柄（关闭句柄 fd 即释放线占用）
function gpio_free_line(hfd)
	hfd = tonumber(hfd)
	if hfd ~= nil and hfd >= 0 then HAL.sys.close(hfd) end
end

------------------------------------------------------------------
-- UART（termios raw 8N1：/dev/tty*、/dev/serial*；非阻塞轮询读）
------------------------------------------------------------------
-- 常量经 test/test_uart_consts.c 与系统头文件实证（gpio 段同款方法）：
-- sizeof(struct termios)=60、c_line 偏移 16、c_cc 偏移 17、VMIN=6/VTIME=5、
-- O_RDWR=2 O_NOCTTY=256 O_NONBLOCK=2048、TCSANOW=0、TCIFLUSH=0、
-- CREAD=128 CLOCAL=2048 CS8=48；现代 glibc 的 B* 波特率常量即数值本身
-- （B9600==9600、B115200==115200），cfsetispeed 直接收 Hz 值

ffi.cdef[[
int  tcgetattr(int fd, void *termios_p);
int  tcsetattr(int fd, int act, const void *termios_p);
void cfmakeraw(void *termios_p);
int  cfsetispeed(void *termios_p, unsigned int speed);
int  cfsetospeed(void *termios_p, unsigned int speed);
int  tcflush(int fd, int queue_selector);

typedef struct {
	unsigned int c_iflag, c_oflag, c_cflag, c_lflag;
	unsigned char c_line;
	unsigned char c_cc[32];
	unsigned int c_ispeed, c_ospeed;
} cj_termios;
]]

-- 结构体尺寸自检：glibc x86_64/aarch64 均为 60 字节，不符则立即失败
-- （防止分架构布局静默漂移导致 c_cc 下标越界写）
assert(ffi.sizeof("cj_termios") == 60,
	"cj_termios size mismatch: expect 60, got " .. ffi.sizeof("cj_termios"))

HAL.UART_O_FLAGS  = 2306		-- O_RDWR(2) | O_NOCTTY(256) | O_NONBLOCK(2048)
HAL.UART_TCSANOW  = 0
HAL.UART_TCIFLUSH = 0
HAL.UART_VMIN_IDX = 6			-- c_cc 下标（VMIN）
HAL.UART_VTIME_IDX = 5			-- c_cc 下标（VTIME）
HAL.UART_CREAD_CLOCAL = 2176	-- CREAD(128) | CLOCAL(2048)
HAL.EAGAIN = 11					-- Linux errno：非阻塞读暂无数据
HAL.EINTR = 4					-- Linux errno：被信号打断

HAL.uart_baud = {}				-- fd -> 波特率（调试/生命周期摘要）

local UART_BAUDS = { 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600 }

-- 打开串口（raw 8N1 + 波特率 + 非阻塞），成功返回 fd，失败返回 -1
function uart_open(path, baud)
	if type(path) ~= "string" then return -1 end
	baud = tonumber(baud)
	local baud_ok = false
	for _, b in ipairs(UART_BAUDS) do
		if b == baud then baud_ok = true; break end
	end
	if not baud_ok then
		print("HAL: invalid uart baud: " .. tostring(baud))
		return -1
	end
	-- 路径白名单：常规 tty 命名 + /dev/serialN（树莓派软链惯例）
	if string.match(path, "^/dev/tty[A-Za-z0-9]+$") == nil
		and string.match(path, "^/dev/serial%d+$") == nil then
		print("HAL: invalid uart path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, HAL.UART_O_FLAGS))
	if fd == nil or fd < 0 then
		print("HAL: failed to open uart: " .. path)
		return -1
	end
	local t = ffi.new("cj_termios[1]")	-- ffi.new 零初始化
	if HAL.sys.tcgetattr(fd, t) ~= 0 then
		print("HAL: tcgetattr failed: " .. path .. " (是串口设备吗?)")
		HAL.sys.close(fd)
		return -1
	end
	HAL.sys.cfmakeraw(t)				-- raw 模式（无回显/无行缓冲/8N1 基础）
	-- CREAD|CLOCAL 用真位或置位（cfmakeraw 不清这两位，加法会进位污染高位；
	-- HAL 仅支持 LuaJIT，内建 bit 库可用）
	local bitlib = require("bit")
	t[0].c_cflag = bitlib.bor(tonumber(t[0].c_cflag) or 0, HAL.UART_CREAD_CLOCAL)
	t[0].c_cc[HAL.UART_VMIN_IDX] = 0	-- 非阻塞读：VMIN=0
	t[0].c_cc[HAL.UART_VTIME_IDX] = 1	-- 100ms 字间计时器（驱动层另有轮询超时）
	HAL.sys.cfsetispeed(t, baud)
	HAL.sys.cfsetospeed(t, baud)
	if HAL.sys.tcsetattr(fd, HAL.UART_TCSANOW, t) ~= 0 then
		print("HAL: tcsetattr failed: " .. path)
		HAL.sys.close(fd)
		return -1
	end
	HAL.uart_baud[fd] = baud
	return fd
end

-- 关闭串口
function uart_close(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 then return -1 end
	HAL.uart_baud[fd] = nil
	return HAL.sys.close(fd)
end

-- 清空输入缓冲（丢弃未读字节，请求-应答协议发帧前用）
function uart_flush(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 then return -1 end
	return HAL.sys.tcflush(fd, HAL.UART_TCIFLUSH)
end

-- 写一帧字节（data 为 1 基字节值表），返回写入字节数或 -1
function uart_write(fd, data)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return -1 end
	if #data > 512 then return -1 end
	local buf = ffi.new("uint8_t[?]", #data)
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		buf[i - 1] = b
	end
	local r = tonumber(HAL.sys.write(fd, buf, #data))
	if r == nil or r < 0 then return -1 end
	return r
end

-- 读最多 n 字节（非阻塞轮询，1ms 步进直至 timeout_ms），返回 1 基字节表
-- （可能为空表 = 超时无数据）；fd 读取错误（EAGAIN/EINTR 之外的 errno）
-- 立即返回 nil——原实现把一切 read 失败当"无数据"空转到超时，错误被吞
function uart_read(fd, n, timeout_ms)
	fd = tonumber(fd)
	n = uint_of(n)
	timeout_ms = tonumber(timeout_ms) or 0
	if fd == nil or n == nil or n < 1 then return nil end
	if n > 512 then n = 512 end
	local buf = ffi.new("uint8_t[?]", n)
	local out = {}
	local iters = math.max(0, math.floor(timeout_ms)) + 1
	for it = 1, iters do
		local want = n - #out
		local r = tonumber(HAL.sys.read(fd, buf, want))
		if r ~= nil and r > 0 then
			for i = 0, r - 1 do out[#out + 1] = tonumber(buf[i]) end
			if #out >= n then break end
		elseif r == nil or r < 0 then
			-- EAGAIN=暂无数据、EINTR=被信号打断：继续轮询；其余错误显式失败
			local e = HAL.sys.errno()
			if e ~= HAL.EAGAIN and e ~= HAL.EINTR then return nil end
		end
		if it < iters then HAL.sys.usleep(1000) end
	end
	return out
end

------------------------------------------------------------------
-- PWM（Linux sysfs：/sys/class/pwm/pwmchipN/pwmM）
------------------------------------------------------------------
-- 波形由 SoC（Pi 5 为 RP1）的 PWM 控制器自行产生，Lua 侧只写
-- period / duty_cycle / enable 三个属性——无 CPU 占用、无软件抖动。
-- 这是本框架唯一可行的 PWM 路径：软件 bit-bang 要么阻塞主线程的动作播放，
-- 要么在守护线程里 ffi usleep 自旋耗尽 schd-worker 池（README 已记死锁）。
--
-- 【为何用 ffi 而不是 io 库】Lua.cj 的 sandbox_lua 中和了 io.open/io.lines，
-- 驱动写不了 sysfs；这里走 HAL.sys.open/write（ffi 直调 libc），
-- 既保持沙箱不变，也与各总线段的写法一致。
--
-- 【sysfs 已 deprecated 但可用】树莓派 OS（Bookworm）默认挂载 /sys/class/pwm；
-- 将来若需多通道原子配置可换 /dev/pwmchip* 的字符设备 uAPI——届时按
-- test/test_ioctl_nums.c 的方法实证 ioctl 编号与结构体尺寸，别硬编码。
--
-- 接口：pwm_exported / pwm_export / pwm_config / pwm_set_polarity /
--       pwm_enable / pwm_unexport
-- chip、channel 必须是非负整数（防路径穿越），其余一律拒绝并打印诊断。
-- 典型：CM0 / Pi Zero 2 W 的 PWM1 复用 GPIO19（ALT5）→ chip=0 channel=1。

HAL.PWM_SYSFS_ROOT = "/sys/class/pwm"
HAL.pwm_state = {}			-- "chip/channel" -> {freq, duty, period_ns, duty_ns, enabled}

local O_WRONLY = 1
local O_RDONLY = 0

-- sysfs 写失败几乎总是这两种原因，给出人话提示（errno 取自 Linux 通用值）
HAL.ENOENT = 2			-- 节点不存在：overlay 未启用 / chip 编号不对
HAL.EACCES = 13			-- 权限不足：export 通常仅 root 可写
HAL.EINVAL = 22			-- 参数被内核拒绝（如越界通道号、重复 export）

local function errno_hint(e)
	if e == HAL.ENOENT then
		return "ENOENT(节点不存在：PWM overlay 未启用，或 pwmchip 编号不对?)"
	elseif e == HAL.EACCES then
		return "EACCES(权限不足：export/unexport 默认仅 root 可写，需 udev 规则或 sudo -E)"
	elseif e == HAL.EINVAL then
		return "EINVAL(参数被内核拒绝)"
	end
	return "errno=" .. tostring(e)
end

-- 规范化非负整数 id（拒绝负数、小数、"../"、超范围值），非法返回 nil。
-- 上限 65535：既覆盖真实 pwmchip 编号，也避免 tostring 对大数输出科学
-- 计数法（如 1e+15）污染路径。
local function pwm_id(v)
	local n = tonumber(v)
	if n == nil or n < 0 or n > 65535 or n ~= math.floor(n) then return nil end
	return tostring(math.floor(n))
end

-- pwmchip 级属性路径（export / unexport）
local function pwm_chip_path(chip, attr)
	local c = pwm_id(chip)
	if c == nil then
		print("HAL: invalid pwm chip: " .. tostring(chip))
		return nil
	end
	return HAL.PWM_SYSFS_ROOT .. "/pwmchip" .. c .. "/" .. attr
end

-- 通道级属性路径（period / duty_cycle / enable / polarity）
local function pwm_attr_path(chip, channel, attr)
	local c, h = pwm_id(chip), pwm_id(channel)
	if c == nil or h == nil then
		print("HAL: invalid pwm chip/channel: " .. tostring(chip) .. "/" .. tostring(channel))
		return nil
	end
	return HAL.PWM_SYSFS_ROOT .. "/pwmchip" .. c .. "/pwm" .. h .. "/" .. attr
end

-- 向任意 sysfs 文件写入字符串；成功 true，失败打印路径并 false
local function sysfs_write(path, val)
	if type(path) ~= "string" then return false end
	local fd = tonumber(HAL.sys.open(path, O_WRONLY))
	if fd == nil or fd < 0 then
		print("HAL: pwm open failed: " .. path .. " " .. errno_hint(HAL.sys.errno()))
		return false
	end
	local s = tostring(val)
	-- ffi.copy 从 Lua 字符串拷贝（不显式给 len）会连同结尾 NUL 一起拷
	-- （#s+1 字节）；缓冲只开 #s 会固定越界 1 字节、写坏相邻 GC 对象，
	-- 下一次 GC 扫描时段错误（崩溃点与写操作相隔甚远，极难查）。
	-- 缓冲留 1 字节给 NUL；实际写计数仍用 #s，NUL 不发给内核。
	local buf = ffi.new("char[?]", #s + 1)
	ffi.copy(buf, s)
	local n = tonumber(HAL.sys.write(fd, buf, #s))
	HAL.sys.close(fd)
	if n == nil or n < #s then
		print("HAL: pwm write failed: " .. path .. " <- " .. s .. " " .. errno_hint(HAL.sys.errno()))
		return false
	end
	return true
end

-- 读 pwmchip 的通道数（npwm）；读不到返回 nil
-- 通道号必须小于该值，export 越界通道时内核静默不生成目录，
-- 故失败诊断必须带上它（只说"没生效"无法区分越界与权限）。
function pwm_npwm(chip)
	local p = pwm_chip_path(chip, "npwm")
	if p == nil then return nil end
	local fd = tonumber(HAL.sys.open(p, O_RDONLY))
	if fd == nil or fd < 0 then return nil end
	local buf = ffi.new("char[16]")
	local n = tonumber(HAL.sys.read(fd, buf, 16))
	HAL.sys.close(fd)
	if n == nil or n <= 0 then return nil end
	return tonumber(ffi.string(buf, n))
end

-- 通道是否已导出（以 enable 属性能否打开为准）
-- 用 O_RDONLY 探测：存在性判断不该受写权限影响——
-- enable 默认 0644 root:root，非 root 用 O_WRONLY 探测会拿到 EACCES 误判为"未导出"
function pwm_exported(chip, channel)
	local path = pwm_attr_path(chip, channel, "enable")
	if path == nil then return false end
	local fd = tonumber(HAL.sys.open(path, O_RDONLY))
	if fd == nil or fd < 0 then return false end
	HAL.sys.close(fd)
	return true
end

-- 导出通道；已导出则直接成功（重复 export 会被内核以 EINVAL 拒绝）
function pwm_export(chip, channel)
	if pwm_exported(chip, channel) then return true end
	local p = pwm_chip_path(chip, "export")
	local h = pwm_id(channel)
	if p == nil or h == nil then
		print("HAL: invalid pwm channel: " .. tostring(channel))
		return false
	end
	-- 前置校验：越界通道号内核只回一个 EINVAL，错误信息本身无法自解释。
	-- 最常见的误用是把 channel 当成 GPIO 引脚号填（如 17）——
	-- 引脚由 config.txt 的 dtoverlay 决定，与 channel 无关。
	local n = pwm_npwm(chip)
	if n ~= nil and tonumber(h) >= n then
		print("HAL: pwm channel " .. h .. " out of range on pwmchip" .. tostring(chip) ..
			": 该 chip 只有 " .. tostring(n) .. " 个通道（合法值 0~" .. tostring(n - 1) .. "）。" ..
			"channel 是 PWM 硬件通道号，不是 GPIO 引脚号——引脚由 dtoverlay 决定。")
		return false
	end
	if not sysfs_write(p, h) then return false end
	if not pwm_exported(chip, channel) then
		-- 写入成功却没生成目录，最常见是通道号越界（内核静默忽略）
		local n = pwm_npwm(chip)
		if n ~= nil then
			print("HAL: pwm export did not take effect: pwmchip" .. tostring(chip) ..
				" pwm" .. tostring(h) .. " — 该 chip 只有 " .. tostring(n) ..
				" 个通道，channel 须为 0~" .. tostring(n - 1) ..
				"（要双通道请用 dtoverlay=pwm-2chan 并重启）")
		else
			print("HAL: pwm export did not take effect: pwmchip" .. tostring(chip) ..
				" pwm" .. tostring(h) .. "（无法读取 npwm，检查 /sys/class/pwm 挂载与权限）")
		end
		return false
	end
	return true
end

-- 设载波频率与占空比（duty 为百分比 0~100）
-- 返回 (true, period_ns, duty_ns) 或 false
function pwm_config(chip, channel, freq_hz, duty_pct)
	local f = tonumber(freq_hz)
	local d = tonumber(duty_pct)
	if f == nil or f <= 0 then
		print("HAL: invalid pwm frequency: " .. tostring(freq_hz))
		return false
	end
	if d == nil or d < 0 or d > 100 then
		print("HAL: invalid pwm duty: " .. tostring(duty_pct) .. " (expect 0~100)")
		return false
	end
	local period_ns = math.floor(1e9 / f + 0.5)
	if period_ns < 1 then period_ns = 1 end
	local duty_ns = math.floor(period_ns * d / 100 + 0.5)
	if duty_ns > period_ns then duty_ns = period_ns end

	-- 写序：内核要求 duty_cycle <= period，故先把 duty 归零再改 period。
	-- 否则「新 period 小于旧 duty」会被内核以 EINVAL 拒绝——降频必踩。
	-- 代价是切换瞬间多一个低电平周期，对电机/LED 无实际影响。
	if not sysfs_write(pwm_attr_path(chip, channel, "duty_cycle"), 0) then return false end
	if not sysfs_write(pwm_attr_path(chip, channel, "period"), period_ns) then return false end
	if not sysfs_write(pwm_attr_path(chip, channel, "duty_cycle"), duty_ns) then return false end

	local key = tostring(pwm_id(chip)) .. "/" .. tostring(pwm_id(channel))
	local st = HAL.pwm_state[key] or {}
	st.freq, st.duty = f, d
	st.period_ns, st.duty_ns = period_ns, duty_ns
	HAL.pwm_state[key] = st
	return true, period_ns, duty_ns
end

-- 极性：inversed = 输出反相（低电平有效的驱动板用）
function pwm_set_polarity(chip, channel, inversed)
	return sysfs_write(pwm_attr_path(chip, channel, "polarity"),
		inversed and "inversed" or "normal")
end

-- 使能 / 关闭输出
function pwm_enable(chip, channel, on)
	local ok = sysfs_write(pwm_attr_path(chip, channel, "enable"), (on and 1 or 0))
	if ok then
		local key = tostring(pwm_id(chip)) .. "/" .. tostring(pwm_id(channel))
		local st = HAL.pwm_state[key] or {}
		st.enabled = on and true or false
		HAL.pwm_state[key] = st
	end
	return ok
end

-- 取消导出（先停输出，避免取消后引脚停在某个电平上继续驱动负载）
function pwm_unexport(chip, channel)
	local p = pwm_chip_path(chip, "unexport")
	local h = pwm_id(channel)
	if p == nil or h == nil then return false end
	pwm_enable(chip, channel, false)
	local ok = sysfs_write(p, h)
	if ok then HAL.pwm_state[tostring(pwm_id(chip)) .. "/" .. tostring(h)] = nil end
	return ok
end

return HAL

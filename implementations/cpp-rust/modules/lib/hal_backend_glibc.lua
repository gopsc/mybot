-- hal_backend_glibc.lua - HAL 系统调用后端：glibc（LuaJIT ffi 直调）
-- fix-plan 2026-09-20 阶段 A-1（外部评估 2026-09-20 扣分点「平台与运行时绑定」整改）：
-- 原 HAL.lua 内联的 HAL.sys 函数表原样迁入，成为可替换后端；
-- 换后端（仿真桩 / 其它 libc）= 新增 modules/lib/hal_backend_<名>.lua，
-- HAL 总线函数与驱动零改动。
--
-- 2026-09-30 跨平台抽象（方案 A）：ffi.cdef 结构体声明、ioctl 编号常量、
-- 总线传输原语（i2c_rdwr/spi_setup/spi_xfer）全部下沉到本后端，HAL.lua
-- 不再包含任何平台特有代码——只保留参数校验、quiesce 检查、返回值归一化。
-- 换平台 = 新增 hal_backend_<平台>.lua（提供同构 ffi.cdef + 常量 + 原语），
-- HAL.lua 与驱动零改动。
--
-- 【后端接口契约】BOT4CJ_HAL_BACKEND 指定的后端必须返回实现以下函数集的表
--（HAL.lua 加载时会逐项断言，缺函数即 fail-fast）：
--
-- 原始系统调用：
--   open(path, flags[, mode])  -> fd(>=0)；失败 -1
--   close(fd)                  -> 0 成功 / -1 失败
--   ioctl_i(fd, req, val)      -> int（val 按 unsigned long cast，JIT/解释 ABI 一致）
--   ioctl_p(fd, req, ptr)      -> int（ptr 为 cdata 指针）
--   read(fd, buf, n)           -> 读到字节数(>=0) / -1
--   write(fd, buf, n)          -> 写入字节数(>=0) / -1
--   usleep(us)                 -> nil（调用方不依赖返回值）
--   errno()                    -> 最近一次系统调用的 errno
--   version()                  -> libc 版本串（如 "2.42"）；不可知返回 nil
--
-- 总线传输原语（2026-09-30 新增）：
--   i2c_rdwr(fd, msgs, nmsgs)  -> int（内核 ioctl 返回值；msgs 为 cj_i2c_msg[]）
--   spi_setup(fd, mode, bits, speed) -> int（0=成功，-1=失败；三次 ioctl 配置 fd）
--   spi_xfer(fd, tx, rx, len, delay_us) -> int（内核 ioctl 返回值；tx/rx 为 uint8_t* cdata）
--
-- UART termios：
--   tcgetattr/tcsetattr/cfmakeraw/cfsetispeed/cfsetospeed/tcflush
--                              （同 glibc 语义；termios 以 void* 传递避免分架构布局差异）
--
-- 平台常量（2026-09-30 新增，导出为 M.consts 表）：
--   O_CLOEXEC, I2C_RDWR, I2C_M_RD, SPI_IOC_WR_MODE, SPI_IOC_WR_BITS_PER_WORD,
--   SPI_IOC_WR_MAX_SPEED_HZ, SPI_IOC_MESSAGE_1, GPIO_GET_LINEHANDLE,
--   GPIOHANDLE_GET_LINE_VALUES, GPIOHANDLE_SET_LINE_VALUES,
--   GPIOHANDLE_REQUEST_INPUT, GPIOHANDLE_REQUEST_OUTPUT, GPIOHANDLE_REQUEST_ACTIVE_LOW,
--   UART_O_FLAGS, UART_TCSANOW, UART_TCIFLUSH, UART_VMIN_IDX, UART_VTIME_IDX,
--   UART_CREAD_CLOCAL, EAGAIN, EINTR, ENOENT, EACCES, EINVAL
--
-- 【加载时序】本文件由 HAL.lua 经 dofile 加载，自行完成 ffi.cdef 声明
--（glibc 函数 + spidev/i2c/gpio/termios 结构体）与尺寸自检——不再依赖 HAL.lua
-- 预先声明。HAL.lua 在加载本后端后可直接使用已声明的类型（ffi.cdef 全局生效）。
--
-- 【返回码契约】HAL 层「失败 = -1 / nil / false」三种风格并存是既有契约
--（i2c_write_reg 返布尔、write_multi 返 0/-1……virtbus.lua:319-322 已记载
-- 「-1 在 Lua 中为真值」的陷阱），后端不得私自统一口径，以免静默改变
-- 上层判据——这正是 bus_contract 单点（N-25）要防的同类漂移。
local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then
	error("hal_backend_glibc requires LuaJIT ffi")
end

------------------------------------------------------------------
-- ffi 声明（glibc + Linux spidev/i2c/gpio/termios ABI）
------------------------------------------------------------------
-- 2026-09-30：从 HAL.lua 迁入。结构体布局是平台特有代码，归后端所有。
ffi.cdef[[
int  open(const char *pathname, int flags, ...);
int  close(int fd);
int  ioctl(int fd, unsigned long request, ...);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int  usleep(unsigned int usec);

/* 守护槽互斥锁（BQ-1 灭火检查用）。与 modules/lib/pthread.lua 的声明逐字
 * 相同——守护 chunk 同时加载两库，LuaJIT 对相同签名的重复声明幂等，签名
 * 漂移则静默失配，靠这份注释双向钉住。 */
typedef struct { char __m[64]; } cj_pthread_mutex_t;
int  pthread_mutex_lock(cj_pthread_mutex_t *mutex);
int  pthread_mutex_unlock(cj_pthread_mutex_t *mutex);

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

/* termios 函数声明（glibc；termios 结构以 void* 传递避免分架构布局差异） */
int  tcgetattr(int fd, void *termios_p);
int  tcsetattr(int fd, int act, const void *termios_p);
void cfmakeraw(void *termios_p);
int  cfsetispeed(void *termios_p, unsigned int speed);
int  cfsetospeed(void *termios_p, unsigned int speed);
int  tcflush(int fd, int queue_selector);

/* glibc termios 结构（x86_64/aarch64 同布局，60 字节） */
typedef struct {
	unsigned int c_iflag, c_oflag, c_cflag, c_lflag;
	unsigned char c_line;
	unsigned char c_cc[32];
	unsigned int c_ispeed, c_ospeed;
} cj_termios;
]]

-- 布局自检：结构体尺寸与内核头文件不符则立即失败（防止静默内存越界）
assert(ffi.sizeof("spi_ioc_transfer") == 32,
	"spi_ioc_transfer size mismatch: expect 32, got " .. ffi.sizeof("spi_ioc_transfer"))
assert(ffi.sizeof("cj_i2c_msg") == 16,
	"cj_i2c_msg size mismatch: expect 16, got " .. ffi.sizeof("cj_i2c_msg"))
assert(ffi.sizeof("cj_gpiohandle_request") == 364,
	"gpiohandle_request size mismatch: expect 364, got " .. ffi.sizeof("cj_gpiohandle_request"))
assert(ffi.sizeof("cj_gpiohandle_data") == 64,
	"gpiohandle_data size mismatch: expect 64, got " .. ffi.sizeof("cj_gpiohandle_data"))
assert(ffi.sizeof("cj_termios") == 60,
	"cj_termios size mismatch: expect 60, got " .. ffi.sizeof("cj_termios"))

------------------------------------------------------------------
-- 平台常量（Linux x86_64/aarch64）
------------------------------------------------------------------
-- 2026-09-30：从 HAL.lua 迁入。ioctl 编号、errno 值、open 标志位均为平台特有，
-- 归后端所有。HAL.lua 经 HAL.sys.consts.* 访问，不再硬编码字面量。
-- ioctl 编号经 test/test_ioctl_nums.c 与系统头文件实证。
local consts = {
	-- exec 时自动关闭。**每一个**器件 open 都必须带上它：agent 模式的 run_command
	-- 会 fork /bin/sh，未标 CLOEXEC 的句柄被子进程继承后，模型驱动的命令可以直接
	-- ioctl 它拨动硬件——而且在 robot->deactivate() 之后依然有效（宿主侧另有
	-- close_range 兜底，见 src/agent_subprocess.cpp 的 revokeInheritedFds）。
	-- Linux 各架构同为 0x80000；由 test/test_ioctl_nums.c 与 fcntl.h 双边钉住。
	O_CLOEXEC = 0x80000,

	-- I2C
	I2C_RDWR = 0x0707,		-- i2c-dev 原子多消息事务
	I2C_M_RD = 0x0001,		-- i2c_msg.flags：读（0 为写）

	-- SPI（ioctl 编号按 _IOC(dir=WRITE(1)<<30 | size<<16 | type('k'=0x6b)<<8 | nr) 计算）
	SPI_IOC_WR_MODE          = 0x40016b01,	-- _IOW('k', 1, __u8)
	SPI_IOC_WR_BITS_PER_WORD = 0x40016b03,	-- _IOW('k', 3, __u8)
	SPI_IOC_WR_MAX_SPEED_HZ  = 0x40046b04,	-- _IOW('k', 4, __u32)
	SPI_IOC_MESSAGE_1        = 0x40206b00,	-- _IOW('k', 0, spi_ioc_transfer[1])

	-- GPIO（gpiod uAPI v1）
	GPIO_GET_LINEHANDLE         = 0xC16CB403,	-- _IOWR(0xB4, 0x03, gpiohandle_request)
	GPIOHANDLE_GET_LINE_VALUES  = 0xC040B408,	-- _IOWR(0xB4, 0x08, gpiohandle_data)
	GPIOHANDLE_SET_LINE_VALUES  = 0xC040B409,	-- _IOWR(0xB4, 0x09, gpiohandle_data)
	-- 注意：HAL 运行于 LuaJIT（5.1），无 << 运算符，标志位用字面量（INPUT=1<<0 等）
	GPIOHANDLE_REQUEST_INPUT      = 1,
	GPIOHANDLE_REQUEST_OUTPUT     = 2,
	GPIOHANDLE_REQUEST_ACTIVE_LOW = 4,

	-- UART（termios 常量，经 test/test_uart_consts.c 与系统头文件实证）
	UART_O_FLAGS  = 526594,		-- O_RDWR(2)|O_NOCTTY(256)|O_NONBLOCK(2048)|O_CLOEXEC(524288)
	UART_TCSANOW  = 0,
	UART_TCIFLUSH = 0,
	UART_VMIN_IDX = 6,			-- c_cc 下标（VMIN）
	UART_VTIME_IDX = 5,			-- c_cc 下标（VTIME）
	UART_CREAD_CLOCAL = 2176,	-- CREAD(128) | CLOCAL(2048)

	-- errno（Linux 通用值）
	EAGAIN = 11,				-- 非阻塞读暂无数据
	EINTR = 4,					-- 被信号打断
	ENOENT = 2,					-- 节点不存在（PWM sysfs）
	EACCES = 13,				-- 权限不足（PWM export）
	EINVAL = 22,				-- 参数被内核拒绝
}

------------------------------------------------------------------
-- glibc 版本探测
------------------------------------------------------------------
-- glibc 版本探测：gnu_get_libc_version 是 glibc 专有符号（musl 没有），
-- 非 glibc 平台 version() 返 nil，上层波特率编码探测按旧 ABI 编码处理
-- （hal/uart.lua 与 test_uart_consts.c 三重把关）。
-- 2026-09-25 musl 实证修正：cdef 只是声明、永远成功，符号缺失是在 **ffi.C 取值时**
-- 抛「Symbol not found」——此前 pcall 只包住 cdef，musl 下 version() 直接崩，
-- 与本文件顶部契约「不可知返回 nil」相悖。故解析符号的那一步也放进 pcall。
pcall(ffi.cdef, [[ const char* gnu_get_libc_version(void); ]])
local function libc_version()
	local ok, p = pcall(function() return ffi.C.gnu_get_libc_version() end)
	if not ok or p == nil then return nil end
	return ffi.string(p)
end

------------------------------------------------------------------
-- 总线传输原语（2026-09-30 新增）
------------------------------------------------------------------
-- I2C：组装 cj_i2c_rdwr 结构 + ioctl(I2C_RDWR)
local function i2c_rdwr(fd, msgs, nmsgs)
	local data = ffi.new("cj_i2c_rdwr[1]")
	data[0].msgs = msgs
	data[0].nmsgs = nmsgs
	return ffi.C.ioctl(fd, consts.I2C_RDWR, data)
end

-- SPI 配置：三次 ioctl 持久化 mode/bits/speed 到 fd
local function spi_setup(fd, mode, bits, speed)
	local m8 = ffi.new("uint8_t[1]", mode)
	if ffi.C.ioctl(fd, consts.SPI_IOC_WR_MODE, m8) ~= 0 then return -1 end
	local b8 = ffi.new("uint8_t[1]", bits)
	if ffi.C.ioctl(fd, consts.SPI_IOC_WR_BITS_PER_WORD, b8) ~= 0 then return -1 end
	local s32 = ffi.new("uint32_t[1]", speed)
	if ffi.C.ioctl(fd, consts.SPI_IOC_WR_MAX_SPEED_HZ, s32) ~= 0 then return -1 end
	return 0
end

-- SPI 传输：组装 spi_ioc_transfer 结构 + ioctl(SPI_IOC_MESSAGE_1)
-- delay_us 已由 hal/spi.lua 校验并钳制到 0~65535（__u16 上限）
local function spi_xfer(fd, tx, rx, len, delay_us)
	local msg = ffi.new("spi_ioc_transfer[1]")	-- ffi.new 零初始化
	msg[0].len = len
	if delay_us ~= nil then
		msg[0].delay_usecs = delay_us
	end
	if tx ~= nil then
		msg[0].tx_buf = ffi.cast("unsigned long long", ffi.cast("const uint8_t *", tx))
	end
	if rx ~= nil then
		msg[0].rx_buf = ffi.cast("unsigned long long", ffi.cast("uint8_t *", rx))
	end
	return ffi.C.ioctl(fd, consts.SPI_IOC_MESSAGE_1, msg)
end

------------------------------------------------------------------
-- 后端导出表
------------------------------------------------------------------
local M = {
	-- 原始系统调用
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
	version = libc_version,

	-- 总线传输原语
	i2c_rdwr  = i2c_rdwr,
	spi_setup = spi_setup,
	spi_xfer  = spi_xfer,

	-- UART termios（glibc 直接调用；termios 以 void* 传递避免分架构布局差异）
	tcgetattr   = function(fd, ptr)     return ffi.C.tcgetattr(fd, ptr) end,
	tcsetattr   = function(fd, act, ptr) return ffi.C.tcsetattr(fd, act, ptr) end,
	cfmakeraw   = function(ptr)         ffi.C.cfmakeraw(ptr) end,
	cfsetispeed = function(ptr, baud)   return ffi.C.cfsetispeed(ptr, baud) end,
	cfsetospeed = function(ptr, baud)   return ffi.C.cfsetospeed(ptr, baud) end,
	tcflush     = function(fd, q)       return ffi.C.tcflush(fd, q) end,

	-- 平台常量
	consts = consts,
}
return M

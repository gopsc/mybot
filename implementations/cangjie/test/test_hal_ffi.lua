-- HAL.lua ffi 后端离线单元测试
-- mock HAL.sys.* 系统调用层，验证调用序列、缓冲区内容与错误路径；不触碰真实硬件。
-- 用法（项目根目录）: luajit test/test_hal_ffi.lua

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local ffi = require("ffi")
local HAL = dofile("modules/lib/HAL.lua")

check("ffi 后端被选中", HAL.backend == "ffi", HAL.backend)

------------------------------------------------------------------
-- mock 系统调用层
------------------------------------------------------------------
local calls = {}			-- {op=..., ...} 记录
local mock_open_fd = 7		-- open 返回的假 fd
local mock_ioctl_ret = 0	-- ioctl 返回值
local mock_rw_ok = true		-- read/write 是否成功
local rx_preset = {}		-- read/rx_buf 预置字节（1 基数组）
local mock_errno = 0		-- errno 返回值
local mock_ioctl_i_by_req = nil	-- 按请求号区分 ioctl_i 返回值（EBUSY 回退用例）

HAL.sys.open = function(path, flags)
	calls[#calls + 1] = { op = "open", path = path, flags = flags }
	return mock_open_fd
end
HAL.sys.close = function(fd)
	calls[#calls + 1] = { op = "close", fd = fd }
	return 0
end
HAL.sys.ioctl_i = function(fd, req, val)
	calls[#calls + 1] = { op = "ioctl_i", fd = fd, req = req, val = val }
	if mock_ioctl_i_by_req ~= nil and mock_ioctl_i_by_req[req] ~= nil then
		return mock_ioctl_i_by_req[req]
	end
	return mock_ioctl_ret
end
HAL.sys.errno = function() return mock_errno end
HAL.sys.ioctl_p = function(fd, req, ptr)
	local rec = { op = "ioctl_p", fd = fd, req = req }
	if req == HAL.I2C_RDWR then
		-- 解包 i2c_rdwr：逐条消息记录 addr/flags/len；写消息记内容，读消息按 rx_preset 填充
		local nmsgs = tonumber(ptr[0].nmsgs)
		rec.nmsgs = nmsgs
		rec.msgs = {}
		for m = 0, nmsgs - 1 do
			local msg = ptr[0].msgs[m]
			local e = { addr = tonumber(msg.addr), flags = tonumber(msg.flags), len = tonumber(msg.len) }
			if e.flags == HAL.I2C_M_RD then
				for i = 0, e.len - 1 do msg.buf[i] = rx_preset[i + 1] or 0 end
			else
				e.data = ffi.string(msg.buf, e.len)
			end
			rec.msgs[m + 1] = e
		end
	elseif req == HAL.SPI_IOC_MESSAGE_1 then
		-- 解包 transfer 结构体：长度、速率、延时、tx 字节、rx 填充
		rec.len = tonumber(ptr[0].len)
		rec.speed = tonumber(ptr[0].speed_hz)
		rec.delay = tonumber(ptr[0].delay_usecs)
		if ptr[0].tx_buf ~= 0 then
			rec.tx = ffi.string(ffi.cast("const char *",
				ffi.cast("const void *", ptr[0].tx_buf)), rec.len)
		end
		if ptr[0].rx_buf ~= 0 then
			local rxb = ffi.cast("uint8_t *", ffi.cast("void *", ptr[0].rx_buf))
			for i = 0, rec.len - 1 do rxb[i] = rx_preset[i + 1] or 0 end
		end
	elseif req == HAL.SPI_IOC_WR_MODE or req == HAL.SPI_IOC_WR_BITS_PER_WORD then
		rec.u8 = tonumber(ffi.cast("uint8_t *", ptr)[0])
	elseif req == HAL.SPI_IOC_WR_MAX_SPEED_HZ then
		rec.u32 = tonumber(ffi.cast("uint32_t *", ptr)[0])
	end
	calls[#calls + 1] = rec
	return mock_ioctl_ret
end
HAL.sys.write = function(fd, buf, n)
	calls[#calls + 1] = { op = "write", fd = fd, n = n, data = ffi.string(buf, n) }
	if not mock_rw_ok then return -1 end
	return n
end
HAL.sys.read = function(fd, buf, n)
	calls[#calls + 1] = { op = "read", fd = fd, n = n }
	if not mock_rw_ok then return -1 end
	for i = 0, n - 1 do buf[i] = rx_preset[i + 1] or 0 end
	return n
end
HAL.sys.usleep = function(us)
	calls[#calls + 1] = { op = "usleep", us = us }
	return 0
end

local function reset()
	calls, rx_preset = {}, {}
	mock_open_fd, mock_ioctl_ret, mock_rw_ok = 7, 0, true
	mock_errno, mock_ioctl_i_by_req = 0, nil
end
local function find(op, field, value)
	for _, c in ipairs(calls) do
		if c.op == op and (field == nil or c[field] == value) then return c end
	end
	return nil
end

------------------------------------------------------------------
-- I2C
------------------------------------------------------------------
reset()
local fd = i2c_open("/dev/i2c-1")
check("i2c_open 返回 mock fd", fd == 7, fd)
check("i2c_open 以 O_RDWR 打开", find("open", "flags", 2) ~= nil)
check("i2c_open 非法路径拒绝", i2c_open("../../etc") == -1)
check("i2c_open 注入路径拒绝", i2c_open("/dev/i2c-1; rm -rf /") == -1)

reset()
check("i2c_set_addr 成功（仅记录地址）", i2c_set_addr(fd, 0x40) == true)
check("i2c_set_addr 不再发 ioctl（无 I2C_SLAVE）",
	find("ioctl_p") == nil and find("ioctl_i") == nil)
check("i2c_set_addr 注入地址拒绝", i2c_set_addr(fd, "0x40; reboot") == false)

-- write_reg：单条写消息，单次原子 I2C_RDWR
reset()
i2c_set_addr(fd, 0x40)
check("i2c_write_reg 成功", i2c_write_reg(fd, 0xFE, 0x03) == true)
local c = find("ioctl_p", "req", HAL.I2C_RDWR)
check("write_reg 单次 I2C_RDWR 含 1 条写消息", c ~= nil and c.nmsgs == 1)
check("write_reg msg: addr=0x40 flags=写 len=2 data=FE,03",
	c ~= nil and c.msgs[1].addr == 0x40 and c.msgs[1].flags == 0
	and c.msgs[1].len == 2 and c.msgs[1].data == string.char(0xFE, 0x03))
mock_ioctl_ret = -1
check("write_reg 失败返回 false", i2c_write_reg(fd, 0, 0) == false)

-- read_reg：写指针 + 读 合并为单次原子事务（消除两 syscall 间的竞态）
reset()
i2c_set_addr(fd, 0x40)
rx_preset = { 0x1a }
check("i2c_read_reg 返回字节值", i2c_read_reg(fd, 0x00) == 0x1a)
c = find("ioctl_p", "req", HAL.I2C_RDWR)
check("read_reg 单次 I2C_RDWR 含 2 条消息（原子）", c ~= nil and c.nmsgs == 2)
check("read_reg msg1=写指针(0x00) msg2=读1字节",
	c ~= nil and c.msgs[1].flags == 0 and c.msgs[1].data == string.char(0x00)
	and c.msgs[2].flags == HAL.I2C_M_RD and c.msgs[2].len == 1)
mock_ioctl_ret = -1
check("read_reg 失败返回 -1", i2c_read_reg(fd, 0x00) == -1)

-- write_multi：单条写消息 reg+b1+b2
reset()
i2c_set_addr(fd, 0x48)
check("i2c_write_multi 返回 0", i2c_write_multi(fd, 0x01, 0x84, 0x83) == 0)
c = find("ioctl_p", "req", HAL.I2C_RDWR)
check("write_multi 单消息 reg+b1+b2",
	c ~= nil and c.nmsgs == 1 and c.msgs[1].len == 3
	and c.msgs[1].data == string.char(0x01, 0x84, 0x83))

-- read_multi：写指针+读n 单次原子事务，大端合并
reset()
i2c_set_addr(fd, 0x48)
rx_preset = { 0x12, 0x34 }
check("i2c_read_multi 大端合并", i2c_read_multi(fd, 0x00, 2) == 0x1234)
c = find("ioctl_p", "req", HAL.I2C_RDWR)
check("read_multi 单次原子含 2 消息、读 2 字节",
	c ~= nil and c.nmsgs == 2 and c.msgs[2].len == 2)
rx_preset = { 0xaa, 0xbb, 0xcc }
check("i2c_read_multi 3 字节", i2c_read_multi(fd, 0x00, 3) == 0xAABBCC)
rx_preset = { 0x07 }
check("i2c_read_multi n>6 显式失败返回 -1（静默钳 1 会放大成长度错位的错误合并值）",
	i2c_read_multi(fd, 0, 99) == -1)
-- 字节表版：不受 2^53 限制，n 钳制 1~16
rx_preset = { 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 }
local rb8 = i2c_read_multi_bytes(fd, 0x00, 8)
check("i2c_read_multi_bytes 8 字节返回字节表",
	type(rb8) == "table" and #rb8 == 8
	and rb8[1] == 0x12 and rb8[4] == 0x78 and rb8[8] == 0xf0)
check("i2c_read_multi_bytes n>16 钳制 16", #(i2c_read_multi_bytes(fd, 0x00, 99) or {}) == 16)
mock_ioctl_ret = -1
check("i2c_read_multi_bytes 失败返回 nil", i2c_read_multi_bytes(fd, 0x00, 8) == nil)
mock_ioctl_ret = 0
mock_ioctl_ret = -1
check("read_multi 失败返回 -1", i2c_read_multi(fd, 0, 2) == -1)

-- 纯读：单条读消息，无写指针
reset()
i2c_set_addr(fd, 0x58)
rx_preset = { 0x00, 0x2a }
check("i2c_read 纯读大端合并", i2c_read(fd, 2) == 0x2a)
c = find("ioctl_p", "req", HAL.I2C_RDWR)
check("i2c_read 为单条读消息（无写指针）",
	c ~= nil and c.nmsgs == 1 and c.msgs[1].flags == HAL.I2C_M_RD)
check("i2c_read n>8 显式失败返回 -1", i2c_read(fd, 9) == -1)
check("i2c_read n<1 显式失败返回 -1", i2c_read(fd, 0) == -1)

-- 字节表纯读版：n 钳制 1~16（对齐 i2c_read_multi_bytes；
-- 0.3.2 修复：原实现 n<1 反向钳到 16，请求 0 字节反读 16 字节超长表）
rx_preset = { 0x5a, 0x5b }
local prb = i2c_read_bytes(fd, 2)
check("i2c_read_bytes 2 字节返回字节表",
	type(prb) == "table" and #prb == 2 and prb[1] == 0x5a and prb[2] == 0x5b)
check("i2c_read_bytes n>16 钳制 16", #(i2c_read_bytes(fd, 99) or {}) == 16)
check("i2c_read_bytes n<1 钳制 1（不再反向钳 16）", #(i2c_read_bytes(fd, 0) or {}) == 1)
mock_ioctl_ret = -1
check("i2c_read_bytes 失败返回 nil", i2c_read_bytes(fd, 2) == nil)
mock_ioctl_ret = 0

-- 未 set_addr 的 fd：地址缺失，操作应拒绝且不发 ioctl
reset()
check("未设地址 write_reg 拒绝", i2c_write_reg(999, 0, 0) == false)
check("未设地址 read_reg 拒绝", i2c_read_reg(999, 0) == -1)
check("未设地址不发 ioctl", find("ioctl_p") == nil)

reset()
milli_sleep(200)
check("milli_sleep 调 usleep(200000)", find("usleep", "us", 200000) ~= nil)

------------------------------------------------------------------
-- SPI
------------------------------------------------------------------
reset()
local sfd = spi_open("/dev/spidev0.0")
check("spi_open 返回 mock fd", sfd == 7)
check("spi_open 注入路径拒绝", spi_open("/dev/spidev0.0; reboot") == -1)

reset()
check("spi_setup 返回 0", spi_setup(sfd, 1, 8, 4000000, 0) == 0)
c = find("ioctl_p", "req", HAL.SPI_IOC_WR_MODE)
check("spi_setup 写 mode=1", c ~= nil and c.u8 == 1)
c = find("ioctl_p", "req", HAL.SPI_IOC_WR_BITS_PER_WORD)
check("spi_setup 写 bits=8", c ~= nil and c.u8 == 8)
c = find("ioctl_p", "req", HAL.SPI_IOC_WR_MAX_SPEED_HZ)
check("spi_setup 写 speed=4000000", c ~= nil and c.u32 == 4000000)
check("spi_setup 非法 mode 拒绝", spi_setup(sfd, 9, 8, 1000, 0) == -1)
mock_ioctl_ret = -1
check("spi_setup ioctl 失败返回 -1", spi_setup(sfd, 0, 8, 1000, 0) == -1)

reset()
check("spi_write3 返回 0", spi_write3(sfd, 0x50, 0x00, 0x03) == 0)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_write3 单次 3 字节传输（CS 保持低）",
	c ~= nil and c.len == 3 and c.tx == string.char(0x50, 0x00, 0x03))
check("spi_write3 speed_hz=0（沿用 fd 配置）", c ~= nil and c.speed == 0)
check("spi_write3 缺省 delay_usecs=0（向后兼容）", c ~= nil and c.delay == 0, c and c.delay)

reset()
check("spi_write_multi 返回 0", spi_write_multi(sfd, { 0x21, 0x00 }, 0) == 0)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_write_multi 单次 2 字节帧（CS 保持低）",
	c ~= nil and c.len == 2 and c.tx == string.char(0x21, 0x00))
check("spi_write_multi 非法字节拒绝", spi_write_multi(sfd, { 0x21, 300 }, 0) == -1)
check("spi_write_multi 空表拒绝", spi_write_multi(sfd, {}, 0) == -1)
check("spi_write_multi 缺表拒绝", spi_write_multi(sfd, nil, 0) == -1)
reset()
check("spi_write_multi 携带 delay_us", spi_write_multi(sfd, { 0x40, 0x00 }, 120) == 0
	and (find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1) or {}).delay == 120)

reset()
check("spi_write 单字节", spi_write(sfd, 0xAB) == 0)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_write 传输 1 字节", c ~= nil and c.len == 1 and c.tx == string.char(0xAB))

reset()
rx_preset = { 0x2a }
check("spi_read 解析收到的字节", spi_read(sfd) == 0x2a)

reset()
rx_preset = { 0x00, 0x12, 0x34, 0x56 }
check("spi_read_multi 大端合并 4 字节", spi_read_multi(sfd, 4) == 0x00123456)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_read_multi 单次 4 字节传输", c ~= nil and c.len == 4)
mock_ioctl_ret = -1
check("spi_read_multi ioctl 失败返回 -1", spi_read_multi(sfd, 4) == -1)
mock_ioctl_ret = 0
reset()
check("spi_read_multi n>8 显式失败返回 -1", spi_read_multi(sfd, 9) == -1)

-- delay_us 逐次传输（方案3：驱动显式传入）
reset()
mock_ioctl_ret = 0
check("spi_write3 携带 delay_us", spi_write3(sfd, 0x50, 0x00, 0x03, 50) == 0)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("delay_usecs 写入传输结构体", c ~= nil and c.delay == 50, c and c.delay)

reset()
check("spi_read_multi 携带 delay_us", spi_read_multi(sfd, 2, 120) ~= nil)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_read_multi delay_usecs=120", c ~= nil and c.delay == 120, c and c.delay)

reset()
spi_write(sfd, 0x01, 30)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_write 携带 delay_us", c ~= nil and c.delay == 30, c and c.delay)

reset()
rx_preset = { 0x11 }
spi_read(sfd, 40)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("spi_read 携带 delay_us", c ~= nil and c.delay == 40, c and c.delay)

reset()
spi_write3(sfd, 1, 2, 3, 99999)
c = find("ioctl_p", "req", HAL.SPI_IOC_MESSAGE_1)
check("delay_usecs 超 __u16 钳制为 65535", c ~= nil and c.delay == 65535, c and c.delay)

------------------------------------------------------------------
-- 驱动链：I2C.lua + PCA9685.lua 纯 Lua 端到端（mock 系统调用）
------------------------------------------------------------------
reset()
io.write("\n---- 驱动链测试输出开始 ----\n")
dofile("modules/I2C.lua")
local r = build({ mode = "build", path = "/dev/i2c-1" })
check("I2C.lua build 打开总线", r.result == "OK" and tonumber(r.fd) == 7, r.fd)

dofile("modules/PCA9685.lua")
reset()
r = build({ mode = "build", fd = 7, address = "0x40" })
check("PCA9685.lua build 配置芯片", r.result == "OK", r.result)
check("build 经 I2C_RDWR 原子写配置寄存器",
	find("ioctl_p", "req", HAL.I2C_RDWR) ~= nil)

reset()
r = call({ mode = "call", fd = 7, address = "0x40", channel = 6, angle = 45 })
check("PCA9685.lua call 设置角度", r.result == "OK", r.result)
-- channel 6 → 寄存器 0x1e 起；angle 45 → offval 204 = 0xcc
-- call 为单次 i2c_write_multi（AI 自增）：一条写消息 = 寄存器指针 + ON(2B) + OFF(2B)
local writes = {}
for _, cc in ipairs(calls) do
	if cc.op == "ioctl_p" and cc.req == HAL.I2C_RDWR and cc.msgs then
		for _, m in ipairs(cc.msgs) do
			if m.flags == 0 and m.data then writes[#writes + 1] = m.data end
		end
	end
end
check("call 单次原子写 PWM 4 字节 (0x1e,00,00,cc,00)",
	#writes == 1 and writes[1] == string.char(0x1e, 0x00, 0x00, 0xcc, 0x00),
	tostring(#writes) .. ":" .. tostring(writes[1] and #writes[1]))
io.write("---- 驱动链测试输出结束 ----\n\n")

------------------------------------------------------------------
-- SPI.lua：delay 经 call() 随 fd 传播（供设备驱动经元数据引用获取）
------------------------------------------------------------------
reset()
dofile("modules/SPI.lua")
r = build({ mode = "build", path = "/dev/spidev0.0",
            spi_mode = 1, bits = 8, speed = 1920000, delay = 50 })
check("SPI.lua build 成功", r.result == "OK", r.result)
r = call({ mode = "call" })
check("SPI.lua call 随 fd 返回 delay=50",
	tonumber(r.fd) ~= nil and tonumber(r.delay) == 50, r.delay)

------------------------------------------------------------------
tester.summary()

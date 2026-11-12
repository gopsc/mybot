-- hal/spi.lua —— HAL 的 SPI 域（spidev ioctl）
-- bot4cj 仓颉语言机器人框架
--
-- 本文件是 modules/lib/HAL.lua 的**分块**，不是可独立加载的模块：由门面按序
-- loadfile 后以 ctx 表传入共享上下文（见门面「各总线域加载」段）。
-- 正文自 HAL.lua 逐字搬迁（26.2 按域拆分），注释与错误文案未改写。
local ctx = assert(..., "hal/spi.lua 须由 modules/lib/HAL.lua 聚合加载（不支持单独 dofile）")
local HAL, ffi, bus, byte_of = ctx.HAL, ctx.ffi, ctx.bus, ctx.byte_of
local uint_of, int_of, bus_quiesced, O_RDWR = ctx.uint_of, ctx.int_of, ctx.bus_quiesced, ctx.O_RDWR

------------------------------------------------------------------
-- SPI（spidev ioctl；fd 为真实内核句柄）
------------------------------------------------------------------

-- 打开 SPI 设备，成功返回 fd（>=0），失败返回 -1
function spi_open(path)
	if type(path) ~= "string" then return -1 end
	if not bus.spi_path_ok(path) then
		print("HAL: invalid spi path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, O_RDWR + HAL.O_CLOEXEC))
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
	-- 诊断打印用归一化前的实参（否则越界值会显示成 nil，丢失定位信息）
	local raw_mode, raw_bits, raw_speed = mode, bits, speed
	-- mode/bits/speed 用 int_of（bus_contract 单点）：**拒绝非整数**，不再静默
	-- 取整——与 virtbus 同判据（旧实现走 uint_of 的 math.floor，spi_setup(fd,
	-- 1.9, 8, 1e6) 真机上会变成 mode=1 并成功，仿真侧却直接失败）。
	mode = int_of(mode, 0, 3)
	bits = int_of(bits, 7, 16)
	speed = int_of(speed, 1)
	if fd == nil or mode == nil or bits == nil or speed == nil then
		print("HAL: spi_setup invalid args: mode=" .. tostring(raw_mode) ..
		      " bits=" .. tostring(raw_bits) .. " speed=" .. tostring(raw_speed))
		return -1
	end
	if tonumber(delay) ~= nil and tonumber(delay) > 0 then
		print("HAL: spi_setup delay cannot persist on fd; pass delay_us per transfer instead")
	end

	-- 2026-09-30 方案 A 重构：三次 ioctl 配置下沉到后端原语
	return HAL.sys.spi_setup(fd, mode, bits, speed)
end

-- 内部：单次 SPI 事务（一条 message，CS 保持低）。
-- tx/rx 为 uint8_t 缓冲区 cdata（nil 表示该方向不使用）；len 为字节数。
-- speed_hz/bits_per_word 填 0：内核自动沿用 fd 上 spi_setup 配置的值。
-- delay_us：可选，本次传输最后一位之后、CS 拉高之前的等待微秒数
-- （内核无 per-fd 持久化途径，由驱动逐次显式传入，__u16 钳制到 65535）。
-- 2026-09-30 方案 A 重构：组装 spi_ioc_transfer 结构 + ioctl 下沉到后端原语
local function spi_xfer(fd, tx, rx, len, delay_us)
	if bus_quiesced() then return false end
	delay_us = uint_of(delay_us)
	if delay_us ~= nil and delay_us > 65535 then delay_us = 65535 end
	local r = HAL.sys.spi_xfer(fd, tx, rx, len, delay_us)
	return r ~= nil and r >= 0
end

-- 写 1 字节，返回 0 = 成功，-1 = 失败；delay_us 可选（CS 拉高前等待）
function spi_write(fd, val, delay_us)
	fd = tonumber(fd)
	val = int_of(val, 0, 255)	-- 严格整数（拒绝小数，不再静默 floor；同 virtbus）
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
	-- 严格整数（拒绝小数，不再静默 floor；同 virtbus）
	b0, b1, b2 = int_of(b0, 0, 255), int_of(b1, 0, 255), int_of(b2, 0, 255)
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
	if #data > bus.SPI_IO_MAX_BYTES then return -1 end
	local buf = ffi.new("uint8_t[?]", #data)
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		buf[i - 1] = b
	end
	if spi_xfer(fd, buf, nil, #data, delay_us) then return 0 end
	return -1
end

-- 一次读 n 字节（单次传输），返回大端合并值；失败返回 -1（n 有效范围 1~6，
-- 2^53 精度上限同 i2c_read_multi——7 字节起合并值可能被静默截断；越界显式
-- 返回 -1，静默钳制危害同 i2c_read_multi）；更长的全双工帧请用 spi_xfer_full
-- （MOSI 命令与 MISO 数据同帧、返回字节表）；delay_us 可选
function spi_read_multi(fd, n, delay_us)
	fd = tonumber(fd)
	n = uint_of(n)
	if fd == nil or n == nil then return -1 end
	if n < 1 or n > bus.MERGED_READ_MAX then return -1 end
	local buf = ffi.new("uint8_t[?]", n)
	if not spi_xfer(fd, nil, buf, n, delay_us) then return -1 end
	local v = 0
	for i = 0, n - 1 do
		v = v * 256 + tonumber(buf[i])
	end
	return v
end

-- 全双工一帧任意长度（单次传输，CS 保持低）：MOSI 发 data 的同时逐位移入
-- MISO。data 为 1 基字节值表（1~64 字节，同 spi_write_multi），返回等长
-- 1 基接收字节表；任何参数/传输失败返回 nil。delay_us 可选（CS 拉高前等待）。
-- 用于「MOSI 命令段与 MISO 数据段同帧」的协议：spi_read_multi 只发 dummy，
-- 拿不回与命令同帧移位的回传数据（MT6826S 的 24 位读帧：前两字节发
-- 命令+地址，MISO 数据在第 3 字节）。
function spi_xfer_full(fd, data, delay_us)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return nil end
	if #data > bus.SPI_IO_MAX_BYTES then return nil end
	local n = #data
	local txbuf = ffi.new("uint8_t[?]", n)
	for i = 1, n do
		local b = int_of(data[i], 0, 255)	-- 严格整数（拒绝小数；同 virtbus）
		if b == nil then return nil end
		txbuf[i - 1] = b
	end
	local rxbuf = ffi.new("uint8_t[?]", n)
	if not spi_xfer(fd, txbuf, rxbuf, n, delay_us) then return nil end
	local out = {}
	for i = 0, n - 1 do out[i + 1] = tonumber(rxbuf[i]) end
	return out
end

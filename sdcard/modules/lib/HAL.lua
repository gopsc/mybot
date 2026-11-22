-- P1-C 最小 Pico HAL：只提供 Timer 需要的 milli_sleep。
-- 后续 I2C/SPI/UART 会在这里接 __hal_call / Pico SDK。
if _G.__BOT4CJ_HAL ~= nil then
    return _G.__BOT4CJ_HAL
end

local HAL = {
    backend = "pico",
    backend_name = "pico-vga minimal HAL",
    platform = { name = "pico" },
    i2c_addr = {},
    uart_baud = {},
    uart_orig = {},
    pwm_state = {},
    PWM_SYSFS_ROOT = "",
    I2C_M_RD = 1,
}

function HAL.last_error()
    return "pico HAL: operation not implemented yet"
end

HAL.sys = {}
function HAL.sys.usleep(us)
    local n = tonumber(us) or 0
    if n > 0 then
        milli_sleep(n / 1000)
    end
end
function HAL.sys.close(fd)
    return 0
end

-- P3 I2C：Lua 只做参数归一化，物理事务走 C 侧 __i2c_*（Pico hardware_i2c）。
-- /dev/i2c-0 -> GP6/GP7，/dev/i2c-1 -> GP14/GP15；fake 路径仍是 fd=2。
function HAL.i2c_open(path) return __i2c_open(path) end
function HAL.i2c_close(fd) return __i2c_close(fd) end
function HAL.i2c_set_addr(fd, addr)
    fd, addr = tonumber(fd), tonumber(addr)
    if fd == nil or addr == nil or addr < 0 or addr > 0x7F then
        return false
    end
    HAL.i2c_addr[fd] = math.floor(addr)
    return true
end
function i2c_open(path) return HAL.i2c_open(path) end
function i2c_close(fd)
    HAL.i2c_addr[tonumber(fd) or -1] = nil
    return HAL.i2c_close(fd)
end
function i2c_set_addr(fd, addr) return HAL.i2c_set_addr(fd, addr) end

local function i2c_byte(v)
    v = tonumber(v)
    if v == nil or v < 0 or v > 255 then return nil end
    return math.floor(v)
end

local function i2c_transfer(fd, write, read_len)
    fd = tonumber(fd)
    local addr = HAL.i2c_addr[fd]
    if fd == nil or addr == nil then return nil end
    return __i2c_transfer(fd, addr, write, read_len or 0)
end

function i2c_write_reg(fd, reg, val)
    reg, val = i2c_byte(reg), i2c_byte(val)
    if reg == nil or val == nil then return -1 end
    local out = i2c_transfer(fd, {reg, val}, 0)
    return type(out) == "table" and 0 or -1
end

function i2c_read_reg(fd, reg)
    reg = i2c_byte(reg)
    if reg == nil then return -1 end
    local out = i2c_transfer(fd, {reg}, 1)
    if type(out) ~= "table" or #out ~= 1 then return -1 end
    return out[1]
end

function i2c_write_multi(fd, reg, ...)
    reg = i2c_byte(reg)
    if reg == nil then return -1 end
    local data = {reg}
    for _, v in ipairs({...}) do
        local b = i2c_byte(v)
        if b == nil then return -1 end
        data[#data + 1] = b
    end
    local out = i2c_transfer(fd, data, 0)
    return type(out) == "table" and 0 or -1
end

function i2c_read_multi_bytes(fd, reg, n)
    reg, n = i2c_byte(reg), tonumber(n)
    if reg == nil or n == nil or n < 1 or n > 64 then return nil end
    local out = i2c_transfer(fd, {reg}, math.floor(n))
    if type(out) ~= "table" or #out ~= math.floor(n) then return nil end
    return out
end

function i2c_read_multi(fd, reg, n)
    n = tonumber(n)
    if n == nil or n < 1 or n > 6 then return -1 end
    local bytes = i2c_read_multi_bytes(fd, reg, n)
    if bytes == nil then return -1 end
    local v = 0
    for i = 1, #bytes do v = v * 256 + bytes[i] end
    return v
end

function i2c_read(fd, n)
    n = tonumber(n)
    if n == nil or n < 1 or n > 6 then return -1 end
    local out = i2c_transfer(fd, {}, math.floor(n))
    if type(out) ~= "table" or #out ~= math.floor(n) then return -1 end
    local v = 0
    for i = 1, #out do v = v * 256 + out[i] end
    return v
end

function i2c_probe(fd, addr)
    addr = tonumber(addr)
    if addr == nil or addr < 0 or addr > 0x7F then return false end
    return __i2c_probe(tonumber(fd), math.floor(addr)) == true
end

function i2c_scan(fd)
    return __i2c_scan(tonumber(fd))
end

function HAL.spi_open(path) return __spi_open(path) end
function HAL.spi_close(fd) return __spi_close(fd) end
function HAL.spi_setup(fd, mode, bits, speed, delay)
    return __spi_setup(tonumber(fd), tonumber(mode), tonumber(bits),
        tonumber(speed), tonumber(delay) or 0)
end
function spi_open(path) return HAL.spi_open(path) end
function spi_close(fd) return HAL.spi_close(fd) end
function spi_setup(fd, mode, bits, speed, delay)
    return HAL.spi_setup(fd, mode, bits, speed, delay)
end

local function spi_byte(v)
    v = tonumber(v)
    if v == nil or v < 0 or v > 255 then return nil end
    return math.floor(v)
end

local function spi_xfer(fd, tx, read_len, delay)
    return __spi_xfer(tonumber(fd), tx, read_len or 0, delay)
end

function spi_write(fd, val, delay_us)
    val = spi_byte(val)
    if val == nil then return -1 end
    local out = spi_xfer(fd, {val}, 0, delay_us)
    return type(out) == "table" and 0 or -1
end

function spi_read(fd, delay_us)
    local out = spi_xfer(fd, {}, 1, delay_us)
    if type(out) ~= "table" or #out ~= 1 then return -1 end
    return out[1]
end

function spi_write3(fd, b0, b1, b2, delay_us)
    b0, b1, b2 = spi_byte(b0), spi_byte(b1), spi_byte(b2)
    if b0 == nil or b1 == nil or b2 == nil then return -1 end
    local out = spi_xfer(fd, {b0, b1, b2}, 0, delay_us)
    return type(out) == "table" and 0 or -1
end

function spi_write_multi(fd, data, delay_us)
    if type(data) ~= "table" or #data == 0 then return -1 end
    local tx = {}
    for i = 1, #data do
        local b = spi_byte(data[i])
        if b == nil then return -1 end
        tx[i] = b
    end
    local out = spi_xfer(fd, tx, 0, delay_us)
    return type(out) == "table" and 0 or -1
end

function spi_read_multi(fd, n, delay_us)
    n = tonumber(n)
    if n == nil or n < 1 or n > 6 then return -1 end
    local out = spi_xfer(fd, {}, math.floor(n), delay_us)
    if type(out) ~= "table" or #out ~= math.floor(n) then return -1 end
    local v = 0
    for i = 1, #out do v = v * 256 + out[i] end
    return v
end

function spi_xfer_full(fd, data, delay_us)
    if type(data) ~= "table" or #data == 0 then return nil end
    local tx = {}
    for i = 1, #data do
        local b = spi_byte(data[i])
        if b == nil then return nil end
        tx[i] = b
    end
    local out = spi_xfer(fd, tx, #tx, delay_us)
    if type(out) ~= "table" or #out ~= #tx then return nil end
    return out
end

function HAL.uart_open(path, baud) return __uart_open(path, tonumber(baud)) end
function HAL.uart_close(fd) return __uart_close(fd) end
function HAL.uart_write(fd, data) return __uart_write(fd, data) end
function HAL.uart_read(fd, n, timeout_ms) return __uart_read(fd, n, timeout_ms or 0) end
function HAL.uart_flush(fd) return __uart_flush(fd) end
function uart_open(path, baud) return HAL.uart_open(path, baud) end
function uart_close(fd) return HAL.uart_close(fd) end
function uart_write(fd, data) return HAL.uart_write(fd, data) end
function uart_read(fd, n, timeout_ms) return HAL.uart_read(fd, n, timeout_ms) end
function uart_flush(fd) return HAL.uart_flush(fd) end

_G.__BOT4CJ_HAL = HAL
return HAL

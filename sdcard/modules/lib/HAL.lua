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

function HAL.spi_open(path) return -1 end
function HAL.spi_close(fd) return -1 end
function HAL.uart_open(path, baud) return -1 end
function HAL.uart_close(fd) return -1 end
function HAL.uart_write(fd, data) return -1 end
function HAL.uart_read(fd, n, timeout_ms) return nil end

_G.__BOT4CJ_HAL = HAL
return HAL

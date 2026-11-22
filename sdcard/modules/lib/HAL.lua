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

-- P2-B 假 I2C 总线：路径含 fake/virt 时返回句柄 1，便于验证 $ref。
-- 真实 I2C 会在 P3 HAL 中替换这一层。
local function fake_i2c_path(path)
    return type(path) == "string" and (path:find("fake") ~= nil or path:find("virt") ~= nil)
end
function HAL.i2c_open(path)
    if fake_i2c_path(path) then return 1 end
    return -1
end
function HAL.i2c_close(fd) return 0 end
function HAL.i2c_set_addr(fd, addr) return true end
function i2c_open(path) return HAL.i2c_open(path) end
function i2c_close(fd) return HAL.i2c_close(fd) end
function i2c_set_addr(fd, addr) return HAL.i2c_set_addr(fd, addr) end
function HAL.spi_open(path) return -1 end
function HAL.spi_close(fd) return -1 end
function HAL.uart_open(path, baud) return -1 end
function HAL.uart_close(fd) return -1 end
function HAL.uart_write(fd, data) return -1 end
function HAL.uart_read(fd, n, timeout_ms) return nil end

_G.__BOT4CJ_HAL = HAL
return HAL

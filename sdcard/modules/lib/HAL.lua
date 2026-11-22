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

function HAL.i2c_open(path) return -1 end
function HAL.i2c_close(fd) return -1 end
function HAL.i2c_set_addr(fd, addr) return false end
function HAL.spi_open(path) return -1 end
function HAL.spi_close(fd) return -1 end
function HAL.uart_open(path, baud) return -1 end
function HAL.uart_close(fd) return -1 end
function HAL.uart_write(fd, data) return -1 end
function HAL.uart_read(fd, n, timeout_ms) return nil end

_G.__BOT4CJ_HAL = HAL
return HAL

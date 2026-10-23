-- Portable HAL: Lua buffers/driver semantics, Python library-backed hardware.
-- Host injects __hal_call before load, then removes it. Binary data uses byte tables.
if _G.__BOT4CJ_HAL ~= nil then return _G.__BOT4CJ_HAL end
local bridge = assert(__hal_call, "HAL requires the host __hal_call bridge")
local ffi = require("ffi")
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local bus = dofile(mpath.resolve("lib/bus_contract.lua"))
local HAL = {
    backend = "python", backend_name = "pyserial/pyftdi/pyav/urllib",
    platform = { name = "portable", gpio_prefix = false, pwm_sysfs_root = false },
    PWM_SYSFS_ROOT = false, i2c_addr = {}, uart_baud = {}, uart_orig = {}, pwm_state = {},
    UART_READ_MAX_MS = bus.UART_READ_MAX_MS,
}
-- Compatibility tokens only: never used for native OS calls.
local consts = {
    O_CLOEXEC = 0x80000, I2C_RDWR = 0x0707, I2C_M_RD = 1,
    SPI_IOC_WR_MODE = 0x40016b01, SPI_IOC_WR_BITS_PER_WORD = 0x40016b03,
    SPI_IOC_WR_MAX_SPEED_HZ = 0x40046b04, SPI_IOC_MESSAGE_1 = 0x40206b00,
    GPIO_GET_LINEHANDLE = 0xC16CB403, GPIOHANDLE_GET_LINE_VALUES = 0xC040B408,
    GPIOHANDLE_SET_LINE_VALUES = 0xC040B409, GPIOHANDLE_REQUEST_INPUT = 1,
    GPIOHANDLE_REQUEST_OUTPUT = 2, GPIOHANDLE_REQUEST_ACTIVE_LOW = 4,
    UART_O_FLAGS = 526594, UART_TCSANOW = 0, UART_TCIFLUSH = 0,
    UART_VMIN_IDX = 6, UART_VTIME_IDX = 5, UART_CREAD_CLOCAL = 2176,
    EAGAIN = 11, EINTR = 4, ENOENT = 2, EACCES = 13, EINVAL = 22,
}
for k, v in pairs(consts) do HAL[k] = v end
-- Retain the source's non-glibc/legacy compatibility table. pyserial itself
-- receives baud rates in Hz, never these historical termios tokens.
HAL.UART_B_CONST = {
    [1200] = 9, [2400] = 11, [4800] = 12, [9600] = 13, [19200] = 14, [38400] = 15,
    [57600] = 0x1001, [115200] = 0x1002, [230400] = 0x1003, [460800] = 0x1004,
    [500000] = 0x1005, [921600] = 0x1007, [1000000] = 0x1008,
}
HAL.sys = { consts = consts }
local function unsupported(name)
    return function() error("HAL: " .. name .. " is not supported by the portable backend", 2) end
end
function HAL.last_error() return bridge("last_error") end
local function report(value)
    if value == nil or value == -1 then print("HAL: " .. tostring(HAL.last_error())) end
    return value
end
function milli_sleep(ms)
    ms = bus.finite_of(ms)
    if ms == nil or ms <= 0 then return end
    bridge("sleep_ms", math.min(ms, 4294967))
end
HAL.sys.usleep = function(us) return bridge("sleep_ms", us / 1000) end
HAL.sys.close = function(fd) return report(bridge("close_handle", fd)) end
HAL.sys.version = function() return "portable" end
-- A data buffer ONLY; no native functions, addresses or ABI dependencies.
ffi.cdef[[
    typedef struct {
        uint16_t addr; uint16_t flags; uint16_t len; uint8_t *buf;
    } cj_i2c_msg;
]]
local function bytes(buf, n)
    local out = {}
    for i = 0, n - 1 do out[i + 1] = buf ~= nil and tonumber(buf[i]) or 0 end
    return out
end
local function copy_bytes(buf, data, n)
    if type(data) ~= "table" or #data ~= n then return false end
    for i = 1, n do
        if bus.int_of(data[i], 0, 255) == nil then return false end
    end
    for i = 1, n do buf[i - 1] = data[i] end
    return true
end
function HAL.sys.i2c_rdwr(fd, msgs, count)
    if count < 1 or count > 2 then return -1 end
    local addr, write, n, readbuf = tonumber(msgs[0].addr), {}, 0, nil
    for i = 0, count - 1 do
        local msg = msgs[i]
        if tonumber(msg.addr) ~= addr then return -1 end
        if tonumber(msg.flags) == HAL.I2C_M_RD then
            if i ~= count - 1 then return -1 end
            n, readbuf = tonumber(msg.len), msg.buf
        elseif tonumber(msg.flags) == 0 and i == 0 then
            write = bytes(msg.buf, tonumber(msg.len))
        else return -1 end
    end
    local out = report(bridge("i2c_transfer", fd, addr, write, n))
    if type(out) ~= "table" or #out ~= n then return -1 end
    if n > 0 and not copy_bytes(readbuf, out, n) then return -1 end
    return count
end
function HAL.sys.spi_setup(fd, mode, bits, speed)
    return report(bridge("spi_setup", fd, mode, bits, speed))
end
function HAL.sys.spi_xfer(fd, tx, rx, n, delay)
    local out = report(bridge("spi_transfer", fd, bytes(tx, n), delay or 0))
    if type(out) ~= "table" or #out ~= n then return -1 end
    if rx ~= nil and not copy_bytes(rx, out, n) then return -1 end
    return n
end
-- Preserve source normalization, merged-read limits and buffer behavior.
-- These two domains use FFI only for buffers, and hardware only through HAL.sys.
local ctx = { HAL = HAL, ffi = ffi, bus = bus, _c = consts,
    byte_of = bus.byte_of, uint_of = bus.uint_of, int_of = bus.int_of,
    bus_quiesced = function() return false end, O_RDWR = 2 }
for _, name in ipairs({ "i2c", "spi" }) do
    assert(loadfile(mpath.resolve("lib/hal/" .. name .. ".lua")))(ctx)
end
function i2c_open(path) return report(bridge("i2c_open", path)) end
function spi_open(path) return report(bridge("spi_open", path)) end
function uart_open(path, baud)
    baud = tonumber(baud)
    if not bus.baud_ok(baud) then return -1 end
    local fd = report(bridge("uart_open", path, baud))
    if fd ~= nil and fd >= 0 then HAL.uart_baud[fd] = baud end
    return fd or -1
end
function uart_close(fd)
    fd = bus.int_of(fd, 0)
    if fd == nil then return -1 end
    HAL.uart_baud[fd], HAL.uart_orig[fd] = nil, nil
    return report(bridge("close_handle", fd))
end
function uart_flush(fd) return report(bridge("uart_flush", tonumber(fd))) end
function uart_write(fd, data)
    if type(data) ~= "table" or #data == 0 or #data > bus.UART_IO_MAX_BYTES then return -1 end
    local out = {}
    for i = 1, #data do
        local b = bus.byte_of(data[i])
        if b == nil then return -1 end
        out[i] = b
    end
    return report(bridge("uart_write", tonumber(fd), out))
end
function uart_read(fd, n, timeout_ms)
    n = bus.uint_of(n)
    timeout_ms = timeout_ms == nil and 0 or bus.finite_of(timeout_ms)
    if n == nil or n < 1 or timeout_ms == nil or timeout_ms > bus.UART_READ_MAX_MS then return nil end
    return report(bridge("uart_read", tonumber(fd), math.min(n, bus.UART_IO_MAX_BYTES), timeout_ms))
end
-- HTTP 端点会话：open 只做 URL/超时校验（不建连，HTTP 无持久连接），
-- 实际请求由 http_request 逐次发起。回环之外的 base 由宿主 runtime 门
-- （--allow-hardware）拦截，Lua 侧不重复判定。http_request 返回表
-- {result, status, body, headers}——HTTP 4xx/5xx 也是 result="OK" 的合法
-- 响应（status 携带状态码），仅传输层失败返回 result="ERR"。
function http_open(base, timeout_ms)
    timeout_ms = bus.finite_of(timeout_ms)
    if timeout_ms == nil then timeout_ms = 10000 end
    if timeout_ms < 1 or timeout_ms > bus.HTTP_TIMEOUT_MAX_MS then return -1 end
    return report(bridge("http_open", base, timeout_ms))
end
function http_close(fd)
    fd = bus.int_of(fd, 0)
    if fd == nil then return -1 end
    return report(bridge("close_handle", fd))
end
function http_request(fd, method, path, headers, body)
    return bridge("http_request", tonumber(fd), method, path, headers, body)
end
-- 宿主进程执行会话：open 仅登记默认超时（不拉起进程），实际执行在 shell_run，
-- 进程逐次创建、随调用结束击杀。该能力属宿主世界访问，由宿主 runtime 门统一
-- 要求 --allow-hardware（与物理设备/非回环 HTTP 同门，Lua 侧不重复判定）。
-- shell_run 返回 {result, code, out, err, truncated}——非零退出码仍是
-- result="OK" 的正常完成（code 携带退出码），仅启动失败/超时/取消为 ERR。
function shell_open(timeout_ms)
    timeout_ms = bus.finite_of(timeout_ms)
    if timeout_ms == nil then timeout_ms = 10000 end
    if timeout_ms < 1 or timeout_ms > bus.SHELL_TIMEOUT_MAX_MS then return -1 end
    return report(bridge("shell_open", timeout_ms))
end
function shell_close(fd)
    fd = bus.int_of(fd, 0)
    if fd == nil then return -1 end
    return report(bridge("close_handle", fd))
end
function shell_run(fd, command, timeout_ms)
    return bridge("shell_run", tonumber(fd), command, timeout_ms)
end
for _, name in ipairs({ "gpio_request_line", "gpio_set_value", "gpio_get_value", "gpio_free_line",
    "pwm_npwm", "pwm_exported", "pwm_export", "pwm_config", "pwm_set_polarity", "pwm_enable", "pwm_unexport",
    "speaker_open", "speaker_write", "speaker_close" }) do
    _G[name] = unsupported(name)
end
for _, name in ipairs({ "open", "ioctl_i", "ioctl_p", "read", "write", "errno",
    "tcgetattr", "tcsetattr", "cfmakeraw", "cfsetispeed", "cfsetospeed", "tcflush" }) do
    HAL.sys[name] = unsupported("native " .. name)
end
-- Camera receives Lua closures, not the Python callable or its attributes.
function HAL.camera_open(device, width, height)
    return report(bridge("camera_open", device, width, height))
end
function HAL.camera_capture(handle, options) return bridge("camera_capture", handle, options) end
function HAL.camera_close(handle) return report(bridge("close_handle", handle)) end
-- Reuse pure Lua virtual models; mixed physical/virtual states route by handle.
-- Legacy proto=virt callers can still inject()/adopt_fd() without modification.
local function virtual_path(path)
    return type(path) == "string" and path:match("^virt%-%w[%w_./%-]*$") ~= nil
end
for _, kind in ipairs({ "i2c", "spi", "uart" }) do
    local key, previous = kind .. "_path_ok", bus[kind .. "_path_ok"]
    bus[key] = function(path) return virtual_path(path) or previous(path) end
end
-- Hand virtbus the already-loaded (and path-wrapped) contract through a private
-- source environment instead of recompiling it. Host-resolved paths use the
-- platform separator, so match either slash.
local vchunk = assert(loadfile(mpath.resolve("lib/virtbus.lua")))
local venvironment = setmetatable({ dofile = function(path)
    if type(path) == "string" and path:match("[/\\]lib[/\\]bus_contract%.lua$") then return bus end
    return dofile(path)
end }, { __index = _G, __newindex = _G })
setfenv(vchunk, venvironment)
local vbus = vchunk()
local virtual = {}
for _, kind in ipairs({ "i2c", "spi", "uart" }) do
    local name = kind .. "_open"
    local real_open, virtual_open = _G[name], vbus["v_" .. name]
    _G[name] = function(path, ...)
        if virtual_path(path) then
            local fd = virtual_open(path, ...)
            if fd ~= nil and fd >= 0 then virtual[fd] = kind end
            return fd
        end
        return real_open(path, ...)
    end
end
local routed = {}
for name, fn in pairs(vbus) do
    if type(fn) == "function" and name:match("^v_") and not name:match("_open$") then
        routed[name:sub(3)] = fn
    end
end
for name, virtual_fn in pairs(routed) do
    local real_fn = _G[name]
    if real_fn ~= nil then
        _G[name] = function(fd, ...)
            if virtual[tonumber(fd)] ~= nil then
                local result = virtual_fn(fd, ...)
                if name:match("_close$") then virtual[tonumber(fd)] = nil end
                return result
            end
            return real_fn(fd, ...)
        end
    end
end
_G.__BOT4CJ_HAL = HAL
-- Route drv_common's proto=virt library probes to this state's loaded tables
-- (virtbus/bus_contract also guard re-entry; this just skips recompiling).
if type(virt_prepare) ~= "function" then dofile(mpath.resolve("lib/drv_common.lua")) end
local prepare_environment = setmetatable({ dofile = function(path)
    if type(path) == "string" and path:match("[/\\]lib[/\\]virtbus%.lua$") then return vbus end
    if type(path) == "string" and path:match("[/\\]lib[/\\]bus_contract%.lua$") then return bus end
    return dofile(path)
end }, { __index = _G, __newindex = _G })
setfenv(virt_prepare, prepare_environment)
_G.__hal_call = nil
return HAL

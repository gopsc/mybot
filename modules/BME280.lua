-- BME280 温湿度气压传感器 驱动模块（I2C，地址 0x76/0x77）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .mt 或 .sql）：
--   @BME280
--        name    I2C   address;
--   bme280-0  i2c-1     0x76;
--   @
--
-- call 无需额外参数（元数据由框架自动合并传入），返回 { result, T(°C), P(Pa), H(%RH) }
--
-- 实现要点：
--   1. i2c_write_reg 在 r.cj 中不向 Lua 压入返回值（fire-and-forget），
--      因此不检查其返回值，改为回读寄存器验证配置是否生效
--   2. i2c_read_multi 把 n 字节按大端合并为有符号 Int64，
--      首字节 >= 0x80 时会回绕成负数、被误判为读取失败，
--      故多字节读取一律按 4 字节块进行（合并值 <= 0xFFFFFFFF，恒为正）
--   3. 软复位后须等状态寄存器 im_update 位（bit0）清零，才可读取校准系数
--   4. 校准区 0x88~0x9F 为小端，测量数据区 0xF7~0xFE 为大端
--   5. 补偿公式为数据手册附录 8.3 的浮点版
--   6. 过采样固定 x1/x1/x1（单次测量约 6~9ms），两次 call 建议间隔 > 1s

-- ==================== 寄存器 ====================
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/HAL.lua")
-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")
local bitc = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/bitcompat.lua")

local REG_ID        = 0xD0   -- 芯片ID（BME280=0x60，BMP280=0x58）
local REG_RESET     = 0xE0   -- 软复位（写0xB6）
local REG_STATUS    = 0xF3   -- bit3=measuring，bit0=im_update
local REG_CTRL_HUM  = 0xF2   -- 湿度过采样（须在 ctrl_meas 之前写入才生效）
local REG_CTRL_MEAS = 0xF4   -- 温/压过采样与模式
local REG_CONFIG    = 0xF5   -- 待机时间/滤波（I2C下spi3w只读）
local REG_TP_CAL    = 0x88   -- 温度/气压校准系数块 0x88~0x9F（小端）
local REG_H1        = 0xA1   -- H1（8位）
local REG_H_CAL     = 0xE1   -- 湿度校准系数块 0xE1~0xE7
local REG_DATA      = 0xF7   -- 测量数据块 0xF7~0xFE（大端）：P(20bit) T(20bit) H(16bit)

-- ==================== 配置 ====================
local CHIP_ID_BME280   = 0x60
local RESET_CMD        = 0xB6
local STATUS_IM_UPDATE = 0x01                 -- NVM校准数据拷贝进行中
local STATUS_MEASURING = 0x08                 -- 测量进行中
local OSRS_H_X1        = 0x01                 -- 湿度过采样 x1
local CTRL_MEAS_BASE   = bitc.bor(bitc.lshift(0x01, 5), bitc.lshift(0x01, 2))  -- 温/压过采样 x1，mode=00
local MODE_SLEEP       = 0x00
local MODE_FORCED      = 0x01                 -- 单次触发

-- 调试开关：默认关闭逐次打印
local DEBUG = false

-- ==================== 校准系数（build 时读出） ====================
local dig_T1, dig_T2, dig_T3
local dig_P1, dig_P2, dig_P3, dig_P4, dig_P5, dig_P6, dig_P7, dig_P8, dig_P9
local dig_H1, dig_H2, dig_H3, dig_H4, dig_H5, dig_H6
local cal_ok = false

-- 辅助：整数值拆成 n 个字节（下标1起始，大端序），用 // 与 % 保持在整数域
local function to_bytes(v, n)
    local b = {}
    for i = n, 1, -1 do
        b[i] = v % 256
        v = math.floor(v / 256)
    end
    return b
end

-- 辅助：从 reg 起按 4 字节块读 n 字节（n 为 4 的倍数），拼接成大端字节数组
-- 失败返回 nil（宿主合并值只有 -1 表示失败，4 字节合并恒为正）
local function read_block(fd, reg, n)
    local b = {}
    for off = 0, n - 4, 4 do
        local v = i2c_read_multi(fd, reg + off, 4)
        if v < 0 then
            return nil
        end
        local seg = to_bytes(v, 4)
        for i = 1, 4 do
            b[#b + 1] = seg[i]
        end
    end
    return b
end

-- 辅助：小端16位（校准系数：b[i]=LSB，b[i+1]=MSB）
local function u16le(b, i) return b[i] + b[i + 1] * 256 end
local function s16le(b, i)
    local v = b[i] + b[i + 1] * 256
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

-- 辅助：符号扩展
local function s12(v)
    if v >= 0x800 then v = v - 0x1000 end
    return v
end
local function s8(v)
    if v >= 0x80 then v = v - 0x100 end
    return v
end

-- 【配置脚本】初始化BME280：校验ID、软复位、读校准系数、配置过采样
function build(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments Type: table" }
    end

    if DEBUG then
        dbg_table("-------- BME280 builder func get a table --------", data)
    end

    local fd = tonumber(data.fd)
    local addr = tonumber(data.address)
    if fd == nil or addr == nil then
        return { result = "ERR", message = "Invalid Argument: fd or address" }
    end

    i2c_set_addr(fd, addr)

    -- 校验芯片ID
    local id = i2c_read_multi(fd, REG_ID, 1)
    if id < 0 then
        return { result = "ERR", message = "Failed to read chip id" }
    end
    if id ~= CHIP_ID_BME280 then
        return { result = "ERR",
                 message = string.format("Unexpected chip id: 0x%02X (BMP280?)", id) }
    end

    -- 软复位，等待NVM校准数据拷贝完成（im_update位清零）
    i2c_write_reg(fd, REG_RESET, RESET_CMD)
    milli_sleep(3)
    local copied = false
    for _ = 1, 50 do
        local st = i2c_read_multi(fd, REG_STATUS, 1)
        if st >= 0 and bitc.band(st, STATUS_IM_UPDATE) == 0 then
            copied = true
            break
        end
        milli_sleep(1)
    end
    if not copied then
        return { result = "ERR", message = "Calibration copy timeout" }
    end

    -- 校准系数：0x88~0x9F共24字节（小端），按4字节块读取
    local b = read_block(fd, REG_TP_CAL, 24)
    if b == nil then
        return { result = "ERR", message = "Failed to read calibration" }
    end
    dig_T1 = u16le(b, 1);  dig_T2 = s16le(b, 3);  dig_T3 = s16le(b, 5)
    dig_P1 = u16le(b, 7);  dig_P2 = s16le(b, 9);  dig_P3 = s16le(b, 11)
    dig_P4 = s16le(b, 13); dig_P5 = s16le(b, 15); dig_P6 = s16le(b, 17)
    dig_P7 = s16le(b, 19); dig_P8 = s16le(b, 21); dig_P9 = s16le(b, 23)

    local h1 = i2c_read_multi(fd, REG_H1, 1)
    if h1 < 0 then
        return { result = "ERR", message = "Failed to read calibration" }
    end
    dig_H1 = h1

    -- H2(0xE1,s16) H3(0xE3,u8) H4(s12: E4<<4|E5低4位) H5(s12: E6<<4|E5高4位) H6(0xE7,s8)
    -- 共7字节，合并值 < 2^56，不会溢出，可一次读
    local ce = i2c_read_multi(fd, REG_H_CAL, 7)
    if ce < 0 then
        return { result = "ERR", message = "Failed to read calibration" }
    end
    local e = to_bytes(ce, 7)
    dig_H2 = s16le(e, 1)
    dig_H3 = e[3]
    dig_H4 = s12(bitc.bor(bitc.lshift(e[4], 4), bitc.band(e[5], 0x0F)))
    dig_H5 = s12(bitc.bor(bitc.lshift(e[6], 4), bitc.rshift(e[5], 4)))
    dig_H6 = s8(e[7])

    -- 配置：滤波关闭 -> 湿度过采样 -> 温/压过采样，保持睡眠模式
    i2c_write_reg(fd, REG_CONFIG, 0x00)
    i2c_write_reg(fd, REG_CTRL_HUM, OSRS_H_X1)
    i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP))

    -- write_reg 不返回状态，回读寄存器确认配置生效
    local chk_hum = i2c_read_multi(fd, REG_CTRL_HUM, 1)
    local chk_meas = i2c_read_multi(fd, REG_CTRL_MEAS, 1)
    if chk_hum ~= OSRS_H_X1 or chk_meas ~= (bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP)) then
        return { result = "ERR", message = "Failed to configure BME280" }
    end

    cal_ok = true
    print(string.format("BME280 init OK: addr=0x%02X, oversampling=x1/x1/x1", addr))
    return { result = "OK" }
end

-- 【销毁脚本】进入睡眠模式
function destroy(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments Type: table" }
    end

    local fd = tonumber(data.fd)
    local addr = tonumber(data.address)
    if fd ~= nil and fd >= 0 and addr ~= nil then
        i2c_set_addr(fd, addr)
        i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_SLEEP))
    end
    cal_ok = false

    return { result = "OK" }
end

-- 【调用脚本】单次触发测量并返回 T(°C) / P(Pa) / H(%RH)
function call(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments Type: table" }
    end

    if not cal_ok then
        return { result = "ERR", message = "BME280 not initialized, run build first" }
    end

    local fd = tonumber(data.fd)
    local addr = tonumber(data.address)
    if fd == nil or addr == nil then
        return { result = "ERR", message = "Invalid Argument: fd or address" }
    end

    i2c_set_addr(fd, addr)

    -- 单次触发测量（forced模式，完成后自动回到睡眠）
    i2c_write_reg(fd, REG_CTRL_MEAS, bitc.bor(CTRL_MEAS_BASE, MODE_FORCED))

    -- x1过采样单次测量约6~9ms，先等5ms再轮询measuring位，最多再等100ms
    milli_sleep(5)
    local ready = false
    for _ = 1, 100 do
        local st = i2c_read_multi(fd, REG_STATUS, 1)
        if st >= 0 and bitc.band(st, STATUS_MEASURING) == 0 then
            ready = true
            break
        end
        milli_sleep(1)
    end
    if not ready then
        return { result = "ERR", message = "Measurement timeout" }
    end

    -- 数据区 0xF7~0xFE（大端）：P(20bit) T(20bit) H(16bit)，按4字节块读
    local b = read_block(fd, REG_DATA, 8)
    if b == nil then
        return { result = "ERR", message = "Failed to read measurement" }
    end

    local adc_P = bitc.bor(bitc.bor(bitc.lshift(b[1], 12), bitc.lshift(b[2], 4)), bitc.rshift(b[3], 4))
    local adc_T = bitc.bor(bitc.bor(bitc.lshift(b[4], 12), bitc.lshift(b[5], 4)), bitc.rshift(b[6], 4))
    local adc_H = bitc.bor(bitc.lshift(b[7], 8), b[8])

    if adc_T == 0x80000 then
        return { result = "ERR", message = "Invalid temperature reading" }
    end
    if adc_H == 0x8000 then
        return { result = "ERR", message = "Invalid humidity reading" }
    end

    -- 温度补偿（数据手册附录8.3浮点版），t_fine 供气压/湿度复用
    local var1 = (adc_T / 16384.0 - dig_T1 / 1024.0) * dig_T2
    local var2 = adc_T / 131072.0 - dig_T1 / 8192.0
    var2 = var2 * var2 * dig_T3
    local t_fine = var1 + var2
    local T = t_fine / 5120.0

    -- 气压补偿（Pa）
    var1 = t_fine / 2.0 - 64000.0
    var2 = var1 * var1 * dig_P6 / 32768.0
    var2 = var2 + var1 * dig_P5 * 2.0
    var2 = var2 / 4.0 + dig_P4 * 65536.0
    var1 = (dig_P3 * var1 * var1 / 524288.0 + dig_P2 * var1) / 524288.0
    var1 = (1.0 + var1 / 32768.0) * dig_P1
    if var1 == 0 then
        return { result = "ERR", message = "Pressure compensation failed" }
    end
    local p = 1048576.0 - adc_P
    p = (p - var2 / 4096.0) * 6250.0 / var1
    var1 = dig_P9 * p * p / 2147483648.0
    var2 = p * dig_P8 / 32768.0
    p = p + (var1 + var2 + dig_P7) / 16.0

    -- 湿度补偿（%RH，钳位0~100）
    local h = t_fine - 76800.0
    h = (adc_H - (dig_H4 * 64.0 + dig_H5 / 16384.0 * h))
        * (dig_H2 / 65536.0 * (1.0 + dig_H6 / 67108864.0 * h
            * (1.0 + dig_H3 / 67108864.0 * h)))
    h = h * (1.0 - dig_H1 * h / 524288.0)
    if h > 100.0 then h = 100.0 elseif h < 0.0 then h = 0.0 end

    if DEBUG then
        print(string.format("BME280: T=%.2f C, P=%.2f Pa, H=%.2f %%RH", T, p, h))
    end

    return { result = "OK", T = T, P = p, H = h }
end

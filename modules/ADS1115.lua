-- ADS1115 模数转换器 驱动模块（I2C，16 位，4 通道单端 / 2 路差分）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（.mt 脚本）：
--   @ADS1115
--   name    I2C     address   pga   dr   channel;
--   ads1115-0  i2c-1  0x48      -     -     0;
--   @
-- pga: 0~5（默认 2 = ±2.048V）；dr: 0~7（默认 4 = 128SPS）；channel: 默认 0
--
-- call 参数（来自 @Action 或直接 play）：
--   channel: 0~3 单端读取
--   pos/neg: 差分读取（支持 0-1, 0-3, 1-3, 2-3）
--
-- 依赖 r.cj 注册的 i2c_write_multi / i2c_read_multi（burst 读写 16 位寄存器）

-- ==================== 寄存器 ====================
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/HAL.lua")
-- 调试打印辅助 print_table（modules/lib/）
dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/print_table.lua")
local bitc = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/bitcompat.lua")

local REG_CONVERSION     = 0x00   -- 转换结果（只读，16 位）
local REG_CONFIG         = 0x01   -- 配置寄存器（读/写，16 位）
local REG_LO_THRESH      = 0x02   -- 低阈值比较
local REG_HI_THRESH      = 0x03   -- 高阈值比较

-- ==================== 配置位 ====================
local OS_START           = 0x8000 -- 单次转换启动位（1=开始，完成后硬件自动清零）
local MUX_DIFF_AIN0_AIN1 = 0x0000 -- 差分：P=AIN0，N=AIN1
local MUX_DIFF_AIN0_AIN3 = 0x1000 -- 差分：P=AIN0，N=AIN3
local MUX_DIFF_AIN1_AIN3 = 0x2000 -- 差分：P=AIN1，N=AIN3
local MUX_DIFF_AIN2_AIN3 = 0x3000 -- 差分：P=AIN2，N=AIN3
local MUX_SINGLE_AIN0    = 0x4000 -- 单端：AIN0（AINch = 0x4000 | ch<<12）
local MODE_SINGLE        = 0x0100 -- 单次转换模式
local COMP_QUE_DISABLE   = 0x0003 -- 禁用比较器

-- PGA 增益 → 满量程电压（V）
local pga_fs = { 6.144, 4.096, 2.048, 1.024, 0.512, 0.256 }
local pga_names = { "±6.144V", "±4.096V", "±2.048V", "±1.024V", "±0.512V", "±0.256V" }
-- 数据速率（SPS）
local dr_sps = { 8, 16, 32, 64, 128, 250, 475, 860 }
local dr_names = { "8", "16", "32", "64", "128", "250", "475", "860" }

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- 辅助：把 16 位无符号值符号扩展为有符号数
local function sign16(v)
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

-- 辅助：把数据里的字段转成数字（字符串/数字均可），nil 返回默认值
local function tonum(v, default)
    if v == nil then return default end
    return tonumber(v) or default
end

-- 【配置脚本】初始化 ADS1115
function build(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments Type: table" }
    end

    if DEBUG then
        dbg_table("-------- ADS1115 builder func get a table --------", data)
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Argument: fd" }
    end
    fd = tonumber(fd)

    local addr = data.address
    if addr == nil then
        return { result = "ERR", message = "Invalid Arguments: addr" }
    end
    addr = tonumber(addr)

    -- 可配置项（缺省：AIN0 单端 / ±2.048V / 128SPS / 单次 / 禁比较器）
    local pga_idx = tonum(data.pga, 2)
    local dr_idx  = tonum(data.dr, 4)
    local channel = tonum(data.channel, 0)
    if pga_idx < 0 or pga_idx > 5 then pga_idx = 2 end
    if dr_idx  < 0 or dr_idx  > 7 then dr_idx  = 4 end
    if channel < 0 or channel > 3 then channel = 0 end

    local config = MUX_SINGLE_AIN0
    config = bitc.bor(config, bitc.lshift(channel, 12))   -- 输入通道
    config = bitc.bor(config, bitc.lshift(pga_idx, 9))    -- PGA 增益
    config = bitc.bor(config, MODE_SINGLE)                -- 单次模式
    config = bitc.bor(config, bitc.lshift(dr_idx, 5))     -- 数据速率
    config = bitc.bor(config, COMP_QUE_DISABLE)           -- 禁用比较器

    i2c_set_addr(fd, addr)

    -- 写 16 位配置寄存器（burst 写：reg + 高字节 + 低字节）
    local hi = math.floor(config / 256) % 256
    local lo = config % 256
    local wr = i2c_write_multi(fd, REG_CONFIG, hi, lo)
    if wr ~= 0 then
        return { result = "ERR", message = "Failed to write ADS1115 config" }
    end

    -- 读回验证
    local rd = i2c_read_multi(fd, REG_CONFIG, 2)
    if rd < 0 then
        return { result = "ERR", message = "Failed to read back ADS1115 config" }
    end

    print(string.format("ADS1115 init OK: addr=0x%02X, channel=AIN%d, PGA=%s, DR=%s SPS",
        addr, channel, pga_names[pga_idx + 1], dr_names[dr_idx + 1]))
    return { result = "OK" }
end

-- 【销毁脚本】停止转换，回到低功耗
function destroy(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments Type: table" }
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Arguments: fd" }
    end
    local addr = data.address
    if addr == nil then
        return { result = "ERR", message = "Invalid Arguments: addr" }
    end

    i2c_set_addr(tonumber(fd), tonumber(addr))
    i2c_write_multi(tonumber(fd), REG_CONFIG, 0x00, 0x00)  -- 清零配置，停止转换

    return { result = "OK" }
end

-- 【调用脚本】读取一个通道的电压
-- 参数：channel（0~3 单端）或 pos/neg（差分）
function call(data)
    if type(data) ~= "table" then
        return { result = "ERR", message = "Invalid Arguments: table" }
    end

    if DEBUG then
        dbg_table("-------- ADS1115 caller func get a table --------", data)
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Argument: fd" }
    end
    fd = tonumber(fd)

    local addr = data.address
    if addr == nil then
        return { result = "ERR", message = "Invalid Argument: addr" }
    end
    addr = tonumber(addr)

    -- 差分 / 单端模式选择
    local mux
    if data.pos ~= nil and data.neg ~= nil then
        local pos, neg = tonumber(data.pos), tonumber(data.neg)
        local diff_map = { ["0,1"] = MUX_DIFF_AIN0_AIN1, ["0,3"] = MUX_DIFF_AIN0_AIN3,
                           ["1,3"] = MUX_DIFF_AIN1_AIN3, ["2,3"] = MUX_DIFF_AIN2_AIN3 }
        mux = diff_map[pos .. "," .. neg]
        if mux == nil then
            return { result = "ERR", message = "Unsupported diff pair, use 0-1/0-3/1-3/2-3" }
        end
    else
        local channel = tonum(data.channel, 0)
        if channel < 0 or channel > 3 then
            return { result = "ERR", message = "Invalid channel: 0~3" }
        end
        mux = bitc.bor(MUX_SINGLE_AIN0, bitc.lshift(channel, 12))
    end

    -- 读回当前配置，保留 PGA/DR，只改 MUX 并启动单次转换
    local config = i2c_read_multi(fd, REG_CONFIG, 2)
    if config < 0 then
        return { result = "ERR", message = "Failed to read config" }
    end
    local new_config = bitc.bor(bitc.bor(bitc.band(config, 0x8FFF), mux), OS_START)   -- 清 MUX 位，设通道，启动转换

    local hi = math.floor(new_config / 256) % 256
    local lo = new_config % 256
    if i2c_write_multi(fd, REG_CONFIG, hi, lo) ~= 0 then
        return { result = "ERR", message = "Failed to start conversion" }
    end

    -- 轮询 OS 位：转换完成后硬件自动清零（128SPS 约 7.8ms，最多等 100ms）
    local ready = false
    for _ = 1, 100 do
        local cfg = i2c_read_multi(fd, REG_CONFIG, 2)
        if cfg >= 0 and bitc.band(cfg, OS_START) == 0 then
            ready = true
            break
        end
        milli_sleep(1)
    end
    if not ready then
        return { result = "ERR", message = "Conversion timeout" }
    end

    -- 读转换结果（16 位有符号）
    local raw16 = i2c_read_multi(fd, REG_CONVERSION, 2)
    if raw16 < 0 then
        return { result = "ERR", message = "Failed to read conversion" }
    end

    local pga_idx = tonum(data.pga, bitc.band(bitc.rshift(config, 9), 0x07))
    if pga_idx < 0 or pga_idx > 5 then pga_idx = 2 end
    local fs = pga_fs[pga_idx + 1]
    local raw = sign16(raw16)
    local voltage = raw * fs / 32768.0

    return {
        result = "OK",
        raw = raw,
        voltage = voltage
    }
end

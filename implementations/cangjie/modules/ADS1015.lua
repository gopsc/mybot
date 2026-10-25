-- ADS1015 模数转换器 驱动模块（I2C，12 位，4 通道单端 / 差分）
-- bot4cj 仓颉语言机器人框架
--
-- TI ADS1015：ADS1115 的 12 位快速孪生（引脚/寄存器兼容），换约 4 倍数据率
-- （最高 3300SPS vs 860SPS）。列语义与返回键与 ADS1115.lua 完全一致，
-- 差异仅两处：DR 档位表（128~3300SPS）、12 位结果【左对齐】放在 16 位转换
-- 寄存器（低 4 位恒 0，需右移 4 位；单端有效 11 位）。
--
-- 用法（.mt 脚本）：
--   @ADS1015
--   name    I2C     address   pga   dr   channel;
--   ads1015-0  i2c-1  0x48      -     -     0;
--   @
-- pga: 0~5（默认 2 = ±2.048V）；dr: 0~7（默认 4 = 1600SPS）；channel: 默认 0
--
-- call 参数（来自 @Action 或直接 play）：
--   channel: 0~3 单端读取
--   pos/neg: 差分读取（支持 0-1, 0-3, 1-3, 2-3）
--
-- 自检：本芯片无 ID 寄存器，build 写配置后读回比对（在位探测 + 配置确认）。
-- 数据率事实来源：Linux 内核 ti-ads1015 IIO 驱动（DR 表 {128,250,490,920,
-- 1600,2400,3300,3300}，数据提取 sign_extend32(raw>>4, 11)）。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

local REG_CONVERSION     = 0x00   -- 转换结果（只读，12 位左对齐于 16 位）
local REG_CONFIG         = 0x01   -- 配置寄存器（读/写，16 位）
local REG_LO_THRESH      = 0x02   -- 低阈值比较
local REG_HI_THRESH      = 0x03   -- 高阈值比较

-- ==================== 配置位 ====================
local OS_START           = 0x8000 -- 单次转换启动位。写 1=启动转换；
                                  -- 读语义：0=正在转换，1=空闲/转换完成（datasheet 8.6.3）
local MUX_DIFF_AIN0_AIN1 = 0x0000 -- 差分：P=AIN0，N=AIN1
local MUX_DIFF_AIN0_AIN3 = 0x1000 -- 差分：P=AIN0，N=AIN3
local MUX_DIFF_AIN1_AIN3 = 0x2000 -- 差分：P=AIN1，N=AIN3
local MUX_DIFF_AIN2_AIN3 = 0x3000 -- 差分：P=AIN2，N=AIN3
local MUX_SINGLE_AIN0    = 0x4000 -- 单端：AIN0（AINch = 0x4000 | ch<<12）
local MODE_SINGLE        = 0x0100 -- 单次转换模式（1 = 单次/转换间隙断电）
local COMP_QUE_DISABLE   = 0x0003 -- 禁用比较器

-- PGA 增益 → 满量程电压（V）
local pga_fs = { 6.144, 4.096, 2.048, 1.024, 0.512, 0.256 }
local pga_names = { "±6.144V", "±4.096V", "±2.048V", "±1.024V", "±0.512V", "±0.256V" }
-- 数据速率（SPS）：ADS1015 档位表（110/111 同为 3300）
local dr_sps = { 128, 250, 490, 920, 1600, 2400, 3300, 3300 }
local dr_names = { "128", "250", "490", "920", "1600", "2400", "3300", "3300" }

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

-- 辅助：12 位左对齐原始值 -> 12 位有符号码值（算术右移 4 位）
local function raw12_of(raw16)
    local v = sign16(raw16)
    -- floor 除法即算术右移（负数向 -inf 取整，与 >> 语义一致）
    return math.floor(v / 16)
end

-- 【配置脚本】初始化 ADS1015
function build(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    if DEBUG then
        dbg_table("-------- ADS1015 builder func get a table --------", data)
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

    -- 可配置项（缺省：AIN0 单端 / ±2.048V / 1600SPS / 单次 / 禁比较器）
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

    if not i2c_set_addr(fd, addr) then
        return { result = "ERR", message = "Invalid Argument: fd or address (set_addr failed)" }
    end

    -- 写 16 位配置寄存器（burst 写：reg + 高字节 + 低字节）
    local hi = math.floor(config / 256) % 256
    local lo = config % 256
    if i2c_write_multi(fd, REG_CONFIG, hi, lo) ~= 0 then
        return { result = "ERR", message = "Failed to write ADS1015 config" }
    end

    -- 读回比对自检（无 ID 寄存器，兼在位探测与配置确认）。
    -- 比对须掩掉 OS 位（bit15）：其读语义为转换状态（空闲恒读 1），
    -- 与写入值（OS=0）必然不同，全 16 位比对在真实器件上永远 mismatch。
    local rd = i2c_read_multi(fd, REG_CONFIG, 2)
    if rd < 0 then
        return { result = "ERR", message = "Failed to read back ADS1015 config" }
    end
    if bitc.band(rd, 0x7FFF) ~= bitc.band(config, 0x7FFF) then
        return { result = "ERR",
                 message = string.format("ADS1015 config echo mismatch: got 0x%04X (expect 0x%04X)", rd, config) }
    end

    print(string.format("ADS1015 init OK: addr=0x%02X, channel=AIN%d, PGA=%s, DR=%s SPS",
        addr, channel, pga_names[pga_idx + 1], dr_names[dr_idx + 1]))
    return { result = "OK" }
end

-- 【销毁脚本】置单次模式进入转换间隙断电态（保留 PGA/DR/MUX 配置）
function destroy(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    local fd = tonumber(data.fd)
    local addr = tonumber(data.address)
    if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
        -- 读改写：仅确保 MODE=1（单次态下不启动转换即断电），不破坏其余配置。
        -- 须清掉读回的 OS 位（空闲恒读 1）：原样写回 OS=1 会误启动一次多余转换。
        local config = i2c_read_multi(fd, REG_CONFIG, 2)
        if config >= 0 then
            local new_config = bitc.band(bitc.bor(config, MODE_SINGLE), 0x7FFF)
            i2c_write_multi(fd, REG_CONFIG,
                math.floor(new_config / 256) % 256, new_config % 256)
        end
    end

    return { result = "OK" }
end

-- 【调用脚本】读取一个通道的电压
-- 参数：channel（0~3 单端）或 pos/neg（差分）
function call(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    if DEBUG then
        dbg_table("-------- ADS1015 caller func get a table --------", data)
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

    if not i2c_set_addr(fd, addr) then
        return { result = "ERR", message = "Invalid Argument: fd or address (set_addr failed)" }
    end

    -- 差分 / 单端模式选择
    local mux
    if data.pos ~= nil and data.neg ~= nil then
        -- 先判 tonumber 结果：占位符 "-" 或非法串转出 nil，直接拼串会触发
        -- 裸 Lua error（被宿主 pcall 吞成通用错误），应按契约返回 ERR
        local pos, neg = tonumber(data.pos), tonumber(data.neg)
        if pos == nil or neg == nil then
            return { result = "ERR", message = "Invalid diff pair: pos/neg not a number" }
        end
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

    if i2c_write_multi(fd, REG_CONFIG,
        math.floor(new_config / 256) % 256, new_config % 256) ~= 0 then
        return { result = "ERR", message = "Failed to start conversion" }
    end

    -- 轮询 OS 位：读到 0 表示正在转换，读到 1 表示转换完成/空闲
    -- （1600SPS 约 0.6ms，最多等 100ms）。注意与写语义相反——若误等 0，
    -- 启动转换后首轮即满足，读到的是上一次的陈旧值。
    local ready = false
    for _ = 1, 100 do
        local cfg = i2c_read_multi(fd, REG_CONFIG, 2)
        if cfg >= 0 and bitc.band(cfg, OS_START) ~= 0 then
            ready = true
            break
        end
        milli_sleep(1)
    end
    if not ready then
        return { result = "ERR", message = "Conversion timeout" }
    end

    -- 读转换结果（12 位左对齐于 16 位，低 4 位恒 0）
    local raw16 = i2c_read_multi(fd, REG_CONVERSION, 2)
    if raw16 < 0 then
        return { result = "ERR", message = "Failed to read conversion" }
    end

    -- pga 缺省时回读芯片配置的 PGA 字段（3 位，0~7）：6/7 与 5 同为 ±0.256V
    -- （datasheet 冗余编码），须映射到 5——原实现重置为 2（±2.048V）换算错 8 倍
    local pga_idx = tonum(data.pga, bitc.band(bitc.rshift(config, 9), 0x07))
    if pga_idx > 5 then pga_idx = 5 end
    if pga_idx < 0 then pga_idx = 2 end
    local fs = pga_fs[pga_idx + 1]
    local raw = raw12_of(raw16)
    local voltage = raw * fs / 2048.0

    return {
        result = "OK",
        raw = raw,
        voltage = voltage
    }
end

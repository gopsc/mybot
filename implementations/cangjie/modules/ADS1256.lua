-- ADS1256 模数转换器 驱动模块（SPI，24 位，8 通道单端 / 4 路差分）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（.mt 脚本）：
--   @SPI
--   name       path            spi_mode  bits  speed      delay;
--   spi-0      /dev/spidev0.0      1        8   1920000      0;
--   @
--   @ADS1256
--   name       SPI    drate  pga   channel;
--   ads1256-0  spi-0    -      -      0;
--   @
-- drate: 0~14（默认 5 = 1000SPS）；pga: 0~6 对应 ×1/×2/×4/×8/×16/×32/×64（默认 0 = ×1）
--
-- call 参数（来自 @Action 或直接 play）：
--   channel: 0~7 单端读取（相对 AINCOM）
--   pos/neg: 差分读取（0~7）
--
-- 依赖 r.cj 注册的 spi_write3 / spi_read_multi（单次传输多字节，CS 保持低）
-- NOTE: ADS1256 要求 SPI Mode 1（CPOL=0, CPHA=1），请在 @SPI 块中配置

-- ==================== 寄存器 ====================
-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
-- 调试打印辅助 print_table（modules/lib/）
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 本设备的 SPI 传输封装：统一附带 @SPI 矩阵配置的 delay
-- （delay 由 SPI.lua 的 call() 随 fd 返回，经元数据引用流入 data.delay）
local dev_delay = 0
local function spi_w(fd, v)        return spi_write(fd, v, dev_delay) end
local function spi_w3(fd, a, b, c) return spi_write3(fd, a, b, c, dev_delay) end
local function spi_rm(fd, n)       return spi_read_multi(fd, n, dev_delay) end

local REG_STATUS = 0x00
local REG_MUX    = 0x01
local REG_ADCON  = 0x02
local REG_DRATE  = 0x03

-- ==================== 命令 ====================
local CMD_WAKEUP  = 0x00   -- 退出待机
local CMD_RDATA   = 0x01   -- 读数据（单次）
local CMD_RDATAC  = 0x03   -- 连续读数据
local CMD_SDATAC  = 0x0F   -- 停止连续读
local CMD_RREG    = 0x10   -- 读寄存器（| 寄存器地址）
local CMD_WREG    = 0x50   -- 写寄存器（| 寄存器地址）
local CMD_SELFCAL = 0xF0   -- 自校准
local CMD_SYNC    = 0xFC   -- 同步
local CMD_RESET   = 0xFE   -- 复位

-- ==================== 数据速率表 ====================
-- [序号] = { 寄存器值, SPS }
local drate_tab = {
    { 0xF0, 30000 }, { 0xE0, 15000 }, { 0xD0, 7500 },  { 0xC0, 3750 },
    { 0xB0, 2000 },  { 0xA0, 1000 },  { 0x90, 500 },   { 0x80, 100 },
    { 0x70, 60 },    { 0x60, 50 },    { 0x50, 30 },    { 0x40, 25 },
    { 0x30, 15 },    { 0x20, 10 },    { 0x10, 5 }
}

-- ==================== PGA 增益（ADCON 低 3 位）====================
local pga_gain = { 1, 2, 4, 8, 16, 32, 64 }

-- 参考电压（V）
local VREF = 2.5

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- 辅助：把数据里的字段转成数字（字符串/数字均可），nil 返回默认值
local function tonum(v, default)
    if v == nil then return default end
    return tonumber(v) or default
end

-- 辅助：写寄存器（WREG：命令 + 计数字节 + 数据，一次传输）
local function write_reg(fd, reg, val)
    return spi_w3(fd, bitc.bor(CMD_WREG, reg), 0x00, val)
end

-- 【配置脚本】初始化 ADS1256
function build(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    if DEBUG then
        dbg_table("-------- ADS1256 builder func get a table --------", data)
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Argument: fd" }
    end
    fd = tonumber(fd)

    -- 可配置项（缺省：1000SPS / PGA ×1 / AIN0 单端）
    dev_delay = tonum(data.delay, dev_delay)
    local drate_idx = tonum(data.drate, 5)
    local pga_idx   = tonum(data.pga, 0)
    local channel   = tonum(data.channel, 0)
    if drate_idx < 0 or drate_idx > 14 then drate_idx = 5 end
    if pga_idx < 0 or pga_idx > 6 then pga_idx = 0 end
    if channel < 0 or channel > 7 then channel = 0 end

    -- 1. 复位并唤醒
    if spi_w(fd, CMD_RESET) ~= 0 then
        return { result = "ERR", message = "Failed to reset ADS1256" }
    end
    milli_sleep(5)
    if spi_w(fd, CMD_WAKEUP) ~= 0 then
        return { result = "ERR", message = "Failed to wake ADS1256" }
    end
    milli_sleep(5)

    -- 2. STATUS：BIT5 ORDER=0（MSB 优先），BIT4 ACAL=1（自动校准），其余 0
    if write_reg(fd, REG_STATUS, 0x14) ~= 0 then
        return { result = "ERR", message = "Failed to write STATUS" }
    end

    -- 3. MUX：默认 AIN0 + AINCOM（单端）
    if write_reg(fd, REG_MUX, bitc.bor(bitc.lshift(channel, 4), 0x08)) ~= 0 then
        return { result = "ERR", message = "Failed to write MUX" }
    end

    -- 4. ADCON：PGA 增益
    if write_reg(fd, REG_ADCON, pga_idx) ~= 0 then
        return { result = "ERR", message = "Failed to write ADCON" }
    end

    -- 5. DRATE：数据速率
    if write_reg(fd, REG_DRATE, drate_tab[drate_idx + 1][1]) ~= 0 then
        return { result = "ERR", message = "Failed to write DRATE" }
    end

    -- 6. 自校准（约 2 个转换周期，保守等待）
    if spi_w(fd, CMD_SELFCAL) ~= 0 then
        return { result = "ERR", message = "Failed to start self-calibration" }
    end
    milli_sleep(50)

    -- 7. 进入连续读模式
    if spi_w(fd, CMD_RDATAC) ~= 0 then
        return { result = "ERR", message = "Failed to enter continuous read mode" }
    end

    print(string.format("ADS1256 init OK: drate=%d SPS, PGA=×%d, channel=AIN%d",
        drate_tab[drate_idx + 1][2], pga_gain[pga_idx + 1], channel))
    return { result = "OK" }
end

-- 【销毁脚本】停止连续读
function destroy(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Arguments: fd" }
    end

    if spi_w(tonumber(fd), CMD_SDATAC) ~= 0 then
        return { result = "ERR", message = "Failed to stop continuous read mode" }
    end
    return { result = "OK" }
end

-- 【调用脚本】读取一个通道的电压
-- 参数：channel（0~7 单端）或 pos/neg（差分）
function call(data)
    local ok, ek = arg_table(data)
    if not ok then
    	return ek
    end

    if DEBUG then
        dbg_table("-------- ADS1256 caller func get a table --------", data)
    end

    local fd = data.fd
    if fd == nil then
        return { result = "ERR", message = "Invalid Argument: fd" }
    end
    fd = tonumber(fd)

    -- 差分 / 单端模式选择
    local mux
    if data.pos ~= nil and data.neg ~= nil then
        -- 先判 tonumber 结果：占位符 "-" 或非法串转出 nil，直接比较会触发
        -- 裸 Lua error（被宿主 pcall 吞成通用错误），应按契约返回 ERR
        local pos, neg = tonumber(data.pos), tonumber(data.neg)
        if pos == nil or neg == nil then
            return { result = "ERR", message = "Invalid diff channel: pos/neg not a number" }
        end
        if pos < 0 or pos > 7 or neg < 0 or neg > 7 then
            return { result = "ERR", message = "Invalid diff channel: 0~7" }
        end
        mux = bitc.bor(bitc.lshift(pos, 4), neg)
    else
        local channel = tonum(data.channel, 0)
        if channel < 0 or channel > 7 then
            return { result = "ERR", message = "Invalid channel: 0~7" }
        end
        mux = bitc.bor(bitc.lshift(channel, 4), 0x08)    -- AINch vs AINCOM
    end

    -- 退出连续模式 → 改通道 → 同步重启转换 → 回到连续模式
    if spi_w(fd, CMD_SDATAC) ~= 0 then
        return { result = "ERR", message = "Failed to stop continuous read mode" }
    end
    if write_reg(fd, REG_MUX, mux) ~= 0 then
        spi_w(fd, CMD_RDATAC)
        return { result = "ERR", message = "Failed to write MUX" }
    end
    if spi_w(fd, CMD_SYNC) ~= 0 then
        spi_w(fd, CMD_RDATAC)
        return { result = "ERR", message = "Failed to sync ADS1256" }
    end
    milli_sleep(1)
    if spi_w(fd, CMD_WAKEUP) ~= 0 then
        spi_w(fd, CMD_RDATAC)
        return { result = "ERR", message = "Failed to wake ADS1256" }
    end
    if spi_w(fd, CMD_RDATAC) ~= 0 then
        return { result = "ERR", message = "Failed to enter continuous read mode" }
    end

    -- 等待一个完整转换周期（按 drate 估算，最少 1ms）
    dev_delay = tonum(data.delay, dev_delay)
    local drate_idx = tonum(data.drate, 5)
    if drate_idx < 0 or drate_idx > 14 then drate_idx = 5 end
    local sps = drate_tab[drate_idx + 1][2]
    local wait_ms = math.ceil(1000 / sps) + 1
    milli_sleep(wait_ms)

    -- 读 24 位数据（RDATAC 连续模式：CS 拉低即输出最新样本，无需命令）
    -- 一次读 4 字节，前 3 字节是当前样本（第 4 字节是下一个样本的高字节，丢弃）
    local v = spi_rm(fd, 4)
    if v < 0 then
        return { result = "ERR", message = "Failed to read data" }
    end

    local raw24 = bitc.band(bitc.rshift(v, 8), 0xFFFFFF)   -- 取前 3 字节
    if raw24 >= 0x800000 then raw24 = raw24 - 0x1000000 end  -- 24 位符号扩展

    local pga_idx = tonum(data.pga, 0)
    if pga_idx < 0 or pga_idx > 6 then pga_idx = 0 end
    local gain = pga_gain[pga_idx + 1]
    -- 满量程差分输入 = ±2·VREF/PGA（datasheet：0x7FFFFF 对应 +2·VREF/PGA，
    -- VREF=2.5V、PGA=1 时即 ±5V）——分子须乘 2，否则读数系统性低一半
    local voltage = raw24 * 2 * VREF / 8388608.0 / gain

    return {
        result = "OK",
        raw = raw24,
        voltage = voltage
    }
end

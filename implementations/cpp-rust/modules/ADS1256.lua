-- ADS1256 模数转换器 驱动模块（SPI，24 位，8 通道单端 / 4 路差分）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 ADS1256_VIRT（2026-09-15 自 modules/lib/virtbus/ads1256.lua
-- 迁入，单文件驱动+模型实验第五个，SPI 族样板；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + fd 校验 + destroy 空操作
-- 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍在文件尾部。
-- 1 行 prelude 加载 drv_common（自带 require_driver 定义）；HAL/print_table
-- 由 require_driver 内部代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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
-- 数值列 -> tonumber 结果，非法回落缺省（实现收敛至 drv_common.num_or，N-24）
local tonum = num_or

-- 辅助：写寄存器（WREG：命令 + 计数字节 + 数据，一次传输）
local function write_reg(fd, reg, val)
    return spi_w3(fd, bitc.bor(CMD_WREG, reg), 0x00, val)
end

require_driver("spi", {
	name = "ADS1256",

	-- 【配置脚本】初始化 ADS1256
	build = function(ctx, data)
	    if DEBUG then
	        dbg_table("-------- ADS1256 builder func get a table --------", data)
	    end

	    local fd = ctx.fd

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
	        return err("Failed to reset ADS1256")
	    end
	    milli_sleep(5)
	    if spi_w(fd, CMD_WAKEUP) ~= 0 then
	        return err("Failed to wake ADS1256")
	    end
	    milli_sleep(5)

	    -- 2. STATUS
	    if write_reg(fd, REG_STATUS, 0x14) ~= 0 then
	        return err("Failed to write STATUS")
	    end

	    -- 3. MUX
	    if write_reg(fd, REG_MUX, bitc.bor(bitc.lshift(channel, 4), 0x08)) ~= 0 then
	        return err("Failed to write MUX")
	    end

	    -- 4. ADCON
	    if write_reg(fd, REG_ADCON, pga_idx) ~= 0 then
	        return err("Failed to write ADCON")
	    end

	    -- 5. DRATE
	    if write_reg(fd, REG_DRATE, drate_tab[drate_idx + 1][1]) ~= 0 then
	        return err("Failed to write DRATE")
	    end

	    -- 6. 自校准
	    if spi_w(fd, CMD_SELFCAL) ~= 0 then
	        return err("Failed to start self-calibration")
	    end
	    milli_sleep(50)

	    -- 7. 进入连续读模式
	    if spi_w(fd, CMD_RDATAC) ~= 0 then
	        return err("Failed to enter continuous read mode")
	    end

	    print(string.format("ADS1256 init OK: drate=%d SPS, PGA=×%d, channel=AIN%d",
	        drate_tab[drate_idx + 1][2], pga_gain[pga_idx + 1], channel))
	    return { result = "OK" }
	end,

	-- 【销毁脚本】停止连续读（非空：发 SDATAC 命令）
	destroy = function(ctx, data)
	    local fd = data.fd
	    if fd == nil then
	        return err("Invalid Argument: fd")
	    end

	    if spi_w(tonumber(fd), CMD_SDATAC) ~= 0 then
	        return err("Failed to stop continuous read mode")
	    end
	    return { result = "OK" }
	end,

	-- 【调用脚本】读取一个通道的电压
	call = function(ctx, data)
	    if DEBUG then
	        dbg_table("-------- ADS1256 caller func get a table --------", data)
	    end

	    local fd = ctx.fd

	    -- 差分 / 单端模式选择
	    local mux
	    if data.pos ~= nil and data.neg ~= nil then
	        -- 26.3：本文件唯一没走归一化器的数值列（delay/drate/pga/channel 全经
	        -- 上面 `local tonum = num_or`）。判据取「拒绝」而非「归缺省」——与紧邻
	        -- 下方既有的 pos/neg 非数值处理同结论：差分通道对选错是测到另一对通道，
	        -- 静默归 0 比报错更坏。finite_of 让 'nan' 落到既有的那条 ERR 上，而不是
	        -- 穿过 `pos < 0 or pos > 7`（对 NaN 恒假）一路走到 bitc.lshift 抛
	        -- bitcompat 内部文案。
	        local pos, neg = finite_of(data.pos), finite_of(data.neg)
	        if pos == nil or neg == nil then
	            return err("Invalid diff channel: pos/neg not a number")
	        end
	        if pos < 0 or pos > 7 or neg < 0 or neg > 7 then
	            return err("Invalid diff channel: 0~7")
	        end
	        mux = bitc.bor(bitc.lshift(pos, 4), neg)
	    else
	        local channel = tonum(data.channel, 0)
	        if channel < 0 or channel > 7 then
	            return err("Invalid channel: 0~7")
	        end
	        mux = bitc.bor(bitc.lshift(channel, 4), 0x08)
	    end

	    -- 退出连续模式 → 改通道 → 同步重启转换 → 回到连续模式
	    if spi_w(fd, CMD_SDATAC) ~= 0 then
	        return err("Failed to stop continuous read mode")
	    end
	    if write_reg(fd, REG_MUX, mux) ~= 0 then
	        spi_w(fd, CMD_RDATAC)
	        return err("Failed to write MUX")
	    end
	    if spi_w(fd, CMD_SYNC) ~= 0 then
	        spi_w(fd, CMD_RDATAC)
	        return err("Failed to sync ADS1256")
	    end
	    milli_sleep(1)
	    if spi_w(fd, CMD_WAKEUP) ~= 0 then
	        spi_w(fd, CMD_RDATAC)
	        return err("Failed to wake ADS1256")
	    end
	    if spi_w(fd, CMD_RDATAC) ~= 0 then
	        return err("Failed to enter continuous read mode")
	    end

	    -- 等待一个完整转换周期
	    dev_delay = tonum(data.delay, dev_delay)
	    local drate_idx = tonum(data.drate, 5)
	    if drate_idx < 0 or drate_idx > 14 then drate_idx = 5 end
	    local sps = drate_tab[drate_idx + 1][2]
	    local wait_ms = math.ceil(1000 / sps) + 1
	    milli_sleep(wait_ms)

	    -- 读 24 位数据
	    local v = spi_rm(fd, 4)
	    if v < 0 then
	        return err("Failed to read data")
	    end

	    local raw24 = bitc.band(bitc.rshift(v, 8), 0xFFFFFF)
	    if raw24 >= 0x800000 then raw24 = raw24 - 0x1000000 end

	    local pga_idx = tonum(data.pga, 0)
	    if pga_idx < 0 or pga_idx > 6 then pga_idx = 0 end
	    local gain = pga_gain[pga_idx + 1]
	    local voltage = raw24 * 2 * VREF / 8388608.0 / gain

	    return {
	        result = "OK",
	        raw = raw24,
	        voltage = voltage
	    }
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】ADS1256_VIRT —— 2026-09-15 自 modules/lib/virtbus/ads1256.lua
-- 整体迁入（单文件驱动+模型第五个，SPI 族样板，守护 E2E 走 sensor_daemon
-- 回退路径）。约定同前四者：① 生产路径零执行（new() 仅虚拟总线测试调用，
-- 命令/寄存器/位运算均移入 new() 内——避免与上方驱动同名局部量遮蔽，bitcompat
-- 经本文件 mpath 上值独立 dofile、失败退化纯算术，不共用驱动的 bitc 以保
-- 互证独立性）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。工厂表带 BUS="spi"：
-- sensor_daemon proto=virt 据此走 attach_spi/spidev 路径。
--
-- 对应真实驱动 modules/ADS1256.lua（SPI Mode 1）。协议只建模到驱动实际用到
-- 的事实层：命令字节、WREG/RREG 寄存器访问、RDATAC 连续读模式下的 24bit 样本
-- 帧；电压换算（raw*2*VREF/2^23/PGA）只存在于真实驱动，本模型给有符号原始码。
--
-- 挂载（SPI 路径即片选身份）：
--   vbus.load_driver("modules/ADS1256.lua")  -- 定义全局 build/call/destroy 与 ADS1256_VIRT
--   local dev = ADS1256_VIRT.new()
--   vbus.attach_spi("ADS1256", "/dev/spidev0.0", dev)
--
-- 驱动事务形态（一次 HAL 传输 = 一个 CS 帧，全双工）：
--   build: [FE]RESET [00]WAKEUP [50 00 14]WREG STATUS [51 00 mux]WREG MUX
--          [52 00 pga]WREG ADCON [53 00 drate]WREG DRATE [F0]SELFCAL [03]RDATAC
--   call : [0F]SDATAC [51 00 mux]WREG MUX [FC]SYNC [00]WAKEUP [03]RDATAC
--          然后一帧 4 个 dummy 字节，MISO 前 3 字节为 24bit 样本（MSB 优先），
--          第 4 字节被驱动丢弃（rshift 8）；destroy: [0F]SDATAC
--
-- 模型不模拟 DRDY 引脚时序（驱动只按 drate sleep，不轮询引脚），样本在 RDATAC
-- 模式下随时可读；milli_sleep 由测试桩累计推进，无需虚拟时钟参与读就绪。
-- =====================================================================

ADS1256_VIRT = { _VERSION = "0.1.0", BUS = "spi" }

function ADS1256_VIRT.new(opts)
	local unpack = table.unpack or unpack	-- LuaJIT 全局 / Lua5.4 table.unpack

	-- 位运算：独立 dofile bitcompat（不经驱动的 bitc 局部量，保互证独立）；
	-- 失败退化为纯算术兜底（必须 Lua 5.1 语法，不能写 &/|/<<——LuaJIT 解析期
	-- 即报错，即使分支不执行）。
	local band, bor, lshift, rshift
	local ok_bc, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
	if ok_bc then
		band, bor, lshift, rshift = bc.band, bc.bor, bc.lshift, bc.rshift
	end
	if not band then
		local function b_and(a, b)
			local r, p = 0, 1
			while a > 0 and b > 0 do
				if a % 2 == 1 and b % 2 == 1 then r = r + p end
				a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
			end
			return r
		end
		local function b_or(a, b)
			local r, p = 0, 1
			while a > 0 or b > 0 do
				if a % 2 == 1 or b % 2 == 1 then r = r + p end
				a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
			end
			return r
		end
		band = b_and
		bor = b_or
		lshift = function(a, n) return a * 2 ^ n end
		rshift = function(a, n) return math.floor(a / 2 ^ n) end
	end

	-- ==================== 命令 / 寄存器（与驱动一致）====================
	local CMD_WAKEUP  = 0x00
	local CMD_RDATA   = 0x01
	local CMD_RDATAC  = 0x03
	local CMD_SDATAC  = 0x0F
	local CMD_RREG    = 0x10
	local CMD_WREG    = 0x50
	local CMD_SELFCAL = 0xF0
	local CMD_SYNC    = 0xFC
	local CMD_RESET   = 0xFE

	local REG_STATUS, REG_MUX, REG_ADCON, REG_DRATE = 0x00, 0x01, 0x02, 0x03

	-- DRATE 寄存器值 → SPS（与驱动 drate_tab 同一张表；模型据此回读速率）
	local DRATE_SPS = {
		[0xF0] = 30000, [0xE0] = 15000, [0xD0] = 7500,  [0xC0] = 3750,
		[0xB0] = 2000,  [0xA0] = 1000,  [0x90] = 500,   [0x80] = 100,
		[0x70] = 60,    [0x60] = 50,    [0x50] = 30,    [0x40] = 25,
		[0x30] = 15,    [0x20] = 10,    [0x10] = 5,
	}
	local PGA_GAIN = { 1, 2, 4, 8, 16, 32, 64 }
	local VREF = 2.5	-- 仅 set_voltage 便捷 API 用，常量必须与驱动一致

	local RAW_MIN, RAW_MAX = -0x800000, 0x7FFFFF

	local self = {}

	-- ---- 器件状态 ----
	-- 寄存器初值：驱动不读 STATUS，MUX/ADCON/DRATE 在 build 必写；
	-- 这里只给自洽的复位级初值（不声称是未经驱动验证的硬件事实）。
	local regs = { [0] = 0x01, [1] = 0x01, [2] = 0x00, [3] = 0x00 }
	local datac = false		-- RDATAC 连续读模式
	local raw_u = 0			-- 当前样本（24bit 无符号）
	local clock_ms = 0		-- 虚拟时钟（milli_sleep 桩经 advance 推进）
	local cmds = {}			-- 解析出的命令流水：{name=, bytes=}
	local reg_writes = {}	-- WREG 流水：{reg=, val=}
	local pending_rreg = nil -- RREG 命令后待回填的 {next_reg=, left=}
	local pending_rdata = false -- RDATA 单次模式下一帧 dummy 出数

	-- 故障注入
	local fail_pred = nil	-- function(tx) → true 则本帧传输失败（返 nil）
	local data_fail = false -- 下一帧/持续的数据帧失败

	-- ===================== 样本注入 API =====================

	-- 注入有符号 24bit 原始码（量化为整数并 clamp 到 -2^23..2^23-1）。
	-- 主测试输入用这个；必须 floor，否则 set_voltage 反解的浮点码会让
	-- virt_tick 周期点（如 sin(2π)≈-2e-16 的尾巴）读不回同一整数。
	function self:set_raw(v)
		v = math.floor(tonumber(v) or 0)
		if v < RAW_MIN then v = RAW_MIN elseif v > RAW_MAX then v = RAW_MAX end
		raw_u = (v < 0) and (v + 0x1000000) or v
		return self
	end

	-- 读回当前有符号原始码
	function self:raw()
		return raw_u >= 0x800000 and raw_u - 0x1000000 or raw_u
	end

	-- 便捷 API（守护/E2E 造样本）：按物理电压反推原始码。
	-- 驱动换算 voltage = raw * 2 * VREF / 2^23 / gain，反解之。
	-- pga_idx 与驱动 pga 参数同义（0~6）；默认 ×1。
	function self:set_voltage(v, pga_idx)
		v = tonumber(v) or 0
		local gain = PGA_GAIN[(tonumber(pga_idx) or 0) + 1] or 1
		self:set_raw(v * 0x800000 / (2 * VREF) * gain)
		return self
	end

	-- ===================== 状态/留痕 API =====================

	function self:advance(ms)
		clock_ms = clock_ms + (tonumber(ms) or 0)
		return self
	end
	function self:clock() return clock_ms end
	function self:in_datac() return datac end

	-- 当前配置（寄存器解码）
	function self:config()
		local mux = regs[REG_MUX]
		return {
			status = regs[REG_STATUS],
			mux = mux,
			adcon = regs[REG_ADCON],
			drate = regs[REG_DRATE],
			sps = DRATE_SPS[band(regs[REG_DRATE], 0xF0)],
			pga_idx = band(regs[REG_ADCON], 0x07),
			gain = PGA_GAIN[band(regs[REG_ADCON], 0x07) + 1],
			-- MUX：低 4 位 0x08=AINCOM 表示单端；否则差分 (pos,neg)
			single = band(mux, 0x0F) == 0x08,
			channel = rshift(mux, 4),
			pos = rshift(mux, 4),
			neg = band(mux, 0x0F),
		}
	end

	function self:cmd_log() return cmds end
	function self:reg_writes() return reg_writes end
	function self:reset_logs()
		cmds, reg_writes = {}, {}
		return self
	end

	-- 状态机复位（等价硬件 RESET 命令，也供测试 section 重置）。
	-- 注意：不清 fail_pred/data_fail——故障注入是测试侧钩子，硬件 RESET
	-- 语义上也不可能「修复」总线故障；若让 RESET 清钩子，build 失败路径
	-- 里第一帧 RESET 会把后续命令的故障条件一并解除，负路径全假绿。
	function self:reset()
		regs = { [0] = 0x01, [1] = 0x01, [2] = 0x00, [3] = 0x00 }
		datac = false
		pending_rreg, pending_rdata = nil, false
		raw_u = 0
		clock_ms = 0
		cmds, reg_writes = {}, {}
		return self
	end

	-- ---- 故障注入钩子 ----
	-- pred(tx 字节表) 返回 true 的帧一律传输失败（xfer 返 nil，HAL 传输族返 -1）
	function self:fail_when(pred) fail_pred = pred; return self end
	function self:fail_data(on) data_fail = (on ~= false); return self end
	function self:clear_fail() fail_pred, data_fail = nil, false; return self end

	-- ===================== 全双工帧核心 =====================

	-- 组装一帧样本：[MSB, mid, LSB, 丢弃字节]；驱动只读前 3 字节，第 4 给 0。
	local function sample_frame(n)
		local t = {
			band(rshift(raw_u, 16), 0xFF),
			band(rshift(raw_u, 8), 0xFF),
			band(raw_u, 0xFF),
		}
		while #t < n do t[#t + 1] = 0 end
		return t
	end

	-- xfer(tx)：点定义、无 self 参数（virtbus attach 动态委托契约）。
	-- 逐字节状态机解析一帧内可能合并的多字节命令（WREG/RREG 为 2+ 字节）。
	local function xfer(tx)
		if type(fail_pred) == "function" and fail_pred(tx) then return nil end
		local n = #tx
		local rx = {}
		for i = 1, n do rx[i] = 0 end

		-- RDATAC 数据帧：模式内整帧 dummy（MOSI 全 0，真机 tx_buf=NULL/读命令流）
		-- 且长度 ≥3（WAKEUP 单字节 0x00 不会出现在 datac 内，长度也不同）。
		if datac then
			local allzero = true
			for i = 1, n do if tx[i] ~= 0 then allzero = false break end end
			if allzero and n >= 3 then
				if data_fail then return nil end
				return sample_frame(n)
			end
		end

		local i = 1
		while i <= n do
			local b = tx[i]
			-- pending 的 RREG/RDATA 读窗口优先：窗口内 MOSI 是 dummy（任意值，
			-- 0x00 也不能再当 WAKEUP 解释），MISO 回填寄存器/样本。
			-- 真实芯片 RREG 命令帧后隔 t6 才进入读窗口，模型把「命令之后的
			-- 后续 dummy 字节」当作窗口（驱动当前不用 RREG，时序近似无害）。
			if pending_rreg ~= nil and pending_rreg.left > 0 then
				rx[i] = regs[pending_rreg.next_reg] or 0
				pending_rreg.next_reg = pending_rreg.next_reg + 1
				pending_rreg.left = pending_rreg.left - 1
				if pending_rreg.left == 0 then pending_rreg = nil end
				i = i + 1
			elseif pending_rdata then
				local f = sample_frame(n - i + 1)
				for k = 1, #f do rx[i + k - 1] = f[k] end
				pending_rdata = false
				break
			elseif b == CMD_RESET then
				self.reset()
				-- reset 已清 cmds；本命令自身重新记一条
				cmds[#cmds + 1] = { name = "RESET", bytes = { b } }
				rx[i] = 0xFF
				i = i + 1
			elseif b == CMD_WAKEUP then
				cmds[#cmds + 1] = { name = "WAKEUP", bytes = { b } }; i = i + 1
			elseif b == CMD_RDATAC then
				datac = true
				cmds[#cmds + 1] = { name = "RDATAC", bytes = { b } }; i = i + 1
			elseif b == CMD_SDATAC then
				datac = false
				cmds[#cmds + 1] = { name = "SDATAC", bytes = { b } }; i = i + 1
			elseif b == CMD_SYNC then
				cmds[#cmds + 1] = { name = "SYNC", bytes = { b } }; i = i + 1
			elseif b == CMD_SELFCAL then
				cmds[#cmds + 1] = { name = "SELFCAL", bytes = { b } }; i = i + 1
			elseif b == CMD_RDATA then
				pending_rdata = true
				cmds[#cmds + 1] = { name = "RDATA", bytes = { b } }; i = i + 1
			elseif band(b, 0xF0) == CMD_WREG then
				-- WREG：[0x50|reg, count, data1..]（驱动恒 count=0 单寄存器，
				-- 一次 write3 一帧发完；模型仍按 count 支持多寄存器）
				local reg = band(b, 0x0F)
				local cnt = tx[i + 1] or 0
				local how = 2 + cnt + 1
				for k = 1, cnt + 1 do
					local val = tx[i + 1 + k]
					if val ~= nil then
						regs[reg + k - 1] = val
						reg_writes[#reg_writes + 1] = { reg = reg + k - 1, val = val }
					end
				end
				cmds[#cmds + 1] = {
					name = "WREG", bytes = { unpack(tx, i, math.min(i + how - 1, n)) },
				}
				i = i + how
			elseif band(b, 0xF0) == CMD_RREG then
				-- RREG：[0x10|reg, count]，随后 dummy 读帧回填寄存器值。
				-- 真实硬件命令帧与数据帧之间隔 t6；模型在「后续 dummy 字节」回填，
				-- 驱动当前不用 RREG（build/call 无寄存器回读），此处仅保证协议完整。
				pending_rreg = { next_reg = band(b, 0x0F), left = (tx[i + 1] or 0) + 1 }
				cmds[#cmds + 1] = { name = "RREG", bytes = { b, tx[i + 1] or 0 } }
				i = i + 2
			else
				-- 未识别命令字节：MISO 保持 0
				i = i + 1
			end
		end
		return rx
	end
	self.xfer = xfer

	-- ===================== 守护节拍（确定性合成波形）====================
	-- 以 PGA=×1（±5V 量程）为基准：中心 1.25V、幅度 1.0V、32 拍周期的正弦，
	-- 确定无随机；守护 build 默认 channel=0/pga=0，与 set_voltage 的 gain 一致。
	-- 无需预武装/就绪态：样本随时可读（驱动只 sleep 不轮询 DRDY）。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local m = n % 32 -- 周期归一拍号
		-- 周期零点特判：sin(2π) 浮点尾巴（≈-2e-16）经 set_raw floor 量化后
		-- 会让第 32 拍与第 0 拍差 1 LSB，破坏「32 拍严格重复」的确定性。
		local s = (m == 0) and 0 or math.sin(2 * math.pi * m / 32)
		local v = 1.25 + 1.0 * s
		self:set_voltage(v, 0)
		return self
	end

	return self
end

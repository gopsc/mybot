-- ADS1115 模数转换器 驱动模块（I2C，16 位，4 通道单端 / 2 路差分）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 ADS1115_VIRT（2026-09-15 自 modules/lib/virtbus/ads1115.lua
-- 迁入，单文件驱动+模型实验第二十三个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

local REG_CONVERSION     = 0x00   -- 转换结果（只读，16 位）
local REG_CONFIG         = 0x01   -- 配置寄存器（读/写，16 位）
local REG_LO_THRESH      = 0x02   -- 低阈值比较
local REG_HI_THRESH      = 0x03   -- 高阈值比较

-- ==================== 配置位 ====================
local OS_START           = 0x8000 -- 单次转换启动位。写 1=启动转换；
                                  -- 读语义：0=正在转换，1=空闲/转换完成（datasheet 9.6.3）
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
local sign16 = bitc.s16

-- 辅助：把数据里的字段转成数字（字符串/数字均可），nil 返回默认值
-- 数值列 -> tonumber 结果，非法回落缺省（实现收敛至 drv_common.num_or，N-24）
local tonum = num_or

require_driver("i2c", {
	name = "ADS1115",

	-- 【配置脚本】初始化 ADS1115
	build = function(ctx, data)
	    if DEBUG then
	        dbg_table("-------- ADS1115 builder func get a table --------", data)
	    end

	    local fd = ctx.fd

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

	    -- 写 16 位配置寄存器（burst 写：reg + 高字节 + 低字节）
	    local hi = math.floor(config / 256) % 256
	    local lo = config % 256
	    local wr = i2c_write_multi(fd, REG_CONFIG, hi, lo)
	    if wr ~= 0 then
	        return err("Failed to write ADS1115 config")
	    end

	    -- 读回比对自检（无 ID 寄存器，兼在位探测与配置确认）。
	    local rd = i2c_read_multi(fd, REG_CONFIG, 2)
	    if rd < 0 then
	        return err("Failed to read back ADS1115 config")
	    end
	    if bitc.band(rd, 0x7FFF) ~= bitc.band(config, 0x7FFF) then
	        return err(string.format("ADS1115 config echo mismatch: got 0x%04X (expect 0x%04X)", rd, config))
	    end

	    print(string.format("ADS1115 init OK: addr=0x%02X, channel=AIN%d, PGA=%s, DR=%s SPS",
	        ctx.addr, channel, pga_names[pga_idx + 1], dr_names[dr_idx + 1]))
	    return { result = "OK" }
	end,

	-- 【销毁脚本】置单次模式进入转换间隙断电态（保留 PGA/DR/MUX 配置）
	destroy = function(ctx, data)
	    local fd = data.fd
	    if fd == nil then
	        return err("Invalid Arguments: fd")
	    end
	    local addr = data.address
	    if addr == nil then
	        return err("Invalid Arguments: addr")
	    end

	    if not i2c_set_addr(tonumber(fd), tonumber(addr)) then
	        return err("Invalid Argument: fd or address (set_addr failed)")
	    end
	    -- 读改写：须清掉读回的 OS 位（空闲恒读 1）——原样写回 OS=1 会误启动一次多余转换
	    local config = i2c_read_multi(tonumber(fd), REG_CONFIG, 2)
	    if config >= 0 then
	        local new_config = bitc.band(bitc.bor(config, MODE_SINGLE), 0x7FFF)
	        i2c_write_multi(tonumber(fd), REG_CONFIG,
	            math.floor(new_config / 256) % 256, new_config % 256)
	    end

	    return { result = "OK" }
	end,

	-- 【调用脚本】读取一个通道的电压
	call = function(ctx, data)
	    if DEBUG then
	        dbg_table("-------- ADS1115 caller func get a table --------", data)
	    end

	    local fd = ctx.fd

	    -- 差分 / 单端模式选择
	    local mux
	    if data.pos ~= nil and data.neg ~= nil then
	        -- 26.3 盘点：**评估后不改**。与 ADS1256 的 pos/neg（那边用 bitc.lshift
	        -- 合成 mux，NaN 会抛 Lua error，已于 26.3 改 finite_of）后果不同：本处
	        -- 把两值拼成字符串查 diff_map，NaN 拼出 "nan,nan"、inf 拼出 "inf,1"
	        -- 之类命中不到任何键（实测不抛，LuaJIT 的数值拼串对非有限值给
	        -- "nan"/"inf"）→ 落到下面那条 ERR，且文案还给出了合法集
	        -- 0-1/0-3/1-3/2-3。已是 fail-closed 且可操作，换判据只会换掉一句
	        -- 更好的错误文案。本文件与 ADS1015 为机械孪生，此注两侧逐字相同。
	        local pos, neg = tonumber(data.pos), tonumber(data.neg)
	        if pos == nil or neg == nil then
	            return err("Invalid diff pair: pos/neg not a number")
	        end
	        local diff_map = { ["0,1"] = MUX_DIFF_AIN0_AIN1, ["0,3"] = MUX_DIFF_AIN0_AIN3,
	                           ["1,3"] = MUX_DIFF_AIN1_AIN3, ["2,3"] = MUX_DIFF_AIN2_AIN3 }
	        mux = diff_map[pos .. "," .. neg]
	        if mux == nil then
	            return err("Unsupported diff pair, use 0-1/0-3/1-3/2-3")
	        end
	    else
	        local channel = tonum(data.channel, 0)
	        if channel < 0 or channel > 3 then
	            return err("Invalid channel: 0~3")
	        end
	        mux = bitc.bor(MUX_SINGLE_AIN0, bitc.lshift(channel, 12))
	    end

	    -- 读回当前配置，保留 PGA/DR，只改 MUX 并启动单次转换
	    local config = i2c_read_multi(fd, REG_CONFIG, 2)
	    if config < 0 then
	        return err("Failed to read config")
	    end
	    local new_config = bitc.bor(bitc.bor(bitc.band(config, 0x8FFF), mux), OS_START)

	    local hi = math.floor(new_config / 256) % 256
	    local lo = new_config % 256
	    if i2c_write_multi(fd, REG_CONFIG, hi, lo) ~= 0 then
	        return err("Failed to start conversion")
	    end

	    -- 轮询 OS 位
	    local ready = false
	    for _ = 1, 200 do
	        local cfg = i2c_read_multi(fd, REG_CONFIG, 2)
	        if cfg >= 0 and bitc.band(cfg, OS_START) ~= 0 then
	            ready = true
	            break
	        end
	        milli_sleep(1)
	    end
	    if not ready then
	        return err("Conversion timeout")
	    end

	    -- 读转换结果（16 位有符号）
	    local raw16 = i2c_read_multi(fd, REG_CONVERSION, 2)
	    if raw16 < 0 then
	        return err("Failed to read conversion")
	    end

	    local pga_idx = tonum(data.pga, bitc.band(bitc.rshift(config, 9), 0x07))
	    if pga_idx > 5 then pga_idx = 5 end
	    if pga_idx < 0 then pga_idx = 2 end
	    local fs = pga_fs[pga_idx + 1]
	    local raw = sign16(raw16)
	    local voltage = raw * fs / 32768.0

	    return {
	        result = "OK",
	        raw = raw,
	        voltage = voltage
	    }
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】ADS1115_VIRT —— 2026-09-15 自 modules/lib/virtbus/ads1115.lua
-- 整体迁入（单文件驱动+模型第二十三个，字寻址 16 位 + oneshot 转换门族，
-- 守护 E2E 走 sensor_daemon 回退路径）。约定同前二十二者：① 生产路径零执行
-- （new() 仅虚拟总线测试调用，自包含字寻址实现；OS/MODE 位/clamp/encode16
-- 移入 new() 内避让；new() 内 `local ads1115 = ADS1115_VIRT` 绑定使模型体
-- 零改动移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 【字寻址 16 位寄存器 + oneshot 转换门/OS 就绪握手器件】（骨架同族 ina219：
-- 寄存器号 0x00~0x03 各代表一个 16 位字，绝不能套字节地址 regmap；但与
-- INA219「连续模式结果恒有值、无转换门」不同，ADS1115 驱动走单次转换）：
--   0x00 CONVERSION  16 位有符号转换结果（16 位直接编码，区别 ADS1015 的
--                    12 位左对齐——本模型不覆盖 ADS1015）
--   0x01 CONFIG      [15]OS [14:12]MUX [11:9]PGA [8]MODE [7:5]DR [4:0]比较器
--   0x02 LO_THRESH / 0x03 HI_THRESH（驱动不用，POR 0x8000/0x7FFF，照读照写）
--
-- OS 位是模型核心（datasheet 9.6.3）：写 1 在单次模式（MODE=1）下=启动一次
-- 转换；读语义与写相反——转换中读 0、空闲/完成读 1。故 OS 位不能静态落盘：
-- shadow 保存驱动写入值，读 CONFIG 时 bit15 按转换状态机【动态合成】。
-- 单次转换时长 = 1/DR（精确 datasheet 周期：8SPS=125ms … 860SPS=1.1628ms），
-- 由 advance(ms) 虚拟时钟推进；转换完成瞬间把当前 MUX 通道的注入码装入
-- CONVERSION。连续模式（MODE=0）OS 位读恒 0、结果立即可用（驱动不用，仅
-- 协议完整性）。
--
-- 守护不驱动虚拟时钟（不注 milli_sleep 桩），靠 virt_tick 的【预武装】：
-- 每拍 virt_tick(n) 注入该拍电压并置 armed——下一次 OS=1 启动写立即完成
-- （首读 OS 即 1、结果已装载），驱动 1ms 轮询零真实睡眠；armed 一次性，
-- 启动写时消费。未武装的测试路径走真实 remaining/advance 节拍。
--
-- 用法：
--   vbus.load_driver("modules/ADS1115.lua")  -- 定义全局 build/call/destroy 与 ADS1115_VIRT
--   local dev = ADS1115_VIRT.new()           -- POR CONFIG 0x8583、阈值 0x8000/0x7FFF
--   dev:set_single(0, 1.5, 2)                -- AIN0 注入 1.5V（PGA=2 即 ±2.048V）
--   vbus.attach("ADS1115@0x48", 0x48, dev)
--
--   dev:set_never_ready(true)  -- 转换卡死，喂驱动 200ms 轮询超时
--   dev.nack_read = true       -- 定向故障
--
-- 【边界约定】模型只固化字寻址布局/位域/OS 读写相反语义/转换周期；
-- V=raw*FS/32768 换算归驱动，物理量注入 API 的 PGA 常量仅造样本，测试另做
-- 独立换算交叉，避免模型与驱动共用一份理解互证假绿。
-- =====================================================================

ADS1115_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		CONVERSION = 0x00,
		CONFIG     = 0x01,
		LO_THRESH  = 0x02,
		HI_THRESH  = 0x03,
	}
}

-- 标量常数（逐条挂工厂表）


ADS1115_VIRT.POR_CONFIG = 0x8583		-- OS=1 MUX=100 PGA=010 MODE=1 DR=100 CQUE=11
ADS1115_VIRT.POR_LO     = 0x8000
ADS1115_VIRT.POR_HI     = 0x7FFF

-- PGA 增益 → 满量程（V）；索引 6/7 为 datasheet 冗余编码，同 5（±0.256V）
ADS1115_VIRT.PGA_FS = { [0] = 6.144, 4.096, 2.048, 1.024, 0.512, 0.256 }
-- 数据速率 SPS
ADS1115_VIRT.DR_SPS = { [0] = 8, 16, 32, 64, 128, 250, 475, 860 }
-- 精确单次转换周期 1000/SPS（独立于驱动 1ms 轮询，别抄驱动预算）
ADS1115_VIRT.CONV_MS = { [0] = 125, [1] = 62.5, [2] = 31.25, [3] = 15.625,
                    [4] = 7.8125, [5] = 4, [6] = 1000/475, [7] = 1000/860 }

function ADS1115_VIRT.new(opts)
	local ads1115 = ADS1115_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	local OS_BIT   = 0x8000
	local MODE_BIT = 0x0100

	local function encode16(raw)
		return clampi(math.floor(raw + 0.5), -32768, 32767) % 65536
	end


	local d = {}
	local regs = {}				-- 字地址（0~3）→ 16 位值
	local ptr = 0				-- 当前寄存器指针（字地址）
	local shadow				-- CONFIG 驱动写入值（含 OS 写位，读时动态合成 bit15）
	local remaining				-- oneshot 转换剩余 ms；nil=空闲
	local active_mux = 4		-- 最近一次启动转换的 MUX（POR MUX=100=AIN0）
	local results = {}			-- mux(0~7) → s16 注入码
	local armed = false			-- 预武装：下次启动立即完成（守护零睡眠）
	local never_ready = false	-- 卡死：转换永不完成（喂轮询超时）
	local start_count = 0
	local write_pred, read_pred
	d.write_log = {}

	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[ads1115.REG.CONVERSION] = 0
		regs[ads1115.REG.LO_THRESH]  = ads1115.POR_LO
		regs[ads1115.REG.HI_THRESH]  = ads1115.POR_HI
		shadow = ads1115.POR_CONFIG
		remaining = nil
		active_mux = 4
		start_count = 0
		armed = false
		ptr = 0
	end
	reseed()

	-- 转换完成：把启动时 MUX 通道的注入码装入 CONVERSION
	local function finish_conv()
		regs[ads1115.REG.CONVERSION] = encode16(results[active_mux] or 0)
		remaining = nil
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- CONFIG 读回字：bit15 按状态动态合成（OS 读写语义相反）
	local function config_read_word()
		local w = shadow % 0x8000			-- 落盘的低 15 位
		if (math.floor(shadow / MODE_BIT) % 2) == 0 then
			return w						-- 连续模式：OS 位读恒 0
		end
		if remaining == nil then return w + OS_BIT end	-- 单次空闲/完成：OS=1
		return w							-- 单次转换中：OS=0
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 恰 1 字节 {reg}=纯指针写；恰 3 字节 {reg,hi,lo}=字写；其余 NACK
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		if p > 0x03 then return false end
		ptr = p
		if #bytes == 1 then return true end

		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p ~= ads1115.REG.CONFIG then
			regs[p] = word
			return true
		end

		-- CONFIG 写：shadow 落全字（含 OS 写位），按 OS/MODE 驱动状态机
		shadow = word
		local os_bit   = word >= OS_BIT
		local single   = (math.floor(word / MODE_BIT) % 2) == 1
		local mux      = math.floor(word / 0x1000) % 8
		local dr       = math.floor(word / 32) % 8
		if single then
			-- 单次模式：OS=0 无作用（不启动）；OS=1 启动一次转换
			if os_bit then
				start_count = start_count + 1
				active_mux = mux
				if armed and not never_ready then
					armed = false			-- 武装一次性消费
					finish_conv()			-- 启动即完成（守护零睡眠）
				else
					remaining = ads1115.CONV_MS[dr]
				end
			end
		else
			-- 连续模式：OS 写位忽略，持续转换，结果立即可用
			active_mux = mux
			finish_conv()
		end
		return true
	end

	-- 读 n 字节：从当前指针字取 hi/lo；n>2 按字自增续读、奇数尾补 0
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		local p = ptr
		for i = 1, n do
			local idx = p + math.floor((i - 1) / 2)
			local word = idx == ads1115.REG.CONFIG and config_read_word()
			        or (regs[idx] or 0)
			out[i] = (i % 2 == 1) and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- 按 MUX 码注入 16 位有符号转换结果：0~3 差分对，4~7 单端 AIN0~3。
	-- 只入注入表——CONVERSION 寄存器仅由「转换完成」事件改变（oneshot
	-- finish_conv / 连续写 CONFIG），空闲注入不得提前出现在结果寄存器。
	function d:set_result(mux, raw)
		results[clampi(math.floor(mux), 0, 7)] =
			clampi(math.floor(raw + 0.5), -32768, 32767)
		return self
	end

	-- ---------------- 物理量造样本（PGA 常量仅造样本，与驱动独立） ----------------

	-- 单端通道 ch(0~3) 注入电压 V，pga 为 PGA 索引（缺省 2=±2.048V）
	function d:set_single(ch, v, pga)
		local fs = ads1115.PGA_FS[clampi(tonumber(pga) or 2, 0, 5)]
		return self:set_result(4 + clampi(math.floor(ch), 0, 3),
		                       math.floor(v * 32768 / fs + 0.5))
	end

	-- 差分注入：mux 0~3（0=AIN0-AIN1,1=AIN0-AIN3,2=AIN1-AIN3,3=AIN2-AIN3）
	function d:set_diff(mux, v, pga)
		local fs = ads1115.PGA_FS[clampi(tonumber(pga) or 2, 0, 5)]
		return self:set_result(clampi(math.floor(mux), 0, 3),
		                       math.floor(v * 32768 / fs + 0.5))
	end

	-- ---------------- 虚拟时钟 / 守护节拍 ----------------

	-- 推进转换时钟 ms（测试 milli_sleep 桩转调；守护不调）
	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil and not never_ready then
			remaining = remaining - ms
			if remaining <= 0 then finish_conv() end
		end
		return self
	end

	-- 32 拍确定性正弦造样本：AIN0 单端 1.65 ± 0.25V（1.40~1.90V，PGA=2
	-- ±2.048V 量程内），同时预武装——守护本拍随后的 call 启动转换首读即就绪，
	-- 1ms 轮询零真实睡眠。无随机，E2E 数值可复现。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local v = 1.65 + 0.25 * math.sin(n * (2 * math.pi / 32))
		self:set_single(0, v, 2)
		armed = true
		return self
	end

	-- ---------------- 故障/留痕/复位 ----------------

	-- 转换卡死：启动后 OS 恒读 0、advance 不推进（喂驱动 200ms 超时），
	-- 且武装无效
	function d:set_never_ready(on) never_ready = on ~= false; return self end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		never_ready = false
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs() self.write_log = {}; return self end

	-- 回 POR 态（保留故障钩子，与全系列约定一致）
	function d:reset()
		reseed()
		self.write_log = {}
		return self
	end

	-- 驱动写过的字写事务（write_log 中恰 3 字节）：{reg,hi,lo,word}
	function d:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e == 3 then
				out[#out + 1] = { reg = e[1], hi = e[2], lo = e[3],
				                  word = e[2] * 256 + e[3] }
			end
		end
		return out
	end

	-- ---------------- 观察口 ----------------

	function d:pointer() return ptr end
	function d:busy() return remaining ~= nil end
	function d:remaining_ms() return remaining end
	function d:start_count() return start_count end
	function d:active_mux() return active_mux end
	function d:armed() return armed end
	function d:config_shadow() return shadow end	-- 驱动写入的原字（含 OS 写位）
	function d:config() return config_read_word() end	-- 读回字（OS 动态合成）
	function d:conversion_raw()
		local v = regs[ads1115.REG.CONVERSION] or 0
		return v >= 0x8000 and v - 0x10000 or v
	end
	function d:lo_thresh() return regs[ads1115.REG.LO_THRESH] end
	function d:hi_thresh() return regs[ads1115.REG.HI_THRESH] end
	-- 注入码反推电压（观察用，pga 缺省回读 shadow 的 PGA 字段，6/7→5）
	function d:voltage(mux, pga)
		local pi = pga or (math.floor(shadow / 512) % 8)
		if pi > 5 then pi = 5 end
		local raw = results[clampi(tonumber(mux) or active_mux, 0, 7)] or 0
		return raw * ads1115.PGA_FS[pi] / 32768
	end

	return d
end

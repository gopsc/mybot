-- modules/lib/virtbus/mcp3421.lua —— MCP3421 18 位 ΔΣ ADC 虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个「单字节配置写 + 数据流纯读、读回帧自带配置回显与就绪位」
-- 的命令式 I2C 器件】——无寄存器指针（区别于 regmap 指针器件），也不是
-- SHT3X 那种 16 位命令字：写恒为 1 字节配置（i2c_write_multi 单字节），
-- 读恒为无指针纯读（i2c_read），且读回帧的【末字节是配置回显】——bit7
-- RDY 兼作数据就绪握手（0=新数据、1=转换中/上一结果已读走），低 6 位
-- O/C+S1S0+G1G0 回显供主设备核对（驱动 build 做在位探测）。
--
-- 只复刻协议层事实（Microchip DS22003E，以真实驱动 modules/MCP3421.lua
-- 实际访问为准）：
--   1) 配置字节位域：[7]RDY（写 1 启动单次转换）[4]O/C（1 连续）
--      [3:2]S1S0 分辨率（0/1/2/3 = 12/14/16/18bit）[1:0]G1G0（PGA
--      ×1/×2/×4/×8）；bit6/5 通道位本芯片恒 0。
--   2) 转换时间（驱动取整门限，1/SPS 向上取整）：12bit 5ms、14bit 17ms、
--      16bit 67ms、18bit 267ms；advance(ms) 推进。写 RDY=1 启动转换，
--      完成前回显 RDY=1；连续模式（O/C=1）读完一帧立即开始下一转换，
--      单次模式读完进低功耗待机（再读 RDY=1）；O/C=0/RDY=0 为待机配置。
--   3) 帧布局：18bit 读 4 字节——D[17:16] 在首字节低 2 位 + 2 数据字节
--      + 回显；12/14/16bit 读 3 字节——16 位字（12/14 位档顶部为重复
--      符号位，按 int16 解释即该分辨率补码）+ 回显。
--   4) 出厂无校准系数：内部基准 2.048V，LSB=2.048/2^(res-1)/pga 是驱动
--      侧换算，模型只按位宽存补码（set_raw 钳制）；set_voltage 物理量
--      API 仅供守护 virt_tick 造样本。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：纯算术无 5.4 位运算符。

local M = {}
M._VERSION = "0.1.0"

local BIT_RDY  = 0x80
local BIT_CONT = 0x10

-- S1S0 编码 → 分辨率/转换门限 ms（驱动取整：4.2/16.7/66.7/266.7 → 5/17/67/267）
local RES_OF_CODE = { [0] = 12, [1] = 14, [2] = 16, [3] = 18 }
local TCONV = { [12] = 5, [14] = 17, [16] = 67, [18] = 267 }
local PGA_OF_CODE = { [0] = 1, [1] = 2, [2] = 4, [3] = 8 }

local DEFAULT_CFG = 0x90	-- 连续/12bit/×1（RDY 位上电不置，build 必重写）

local function clamp(v, lo, hi)
	v = math.floor(tonumber(v) or 0)
	if v < lo then return lo elseif v > hi then return hi else return v end
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local cfg = DEFAULT_CFG
	local code = 0				-- S1S0
	local gain = 1
	local cont = true
	local raw = 0				-- 当前分辨率档的有符号码值
	local remaining = nil		-- 转换剩余 ms（nil=无进行中转换）
	local fresh = false			-- 有未被读走的新结果（回显 RDY=0）
	local writes = {}			-- 配置写字节序列

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_ready = false		-- 转换永不完成（RDY 恒 1，驱动超时路径）
	local echo_bad = false			-- 回显低 6 位翻转（build echo mismatch）

	local function res_bits() return RES_OF_CODE[code] end

	local function start_conversion()
		remaining = TCONV[res_bits()]
		fresh = false
	end

	-- 配置字节生效（返回是否识别；位域全部合法，恒 true，保留扩展）
	local function apply_cfg(b)
		cfg = b
		code = math.floor(b / 4) % 4
		gain = PGA_OF_CODE[b % 4]
		cont = math.floor(b / 16) % 2 == 1
		local rdy = math.floor(b / 128) % 2 == 1
		if rdy then
			-- RDY=1：无论连续/单次都（重新）启动一次转换，计时按新档位
			start_conversion()
		elseif cont then
			-- 连续配置但未带触发位：空闲则启动，进行中不打断（速率已更新，
			-- 驱动从不发此组合，仅模型自洽）
			if remaining == nil then start_conversion() end
		else
			-- O/C=0/RDY=0：当前转换完成后进待机（destroy 路径立即空闲）
			remaining, fresh = nil, false
		end
		return true
	end

	-- 有符号码值 → 该分辨率档的数据字节（不含回显）
	local function encode()
		local bits = res_bits()
		if bits == 18 then
			local u = raw % 0x40000			-- 18 位补码无符号
			return { math.floor(u / 65536) % 4, math.floor(u / 256) % 256, u % 256 }
		end
		local u, w
		if bits == 16 then
			u = raw % 0x10000
			w = u
		elseif bits == 14 then
			u = raw % 0x4000
			-- 顶部 2 位重复符号位（datasheet 14bit 输出格式）
			w = (u >= 0x2000) and (u + 0xC000) or u
		else
			u = raw % 0x1000
			-- 顶部 4 位重复符号位（datasheet 12bit 输出格式）
			w = (u >= 0x800) and (u + 0xF000) or u
		end
		return { math.floor(w / 256) % 256, w % 256 }
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		-- MCP3421 写恒为 1 字节配置；多字节帧器件不认
		if #bytes ~= 1 then return false end
		local b = bytes[1]
		if write_pred and write_pred(b) then return false end
		writes[#writes + 1] = b
		apply_cfg(b)
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(n, fresh) then return nil end
		n = math.floor(tonumber(n) or 0)
		if n < 1 then return nil end
		-- 转换到点（advance 推进；never_ready 钩子下永不置 fresh）
		-- fresh 由 advance/virt_tick 设置；此处只组帧
		local echo
		if fresh and not never_ready then
			echo = cfg % 128					-- RDY=0：新数据就绪
		else
			echo = cfg						-- RDY=1：转换中/已读走
		end
		if echo_bad then echo = (echo % 64 + 1) % 64 + (echo - echo % 64) end
		local frame = encode()
		frame[#frame + 1] = echo
		-- 读走一帧新数据：连续模式立即排下一转换；单次模式进待机
		if fresh and not never_ready then
			if cont then
				start_conversion()
			else
				remaining, fresh = nil, false
			end
		end
		-- 主设备决定读长度（真机为字节流）：按请求截取，不足补 0
		local out = {}
		for i = 1, n do out[i] = frame[i] or 0 end
		return out
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then
				remaining = nil
				if not never_ready then fresh = true end
			end
		end
		return self
	end

	-- 注入有符号码值（按当前分辨率位宽钳制；换算公式归驱动，模型不抄）
	function d:set_raw(v)
		local bits = res_bits()
		raw = clamp(v, -2 ^ (bits - 1), 2 ^ (bits - 1) - 1)
		return self
	end

	-- 物理量注入（仅供守护/E2E；LSB 常量与驱动同源，随配置档位变化）
	function d:set_voltage(volt)
		local lsb = 2.048 / 2 ^ (res_bits() - 1) / gain
		raw = clamp(math.floor(volt / lsb + 0.5),
			-2 ^ (res_bits() - 1), 2 ^ (res_bits() - 1) - 1)
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:set_never_ready(on) never_ready = on ~= false; return self end
	function d:corrupt_echo(on) echo_bad = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_ready, echo_bad = false, false
		return self
	end

	function d:reset_logs() writes = {}; return self end

	-- 上电复位：配置/结果回默认；故障钩子保留（防负路径假解除）
	function d:reset()
		cfg = DEFAULT_CFG
		code, gain, cont = 0, 1, true
		raw = 0
		remaining, fresh = nil, false
		writes = {}
		return self
	end

	-- 守护逐拍造数：确定性电压正弦（±1.5V，内部基准 ±2.048V 量程内，
	-- 各档位/增益下 set_voltage 自行钳制），32 拍周期；并预武装——
	-- 守护不驱动 advance，连续模式 call 首读必须直接 RDY=0（interval
	-- 取 ≥ 转换周期即可，模型不依赖真实 milli_sleep 推进）。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_voltage(1.5 * math.sin(ph))
		remaining, fresh = nil, true
		return self
	end

	-- 只读观察口
	function d:config() return cfg end
	function d:res_bits() return res_bits() end
	function d:pga() return gain end
	function d:is_continuous() return cont end
	function d:is_fresh() return fresh end
	function d:remaining_ms() return remaining end
	function d:raw_value() return raw end
	function d:write_count() return #writes end
	function d:write_log() return writes end

	return d
end

return M

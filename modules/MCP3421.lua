-- MCP3421.lua - 18 位差分模数转换器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MCP3421_VIRT（2026-09-15 自 modules/lib/virtbus/mcp3421.lua
-- 迁入，单文件驱动+模型实验第十二个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Microchip MCP3421：单通道差分 ΔΣ ADC，I2C 地址固定 0x68，PGA ×1~×8，
-- 分辨率/速率绑定档位：18bit@3.75SPS、16bit@15SPS、14bit@60SPS、12bit@240SPS。
-- 无寄存器指针：写 = 单字节配置；读 = 纯读数据流。内部基准 2.048V。
--
-- 用法（结构脚本 .sql，直连路径）：
--   CREATE TABLE MCP3421 (
--       name    String,
--       I2C     String,
--       address String,
--       res     String,   -- 分辨率 12/14/16/18（默认 18；对应 240/60/15/3.75 SPS）
--       pga     String,   -- 增益 1/2/4/8（默认 1；满量程 ±2.048V/pga）
--       opmode  String,   -- 'cont'(默认) | 'oneshot'（转换完进低功耗，省电用）
--       wait    String    -- 等新数据就绪 ms（默认 = 转换周期 + 20 余量；可 call 传参覆盖）
--   );
--   INSERT INTO MCP3421 (name, I2C, address, res, pga, opmode, wait)
--     VALUES ('adc18-0', 'i2c-1', '0x68', '18', '1', 'cont', '-');
--
-- 守护路径：interval 建议 >= 转换周期（18bit 档 >= 270ms），这样每拍数据恰好
--   就绪、call 不必等待；fields 取 "voltage"（伏特浮点）或 "raw"（有符号码值）：
--   INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, res, pga)
--     VALUES ('adc18-0', 'lib/sensor_daemon.lua', 'MCP3421', 'i2c',
--             '/dev/i2c-1', '0x68', '270', 'voltage', '-', '18', '1');
--
-- call 返回契约（键名与 ADS1115 对齐）：{ result, raw, voltage }。
--   数据未就绪（转换中/已被读走）时轮询等待至 wait 超时，仍无新数据返回 ERR
--   （守护 daemon_tick 跳拍不发布；interval >= 转换周期时不会发生）。
--   18 位档读 4 字节（3 数据 + 配置回显，右对齐），其余档读 3 字节（2 数据 + 回显，
--   顶部为重复符号位，按 int16 解释即为该分辨率的有符号码值）。
--   注意与同总线的 MPU6050（默认 0x68）地址冲突，本驱动不做处理。
--
-- build 流程：写配置 -> 读回回显校验（MCP3421 无 ID 寄存器，回显比对兼做在位
--   探测与配置确认；仅比对 O/C+S+G 六位，RDY 位随转换状态浮动不比对）。
--   destroy 写 O/C=0 使器件在当前转换后进入低功耗待机（保留速率/增益配置）。
--
-- 寄存器事实来源：数据手册 DS22003E；位域与数据格式经 Linux 内核 mcp3422 IIO
--   驱动、libdriver/mcp3421、Adafruit_MCP3421 三方实现交叉验证。
--   单次触发极性（写 RDY=1 启动转换）沿用两套参考库的实现。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 配置寄存器位域（bit7..0） ====================
-- [7]=RDY  [6:5]=通道（MCP3422/3/4 用，本芯片恒 0）  [4]=O/C  [3:2]=S1S0  [1:0]=G1G0
local BIT_RDY       = 0x80		-- 写 1 启动单次转换；读 0 = 新数据就绪（1 = 转换中/已被读走）
local BIT_CONT      = 0x10		-- 1 = 连续转换，0 = 单次（转换完进低功耗）
local MASK_RATE     = 0x0C
local MASK_GAIN     = 0x03
local MASK_ECHO     = 0x3F		-- 回显比对范围：O/C + 速率 + 增益（RDY 随状态浮动不比对）

-- 分辨率 -> 速率编码 / 转换周期 ms（数据手册 1/SPS，向上取整）
local RES_CODE = { [12]=0, [14]=1, [16]=2, [18]=3 }
local RES_SPS  = { [12]=240, [14]=60, [16]=15, [18]=3.75 }
local T_CONV_MS = { [12]=5, [14]=17, [16]=67, [18]=267 }
local PGA_CODE = { [1]=0, [2]=1, [4]=2, [8]=3 }

-- 模块级配置（build 写入，跨 call 保持于本变量独立状态机，destroy 后废弃）
local cfg_res			-- 分辨率（12/14/16/18）
local cfg_lsb_v			-- 每 LSB 伏特（2.048 / 2^(res-1) / pga）
local cfg_nbytes		-- 单次读取字节数（18bit=4，其余=3）
local cfg_cont			-- true=连续模式
local cfg_trigger		-- call 触发用的配置字节（oneshot 用，RDY=1）
local cfg_wait			-- 等新数据超时 ms（默认转换周期 + 余量）

-- ==================== 配置解析 ====================
local function cfg_num(v, default, valid, label)
	if v == nil or v == "-" or v == "" then return default end
	local n = math.floor(tonumber(v) or -1)
	if valid[n] == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "'"
	end
	return n
end

-- ==================== 数据解码 ====================
-- v 为大端合并的原始读数（i2c_read 返回）。返回有符号码值与回显字节。
local function decode(v)
	local echo = v % 256
	local raw
	if cfg_res == 18 then
		-- 4 字节：D[17:16] 在首字节低 2 位（高 6 位未用），D[15:8]，D[7:0]，回显
		local b0 = math.floor(v / 256 ^ 3) % 4
		local b1 = math.floor(v / 256 ^ 2) % 256
		local b2 = math.floor(v / 256) % 256
		raw = b0 * 65536 + b1 * 256 + b2
		if raw >= 0x20000 then raw = raw - 0x40000 end		-- 18 位二补码
	else
		-- 3 字节：16 位字（顶部为重复符号位）+ 回显；int16 即该分辨率有符号值
		local w = math.floor(v / 256) % 65536
		w = bitc.s16(w)
		raw = w
	end
	return raw, echo
end

-- ==================== 配置脚本 ====================
-- 写配置 -> 读回回显校验（兼在位探测）
require_driver("i2c", {
name = "MCP3421",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- MCP3421 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-----------------------------------------------------
	-- 解析配置
	local res, e1 = cfg_num(data.res, 18, RES_CODE, "res(bits)")
	if e1 then return err(e1) end

	local pga, e2 = cfg_num(data.pga, 1, PGA_CODE, "pga(gain)")
	if e2 then return err(e2) end

	local opmode_s = data.opmode
	if opmode_s == nil or opmode_s == "-" or opmode_s == "" then opmode_s = "cont" end
	opmode_s = tostring(opmode_s)
	local cont
	if opmode_s == "cont" then cont = true
	elseif opmode_s == "oneshot" then cont = false
	else
		return err("Invalid Argument: opmode '" .. opmode_s .. "' (cont|oneshot)")
	end

	local wait = finite_of(data.wait)
	if wait == nil or wait < 0 then wait = T_CONV_MS[res] + 20 end

	-- 配置字节：RDY=1（连续模式下启动转换流；单次模式下触发首次转换）
	local g_code = PGA_CODE[pga]
	local cfg = BIT_RDY + (cont and BIT_CONT or 0) + RES_CODE[res] * 4 + g_code

	-----------------------------------------------------
	-- 写配置（MCP3421 无寄存器指针：单字节写入即配置）
	if i2c_write_multi(fd, cfg) ~= 0 then
		return err("MCP3421 not responding (config write failed, check address 0x68 and wiring)")
	end

	-- 读回回显校验（兼在位探测）：RDY 位随转换状态浮动，仅比对低 6 位
	-- （回显在末字节，与分辨率档位无关，直接取 v 的最低字节）
	local nbytes = (res == 18) and 4 or 3
	local v = i2c_read(fd, nbytes)
	if v < 0 then
		return err("MCP3421 not responding (echo read failed)")
	end
	local echo = v % 256
	if echo % 64 ~= cfg % 64 then
		return err(string.format("MCP3421 config echo mismatch: got 0x%02X (expect 0x%02X masked 0x%02X)", echo, cfg, MASK_ECHO))
	end

	cfg_res = res
	cfg_lsb_v = 2.048 / 2 ^ (res - 1) / pga
	cfg_nbytes = nbytes
	cfg_cont = cont
	cfg_trigger = cfg				-- RDY=1 的配置字节，oneshot 每次 call 重写触发
	cfg_wait = math.floor(wait)

	print(string.format("MCP3421 init OK: addr=0x%02X res=%dbit pga=x%d mode=%s (%gSPS, LSB=%.4guV)",
		addr, res, pga, opmode_s, RES_SPS[res], cfg_lsb_v * 1e6))
	return {  result = "OK"  }

	end,

-- ==================== 调用 ====================
-- 取一次转换结果。数据未就绪时轮询等待（wait 超时仍无新数据则 ERR）。
-- 返回 { result, raw, voltage }，键名与 ADS1115 驱动对齐。
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- MCP3421 caller func get a table --------", data)
	end

	-----------------------------------------------------

	-----------------------------------------------------
	local wait_ms = finite_of(data.wait)
	if wait_ms == nil then wait_ms = cfg_wait or 0 end
	if wait_ms < 0 then wait_ms = 0 end

	-- 单次模式：每次 call 重写配置触发新转换；连续模式芯片自行持续转换
	if not cfg_cont then
		if i2c_write_multi(fd, cfg_trigger) ~= 0 then
			return err("MCP3421 not responding (trigger write failed)")
		end
	end

	-- 轮询回显 RDY 位：0 = 新数据就绪（1 = 转换中 / 上一结果已被读走）
	local waited = 0
	while true do
		local v = i2c_read(fd, cfg_nbytes)
		if v < 0 then
			return err("MCP3421 not responding (read failed)")
		end
		local raw, echo = decode(v)
		if math.floor(echo / 128) % 2 == 0 then
			return {
				result = "OK",
				raw = raw,
				voltage = raw * cfg_lsb_v
			}
		end
		if waited >= wait_ms then
			return err("MCP3421 conversion not ready (wait " .. math.floor(wait_ms) .. "ms timeout)")
		end
		milli_sleep(5)
		waited = waited + 5
	end

end,
destroy = function(ctx, data)
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) and cfg_trigger then
		-- 仅保留速率+增益位（低 4 位）：RDY=0 不触发、O/C=0 单次 -> 转换完即待机
		i2c_write_multi(fd, cfg_trigger % 16)
	end
	return {  result = "OK"  }
end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MCP3421_VIRT —— 2026-09-15 自 modules/lib/virtbus/mcp3421.lua
-- 整体迁入（单文件驱动+模型第十二个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十一个：① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零外部
-- 依赖；位域常量/分辨率表/clamp 全部移入 new() 内，与上方驱动同名局部量
-- 避让）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
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
-- =====================================================================

MCP3421_VIRT = { _VERSION = "0.1.0" }

function MCP3421_VIRT.new()
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

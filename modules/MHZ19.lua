-- MH-Z19B NDIR CO₂ 传感器 驱动模块（UART 串口，首个串口设备参考实现）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MHZ19_VIRT（2026-09-15 自 modules/lib/virtbus/mhz19.lua
-- 迁入，单文件驱动+模型实验第四个，UART 族样板；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Winsen MH-Z19B：9600 8N1，请求-应答定长帧协议（9 字节 + 累加和校验），
-- 量程 400~5000ppm（或 0~10000 视型号），预热约 3 分钟
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE UART (
--       name String, path String, baud String
--   );
--   INSERT INTO UART (name, path, baud)
--     VALUES ('uart-0', '/dev/serial0', '9600');
--   CREATE TABLE MHZ19 (
--       name String,
--       UART String
--   );
--   INSERT INTO MHZ19 (name, UART) VALUES ('co2-0', 'uart-0');
-- @UART 的 baud 必须 9600（MH-Z19 固定）；UART 列引用 uart-0，
-- fd 经引用机制从 @UART 的 call 流入（与 I2C/SPI 设备同款模式）
--
-- call 无需额外参数，返回 { result, CO2(ppm), TEMP(°C 近似), S(状态字节) }
-- TEMP 为响应帧温度字节 - 40 的近似内部温度（非计量值）；
-- 接 sensor_daemon：fields=CO2（守护路径需 sensor_daemon 支持 proto=uart）
--
-- 实现要点（协议依 Winsen MH-Z19B 数据手册与社区通用实现）：
--   1. 请求帧 9 字节：FF 01 86 00 00 00 00 00 79（读 CO₂），
--      校验和 = (~(b1+..+b7)) + 1 & 0xFF，即 (0x100 - 累加和) & 0xFF
--   2. 应答帧 9 字节：FF 86 HI LO TEMP S U1 U2 CS；CS 校验同上
--      （b1=0x86 起）；CO₂ = HI x 256 + LO
--   3. 读序：发帧前先清输入缓冲（uart_flush，丢弃陈旧字节），
--      发后多轮累积聚合读（同 SDS011.read_frame）：uart_read 单次最多
--      返回 n 字节，帧前有噪声字节时完整帧跨轮到达——只读一轮 9 字节
--      再做帧头扫描在数学上不可达（帧头移位后 9 字节装不下整帧，
--      2026-09 审计 S4 已修）；扫描 + 校验和兜底
--   4. 字节流可能分片到达，uart_read 轮询聚合由 HAL 承担
--   5. 校验和错误/短读/写失败均报 ERR（halt-on-error 链路可用）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + fd ≥ 0 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
dofile((__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
	.resolve("lib/drv_common.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 协议常量 ====================
local FRAME_LEN    = 9
local CMD_READ_CO2 = 0x86
local READ_TIMEOUT_MS = 300		-- 应答帧通常 <50ms 到达，300ms 余量

local RESP_HEAD    = 0xFF
local RESP_CMD     = 0x86

-- MH-Z19 校验和：~(b1+..+b7) + 1（模 256），即 (0x100 - 累加和) & 0xFF
local function checksum(frame, from, to)
	local sum = 0
	for i = from, to do sum = sum + frame[i] end
	return (0x100 - (sum % 0x100)) % 0x100
end

-- 读一帧应答（FF 86 开头 + 校验和），容忍前导噪声：聚合扫描，最多 3 轮。
-- uart_read 单次最多返回 n 字节，噪声字节后完整帧跨轮到达——逐轮累计，
-- 每轮对全部窗口扫描帧头 + 校验和。返回 9 字节 1 基表；失败返回 nil, 原因。
local function read_frame(fd, timeout_ms)
	local acc = {}
	for _ = 1, 3 do
		local chunk = uart_read(fd, FRAME_LEN, timeout_ms)
		if chunk == nil then return nil, "read error" end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		for i = 1, (#acc >= FRAME_LEN) and (#acc - FRAME_LEN + 1) or 0 do
			if acc[i] == RESP_HEAD and acc[i + 1] == RESP_CMD then
				local f = {}
				for k = 0, FRAME_LEN - 1 do f[k + 1] = acc[i + k] end
				local cs = checksum(f, 2, 8)
				if f[9] == cs then return f, nil end
			end
		end
	end
	if #acc == 0 then return nil, "timeout (no bytes)" end
	return nil, "no valid frame (head FF 86 + checksum)"
end

require_driver("uart", {
	name = "MHZ19",

	-- 【配置脚本】校验句柄，清输入缓冲（无寄存器可校验器件）
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- MHZ19 builder func get a table --------", data)
		end

		-- 丢弃上电以来的陈旧字节
		uart_flush(ctx.fd)

		print(string.format("MHZ19 init OK: fd=%d (9600 8N1，预热约 3 分钟后读数稳定)", ctx.fd))
		return {  result = "OK"  }
	end,

	-- 【调用MHZ19】请求-应答读 CO₂ 浓度
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- MHZ19 caller func get a table --------", data)
		end

		local fd = ctx.fd

		-----------------------------------------------------
		-- 请求帧：FF 01 86 00 00 00 00 00 79
		local req = { 0xFF, 0x01, CMD_READ_CO2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
		req[FRAME_LEN] = checksum(req, 2, 8)

		uart_flush(fd)		-- 丢弃陈旧字节，防止旧应答错位
		local wn = uart_write(fd, req)
		if wn ~= FRAME_LEN then
			return err("Failed to write MHZ19 request (" .. tostring(wn) .. ")")
		end

		-- 多轮累积聚合读：容忍前导噪声与跨轮分片（校验和在 read_frame 内兜底）
		local f, ferr = read_frame(fd, READ_TIMEOUT_MS)
		if f == nil then
			return err("MHZ19 no valid response: " .. tostring(ferr))
		end

		local co2 = f[3] * 256 + f[4]

		if DEBUG then
			print(string.format("MHZ19: CO2=%dppm TEMP=%d S=%d", co2, f[5] - 40, f[6]))
		end

		return {
			result = "OK",
			CO2    = co2,
			TEMP   = f[5] - 40,		-- 近似内部温度（非计量值）
			S      = f[6]
		}
	end,

	-- destroy 缺省 = 空操作（原 MHZ19 destroy 仅 arg_table + return OK，等价）
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MHZ19_VIRT —— 2026-09-15 自 modules/lib/virtbus/mhz19.lua
-- 整体迁入（单文件驱动+模型第四个，UART 族样板，守护 E2E 走 sensor_daemon
-- 回退路径）。约定同 PCA9685_VIRT/BH1750_VIRT/MPU6050_VIRT：① 生产路径零执行
-- （new() 仅虚拟总线测试调用，纯闭包无外部依赖）；② 工厂经全局表而非文件
-- return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无
-- settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现（模型自带
-- 帧组装/校验和，不引用上方驱动局部量），互证防假绿性质不变。
-- 工厂表带 BUS="uart"：sensor_daemon proto=virt 据此走 attach_uart/tty 路径。
--
-- 对应真实驱动 modules/MHZ19.lua（9600 8N1，请求-应答定长帧，9 字节 + 累加和
-- 校验）。模型只存协议事实层：FF 01 86 请求帧解析（含校验和验证）、FF 86
-- 应答帧组装、ppm 双字节拆分；TEMP 字节到摄氏度的换算（f[5]-40）只存在于
-- 真实驱动，本模型收摄氏温度逆推原始字节。
--
-- 挂载（UART 路径即设备身份）：
--   vbus.load_driver("modules/MHZ19.lua")   -- 定义全局 build/call/destroy 与 MHZ19_VIRT
--   local dev = MHZ19_VIRT.new()
--   vbus.attach_uart("MHZ19", "/dev/serial0", dev)
--
-- 协议（Winsen MH-Z19B 手册，与驱动一致）：
--   请求 9B：FF 01 86 00 00 00 00 00 CS；CS = (0x100 - Σb2..b8) % 0x100 = 0x79
--   应答 9B：FF 86 HI LO TEMP S 00 00 CS；CO₂ = HI*256 + LO，CS 覆盖 b2..b8
--   收到非法请求（帧头/命令/长度/校验和不符）不应答——真机对垃圾字节流
--   不回帧的事实；驱动侧表现为读超时。
--
-- on_write 三态（virtbus UART 契约）：本模型返回应答 9 字节表；故障钩子
-- 使其返回 nil（不应答）或 false（TX 失败）。
-- =====================================================================

MHZ19_VIRT = { _VERSION = "0.1.0", BUS = "uart" }

function MHZ19_VIRT.new()
	local self = {}

	-- ---- 器件状态（协议事实层原始量）----
	local co2 = 400			-- ppm（HI/LO 双字节合成值）
	local temp_raw = 65		-- 应答 TEMP 字节（驱动换算 TEMP-40 → 25°C）
	local status = 0		-- 应答 S 状态字节
	local requests = {}		-- 请求帧留痕 { bytes=, valid=bool }

	-- ---- 故障注入 ----
	local no_reply = false		-- 收合法请求也不应答（驱动读超时）
	local fail_write_flag = false	-- TX 失败（uart_write 返 -1）
	local corrupt_cs = false	-- 应答校验和翻转（驱动帧扫描全落空）
	local noise_on = false		-- 应答前垫 3 个无帧头噪声字节（跨轮聚合读路径）
	local NOISE = { 0x00, 0x01, 0x02 }	-- 不含 0xFF，保证不误构假帧头

	-- MH-Z19 校验和：(0x100 - Σ(from..to)) % 0x100（与驱动 checksum 同式，纯算术）
	local function checksum(t, from, to)
		local sum = 0
		for i = from, to do sum = sum + (tonumber(t[i]) or 0) end
		return (0x100 - (sum % 0x100)) % 0x100
	end

	-- ===================== 注入 API =====================

	-- CO₂ ppm（协议码空间 0~65535 钳制；量程上下限是器件规格，不在此模拟）
	function self:set_co2(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
		co2 = v
		return self
	end
	function self:co2() return co2 end

	-- 摄氏温度逆推 TEMP 原始字节（-40~215 对应字节 0~255；越界钳制）
	function self:set_temp_c(c)
		local b = math.floor(tonumber(c) or 0) + 40
		if b < 0 then b = 0 elseif b > 255 then b = 255 end
		temp_raw = b
		return self
	end
	function self:temp_raw() return temp_raw end

	function self:set_status(s)
		s = math.floor(tonumber(s) or 0) % 256
		status = s
		return self
	end
	function self:status() return status end

	-- ---- 故障钩子 ----
	function self:no_reply(on) no_reply = (on ~= false); return self end
	function self:fail_write(on) fail_write_flag = (on ~= false); return self end
	function self:corrupt_checksum(on) corrupt_cs = (on ~= false); return self end
	function self:noise(on) noise_on = (on ~= false); return self end
	function self:clear_faults()
		no_reply = false
		fail_write_flag = false
		corrupt_cs = false
		noise_on = false
		return self
	end

	-- ===================== 留痕 / 复位 API =====================

	function self:requests() return requests end
	function self:request_count() return #requests end
	function self:reset_logs()
		requests = {}
		return self
	end

	-- 器件状态复位（回 400ppm 初值/清日志）；不清故障钩子（同其余 virtbus
	-- 模型约定——负路径 section 重开时钩子必须仍在才不假绿）。
	function self:reset()
		co2 = 400
		temp_raw = 65
		status = 0
		requests = {}
		return self
	end

	-- ===================== 应答帧组装 =====================

	local RESP_HEAD, RESP_CMD, FRAME_LEN = 0xFF, 0x86, 9

	local function build_reply()
		local hi = math.floor(co2 / 256) % 256
		local lo = co2 % 256
		local f = { RESP_HEAD, RESP_CMD, hi, lo, temp_raw, status, 0x00, 0x00, 0x00 }
		f[9] = checksum(f, 2, 8)
		if corrupt_cs then f[9] = (f[9] + 0xA5) % 256 end
		return f
	end

	-- on_write(bytes)：点定义、无 self 参数（virtbus attach_uart 动态委托契约）。
	-- 收主机 1 基字节表；返回应答表 = 入环，nil = 不应答，false = TX 失败。
	local function on_write(bytes)
		if fail_write_flag then return false end
		-- 请求帧合法性：FF 01 86 开头、9 字节、尾字节 = b2..b8 校验和
		local valid = #bytes == FRAME_LEN
			and bytes[1] == 0xFF and bytes[2] == 0x01 and bytes[3] == RESP_CMD
			and bytes[9] == checksum(bytes, 2, 8)
		requests[#requests + 1] = { bytes = bytes, valid = valid }
		if not valid or no_reply then return nil end
		if noise_on then
			local reply = build_reply()
			local out = {}
			for _, b in ipairs(NOISE) do out[#out + 1] = b end
			for _, b in ipairs(reply) do out[#out + 1] = b end
			return out
		end
		return build_reply()
	end
	self.on_write = on_write

	-- ===================== 守护节拍（确定性合成波形）====================
	-- 32 拍一周的 CO₂ 爬坡：400 + m*128 ppm（m = n % 32，覆盖 400~4368），
	-- 无随机、逐拍确定；温度/状态保持注入值不动（E2E 只消费 CO2 字段）。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		return self:set_co2(400 + (n % 32) * 128)
	end

	return self
end

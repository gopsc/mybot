-- SDS011 激光 PM2.5/PM10 粉尘传感器 驱动模块（UART 9600 8N1，Nova Fitness）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 SDS011_VIRT（2026-09-15 自 modules/lib/virtbus/sds011.lua
-- 迁入，单文件驱动+模型实验第十一个，UART 第二例；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- 激光散射颗粒物传感器，内置风扇主动吸气。本驱动切【被动查询模式】工作
-- （上电默认主动推送，build 期切换），call 一次查询取一对 PM 值——
-- 请求-应答节奏与 MHZ19.lua 一致，无主动数据流错帧问题。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE UART (
--       name String, path String, baud String
--   );
--   INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/ttyUSB0', '9600');
--   CREATE TABLE SDS011 (
--       name    String,
--       UART    String,
--       timeout String    -- 应答超时 ms（默认 300）
--   );
--   INSERT INTO SDS011 (name, UART, timeout) VALUES ('pm-0', 'uart-0', '-');
--
-- call 返回 { result, PM25, PM10 }（µg/m³，浮点）：
--   传 power="sleep"/"work" 控制风扇停转/工作（风扇寿命约 8000h，间歇采样
--   可延长；注意 work 后需 5~10s 风扇起转才能出有效读数）。
-- 接 sensor_daemon：fields=PM25|PM10（浮点，勿配 sign），interval >= 1s
--   （传感器测量周期约 1s，查询过快得到重复值）。
--
-- 帧格式（py-sds011 与 ricki-z/SDS011 两实现互证）：
--   请求 19 字节：AA B4 | CMD | 12 x 数据 | ID1 ID2 | CS | AB
--     CS = (CMD + 数据 + ID) 累加和 mod 256；设备 ID 用 FF FF 广播
--   应答 10 字节：AA C5 | PM25低 PM25高 PM10低 PM10高 | ID1 ID2 | CS | AB
--     CS = 前 6 字节累加和 mod 256；PM = 小端 16 位 / 10 (µg/m³)
--   命令：02 上报模式（0 主动/1 被动）04 查询 06 睡眠(0)/工作(1)
--     07 固件版本（读）
--   前导噪声容忍：应答帧做 AA C5 扫描 + 校验和兜底（同 MHZ19 的帧头扫描）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 协议常量 ====================
local FRAME_LEN = 19			-- 请求帧
local RESP_LEN  = 10			-- 应答帧
local RESP_CMD  = 0xC5			-- 应答命令字节
local TAIL      = 0xAB

local CMD_REPORT  = 0x02		-- 上报模式（D0: 0 主动 / 1 被动）
local CMD_QUERY   = 0x04		-- 查询一次读数
local CMD_SLEEP   = 0x06		-- 睡眠（D0=0）/ 工作（D0=1）
local CMD_VERSION = 0x07		-- 固件版本（读）

local READ_TIMEOUT_MS = 300

-- 构造请求帧：AA B4 | CMD | D0..D11 | FF FF | CS | AB
local function make_frame(cmd, d0)
	local f = { 0xAA, 0xB4, cmd }
	for _ = 1, 12 do f[#f + 1] = d0 or 0 end		-- D0..D11
	f[#f + 1] = 0xFF		-- ID1（广播）
	f[#f + 1] = 0xFF		-- ID2
	local sum = 0
	for i = 3, #f do sum = sum + f[i] end			-- CMD 起（含 ID）累加
	f[#f + 1] = sum % 256
	f[#f + 1] = TAIL
	return f
end

-- 读一帧应答（AA C5 开头 + 校验和），容忍前导噪声：聚合扫描，最多 3 轮
-- 返回 10 字节 1 基表；无帧/校验和不过返回 nil
local function read_frame(fd, timeout_ms)
	local acc = {}
	for _ = 1, 3 do
		local chunk = uart_read(fd, RESP_LEN, timeout_ms)
		if chunk == nil then return nil end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		for i = 1, (#acc >= RESP_LEN) and (#acc - RESP_LEN + 1) or 0 do
			if acc[i] == 0xAA and acc[i + 1] == RESP_CMD then
				local sum = 0
				for k = i + 2, i + 7 do sum = sum + acc[k] end
				if acc[i + 8] == sum % 256 then
					local f = {}
					for k = 0, RESP_LEN - 1 do f[k + 1] = acc[i + k] end
					return f
				end
			end
		end
	end
	return nil
end

-- 发命令并收应答（校验和由 read_frame 兜底）
local function exec(fd, cmd, d0, timeout_ms)
	uart_flush(fd)
	local wn = uart_write(fd, make_frame(cmd, d0))
	if wn ~= FRAME_LEN then
		return nil, "write failed (" .. tostring(wn) .. ")"
	end
	local f = read_frame(fd, timeout_ms)
	if f == nil then
		return nil, "no valid response"
	end
	return f
end

-- ==================== 模块级配置 ====================
local cfg_timeout

-- ==================== 配置脚本 ====================
-- 切被动查询模式 + 读固件版本（顺带在位探测）
require_driver("uart", {
name = "SDS011",
build = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- SDS011 builder func get a table --------", data)
	end


	local timeout = finite_of(data.timeout)
	if timeout == nil or timeout < 0 then timeout = READ_TIMEOUT_MS end
	cfg_timeout = math.floor(timeout)

	-- 切被动模式（器件 ACK 应答回读校验）
	-- 局部名用 emsg 而非 err：局部 err 会遮蔽 drv_common 的全局 err() 构造器
	local f, emsg = exec(fd, CMD_REPORT, 0x01, cfg_timeout)
	if f == nil then
		return err("SDS011 not responding (set passive mode: " .. emsg .. ")")
	end
	if f[3] ~= CMD_REPORT or f[4] ~= 0x01 then
		return err("SDS011 passive mode rejected")
	end

	-- 固件版本（横幅展示，同时确认查询链路）
	local v, verr = exec(fd, CMD_VERSION, 0x00, cfg_timeout)
	local fw = "?"
	if v ~= nil then
		fw = string.format("%d.%d", v[3], v[4])
	else
		dbg("SDS011 version read failed: " .. tostring(verr))
	end

	print(string.format("SDS011 init OK: fd=%d firmware=%s (passive mode)", fd, fw))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- SDS011 caller func get a table --------", data)
	end

	-----------------------------------------------------
	-- 风扇电源控制
	local power = data.power
	if power ~= nil then
		local d0
		if tostring(power) == "sleep" then d0 = 0
		elseif tostring(power) == "work" then d0 = 1
		else
			return err("Invalid Argument: power '" .. tostring(power) .. "' (sleep|work)")
		end
		local f, emsg = exec(fd, CMD_SLEEP, d0, cfg_timeout or READ_TIMEOUT_MS)
		if f == nil then
			return err("SDS011 not responding (power: " .. emsg .. ")")
		end
		return {
			result = "OK",
			POWER = tostring(power)
		}
	end

	-----------------------------------------------------
	-- 查询读数
	local f, emsg = exec(fd, CMD_QUERY, nil, cfg_timeout or READ_TIMEOUT_MS)
	if f == nil then
		return err("SDS011 not responding (query: " .. emsg .. ")")
	end

	local pm25 = (f[3] + f[4] * 256) / 10.0
	local pm10 = (f[5] + f[6] * 256) / 10.0

	return {
		result = "OK",
		PM25 = pm25,
		PM10 = pm10
	}

	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】SDS011_VIRT —— 2026-09-15 自 modules/lib/virtbus/sds011.lua
-- 整体迁入（单文件驱动+模型第十一个，UART 第二例，守护 E2E 走 sensor_daemon
-- 回退路径）。约定同前十者：① 生产路径零执行（new() 仅虚拟总线测试调用，
-- 纯闭包零外部依赖；帧常量/checksum/STALE 残留帧全部移入 new() 内，与上方
-- 驱动同名局部量避让）；② 工厂经全局表而非文件 return（生产侧 Lua.cj
-- build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值
-- 会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 工厂表带 BUS="uart"：sensor_daemon proto=virt 据此走 attach_uart/tty 路径。
--
-- 对应真实驱动 modules/SDS011.lua（9600 8N1，被动查询模式；请求 19 字节定长
-- 帧、应答 10 字节定长帧，均为累加和 mod 256 校验）。
-- 模型只存协议事实层：AA B4 请求帧解析（命令 + 校验和验证）、按命令组装
-- 10 字节应答（PM 小端双字节拆分 / 命令回显 / 固件版本）；µg/m³ 换算（原始值
-- /10）与 TEMP 类语义换算只存在于真实驱动，本模型一律以协议原始 16 位量存值。
--
-- 挂载（UART 路径即设备身份）：
--   vbus.load_driver("modules/SDS011.lua")  -- 定义全局 build/call/destroy 与 SDS011_VIRT
--   local dev = SDS011_VIRT.new()
--   vbus.attach_uart("SDS011", "/dev/serial0", dev)
--
-- 协议（驱动头注释：py-sds011 与 ricki-z/SDS011 两实现互证）：
--   请求 19B：AA B4 CMD D0..D11 ID1 ID2 CS AB；CS = Σ(CMD..ID2) % 256，ID 用 FF FF 广播
--   应答 10B：AA C5 b3 b4 b5 b6 ID1 ID2 CS AB；CS = Σb3..b8 % 256
--   （驱动 read_frame 的窗口即 10 字节：acc[i+2..i+7] 求和、acc[i+8] 比对，
--     故数据段只有 4 字节，ID 两字节计入校验和。）
--   同一帧结构按命令换语义：0x04 查询 → b3..b6 = PM25L PM25H PM10L PM10H；
--   0x02/0x06 命令 ACK → b3 b4 = 命令号 D0（驱动据此回读校验 passive mode）；
--   0x07 版本 → b3 b4 = 固件主/次版本。
--   收到非法请求（帧头/长度/校验和不符或未知命令）不应答——真机对垃圾字节流
--   不回帧；驱动侧表现为读超时。
--
-- on_write 三态（virtbus UART 契约）：返回应答表 = 入环；nil = 不应答；
-- false = 本笔 TX 失败（uart_write 返 -1）。
-- =====================================================================

SDS011_VIRT = { _VERSION = "0.1.0", BUS = "uart" }

function SDS011_VIRT.new()
	local REQ_LEN  = 19
	local RESP_LEN = 10
	local HEAD_REQ = 0xAA
	local HEAD_RESP = 0xAA
	local CMD_BYTE = 0xB4		-- 请求第二字节
	local RESP_CMD = 0xC5		-- 应答第二字节
	local TAIL     = 0xAB
	local ID1, ID2 = 0xFF, 0xFF	-- 广播地址（应答原样回）

	-- 应答 b3..b8 累加和 mod 256（与驱动 read_frame 兜底校验同式，纯算术）
	local function checksum(t, from, to)
		local sum = 0
		for i = from, to do sum = sum + (tonumber(t[i]) or 0) end
		return sum % 0x100
	end

	local self = {}

	-- ---- 器件状态（协议事实层原始量：0.1 µg/m³ 计）----
	local pm25_raw = 423		-- 42.3 µg/m³
	local pm10_raw = 1000		-- 100.0 µg/m³
	local fw_major, fw_minor = 7, 0	-- 驱动横幅 "%d.%d" 取应答 b3 b4
	local passive = false		-- 0x02 D0=1 后置位（上电默认主动推送）
	local sleeping = false		-- 0x06 D0=0 后置位（风扇停转）
	local requests = {}		-- 请求帧留痕 { bytes=, cmd=, d0=, valid=bool }

	-- ---- 故障注入 ----
	local no_reply = false		-- 收合法请求也不应答（驱动读超时）
	local fail_write_flag = false	-- TX 失败（uart_write 返 -1）
	local corrupt_cs = false		-- 应答校验和 +1 翻转（驱动帧扫描全落空）
	local stale_push = false		-- 应答前垫一帧「主动模式残留推送」（命令切换 ACK 场景）
	local swallow_cmd = nil		-- 只吞指定命令的一次应答（模拟版本查询丢失）

	-- 残留主动帧：AA C5 | 00 00 00 00 | FF FF | 00 | AB——
	-- 帧头/ID/尾全对，唯 CS 字段填 0（真值应为 FE；真机主动流被 cut 在半帧处的等价形态）：
	-- 驱动扫描时 AA C5 命中但校验和不过 → 跳过，下一轮读取才命中真应答帧。
	-- 注意不能填合法 CS：全零数据帧会被驱动当成合法查询应答（PM=0.0）误消费。
	local STALE = { 0xAA, 0xC5, 0, 0, 0, 0, ID1, ID2, 0x00, TAIL }

	-- ===================== 注入 API =====================

	-- 原始 16 位量（协议码空间 0~65535 钳制；真机量程上限是器件规格，不在此模拟）
	function self:set_pm25_raw(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
		pm25_raw = v
		return self
	end
	function self:pm25_raw() return pm25_raw end

	function self:set_pm10_raw(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
		pm10_raw = v
		return self
	end
	function self:pm10_raw() return pm10_raw end

	-- 固件版本（应答 b3 b4；驱动 string.format("%d.%d") 展示）
	function self:set_firmware(major, minor)
		fw_major = math.floor(tonumber(major) or 0) % 256
		fw_minor = math.floor(tonumber(minor) or 0) % 256
		return self
	end
	function self:firmware() return fw_major, fw_minor end

	-- 被动模式状态（真机上电默认主动推送，build 期由驱动切被动）
	function self:passive_mode() return passive end
	function self:sleeping() return sleeping end

	-- ---- 故障钩子 ----
	function self:no_reply(on) no_reply = (on ~= false); return self end
	function self:fail_write(on) fail_write_flag = (on ~= false); return self end
	function self:corrupt_checksum(on) corrupt_cs = (on ~= false); return self end
	function self:stale_push(on) stale_push = (on ~= false); return self end
	-- 定向吞一次：只对本次命令号为 cmd 的合法请求不应答（后续命令恢复正常）。
	-- 驱动 build 期第一条命令是 0x02 切被动，若无差别吞掉首次应答会直接让 build 失败，
	-- 故「版本读不到」这类降级路径必须按命令定向注入（cmd=0x07）。
	function self:swallow_next(cmd) swallow_cmd = tonumber(cmd); return self end
	function self:clear_faults()
		no_reply = false
		fail_write_flag = false
		corrupt_cs = false
		stale_push = false
		swallow_cmd = nil
		return self
	end

	-- ===================== 留痕 / 复位 API =====================

	function self:requests() return requests end
	function self:request_count() return #requests end
	function self:reset_logs()
		requests = {}
		return self
	end

	-- 器件状态复位（回默认浓度/主动模式/风扇运转/清日志）；不清故障钩子
	-- （同其余 virtbus 模型约定——负路径 section 重开时钩子必须仍在才不假绿）。
	function self:reset()
		pm25_raw = 423
		pm10_raw = 1000
		fw_major, fw_minor = 7, 0
		passive = false
		sleeping = false
		requests = {}
		return self
	end

	-- ===================== 应答帧组装 =====================

	-- 10 字节应答：b1 b2 = AA C5，b3..b6 由调用方给，b7 b8 = ID，b9 = CS、b10 = AB
	local function resp(data4)
		local f = { HEAD_RESP, RESP_CMD }
		for i = 1, 4 do f[2 + i] = data4[i] or 0 end
		f[7], f[8] = ID1, ID2
		f[9] = checksum(f, 3, 8)
		f[10] = TAIL
		if corrupt_cs then f[9] = (f[9] + 1) % 256 end
		return f
	end

	local function ack(cmd, d0)
		return resp({ cmd, d0, 0, 0 })
	end

	local function query_frame()
		return resp({ pm25_raw % 256, math.floor(pm25_raw / 256) % 256,
			pm10_raw % 256, math.floor(pm10_raw / 256) % 256 })
	end

	-- on_write(bytes)：点定义、无 self 参数（virtbus attach_uart 动态委托契约）。
	-- 收主机 1 基字节表；返回应答表 = 入环，nil = 不应答，false = TX 失败。
	local function on_write(bytes)
		if fail_write_flag then return false end
		-- 请求帧合法性：AA B4 开头、19 字节、b18 = Σb3..b17、b19 = AB
		local valid = #bytes == REQ_LEN
			and bytes[1] == HEAD_REQ and bytes[2] == CMD_BYTE
			and bytes[19] == TAIL
			and bytes[18] == checksum(bytes, 3, 17)
		local cmd, d0 = bytes[3] or 0, bytes[4] or 0
		requests[#requests + 1] = { bytes = bytes, cmd = cmd, d0 = d0, valid = valid }
		if not valid or no_reply then return nil end
		local reply
		if cmd == 0x02 then
			passive = (d0 == 1)
			reply = ack(0x02, d0)
		elseif cmd == 0x04 then
			reply = query_frame()
		elseif cmd == 0x06 then
			sleeping = (d0 == 0)
			reply = ack(0x06, d0)
		elseif cmd == 0x07 then
			reply = resp({ fw_major, fw_minor, 0, 0 })
		else
			return nil		-- 未知命令：真机不回帧
		end
		if swallow_cmd ~= nil and swallow_cmd == cmd then
			swallow_cmd = nil
			return nil
		end
		if stale_push then
			local out = {}
			for _, b in ipairs(STALE) do out[#out + 1] = b end
			for _, b in ipairs(reply) do out[#out + 1] = b end
			return out
		end
		return reply
	end
	self.on_write = on_write

	-- ===================== 守护节拍（确定性合成波形）====================
	-- 5 拍一周的扬尘爬坡：PM2.5 = 105 + m*8、PM10 = 163 + m*8（0.1 µg/m³ 计，
	-- m = n % 5）→ 10.5/11.3/12.1/12.9/13.7 与 16.3/17.1/17.9/18.7/19.5 µg/m³。
	-- 两列原始值 mod 10 恒非 0（5 与 3 起步、步长 8），故 PM 读数恒带一位小数——
	-- E2E 的浮点断言可直接锚守护 raw 行 "v0":NN.N（与 MHZ19 的整数 ppm 相反，
	-- 无需退到 Monitor Ema 的 out 字段）。无随机、逐拍确定。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local m = n % 5
		self:set_pm25_raw(105 + m * 8)
		self:set_pm10_raw(163 + m * 8)
		return self
	end

	return self
end

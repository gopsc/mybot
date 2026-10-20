-- SCSCL 总线舵机 驱动模块（飞特 FT-SCS 自定义协议，UART TTL 单总线）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 SCSCL_VIRT（无硬件单测与 @Action E2E 共用；
-- 模型与驱动保持独立实现——模型自带帧组装/校验和，不引用上方驱动局部量）
--
-- 适用：飞特（Feetech）电位器型 SCSCL 舵机（SCS 系列；文档见
-- http://doc.feetech.cn 《SCSCL舵机内存表手册》《SCS通信协议》）。
-- 帧格式：FF FF ID LEN INST 参数… CS，LEN = 参数数 + 2；
-- CS = 0xFF - ((ID+LEN+INST+参数) mod 256)。
-- SCSCL 多字节寄存器为大端（高字节在前，内存表 0x02 END=1 表大端存储）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE UART (name String, path String, baud String);
--   INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/serial0', '1000000');
--   CREATE TABLE SCSCL (
--       name String, UART String, id String, max String, min String, offset String
--   );
--   INSERT INTO SCSCL (name, UART, id, max, min, offset)
--     VALUES ('s1', '$uart-0', '1', '1023', '0', '0');
-- baud 支持 500000/1000000（SCSCL 出厂默认档，HAL 白名单含）；
-- UART 列引用 uart-0，fd 经引用机制从 @UART 的 call 流入（与 I2C/SPI 设备同款）
--
-- 结构元数据列：
--   id      舵机站号 1~253（必填）；build 期 PING（0x01）探测在位，不应答即报错
--   max/min 步数限位（0~1023；缺省 max=1023 / min=0；max 为负表示方向反向：
--           限幅后按 1023-p 取反，语义对齐 modules/Servo.lua 的 max 用法）
--   offset  中位漂移（先加 offset 再限幅）
--
-- 动作参数（.mt 列，如 s1.position / s1.speed / s1.time / s1.torque）：
--   position 目标位置 0~1023 步（经 offset/限幅管线；可与 torque 同帧先后下发）
--   speed    运行速度 步/s（0~1000；写 0 且 time 非 0 时按 time 走）
--   time     运行时间 ms（0~9999；speed=0 时生效——指定从当前位到目标位的
--            运动耗时，多关节同时启停用它，见内存表 0x2C）
--   torque   扭矩开关 0 自由 / 1 使能 / 2 阻尼（单独下发 0x28）
--   set_id   站号烧写 1~253（解锁 EPROM 0x30=0 → 广播 0xFE 写 0x05，
--            掉电重启生效；独占本次调用，同行其他参数忽略——烧号是
--            一次性操作，.mt 里单独一行；<=0 或未给 = 不烧号，
--            首行 "-" 解析为 0 即此语义，烧号行之后请显式写 0）。
--            真机烧号请只接目标舵机：广播会命中总线上所有舵机；
--            波特率不会随烧号改变
-- 写指令「发完即走」不读应答：应答状态级别可被配成 0（除读/PING 不应答），
-- 且半双工单总线（方向控制转接板/回显）下回显帧会污染应答解析。
-- 反馈读取走全局 read()（0x02 读 0x38 起 11 字节，无副作用）：位置/速度/
-- 负载/电压/温度/异步标志/状态/移动标志，可被 $ 引用或 Monitor 消费。
--
-- destroy：扭矩关闭（0x28=0，自由状态）——与 PWM 舵机失信号即松开的语义一致，
-- 避免进程退出后舵机持续顶住负载。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- ==================== 协议常量 ====================
local INST_PING  = 0x01
local INST_READ  = 0x02
local INST_WRITE = 0x03

local REG_SERVO_ID         = 0x05	-- 1B：站号（EPROM；改号须先解锁再广播写，掉电重启生效）
local REG_TORQUE_ENABLE    = 0x28	-- 1B：0 自由 / 1 使能 / 2 阻尼
local REG_GOAL_POSITION    = 0x2A	-- 2B 大端：目标位置 0~1023 步
local REG_LOCK             = 0x30	-- 1B：EPROM 写锁（0 解锁（写值掉电保存）/ 1 上锁）
local REG_PRESENT_POSITION = 0x38	-- 反馈块起点：位置2 速度2 负载2 电压1 温度1 异步1 状态1 移动1
local FEEDBACK_LEN         = 11
local REPLY_TIMEOUT_MS     = 100	-- 1M 波特下一帧微秒级到达，100ms 余量
local ADDR_BROADCAST       = 0xFE	-- 广播站号（改号指令用；除 PING 外广播不应答）

-- FT-SCS 校验和：~(ID+LEN+INST+参数) 取低 8 位 = 0xFF - (Σ mod 256)
-- （注意与 MHZ19 的 (0x100-Σ)%256 不同式；PING 经典帧 FF FF 01 02 01 FB 实证）
local function checksum(t, from, to)
	local s = 0
	for i = from, to do s = s + t[i] end
	return 0xFF - (s % 0x100)
end

local function hi8(v) return math.floor(v / 256) % 256 end
local function lo8(v) return math.floor(v) % 256 end
local function be16(hi, lo) return hi * 256 + lo end

-- 组装指令帧（1 基字节表）；校验和覆盖 ID 起（两个 FF 字头不计入）
local function build_frame(id, inst, params)
	local f = { 0xFF, 0xFF, id, #params + 2, inst }
	for i = 1, #params do f[#f + 1] = params[i] end
	f[#f + 1] = checksum(f, 3, #f)
	return f
end

-- 在累计窗口里扫描应答帧：FF FF ID LEN ERROR 参数… CS（帧长 = LEN + 4）。
-- 校验和覆盖 ID..末参数；expect_id 非 nil 时只认该站号（其余帧头跳过后继续扫）。
local function scan_frame(acc, expect_id)
	for i = 1, #acc - 3 do
		if acc[i] == 0xFF and acc[i + 1] == 0xFF then
			local len = acc[i + 3]
			local csIdx = i + len + 3
			if csIdx <= #acc
				and acc[csIdx] == checksum(acc, i + 2, i + len + 2) then
				local frame = { id = acc[i + 2], len = len, error = acc[i + 4], data = {} }
				for k = 5, len + 2 do frame.data[#frame.data + 1] = acc[i + k] end
				if expect_id == nil or frame.id == expect_id then return frame end
			end
		end
	end
	return nil
end

-- 读一帧应答：多轮累积聚合（前导噪声/跨轮分片均可达），最多 3 轮。
-- 返回 frame 或 nil, 原因。
local function read_reply(fd, timeout_ms, expect_id)
	local acc = {}
	for _ = 1, 3 do
		local chunk = uart_read(fd, 64, timeout_ms)
		if chunk == nil then return nil, "read error" end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		local f = scan_frame(acc, expect_id)
		if f ~= nil then return f, nil end
	end
	if #acc == 0 then return nil, "timeout (no bytes)" end
	return nil, "no valid frame (head FF FF + checksum/id)"
end

-- fd/id 公共校验（fd 0 合法；id 必须整数 1~253）
local function resolve_common(data)
	local fd = tonumber(data.fd)
	if fd == nil or fd < 0 then
		return nil, nil, err("Invalid Argument: fd (does the UART column reference an @UART variable?)")
	end
	local id = tonumber(data.id)
	if id == nil or id < 1 or id > 253 or id ~= math.floor(id) then
		return nil, nil, err("Invalid Argument: id (1~253)")
	end
	return fd, id, nil
end

-- 结构元数据列（max/min/offset）的取值判据：缺失与占位符 "-" 都按"未给"
-- 处理（返回 nil，由调用方取缺省）；给了但不是有限数则返回原因串。
-- 审计 P3：这里此前是裸 tonumber + `or 0`，NaN 能穿过去——而 NaN 会让
-- limited_position 的每一道限幅比较恒假（NaN 与任何数比较都是 false），
-- 软限位**静默消失**变成全行程直通，比报错危险得多。
local function meta_finite(v, name)
	if v == nil or v == "-" then return nil, nil end
	local n = finite_of(v)
	if n == nil then return nil, name .. " (not a finite number)" end
	return n, nil
end

-- 动作参数（speed/time/torque）同款判据，差别只在"未给"时取调用方指定的缺省。
-- 审计 P3：`tonumber(x) or 0` 对 NaN 无效（NaN 非 nil，`or` 不触发），
-- NaN 会让后面的区间检查（`< 0` / `> 1000`）恒假、直通到 build_frame，
-- 最后炸在 HAL 的 byte_of 上——末态安全（不会写坏字节）但层次错、报错不透明。
local function opt_finite(v, dflt, name)
	if v == nil or v == "-" then return dflt, nil end
	local n = finite_of(v)
	if n == nil then return nil, name .. " (not a finite number)" end
	return n, nil
end

-- 位置限幅管线（语义对齐 modules/Servo.lua）：pos+offset → 限幅 [|min|,|max|]
-- → max<0 反向（1023-p）→ 钳 0..1023 并四舍五入到整步。
-- 缺省 max=1023 / min=0（全行程）；限位与 offset 属结构元数据（.sql 独占）。
-- 返回 (位置, nil) 或 (nil, 原因)——原因由调用方拼进 ERR 契约。
local function limited_position(pos, data)
	local maxv, e = meta_finite(data.max, "max")
	if e ~= nil then return nil, e end
	local minv
	minv, e = meta_finite(data.min, "min")
	if e ~= nil then return nil, e end
	local off
	off, e = meta_finite(data.offset, "offset")
	if e ~= nil then return nil, e end
	if maxv == nil then maxv = 1023 end
	if minv == nil then minv = 0 end
	if off == nil then off = 0 end
	local p = pos + off
	local amax, amin = math.abs(maxv), math.abs(minv)
	if p > amax then p = amax end
	if p < amin then p = amin end
	if maxv < 0 then p = 1023 - p end
	p = math.floor(p + 0.5)
	if p < 0 then p = 0 elseif p > 1023 then p = 1023 end
	return p, nil
end

-- 【配置脚本】校验 fd/id，PING 探测舵机在位（不应答/错误状态即失败）
require_driver("uart", {
name = "SCSCL",
build = function(ctx, data)
	local fd = ctx.fd

	dbg_table("-------- SCSCL builder func get a table --------", data)

	local id = tonumber(data.id)
	if id == nil or id < 1 or id > 253 or id ~= math.floor(id) then
		return err("Invalid Argument: id (1~253)")
	end

	uart_flush(fd)	-- 丢弃上电/上一次会话残留字节
	local ping = build_frame(id, INST_PING, {})
	local wn = uart_write(fd, ping)
	if wn ~= #ping then
		return err("Failed to write PING request (" .. tostring(wn) .. ")")
	end
	local rep, rerr = read_reply(fd, REPLY_TIMEOUT_MS, id)
	if rep == nil then
		return err("No PING response from SCSCL servo id=" .. tostring(id) .. ": " .. tostring(rerr))
	end
	if rep.error ~= 0 then
		return err("SCSCL servo id=" .. tostring(id) .. " reports error status " .. tostring(rep.error))
	end

	print(string.format("SCSCL init OK: id=%d fd=%d", id, fd))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	local id = tonumber(data.id)
	if id == nil or id < 1 or id > 253 or id ~= math.floor(id) then
		return err("Invalid Argument: id (1~253)")
	end

	-- 26.3 盘点：**评估后不改**。这三处 `tonumber(...) ~= nil` 形似 PWM.lua 的
	-- has_duty（26.3 已修：那里 NaN 会触发「主动使能输出」这个动作），但本处只是
	-- **在场探针**——它只决定「要不要进校验块」，真正的取值在校验块内重走一遍
	-- finite_of/opt_finite（见下面 position 段的 `local p = finite_of(data.position)`），
	-- NaN 在那里被拒成 ERR。set_id 的 `> 0` 与 allow_burn 的 `~= 1` 对 NaN 均为
	-- 假/真，分别落「不烧号」与「拒绝烧号」，都在安全侧。
	local has_pos = tonumber(data.position) ~= nil
	local torque = tonumber(data.torque)
	local set_id = tonumber(data.set_id)

	-- 【站号烧写】set_id 在 1~253 时触发且独占本次调用：.mt 矩阵行必须给满
	-- 所有列，未写的列用 "-"（首行解析为 0、后续行继承上一行）——故 set_id<=0
	-- 一律视为「本行不烧号」，与位置/扭矩照常共存（首行 "-" 即此形态）。
	-- 烧号行触发时同行其他动作参数一律忽略（框架无法区分显式数值与 "-" 继承）。
	-- 注意：烧号行之后的行如果 set_id 写 "-" 会继承本次数值再次烧号，
	-- 请在烧号行之后显式写 0（或把烧号行放在动作脚本最后）。
	if set_id ~= nil and set_id > 0 then
		if set_id > 253 or set_id ~= math.floor(set_id) then
			return err("Invalid Argument: set_id (1~253)")
		end
		-- 审计 H-3 防线：烧号是不可逆持久化硬件写（EPROM 解锁 + 广播 0xFE
		-- 命中全总线），而 set_id 是纯动作参数（不在结构元数据中，框架的
		-- rejectReservedKeys 拦不住）——一行 .mt 即可远程触发（--tcp 下即
		-- 可达）。故必须由结构脚本显式声明 allow_burn 列（值为 1）授权；
		-- 未授权结构脚本的 set_id 动作参数一律拒绝。allow_burn 在元数据中
		-- 后，.mt 侧同名参数键也会被 rejectReservedKeys 拒绝，无法旁路。
		if tonumber(data.allow_burn) ~= 1 then
			return err("Invalid Argument: set_id requires allow_burn=1 in the structure script"
				.. " (burning the id is an irreversible broadcast write; the structure script must authorize it)")
		end
		-- 手册流程：先解锁 EPROM 写锁（0x30=0，否则写值掉电不保存），
		-- 再用广播 ID 0xFE 写 0x05 新站号（对应手册《SCS通信协议》例 3）。
		-- 锁标志是 SRAM，掉电重启自动回 1，故不回锁；新站号重启后生效
		-- （重启前旧站号已不应答）。
		-- 注意：广播会命中总线上所有舵机——真机烧号请只接目标舵机。
		local f1 = build_frame(id, INST_WRITE, { REG_LOCK, 0 })
		local w1 = uart_write(fd, f1)
		if w1 ~= #f1 then
			return err("Failed to write EPROM unlock (" .. tostring(w1) .. ")")
		end
		local f2 = build_frame(ADDR_BROADCAST, INST_WRITE, { REG_SERVO_ID, set_id })
		local w2 = uart_write(fd, f2)
		if w2 ~= #f2 then
			return err("Failed to write servo id (" .. tostring(w2) .. ")")
		end
		if os.getenv("BOT4CJ_DEBUG") == "1" then
			print(string.format("SCSCL: burn id %d -> %d (断电重启生效)", id, set_id))
		end
		return {  result = "OK",  id = id,  set_id = set_id,  note = "断电重启后生效"  }
	end

	if not has_pos and torque == nil then
		return err("Invalid Argument: position (missing; or send torque / set_id only)")
	end

	-- ==================== 先校验完，再下发任何一帧 ====================
	-- 审计 P3（部分提交）：原顺序是"扭矩帧先发、位置参数后校验"。位置/速度/时间
	-- 非法时，扭矩帧已经落到舵机上了——舵机被设成刚性（顶死负载时可能烧机），
	-- 而报错却说 "Failed to write goal position"，把排障指向错误的那一帧。
	-- 现在校验段零总线事务，全部通过后才开始写。
	local pos, spd, tm
	if has_pos then
		local p = finite_of(data.position)
		if p == nil then
			return err("Invalid Argument: position (not a finite number)")
		end
		local e
		pos, e = limited_position(p, data)
		if pos == nil then return err("Invalid Argument: " .. tostring(e)) end
		spd, e = opt_finite(data.speed, 0, "speed")
		if e ~= nil then return err("Invalid Argument: " .. e) end
		if spd < 0 or spd > 1000 then
			return err("Invalid Argument: speed (0~1000 steps/s)")
		end
		tm, e = opt_finite(data.time, 0, "time")
		if e ~= nil then return err("Invalid Argument: " .. e) end
		if tm < 0 or tm > 9999 then
			return err("Invalid Argument: time (0~9999 ms)")
		end
		spd, tm = math.floor(spd), math.floor(tm)
	end
	if torque ~= nil then
		local e
		torque, e = opt_finite(data.torque, nil, "torque")
		if e ~= nil then return err("Invalid Argument: " .. e) end
		torque = math.floor(torque)
		if torque < 0 or torque > 2 then
			return err("Invalid Argument: torque (0 free | 1 enabled | 2 damping)")
		end
	end

	-- ==================== 校验通过，开始下发 ====================
	-- 扭矩开关：单独一帧（0x28），仍在位置帧之前（既有帧序，测试与真机时序依赖它）
	if torque ~= nil then
		local f = build_frame(id, INST_WRITE, { REG_TORQUE_ENABLE, torque })
		local wn = uart_write(fd, f)
		if wn ~= #f then
			return err("Failed to write torque command (" .. tostring(wn) .. ")")
		end
	end

	local res = {  result = "OK",  id = id  }
	if torque ~= nil then res.torque = torque end

	if has_pos then
		local f = build_frame(id, INST_WRITE, {
			REG_GOAL_POSITION, hi8(pos), lo8(pos),
			hi8(tm), lo8(tm), hi8(spd), lo8(spd),
		})
		local wn = uart_write(fd, f)
		if wn ~= #f then
			return err("Failed to write goal position (" .. tostring(wn) .. ")")
		end
		res.position, res.speed, res.time = pos, spd, tm
	end

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print(string.format("SCSCL: id=%s position=%s speed=%s time=%s",
			tostring(id), tostring(res.position), tostring(res.speed), tostring(res.time)))
	end

	return res

end,
destroy = function(ctx, data)
	local fd = tonumber(data.fd)
	local id = tonumber(data.id)
	if fd ~= nil and fd >= 0 and id ~= nil and id >= 1 and id <= 253 then
		local f = build_frame(id, INST_WRITE, { REG_TORQUE_ENABLE, 0 })
		local wn = uart_write(fd, f)
		if wn ~= #f then
			return err("Failed to write torque-off (" .. tostring(wn) .. ")")
		end
	end
	return {  result = "OK"  }
end,
})

-- 【读SCSCL】反馈块（0x38 起 11 字节），无副作用——可被 $ 引用/Monitor 消费
-- 负载/电压按内存表原样返回（负载 0.1% 单位 BIT10 方向位；电压 0.1V 单位）
function read(data)

	-- 审计 #4：与 call 同规，入口走 arg_table（含 proto=virt 前置）
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	local fd, id, e = resolve_common(data)
	if fd == nil then return e end

	uart_flush(fd)	-- 丢弃上一条写指令的应答残留
	local req = build_frame(id, INST_READ, { REG_PRESENT_POSITION, FEEDBACK_LEN })
	local wn = uart_write(fd, req)
	if wn ~= #req then
		return err("Failed to write feedback request (" .. tostring(wn) .. ")")
	end
	local rep, rerr = read_reply(fd, REPLY_TIMEOUT_MS, id)
	if rep == nil then
		return err("No feedback response from SCSCL servo id=" .. tostring(id) .. ": " .. tostring(rerr))
	end
	local d = rep.data
	if #d < FEEDBACK_LEN then
		return err("Short feedback frame (" .. tostring(#d) .. "/" .. tostring(FEEDBACK_LEN) .. ")")
	end

	return {
		result   = "OK",
		id       = id,
		position = be16(d[1], d[2]),
		speed    = be16(d[3], d[4]),
		load     = be16(d[5], d[6]),	-- 0.1%，BIT10 为方向位（原样）
		voltage  = d[7],				-- 0.1V（原样）
		temp     = d[8],				-- °C
		async    = d[9],				-- 异步写标志
		status   = d[10],				-- 状态位（0 正常）
		moving   = d[11],				-- 1 运动中 / 0 到位
	}

end


-- =====================================================================
-- 【内嵌虚拟器件模型】SCSCL_VIRT —— 飞特 SCS 协议舵机（电位器型）
-- 约定同 MHZ19_VIRT/PCA9685_VIRT 等内嵌模型：① 生产路径零执行（new() 仅虚拟
-- 总线测试调用，纯闭包无外部依赖）；② 工厂经全局表而非文件 return（生产侧
-- build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会
-- 滞留 Lua 栈）；③ 模型与驱动保持独立实现（模型自带帧组装/校验和，不引用
-- 上方驱动局部量），互证防假绿性质不变。工厂表带 BUS="uart"：drv_common
-- proto=virt 前置据此走 attach_uart（按 tty 路径定位）路径。
--
-- 协议事实层（《SCS通信协议》+《SCSCL舵机内存表手册》）：
--   指令帧 FF FF ID LEN INST 参数 CS；应答帧 FF FF ID LEN ERROR 参数 CS；
--   CS = 0xFF - (Σ(ID..参数) mod 256)；广播 ID 0xFE（PING 也应答，其余不应答）；
--   站号不匹配不应答；非法帧（帧头/长度/校验和）不应答（真机对垃圾字节流
--   不回帧的事实，驱动侧表现为读超时）。
--   寄存器（大端）：0x05 站号、0x28 扭矩开关、0x2A 目标位置、0x2C 运行时间、
--   0x2E 运行速度、0x30 EPROM 写锁、0x38~0x42 反馈块（位置/速度/负载/电压/
--   温度/异步/状态/移动）。
--   站号语义：写 0x05 立即切换站号（旧站号不再应答）；掉电保存靠解锁——
--   persisted_id 仅在 0x30=0 时随写更新（模拟「上锁写入掉电不保存」），
--   锁标志是 SRAM，重启回 1。
--   运动学：advance(ms) 推进——速度优先（0x2E>0），其次运行时间折算
--   （speed = 距离/时间），都为 0 用出厂默认速度；到位 moving=0、速度反馈归零。
--
-- 挂载（UART 路径即设备身份）：
--   vbus.load_driver("modules/SCSCL.lua")   -- 定义全局 build/call/destroy/read 与 SCSCL_VIRT
--   local dev = SCSCL_VIRT.new()
--   vbus.attach_uart("SCSCL", "/dev/serial0", dev)
-- =====================================================================

SCSCL_VIRT = { _VERSION = "0.1.0", BUS = "uart" }

function SCSCL_VIRT.new()
	local self = {}

	-- ---- 寄存器字节地图（可读；写白名单 = 非只读项）----
	-- 初值取内存表 POR（0x2E 初值「出厂默认最大速度」以 1000 步/s 近似）
	local READONLY = {
		[0x38] = true, [0x39] = true, [0x3A] = true, [0x3B] = true,
		[0x3C] = true, [0x3D] = true, [0x3E] = true, [0x3F] = true,
		[0x40] = true, [0x41] = true, [0x42] = true,
	}
	local regs
	local function por()
		regs = {
			[0x05] = 1,					-- 站号：POR 1
			[0x28] = 0,					-- 扭矩开关：POR 0（自由）
			[0x2A] = 0, [0x2B] = 0,		-- 目标位置
			[0x2C] = 0, [0x2D] = 0,		-- 运行时间
			[0x2E] = 0x03, [0x2F] = 0xE8,	-- 运行速度 1000 步/s
			[0x30] = 1,					-- EPROM 写锁：POR 1（上锁）
			[0x38] = 0, [0x39] = 0,		-- 位置反馈
			[0x3A] = 0, [0x3B] = 0,		-- 速度反馈
			[0x3C] = 0, [0x3D] = 0,		-- 负载反馈
			[0x3E] = 78,				-- 电压 7.8V（0.1V 单位）
			[0x3F] = 35,				-- 温度 35°C
			[0x40] = 0,					-- 异步写标志
			[0x41] = 0,					-- 状态（0 正常）
			[0x42] = 0,					-- 移动标志
		}
	end
	por()

	local servo_id = 1			-- 当前生效站号（写 0x05 立即切换）
	local persisted_id = 1		-- 掉电保存的站号（仅解锁 0x30=0 时随写更新）

	-- ---- 故障注入 ----
	local no_reply = false		-- 收合法请求也不应答（驱动读超时）
	local fail_write_flag = false	-- TX 失败（uart_write 返 -1）
	local corrupt_cs = false	-- 应答校验和翻转（驱动帧扫描全落空）
	local noise_on = false		-- 应答前垫 3 个无帧头噪声字节（跨轮聚合读路径）
	local NOISE = { 0x00, 0x01, 0x02 }	-- 不含 0xFF，保证不误构假帧头

	-- ---- 留痕 ----
	local requests = {}			-- { bytes=, valid=bool, kind="ping"|"read"|"write"|"other" }

	-- 独立校验和实现（纯算术；与驱动同式，测试侧另有第三份交叉）
	local function cs(t, from, to)
		local s = 0
		for i = from, to do s = s + (tonumber(t[i]) or 0) end
		return 0xFF - (s % 0x100)
	end

	local function u16(hi, lo) return hi * 256 + lo end

	local function reply_frame(rid, error, params)
		local f = { 0xFF, 0xFF, rid, #params + 2, error }
		for i = 1, #params do f[#f + 1] = params[i] end
		f[#f + 1] = cs(f, 3, #f)	-- 校验和覆盖 ID 起（两个 FF 字头不计入）
		if corrupt_cs then f[#f] = (f[#f] + 0xA5) % 256 end
		if noise_on then
			local out = {}
			for _, b in ipairs(NOISE) do out[#out + 1] = b end
			for _, b in ipairs(f) do out[#out + 1] = b end
			return out
		end
		return f
	end

	-- 目标位置（钳 0~1023，内存表量程）
	local function goal_pos()
		local g = u16(regs[0x2A], regs[0x2B])
		if g > 1023 then g = 1023 end
		return g
	end

	-- 写白名单：地图内且非只读；越界/只读整笔拒绝（真机 NACK 语义）
	local function apply_write(addr, data)
		for k = 0, #data - 1 do
			local a = addr + k
			if regs[a] == nil or READONLY[a] then return false end
		end
		for k = 0, #data - 1 do
			regs[addr + k] = data[k + 1]
		end
		-- 站号写（0x05）：立即切换（旧站号不再应答）；掉电保存语义——
		-- 仅在写时已解锁（0x30=0）才更新 persisted_id（上锁写的值重启即丢）
		for k = 0, #data - 1 do
			if addr + k == 0x05 then
				local v = regs[0x05]
				if v < 1 then v = 1 elseif v > 253 then v = 253 end
				servo_id = v
				if regs[0x30] == 0 then persisted_id = v end
			end
		end
		-- 目标位置一变，移动标志立即反映（位置由 advance 推进）
		regs[0x42] = (u16(regs[0x38], regs[0x39]) ~= goal_pos()) and 1 or 0
		return true
	end

	local function on_write(bytes)
		if fail_write_flag then return false end
		-- 帧合法性：FF FF 开头、LEN 与帧长一致（总长 = LEN + 4）、校验和一致
		-- （校验和覆盖 ID 起；test/test_scscl.lua 有第三份独立实现交叉）
		local valid = #bytes >= 6 and bytes[1] == 0xFF and bytes[2] == 0xFF
			and bytes[4] == #bytes - 4
			and bytes[#bytes] == cs(bytes, 3, #bytes - 1)
		local kind = "invalid"
		if valid then
			local inst = bytes[5]
			if inst == 0x01 then kind = "ping"
			elseif inst == 0x02 then kind = "read"
			elseif inst == 0x03 then kind = "write"
			else kind = "other" end
		end
		requests[#requests + 1] = { bytes = bytes, valid = valid, kind = kind }
		if not valid or no_reply then return nil end

		local rid = bytes[3]
		-- 站号过滤：非本站且非广播 → 静默（真机不匹配 ID 的舵机不动作不应答）
		if rid ~= servo_id and rid ~= 0xFE then return nil end

		local inst = bytes[5]
		local params = {}
		for k = 6, #bytes - 1 do params[#params + 1] = bytes[k] end

		if inst == 0x01 then
			-- PING：广播 ID 也应答（协议文档语义）；应答带本站 ID
			return reply_frame(servo_id, regs[0x41], {})
		elseif inst == 0x02 then
			local addr, n = params[1], params[2]
			if addr == nil or n == nil or n < 1 or n > 32 then return nil end
			if rid == 0xFE then return nil end	-- 广播读无意义，不应答
			local out = {}
			for k = 0, n - 1 do
				local a = addr + k
				if regs[a] == nil then return nil end	-- 地图外整笔不应答
				out[#out + 1] = regs[a]
			end
			return reply_frame(rid, regs[0x41], out)
		elseif inst == 0x03 then
			local addr = params[1]
			local data = {}
			for k = 2, #params do data[#data + 1] = params[k] end
			if addr == nil or #data == 0 then return nil end
			if not apply_write(addr, data) then return nil end
			if rid == 0xFE then return nil end	-- 广播写不应答
			return reply_frame(rid, regs[0x41], {})
		end
		return nil
	end
	self.on_write = on_write

	-- ===================== 运动学推进 =====================

	-- 推进 ms 毫秒（确定性算术，无时钟）：速度优先（0x2E>0），
	-- 其次运行时间折算（speed = 距离/时间），都为 0 用出厂默认速度。
	local DEFAULT_SPEED = 1000	-- 步/s
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if ms <= 0 then return self end
		local target = goal_pos()
		local pos = u16(regs[0x38], regs[0x39])
		if pos == target then
			regs[0x3A], regs[0x3B] = 0, 0
			regs[0x42] = 0
			return self
		end
		local spd = u16(regs[0x2E], regs[0x2F])
		local tm = u16(regs[0x2C], regs[0x2D])
		if spd == 0 then
			if tm > 0 then
				spd = math.max(1, math.floor(math.abs(target - pos) * 1000 / tm))
			else
				spd = DEFAULT_SPEED
			end
		end
		local dist = target - pos
		local dir = dist > 0 and 1 or -1
		local step = math.floor(spd * ms / 1000)
		if step > math.abs(dist) then step = math.abs(dist) end
		pos = pos + dir * step
		regs[0x38], regs[0x39] = math.floor(pos / 256) % 256, pos % 256
		if pos == target then
			regs[0x3A], regs[0x3B] = 0, 0
			regs[0x42] = 0
		else
			regs[0x3A], regs[0x3B] = math.floor(spd / 256) % 256, spd % 256
			regs[0x42] = 1
		end
		return self
	end

	-- 守护节拍：一拍 = 20ms 确定性推进（写路径无守护 E2E，保留给未来扩展；
	-- 无时钟、纯算术，同其余模型的 virt_tick 约定）
	function self:virt_tick(n)
		return self:advance(20)
	end

	-- ===================== 注入 / 观察 API =====================

	function self:set_id(v)
		v = math.floor(tonumber(v) or 0)
		if v < 1 then v = 1 elseif v > 253 then v = 253 end
		servo_id = v
		regs[0x05] = v
		persisted_id = v	-- 注入即视为已保存（与「解锁后写入」等效）
		return self
	end
	function self:id() return servo_id end

	-- 站号烧写观察口：lock=POR 上锁/解锁状态；persisted_id=掉电后仍生效的站号
	-- （解锁后写 0x05 才同步更新——测试据此证明驱动先解锁再写号）
	function self:lock() return regs[0x30] end
	function self:persisted_id() return persisted_id end

	-- 位置反馈注入（钳 0~1023）
	function self:set_present_position(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then v = 0 elseif v > 1023 then v = 1023 end
		regs[0x38], regs[0x39] = math.floor(v / 256) % 256, v % 256
		regs[0x42] = (v ~= goal_pos()) and 1 or 0
		return self
	end
	function self:present_position() return u16(regs[0x38], regs[0x39]) end

	function self:set_voltage_raw(b)
		regs[0x3E] = math.floor(tonumber(b) or 0) % 256
		return self
	end
	function self:voltage_raw() return regs[0x3E] end

	function self:set_temp_c(c)
		local v = math.floor(tonumber(c) or 0)
		if v < 0 then v = 0 elseif v > 255 then v = 255 end
		regs[0x3F] = v
		return self
	end
	function self:temp_c() return regs[0x3F] end

	function self:set_status(s)
		regs[0x41] = math.floor(tonumber(s) or 0) % 256
		return self
	end
	function self:status() return regs[0x41] end

	function self:set_load(v)
		v = math.floor(tonumber(v) or 0) % 65536
		regs[0x3C], regs[0x3D] = math.floor(v / 256) % 256, v % 256
		return self
	end
	function self:load() return u16(regs[0x3C], regs[0x3D]) end

	-- 驱动器写入后的观察口（测试断言用）
	function self:torque_enable() return regs[0x28] end
	function self:goal_position() return u16(regs[0x2A], regs[0x2B]) end
	function self:run_time() return u16(regs[0x2C], regs[0x2D]) end
	function self:run_speed() return u16(regs[0x2E], regs[0x2F]) end
	function self:moving() return regs[0x42] end

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

	-- ---- 留痕 / 复位 ----
	function self:requests() return requests end
	function self:request_count() return #requests end
	function self:reset_logs()
		requests = {}
		return self
	end

	-- 器件状态回初值（寄存器 POR + 站号 1）+ 清日志；不清故障钩子
	-- （同其余 virtbus 模型约定——负路径 section 重开时钩子必须仍在才不假绿）
	function self:reset()
		por()
		servo_id, persisted_id = 1, 1
		requests = {}
		return self
	end

	return self
end

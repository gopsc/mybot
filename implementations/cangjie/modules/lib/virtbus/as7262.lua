-- modules/lib/virtbus/as7262.lua —— AS7262 六通道可见光光谱传感器虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个「硬件仅 3 寄存器 + 虚拟寄存器间接窗口 + TX/RX 就绪握手」
-- I2C 器件】（ams AS7262，地址 0x49；纯闭包、纯算术无 bitcompat）。I2C 总线
-- 上只能看到 3 个硬件寄存器：STATUS 0x00（bit1=TX_VALID 写口忙、
-- bit0=RX_VALID 读口有数据）、写口 WRITE 0x01、读口 READ 0x02；DEVICE_TYPE/
-- CONTROL/INT_T/六通道等全部虚拟寄存器（0x00~0x13）都不能直接寻址，必须走
-- SparkFun 同款握手时序（真实驱动 modules/AS7262.lua 同款）：
--   读虚拟 = 预冲刷滞留 RX -> 等 STATUS.TX=0 -> 写口发地址(bit7=0)
--           -> 等 STATUS.RX=1 -> 读读口；
--   写虚拟 = 等 STATUS.TX=0 -> 写口发 地址|0x80 -> 再等 TX=0 -> 写口发数据。
-- 总线事务形态：i2c_read_reg 是「w 指针 1B + r 1B」两步，i2c_write_reg 是
-- 一笔 {reg,val} 2B；模型必须在 3 个硬件寄存器之上自己实现芯片侧握手。
--
-- 协议层事实（AS7262 datasheet / SparkFun AS726X，以真实驱动访问为准）：
--   1) 零延迟握手：芯片对写口/读口的处理在 I2C 速率下瞬时完成——模型里
--      TX_VALID 正常恒读 0（驱动 5ms 步进轮询第一次即通过、零睡眠），读命令
--      锁存后 RX_VALID 立即置 1、读口消费后清 0；tx_stuck 可强制 TX 恒 1、
--      rx_stuck 可让读命令不置 RX，分别喂驱动两段 50 次×5ms=250ms 握手超时。
--   2) 写口字节【按状态机位置解释，不按 bit7 区分命令/数据】：空闲态 bit7=1
--      是写地址相位、bit7=0 是读地址相位；进入等数据态后下一字节无条件是
--      数据（数据可以 >=0x80，如驱动 RST 写 0x88），再按 bit7 判会误吃数据。
--   3) 虚拟寄存器：0x00 DEVICE_TYPE（AS7262=0x3E，0x3D=AS7261/0x3F=AS7263）、
--      0x04 CONTROL_SETUP（bit7=RST 软复位自清除不落盘、[5:4]=GAIN、
--      [3:2]=BANK、bit1=DATA_RDY 只读状态位——读时动态合成，写 0 清除、
--      写 1 无效）、0x05 INT_T（每单位 2.8ms）、0x06 DEVICE_TEMP（补码 °C）、
--      六通道 16 位计数 MSB 在偶地址：V 0x08/B 0x0A/G 0x0C/Y 0x0E/O 0x10/
--      R 0x12。POR：TYPE=0x3E、CONTROL=0x08（BANK=2 连续全通道、GAIN=1x、
--      DATA_RDY=0）、INT_T=0x00、TEMP=24、通道全 0。
--   4) 连续全通道（BANK=2）一轮转换 = 2×INT_T×2.8ms，完成置 DATA_RDY 并把
--      六通道结果锁入数据寄存器；驱动 RMW 清 DATA_RDY 后芯片随即开始下一
--      轮。advance(ms) 推转换门，测试 milli_sleep 桩转调（驱动 call 就绪
--      轮询 5ms 步进，超时默认 2×轮时间+500ms）；通道数据寄存器【只由转换
--      完成事件/virt_tick 改变】，set_result 只入注入表不提前同步。
--   5) 守护零睡眠：sensor_daemon 每拍 virt_tick(n) 直接装六通道+温度并置
--      DATA_RDY（预武装），call 首次轮询即就绪；build 含 RST 后 1000ms
--      硬睡（SparkFun 同款不轮询启动），E2E 首行预热须容纳。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")

local M = {}
M._VERSION = "0.1.0"

-- ==================== 硬件寄存器（I2C 直接可见） ====================
local HW_STATUS, HW_WRITE, HW_READ = 0x00, 0x01, 0x02
local F_TX_VALID, F_RX_VALID = 0x02, 0x01

-- ==================== 虚拟寄存器 ====================
local V_DEVICE_TYPE   = 0x00	-- 0x3E=AS7262 / 0x3D=AS7261 / 0x3F=AS7263
local V_CONTROL_SETUP = 0x04	-- bit7=RST [5:4]=GAIN [3:2]=BANK bit1=DATA_RDY
local V_INT_T         = 0x05
local V_DEVICE_TEMP   = 0x06

local NAMES = { "V", "B", "G", "Y", "O", "R" }
local CHAN_ADDR = { V = 0x08, B = 0x0A, G = 0x0C, Y = 0x0E, O = 0x10, R = 0x12 }

local DEV_TYPE_AS7262 = 0x3E
local BIT_RST, BIT_DATA_RDY = 0x80, 0x02

-- virt_tick 六通道确定性正弦基线/幅值（计数，0~65535 量程内）
local TICK_BASE = { 9000, 14000, 22000, 26000, 19000, 11000 }
local TICK_AMP  = { 3000, 4000, 6000, 5000, 4500, 3500 }

local function clamp_u16(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end

-- 通道名/序号 -> {地址, 名字}
local function ch_resolve(ch)
	if type(ch) == "string" then
		local name = ch:upper()
		local addr = CHAN_ADDR[name]
		if addr then return addr, name end
		return nil
	end
	local i = tonumber(ch)
	if i and i == math.floor(i) and i >= 1 and i <= 6 then
		return 0x08 + (i - 1) * 2, NAMES[i]
	end
	return nil
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local vregs = {}			-- 虚拟寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil			-- 最近一笔硬件指针写（0x00/0x01/0x02）
	local rx_addr = nil			-- 读口待取的虚拟地址（nil=RX_VALID=0）
	local wstate = nil			-- nil | "data"（写口等数据相位）
	local waddr = nil
	local data_rdy = false		-- CONTROL bit1（只读状态，读时合成）
	local remaining = nil		-- 连续模式距下一轮完成的 ms
	local results = {}			-- 六通道待转换注入值（完成事件才进 vregs）
	local dev_type = DEV_TYPE_AS7262

	-- 计数/日志
	local vread_cmds = 0		-- 写口收到的读地址命令次数
	local vwrite_cmds = 0		-- 完成的虚拟寄存器写次数
	local reset_count = 0		-- RST 位软复位次数

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_ready = false	-- DATA_RDY 永不置位（advance/武装均无效）
	local tx_stuck = false		-- STATUS.TX_VALID 恒 1（等 TX 空超时）
	local rx_stuck = false		-- 读命令不置 RX（等 RX 有效超时）

	-- ---------------- 上电种子 / 复位 ----------------

	local function seed_vregs()
		vregs = {}
		vregs[0x00] = dev_type
		vregs[0x01] = 0x40			-- HW version 占位（驱动不读）
		vregs[0x04] = 0x08			-- BANK=2 连续全通道、GAIN=0(1x)、RDY=0
		vregs[0x05] = 0x00			-- INT_T POR=0（build 写缺省 50）
		vregs[0x06] = 24			-- 片上温度占位
		vregs[0x07] = 0x00
		for a = 0x08, 0x13 do vregs[a] = 0 end
	end

	local function chip_state_clear()
		read_ptr = nil
		rx_addr, wstate, waddr = nil, nil, nil
		data_rdy, remaining = false, nil
	end

	-- RST 位/软复位：寄存器回 POR、清芯片侧握手与转换态；
	-- 外部注入（results）与故障钩子保留（复位不清激励、防负路径假解除）
	local function reseed()
		seed_vregs()
		chip_state_clear()
		-- 上电即连续全通道运转，排第一轮（INT_T=0 时周期 0，advance 即完成）
		remaining = 0
	end

	seed_vregs()
	remaining = 0

	-- ---------------- 派生/合成 ----------------

	local function gain_of()		return math.floor(vregs[V_CONTROL_SETUP] / 0x10) % 4 end
	local function bank_of()		return math.floor(vregs[V_CONTROL_SETUP] / 0x04) % 4 end
	local function cycle_ms()		return (vregs[V_INT_T] or 0) * 5.6 end	-- 2×2.8ms

	-- CONTROL 读回：配置影子 + DATA_RDY 动态合成（RST 位永不落盘）。
	-- 影子的 bit1/bit7 由写入侧保证恒 0（只读位/自清除位不入库），直接加成就位；
	-- 不能用 shadow % 0xFD 一类取模清位——0xFD 非 2 的幂，取模不等于按位与。
	local function control_read()
		return vregs[V_CONTROL_SETUP] + (data_rdy and BIT_DATA_RDY or 0)
	end

	local function read_vreg(a)
		if a == V_CONTROL_SETUP then return control_read() end
		return vregs[a] or 0
	end

	local function status_byte()
		return (rx_addr ~= nil and F_RX_VALID or 0)
		     + (tx_stuck and F_TX_VALID or 0)
	end

	-- 一轮转换完成：锁存注入结果到通道数据寄存器、置 DATA_RDY；
	-- 下一轮等驱动 RMW 清 DATA_RDY 后再排（连续模式时序确定）
	local function finish_cycle()
		if never_ready then return end
		for i = 1, 6 do
			local raw = results[NAMES[i]] or 0
			local a = 0x08 + (i - 1) * 2
			vregs[a] = math.floor(raw / 256) % 256
			vregs[a + 1] = raw % 256
		end
		data_rdy, remaining = true, nil
	end

	-- ---------------- 虚拟寄存器写副作用 ----------------

	local function write_vreg(addr, val)
		vwrite_cmds = vwrite_cmds + 1
		val = val % 256
		if addr == V_CONTROL_SETUP then
			if math.floor(val / 0x80) % 2 == 1 then
				-- bit7=RST：软复位，自清除不落盘
				reseed()
				reset_count = reset_count + 1
				return
			end
			-- DATA_RDY 只读：bit1 写 0 清除（写 1 无效，保持原状态）
			local rdy_written = math.floor(val / 2) % 2 == 1
			if not rdy_written then
				data_rdy = false
			end
			-- 落配置位：bit7(RST) 已在上方分支返回；只读 bit1(DATA_RDY) 用减法
			-- 剔除后再入影子。严禁 val % 0x7D——0x7D 非 2 的幂，取模不清位，
			-- 会让驱动 RMW 写回的就绪位残留（读回再加成就位会进位出错）。
			local cfg = val
			if rdy_written then cfg = cfg - 0x02 end
			vregs[V_CONTROL_SETUP] = cfg
			-- 连续全通道：清位后芯片随即开始下一轮；其他 BANK 暂停转换
			if bank_of() == 0x02 then
				if not data_rdy and remaining == nil then remaining = cycle_ms() end
			else
				remaining = nil
			end
			return
		end
		vregs[addr] = val
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		if #bytes == 1 then
			-- 纯硬件寄存器指针写（i2c_read_reg 的指针相位）
			if bytes[1] > HW_READ then return false end
			read_ptr = bytes[1]
			return true
		end
		if #bytes ~= 2 then return false end
		if write_pred and write_pred(bytes) then return false end
		local reg, val = bytes[1], bytes[2]
		if reg ~= HW_WRITE then
			-- STATUS/READ 只读；0x03+ 硬件地址不存在
			return false
		end
		if wstate == "data" then
			-- 数据相位：字节按位置解释（即使 >=0x80，如 RST 0x88）
			wstate = nil
			write_vreg(waddr, val)
		elseif val >= 0x80 then
			-- 写地址相位（bit7=1），芯片锁存后瞬时就绪（TX 不置忙）
			waddr, wstate = val - 0x80, "data"
		else
			-- 读地址相位（bit7=0）：RX 瞬时有效；rx_stuck 时芯片不应答数据
			vread_cmds = vread_cmds + 1
			if not rx_stuck then rx_addr = val end
		end
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = tonumber(n) or 1
		n = math.floor(n)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		local b
		if read_ptr == HW_STATUS then
			b = status_byte()
		elseif read_ptr == HW_READ then
			if rx_addr ~= nil then
				b = read_vreg(rx_addr)
				rx_addr = nil			-- 读口消费，RX_VALID 清 0
			else
				b = 0				-- 空读（协议上驱动不会在此刻读）
			end
		else
			return nil				-- 无指针/写口 0x01 不可读
		end
		local t = { b }
		for i = 2, n do t[i] = 0 end
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil and bank_of() == 0x02 and not never_ready then
			remaining = remaining - ms
			if remaining <= 0 then finish_cycle() end
		end
		return self
	end

	-- 注入下一轮转换结果（16 位无符号计数；只入注入表，完成事件才进数据寄存器）
	function d:set_result(ch, raw)
		local _, name = ch_resolve(ch)
		if name then results[name] = clamp_u16(raw) end
		return self
	end

	function d:set_results(t)
		if type(t) == "table" then
			for k, v in pairs(t) do self:set_result(k, v) end
		end
		return self
	end

	-- 直接写通道数据寄存器（静态读回/模型事实用，绕过转换事件）
	function d:set_channel_raw(ch, raw)
		local addr = ch_resolve(ch)
		if addr then
			raw = clamp_u16(raw)
			vregs[addr] = math.floor(raw / 256) % 256
			vregs[addr + 1] = raw % 256
		end
		return self
	end

	-- 片上温度（有符号补码 °C，-128~127）
	function d:set_temp(c)
		c = math.floor(tonumber(c) or 0)
		if c < -128 then c = -128 elseif c > 127 then c = 127 end
		vregs[V_DEVICE_TEMP] = c < 0 and c + 256 or c
		return self
	end

	function d:set_device_type(t)
		t = math.floor(tonumber(t) or DEV_TYPE_AS7262) % 256
		dev_type = t
		vregs[V_DEVICE_TYPE] = t
		return self
	end

	-- DATA_RDY 永不置位（喂 call 就绪超时；advance 不推、virt_tick 不武装）
	function d:set_never_ready(on) never_ready = on ~= false; return self end
	-- 握手卡死：TX 恒忙（等 TX 空超时）/读命令不置 RX（等 RX 有效超时）
	function d:set_tx_stuck(on) tx_stuck = on ~= false; return self end
	function d:set_rx_stuck(on) rx_stuck = on ~= false; return self end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_ready, tx_stuck, rx_stuck = false, false, false
		return self
	end

	function d:reset_logs()
		vread_cmds, vwrite_cmds = 0, 0
		return self
	end

	-- 重新上电：全状态回 POR、注入/计数清空；故障钩子保留
	function d:reset()
		dev_type = DEV_TYPE_AS7262
		results = {}
		seed_vregs()
		chip_state_clear()
		remaining = 0
		vread_cmds, vwrite_cmds, reset_count = 0, 0, 0
		return self
	end

	-- 守护逐拍造数：确定性六通道光谱正弦 + 温度，并预武装（直接置
	-- DATA_RDY 且把样本锁入数据寄存器——守护不驱动 advance，call 首读
	-- CONTROL 即就绪、随后读到本拍值；never_ready 时武装失效）
	function d:virt_tick(n)
		local ph = 2 * math.pi * ((tonumber(n) or 0) % 32) / 32
		for i = 1, 6 do
			local raw = TICK_BASE[i] + TICK_AMP[i] * math.sin(ph + (i - 1) * math.pi / 6)
			raw = clamp_u16(raw)
			results[NAMES[i]] = raw
			local a = 0x08 + (i - 1) * 2
			vregs[a] = math.floor(raw / 256) % 256
			vregs[a + 1] = raw % 256
		end
		self:set_temp(math.floor(25 + 4 * math.sin(ph) + 0.5))
		if not never_ready then
			data_rdy, remaining = true, nil
		end
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:status() return status_byte() end
	function d:vreg(a) return read_vreg(math.floor(tonumber(a) or 0)) end
	function d:vreg_shadow(a) return vregs[math.floor(tonumber(a) or 0)] end
	function d:control() return control_read() end
	function d:control_shadow() return vregs[V_CONTROL_SETUP] end
	function d:int_t() return vregs[V_INT_T] or 0 end
	function d:gain() return gain_of() end
	function d:bank() return bank_of() end
	function d:data_ready() return data_rdy end
	function d:remaining_ms() return remaining end
	function d:cycle_ms() return cycle_ms() end
	function d:reset_count() return reset_count end
	function d:vread_count() return vread_cmds end
	function d:vwrite_count() return vwrite_cmds end
	function d:rx_pending() return rx_addr end
	function d:write_pending() return wstate == "data" and waddr or nil end
	function d:device_type() return vregs[V_DEVICE_TYPE] end

	function d:temp_c()
		local b = vregs[V_DEVICE_TEMP] or 0
		return b >= 128 and b - 256 or b
	end

	function d:channel(ch)
		local addr = ch_resolve(ch)
		if not addr then return nil end
		return (vregs[addr] or 0) * 256 + (vregs[addr + 1] or 0)
	end

	function d:result(ch)
		local _, name = ch_resolve(ch)
		return name and results[name] or nil
	end

	return d
end

return M

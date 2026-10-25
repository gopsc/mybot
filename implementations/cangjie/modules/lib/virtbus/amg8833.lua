-- modules/lib/virtbus/amg8833.lua —— AMG8833 Grid-EYE 8x8 红外热电堆阵列虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【8 位字节指针 + 128 字节像素块连续 burst 读 + 帧周期门】样板
-- （Panasonic AMG8833，地址 0x69 缺省/0x68；纯闭包、纯算术无 bitcompat）。
-- 与 regmap 通用底座同属字节指针族，但器件特有的命令寄存器/帧状态机/整块
-- 像素注入不适合底座，照 max30102.lua 同式自定义闭包：
--
--   1) 寄存器全按字节寻址（i2c_read_multi_bytes = 写 1B 指针 + 连续读 nB），
--      读指针随字节自增、0xFF 后回绕 0x00。0x80 起 128 字节 = 64 像素 ×2B，
--      12 位补码、小端（LSB 在偶地址 0x80+2i）、0.25°C/LSB，MSB 高 4 位恒 0；
--      热敏电阻 0x0E/0x0F 同构 12 位补码小端、0.0625°C/LSB。
--   2) RST 0x01 是命令寄存器、写值不落盘：0x3F=初始复位（全部寄存器/数据区
--      回 POR、帧计时重启，驱动 build 写后实睡 5ms），0x30=标志复位（只清
--      中断标志/中断表，本模型计数留痕，不动数据与配置）。
--   3) PCTL 0x00：0x00=normal 持续出帧，0x10=sleep（0x20/0x21 stand-by 同样
--      不采样）；FPSC 0x02 bit0 帧率（0=10Hz 周期 100ms / 1=1Hz 周期 1000ms，
--      POR 10Hz）。normal 下首帧在一个帧周期后就绪——驱动 build 不查就绪位，
--      靠 milli_sleep 等 120ms/1020ms；模型用 advance(ms) 推帧门（测试的
--      milli_sleep 桩转调它），帧到点只装载显式排队的注入帧、无注入则像素
--      保持上一帧（POR 全 0）——模型没有"场景"概念，绝不自造测量值。
--   4) virt_tick 供守护逐拍造数：确定性移动热点热图（背景 25°C + 高斯式
--      线性衰减热点，32 拍周期绕中心旋转）直接装入像素寄存器、绕过帧门，
--      守护 build 前的 virt_tick(0) 即预武装，build 睡醒 call 必有数据、
--      零额外等待。
--   5) 无 ID 寄存器（build 靠固定序列初始化，不做在位甄别）；像素阈值中断
--      组（0x08~0x0D + 中断表）真实驱动不访问，照存照读 0、不实现。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。

local M = {}
M._VERSION = "0.1.0"

-- ==================== 寄存器地址 ====================
local REG_PCTL, REG_RST, REG_FPSC, REG_INTC = 0x00, 0x01, 0x02, 0x03
local REG_THERM_L, REG_THERM_H = 0x0E, 0x0F
local REG_DATA = 0x80			-- 64 像素 ×2B 小端，终于 0xFF

local NORMAL_MODE   = 0x00
local INITIAL_RESET = 0x3F
local FLAG_RESET    = 0x30

local PIXEL_COUNT = 64
local PERIOD_10HZ, PERIOD_1HZ = 100, 1000

-- virt_tick 确定性热图（32 拍周期）：25°C 背景 + 绕中心旋转的移动热点
local TICK_BG     = 25			-- 背景温度 °C
local TICK_PEAK   = 20			-- 热点中心升温幅度 °C（中心约 45°C）
local TICK_RADIUS = 3.0			-- 线性衰减系数（dist2/RADIUS 扣分）
local TICK_THERM_BASE, TICK_THERM_AMP = 30, 2

local function clamp12(v)
	v = math.floor(tonumber(v) or 0)
	if v < -2048 then return -2048 elseif v > 2047 then return 2047 else return v end
end

-- 12 位补码解码（驱动同式：(hi%0x10)*256+lo 再判负）
local function s12(u)
	u = u % 0x1000
	if u >= 0x800 then u = u - 0x1000 end
	return u
end

-- 确定性热图：返回 64 个温度码（0.25°C/LSB）+ 热敏电阻温度码（0.0625°C/LSB）
local function wave(n)
	n = math.floor(tonumber(n) or 0) % 32
	local ph = 2 * math.pi * n / 32
	local hr = 3.5 + 2.5 * math.sin(ph)		-- 热点中心行（约 1.0~6.0）
	local hc = 3.5 + 2.5 * math.cos(ph)		-- 热点中心列
	local px = {}
	for i = 0, PIXEL_COUNT - 1 do
		local r, c = math.floor(i / 8), i % 8
		local d2 = (r - hr) * (r - hr) + (c - hc) * (c - hc)
		local lift = TICK_PEAK - d2 / TICK_RADIUS
		if lift < 0 then lift = 0 end
		px[i] = math.floor((TICK_BG + lift) * 4 + 0.5)
	end
	local therm = math.floor((TICK_THERM_BASE + TICK_THERM_AMP * math.sin(ph)) * 16 + 0.5)
	return px, therm
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 字节寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此起 burst）
	local remaining = nil		-- 距下一帧的 ms（nil=sleep/不采样）
	local frame_count = 0		-- normal 下已产出的帧事件数
	local reset_count = 0		-- 初始复位（写 RST=0x3F）次数
	local flag_count = 0		-- 标志复位（写 RST=0x30）次数
	local frame_queue = {}		-- 帧事件注入队列（advance 到点按序装载，先于"保持上一帧"）

	-- 故障钩子（硬件 RESET 保留，clear_faults/d:reset 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- 派生 ----------------

	local function fps_1hz() return regs[REG_FPSC] % 2 == 1 end
	local function period_ms() return fps_1hz() and PERIOD_1HZ or PERIOD_10HZ end
	-- PCTL 仅 0x00=normal；0x10 sleep / 0x20·0x21 stand-by 均不采样
	local function active() return regs[REG_PCTL] == NORMAL_MODE end

	-- ---------------- 数据区编码 / 帧事件 ----------------

	local function load_pixel(i, raw)
		raw = clamp12(raw)
		local u = raw % 0x1000
		local base = REG_DATA + (i % PIXEL_COUNT) * 2
		regs[base] = u % 256				-- LSB 偶地址
		regs[base + 1] = math.floor(u / 256)	-- MSB 高 4 位恒 0
	end

	local function load_therm(raw)
		raw = clamp12(raw)
		local u = raw % 0x1000
		regs[REG_THERM_L] = u % 256
		regs[REG_THERM_H] = math.floor(u / 256)
	end

	local function load_frame(list)
		if type(list) ~= "table" then return end
		for i = 0, PIXEL_COUNT - 1 do
			if list[i] ~= nil then load_pixel(i, list[i]) end
		end
	end

	-- 帧到点：排队注入优先；无注入则像素保持上一帧（无场景概念，POR 为全 0）
	local function produce_frame()
		local q = table.remove(frame_queue, 1)
		if type(q) == "table" then load_frame(q) end
		frame_count = frame_count + 1
	end

	-- ---------------- POR / 初始复位 ----------------

	local function seed_regs()
		regs = {}
		regs[REG_PCTL] = 0x00		-- POR 即 normal
		regs[REG_FPSC] = 0x00		-- 10Hz
		regs[REG_INTC] = 0x00
		-- 0x04~0xFF 全部缺省 0（含热敏电阻与像素数据区）
		for a = 0x04, 0xFF do regs[a] = 0 end
	end

	-- RST=0x3F：全部寄存器/数据区回 POR、帧计时重启；
	-- 注入队列/故障钩子保留（硬件复位不清激励、防负路径假解除）
	local function reseed()
		seed_regs()
		read_ptr = nil
		remaining = period_ms()
		frame_count = 0
	end

	seed_regs()
	remaining = PERIOD_10HZ			-- POR normal：首帧一个 10Hz 周期后就绪

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）
			if bytes[1] > 0xFF then return false end
			read_ptr = bytes[1]
			return true
		end
		local reg = bytes[1]
		if reg > 0xFF then return false end
		local val = bytes[2] % 256
		if reg == REG_RST then
			-- 命令寄存器：值不落盘
			if val == INITIAL_RESET then
				reseed()
				reset_count = reset_count + 1
			elseif val == FLAG_RESET then
				flag_count = flag_count + 1	-- 中断标志/表本模型恒 0，只计数
			end
			return true
		end
		if reg == REG_PCTL then
			regs[REG_PCTL] = val
			-- normal 重新计时首帧；sleep/stand-by 停转
			remaining = active() and period_ms() or nil
			return true
		end
		if reg == REG_FPSC then
			regs[REG_FPSC] = val % 2	-- 仅 bit0 有效
			if active() then remaining = period_ms() end
			return true
		end
		-- 其余 burst 落盘：只读数据区（0x0E/0x0F、0x80+）写忽略但 ACK，
		-- 测量值只能由注入 API 改变，避免总线写污染造数
		for i = 2, nb do
			local a = (reg + i - 2) % 256
			if a ~= REG_THERM_L and a ~= REG_THERM_H and a < REG_DATA then
				regs[a] = bytes[i] % 256
			end
		end
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_ptr == nil then return nil end	-- 无指针纯读：NACK
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		local t = {}
		for i = 1, n do
			t[i] = regs[read_ptr] or 0
			read_ptr = (read_ptr + 1) % 256		-- burst 自增、0xFF 回绕
		end
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 单像素：原始码（-2048..2047，0.25°C/LSB）/ 摄氏度
	function d:set_pixel_raw(i, raw)
		load_pixel(math.floor(tonumber(i) or 0), raw)
		return self
	end
	function d:set_pixel_c(i, c)
		load_pixel(math.floor(i) or 0, math.floor((tonumber(c) or 0) * 4 + 0.5))
		return self
	end

	-- 整帧 64 像素：0 基表（list[0..63]）
	function d:set_frame_raw(list) load_frame(list); return self end
	function d:set_frame_c(list)
		if type(list) == "table" then
			local codes = {}
			for i = 0, PIXEL_COUNT - 1 do
				if list[i] ~= nil then codes[i] = math.floor(list[i] * 4 + 0.5) end
			end
			load_frame(codes)
		end
		return self
	end

	-- 帧事件注入：advance 到下一个帧边界时装载（先于"保持上一帧"）
	function d:queue_frame_raw(list)
		if type(list) == "table" then frame_queue[#frame_queue + 1] = list end
		return self
	end
	function d:queue_frame_c(list)
		if type(list) ~= "table" then return self end
		local codes = {}
		for i = 0, PIXEL_COUNT - 1 do
			if list[i] ~= nil then codes[i] = math.floor(list[i] * 4 + 0.5) end
		end
		frame_queue[#frame_queue + 1] = codes
		return self
	end

	-- 热敏电阻：原始码（0.0625°C/LSB）/ 摄氏度
	function d:set_therm_raw(v) load_therm(v); return self end
	function d:set_therm_c(c)
		load_therm(math.floor((tonumber(c) or 0) * 16 + 0.5))
		return self
	end

	function d:clear_frame()
		for a = REG_DATA, 0xFF do regs[a] = 0 end
		return self
	end

	-- 推虚拟时钟：normal 下按帧周期产帧（可一次跨多拍）
	function d:advance(ms)
		ms = tonumber(ms) or 0
		if active() and remaining ~= nil then
			remaining = remaining - ms
			while remaining <= 0 do
				produce_frame()
				remaining = remaining + period_ms()
			end
		end
		return self
	end

	-- 守护逐拍造数：移动热点热图直接装入数据寄存器（不经帧门），
	-- build 前 virt_tick(0) 即预武装，call 恒有新鲜数据、零真实睡眠
	function d:virt_tick(n)
		local px, therm = wave(n)
		load_frame(px)
		load_therm(therm)
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		return self
	end

	function d:reset_logs()
		frame_count, reset_count, flag_count = 0, 0, 0
		return self
	end

	-- 重新上电：全状态回 POR（含注入队列）；故障钩子保留
	function d:reset()
		frame_queue = {}
		seed_regs()
		read_ptr = nil
		remaining = PERIOD_10HZ
		frame_count, reset_count, flag_count = 0, 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:pixel_raw(i)
		local base = REG_DATA + (math.floor(tonumber(i) or 0) % PIXEL_COUNT) * 2
		return s12((regs[base + 1] or 0) * 256 + (regs[base] or 0))
	end
	function d:pixel_c(i) return d:pixel_raw(i) * 0.25 end
	function d:therm_raw()
		return s12((regs[REG_THERM_H] or 0) * 256 + (regs[REG_THERM_L] or 0))
	end
	function d:therm_c() return d:therm_raw() * 0.0625 end
	function d:ptr() return read_ptr end
	function d:fps_1hz() return fps_1hz() end
	function d:is_active() return active() end
	function d:period_ms() return active() and period_ms() or nil end
	function d:remaining_ms() return remaining end
	function d:frame_count() return frame_count end
	function d:reset_count() return reset_count end
	function d:flag_reset_count() return flag_count end
	function d:queue_len() return #frame_queue end
	function d:reg(a) return regs[math.floor(tonumber(a) or 0) % 256] or 0 end

	return d
end

return M

-- modules/lib/virtbus/ms5611.lua —— MS5611-01BA03 高分辨率气压计虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个「单字节命令里编码通道+OSR 档位」+「指针读 PROM/ADC」+
-- PROM 出厂校准 CRC-4 校验的命令式 I2C 器件】——无寄存器地图，但读访问
-- 是「写 1 字节指针命令 + 读 N 字节」（驱动用 i2c_read_multi，virtbus
-- 复刻为指针写事务+纯读两步），与 regmap 指针器件的区别是 PROM/ADC
-- 不是可寻址寄存器而是命令对象：
--   0x1E              软复位（PROM 重载，真机 <=2.8ms）
--   0xA0+2i (i=0..7)  指针：下一次 2B 读返回 PROM word i（word0 出厂数据、
--                      word1~6 = C1~C6、word7 = CRC-4 位域 + 12 位序列号）
--   0x00              指针：下一次 3B 读返回 24 位 ADC 结果
--   0x40+2i / 0x50+2i 单字节命令：启动 D1 气压 / D2 温度转换，i=0..4 对应
--                      OSR 256~4096（偶数才合法，奇数/越界 NACK）
-- 与同族对照：SHT3X 是 2 字节命令字+每字 CRC-8；MS5611 是 1 字节命令且
-- 数据帧本身无 CRC（校验只在出厂 PROM，且为 4 位 nibble CRC）。
--
-- 只复刻协议层事实（TE MS5611 datasheet，以真实驱动 modules/MS5611.lua
-- 实际访问为准）：
--   1) 转换门用 datasheet 最大转换时间（0.60/1.17/2.28/4.54/9.04ms，
--      驱动取整等待表 1/2/3/5/10ms 留余量）；advance(ms) 推进，转换未
--      完成时 ADC 读 NACK（真机转换期间不响应）；oneshot 结果保持到下
--      一条转换命令（ADC 重读不消费）；必须先发转换命令 ADC 才有数。
--   2) PROM 8 字随时可读（与转换态无关）；每次读都要先写指针（读后指针
--      自动失效，贴合真机「每次读重发命令」）；长度必须匹配（PROM 2B、
--      ADC 3B），无前置指针的纯读 NACK。
--   3) PROM 种子 CRC-4 自洽（多项式 0x3000，CRC 位域参与自身运算，
--      word7 仅清低字节——与驱动同款布局，模型自带 nibble 计算并公开，
--      测试另有独立实现三方交叉）。
--   4) 补偿解算（一阶/二阶）是驱动侧算法，模型【不抄】：只存 24 位
--      D1/D2 原始码与 PROM 系数；set_pt(p_hpa,t_c) 仅供守护/E2E 按
--      暖机一阶逆模型造物理量样本（温度在 20°C 附近，二阶不触发）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：用 bitcompat。

local M = {}
M._VERSION = "0.1.0"

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- datasheet 最大转换时间 ms（OSR 256/512/1024/2048/4096）
local T_MAX = { [0] = 0.60, [1] = 1.17, [2] = 2.28, [3] = 4.54, [4] = 9.04 }

-- 出厂种子：接近真实器件量级的系数（datasheet 一阶算例同款，旧桩沿用）
local SEED_WORD0 = 0x06A4
local SEED_COEFF = { 40127, 36924, 23317, 23282, 33464, 31471 }	-- C1~C6
local SEED_SERIAL = 0x321										-- word7 低 12 位

-- PROM CRC-4（TE 官方/PX4 同款；prom[1..8]，word8 未屏蔽）。
-- 返回 (算出的 nibble, word8 中存储的 nibble)。
local function crc4_nibbles(prom)
	local n_prom = {}
	for i = 1, 8 do n_prom[i] = prom[i] % 65536 end
	local crc_read = math.floor(n_prom[8] / 4096) % 16
	n_prom[8] = bitc.band(n_prom[8], 0xFF00)	-- word7 仅清低字节（CRC 位域保留）
	local n_rem = 0
	for cnt = 0, 15 do
		local w = n_prom[math.floor(cnt / 2) + 1]
		if cnt % 2 == 1 then
			n_rem = bitc.bxor(n_rem, w % 256)			-- 低字节
		else
			n_rem = bitc.bxor(n_rem, math.floor(w / 256))	-- 高字节
		end
		for _ = 1, 8 do
			if bitc.band(n_rem, 0x8000) ~= 0 then
				n_rem = bitc.bxor(bitc.band(n_rem * 2, 0xFFFF), 0x3000)
			else
				n_rem = bitc.band(n_rem * 2, 0xFFFF)
			end
		end
	end
	return math.floor((n_rem % 65536) / 4096) % 16, crc_read
end

-- 公开：给定 prom8 返回 CRC 是否自洽（测试自证/三方交叉用）
function M.crc4_ok(prom)
	local got, stored = crc4_nibbles(prom)
	return got == stored, got, stored
end

local function clamp24(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 0xFFFFFF then return 0xFFFFFF else return v end
end

function M.new()
	local d = {}

	-- 芯片侧状态
	local prom = {}
	local d1, d2 = 9085466, 8569156	-- 暖机 ~1000hPa / ~20.5°C 种子
	local pending				-- 'd1' | 'd2'：最近一次转换命令（结果保持）
	local remaining				-- 当前转换剩余 ms（nil=完成/无转换）
	local read_target			-- nil | 'adc' | 'prom'
	local prom_idx
	local armed					-- virt_tick 预武装：转换命令即时就绪
	local cmds = {}				-- 识别的命令/指针写序列（全部 1 字节写）

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local cmd_pred, read_pred
	local prom_bad = false

	local function seed_prom()
		prom = { [1] = SEED_WORD0 }
		for i = 1, 6 do prom[i + 1] = SEED_COEFF[i] end
		-- word7 = CRC 位域（参与自身运算，逐一试探合法 nibble）+ 序列号
		for nib = 0, 15 do
			prom[8] = nib * 4096 + SEED_SERIAL
			if M.crc4_ok(prom) then break end
		end
	end

	local function start_conversion(kind, oi)
		pending = kind
		cmds[#cmds + 1] = (kind == "d1") and (0x40 + 2 * oi) or (0x50 + 2 * oi)
		-- 注意不能用 `armed and nil or T_MAX[oi]`：and 链中 nil 为假会落到 or 分支
		if armed then remaining = nil else remaining = T_MAX[oi] end
		read_target = nil
	end

	seed_prom()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes ~= 1 then return false end
		if d.nack or d.nack_write then return false end
		local b = bytes[1]
		if cmd_pred and cmd_pred(b) then return false end

		if b == 0x1E then
			-- 软复位：PROM 重载、转换/指针状态清空
			seed_prom()
			pending, remaining, read_target, prom_idx = nil, nil, nil, nil
			cmds[#cmds + 1] = b
			return true
		end
		-- 转换命令：D1 0x40~0x48 / D2 0x50~0x58，仅偶数（0x4A 等保留码 NACK）
		if (b >= 0x40 and b <= 0x48 and b % 2 == 0)
			or (b >= 0x50 and b <= 0x58 and b % 2 == 0) then
			local kind = (b < 0x50) and "d1" or "d2"
			local base = (kind == "d1") and 0x40 or 0x50
			start_conversion(kind, (b - base) / 2)
			return true
		end
		-- ADC 指针
		if b == 0x00 then
			read_target, prom_idx = "adc", nil
			return true
		end
		-- PROM 指针：0xA0~0xAE，仅偶数
		if b >= 0xA0 and b <= 0xAE and b % 2 == 0 then
			read_target, prom_idx = "prom", (b - 0xA0) / 2 + 1
			return true
		end
		-- 未定义命令/奇数地址：NACK
		return false
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 0)
		if read_pred and read_pred(read_target, n, prom_idx) then return nil end
		if read_target == "prom" then
			if n ~= 2 then return nil end
			local w = prom[prom_idx]
			-- corrupt 只改 word7 的 CRC 位域（系数不动，专打 build CRC 校验）
			if prom_bad and prom_idx == 8 then
				local _, stored = crc4_nibbles(prom)
				w = ((stored + 1) % 16) * 4096 + (prom[8] % 4096)
			end
			read_target = nil
			return { math.floor(w / 256) % 256, w % 256 }
		elseif read_target == "adc" then
			if n ~= 3 then return nil end
			if pending == nil or remaining ~= nil then
				-- 未启动转换 / 转换仍在进行：NACK（读后不清除指针语义无意义）
				return nil
			end
			local v = (pending == "d2") and d2 or d1
			-- oneshot：结果保持到下一条转换命令；指针读后失效（需重发 0x00）
			read_target = nil
			return { math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256 }
		end
		-- 无前置指针的纯读：NACK
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining = nil end
		end
		return self
	end

	-- 注入 24 位原始码（模型不做补偿，换算公式归驱动）
	function d:set_d1(v) d1 = clamp24(v); return self end
	function d:set_d2(v) d2 = clamp24(v); return self end

	-- 物理量注入（暖机一阶逆模型，仅供守护/E2E；要求 T 在 20°C 附近，
	-- 二阶不触发，与驱动正算闭环误差 <0.01hPa / <0.01°C）
	function d:set_pt(p_hpa, t_c)
		local c1, c2, c3, c4, c5, c6 = prom[2], prom[3], prom[4], prom[5], prom[6], prom[7]
		local dt = math.floor((t_c * 100 - 2000) * 8388608 / c6 + 0.5)
		local d2v = c5 * 256 + dt
		local off = c2 * 65536 + math.floor(c4 * dt / 128)
		local sens = c1 * 32768 + math.floor(c3 * dt / 256)
		local p_cbar = math.floor(p_hpa * 100 + 0.5)		-- 0.01 mbar 单位
		local d1v = math.floor(((p_cbar * 32768 + off) * 2097152) / sens + 0.5)
		d1, d2 = clamp24(d1v), clamp24(d2v)
		return self
	end

	function d:fail_cmd(pred) cmd_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_prom(on) prom_bad = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		cmd_pred, read_pred, prom_bad = nil, nil, false
		return self
	end

	function d:reset_logs() cmds = {}; return self end

	-- 上电/软复位：PROM reseed、转换态清空；故障钩子保留（防负路径假解除）
	function d:reset()
		seed_prom()
		d1, d2 = 9085466, 8569156
		pending, remaining, read_target, prom_idx = nil, nil, nil, nil
		armed = false
		cmds = {}
		return self
	end

	-- 守护逐拍造数：气压 1013.25±5 hPa、温度 22±2°C（32 拍周期，均在
	-- 暖机段二阶不触发）；并预武装——守护不驱动 advance，call 内两段
	-- 转换命令（D1/D2）下发即就绪，真实 milli_sleep 仅作节拍余量。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_pt(1013.25 + 5 * math.sin(ph), 22 + 2 * math.sin(ph))
		armed = true
		pending, remaining = nil, nil
		return self
	end

	-- 只读观察口
	function d:prom_word(i) return prom[i] end
	function d:prom_table()
		local t = {}
		for i = 1, 8 do t[i] = prom[i] end
		return t
	end
	function d:crc_is_valid() return M.crc4_ok(prom) end
	function d:pending() return pending end
	function d:remaining_ms() return remaining end
	function d:read_target() return read_target end
	function d:is_armed() return armed end
	function d:d1() return d1 end
	function d:d2() return d2 end
	function d:cmd_count() return #cmds end
	function d:cmd_log() return cmds end

	return d
end

return M

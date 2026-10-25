-- modules/lib/virtbus/vl53l4cd.lua —— VL53L4CD ToF 激光测距虚拟器件模型
-- bot4cj 虚拟总线器件库（无 BUS 字段 = I2C，attach 动态委托 dev.write/dev.read）
--
-- 定位：【首个 16 位寄存器指针（regmap ptr16）真实器件】——与同系列
-- VL53L0X（8 位指针 + 0xFF 分页）刻意对照：VL53L4CD 寄存器窗直接用
-- 16 位地址线性寻址（0x0000~0x00FF），指针事务为 2 字节大端地址，
-- 多字节写按地址自增（91 字节默认配置流就是一笔 0x002D 起的流写）。
-- 底座用 regmap.new(init, {ptr16=true})，本文件用包装法（链接原
-- write/read 后覆盖同表字段）加器件状态机，保留 regmap 全部能力。
--
-- 只复刻协议层事实（ST ULD vl53l4cd_api，以真实驱动 modules/VL53L4CD.lua
-- 的实际访问为准）：
--   1) 软复位：0x0000 写 0x00 保持 / 写 0x01 释放——释放后器件寄存器
--      回到上电种子（振荡器频率 0x0006=10000、PLL 校准 0x00DE=512、
--      固件状态 0x00E5=3），芯片侧状态全新（启动序列/清中断计数清零）。
--   2) data-ready 极性链：0x0030 bit4 决定有效极性 int_pol（bit4=1→0，
--      否则→1），0x0031 bit0 == int_pol 即就绪（驱动 check_data_ready）。
--      模型动态合成 0x0031 bit0（bit1 保留位读 1），极性随 0x0030 翻转
--      自动跟随；never_ready 钩子强制反极性电平。
--   3) 测量状态机：0x0087 写 0x40（VHV 预热/自主）或 0x21（连续）启动，
--      写 0x00 停；启动即预武装一帧（skill 惯例：守护不驱动 milli_sleep，
--      build 的 VHV/首测量自检首次轮询必须直接就绪）。0x0086=0x01 清中断：
--      运行态下解除武装并进入 5ms 转换倒计时，advance(ms) 虚拟时钟推进
--      （测试 milli_sleep 桩转调；连续两拍 call 之间自然走完倒计时）。
--   4) 结果块固定地址（各为独立原子读，非 burst）：0x0089 状态原始码
--      （&0x1F 查 STATUS_RTN）、0x008C SPAD word(/256)、0x008E 信号率
--      word(×8 kcps)、0x0090 环境光率、0x0092 sigma(/4 mm)、0x0096
--      距离 word（mm）。inject_result 按字节宽度写入，不抄驱动换算。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local regmap = dofile(mpath.resolve("lib/virtbus/regmap.lua"))

local M = {}

local CONV_MS = 5	-- 清中断到下一帧就绪的虚拟转换时间

-- 上电种子（释放软复位后同样回到这组值）
local function seed_table()
	return {
		[0x0006] = 0x27, [0x0007] = 0x10,	-- OSC_FREQUENCY word = 10000
		[0x00DE] = 0x02, [0x00DF] = 0x00,	-- OSC_CALIBRATE word = 512
		[0x00E5] = 0x03,					-- 固件就绪
	}
end

function M.new()
	local base = regmap.new(seed_table(), { ptr16 = true })

	-- 芯片侧状态
	local running = false		-- 0x0087 启动后处于测距态
	local armed = true			-- 上电/启动即有一帧（预武装）
	local countdown = 0			-- 清中断后的转换剩余 ms
	local start_log = {}		-- 写入 0x0087 的值序列（软复位清零）
	local clear_count = 0		-- 0x0086=0x01 次数（软复位清零）
	local boot_releases = 0		-- 0x0000=0x01 次数（累计，调试用）

	-- 故障钩子（reset 保留，clear_faults 解除）
	local read_pred, write_pred
	local never_ready, boot_stuck = false, false

	local self = {}
	-- 注意：浅拷贝后 self.nack 与底座 m.nack 是两个字段，外部置 d.nack
	-- 不会被 old_write 看到，故三个 nack 由包装层自持自判（底座恒不挂故障）。
	for k, v in pairs(base) do self[k] = v end
	self.nack, self.nack_read, self.nack_write = false, false, false
	local old_write, old_read = base.write, base.read

	-- 把一笔失败写也留进 regmap write_log（与 nack 路径先 log 后拒一致）
	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] end
		base.write_log[#base.write_log + 1] = cp
	end

	local function reseed(boot_value)
		-- 原地清空：包装表 d.regs 与底座共享同一表引用，不能换表
		-- （否则 d:set_word 走 self.regs 会写到复位前的旧表）
		for k in pairs(base.regs) do base.regs[k] = nil end
		for k, v in pairs(seed_table()) do base.regs[k] = v end
		base.ptr = 0
		if boot_value then base.regs[0x00E5] = boot_value end
		start_log = {}
		clear_count = 0
		running, armed, countdown = false, false, 0
	end

	-- ---- 总线写：包装层先判故障并留痕，通过后走 regmap（ptr16 存储） ----
	self.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if self.nack or self.nack_write or (write_pred and write_pred(bytes)) then
			log_copy(bytes)
			return false
		end
		local ok = old_write(bytes)
		if not ok then return false end

		if #bytes >= 3 then
			local p = (bytes[1] % 256) * 256 + (bytes[2] % 256)
			local v = bytes[3] % 256
			if p == 0x0000 then
				if v == 0x01 then
					-- 释放复位：芯片全新启动（固件状态看 stuck 钩子）
					boot_releases = boot_releases + 1
					reseed(boot_stuck and 0x00 or 0x03)
				end
				-- v==0x00 复位保持：无副作用（驱动只要求写成功）
			elseif p == 0x0087 then
				start_log[#start_log + 1] = v
				if v == 0x40 or v == 0x21 then
					-- 启动：预武装一帧（build 自检/守护首次轮询即就绪）
					running, armed, countdown = true, true, 0
				elseif v == 0x00 then
					running, armed, countdown = false, false, 0
				end
			elseif p == 0x0086 and v == 0x01 then
				clear_count = clear_count + 1
				-- 结果寄存器锁存到下一次清中断；运行态重新走转换倒计时
				if running then armed, countdown = false, CONV_MS end
			end
		end
		return true
	end

	-- ---- 总线读：包装层先判故障，通过后走 regmap（ptr16 burst）+合成就绪位 ----
	self.read = function(n)
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 end
		local p0 = base.ptr	-- old_read 会推进指针，先存首地址
		if self.nack or self.nack_read or (read_pred and read_pred(p0, n)) then
			return nil
		end
		local t = old_read(n)
		if t and p0 == 0x0031 then
			local mux = base.regs[0x0030] or 0
			local int_pol = (math.floor(mux / 16) % 2 == 1) and 0 or 1
			local lvl = (armed and not never_ready) and int_pol or (1 - int_pol)
			t[1] = 0x02 + lvl	-- bit1 保留位读 1，bit0 为合成就绪电平
		end
		return t
	end

	-- ---- 虚拟时钟：推进转换倒计时 ----
	function self:advance(ms)
		ms = tonumber(ms) or 0
		if running and not armed and not never_ready then
			countdown = countdown - ms
			if countdown <= 0 then armed = true end
		end
		return self
	end

	-- ---- 结果块注入（固定地址，字节宽度编码；换算不进模型） ----
	function self:inject_result(t)
		t = t or {}
		base:set(0x0089, t.st or 0x09)						-- 原始状态码
		self:set_word(0x008C, t.spad or 0x0200)				-- word /256 = SPAD 数
		self:set_word(0x008E, t.signal or 0x0064)			-- word ×8 = kcps
		self:set_word(0x0090, t.ambient or 0x0032)
		self:set_word(0x0092, t.sigma or 0x0008)			-- word /4 = mm
		self:set_word(0x0096, t.dist or 300)				-- word mm
		return self
	end

	-- ---- 守护造样本：32 拍确定性正弦 100~1100mm，预武装触发即就绪 ----
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local dist = 100 + math.floor((math.sin(2 * math.pi * n / 32) * 0.5 + 0.5) * 1000 + 0.5)
		self:inject_result({ st = 0x09, spad = 0x0200, signal = 0x0064,
			ambient = 0x0032, sigma = 0x0008, dist = dist })
		if running then armed, countdown = true, 0 end
		return self
	end

	-- ---- 状态/留痕访问 ----
	function self:running() return running end
	function self:armed() return armed end
	function self:start_writes() return start_log end
	function self:clear_count() return clear_count end
	function self:boot_releases() return boot_releases end

	-- ---- 故障钩子 ----
	function self:fail_read(pred) read_pred = pred; return self end
	function self:fail_write(pred) write_pred = pred; return self end
	function self:set_never_ready(on) never_ready = on and true or false; return self end
	function self:set_boot_stuck(on)
		boot_stuck = on and true or false
		base.regs[0x00E5] = boot_stuck and 0x00 or 0x03
		return self
	end
	-- 直接置固件状态值（异常构造，如停在 1/2）
	function self:set_boot_status(v) base.regs[0x00E5] = math.floor(v) % 256; return self end

	function self:clear_faults()
		self.nack, self.nack_read, self.nack_write = false, false, false
		read_pred, write_pred = nil, nil
		never_ready, boot_stuck = false, false
		return self
	end

	function self:reset_logs()
		base:clear_log()
		return self
	end

	-- 换新器件：寄存器/状态/日志全清；故障钩子保留（ads1256/vl53l0x 惯例）
	function self:reset()
		base:clear_log()
		reseed(boot_stuck and 0x00 or 0x03)
		return self
	end

	return self
end

return M

-- bh1750.lua —— BH1750 环境光传感器虚拟器件模型
-- bot4cj 虚拟硬件库（modules/lib/virtbus/，配合 modules/lib/virtbus.lua 使用）
--
-- BH1750 是命令式器件（单字节 opcode，无寄存器指针；测量值从总线纯读 2 字节），
-- 与 regmap 的寄存器形态不同，故单独建模。协议事实与 modules/BH1750.lua 驱动
-- 同源（ROHM 手册）：
--   0x00 PowerDown   0x01 PowerOn
--   0x10/0x11/0x13  连续 H / H2 / L
--   0x20/0x21/0x23  单次 H / H2 / L
--   0x40|x / 0x60|x MTreg 高低字节（本模型记录但不改变测量时序）
--   测量结果 = 2 字节大端 count（驱动换算 LUX = count * lsb * 69 / (1.2 * mtreg)）
--
-- 用法：
--   local bhmod = dofile("modules/lib/virtbus/bh1750.lua")
--   local light = bhmod.new({ count = 30000 })   -- 30000 counts，H 档 → 25000 lux
--   vbus.attach("bh1750@0x23", 0x23, light)
--
--   light:set_count(1234)   -- 用例动态设置读数
--   light.cmds              -- 收到的单字节命令序列（断言 build/destroy 行为）
--   light.nack = true       -- 故障注入：模拟器件掉线（写 false / 读 nil）
--   light.state             -- {power=, mode=, once=} 命令解释后的粗状态

local bh1750 = {}
bh1750._VERSION = "0.1.0"

-- opcode → 状态解释（仅记录协议层事实）
local function interpret(state, cmd)
	if cmd == 0x00 then
		state.power = false
	elseif cmd == 0x01 then
		state.power = true
	elseif cmd == 0x10 or cmd == 0x20 then
		state.power, state.mode, state.once = true, "H", cmd == 0x20
	elseif cmd == 0x11 or cmd == 0x21 then
		state.power, state.mode, state.once = true, "H2", cmd == 0x21
	elseif cmd == 0x13 or cmd == 0x23 then
		state.power, state.mode, state.once = true, "L", cmd == 0x23
	end
	-- 0x40..0x7F 段为 MTreg 命令对，不属于测量模式，状态不变
end

function bh1750.new(opts)
	opts = opts or {}
	local m = {}
	m.count = opts.count or 0	-- 当前测量计数值（0~65535，大端双字节读回）
	m.nack = false
	m.cmds = {}					-- 收到的单字节命令序列（MTreg 等多字节写不入此列）
	m.last_cmd = nil
	m.state = { power = false, mode = nil, once = false }

	-- virtbus 设备接口（点定义闭包，总线无 self 调用）
	function m.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if m.nack then return false end
		if #bytes == 1 then
			local cmd = bytes[1]
			m.cmds[#m.cmds + 1] = cmd
			m.last_cmd = cmd
			interpret(m.state, cmd)
		end
		-- 单字节以外的写事务 BH1750 协议不存在（MTreg 也是单字节命令对），
		-- 模型不报错：真实器件对非法写静默忽略，保持与真机一致的宽松度
		return true
	end

	function m.read(n)
		if m.nack then return nil end
		local c = math.floor(tonumber(m.count) or 0) % 65536
		local t = { math.floor(c / 256) % 256, c % 256 }
		-- 驱动固定读 2 字节；按请求长度截断/补零，行为对调用方可见
		n = math.floor(tonumber(n) or 2)
		if n < 1 then n = 1 end
		local out = {}
		for i = 1, n do out[i] = t[i] or 0 end
		return out
	end

	-- ---------------- 测试辅助 ----------------

	function m:set_count(c)
		self.count = c
		return self
	end

	function m:clear_cmds()
		self.cmds = {}
		return self
	end

	function m:reset(new_count)
		self.count = new_count or 0
		self.nack = false
		self.cmds = {}
		self.last_cmd = nil
		self.state = { power = false, mode = nil, once = false }
		return self
	end

	return m
end

return bh1750

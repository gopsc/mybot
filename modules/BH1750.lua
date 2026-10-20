-- BH1750 环境光传感器（I2C，数字光照强度）驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BH1750_VIRT（2026-09-15 自 modules/lib/virtbus/bh1750.lua
-- 迁入，单文件驱动+模型实验第二个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 特点：
--   - 二线命令式协议：指令为单字节 opcode（无寄存器指针），
--     测量结果从数据寄存器【纯读】（0x00 是 Power Down 命令，写指针会破坏状态，
--     故不用 i2c_read_multi_bytes，必须走 HAL 的 i2c_read 纯读路径）
--   - 器件无 ID 寄存器可甄别，build 以「上电 + 模式命令写成功」作为在位判定
--   - 连续模式由器件自主刷新，call 每次读当前值（读太频繁只是值滞后）
--   - 地址：ADDR=Low -> 0x23，ADDR=High -> 0x5C（一总线可挂 2 颗）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BH1750 (
--       name    String,
--       I2C     String,
--       address String,
--       mode    String,   -- 可选：H（缺省，连续 1lx/0.5lx sensing）| H2 | L
--       once    String,   -- 可选：1 = 单次测量（每 call 发命令+等待），缺省连续
--       mtreg   String    -- 可选：测量时间/灵敏度 31~254（缺省 69，越大越灵敏越慢）
--   );
--   INSERT INTO BH1750 (name, I2C, address) VALUES ('light0', 'i2c-1', '0x23');
--
-- call 无需参数，返回 { result, LUX(单位 lux，浮点) }
-- 换算（含 MTreg 归一）：LUX = count x LSB_LUX x 69 / (1.2 x mtreg)
--   mode=H ：LSB=1.0（1lx/LSB，mt=69 时 LUX = count/1.2，一帧约 120ms）
--   mode=H2：LSB=0.5（0.5lx/LSB，LUX = count/2.4）
--   mode=L ：LSB=4.0（4lx/LSB，LUX = count/0.3，一帧约 16ms）
--
-- 接 sensor_daemon：fields=LUX（浮点，勿配 sign）；连续模式下 interval 建议
-- >= 一帧时间（H/H2 约 120ms、L 约 16ms）以求逐帧新值。
--
-- 实现要点（协议与换算经官方罗姆 ROHM 手册 + Adafruit/Claws BH1750 双源互证）：
--   1. 模式命令 0x10/0x11/0x13 连续，0x20/0x21/0x23 单次
--   2. MTreg 设置需连写两字节命令：0x40|(mt>>5)&7 与 0x60|mt&0x1F
--      （先高比特再低比特；MTreg 增大测量时间与灵敏度均按比例提升）
--   3. 返回值最大 65535 counts；H2 档约 27306 lx、H 档约 54612 lx 封顶

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：光照高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令 opcode ====================
local CMD_POWER_DOWN = 0x00		-- 掉电（唤醒需再 Power On）
local CMD_POWER_ON   = 0x01		-- 上电待机
local CMD_CONT_H     = 0x10		-- 连续 H 分辨率（1lx）
local CMD_CONT_H2    = 0x11		-- 连续 H2 分辨率（0.5lx）
local CMD_CONT_L     = 0x13		-- 连续 L 分辨率（4lx）
local CMD_ONCE_H     = 0x20		-- 单次 H
local CMD_ONCE_H2    = 0x21		-- 单次 H2
local CMD_ONCE_L     = 0x23		-- 单次 L
local CMD_MT_HIGH    = 0x40		-- MTreg 高比特基址
local CMD_MT_LOW     = 0x60		-- MTreg 低比特基址

local MTREG_DEFAULT  = 69		-- 出厂测量时间基准
local MTREG_MIN      = 31
local MTREG_MAX      = 254
local FRAME_MS_H     = 120		-- H/H2 一帧（mt=69 时）
local FRAME_MS_L     = 16		-- L 一帧

-- 每档位每 LSB 的 lux 数（换算基准，见头部公式）
local MODE_T = {
	H  = { cont = CMD_CONT_H,  once = CMD_ONCE_H,  lsb = 1.0, frame = FRAME_MS_H },
	H2 = { cont = CMD_CONT_H2, once = CMD_ONCE_H2, lsb = 0.5, frame = FRAME_MS_H },
	L  = { cont = CMD_CONT_L,  once = CMD_ONCE_L,  lsb = 4.0, frame = FRAME_MS_L },
}
local MODE_DEFAULT = "H"

-- ==================== 模块级配置 ====================
local mode_t = MODE_T[MODE_DEFAULT]
local once   = false
local mtreg  = MTREG_DEFAULT

-- 单字节命令写（BH1750 无寄存器指针，opcode 即整帧）
local function send_cmd(fd, cmd)
	return i2c_write_multi(fd, cmd) == 0
end

-- MTreg 测量时间/灵敏度设置：连写高比特 + 低比特两字节命令
local function set_mtreg(fd)
	if mtreg == MTREG_DEFAULT then return true end
	local hi = bitc.bor(CMD_MT_HIGH, math.floor(mtreg / 32) % 8)	-- 0x40|(mt>>5)&7
	local lo = bitc.bor(CMD_MT_LOW,  mtreg % 32)					-- 0x60|mt&0x1F（MT[4:0]）
	return send_cmd(fd, hi) and send_cmd(fd, lo)
end

-- 测量模式命令 + 单帧时间
local function mode_cmd()
	return once and mode_t.once or mode_t.cont
end

require_driver("i2c", {
	name = "BH1750",

	-- ==================== 配置脚本 ====================
	-- 上电 +（可选）MTreg + 测量模式；连续/单次模式均等待一帧让首发有效
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- BH1750 builder func get a table --------", data)
		end

		local fd = ctx.fd

		-- 列参数：mode（H/H2/L）、once（1/0）、mtreg（31~254）
		local m = tostring(data.mode or MODE_DEFAULT):upper()
		if MODE_T[m] == nil then
			return err("Invalid mode '" .. tostring(data.mode) .. "' (H|H2|L)")
		end
		mode_t = MODE_T[m]
		once   = (tostring(data.once) == "1" or tostring(data.once) == "true")

		-- mtreg 非有限回落缺省（drv_common 单点）：`tonumber(..) or MTREG_DEFAULT`
		-- 挡不住 NaN（NaN 是 truthy），两条钳制对 NaN 也全为假 → mtreg=NaN 会让
		-- LUX 换算与等待时长双双变 NaN 且仍返回 result="OK"（2026-09-20 评估）
		mtreg = num_or(data.mtreg, MTREG_DEFAULT)
		if mtreg < MTREG_MIN then mtreg = MTREG_MIN end
		if mtreg > MTREG_MAX then mtreg = MTREG_MAX end

		-- 在位判定：Power On + 模式命令写成功（器件无 ID 寄存器可读）
		if not send_cmd(fd, CMD_POWER_ON) then
			return err("BH1750 not responding (power on failed, check address 0x23/0x5C and wiring)")
		end
		if not set_mtreg(fd) then
			return err("BH1750 not responding (MTreg write failed)")
		end
		if not send_cmd(fd, mode_cmd()) then
			return err("BH1750 not responding (mode command failed)")
		end

		-- 等待一帧（连续模式让首发即时有效；单次模式该命令即本帧）
		milli_sleep(mode_t.frame * mtreg / MTREG_DEFAULT)

		print(string.format("BH1750 init OK: addr=0x%02X mode=%s once=%s mtreg=%d",
			ctx.addr, m, tostring(once), mtreg))
		return {  result = "OK"  }
	end,

	-- ==================== 调用 ====================
	-- 读当前光照（连续模式读最新帧；单次模式发命令 + 等一帧再读）
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- BH1750 caller func get a table --------", data)
		end

		local fd = ctx.fd

		if once then
			if not send_cmd(fd, mode_cmd()) then
				return err("BH1750 not responding (one-shot command failed)")
			end
			milli_sleep(mode_t.frame * mtreg / MTREG_DEFAULT)
		end

		-- 纯读 2 字节（不能用 i2c_read_multi_bytes：写指针 0x00 = Power Down 命令）
		local raw = i2c_read(fd, 2)
		if raw < 0 then
			return err("BH1750 not responding (read measurement failed)")
		end
		local count = raw % 65536

		-- LUX = count x LSB x 69 / (1.2 x mtreg)
		local lux = count * mode_t.lsb * MTREG_DEFAULT / (1.2 * mtreg)

		return {  result = "OK",  LUX = lux  }
	end,

	-- ==================== 销毁 ====================
	-- 发 Power Down 进入最低功耗；失败不致命（返回 OK）
	destroy = function(ctx, data)
		if DEBUG then
			dbg_table("-------- BH1750 ender func get a table --------", data)
		end

		local fd, addr, ek = i2c_pair(data)
		if fd == nil then return ek end

		if not send_cmd(fd, CMD_POWER_DOWN) then
			print("BH1750 destroy: power down write failed (ignored)")
		end

		return {  result = "OK"  }
	end,
})

-- =====================================================================
-- 【内嵌虚拟器件模型】BH1750_VIRT —— 2026-09-15 自 modules/lib/virtbus/bh1750.lua
-- 整体迁入（单文件驱动+模型第二个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同 PCA9685_VIRT：① 生产路径零执行（new() 仅虚拟总线测试调用，本模型
-- 纯闭包无外部依赖）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua
-- 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现（模型自带 opcode 解释/换算基线，不引用上方驱动
-- 局部量），互证防假绿性质不变。
--
-- BH1750 是命令式器件（单字节 opcode，无寄存器指针；测量值从总线纯读 2 字节），
-- 与 regmap 的寄存器形态不同，故单独建模。协议事实（ROHM 手册）：
--   0x00 PowerDown   0x01 PowerOn
--   0x10/0x11/0x13  连续 H / H2 / L
--   0x20/0x21/0x23  单次 H / H2 / L
--   0x40|x / 0x60|x MTreg 高低字节（本模型记录但不改变测量时序）
--   测量结果 = 2 字节大端 count（驱动换算 LUX = count * lsb * 69 / (1.2 * mtreg)）
--
-- 用法：
--   vbus.load_driver("modules/BH1750.lua")     -- 定义全局 build/call/destroy 与 BH1750_VIRT
--   local light = BH1750_VIRT.new({ count = 30000 })  -- 30000 counts，H 档 → 25000 lux
--   vbus.attach("bh1750@0x23", 0x23, light)
--
--   light:set_count(1234)   -- 用例动态设置读数
--   light.cmds              -- 收到的单字节命令序列（断言 build/destroy 行为）
--   light.nack = true       -- 故障注入：模拟器件掉线（写 false / 读 nil）
--   light.state             -- {power=, mode=, once=} 命令解释后的粗状态
-- =====================================================================

BH1750_VIRT = { _VERSION = "0.1.0" }

-- opcode → 状态解释（仅记录协议层事实）
local function bh1750_interpret(state, cmd)
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

function BH1750_VIRT.new(opts)
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
			bh1750_interpret(m.state, cmd)
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

	-- ---------------- 守护仿真节拍（proto=virt） ----------------
	-- 32 拍一周正弦照度（count 15002±3000，H 档 → LUX = count/1.2）。基线取
	-- 15002 使相位中点拍（n=0/16/32）的 count 非 6 的倍数 ⇒ 除不尽 1.2、必为
	-- 带小数浮点（12501.666667，单测钉该拍）。余下拍里有少数 count 恰为 6 的
	-- 倍数（如 17496→14580）、发布值成整数，属真机同样的「整帧整数」现象；
	-- 守护 20ms 拍与外部 50ms pump 又存在混叠（快照采到哪拍不固定），故 E2E 的
	-- :f 浮点断言不锚 raw 某一拍，改锚 Ema 混合后的 out。virt_tick 仅造测量数据，
	-- 不改命令状态与 cmds（真实器件连续模式下照度变化也不产生总线写事务），
	-- 故 build 前预武装与每拍驱动都不干扰驱动的在位判定与命令留痕。
	function m:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self.count = math.floor(15002 + 3000 * s + 0.5)
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

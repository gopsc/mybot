-- SHT3X 温湿度传感器 驱动模块（I2C，兼容 SHT30/31/35）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 SHT3X_VIRT（2026-09-15 自 modules/lib/virtbus/sht3x.lua
-- 迁入，单文件驱动+模型实验第十八个，16 位命令字 + CRC-8 族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SHT3X (
--       name    String,
--       I2C     String,
--       address String
--   );
--   INSERT INTO SHT3X (name, I2C, address) VALUES ('sht3x-0', 'i2c-1', '0x44');
--
-- call 无需额外参数（元数据由框架自动合并传入），
-- 返回 { result, T(°C), RH(%RH), CRC_OK }。
-- 接 sensor_daemon：fields 填 T|RH；值已是换算后的浮点，切勿配 sign=16
-- （sign 是给原始 16 位补码整数用的，会破坏浮点）。
--
-- 实现要点：
--   1. 树莓派 BCM 系列 I2C 主控对时钟拉伸支持有缺陷，测量固定用【轮询模式】
--      （0x2400 单次·高重复性）：写命令 -> milli_sleep(16) -> 纯读 6 字节
--   2. SHT3X 命令为 16 位双字节，恰与 i2c_write_reg(fd, hi, lo) 的 2 字节
--      原子写吻合；HAL 的 i2c_write_reg 返回 true/false，可直接检查
--   3. i2c_read 纯读 n 字节按大端合并：纯 Lua 算术，失败返回 -1、成功恒为
--      非负且 6 字节（<=2^48）在 double 域内精确——负值还原分支为旧 cfunc
--      桥的防御遗留，现恒不触发，保留作护栏
--   4. CRC8 多项式 0x31、初值 0xFF（与 SGP30.lua 相同；数据手册校验向量
--      0xBEEF -> 0x92）。6 字节 = T_MSB T_LSB CRC | RH_MSB RH_LSB CRC
--   5. 出厂校准无系数表；换算 T = -45 + 175*raw/65535，RH = 100*raw/65535

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令（16 位，双字节发送） ====================
local CMD_SOFT_RESET  = { 0x30, 0xA2 }	-- 软复位，约 1.5ms 后就绪
local CMD_READ_STATUS = { 0xF3, 0x2D }	-- 读状态寄存器：2 数据字节 + CRC
-- 单次测量·轮询模式（不用时钟拉伸，树莓派 BCM 主控不支持）
local CMD_MEAS_HIGH   = { 0x24, 0x00 }	-- 高重复性，最大 15.5ms
local MEAS_WAIT_MS    = 16		-- 轮询等待（不低于数据手册最大值）

-- ==================== 状态寄存器位（数据手册 Table 18，读命令 0xF32D） ====================
--   bit0 = 写数据校验和状态（'1' = 上次写数据校验和失败）
--   bit1 = 命令状态（'1' = 上一命令未处理或非法）
--   bit4 = 系统复位检测（软复位/硬复位/上电后置位）
-- 旧映射把 bit0/bit1 当作命令/复位位——真命令错误漏检、复位检测位永错
-- （2026-09 审计 M1 已修；bit0 仅诊断参考，build 不判）
local ST_WRITE_CRC = 0x0001		-- bit0：写数据校验和状态
local ST_CMD_STATUS = 0x0002		-- bit1：1=上一命令未处理或非法
local ST_RESET_SEEN = 0x0010		-- bit4：1=发生过复位（软复位/硬复位/上电）

-- CRC8校验字（多项式0x31，初值0xFF，与 SGP30.lua 一致）
-- CRC 判据单点在 bitcompat.crc8（D1 收敛，2026-09-25）：Sensirion 词 CRC
-- = poly 0x31、init 0xFF、16 位词按 hi/lo 两字节展开——器件约定留在调用方。
local function crc8(word)
	return bitc.crc8(0xFF, 0x31, { math.floor(word / 256) % 256, word % 256 })
end

-- 纯读 n 字节 → n 字节表（0 基下标）。失败（-1）返回 nil；
-- 其余负值按旧 cfunc 桥的有符号合并语义还原为无符号（现 HAL 恒为正，防御分支）
local function read_bytes(fd, n)
	local raw = i2c_read(fd, n)
	if raw == -1 then return nil end
	if raw < 0 then raw = raw + 256 ^ n end
	local b = {}
	for i = 0, n - 1 do
		b[i] = math.floor(raw / 256 ^ (n - 1 - i)) % 256
	end
	return b
end

require_driver("i2c", {
	name = "SHT3X",

	-- 【配置脚本】软复位 + 读状态寄存器验证响应
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- SHT3X builder func get a table --------", data)
		end

		local fd = ctx.fd

		-----------------------------------------------------
		-- 软复位（HAL 的 i2c_write_reg 是 2 字节原子写，返回 true/false）
		if not i2c_write_reg(fd, CMD_SOFT_RESET[1], CMD_SOFT_RESET[2]) then
			return err("Failed to write SHT3X soft reset")
		end
		milli_sleep(2)			-- 复位就绪约 1.5ms

		-- 读状态寄存器验证响应
		if not i2c_write_reg(fd, CMD_READ_STATUS[1], CMD_READ_STATUS[2]) then
			return err("Failed to write SHT3X read status")
		end
		milli_sleep(1)
		local sb = read_bytes(fd, 3)
		if sb == nil then
			return err("Failed to read SHT3X status")
		end

		local status = sb[0] * 256 + sb[1]
		if crc8(status) ~= sb[2] then
			return err("SHT3X status CRC mismatch")
		end
		if bitc.band(status, ST_CMD_STATUS) ~= 0 then
			return err("SHT3X command status error (bit1: last command not processed)")
		end
		if bitc.band(status, ST_RESET_SEEN) == 0 then
			print("SHT3X: reset flag (bit4) not set in status, continuing")
		end

		print(string.format("SHT3X init OK: addr=0x%02X, status=0x%04X", ctx.addr, status))
		return {  result = "OK"  }
	end,

	-- 【调用SHT3X】单次测量（轮询模式）：写命令 -> 等待 -> 纯读 6 字节
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- SHT3X caller func get a table --------", data)
		end

		local fd = ctx.fd

		-----------------------------------------------------
		-- 单次测量（0x2400 轮询·高重复性），等待转换完成
		if not i2c_write_reg(fd, CMD_MEAS_HIGH[1], CMD_MEAS_HIGH[2]) then
			return err("Failed to write SHT3X measure command")
		end
		milli_sleep(MEAS_WAIT_MS)

		local b = read_bytes(fd, 6)
		if b == nil then
			return err("Failed to read SHT3X measurement")
		end

		-----------------------------------------------------
		local st  = b[0] * 256 + b[1]		-- 温度原始值（16 位无符号）
		local srh = b[3] * 256 + b[4]		-- 湿度原始值（16 位无符号）
		local crc_ok = (crc8(st) == b[2]) and (crc8(srh) == b[5])

		local T  = -45.0 + 175.0 * st / 65535.0
		local RH = 100.0 * srh / 65535.0

		if DEBUG then
			print(string.format("SHT3X: T=%.2f C, RH=%.2f %%RH, CRC %s",
				T, RH, crc_ok and "OK" or "FAIL"))
		end

		-- 返回字典（CRC_OK：0/1，参照 SGP30 的约定不因 CRC 失败而中断）
	 	return {
			result = "OK",
			T      = T,
			RH     = RH,
			CRC_OK = crc_ok and 1 or 0
		}
	end,

	-- destroy 缺省 = 空操作（原 SHT3X destroy 仅 arg_table + return OK，等价）
})


-- =====================================================================
-- 【内嵌虚拟器件模型】SHT3X_VIRT —— 2026-09-15 自 modules/lib/virtbus/sht3x.lua
-- 整体迁入（单文件驱动+模型第十八个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十七者：① 生产路径零执行（new() 仅虚拟总线测试调用；位运算经
-- 本文件 mpath 上值惰性 dofile bitcompat 并缓存，不共用驱动 bitc；CRC-8
-- 公开在 SHT3X_VIRT.crc8 表字段——模型/驱动/测试三方独立实现交叉，常量/
-- 命令表移入 new() 内避让）；② 工厂经全局表而非文件 return（生产侧 Lua.cj
-- build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会
-- 滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 定位：【首个 16 位命令字 + 每数据字 CRC-8 的命令式 I2C 器件】——没有
-- 寄存器指针：每笔总线写恰为 2 字节命令大端字（驱动借 i2c_write_reg(fd,hi,lo)
-- 的 2 字节原子写发送），测量/状态从总线【纯读】（i2c_read，无前置指针写）。
-- 与 BH1750（单字节 opcode）同族但命令宽一倍，且读回帧每 2 字节带 1 字节
-- CRC-8（多项式 0x31、初值 0xFF，校验向量 0xBEEF→0x92），模型必须按
-- datasheet 真算 CRC 而不是常量占位——驱动 build 校验状态 CRC、call 报告
-- CRC_OK，坏 CRC 是必须能注入的真实故障面。
--
-- 只复刻协议层事实（Sensirion SHT3x datasheet，以真实驱动
-- modules/SHT3X.lua 实际访问为准）：
--   1) 软复位 0x30A2：约 1.5ms 后就绪，状态回上电值 bit4=1（复位检测）、
--      加热器关、测量态清空；清状态 0x3041 只清标志位（保留 bit12 加热器）。
--   2) 状态寄存器（读命令 0xF32D，纯读 3 字节 status_MSB/LSB/CRC）：
--      bit0=上次写数据校验和状态、bit1=上命令未处理/非法、bit4=复位检测、
--      bit12=加热器；bit0/bit1 为读后清零（read-to-clear）。非法命令字
--      被器件拒绝（NACK）并置 bit1。
--   3) 单次测量（轮询 0x2400/0x240B/0x2416，时钟拉伸 0x2C06/0x2C0D/
--      0x2C10）：转换未完成前纯读 6 字节被 NACK（轮询模式语义），
--      advance(ms) 推进转换（测试 milli_sleep 桩转调，驱动高重复性固定
--      等 16ms ≥ datasheet max 15.5ms）；6 字节 = T_MSB T_LSB CRC |
--      RH_MSB RH_LSB CRC，单次结果读后即失效（再读 NACK）。
--   4) 周期模式 15 个启动字 + 0x3093 break + 0xE000 fetch（驱动不用，
--      模型识别留痕，周期数据可重复 fetch）；加热器 0x306D/0x3066 改
--      bit12。出厂无校准系数表：raw→T=-45+175·raw/65535、RH=100·raw/65535
--      是驱动侧换算，模型只按 16 位宽度存储（set_raw），set_sample 物理量
--      API 仅供守护 virt_tick 造样本。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：无 5.4 位运算符。
-- =====================================================================

SHT3X_VIRT = { _VERSION = "0.1.0" }

-- 位运算惰性装载：首次 crc8 计算时 dofile bitcompat 并缓存
local sht3x_ops_cache = nil
local function sht3x_ops()
	if sht3x_ops_cache == nil then
		local ok, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
		sht3x_ops_cache = (ok and bc) or false
	end
	return sht3x_ops_cache
end

-- CRC-8（多项式 0x31、初值 0xFF；datasheet 校验向量 0xBEEF → 0x92）。
-- 公开在工厂表字段：模型/驱动/测试三方独立实现交叉。
local function sht3x_crc8(word)
	local bitc = sht3x_ops()
	local crc = 0xFF
	for _, b in ipairs({ math.floor(word / 256) % 256, word % 256 }) do
		crc = bitc.bxor(crc, b)
		for _ = 1, 8 do
			if bitc.band(crc, 0x80) ~= 0 then
				crc = bitc.band(bitc.bxor(bitc.lshift(crc, 1), 0x31), 0xFF)
			else
				crc = bitc.band(bitc.lshift(crc, 1), 0xFF)
			end
		end
	end
	return crc
end
SHT3X_VIRT.crc8 = sht3x_crc8

function SHT3X_VIRT.new()
	local crc8 = sht3x_crc8

	-- 状态寄存器位（datasheet Table 18）
	local F_WRITE_CRC = 0x0001	-- bit0：上次写数据校验和失败（读后清）
	local F_CMD_BAD   = 0x0002	-- bit1：上命令未处理/非法（读后清）
	local F_RESET     = 0x0010	-- bit4：发生过复位（上电/软/硬）
	local F_HEATER    = 0x1000	-- bit12：加热器开关（清状态命令保留）

	-- 单次测量字 → 转换时间上限 ms（向上取整：15.5/6.5/4.5）
	local SINGLE_WAIT = {
		[0x2400] = 16, [0x240B] = 7, [0x2416] = 5,	-- 轮询（不拉伸时钟）
		[0x2C06] = 16, [0x2C0D] = 7, [0x2C10] = 5,	-- 时钟拉伸（片内等待，同上限）
	}
	-- 周期测量启动字（mps × 重复性，共 15 个；驱动不用，识别留痕即可）
	local PERIODIC_START = {
		[0x2032] = true, [0x2024] = true, [0x202F] = true,	-- 0.5 mps
		[0x2130] = true, [0x2126] = true, [0x212D] = true,	-- 1 mps
		[0x2236] = true, [0x2220] = true, [0x222B] = true,	-- 2 mps
		[0x2334] = true, [0x2322] = true, [0x2329] = true,	-- 4 mps
		[0x2737] = true, [0x2721] = true, [0x272A] = true,	-- 10 mps
	}

	local SOFT_RESET, CLEAR_STATUS, READ_STATUS = 0x30A2, 0x3041, 0xF32D
	local HEATER_ON, HEATER_OFF, BREAK, FETCH = 0x306D, 0x3066, 0x3093, 0xE000

	local function clamp_word(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
	end

	-- 25°C / 50%RH 的上电种子原始值（set_sample 同款编码，仅为静态初值合理）
	local function seed_data()
		return math.floor((25 + 45) * 65535 / 175 + 0.5),
		       math.floor(50 * 65535 / 100 + 0.5)
	end

	local d = {}

	-- 芯片侧状态
	local status = F_RESET			-- 上电即置复位检测位
	local t_raw, rh_raw = seed_data()
	local pending = nil			-- nil | "status" | "meas"（最近命令待读）
	local consume = false			-- 单次结果读后失效；周期 fetch 可重复读
	local remaining, ready = nil, false
	local periodic = false
	local prearmed = false			-- virt_tick 预武装：下一单次命令零转换
	local cmds, bad_cmds = {}, {}		-- 识别命令字序列 / 非法命令字序列

	-- 故障钩子（reset 保留，clear_faults 解除）
	-- 三个 nack 为表字段（外部直接 d.nack=true，与 bh1750 等模型一致）；
	-- 定向谓词/坏 CRC/卡死/状态覆写为 local，由方法设置
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local bad_crc = false			-- 破坏所有输出帧 CRC（状态+测量）
	local meas_stuck = false		-- 转换永不完成（轮询读恒 NACK）
	local status_override = nil		-- 强制状态字（注入坏标志位组合）

	local function flag(f, on)
		local set = math.floor(status / f) % 2 == 1
		if on and not set then status = status + f
		elseif not on and set then status = status - f end
	end

	local function start_single(word)
		pending, consume = "meas", true
		periodic = false
		if prearmed then
			remaining, ready = 0, true
		else
			remaining, ready = SINGLE_WAIT[word], false
		end
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		-- SHT3x 只有 16 位命令：非 2 字节写视为非法帧 NACK
		if #bytes ~= 2 then return false end
		local word = bytes[1] * 256 + bytes[2]
		if write_pred and write_pred(word, bytes) then return false end

		if word == SOFT_RESET then
			status = F_RESET
			pending, consume = nil, false
			remaining, ready, periodic = nil, false, false
		elseif word == CLEAR_STATUS then
			-- 清所有标志位，保留加热器在位状态（bit12）
			status = math.floor(status / F_HEATER) % 2 == 1 and F_HEATER or 0
			-- 清状态不改变待读语义（datasheet 不产生数据）
		elseif word == READ_STATUS then
			pending = "status"
		elseif SINGLE_WAIT[word] then
			start_single(word)
		elseif PERIODIC_START[word] then
			periodic = true
			pending, remaining, ready = nil, nil, false
		elseif word == BREAK then
			periodic = false
			pending = nil
		elseif word == FETCH then
			-- 仅周期模式有数据缓冲；空闲 fetch 无数据（随后读 NACK）
			if periodic then pending, consume, ready = "meas", false, true end
		elseif word == HEATER_ON then
			flag(F_HEATER, true)
		elseif word == HEATER_OFF then
			flag(F_HEATER, false)
		else
			-- 非法命令：器件拒绝并置命令状态位（datasheet bit1）
			flag(F_CMD_BAD, true)
			bad_cmds[#bad_cmds + 1] = word
			return false
		end
		cmds[#cmds + 1] = word
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(pending, consume, n) then return nil end
		if pending == "status" and n == 3 then
			local w = status_override or status
			local crc = bad_crc and (crc8(w) ~= 0xFF and 0xFF or 0x00) or crc8(w)
			-- bit0/bit1 读后清零（bit4/bit12 保持；override 不改真实 status）
			if math.floor(status / F_WRITE_CRC) % 2 == 1 then status = status - F_WRITE_CRC end
			if math.floor(status / F_CMD_BAD) % 2 == 1 then status = status - F_CMD_BAD end
			pending = nil
			return { math.floor(w / 256) % 256, w % 256, crc }
		end
		if pending == "meas" and n == 6 then
			if meas_stuck or not ready then return nil end
			local tc = bad_crc and (crc8(t_raw) ~= 0xFF and 0xFF or 0x00) or crc8(t_raw)
			local rc = bad_crc and (crc8(rh_raw) ~= 0xFF and 0xFF or 0x00) or crc8(rh_raw)
			if consume then pending = nil end	-- 单次结果读后失效
			return { math.floor(t_raw / 256) % 256, t_raw % 256, tc,
			         math.floor(rh_raw / 256) % 256, rh_raw % 256, rc }
		end
		-- 空闲/未触发转换/长度不符：无数据可读，NACK（真机轮询语义）
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining, ready = 0, true end
		end
		return self
	end

	-- 注入测量原始值（16 位无符号宽度；换算公式归驱动，模型不抄）
	function d:set_raw(t, rh)
		t_raw, rh_raw = clamp_word(t), clamp_word(rh)
		return self
	end

	-- 物理量注入（仅供守护/E2E 造样本；常量与驱动换算同源同量程）
	function d:set_sample(t_c, rh_pct)
		t_raw = clamp_word((t_c + 45) * 65535 / 175)
		rh_raw = clamp_word(rh_pct * 65535 / 100)
		return self
	end

	-- 强制状态寄存器上报值（build 负路径注入：坏标志位但 CRC 正确）
	function d:set_status_word(w)
		status_override = w and clamp_word(w) or nil
		return self
	end

	function d:fail_cmd(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_crc(on) bad_crc = on ~= false; return self end
	function d:set_meas_stuck(on) meas_stuck = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		bad_crc, meas_stuck, status_override = false, false, nil
		return self
	end

	function d:reset_logs()
		cmds, bad_cmds = {}, {}
		return self
	end

	-- 上电复位：芯片状态回种子；故障钩子保留（防负路径假解除）
	function d:reset()
		status = F_RESET
		t_raw, rh_raw = seed_data()
		pending, consume = nil, false
		remaining, ready, periodic, prearmed = nil, false, false, false
		cmds, bad_cmds = {}, {}
		return self
	end

	-- 守护逐拍造数：确定性温湿度正弦（T 20~30°C，RH 30~70%），
	-- 并预武装——驱动每拍新写单次命令，守护不驱动 advance，
	-- 必须让命令下发时转换即完成（真实 16ms milli_sleep 在守护里照常睡）。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_sample(25 + 5 * math.sin(ph),
		                50 + 20 * math.sin(ph + math.pi / 4))
		prearmed = true
		return self
	end

	-- 只读观察口
	function d:current_status() return status_override or status end
	function d:is_periodic() return periodic end
	function d:is_ready() return ready end
	function d:remaining_ms() return remaining end
	function d:pending() return pending end
	function d:cmd_count() return #cmds end
	function d:commands() return cmds end
	function d:bad_commands() return bad_cmds end

	return d
end

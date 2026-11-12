-- CHT8305 温湿度传感器 驱动模块（I2C，申矽凌微 SensyLink）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 CHT8305_VIRT（2026-09-15 自 modules/lib/virtbus/cht8305.lua
-- 迁入，单文件驱动+模型实验第二十九个，字寄存器指针族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- 第二代数字温湿度传感器：±3.0%RH / ±0.5℃（最大），14 位 ADC，2.5~5.5V，
-- DFN3x3-6 封装。协议为指针寄存器风格（写指针 -> 等转换 -> 纯读 2 字节），
-- 无 CRC。ALERT 开漏输出（过限告警）本驱动未用（轮询）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE CHT8305 (
--       name    String,
--       I2C     String,
--       address String
--   );
--   INSERT INTO CHT8305 (name, I2C, address) VALUES ('th-0', 'i2c-1', '0x40');
-- 地址由 AD0 引脚选（接 GND/Vcc/SDA/SCL -> 4 个从地址），悬空 = 0x40
-- （数据手册 8 位地址 0x80）；一条总线最多 4 颗。
--
-- call 返回 { result, T(°C), H(%RH) }——14 位满量程换算：
--   T = raw x 165/65535 - 40；RH = raw x 100/65535
-- 接 sensor_daemon：fields=T|H（浮点，勿配 sign），interval >= 30ms 即可
--   （每次 call 内含 2 x 14ms 转换等待）。
--
-- 实现要点（协议与换算经官方 sensylink/CHT8305 与 RobTillaart/CHT8305
-- 两套实现逐行互证，官方代码即以 MID==0x5959 作在位校验）：
--   1. 指针寄存器：0x00 温度 / 0x01 湿度 / 0x02 配置 / 0x03 告警限 /
--      0x04 电压（换算公式存疑，两源之一标注 best guess，本驱动不实现）/
--      0xFE 厂商 ID（0x5959）/ 0xFF 器件 ID（0x8305）
--   2. 配置位：bit15 软复位、bit14 时钟拉伸、bit13 加热器、bit12 模式、
--      bit10 温度分辨率、bit9:8 湿度分辨率（缺省 14 位）——本驱动只发
--      软复位，其余保持 POR 默认
--   3. 转换等待：14 位双通道约 13ms，取 14ms 余量（RobTillaart 同值）
--   4. 告警限（HLIMIT/TLIMIT，0x03）编程流程未实现，按手册另行操作

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（指针） ====================
local REG_TEMP  = 0x00
local REG_HUMI  = 0x01
local REG_CONF  = 0x02
local REG_MID   = 0xFE
local REG_DID   = 0xFF

local MID_MAGIC = 0x5959		-- 厂商 ID（官方代码在位校验同款）
local DID_MAGIC = 0x8305		-- 器件 ID
local CFG_SOFT_RESET = 0x80
local T_CONV_MS = 14			-- 14 位转换等待（数据手册 2 x 6.5ms + 余量）

-- ==================== 模块级配置 ====================
local cfg_addr

-- 写指针寄存器（单字节命令，无数据）
local function set_pointer(fd, reg)
	return i2c_write_multi(fd, reg) == 0
end

-- 读当前指针指向的 16 位寄存器
local function read_reg16(fd)
	local v = i2c_read(fd, 2)
	if v < 0 then return nil end
	return v % 65536
end

-- ==================== 配置脚本 + 调用 + 销毁 ====================
require_driver("i2c", {
	name = "CHT8305",

	-- 软复位 -> 厂商/器件 ID 自检
	build = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- CHT8305 builder func get a table --------", data)
		end

		-- 软复位（bit15 自清零，恢复 POR 默认配置）：
		-- 写寄存器必须单事务 [指针, 数据]——两段式会把数据字节当指针发（双源实现均同）
		if i2c_write_multi(fd, REG_CONF, 0x80) ~= 0 then
			return err("CHT8305 not responding (soft reset failed, check address 0x40 and wiring)")
		end
		milli_sleep(10)

		-- 厂商/器件 ID 自检
		if not set_pointer(fd, REG_MID) then
			return err("CHT8305 not responding (pointer write failed)")
		end
		local mid = read_reg16(fd)
		if mid == nil then
			return err("CHT8305 not responding (read manufacturer id failed)")
		end
		if mid ~= MID_MAGIC then
			return err(string.format("CHT8305 unexpected manufacturer id 0x%04X (expect 0x%04X)", mid, MID_MAGIC))
		end
		if not set_pointer(fd, REG_DID) then
			return err("CHT8305 not responding (pointer write failed)")
		end
		local did = read_reg16(fd)
		if did == nil then
			return err("CHT8305 not responding (read device id failed)")
		end
		if did ~= DID_MAGIC then
			return err(string.format("CHT8305 unexpected device id 0x%04X (expect 0x%04X)", did, DID_MAGIC))
		end

		cfg_addr = ctx.addr
		print(string.format("CHT8305 init OK: addr=0x%02X mid=0x%04X did=0x%04X", ctx.addr, mid, did))
		return {  result = "OK"  }
	end,

	-- 触发并读取温度 + 湿度（各一次指针写 + 14ms 转换等待 + 2 字节读）
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- CHT8305 caller func get a table --------", data)
		end

		-----------------------------------------------------
		-- 温度
		if not set_pointer(fd, REG_TEMP) then
			return err("CHT8305 not responding (temp pointer write failed)")
		end
		milli_sleep(T_CONV_MS)
		local t_raw = read_reg16(fd)
		if t_raw == nil then
			return err("CHT8305 not responding (read temperature failed)")
		end
		-- 湿度
		if not set_pointer(fd, REG_HUMI) then
			return err("CHT8305 not responding (humi pointer write failed)")
		end
		milli_sleep(T_CONV_MS)
		local h_raw = read_reg16(fd)
		if h_raw == nil then
			return err("CHT8305 not responding (read humidity failed)")
		end

		return {
			result = "OK",
			T = t_raw * 165.0 / 65535.0 - 40.0,
			H = h_raw * 100.0 / 65535.0
		}
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】CHT8305_VIRT —— 2026-09-15 自 modules/lib/virtbus/cht8305.lua
-- 整体迁入（单文件驱动+模型第二十九个，字寄存器指针 + 每通道转换门族，守护
-- E2E 走 sensor_daemon 回退路径）。约定同前二十八者：① 生产路径零执行
-- （new() 仅虚拟总线测试调用，纯闭包零外部依赖；寄存器指针/门限/地图表/
-- helper 全部移入 new() 内——驱动文件级有同名 REG_TEMP 等，文件级再定义会
-- 遮蔽混淆）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【8 位「字寄存器」指针 + 无指针纯读 + 每通道转换门 + 双 ROM ID 甄别】
-- I2C 器件（申矽凌微 SensyLink CHT8305C，AD0 选 4 个从地址 0x40~0x43，悬空
-- 0x40——8 位地址 0x80）。指针索引的是 16 位【字寄存器】而非字节（区别
-- LTC2944 的字节文件模 26、AMG8833 的 256 字节空间、INA219 的写帧恰 3B
-- 字寻址）：datasheet 寄存器地图仅 6 个指针——
--   0x00 温度测量字（只读，16 位无符号，T = raw·165/65535 − 40）
--   0x01 湿度测量字（只读，16 位无符号，H = raw·100/65535）
--   0x02 配置字（POR 0x0000；bit15 软复位，写 1 触发后回读恒 0）
--   0x03 告警高限设置字（R/W）；0xFE 厂商 ID = 0x5959、0xFF 版本 ID = 0x8305
--   0x04~0xFD 为 datasheet 未定义指针：整笔 NACK（真机无对应寄存器）。
--
-- 总线事务形态（真实驱动 modules/CHT8305.lua 实际访问）：
--   - 纯指针写：i2c_write_multi(fd, reg) 发恰 1 字节 {reg}，选当前字寄存器；
--   - 字写：i2c_write_multi(fd, reg, MSB, ...) 发 {reg, 数据字节…}，数据
--     大端打包进连续字寄存器（偶数位=高字节、奇数位=低字节）；
--   - 纯读：i2c_read(fd, 2) 是【无指针纯读】（不是 i2c_read_multi 的指针写
--     +读两事务），读最近指针选中的字寄存器、大端高字节在前。
--   注意驱动软复位只发 {0x02, 0x80} 两个字节——指针 + 仅 1 个高数据字节：
--   高字节 0x80 即配置 bit15，芯片立即软复位（低字节保持 POR 0x00），bit15
--   回读自清零；模型忠实复刻「半个字写也触发复位」，不替驱动补齐 LSB。
--
-- 转换门（datasheet 1.4 测量流程：写指针触发 → 等转换时间 → 纯读）：
--   - 写指针到 0x00/0x01 即启动该通道一次转换，14 位每通道门限 14ms；
--   - 非时钟拉伸模式下门内纯读被 NACK（轮询语义，同 SHT3x）；advance(ms)
--     推虚拟时钟（测试 milli_sleep 桩转调，驱动 call 实睡 2×14ms）；
--   - 转换完成后结果保持到下一次同通道指针写（连续测量器件，可重复读）；
--   - 配置/告警/ID 字无门随时可读；POR 后未完成过转换时 T/H 读 NACK。
--   - virt_tick 预武装：armed 后写指针触发的转换零时间即就绪（守护不驱动
--     advance，真实 14ms milli_sleep 在守护里照睡但模型不等它）；武装跨
--     软复位保留——守护 build 前 tick 一次，build 内的复位不得解除武装。
--
-- 只复刻协议层事实：换算公式归驱动；模型按 16 位宽度存原始码，另给物理量
-- 逆注入 API（常数与驱动同源）仅供守护/E2E 造样本。
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：纯算术无 bitcompat。
-- =====================================================================

CHT8305_VIRT = { _VERSION = "0.1.0" }

function CHT8305_VIRT.new(seed)
local REG_TEMP, REG_HUMI, REG_CONF, REG_ALERT = 0x00, 0x01, 0x02, 0x03
local REG_MID, REG_DID = 0xFE, 0xFF
local MID_MAGIC, DID_MAGIC = 0x5959, 0x8305
local GATE_MS = 14			-- 每通道 14 位转换门（驱动等待同值）

-- datasheet 定义的全部字寄存器指针
local VALID = {
	[0x00] = true, [0x01] = true, [0x02] = true, [0x03] = true,
	[0xFE] = true, [0xFF] = true,
}
local MEAS = { [0x00] = true, [0x01] = true }	-- 带转换门的测量字
local READONLY = { [0x00] = true, [0x01] = true, [0xFE] = true, [0xFF] = true }

local function clamp_word(v)
	v = math.floor((tonumber(v) or 0) + 0.5)	-- 物理逆注入取最近 LSB
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end

local function is_byte(v)
	return type(v) == "number" and v >= 0 and v <= 255 and math.floor(v) == v
end

-- 字内替换高/低字节（保留另一半；纯算术）
local function put_hi(cur, b) return b * 256 + cur % 256 end
local function put_lo(cur, b) return math.floor(cur / 256) % 256 * 256 + b end

	local d = {}

	-- ---- 芯片侧状态 ----
	local ptr = REG_TEMP
	local words = {}			-- 稀疏字存储（T/H 未播种为 nil=无数据）
	local ready = { [0x00] = false, [0x01] = false }
	local conv_reg, remaining = nil, nil
	local armed = false			-- virt_tick 预武装（跨软复位保留）
	local mid_ov, did_ov = nil, nil	-- who() 身份覆写（负路径）

	-- 留痕
	local wr_frames = {}
	local write_count, read_count, reset_count = 0, 0, 0

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_ready = false	-- 转换永不完成（advance/武装均无效）

	local function reseed()
		words = {
			[REG_CONF] = 0x0000,		-- 配置 POR 全 0
			[REG_ALERT] = 0x0000,		-- 告警限 POR 0
			[REG_MID] = mid_ov or MID_MAGIC,	-- ROM ID（覆写是测试脚手架）
			[REG_DID] = did_ov or DID_MAGIC,
		}
		ready = { [0x00] = false, [0x01] = false }
		conv_reg, remaining = nil, nil
		ptr = REG_TEMP
	end
	reseed()

	-- 种子构造：合法字段播种，任一字段非法回 POR（不采纳半份种子）
	if type(seed) == "table" then
		local ok, t = pcall(function()
			local s = {}
			if seed.temp ~= nil then
				local v = assert(tonumber(seed.temp))
				assert(v >= 0 and v <= 65535); s[REG_TEMP] = clamp_word(v)
			end
			if seed.humi ~= nil then
				local v = assert(tonumber(seed.humi))
				assert(v >= 0 and v <= 65535); s[REG_HUMI] = clamp_word(v)
			end
			if seed.config ~= nil then
				local v = assert(tonumber(seed.config))
				assert(v >= 0 and v <= 0x7FFF); s[REG_CONF] = clamp_word(v)
			end
			if seed.alert ~= nil then
				local v = assert(tonumber(seed.alert))
				assert(v >= 0 and v <= 65535); s[REG_ALERT] = clamp_word(v)
			end
			if seed.mid ~= nil then
				local v = assert(tonumber(seed.mid))
				assert(v >= 0 and v <= 65535)
				mid_ov = clamp_word(v); s[REG_MID] = mid_ov
			end
			if seed.did ~= nil then
				local v = assert(tonumber(seed.did))
				assert(v >= 0 and v <= 65535)
				did_ov = clamp_word(v); s[REG_DID] = did_ov
			end
			return s
		end)
		if ok then
			for r, v in pairs(t) do
				words[r] = v
				if r == REG_TEMP or r == REG_HUMI then ready[r] = true end
			end
		else
			mid_ov, did_ov = nil, nil
			reseed()
		end
	end

	local function start_gate(reg)
		conv_reg = reg
		if armed and not never_ready then
			remaining, ready[reg] = 0, true
		else
			remaining, ready[reg] = GATE_MS, false
		end
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes < 1 then return false end
		for _, b in ipairs(bytes) do
			if not is_byte(b) then return false end
		end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end

		local start = bytes[1]
		if not VALID[start] then return false end	-- 未定义指针整笔 NACK

		if #bytes == 1 then
			-- 纯指针写：选字寄存器；测量指针兼作转换触发
			ptr = start
			if MEAS[start] then start_gate(start) end
		else
			-- 字写：数据从 start 起按字大端打包，字指针每 2 字节自增。
			-- 只读字（T/H 测量结果、MID/DID）数据写 ACK 但丢弃。
			local do_reset = false
			local last = start
			for j = 2, #bytes do
				local r = start + math.floor((j - 2) / 2)
				if not VALID[r] then break end		-- 越过地图：后续忽略
				local hi = (j - 2) % 2 == 0
				if r == REG_CONF and hi and bytes[j] >= 0x80 then
					do_reset = true				-- 高字节 bit7=bit15 软复位
				end
				if not READONLY[r] then
					local cur = words[r] or 0
					words[r] = hi and put_hi(cur, bytes[j]) or put_lo(cur, bytes[j])
				end
				last = r
			end
			-- 帧末指针停最后访问字的下一字（真机字自增；驱动总重写指针）
			ptr = last + 1

			wr_frames[#wr_frames + 1] = {}
			for i, b in ipairs(bytes) do wr_frames[#wr_frames][i] = b end
			write_count = write_count + 1

			if do_reset then
				-- bit15 自清 + 全寄存器回默认（ID 为 ROM 常量）；
				-- 故障钩子与预武装保留（守护 build 前 tick，复位不得断流）
				reseed()
				reset_count = reset_count + 1
			end
			-- 非复位配置写：bit15 物理上写不进（高字节 <0x80 才走到这），
			-- 其余控制位（拉伸/加热器/模式/分辨率）原样落盘供读回。
		end

		if #bytes == 1 then
			wr_frames[#wr_frames + 1] = { start }
			write_count = write_count + 1
		end
		return true
	end

	function d.read(n)
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 8 then n = 8 end
		-- NACK 判定在任何指针推进之前：读失败指针不动
		if d.nack or d.nack_read then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		if not VALID[ptr] then return nil end
		if MEAS[ptr] and (never_ready or not ready[ptr]) then return nil end

		local out = {}
		for j = 1, n do
			local r = ptr + math.floor((j - 1) / 2)
			local w = VALID[r] and (words[r] or 0) or 0
			if (j - 1) % 2 == 0 then
				out[j] = math.floor(w / 256) % 256	-- 高字节
			else
				out[j] = w % 256				-- 低字节
			end
		end
		-- 字自增：n 字节覆盖 ceil(n/2) 个字，指针停末字 +1
		ptr = ptr + math.floor((n + 1) / 2)
		read_count = read_count + 1
		return out
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if remaining ~= nil and not never_ready then
			remaining = remaining - ms
			if remaining <= 0 then
				remaining = 0
				if conv_reg then ready[conv_reg] = true end
			end
		end
		return self
	end

	-- 注入测量原始码（16 位无符号宽度；不改变就绪态，转换门纪律归调用方）
	function d:set_raw(t, h)
		if t ~= nil then words[REG_TEMP] = clamp_word(t) end
		if h ~= nil then words[REG_HUMI] = clamp_word(h) end
		return self
	end

	-- 物理量逆注入（仅供守护/E2E 造样本；常数与驱动换算同源）
	function d:set_temp_c(t)
		t = tonumber(t) or 0
		words[REG_TEMP] = clamp_word((t + 40) * 65535 / 165)
		return self
	end
	function d:set_humi_pct(h)
		h = tonumber(h) or 0
		words[REG_HUMI] = clamp_word(h * 65535 / 100)
		return self
	end

	-- 覆写 ROM ID（build 双 ID 自检负路径）；nil 恢复出厂常量
	function d:who(mid, did)
		if mid ~= nil then mid_ov = clamp_word(mid); words[REG_MID] = mid_ov end
		if did ~= nil then did_ov = clamp_word(did); words[REG_DID] = did_ov end
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:set_never_ready(on) never_ready = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred, never_ready = nil, nil, false
		return self
	end

	function d:reset_logs()
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 上电/软复位：回 POR；故障钩子与预武装保留（防负路径假解除、守护不断流）
	function d:reset()
		reseed()
		conv_reg, remaining = nil, nil
		wr_frames = {}
		write_count, read_count, reset_count = 0, 0, 0
		return self
	end

	-- 守护逐拍造数：确定性反相正弦（32 拍）——T 25±5°C（20~30）、
	-- H 50∓10%RH（60~40，温度峰对应湿度谷）；装码 + 武装，call 零等待。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(2 * math.pi * (n % 32) / 32)
		self:set_temp_c(25 + 5 * s)
		self:set_humi_pct(50 - 10 * s)
		armed = true
		ready[REG_TEMP], ready[REG_HUMI] = true, true
		return self
	end

	-- ---- 只读观察口 ----
	function d:ptr() return ptr end
	function d:word(r) return words[r] end
	function d:config() return words[REG_CONF] end
	function d:alert() return words[REG_ALERT] end
	function d:mid() return words[REG_MID] end
	function d:did() return words[REG_DID] end
	function d:temp_raw() return words[REG_TEMP] end
	function d:humi_raw() return words[REG_HUMI] end
	function d:is_ready(r) return ready[r or conv_reg] == true end
	function d:remaining_ms() return remaining end
	function d:conv_reg() return conv_reg end
	function d:is_armed() return armed end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:reset_count() return reset_count end
	function d:frames() return wr_frames end

	return d
end

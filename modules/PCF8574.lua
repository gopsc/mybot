-- PCF8574 8 位准双向 IO 扩展器 驱动模块（I2C）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 PCF8574_VIRT（2026-09-15 自 modules/lib/virtbus/pcf8574.lua
-- 迁入，单文件驱动+模型实验第九个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- NXP PCF8574（T=SO16 封装后缀）：无寄存器图——写一字节 = 输出锁存，
-- 读一字节 = 引脚即时状态。总线限 100kHz 标准模式（不支持 400kHz）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE PCF8574 (
--       name    String,
--       I2C     String,
--       address String,
--       out     String    -- 上电初始输出锁存 0~255（缺省 0xFF = 全部弱上拉/输入态）
--   );
--   INSERT INTO PCF8574 (name, I2C, address, out)
--     VALUES ('io-0', 'i2c-1', '0x20', '255');
-- 地址族：PCF8574 = 0x20~0x27（A2/A1/A0 引脚），PCF8574A 变体 = 0x38~0x3F，
--   其他地址直接报错（常见接错器件）
--
-- call 返回 { result, PINS(引脚即时状态 0~255), OUT(当前输出锁存) }：
--   传 out=0~255 先写锁存再回读；不传则纯读引脚。
-- 准双向语义（无方向寄存器）：写 1 = 弱上拉（可被外部拉低，当输入），
--   写 0 = 强驱动低（当输出）；外部拉低恒胜过弱上拉。全输入姿势：out=255 后读。
--
-- 硬件注意：灌电流强（单脚约 25mA，可直点 LED/继电器板晶体管），拉电流极弱
--   （约百 uA）——输出高靠外部上拉，勿用它直接供电；INT 引脚本驱动未用（轮询）。
-- 在位探测：I2C ACK 即存在性证据（器件无 ID 寄存器），build 读一次确认。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
dofile((__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
	.resolve("lib/drv_common.lua"))

-- 调试开关：IO 扩展器逐拍读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 模块级配置 ====================
local cfg_latch		-- 当前输出锁存（跨 call 保持于本变量独立状态机）

-- 读引脚即时状态（0~255）；失败返回 nil
local function read_pins(fd)
	local v = i2c_read(fd, 1)
	if v < 0 then return nil end
	return v % 256
end

require_driver("i2c", {
	name = "PCF8574",

	-- ==================== 配置脚本 ====================
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- PCF8574 builder func get a table --------", data)
		end

		-- fd/address 存在性 + set_addr 由框架 i2c_pair 代劳；
		-- 地址族校验在 set_addr 之后（set_addr 仅配置 fd 不碰总线，无害）
		-- 地址族校验：8574 = 0x20~0x27，8574A = 0x38~0x3F
		local in_family = (addr >= 0x20 and addr <= 0x27) or (addr >= 0x38 and addr <= 0x3F)
		if not in_family then
			return err(string.format("PCF8574 invalid address 0x%02X (expect 0x20~0x27 or 0x38~0x3F for PCF8574A)", addr))
		end

		-- 在位探测：读一次引脚（ACK 即存在性证据）
		local pins = read_pins(fd)
		if pins == nil then
			return err("PCF8574 not responding (read failed, check address and wiring)")
		end

		-- 初始输出锁存（缺省 0xFF：POR 默认全弱上拉，显式写以对齐状态）
		local out = finite_of(data.out)
		if out == nil or data.out == "-" or data.out == "" then out = 0xFF end
		out = math.floor(out)
		if out < 0 or out > 255 then
			return err("Invalid Argument: out '" .. tostring(data.out) .. "' (range 0~255)")
		end
		if i2c_write_multi(fd, out) ~= 0 then
			return err("PCF8574 not responding (latch write failed)")
		end
		cfg_latch = out

		if os.getenv("BOT4CJ_DEBUG") == "1" then
			print(string.format("PCF8574 init OK: addr=0x%02X latch=0x%02X pins=0x%02X",
				addr, out, pins))
		end
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 PCF8574 destroy 仅 arg_table + return OK，等价）

	-- ==================== 调用 ====================
	-- out=0~255 写输出锁存；不传则纯读引脚。两种情况都回读引脚即时状态。
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- PCF8574 caller func get a table --------", data)
		end

		-----------------------------------------------------
		local out = finite_of(data.out)
		if out ~= nil then
			out = math.floor(out)
			if out < 0 or out > 255 then
				return err("Invalid Argument: out '" .. tostring(data.out) .. "' (range 0~255)")
			end
			if i2c_write_multi(fd, out) ~= 0 then
				return err("PCF8574 not responding (latch write failed)")
			end
			cfg_latch = out
		end

		local pins = read_pins(fd)
		if pins == nil then
			return err("PCF8574 not responding (read failed)")
		end

		return {
			result = "OK",
			PINS = pins,
			OUT = cfg_latch or 0xFF
		}
	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】PCF8574_VIRT —— 2026-09-15 自 modules/lib/virtbus/pcf8574.lua
-- 整体迁入（单文件驱动+模型第九个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前八者：① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零外部
-- 依赖，POR 常量/纯算术 band8 移入段内改名 PCF8574_POR_LATCH/pcf8574_band8
-- 保文件级唯一）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；
-- ③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【无寄存器图 · 单字节 P 口写 + 无指针纯读】极简样板（NXP PCF8574 /
-- PCF8574A，地址族 0x20~0x27 / 0x38~0x3F；纯闭包、纯算术无 bitcompat）。
-- 协议事实与 modules/PCF8574.lua 驱动同源（NXP 手册）：
--   1) 没有寄存器指针/寄存器地图：写事务的每个数据字节直接进 P 口输出锁存
--      （每字节都 ACK、逐字节传送到 P 口，驱动永远只写 1 字节，末字节留口）；
--      读事务是无指针纯读，每字节 = P 口引脚即时电平（连续读重复返回当前
--      引脚态，n 钳 1~16）。
--   2) 准双向、无方向寄存器：锁存写 1 = 弱上拉（可作输入，外部可拉低），
--      写 0 = 强驱动低。引脚读值 = latch & ~pull_low——外部低电平恒胜过
--      弱上拉，强驱动低位恒读 0。POR 锁存 = 0xFF（全弱上拉/输入态）。
--      pull_low 是测试侧的「外部激励」（按键/开漏器件），只能由注入 API 设置；
--      模型不臆造引脚电平。
--   3) 无 ID 寄存器：build 的在位甄别就是一次纯读 ACK；地址族校验在驱动侧。
--   4) virt_tick 供守护逐拍造数：walking 低电平位（8 拍周期循环拉低 P0~P7，
--      模拟按键轮询），build 前 virt_tick(0) 预武装、call 纯读引脚随拍变化。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

PCF8574_VIRT = { _VERSION = "0.1.0" }

local PCF8574_POR_LATCH = 0xFF

-- 8 位按位与（纯算术，模型不引 bitcompat）
local function pcf8574_band8(a, b)
	a = a % 256
	b = b % 256
	local r, p = 0, 1
	for _ = 1, 8 do
		if a % 2 == 1 and b % 2 == 1 then r = r + p end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		p = p * 2
	end
	return r
end

local function pcf8574_bytev(v)
	v = tonumber(v)
	if v == nil or v ~= math.floor(v) or v < 0 or v > 255 then return nil end
	return v
end

function PCF8574_VIRT.new(opts)
	opts = opts or {}
	local d = {}

	-- 芯片侧状态
	local latch = pcf8574_bytev(opts.latch) or PCF8574_POR_LATCH	-- P 口输出锁存（POR 0xFF）
	local pull_low = pcf8574_bytev(opts.pull_low) or 0	-- 外部拉低掩码（测试激励，非芯片寄存器）

	-- 事务留痕（txlog 之外的模型级计数/帧表）
	local wr_frames = {}				-- 每笔写事务的字节表副本
	local write_count, read_count = 0, 0

	-- 故障钩子（d:reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- 派生 ----------------

	-- 引脚即时电平：强驱动低位恒 0；弱上拉位被外部拉低则读 0
	local function pins()
		return pcf8574_band8(latch, 255 - pull_low)
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end
		local frame = {}
		for i = 1, #bytes do
			local b = pcf8574_bytev(bytes[i])
			if b == nil then return false end	-- 非字节：整笔 NACK，锁存不动
			frame[i] = b
			latch = b				-- 逐字节传送 P 口，末字节留口
		end
		wr_frames[#wr_frames + 1] = frame
		write_count = write_count + 1
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(n) then return nil end
		local p = pins()
		local t = {}
		for i = 1, n do t[i] = p end		-- 连续读重复返回当前引脚态
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 直接置输出锁存（正常路径由总线写改变；仅供特殊注入/重开电场景）
	function d:set_latch(v)
		v = pcf8574_bytev(v)
		if v ~= nil then latch = v end
		return self
	end

	-- 外部激励：8 位掩码，置 1 的位被外部强拉低（按键/开漏）
	function d:set_pull_low(mask)
		mask = pcf8574_bytev(mask)
		if mask ~= nil then pull_low = mask end
		return self
	end
	function d:pull(i)			-- 单脚外部拉低
		i = math.floor(tonumber(i) or -1)
		if i >= 0 and i <= 7 and pcf8574_band8(pull_low, 2 ^ i) == 0 then
			pull_low = pull_low + 2 ^ i
		end
		return self
	end
	function d:release(i)			-- 单脚外部释放
		i = math.floor(tonumber(i) or -1)
		if i >= 0 and i <= 7 and pcf8574_band8(pull_low, 2 ^ i) ~= 0 then
			pull_low = pull_low - 2 ^ i
		end
		return self
	end
	function d:release_all() pull_low = 0; return self end

	-- 守护逐拍造数：walking 低电平位，8 拍周期（模拟 P0~P7 轮询按键）
	function d:virt_tick(n)
		local k = math.floor(tonumber(n) or 0) % 8
		pull_low = 2 ^ k
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
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 重新上电：锁存回 POR 0xFF、外部激励清空、留痕清零；故障钩子保留
	function d:reset()
		latch = PCF8574_POR_LATCH
		pull_low = 0
		wr_frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:latch() return latch end
	function d:pins() return pins() end
	function d:pull_low() return pull_low end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:frames() return wr_frames end
	function d:last_write()
		local f = wr_frames[#wr_frames]
		return f and f[#f] or nil
	end

	return d
end

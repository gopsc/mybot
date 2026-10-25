-- MAX17048 单节锂电池电量计 驱动模块（I2C，地址固定 0x36）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MAX17048_VIRT（2026-09-15 自 modules/lib/virtbus/max17048.lua
-- 迁入，单文件驱动+模型实验第二十二个，MAX17043 同族换代；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Maxim/ADI ModelGauge：靠电池模型从电压推算 SOC，无需分流电阻；
-- MAX17048 = 仓库 MAX17043 驱动的换代芯片（寄存器图扩展、VCELL 换算不同，
-- 两代不可共用驱动）；同总线同地址（0x36）只能挂一颗。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MAX17048 (
--       name       String,
--       I2C        String,
--       address    String,
--       valrt_max  String,   -- 过压告警阈值 V（20mV 步进；'-' = 保持 POR 值 5.1V）
--       valrt_min  String,   -- 欠压告警阈值 V（20mV 步进；'-' = 保持 POR 值 0V）
--       athd       String,   -- SOC 低电告警阈值 % 1~32（CONFIG ATHD；'-' = 不改）
--       quickstart String    -- '1' = build 时发 QuickStart（换电池后快速重新收敛）
--   );
--   INSERT INTO MAX17048 (name, I2C, address, valrt_max, valrt_min, athd, quickstart)
--     VALUES ('fuel-0', 'i2c-1', '0x36', '-', '3.3', '10', '-');
--
-- call 返回
--   { result, VCELL(V), SOC(%), CRATE(%/hr，充电为正), STATUS(6 位告警掩码) }
--   STATUS 位（清零=正常）：bit0 RI 复位指示 bit1 VH 过压 bit2 VL 欠压
--   bit3 VR 电压复位 bit4 HD SOC 变化 bit5 SC 1% SOC 变化；
--   传 clear=1 读取后清除告警位（默认只读不清）。
-- 接 sensor_daemon：fields=VCELL|SOC（浮点，勿配 sign）；
--   低电急停：Monitor 引用本变量判 SOC <= 阈值后经 controller 转发执行器。
--
-- 实现要点（寄存器语义与换算经 SparkFun MAX1704x 库全源核对，内核
-- max17042_battery.c 同图互证；与 MAX17043.lua 的差异点均已注明）：
--   1. VERSION（0x08）自检：0x0012=MAX17048（78.125uV/LSB，满量程 5.12V）、
--      0x0013=MAX17049 双节（156.25uV/LSB）；0x001E/0x001F 是 MAX17043/44，
--      报错引导用 MAX17043 驱动
--   2. VCELL（0x02）：16 位直读（无 17043 的左移 4）
--   3. SOC（0x04）：高字节整数 % + 低字节 /256
--   4. CRATE（0x16）：16 位带符号，0.208%/hr 每 LSB
--   5. STATUS（0x1A）：告警位在高字节 bit0~5，清除=写 0（保留 bit14 EnVR）
--   6. VALRT（0x14/0x15）：高字节 MIN（地址 0x14）、低字节 MAX（地址 0x15），
--      20mV/LSB，POR 0x00FF（MIN=0/0V、MAX=255/5.1V）
--   7. ATHD：CONFIG（0x0C）低 5 位，值 = 32 - 阈值%（00000=32%）
--   8. QuickStart：MODE（0x06）写 0x4000（本驱动仅在 build 配置时发一次）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：电量计读取频率低，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器（SparkFun MAX1704x 命名） ====================
local REG_VCELL   = 0x02		-- 电池电压 16 位
local REG_SOC     = 0x04		-- 剩余电量（高字节 %，低字节 /256）
local REG_MODE    = 0x06		-- QuickStart 0x4000
local REG_VER     = 0x08		-- 版本号：0x0012/0x0013 = 17048/49
local REG_CONFIG  = 0x0C		-- [15:8]RCOMP [4:0]ATHD
local REG_VALRT   = 0x14		-- [15:8]MAX [7:0]MIN，20mV/LSB
local REG_CRATE   = 0x16		-- 充放电速率（带符号，0.208%/hr）
local REG_STATUS  = 0x1A		-- 告警标志（高字节 bit0~5），EnVR=bit14

local VER_17048   = 0x0012
local VER_17049   = 0x0013
local VER_17043   = 0x001E
local VER_17044   = 0x001F

local MODE_QUICKSTART = 0x4000
local STATUS_FLAGS    = 0x3F00	-- 高字节 bit0~5 的 16 位掩码
local STATUS_ENVR     = 0x4000

-- ==================== 工具 ====================
local s16 = function(v) return bitc.s16(v % 65536) end

-- ==================== 模块级配置 ====================
local cfg_lsb_v		-- VCELL 每 LSB 伏特（17048: 78.125uV / 17049: 156.25uV）
local cfg_variant	-- 器件名（横幅/报错用）

-- ==================== 配置脚本 ====================
require_driver("i2c", {
name = "MAX17048",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- MAX17048 builder func get a table --------", data)
	end


	-- VERSION 自检（家族地址相同，插错芯片在这里拦下）
	local ver = i2c_read_multi(fd, REG_VER, 2)
	if ver < 0 then
		return err("MAX17048 not responding (read version failed, check address 0x36 and wiring)")
	end
	if ver == VER_17043 or ver == VER_17044 then
		return err(string.format("MAX17048 wrong chip: version 0x%04X is MAX17043/44, use the MAX17043 driver", ver))
	end
	if ver ~= VER_17048 and ver ~= VER_17049 then
		return err(string.format("MAX17048 unexpected version 0x%04X (expect 0x0012/0x0013)", ver))
	end
	cfg_variant = (ver == VER_17048) and "MAX17048" or "MAX17049"
	cfg_lsb_v = (ver == VER_17048) and 78.125e-6 or 156.25e-6

	-- QuickStart（可选）：换电池/上电后跳过慢收敛
	if tostring(data.quickstart) == "1" then
		if i2c_write_multi(fd, REG_MODE, 0x40, 0x00) ~= 0 then
			return err("MAX17048 not responding (quickstart write failed)")
		end
		milli_sleep(5)
	end

	-- VALRT 过压/欠压阈值（20mV/LSB，读改写保留另一侧）
	-- datasheet Figure 11：地址 0x14 = VALRT.MIN（16 位字的高字节）、
	-- 地址 0x15 = VALRT.MAX（低字节），POR 0x00FF（MIN=0/0V、MAX=255/5.1V）
	local vmax = finite_of(data.valrt_max)
	local vmin = finite_of(data.valrt_min)
	if vmax ~= nil or vmin ~= nil then
		local cur = i2c_read_multi(fd, REG_VALRT, 2)
		if cur < 0 then
			return err("MAX17048 not responding (read VALRT failed)")
		end
		local min_code = math.floor(cur / 256) % 256	-- 0x14 = MIN
		local max_code = cur % 256				-- 0x15 = MAX
		if vmax ~= nil then
			if vmax < 0 or vmax > 5.1 then
				return err("Invalid Argument: valrt_max '" .. tostring(data.valrt_max) .. "' (range 0~5.1V)")
			end
			max_code = math.floor(vmax / 0.02 + 0.5)
			if max_code > 255 then max_code = 255 end
		end
		if vmin ~= nil then
			if vmin < 0 or vmin > 5.1 then
				return err("Invalid Argument: valrt_min '" .. tostring(data.valrt_min) .. "' (range 0~5.1V)")
			end
			min_code = math.floor(vmin / 0.02 + 0.5)
			if min_code > 255 then min_code = 255 end
		end
		if i2c_write_multi(fd, REG_VALRT, min_code, max_code) ~= 0 then
			return err("MAX17048 not responding (VALRT write failed)")
		end
	end

	-- ATHD SOC 低电告警阈值（CONFIG 低 5 位，读改写保留 RCOMP）
	local athd = finite_of(data.athd)
	if athd ~= nil then
		if athd < 1 or athd > 32 then
			return err("Invalid Argument: athd '" .. tostring(data.athd) .. "' (range 1~32%)")
		end
		local cur = i2c_read_multi(fd, REG_CONFIG, 2)
		if cur < 0 then
			return err("MAX17048 not responding (read CONFIG failed)")
		end
		-- 低字节 bit7:5（SLEEP/ALSC/ETHRM）保留，仅替换 bit4:0 的 ATHD
		local lo = (cur % 256) - (cur % 32) + (32 - math.floor(athd))
		local hi = math.floor(cur / 256) % 256
		if i2c_write_multi(fd, REG_CONFIG, hi, lo % 256) ~= 0 then
			return err("MAX17048 not responding (CONFIG write failed)")
		end
	end

	-- 读一次状态做横幅（复位指示 RI 常见于上电后首次读取）
	local st = i2c_read_multi(fd, REG_STATUS, 2)
	local flags = (st >= 0) and math.floor(st / 256) % 64 or 0

	print(string.format("%s init OK: addr=0x%02X ver=0x%04X status=0x%02X lsb=%.2fuV",
		cfg_variant, addr, ver, flags, cfg_lsb_v * 1e6))
	return {  result = "OK"  }

end,

-- ==================== 调用 ====================
-- 读电压/SOC/速率/告警标志；clear=1 时读取后清除告警位
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- MAX17048 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local vraw = i2c_read_multi(fd, REG_VCELL, 2)
	if vraw < 0 then
		return err("MAX17048 not responding (read VCELL failed)")
	end
	local sraw = i2c_read_multi(fd, REG_SOC, 2)
	if sraw < 0 then
		return err("MAX17048 not responding (read SOC failed)")
	end
	local craw = i2c_read_multi(fd, REG_CRATE, 2)
	if craw < 0 then
		return err("MAX17048 not responding (read CRATE failed)")
	end
	local straw = i2c_read_multi(fd, REG_STATUS, 2)
	if straw < 0 then
		return err("MAX17048 not responding (read STATUS failed)")
	end

	-- clear=1：按位清除告警标志（高字节 bit0~5；保留 bit6 EnVR 等）
	if tostring(data.clear) == "1" then
		local hi = math.floor(straw / 256) % 256
		if hi % 64 ~= 0 then		-- 告警位有置位才写
			i2c_write_multi(fd, REG_STATUS, hi - (hi % 64), straw % 256)
		end
	end

	return {
		result = "OK",
		VCELL = vraw * (cfg_lsb_v or 78.125e-6),
		SOC = math.floor(sraw / 256) + (sraw % 256) / 256.0,
		CRATE = s16(craw) * 0.208,
		STATUS = math.floor(straw / 256) % 64
	}

end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】MAX17048_VIRT —— 2026-09-15 自 modules/lib/virtbus/max17048.lua
-- 整体迁入（单文件驱动+模型第二十二个，MAX17043 同族换代，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前二十一个：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，自包含偶地址字地图实现；可读表/clamp 移入段内加
-- max17048_ 前缀避让；new() 内 `local max17048 = MAX17048_VIRT` 绑定使模型
-- 体零改动移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua
-- 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua
-- 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段 = I2C。
--
-- 【MAX17043 的换代芯片，同地址 0x36 同偶地址稀疏字地图，但寄存器图扩展，
-- 常数逐条不同，不能与 max17043.lua 互抄】（datasheet MAX17048/17049 Rev.7
-- Figure 8/11/13 与 Table.2 核对）：
--   0x02 VCELL  16 位直读（无 17043 的左移 4/>>4），LSB 78.125µV（17049
--               双节 156.25µV，刻度分支在驱动按 VERSION 选择）；只读
--   0x04 SOC    u16 定点 1/256%（同 17043，可报告 >100%）；只读
--   0x06 MODE   bit14 Quick-Start（写 1 触发、自清不落盘 + 计数）、bit13
--               EnSleep 照存、bit12 HibStat 只读写忽略、bit15 保留抹掉
--   0x08 VERSION ROM：0x0012=MAX17048、0x0013=MAX17049（驱动精确甄别，
--               0x001E/F=17043/44 拒收）；who() 可覆写；POR 0x0012
--   0x0C CONFIG POR 0x971C；0x14 VALRT POR 0x00FF（0x14=MIN 高字节、
--               0x15=MAX 低字节，20mV/LSB）；0x16 CRATE s16 0.208%/hr；
--   0x1A STATUS POR 0x0100（RI 上电置位），高字节六告警 + EnVr，全字读写
-- 0xFE CMD    只写命令口：复位魔数 0x5400（帧 {0xFE,0x54,0x00}，与 17043
--               的 0x0054 相反），恰写触发 reseed + reset_count+1
-- 驱动不触碰的寄存器不建模：HIBRT 0x0A、VRESET/ID 0x18、TABLE 0x40~0x7F
-- 与解锁口 0x3E/0x3F——读 NACK、字写 NACK。
--
-- 驱动 build/call 事务：build set + 指针读 VERSION 甄别 + 可选 QuickStart +
-- VALRT/CONFIG 读改写 + STATUS 横幅；call 依次指针读 VCELL/SOC/CRATE/STATUS
-- （9 事务）零睡眠。芯片转换自由运行——无转换门/无 pending/不需要 advance，
-- 测量值只由注入 API 改变，模型绝不自造电池数据。
--
-- 用法：
--   vbus.load_driver("modules/MAX17048.lua")  -- 定义全局 build/call/destroy 与 MAX17048_VIRT
--   local dev = MAX17048_VIRT.new()
--   dev:set_vcell_v(3.85):set_soc_pct(80):set_crate_pcthr(-2.5)
--   vbus.attach("MAX17048@0x36", 0x36, dev)
--
--   dev:who(0x0013)     -- 覆写为 MAX17049（驱动切 156.25µV 刻度）
--   dev:set_flags(63)   -- 注入六告警位
--
-- 【边界约定】模型只固化偶地址字地图/16 位直读 VCELL/1/256 定点 SOC/
-- s16 CRATE/三段阈值字节序/STATUS 标志位/CMD 魔数；物理换算在驱动，
-- 物理量注入 API 常量仅为造样本，测试另做独立换算交叉。
-- =====================================================================

MAX17048_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		VCELL  = 0x02,
		SOC    = 0x04,
		MODE   = 0x06,
		VER    = 0x08,
		CONFIG = 0x0C,
		VALRT  = 0x14,
		CRATE  = 0x16,
		STATUS = 0x1A,
		CMD    = 0xFE,
	}
}

-- 标量常数（逐条挂工厂表）


MAX17048_VIRT.VER_DEFAULT   = 0x0012	-- 0x0012=MAX17048（0x0013=MAX17049）
MAX17048_VIRT.CFG_DEFAULT   = 0x971C	-- RCOMP=0x97（25°C）+ 低字节 POR
MAX17048_VIRT.VALRT_DEFAULT = 0x00FF	-- MIN(0x14)=0x00、MAX(0x15)=0xFF
MAX17048_VIRT.STATUS_POR    = 0x0100	-- RI 上电置位，低字节未定义取 0
MAX17048_VIRT.CMD_RESET     = 0x5400	-- 17048 全片复位魔数（17043 是 0x0054）
MAX17048_VIRT.VCELL_LSB_V   = 78.125e-6	-- MAX17048 单节刻度（17049=156.25µV）
MAX17048_VIRT.VCELL_MAX     = 65535	-- 16 位无符号码域
MAX17048_VIRT.CRATE_LSB     = 0.208	-- %/hr 每 LSB
MAX17048_VIRT.VALRT_LSB_V   = 0.020	-- 20mV/LSB
MAX17048_VIRT.I2C_ADDR      = 0x36	-- 芯片固定地址（无地址引脚）

-- 可读字（测量/配置）；CMD 是只写口不在其中
local max17048_READABLE = {
	[0x02] = true, [0x04] = true, [0x06] = true, [0x08] = true,
	[0x0C] = true, [0x14] = true, [0x16] = true, [0x1A] = true,
}

local function max17048_clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function MAX17048_VIRT.new(opts)
	local max17048 = MAX17048_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local d = {}
	local regs = {}				-- 偶地址 → 16 位值
	local ptr = 0				-- 当前寄存器指针（字节地址）
	local ver_id = opts.version or max17048.VER_DEFAULT
	local reset_cfg = opts.reset_cfg or max17048.CFG_DEFAULT
	local write_pred, read_pred
	local reset_count = 0
	local quickstart_count = 0
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[max17048.REG.VCELL]  = 0
		regs[max17048.REG.SOC]    = 0
		regs[max17048.REG.MODE]   = 0
		regs[max17048.REG.VER]    = ver_id
		regs[max17048.REG.CONFIG] = reset_cfg
		regs[max17048.REG.VALRT]  = max17048.VALRT_DEFAULT
		regs[max17048.REG.CRATE]  = 0
		regs[max17048.REG.STATUS] = max17048.STATUS_POR
	end
	reseed()

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 1 字节 {reg} = 纯指针写（任何地址都 ACK，读时才验可读性）；恰 3 字节
	-- {reg,hi,lo} = 写一个 16 位寄存器；其余长度在本器件协议下不存在，NACK。
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		if #bytes ~= 1 and #bytes ~= 3 then return false end
		local p = bytes[1] % 256
		ptr = p
		if #bytes == 1 then return true end

		local word = (bytes[2] % 256) * 256 + (bytes[3] % 256)
		if p == max17048.REG.VCELL or p == max17048.REG.SOC
			or p == max17048.REG.CRATE or p == max17048.REG.VER then
			-- 测量结果区（VCELL/SOC/CRATE）/ROM（VERSION）：只读，写 ACK
			-- 但丢弃（测量值只能由注入 API 改）
			return true
		elseif p == max17048.REG.MODE then
			-- QuickStart（bit14）自清不落盘且计数；bit15 保留抹掉；
			-- HibStat（bit12）只读写忽略（模型恒 0）；EnSleep（bit13）
			-- 及其余低位照存
			if math.floor(word / 0x4000) % 2 == 1 then
				quickstart_count = quickstart_count + 1
			end
			local v = word % 0x4000					-- 抹 bit15/bit14
			regs[p] = v - math.floor(v / 0x1000) % 2 * 0x1000	-- 抹 bit12
			return true
		elseif p == max17048.REG.CONFIG
			or p == max17048.REG.VALRT
			or p == max17048.REG.STATUS then
			regs[p] = word
			return true
		elseif p == max17048.REG.CMD then
			-- 只写命令口：恰 0x5400 全片复位，其他值 ACK 忽略
			if word == max17048.CMD_RESET then
				reseed()
				reset_count = reset_count + 1
			end
			return true
		end
		-- 未定义偶地址/奇地址（含 HIBRT 0x0A、VRESET 0x18、TABLE 区）
		-- 字写：整笔 NACK
		return false
	end

	-- 读 n 字节：从当前指针寄存器取字的 hi/lo。驱动恒读恰 2 字节/寄存器；
	-- n>2 时字节流按偶地址（每 2 字节一字、字间 +2）连续——读 3 字节 =
	-- 当前字 hi/lo + 下一偶地址字 hi（无「奇尾补 0」，与真实字节流一致），
	-- 途中任一地址不可读整笔 NACK。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if not max17048_READABLE[ptr] then return nil end
		if read_pred and read_pred(ptr, n) then return nil end
		local words = math.ceil(n / 2)
		for i = 0, words - 1 do
			if not max17048_READABLE[ptr + i * 2] then return nil end
		end
		local out = {}
		for i = 1, n do
			local wi = ptr + math.floor((i - 1) / 2) * 2
			local word = regs[wi] or 0
			out[i] = (i - 1) % 2 == 0 and math.floor(word / 256) % 256 or word % 256
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- VCELL 码：u16 0~65535（16 位直读，78.125µV/LSB）
	function d:set_vcell_raw(code)
		regs[max17048.REG.VCELL] = max17048_clampi(math.floor(tonumber(code) or 0),
		                                 0, max17048.VCELL_MAX)
		return self
	end

	-- SOC 码：u16 0~65535（1/256%，芯片可报告 >100%，不钳到 100）
	function d:set_soc_raw(word)
		regs[max17048.REG.SOC] = max17048_clampi(math.floor(tonumber(word) or 0), 0, 65535)
		return self
	end

	-- CRATE 码：s16 -32768~32767（0.208%/hr，充电正/放电负）
	function d:set_crate_raw(code)
		regs[max17048.REG.CRATE] = max17048_clampi(math.floor(tonumber(code) or 0),
		                                 -32768, 32767) % 65536
		return self
	end

	-- STATUS 原始 16 位字（高字节六告警 + EnVr，低字节照存）
	function d:set_status(word)
		regs[max17048.REG.STATUS] = max17048_clampi(math.floor(tonumber(word) or 0),
		                                  0, 65535)
		return self
	end

	-- 只置高字节低 6 位告警标志（RI/VH/VL/VR/HD/SC），保留 EnVr 与低字节
	function d:set_flags(bits)
		local cur = regs[max17048.REG.STATUS] or max17048.STATUS_POR
		local hi = (math.floor(bits) % 64)
		           + math.floor(cur / 0x4000) % 2 * 0x40	-- 保留 EnVr(高字节 bit6)
		regs[max17048.REG.STATUS] = hi * 256 + cur % 256
		return self
	end

	-- MODE/CONFIG/VALRT 等协议寄存器留原始 16 位码注入口
	function d:set_word(reg, word)
		reg = max17048_clampi(math.floor(reg), 0, 255)
		regs[reg] = max17048_clampi(math.floor(word) % 65536, 0, 65535)
		return self
	end

	-- ---------------- 物理量造样本（常量仅造样本用，与驱动独立） ----------------

	-- 电池电压 V（16 位、78.125µV/LSB 最近码；满码 5.11992V）
	function d:set_vcell_v(v)
		local code = max17048_clampi(math.floor(v / max17048.VCELL_LSB_V + 0.5),
		                    0, max17048.VCELL_MAX)
		regs[max17048.REG.VCELL] = code
		return self
	end

	-- 剩余电量 %（1/256% 定点最近码；允许 >100，u16 饱和 255.996%）
	function d:set_soc_pct(pct)
		local word = max17048_clampi(math.floor(pct * 256 + 0.5), 0, 65535)
		regs[max17048.REG.SOC] = word
		return self
	end

	-- 充放电速率 %/hr（0.208/LSB 最近码，s16 饱和）
	function d:set_crate_pcthr(rate)
		local code = max17048_clampi(math.floor(rate / max17048.CRATE_LSB + 0.5),
		                    -32768, 32767)
		regs[max17048.REG.CRATE] = code % 65536
		return self
	end

	-- VALRT 阈值（伏特；0x14=MIN 高字节、0x15=MAX 低字节，20mV 最近码）
	function d:set_valrt_v(vmin, vmax)
		local mn = max17048_clampi(math.floor((vmin or 0) / max17048.VALRT_LSB_V + 0.5),
		                  0, 255)
		local mx = max17048_clampi(math.floor((vmax or 0) / max17048.VALRT_LSB_V + 0.5),
		                  0, 255)
		regs[max17048.REG.VALRT] = mn * 256 + mx
		return self
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期，一节典型锂电：电压 3.85±0.25V（3.6~4.1V 常用区间）、
	-- 电量 80±8% 同相正弦，CRATE 取 SOC 变化率量级的余弦 ±9.98%/hr
	--（±48 码 ×0.208），无随机、E2E 数值可复现。
	--   n0  = 3.85V / 80% / CRATE=+9.984（cos 峰，电压中值上升沿）；
	--   n8  = 4.10V / 88% / CRATE≈0（电压峰）；
	--   n16 = 3.85V / 80% / CRATE=-9.984（cos 谷）；
	--   n24 = 3.60V / 72% / CRATE≈0（电压谷）。
	-- 连续转换无武装概念，直接更新结果寄存器（守护不驱动虚拟时钟）；
	-- STATUS 不触碰（告警只由注入 API 改）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		local c = math.cos(n * (2 * math.pi / 32))
		self:set_vcell_v(3.85 + 0.25 * s)
		self:set_soc_pct(80 + 8 * s)
		self:set_crate_pcthr(48 * max17048.CRATE_LSB * c)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写 CONFIG 复位默认值（立即置于该值，CMD 复位后也是它；nil=不改）
	function d:set_reset_cfg(word)
		if word ~= nil then
			reset_cfg = math.floor(word) % 65536
			regs[max17048.REG.CONFIG] = reset_cfg
		end
		return self
	end

	-- 覆写 VERSION（nil=不改；CMD 全片复位不恢复，测试 section 须显式恢复）
	function d:who(ver)
		if ver ~= nil then
			ver_id = math.floor(ver) % 65536
			regs[max17048.REG.VER] = ver_id
		end
		return self
	end

	-- 驱动 build/call 写过的 3 字节字写 {reg,hi,lo}；1 字节事务是读指针
	function d:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e == 3 then
				out[#out + 1] = { reg = e[1], hi = e[2], lo = e[3],
				                  word = e[2] * 256 + e[3] }
			end
		end
		return out
	end

	function d:reset_count() return reset_count end
	function d:quickstart_count() return quickstart_count end
	function d:pointer() return ptr end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred)  read_pred = pred; return self end
	function d:clear_faults()
		write_pred, read_pred = nil, nil
		self.nack, self.nack_read, self.nack_write = false, false, false
		return self
	end

	function d:reset_logs()
		self.write_log = {}
		return self
	end

	-- 回上电态（保留故障钩子与 who()/set_reset_cfg() 身份，复位不得解除钩子）
	function d:reset()
		reseed()
		reset_count = 0
		quickstart_count = 0
		ptr = 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------
	-- （s16 统一走模块级 bitc 包装（第 74 行）。#30：此前此处另有一份独立
	-- 实现遮蔽 74 行 bitc 包装——实际运行时用的是这份独立拷贝，属重复造轮子）

	function d:version() return regs[max17048.REG.VER] or 0 end
	function d:config()  return regs[max17048.REG.CONFIG] or 0 end
	function d:mode()    return regs[max17048.REG.MODE] or 0 end
	function d:valrt()   return regs[max17048.REG.VALRT] or 0 end
	function d:status()  return regs[max17048.REG.STATUS] or 0 end
	function d:word(reg) return regs[reg] or 0 end

	-- VALRT 两侧阈值码（Figure 11：高字节=MIN、低字节=MAX）
	function d:valrt_min_code()
		return math.floor((regs[max17048.REG.VALRT] or 0) / 256) % 256
	end
	function d:valrt_max_code()
		return (regs[max17048.REG.VALRT] or 0) % 256
	end

	-- 高字节低 6 位告警标志；bit6 EnVr 单独观察
	function d:flags()
		return math.floor((regs[max17048.REG.STATUS] or 0) / 256) % 64
	end
	function d:envr()
		return math.floor((regs[max17048.REG.STATUS] or 0) / 0x4000) % 2
	end

	-- VCELL 寄存器字（u16 直读码）
	function d:vcell_raw()
		return regs[max17048.REG.VCELL] or 0
	end
	function d:soc_raw()
		return regs[max17048.REG.SOC] or 0
	end
	function d:crate_raw()
		return s16(regs[max17048.REG.CRATE] or 0)
	end

	function d:vcell_v()  return self:vcell_raw() * max17048.VCELL_LSB_V end
	function d:soc_pct()  return self:soc_raw() / 256 end
	function d:crate_pcthr() return self:crate_raw() * max17048.CRATE_LSB end

	return d
end

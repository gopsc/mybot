-- TPL0501 256 抽头数字电位器 驱动模块（SPI，写-only）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 TPL0501_VIRT（2026-09-15 自 modules/lib/virtbus/tpl0501.lua
-- 迁入，单文件驱动+模型实验第六个；无硬件单测共用；写-only 无测量值，守护 E2E 豁免）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SPI (
--       name String, path String, spi_mode String, bits String, speed String, delay String
--   );
--   INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
--     VALUES ('spi-0', '/dev/spidev0.0', '0', '8', '1000000', '0');
--   CREATE TABLE TPL0501 (
--       name    String,
--       SPI     String,
--       rtotal  String
--   );
--   INSERT INTO TPL0501 (name, SPI, rtotal) VALUES ('dpot-0', 'spi-0', '100000');
-- @SPI 的 spi_mode 配 0（模式 0，MSB 先行，CS 低有效）；bits 配 8；
-- 时钟上限 10MHz（数据手册），接线长时建议 1MHz 起步
-- rtotal = 端到端电阻（Ω）：100000 = TPL0501-100，10000 = TPL0501-10
--
-- call 参数（三选一，优先级 level > percent > ohms）：
--   level   0~255 抽头原始值
--   percent 0~100 抽头百分比（按 255 折算）
--   ohms    目标电阻（W-L 之间，Ω；需 rtotal 列，滑动端电阻 ~70Ω 另计入实际电路）
-- 返回 { result, level, ohms }（ohms 为按 rtotal 折算的实际阻值）
--
-- 实现要点（依 TI 数据手册 SLIS151）：
--   1. 协议即一个 SPI 字节：CS 低 -> 移入 8 位抽头值 -> CS 高，无命令字、
--      无寄存器地址、无读回能力（引脚无 SDO）——故 build 无事可做，
--      写失败只能靠 HAL spi_write 的返回值（0/-1）报告传输成败
--   2. 抽头易失：上电默认中点 0x7F（127），掉电不保存——动作序列
--      勿假设抽头从 0 开始，build 亦不做任何写操作
--   3. 量化：100k 型每步约 390Ω，10k 型每步约 39Ω
--   4. fd/delay 经元数据引用机制从 @SPI 变量流入（同 ADS1256 的模式）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + fd 校验 + destroy 空操作
-- 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍在文件尾部。
-- 1 行 prelude 加载 drv_common（自带 require_driver 定义）；HAL/print_table
-- 由 require_driver 内部代劳，新驱动作者漏加载的旧坑从根上消失。
dofile((__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
	.resolve("lib/drv_common.lua"))

local WIPER_MAX = 255			-- 256 抽头（0~255）
local DEF_RTOTAL = 100000		-- 缺省按 TPL0501-100（100kΩ）

-- 调试开关：电位器一般低频调节，默认关闭逐次打印
local DEBUG = false

-- 模块级配置（build 写入，跨 call 保持于状态机内存）
local rtotal

-- 抽头位置 -> W-L 实际阻值（Ω）
local function level_to_ohms(level)
	return level / WIPER_MAX * (rtotal or DEF_RTOTAL)
end

require_driver("spi", {
	name = "TPL0501",

	-- 【配置脚本】写-only 器件无寄存器可校验，仅记录换算配置
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- TPL0501 builder func get a table --------", data)
		end

		local rt = tonumber(data.rtotal)
		if rt ~= nil and rt > 0 then rtotal = rt else rtotal = DEF_RTOTAL end

		print(string.format(
			"TPL0501 init OK: rtotal=%d Ω（上电抽头为中点 127，非 0）", rtotal))
		return {  result = "OK"  }
	end,

	-- 【调用TPL0501】设置抽头位置（level/percent/ohms 三选一）
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- TPL0501 caller func get a table --------", data)
		end

		-- 三选一换算（优先级 level > percent > ohms）
		local level
		if data.level ~= nil then
			level = finite_of(data.level)
			if level == nil then
				return err("Invalid Argument: level (not a finite number)")
			end
		elseif data.percent ~= nil then
			local pct = finite_of(data.percent)
			if pct == nil then
				return err("Invalid Argument: percent (not a finite number)")
			end
			level = math.floor(pct / 100.0 * WIPER_MAX + 0.5)
		elseif data.ohms ~= nil then
			local ohms = finite_of(data.ohms)
			if ohms == nil then
				return err("Invalid Argument: ohms (not a finite number)")
			end
			level = math.floor(ohms / (rtotal or DEF_RTOTAL) * WIPER_MAX + 0.5)
		else
			return err("Invalid Argument: need level / percent / ohms")
		end

		-- 限幅到 0~255
		if level < 0 then level = 0 end
		if level > WIPER_MAX then level = WIPER_MAX end
		level = math.floor(level)

		-- 写抽头：一个 SPI 字节即完整操作；delay 经元数据从 @SPI 流入
		if spi_write(ctx.fd, level, finite_of(data.delay)) ~= 0 then
			return err("Failed to write TPL0501 wiper")
		end

		if DEBUG then
			print(string.format("TPL0501: level=%d (≈%.0f Ω)", level, level_to_ohms(level)))
		end

		return {
			result = "OK",
			level  = level,
			ohms   = level_to_ohms(level)
		}
	end,

	-- destroy 缺省 = 空操作（原 TPL0501 destroy 仅 arg_table + return OK，等价）
})


-- =====================================================================
-- 【内嵌虚拟器件模型】TPL0501_VIRT —— 2026-09-15 自 modules/lib/virtbus/tpl0501.lua
-- 整体迁入（单文件驱动+模型第六个，write-only SPI 样板）。约定同前五者：
-- ① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包；模型常量移入 new()
-- 内——WIPER_MAX/DEF_RTOTAL 与上方驱动同名局部量避让）；② 工厂经全局表而非
-- 文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功
-- 路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证
-- 防假绿性质不变。工厂表带 BUS="spi"（写-only 无守护 E2E，字段仅备分派）。
--
-- 对应真实驱动 modules/TPL0501.lua（SPI Mode 0，MSB 先行，CS 低有效）。
-- 器件无 SDO/读回能力，协议是 SPI 输出器件里最小的一种：
--   CS 低 -> SCLK 移入 8 位抽头值 -> CS 上升沿把 8 位移位寄存器装入抽头
--   寄存器；无命令字、无寄存器地址。抽头易失，上电默认中点 0x7F（127），
--   掉电不保存——故 build 不发任何帧，模型初值就是 127 而不是 0。
--
-- 挂载（SPI 路径即片选身份）：
--   vbus.load_driver("modules/TPL0501.lua")  -- 定义全局 build/call/destroy 与 TPL0501_VIRT
--   local pot = TPL0501_VIRT.new({ rtotal = 100000 })   -- TPL0501-100，缺省 100kΩ
--   vbus.attach_spi("TPL0501", "/dev/spidev0.0", pot)
--
-- 一个 CS 帧内若移入多个字节（驱动不会这么做，仅协议事实建模）：8 位移位
-- 寄存器持续移入，早到的位被依次挤出，CS 上升沿只有最后 8 位被锁存——
-- 模型取帧内最后一个字节生效，全部字节留痕。
-- 模型不抄驱动的 percent/ohms 正向公式，只按 datasheet 的线性关系
-- （R_WL = level/255 · rtotal）提供反向读取（事实层）。
-- =====================================================================

TPL0501_VIRT = { _VERSION = "0.1.0", BUS = "spi" }

function TPL0501_VIRT.new(opts)
	local POWERUP_WIPER = 0x7F	-- 上电/复位默认中点抽头（易失，非 0）
	local WIPER_MAX = 255
	local DEF_RTOTAL = 100000	-- 缺省 TPL0501-100

	opts = opts or {}
	local self = {}

	local rtotal = tonumber(opts.rtotal) or DEF_RTOTAL
	local wiper = POWERUP_WIPER	-- 抽头寄存器初值（上电事实）
	local bytes = {}		-- 每帧锁存值留痕 { b=字节, n=帧内字节数 }
	local fail_pred = nil

	-- ===================== 状态/留痕 API（冒号定义） =====================

	-- 当前抽头原始码 0~255
	function self:wiper() return wiper end

	-- 当前抽头百分比（datasheet 线性事实：level/255）
	function self:percent() return wiper / WIPER_MAX * 100 end

	-- W-L 间实际阻值（Ω）；可临时传 rtotal 覆盖构造配置
	function self:ohms(rt)
		rt = tonumber(rt) or rtotal
		return wiper / WIPER_MAX * rt
	end

	function self:rtotal() return rtotal end
	function self:set_rtotal(rt)
		rt = tonumber(rt)
		if rt ~= nil and rt > 0 then rtotal = rt end
		return self
	end

	function self:byte_log() return bytes end
	function self:reset_logs() bytes = {}; return self end

	-- 状态机复位（等价重新上电：抽头回中点；不清测试故障钩子）
	function self:reset()
		wiper = POWERUP_WIPER
		bytes = {}
		return self
	end

	-- ---- 故障注入钩子：命中的帧传输失败（返回 nil，失败帧仍入总线 txlog） ----
	function self:fail_when(pred) fail_pred = pred; return self end
	function self:clear_fail() fail_pred = nil; return self end

	-- ===================== 全双工帧核心（点定义，无 self） =====================
	-- 收本帧 MOSI 1 基字节表，返回等长 MISO（器件无 SDO，纯 0）；
	-- nil/false = 本帧传输失败。
	self.xfer = function(tx)
		if fail_pred ~= nil and fail_pred(tx) then return nil end
		local n = #tx
		if n == 0 then return {} end
		-- 移位寄存器语义：CS 上升沿锁存最后移入的 8 位
		-- HAL 层已保证字节为 0~255 整数，这里再做一次防御性取模
		local v = tx[n] % 256
		wiper = v
		bytes[#bytes + 1] = { b = v, n = n }
		local rx = {}
		for i = 1, n do rx[i] = 0 end
		return rx
	end

	return self
end

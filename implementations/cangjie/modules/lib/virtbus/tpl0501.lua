-- virtbus/tpl0501.lua —— TPL0501 256 抽头数字电位器的虚拟 SPI 器件模型（写-only）
-- bot4cj 仓颉机器人框架
--
-- 对应真实驱动 modules/TPL0501.lua（SPI Mode 0，MSB 先行，CS 低有效）。
-- 器件无 SDO/读回能力，协议是 SPI 输出器件里最小的一种：
--   CS 低 -> SCLK 移入 8 位抽头值 -> CS 上升沿把 8 位移位寄存器装入抽头
--   寄存器；无命令字、无寄存器地址。抽头易失，上电默认中点 0x7F（127），
--   掉电不保存——故 build 不发任何帧，模型初值就是 127 而不是 0。
--
-- 挂载（SPI 路径即片选身份）：
--   local potmod = dofile("modules/lib/virtbus/tpl0501.lua")
--   local pot = potmod.new({ rtotal = 100000 })   -- TPL0501-100，缺省 100kΩ
--   vbus.attach_spi("TPL0501", "/dev/spidev0.0", pot)
--
-- 一个 CS 帧内若移入多个字节（驱动不会这么做，仅协议事实建模）：8 位移位
-- 寄存器持续移入，早到的位被依次挤出，CS 上升沿只有最后 8 位被锁存——
-- 模型取帧内最后一个字节生效，全部字节留痕。
-- 模型不抄驱动的 percent/ohms 正向公式，只按 datasheet 的线性关系
-- （R_WL = level/255 · rtotal）提供反向读取（事实层）。

local pot = {}
pot.BUS = "spi"		-- 供 sensor_daemon proto=virt 区分挂载类型（写-only 无守护 E2E）

local POWERUP_WIPER = 0x7F	-- 上电/复位默认中点抽头（易失，非 0）
local WIPER_MAX = 255
local DEF_RTOTAL = 100000	-- 缺省 TPL0501-100

function pot.new(opts)
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

return pot

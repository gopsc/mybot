-- AS3935 闪电传感器 驱动模块（ams Franklin Lightning Sensor，I2C 地址 0x01~0x03）
-- bot4cj 仓颉语言机器人框架
--
-- 【单消费者声明】失效形态与 AS7262（地址相位被踩）**不同**：本器件是事件锁存型，
-- 检测到噪声过高/干扰源/闪电后把原因锁存在 REG_INT 的 [3:0]，而**读这个寄存器
-- 就会清锁存**（消费性读取）。两个消费者并存时，先读的一方把事件拿走并清掉，
-- 另一方永远看不到那次闪电——**静默漏报**，既不报错也没有任何征兆。
-- 另有 AFE 增益、MASK_DIST 的读-改-写与 RCO 校准等写侧状态。
-- 故只能有一个读者：正道是让 @Daemon 做唯一读者、把事件码发布到共享槽，
-- 其他消费者读快照（见 docs/drivers.md 的「单消费者声明」小节）。
-- 装配期判据见 src/hw_factory.cpp 的 checkSingleConsumer；标记必须写在**行首**。
SINGLE_CONSUMER = "事件锁存 + 读即清：消费性读取，第二个读者会静默漏报事件"
-- 虚拟器件模型：内嵌本文件尾部 AS3935_VIRT（2026-09-15 自 modules/lib/virtbus/as3935.lua
-- 迁入，单文件驱动+模型实验第三十二个，事件型锁存族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 事件型器件（区别于连续采样型）：平时无"数据"，检测到事件（噪声过高/干扰源/
-- 闪电）后锁存中断原因，call 读取并返回最近一次事件。适合 @Daemon 低频轮询
-- （250ms~1s）或 Monitor 消费决策（如户外机器人检测到近距离雷暴提前收工）。
-- 模块：SparkFun SEN-15441 / DFRobot SEN0290 / GY-AS3935 等（板载 500kHz 谐振天线）。
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE AS3935 (
--       name      String,
--       I2C       String,
--       address   String,
--       indoor    String,
--       nf        String,
--       wdth      String,
--       srej      String,
--       min_lig   String,
--       mask_dist String,
--       tun_cap   String
--   );
--   INSERT INTO AS3935 (name, I2C, address, indoor)
--     VALUES ('as3935-0', 'i2c-1', '0x03', '-');
--
-- 列说明（均可选，'-' 归缺省）：
--   indoor    = '1' 室内增益（缺省）/ '0' 室外增益
--   nf        = 噪声底 0~7（缺省 2；电机/舵机旁需调高）
--   wdth      = 看门狗阈值 0~10（缺省 2）
--   srej      = 尖峰抑制 0~15（缺省 2）
--   min_lig   = 确认一次闪电的最少 strikes（1/5/9/16，非法值向下取合法档，缺省 1）
--   mask_dist = '1' 屏蔽干扰源事件（误报排查利器，缺省 '0'）
--   tun_cap   = 天线调谐电容 pF，0~120（8pF 步进截断，缺省 0；模块一般预调好）
--
-- call 无需参数，返回：
--   { result, EVENT("none"|"noise"|"disturber"|"lightning"), CODE(0~3),
--     DIST_KM(闪电时 1~40km；非闪电/未知/超范围 = -1),
--     ENERGY(闪电相对能量 0~2^21，非闪电 = 0) }
-- 接 sensor_daemon：fields=CODE|DIST_KM|ENERGY（数值字段；CODE=3 即闪电）
--
-- build 流程：软复位（0x3C=0x96）-> 在位甄别（复位默认 AFE_GB 应为室内增益）
--   -> 写环境配置（逐字段读-改-写）-> RCO 校准（0x3D=0x96，0x3A/0x3B 的
--   bit6=0 为通过）。天线谐振调谐的严格做法需经 IRQ 引脚测 LCO 频率，
--   本驱动未接 IRQ：tun_cap 按模块手册静态配置即可。
--
-- 协议依据：SparkFun_AS3935_Arduino_Library 与 ESPHome as3935 组件交叉一致，
--   距离特殊值（0x3F=超范围、1=头顶）依 datasheet S_DIST 编码表。
-- 部署提醒：电机/舵机/开关电源是强干扰源——天线远离动力线；误报频繁先
--   mask_dist='1' 验证链路，再逐项放开；地址 0x03 在 I2C 保留区，
--   i2cdetect 默认扫不到（勿误判模块损坏）。
-- 已知兼容性坑：个别模块（DFRobot SEN0290）中断锁存经 I2C 清除不干净
--   （ESPHome #17581），若同一事件反复上报，在消费侧按 CODE 去重。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：事件轮询频率不高，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_AFE_GAIN   = 0x00		-- bit0=PWD，[5:1]=AFE_GB（室内/室外增益）
local REG_THRESHOLD  = 0x01		-- [6:4]=NF_LEV 噪声底，[3:0]=WDTH 看门狗
local REG_LIGHTNING  = 0x02		-- [5:4]=MIN_NUM_LIG，[3:0]=SREJ 尖峰抑制
local REG_INT        = 0x03		-- [3:0]=INT 事件码（读后清锁存），bit5=MASK_DIST
local REG_EGY_LSB    = 0x04		-- 闪电能量 LSB
local REG_EGY_MSB    = 0x05		-- 闪电能量 MSB
local REG_EGY_MMSB   = 0x06		-- 闪电能量最高 5 位
local REG_DISTANCE   = 0x07		-- [5:0]=S_DIST 雷暴距离估计
local REG_FDISP      = 0x08		-- [3:0]=TUN_CAP（pF/8），[7:6]=SRCO/TRCO 显示位
local REG_CALIB_TRCO = 0x3A		-- bit6：TRCO 校准状态（1 = 未通过）
local REG_CALIB_SRCO = 0x3B		-- bit6：SRCO 校准状态（1 = 未通过）
local REG_RESET      = 0x3C		-- 写 0x96 = 软复位/恢复默认
local REG_CALIB_RCO  = 0x3D		-- 写 0x96 = RCO 校准命令

-- ==================== 常量 ====================
local INDOOR_GB  = 0x12			-- AFE_GB 室内增益
local OUTDOOR_GB = 0x0E			-- AFE_GB 室外增益

local EVT_NONE      = 0x00
local EVT_NOISE     = 0x01
local EVT_DISTURBER = 0x04
local EVT_LIGHTNING = 0x08

local CMD_DATA  = 0x96			-- 0x3C 复位 / 0x3D 校准 共用的命令数据
local CALIB_NOK = 0x40			-- 0x3A/0x3B bit6：置位 = 校准未通过

local DIST_OOR = 0x3F			-- S_DIST 超出量程特殊值（1 = 雷暴在头顶）

local T_RESET_MS = 2			-- 复位生效等待
local T_CALIB_MS = 2			-- 校准状态更新等待（显示位强制刷新窗口）

-- 缺省配置（datasheet 复位默认值）
local DEF_NF      = 2
local DEF_WDTH    = 2
local DEF_SREJ    = 2
local DEF_TUN_CAP = 0

-- ==================== 解析辅助 ====================
-- 数值列 -> 钳到 [lo, hi] 的整数；非法/'-' 归缺省
-- （实现收敛至 drv_common.int_of，N-24）

-- min_lig 列 -> MIN_NUM_LIG 编码：1/5/9/16 四档，非法值向下取合法档
local function min_lig_code(v)
	local n = tonumber(v)
	if n == nil then n = 1 end
	n = math.floor(n)
	if n >= 16 then return 3 elseif n >= 9 then return 2
	elseif n >= 5 then return 1 else return 0 end
end

-- 读-改-写寄存器位域：keep_mask = 保留位掩码（1 保留），value 写到 pos 起的字段
-- 成功返回 true（任一步总线失败返回 false）
local function modify_reg(fd, reg, keep_mask, value, pos)
	local cur = i2c_read_reg(fd, reg)
	if cur == nil or cur < 0 then return false end
	local field_mask = bitc.bxor(keep_mask, 0xFF)
	local newv = bitc.bor(bitc.band(cur, keep_mask),
		bitc.band(bitc.lshift(value, pos), field_mask))
	return i2c_write_reg(fd, reg, newv)
end

-- 【配置脚本】软复位 -> 在位甄别 -> 写环境配置 -> RCO 校准
require_driver("i2c", {
name = "AS3935",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- AS3935 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-- 配置列解析
	-- 布尔列走 num_or 而非 `tonumber(x) or dflt`：'nan'/'inf' 经 tonumber 出的是
	-- number（Lua 里 truthy），`or` 兜不住，NaN 会落进「非零即真」把 MASK_DIST
	-- 置成 0x20——与数值列 int_or 已钉死的「非法列归缺省」同一条契约分叉。
	local indoor = num_or(data.indoor, 1) ~= 0
	local nf     = int_or(data.nf, DEF_NF, 0, 7)
	local wdth   = int_or(data.wdth, DEF_WDTH, 0, 10)
	local srej   = int_or(data.srej, DEF_SREJ, 0, 15)
	local lig_c  = min_lig_code(data.min_lig)
	local mask   = num_or(data.mask_dist, 0) ~= 0
	local cap_pF = int_or(data.tun_cap, DEF_TUN_CAP, 0, 120)

	-----------------------------------------------------
	-- 软复位（恢复默认配置）
	if not i2c_write_reg(fd, REG_RESET, CMD_DATA) then
		return err("Failed to reset AS3935")
	end
	milli_sleep(T_RESET_MS)

	-- 在位甄别：复位默认 AFE_GB 应为室内增益 0x12（读-改-写前的身份校验）
	local afe = i2c_read_reg(fd, REG_AFE_GAIN)
	if afe == nil or afe < 0 then
		return err("Failed to read AS3935 AFE_GAIN")
	end
	if bitc.band(bitc.rshift(afe, 1), 0x1F) ~= INDOOR_GB then
		return err(string.format("AFE_GAIN after reset = 0x%02X (expect INDOOR default, not AS3935? wiring/address issue?)", afe))
	end

	-- 写环境配置（逐字段读-改-写，不扰动其他位）
	if not modify_reg(fd, REG_AFE_GAIN, 0xC1, indoor and INDOOR_GB or OUTDOOR_GB, 1) then
		return err("Failed to write AS3935 AFE gain")
	end
	if not modify_reg(fd, REG_THRESHOLD, 0x8F, nf, 4) then
		return err("Failed to write AS3935 noise floor")
	end
	if not modify_reg(fd, REG_THRESHOLD, 0xF0, wdth, 0) then
		return err("Failed to write AS3935 watchdog threshold")
	end
	if not modify_reg(fd, REG_LIGHTNING, 0xCF, lig_c, 4) then
		return err("Failed to write AS3935 min lightning")
	end
	if not modify_reg(fd, REG_LIGHTNING, 0xF0, srej, 0) then
		return err("Failed to write AS3935 spike rejection")
	end
	if not modify_reg(fd, REG_INT, 0xDF, mask and 1 or 0, 5) then
		return err("Failed to write AS3935 disturber mask")
	end
	if not modify_reg(fd, REG_FDISP, 0xF0, math.floor(cap_pF / 8), 0) then
		return err("Failed to write AS3935 tuning capacitor")
	end

	-----------------------------------------------------
	-- RCO 校准（内部 RC 振荡器，事件计时的时基）
	if not i2c_write_reg(fd, REG_CALIB_RCO, CMD_DATA) then
		return err("Failed to send AS3935 RCO calibration command")
	end
	-- 置 SRCO/TRCO 显示位强制校准状态刷新，等一拍后清除
	if not modify_reg(fd, REG_FDISP, 0x3F, 0x03, 6) then
		return err("Failed to set AS3935 calib display bits")
	end
	milli_sleep(T_CALIB_MS)
	if not modify_reg(fd, REG_FDISP, 0x3F, 0x00, 6) then
		return err("Failed to clear AS3935 calib display bits")
	end

	-- 校准状态：SRCO/TRCO 两个状态位都必须为 0（bit6=1 即校准未通过）
	local srco = i2c_read_reg(fd, REG_CALIB_SRCO)
	local trco = i2c_read_reg(fd, REG_CALIB_TRCO)
	if srco == nil or srco < 0 or trco == nil or trco < 0 then
		return err("Failed to read AS3935 calibration status")
	end
	if bitc.band(srco, CALIB_NOK) ~= 0 or bitc.band(trco, CALIB_NOK) ~= 0 then
		return err(string.format("AS3935 RCO calibration failed (SRCO=0x%02X TRCO=0x%02X, NOK bit set)", srco, trco))
	end

	print(string.format("AS3935 init OK: addr=0x%02X, %s, nf=%d, wdth=%d, srej=%d, min_lig_c=%d, mask_dist=%s, tun_cap=%dpF",
		addr, indoor and "indoor" or "outdoor", nf, wdth, srej, lig_c, tostring(mask), cap_pF))
	return {  result = "OK"  }

end,
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- AS3935 caller func get a table --------", data)
	end

	-----------------------------------------------------

	-- 与参考实现一致：事件锁存稳定后再读（IRQ 触发后约 2ms 才可读）
	milli_sleep(2)

	local intv = i2c_read_reg(fd, REG_INT)
	if intv == nil or intv < 0 then
		return err("Failed to read AS3935 interrupt register")
	end
	intv = intv % 16		-- INT 位域 [3:0]

	local ret = {
		result = "OK",
		EVENT = "none", CODE = 0, DIST_KM = -1, ENERGY = 0
	}

	-----------------------------------------------------
	-- 按位判定（比精确相等更稳：个别模块 INT 位域外可能有杂散位）
	if bitc.band(intv, EVT_LIGHTNING) ~= 0 then
		ret.EVENT = "lightning"
		ret.CODE = 3

		local dist = i2c_read_reg(fd, REG_DISTANCE)
		if dist == nil or dist < 0 then
			return err("Failed to read AS3935 distance")
		end
		dist = dist % 64		-- S_DIST 位域 [5:0]
		-- 1 = 雷暴在头顶/极近，2~62 = 公里数，0x3F = 超出量程，0 = 未知
		if dist >= 1 and dist <= 62 then
			ret.DIST_KM = dist
		end

		local lsb = i2c_read_reg(fd, REG_EGY_LSB)
		local msb = i2c_read_reg(fd, REG_EGY_MSB)
		local mmsb = i2c_read_reg(fd, REG_EGY_MMSB)
		if lsb == nil or lsb < 0 or msb == nil or msb < 0 or mmsb == nil or mmsb < 0 then
			return err("Failed to read AS3935 energy")
		end
		ret.ENERGY = bitc.band(mmsb, 0x1F) * 65536 + msb * 256 + lsb

	elseif bitc.band(intv, EVT_DISTURBER) ~= 0 then
		ret.EVENT = "disturber"
		ret.CODE = 2
	elseif bitc.band(intv, EVT_NOISE) ~= 0 then
		ret.EVENT = "noise"
		ret.CODE = 1
	end

	if DEBUG and ret.CODE ~= 0 then
		print(string.format("AS3935: event=%s dist=%skm energy=%d",
			ret.EVENT, tostring(ret.DIST_KM), ret.ENERGY))
	end

	return ret

	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】AS3935_VIRT —— 2026-09-15 自 modules/lib/virtbus/as3935.lua
-- 整体迁入（单文件驱动+模型第三十二个，事件型 INT 锁存族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前三十一者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，纯闭包零外部依赖；寄存器地址/事件码/POR/8 拍事件脚本/
-- clamp 全部移入 new() 内避让）；② 工厂经全局表而非文件 return（生产侧
-- Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件
-- 返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 定位：【8 位字节指针 + 事件型中断锁存（INT 读后清）+ 两条直接命令
-- （0x3C 软复位 / 0x3D RCO 校准）+ 21 位能量三字节小端】样板（ams
-- AS3935，I2C 地址族 0x01~0x03；纯闭包、纯算术无 bitcompat）。六处个性：
--   1) 事件型器件：事件码锁存进 0x03 低 4 位，读 0x03 取走并同拍清事件
--      （bit5 MASK_DIST 配置位保留）；0x01=NOISE/0x04=DISTURBER/0x08=LIGHTNING。
--   2) 距离/能量是独立测量区（0x07/0x04~06），读 INT 不清它们；能量 21 位
--      MMSB 仅低 5 位；换算/判定全在驱动侧，模型只存字节。
--   3) 直接命令 {0x3C,0x96}=软复位（reset_count++）、{0x3D,0x96}=RCO 校准
--      （DONE=1、NOK 按 set_calib_fail 注入）；0x3A/0x3B 只读。
--   4) 0x03 动态合成 + RMW 安全（写 0x03 仅合并 bit5 MASK_DIST，事件锁存
--      不受写影响）；MASK_DIST=1 屏蔽 disturber 注入。
--   5) 0x00 bit0=PWD 检测停摆（注入一律拒绝）；写掩码 0x00→0x3F、0x01→0x7F、
--      0x02→0x3F、0x08→0xCF。
--   6) 无转换门/无 advance：virt_tick 按 8 拍确定性脚本逐拍定义当前锁存
--      事件（n=0 必须 none 供 build 预武装）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

AS3935_VIRT = { _VERSION = "0.1.0" }

function AS3935_VIRT.new()
-- ==================== 寄存器地址 / 常量 ====================
local REG_AFE_GAIN   = 0x00
local REG_THRESHOLD  = 0x01
local REG_LIGHTNING  = 0x02
local REG_INT        = 0x03
local REG_EGY_LSB    = 0x04
local REG_EGY_MSB    = 0x05
local REG_EGY_MMSB   = 0x06
local REG_DISTANCE   = 0x07
local REG_FDISP      = 0x08
local REG_CALIB_TRCO = 0x3A
local REG_CALIB_SRCO = 0x3B
local REG_RESET      = 0x3C
local REG_CALIB_RCO  = 0x3D

local CMD_DATA       = 0x96
local EVT_NOISE      = 0x01
local EVT_DISTURBER  = 0x04
local EVT_LIGHTNING  = 0x08

-- POR 默认值（datasheet reset 缺省：室内增益、NF=2、WDTH=2、SREJ=2、
-- MIN_NUM_LIG=1 码 0、距离 0x3F 超量程）
local POR_AFE       = 0x24		-- PWD=0, AFE_GB[5:1]=0x12 室内
local POR_THRESHOLD = 0x22		-- NF_LEV=2<<4 | WDTH=2
local POR_LIGHTNING = 0x02		-- MIN_NUM=0(1 次) | SREJ=2
local POR_DISTANCE  = 0x3F		-- 复位后距离=超量程

-- virt_tick 8 拍事件脚本：0/1/3/5=none，2/6=闪电，4=噪声，7=干扰源
-- （n=0 必须是 none：守护 build 前用它预武装，build 的 0x03 RMW
-- 读不得读到事件，否则首拍 call 会吃到陈旧事件码）
local TICK_EVENTS = {
	[0] = "none", "none", "lightning", "none",
	"noise", "none", "lightning", "disturber",
}

	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 字节寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此起 burst）
	local afe_por = POR_AFE		-- 软复位后 0x00 的值（who() 可覆写喂负路径）
	local trco_nok = false		-- RCO 校准失败注入（影响下次 0x3D=0x96）
	local srco_nok = false
	local reset_count = 0		-- 软复位 {0x3C,0x96} 次数
	local rco_count = 0		-- RCO 校准 {0x3D,0x96} 次数
	local write_count = 0		-- ≥2B 写事务笔数
	local write_log = {}		-- ≥2B 写事务 {reg=首地址, bytes=...}

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- POR / 软复位 ----------------

	local function seed_body()
		regs = {}
		regs[REG_AFE_GAIN] = afe_por
		regs[REG_THRESHOLD] = POR_THRESHOLD
		regs[REG_LIGHTNING] = POR_LIGHTNING
		regs[REG_INT] = 0x00
		regs[REG_EGY_LSB], regs[REG_EGY_MSB], regs[REG_EGY_MMSB] = 0, 0, 0
		regs[REG_DISTANCE] = POR_DISTANCE
		regs[REG_FDISP] = 0x00
		-- 0x3A/0x3B 校准状态 POR=0x00（DONE=0/NOK=0），命令寄存器不落盘
		regs[REG_CALIB_TRCO], regs[REG_CALIB_SRCO] = 0x00, 0x00
	end

	seed_body()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	local function write_byte(a, v)
		v = v % 256
		if a == REG_RESET then
			if v == CMD_DATA then
				reset_count = reset_count + 1
				seed_body()			-- 软复位：易失寄存器全回 POR
			end						-- 其他值：ACK 忽略；命令寄存器不落盘
			return
		end
		if a == REG_CALIB_RCO then
			if v == CMD_DATA then
				rco_count = rco_count + 1
				-- 模型无 2ms 时间门：命令即完成（DONE bit7=1），NOK 按注入
				regs[REG_CALIB_TRCO] = 0x80 + (trco_nok and 0x40 or 0)
				regs[REG_CALIB_SRCO] = 0x80 + (srco_nok and 0x40 or 0)
			end
			return
		end
		if a == REG_AFE_GAIN then
			regs[a] = v % 0x40			-- bit[7:6] 保留
		elseif a == REG_THRESHOLD then
			regs[a] = v % 0x80			-- bit7 保留
		elseif a == REG_LIGHTNING then
			regs[a] = v % 0x40			-- bit[7:6] 保留
		elseif a == REG_INT then
			-- 仅 bit5 MASK_DIST 可写；低 4 位事件锁存与保留位不受写影响
			regs[a] = (regs[a] % 16) + (v % 0x40 >= 0x20 and 0x20 or 0)
		elseif a == REG_FDISP then
			regs[a] = v - math.floor(v / 0x10) % 4 * 0x10	-- 清 bit[5:4] 保留位 = v & 0xCF
		elseif a >= REG_EGY_LSB and a <= REG_DISTANCE then
			-- 能量/距离只读测量区：写 ACK 丢弃，只能由注入 API 改
			return
		elseif a == REG_CALIB_TRCO or a == REG_CALIB_SRCO then
			return						-- 校准状态只读
		end
		-- 其余保留地址（0x09~0x39/0x3E/0x3F）：ACK 丢弃
	end

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）：0x00..0xFF ACK 设 ptr
			if bytes[1] > 0xFF then return false end
			read_ptr = bytes[1]
			return true
		end
		if bytes[1] > 0xFF then return false end
		for i = 2, nb do
			local b = bytes[i]
			if type(b) ~= "number" or b < 0 or b > 0xFF then return false end
			write_byte((bytes[1] + i - 2) % 256, b)
		end
		write_count = write_count + 1
		local copy = { bytes[1] }
		for i = 2, nb do copy[i] = bytes[i] end
		write_log[#write_log + 1] = { reg = bytes[1], bytes = copy }
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_ptr == nil then return nil end	-- 无指针纯读：NACK
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		if read_ptr > 0x3F then return nil end	-- 寄存器空间 0x00..0x3F
		local t = {}
		for i = 1, n do
			local a = read_ptr
			t[i] = regs[a] or 0
			if a == REG_INT then
				-- 读 0x03 清事件锁存（低 4 位），MASK_DIST 保留
				regs[REG_INT] = regs[REG_INT] - (regs[REG_INT] % 16)
			end
			read_ptr = (read_ptr + 1) % 0x40	-- burst 自增、0x3F 回绕
		end
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	local function pwd() return (regs[REG_AFE_GAIN] or 0) % 2 == 1 end
	local function masked() return (regs[REG_INT] or 0) >= 0x20 end

	-- 闪电事件：dist=S_DIST 码（1=头顶、2~62=km、0x3F 超量程、0 未知），
	-- energy=21 位相对能量（MMSB 仅低 5 位）。PWD 下拒绝。
	function d:strike(dist, energy)
		if pwd() then return false end
		dist = clampi(dist, 0, 63)
		energy = clampi(energy, 0, 0x1FFFFF)
		regs[REG_INT] = (regs[REG_INT] - regs[REG_INT] % 16) + EVT_LIGHTNING
		regs[REG_DISTANCE] = dist
		regs[REG_EGY_LSB] = energy % 256
		regs[REG_EGY_MSB] = math.floor(energy / 256) % 256
		regs[REG_EGY_MMSB] = math.floor(energy / 65536) % 0x20
		return true
	end

	-- 噪声过高事件（不受 MASK_DIST 影响）
	function d:noise()
		if pwd() then return false end
		regs[REG_INT] = (regs[REG_INT] - regs[REG_INT] % 16) + EVT_NOISE
		return true
	end

	-- 干扰源事件：MASK_DIST=1 时被硬件屏蔽（INT 不置位）
	function d:disturber()
		if pwd() or masked() then return false end
		regs[REG_INT] = (regs[REG_INT] - regs[REG_INT] % 16) + EVT_DISTURBER
		return true
	end

	-- 直接装事件码（喂杂散位/叠加位用例，如 0x0A），不动距离/能量
	function d:set_int_raw(code)
		regs[REG_INT] = (regs[REG_INT] - regs[REG_INT] % 16)
			+ (math.floor(tonumber(code) or 0) % 16)
		return self
	end

	function d:clear_event()
		regs[REG_INT] = regs[REG_INT] - regs[REG_INT] % 16
		return self
	end

	-- 校准失败注入："trco"/"srco"/true=两个都失败，false/nil=清除
	function d:set_calib_fail(which)
		if which == "trco" then
			trco_nok, srco_nok = true, false
		elseif which == "srco" then
			trco_nok, srco_nok = false, true
		elseif which == true then
			trco_nok, srco_nok = true, true
		else
			trco_nok, srco_nok = false, false
		end
		return self
	end

	-- 复位后身份覆写（喂 build "not AS3935?" 负路径；软复位保留，
	-- 完整 reset() 恢复 POR_AFE）
	function d:who(byte)
		if byte ~= nil then
			afe_por = math.floor(tonumber(byte) or 0) % 256
			regs[REG_AFE_GAIN] = afe_por
		end
		return self
	end

	-- 守护逐拍事件脚本：8 拍周期定义当前锁存事件（none 拍清事件）。
	-- 闪电距离 10~35km 按 16 拍正弦、能量 1e5~9e5 按 8 拍正弦。
	function d:virt_tick(n)
		n = math.floor(tonumber(n) or 0)
		local kind = TICK_EVENTS[n % 8]
		if kind == "lightning" then
			local dist = 10 + math.floor(25 * (0.5 + 0.5 * math.sin(2 * math.pi * n / 16)))
			local energy = 100000 + math.floor(800000 * (0.5 + 0.5 * math.sin(2 * math.pi * n / 8 + math.pi / 4)))
			d:strike(dist, energy)
		elseif kind == "noise" then
			d:noise()
		elseif kind == "disturber" then
			d:disturber()			-- 被 mask 时安静无事件（默认配置不 mask）
		else
			d:clear_event()
		end
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		trco_nok, srco_nok = false, false
		return self
	end

	function d:reset_logs()
		write_count, reset_count, rco_count = 0, 0, 0
		write_log = {}
		return self
	end

	-- 重新上电：全状态回 POR（身份/校准失败注入/日志清零）；故障钩子保留
	function d:reset()
		afe_por = POR_AFE
		trco_nok, srco_nok = false, false
		write_count, reset_count, rco_count = 0, 0, 0
		write_log = {}
		read_ptr = nil
		seed_body()
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a) return regs[math.floor(tonumber(a) or 0) % 256] end
	function d:ptr() return read_ptr end
	function d:event() return regs[REG_INT] % 16 end
	function d:pwd() return pwd() end
	function d:mask_dist() return masked() end
	function d:afe_gb() return math.floor((regs[REG_AFE_GAIN] or 0) / 2) % 0x20 end
	function d:nf_lev() return math.floor((regs[REG_THRESHOLD] or 0) / 16) % 8 end
	function d:wdth() return (regs[REG_THRESHOLD] or 0) % 16 end
	function d:min_lig_code() return math.floor((regs[REG_LIGHTNING] or 0) / 16) % 4 end
	function d:srej() return (regs[REG_LIGHTNING] or 0) % 16 end
	function d:tun_cap_code() return (regs[REG_FDISP] or 0) % 16 end
	function d:distance() return regs[REG_DISTANCE] or 0 end
	function d:energy()
		return (regs[REG_EGY_MMSB] or 0) * 65536
			+ (regs[REG_EGY_MSB] or 0) * 256 + (regs[REG_EGY_LSB] or 0)
	end
	function d:trco_status() return regs[REG_CALIB_TRCO] or 0 end
	function d:srco_status() return regs[REG_CALIB_SRCO] or 0 end
	function d:reset_count() return reset_count end
	function d:rco_count() return rco_count end
	function d:write_count() return write_count end
	function d:writes() return write_log end

	return d
end

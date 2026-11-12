-- BH1745NUC 四通道颜色传感器 驱动模块（红/绿/蓝/透明）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BH1745_VIRT（2026-09-15 自 modules/lib/virtbus/bh1745.lua
-- 迁入，单文件驱动+模型实验第三十八个，双 ROM ID + 小端四通道族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- ROHM，I2C 地址 0x38/0x39（ADRSEL 引脚），16 位 ADC x 4 通道
-- 注意：是颜色传感器（RGB 光谱比值），不是 BH1750 照度计
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BH1745 (
--       name    String,
--       I2C     String,
--       address String,
--       mt      String,
--       gain    String
--   );
--   INSERT INTO BH1745 (name, I2C, address, mt, gain)
--     VALUES ('colour0', 'i2c-1', '0x38', '-', '-');
-- mt   = 测量时间 ms（160/320/640/1280/2560/5120，非法值向下降档，缺省 160）
-- gain = ADC 增安比？增益（1/2/16，非法值向下降档，缺省 1）；暗光可开 16，
--        强光下高增益会饱和（通道读数顶到 0xFFFF）
-- 各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回 { result, R, G, B, C }（各通道 16 位原始计
-- 数，无符号；通道间比值才是颜色信息，绝对值受积分时间/增益/光源影响）
-- 接 sensor_daemon：fields=R|G|B|C（无符号，勿配 sign；interval >= mt）
--
-- 实现要点（寄存器/语义依 Pimoroni BH1745-python 库核实，MIT）：
--   1. 甄别双 ID：SYSTEM_CONTROL(0x40)[5:0] Part ID = 0x0B（0b001011）、
--      MANUFACTURER(0x92) = 0xE0，build 软复位后验证
--   2. 寄存器基址 0x40 起（网上老示例按 0x80 起的写法是别的芯片，勿照搬）
--   3. 颜色数据【小端】：datasheet Rev.002 Command Set 逐行明确
--      0x50=RED_DATA_LSBs/0x51=RED_DATA_MSBs（G/B/Clear 同构，LSB 在
--      偶地址）——与 ST/Bosch IMU 小端一致；8 字节一次原子读后按
--      MSB*256+LSB 逐对拆分（早期版本误按大端解码，迁移 virtbus 时
--      照 datasheet 修正）
--   4. 配置分工与直觉不同：MODE_CONTROL1(0x41) 只有测量时间 [2:0]，
--      ADC 增益在 MODE_CONTROL2(0x42)[1:0]（只有 x1/x2/x16 三档，0b11 保留），
--      测量启动 = MODE_CONTROL2 bit4 (RGBC_EN)，数据有效 = bit7 (VALID)
--   5. MODE_CONTROL3(0x44) 写 0x02 启用通道有效判别（Pimoroni 同款）；
--      build 后等一个完整测量时间首拍数据才就绪
--   6. 中断/阈值/持久化（0x60~0x65）本驱动未用（守护周期采样路径不需要）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：采样周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_SYS_CTRL  = 0x40		-- bit7=sw_reset bit6=int_reset [5:0]=part_id
local REG_MODE1     = 0x41		-- [2:0] 测量时间
local REG_MODE2     = 0x42		-- bit7=VALID bit4=RGBC_EN [1:0]=ADC 增益
local REG_MODE3     = 0x44		-- 写 0x02 = 通道有效判别开启
local REG_DATA      = 0x50		-- 8 字节：R/G/B/C 四通道 16 位，MSB 在前
local REG_MFR_ID    = 0x92

local PART_ID       = 0x0B		-- 0b001011
local MFR_ID        = 0xE0
local SW_RESET      = 0x80
local RGBC_EN       = 0x10

-- 测量时间档 ms（MODE1 代码 0..5），缺省 160
local mt_tab = { 160, 320, 640, 1280, 2560, 5120 }
-- ADC 增益（MODE2 代码 0..2），缺省 x1
local gain_tab = { 1, 2, 16 }

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local mt_ms = 160

-- 向下取档：不大于 n 的最大合法档；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

local function mt_code_of(v)
	local i = snap_down(v, mt_tab, 1)
	return i - 1, mt_tab[i]
end

local function gain_code_of(v)
	local i = snap_down(v, gain_tab, 1)
	return i - 1, gain_tab[i]
end

require_driver("i2c", {
	name = "BH1745",

	-- 【配置脚本】软复位 -> 双 ID 甄别 -> 测量时间/增益 -> 启动测量 -> 等首拍
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- BH1745 builder func get a table --------", data)
		end

		-- 列配置
		local mt_code_v, mt_n = mt_code_of(data.mt)
		local gain_code_v, gain_n = gain_code_of(data.gain)
		mt_ms = mt_n

		-----------------------------------------------------
		-- 软复位（bit7 自清，随后系统控制仅剩 Part ID）
		if not i2c_write_reg(fd, REG_SYS_CTRL, SW_RESET) then
			return err("Failed to write BH1745 soft reset")
		end
		milli_sleep(5)

		-- 双 ID 甄别
		local sys = i2c_read_reg(fd, REG_SYS_CTRL)
		local mfr = i2c_read_reg(fd, REG_MFR_ID)
		if sys < 0 or mfr < 0 then
			return err("Failed to read BH1745 ID registers")
		end
		local part = sys % 64		-- [5:0] Part ID（算术取低位）
		if part ~= PART_ID or mfr ~= MFR_ID then
			return err(string.format("Not BH1745: PART_ID=0x%02X (expect 0x0B), MFR_ID=0x%02X (expect 0xE0)",
				part, mfr))
		end

		-- 测量时间（MODE1 [2:0]）+ 增益（MODE2 [1:0]）+ 启动测量（bit4）
		if not i2c_write_reg(fd, REG_MODE1, mt_code_v) then
			return err("Failed to write BH1745 mode control 1")
		end
		if not i2c_write_reg(fd, REG_MODE2, bitc.bor(RGBC_EN, gain_code_v)) then
			return err("Failed to write BH1745 mode control 2")
		end
		if not i2c_write_reg(fd, REG_MODE3, 0x02) then
			return err("Failed to write BH1745 mode control 3")
		end

		-- 等一个完整测量时间，首拍数据就绪
		milli_sleep(mt_n + 2)

		print(string.format("BH1745 init OK: addr=0x%02X, mt=%dms, gain=x%d", addr, mt_n, gain_n))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 BH1745 destroy 仅 arg_table + return OK，等价）


	-- 【调用BH1745】读四通道原始计数
	-- NOTE: 数据小端（0x50=LSB、0x51=MSB，datasheet Rev.002）；一次 8 字节原子读
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- BH1745 caller func get a table --------", data)
		end

		-----------------------------------------------------
		-- 8 字节一次原子读（字节表接口：合并数值接口 6 字节以上超 Lua number 精度）
		local b = i2c_read_multi_bytes(fd, REG_DATA, 8)
		if b == nil then
			return err("Failed to read BH1745 colour data")
		end

		-- 8 字节按小端拆 4 个 16 位通道（偶地址 LSB）：R/G/B/C
		local ret = {
			result = "OK",
			R = b[2] * 256 + b[1],
			G = b[4] * 256 + b[3],
			B = b[6] * 256 + b[5],
			C = b[8] * 256 + b[7]
		}

		if DEBUG then
			print(string.format("BH1745: R=%d G=%d B=%d C=%d", ret.R, ret.G, ret.B, ret.C))
		end

		return ret
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】BH1745_VIRT —— 2026-09-15 自 modules/lib/virtbus/bh1745.lua
-- 整体迁入（单文件驱动+模型第三十八个，双 ROM ID + 命令位自清 + VALID
-- 动态合成 + 小端四通道族，守护 E2E 走 sensor_daemon 回退路径）。约定同
-- 前三十七者：① 生产路径零执行（new() 仅虚拟总线测试调用，纯闭包零外部
-- 依赖）；② 工厂经全局表而非文件 return（生产侧 Lua.cj build_lua 以
-- LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值会滞留 Lua
-- 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。无 BUS 字段
-- = I2C。REG 表/PART_ID/MFR_ID 与 RW_REGS/RO_REGS/clampi 段级辅助随
-- 工厂表暴露（与驱动文件级无同名冲突，无需改名）；new() 内
-- `local bh1745 = BH1745_VIRT` 绑定使模型体零改动移植。
--
-- 定位：ROHM BH1745NUC 四通道颜色传感器模型（双地址 0x38/0x39，纯闭包
-- 不用 regmap、纯算术无 bitcompat）：稀疏字节 regs + ptr——1B 写=纯指针、
-- ≥2B 写流首址起字节自增 mod 256；坏帧整笔 NACK 且指针不动；burst 0xFF
-- 回绕。0x40 SYSTEM_CONTROL POR 0x0B（bit7 SW reset 自清触发 reseed +
-- reset_count++、bit6 INT reset 计数、[5:0] Part ID ROM 0x0B）；0x41
-- MODE1 存 %8；0x42 MODE2 存 bit4×16+%4；0x44 MODE3 写任一 MODE 寄存器
-- 都 restart_meas()（VALID 清 0）；0x50~0x57 RGBC 数据块小端只读 POR 全 0；
-- 0x60 INTERRUPT、0x61 PERSISTENCE POR 0x01、0x62/63 TH POR 0xFFFF、
-- 0x64/65 TL POR 0x0000；0x92 MFR ROM 0xE0；RO 区/未定义地址写 ACK 丢弃、
-- 未定义读 0。bit7 VALID 动态合成：写 MODE 或读 0x42 后清 0、积分周期
-- 到点置 1；advance(ms) 推积分门（enabled=false/forbidden 码不出样）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

BH1745_VIRT = { _VERSION = "0.1.0" }

BH1745_VIRT.REG = {
	SYS  = 0x40,		-- SYSTEM_CONTROL
	M1   = 0x41,		-- MODE_CONTROL1（积分时间）
	M2   = 0x42,		-- MODE_CONTROL2（VALID/RGBC_EN/增益）
	M3   = 0x44,		-- MODE_CONTROL3
	DATA = 0x50,		-- 8B R/G/B/C 小端
	DINT = 0x58,		-- 2B 内部数据（只读）
	INT  = 0x60,		-- INTERRUPT
	PERS = 0x61,		-- PERSISTENCE
	TH_L = 0x62, TH_M = 0x63,
	TL_L = 0x64, TL_M = 0x65,
	MFR  = 0x92,		-- MANUFACTURER ID
}

BH1745_VIRT.PART_ID    = 0x0B
BH1745_VIRT.MFR_ID     = 0xE0
BH1745_VIRT.SW_RESET   = 0x80
BH1745_VIRT.INT_RESET  = 0x40
BH1745_VIRT.RGBC_EN    = 0x10
BH1745_VIRT.MT_TAB     = { 160, 320, 640, 1280, 2560, 5120 }	-- 码 0..5
BH1745_VIRT.I2C_ADDR   = 0x38	-- ADDR=L；ADDR=H = 0x39

-- 寄存器类型表（未列地址 = 未定义：指针写/读 ACK，字写 ACK 丢弃，读 0）
-- rw 可写字节 / ro 只读字节 / sys=SYSTEM_CONTROL（命令位+ROM）
local RW_REGS = {
	[0x41] = true, [0x42] = true, [0x44] = true,
	[0x60] = true, [0x61] = true,
	[0x62] = true, [0x63] = true, [0x64] = true, [0x65] = true,
}
local RO_REGS = {}
for a = 0x50, 0x59 do RO_REGS[a] = true end
RO_REGS[0x92] = true

function BH1745_VIRT.new(opts)
	local bh1745 = BH1745_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local d = {}
	local regs = {}				-- 稀疏字节影子
	local ptr = nil			-- 最近一笔 1B 指针写
	local part_id = opts.part_id or bh1745.PART_ID
	local mfr_id  = opts.mfr_id  or bh1745.MFR_ID
	local valid = false			-- MODE2 bit7 动态值
	local remaining = nil		-- 距本积分周期结束 ms（nil=停转/POR）
	local measure_count = 0		-- 积分完成次数
	local reset_count = 0		-- SW reset（写 0x40 bit7）
	local int_reset_count = 0	-- INT reset（写 0x40 bit6）
	-- 最近一次注入样本（周期到点时装入数据区；u16）
	local sample = { 0, 0, 0, 0 }
	local write_pred, read_pred
	d.write_log = {}

	d.nack = false
	d.nack_read = false
	d.nack_write = false

	-- ---------------- 派生 ----------------

	local function mt_code() return regs[bh1745.REG.M1] % 8 end
	local function period_ms()
		local c = mt_code()
		if c >= #bh1745.MT_TAB then return nil end	-- 码 6/7 forbidden
		return bh1745.MT_TAB[c + 1]
	end
	local function enabled()
		return math.floor(regs[bh1745.REG.M2] / 16) % 2 == 1
	end

	-- ---------------- 数据块装载（小端：LSB 偶地址） ----------------

	local function load_data()
		for i = 0, 3 do
			local u = clampi(sample[i + 1], 0, 65535) % 65536
			regs[0x50 + i * 2]     = u % 256		-- LSB
			regs[0x50 + i * 2 + 1] = math.floor(u / 256)	-- MSB
		end
	end

	-- 写 MODE_CONTROL1/2/3：进行中的测量立即中止、从头重启、VALID 清 0
	local function restart_meas()
		valid = false
		if enabled() and period_ms() then
			remaining = period_ms()
		else
			remaining = nil
		end
	end

	-- ---------------- POR / 软复位 ----------------

	local function seed_regs()
		regs = {}
		regs[bh1745.REG.SYS]  = part_id
		regs[bh1745.REG.M1]   = 0x00
		regs[bh1745.REG.M2]   = 0x00
		regs[bh1745.REG.M3]   = 0x00
		for a = 0x50, 0x59 do regs[a] = 0 end
		regs[bh1745.REG.INT]  = 0x00
		regs[bh1745.REG.PERS] = 0x01
		regs[bh1745.REG.TH_L] = 0xFF
		regs[bh1745.REG.TH_M] = 0xFF
		regs[bh1745.REG.TL_L] = 0x00
		regs[bh1745.REG.TL_M] = 0x00
		regs[bh1745.REG.MFR]  = mfr_id
	end

	-- SW reset：全部寄存器回 POR、power down（VALID 清、门停），
	-- 注入样本清零、计数归零；故障钩子/who 身份保留由调用方约束（reseed
	-- 用当前 part/mfr 播种）
	local function reseed()
		seed_regs()
		ptr = nil
		valid = false
		remaining = nil
		measure_count = 0
		sample = { 0, 0, 0, 0 }
	end

	seed_regs()

	-- ---------------- 单字节寄存器写（含命令/只读/保留语义） ----------------

	local function write_one(reg, val)
		val = val % 256
		if reg == bh1745.REG.SYS then
			-- bit7 SW reset 优先：全片回 POR（datasheet：所有寄存器复位、
			-- power down）；bit6 INT reset 只抬 INT 脚；两位都自清，
			-- [5:0] Part ID 只读——读回恒 part_id
			if val >= 0x80 then
				reseed()
				reset_count = reset_count + 1
			elseif val >= 0x40 then
				int_reset_count = int_reset_count + 1
			end
			regs[bh1745.REG.SYS] = part_id
			return
		end
		if reg == bh1745.REG.M1 then
			regs[reg] = val % 8			-- [7:3] 保留抹
			restart_meas()
			return
		end
		if reg == bh1745.REG.M2 then
			-- bit7 VALID 只读不写；[6:5]/[3:2] 保留抹；bit4+[1:0] 照存
			regs[reg] = (math.floor(val / 16) % 2) * 16 + val % 4
			restart_meas()
			return
		end
		if reg == bh1745.REG.M3 then
			regs[reg] = val			-- datasheet 仅要求写 0x02
			restart_meas()
			return
		end
		if reg == bh1745.REG.INT then
			-- bit7/[6:5] 只读、bit1 保留抹；bit4/[3:2]/bit0 照存
			regs[reg] = (math.floor(val / 16) % 2) * 16
			          + (math.floor(val / 4) % 4) * 4
			          + val % 2
			return
		end
		if reg == bh1745.REG.PERS then
			regs[reg] = val % 4		-- [7:2] 保留抹
			return
		end
		if RW_REGS[reg] then
			regs[reg] = val			-- 阈值字节照存（LSB 先）
			return
		end
		-- RO_REGS 与未定义地址：写 ACK 丢弃（测量值只能由注入 API 改）
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		for i = 1, #bytes do
			local b = bytes[i]
			if type(b) ~= "number" or b ~= b or b < 0 or b > 0xFF
				or math.floor(b) ~= b then
				return false			-- 坏帧（非字节）整笔 NACK
			end
		end
		-- 1B = 纯指针写（任何地址 ACK，读时才从该址起 burst）
		ptr = bytes[1]
		-- ≥2B：寄存器写流，地址自增 mod 256（驱动恒发恰 2B 单寄存器写）
		for i = 2, #bytes do
			write_one((bytes[1] + i - 2) % 256, bytes[i])
		end
		return true
	end

	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if n > 16 then n = 16 end
		if ptr == nil then return nil end	-- 无指针纯读 NACK
		if read_pred and read_pred(ptr, n) then return nil end
		local out = {}
		for _ = 1, n do
			local a = ptr
			if a == bh1745.REG.M2 then
				-- VALID 动态合成；且 datasheet：读 MODE_CONTROL2 后 VALID 清 0
				out[#out + 1] = (regs[a] or 0) % 128 + (valid and 0x80 or 0)
				valid = false
			elseif a == bh1745.REG.SYS then
				out[#out + 1] = regs[a] or part_id	-- 命令位自清，恒 Part ID
			else
				out[#out + 1] = regs[a] or 0
			end
			ptr = (ptr + 1) % 256			-- burst 自增、0xFF 回绕
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- 四通道原始计数（u16，立即装数据区并记为后续周期样本）
	function d:set_rgbc_raw(r, g, b, c)
		sample = {
			clampi(r, 0, 65535), clampi(g, 0, 65535),
			clampi(b, 0, 65535), clampi(c, 0, 65535),
		}
		load_data()
		return self
	end
	function d:set_red_raw(v)   sample[1] = clampi(v, 0, 65535); load_data(); return self end
	function d:set_green_raw(v) sample[2] = clampi(v, 0, 65535); load_data(); return self end
	function d:set_blue_raw(v)  sample[3] = clampi(v, 0, 65535); load_data(); return self end
	function d:set_clear_raw(v) sample[4] = clampi(v, 0, 65535); load_data(); return self end

	-- 配置/阈值等协议字节留测试直注入口
	function d:set_reg(a, v)
		a = clampi(a, 0, 255)
		regs[a] = clampi(v, 0, 255)
		return self
	end

	-- ---------------- 积分周期门（协议测试用；守护不驱动） ----------------

	-- 推虚拟时钟：连续测量下周期到点 → 装载注入样本、VALID 置 1、排下周期
	function d:advance(ms)
		ms = tonumber(ms) or 0
		while enabled() and remaining ~= nil do
			remaining = remaining - ms
			if remaining > 0 then break end
			load_data()
			valid = true
			measure_count = measure_count + 1
			if period_ms() then
				remaining = remaining + period_ms()
			else
				remaining = nil
			end
			ms = 0					-- 后续周期只走补偿后的 remaining
		end
		return self
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期一组典型室内反射色计数（x1 量程内远不削顶）：
	-- R 22000±3000、G 26000±3500、B 15000±2200、C 42000±4000 同相正弦，
	-- 直接装数据区并置 VALID=1（绕过积分门预武装；build 的 MODE 写会把
	-- VALID 清 0 但不清数据，驱动不读 VALID，call 恒有新鲜数据零睡眠）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		self:set_rgbc_raw(
			math.floor(22000 + 3000 * s + 0.5),
			math.floor(26000 + 3500 * s + 0.5),
			math.floor(15000 + 2200 * s + 0.5),
			math.floor(42000 + 4000 * s + 0.5)
		)
		valid = true
		return self
	end

	-- ---------------- 身份/故障钩子/复位 ----------------

	-- 覆写 ROM ID（part/mfr 任一 nil=该项不改；软复位不恢复，section 显式复原）
	function d:who(part, mfr)
		if part ~= nil then
			part_id = clampi(part, 0, 63)	-- Part ID 仅 [5:0]
			regs[bh1745.REG.SYS] = part_id
		end
		if mfr ~= nil then
			mfr_id = clampi(mfr, 0, 255)
			regs[bh1745.REG.MFR] = mfr_id
		end
		return self
	end

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

	-- 回上电态（保留 who 身份与故障钩子——复位不得解除故障注入）
	function d:reset()
		reseed()
		reset_count, int_reset_count = 0, 0
		self.write_log = {}
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a) return regs[clampi(a, 0, 255)] or 0 end
	function d:ptr() return ptr end
	function d:part_id() return part_id end
	function d:mfr_id() return mfr_id end
	function d:valid() return valid end
	function d:enabled() return enabled() end
	function d:mt_code() return mt_code() end
	function d:gain_code() return regs[bh1745.REG.M2] % 4 end
	function d:period_ms() return period_ms() end
	function d:remaining_ms() return remaining end
	function d:measure_count() return measure_count end
	function d:reset_count() return reset_count end
	function d:int_reset_count() return int_reset_count end

	-- 数据区四通道 u16（小端拼字）
	function d:red_raw()   return (regs[0x51] or 0) * 256 + (regs[0x50] or 0) end
	function d:green_raw() return (regs[0x53] or 0) * 256 + (regs[0x52] or 0) end
	function d:blue_raw()  return (regs[0x55] or 0) * 256 + (regs[0x54] or 0) end
	function d:clear_raw() return (regs[0x57] or 0) * 256 + (regs[0x56] or 0) end
	function d:rgbc_raw()
		return self:red_raw(), self:green_raw(), self:blue_raw(), self:clear_raw()
	end

	-- 阈值对（LSB 在偶地址）
	function d:th() return (regs[0x63] or 0) * 256 + (regs[0x62] or 0) end
	function d:tl() return (regs[0x65] or 0) * 256 + (regs[0x64] or 0) end

	-- 驱动 build/call 写过的寄存器写 {reg,val}（≥2B 事务的首两字节）
	function d:config_writes()
		local out = {}
		for _, e in ipairs(self.write_log) do
			if #e >= 2 then
				out[#out + 1] = { reg = e[1], val = e[2] }
			end
		end
		return out
	end

	return d
end

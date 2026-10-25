-- MT6826S 15 位磁编码器 驱动模块（SPI 模式 3，麦歌恩 AMR 在轴安装）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MT6826S_VIRT（2026-09-15 自 modules/lib/virtbus/mt6826s.lua
-- 迁入，单文件驱动+模型实验第十七个，SPI 全双工族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE SPI (
--       name String, path String, spi_mode String, bits String, speed String, delay String
--   );
--   INSERT INTO SPI (name, path, spi_mode, bits, speed, delay)
--     VALUES ('spi-0', '/dev/spidev0.0', '3', '8', '1000000', '0');
--   CREATE TABLE MT6826S (
--       name String,
--       SPI  String,
--       zero String
--   );
--   INSERT INTO MT6826S (name, SPI, zero) VALUES ('enc-0', 'spi-0', '-');
-- @SPI 的 spi_mode 必须配 3（CPOL=1 CPHA=1，数据手册 8.6.2）；时钟周期下限
--   64ns（约 15MHz），建议 1MHz 起步；bits 配 8
-- zero = 零位偏移（°）：输出 = (原始角 - zero) mod 360，关节安装偏移用；
--   芯片级零位（ZERO_POS 寄存器 0x009/0x00A + EEPROM 固化）请按手册 8.8.6
--   流程操作，本驱动不写 EEPROM
--
-- call 无需参数，返回
--   { result, ANGLE(°, 0~360, 已扣 zero), RAW(15 位原始码), STATUS(0~7), CRC_OK }
--   STATUS 位（0=正常）：bit0 超速告警 bit1 磁场弱告警 bit2 欠压告警；
--   CRC_OK=0 表示帧校验失败（已重试一次仍失败），数值照常返回交消费者决策
--   （同 SGP30 CRC_OK 契约）
--
-- 实现要点（依官方数据手册 Rev1.1 第 8.6/11 章，本地逐页核对）：
--   1. 24 位帧 = 命令 4 位 + 地址 12 位 + 数据 8 位：读 0011 / 写 0110 /
--      烧 EEPROM 1100 / 连续角度读 1010。MISO 在命令+地址段为 Hi-Z，数据在末字节
--   2. 角度寄存器（只读）：0x003=ANGLE[14:7]，0x004=ANGLE[6:0]<<1（bit0 恒 0），
--      0x005=高 5 位恒 0 + STATUS[2:0]，0x006=CRC。CSN 下降沿锁存四寄存器快照
--   3. CRC-8（多项式 0x07，MSB 先行）覆盖 0x003~0x005 共 24 位；手册未写明
--      初值，按 MT68xx 家族惯例取 0x00——若真机 CRC_OK 恒 0 请反馈核对
--   4. 读帧需同帧收发（MOSI 命令 + MISO 数据在末字节），走 HAL 全局全双工
--      原语 spi_xfer_full（1 基字节表进/等长接收表出），virtbus 可同帧注入
--   5. 逐寄存器读（0x003~0x006 各一帧）：锁存语义下快照跨 CSN 保持，CRC
--      校验兜底一致性；不匹配自动重读一轮

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：编码器逐拍读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令与寄存器 ====================
local CMD_READ  = 0x3			-- 0011 读寄存器
local REG_ANGLE_H = 0x003		-- ANGLE[14:7]
local REG_ANGLE_L = 0x004		-- ANGLE[6:0]<<1（bit0 恒 0）
local REG_STATUS  = 0x005		-- [7:3]恒 0，[2:0]STATUS
local REG_CRC     = 0x006		-- CRC（覆盖 0x003~0x005）

local ANGLE_MAX = 32768			-- 15 位满量程（360°）

-- 读一个寄存器：24 位帧 [0011|A11..A8, A7..A0, dummy]，全双工同帧收发，
-- MISO 在命令+地址段为 Hi-Z，数据在末字节（rx[3]）
local function read_reg(fd, reg, delay_us)
	local rx = spi_xfer_full(fd,
		{ CMD_READ * 16 + math.floor(reg / 256) % 16, reg % 256, 0x00 }, delay_us)
	if rx == nil then return nil end
	return rx[3]
end

-- CRC-8：多项式 0x07，初值 0x00，MSB 先行（覆盖 0x003~0x005 三字节）
-- CRC 判据单点在 bitcompat.crc8（D1 收敛，2026-09-25）：poly 0x07、init 0x00、
-- 字节表直入——器件约定留在调用方。
local function crc8(bytes)
	return bitc.crc8(0x00, 0x07, bytes)
end

-- ==================== 模块级配置 ====================
local dev_delay		-- @SPI 矩阵的传输延时（us），随 fd 从元数据流入
local cfg_zero		-- 零位偏移（°）

-- 读一组角度快照（四寄存器），校验固定位与 CRC；失败返回 nil
local function read_snapshot(fd)
	local h = read_reg(fd, REG_ANGLE_H, dev_delay)
	if h == nil then return nil end
	local l = read_reg(fd, REG_ANGLE_L, dev_delay)
	local st = read_reg(fd, REG_STATUS, dev_delay)
	local crc = read_reg(fd, REG_CRC, dev_delay)
	if l == nil or st == nil or crc == nil then return nil end
	-- 固定值校验：0x004 bit0 恒 0，0x005 高 5 位恒 0（协议一致性 + 在位佐证）
	if l % 2 ~= 0 then return nil end
	if math.floor(st / 8) ~= 0 then return nil end
	local raw = h * 128 + math.floor(l / 2)
	local ok = (crc8({ h, l, st }) == crc)
	return raw, st, ok
end

-- ==================== 配置脚本 ====================
-- 无运行时配置寄存器可写（EEPROM 项零位/线数等按手册用编程流程），仅做在位自检
require_driver("spi", {
name = "MT6826S",
build = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- MT6826S builder func get a table --------", data)
	end

	-- 两列经 num_or/finite_of 而非裸 tonumber：'nan' 过 tonumber 出的是 number
	-- （Lua 里 truthy），`or 0` 兜不住，下面 and/or 链里的 `z ~= nil`、`z ~= 0`
	-- 与末尾的 `NaN or 0` 也全都兜不住。cfg_zero/dev_delay 都是模块级状态：
	-- cfg_zero=NaN 会让每次 call 的 `cfg_zero ~= 0` 恒真，ANGLE 被 (deg - NaN)
	-- % 360 永久污染成 nan；dev_delay=NaN 则流进 read_reg 的延时参数，并被横幅
	-- 的 %d 打成 -9223372036854775808（string.format 对 NaN 不报错，只出垃圾）。
	dev_delay = num_or(data.delay, 0)

	local z = finite_of(data.zero)
	cfg_zero = (z ~= nil and z ~= 0) and z % 360 or 0

	-- 在位自检：读固定值寄存器（0x005 高 5 位恒 0；0x004 bit0 恒 0）
	local raw, st, ok = read_snapshot(fd)
	if raw == nil then
		return err("MT6826S not responding (fixed-bit check failed, check SPI mode 3 and wiring)")
	end

	print(string.format("MT6826S init OK: fd=%d delay=%dus zero=%.1fdeg status=%d crc_ok=%s",
		fd, dev_delay, cfg_zero, st, tostring(ok)))
	return {  result = "OK"  }

	end,

-- ==================== 调用 ====================
-- 读一次角度快照；CRC 失败自动重读一轮，仍失败置 CRC_OK=0
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- MT6826S caller func get a table --------", data)
	end

	local raw, st, ok = read_snapshot(fd)
	if raw == nil or not ok then
		-- 传输失败/固定位违例/CRC 不符（快照撕裂特征）：整轮重试一次
		raw, st, ok = read_snapshot(fd)
	end
	if raw == nil then
		return err("MT6826S not responding (read failed)")
	end

	local deg = raw * 360.0 / ANGLE_MAX
	if cfg_zero ~= nil and cfg_zero ~= 0 then
		deg = (deg - cfg_zero) % 360
	end

	return {
		result = "OK",
		ANGLE = deg,
		RAW = raw,
		STATUS = st,
		CRC_OK = ok and 1 or 0
	}

end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MT6826S_VIRT —— 2026-09-15 自 modules/lib/virtbus/mt6826s.lua
-- 整体迁入（单文件驱动+模型第十七个，SPI 全双工 spi_xfer_full 族，守护 E2E
-- 走 sensor_daemon 回退路径）。约定同前十六者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用；位运算经本文件 mpath 上值惰性 dofile bitcompat、失败
-- 退化纯算术，不共用驱动 bitc；命令/寄存器常量移入 new() 内避让）；② 工厂
-- 经全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载
-- 驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持
-- 独立实现，互证防假绿性质不变。工厂表带 BUS="spi"。
--
-- 对应真实驱动 modules/MT6826S.lua（SPI Mode 3，CPOL=1/CPHA=1，bits=8）。
-- 模型只存协议事实层：24 位帧结构、角度四寄存器布局、固定位、CRC-8；
-- 角度换算 raw*360/32768 只存在于真实驱动，本模型给 15 位原始码与度数逆注入。
--
-- 挂载（SPI 路径即片选身份）：
--   vbus.load_driver("modules/MT6826S.lua")  -- 定义全局 build/call/destroy 与 MT6826S_VIRT
--   local dev = MT6826S_VIRT.new()
--   vbus.attach_spi("MT6826S", "/dev/spidev0.0", dev)
--
-- 24 位帧 = 命令 4 位 + 地址 12 位 + 数据 8 位（手册第 11 章）：
--   读 0011(0x3) / 写 0110(0x6) / 烧 EEPROM 1100(0xC) / 连续角度读 1010(0xA)
--   MOSI：{cmd*16 + addr_hi, addr_lo, dummy}；MISO 命令+地址段 Hi-Z，
--   数据在第 3 字节。驱动只用读命令（不写寄存器/不烧 EEPROM），模型只把
--   读路径建完整；其余命令解析留痕、MISO 保持 0（协议事实未用到即不声称）。
--
-- 角度寄存器（只读，CSN 下降沿锁存四寄存器快照，逐寄存器读跨 CSN 一致）：
--   0x003 = ANGLE[14:7]
--   0x004 = ANGLE[6:0]<<1，bit0 恒 0
--   0x005 = 高 5 位恒 0 + STATUS[2:0]（bit0 超速/bit1 磁场弱/bit2 欠压，0 正常）
--   0x006 = CRC-8（poly 0x07、init 0x00、MSB first，覆盖 0x003~0x005）
-- 驱动四帧为一组读同一快照；模型里 angle/status 只由注入 API/virt_tick 改变，
-- 组内四帧天然取自同一 upvalue，锁存一致性自动成立。
-- =====================================================================

MT6826S_VIRT = { _VERSION = "0.1.0", BUS = "spi" }

function MT6826S_VIRT.new()
	-- 位运算：独立 dofile bitcompat（不经驱动的 bitc 局部量，保互证独立）；
	-- 失败退化为纯算术兜底（必须 Lua 5.1 语法，LuaJIT 解析期不认 &/^/<<）。
	local band, bxor, lshift
	local ok_bc, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
	if ok_bc then
		band, bxor, lshift = bc.band, bc.bxor, bc.lshift
	end
	if not band then
		local function b_and(a, b)
			local r, p = 0, 1
			while a > 0 and b > 0 do
				if a % 2 == 1 and b % 2 == 1 then r = r + p end
				a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
			end
			return r
		end
		local function b_xor(a, b)
			local r, p = 0, 1
			while a > 0 or b > 0 do
				local x, y = a % 2, b % 2
				if x ~= y then r = r + p end
				a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
			end
			return r
		end
		band = b_and
		bxor = b_xor
		lshift = function(a, n) return a * 2 ^ n end
	end

	-- ==================== 命令 / 寄存器（与驱动一致）====================
	local CMD_READ = 0x3			-- 0011 读寄存器
	local REG_ANGLE_H = 0x003		-- ANGLE[14:7]
	local REG_ANGLE_L = 0x004		-- ANGLE[6:0]<<1（bit0 恒 0）
	local REG_STATUS  = 0x005		-- [7:3]恒 0，[2:0]STATUS
	local REG_CRC     = 0x006		-- CRC（覆盖 0x003~0x005）

	local ANGLE_MAX = 32768			-- 15 位满量程（360°），有效码 0~32767

	-- CRC-8：多项式 0x07，初值 0x00，MSB 先行；公开供测试与驱动三方交叉
	local function crc8(bytes)
		local crc = 0x00
		for _, b in ipairs(bytes) do
			crc = bxor(crc, b)
			for _ = 1, 8 do
				if band(crc, 0x80) ~= 0 then
					crc = bxor(band(lshift(crc, 1), 0xFF), 0x07)
				else
					crc = band(lshift(crc, 1), 0xFF)
				end
			end
		end
		return crc
	end

	local self = {}

	-- ---- 器件状态 ----
	local angle15 = 0			-- 当前角度快照（15 位原始码 0~32767）
	local status_bits = 0		-- STATUS[2:0]（0=正常）
	local read_count = 0		-- 累计读帧计数（4 帧一组）
	local frames = {}			-- 帧流水 {cmd=, addr=}

	-- ---- 故障注入 ----
	local crc_always_bad = false	-- 持续坏 CRC（CRC_OK=0，数值照常）
	local bad_arm_group = -1		-- 坏 CRC 组区间下界（武装时所处组号）
	local bad_end_group = -1		-- 坏 CRC 组区间上界（不含）
	local bad_fixed_l = false		-- 0x004 bit0 固定位违例
	local bad_fixed_st = false		-- 0x005 高 5 位固定位违例
	local fail_persistent = false	-- 持续传输失败（xfer 返 nil）
	local fail_pred = nil			-- function(tx) → true 则本帧失败

	-- ===================== 注入 API =====================

	-- 注入 15 位原始角码（钳到 0~32767；码空间无负值，超界钳制而非回绕）
	function self:set_angle_raw(v)
		v = math.floor(tonumber(v) or 0)
		if v < 0 then v = 0 elseif v > ANGLE_MAX - 1 then v = ANGLE_MAX - 1 end
		angle15 = v
		return self
	end

	-- 便捷 API：按物理角度反推原始码（先归一化到 [0,360)，再四舍五入）。
	-- 仅做注入逆变换；正算 raw*360/32768 归驱动，模型不含该公式。
	function self:set_angle_deg(deg)
		deg = (tonumber(deg) or 0) % 360
		angle15 = math.floor(deg * ANGLE_MAX / 360 + 0.5) % ANGLE_MAX
		return self
	end

	function self:angle_raw() return angle15 end

	-- STATUS[2:0]：bit0 超速 / bit1 磁场弱 / bit2 欠压，钳 0~7
	function self:set_status(s)
		s = math.floor(tonumber(s) or 0)
		if s < 0 then s = 0 elseif s > 7 then s = 7 end
		status_bits = s
		return self
	end
	function self:status() return status_bits end

	-- ---- CRC / 固定位故障 ----
	function self:corrupt_crc(on) crc_always_bad = (on ~= false); return self end
	-- 从「下一帧所在组」起连续 n 个读组（四帧一组）CRC 坏（固定半开区间
	-- [arm, arm+n)，不随后续帧消减）；build 已耗一组后武装，组号按武装瞬间
	-- read_count 锚定——call 注 1 组即「首组坏、重试组好」
	function self:corrupt_next_groups(n)
		bad_arm_group = math.floor(read_count / 4)
		bad_end_group = bad_arm_group + math.floor(tonumber(n) or 0)
		return self
	end
	function self:bad_fixed_l(on) bad_fixed_l = (on ~= false); return self end
	function self:bad_fixed_st(on) bad_fixed_st = (on ~= false); return self end

	-- ---- 传输层故障 ----
	function self:fail_transfer(on) fail_persistent = (on ~= false); return self end
	function self:fail_when(pred) fail_pred = pred; return self end
	function self:clear_faults()
		crc_always_bad = false
		bad_arm_group = -1
		bad_end_group = -1
		bad_fixed_l = false
		bad_fixed_st = false
		fail_persistent = false
		fail_pred = nil
		return self
	end

	-- ===================== 留痕 / 复位 API =====================

	function self:frames() return frames end
	function self:read_count() return read_count end
	function self:crc8(bytes) return crc8(bytes) end
	function self:reset_logs()
		frames = {}
		read_count = 0
		return self
	end

	-- 器件状态复位（回零位/正常状态/清日志）；不清故障注入钩子——硬件复位
	-- 语义上修不好总线故障，若 reset 清钩子，负路径 section 重开时会假绿
	-- （同 ads1256 模型约定）。
	function self:reset()
		angle15 = 0
		status_bits = 0
		frames = {}
		read_count = 0
		return self
	end

	-- ===================== 全双工帧核心 =====================

	-- 组装某地址读帧的末字节（含固定位/CRC 注入）。h/l/st 同取自当前快照
	-- upvalue：一次 read_snapshot 的四帧之间无注入介入即严格一致（CSN 锁存）。
	-- corrupt 为本组 CRC 是否翻转（由 xfer 按组号/配额判定后传入）。
	local function read_byte(addr, corrupt)
		local h = math.floor(angle15 / 128) % 256
		local l = (angle15 % 128) * 2
		local st = status_bits % 8
		if bad_fixed_l then l = l + 1 end			-- bit0 翻 1（l 最大 254，+1 不溢出）
		if bad_fixed_st then st = st + 8 end		-- [7:3] 出现非零位
		if addr == REG_ANGLE_H then return h end
		if addr == REG_ANGLE_L then return l end
		if addr == REG_STATUS then return st end
		if addr == REG_CRC then
			local c = crc8({ h, l, st })
			if corrupt then c = bxor(c, 0xA5) end
			return c
		end
		return 0
	end

	-- xfer(tx)：点定义、无 self 参数（virtbus attach 动态委托契约）。
	-- 入参 1 基 MOSI 表（驱动恒 3 字节），返回等长 MISO 表；nil/false = 帧失败。
	local function xfer(tx)
		if fail_persistent then return nil end
		if type(fail_pred) == "function" and fail_pred(tx) then return nil end

		local n = #tx
		local rx = {}
		for i = 1, n do rx[i] = 0 end
		if n ~= 3 then
			-- 24 位定长协议之外的帧形：MISO 保持 Hi-Z 读回 0，不声称行为
			return rx
		end

		local cmd = math.floor(tx[1] / 16) % 16
		local addr = (tx[1] % 16) * 256 + tx[2]
		frames[#frames + 1] = { cmd = cmd, addr = addr }

		if cmd == CMD_READ then
			-- 组计数在取数之前：0x003/4/5/6 四帧共享同一组号；坏 CRC 配额是
			-- 武装时锚定的固定半开区间，build 耗掉的组不会让 call 边界错位
			local group = math.floor(read_count / 4)
			local quota_bad = group >= bad_arm_group and group < bad_end_group
			rx[3] = read_byte(addr, crc_always_bad or quota_bad)
			read_count = read_count + 1
		end
		-- 写 0110 / 烧 EEPROM 1100 / 连续读 1010：驱动不用，解析留痕即可，
		-- MISO 命令+地址段本就 Hi-Z、数据段未定义，保持 0。
		return rx
	end
	self.xfer = xfer

	-- ===================== 守护节拍（确定性合成波形）====================
	-- 32 拍一周的线性角度爬坡：第 m 拍角度 m*360/32（11.25° 步进），
	-- 0~359.99° 全覆盖、确定无随机；守护 build 前自动 virt_tick(0) 预武装
	-- （零位，build 固定位自检照过）。无转换门/无睡眠，装码即可读。
	function self:virt_tick(n)
		n = tonumber(n) or 0
		local m = n % 32
		self:set_angle_deg(m * 360 / 32)
		return self
	end

	return self
end

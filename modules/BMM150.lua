-- BMM150 三轴地磁传感器 驱动模块（上电挂起态 + 工厂 trim 温度补偿）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BMM150_VIRT（2026-09-15 自 modules/lib/virtbus/bmm150.lua
-- 迁入，单文件驱动+模型实验第三十一个，挂起电源门 + trim NVM 族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Bosch Sensortec，I2C 地址 0x10/0x11/0x12/0x13（CSB/SDO 引脚四组合，
-- 模块常见 0x10/0x11），XY ±1300µT / Z ±2500µT，13 位 + RHALL
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BMM150 (
--       name    String,
--       I2C     String,
--       address String,
--       preset  String
--   );
--   INSERT INTO BMM150 (name, I2C, address, preset)
--     VALUES ('mag0', 'i2c-1', '0x10', '-');
-- preset = 'lowpower | 'regular | 'enhanced | 'highaccuracy（缺省 regular），
--   四种 preset 对应 ODR/重复次数表：10/10/10/20Hz，rep_xy 1/4/7/23，
--   rep_z 1/7/13/41（依 Bosch bmm150_set_presetmode 钉死）；'-' 缺省
--
-- call 无需额外参数，返回 { result, X, Y, Z }（补偿后微特斯拉浮点）。
-- 三轴补偿管线均以 /16 收尾（compensate_x/y 的末步与 compensate_z 的
-- 「LSB -> micro-tesla」换算同构），输出即 µT——依 Bosch BMM150_SensorAPI
-- master 的 int16 compensate_* 文档「data(micro-tesla) in int16_t」钉死，
-- 勿再乘缩放系数；溢出/饱和异常轴为 nil（原始码 -4096(XY)/-16384(Z)
-- 或 RHALL/trim 不可用）
-- 接 sensor_daemon：fields=X|Y|Z（浮点透传，勿配 sign）
--
-- 实现要点（寄存器/公式依 Bosch BMM150_SensorAPI master 逐行核实）：
--   1. 上电序列与所有常规芯片相反：复位后芯片处于 suspend 挂起态，
--      必须先写 0x4B bit0=1（Power Control）再等 3ms，才能读 CHIP_ID
--      （0x40 = 0x32）与 trim 寄存器
--   2. 工厂 trim 16 字节三段直读：0x5Dx2（dig_x1/y1）、0x62x4（dig_z4、
--      dig_x2、dig_y2）、0x68x10（dig_z2、dig_z1、dig_z3、dig_xy2、
--      dig_xyz1、dig_xy1），逐字节拼装含符号/掩码（0x68+5 字节高位置 0x7F）
--   3. 数据 0x42 起 8 字节：X/Y = 13 位（LSB&0xF8>>3 + MSB 有符号 x32）、
--      Z = 13 位（LSB&0xFE>>1 + MSB 有符号 x128）、RHALL = 14 位无符号
--      （LSB&0xFC>>2 + MSB x64）；原始码 -4096(XY)/-16384(Z) = 溢出
--   4. 温度补偿：Bosch compensate_x/y/z 整数管线逐行移植——C 的除法
--      向零截断（Lua floor 对负数不同，走 idiv 截断助手）、uint16/int16
--      回绕走 u16/s16 助手；黄金向量由 Bosch 原函数 C 编译生成
--      （test/test_bmm150.lua 交叉验证）
--   5. OPMODE(0x4C)：bit[4:3]=ODR（10/2/6/8/15/20/25/30Hz 码 0~7）、
--      bit[2:1]=工作模式（normal=0）；重复次数 0x51(REP_XY)/0x52(REP_Z)
--   6. 无中断/FIFO 路径（守护周期采样不需要）；正常模式典型电流 170µA

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
local REG_CHIP_ID   = 0x40
local REG_DATA      = 0x42		-- X_LSB,X_MSB,Y_LSB,Y_MSB,Z_LSB,Z_MSB,RHALL_LSB,RHALL_MSB
local REG_POWER     = 0x4B		-- bit0=Power Control bit7=Soft Reset
local REG_OP_MODE   = 0x4C		-- bit[4:3]=ODR bit[2:1]=工作模式
local REG_REP_XY    = 0x51
local REG_REP_Z     = 0x52
local REG_DIG_X1    = 0x5D		-- trim 段 1（2 字节）
local REG_DIG_Z4    = 0x62		-- trim 段 2（4 字节）
local REG_DIG_Z2    = 0x68		-- trim 段 3（10 字节）

local CHIP_ID       = 0x32
local POWER_ON      = 0x01
local POWER_ON_RST  = 0x81
local ODR_MSK       = 0x18
local MODE_MSK      = 0x06
local STARTUP_MS    = 3			-- BMM150_START_UP_TIME

-- 溢出与饱和常量（Bosch 原值）
local OV_XY   = -4096
local OV_Z    = -16384
local SAT_Z_P = 32767
local SAT_Z_N = -32767

-- 预设模式表（odr 码 / REP_XY / REP_Z，依 bmm150_set_presetmode）
local PRESETS = {
	lowpower     = { odr = 0x00, rxy = 0x01, rz = 0x01 },
	regular      = { odr = 0x00, rxy = 0x04, rz = 0x07 },
	enhanced     = { odr = 0x00, rxy = 0x07, rz = 0x0D },
	highaccuracy = { odr = 0x05, rxy = 0x17, rz = 0x29 },
}
local PRESET_ODR_HZ = { [0x00] = 10, [0x05] = 20 }

-- 模块级状态（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local trim = nil

-- ==================== C 语义算术助手 ====================
-- 截断除法：C 整数除法向零截断，Lua floor 对负数向 -inf，负数路径必须走 idiv
local function idiv(a, b)
	local q = a / b
	if q >= 0 then return math.floor(q) end
	return math.ceil(q)
end
-- uint16/int16/int8 回绕（Bosch 公式中的显式窄化转换）
local function u16(v) return v % 0x10000 end
local s16 = function(v) return bitc.s16(v % 0x10000) end
local s8 = function(v) return bitc.s8(v % 0x100) end

-- ==================== trim 寄存器解析 ====================
-- 三段直读 0x5Dx2 / 0x62x4 / 0x68x10，拼装依 bmm150.c read_trim_registers
local function read_trim(fd)
	local t1 = i2c_read_multi_bytes(fd, REG_DIG_X1, 2)
	if t1 == nil then return nil end
	local t2 = i2c_read_multi_bytes(fd, REG_DIG_Z4, 4)
	if t2 == nil then return nil end
	local t3 = i2c_read_multi_bytes(fd, REG_DIG_Z2, 10)
	if t3 == nil then return nil end
	local t = {}
	t.dig_x1 = s8(t1[1])
	t.dig_y1 = s8(t1[2])
	t.dig_z4 = s16(t2[1] + t2[2] * 256)
	t.dig_x2 = s8(t2[3])
	t.dig_y2 = s8(t2[4])
	t.dig_z2 = s16(t3[2] * 256 + t3[1])
	t.dig_z1 = u16(t3[4] * 256 + t3[3])
	t.dig_z3 = s16(t3[8] * 256 + t3[7])
	t.dig_xy2 = s8(t3[9])
	-- dig_xyz1：高字节在 0x68+5 且仅低 7 位有效（&0x7F），低字节在 0x68+4
	t.dig_xyz1 = u16((t3[6] % 0x80) * 256 + t3[5])
	t.dig_xy1 = t3[10]
	return t
end

-- ==================== 温度补偿（Bosch compensate_x/y/z 逐行移植） ====================
local function compensate_x(mag_x, rhall, t)
	local retval = -32768
	if mag_x ~= OV_XY then
		local comp_x0 = 0
		if rhall ~= 0 then comp_x0 = rhall
		elseif t.dig_xyz1 ~= 0 then comp_x0 = t.dig_xyz1 end
		if comp_x0 ~= 0 then
			local x1 = t.dig_xyz1 * 16384
			local x2 = u16(idiv(x1, comp_x0) - 0x4000)	-- uint16 回绕
			retval = s16(x2)
			local x3 = retval * retval
			local x4 = t.dig_xy2 * idiv(x3, 128)
			local x5 = t.dig_xy1 * 128		-- dig_xy1 为 uint8_t（0~255），勿符号扩展
			local x6 = retval * x5
			local x7 = idiv(x4 + x6, 512) + 0x100000
			local x8 = s8(t.dig_x2) + 0xA0
			local x9 = idiv(x7 * x8, 4096)
			local x10 = mag_x * x9
			retval = s16(idiv(x10, 8192))
			retval = idiv(retval + s8(t.dig_x1) * 8, 16)
		end
	end
	return retval
end

local function compensate_y(mag_y, rhall, t)
	local retval = -32768
	if mag_y ~= OV_XY then
		local comp_y0 = 0
		if rhall ~= 0 then comp_y0 = rhall
		elseif t.dig_xyz1 ~= 0 then comp_y0 = t.dig_xyz1 end
		if comp_y0 ~= 0 then
			local y1 = idiv(t.dig_xyz1 * 16384, comp_y0)	-- 与 x 不同：先除后窄化
			local y2 = u16(y1 - 0x4000)
			retval = s16(y2)
			local y3 = retval * retval
			local y4 = t.dig_xy2 * idiv(y3, 128)
			local y5 = t.dig_xy1 * 128		-- dig_xy1 为 uint8_t（0~255），勿符号扩展
			local y6 = idiv(y4 + retval * y5, 512)
			local y7 = s8(t.dig_y2) + 0xA0
			local y8 = idiv((y6 + 0x100000) * y7, 4096)
			local y9 = mag_y * y8
			retval = s16(idiv(y9, 8192))
			retval = idiv(retval + s8(t.dig_y1) * 8, 16)
		end
	end
	return retval
end

local function compensate_z(mag_z, rhall, t)
	local retval = -32768
	if mag_z ~= OV_Z then
		if t.dig_z2 ~= 0 and t.dig_z1 ~= 0 and rhall ~= 0 and t.dig_xyz1 ~= 0 then
			local z0 = s16(rhall) - t.dig_xyz1
			local z1 = idiv(t.dig_z3 * z0, 4)
			local z2 = (mag_z - t.dig_z4) * 32768
			local z3 = t.dig_z1 * (s16(rhall) * 2)
			local z4 = s16(idiv(z3 + 32768, 65536))
			retval = idiv(z2 - z1, t.dig_z2 + z4)
			if retval > SAT_Z_P then retval = SAT_Z_P
			elseif retval < SAT_Z_N then retval = SAT_Z_N end
			retval = idiv(retval, 16)	-- Bosch 原注释：LSB -> micro-tesla 换算
		end
	end
	return retval
end

-- 【配置脚本】上电（挂起态 -> 工作态）-> 验 ID -> trim -> preset + normal
require_driver("i2c", {
name = "BMM150",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- BMM150 builder func get a table --------", data)
	end

	-- 预设模式列（'-' 缺省 regular）
	local pname = string.lower(tostring(data.preset or "regular"))
	if pname == "-" or pname == "" then pname = "regular" end
	local p = PRESETS[pname]
	if p == nil then
		return err("Invalid preset: '" .. tostring(data.preset) ..
				"' (expect lowpower/regular/enhanced/highaccuracy)")
	end

	-----------------------------------------------------
	-- 上电：芯片复位后处于 suspend 挂起态，先写 Power Control 再等 3ms，
	-- 之后才允许读 CHIP_ID / trim
	if not i2c_write_reg(fd, REG_POWER, POWER_ON) then
		return err("Failed to power on BMM150")
	end
	milli_sleep(STARTUP_MS)

	local id = i2c_read_reg(fd, REG_CHIP_ID)
	if id < 0 then
		return err("Failed to read BMM150 CHIP_ID")
	end
	if id ~= CHIP_ID then
		return err(string.format("CHIP_ID = 0x%02X (expect 0x32, not BMM150?)", id))
	end

	-- 工厂 trim 16 字节（补偿必需，无 trim 数据则输出无意义）
	trim = read_trim(fd)
	if trim == nil then
		return err("Failed to read BMM150 trim registers")
	end

	-- 预设：重复次数 + ODR，随后进 normal 模式（bit[2:1] = 0）
	if not i2c_write_reg(fd, REG_REP_XY, p.rxy) then
		return err("Failed to write BMM150 REP_XY")
	end
	if not i2c_write_reg(fd, REG_REP_Z, p.rz) then
		return err("Failed to write BMM150 REP_Z")
	end
	local mode = p.odr * 8		-- ODR 置 bit[4:3] + normal 模式（bit[2:1]=0）
	if not i2c_write_reg(fd, REG_OP_MODE, mode) then
		return err("Failed to write BMM150 OP_MODE")
	end

	print(string.format("BMM150 init OK: addr=0x%02X, preset=%s (odr=%dHz)",
		addr, pname, PRESET_ODR_HZ[p.odr] or 10))
	return {  result = "OK"  }

end,

-- 【调用BMM150】读三轴，补偿换算微特斯拉
-- NOTE: 8 字节一次原子读（字节表接口）；溢出轴返回 nil
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- BMM150 caller func get a table --------", data)
	end

	-----------------------------------------------------
	if trim == nil then
		return err("BMM150 not built (trim data missing)")
	end

	local m = i2c_read_multi_bytes(fd, REG_DATA, 8)
	if m == nil then
		return err("Failed to read BMM150 data")
	end

	-- 13 位有符号拆装（MSB 寄存器存符号扩展位，Bosch 构造法）：
	-- X/Y 字段在 LSB 的 bit[7:3]（>>3 = /8），Z 在 bit[7:1]（>>1 = /2），
	-- RHALL 在 bit[7:2]（>>2 = /4，14 位无符号）
	local x_raw = s8(m[2]) * 32 + math.floor((m[1] % 0x100) / 8)
	local y_raw = s8(m[4]) * 32 + math.floor((m[3] % 0x100) / 8)
	local z_raw = s8(m[6]) * 128 + math.floor((m[5] % 0x100) / 2)
	local rhall = math.floor((m[8] % 0x100) * 64 + (m[7] % 0x100) / 4)

	local x = compensate_x(x_raw, rhall, trim)
	local y = compensate_y(y_raw, rhall, trim)
	local z = compensate_z(z_raw, rhall, trim)

	-- 溢出哨兵 -32768 -> nil（不能用 and/or 惯用法：then 值为 nil 时必落 or 分支）
	-- 三轴管线均已 /16 收尾、输出 µT（见文件头），无需再乘任何系数
	local X, Y, Z
	if x == -32768 then X = nil else X = x end
	if y == -32768 then Y = nil else Y = y end
	if z == -32768 then Z = nil else Z = z end

	local ret = {
		result = "OK",
		X = X,
		Y = Y,
		Z = Z
	}

	if DEBUG then
		print(string.format("BMM150: X=%s Y=%s Z=%s µT",
			tostring(ret.X), tostring(ret.Y), tostring(ret.Z)))
	end

	return ret

end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】BMM150_VIRT —— 2026-09-15 自 modules/lib/virtbus/bmm150.lua
-- 整体迁入（单文件驱动+模型第三十一个，上电挂起电源门 + trim NVM 族，守护
-- E2E 走 sensor_daemon 回退路径）。约定同前三十者：① 生产路径零执行（new()
-- 仅虚拟总线测试调用，纯闭包零外部依赖；寄存器地址/ODR/trim 常数/码表/
-- helper 全部移入 new() 内避让）；② 工厂经全局表而非文件 return（生产侧
-- Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件
-- 返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 定位：【8 位字节指针 + 上电挂起态电源门 + 三段工厂 trim NVM + XY/Z 异构
-- 13/15 位数据块】样板（Bosch BMM150，I2C 地址族 0x10~0x13；纯闭包、纯
-- 算术无 bitcompat）。五处个性：
--   1) 上电 suspend：仅 0x4B 可访问，其余读 0x00、写 ACK 丢弃；写 0x4B
--      bit0=1 进 sleep/active，驱动随后实睡 3ms 才读 CHIP_ID 与 trim。
--   2) 0x4B bit7=软复位（自清不落盘）：易失寄存器回 POR，trim 是 NVM 不丢，
--      CHIP_ID ROM 0x32，who() 覆写跨软复位保留。
--   3) 工厂 trim 16 字节三段（0x5Dx2/0x62x4/0x68x10），0x6D bit7 保留读恒 0；
--      补偿管线在驱动侧，模型只存字节。
--   4) 数据 0x42 起 8 字节小端位域异构：X/Y 13 位有符号（-4096 溢出哨兵）、
--      Z 15 位（-16384 哨兵）、RHALL 14 位无符号；测量区只读。
--   5) normal 连续出数无 data-ready 握手——无转换门/无 advance；virt_tick
--      直接装数据块预武装，call 零真实睡眠。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

BMM150_VIRT = { _VERSION = "0.1.0" }

function BMM150_VIRT.new()
-- ==================== 寄存器地址 / 常量 ====================
local REG_CHIP_ID   = 0x40
local REG_DATA      = 0x42		-- 8B：XL,XH,YL,YH,ZL,ZH,RL,RH 终于 0x49
local REG_POWER     = 0x4B		-- bit0=Power Control, bit7=Soft Reset
local REG_OP_MODE   = 0x4C		-- bit[4:3]=ODR, bit[2:1]=工作模式
local REG_REP_XY    = 0x51
local REG_REP_Z     = 0x52
local REG_DIG_X1    = 0x5D		-- trim 段 1：2B（dig_x1 s8, dig_y1 s8）
local REG_DIG_Z4    = 0x62		-- trim 段 2：4B（z4 s16LE, x2 s8, y2 s8）
local REG_DIG_Z2    = 0x68		-- trim 段 3：10B 终于 0x71
local REG_XYZ1_HI   = 0x6D		-- dig_xyz1 高字节，bit7 保留读恒 0

local CHIP_ID       = 0x32
local STARTUP_MS    = 3

-- ODR 码（OP_MODE bit[4:3]）→ Hz（datasheet 表）
local ODR_HZ = { [0] = 10, [1] = 2, [2] = 6, [3] = 8, [4] = 15, [5] = 20, [6] = 25, [7] = 30 }

-- 模型默认工厂 trim：XY 段取 Bosch C 黄金向量 trimA（典型量级），Z 段取
-- 真实量级大值（dig_z2=4000/dig_z1=30000，使 Z 轴 µT 量化步进 <1µT，
-- virt_tick 正弦平滑）。黄金向量单测会显式 set_trim(trimA/trimB) 覆盖。
local DEFAULT_TRIM = {
	dig_x1 = -32, dig_y1 = -3, dig_x2 = -25, dig_y2 = 250,
	dig_z1 = 30000, dig_z2 = 4000, dig_z3 = 0, dig_z4 = 0,
	dig_xy1 = 137, dig_xy2 = 57, dig_xyz1 = 7920,
}

-- virt_tick 32 拍原始码表（默认工厂 trim、rhall=512 离线反解，逐拍命中
-- 目标 µT 误差 0：X 30±20、Y -12±15、Z -42±18，模型内不含补偿公式）。
-- 离线 codegen 用驱动同款 Bosch 管线搜索 -4095..4095 / -16383..16383。
local TICK_FRAMES = {
	{249,22,-54,512},  {270,22,-54,512},  {292,17,-56,512},  {308,3,-61,512},
	{324,-2,-65,512},  {341,-16,-72,512}, {346,-26,-78,512}, {357,-40,-85,512},
	{357,-54,-93,512}, {357,-68,-102,512},{346,-82,-109,512},{341,-92,-115,512},
	{324,-106,-122,512},{308,-111,-126,512},{292,-120,-130,512},{270,-125,-133,512},
	{249,-125,-133,512},{227,-125,-133,512},{206,-120,-130,512},{189,-111,-126,512},
	{173,-106,-122,512},{157,-92,-115,512},{152,-82,-109,512},{141,-68,-102,512},
	{141,-54,-93,512}, {141,-40,-85,512}, {152,-26,-78,512}, {157,-16,-72,512},
	{173,-2,-65,512},  {189,3,-61,512},   {206,17,-56,512},  {227,22,-54,512},
}

-- ==================== 纯算术助手 ====================
-- X/Y 13 位：LSB=低 5 位<<3、MSB=floor(v/32) 字节（驱动 s8(msb)*32+lsb/8）
local function encode_xy(v)
	v = clampi(v, -4096, 4095)
	return (v % 32) * 8, math.floor(v / 32) % 256
end
-- Z 15 位：LSB=低 7 位<<1、MSB=floor(v/128) 字节
local function encode_z(v)
	v = clampi(v, -16384, 16383)
	return (v % 128) * 2, math.floor(v / 128) % 256
end
-- RHALL 14 位无符号：LSB=低 6 位<<2、MSB=floor(r/64) 字节
local function encode_r(r)
	r = clampi(r, 0, 16383)
	return (r % 64) * 4, math.floor(r / 64) % 256
end

-- （s8 统一走模块级 bitc 包装（第 106 行）。#30：此前此处另有一份独立
-- 实现遮蔽 106 行 bitc 包装——实际运行时用的是这份独立拷贝，属重复造轮子）

-- trim 表 → 16 字节 NVM 布局（拼装顺序严格同驱动 read_trim）
local function trim_bytes(t)
	return {
		[0x5D] = { t.dig_x1 % 256, t.dig_y1 % 256 },
		[0x62] = { t.dig_z4 % 256, math.floor(t.dig_z4 / 256) % 256,
			t.dig_x2 % 256, t.dig_y2 % 256 },
		[0x68] = { t.dig_z2 % 256, math.floor(t.dig_z2 / 256) % 256,
			t.dig_z1 % 256, math.floor(t.dig_z1 / 256) % 256,
			t.dig_xyz1 % 256, math.floor(t.dig_xyz1 / 256) % 128,
			t.dig_z3 % 256, math.floor(t.dig_z3 / 256) % 256,
			t.dig_xy2 % 256, t.dig_xy1 % 256 },
	}
end

	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 字节寄存器影子（稀疏，缺省读 0）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此起 burst）
	local powered = false		-- 0x4B bit0：false=suspend（仅 0x4B 可访问）
	local chip_id = CHIP_ID		-- ROM 身份（who 可覆写，软复位不恢复）
	local trim = DEFAULT_TRIM	-- NVM 当前内容（软复位不丢）
	local reset_count = 0		-- 软复位（写 0x4B bit7）次数
	local write_count = 0		-- ≥2B 写事务笔数
	local write_log = {}		-- ≥2B 写事务 {reg=首地址, bytes=...}

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- 地址派生 ----------------

	local function in_trim(a)
		return a == 0x5D or a == 0x5E
			or (a >= 0x62 and a <= 0x65)
			or (a >= 0x68 and a <= 0x71)
	end
	local function in_data(a) return a >= REG_DATA and a <= 0x49 end

	-- ---------------- POR / 软复位 ----------------

	local function seed_body()
		regs = {}
		regs[0x4B] = 0x00			-- 仅控制寄存器在挂起态有内容
		regs[REG_CHIP_ID] = chip_id
		-- trim NVM 影子（挂起态不可读，上电后可读）
		for base, bytes in pairs(trim_bytes(trim)) do
			for i = 1, #bytes do regs[base + i - 1] = bytes[i] end
		end
		-- 0x42~0x49 数据区 / 0x4C / 0x51 / 0x52 等易失寄存器不播种，读 0
	end

	local function power_off_reset()
		-- 软复位 / 进挂起：易失内容全丢（datasheet：除 0x4B 外全部丢失），
		-- NVM trim 与 ROM 身份保留，重新上电后 trim 仍在
		seed_body()
		read_ptr = nil
	end

	seed_body()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	local function write_byte(a, v)
		v = v % 256
		if a == REG_POWER then
			-- 进挂起（bit0 1→0）或软复位（bit7）：易失内容立即丢失
			-- （datasheet：挂起态除 0x4B 外全部 lose content），NVM/ROM 保留
			local lose = (v >= 0x80) or (powered and v % 2 == 0)
			if v >= 0x80 then
				reset_count = reset_count + 1
				v = v % 0x80			-- bit7 自清不落盘，低 7 位照落
			end
			if lose then power_off_reset() end
			regs[REG_POWER] = v
			powered = (v % 2 == 1)
			return
		end
		if not powered then
			-- 挂起态仅 0x4B 可访问：其余写 ACK 但丢弃（寄存器无内容）
			return
		end
		if a == REG_CHIP_ID or in_data(a) or in_trim(a) then
			-- ROM/只读测量区/NVM：写 ACK 丢弃，测量码只能由注入 API 改
			return
		end
		regs[a] = v
	end

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）：任意地址 ACK 设 ptr
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
		local t = {}
		for i = 1, n do
			local a = read_ptr
			local v
			if not powered and a ~= REG_POWER then
				v = 0					-- 挂起态：CHIP_ID/trim/数据全读 0x00
			else
				v = regs[a] or 0
				if a == REG_XYZ1_HI then v = v % 0x80 end	-- 保留位 bit7 读 0
			end
			t[i] = v
			read_ptr = (read_ptr + 1) % 256		-- burst 自增、0xFF 回绕
		end
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	-- 数据块：有符号原始 LSB（XY -4096..4095，Z -16384..16383，RHALL 0..16383）
	function d:set_data(x, y, z, rhall)
		local xl, xh = encode_xy(x)
		local yl, yh = encode_xy(y)
		local zl, zh = encode_z(z)
		local rl, rh = encode_r(rhall)
		regs[0x42], regs[0x43] = xl, xh
		regs[0x44], regs[0x45] = yl, yh
		regs[0x46], regs[0x47] = zl, zh
		regs[0x48], regs[0x49] = rl, rh
		return self
	end
	function d:set_x_raw(v) regs[0x42], regs[0x43] = encode_xy(v); return self end
	function d:set_y_raw(v) regs[0x44], regs[0x45] = encode_xy(v); return self end
	function d:set_z_raw(v) regs[0x46], regs[0x47] = encode_z(v); return self end
	function d:set_rhall(v) regs[0x48], regs[0x49] = encode_r(v); return self end

	-- 装载工厂 trim（16B NVM 三段）；nil 或缺字段按 0 处理
	function d:set_trim(t)
		if type(t) ~= "table" then return self end
		local z = {}
		for k, v in pairs(DEFAULT_TRIM) do z[k] = v end
		for k, v in pairs(t) do z[k] = v end
		trim = z
		for base, bytes in pairs(trim_bytes(trim)) do
			for i = 1, #bytes do regs[base + i - 1] = bytes[i] end
		end
		return self
	end

	-- ROM 身份覆写（喂 build 错 ID 负路径；nil=不改，软复位不恢复）
	function d:who(id)
		if id ~= nil then
			chip_id = math.floor(tonumber(id) or 0) % 256
			regs[REG_CHIP_ID] = chip_id
		end
		return self
	end

	-- 守护逐拍造数：32 拍地磁原始码正弦直接装入数据块（无转换门概念，
	-- build 前 virt_tick(0) 即预武装），call 零真实睡眠
	function d:virt_tick(n)
		local f = TICK_FRAMES[(math.floor(tonumber(n) or 0) % 32) + 1]
		d:set_data(f[1], f[2], f[3], f[4])
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
		write_count, reset_count = 0, 0
		write_log = {}
		return self
	end

	-- 重新上电：全状态回 POR（默认 trim/CHIP_ID/挂起态）；故障钩子保留
	function d:reset()
		chip_id = CHIP_ID
		trim = DEFAULT_TRIM
		powered = false
		write_count, reset_count = 0, 0
		write_log = {}
		read_ptr = nil
		seed_body()
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:x_raw() return s8(regs[0x43] or 0) * 32 + math.floor((regs[0x42] or 0) / 8) end
	function d:y_raw() return s8(regs[0x45] or 0) * 32 + math.floor((regs[0x44] or 0) / 8) end
	function d:z_raw() return s8(regs[0x47] or 0) * 128 + math.floor((regs[0x46] or 0) / 2) end
	function d:rhall() return (regs[0x49] or 0) * 64 + math.floor((regs[0x48] or 0) / 4) end

	function d:trim()
		local z = {}
		for k, v in pairs(trim) do z[k] = v end
		return z
	end
	function d:chip_id() return chip_id end
	function d:powered() return powered end
	function d:ptr() return read_ptr end
	function d:rep_xy() return regs[REG_REP_XY] or 0 end
	function d:rep_z() return regs[REG_REP_Z] or 0 end
	function d:op_mode() return regs[REG_OP_MODE] or 0 end
	function d:odr_code() return math.floor((regs[REG_OP_MODE] or 0) / 8) % 8 end
	function d:odr_hz() return ODR_HZ[d:odr_code()] end
	function d:mode_code() return math.floor((regs[REG_OP_MODE] or 0) / 2) % 4 end
	function d:reset_count() return reset_count end
	function d:write_count() return write_count end
	function d:writes() return write_log end
	function d:reg(a) return regs[math.floor(tonumber(a) or 0) % 256] end

	return d
end

-- APDS9900.lua - 环境光 + 近距传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 APDS9900_VIRT（2026-09-15 自 modules/lib/virtbus/apds9900.lua
-- 迁入，单文件驱动+模型实验第二十七个，命令字节四态寻址族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Broadcom/Avago APDS-9900（TAOS TSL2771 架构）：双通道 ALS（CH0 全谱 / CH1 红外）
-- + 片内 IR LED 近距，I2C 地址 0x39。APDS-9960 的前代（无手势引擎），寄存器布局
-- 与 9960 不同，切勿混用网上 9960 的代码。
--
-- I2C 协议：命令字节寻址——寄存器访问须发 0x80|reg（字节），字/自动增量访问发
--   0xA0|reg（命令位 7 + 自动增量位 5）；数据寄存器低字节在前（小端流）。
--
-- 用法（结构脚本 .sql，直连路径）：
--   CREATE TABLE APDS9900 (
--       name    String,
--       I2C     String,
--       address String,
--       atime   String,   -- ALS 积分时间 ms 2.73~696（默认 50；周期 = 2.72ms x N）
--       again   String,   -- ALS 增益 1/8/16/120（默认 1）
--       pdrive  String,   -- 近距 LED 电流 mA 12.5/25/50/100（默认 100）
--       pgain   String,   -- 近距增益 1/2/4/8（默认 1）
--       ppcount String,   -- 每周期 IR 脉冲数 1~255（默认 8，影响近距灵敏度/周期耗时）
--       df      String,   -- lux 校准：器件因子（默认 52，内核默认值）
--       ga      String    -- lux 校准：玻璃衰减系数 0~1（默认 0.48，按外壳实测调）
--   );
--   INSERT INTO APDS9900 (name, I2C, address, atime, again, pdrive, pgain, ppcount, df, ga)
--     VALUES ('als0', 'i2c-1', '0x39', '-', '-', '-', '-', '-', '-', '-');
--
-- call 返回：{ result, LUX, CH0, CH1, PROX }——连续转换，读即最新值（build 后首帧
--   前可能为 0）。LUX 为照度（lux，浮点），CH0/CH1/PROX 为原始计数。
--   近距是反射 IR 强度的相对量（有效量程约 1023），不是真实距离。
--   lux 算法与 Linux 内核 apds990x 驱动一致（两线 IR 补偿取大 + df/ga 校准），
--   cf1/irf1/cf2/irf2 用内核默认谱线（1.00/2.23/0.70/1.42）；核内输出 0.1-lux
--   单位，本驱动换算为真 lux。整机装壳后按实测调 ga/df。
--
-- build 流程：ENABLE=0 -> ID 自检（0x12 寄存器，接受 0x00/0x04/0x29）-> 写
--   ATIME/PTIME/WTIME/CONFIG/PERS/PPCOUNT/CONTROL -> ENABLE=PON|AEN|PEN 启动连续转换。
--   destroy 写 ENABLE=0 断电（fd 归 I2C 硬件变量所有）。
--
-- 事实来源：数据手册 AV02-2049EN 架构（TAOS 谱系）经 Linux 内核 apds990x 驱动
--   （drivers/misc/apds990x.c，N9 机型实践）交叉验证：命令字节协议、ID 值、
--   ENABLE/CONTROL 位域、lux 算法与校准常量。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
dofile((__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
	.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 命令字节与寄存器（0x00 基址） ====================
local CMD_BYTE = 0x80		-- 字节访问（命令位 7）
local CMD_INC  = 0xA0		-- 自动增量访问（命令位 7 + 位 5），寄存器对（小端流）用

local REG_ENABLE  = 0x00	-- [3]=WEN [2]=PEN [1]=AEN [0]=PON（中断位不用）
local REG_ATIME   = 0x01	-- ALS 积分周期数：256 - reg 个周期，每周期 2.72ms
local REG_PTIME   = 0x02	-- 近距积分（0xFF = 1 周期 2.7ms）
local REG_WTIME   = 0x03	-- 等待时间（WEN=1 时插入本驱动不用的等待态）
local REG_PERS    = 0x0C	-- 中断持续性（本驱动轮询不用，写 0 保持确定态）
local REG_CONFIG  = 0x0D	-- 附加配置（内核写 0）
local REG_PPCOUNT = 0x0E	-- 每周期 IR LED 脉冲数
local REG_CONTROL = 0x0F	-- [7:6]PDRIVE [5:4]PDIODE [3:2]PGAIN [1:0]AGAIN
local REG_ID      = 0x12	-- 器件 ID（0x00 / 0x04 / 0x29）
local REG_CDATA   = 0x14	-- CH0（全谱）低/高字节对
local REG_IRDATA  = 0x16	-- CH1（红外）低/高字节对
local REG_PDATA   = 0x18	-- 近距 低/高字节对（有效量程约 1023）

local EN_PON, EN_AEN, EN_PEN = 0x01, 0x02, 0x04

-- ==================== 离散配置取值 ====================
local AGAIN_CODE = { [1]=0, [8]=1, [16]=2, [120]=3 }		-- ALS 增益
local PGA_CODE   = { [1]=0, [2]=1, [4]=2, [8]=3 }			-- 近距增益
local PDRIVE_CODE = { [12.5]=3, [25]=2, [50]=1, [100]=0 }	-- LED 电流 mA（数据手册码序）
local PDIODE_IR  = 0x2										-- 近距用 CH1 红外光电二极管

-- lux 算法常量（内核 apds990x 默认校准；APDS_PARAM_SCALE = 4096）
local SCALE = 4096
local CF1, IRF1 = 1.00, 2.23	-- 谱线 1（典型光源 IR 补偿线）
local CF2, IRF2 = 0.70, 1.42	-- 谱线 2
local TIME_SCALER = 32 / 87		-- 周期数 = ms x 32/87（每周期 87/32 = 2.71875ms）

-- 模块级配置（build 写入，跨 call 保持于本变量独立状态机，destroy 后废弃）
local cfg_atime_ms		-- 实际积分 ms（周期数 x 2.71875）
local cfg_again			-- ALS 增益（1/8/16/120）
local cfg_df			-- lux 校准：器件因子
local cfg_ga_scaled		-- lux 校准：玻璃衰减（x SCALE 定点）

-- ==================== 配置解析 ====================
local function cfg_choice(v, default, codes, label)
	if v == nil or v == "-" or v == "" then return default end
	local n = tonumber(v)
	if n == nil or codes[n] == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "'"
	end
	return n
end

-- 字访问：寄存器对小端流（低字节在前），HAL 大端合并后需换序
local function read_word_le(fd, reg)
	local v = i2c_read_multi(fd, CMD_INC + reg, 2)
	if v < 0 then return -1 end
	return (v % 256) * 256 + math.floor(v / 256) % 256
end

-- ==================== lux 计算（内核 apds990x 两线 IR 补偿） ====================
-- iac1 = cf1 x CH0 - irf1 x CH1；iac2 = cf2 x CH0 - irf2 x CH1；
-- iac = max(iac1, iac2, 0)；lux = iac x df x ga / (again x atime_ms)（SCALE 归一）
local function lux_of(ch0, ch1, again, atime_ms, df, ga_scaled)
	local iac1 = (CF1 * ch0 - IRF1 * ch1)
	local iac2 = (CF2 * ch0 - IRF2 * ch1)
	local iac = math.max(iac1, iac2, 0)
	return iac * df * (ga_scaled / SCALE) / (again * atime_ms)
end

require_driver("i2c", {
	name = "APDS9900",

	-- ==================== 配置脚本 ====================
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- APDS9900 builder func get a table --------", data)
		end

		-----------------------------------------------------
		-- 上电断言：先断电，读 ID 在位探测（无独立 ID 的写读回显需求，ID 寄存器可用）
		if not i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, 0x00) then
			return err("APDS9900 not responding (enable write failed, check address 0x39 and wiring)")
		end
		local id = i2c_read_reg(fd, CMD_BYTE + REG_ID)
		if id < 0 then
			return err("APDS9900 not responding (read ID failed)")
		end
		if id ~= 0x00 and id ~= 0x04 and id ~= 0x29 then
			return err(string.format("APDS9900 unexpected ID 0x%02X (expect 0x00/0x04/0x29)", id))
		end

		-----------------------------------------------------
		-- 解析配置
		-- atime 为连续量：2.73~696 ms -> 周期数 1~256（每周期 87/32 ms）
		-- 数值列经 finite_of/num_or 而非裸 tonumber：'nan' 过 tonumber 出的是
		-- number（Lua 里 truthy），`or 缺省` 兜不住，而 NaN 与任何数比较都为假，
		-- 下面六条区间判定一律放行（±inf 被上/下界接住，只有 NaN 穿得过去）。
		-- df/ga 后果最重：它们不落寄存器而落**模块级 cfg_* 状态**，call 侧的
		-- `cfg_df or 52` 同样兜不住 NaN，于是此后每一次 call 的 LUX 都是 nan。
		-- 判据取「与该列既有的非数字串同结论」：ppcount/df/ga 的 'abc' 本就静默
		-- 归缺省（num_or），atime 的越界本就报 ERR（finite_of）。审计 P3 口径。
		local atime_ms = finite_of(data.atime)
		if data.atime == nil or data.atime == "-" or data.atime == "" then atime_ms = 50 end
		-- 局部名用 emsg 而非 err：局部 err 会遮蔽 drv_common 的全局 err() 构造器
		local emsg
		if atime_ms == nil or atime_ms < 2.73 or atime_ms > 696 then
			emsg = "Invalid Argument: atime(ms) '" .. tostring(data.atime) .. "' (range 2.73~696)"
		end
		if emsg then return err(emsg) end
		local cycles = math.floor(atime_ms * TIME_SCALER)
		if cycles < 1 then cycles = 1 elseif cycles > 256 then cycles = 256 end
		local atime_actual = cycles * 87 / 32

		local again, e2 = cfg_choice(data.again, 1, AGAIN_CODE, "again")
		local pdrive, e3 = cfg_choice(data.pdrive, 100, PDRIVE_CODE, "pdrive(mA)")
		local pgain, e4 = cfg_choice(data.pgain, 1, PGA_CODE, "pgain")
		if e2 or e3 or e4 then
			return err(e2 or e3 or e4)
		end

		local ppcount = math.floor(num_or(data.ppcount, 8))
		if ppcount < 1 or ppcount > 255 then
			return err("Invalid Argument: ppcount '" .. tostring(data.ppcount) .. "' (range 1~255)")
		end

		local df = num_or(data.df, 52)
		local ga = num_or(data.ga, 0.48)
		if df <= 0 or ga <= 0 or ga > 1 then
			return err("Invalid Argument: df/ga (df>0, 0<ga<=1)")
		end
		local ga_scaled = math.floor(ga * SCALE + 0.5)

		-----------------------------------------------------
		-- 逐项配置（内核 apds990x_configure 同序，等待态/中断不用）
		local wfail = nil
		local function wr(reg, val, what)
			if wfail == nil and not i2c_write_reg(fd, CMD_BYTE + reg, val) then
				wfail = "APDS9900 not responding (" .. what .. " write failed)"
			end
		end

		wr(REG_ATIME, 256 - cycles, "ATIME")
		wr(REG_PTIME, 0xFF, "PTIME")		-- 近距积分 1 周期（2.7ms）
		wr(REG_WTIME, 0xFF, "WTIME")		-- 等待态不用（WEN=0），保持最短
		wr(REG_CONFIG, 0x00, "CONFIG")
		wr(REG_PERS, 0x00, "PERS")
		wr(REG_PPCOUNT, ppcount, "PPCOUNT")
		wr(REG_CONTROL, PDRIVE_CODE[pdrive] * 64 + PDIODE_IR * 16 + PGA_CODE[pgain] * 4 + AGAIN_CODE[again], "CONTROL")
		if wfail ~= nil then
			return err(wfail)
		end

		-- 启动连续转换：上电 + ALS + 近距（无等待态、无中断）
		if not i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, EN_PON + EN_AEN + EN_PEN) then
			return err("APDS9900 not responding (enable failed)")
		end

		cfg_atime_ms = atime_actual
		cfg_again = again
		cfg_df = df
		cfg_ga_scaled = ga_scaled

		print(string.format(
			"APDS9900 init OK: addr=0x%02X id=0x%02X atime=%.1fms again=x%d led=%.1fmA pgain=x%d ppulse=%d df=%g ga=%.2f",
			addr, id, atime_actual, again, pdrive, pgain, ppcount, df, ga_scaled / SCALE))
		return {  result = "OK"  }
	end,

	-- ==================== 调用 ====================
	-- 读最新 ALS 两通道与近距计数，LUX 按内核算法换算。连续转换无"未就绪"态。
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- APDS9900 caller func get a table --------", data)
		end

		-----------------------------------------------------
		local ch0 = read_word_le(fd, REG_CDATA)
		if ch0 < 0 then
			return err("APDS9900 not responding (read CH0 failed)")
		end
		local ch1 = read_word_le(fd, REG_IRDATA)
		if ch1 < 0 then
			return err("APDS9900 not responding (read CH1 failed)")
		end
		local prox = read_word_le(fd, REG_PDATA)
		if prox < 0 then
			return err("APDS9900 not responding (read PROX failed)")
		end

		return {
			result = "OK",
			LUX = lux_of(ch0, ch1, cfg_again or 1, cfg_atime_ms or 50, cfg_df or 52, cfg_ga_scaled or 1966),
			CH0 = ch0,
			CH1 = ch1,
			PROX = prox
		}
	end,

	-- ==================== 销毁 ====================
	-- 写 ENABLE=0 断电（PON 清零，所有子模块停止；fd 归 I2C 硬件变量所有）
	destroy = function(ctx, data)
		if DEBUG then
			dbg_table("-------- APDS9900 ender func get a table --------", data)
		end

		local fd = tonumber(data.fd)
		local addr = tonumber(data.address)
		if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
			i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, 0x00)
		end

		return {  result = "OK"  }
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】APDS9900_VIRT —— 2026-09-15 自 modules/lib/virtbus/apds9900.lua
-- 整体迁入（单文件驱动+模型第二十七个，命令字节 COMMAND+TYPE 四态寻址族，
-- 守护 E2E 走 sensor_daemon 回退路径）。约定同前二十六者：① 生产路径零执行
-- （new() 仅虚拟总线测试调用，自包含命令字节状态机；RW/READ_ONLY/MODELED/
-- POR 表与 clamp 移入段内加 apds9900_ 前缀避让；new() 内 `local apds9900 =
-- APDS9900_VIRT` 绑定使模型体零改动移植）；② 工厂经全局表而非文件 return
-- （生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无
-- settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿
-- 性质不变。无 BUS 字段 = I2C。
--
-- TAOS TSL2771 架构（APDS-9960 的前代，无手势引擎；寄存器布局与 9960 不同），
-- 固定 I2C 地址 0x39。命令字节寻址协议（datasheet AV02-2049EN + Linux 内核
-- apds990x.c 交叉验证），【不是朴素寄存器指针】：
--   每笔寄存器访问的首字节是命令字节：bit7 必为 1（COMMAND），bit6:5 是
--   TYPE 选择随后事务形态，bit4:0 是寄存器地址（地址空间 0x00~0x1F）：
--     TYPE=00（0x80|reg）重复字节：所有数据字节落在同一寄存器；
--     TYPE=01（0xA0|reg）自动增量：每字节后地址 +1（寄存器对小端流用）；
--     TYPE=10（0xC0|reg）重复字：奇数字节回同字低址、偶数字节走高址；
--     TYPE=11（0xE0|reg）自动增量（同 01，线性 +1）。
--   真实驱动只用 TYPE=00 单字节写/读与 TYPE=01 的 2 字节字对读。
--
-- 建模寄存器（驱动 build/call 全部触点；阈值/STATUS 不碰即不建模，NACK）：
--   0x00 ENABLE R/W  POR 0x00：bit0 PON/bit1 AEN/bit2 PEN/bit3 WEN/
--                    bit4 AIEN/bit5 PIEN，bit7:6 保留写时抹 0
--   0x01 ATIME / 0x02 PTIME / 0x03 WTIME（POR 0xFF）/ 0x0C PERS /
--   0x0D CONFIG / 0x0E PPCOUNT POR 0x01 / 0x0F CONTROL POR 0x00（8 位全用）
--   0x12 ID     ROM 只读（驱动接受 0x00/0x04/0x29，模型默认 0x29），写 ACK 丢弃
--   0x14/15 CDATA、0x16/17 IRDATA、0x18/19 PDATA【小端字对】只读测量区
--   0x04~0x09 阈值、0x0A/0B 保留、0x13 STATUS、0x1A~0x1F：不建模，NACK
--
-- 【真实驱动 build/call 事务】build：set + 断电写 + ID 指针读 + 7 笔配置写 +
-- 启动 = 12 txlog；call：三笔 TYPE=01 字对指针读 = 7 txlog；destroy 2 txlog。
--
-- 用法：
--   vbus.load_driver("modules/APDS9900.lua")  -- 定义全局 build/call/destroy 与 APDS9900_VIRT
--   local dev = APDS9900_VIRT.new()
--   dev:set_counts(10000, 2500, 517)
--   vbus.attach("APDS9900@0x39", 0x39, dev)
--
--   dev:who(0x04)       -- 覆写批次 ID（0x00/0x04/0x29 均被驱动接受）
--
-- 【边界约定】模型只固化命令字节/TYPE 寻址、小端字对字节流、寄存器 POR
-- 与位域、ROM/测量区只读；lux 两线 IR 补偿物理换算在驱动，物理量注入
-- API 常量仅为造样本，测试另做独立换算交叉。
-- =====================================================================

APDS9900_VIRT = {
	_VERSION = "0.1.0",
	REG = {
		ENABLE  = 0x00,
		ATIME   = 0x01,
		PTIME   = 0x02,
		WTIME   = 0x03,
		PERS    = 0x0C,
		CONFIG  = 0x0D,
		PPCOUNT = 0x0E,
		CONTROL = 0x0F,
		ID      = 0x12,
		CDATA   = 0x14,
		IRDATA  = 0x16,
		PDATA   = 0x18,
	}
}

-- 标量常数（逐条挂工厂表）


APDS9900_VIRT.ID_DEFAULT = 0x29		-- 批次 ID（驱动另接受 0x00/0x04）
APDS9900_VIRT.I2C_ADDR   = 0x39		-- 芯片固定地址（无地址引脚）

-- 可写配置寄存器（含 ENABLE）；测量区/ROM 不在其中
local apds9900_RW = {
	[0x00] = true, [0x01] = true, [0x02] = true, [0x03] = true,
	[0x0C] = true, [0x0D] = true, [0x0E] = true, [0x0F] = true,
}

-- 只读区：ID ROM + 三个小端字对（偶=LSB、奇=MSB）
local apds9900_READ_ONLY = {
	[0x12] = true,
	[0x14] = true, [0x15] = true,
	[0x16] = true, [0x17] = true,
	[0x18] = true, [0x19] = true,
}

-- 全部已建模地址（未列入者：阈值 0x04~0x09、0x0A/0x0B、STATUS 0x13、
-- 0x1A~0x1F——任何形式访问整笔 NACK）
local apds9900_MODELED = {}
for a in pairs(apds9900_RW) do apds9900_MODELED[a] = true end
for a in pairs(apds9900_READ_ONLY) do apds9900_MODELED[a] = true end

-- 配置寄存器 POR（ID/测量区在 reseed 另行放置）
local apds9900_POR = {
	[0x00] = 0x00,	-- ENABLE：上电断电态
	[0x01] = 0xFF,	-- ATIME：最短积分
	[0x02] = 0xFF,	-- PTIME
	[0x03] = 0xFF,	-- WTIME
	[0x0C] = 0x00,	-- PERS
	[0x0D] = 0x00,	-- CONFIG
	[0x0E] = 0x01,	-- PPCOUNT：复位 1 脉冲
	[0x0F] = 0x00,	-- CONTROL
}

local function apds9900_clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function APDS9900_VIRT.new(opts)
	local apds9900 = APDS9900_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	opts = opts or {}

	local d = {}
	local regs = {}				-- 已建模地址 → 字节值（含 ID/数据字对）
	local ptr = 0				-- 最近命令字节选中的地址
	local ptype = 0			-- 最近命令字节 TYPE（0..3）
	local id_reg = opts.id or apds9900.ID_DEFAULT
	local write_pred, read_pred
	d.write_log = {}			-- 全部写事务（字节表副本），含指针写/失败写

	-- 故障注入三件（与 regmap/max17048 约定同名）
	d.nack = false
	d.nack_read = false
	d.nack_write = false

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		for a, v in pairs(apds9900_POR) do regs[a] = v end
		regs[0x12] = id_reg
		regs[0x14], regs[0x15] = 0, 0		-- CDATA
		regs[0x16], regs[0x17] = 0, 0		-- IRDATA
		regs[0x18], regs[0x19] = 0, 0		-- PDATA
	end
	reseed()

	-- 命令字节解码：bit7 COMMAND 必置；返回 地址(0..31), TYPE(0..3)；
	-- 命令位缺失=协议坏帧，整笔 NACK
	local function decode(cmd)
		cmd = math.floor(cmd) % 256
		if math.floor(cmd / 0x80) % 2 ~= 1 then return nil end
		return cmd % 32, math.floor(cmd / 32) % 4
	end

	-- TYPE 寻址：帧内第 k 个数据字节（0 基）落在哪个寄存器地址
	local function addr_at(kind, base, k)
		if kind == 0 then
			return base				-- 重复字节：恒同址
		elseif kind == 2 then
			return base + (k % 2)	-- 重复字：字内偶奇循环
		end
		return base + k				-- 01/11 自动增量：线性 +1
	end

	local function log_copy(bytes)
		local cp = {}
		for i = 1, #bytes do cp[i] = bytes[i] % 256 end
		d.write_log[#d.write_log + 1] = cp
	end

	-- ---------------- virtbus 点定义回调（无 self） ----------------

	-- 1 字节 {cmd} = 纯指针写（读事务前奏，只锁地址/TYPE，ACK）；
	-- 2 字节起 = 数据写：命令字节后跟 1..N 个数据字节，按 TYPE 落址。
	-- ENABLE 保留位 7:6 写入即抹 0；ROM/测量区只读，写 ACK 但丢弃；
	-- 任何数据字节落未建模地址，整笔 NACK（先验后写，不落半截）。
	d.write = function(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		log_copy(bytes)
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end
		local base, kind = decode(bytes[1])
		if base == nil then return false end
		ptr, ptype = base, kind
		if #bytes == 1 then return true end

		for k = 2, #bytes do
			local a = addr_at(kind, base, k - 2)
			if not apds9900_MODELED[a] then return false end
		end
		for k = 2, #bytes do
			local a = addr_at(kind, base, k - 2)
			if apds9900_RW[a] then
				local v = bytes[k] % 256
				if a == 0x00 then v = v % 0x40 end	-- ENABLE 保留位抹 0
				regs[a] = v
			end
			-- READ_ONLY：ACK 丢弃
		end
		return true
	end

	-- 读 n 字节：严格按最近指针写的 TYPE 取字节流（小端字对由驱动换序，
	-- 模型只保证偶址 LSB 在前）；途中任一地址未建模整笔 NACK。
	d.read = function(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 1)
		if n < 1 then return nil end
		if read_pred and read_pred(ptr, ptype, n) then return nil end
		local out = {}
		for k = 0, n - 1 do
			local a = addr_at(ptype, ptr, k)
			if not apds9900_MODELED[a] then return nil end
			out[k + 1] = regs[a] or 0
		end
		return out
	end

	-- ---------------- 原始码注入（协议层主输入，冒号 API） ----------------

	-- 三通道计数：CH0 全谱/CH1 红外/PROX 近距，均 u16（0~65535），
	-- 按 datasheet 小端字对摆放（偶址 LSB）
	local function set_pair(base, v)
		v = apds9900_clampi(math.floor(tonumber(v) or 0), 0, 65535)
		regs[base] = v % 256
		regs[base + 1] = math.floor(v / 256) % 256
		return v
	end

	function d:set_counts(ch0, ch1, prox)
		local a = set_pair(0x14, ch0)
		local b = set_pair(0x16, ch1)
		local c = set_pair(0x18, prox)
		return a, b, c
	end
	function d:set_ch0(v) set_pair(0x14, v); return self end
	function d:set_ch1(v) set_pair(0x16, v); return self end
	function d:set_prox(v) set_pair(0x18, v); return self end

	-- 可写配置寄存器留原始码注入口（只允许 RW 地址）
	function d:set_reg(reg, val)
		reg = math.floor(tonumber(reg) or 0)
		if apds9900_RW[reg] then
			local v = apds9900_clampi(math.floor(tonumber(val) or 0), 0, 255)
			if reg == 0x00 then v = v % 0x40 end
			regs[reg] = v
		end
		return self
	end

	-- ---------------- 守护仿真节拍（sensor_daemon 每拍调用，确定性） ----------------

	-- 32 拍周期的典型室内光场景（仅造样本，与驱动 lux 管线独立）：
	--   CH0 10000±4000（6000~14000）、CH1 = CH0/4 同相（IR 占比恒定，
	--   两线补偿后 lux 恒正）、PROX 300±200（100~500，有效量程 1023 内）。
	--   n0=10000/2500/300、n8 峰 14000/3500/500、n24 谷 6000/1500/100。
	-- 缺省 build（18 周期 48.94ms/×1/df52/ga0.48）下 lux ≈ 0.51×
	--   (ch0-2.23ch1)：n0≈2257、峰≈3160、谷≈1354，浮点带小数。
	-- 连续转换无武装/无转换门，直接装测量区（守护 build 前还会
	-- virt_tick(0) 预武装一次，确定性不变）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local s = math.sin(n * (2 * math.pi / 32))
		local ch0 = math.floor(10000 + 4000 * s + 0.5)
		local ch1 = math.floor(ch0 / 4)
		local prox = math.floor(300 + 200 * s + 0.5)
		self:set_counts(ch0, ch1, prox)
		return self
	end

	-- ---------------- 身份/留痕/故障钩子 ----------------

	-- 覆写批次 ID（nil=不改；驱动接受 0x00/0x04/0x29，其余 build 拒收）
	function d:who(id)
		if id ~= nil then
			id_reg = math.floor(id) % 256
			regs[0x12] = id_reg
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

	-- 回上电态（保留故障钩子与 who() 身份，复位不得解除钩子）
	function d:reset()
		reseed()
		ptr, ptype = 0, 0
		self.write_log = {}
		return self
	end

	-- ---------------- 观察口 ----------------

	function d:reg(a) return regs[a] or 0 end
	function d:id() return regs[0x12] end
	function d:enable() return regs[0x00] end
	function d:atime() return regs[0x01] end
	function d:ptime() return regs[0x02] end
	function d:wtime() return regs[0x03] end
	function d:pers() return regs[0x0C] end
	function d:config() return regs[0x0D] end
	function d:ppcount() return regs[0x0E] end
	function d:control() return regs[0x0F] end
	function d:pointer() return ptr end
	function d:ptype() return ptype end

	local function pair_of(base)
		return (regs[base] or 0) + (regs[base + 1] or 0) * 256
	end
	function d:ch0() return pair_of(0x14) end
	function d:ch1() return pair_of(0x16) end
	function d:prox() return pair_of(0x18) end

	function d:modeled(a) return apds9900_MODELED[a] == true end

	return d
end

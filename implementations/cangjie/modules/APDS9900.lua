-- APDS9900.lua - 环境光 + 近距传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
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

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

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

-- ==================== 配置脚本 ====================
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- APDS9900 builder func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	-- 上电断言：先断电，读 ID 在位探测（无独立 ID 的写读回显需求，ID 寄存器可用）
	if not i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, 0x00) then
		return {
			result = "ERR",
			message = "APDS9900 not responding (enable write failed, check address 0x39 and wiring)"
		}
	end
	local id = i2c_read_reg(fd, CMD_BYTE + REG_ID)
	if id < 0 then
		return {
			result = "ERR",
			message = "APDS9900 not responding (read ID failed)"
		}
	end
	if id ~= 0x00 and id ~= 0x04 and id ~= 0x29 then
		return {
			result = "ERR",
			message = string.format("APDS9900 unexpected ID 0x%02X (expect 0x00/0x04/0x29)", id)
		}
	end

	-----------------------------------------------------
	-- 解析配置
	-- atime 为连续量：2.73~696 ms -> 周期数 1~256（每周期 87/32 ms）
	local atime_ms = tonumber(data.atime)
	if data.atime == nil or data.atime == "-" or data.atime == "" then atime_ms = 50 end
	local err
	if atime_ms == nil or atime_ms < 2.73 or atime_ms > 696 then
		err = "Invalid Argument: atime(ms) '" .. tostring(data.atime) .. "' (range 2.73~696)"
	end
	if err then return { result = "ERR", message = err } end
	local cycles = math.floor(atime_ms * TIME_SCALER)
	if cycles < 1 then cycles = 1 elseif cycles > 256 then cycles = 256 end
	local atime_actual = cycles * 87 / 32

	local again, e2 = cfg_choice(data.again, 1, AGAIN_CODE, "again")
	local pdrive, e3 = cfg_choice(data.pdrive, 100, PDRIVE_CODE, "pdrive(mA)")
	local pgain, e4 = cfg_choice(data.pgain, 1, PGA_CODE, "pgain")
	if e2 or e3 or e4 then
		return { result = "ERR", message = e2 or e3 or e4 }
	end

	local ppcount = math.floor(tonumber(data.ppcount) or 8)
	if ppcount < 1 or ppcount > 255 then
		return {
			result = "ERR",
			message = "Invalid Argument: ppcount '" .. tostring(data.ppcount) .. "' (range 1~255)"
		}
	end

	local df = tonumber(data.df) or 52
	local ga = tonumber(data.ga) or 0.48
	if df <= 0 or ga <= 0 or ga > 1 then
		return {
			result = "ERR",
			message = "Invalid Argument: df/ga (df>0, 0<ga<=1)"
		}
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
		return {
			result = "ERR",
			message = wfail
		}
	end

	-- 启动连续转换：上电 + ALS + 近距（无等待态、无中断）
	if not i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, EN_PON + EN_AEN + EN_PEN) then
		return {
			result = "ERR",
			message = "APDS9900 not responding (enable failed)"
		}
	end

	cfg_atime_ms = atime_actual
	cfg_again = again
	cfg_df = df
	cfg_ga_scaled = ga_scaled

	print(string.format(
		"APDS9900 init OK: addr=0x%02X id=0x%02X atime=%.1fms again=x%d led=%.1fmA pgain=x%d ppulse=%d df=%g ga=%.2f",
		addr, id, atime_actual, again, pdrive, pgain, ppcount, df, ga_scaled / SCALE))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 读最新 ALS 两通道与近距计数，LUX 按内核算法换算。连续转换无"未就绪"态。
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- APDS9900 caller func get a table --------", data)
	end

	-----------------------------------------------------
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd == nil or addr == nil then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address"
		}
	end

	if not i2c_set_addr(fd, addr) then
		return {
			result = "ERR",
			message = "Invalid Argument: fd or address (set_addr failed)"
		}
	end

	-----------------------------------------------------
	local ch0 = read_word_le(fd, REG_CDATA)
	if ch0 < 0 then
		return {
			result = "ERR",
			message = "APDS9900 not responding (read CH0 failed)"
		}
	end
	local ch1 = read_word_le(fd, REG_IRDATA)
	if ch1 < 0 then
		return {
			result = "ERR",
			message = "APDS9900 not responding (read CH1 failed)"
		}
	end
	local prox = read_word_le(fd, REG_PDATA)
	if prox < 0 then
		return {
			result = "ERR",
			message = "APDS9900 not responding (read PROX failed)"
		}
	end

	return {
		result = "OK",
		LUX = lux_of(ch0, ch1, cfg_again or 1, cfg_atime_ms or 50, cfg_df or 52, cfg_ga_scaled or 1966),
		CH0 = ch0,
		CH1 = ch1,
		PROX = prox
	}

end

-- ==================== 销毁 ====================
-- 写 ENABLE=0 断电（PON 清零，所有子模块停止；fd 归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- APDS9900 ender func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		i2c_write_reg(fd, CMD_BYTE + REG_ENABLE, 0x00)
	end

	return {  result = "OK"  }

end

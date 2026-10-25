-- MS5611-01BA03 高分辨率气压计/高度计 驱动模块（TE/MEAS，I2C 0x76~0x77）
-- bot4cj 仓颉语言机器人框架
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MS5611 (
--       name    String,
--       I2C     String,
--       address String,
--       osr     String,
--       p0      String
--   );
--   INSERT INTO MS5611 (name, I2C, address, osr)
--     VALUES ('baro0', 'i2c-1', '0x77', '-');
--
-- 列说明（均可选，'-' 归缺省）：
--   osr = 过采样率 256/512/1024/2048/4096（非法值向下降档，缺省 4096 最高
--         分辨率 0.012mbar；档位越高单次转换越慢，4096 时一次 call 约 20ms）
--   p0  = 参考海平面气压 hPa（缺省 1013.25，ALT_M 换算用；本地天气下按
--         气象台实测值校准可显著提高海拔精度）
--
-- call 无需参数，返回：
--   { result, P_HPA(气压 hPa), T_C(温度 °C), ALT_M(海拔 m，压高公式近似) }
-- 接 sensor_daemon：fields=P_HPA|T_C|ALT_M（interval >= 25ms @OSR4096）
--
-- 协议（命令式，无寄存器地图；单字节命令 + ADC 读值）：
--   0x1E 复位（PROM 重载 <=2.8ms）| 0xA0~0xAC 读 PROM（word0 含 4 位 CRC，
--   word1~6 = C1~C6 校准系数）| 0x40~0x48 启动 D1（气压）转换、
--   0x50~0x58 启动 D2（温度）转换（+2 步进对应 OSR 256~4096）| 0x00 读 ADC 24 位
-- build：复位 -> 读 7 字 PROM -> CRC-4 校验（兼在位甄别）-> 缓存系数
-- call：转换 D1 -> 等 -> 读 ADC -> 转换 D2 -> 等 -> 读 ADC -> 补偿解算
--
-- 补偿算法（datasheet + Linux 内核 ms5611_core + jarzebski 库三方一致）：
--   一阶：dT/TEMP/OFF/SENS/标准移位；二阶（TEMP<2000）：T2/OFF2/SENS2，
--   极低温（TEMP<-1500）追加项。除法统一 floor（算术移位语义，负 dT 安全）。
--   精度注意：D1*SENS 最大 ~2^56，超 double 2^53 线——按 D1 高/低 12 位
--   拆项分别除 2 的幂再求和（各项与和均 < 2^53，全精确），见 d1_sens_shr21。
--
-- 部署提醒：芯片裸露受光会引入气压噪声，模块出厂遮光海绵/胶勿撕除；
--   压高公式为国际标准大气近似，且海拔参考点 p0 随天气漂移（1hPa ≈ 8.5m）。

-- 加载纯 Lua 基层硬件抽象层（HAL，issue #14：不再依赖仓颉 cfunc）
-- 调试打印辅助 print_table（modules/lib/）
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：气压高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令 ====================
local CMD_RESET     = 0x1E
local CMD_ADC_READ  = 0x00
local CMD_PROM_BASE = 0xA0			-- +2*i：word0(出厂+CRC) 与 C1~C6
local CMD_CONV_D1   = 0x40			-- +2*i：启动气压转换（i=0~4 为 OSR 档）
local CMD_CONV_D2   = 0x50			-- +2*i：启动温度转换

-- ==================== OSR 档表（代码 0~4） ====================
-- 最大转换时间（datasheet）+ 余量，取整到常用值（与 jarzebski 库同款）
local OSR_TAB   = { 256, 512, 1024, 2048, 4096 }
local WAIT_TAB  = { 1, 2, 3, 5, 10 }		-- ms

local DEF_OSR = 4096
local DEF_P0  = 1013.25

local T_RESET_MS = 3				-- 复位 PROM 重载 <=2.8ms + 余量

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local c1, c2, c3, c4, c5, c6		-- PROM 校准系数
local conv_cmd_d1, conv_cmd_d2		-- 当前 OSR 档的转换命令
local wait_ms						-- 当前档位转换等待
local p0_hpa						-- ALT_M 参考海平面气压

-- ==================== 底层辅助 ====================
-- 数值列 -> 向下降档到不大于 n 的最大 OSR 档；非法/'-' 归缺省
local function osr_idx_of(v)
	local n = tonumber(v)
	if n == nil or n <= 0 then return #OSR_TAB end
	for i = #OSR_TAB, 1, -1 do
		if n >= OSR_TAB[i] then return i end
	end
	return #OSR_TAB
end

-- floor(x / 2^k)：与算术移位同语义（负数向 -Inf 取整，内核驱动一致）
local function shr(x, k)
	return math.floor(x / 2 ^ k)
end

-- PROM CRC-4 校验。PROM Word Map（datasheet Fig.16）：8 字 0xA0~0xAE，
-- word0 = 出厂数据、word1~6 = C1~C6、word7(0xAE) = 4 位 CRC + 12 位序列号。
-- 算法同 TE 官方驱动/PX4：CRC 位域本身参与运算（word7 仅清低字节），
-- 多项式 0x3000；计算出的位域 == 存储的位域为通过。
-- 【真机首跑注意】若报 CRC mismatch，优先复核本布局与器件批次差异。
local function crc4_ok(prom)
	local n_prom = {}
	for i = 1, 8 do n_prom[i] = prom[i] % 65536 end
	local crc_read = math.floor(n_prom[8] / 4096) % 16
	n_prom[8] = bitc.band(n_prom[8], 0xFF00)	-- word7 仅清低字节（CRC 位域保留）
	local n_rem = 0
	for cnt = 0, 15 do
		local w = n_prom[math.floor(cnt / 2) + 1]
		if cnt % 2 == 1 then
			n_rem = bitc.bxor(n_rem, w % 256)	-- 低字节
		else
			n_rem = bitc.bxor(n_rem, math.floor(w / 256))	-- 高字节
		end
		for _ = 1, 8 do
			if bitc.band(n_rem, 0x8000) ~= 0 then
				n_rem = bitc.bxor(bitc.band(n_rem * 2, 0xFFFF), 0x3000)
			else
				n_rem = bitc.band(n_rem * 2, 0xFFFF)
			end
		end
	end
	n_rem = math.floor((n_rem % 65536) / 4096) % 16
	return n_rem == crc_read
end

-- floor(D1*SENS / 2^21)：D1*SENS 最大 ~2^56 超 double 2^53 精度线。
-- 按 D1 高/低 12 位拆项：dh*SENS/2^9 (<=2^36) 与 dl*SENS/2^21 (<=2^24)
-- 各自精确（除以 2 的幂仅移指数），和 <=2^36 亦精确，floor 后与 64 位
-- 整数语义一致
local function d1_sens_shr21(d1, sens)
	local dh = math.floor(d1 / 4096)
	local dl = d1 % 4096
	return math.floor(dh * sens / 512 + dl * sens / 2097152)
end

-- 发送单字节命令，成功返回 true
local function send_cmd(fd, cmd)
	return i2c_write_multi(fd, cmd) == 0
end

-- 读 24 位 ADC 结果，失败返回 nil
local function read_adc24(fd)
	local v = i2c_read_multi(fd, CMD_ADC_READ, 3)
	if v < 0 then return nil end
	return v
end

-- 【配置脚本】复位 -> 读 PROM -> CRC 自检 -> 缓存系数
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MS5611 builder func get a table --------", data)
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

	-- OSR 档位与等待时间
	local oi = osr_idx_of(data.osr)
	conv_cmd_d1 = CMD_CONV_D1 + 2 * (oi - 1)
	conv_cmd_d2 = CMD_CONV_D2 + 2 * (oi - 1)
	wait_ms = WAIT_TAB[oi]

	-- 参考海平面气压（非法/非正归缺省）
	local p0 = tonumber(data.p0)
	if p0 == nil or p0 <= 0 then p0 = DEF_P0 end
	p0_hpa = p0

	-----------------------------------------------------
	-- 复位
	if not send_cmd(fd, CMD_RESET) then
		return {
			result = "ERR",
			message = "Failed to reset MS5611"
		}
	end
	milli_sleep(T_RESET_MS)

	-- 读 8 字 PROM（word0 = 出厂数据，word1~6 = C1~C6，word7 = 序列号 + CRC）
	local prom = {}
	for i = 0, 7 do
		local w = i2c_read_multi(fd, CMD_PROM_BASE + 2 * i, 2)
		if w < 0 then
			return {
				result = "ERR",
				message = "Failed to read MS5611 PROM"
			}
		end
		prom[i + 1] = w
	end

	-- CRC-4 自检（兼在位甄别：错挂器件/总线异常过不了这关）
	if not crc4_ok(prom) then
		return {
			result = "ERR",
			message = string.format("MS5611 PROM CRC mismatch (word0=0x%04X, not MS5611?)", prom[1])
		}
	end

	c1 = prom[2]; c2 = prom[3]; c3 = prom[4]
	c4 = prom[5]; c5 = prom[6]; c6 = prom[7]

	print(string.format("MS5611 init OK: addr=0x%02X, osr=%d, wait=%dms, C1=%d C6=%d",
		addr, OSR_TAB[oi], wait_ms, c1, c6))
	return {  result = "OK"  }

end

-- 【销毁MS5611】无资源需要释放（总线归 I2C 硬件变量所有）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【调用MS5611】双段转换（D1 气压 / D2 温度）+ 一阶/二阶补偿解算
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MS5611 caller func get a table --------", data)
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
	-- D1（气压）转换
	if not send_cmd(fd, conv_cmd_d1) then
		return {
			result = "ERR",
			message = "Failed to start MS5611 D1 conversion"
		}
	end
	milli_sleep(wait_ms)
	local d1 = read_adc24(fd)
	if d1 == nil then
		return {
			result = "ERR",
			message = "Failed to read MS5611 D1"
		}
	end

	-- D2（温度）转换
	if not send_cmd(fd, conv_cmd_d2) then
		return {
			result = "ERR",
			message = "Failed to start MS5611 D2 conversion"
		}
	end
	milli_sleep(wait_ms)
	local d2 = read_adc24(fd)
	if d2 == nil then
		return {
			result = "ERR",
			message = "Failed to read MS5611 D2"
		}
	end

	-----------------------------------------------------
	-- 一阶补偿（datasheet 整数算法，除法 floor = 算术移位语义）
	local dt = d2 - c5 * 256
	local temp = 2000 + shr(dt * c6, 23)
	local off = c2 * 65536 + shr(c4 * dt, 7)
	local sens = c1 * 32768 + shr(c3 * dt, 8)

	-- 二阶补偿（低温非线性；OFF2/SENS2 用一阶 TEMP，顺序同 datasheet 流程图）
	if temp < 2000 then
		local t2 = shr(dt * dt, 31)
		local off2 = shr(5 * (temp - 2000) * (temp - 2000), 1)
		local sens2 = shr(5 * (temp - 2000) * (temp - 2000), 2)
		if temp < -1500 then
			off2 = off2 + 7 * (temp + 1500) * (temp + 1500)
			sens2 = sens2 + shr(11 * (temp + 1500) * (temp + 1500), 1)
		end
		temp = temp - t2
		off = off - off2
		sens = sens - sens2
	end

	-- 气压（0.01 mbar 单位 -> hPa）
	local p_cbar = d1_sens_shr21(d1, sens) - off
	p_cbar = shr(p_cbar, 15)
	local p_hpa = p_cbar / 100
	local t_c = temp / 100

	-- 压高公式（国际标准大气近似）：h = 44330 x (1 - (p/p0)^0.1902949)
	local alt_m = 44330 * (1 - (p_hpa / p0_hpa) ^ 0.1902949)

	local ret = {
		result = "OK",
		P_HPA = p_hpa,
		T_C = t_c,
		ALT_M = alt_m
	}

	if DEBUG then
		print(string.format("MS5611: P=%.2fhPa T=%.2f°C alt=%.1fm", p_hpa, t_c, alt_m))
	end

	return ret

end

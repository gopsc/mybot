-- MS5611-01BA03 高分辨率气压计/高度计 驱动模块（TE/MEAS，I2C 0x76~0x77）
-- bot4cj 仓颉语言机器人框架
--
-- 【单消费者声明】本器件是**转换命令式**：一次采样 = 写 CMD_CONV_D1（气压）或
-- CMD_CONV_D2（温度）→ 等 8~10ms → 写 CMD_ADC_READ 读 3 字节原始值 → 用 PROM
-- 系数做二阶补偿。器件侧状态是「当前在转换哪一个量」，跨 3 个事务。
-- 两个消费者交错时：A 发 D1、B 发 D2，A 读回的 ADC 其实是 B 的温度原始值，
-- 却被当成气压代入补偿公式——得到**数值上看似合理的错误高度**，比报错危险得多
-- （既不报错也不越界，只是错）。HAL 的单事务原子性帮不上忙：原子单位是一个事务，
-- 而本驱动的一次采样跨多个事务。装配期据此按 (总线路径, 地址) 判重，
-- 见 src/hw_factory.cpp 的 checkSingleConsumer；正道是让 @Daemon 做唯一采样者、
-- 主线程经 '$' 引用读快照（见 docs/drivers.md 的「单消费者声明」小节）。
-- 标记必须写在**行首**（宿主是纯文本扫描、不执行 Lua）。
SINGLE_CONSUMER = "转换命令式：器件侧记着'在转换哪个量'，交错会把温度原始值当气压算"
-- 虚拟器件模型：内嵌本文件尾部 MS5611_VIRT（2026-09-15 自 modules/lib/virtbus/ms5611.lua
-- 迁入，单文件驱动+模型实验第十六个；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
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
--   osr = 过采样率 256/512/1024/2048/4096（缺省 4096 最高分辨率 0.012mbar；
--         超档值向下降档到不大于它的最大档；<256 或非数字显式报错，不静默选档。
--         档位越高单次转换越慢，4096 时一次 call 约 20ms）
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

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
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

local DEF_P0  = 1013.25

local T_RESET_MS = 3				-- 复位 PROM 重载 <=2.8ms + 余量

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local c1, c2, c3, c4, c5, c6		-- PROM 校准系数
local conv_cmd_d1, conv_cmd_d2		-- 当前 OSR 档的转换命令
local wait_ms						-- 当前档位转换等待
local p0_hpa						-- ALT_M 参考海平面气压

-- ==================== 底层辅助 ====================
-- 数值列 -> 向下降档到不大于 n 的最大 OSR 档；'-'/缺省归默认档（4096）。
-- 非法值（非数字 / < 256 无档可降）返回 nil + 原因，由 build 显式报 ERR——
-- 旧实现一律回落 #OSR_TAB（4096 = 最慢档），osr='100' 或拼成 '10O' 会静默
-- 把采样率拉到最低（20ms/call）且无从察觉，与「向下降档」的注释相反。
local function osr_idx_of(v)
	if v == nil or v == "-" then return #OSR_TAB end
	local n = tonumber(v)
	if n == nil then
		return nil, "osr is not a number: '" .. tostring(v)
			.. "' (valid: 256/512/1024/2048/4096 or '-')"
	end
	for i = #OSR_TAB, 1, -1 do
		if n >= OSR_TAB[i] then return i end
	end
	return nil, "osr=" .. tostring(v) .. " is below the lowest ratio 256;"
		.. " there is no ratio to step down to (valid: 256/512/1024/2048/4096 or '-')"
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

require_driver("i2c", {
	name = "MS5611",

	-- 【配置脚本】复位 -> 读 PROM -> CRC 自检 -> 缓存系数
	build = function(ctx, data)
		local fd = ctx.fd
		local addr = ctx.addr

		if DEBUG then
			dbg_table("-------- MS5611 builder func get a table --------", data)
		end

		-- OSR 档位校验先于一切总线动作：非法值不碰硬件
		local oi, oerr = osr_idx_of(data.osr)
		if oi == nil then
			return err("Invalid Argument: " .. oerr)
		end

		-- OSR 档位与等待时间
		conv_cmd_d1 = CMD_CONV_D1 + 2 * (oi - 1)
		conv_cmd_d2 = CMD_CONV_D2 + 2 * (oi - 1)
		wait_ms = WAIT_TAB[oi]

		-- 参考海平面气压（非法/非正归缺省）
		-- 26.3：num_or 而非 tonumber——'nan'/'1e400' 过 tonumber 出的是 number
		-- （Lua 里 truthy），`p0 == nil` 与 `p0 <= 0` 对 NaN 均为假，于是 NaN 被存进
		-- **模块级** p0_hpa：此后每一次 call 的 ALT_M = 44330*(1-(P/NaN)^0.19) 都是
		-- NaN，却仍报 result="OK"——一次污染、永久输出，且 NaN 进 JSON 变 null，
		-- 下游 fields=ALT_M 的消费者拿到空值而非报错；inf 则让 ALT_M 恒为 44330 定值。
		-- 本处契约写的是「归缺省」，故用 num_or（与 26.1 的判据同规：or dflt 站点
		-- 用 num_or，== nil → err 站点用 finite_of）。
		local p0 = num_or(data.p0, DEF_P0)
		if p0 <= 0 then p0 = DEF_P0 end
		p0_hpa = p0

		-----------------------------------------------------
		-- 复位
		if not send_cmd(fd, CMD_RESET) then
			return err("Failed to reset MS5611")
		end
		milli_sleep(T_RESET_MS)

		-- 读 8 字 PROM（word0 = 出厂数据，word1~6 = C1~C6，word7 = 序列号 + CRC）
		local prom = {}
		for i = 0, 7 do
			local w = i2c_read_multi(fd, CMD_PROM_BASE + 2 * i, 2)
			if w < 0 then
				return err("Failed to read MS5611 PROM")
			end
			prom[i + 1] = w
		end

		-- CRC-4 自检（兼在位甄别：错挂器件/总线异常过不了这关）
		if not crc4_ok(prom) then
			return err(string.format("MS5611 PROM CRC mismatch (word0=0x%04X, not MS5611?)", prom[1]))
		end

		c1 = prom[2]; c2 = prom[3]; c3 = prom[4]
		c4 = prom[5]; c5 = prom[6]; c6 = prom[7]

		print(string.format("MS5611 init OK: addr=0x%02X, osr=%d, wait=%dms, C1=%d C6=%d",
			addr, OSR_TAB[oi], wait_ms, c1, c6))
		return {  result = "OK"  }

	end,

	-- destroy 缺省 = 空操作（原 MS5611 destroy 仅 arg_table + return OK，等价）

	-- 【调用MS5611】双段转换（D1 气压 / D2 温度）+ 一阶/二阶补偿解算
	call = function(ctx, data)
		local fd = ctx.fd

		if DEBUG then
			dbg_table("-------- MS5611 caller func get a table --------", data)
		end

		-----------------------------------------------------
		-- D1（气压）转换
		if not send_cmd(fd, conv_cmd_d1) then
			return err("Failed to start MS5611 D1 conversion")
		end
		milli_sleep(wait_ms)
		local d1 = read_adc24(fd)
		if d1 == nil then
			return err("Failed to read MS5611 D1")
		end

		-- D2（温度）转换
		if not send_cmd(fd, conv_cmd_d2) then
			return err("Failed to start MS5611 D2 conversion")
		end
		milli_sleep(wait_ms)
		local d2 = read_adc24(fd)
		if d2 == nil then
			return err("Failed to read MS5611 D2")
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

	end,
})


-- =====================================================================
-- 【内嵌虚拟器件模型】MS5611_VIRT —— 2026-09-15 自 modules/lib/virtbus/ms5611.lua
-- 整体迁入（单文件驱动+模型第十六个，守护 E2E 走 sensor_daemon 回退路径）。
-- 约定同前十五者：① 生产路径零执行（new() 仅虚拟总线测试调用；位运算经
-- 本文件 mpath 上值惰性加载 bitcompat——首次 crc4 计算时装载并缓存，不共用
-- 驱动 bitc；常量/clamp 移入段内加 ms5611_ 前缀，与驱动同名 crc4_ok 独立
-- ——模型/驱动/测试三方 CRC 各自实现交叉正是本器件的互证设计）；② 工厂经
-- 全局表而非文件 return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载
-- 驱动且成功路径无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持
-- 独立实现。无 BUS 字段 = I2C。
--
-- 定位：【首个「单字节命令里编码通道+OSR 档位」+「指针读 PROM/ADC」+
-- PROM 出厂校准 CRC-4 校验的命令式 I2C 器件】——无寄存器地图，但读访问
-- 是「写 1 字节指针命令 + 读 N 字节」（驱动用 i2c_read_multi，virtbus
-- 复刻为指针写事务+纯读两步），与 regmap 指针器件的区别是 PROM/ADC
-- 不是可寻址寄存器而是命令对象：
--   0x1E              软复位（PROM 重载，真机 <=2.8ms）
--   0xA0+2i (i=0..7)  指针：下一次 2B 读返回 PROM word i（word0 出厂数据、
--                      word1~6 = C1~C6、word7 = CRC-4 位域 + 12 位序列号）
--   0x00              指针：下一次 3B 读返回 24 位 ADC 结果
--   0x40+2i / 0x50+2i 单字节命令：启动 D1 气压 / D2 温度转换，i=0..4 对应
--                      OSR 256~4096（偶数才合法，奇数/越界 NACK）
-- 与同族对照：SHT3X 是 2 字节命令字+每字 CRC-8；MS5611 是 1 字节命令且
-- 数据帧本身无 CRC（校验只在出厂 PROM，且为 4 位 nibble CRC）。
--
-- 只复刻协议层事实（TE MS5611 datasheet，以真实驱动 modules/MS5611.lua
-- 实际访问为准）：
--   1) 转换门用 datasheet 最大转换时间（0.60/1.17/2.28/4.54/9.04ms，
--      驱动取整等待表 1/2/3/5/10ms 留余量）；advance(ms) 推进，转换未
--      完成时 ADC 读 NACK（真机转换期间不响应）；oneshot 结果保持到下
--      一条转换命令（ADC 重读不消费）；必须先发转换命令 ADC 才有数。
--   2) PROM 8 字随时可读（与转换态无关）；每次读都要先写指针（读后指针
--      自动失效，贴合真机「每次读重发命令」）；长度必须匹配（PROM 2B、
--      ADC 3B），无前置指针的纯读 NACK。
--   3) PROM 种子 CRC-4 自洽（多项式 0x3000，CRC 位域参与自身运算，
--      word7 仅清低字节——与驱动同款布局，模型自带 nibble 计算并公开，
--      测试另有独立实现三方交叉）。
--   4) 补偿解算（一阶/二阶）是驱动侧算法，模型【不抄】：只存 24 位
--      D1/D2 原始码与 PROM 系数；set_pt(p_hpa,t_c) 仅供守护/E2E 按
--      暖机一阶逆模型造物理量样本（温度在 20°C 附近，二阶不触发）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。LuaJIT 兼容：用 bitcompat。
-- =====================================================================

MS5611_VIRT = { _VERSION = "0.1.0" }

-- 位运算惰性装载：首次 crc4 计算时 dofile bitcompat 并缓存（false=装载失败，
-- 理论兜底路径不建模——本仓库测试/守护环境 bitcompat 恒可得）
local ms5611_ops_cache = nil
local function ms5611_ops()
	if ms5611_ops_cache == nil then
		local ok, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
		ms5611_ops_cache = (ok and bc) or false
	end
	return ms5611_ops_cache
end

-- PROM CRC-4（TE 官方/PX4 同款；prom[1..8]，word8 未屏蔽）。
-- 返回 (算出的 nibble, word8 中存储的 nibble)。独立于驱动 crc4_ok 实现。
local function ms5611_crc4_nibbles(bitc, prom)
	local n_prom = {}
	for i = 1, 8 do n_prom[i] = prom[i] % 65536 end
	local crc_read = math.floor(n_prom[8] / 4096) % 16
	n_prom[8] = bitc.band(n_prom[8], 0xFF00)	-- word7 仅清低字节（CRC 位域保留）
	local n_rem = 0
	for cnt = 0, 15 do
		local w = n_prom[math.floor(cnt / 2) + 1]
		if cnt % 2 == 1 then
			n_rem = bitc.bxor(n_rem, w % 256)			-- 低字节
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
	return math.floor((n_rem % 65536) / 4096) % 16, crc_read
end

-- 公开：给定 prom8 返回 CRC 是否自洽（测试自证/三方交叉用）
function MS5611_VIRT.crc4_ok(prom)
	local got, stored = ms5611_crc4_nibbles(ms5611_ops(), prom)
	return got == stored, got, stored
end

local function ms5611_clamp24(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 0xFFFFFF then return 0xFFFFFF else return v end
end

function MS5611_VIRT.new()
	local bitc = ms5611_ops()

	-- datasheet 最大转换时间 ms（OSR 256/512/1024/2048/4096）
	local T_MAX = { [0] = 0.60, [1] = 1.17, [2] = 2.28, [3] = 4.54, [4] = 9.04 }

	-- 出厂种子：接近真实器件量级的系数（datasheet 一阶算例同款，旧桩沿用）
	local SEED_WORD0 = 0x06A4
	local SEED_COEFF = { 40127, 36924, 23317, 23282, 33464, 31471 }	-- C1~C6
	local SEED_SERIAL = 0x321										-- word7 低 12 位

	local d = {}

	-- 芯片侧状态
	local prom = {}
	local d1, d2 = 9085466, 8569156	-- 暖机 ~1000hPa / ~20.5°C 种子
	local pending				-- 'd1' | 'd2'：最近一次转换命令（结果保持）
	local remaining				-- 当前转换剩余 ms（nil=完成/无转换）
	local read_target			-- nil | 'adc' | 'prom'
	local prom_idx
	local armed					-- virt_tick 预武装：转换命令即时就绪
	local cmds = {}				-- 识别的命令/指针写序列（全部 1 字节写）

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local cmd_pred, read_pred
	local prom_bad = false

	local function crc4_nibbles(prom)
		return ms5611_crc4_nibbles(bitc, prom)
	end

	local function seed_prom()
		prom = { [1] = SEED_WORD0 }
		for i = 1, 6 do prom[i + 1] = SEED_COEFF[i] end
		-- word7 = CRC 位域（参与自身运算，逐一试探合法 nibble）+ 序列号
		for nib = 0, 15 do
			prom[8] = nib * 4096 + SEED_SERIAL
			if MS5611_VIRT.crc4_ok(prom) then break end
		end
	end

	local function start_conversion(kind, oi)
		pending = kind
		cmds[#cmds + 1] = (kind == "d1") and (0x40 + 2 * oi) or (0x50 + 2 * oi)
		-- 注意不能用 `armed and nil or T_MAX[oi]`：and 链中 nil 为假会落到 or 分支
		if armed then remaining = nil else remaining = T_MAX[oi] end
		read_target = nil
	end

	seed_prom()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes ~= 1 then return false end
		if d.nack or d.nack_write then return false end
		local b = bytes[1]
		if cmd_pred and cmd_pred(b) then return false end

		if b == 0x1E then
			-- 软复位：PROM 重载、转换/指针状态清空
			seed_prom()
			pending, remaining, read_target, prom_idx = nil, nil, nil, nil
			cmds[#cmds + 1] = b
			return true
		end
		-- 转换命令：D1 0x40~0x48 / D2 0x50~0x58，仅偶数（0x4A 等保留码 NACK）
		if (b >= 0x40 and b <= 0x48 and b % 2 == 0)
			or (b >= 0x50 and b <= 0x58 and b % 2 == 0) then
			local kind = (b < 0x50) and "d1" or "d2"
			local base = (kind == "d1") and 0x40 or 0x50
			start_conversion(kind, (b - base) / 2)
			return true
		end
		-- ADC 指针
		if b == 0x00 then
			read_target, prom_idx = "adc", nil
			return true
		end
		-- PROM 指针：0xA0~0xAE，仅偶数
		if b >= 0xA0 and b <= 0xAE and b % 2 == 0 then
			read_target, prom_idx = "prom", (b - 0xA0) / 2 + 1
			return true
		end
		-- 未定义命令/奇数地址：NACK
		return false
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 0)
		if read_pred and read_pred(read_target, n, prom_idx) then return nil end
		if read_target == "prom" then
			if n ~= 2 then return nil end
			local w = prom[prom_idx]
			-- corrupt 只改 word7 的 CRC 位域（系数不动，专打 build CRC 校验）
			if prom_bad and prom_idx == 8 then
				local _, stored = crc4_nibbles(prom)
				w = ((stored + 1) % 16) * 4096 + (prom[8] % 4096)
			end
			read_target = nil
			return { math.floor(w / 256) % 256, w % 256 }
		elseif read_target == "adc" then
			if n ~= 3 then return nil end
			if pending == nil or remaining ~= nil then
				-- 未启动转换 / 转换仍在进行：NACK（读后不清除指针语义无意义）
				return nil
			end
			local v = (pending == "d2") and d2 or d1
			-- oneshot：结果保持到下一条转换命令；指针读后失效（需重发 0x00）
			read_target = nil
			return { math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256 }
		end
		-- 无前置指针的纯读：NACK
		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then remaining = nil end
		end
		return self
	end

	-- 注入 24 位原始码（模型不做补偿，换算公式归驱动）
	function d:set_d1(v) d1 = ms5611_clamp24(v); return self end
	function d:set_d2(v) d2 = ms5611_clamp24(v); return self end

	-- 物理量注入（暖机一阶逆模型，仅供守护/E2E；要求 T 在 20°C 附近，
	-- 二阶不触发，与驱动正算闭环误差 <0.01hPa / <0.01°C）
	function d:set_pt(p_hpa, t_c)
		local c1, c2, c3, c4, c5, c6 = prom[2], prom[3], prom[4], prom[5], prom[6], prom[7]
		local dt = math.floor((t_c * 100 - 2000) * 8388608 / c6 + 0.5)
		local d2v = c5 * 256 + dt
		local off = c2 * 65536 + math.floor(c4 * dt / 128)
		local sens = c1 * 32768 + math.floor(c3 * dt / 256)
		local p_cbar = math.floor(p_hpa * 100 + 0.5)		-- 0.01 mbar 单位
		local d1v = math.floor(((p_cbar * 32768 + off) * 2097152) / sens + 0.5)
		d1, d2 = ms5611_clamp24(d1v), ms5611_clamp24(d2v)
		return self
	end

	function d:fail_cmd(pred) cmd_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:corrupt_prom(on) prom_bad = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		cmd_pred, read_pred, prom_bad = nil, nil, false
		return self
	end

	function d:reset_logs() cmds = {}; return self end

	-- 上电/软复位：PROM reseed、转换态清空；故障钩子保留（防负路径假解除）
	function d:reset()
		seed_prom()
		d1, d2 = 9085466, 8569156
		pending, remaining, read_target, prom_idx = nil, nil, nil, nil
		armed = false
		cmds = {}
		return self
	end

	-- 守护逐拍造数：气压 1013.25±5 hPa、温度 22±2°C（32 拍周期，均在
	-- 暖机段二阶不触发）；并预武装——守护不驱动 advance，call 内两段
	-- 转换命令（D1/D2）下发即就绪，真实 milli_sleep 仅作节拍余量。
	function d:virt_tick(n)
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_pt(1013.25 + 5 * math.sin(ph), 22 + 2 * math.sin(ph))
		armed = true
		pending, remaining = nil, nil
		return self
	end

	-- 只读观察口
	function d:prom_word(i) return prom[i] end
	function d:prom_table()
		local t = {}
		for i = 1, 8 do t[i] = prom[i] end
		return t
	end
	function d:crc_is_valid() return MS5611_VIRT.crc4_ok(prom) end
	function d:pending() return pending end
	function d:remaining_ms() return remaining end
	function d:read_target() return read_target end
	function d:is_armed() return armed end
	function d:d1() return d1 end
	function d:d2() return d2 end
	function d:cmd_count() return #cmds end
	function d:cmd_log() return cmds end

	return d
end

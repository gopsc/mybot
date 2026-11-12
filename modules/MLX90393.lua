-- MLX90393 三轴磁力计 驱动模块（Melexis Triaxis Hall，I2C 地址 0x0C~0x0F）
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MLX90393_VIRT（2026-09-15 自 modules/lib/virtbus/mlx90393.lua
-- 迁入，单文件驱动+模型实验第三十七个，命令字 + status-first 族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE MLX90393 (
--       name    String,
--       I2C     String,
--       address String,
--       gain    String,
--       timeout String
--   );
--   INSERT INTO MLX90393 (name, I2C, address, gain, timeout)
--     VALUES ('mlx0', 'i2c-1', '0x0C', '-', '-');
--
-- 列说明：
--   gain    = GAIN_SEL 0~7（0=最低增益 0.751µT/LSB 量程最大，7=最高增益
--              0.150µT/LSB，灵敏度相差 5 倍），非法值钳到界内，缺省 0
--   timeout = 单次测量就绪轮询超时 ms（缺省 50；就绪位轮不到即报 ERR）
--   各列写 '-' 按缺省值处理
--
-- call 无需额外参数，返回：
--   { result, X/Y/Z(µT，浮点), T(°C), XR/YR/ZR(有符号原始计数), TR(无符号),
--     status(状态字节) }
-- 接 sensor_daemon：fields=X:f|Y:f|Z:f|T:f（驱动内已做补码还原，浮点透传）
--
-- 协议要点（datasheet 3901090393 Rev012 §15；命令式，非寄存器地图）：
--   每条命令的应答【首字节永远是 status】，其后才是数据；先发命令写事务，
--   再 Sr 纯读（NOP 0x00 无副作用，驱动用它轮询 status）。
--   命令：0x00 NOP | 0x10+zyxt SB 突发 | 0x20+zyxt SW 唤醒 |
--         0x30+zyxt SM 单次 | 0x40+zyxt RM 读测量 | 0x50 RR 读寄存器 |
--         0x60 WR 写寄存器 | 0x80 EX 退出模式 | 0xD0 HR Memory Recall |
--         0xE0 HS Memory Store | 0xF0 RT 复位
--   zyxt：bit0=T bit1=X bit2=Y bit3=Z，故 0x3F=SM XYZT、0x4F=RM XYZT；
--         RM/ SM 的片内转换顺序为 TXYZ，应答按 Status-TXYZ 组帧，zyxt
--         中为 0 的分量跳过。
--   WR 帧【4 字节】：[0x60, D15..8, D7..0, A5..A0<<2]（地址在独立第 4 字节）
--   RR 帧【2 字节】：[0x50, A5..A0<<2]，应答 3 字节 = [status, D15..8, D7..0]
--   status：bit7=BURST_MODE bit6=WOC_MODE bit5=SM_MODE（单次转换完成）、
--           bit4=ERROR、bit3=SED、bit2=RS（复位后首帧自清）、bit1:0=D
--           （仅 RR/RM 有效：附加数据字节数 = 2D+2）
--   RM XYZT 应答 9 字节 [status,Tmsb,Tlsb,Xmsb,Xlsb,Ymsb,Ylsb,Zmsb,Zlsb]，
--   走 HAL.i2c_read_bytes（大端合并超 2^53 精度线）
--
-- 寄存器 0x00 = Z-SERIES[15]/GAIN_SEL[14:12]/HALLCONF[11:8]，POR=0x007C
--   （GAIN_SEL=7、HALLCONF=0xC）；build 读-改-写保留 HALLCONF，只改 GAIN_SEL。
--
-- 换算（HALLCONF=0xC、RES=0、TC off、25°C，datasheet Table 17）：
--   GAIN_SEL=0 时 XY=0.751 / Z=1.210 µT/LSB；GAIN_SEL 7~0 的增益倍数表
--   {1,4/3,5/3,2,2.5,3,4,5}，SEL=0 对应 5（相对 SEL=7 基准 0.150/0.242）。
--   温度：45.2 LSB/°C、25°C 输出 46244（u16 无符号），°C = 25+(TR-46244)/45.2。
--
-- build 流程（自检链路）：RT 复位 -> HR Memory Recall（POR/RT 时片内其实
--   自动执行一次 HR，显式再做一次无害）-> 写 GAIN_SEL（读-改-写 + 回读校验）
--   -> SM/RM 试测一帧并丢弃（甄别在位、打通 触发/轮询/读回 全链路）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))

-- 调试开关：传感器高频读取，默认关闭逐次打印
local DEBUG = false

-- ==================== 命令与状态 ====================
local CMD_NOP    = 0x00
local CMD_SB     = 0x10		-- 启动突发模式（低 4 位 zyxt）
local CMD_SW     = 0x20		-- 启动 Wake-on-Change（低 4 位 zyxt）
local CMD_SINGLE = 0x30		-- 启动单次测量（低 4 位 zyxt）
local CMD_READ   = 0x40		-- 读测量结果（低 4 位 zyxt）
local CMD_RR     = 0x50		-- 读寄存器（第 2 字节 = 地址<<2）
local CMD_WR     = 0x60		-- 写寄存器（4 字节帧）
local CMD_EXIT   = 0x80		-- 退出当前模式
local CMD_RECALL = 0xD0		-- HR：NVRAM -> 易失内存（恢复出厂 TRIM）
local CMD_STORE  = 0xE0		-- HS：易失内存 -> NVRAM
local CMD_RESET  = 0xF0		-- RT：复位

local FLAG_T = 0x01
local FLAG_X = 0x02
local FLAG_Y = 0x04
local FLAG_Z = 0x08

-- status 字节布局（datasheet §15.2 Table 12，status 永远是应答首字节）
local ST_BURST = 0x80		-- bit7：当前处于突发模式
local ST_WOC   = 0x40		-- bit6：当前处于 Wake-on-Change 模式
local ST_SM    = 0x20		-- bit5：单次测量完成（SM_MODE）
local ST_ERROR = 0x10		-- bit4：命令被拒绝/不可纠正错误
local ST_RS    = 0x04		-- bit2：复位发生（RT 后首 status 置位、自清）

local CMD_XYZT  = CMD_SINGLE + FLAG_T + FLAG_X + FLAG_Y + FLAG_Z	-- 0x3F
local READ_XYZT = CMD_READ  + FLAG_T + FLAG_X + FLAG_Y + FLAG_Z	-- 0x4F
local RESP_N    = 9			-- 0x4F 应答：status + T/X/Y/Z 各 2 字节

-- 应答内偏移（1 基；status 占 b[1]，片内转换/组帧顺序 TXYZ）
local OFF_STATUS = 1
local OFF_T = 2
local OFF_X = 4
local OFF_Y = 6
local OFF_Z = 8

local REG_GAIN = 0x00		-- Z-SERIES/GAIN_SEL[6:4]/HALLCONF[3:0]，POR=0x007C

-- ==================== 时序常量 ====================
-- RT 后 datasheet 建议等 1.5ms（取 5ms 余量）；HR 无单独等待要求（留 2ms）
local T_RESET_MS  = 5
local T_RECALL_MS = 2
local POLL_MS     = 1		-- 就绪轮询步长

-- ==================== 灵敏度换算（datasheet Table 17，HALLCONF=0xC/RES=0） ====================
-- GAIN_SEL=0 基准：XY=0.751 / Z=1.210 µT/LSB；GAIN_TAB 是 SEL 7~0 相对
-- SEL=7（最高增益 1x）的增益倍数：SEL=0 为 5x。µT/LSB 随倍数正比放大。
local SENS_XY_0 = 0.751
local SENS_Z_0  = 1.210
local GAIN_BASE = 5									-- SEL=0 对应倍数
local GAIN_TAB  = { 5, 4, 3, 2.5, 2, 5 / 3, 4 / 3, 1 }	-- GAIN_SEL 0~7

-- 温度（datasheet §电气特性）：45.2 LSB/°C，25°C 输出 46244（u16 无符号）
local T_LSB_PER_C = 45.2
local T_RAW_AT_25 = 46244

local DEF_GAIN    = 0
local DEF_TIMEOUT = 50		-- ms

-- 模块级配置（build 写入，跨 call 保持于状态机内存，destroy 后废弃）
local sens_xy			-- XY 轴 µT/LSB
local sens_z			-- Z 轴 µT/LSB
local poll_timeout_ms	-- 就绪轮询超时 ms

-- 16 位有符号还原
local s16 = bitc.s16

-- 发送 1 字节命令，成功返回 true
local function send_cmd(fd, cmd)
	return i2c_write_multi(fd, cmd) == 0
end

-- 读 status：NOP 查询（命令本身无副作用），返回 0~255；失败返回 nil
local function read_status(fd)
	if not send_cmd(fd, CMD_NOP) then return nil end
	local v = i2c_read(fd, 1)
	if v < 0 then return nil end
	return v
end

-- 写寄存器（WR 4 字节帧）：[0x60, D15..8, D7..0, A5..A0<<2]
local function write_reg(fd, addr, data16)
	return i2c_write_multi(fd, CMD_WR,
		math.floor(data16 / 256) % 256, data16 % 256, addr * 4) == 0
end

-- 读 16 位寄存器（RR：[0x50, addr<<2] -> [status,Dhi,Dlo] 3 字节应答），
-- 返回 16 位值；失败返回 nil
local function read_reg16(fd, addr)
	if i2c_write_multi(fd, CMD_RR, addr * 4) ~= 0 then return nil end
	local b = i2c_read_bytes(fd, 3)
	if b == nil then return nil end
	return b[2] * 256 + b[3]
end

-- 单次测量：SM 触发 -> NOP 轮询 SM_MODE -> RM 读 9 字节应答。
-- 成功返回字节数组，失败返回 nil + 错误信息
local function measure_once(fd)
	if not send_cmd(fd, CMD_XYZT) then
		return nil, "Failed to start MLX90393 single measurement"
	end

	local left = poll_timeout_ms
	while left > 0 do
		milli_sleep(POLL_MS)
		left = left - POLL_MS

		local st = read_status(fd)
		if st == nil then
			return nil, "Failed to poll MLX90393 status"
		end
		if bitc.band(st, ST_ERROR) ~= 0 then
			return nil, string.format("MLX90393 status ERROR (0x%02X)", st)
		end
		if bitc.band(st, ST_SM) ~= 0 then
			if not send_cmd(fd, READ_XYZT) then
				return nil, "Failed to send MLX90393 read command"
			end
			local b = i2c_read_bytes(fd, RESP_N)
			if b == nil then
				return nil, "Failed to read MLX90393 measurement"
			end
			return b
		end
	end
	return nil, string.format("MLX90393 measurement timeout (%dms, SM_MODE never set; check wiring)", poll_timeout_ms)
end

-- 解析 9 字节应答（status-first，TXYZ 顺序）并换算，返回结果表
local function parse_response(b)
	local tr = b[OFF_T] * 256 + b[OFF_T + 1]			-- 温度 u16 无符号
	local xr = s16(b[OFF_X] * 256 + b[OFF_X + 1])
	local yr = s16(b[OFF_Y] * 256 + b[OFF_Y + 1])
	local zr = s16(b[OFF_Z] * 256 + b[OFF_Z + 1])

	local ret = {
		result = "OK",
		X = xr * sens_xy,				-- µT（浮点）
		Y = yr * sens_xy,
		Z = zr * sens_z,
		T = 25 + (tr - T_RAW_AT_25) / T_LSB_PER_C,	-- °C
		XR = xr, YR = yr, ZR = zr, TR = tr,	-- 磁场有符号；温度无符号
		status = b[OFF_STATUS]
	}

	if DEBUG then
		print(string.format("MLX90393: X=%.2fµT Y=%.2fµT Z=%.2fµT T=%.2f°C", ret.X, ret.Y, ret.Z, ret.T))
	end

	return ret
end

require_driver("i2c", {
	name = "MLX90393",

	-- 【配置脚本】复位 -> Memory Recall -> 写 GAIN_SEL -> 试测一帧自检
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- MLX90393 builder func get a table --------", data)
		end

		local fd = ctx.fd

		-- gain 列 -> GAIN_SEL：取整后钳到 0~7（非法/'-' 归缺省 0）
		-- 26.3：num_or 而非 tonumber——'nan' 过 tonumber 出的是 number，`gain == nil`
		-- 为假；math.floor(NaN) 仍是 NaN，而下面 `gain < 0` / `gain > 7` 两道钳位对
		-- NaN 恒假也放行，于是 GAIN_TAB[NaN + 1] 读出 nil，灵敏度换算对 nil 做算术，
		-- build 抛的是 Lua error 而非 ERR 表——操作者拿到「attempt to perform
		-- arithmetic on a nil value」而不是一句配置错误。本处契约是「归缺省」。
		local gain = num_or(data.gain, DEF_GAIN)
		gain = math.floor(gain)
		if gain < 0 then gain = 0 end
		if gain > 7 then gain = 7 end

		-- timeout 列 -> 轮询超时 ms（非法/非正数归缺省）
		-- 26.3：同 gain——'nan' 使 `to == nil` 与 `to < 1` 均为假，poll_timeout_ms
		-- 落成 NaN，轮询的 `while left > 0` 一拍都不进，于是**每次**测量都立刻判超时，
		-- 而超时文案用 %d 格式化 NaN 出 -9223372036854775808ms。
		local to = num_or(data.timeout, DEF_TIMEOUT)
		if to < 1 then to = DEF_TIMEOUT end
		poll_timeout_ms = math.floor(to)

		-- 灵敏度：µT/LSB 随增益倍数正比（SEL=0 基准 × tab/5）
		sens_xy = SENS_XY_0 * GAIN_TAB[gain + 1] / GAIN_BASE
		sens_z  = SENS_Z_0  * GAIN_TAB[gain + 1] / GAIN_BASE

		-----------------------------------------------------
		-- RT 暖复位
		if not send_cmd(fd, CMD_RESET) then
			return err("Failed to reset MLX90393")
		end
		milli_sleep(T_RESET_MS)

		if not send_cmd(fd, CMD_RECALL) then
			return err("Failed to recall MLX90393 TRIM")
		end
		milli_sleep(T_RECALL_MS)

		-- 写 GAIN_SEL（读-改-写）
		local g = read_reg16(fd, REG_GAIN)
		if g == nil then
			return err("Failed to read MLX90393 GAIN register")
		end
		local newg = bitc.bor(bitc.band(g, 0xFF8F), bitc.lshift(gain, 4))
		if not write_reg(fd, REG_GAIN, newg) then
			return err("Failed to write MLX90393 GAIN register")
		end
		local g2 = read_reg16(fd, REG_GAIN)
		if g2 ~= newg then
			return err(string.format("MLX90393 GAIN verify failed: wrote 0x%04X, read back 0x%04X", newg, g2 or 0))
		end

		-- 试测一帧并丢弃
		local b, emsg = measure_once(fd)
		if b == nil then
			return err(emsg)
		end

		print(string.format("MLX90393 init OK: addr=0x%02X, gain=%d, sens_xy=%.4f sens_z=%.4f µT/LSB, timeout=%dms",
			ctx.addr, gain, sens_xy, sens_z, poll_timeout_ms))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 MLX90393 destroy 仅 arg_table + return OK，等价）

	-- 【调用MLX90393】单次测量
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- MLX90393 caller func get a table --------", data)
		end

		local fd = ctx.fd

		if poll_timeout_ms == nil or sens_xy == nil then
			return err("MLX90393 not built (build first)")
		end

		local b, emsg = measure_once(fd)
		if b == nil then
			return err(emsg)
		end

		return parse_response(b)
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】MLX90393_VIRT —— 2026-09-15 自 modules/lib/virtbus/mlx90393.lua
-- 整体迁入（单文件驱动+模型第三十七个，命令字 + status-first 应答族，守护
-- E2E 走 sensor_daemon 回退路径）。约定同前三十六者：① 生产路径零执行
-- （new() 仅虚拟总线测试调用；位运算经本文件 mpath 上值惰性 dofile
-- bitcompat 并缓存，不共用驱动 bitc；POR 常量/status 位/GAIN 表/clamp/
-- rround 移入段内加 mlx90393_ 前缀避让；new() 内 `local M = MLX90393_VIRT`
-- 绑定使模型体零改动移植）；② 工厂经全局表而非文件 return（生产侧 Lua.cj
-- build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径无 settop，文件返回值
-- 会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防假绿性质不变。
-- 无 BUS 字段 = I2C。
--
-- 定位：【首个「命令字 + status-first 应答 + 易失内存 RR/WR 读写」命令式
-- I2C 器件】（Melexis MLX90393 Triaxis 三轴磁力计，驱动用 0x0C）——无
-- 寄存器指针事务：每条命令先一笔写再 Sr 纯读，应答首字节永远是 status。
-- 命令集 0x00 NOP/0x1n SB/0x2n SW/0x3n SM/0x4n RM/0x50 RR/0x60 WR/0x80 EX/
-- 0xD0 HR/0xE0 HS/0xF0 RT；非法命令恒 ACK+ERROR 锁存；RM Status-TXYZ
-- 组帧；SM 单次转换门与 DRDY 低读锁错；64×16bit 易失内存（Melexis 区
-- 0x20~0x3F 写保护）；转换门 advance(ms) 推进；prearmed 测试桩注入态；
-- virt_tick 32 拍正弦四通道。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

MLX90393_VIRT = {
	_VERSION = "0.1.0",
	I2C_ADDR = 0x0C,			-- EE_I2C_ADDR=0x03 时 0x0C/0x0D/0x0E/0x0F，驱动用 0x0C
	POR_GAIN = 0x007C,		-- reg0x00 上电值：GAIN_SEL=7、HALLCONF=0xC
	T_RAW_25C = 46244,		-- 25°C 温度原始输出（45.2 LSB/°C）
}

-- 位运算惰性装载：首次用到位运算时 dofile bitcompat 并缓存
local mlx90393_ops_cache = nil
local function mlx90393_ops()
	if mlx90393_ops_cache == nil then
		local ok, bc = pcall(dofile, mpath.resolve("bitcompat.lua"))
		mlx90393_ops_cache = (ok and bc) or false
	end
	return mlx90393_ops_cache
end

function MLX90393_VIRT.new()
	local bitc = mlx90393_ops()

-- status 位（datasheet §15.2）
local ST_BURST, ST_WOC, ST_SM, ST_ERROR, ST_RS = 0x80, 0x40, 0x20, 0x10, 0x04

-- GAIN_SEL 0~7 相对 SEL=7（最高增益 1x）的增益倍数（Table 17）
local GAIN_MULT = { 5, 4, 3, 2.5, 2, 5 / 3, 4 / 3, 1 }

local function clamp16(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > 65535 then return 65535 else return v end
end
local function clamp_s16(v)
	v = math.floor(tonumber(v) or 0)
	if v < -32768 then return -32768 elseif v > 32767 then return 32767 else return v end
end
-- 四舍五入（含负值：-0.6 -> -1；按幅度取整，避免 -75.1/0.751 的二进制
-- 表示误差 99.9999999 被旧 floor(v-0.5) 误杀成 -101）
local function rround(v)
	if v >= 0 then return math.floor(v + 0.5) end
	return -math.floor(-v + 0.5)
end

	local M = MLX90393_VIRT	-- 模型体沿用原模块表引用（零改动移植）

	local d = {}

	-- ---------------- 芯片侧状态 ----------------
	local regs = {}						-- 64×16bit 易失内存（缺省 0）
	local mode = "idle"					-- idle | single | burst | woc
	local sel = 0						-- 最近一次 SM/SB 的 zyxt 分量
	local drdy = false					-- single：转换完成结果锁存；burst：首转换后恒真
	local remaining = nil				-- 转换剩余 ms（nil=无转换进行中）
	local prearmed = false				-- virt_tick 预武装：下一次 SM 零转换门
	local never_ready = false			-- 转换永不完成（轮询超时注入）
	local error_latch = false			-- status ERROR 位锁存（被接受的命令清除）
	local rs_latch = false				-- RT 后首 status 的 RS 位
	local pending = nil					-- nil | {k="status"} | {k="rr",a=} | {k="rm",m=}
	local sample_t, sample_x, sample_y, sample_z = M.T_RAW_25C, 0, 0, 0
	local cmds, unknown, frames = {}, {}, {}

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	local function reseed()
		for k in pairs(regs) do regs[k] = nil end
		regs[0x00] = M.POR_GAIN
	end
	reseed()

	-- 当前 GAIN_SEL/RES 配置下的 µT/LSB（与驱动 Table 17 同源，仅供 set_sample）
	local function sensitivities()
		local g = bitc.band(bitc.rshift(regs[0x00] or 0, 4), 0x7)
		local mult = GAIN_MULT[g + 1]
		return 0.751 * mult / 5, 1.210 * mult / 5
	end

	-- status 合成：dbits 仅 RR/RM 应答有效（附加数据 2D+2 字节）
	local function build_status(dbits)
		local s = dbits or 0
		if mode == "burst" then s = s + ST_BURST end
		if mode == "woc" then s = s + ST_WOC end
		if mode == "single" and drdy then s = s + ST_SM end
		if error_latch then s = s + ST_ERROR end
		if rs_latch then s = s + ST_RS end
		return s
	end

	-- 转换门 ms（§电气特性公式；RES 只选输出位宽、不影响时间）
	local function conv_ms(mask)
		local r2 = regs[0x02] or 0
		local hi = math.floor(r2 / 256) % 256
		local lo = r2 % 256
		local osr = bitc.band(hi, 0x03)
		local dig = bitc.band(hi, 0x0C) / 4
		local osr2 = bitc.band(lo, 0xC0) / 64
		local tmag = 0.067 + 0.064 * 2 ^ osr * (2 + 2 * dig)
		local ttmp = 0.067 + 0.192 * 2 ^ osr2
		local nm = (bitc.band(mask, 0x2) ~= 0 and 1 or 0)
			+ (bitc.band(mask, 0x4) ~= 0 and 1 or 0)
			+ (bitc.band(mask, 0x8) ~= 0 and 1 or 0)
		local total = 0.36 + 0.10 + nm * tmag
			+ (bitc.band(mask, 0x1) ~= 0 and ttmp or 0)
		local ms = math.ceil(total)
		if ms < 1 then ms = 1 end
		return ms
	end

	local function start_single(mask)
		mode, sel, drdy = "single", mask, false
		error_latch = false
		if prearmed and not never_ready then
			remaining, drdy = 0, true
		elseif never_ready then
			remaining = nil
		else
			remaining = conv_ms(mask)
		end
		prearmed = false
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		frames[#frames + 1] = {}
		for i = 1, #bytes do frames[#frames][i] = bytes[i] % 256 end
		if d.nack or d.nack_write or (write_pred and write_pred(bytes)) then
			return false
		end

		local c = bytes[1] % 256
		local hi = math.floor(c / 16) % 16
		local nib = c % 16

		if c == 0x00 then									-- NOP
			if #bytes ~= 1 then return false end
			error_latch = false
			pending = { k = "status" }

		elseif hi == 0x1 or hi == 0x2 then					-- SB / SW
			if #bytes ~= 1 then return false end
			if mode ~= "idle" then
				error_latch = true; pending = { k = "status" }; unknown[#unknown + 1] = c
				return true
			end
			local mask = nib ~= 0 and nib or (regs[0x01] or 0) % 16
			if mask == 0 then
				error_latch = true; pending = { k = "status" }; unknown[#unknown + 1] = c
				return true
			end
			mode = (hi == 0x1) and "burst" or "woc"
			sel, drdy = mask, false
			if never_ready then
				remaining = 1e9
			else
				remaining = prearmed and 0 or conv_ms(mask)
			end
			prearmed = false
			error_latch = false
			pending = { k = "status" }

		elseif hi == 0x3 then								-- SM
			if #bytes ~= 1 then return false end
			-- 仅 IDLE 接受：拒答时期望模式位保持清零 + ERROR
			if mode ~= "idle" then
				error_latch = true; pending = { k = "status" }; unknown[#unknown + 1] = c
				return true
			end
			local mask = nib ~= 0 and nib or (regs[0x01] or 0) % 16
			if mask == 0 then
				error_latch = true; pending = { k = "status" }; unknown[#unknown + 1] = c
				return true
			end
			start_single(mask)
			pending = { k = "status" }

		elseif hi == 0x4 then								-- RM（就绪与否在读时判）
			if #bytes ~= 1 then return false end
			error_latch = false
			pending = { k = "rm", m = nib }

		elseif c == 0x50 then								-- RR：恰 2B，abc=0
			if #bytes ~= 2 or bytes[2] % 4 ~= 0 then return false end
			local addr = math.floor(bytes[2] / 4)
			if mode ~= "idle" then
				error_latch = true; pending = { k = "status" }
			else
				error_latch = false
				pending = { k = "rr", a = addr }
			end

		elseif c == 0x60 then								-- WR：恰 4B，地址字节低 2 位 0
			if #bytes ~= 4 or bytes[4] % 4 ~= 0 then return false end
			local addr = math.floor(bytes[4] / 4)
			local data = bytes[2] * 256 + bytes[3]
			error_latch = false
			if mode ~= "idle" or addr >= 0x20 then
				-- 突发中 RR/WR 不允许、Melexis 区写保护：命令照 ACK，ERROR 置位
				error_latch = true
			else
				regs[addr] = data % 65536
			end
			pending = { k = "status" }

		elseif c == 0x80 then								-- EX
			if #bytes ~= 1 then return false end
			mode, sel, drdy, remaining = "idle", 0, false, nil
			error_latch = false
			pending = { k = "status" }

		elseif c == 0xD0 then								-- HR：NVRAM -> 易失
			if #bytes ~= 1 then return false end
			reseed()
			mode, sel, drdy, remaining = "idle", 0, false, nil
			error_latch = false
			pending = { k = "status" }

		elseif c == 0xE0 then								-- HS（后等 15ms，模型无 NVRAM 写）
			if #bytes ~= 1 then return false end
			error_latch = false
			pending = { k = "status" }

		elseif c == 0xF0 then							-- RT：暖复位
			if #bytes ~= 1 then return false end
			reseed()
			mode, sel, drdy, remaining = "idle", 0, false, nil
			-- 注意：prearmed【不清】——它是测试桩注入态而非芯片状态。守护
			-- build 前 virt_tick(0) 预武装，而 build 第一条命令正是 RT，
			-- 若随复位取消，build 内试测转换门在真实 milli_sleep 下永不完成。
			error_latch = false
			rs_latch = true
			pending = { k = "status" }

		else
			-- 非法命令：I2C 恒 ACK，ERROR 置位（datasheet §15.1）
			error_latch = true
			pending = { k = "status" }
			unknown[#unknown + 1] = c
		end

		cmds[#cmds + 1] = c
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		n = math.floor(tonumber(n) or 0)
		if n < 1 then return nil end
		if read_pred and read_pred(pending, n) then return nil end
		if pending == nil then return nil end

		if pending.k == "status" then
			if n ~= 1 then return nil end
			local s = build_status(0)
			rs_latch = false					-- RS 首读后自清
			pending = nil
			return { s }
		end

		if pending.k == "rr" then
			if n ~= 3 then return nil end
			local v = regs[pending.a] or 0
			pending = nil
			return { build_status(0), math.floor(v / 256) % 256, v % 256 }
		end

		if pending.k == "rm" then
			local mask = pending.m
			local knt = (bitc.band(mask, 0x1) ~= 0 and 1 or 0)
				+ (bitc.band(mask, 0x2) ~= 0 and 1 or 0)
				+ (bitc.band(mask, 0x4) ~= 0 and 1 or 0)
				+ (bitc.band(mask, 0x8) ~= 0 and 1 or 0)
			if n ~= 1 + 2 * knt then return nil end
			-- DRDY 低读数据：ERROR 置位、无数据（datasheet §15.2）
			if mode == "single" and not drdy then
				error_latch = true; return nil
			end
			if mode ~= "burst" and not drdy then
				error_latch = true; return nil
			end
			if mode == "burst" and remaining ~= nil and remaining > 0 then
				error_latch = true; return nil
			end
			local out = { build_status(knt - 1) }
			local function put(v)
				v = v % 65536
				out[#out + 1] = math.floor(v / 256) % 256
				out[#out + 1] = v % 256
			end
			if bitc.band(mask, 0x1) ~= 0 then put(sample_t) end
			if bitc.band(mask, 0x2) ~= 0 then put(sample_x) end
			if bitc.band(mask, 0x4) ~= 0 then put(sample_y) end
			if bitc.band(mask, 0x8) ~= 0 then put(sample_z) end
			if mode == "single" then
				-- 结果读走：回 IDLE、SM_MODE 清
				mode, drdy = "idle", false
			end
			pending = nil
			return out
		end

		return nil
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	function d:advance(ms)
		ms = tonumber(ms) or 0
		if rs_latch and ms > 0 then rs_latch = false end
		if never_ready then return self end
		if remaining ~= nil then
			remaining = remaining - ms
			if remaining <= 0 then
				remaining = nil
				if mode == "single" then drdy = true end
			end
			if mode == "burst" and remaining == nil then drdy = true end
		end
		return self
	end

	-- 注入原始码：磁场 s16 计数（µT 换算归驱动），温度 u16 无符号
	function d:set_raw(t, x, y, z)
		sample_t = clamp16(t)
		sample_x = clamp_s16(x)
		sample_y = clamp_s16(y)
		sample_z = clamp_s16(z)
		return self
	end

	-- 物理量注入（守护/E2E 造样本；按当前 GAIN_SEL 反算成码）
	function d:set_sample(t_c, x_uT, y_uT, z_uT)
		local sxy, sz = sensitivities()
		sample_t = clamp16(rround(M.T_RAW_25C + 45.2 * ((tonumber(t_c) or 25) - 25)))
		sample_x = clamp_s16(rround((tonumber(x_uT) or 0) / sxy))
		sample_y = clamp_s16(rround((tonumber(y_uT) or 0) / sxy))
		sample_z = clamp_s16(rround((tonumber(z_uT) or 0) / sz))
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end
	function d:set_error(on) error_latch = on ~= false; return self end
	function d:set_never_ready(on) never_ready = on ~= false; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		error_latch, never_ready = false, false
		return self
	end

	function d:reset_logs()
		cmds, unknown, frames = {}, {}, {}
		return self
	end

	-- 回上电态（故障钩子保留，防负路径假解除）
	function d:reset()
		reseed()
		mode, sel, drdy = "idle", 0, false
		remaining, prearmed, error_latch, rs_latch, pending = nil, false, false, false, nil
		sample_t, sample_x, sample_y, sample_z = M.T_RAW_25C, 0, 0, 0
		cmds, unknown, frames = {}, {}, {}
		return self
	end

	-- 守护逐拍造数：确定性地磁场量级正弦（X±30µT 含负值、Y 25µT 移相、
	-- Z 30~50µT、T 20~30°C，32 拍周期）+ 预武装（下一次 SM 零转换门）。
	function d:virt_tick(n)
		n = tonumber(n) or 0
		local ph = 2 * math.pi * (n % 32) / 32
		self:set_sample(25 + 5 * math.sin(ph + math.pi / 4),
			30 * math.sin(ph),
			25 * math.sin(ph + math.pi / 3),
			40 + 10 * math.sin(ph + math.pi / 2))
		prearmed = true
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a) return regs[a] or 0 end
	function d:gain_sel() return bitc.band(bitc.rshift(regs[0x00] or 0, 4), 0x7) end
	function d:sensitivities() local a, b = sensitivities(); return a, b end
	function d:mode() return mode end
	function d:select_mask() return sel end
	function d:is_ready() return drdy end
	function d:remaining_ms() return remaining end
	function d:pending() return pending and pending.k or nil end
	function d:current_status() return build_status(0) end
	function d:cmd_count() return #cmds end
	function d:commands() return cmds end
	function d:unknown_commands() return unknown end
	function d:write_log() return frames end
	function d:raw() return sample_t, sample_x, sample_y, sample_z end

	return d
end

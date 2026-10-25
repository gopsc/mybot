-- BMI270 六轴 IMU（16 位加速度计 + 16 位陀螺仪）驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 BMI270_VIRT（2026-09-15 自 modules/lib/virtbus/bmi270.lua
-- 迁入，单文件驱动+模型实验第三十九个，blob 上传状态机族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- Bosch Sensortec，I2C 地址 0x68/0x69（SDO 引脚，与 MPU6050 同址），
-- 输出六轴原始码：ACCEL_X/Y/Z（g）与 GYRO_X/Y/Z（dps）
--
-- 用法（结构脚本 .sql）：
--   CREATE TABLE BMI270 (
--       name       String,
--       I2C        String,
--       address    String,
--       range      String,
--       gyro_range String,
--       odr        String,
--       cfg        String
--   );
--   INSERT INTO BMI270 (name, I2C, address, range, gyro_range, odr, cfg)
--     VALUES ('imu0', 'i2c-1', '0x68', '-', '-', '-', '-');
-- range      = 加速度计量程 g（2/4/8/16，非法值向下降档，缺省 8，同 MPU6050 驱动）
-- gyro_range = 陀螺仪量程 dps（125/250/500/1000/2000，非法值向下降档，缺省 500）
-- odr        = 输出数据率 Hz（25/50/100/200/400/800/1600，取最近档，缺省 100）
-- cfg        = 配置文件 blob：'fifo'（缺省，328B）/ 'full'（8KB，见下）
-- 各列写 '-' 按缺省值处理
--
-- 接 sensor_daemon：fields=ACCEL_X|ACCEL_Y|ACCEL_Z|GYRO_X|GYRO_Y|GYRO_Z，
-- sign='16'（输出为 16 位补码语义的原始无符号码，与 MPU6050 驱动同约定，
-- 负值由守护的 sign 展开而非驱动侧转负）
--
-- 实现要点（依 Bosch BMI270-SensorAPI v2.46.1 bmi2.c/bmi2_defs.h + datasheet 钉死）：
--   1. 与 MPU6050 的两大差异，勿照搬：
--      a) 陀螺仪与特性引擎必须先上传配置文件 blob 才工作（MPU6050 写两个
--         寄存器就能用）；不传 blob 只有加速度计可用
--      b) 数据寄存器小端（LSB 在前），MPU6050 是大端——照搬会六轴全错
--   2. blob 双版本（modules/lib/bmi270_config.lua，Bosch 官方 MIT）：
--      'fifo'  = maximum_fifo 变体 328B，只含传感器数据必需配置（片上特性
--                算法不启用——框架滤波自做），上传 41 事务，Zephyr 通用驱动同款；
--      'full'  = context 变体 8KB，全特性引擎兜底；个别硅版 fifo 陀螺仪
--                不出数时换用，上传约 1s
--      上传协议（bmi2.c upload_file）：INIT_CTRL(0x59)=0 -> 每块先写内部字地址
--      （字节序号/2，12 位小端，低字节 &0x0F）到 0x5B/0x5C，再 8 字节突发写
--      INIT_DATA(0x5E) -> INIT_CTRL=1 -> 轮询 INTERNAL_STATUS(0x21) 到 0x01
--      （BMI2_INIT_OK；注意是状态码不是位掩码）
--   3. 初始化全序：软复位(0x7E<-0xB6) -> 验芯片 ID 0x24（读到 0x26 是 BMI260
--      变体）-> 关高级省电(PWR_CONF=0) -> 上电配置上传 -> ODR 读改写 [3:0] 域
--      （保留复位默认滤波）-> 量程 -> PWR_CTRL |0x06（acc+gyr）-> 等 100ms
--      陀螺仪启动
--   4. call 用 0x0C 起单次 12 字节原子读（i2c_read_multi_bytes 的 I2C_RDWR
--      合并事务，字节表版无 2^53 精度限制；并读防六轴两笔事务间新采样完成
--      造成 acc/gyr 时间错位——C-L1，与 MPU6050 14 字节 burst 同一结论）
--   5. 原始码换算（写配置时定）：加速度计 LSB/g = 16384/8192/4096/2048
--      （±2/4/8/16g）；陀螺仪 LSB/dps = 262.144/131.072/65.536/32.768/16.384
--      （±125/250/500/1000/2000dps）

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bitc = dofile(mpath.resolve("bitcompat.lua"))
local CONFIG = dofile(mpath.resolve("lib/bmi270_config.lua"))
local unpack = unpack or table.unpack		-- LuaJIT 5.1 / Lua 5.4 双兼容

-- 调试开关：高频采样，默认关闭逐次打印
local DEBUG = false

-- ==================== 寄存器 ====================
local REG_CHIP_ID    = 0x00
local REG_ACC_DATA   = 0x0C		-- 加速度计 X_LSB 起 6 字节（小端）
local REG_INT_STATUS = 0x21		-- 内部状态码：0x01 = BMI2_INIT_OK
local REG_ACC_CONF   = 0x40		-- [3:0]=ODR [6:4]=滤波 [7]=性能模式
local REG_ACC_RANGE  = 0x41		-- [1:0]：0=±2g 1=±4g 2=±8g 3=±16g
local REG_GYR_CONF   = 0x42		-- [3:0]=ODR [6:4]=滤波 [7]=噪声性能
local REG_GYR_RANGE  = 0x43		-- [2:0]：0=±2000 1=±1000 2=±500 3=±250 4=±125dps
local REG_INIT_CTRL  = 0x59		-- 0=准备下载 1=开始加载
local REG_INIT_ADDR  = 0x5B		-- 内部字地址（0x5B 低字节 &0x0F + 0x5C 高字节）
local REG_INIT_DATA  = 0x5E		-- 配置数据窗口
local REG_PWR_CONF   = 0x7C		-- bit0 = 高级省电（上传期间必须关）
local REG_PWR_CTRL   = 0x7D		-- bit1=gyr_en bit2=acc_en
local REG_CMD        = 0x7E		-- 命令寄存器

local CHIP_ID        = 0x24
local CMD_SOFT_RESET = 0xB6
local PWR_ACC_GYR    = 0x06
local INIT_OK        = 0x01

-- 上传块长（Bosch read_write_len 上限 32 内取 8：fifo/full 两种 blob 长度
-- 均为 8 的倍数，免去官方 API 的 2 字节余量分支；字地址随块推进 4）
local CHUNK = 8

-- ==================== 配置表 ====================
-- 加速度计量程 g（代码 0..3），缺省 ±8g
local acc_tab = { 2, 4, 8, 16 }
-- 陀螺仪量程 dps（与代码逆序：125=4 ... 2000=0），缺省 ±500dps
local gyr_tab = { 125, 250, 500, 1000, 2000 }
-- 输出数据率 Hz（25Hz=代码 0x06 起），缺省 100Hz
local odr_tab = { 25, 50, 100, 200, 400, 800, 1600 }

-- 向下取档：不大于 n 的最大合法档（量程类，保守取小）；非法/非正归缺省档
local function snap_down(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	for i = #tab, 1, -1 do
		if n >= tab[i] then return i end
	end
	return def_i
end

-- 最近取档：差值最小档（ODR 类，双向皆可），平手取低
local function snap_near(v, tab, def_i)
	local n = tonumber(v)
	if n == nil or n <= 0 then return def_i end
	local best, bd = def_i, math.huge
	for i = 1, #tab do
		local d = math.abs(n - tab[i])
		if d < bd then best, bd = i, d end
	end
	return best
end

local function acc_code_of(v)
	local i = snap_down(v, acc_tab, 3)
	return i - 1, acc_tab[i]
end

local function gyr_code_of(v)
	local i = snap_down(v, gyr_tab, 3)
	return #gyr_tab - i, gyr_tab[i]		-- dps 与寄存器代码逆序
end

local function odr_code_of(v)
	local i = snap_near(v, odr_tab, 3)
	return 0x05 + i, odr_tab[i]
end

-- ==================== 配置文件 blob ====================
-- hex 串惰性解码为二进制（每状态机一次）；长度不符立即失败（数据文件损坏
-- 会在驱动加载时报错，而不是 build 时静默上传垃圾）
local function hex2bin(h)
	return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end
local BLOBS = {
	fifo = hex2bin(CONFIG.FIFO_HEX),
	full = hex2bin(CONFIG.FULL_HEX),
}
if #BLOBS.fifo ~= 328 or #BLOBS.full ~= 8192 then
	error("BMI270 config blob size mismatch: fifo=" .. #BLOBS.fifo .. " full=" .. #BLOBS.full)
end

-- 上传 blob：字地址（字节序号/2，低字节 &0x0F + 高字节）-> 0x5B，再 CHUNK
-- 字节突发写 0x5E（依 bmi2.c upload_file：地址按 2 字节字粒度，burst<=32）
local function upload_blob(fd, blob)
	for i = 1, #blob, CHUNK do
		local word = math.floor((i - 1) / 2)
		local bytes = { blob:byte(i, math.min(i + CHUNK - 1, #blob)) }
		-- 注意 i2c_write_multi 契约为 0=成功/-1=NACK：不能用 not r
		-- 判定（Lua 中 -1 为真，地址相写失败会被当成功继续传数据）
		if i2c_write_multi(fd, REG_INIT_ADDR, word % 16, math.floor(word / 16)) ~= 0 then
			return false
		end
		if i2c_write_multi(fd, REG_INIT_DATA, unpack(bytes)) ~= 0 then
			return false
		end
	end
	return true
end

-- 读 1 字节寄存器；失败返回 nil
local function read_reg8(fd, reg)
	local v = i2c_read_multi(fd, reg, 1)
	if v < 0 then return nil end
	return v
end

require_driver("i2c", {
	name = "BMI270",

	-- 【配置脚本】软复位 -> 验 ID -> 上传 blob -> ODR/量程 -> 上电
	build = function(ctx, data)
		if DEBUG then
			dbg_table("-------- BMI270 builder func get a table --------", data)
		end

		local fd = ctx.fd

		-- 列配置
		local acc_code_v, acc_g = acc_code_of(data.range)
		local gyr_code_v, gyr_dps = gyr_code_of(data.gyro_range)
		local odr_code_v, odr_hz = odr_code_of(data.odr)
		local blob_name = (data.cfg == "full") and "full" or "fifo"
		local blob = BLOBS[blob_name]

		-----------------------------------------------------
		-- 软复位（含 450µs 复位延时，取 2ms 余量）
		if not i2c_write_reg(fd, REG_CMD, CMD_SOFT_RESET) then
			return err("Failed to write BMI270 soft reset")
		end
		milli_sleep(2)

		-- 芯片甄别（0x26 = BMI260 变体，blob 不通用）
		local id = i2c_read_reg(fd, REG_CHIP_ID)
		if id < 0 then
			return err("Failed to read BMI270 chip ID")
		end
		if id ~= CHIP_ID then
			return err(string.format("Chip ID = 0x%02X (expect 0x24; 0x26 means BMI260 variant?)", id))
		end

		-- 关高级省电（上传前提）+ 全传感器下电（复位后本就为 0，显式写保平安）
		if not i2c_write_reg(fd, REG_PWR_CONF, 0x00) then
			return err("Failed to write BMI270 PWR_CONF")
		end
		milli_sleep(1)
		if not i2c_write_reg(fd, REG_PWR_CTRL, 0x00) then
			return err("Failed to write BMI270 PWR_CTRL")
		end
		milli_sleep(1)

		-- 上传配置文件 blob
		if not i2c_write_reg(fd, REG_INIT_CTRL, 0x00) then
			return err("Failed to write BMI270 INIT_CTRL")
		end
		if not upload_blob(fd, blob) then
			return err("Failed to upload BMI270 config file (" .. blob_name .. ")")
		end
		if not i2c_write_reg(fd, REG_INIT_CTRL, 0x01) then
			return err("Failed to start BMI270 config load")
		end

		-- 轮询内部状态码（0x01 = BMI2_INIT_OK），10ms 步进 50 次（500ms 超时）
		local st = -1
		for _ = 1, 50 do
			milli_sleep(10)
			st = i2c_read_reg(fd, REG_INT_STATUS)
			if st == INIT_OK or st < 0 then break end
		end
		if st < 0 then
			return err("Failed to read BMI270 internal status")
		end
		if st ~= INIT_OK then
			return err(string.format("BMI270 config load failed: internal status 0x%02X (expect 0x01 INIT_OK)",
					st))
		end

		-- ODR：读改写 [3:0] 域，保留复位默认滤波/性能位
		local acc_conf = read_reg8(fd, REG_ACC_CONF)
		local gyr_conf = read_reg8(fd, REG_GYR_CONF)
		if acc_conf == nil or gyr_conf == nil then
			return err("Failed to read BMI270 CONF registers")
		end
		if not i2c_write_reg(fd, REG_ACC_CONF,
			bitc.bor(bitc.band(acc_conf, 0xF0), odr_code_v)) then
			return err("Failed to write BMI270 ACC_CONF")
		end
		if not i2c_write_reg(fd, REG_GYR_CONF,
			bitc.bor(bitc.band(gyr_conf, 0xF0), odr_code_v)) then
			return err("Failed to write BMI270 GYR_CONF")
		end

		-- 量程
		if not i2c_write_reg(fd, REG_ACC_RANGE, acc_code_v) then
			return err("Failed to write BMI270 ACC_RANGE")
		end
		if not i2c_write_reg(fd, REG_GYR_RANGE, gyr_code_v) then
			return err("Failed to write BMI270 GYR_RANGE")
		end

		-- 上电：加速度计 + 陀螺仪（温度恒开；保留其余位）
		local pc = read_reg8(fd, REG_PWR_CTRL)
		if pc == nil then
			return err("Failed to read BMI270 PWR_CTRL")
		end
		if not i2c_write_reg(fd, REG_PWR_CTRL, bitc.bor(pc, PWR_ACC_GYR)) then
			return err("Failed to enable BMI270 acc+gyr")
		end

		-- 陀螺仪启动等待（数据手册 ~40ms，取 100ms 余量，首拍数据就绪）
		milli_sleep(100)

		print(string.format("BMI270 init OK: addr=0x%02X, blob=%s(%dB), ±%dg/±%ddps, odr=%dHz",
			ctx.addr, blob_name, #blob, acc_g, gyr_dps, odr_hz))
		return {  result = "OK"  }
	end,

	-- destroy 缺省 = 空操作（原 BMI270 destroy 仅 arg_table + return OK，等价）

	-- 【调用BMI270】读六轴原始码
	call = function(ctx, data)
		if DEBUG then
			dbg_table("-------- BMI270 caller func get a table --------", data)
		end

		local fd = ctx.fd

		-- 0x0C~0x17 地址连续：acc+gyr 12 字节单事务读，防两笔事务间撕裂（C-L1）
		local d = i2c_read_multi_bytes(fd, REG_ACC_DATA, 12)
		if d == nil then
			return err("Failed to read BMI270 sensor data")
		end
		local a = { d[1], d[2], d[3], d[4], d[5], d[6] }
		local g = { d[7], d[8], d[9], d[10], d[11], d[12] }

		-- 返回字典（小端拼字：值 = MSB<<8 | LSB）
	 	return {
			result  = "OK",
			ACCEL_X = bitc.bor(bitc.lshift(a[2], 8), a[1]),
			ACCEL_Y = bitc.bor(bitc.lshift(a[4], 8), a[3]),
			ACCEL_Z = bitc.bor(bitc.lshift(a[6], 8), a[5]),
			GYRO_X  = bitc.bor(bitc.lshift(g[2], 8), g[1]),
			GYRO_Y  = bitc.bor(bitc.lshift(g[4], 8), g[3]),
			GYRO_Z  = bitc.bor(bitc.lshift(g[6], 8), g[5])
		}
	end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】BMI270_VIRT —— 2026-09-15 自 modules/lib/virtbus/bmi270.lua
-- 整体迁入（单文件驱动+模型第三十九个，blob 上传状态机族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前三十八者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，纯闭包零外部依赖（blob 数据引用
-- modules/lib/bmi270_config.lua 不转录）；寄存器地址/POR 表/量程表/clamp/
-- is_byte/round_away 全部移入 new() 内避让）；② 工厂经全局表而非文件
-- return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径
-- 无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防
-- 假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：Bosch BMI270 六轴 IMU 模型（CHIP_ID=0x24；配置 blob 三段握手
-- INIT_CTRL 清零→每 8 字节 INIT_ADDR(0x5B) 低 4 位/整字双字节寻址 +
-- INIT_DATA(0x5E) 8 字节突发——burst 全部字节落 blob 窗口、不普通自增
-- 不进 regs 影子→INIT_CTRL=1 启动 150ms 加载门；fifo 328B/full 8192B
-- 合法长度、不符即 INTERNAL_STATUS=0x02；0x0C..0x17 六轴 12 字节小端
-- LSB 在前连续测量；blob 数据引用 modules/lib/bmi270_config.lua 不转录
-- 进模型，32 拍六轴离线码钉独立换算反解）。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

BMI270_VIRT = { _VERSION = "0.1.0" }

function BMI270_VIRT.new()
-- ==================== 寄存器地址 / 协议常量 ====================
local R_CHIP_ID    = 0x00		-- ROM CHIP_ID=0x24
local R_ACC_X_LSB  = 0x0C		-- 加速度 6 字节小端 0x0C..0x11
local R_GYR_X_LSB  = 0x12		-- 陀螺仪 6 字节小端 0x12..0x17
local R_INT_STATUS = 0x21		-- 内部状态码（非位掩码）：1=init_ok
local R_ACC_CONF   = 0x40		-- [3:0]=ODR [6:4]=bwp bit7=perf
local R_ACC_RANGE  = 0x41		-- [1:0] 量程码
local R_GYR_CONF   = 0x42
local R_GYR_RANGE  = 0x43		-- [2:0] 量程码（与 dps 逆序）bit3=ois
local R_INIT_CTRL  = 0x59		-- 0=准备下载清缓冲 1=启动加载
local R_INIT_ADDR0 = 0x5B		-- 字地址低 4 位
local R_INIT_ADDR1 = 0x5C		-- 字地址高 8 位
local R_INIT_DATA  = 0x5E		-- 配置数据窗口（地址陷阱）
local R_PWR_CONF   = 0x7C		-- 低 3 位
local R_PWR_CTRL   = 0x7D		-- 低 4 位
local R_CMD        = 0x7E		-- 只写命令

local CHIP_ID        = 0x24
local CMD_SOFT_RESET = 0xB6
local LOAD_GATE_MS   = 150		-- INIT_CTRL=1 到 init_ok 的加载门
local BLOB_FIFO_LEN  = 328		-- maximum_fifo 变体 41 块
local BLOB_FULL_LEN  = 8192	-- context 变体 1024 块

-- POR 默认值（datasheet register overview RESET 列）
local POR_ACC_CONF  = 0xA8
local POR_ACC_RANGE = 0x02
local POR_GYR_CONF  = 0xA9
local POR_GYR_RANGE = 0x00
local POR_PWR_CONF  = 0x03
local POR_PWR_CTRL  = 0x00

-- 量程码 → LSB/物理量（物理量注入反算用；驱动头注释常数）
local ACC_LSB_PER_G = { 16384, 8192, 4096, 2048 }		-- ±2/4/8/16g
local GYR_LSB_PER_DPS = { 16.384, 32.768, 65.536, 131.072, 262.144 } -- ±2000..±125

local function is_byte(v)
	return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 255
end

-- 四舍五入到远离零的整数（负物理量造码用）
local function round_away(x)
	if x >= 0 then return math.floor(x + 0.5) end
	return -math.floor(-x + 0.5)
end

	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 稀疏字节寄存器影子（未定义地址读 0）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此起 burst）
	local chip_id = CHIP_ID		-- ROM 身份（who 覆写跨软复位保留）

	-- blob 上传状态机
	local uploaded = {}			-- 配置缓冲（按字节序号 1 基）
	local upload_bytes = 0		-- INIT_CTRL=0 以来写入窗口的字节数
	local word_addr = 0			-- 当前内部字地址（12 位，0..4095）
	local load_phase = "idle"	-- idle | loading | ok | error
	local gate_left = 0			-- 加载门剩余 ms
	local prearmed = false		-- virt_tick：下次 INIT_CTRL=1 立即 init_ok
	local never_ready = false	-- 加载门永不到点（轮询超时负路径）
	local stuck_code = nil		-- 非 nil 时 0x21 恒返该状态码

	-- 六轴测量码（s16，仅注入 API 可改；软复位保留，reset 清零）
	local ax, ay, az = 0, 0, 0
	local gx, gy, gz = 0, 0, 0

	local reset_count = 0		-- 软复位次数
	local write_count = 0		-- ≥2B 写事务笔数
	local read_count = 0		-- 读事务笔数
	local frames = {}			-- ≥2B 写事务副本

	-- 故障钩子（reset 保留，clear_faults 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred

	-- ---------------- POR / 软复位 ----------------

	local function seed_body()
		regs = {}
		regs[R_ACC_CONF] = POR_ACC_CONF
		regs[R_ACC_RANGE] = POR_ACC_RANGE
		regs[R_GYR_CONF] = POR_GYR_CONF
		regs[R_GYR_RANGE] = POR_GYR_RANGE
		regs[R_PWR_CONF] = POR_PWR_CONF
		regs[R_PWR_CTRL] = POR_PWR_CTRL
		regs[R_INIT_CTRL] = 0x00
		regs[R_INIT_ADDR0] = 0x00
		regs[R_INIT_ADDR1] = 0x00
		-- blob 上传状态清空（测量码/身份/预武装/钩子不在此清）
		uploaded = {}
		upload_bytes = 0
		word_addr = 0
		load_phase, gate_left = "idle", 0
	end

	-- 软复位：重种芯片态；注入码/预武装/身份覆写/故障钩子保留
	local function soft_reset()
		seed_body()
		reset_count = reset_count + 1
	end

	-- ---------------- blob 加载状态机 ----------------

	local function start_load()
		if upload_bytes ~= BLOB_FIFO_LEN and upload_bytes ~= BLOB_FULL_LEN then
			load_phase, gate_left = "error", 0	-- 长度不符 → init_err
		elseif never_ready then
			load_phase, gate_left = "loading", math.huge
		elseif prearmed then
			load_phase, gate_left = "ok", 0		-- 守护零睡眠路径
		else
			load_phase, gate_left = "loading", LOAD_GATE_MS
		end
	end

	local function init_clear()
		uploaded = {}
		upload_bytes = 0
		word_addr = 0
		load_phase, gate_left = "idle", 0
	end

	-- 门限惰性到点（advance 已推时钟时首次读即完成）
	local function check_due()
		if load_phase == "loading" and not never_ready and gate_left <= 0 then
			load_phase, gate_left = "ok", 0
		end
	end

	local function status_code()
		if stuck_code ~= nil then return stuck_code end
		if load_phase == "ok" then return 0x01
		elseif load_phase == "error" then return 0x02 end
		return 0x00					-- idle / loading 均 0x00(not_init)
	end

	-- 单测虚拟时钟：驱动 milli_sleep 桩转调，推加载门
	function d:advance(ms)
		ms = math.max(0, math.floor(tonumber(ms) or 0))
		if load_phase == "loading" and not never_ready then
			gate_left = gate_left - ms
			if gate_left <= 0 then load_phase, gate_left = "ok", 0 end
		end
		return self
	end

	-- ---------------- 地址解码 ----------------

	local function meas_code(i)		-- i=0..11 对应 0x0C..0x17
		if i < 2 then return ax elseif i < 4 then return ay elseif i < 6 then return az
		elseif i < 8 then return gx elseif i < 10 then return gy else return gz end
	end

	local function byte_at(a)
		if a == R_CHIP_ID then return chip_id end
		if a >= R_ACC_X_LSB and a <= R_GYR_X_LSB + 5 then
			local i = a - R_ACC_X_LSB
			local v = meas_code(i)
			if i % 2 == 0 then return v % 256 end			-- LSB 在前
			return math.floor(v / 256) % 256				-- MSB
		end
		if a == R_INT_STATUS then return status_code() end
		if a == R_CMD then return 0x00 end				-- 只写读恒 0
		return regs[a] or 0							-- 稀疏影子，未定义读 0
	end

	-- ---------------- 单字节落盘（地址已折入 0x00..0xFF） ----------------

	local function write_byte(a, v)
		if a == R_CHIP_ID then return end				-- ROM 只读
		if a >= R_ACC_X_LSB and a <= R_GYR_X_LSB + 5 then
			return										-- 测量只读：写 ACK 丢弃
		end
		if a == R_INT_STATUS then return end
		if a == R_CMD then
			if v == CMD_SOFT_RESET then soft_reset() end
			return										-- 命令不落盘
		end
		if a == R_ACC_CONF or a == R_GYR_CONF then
			regs[a] = v								-- 全 8 位有效（驱动 RMW）
		elseif a == R_ACC_RANGE then
			regs[a] = v % 4
		elseif a == R_GYR_RANGE then
			regs[a] = v % 16							-- bit3 ois_range 合法
		elseif a == R_PWR_CONF then
			regs[a] = v % 8
		elseif a == R_PWR_CTRL then
			regs[a] = v % 16
		elseif a == R_INIT_CTRL then
			regs[a] = v % 2
			if (v % 2) == 0 then init_clear() else start_load() end
		elseif a == R_INIT_ADDR0 then
			regs[a] = v % 16							-- 仅低 4 位
		elseif a == R_INIT_ADDR1 then
			regs[a] = v
		elseif a == R_INIT_DATA then
			-- 自增落进窗口的单字节（帧陷阱的单字节退化形态）
			uploaded[word_addr * 2 + 1] = v
			upload_bytes = upload_bytes + 1
		else
			regs[a] = v								-- 未定义地址 ACK 落盘
		end
	end

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" or #bytes == 0 then return false end
		local nb = #bytes
		for i = 1, nb do
			if not is_byte(bytes[i]) then return false end
		end
		if d.nack or d.nack_write then return false end
		if write_pred and write_pred(bytes) then return false end

		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）：0x00..0xFF ACK 设 ptr
			read_ptr = bytes[1]
			return true
		end

		local base = bytes[1]
		if base == R_INIT_DATA then
			-- **地址陷阱**：帧内全部字节都落 0x5E 窗口（不普通自增、
			-- 不进寄存器影子），按当前字地址顺序进 blob 缓冲
			for k = 2, nb do
				uploaded[word_addr * 2 + (k - 1)] = bytes[k]
			end
			upload_bytes = upload_bytes + (nb - 1)
			word_addr = word_addr + math.floor((nb - 1) / 2)
		else
			for i = 2, nb do
				write_byte((base + i - 2) % 256, bytes[i])
			end
			-- 帧内触及 INIT_ADDR 0/1：按末值合成内部字地址
			local first, last = base, (base + nb - 2) % 256
			if first <= R_INIT_ADDR1 and last >= R_INIT_ADDR0 and first <= last then
				word_addr = (regs[R_INIT_ADDR0] or 0) + (regs[R_INIT_ADDR1] or 0) * 16
			end
		end

		write_count = write_count + 1
		local cp = {}
		for i = 1, nb do cp[i] = bytes[i] end
		frames[#frames + 1] = cp
		return true
	end

	function d.read(n)
		if d.nack or d.nack_read then return nil end
		if read_ptr == nil then return nil end			-- 无指针纯读：NACK
		n = math.floor(tonumber(n) or 1)
		if n < 1 then n = 1 elseif n > 16 then n = 16 end
		if read_pred and read_pred(read_ptr, n) then return nil end
		check_due()
		local t = {}
		for _ = 1, n do
			t[#t + 1] = byte_at(read_ptr)
			read_ptr = (read_ptr + 1) % 256			-- burst 自增、算术回绕
		end
		read_count = read_count + 1
		return t
	end

	-- ---------------- 测试 / 守护注入 API（冒号定义） ----------------

	-- 六轴原始码直接装（s16，-32768..32767；小端打包在读取时合成）
	function d:set_accel_raw(x, y, z)
		ax = clampi(x, -32768, 32767)
		ay = clampi(y, -32768, 32767)
		az = clampi(z, -32768, 32767)
		return self
	end

	function d:set_gyro_raw(x, y, z)
		gx = clampi(x, -32768, 32767)
		gy = clampi(y, -32768, 32767)
		gz = clampi(z, -32768, 32767)
		return self
	end

	-- 物理量逆注入：按当前 ACC_RANGE 档 LSB/g 反算原始码
	function d:set_accel_g(g_x, g_y, g_z)
		local lsb = ACC_LSB_PER_G[(regs[R_ACC_RANGE] or 2) % 4 + 1]
		ax = clampi(round_away((tonumber(g_x) or 0) * lsb), -32768, 32767)
		ay = clampi(round_away((tonumber(g_y) or 0) * lsb), -32768, 32767)
		az = clampi(round_away((tonumber(g_z) or 0) * lsb), -32768, 32767)
		return self
	end

	-- 物理量逆注入：按当前 GYR_RANGE 档 LSB/dps 反算（保留码 5..7 按 ±2000）
	function d:set_gyro_dps(w_x, w_y, w_z)
		local code = (regs[R_GYR_RANGE] or 0) % 8
		local lsb = GYR_LSB_PER_DPS[code + 1] or 16.384
		gx = clampi(round_away((tonumber(w_x) or 0) * lsb), -32768, 32767)
		gy = clampi(round_away((tonumber(w_y) or 0) * lsb), -32768, 32767)
		gz = clampi(round_away((tonumber(w_z) or 0) * lsb), -32768, 32767)
		return self
	end

	-- 覆写 ROM 身份喂 build 甄别负路径（0x26=BMI260 变体）；reset 回出厂
	function d:who(id)
		if id ~= nil then chip_id = clampi(id, 0, 255) end
		return self
	end

	-- 强制 INTERNAL_STATUS 返回某状态码（nil 解除）：喂 50×10ms 轮询超时
	function d:set_stuck_status(code)
		if code ~= nil then stuck_code = clampi(code, 0, 255) else stuck_code = nil end
		return self
	end

	function d:set_never_ready(on)
		never_ready = on ~= false
		return self
	end

	-- 守护逐拍造数：32 拍确定性正弦小码（默认 ±8g 档 Z≈1g≈4096），
	-- 连续测量直接装码；同时预武装——下次 INIT_CTRL=1 立即 init_ok。
	-- acc X 300±200 / Y -200∓150 / Z 4096±100；gyr X ±500 / Y ∓400 / Z ±300
	function d:virt_tick(n)
		n = math.floor(tonumber(n) or 0) % 32
		local s = math.sin(2 * math.pi * n / 32)
		ax = round_away(300 + 200 * s)
		ay = round_away(-200 - 150 * s)
		az = round_away(4096 + 100 * s)
		gx = round_away(500 * s)
		gy = round_away(-400 * s)
		gz = round_away(300 * s)
		prearmed = true
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_ready = false
		stuck_code = nil
		return self
	end

	function d:reset_logs()
		frames = {}
		write_count, read_count = 0, 0
		return self
	end

	-- 上电复位：全状态回 POR（身份/注入码/预武装/卡死态归位）；钩子保留
	function d:reset()
		chip_id = CHIP_ID
		ax, ay, az, gx, gy, gz = 0, 0, 0, 0, 0, 0
		prearmed = false
		never_ready = false
		stuck_code = nil
		read_ptr = nil
		frames = {}
		write_count, read_count, reset_count = 0, 0, 0
		seed_body()
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:reg(a) return regs[math.floor(tonumber(a) or 0) % 256] end
	function d:regs() return regs end
	function d:pointer() return read_ptr end
	function d:write_count() return write_count end
	function d:read_count() return read_count end
	function d:reset_count() return reset_count end
	function d:frames() return frames end
	function d:chip_id() return chip_id end
	function d:word_addr() return word_addr end
	function d:blob_len() return upload_bytes end
	function d:phase() return load_phase end
	function d:gate_left_ms() return gate_left end
	function d:init_status() return status_code() end
	function d:is_prearmed() return prearmed == true end

	-- blob 缓冲前 n 字节副本（缺省全部已收字节；空位补 0）
	function d:uploaded(n)
		n = n or upload_bytes
		local t = {}
		for i = 1, n do t[i] = uploaded[i] or 0 end
		return t
	end

	function d:accel_raw() return ax, ay, az end
	function d:gyro_raw() return gx, gy, gz end

	-- 当前配置解码（量程/ODR 码 + 电源位）
	function d:config()
		local ac, gc = regs[R_ACC_CONF] or 0, regs[R_GYR_CONF] or 0
		return {
			acc_conf = ac,
			gyr_conf = gc,
			acc_range = (regs[R_ACC_RANGE] or 0) % 4,
			gyr_range = (regs[R_GYR_RANGE] or 0) % 8,
			acc_odr = ac % 16,
			gyr_odr = gc % 16,
			pwr_conf = regs[R_PWR_CONF] or 0,
			pwr_ctrl = regs[R_PWR_CTRL] or 0,
		}
	end

	seed_body()
	return d
end

-- MAX30102.lua - 心率/血氧（PPG）光学传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
-- 虚拟器件模型：内嵌本文件尾部 MAX30102_VIRT（2026-09-15 自 modules/lib/virtbus/max30102.lua
-- 迁入，单文件驱动+模型实验第三十三个，环形 FIFO 族；无硬件单测与守护 E2E 共用；同协议独立实现，改协议两处同步）
-- 双 LED（红光 660nm + 红外 880nm）光电容积描记前端，I2C 地址固定 0x57，
-- 每样本 18 位 x 2 通道（SpO2 模式 6 字节）或 18 位 x 1 通道（HR 模式 3 字节），32 深 FIFO。
-- 芯片只输出原始 PPG 波形；心率/SpO2 数值是宿主端算法（峰值间隔检测 / 红光红外
-- AC/DC 分量 R 值公式），波形平滑可直接复用 Ema/Kalman 滤波变量（守护 -> 滤波 -> 消费）。
--
-- 用法（结构脚本 .sql，直连路径，@Action 单次读）：
--   CREATE TABLE MAX30102 (
--       name    String,
--       I2C     String,
--       address String,
--       opmode  String,   -- 'spo2'(默认) | 'hr'
--       rate    String,   -- ADC 采样率 sps：50/100/200/400/800/1000/1600/3200（默认 100）
--       pw      String,   -- LED 脉宽 us：69/118/215/411（默认 69，对应 18/17/16/15 位分辨率）
--       adc     String,   -- ADC 满量程 nA：2048/4096/8192/16384（默认 4096）
--       avg     String,   -- 样本平均 1/2/4/8/16/32/64/128（默认 1；平均降低 FIFO 输出率）
--       led1    String,   -- 红光电流 mA 0~51（默认 6.4，0.2mA 步进四舍五入）
--       led2    String,   -- 红外电流 mA（默认同 led1）
--       n       String,   -- 每次 call 读取样本数 1~8（默认 1；SpO2 双通道 8 样本恰占满守护槽 16 值）
--       wait    String    -- FIFO 空时等待 ms（默认 0；守护路径保持 0，tick 内 usleep 会阻塞 worker）
--       （n/wait 在 build 配置后，每次 call 仍可传同名参覆盖——直连路径按行动态批量读）
--   );
--   INSERT INTO MAX30102 (name, I2C, address, opmode, rate, pw, adc, avg, led1, led2, n, wait)
--     VALUES ('hr0', 'i2c-1', '0x57', 'spo2', '100', '69', '4096', '1', '6.4', '-', '1', '0');
--
-- 守护路径（连续采样，推荐）：sensor_daemon 保留 mode 键给 SPI，故本驱动模式列名
--   用 opmode。interval 建议略大于平均后的样本周期（约 1000*avg/rate ms），或配 n>=2
--   兜住节拍抖动：
--   CREATE TABLE Daemon (name String, chunk String, driver String, proto String,
--       path String, addr String, interval String, fields String, sign String,
--       opmode String, rate String, n String);
--   INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields, sign, opmode, rate, n)
--     VALUES ('hr0', 'lib/sensor_daemon.lua', 'MAX30102', 'i2c', '/dev/i2c-1', '0x57',
--             '12', 'IR|RED', '-', 'spo2', '100', '2');
--
-- call 返回契约：
--   result/count/avail/SAT + RED0..RED{k-1}（k=count），SpO2 模式另加 IR0..IR{k-1}；
--   k>=1 时再以 RED/IR 别名暴露最新样本，供 fields="IR|RED" 单样本直取。
--   FIFO 空（无可读样本）返回 ERR：守护 daemon_tick 跳过该拍不发布；直连路径走
--   halt-on-error 中断——轮询快于样本率时请用 wait 列或调低轮询率。
--   SAT=1 表示读到 0x3FFFF 满码（LED 电流过大或环境光饱和：调低 led 或加大 adc 量程），
--   属数据质量问题只置标志，不报 ERR（同 SGP30 的 CRC_OK 契约，交消费者决策）。
--   FIFO 开 rollover：满后覆盖最旧样本，保证读到较新数据；轮询周期远大于样本周期时
--   指针差回绕、可用数被低估（avail 只反映未回绕部分），保持 interval ≈ 样本周期即可。
--
-- build 流程：读 Part ID(0xFF) 自检（期望 0x15）-> RESET -> FIFO/SpO2/LED 配置 ->
--   清 FIFO 指针 -> 写模式启动采样。destroy 置 SHDN 关 LED 停采样（配置保留，
--   总线 fd 归 I2C 硬件变量所有）。
-- 硬件注意：GY 兼容板 VIN 喂 5V（板载 LDO 有压差，喂 3.3V 会欠压）；INT 引脚本驱动未用，
--   全靠轮询 FIFO 指针。

-- 声明式驱动框架（P2 方案 A，2026-09-30）：arg_table + i2c_pair 校验 + 空
-- destroy 样板统一由 require_driver 承担，驱动只写业务 delta。VIRT 模型仍
-- 在文件尾部。1 行 prelude 加载 drv_common；HAL/print_table 由框架代劳。
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 调试开关：传感器周期读取，默认关闭逐次打印
local DEBUG = false
local function dbg(msg)
	if DEBUG then print(msg) end
end

-- ==================== 寄存器 ====================
local REG_FIFO_WR   = 0x04		-- FIFO 写指针（芯片自增）
local REG_FIFO_OVF  = 0x05		-- 溢出计数（rollover 开启时不增）
local REG_FIFO_RD   = 0x06		-- FIFO 读指针
local REG_FIFO_DATA = 0x07		-- FIFO 数据口：读自动步进，HR 每样本 3 字节 / SpO2 6 字节
local REG_FIFO_CFG  = 0x08		-- SMP_AVE[7:5] | ROLLOVER_EN[4] | A_FULL[3:0]
local REG_MODE      = 0x09		-- SHDN[7] RESET[6] | MODE[2:0]：2=HR 3=SpO2 7=多LED
local REG_SPO2      = 0x0A		-- ADC_RGE[6:5] | SR[4:2] | PW[1:0]
local REG_LED1      = 0x0C		-- 红光电流，0.2mA/LSB，最大 51mA
local REG_LED2      = 0x0D		-- 红外电流
local REG_PART_ID   = 0xFF

local PART_ID    = 0x15
local MODE_HR    = 0x02
local MODE_SPO2  = 0x03
local BIT_SHDN   = 0x80
local BIT_RESET  = 0x40
local FULL_SCALE = 0x3FFFF		-- 18 位满码（LED/环境光饱和特征值）
local FIFO_DEPTH = 32

-- 离散配置取值 -> 寄存器编码
local RATE_CODE = { [50]=0,[100]=1,[200]=2,[400]=3,[800]=4,[1000]=5,[1600]=6,[3200]=7 }
local PW_CODE   = { [69]=0,[118]=1,[215]=2,[411]=3 }
local ADC_CODE  = { [2048]=0,[4096]=1,[8192]=2,[16384]=3 }
local AVG_CODE  = { [1]=0,[2]=1,[4]=2,[8]=3,[16]=4,[32]=5,[64]=6,[128]=7 }
-- 采样平均位域（2026-09-20 审计 C5）：数据手册 FIFO_CFG(0x08) 的字段是
--   B7..B5 = SMP_AVE[2:0]、B4 = FIFO_ROLLOVER_EN、B3..B0 = FIFO_A_FULL。
-- 旧实现按 SMP_AVE[6:4]|ROLLOVER[3] 写 `code*16 + 0x08`：芯片实际看到的是
-- SMP_AVE = code>>1、ROLLOVER = 0、A_FULL = 8 —— 即平均档位取半、rollover
-- **关着**（与头注/build 注释声称的"rollover 开"相反），而内嵌模型复刻了同一
-- 处错位，单测因此全绿。这三个常量是位域的唯一事实源，驱动与模型共用。
local SMP_AVE_MUL       = 32		-- SMP_AVE 在 B7..B5（= 2^5；LuaJIT 无内置 <<）
local BIT_ROLLOVER_EN   = 0x10		-- B4：满 32 后覆盖最旧样本
local FIFO_A_FULL_LEVEL = 0x08		-- B3..B0：近满阈值（驱动纯轮询不使能中断，
					-- 该值只影响中断时序，保留既有取值不改）
-- 采样周期须容纳两路 LED 脉冲 + 转换：脉宽越大允许的最高采样率越低（数据手册组合表）
local PW_MAX_RATE = { [69]=3200,[118]=1600,[215]=800,[411]=400 }

-- 模块级配置（build 写入，跨 call 保持于本变量独立状态机，destroy 后废弃）
local cfg_is_spo2		-- true=SpO2（样本 6 字节）/ false=HR（3 字节）
local cfg_n				-- 每次 call 读取的样本数
local cfg_wait			-- FIFO 空等待 ms（0=不等待）

-- ==================== 配置解析 ====================
-- 离散取值：nil/"-"/"" 用默认（M3：整列缺省表达"用默认值"）；非法立即报错
local function cfg_choice(v, default, codes, label)
	if v == nil or v == "-" or v == "" then return default end
	local n = math.floor(tonumber(v) or -1)
	if codes[n] == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "'"
	end
	return n
end

-- 连续区间取值：闭区间 [lo, hi]
-- 审计 2026-09-20（中）：入参必须**有限**。`math.floor(tonumber(v) or (lo-1))` 挡不住
-- NaN（NaN 是 truthy）也不挡 inf——NaN 与任何数比较为假，于是区间校验形同不存在，
-- 非有限值会一路流进 FIFO 批量/等待参数并造成无界轮询（见 call 的 wait 段）。
local function cfg_range(v, default, lo, hi, label)
	if v == nil or v == "-" or v == "" then return default end
	local raw = finite_of(v)
	if raw == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "' (not a finite number)"
	end
	local n = math.floor(raw)
	if n < lo or n > hi then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "' (range " .. lo .. "~" .. hi .. ")"
	end
	return n
end

-- LED 电流 mA -> 寄存器码（0.2mA/LSB，四舍五入，钳制 0~255）。
-- 用 n*5 而非 n/0.2：后者浮点除法会产生 31.4999... 之类偏差（6.3mA -> 0x1F）
local function cfg_led_code(v, label)
	if v == nil or v == "-" or v == "" then v = 6.4 end
	local n = tonumber(v)
	if n == nil then
		return nil, "Invalid Argument: " .. label .. " '" .. tostring(v) .. "'"
	end
	local code = math.floor(n * 5 + 0.5)
	if code < 0 then code = 0 elseif code > 255 then code = 255 end
	return code
end

-- ==================== FIFO ====================
-- 可读样本数（指针差模 32）；传输失败返回 -1
local function fifo_avail(fd)
	local wr = i2c_read_reg(fd, REG_FIFO_WR)
	local rd = i2c_read_reg(fd, REG_FIFO_RD)
	if wr < 0 or rd < 0 then return -1 end
	return (wr - rd) % FIFO_DEPTH
end

-- 弹出一个样本：写 FIFO 数据寄存器指针 + 连续读合并为单次 I2C_RDWR 原子事务
-- （样本字节必须一次事务读完，跨事务会与 FIFO 读指针步进错位）。
-- 每通道 18 位 MSB 对齐：b0=[17:10] b1=[9:2] b2/b5 高 2 位=[1:0]（低 6 位恒 0）。
local function fifo_read_sample(fd)
	local nbytes = (cfg_is_spo2 ~= false) and 6 or 3	-- 未 build 兜底按 SpO2
	local v = i2c_read_multi(fd, REG_FIFO_DATA, nbytes)
	if v < 0 then return nil, nil end
	local b = {}
	for i = 0, nbytes - 1 do
		b[i + 1] = math.floor(v / 256 ^ (nbytes - 1 - i)) % 256
	end
	local red = b[1] * 1024 + b[2] * 4 + math.floor(b[3] / 64)
	if nbytes == 3 then return red, nil end
	local ir = b[4] * 1024 + b[5] * 4 + math.floor(b[6] / 64)
	return red, ir
end

-- ==================== 配置脚本 ====================
-- 读 Part ID 自检 -> RESET -> 配置 -> 清 FIFO 指针 -> 写模式启动采样
require_driver("i2c", {
name = "MAX30102",
build = function(ctx, data)
	local fd = ctx.fd
	local addr = ctx.addr

	if DEBUG then
		dbg_table("-------- MAX30102 builder func get a table --------", data)
	end

	-----------------------------------------------------

	-- 在位探测 + 型号自检（Part ID 固定 0x15）
	local pid = i2c_read_reg(fd, REG_PART_ID)
	if pid < 0 then
		return err("MAX30102 not responding (read Part ID failed, check address 0x57 and wiring)")
	end
	if pid ~= PART_ID then
		return err(string.format("MAX30102 unexpected Part ID 0x%02X (expect 0x%02X)", pid, PART_ID))
	end

	-----------------------------------------------------
	-- 解析配置
	local opmode_s = data.opmode
	if opmode_s == nil or opmode_s == "-" or opmode_s == "" then opmode_s = "spo2" end
	opmode_s = tostring(opmode_s)
	local is_spo2
	if opmode_s == "spo2" then is_spo2 = true
	elseif opmode_s == "hr" then is_spo2 = false
	else
		return err("Invalid Argument: opmode '" .. opmode_s .. "' (hr|spo2)")
	end

	local rate, e1 = cfg_choice(data.rate, 100, RATE_CODE, "rate(sps)")
	local pw,   e2 = cfg_choice(data.pw, 69, PW_CODE, "pw(us)")
	local adc,  e3 = cfg_choice(data.adc, 4096, ADC_CODE, "adc(nA)")
	local avg,  e4 = cfg_choice(data.avg, 1, AVG_CODE, "avg")
	if e1 or e2 or e3 or e4 then
		return err(e1 or e2 or e3 or e4)
	end
	if rate > PW_MAX_RATE[pw] then
		return err(string.format("Invalid Argument: rate %d sps exceeds limit %d sps for pw %dus", rate, PW_MAX_RATE[pw], pw))
	end

	local led1, e5 = cfg_led_code(data.led1, "led1(mA)")
	local led2_ma = data.led2
	if led2_ma == nil or led2_ma == "-" or led2_ma == "" then led2_ma = data.led1 end
	local led2, e6 = cfg_led_code(led2_ma, "led2(mA)")
	local n,     e7 = cfg_range(data.n, 1, 1, 8, "n(samples)")
	local wait,  e8 = cfg_range(data.wait, 0, 0, 60000, "wait(ms)")
	if e5 or e6 or e7 or e8 then
		return err(e5 or e6 or e7 or e8)
	end

	-----------------------------------------------------
	-- 复位（RESET 位自清零，全部寄存器回上电默认，约 1ms）
	if not i2c_write_reg(fd, REG_MODE, BIT_RESET) then
		return err("MAX30102 not responding (reset write failed)")
	end
	milli_sleep(5)

	-- 逐项写配置；任一写失败记录后仍走完（器件可能已复位），统一在末尾报错
	local wfail = nil
	local function wr(reg, val, what)
		if wfail == nil and not i2c_write_reg(fd, reg, val) then
			wfail = "MAX30102 not responding (" .. what .. " write failed)"
		end
	end

	-- C5：位域按数据手册 SMP_AVE[7:5] | ROLLOVER_EN[4] | A_FULL[3:0]
	wr(REG_FIFO_CFG, AVG_CODE[avg] * SMP_AVE_MUL + BIT_ROLLOVER_EN
		+ FIFO_A_FULL_LEVEL, "FIFO config")	-- 平均 + rollover（满后覆盖最旧）
	wr(REG_SPO2, ADC_CODE[adc] * 32 + RATE_CODE[rate] * 4 + PW_CODE[pw], "SpO2 config")
	wr(REG_LED1, led1, "LED1 amplitude")
	wr(REG_LED2, led2, "LED2 amplitude")
	wr(REG_FIFO_WR, 0, "FIFO write pointer clear")
	wr(REG_FIFO_OVF, 0, "FIFO overflow clear")
	wr(REG_FIFO_RD, 0, "FIFO read pointer clear")
	wr(REG_MODE, is_spo2 and MODE_SPO2 or MODE_HR, "mode")		-- 写模式即启动采样
	if wfail ~= nil then
		return err(wfail)
	end

	cfg_is_spo2 = is_spo2
	cfg_n = n
	cfg_wait = wait

	print(string.format(
		"MAX30102 init OK: addr=0x%02X mode=%s rate=%dsps pw=%dus adc=%dnA avg=%dx led1=%.1fmA led2=%.1fmA n=%d",
		addr, opmode_s, rate, pw, adc, avg, led1 * 0.2, led2 * 0.2, n))
	return {  result = "OK"  }

	end,

-- ==================== 调用 ====================
-- 排空 FIFO（至多 n 个样本）。FIFO 空返回 ERR（守护跳拍不发布）；数据质量
-- 问题（饱和）只置 SAT 标志。返回样本键 RED0..RED{k-1}（+IR0..）与最新样本别名 RED/IR。
call = function(ctx, data)
	local fd = ctx.fd

	if DEBUG then
		dbg_table("-------- MAX30102 caller func get a table --------", data)
	end

	-----------------------------------------------------
	-- n/wait 取本次调用参数（缺省用 build 配置）——直连路径可按行动态批量读/等待。
	-- 审计 2026-09-20（中）：两处都必须过 finite_of。此前 wait 只有下界钳制
	-- （`if wait_req < 0`），"1e400"→inf 会让下方 `waited < wait_req` 的轮询
	-- **永不终止**（实测 timeout 10s → exit 124），动作/守护线程直接挂死且
	-- 无 ERR、pcall 也救不回；n 为 NaN 时 math.min(NaN, avail) 在 LuaJIT 下
	-- 返回 avail，于是「按 n 个采样」退化成「把整个 FIFO 排空」。构建期
	-- cfg_range 已钳 0~60000，故这里与之一致地钳到同一上界。
	local n_raw = finite_of(data.n)
	if n_raw == nil then n_raw = cfg_n or 1 end
	local n_req = math.floor(n_raw)
	if n_req < 1 then n_req = 1 elseif n_req > 8 then n_req = 8 end
	local wait_raw = finite_of(data.wait)
	if wait_raw == nil then wait_raw = cfg_wait or 0 end
	local wait_req = math.floor(wait_raw)
	if wait_req < 0 then wait_req = 0 elseif wait_req > 60000 then wait_req = 60000 end

	-- 可读样本数；FIFO 空时可等（直连路径用；守护路径 wait 保持 0）
	local avail = fifo_avail(fd)
	if avail == -1 then
		return err("MAX30102 not responding (read FIFO pointers failed)")
	end
	if avail == 0 and wait_req > 0 then
		local waited = 0
		while avail == 0 and waited < wait_req do
			milli_sleep(10)
			waited = waited + 10
			avail = fifo_avail(fd)
			if avail == -1 then
				return err("MAX30102 not responding (read FIFO pointers failed)")
			end
		end
	end
	if avail == 0 then
		return err("MAX30102 FIFO empty (no new sample yet)")
	end

	-- 逐样本弹出（FIFO 序：旧 -> 新），至多 n 个
	local want = math.min(n_req, avail)
	local sat = false
	local reds, irs = {}, {}
	for k = 1, want do
		local red, ir = fifo_read_sample(fd)
		if red == nil then
			if k == 1 then
				return err("MAX30102 not responding (FIFO data read failed)")
			end
			break	-- 首样本之后传输失败：返回已得部分，不空手而归
		end
		if red >= FULL_SCALE or (ir ~= nil and ir >= FULL_SCALE) then sat = true end
		reds[k], irs[k] = red, ir
	end

	local got = #reds
	local out = {
		result = "OK",
		count = got,
		avail = avail,
		SAT = sat and 1 or 0
	}
	for k = 1, got do
		out["RED" .. (k - 1)] = reds[k]
		if cfg_is_spo2 ~= false then out["IR" .. (k - 1)] = irs[k] end
	end
	if got >= 1 then
		out.RED = reds[got]			-- 最新样本别名（fields="IR|RED" 单样本直取）
		if cfg_is_spo2 ~= false then out.IR = irs[got] end
	end
	return out

end,
destroy = function(ctx, data)
	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		i2c_write_reg(fd, REG_MODE, BIT_SHDN)
	end
	return {  result = "OK"  }
end,
})



-- =====================================================================
-- 【内嵌虚拟器件模型】MAX30102_VIRT —— 2026-09-15 自 modules/lib/virtbus/max30102.lua
-- 整体迁入（单文件驱动+模型第三十三个，环形 FIFO 族，守护 E2E 走
-- sensor_daemon 回退路径）。约定同前三十二者：① 生产路径零执行（new() 仅
-- 虚拟总线测试调用，纯闭包零外部依赖；寄存器地址/FIFO 常数/PPG 波形/
-- clamp18/wave helper 全部移入 new() 内避让）；② 工厂经全局表而非文件
-- return（生产侧 Lua.cj build_lua 以 LUA_MULTRET pcall 加载驱动且成功路径
-- 无 settop，文件返回值会滞留 Lua 栈）；③ 模型与驱动保持独立实现，互证防
-- 假绿性质不变。无 BUS 字段 = I2C。
--
-- 定位：【首个「环形 FIFO + 读写指针/溢出计数 + rollover + 18 位样本块读」
-- I2C 器件】（Maxim MAX30102，地址固定 0x57；纯闭包、纯算术无 bitcompat）。
-- 寄存器是普通 8 位指针，核心协议事实全在 FIFO 状态机：
--   1) 三个 5 位 FIFO 指针（0x04 WR / 0x05 OVF / 0x06 RD，均可写），32 深
--      环形缓冲，可用样本数 = (WR-RD) mod 32（0 既可能是空也可能是满，
--      满状态靠 OVF/物理槽位区分；驱动纯轮询不使能中断，积压整圈后指针差
--      回绕、avail 被低估为 0 是真实硬件行为）。
--   2) FIFO_DATA 0x07 流式数据口：读自动步进内部字节位置；HR 模式每样本
--      3 字节（仅 RED），SpO2 模式 6 字节（RED+IR）；读满一个样本的全部
--      字节 FIFO_RD_PTR 才硬件自增，半样本事务后重新寻址 0x07 仍从同一
--      槽位读起。空 FIFO 读返回 0x00 且 RD 不动。
--   3) 每通道 18 位样本 MSB 对齐在 3 字节帧里（低 6 位恒 0）：
--      b0=[17:10] b1=[9:2] b2[7:6]=[1:0]，满码 0x3FFFF=262143 即 SAT。
--   4) FIFO_CFG 0x08 = SMP_AVE[7:5] | ROLLOVER_EN[4] | A_FULL[3:0]：rollover
--      关（POR）时满 32 后新样本丢弃、OVF_COUNTER++（饱和 31）、WR 停住；
--      rollover 开（驱动 build 固定置 B4）时新样本覆盖最旧槽并把 RD 自动
--      推进、OVF 不增。SPO2_CFG 0x0A：有效输出样本周期 = 1000×2^SMP_AVE/SR。
--      位域位置与驱动共用常量（SMP_AVE_MUL/BIT_ROLLOVER_EN）——2026-09-20
--      审计 C5 前此处与驱动同错（SMP_AVE 记成 [6:4]），模型与驱动同源共错
--      使单测失去判别力。
--   5) MODE 0x09 = SHDN[7] | RESET[6] | MODE[2:0]：RESET 位自清除不落盘，
--      写后全部寄存器回 POR、FIFO/指针清空；SHDN=1 停采样；写有效模式即
--      启动，advance(ms) 按周期向 FIFO 产样（测试 wait 轮询的 milli_sleep
--      桩转调它），virt_tick 直接推入一拍合成样本（守护每拍先 tick 后
--      call，FIFO 恒有新鲜样本、零真实睡眠）。
--   6) PART_ID 0xFF 固定 0x15（build 先读它在位甄别，再 RESET）；温度
--      0x1F/0x20 与中断寄存器真实驱动不访问，照存照读 0，不实现。
--
-- 公开 API 一律冒号定义；write/read 总线回调用点定义（无 self 参数，
-- attach 动态委托 dev.write(bytes) 契约）。
-- =====================================================================

MAX30102_VIRT = { _VERSION = "0.1.0" }

function MAX30102_VIRT.new()
-- ==================== 寄存器地址 ====================
local REG_WR, REG_OVF, REG_RD, REG_DATA = 0x04, 0x05, 0x06, 0x07
local REG_FCFG, REG_MODE, REG_SPO2 = 0x08, 0x09, 0x0A
local REG_LED1, REG_LED2, REG_PART = 0x0C, 0x0D, 0xFF

local PART_ID = 0x15
local BIT_SHDN, BIT_RESET = 0x80, 0x40
local DEPTH = 32				-- FIFO 样本深度
local FULL = 0x3FFFF			-- 18 位满码（SAT 特征）
local MODE_HR, MODE_SPO2 = 0x02, 0x03

-- SR[4:2] 编码 -> 采样率 sps
local SPS = { 50, 100, 200, 400, 800, 1000, 1600, 3200 }

-- virt_tick 确定性 PPG 正弦（计数，远低于 0x3FFFF 满码，SAT 恒 0）
local TICK_RED_BASE, TICK_RED_AMP = 50000, 18000	-- n0=50000 n8=68000 n24=32000
local TICK_IR_BASE,  TICK_IR_AMP  = 60000, 22000	-- n0=60000 n8=82000 n24=38000

local function clamp18(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then return 0 elseif v > FULL then return FULL else return v end
end

-- 确定性 PPG 波形（32 拍周期）：RED/IR 原始计数
local function wave(n)
	n = (math.floor(tonumber(n) or 0)) % 32
	local ph = 2 * math.pi * n / 32
	return clamp18(TICK_RED_BASE + TICK_RED_AMP * math.sin(ph)),
	       clamp18(TICK_IR_BASE  + TICK_IR_AMP  * math.sin(ph))
end

	local d = {}

	-- 芯片侧状态
	local regs = {}				-- 普通寄存器影子（稀疏，缺省读 0）
	local slots = {}			-- FIFO 环形槽 [0..31] = {r=red, i=ir}（HR 无 i）
	local wr, rd, ovf = 0, 0, 0	-- 三个 5 位指针
	local count = 0				-- 物理占用槽数（区分空/满，avail 给驱动公式值）
	local byte_idx = 0			-- 当前样本内已读字节位置（0..size-1）
	local read_ptr = nil		-- 最近一笔指针写（read 回调据此分派）
	local remaining = nil		-- 自动采样：距下一个产出的 ms（nil=未启动/停采）
	local produced = 0			-- 启动后自动产出的样本总数（波形相位）
	local reset_count = 0		-- RESET 位次数
	local part_id = PART_ID
	local prod_queue = {}		-- advance 自动产出时优先注入的样本队列

	-- 故障钩子（硬件 RESET 保留，clear_faults/d:reset 解除）
	d.nack, d.nack_read, d.nack_write = false, false, false
	local write_pred, read_pred
	local never_sample = false	-- advance 不自动产出（喂驱动 wait 耗尽路径）

	-- ---------------- 派生 ----------------

	local function sample_size()
		return (regs[REG_MODE] % 8) == MODE_HR and 3 or 6
	end
	local function is_spo2() return sample_size() == 6 end
	local function mode_bits() return regs[REG_MODE] % 8 end
	local function shdn_on() return math.floor(regs[REG_MODE] / 128) % 2 == 1 end
	local function active()
		local m = mode_bits()
		return (m == MODE_HR or m == MODE_SPO2) and not shdn_on()
	end
	-- C5：位域与驱动共用常量（SMP_AVE 在 B7..B5 → 乘 32、ROLLOVER_EN 在 B4）
	local function rollover_on() return math.floor(regs[REG_FCFG] / BIT_ROLLOVER_EN) % 2 == 1 end
	local function avg_code() return math.floor(regs[REG_FCFG] / SMP_AVE_MUL) % 8 end
	local function rate_code() return math.floor(regs[REG_SPO2] / 4) % 8 end
	-- 有效输出周期：SMP_AVE 个 SR 样本平均成 1 个 FIFO 输出
	local function period_ms()
		return 1000 * 2 ^ avg_code() / SPS[rate_code() + 1]
	end

	-- ---------------- FIFO 入队/出字节 ----------------

	-- 样本入队（按当前模式：HR 3B 仅 RED，SpO2 6B RED+IR）。
	-- rollover 关且满：新样本丢弃、OVF++（饱和 31）、WR 停住；
	-- rollover 开且满：覆盖最旧槽（=WR 位置），WR/RD 同进、OVF 不增。
	local function push_raw(red, ir)
		red = clamp18(red)
		local s = { r = red }
		if is_spo2() then s.i = clamp18(ir or 0) end
		if count >= DEPTH then
			if rollover_on() then
				slots[rd] = nil
				rd = (rd + 1) % DEPTH
				count = count - 1	-- 覆盖最旧：逻辑占用减一，下面再计入新样本
			else
				ovf = math.min(ovf + 1, 31)
				return false
			end
		end
		slots[wr] = s
		wr = (wr + 1) % DEPTH
		count = count + 1
		return true
	end

	-- FIFO_DATA 流式取下一字节；样本字节读满后 RD 硬件自增、槽位释放。
	-- 空槽读返回 0 且 RD/字节位置不动（datasheet 空读 FIFO_DATA = 0x00）。
	local function next_byte()
		local s = slots[rd]
		if s == nil then return 0 end
		local size, b
		if byte_idx < 3 then
			local v = s.r
			if byte_idx == 0 then b = math.floor(v / 1024) % 256
			elseif byte_idx == 1 then b = math.floor(v / 4) % 256
			else b = (v % 4) * 64 end
		else
			size = 6
			local v = s.i or 0
			local j = byte_idx - 3
			if j == 0 then b = math.floor(v / 1024) % 256
			elseif j == 1 then b = math.floor(v / 4) % 256
			else b = (v % 4) * 64 end
		end
		size = size or sample_size()
		byte_idx = byte_idx + 1
		if byte_idx >= size then
			slots[rd] = nil
			rd = (rd + 1) % DEPTH
			count = count - 1
			byte_idx = 0
		end
		return b
	end

	-- 自动采样产出一拍：注入队列优先，否则确定性 PPG 正弦
	local function produce_one()
		local red, ir
		local q = table.remove(prod_queue, 1)
		if type(q) == "table" then
			red, ir = q.red or q.r, q.ir or q.i
		else
			red, ir = wave(produced)
		end
		produced = produced + 1
		push_raw(red, ir)			-- 满丢弃也占一个产出周期
	end

	-- ---------------- POR / RESET ----------------

	local function seed_regs()
		regs = {}
		regs[REG_FCFG] = 0x00		-- POR：rollover 关、SMP_AVE=0、A_FULL=0
		regs[REG_MODE] = 0x00
		regs[REG_SPO2] = 0x00
		regs[REG_LED1] = 0x00
		regs[REG_LED2] = 0x00
	end

	local function fifo_clear()
		for k in pairs(slots) do slots[k] = nil end
		wr, rd, ovf, count, byte_idx = 0, 0, 0, 0, 0
	end

	-- RESET 位：寄存器回 POR、FIFO/指针/采样态全清；
	-- part_id/注入队列/故障钩子保留（硬件复位不清激励、防负路径假解除）
	local function reseed()
		seed_regs()
		fifo_clear()
		read_ptr = nil
		remaining, produced = nil, 0
	end

	seed_regs()

	-- ---------------- 总线回调（点定义，无 self） ----------------

	function d.write(bytes)
		if type(bytes) ~= "table" then return false end
		if d.nack or d.nack_write then return false end
		local nb = #bytes
		if nb == 0 or nb > 2 then return false end
		if write_pred and write_pred(bytes) then return false end
		if nb == 1 then
			-- 纯指针写（读族事务的指针相位）
			if bytes[1] > 0xFF then return false end
			read_ptr = bytes[1]
			if read_ptr == REG_DATA then byte_idx = 0 end
			return true
		end
		local reg, val = bytes[1], bytes[2] % 256
		-- RESET 位自清除：回 POR 且该位不落盘（同写其他位忽略）
		if reg == REG_MODE and math.floor(val / 64) % 2 == 1 then
			reseed()
			reset_count = reset_count + 1
			return true
		end
		if reg == REG_WR then
			wr = val % DEPTH			-- 5 位指针（DEPTH=32=2^5，取模即掩低 5 位）
		elseif reg == REG_OVF then
			ovf = val % DEPTH
		elseif reg == REG_RD then
			rd = val % DEPTH
			byte_idx = 0
		elseif reg == REG_DATA then
			-- FIFO_DATA 只读：写忽略（ACK，不改任何状态）
		else
			regs[reg] = val
		end
		if reg == REG_MODE then
			-- 写有效模式即（重新）启动采样；SHDN/非采样模式停转
			if active() then remaining = period_ms() else remaining = nil end
		end
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
			local b
			if read_ptr == REG_WR then
				b = wr
			elseif read_ptr == REG_OVF then
				b = ovf
			elseif read_ptr == REG_RD then
				b = rd
			elseif read_ptr == REG_DATA then
				b = next_byte()			-- 仅数据口随字节位置推进
			elseif read_ptr == REG_PART then
				b = part_id
			else
				b = regs[read_ptr] or 0
			end
			t[i] = b
		end
		return t
	end

	-- ---------------- 测试 / 守护 API（冒号定义） ----------------

	-- 立即向 FIFO 推入一个注入样本（SpO2 双通道；HR 模式 ir 忽略）
	function d:push_sample(red, ir)
		push_raw(red, ir)
		return self
	end

	-- 批量推入：list 元素 {red=, ir=}（或 r/i 键）
	function d:push_samples(list)
		if type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" then push_raw(s.red or s.r, s.ir or s.i) end
			end
		end
		return self
	end

	-- 排队自动产出注入（advance 到点时按序使用，先于正弦）
	function d:queue_sample(red, ir)
		prod_queue[#prod_queue + 1] = { red = red, ir = ir }
		return self
	end
	function d:queue_samples(list)
		if type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" then
					prod_queue[#prod_queue + 1] = { red = s.red or s.r, ir = s.ir or s.i }
				end
			end
		end
		return self
	end

	function d:clear_fifo()
		fifo_clear()
		return self
	end

	function d:set_part_id(v)
		part_id = math.floor(tonumber(v) or PART_ID) % 256
		return self
	end

	-- 自动采样门停摆（advance 不产出，喂驱动 wait 轮询耗尽；不影响显式 push/virt_tick）
	function d:set_never_sample(on) never_sample = on ~= false; return self end

	-- 推虚拟时钟：active 时按输出周期向 FIFO 产样（可一次跨多拍）
	function d:advance(ms)
		ms = tonumber(ms) or 0
		if active() and remaining ~= nil and not never_sample then
			remaining = remaining - ms
			while remaining <= 0 do
				produce_one()
				remaining = remaining + period_ms()
			end
		end
		return self
	end

	-- 守护逐拍造数：直接推入一拍确定性 PPG 正弦（不经周期门），
	-- 保证 call 读指针即有样本、零真实睡眠；rollover 下也恒取最新数据
	function d:virt_tick(n)
		push_raw(wave(n))
		return self
	end

	function d:fail_write(pred) write_pred = pred; return self end
	function d:fail_read(pred) read_pred = pred; return self end

	function d:clear_faults()
		d.nack, d.nack_read, d.nack_write = false, false, false
		write_pred, read_pred = nil, nil
		never_sample = false
		return self
	end

	function d:reset_logs()
		reset_count, produced = 0, 0
		return self
	end

	-- 重新上电：全状态回 POR（含身份/注入队列）；故障钩子保留
	function d:reset()
		part_id = PART_ID
		prod_queue = {}
		seed_regs()
		fifo_clear()
		read_ptr = nil
		remaining, produced, reset_count = nil, 0, 0
		return self
	end

	-- ---------------- 只读观察口 ----------------

	function d:wr_ptr() return wr end
	function d:rd_ptr() return rd end
	function d:ovf_counter() return ovf end
	-- 驱动口径可用数（(WR-RD) mod 32；积压整圈回绕后与物理占用不符，真实行为）
	function d:avail() return (wr - rd) % DEPTH end
	function d:occupied() return count end
	function d:slot(i)
		local s = slots[math.floor(tonumber(i) or 0) % DEPTH]
		return s and s.r or nil, s and s.i
	end
	function d:rollover_en() return rollover_on() end
	function d:avg_code() return avg_code() end	-- C5：位域位置的白盒观察面
	function d:is_active() return active() end
	function d:mode() return mode_bits() end
	function d:shdn() return shdn_on() end
	function d:spo2_mode() return is_spo2() end
	function d:period_ms() return active() and period_ms() or nil end
	function d:remaining_ms() return remaining end
	function d:produced() return produced end
	function d:reset_count() return reset_count end
	function d:part_id() return part_id end
	function d:reg(a) return regs[math.floor(tonumber(a) or 0)] or 0 end

	return d
end

-- MAX30102.lua - 心率/血氧（PPG）光学传感器 驱动模块
-- bot4cj 仓颉语言机器人框架
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

-- ==================== 寄存器 ====================
local REG_FIFO_WR   = 0x04		-- FIFO 写指针（芯片自增）
local REG_FIFO_OVF  = 0x05		-- 溢出计数（rollover 开启时不增）
local REG_FIFO_RD   = 0x06		-- FIFO 读指针
local REG_FIFO_DATA = 0x07		-- FIFO 数据口：读自动步进，HR 每样本 3 字节 / SpO2 6 字节
local REG_FIFO_CFG  = 0x08		-- SMP_AVE[6:4] | ROLLOVER[3] | A_FULL[2:0]
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
local function cfg_range(v, default, lo, hi, label)
	if v == nil or v == "-" or v == "" then return default end
	local n = math.floor(tonumber(v) or (lo - 1))
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
function build(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments Type: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MAX30102 builder func get a table --------", data)
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

	-- 在位探测 + 型号自检（Part ID 固定 0x15）
	local pid = i2c_read_reg(fd, REG_PART_ID)
	if pid < 0 then
		return {
			result = "ERR",
			message = "MAX30102 not responding (read Part ID failed, check address 0x57 and wiring)"
		}
	end
	if pid ~= PART_ID then
		return {
			result = "ERR",
			message = string.format("MAX30102 unexpected Part ID 0x%02X (expect 0x%02X)", pid, PART_ID)
		}
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
		return {
			result = "ERR",
			message = "Invalid Argument: opmode '" .. opmode_s .. "' (hr|spo2)"
		}
	end

	local rate, e1 = cfg_choice(data.rate, 100, RATE_CODE, "rate(sps)")
	local pw,   e2 = cfg_choice(data.pw, 69, PW_CODE, "pw(us)")
	local adc,  e3 = cfg_choice(data.adc, 4096, ADC_CODE, "adc(nA)")
	local avg,  e4 = cfg_choice(data.avg, 1, AVG_CODE, "avg")
	if e1 or e2 or e3 or e4 then
		return { result = "ERR", message = e1 or e2 or e3 or e4 }
	end
	if rate > PW_MAX_RATE[pw] then
		return {
			result = "ERR",
			message = string.format("Invalid Argument: rate %d sps exceeds limit %d sps for pw %dus", rate, PW_MAX_RATE[pw], pw)
		}
	end

	local led1, e5 = cfg_led_code(data.led1, "led1(mA)")
	local led2_ma = data.led2
	if led2_ma == nil or led2_ma == "-" or led2_ma == "" then led2_ma = data.led1 end
	local led2, e6 = cfg_led_code(led2_ma, "led2(mA)")
	local n,     e7 = cfg_range(data.n, 1, 1, 8, "n(samples)")
	local wait,  e8 = cfg_range(data.wait, 0, 0, 60000, "wait(ms)")
	if e5 or e6 or e7 or e8 then
		return { result = "ERR", message = e5 or e6 or e7 or e8 }
	end

	-----------------------------------------------------
	-- 复位（RESET 位自清零，全部寄存器回上电默认，约 1ms）
	if not i2c_write_reg(fd, REG_MODE, BIT_RESET) then
		return {
			result = "ERR",
			message = "MAX30102 not responding (reset write failed)"
		}
	end
	milli_sleep(5)

	-- 逐项写配置；任一写失败记录后仍走完（器件可能已复位），统一在末尾报错
	local wfail = nil
	local function wr(reg, val, what)
		if wfail == nil and not i2c_write_reg(fd, reg, val) then
			wfail = "MAX30102 not responding (" .. what .. " write failed)"
		end
	end

	wr(REG_FIFO_CFG, AVG_CODE[avg] * 16 + 0x08, "FIFO config")	-- 平均 + rollover（满后覆盖最旧）
	wr(REG_SPO2, ADC_CODE[adc] * 32 + RATE_CODE[rate] * 4 + PW_CODE[pw], "SpO2 config")
	wr(REG_LED1, led1, "LED1 amplitude")
	wr(REG_LED2, led2, "LED2 amplitude")
	wr(REG_FIFO_WR, 0, "FIFO write pointer clear")
	wr(REG_FIFO_OVF, 0, "FIFO overflow clear")
	wr(REG_FIFO_RD, 0, "FIFO read pointer clear")
	wr(REG_MODE, is_spo2 and MODE_SPO2 or MODE_HR, "mode")		-- 写模式即启动采样
	if wfail ~= nil then
		return {
			result = "ERR",
			message = wfail
		}
	end

	cfg_is_spo2 = is_spo2
	cfg_n = n
	cfg_wait = wait

	print(string.format(
		"MAX30102 init OK: addr=0x%02X mode=%s rate=%dsps pw=%dus adc=%dnA avg=%dx led1=%.1fmA led2=%.1fmA n=%d",
		addr, opmode_s, rate, pw, adc, avg, led1 * 0.2, led2 * 0.2, n))
	return {  result = "OK"  }

end

-- ==================== 调用 ====================
-- 排空 FIFO（至多 n 个样本）。FIFO 空返回 ERR（守护跳拍不发布）；数据质量
-- 问题（饱和）只置 SAT 标志。返回样本键 RED0..RED{k-1}（+IR0..）与最新样本别名 RED/IR。
function call(data)

	if type(data) ~= "table" then	-- 检查该参数是否是一张表
		return {
			result = "ERR",
			message = "Invalid Arguments: table"
		}
	end

	if DEBUG then
		dbg_table("-------- MAX30102 caller func get a table --------", data)
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
	-- n/wait 取本次调用参数（缺省用 build 配置）——直连路径可按行动态批量读/等待
	local n_req = math.floor(tonumber(data.n) or cfg_n or 1)
	if n_req < 1 then n_req = 1 elseif n_req > 8 then n_req = 8 end
	local wait_req = math.floor(tonumber(data.wait) or cfg_wait or 0)
	if wait_req < 0 then wait_req = 0 end

	-- 可读样本数；FIFO 空时可等（直连路径用；守护路径 wait 保持 0）
	local avail = fifo_avail(fd)
	if avail == -1 then
		return {
			result = "ERR",
			message = "MAX30102 not responding (read FIFO pointers failed)"
		}
	end
	if avail == 0 and wait_req > 0 then
		local waited = 0
		while avail == 0 and waited < wait_req do
			milli_sleep(10)
			waited = waited + 10
			avail = fifo_avail(fd)
			if avail == -1 then
				return {
					result = "ERR",
					message = "MAX30102 not responding (read FIFO pointers failed)"
				}
			end
		end
	end
	if avail == 0 then
		return {
			result = "ERR",
			message = "MAX30102 FIFO empty (no new sample yet)"
		}
	end

	-- 逐样本弹出（FIFO 序：旧 -> 新），至多 n 个
	local want = math.min(n_req, avail)
	local sat = false
	local reds, irs = {}, {}
	for k = 1, want do
		local red, ir = fifo_read_sample(fd)
		if red == nil then
			if k == 1 then
				return {
					result = "ERR",
					message = "MAX30102 not responding (FIFO data read failed)"
				}
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

end

-- ==================== 销毁 ====================
-- 置 SHDN 关 LED 停采样省电（配置保留；总线 fd 归 I2C 硬件变量所有，不 close）
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	if DEBUG then
		dbg_table("-------- MAX30102 ender func get a table --------", data)
	end

	local fd = tonumber(data.fd)
	local addr = tonumber(data.address)
	if fd ~= nil and addr ~= nil and i2c_set_addr(fd, addr) then
		i2c_write_reg(fd, REG_MODE, BIT_SHDN)
	end

	return {  result = "OK"  }

end

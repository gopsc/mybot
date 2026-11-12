-- sensor_daemon.lua - 万能配置驱动采样守护 chunk（D 方案：setup 一次 + daemon_tick 单次采样）
-- bot4cj 仓颉语言机器人框架
--
-- daemon_body 先 pcall 本 chunk 一次完成 setup（解析配置、加载驱动、开总线、build 传感器、
-- 附着共享槽），随后逐拍 getglobal("daemon_tick")+pcall 采样一次，拍间由 Cangjie sleep 让出
-- 绿色线程（不再由 chunk 内 ffi usleep 阻塞 worker）。
--
-- DAEMON_CONFIG（"k=v;k=v"，来自 @Daemon 矩阵除 name/chunk 外的列）：
--   driver   必填，驱动模块名（modules/<driver>.lua，如 MPU6050/BME280/ADS1115/SGP30）
--   proto    i2c（默认）| spi | uart（uart 时 path=串口设备、baud=波特率）
--            | virt（无硬件仿真：挂 lib/virtbus/<driver 小写>.lua 器件模型，缺失时
--            回退读驱动内嵌的 <驱动名>_VIRT 工厂；驱动/滤波/消费链路全走内存
--            虚拟总线（I2C/SPI/UART 由模型 BUS 标记决定）。模型每拍 virt_tick 造合成数据。
--            仅限测试，启动会打印 VIRTUAL HARDWARE 警告横幅，禁止生产使用）
--   path     总线设备路径（默认 i2c:/dev/i2c-1，spi:/dev/spidev0.0）
--   addr     器件地址（i2c 如 0x68；spi 忽略）
--   fields   逗号或管道分隔的 call() 返回字段名，按序 publish（SQL 里推荐用 |）。
--            每项可带 ":模式" 后缀做逐字段变换，覆盖全局 sign：
--              ACCEL_X        无后缀：按全局 sign 列处理
--              TEMP:f         f/float = 原样透传（温度等换算后的浮点物理量，禁止取整补码）
--              REG_H:s16      s16 = 强制 16 位补码符号扩展
--   sign     可选，16 表示对提取值做 16 位补码符号扩展（无 :后缀 字段的缺省行为）
--   spi 专用：mode/bits/speed/delay
--   其余任意键（如 channel/pga）作为 build/call 的附加参数透传给驱动
--   （interval 由 daemon_body 逐拍 sleep 使用，不在本 chunk 内处理）

if jit then jit.off() end

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local P = dofile(mpath.resolve("lib/pthread.lua"))
dofile(mpath.resolve("lib/HAL.lua"))	-- i2c/spi/uart 采样

-- 解析配置串
-- 注：proto/fields/sign 的**语法**在结构脚本加载期已由宿主校验（src/daemonvar.cpp
-- 的 checkDaemonProto/checkDaemonFields/checkDaemonSign，报错带守护名/列/表/行号）；
-- 下面的解析对非法值仍保持宽容（打日志/透传），仅作为绕过框架直接注入
-- DAEMON_CONFIG（如 test/test_h07_fd.lua）时的兜底，两处规则改动须同步。
-- M6 修复（2026-09-23）：旧 gmatch "([^;=]+)=([^;]*)" 对含 = 的值静默截断
-- （value 内第二个 = 被当新键分隔符，后段被当新键）。改按第一个 = 分割。
local cfg = {}
for pair in string.gmatch(DAEMON_CONFIG or "", "([^;]+)") do
	local eq = string.find(pair, "=")
	if eq then
		local k = string.sub(pair, 1, eq - 1)
		local v = string.sub(pair, eq + 1)
		cfg[k] = v
	end
end

local driver = cfg.driver
local proto  = cfg.proto or "i2c"
local path   = cfg.path or (proto == "spi" and "/dev/spidev0.0" or "/dev/i2c-1")
local addr   = cfg.addr
local sign   = tonumber(cfg.sign)

-- 实际总线族：proto=virt 时由模型 BUS 标记决定（I2C 模型走 i2c_*，SPI 模型走 spi_*，
-- UART 模型走 uart_*）；close_bus/开总线/params 都按它分流。
-- virt 在模型加载后可能从 i2c 修正为 spi/uart。
local bus_kind = (proto == "uart") and "uart" or (proto == "spi") and "spi" or "i2c"

-- fields 解析："名字" 或 "名字:模式"；模式 ""=跟随全局 sign，"f"/"float"=原样，
-- "s16"=16 位补码（解析到非法模式按原样透传并打日志，绝不静默取整丢精度）
local fields = {}
local field_modes = {}
for tok in string.gmatch(cfg.fields or "", "[^,|]+") do
	-- %w* 而非 %a*：s16 等模式名含数字
	local name, suffix = string.match(tok, "^([^:]+):?(%w*)$")
	if name == nil or name == "" then
		print("sensor_daemon: bad field token '" .. tostring(tok) .. "', skipped")
	else
		local mode = ""
		if suffix == "f" or suffix == "float" then
			mode = "f"
		elseif suffix == "s16" then
			mode = "s16"
		elseif suffix ~= "" then
			print("sensor_daemon: unknown field mode ':" .. suffix .. "' on '"
				.. name .. "', passthrough as-is")
			mode = "f"
		end
		fields[#fields + 1] = name
		field_modes[#field_modes + 1] = mode
	end
end

local slot = P.slot_attach(DAEMON_SLOT_ADDR)
P.assert_layout()	-- 跨语言槽布局漂移在守护启动期显式暴露（daemon_probe 同款自检）

-- 保留真实 print 的引用（下文会静默驱动 print 刷屏），fail 诊断日志仍可见
local log = print

-- 总线 fd 提前声明：fail 需在任何失败点关闭已打开的总线（否则守护
-- lua_State 长期持有泄漏 fd）
local fd = nil

-- proto=virt：虚拟总线句柄与器件模型（tick 每拍驱动模型造数，cleanup 还原）
local vbus, vdev = nil, nil

-- H-07：关闭已打开的总线 fd（幂等；fail 与 daemon_cleanup 共用）
local function close_bus()
	if fd ~= nil and fd >= 0 then
		if bus_kind == "spi" then spi_close(fd)
		elseif bus_kind == "uart" then uart_close(fd)
		else i2c_close(fd) end
		fd = -1
	end
end

-- setup 失败：打日志 → 关总线 fd → 写 status 失败码 → daemon_tick 置空转
-- （daemon_body 仍会逐拍调用直到 stop）。
-- 错误码：-9 缺 driver、-8 驱动加载失败、-1 开总线失败、-3 spi setup 失败、-2 build 失败。
-- N-27：失败码写进槽的独立 status 字段（P.set_status），**不再伪装成 v0 采样值**
-- ——旧实现 `P.publish(slot, { code })` 会把 -2 发布成一个负样本，下游 $ 引用
-- 没有甄别手段（配置错误会被当温度做闭环，只有 count 停滞这种间接迹象）。
-- 现在宿主的读路径见 status ≠ 0 即按 ERR 报错，失败是响亮的。
local function fail(code, msg)
	log("[sensor_daemon] setup failed (" .. tostring(code) .. "): " .. tostring(msg))
	close_bus()
	P.set_status(slot, code)
	P.publish(slot, {})	-- 只推进 count（nvals=0），不发布任何假样本
	function daemon_tick() end
end

if not driver or driver == "" then fail(-9, "config missing 'driver'"); return end

local drvpath = mpath.resolve(driver .. ".lua")
local ok_load, load_err = true, nil

if proto == "virt" then
	-- ---- 无硬件仿真：加载虚拟总线 + 与 driver 同名的器件模型 ----
	-- 约定（二选一）：① modules/lib/virtbus/<driver 小写>.lua 存在且 new() 返回
	-- 模型；② 文件缺失时回退读驱动文件内嵌的全局 <驱动名>_VIRT 工厂（单文件
	-- 驱动+模型形态）。模型每拍 virt_tick(n) 造数（无此方法则输出静态初值）。
	-- HAL 已在本 chunk 顶部 dofile（__BOT4CJ_HAL guard 使驱动内的再次 dofile
	-- 不覆盖全局），load_driver 仍重注入一次以固定「驱动加载后全局为虚拟函数」。
	local vrok
	vrok, vbus = pcall(dofile, mpath.resolve("lib/virtbus.lua"))
	if not vrok then
		fail(-8, "virt: cannot load lib/virtbus.lua: " .. tostring(vbus)); return
	end
	local model_path = mpath.resolve("lib/virtbus/" .. string.lower(tostring(driver)) .. ".lua")
	local vmod, drv_preloaded = nil, false
	vrok, vmod = pcall(dofile, model_path)
	if not vrok or type(vmod) ~= "table" or type(vmod.new) ~= "function" then
		-- 回退（单文件驱动+模型约定，2026-09-15 起）：模型文件缺失时加载驱动
		-- 文件本身，取其内嵌的全局 <驱动名>_VIRT 工厂（如 BH1750_VIRT）。
		-- 驱动此时已加载完毕，末尾跳过 load_driver 二次 dofile，仅重注入
		-- （等价 load_driver 后半段：先置 _injected=false 再 inject）。
		local drv_ok, drv_err = pcall(dofile, drvpath)
		if not drv_ok then
			fail(-8, "virt: no virtual device model for driver '" .. tostring(driver)
				.. "' (model file missing and driver load failed: " .. tostring(drv_err) .. ")"); return
		end
		vmod = rawget(_G, tostring(driver) .. "_VIRT")
		if type(vmod) ~= "table" or type(vmod.new) ~= "function" then
			fail(-8, "virt: no virtual device model for driver '" .. tostring(driver)
				.. "': neither " .. model_path .. " nor embedded " .. tostring(driver) .. "_VIRT"); return
		end
		drv_preloaded = true
	end
	vrok, vdev = pcall(vmod.new)
	if not vrok or type(vdev) ~= "table" then
		fail(-8, "virt: model new() failed: " .. tostring(vdev)); return
	end
	-- BUS 类型判定与 attach 分派收敛至 virtbus.attach_model（N-26）：
	-- SPI 模型（模块表/实例 BUS="spi"）路径即片选身份，走 attach_spi；
	-- UART 模型（BUS="uart"）按 tty 路径走 attach_uart（应答环挂载）；
	-- I2C 模型维持 addr 挂载。
	local kind = vbus.model_kind(vmod, vdev)
	bus_kind = kind
	if kind == "spi" then
		-- 用户未显式给 path 时，proto=virt 上面默认成了 /dev/i2c-1，这里修正
		if not cfg.path then path = "/dev/spidev0.0" end
	elseif kind == "uart" then
		-- 同上：virt 的 uart 模型缺省挂 /dev/serial0（HAL 路径白名单内）
		if not cfg.path then path = "/dev/serial0" end
	else
		local addr_n = tonumber(addr)
		if not addr_n then
			fail(-8, "virt: missing/invalid 'addr' for virtual device: " .. tostring(addr)); return
		end
	end
	vbus.attach_model("VIRT:" .. tostring(driver) .. "@"
		.. (kind == "i2c" and tostring(addr) or path),
		vdev, tonumber(addr), path, kind)
	if drv_preloaded then
		vbus._injected = false
		vbus.inject()
		ok_load, load_err = true, nil
	else
		ok_load, load_err = pcall(vbus.load_driver, drvpath)
	end
else
	ok_load, load_err = pcall(dofile, drvpath)
end
if not ok_load then
	fail(-8, "cannot load driver: " .. drvpath .. " (" .. tostring(load_err) .. ")"); return
end

-- M6 修复（2026-09-23）：setup 成功后无条件 print=function()end 吞掉驱动 tick 期全部
-- 诊断输出（驱动内仿真模型打的波形合成日志、异常条件等）。改为限频透传：
-- 每秒最多打印 5 次，超出时静默（避免高速采样刷屏，同时保留关键诊断输出）。
local print_count = 0
local print_reset_time = os.time()
local PRINT_LIMIT_PER_SEC = 5
local original_print = print
print = function(...)
	local now = os.time()
	if now ~= print_reset_time then
		print_reset_time = now
		print_count = 0
	end
	if print_count < PRINT_LIMIT_PER_SEC then
		print_count = print_count + 1
		original_print(...)
	end
end

-- proto=virt 显著横幅：仿真数据绝不能被误当成真机采样（防生产环境误用）
if proto == "virt" then
	log("================================================================")
	log(" [sensor_daemon] *** VIRTUAL HARDWARE -- NO REAL DEVICE ***")
	log(string.format(" proto=virt driver=%s bus=%s(%s) addr=%s",
		tostring(driver), bus_kind, tostring(path), tostring(addr)))
	log(" all samples from in-memory simulation model (synthetic waveforms), NOT from any real device!")
	log(" for hardware-free testing only; must NOT be used in production.")
	log("================================================================")
end

-- 字段提取（逐字段模式优先于全局 sign）：
--   "f"   原样透传（换算后的浮点物理量，如 MPU6050 TEMP °C、INA226 V/I/P、MLX90393 µT）
--   "s16" 16 位二进制补码符号扩展（整型路径，先取整保证 % 65536 可用）
--   ""    跟随全局 sign 列（sign=16 时补码，否则原样）
local function effective_bits(mode)
	return (mode == "s16") and 16 or (mode == "" and sign or nil)
end

local function conv(v, mode)
	v = tonumber(v) or 0
	local bits = effective_bits(mode)
	if bits == 16 then
		v = math.floor(v) % 65536
		if v >= 32768 then v = v - 65536 end
	end
	return v
end

-- 组装驱动参数：fd/address + 配置中的额外键（排除框架键）
local known = {
	driver = 1, proto = 1, path = 1, addr = 1, interval = 1,
	fields = 1, sign = 1, mode = 1, bits = 1, speed = 1, delay = 1, baud = 1,
	maxvals = 1,	-- 框架列：槽容量（宿主消费，不下发驱动）
	sources = 1,	-- 框架列：聚合 peer 清单（宿主解析注入，与本 chunk 无关）
}
local params = {}
-- SPI 器件（含 virt SPI 模型）没有地址概念；只有 I2C 才传 address
if addr and bus_kind ~= "spi" then params.address = addr end
for k, v in pairs(cfg) do
	if not known[k] then params[k] = v end
end

-- 打开总线（fd 已在 fail 定义前声明为 upvalue，供其在失败点关闭）
if bus_kind == "spi" then
	fd = spi_open(path)
	if fd and fd >= 0 then
		-- setup 失败必须显式失败：半配置 fd 交给驱动会得到错误数据
		-- （proto=virt 时 spi_* 是虚拟注入层，mode/bits/speed 同样留痕）
		if spi_setup(fd, tonumber(cfg.mode or 0), tonumber(cfg.bits or 8),
		             tonumber(cfg.speed or 1000000), tonumber(cfg.delay or 0)) ~= 0 then
			fail(-3, "spi_setup failed: " .. path); return
		end
	end
elseif bus_kind == "uart" then
	-- 串口设备（如 MHZ19）：raw 8N1，波特率 baud 列（缺省 9600）
	fd = uart_open(path, tonumber(cfg.baud or 9600))
else
	fd = i2c_open(path)
end
if not fd or fd < 0 then fd = nil; fail(-1, "cannot open bus: " .. path); return end
params.fd = fd

-- 配置器件
-- build 前先打一拍 virt_tick(0)：部分器件 build 内含长转换门（如 SGP30
-- Measure_test 220ms 自检），守护线程不注入 milli_sleep 桩、不推进模型虚拟
-- 时钟，预武装使这类 build 读即就绪；同时把器件置于已上电稳定（warm）态。
-- 无 virt_tick 的模型（写-only 输出器件）不受影响；既有模型 build 不读
-- 转换结果（NVM/状态/回显），预武装不误伤。virt_n 仍从 0 起，造数确定性不变。
if vdev ~= nil and type(vdev.virt_tick) == "function" then
	pcall(function() vdev:virt_tick(0) end)
end
-- 防线：build 抛 Lua error（典型：@Daemon 的 driver 列误配成无全局 build 的模块）
-- 时，裸调用会跳过 fail() 里的 close_bus()；而 C++ 侧 chunk setup 失败是直接
-- lua_close 返回，不会调用本文件末尾的 daemon_cleanup（此刻尚未定义）——HAL 没有
-- ffi.gc，已 open 的总线 fd 就永久泄漏在进程里。故就地 pcall 并走同一条回滚路径。
local okr, rb = pcall(build, params)
if not okr then
	fail(-2, "driver build() raised: " .. tostring(rb)); return
end
local r = rb
if type(r) ~= "table" or r.result ~= "OK" then
	local why = (type(r) == "table" and r.message) and tostring(r.message) or "driver build() not OK"
	fail(-2, why); return
end

-- daemon_body 逐拍调用：单次采样 → 提取 fields → publish
-- 错误限频：tick 期总线错误仅首 3 次 + 每 100 次打印一条摘要，
-- 避免高频采样下日志刷屏，同时保留诊断信息（count 停滞不可见时
-- 日志是唯一线索）
local tick_errors = 0
local tick_total  = 0
local virt_n      = 0	-- proto=virt：已驱动的模型节拍序号（确定性波形相位）
function daemon_tick()
	-- virt：先让模型推进一拍合成数据，驱动随后经虚拟总线读到本拍样本
	if vdev ~= nil and type(vdev.virt_tick) == "function" then
		vdev:virt_tick(virt_n)
		virt_n = virt_n + 1
	end
	local s = call(params)
	-- SHT3X/SGP30 等驱动 CRC 失败仍返回 result=OK（仅标 CRC_OK=0，避免直接 play 时
	-- halt-on-error 中断动作序列）；守护侧是数据流而非动作，坏样本不得发布给下游——
	-- 按 tick 错误处理、本次不 publish（count 停滞即是诊断线索）
	local crc_bad = (type(s) == "table" and s.result == "OK" and s.CRC_OK == 0)
	local ok_sample = (type(s) == "table" and s.result == "OK" and not crc_bad)
	local why = "unknown"
	if crc_bad then
		why = "CRC check failed (CRC_OK=0)"
	elseif ok_sample then
		-- 防线：@Daemon 的 fields 列拼错字段名时，conv 的 `tonumber(v) or 0` 会
		-- 把不存在的键静默发布成 0，走的是 result=OK 分支、零日志、count 正常自增
		-- ——下游 Ema/Kalman/Monitor 于是拿假 0 做闭环决策（真 0 与配置错误不可区分）。
		-- 配置类错误同样按 tick 错误处理：不发布、count 停滞，日志点名缺哪个字段。
		local missing = nil
		local float_s16 = nil
		for i = 1, #fields do
			local raw = tonumber(s[fields[i]])
			if raw == nil then
				missing = (missing and (missing .. ", ") or "") .. tostring(fields[i])
			elseif raw % 1 ~= 0 and effective_bits(field_modes[i]) == 16 then
				-- 防线：浮点物理量（SHT3X 的 T/RH、BME280 的 T/P/H 等已换算值）
				-- 配 s16 补码会被 floor 截断成整数假值（23.56 → 23），tonumber
				-- 照样通过、零日志静默发布错值——与字段拼错发 0 同族的数据破坏，
				-- 拒绝发布，点名让配置改用 ':f' 或去掉 sign 后缀。
				float_s16 = (float_s16 and (float_s16 .. ", ") or "") .. tostring(fields[i])
			end
		end
		if missing ~= nil then
			ok_sample = false
			why = "field(s) absent or non-numeric in driver result: " .. missing
		elseif float_s16 ~= nil then
			ok_sample = false
			why = "float value(s) with s16 mode would be truncated to integer: " .. float_s16
				.. " (use ':f' suffix or drop sign=16 for these fields)"
		end
	elseif type(s) == "table" and s.message then
		why = tostring(s.message)
	end
	if ok_sample then
		local vals = {}
		for i = 1, #fields do
			vals[i] = conv(s[fields[i]], field_modes[i])
		end
		P.publish(slot, vals)
		tick_errors = 0
	else
		tick_errors = tick_errors + 1
		tick_total  = tick_total + 1
		if tick_errors <= 3 or tick_total % 100 == 0 then
			log(string.format("[sensor_daemon] tick error #%d (total %d): %s",
				tick_errors, tick_total, why))
		end
	end
end

-- H-07：守护退出（stop 后、Lua_free 前）由 daemon_body 调用，先调驱动 destroy()（若有）
-- 让器件退出活跃态（VL53L0X 停止 ranging、ADS1x15 置单次态断电等），再关总线 fd。
-- setup 失败路径不会到达此定义（fail 已 return），此时 fd 已由 close_bus 关闭。
--
-- 审计 2026-09-20（中）：destroy 此前是**裸调**——驱动 destroy 抛异常时本函数
-- 直接中断，close_bus() 与 vbus.restore() 都不再执行，总线 fd（build 时
-- open/ioctl 拿到的真内核句柄）泄漏到进程退出；反复启停守护会耗尽 fd。
-- 宿主侧只 pcall 了 cleanup 本身（daemonvar.cpp）并随即 lua_close，HAL 也没有
-- ffi.gc 兜底，所以这里必须自己保证「无论 destroy 成败都要释放」。
-- 语义取舍：destroy 失败**不改变** daemon_cleanup 的返回（调用方只 pcall，
-- 无返回值契约），失败原因按 stderr 注记——退出路径上的资源释放优先于
-- 传播一个无人接收的错误。
function daemon_cleanup()
	if type(destroy) == "function" then
		local ok, err = pcall(destroy, params)
		if not ok then
			io.stderr:write(string.format(
				"[sensor_daemon] driver destroy() failed during cleanup (bus will still be closed): %s\n",
				tostring(err)))
		end
	end
	close_bus()
	-- virt：还原全局 i2c_*/spi_*/uart_*（独立守护 lua_State 随之销毁，主要为状态对称）
	if vbus ~= nil then vbus.restore() end
end

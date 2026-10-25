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
--            | virt（无硬件仿真：挂 modules/lib/virtbus/<driver 小写>.lua 器件模型，
--            驱动/滤波/消费链路全走内存虚拟 I2C；模型每拍 virt_tick 造合成数据。
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

local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
local P = dofile(mpath.resolve("lib/pthread.lua"))
dofile(mpath.resolve("lib/HAL.lua"))	-- i2c/spi 采样

-- 解析配置串
local cfg = {}
for k, v in string.gmatch(DAEMON_CONFIG or "", "([^;=]+)=([^;]*)") do
	cfg[k] = v
end

local driver = cfg.driver
local proto  = cfg.proto or "i2c"
local path   = cfg.path or (proto == "spi" and "/dev/spidev0.0" or "/dev/i2c-1")
local addr   = cfg.addr
local sign   = tonumber(cfg.sign)

-- 实际总线族：proto=virt 时由模型 BUS 标记决定（I2C 模型走 i2c_*，SPI 模型走 spi_*）；
-- close_bus/开总线/params 都按它分流。virt 在模型加载后可能从 i2c 修正为 spi。
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

-- setup 失败：打日志 → 关总线 fd → 发布错误标志一次 → daemon_tick 置空转
-- （daemon_body 仍会逐拍调用直到 stop）。
-- 错误码：-9 缺 driver、-8 驱动加载失败、-1 开总线失败、-3 spi setup 失败、-2 build 失败。
-- 注意：错误码经 v0 发布（槽布局无独立 status 字段）——下游消费者若把 v0
-- 当实测值需自行甄别（特征：count 恒为 1 且 v0 为负整数）；诊断以日志行为准。
local function fail(code, msg)
	log("[sensor_daemon] setup failed (" .. tostring(code) .. "): " .. tostring(msg))
	close_bus()
	P.publish(slot, { code })
	function daemon_tick() end
end

if not driver or driver == "" then fail(-9, "config missing 'driver'"); return end

local drvpath = mpath.resolve(driver .. ".lua")
local ok_load, load_err = true, nil

if proto == "virt" then
	-- ---- 无硬件仿真：加载虚拟总线 + 与 driver 同名的器件模型 ----
	-- 约定：modules/lib/virtbus/<driver 小写>.lua 必须存在且 new() 返回模型；
	-- 模型每拍 virt_tick(n) 造数（无此方法则输出静态初值）。
	-- HAL 已在本 chunk 顶部 dofile（__BOT4CJ_HAL guard 使驱动内的再次 dofile
	-- 不覆盖全局），load_driver 仍重注入一次以固定「驱动加载后全局为虚拟函数」。
	local vrok
	vrok, vbus = pcall(dofile, mpath.resolve("lib/virtbus.lua"))
	if not vrok then
		fail(-8, "virt: cannot load lib/virtbus.lua: " .. tostring(vbus)); return
	end
	local model_path = mpath.resolve("lib/virtbus/" .. string.lower(tostring(driver)) .. ".lua")
	local vmod
	vrok, vmod = pcall(dofile, model_path)
	if not vrok or type(vmod) ~= "table" or type(vmod.new) ~= "function" then
		fail(-8, "virt: no virtual device model for driver '" .. tostring(driver)
			.. "': " .. model_path); return
	end
	vrok, vdev = pcall(vmod.new)
	if not vrok or type(vdev) ~= "table" then
		fail(-8, "virt: model new() failed: " .. tostring(vdev)); return
	end
	-- SPI 模型（模块表 BUS="spi"，兼容实例自带 BUS）：路径即片选身份，
	-- 走 attach_spi；I2C 模型维持 addr 挂载。
	local is_spi = (vmod.BUS == "spi" or vdev.BUS == "spi")
	if is_spi then
		bus_kind = "spi"
		-- 用户未显式给 path 时，proto=virt 上面默认成了 /dev/i2c-1，这里修正
		if not cfg.path then path = "/dev/spidev0.0" end
		vbus.attach_spi("VIRT:" .. tostring(driver) .. "@" .. path, path, vdev)
	else
		local addr_n = tonumber(addr)
		if not addr_n then
			fail(-8, "virt: missing/invalid 'addr' for virtual device: " .. tostring(addr)); return
		end
		vbus.attach("VIRT:" .. tostring(driver) .. "@" .. tostring(addr), addr_n, vdev)
	end
	ok_load, load_err = pcall(vbus.load_driver, drvpath)
else
	ok_load, load_err = pcall(dofile, drvpath)
end
if not ok_load then
	fail(-8, "cannot load driver: " .. drvpath .. " (" .. tostring(load_err) .. ")"); return
end

-- 高速采样中静默驱动的 print 刷屏（本状态机独立）
print = function() end

-- proto=virt 显著横幅：仿真数据绝不能被误当成真机采样（防生产环境误用）
if proto == "virt" then
	log("================================================================")
	log(" [sensor_daemon] *** VIRTUAL HARDWARE -- NO REAL DEVICE ***")
	log(string.format(" proto=virt driver=%s bus=%s(%s) addr=%s",
		tostring(driver), bus_kind, tostring(path), tostring(addr)))
	log(" 采样值全部来自内存仿真模型（合成波形），不代表任何真机！")
	log(" 仅限无硬件链路测试，禁止用于生产环境。")
	log("================================================================")
end

-- 字段提取（逐字段模式优先于全局 sign）：
--   "f"   原样透传（换算后的浮点物理量，如 MPU6050 TEMP °C、INA226 V/I/P、MLX90393 µT）
--   "s16" 16 位二进制补码符号扩展（整型路径，先取整保证 % 65536 可用）
--   ""    跟随全局 sign 列（sign=16 时补码，否则原样）
local function conv(v, mode)
	v = tonumber(v) or 0
	local bits = (mode == "s16") and 16 or (mode == "" and sign or nil)
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
local r = build(params)
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
	if type(s) == "table" and s.result == "OK" and not crc_bad then
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
			local why = "unknown"
			if crc_bad then
				why = "CRC check failed (CRC_OK=0)"
			elseif type(s) == "table" and s.message then
				why = tostring(s.message)
			end
			log(string.format("[sensor_daemon] tick error #%d (total %d): %s",
				tick_errors, tick_total, why))
		end
	end
end

-- H-07：守护退出（stop 后、Lua_free 前）由 daemon_body 调用，先调驱动 destroy()（若有）
-- 让器件退出活跃态（VL53L0X 停止 ranging、ADS1x15 置单次态断电等），再关总线 fd。
-- setup 失败路径不会到达此定义（fail 已 return），此时 fd 已由 close_bus 关闭。
function daemon_cleanup()
	if type(destroy) == "function" then
		destroy(params)
	end
	close_bus()
	-- virt：还原全局 i2c_*/spi_*（独立守护 lua_State 随之销毁，主要为状态对称）
	if vbus ~= nil then vbus.restore() end
end

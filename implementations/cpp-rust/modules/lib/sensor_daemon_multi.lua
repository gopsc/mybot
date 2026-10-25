-- sensor_daemon_multi.lua - 多器件合并采样守护 chunk（sensor_daemon 的 N 器件变体）
-- bot4cj 仓颉语言机器人框架
--
-- 动机（docs/daemon.md「守护线程开销」）：每个 @Daemon = 独立线程 + 独立 Lua 状态，
-- 同一总线上 N 只同型/异型传感器就要 N 份运行时。本 chunk 用**一个守护**轮询
-- 同一条总线上的多个器件：1 线程 + 1 Lua 状态 + 1 总线 fd，逐拍把所有器件的
-- 样本拼进**同一次 publish**（原子快照，主线程不会读到「半新半旧」的一拍）。
--
-- 与 sensor_daemon.lua 的契约差异（其余语义——拍间 sleep 让出、setup 失败
-- status 失败码、坏样本不发布、错误限频——完全同源）：
--   1. 器件清单来自 devices 列（spec 串），不再用 driver/addr/fields 列
--   2. 所有器件共享一条总线（一个 fd），因此只支持 i2c / virt（SPI 片选即
--      路径身份、UART 应答环即 tty，都做不到「一 fd 多器件」，配置即报错）
--   3. spec 内字段用逗号分隔，spec 之间用 | 分隔（与单器件版的
--      「fields 里 , 和 | 等价」不同，注意）
--   4. 每个驱动加载进独立 fenv（LuaJIT setfenv）：驱动把 build/call/destroy
--      定义成全局函数，两个驱动同状态机会互相覆盖；fenv 经 __index 落到
--      _G，共享 HAL/virtbus 注入的 i2c_* 全局
--   5. 全部样本合成一次 publish，故字段总数受共享槽 values[SLOT_MAXVALS] 限制
--
-- DAEMON_CONFIG（"k=v;k=v"，来自 @Daemon 矩阵除 name/chunk 外的列）：
--   devices  必填。器件 spec 列表，| 分隔。每个 spec：
--              driver@addr@f1,f2:模式[@k=v]...
--              driver  驱动模块名（modules/<driver>.lua）
--              addr    I2C 地址（如 0x23）
--              fields  逗号分隔的 call() 返回字段名，:f / :s16 后缀语义
--                      与 sensor_daemon 一致（f=浮点透传，s16=16位补码，
--                      无后缀跟随全局 sign 列）
--              k=v     其余键作为该器件 build 参数透传（覆盖全局同名键）
--   proto    i2c（默认）| virt（无硬件仿真：每只 driver 挂 lib/virtbus/
--            <driver 小写>.lua 模型或内嵌 <驱动名>_VIRT 工厂，仅限测试）
--   path     总线设备路径（默认 /dev/i2c-1）
--   sign     可选，全局 16 位补码缺省（逐字段 :s16/:f 可覆盖）
--   其余任意键作为**所有器件**的 build 参数透传（器件 spec 内同名键优先）
--
-- 用法示例（两只 BH1750 挂同一 i2c-1， ADDR 引脚分接 0x23/0x5C）：
--   INSERT INTO Daemon (name, chunk, proto, path, interval, devices)
--     VALUES ('lux0', 'lib/sensor_daemon_multi.lua', 'i2c', '/dev/i2c-1', '10',
--             'BH1750@0x23@LUX|BH1750@0x5C@LUX');
--   上游 @Ema/@Monitor 用 field=v0/v1/... 按拼接顺序引用（先 spec 序、
--   再字段序）。

if jit then jit.off() end

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
local P = dofile(mpath.resolve("lib/pthread.lua"))
dofile(mpath.resolve("lib/HAL.lua"))	-- i2c 采样（guard 使驱动内的再次 dofile 不覆盖全局）

-- 解析配置串（宽容兜底与 sensor_daemon 同源：语法已由宿主校验，此处不重复）
local cfg = {}
for k, v in string.gmatch(DAEMON_CONFIG or "", "([^;=]+)=([^;]*)") do
	cfg[k] = v
end

local proto = cfg.proto or "i2c"
local path  = cfg.path or "/dev/i2c-1"
local sign  = tonumber(cfg.sign)
local slot  = P.slot_attach(DAEMON_SLOT_ADDR)
P.assert_layout()	-- 跨语言槽布局漂移在守护启动期显式暴露（daemon_probe 同款自检）

local log = print	-- 保留真实 print（下文会静默驱动 print 刷屏）

-- 一次 publish 的总字段数上限 = 本守护槽容量。
-- **不在此处硬编码**（2026-09-21 第七轮审计）：唯一事实源是宿主按 @Daemon 的
-- maxvals 列分配的槽容量（ABI v2），经 DAEMON_SLOT_LAYOUT 注入为 P.SLOT_MAXVALS
-- （缺省回落 pthread.lua 的 base_layout=64）。写死数的后果是两侧各自漂移：
-- C++ 侧改窄 ⇒ 本文件的预算检查放行、pthread.lua 的 publish 再静默钳制 ⇒
-- 尾部字段**永不出值**且无任何报错；改宽 ⇒ 本文件误拒合法配置。
local MAX_VALUES = P.SLOT_MAXVALS

-- 总线 fd 提前声明：fail 需在任何失败点关闭已打开的总线
local fd = nil
-- proto=virt：虚拟总线句柄（多器件共用一个注入态）
local vbus = nil

-- H-07：关闭已打开的总线 fd（幂等；fail 与 daemon_cleanup 共用）
local function close_bus()
	if fd ~= nil and fd >= 0 then
		i2c_close(fd)
		fd = -1
	end
end

-- setup 失败：打日志 → 关总线 fd → 写 status 失败码 → daemon_tick 置空转
-- （语义与 sensor_daemon.fail 完全一致：失败码进槽的 status 字段，
-- 不伪装成采样值；宿主读路径见 status ≠ 0 即响亮报错）。
-- 错误码沿用单器件版口径：-9 缺 driver、-8 驱动/模型加载失败、-1 开总线失败、
-- -2 build 失败（兼作 chunk 级配置错误：proto 不支持、spec 残缺、字段超预算）。
local function fail(code, msg)
	log("[sensor_daemon_multi] setup failed (" .. tostring(code) .. "): " .. tostring(msg))
	close_bus()
	if vbus ~= nil then pcall(vbus.restore) end
	P.set_status(slot, code)
	P.publish(slot, {})	-- 只推进 count（nvals=0），不发布任何假样本
	function daemon_tick() end
end

-- ---- spec 解析 ------------------------------------------------------------
-- spec = driver@addr@fields[@k=v]*，fields 内逗号分隔「名[:模式]」。
-- '@' 分隔符安全：字段名/键名是 C 标识符，地址是 0xNN，均不含 '@'；
-- DAEMON_CONFIG 的顶层分隔符 ';' 由宿主按列字符集拒绝出现在值里。

-- 按 sep 全拆（保留空段供报错点名，gmatch 的 + 模式会把空段吞掉）
local function split(s, sep)
	local out = {}
	local pos = 1
	while true do
		local i, j = string.find(s, sep, pos, true)
		out[#out + 1] = string.sub(s, pos, i and i - 1)
		if not i then return out end
		pos = j + 1
	end
end

local function parse_devices(spec)
	local devs = {}
	for si, sp in ipairs(split(spec or "", "|")) do
		local parts = split(sp, "@")
		local driver, addr, fieldstr = parts[1], parts[2], parts[3]
		if driver == nil or driver == "" or addr == nil or addr == ""
				or fieldstr == nil or fieldstr == "" then
			fail(-2, "devices[" .. si .. "] spec must be driver@addr@fields: '" .. sp .. "'")
			return nil
		end
		local dev = {
			idx    = si,
			driver = driver,
			addr   = addr,
			fields = {},
			modes  = {},
			extra  = {},
		}
		for fi, tok in ipairs(split(fieldstr, ",")) do
			-- 模式语义与单器件版一致：%w* 而非 %a*（s16 含数字）
			local name, suffix = string.match(tok, "^([^:]+):?(%w*)$")
			if name == nil or name == "" then
				fail(-2, "devices[" .. si .. "] bad field token '" .. tok .. "'")
				return nil
			end
			local mode = ""
			if suffix == "f" or suffix == "float" then
				mode = "f"
			elseif suffix == "s16" then
				mode = "s16"
			elseif suffix ~= "" then
				log("[sensor_daemon_multi] devices[" .. si .. "] unknown field mode ':"
					.. suffix .. "' on '" .. name .. "', passthrough as-is")
				mode = "f"
			end
			dev.fields[#dev.fields + 1] = name
			dev.modes[#dev.modes + 1] = mode
		end
		for ki = 4, #parts do
			local k, v = string.match(parts[ki], "^([^=]+)=(.*)$")
			if k == nil or k == "" then
				fail(-2, "devices[" .. si .. "] bad extra param '" .. parts[ki]
					.. "' (expect k=v)")
				return nil
			end
			dev.extra[k] = v
		end
		devs[si] = dev
	end
	return devs
end

-- proto 校验（加载期 fail-fast）：合并采样的一条总线一个 fd 只对 I2C 成立——
-- SPI 的片选即设备路径（一 fd 一器件）、UART 应答环即 tty（一 fd 一器件），
-- 都做不到多器件共用；配了就拒绝，而不是静默只采第一只。
if proto ~= "i2c" and proto ~= "virt" then
	fail(-2, "sensor_daemon_multi only supports proto=i2c|virt (one fd serves many "
		.. "devices on I2C; SPI/UART identity is per-fd), got: " .. tostring(proto))
	return
end

local devs = parse_devices(cfg.devices)
if devs == nil then return end

-- 字段预算：全部样本合成一次 publish，values[MAX_VALUES] 装不下就是配置错误（加载期
-- 响亮失败，而不是发布时静默截断）
local total_vals = 0
for _, dev in ipairs(devs) do
	total_vals = total_vals + #dev.fields
end
if total_vals > MAX_VALUES then
	fail(-2, "total field count " .. total_vals .. " exceeds slot capacity "
		.. MAX_VALUES .. " (devices: " .. cfg.devices .. ")")
	return
end

-- 驱动加载：dofile 进器件私有 fenv（__index 落到 _G，共享 HAL/virtbus 注入
-- 的 i2c_* 全局）。驱动把 build/call/destroy 定义成「全局」函数，实际落进
-- dev_env——两份驱动互不覆盖；驱动文件内 dofile 的 HAL/drv_common 走
-- __BOT4CJ_HAL guard / 幂等重定义，共享无害。
local function load_driver_env(dev)
	local env = setmetatable({}, { __index = _G })
	local drvpath = mpath.resolve(dev.driver .. ".lua")
	local f, err = loadfile(drvpath)
	if f == nil then
		fail(-8, "devices[" .. dev.idx .. "] cannot load driver: " .. drvpath
			.. " (" .. tostring(err) .. ")")
		return nil
	end
	setfenv(f, env)		-- LuaJIT（5.1 语义）：已加载 chunk 缺省落 _G，必须显式换 fenv
	local ok, rerr = pcall(f)
	if not ok then
		fail(-8, "devices[" .. dev.idx .. "] driver load raised: " .. tostring(rerr))
		return nil
	end
	dev.env = env
	return true
end

-- 高速采样中静默驱动的 print 刷屏（本状态机独立；与单器件版同位置：build 前）
print = function() end

-- proto=virt 显著横幅：仿真数据绝不能被误当成真机采样（防生产环境误用）
if proto == "virt" then
	log("================================================================")
	log(" [sensor_daemon_multi] *** VIRTUAL HARDWARE -- NO REAL DEVICE ***")
	log(string.format(" proto=virt bus=%s devices=%s", tostring(path), tostring(cfg.devices)))
	log(" all samples from in-memory simulation model (synthetic waveforms), NOT from any real device!")
	log(" for hardware-free testing only; must NOT be used in production.")
	log("================================================================")
end

-- 字段提取（逐字段模式优先于全局 sign）——与 sensor_daemon 同源
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

-- proto=virt：逐器件挂模型（单器件版 attach_model 收敛点在 virtbus.attach_model，
-- 但多器件的驱动加载走 fenv，不能经 vbus.load_driver 二次 dofile 覆盖全局态，
-- 故此处自行「dofile 模型 → new() → attach → 采纳驱动 fenv」同序操作）。
-- 返回 true 继续 setups，失败已走 fail 并返回 nil。
local function attach_virt_models()
	local ok
	ok, vbus = pcall(dofile, mpath.resolve("lib/virtbus.lua"))
	if not ok then
		fail(-8, "virt: cannot load lib/virtbus.lua: " .. tostring(vbus))
		return nil
	end
	for _, dev in ipairs(devs) do
		local model_path = mpath.resolve("lib/virtbus/" .. string.lower(dev.driver) .. ".lua")
		local vrok, vmod = pcall(dofile, model_path)
		local drv_preloaded = false
		if not vrok or type(vmod) ~= "table" or type(vmod.new) ~= "function" then
			-- 回退（单文件驱动+模型约定，与单器件版一致）：模型文件缺失时经
			-- 器件 fenv 加载驱动，取其内嵌 <驱动名>_VIRT 工厂
			local fenv_ok = load_driver_env(dev)
			if fenv_ok == nil then return nil end
			vmod = rawget(dev.env, dev.driver .. "_VIRT")
			if type(vmod) ~= "table" or type(vmod.new) ~= "function" then
				fail(-8, "virt: devices[" .. dev.idx .. "] no virtual device model for '"
					.. dev.driver .. "': neither " .. model_path
					.. " nor embedded " .. dev.driver .. "_VIRT")
				return nil
			end
			drv_preloaded = true
		end
		local vok, vdev = pcall(vmod.new)
		if not vok or type(vdev) ~= "table" then
			fail(-8, "virt: devices[" .. dev.idx .. "] model new() failed: " .. tostring(vdev))
			return nil
		end
		local addr_n = tonumber(dev.addr)
		if not addr_n then
			fail(-8, "virt: devices[" .. dev.idx .. "] missing/invalid 'addr': " .. tostring(dev.addr))
			return nil
		end
		vbus.attach_model("VIRT:" .. dev.driver .. "@" .. tostring(dev.addr), vdev, addr_n, path, "i2c")
		dev.vdev = vdev
		-- 模型文件形态（非 drv_preloaded）：驱动尚未加载，仍需经 fenv 加载
		if not drv_preloaded then
			if load_driver_env(dev) == nil then return nil end
		end
	end
	vbus.inject()	-- 统一重注入：驱动 dofile 的 HAL 定义须被虚拟函数覆盖
	return true
end

-- 打开共享总线（一条总线一个 fd；多器件靠各自 build 时的 address 区分）
if proto == "virt" then
	if attach_virt_models() == nil then return end
else
	-- 真机总线：驱动加载不走 virt 分支，统一在此逐器件 fenv 加载
	for _, dev in ipairs(devs) do
		if load_driver_env(dev) == nil then return end
	end
end

fd = i2c_open(path)
if not fd or fd < 0 then fd = nil; fail(-1, "cannot open bus: " .. path); return end

-- 逐器件 build：params = { fd, address, 全局透传键（器件 spec 内同名键优先） }
for _, dev in ipairs(devs) do
	local params = { fd = fd, address = dev.addr }
	for k, v in pairs(cfg) do
		-- 框架键不透传（与单器件版 known 表同口径，minus driver/addr/fields）
		if k ~= "devices" and k ~= "proto" and k ~= "path" and k ~= "interval"
				and k ~= "sign" and k ~= "mode" and k ~= "bits" and k ~= "speed"
				and k ~= "delay" and k ~= "baud" and k ~= "maxvals" then
			params[k] = v
		end
	end
	for k, v in pairs(dev.extra) do
		params[k] = v
	end
	dev.params = params
	-- build 的全局函数名在器件 fenv 里（驱动 dofile 时的「全局」定义）
	local buildf = dev.env.build
	if type(buildf) ~= "function" then
		fail(-2, "devices[" .. dev.idx .. "] driver '" .. dev.driver .. "' has no global build()")
		return
	end
	-- 防线与单器件版同源：build 抛 Lua error 就地 pcall 走 fail 回滚，
	-- 不让已 open 的总线 fd 随 setup 中断而泄漏
	local okr, rb = pcall(buildf, params)
	if not okr then
		fail(-2, "devices[" .. dev.idx .. "] driver build() raised: " .. tostring(rb))
		return
	end
	if type(rb) ~= "table" or rb.result ~= "OK" then
		local why = (type(rb) == "table" and rb.message) and tostring(rb.message)
			or "driver build() not OK"
		fail(-2, "devices[" .. dev.idx .. "] " .. why)
		return
	end
end

-- daemon_body 逐拍调用：全部器件各采一拍 → 拼接 → 一次 publish（原子快照）
-- 错误语义与单器件版一致：任一器件本拍失败则整拍不发布（count 停滞即是
-- 诊断线索），限频日志点名器件序号与驱动名。
local tick_errors = 0
local tick_total  = 0
function daemon_tick()
	local vals = {}
	local n = 0
	for _, dev in ipairs(devs) do
		-- virt：先让该器件模型推进一拍合成数据（确定性波形相位，逐器件独立）
		if dev.vdev ~= nil and type(dev.vdev.virt_tick) == "function" then
			pcall(function() dev.vdev:virt_tick(n) end)
		end
		local callf = dev.env.call
		local s = callf and callf(dev.params) or nil
		local crc_bad = (type(s) == "table" and s.result == "OK" and s.CRC_OK == 0)
		local ok_sample = (type(s) == "table" and s.result == "OK" and not crc_bad)
		local why = "unknown"
		if crc_bad then
			why = "CRC check failed (CRC_OK=0)"
		elseif ok_sample then
			-- 防线与单器件版同源：字段拼错发假 0 / 浮点配 s16 截断，
			-- 都按 tick 错误处理，不发布
			local missing = nil
			local float_s16 = nil
			for i = 1, #dev.fields do
				local raw = tonumber(s[dev.fields[i]])
				if raw == nil then
					missing = (missing and (missing .. ", ") or "") .. tostring(dev.fields[i])
				elseif raw % 1 ~= 0 and effective_bits(dev.modes[i]) == 16 then
					float_s16 = (float_s16 and (float_s16 .. ", ") or "") .. tostring(dev.fields[i])
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
		if not ok_sample then
			tick_errors = tick_errors + 1
			tick_total  = tick_total + 1
			if tick_errors <= 3 or tick_total % 100 == 0 then
				log(string.format("[sensor_daemon_multi] tick error #%d (total %d) on devices[%d] %s: %s",
					tick_errors, tick_total, dev.idx, dev.driver, why))
			end
			return	-- 整拍不发布：部分新部分旧的快照比整体滞后更危险
		end
		for i = 1, #dev.fields do
			n = n + 1
			vals[n] = conv(s[dev.fields[i]], dev.modes[i])
		end
	end
	P.publish(slot, vals)
	tick_errors = 0
end

-- H-07：守护退出（stop 后、Lua_free 前）由 daemon_body 调用。逐器件 destroy
-- （有才调）——任一失败都继续释放余下器件与总线（语义取舍与单器件版一致：
-- 退出路径上的资源释放优先于传播一个无人接收的错误），最后关总线 fd。
function daemon_cleanup()
	for _, dev in ipairs(devs) do
		local destroyf = dev.env.destroy
		if type(destroyf) == "function" then
			local ok, err = pcall(destroyf, dev.params)
			if not ok then
				io.stderr:write(string.format(
					"[sensor_daemon_multi] devices[%d] %s destroy() failed during cleanup (will still release the rest): %s\n",
					dev.idx, dev.driver, tostring(err)))
			end
		end
	end
	close_bus()
	-- virt：还原全局 i2c_*（独立守护 lua_State 随之销毁，主要为状态对称）
	if vbus ~= nil then pcall(vbus.restore) end
end

-- HAL.lua - 基层硬件抽象层（LuaJIT ffi，位于 modules/lib/）
-- bot4cj 仓颉语言机器人框架
--
-- issue #14：完全解耦的基层硬件应用层驱动——不再依赖仓颉注册的 cfunc。
--
-- 【运行环境】仅支持 LuaJIT：经 ffi 直调 glibc（open/ioctl/read/write/close/usleep），
-- 原生性能，fd 为真实内核句柄，跨 Lua 状态机天然有效。
-- （原 i2c-tools/spi-tools shell-out 降级后端 HAL_shell.lua 已移除。）
--
-- 【安全】设备路径经白名单模式校验；所有数值参数 tonumber + 范围校验后才进入
-- ioctl/缓冲区，无 shell 参与。
--
-- 【可测试性】系统调用统一走 HAL.sys.* 间接层，离线单测（test/test_hal_ffi.lua）
-- 注入 mock 即可验证调用序列与缓冲区内容。
--
-- 【文件布局】本文件是**聚合门面**（26.2 按域拆分）：只留加载期接线（ffi 环境
-- 检查、重入口守卫、后端派发、常量重导出、bus_contract 接线、milli_sleep、
-- 停机灭火判定），五个总线域各一文件 modules/lib/hal/{i2c,spi,gpio,uart,pwm}.lua，
-- 由下方「各总线域加载」段按序加载并传入共享上下文。域文件是本文件的分块、
-- 不是可独立加载的模块。对驱动而言接口零变化：38 个总线全局与 HAL.* 全部字段
-- 照旧由此导出。布局与域内私有 helper 清单见 docs/hal.md「文件布局」节。
--
-- 【delay 说明】delay_usecs 是逐次传输参数，内核无 per-fd 持久化 ioctl；
-- 需要延时的驱动经传输函数的 delay_us 尾参显式传入（参考 ADS1256.lua：
-- delay 配置在 @SPI 矩阵，由 SPI.lua 的 call() 随 fd 一并返回，
-- 经元数据引用机制流入设备驱动，驱动统一附带在每次传输上）。

-- 重复加载保护：同一状态机内只初始化一次
if _G.__BOT4CJ_HAL ~= nil then return _G.__BOT4CJ_HAL end

-- 环境检查：必须有 ffi（LuaJIT）；shell 降级后端已移除
local has_ffi, ffi = false, nil
if rawget(_G, "jit") ~= nil then
	has_ffi, ffi = pcall(require, "ffi")
end
if not has_ffi then
	error("HAL requires LuaJIT with ffi (the shell-out fallback backend has been removed)")
end

------------------------------------------------------------------
-- ffi 声明与布局自检（2026-09-30 方案 A 重构）
------------------------------------------------------------------
-- 所有 ffi.cdef 声明（glibc 函数、pthread 互斥锁、spidev/i2c/gpio/termios 结构体）
-- 与尺寸自检已下沉到后端（hal_backend_glibc.lua）。后端由下方加载段 dofile 加载，
-- ffi.cdef 全局生效，本文件可直接使用已声明的类型（spi_ioc_transfer、cj_i2c_msg 等）。
-- 换平台 = 新增 hal_backend_<平台>.lua（提供同构 ffi.cdef + 常量 + 原语），
-- HAL.lua 与驱动零改动。

local HAL = {}
_G.__BOT4CJ_HAL = HAL

-- 平台差异单点（阶段 A-2）：设备根路径常量集中一处——移植 / 仿真桩改这里，
-- GPIO / PWM 各节只取表值，不再散落字面量（i2c/spi/uart 路径白名单在
-- bus_contract.lua，同为单点）。
HAL.platform = {
	pwm_sysfs_root = "/sys/class/pwm",
	gpio_prefix    = "/dev/gpiochip",
}
HAL.PWM_SYSFS_ROOT = HAL.platform.pwm_sysfs_root	-- 兼容既有引用（pwm_attr_path 等）
HAL.backend = "ffi"			-- ABI 类标记（ffi=真实句柄后端；test_hal_ffi/test_jit_warmup 按此分流）
HAL.backend_name = "glibc"	-- 后端模块名（BOT4CJ_HAL_BACKEND 指定，见下方加载段）

------------------------------------------------------------------
-- 常量（2026-09-30 方案 A 重构）
------------------------------------------------------------------
-- 平台常量（O_CLOEXEC、I2C_RDWR、SPI_IOC_*、GPIO_*、UART_*、errno）全部由后端
-- 经 HAL.sys.consts 表导出——换平台只需后端提供同键名常量表，HAL.lua 零改动。
-- 下方后端加载段完成后，从 HAL.sys.consts 逐项重导出为 HAL.* 兼容既有引用。
local O_RDWR = 2
HAL.i2c_addr = {}		-- fd -> 7位从地址（per-state；每条 i2c_msg 自带地址，无需 I2C_SLAVE ioctl）

------------------------------------------------------------------
-- 系统调用间接层（离线单测在此注入 mock）
------------------------------------------------------------------
-- 阶段 A-1 后端接口化：本表由 BOT4CJ_HAL_BACKEND 指定的后端提供
--（缺省 glibc，modules/lib/hal_backend_<名>.lua）。接口契约见
-- hal_backend_glibc.lua 头注（open/close/ioctl_i/ioctl_p/read/write/usleep/
-- errno/version + UART termios 六件），加载后逐项断言、缺函数 fail-fast——
-- 本文件是全部驱动的地基，契约不完整必须在加载期暴露而非首笔调用时炸。
-- 定位方式与 bus_contract 相同：BOT4CJ_MODULE_PATH 各段逐段探测，再以
-- 仓库缺省布局兜底。离线单测仍按函数粒度替换 HAL.sys.* 表项注入 mock，
-- 用法与后端化之前完全一致。
do
	local wanted = os.getenv("BOT4CJ_HAL_BACKEND")
	if wanted == nil or wanted == "" then wanted = "glibc" end
	local loaded
	for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
		local okb, mod = pcall(dofile, p .. "/lib/hal_backend_" .. wanted .. ".lua")
		if okb and type(mod) == "table" then loaded = mod break end
	end
	if not loaded then
		local okb, mod = pcall(dofile, "./modules/lib/hal_backend_" .. wanted .. ".lua")
		if okb and type(mod) == "table" then loaded = mod end
	end
	assert(type(loaded) == "table",
		"HAL: backend not found: modules/lib/hal_backend_" .. wanted .. ".lua (BOT4CJ_HAL_BACKEND=" .. wanted .. ")")
	for _, k in ipairs({ "open", "close", "ioctl_i", "ioctl_p", "read", "write",
		"usleep", "errno", "version", "tcgetattr", "tcsetattr", "cfmakeraw",
		"cfsetispeed", "cfsetospeed", "tcflush",
		"i2c_rdwr", "spi_setup", "spi_xfer" }) do
		assert(type(loaded[k]) == "function",
			"HAL: backend '" .. wanted .. "' missing contract function: " .. k
			.. " (see modules/lib/hal_backend_glibc.lua)")
	end
	assert(type(loaded.consts) == "table",
		"HAL: backend '" .. wanted .. "' missing consts table")
	HAL.sys = loaded
	HAL.backend_name = wanted
end

-- 2026-09-30 方案 A 重构：平台常量由后端 consts 表重导出，兼容既有 HAL.* 引用
-- （测试、Camera.lua 等直接访问 HAL.I2C_RDWR / HAL.SPI_IOC_* 等）。
local _c = HAL.sys.consts
HAL.O_CLOEXEC = _c.O_CLOEXEC
HAL.I2C_RDWR  = _c.I2C_RDWR
HAL.I2C_M_RD  = _c.I2C_M_RD
HAL.SPI_IOC_WR_MODE          = _c.SPI_IOC_WR_MODE
HAL.SPI_IOC_WR_BITS_PER_WORD = _c.SPI_IOC_WR_BITS_PER_WORD
HAL.SPI_IOC_WR_MAX_SPEED_HZ  = _c.SPI_IOC_WR_MAX_SPEED_HZ
HAL.SPI_IOC_MESSAGE_1        = _c.SPI_IOC_MESSAGE_1
HAL.GPIO_GET_LINEHANDLE         = _c.GPIO_GET_LINEHANDLE
HAL.GPIOHANDLE_GET_LINE_VALUES  = _c.GPIOHANDLE_GET_LINE_VALUES
HAL.GPIOHANDLE_SET_LINE_VALUES  = _c.GPIOHANDLE_SET_LINE_VALUES
HAL.GPIOHANDLE_REQUEST_INPUT      = _c.GPIOHANDLE_REQUEST_INPUT
HAL.GPIOHANDLE_REQUEST_OUTPUT     = _c.GPIOHANDLE_REQUEST_OUTPUT
HAL.GPIOHANDLE_REQUEST_ACTIVE_LOW = _c.GPIOHANDLE_REQUEST_ACTIVE_LOW

------------------------------------------------------------------
-- 总线契约单点（N-25）
------------------------------------------------------------------
-- 路径白名单 / UART 波特率表 / 各长度上限 / byte_of·uint_of 归一化 与
-- virtbus 共用同一份（modules/lib/bus_contract.lua），此前是两库逐字手工
-- 镜像、漂移即「仿真绿真机红」且无报错。定位方式：BOT4CJ_MODULE_PATH 各段
-- 逐段探测（fix-plan 3-3：此前只取首段，非缺省布局会让本文件地基直接失败），
-- 再以仓库缺省布局兜底——本文件是全部驱动的地基，加载失败会全线停摆，故兜底一次。
local bus
do
	local probed
	for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
		local ok, m = pcall(dofile, p .. "/lib/bus_contract.lua")
		if ok and type(m) == "table" then probed = m break end
	end
	bus = probed or dofile("./modules/lib/bus_contract.lua")
end

-- 参数归一化（0~255 整数 / 非负整数 / 严格整数，非法 nil）
local byte_of, uint_of, int_of = bus.byte_of, bus.uint_of, bus.int_of

------------------------------------------------------------------
-- 停机灭火检查（BQ-1，与 src/daemonvar.hpp 的 quiesce 位配对）
------------------------------------------------------------------
-- 守护线程的 lua_State 里有宿主注入的 DAEMON_SLOT_ADDR / DAEMON_SLOT_LAYOUT；
-- 主线程的状态两者皆无。宿主在「宽限耗尽仍存活」的守护上置槽内 quiesce 位
-- （先置位后弃管，见 daemonvar.cpp finishTeardown），此后本状态的一切真实
-- 总线传输（i2c/spi/uart）在进内核前被拒绝——把「弃管守护触总线」的竞态窗口
-- 从无界收敛到灭火时刻的在途单次传输。
-- 主线程路径的代价是两次 rawget（无全局注入即短路），virt 仿真路径不受此位
-- 约束（虚拟总线无物理副作用）。持同一把槽锁读，与 C++ 侧 daemon_quiesce
-- 的写纪律一致（TSan 经 pthread 调用拦截建立同步边）。
-- cdef 与 pthread.lua 逐字相同（LuaJIT 对相同签名的重复声明是幂等 no-op；
-- 守护 chunk 会同时加载两库，签名漂移会静默失配，故此约束双向钉死）。
local quiesce_warned = false
local function bus_quiesced()
	local addr = rawget(_G, "DAEMON_SLOT_ADDR")
	if addr == nil then return false end
	local layout = rawget(_G, "DAEMON_SLOT_LAYOUT")
	if type(layout) ~= "table" or layout.quiesce == nil then return false end
	local base = ffi.cast("char*", addr)
	local m = ffi.cast("cj_pthread_mutex_t *", base)
	if ffi.C.pthread_mutex_lock(m) ~= 0 then
		error("HAL: cannot lock daemon slot mutex for quiesce check")
	end
	local q = ffi.cast("int32_t *", base + layout.quiesce)[0]
	ffi.C.pthread_mutex_unlock(m)
	if q ~= 0 and not quiesce_warned then
		quiesce_warned = true
		print("HAL: bus access refused (daemon slot quiesced;"
			.. " hardware teardown in progress)")
	end
	return q ~= 0
end
------------------------------------------------------------------
-- 延时
------------------------------------------------------------------
-- 毫秒级延时（usleep，零 fork）
function milli_sleep(ms)
	-- 审计 2026-09-20（中）：tonumber 放行 NaN/inf——`ms <= 0` 对两者恒假、
	-- `ms > 4294967` 对 NaN 亦恒假，于是 NaN 会走到 ffi 的 unsigned int 形参
	-- （NaN→0，实际不睡）而 inf 撞上 usleep 的 EINVAL。统一按「非法即不睡」
	-- 处理：本函数无返回值、调用方无从感知错误，静默不睡优于睡错时长。
	-- 判据走总线契约单点 bus.finite_of（本文件已 dofile 过 bus_contract）。
	local f = bus and bus.finite_of(ms)
	if f == nil or f <= 0 then return end
	ms = f
	-- 审计 #10：usleep 形参是 unsigned int（usec），ms 超过 4294967 时
	-- ms*1000 回绕成短睡/长睡错乱——钳制到 uint32 上限内并显式提示
	if ms > 4294967 then
		print("HAL: milli_sleep " .. tostring(ms) .. "ms exceeds uint32 usec range, clamped to 4294967ms")
		ms = 4294967
	end
	HAL.sys.usleep(math.floor(ms * 1000))
end

------------------------------------------------------------------
-- 各总线域加载（26.2 按域拆分：I2C / SPI / GPIO / UART / PWM 各一文件）
------------------------------------------------------------------
-- 域文件是本文件的**分块**而非独立模块：loadfile 出来的子块看不到本文件的
-- local，故共享上下文（HAL 表、ffi、总线契约 bus、后端常量表 _c、三个归一化器、
-- quiesce 判定、O_RDWR）经 ctx 表显式传入——正文因此得以逐字搬迁不改写。
-- 域文件之间无相互引用（各自的私有 helper 都在自己那段里：i2c_rdwr/be_merge、
-- spi_xfer、UART_B_CONST*、pwm_*/sysfs_write），加载顺序只要求在本段接线之后。
-- 定位方式与 bus_contract / 后端加载段同规：BOT4CJ_MODULE_PATH 各段逐段探测，
-- 再以仓库缺省布局兜底——本文件是全部驱动的地基，加载失败会全线停摆。
-- 探测用 loadfile 而非 dofile：沙箱禁 io.open，loadfile 是既有认可的探测手段
-- （见 lib/mpath.lua 头注），且探测命中即可直接调用，省一次重读。
do
	local function domain_chunk(rel)
		for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
			local chunk = loadfile(p .. "/lib/hal/" .. rel)
			if chunk then return chunk end
		end
		-- 兜底那一跳走 pcall：沙箱的 loadfile 包装对白名单外路径是 luaL_error
		-- （不是返 nil，见 src/luasandbox.cpp restrictedLoader），BOT4CJ_MODULE_PATH
		-- 不含 ./modules 时裸调会把「白名单拒绝」抛成 Lua error，压掉下面这条
		-- 可诊断的成因说明。同规的后端加载段也是 pcall。
		local ok, chunk = pcall(loadfile, "./modules/lib/hal/" .. rel)
		assert(ok and chunk,
			"HAL: domain file not found: modules/lib/hal/" .. rel
			.. " (BOT4CJ_MODULE_PATH=" .. tostring(os.getenv("BOT4CJ_MODULE_PATH")) .. ")")
		return chunk
	end
	local ctx = {
		HAL = HAL, ffi = ffi, bus = bus, _c = _c,
		byte_of = byte_of, uint_of = uint_of, int_of = int_of,
		bus_quiesced = bus_quiesced, O_RDWR = O_RDWR,
	}
	for _, rel in ipairs({ "i2c.lua", "spi.lua", "gpio.lua", "uart.lua", "pwm.lua" }) do
		domain_chunk(rel)(ctx)
	end
end

return HAL

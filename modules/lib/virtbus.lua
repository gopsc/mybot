-- virtbus.lua —— 虚拟总线（issue #18：设计虚拟硬件用于无真机驱动链路验证）
-- bot4cj 仓颉语言机器人框架
--
-- 概念：inject 后替换 HAL 的全部全局 i2c_*/spi_*/uart_* 函数，真实驱动（经 HAL/驱动 dofile
-- 链路）在纯内存的虚拟总线上完成 build/call/destroy——无真机、无 /dev/i2c-*、
-- 无 /dev/spidev*、无 /dev/tty*。器件行为由 attach 时提供的模型回调决定，事务序列记入 txlog
-- 供断言。
--
-- 用法（I2C）：
--   local vbus = dofile(modulePath .. "/lib/virtbus.lua")
--   vbus.attach("光感@0x23", 0x23, {
--       write = function(bytes) ... end,   -- 收命令/寄存器写（bytes 为 1 基表）
--       read  = function(n) return { 0x12, 0x34 } end,  -- 返回 n 字节（1 基表）
--   })
--   vbus.inject()          -- 替换全局 i2c_*/spi_*，此后驱动调用全走虚拟总线
--   -- ... 正常 dofile 驱动、传 build/call/destroy 数据 ...
--   vbus.txlog             -- 事务序列（断言用），条目按时间序追加：
--                            --   I2C：
--                            --   {dir="open", addr=nil, bytes={raw=path}}
--                            --   {dir="set",  addr=addr, bytes={}}
--                            --   {dir="w",    addr=addr, bytes={1基字节表}}
--                            --   {dir="r",    addr=addr, bytes={n=请求长度}}
--                            -- 指针式读产生相邻的 w（指针）+ r 两条
--                            --   SPI（一次传输 = 一个 CS 帧，全双工）：
--                            --   {dir="sopen", path=path}
--                            --   {dir="setup", path=path, mode=,bits=,speed=}
--                            --   {dir="x", path=path, tx={...}, rx={...},
--                            --    delay=us, ok=bool}
--                            --   UART（字节流；应答经 per-path 环回传）：
--                            --   {dir="uopen", path=path, baud=baud}
--                            --   {dir="uw", path=path, bytes={...}, ok=bool}
--                            --   {dir="ur", path=path, n=请求长度, bytes={...}[,err=true]}
--                            --   {dir="uf", path=path}   （flush 清输入环）
--                            -- close 与 I2C/SPI 同款静默不留痕
--   vbus.reset()           -- 清空器件/日志/线索并 restore
--   vbus.restore()         -- 还原原始 i2c_*/spi_* 全局函数
--
-- 模型回调（attach 的 dev 表，点定义、无 self 参数，自身用局部名引用）：
--   I2C dev.write(bytes) 收 1 基字节表；显式 return false = NACK，无返回 = 成功
--   I2C dev.read(n)      返回 1 基字节表；返回 nil = NACK；缺省读返回全 0
--   SPI dev.xfer(tx)     全双工：收本帧 MOSI 1 基表，返回等长 MISO 表；
--                        返回 nil/false = 传输失败；缺省 xfer 返回等长全 0。
--                        纯写（spi_write*）在真机上也会移入字节（被调用方丢弃），
--                        txlog 照记 rx，模型可借此模拟「写命令的同帧状态回传」
--                        （ADS1256 命令态/DATA 就绪轮询一类协议的事实）。
--   UART dev.on_write(bytes) 收主机写出的 1 基字节表（TX 恒成功的前提）：
--                        返回表 = 把应答字节逐字节追加进该 path 的输入环，
--                        供后续 uart_read 取走；返回 nil/无 = 不应答
--                        （驱动读到空表 = 超时无数据）；返回 false = 本笔写失败
--                        （uart_write 返 -1，模拟 TX 错误）。
--                        环是 per-path 字节队列而非寄存器映射——UART 无地址、
--                        无帧同步，驱动侧「前导噪声 + 跨轮聚合读扫描」协议
--                        （MHZ19/SDS011）只要在环里前置噪声字节即可复刻。
--
-- SPI 挂载身份是 spidev 路径（/dev/spidev<bus>.<cs>，路径即片选）：
--   vbus.attach_spi("电位器", "/dev/spidev0.0", { xfer = function(tx) ... end })
--
-- UART 挂载身份是 tty 路径（请求-应答式字节流器件）：
--   vbus.attach_uart("CO2", "/dev/serial0", {
--       on_write = function(bytes) ... return reply end,  -- 收主机帧，返回应答表/nil/false
--   })
--
-- 语义对齐 HAL（返回值契约逐函数与 HAL.lua 相同，驱动用 `if not` / `==0` 等
-- 不同判定时行为才不会在虚拟总线上失真）：
--   i2c_write_reg       → dev.write(...)，返回布尔 true=成功/false=NACK（HAL 契约）
--   i2c_write_multi/16  → dev.write(...)，返回 0=成功/-1=NACK
--   指针式读族（i2c_read_reg/16/multi/multi_bytes）→ 先 dev.write(指针字节表)
--     再 dev.read(n)，复刻 HAL I2C_RDWR 的「写指针+读」原子事务——模型据此
--     知道读的是哪个寄存器（regmap 类器件模型的前提）；指针写 NACK 则整笔读失败
--   纯读族（i2c_read/read_bytes，无指针命令式器件用）→ 仅 dev.read(n)
--   长度约束同 HAL：read/read_multi/read_reg16 合并值 n 1~6 越界（2^53 精度上限）
--   显式失败；read_bytes/read_multi_bytes 钳制 n 1~16（表长对调用方可见）
--   返回值按 HAL 原语义组装（大端合并或字节表）；无器件地址命中按 NACK 处理
--   （写 false/-1、读 -1/nil），与真机"设备不在总线"行为一致，可测负路径
--
--   spi_open 路径白名单同 HAL（^/dev/spidev%d+%.%d+$），fd 与 I2C 共用同一编号
--   空间；spi_setup 复刻参数校验（mode 0~3 / bits 7~16 / speed>0），配置留痕
--   （真机 setup 是控制器 ioctl，无器件也成功——虚拟层同此语义，无挂载也返回 0）。
--   spi_write/write3/write_multi 字节校验同 HAL（非字节 → -1，不发帧），
--   write_multi 帧长 1~64；spi_read_multi 合并值 n 1~6 越界显式 -1；
--   delay_us 同 HAL 钳到 65535 并随帧留痕；spi_read 的 MOSI 为全 0（真机
--   tx_buf=NULL 内核发 0）。无挂载路径/未打开 fd/模型返回失败，传输族一律 -1。
--   spi_xfer_full 是第 9 个 SPI 全局：1 基字节表入参/等长 1 基 MISO 表返回
--   （失败 nil），供「MOSI 命令与 MISO 数据同帧」的全双工协议（MT6826S
--   24 位读帧）；帧长/字节校验同 spi_write_multi，帧照常走 dev.xfer。
--
--   uart_open 路径/波特率白名单同 HAL（^/dev/tty[A-Za-z0-9]+$ 或
--   ^/dev/serial%d+$；baud ∈ 总线契约的 UART_BAUDS 表），fd 与 I2C/SPI 共用编号
--   空间；非法入参 -1（校验顺序同 HAL：先 baud 后 path）。
--   uart_write 入参校验同 HAL（非表/空/超 512/逐字节 byte_of 非法 → -1 且不发
--   事务），通过后 TX 面向控制器恒成功（无挂载也返回 #data，只是无人应答）；
--   模型 on_write 返回表 → 应答入环、返回 false → 本笔 -1。
--   uart_read 校验同 HAL（fd 无效/n<1 → nil，n>512 钳 512），从环即时 drain
--   至多 n 字节（不模拟时序——虚拟层无波特率时钟）：环空返回空表 = 超时无数据，
--   总线级 virtbus.uart_fail_read=true 时返回 nil（模拟链路硬错误，事务记
--   err=true）。uart_flush 清环返 0（无效 fd -1）；uart_close 静默清登记。
--
-- 器件模型故障注入契约：
--   I2C dev.write(bytes) 显式 return false → 本笔写按 NACK（无返回/return nil = 成功）
--   I2C dev.read(n) 返回 nil               → 本笔读按 NACK
--   SPI dev.xfer(tx) 返回 nil/false        → 本帧传输失败（全部传输族返 -1）
--   UART dev.on_write(bytes) 返回 false    → 本笔写失败（uart_write 返 -1）
--   UART virtbus.uart_fail_read = true     → 全部 uart_read 返 nil（链路硬错误）
--
-- 设备模型库：modules/lib/virtbus/（regmap.lua 通用寄存器组、bh1750.lua 等现成模型）。
-- 加载真实驱动建议用 vbus.load_driver(path)：驱动首次 dofile HAL 会覆盖注入的全局
-- i2c_*/spi_*，本助手自动重注入（test_virtbus_bh1750 早期手动 restore+inject 的封装）。
--
-- 本文件为纯 Lua（不依赖 ffi），可用 lua5.4/luajit 离线跑。
--
-- 重入口守卫：下面的 devs/fd_addr/open_paths/txlog 全是文件级 local 表，二次
-- dofile 会造出第二份互不可见的注册表，而 inject() 替换出去的全局函数只认第一次
-- 那份——「attach 到 A 表、全局走 B 表」属静默失效。守护路径与非守护驱动路径会
-- 先后加载本库，故同一状态机内一律复用同一实例（要干净状态请调 vbus.reset()）。
if __BOT4CJ_VIRTBUS ~= nil then
	return __BOT4CJ_VIRTBUS
end

local virtbus = {}
virtbus._VERSION = "0.2.0"

local devs = {}          -- I2C addr -> { name=, write=, read= } 器件模型
local spi_devs = {}      -- SPI path -> { name=, xfer= } 器件模型
local uart_devs = {}     -- UART path -> { name=, model=, on_write= } 器件模型
local uart_rings = {}    -- UART path -> { data={}, pos= } 输入环（设备→主机字节队列）
local txlog = {}         -- 事务序列（I2C/SPI/UART 共用一条时间线）
local originals = {}     -- 原始全局函数（restore 用）
local next_fd = 3
local fd_addr = {}       -- fd -> addr（i2c_set_addr 记录）
local open_paths = {}    -- fd -> path（I2C）
local spi_paths = {}     -- fd -> path（SPI）
local uart_paths = {}    -- fd -> path（UART）
virtbus.txlog = txlog
virtbus.devs = devs
virtbus.spi_devs = spi_devs
virtbus.uart_devs = uart_devs
virtbus.uart_fail_read = false  -- 总线级故障注入：true → uart_read 一律返 nil

-- ---- 总线契约单点（N-25）----
-- 路径白名单 / 波特率表 / 各长度上限 / byte_of·uint_of 归一化 与 HAL 共用
-- 同一份（modules/lib/bus_contract.lua）——此前是两库逐字手工镜像，漂移即
-- 「仿真绿真机红」且无任何报错。定位方式：BOT4CJ_MODULE_PATH 各段逐段探测
-- （fix-plan 3-3：此前只取首段），再以仓库缺省布局兜底
-- （本库常被测试以 dofile("modules/lib/virtbus.lua") 加载）。
local bus
do
	local probed
	for p in (os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):gmatch("[^:]+") do
		local ok, m = pcall(dofile, p .. "/lib/bus_contract.lua")
		if ok and type(m) == "table" then probed = m break end
	end
	bus = probed or dofile("./modules/lib/bus_contract.lua")
end
virtbus.bus_contract = bus

-- 复位：清空器件/日志/线索并还原全局 i2c_*/spi_*/uart_*
function virtbus.reset()
	virtbus.restore()
	devs = {}
	spi_devs = {}
	uart_devs = {}
	uart_rings = {}
	txlog = {}
	fd_addr = {}
	open_paths = {}
	spi_paths = {}
	uart_paths = {}
	next_fd = 3
	virtbus.txlog = txlog
	virtbus.devs = devs
	virtbus.spi_devs = spi_devs
	virtbus.uart_devs = uart_devs
	virtbus.uart_fail_read = false
end

-- 挂载器件模型：name 仅日志用；dev.write(bytes)/dev.read(n) 缺省为空实现。
-- 保存模型引用并在每笔事务时动态取函数：测试既可以替换模型字段（如 dev.nack=true，
-- 函数闭包读到新值），也可以直接换函数（fake_dev.write = ...），attach 后均生效。
function virtbus.attach(name, addr, dev)
	devs[addr] = {
		name = name,
		model = dev,
		write = function(bytes)
			if dev.write then return dev.write(bytes) end
		end,
		read = function(n)
			if dev.read then return dev.read(n) end
			local t = {}
			for i = 1, n do t[i] = 0 end
			return t
		end,
	}
end

-- 挂载 SPI 器件模型：name 仅日志用；path 为 spidev 路径（路径即片选身份）。
-- dev.xfer(tx) 缺省返回等长全 0（只写器件 TPL0501/AD9833 可不给）。
-- 与 I2C attach 同款动态委托：attach 后替换 dev.xfer 即时生效。
function virtbus.attach_spi(name, path, dev)
	if type(path) ~= "string" then return end
	spi_devs[path] = {
		name = name,
		model = dev,
		xfer = function(tx)
			if dev.xfer then return dev.xfer(tx) end
			local t = {}
			for i = 1, #tx do t[i] = 0 end
			return t
		end,
	}
end

-- 挂载 UART 器件模型：name 仅日志用；path 为 tty 路径（路径即设备身份）。
-- dev.on_write(bytes) 三态：返回表 = 应答入环；返回 nil/无 = 不应答；
-- 返回 false = 本笔写失败。同款动态委托：attach 后替换 dev.on_write 即时生效。
function virtbus.attach_uart(name, path, dev)
	if type(path) ~= "string" then return end
	uart_devs[path] = {
		name = name,
		model = dev,
		on_write = function(bytes)
			if dev.on_write then return dev.on_write(bytes) end
		end,
	}
end

-- ---- 内部：事务记录 ----
local function log_tx(dir, addr, bytes)
	txlog[#txlog + 1] = { dir = dir, addr = addr, bytes = bytes }
end

local function dev_of(fd)
	local addr = fd_addr[fd]
	if addr == nil or devs[addr] == nil then return nil end
	return devs[addr]
end

-- ---- 模型挂载分派（N-26）--------------------------------------------------
-- 「判定 BUS 类型 → attach_spi / attach_uart / attach」这套分派原本在
-- sensor_daemon.lua（守护路径）与 lib/drv_common.lua（@Action 直驱路径）
-- 各写一份，两处必须同约定，故收敛于此（挂载本就属虚拟总线的领域）。
--
-- 判定 BUS 类型：先看工厂表的 BUS 标记，再看实例的（两者可省其一）；缺省 i2c。
-- 工厂表写在模块表上、实例写在构造结果上都有可能，故两个入参都接受。
function virtbus.model_kind(factory, inst)
	local function pick(t)
		if type(t) ~= "table" then return nil end
		local k = t.BUS
		if k == "spi" or k == "uart" or k == "i2c" then return k end
		return nil
	end
	return pick(factory) or pick(inst) or "i2c"
end

-- 把一个**实例**按 kind 挂到虚拟总线。name 仅日志用；addr/path 用调用方已
-- 归一化的值（i2c 用 addr，spi/uart 用 path）。返回实际使用的 kind。
-- 约定：必须挂实例而非工厂表——virtbus 的动态委托取 dev.write/dev.on_write，
-- 工厂表身上没有这些方法，直接挂上会「写静默成功、读永远无应答」（PCA9685
-- 直写 E2E 的旧缺口，SCSCL 的 PING 探测把该缺口暴露为构建失败）。
-- new() 的调用与失败报错留在各调用方（守护/直驱两条路径的文案与后续处理
-- 不同：守护要 fail(-8) 并中止，直驱要把原因折进 proto=virt setup failed）。
function virtbus.attach_model(name, dev, addr, path, kind)
	kind = kind or virtbus.model_kind(dev)
	if kind == "spi" then
		virtbus.attach_spi(name, path, dev)
	elseif kind == "uart" then
		virtbus.attach_uart(name, path, dev)
	else
		virtbus.attach(name, addr, dev)
	end
	return kind
end

-- ---- 参数归一化：取自总线契约单点（与 HAL 同一份实现，N-25）----
-- 三条总线共用（I2C/SPI/UART 的入参校验语义必须与真机一致，否则 virt 会接受
-- 真机直接失败的调用——驱动带越界实参时「仿真绿、真机红」）。
-- int_of = 严格整数（拒绝非整数）：SPI 的 mode/bits/speed 与字节参数走此口径，
-- 与 HAL.spi_setup/spi_write/spi_write3/spi_xfer_full 同判据；finite_of 供
-- uart_read 超时校验复用。
local byte_of, uint_of = bus.byte_of, bus.uint_of
local int_of, finite_of = bus.int_of, bus.finite_of

-- ---- 写族：组合字节表后交给器件，返回 0 = 成功，-1 = NACK ----
-- 模型可显式 return false 模拟本笔写 NACK（返回 nil/无返回按成功）
local function do_write(fd, bytes)
	log_tx("w", fd_addr[fd], bytes)
	local dev = dev_of(fd)
	if dev == nil then return -1 end
	if dev.write(bytes) == false then return -1 end
	return 0
end

function virtbus.v_i2c_open(path)
	-- 与 HAL 相同的路径白名单校验；合法即分配虚拟 fd
	if not bus.i2c_path_ok(path) then
		return -1
	end
	local fd = next_fd
	next_fd = next_fd + 1
	open_paths[fd] = path
	log_tx("open", nil, { raw = path })
	return fd
end

function virtbus.v_i2c_close(fd)
	fd = tonumber(fd)
	if fd ~= nil and open_paths[fd] ~= nil then
		open_paths[fd] = nil
		fd_addr[fd] = nil
	end
end

function virtbus.v_i2c_set_addr(fd, addr)
	fd = tonumber(fd)
	addr = uint_of(addr)		-- 同 HAL：非负整数（负数/非数字即失败，不静默取整成别的地址）
	if fd == nil or open_paths[fd] == nil or addr == nil or addr > 0x7F then
		return false
	end
	fd_addr[fd] = addr
	log_tx("set", addr, {})
	return true
end

-- 注意：HAL 的 i2c_write_reg 返回布尔（`i2c_rdwr(...) >= 0`），驱动普遍用
-- `if not i2c_write_reg(...)` 判定；不能像 write_multi 那样返回 0/-1
-- （Lua 中 -1 为真，NACK 会被驱动当成功——假绿）。
function virtbus.v_i2c_write_reg(fd, reg, val)
	fd = tonumber(fd)
	reg, val = byte_of(reg), byte_of(val)
	if fd == nil or reg == nil or val == nil then return false end
	return do_write(fd, { reg, val }) == 0
end

function virtbus.v_i2c_write_multi(fd, reg, ...)
	fd = tonumber(fd)
	reg = byte_of(reg)
	if fd == nil or reg == nil then return -1 end
	local bytes = { reg }
	for _, v in ipairs({ ... }) do
		local b = byte_of(v)
		if b == nil then return -1 end		-- 同 HAL：任一字节非法即整笔失败，不发事务
		bytes[#bytes + 1] = b
	end
	-- 数据字节上限（不含寄存器指针），与 HAL i2c_write_multi 同判据，防镜像漂移
	if #bytes - 1 > bus.I2C_IO_MAX_BYTES then return -1 end
	return do_write(fd, bytes)
end

function virtbus.v_i2c_write_reg16(fd, reg16, ...)
	fd = tonumber(fd)
	reg16 = uint_of(reg16)
	if fd == nil or reg16 == nil or reg16 > 0xFFFF then return -1 end
	local bytes = { math.floor(reg16 / 256) % 256, reg16 % 256 }
	for _, v in ipairs({ ... }) do
		local b = byte_of(v)
		if b == nil then return -1 end
		bytes[#bytes + 1] = b
	end
	-- 数据字节上限（不含 2 字节寄存器指针），与 HAL i2c_write_reg16 同判据
	if #bytes - 2 > bus.I2C_IO_MAX_BYTES then return -1 end
	return do_write(fd, bytes)
end

-- ---- 读族：n 由调用方按 HAL 契约校验/钳制后传入 ----
local function do_read(fd, n)
	local dev = dev_of(fd)
	log_tx("r", fd_addr[fd], { n = n })
	if dev == nil then return nil end
	return dev.read(n)
end

-- 合并值类接口的 n：对齐 HAL i2c_read/i2c_read_multi/spi_read_multi ——
-- uint_of 归一（接受小数/字符串数字并向下取整，与真机同）后限 1~6，
-- 越界或非法显式失败（-1，不静默钳制；静默钳制会放大成错误合并值）
local function merge_n(n)
	n = uint_of(n)
	if n == nil or n < 1 or n > bus.MERGED_READ_MAX then return nil end
	return n
end

-- 字节表类接口的 n：对齐 HAL i2c_read_bytes/i2c_read_multi_bytes ——
-- uint_of 归一；非法（nil/负数/非数字）返回 nil = 失败（旧实现 nil→1 会
-- 让真机必失败的调用在仿真里静默成功）；合法则钳 1~16（表长对调用方可见）
local function bytes_n(n)
	n = uint_of(n)
	if n == nil then return nil end
	if n < 1 then n = 1 end
	if n > bus.BYTES_READ_MAX then n = bus.BYTES_READ_MAX end
	return n
end

-- ---- 指针式读：先把寄存器指针作为一笔写事务发给器件，再读 ----
-- 对齐 HAL：真机上 i2c_read_reg/multi/reg16 是 I2C_RDWR 的「写指针消息 +
-- 读消息」单原子事务；旧实现把指针参数丢弃，模型无从知道读哪个寄存器，
-- 寄存器指针器件（MPU6050/BME280…）无法建模。指针写 NACK（无器件/模型
-- 注入故障）则整笔读失败且不产生读事务——与真机 ioctl 失败一致。
local function do_read_ptr(fd, ptr_bytes, n)
	if do_write(fd, ptr_bytes) ~= 0 then return nil end
	return do_read(fd, n)
end

local function be_merge(t)
	local v = 0
	for i = 1, #t do v = v * 256 + t[i] end
	return v
end

function virtbus.v_i2c_read_reg(fd, reg)
	reg = byte_of(reg)
	if reg == nil then return -1 end
	local t = do_read_ptr(fd, { reg }, 1)
	if t == nil or #t < 1 then return -1 end
	return t[1]
end

-- 纯读大端合并：HAL 限定 n 1~6（2^53 精度上限），越界显式 -1（不静默钳制）
function virtbus.v_i2c_read(fd, n)
	n = merge_n(n)
	if n == nil then return -1 end
	local t = do_read(fd, n)
	if t == nil or #t < 1 then return -1 end
	return be_merge(t)
end

-- 指针读大端合并：HAL 限定 n 1~6（2^53 精度上限）
function virtbus.v_i2c_read_multi(fd, reg, n)
	reg = byte_of(reg)
	n = merge_n(n)
	if reg == nil or n == nil then return -1 end
	local t = do_read_ptr(fd, { reg }, n)
	if t == nil or #t < 1 then return -1 end
	return be_merge(t)
end

-- 指针读字节表：HAL 钳制 n 1~16，非法 n 失败（nil）
function virtbus.v_i2c_read_multi_bytes(fd, reg, n)
	reg = byte_of(reg)
	n = bytes_n(n)
	if reg == nil or n == nil then return nil end
	local t = do_read_ptr(fd, { reg }, n)
	if t == nil then return nil end
	return t
end

-- 16 位指针读大端合并：HAL 限定 n 1~6
function virtbus.v_i2c_read_reg16(fd, reg16, n)
	reg16 = uint_of(reg16)
	n = merge_n(n)
	if reg16 == nil or reg16 > 0xFFFF or n == nil then return -1 end
	local t = do_read_ptr(fd, { math.floor(reg16 / 256) % 256, reg16 % 256 }, n)
	if t == nil or #t < 1 then return -1 end
	return be_merge(t)
end

-- 纯读字节表：HAL 钳制 n 1~16，非法 n 失败（nil）
function virtbus.v_i2c_read_bytes(fd, n)
	n = bytes_n(n)
	if n == nil then return nil end
	local t = do_read(fd, n)
	if t == nil then return nil end
	return t
end

-- ======================================================================
-- SPI（spidev 语义：路径即片选，一次传输一个 CS 帧、全双工）
-- ======================================================================

function virtbus.v_spi_open(path)
	-- 与 HAL 相同的路径白名单校验（^/dev/spidev<bus>.<cs>$）；合法即分配虚拟 fd。
	-- fd 与 I2C 共用编号空间（真机上本就是同一个进程 fd 表）。
	if not bus.spi_path_ok(path) then
		return -1
	end
	local fd = next_fd
	next_fd = next_fd + 1
	spi_paths[fd] = path
	txlog[#txlog + 1] = { dir = "sopen", path = path }
	return fd
end

function virtbus.v_spi_close(fd)
	fd = tonumber(fd)
	if fd ~= nil and spi_paths[fd] ~= nil then
		spi_paths[fd] = nil
	end
end

-- 复刻 HAL spi_setup 参数校验（mode 0~3 / bits 7~16 / speed 正整数）。
-- delay 在真机上也无法 per-fd 持久化（HAL 仅打印提示），虚拟层同样不记录。
-- setup 面向控制器：真机即使总线上无器件，三个 ioctl 仍成功——故不要求挂载，
-- 这与 I2C 的「无地址 NACK」不同（SPI 物理层无 ACK，设备不在不可发现）。
function virtbus.v_spi_setup(fd, mode, bits, speed, _delay)
	fd = tonumber(fd)
	-- 严格整数判据取自 bus_contract.int_of 单点（拒绝非整数，与 HAL 同口径）
	mode, bits, speed = int_of(mode, 0, 3), int_of(bits, 7, 16), int_of(speed, 1)
	if fd == nil or spi_paths[fd] == nil
	   or mode == nil or bits == nil or speed == nil then
		return -1
	end
	txlog[#txlog + 1] = {
		dir = "setup", path = spi_paths[fd],
		mode = mode, bits = bits, speed = speed,
	}
	return 0
end

-- delay 归一化：非数值忽略；超 65535 钳到 65535（对齐 HAL spi_xfer）
local function spi_delay_of(v)
	v = tonumber(v)
	if v == nil or v < 0 then return nil end
	v = math.floor(v)
	if v > 65535 then v = 65535 end
	return v
end

-- 全双工帧核心：tx 为 1 基字节表（读族由调用方传全 0 表，等价真机 tx_buf=NULL）。
-- 模型返回表规范化到 #tx（短补 0、长截断）；返回 nil/false/无挂载 = 传输失败。
-- 无论成败都记一条 "x" 帧事务（rx=nil 表示失败），负路径行为可断言。
local function do_xfer(fd, tx)
	local path = spi_paths[fd]
	local entry = { dir = "x", path = path, tx = tx, rx = nil, ok = false, delay = nil }
	txlog[#txlog + 1] = entry
	local dev = path ~= nil and spi_devs[path] or nil
	if dev == nil then return nil end
	local rx = dev.xfer(tx)
	if type(rx) ~= "table" then return nil end
	local norm = {}
	for i = 1, #tx do norm[i] = tonumber(rx[i]) or 0 end
	entry.rx = norm
	entry.ok = true
	return norm
end

function virtbus.v_spi_write(fd, val, delay_us)
	fd = tonumber(fd)
	val = int_of(val, 0, 255)	-- 严格整数（bus_contract 单点，与 HAL 同判据）
	if fd == nil or val == nil then
		return -1
	end
	local tx = { val }
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, tx)
	if rx == nil then return -1 end
	txlog[#txlog].delay = entry_delay
	return 0
end

function virtbus.v_spi_read(fd, delay_us)
	fd = tonumber(fd)
	if fd == nil or spi_paths[fd] == nil then return -1 end
	local n = 1
	local tx = {}
	for i = 1, n do tx[i] = 0 end
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, tx)
	if rx == nil then return -1 end
	txlog[#txlog].delay = entry_delay
	return rx[1]
end

function virtbus.v_spi_write3(fd, b0, b1, b2, delay_us)
	fd = tonumber(fd)
	-- 严格整数判据取自 bus_contract.int_of 单点（任一非整数即整帧拒绝，同 HAL）
	b0, b1, b2 = int_of(b0, 0, 255), int_of(b1, 0, 255), int_of(b2, 0, 255)
	if fd == nil or b0 == nil or b1 == nil or b2 == nil then
		return -1
	end
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, { b0, b1, b2 })
	if rx == nil then return -1 end
	txlog[#txlog].delay = entry_delay
	return 0
end

-- 任意长度一帧（单次 CS，1~64 字节，校验顺序同 HAL：先表/空长，再超长，再逐字节）
function virtbus.v_spi_write_multi(fd, data, delay_us)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return -1 end
	if #data > bus.SPI_IO_MAX_BYTES then return -1 end
	local tx = {}
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		tx[i] = b
	end
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, tx)
	if rx == nil then return -1 end
	txlog[#txlog].delay = entry_delay
	return 0
end

-- 读 n 字节大端合并，n 1~6 越界显式 -1（对齐 HAL 的 2^53 精度上限，
-- 静默钳制会放大成错误合并值；n 的归一语义同 HAL 的 uint_of）
function virtbus.v_spi_read_multi(fd, n, delay_us)
	fd = tonumber(fd)
	n = merge_n(n)
	if fd == nil or n == nil then
		return -1
	end
	local tx = {}
	for i = 1, n do tx[i] = 0 end
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, tx)
	if rx == nil then return -1 end
	txlog[#txlog].delay = entry_delay
	return be_merge(rx)
end

-- 全双工任意长度一帧（对齐 HAL spi_xfer_full）：data 为 1 基字节表（1~64，
-- 逐字节校验），返回模型 dev.xfer 给的等长 1 基 MISO 表；任何失败返回 nil。
-- 与写族同一 do_xfer 帧核心：tx/rx 全留痕，delay 钳 65535，模型返 nil 即失败。
function virtbus.v_spi_xfer_full(fd, data, delay_us)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return nil end
	if #data > bus.SPI_IO_MAX_BYTES then return nil end
	local tx = {}
	for i = 1, #data do
		local b = int_of(data[i], 0, 255)	-- 严格整数（bus_contract 单点）
		if b == nil then return nil end
		tx[i] = b
	end
	local entry_delay = spi_delay_of(delay_us)
	local rx = do_xfer(fd, tx)
	if rx == nil then return nil end
	txlog[#txlog].delay = entry_delay
	return rx
end

-- ======================================================================
-- UART（tty 字节流：path 即设备身份；模型 on_write 应答进 per-path 输入环，
-- uart_read 从环即时 drain——虚拟层不模拟波特率时钟/轮询时序）
-- ======================================================================

-- 输入环：{ data = 追加式字节数组, pos = 下一个未消费下标 }
local function ring_of(path)
	local r = uart_rings[path]
	if r == nil then
		r = { data = {}, pos = 1 }
		uart_rings[path] = r
	end
	return r
end

local function ring_push(path, bytes)
	local r = ring_of(path)
	for i = 1, #bytes do
		r.data[#r.data + 1] = tonumber(bytes[i]) or 0
	end
	-- 全读完则归零，避免长驻进程里 data 无界增长
	if r.pos > #r.data then
		r.data = {}
		r.pos = 1
	end
end

-- 入参校验用文件顶部的共用 byte_of / uint_of（与 HAL 逐字对齐）

-- 校验顺序同 HAL：先 baud 白名单，再 path 白名单；fd 与 I2C/SPI 共用编号空间
function virtbus.v_uart_open(path, baud)
	baud = tonumber(baud)
	if not bus.baud_ok(baud) then return -1 end
	if not bus.uart_path_ok(path) then
		return -1
	end
	local fd = next_fd
	next_fd = next_fd + 1
	uart_paths[fd] = path
	txlog[#txlog + 1] = { dir = "uopen", path = path, baud = baud }
	return fd
end

function virtbus.v_uart_close(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 then return -1 end
	uart_paths[fd] = nil
	return 0
end

-- flush 语义对齐 HAL TCIFLUSH：只清输入环（丢弃设备已发未读字节），留痕
function virtbus.v_uart_flush(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 or uart_paths[fd] == nil then return -1 end
	local path = uart_paths[fd]
	uart_rings[path] = nil
	txlog[#txlog + 1] = { dir = "uf", path = path }
	return 0
end

-- 入参校验同 HAL（非表/空/超 512/逐字节非法 → -1 且不发事务）；通过后
-- TX 面向控制器恒成功（无挂载也返回字节数，只是无人应答——真机语义）。
function virtbus.v_uart_write(fd, data)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return -1 end
	if #data > bus.UART_IO_MAX_BYTES then return -1 end
	if uart_paths[fd] == nil then return -1 end
	local tx = {}
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		tx[i] = b
	end
	local path = uart_paths[fd]
	local entry = { dir = "uw", path = path, bytes = tx, ok = false }
	txlog[#txlog + 1] = entry
	local dev = uart_devs[path]
	if dev == nil then
		entry.ok = true
		return #tx
	end
	local resp = dev.on_write(tx)
	if resp == false then return -1 end
	if type(resp) == "table" then ring_push(path, resp) end
	entry.ok = true
	return #tx
end

-- 校验同 HAL（fd 无效 / n uint_of 非法或 <1 → nil；timeout 超上限 → nil；
-- n>512 钳 512）。
-- 环 drain 至多 n 字节即时返回：环空 = 空表（对齐"超时无数据"），
-- uart_fail_read = 链路硬错误 → nil（事务记 err=true）。
-- 超时上限取自总线契约单点 bus.UART_READ_MAX_MS（N-25）
function virtbus.v_uart_read(fd, n, timeout_ms)
	fd = tonumber(fd)
	n = uint_of(n)
	-- 非有限超时（NaN/±inf，含 "nan"/"1e400" 等字符串形态）必须显式失败返回 nil：
	-- 旧写法 `tonumber(timeout_ms) or 0` 会让 NaN 穿过 `timeout > UART_READ_MAX_MS`
	-- （NaN 与任何数比较均为 false）被当成"不等待"放行，而真机 HAL 显式返回 nil
	-- ——「仿真绿真机红」。改走总线契约单点 finite_of（virtbus 惯例不打印，只返 nil）。
	local timeout
	if timeout_ms ~= nil then
		timeout = finite_of(timeout_ms)
		if timeout == nil then return nil end
	else
		timeout = 0
	end
	if fd == nil or n == nil or n < 1 then return nil end
	if timeout > bus.UART_READ_MAX_MS then return nil end
	local path = uart_paths[fd]
	if path == nil then return nil end
	if n > bus.UART_IO_MAX_BYTES then n = bus.UART_IO_MAX_BYTES end
	if virtbus.uart_fail_read then
		txlog[#txlog + 1] = { dir = "ur", path = path, n = n, bytes = {}, err = true }
		return nil
	end
	local out = {}
	local r = uart_rings[path]
	if r ~= nil then
		while #out < n and r.pos <= #r.data do
			out[#out + 1] = r.data[r.pos]
			r.pos = r.pos + 1
		end
		if r.pos > #r.data then
			uart_rings[path] = nil
		end
	end
	txlog[#txlog + 1] = { dir = "ur", path = path, n = n, bytes = out }
	return out
end

-- 替换全局 i2c_*/spi_*/uart_* 函数为虚拟实现（幂等：已注入则跳过）
local VFUNCS = {
	i2c_open = virtbus.v_i2c_open,
	i2c_close = virtbus.v_i2c_close,
	i2c_set_addr = virtbus.v_i2c_set_addr,
	i2c_write_reg = virtbus.v_i2c_write_reg,
	i2c_write_multi = virtbus.v_i2c_write_multi,
	i2c_write_reg16 = virtbus.v_i2c_write_reg16,
	i2c_read_reg = virtbus.v_i2c_read_reg,
	i2c_read = virtbus.v_i2c_read,
	i2c_read_multi = virtbus.v_i2c_read_multi,
	i2c_read_multi_bytes = virtbus.v_i2c_read_multi_bytes,
	i2c_read_reg16 = virtbus.v_i2c_read_reg16,
	i2c_read_bytes = virtbus.v_i2c_read_bytes,
	spi_open = virtbus.v_spi_open,
	spi_close = virtbus.v_spi_close,
	spi_setup = virtbus.v_spi_setup,
	spi_write = virtbus.v_spi_write,
	spi_read = virtbus.v_spi_read,
	spi_write3 = virtbus.v_spi_write3,
	spi_write_multi = virtbus.v_spi_write_multi,
	spi_read_multi = virtbus.v_spi_read_multi,
	spi_xfer_full = virtbus.v_spi_xfer_full,
	uart_open = virtbus.v_uart_open,
	uart_close = virtbus.v_uart_close,
	uart_flush = virtbus.v_uart_flush,
	uart_write = virtbus.v_uart_write,
	uart_read = virtbus.v_uart_read,
}
local REPLACED = {}
for name in pairs(VFUNCS) do REPLACED[#REPLACED + 1] = name end

function virtbus.inject()
	if virtbus._injected then return end
	for _, name in ipairs(REPLACED) do
		originals[name] = _G[name]
		_G[name] = VFUNCS[name]
	end
	virtbus._injected = true
end

-- 采纳「在别的 lua_State 里创建的虚拟 fd」：真实 fd 是进程级整数，跨状态机可用；
-- 而本模块的 open_paths/fd_addr/uart_paths 是逐状态机的表。多状态机拓扑里总线变量
-- （modules/I2C.lua、modules/UART.lua）在自己的状态里 open 拿到 fd，设备变量在自己的
-- 状态里对同一个 fd 读写信道——不先登记的话 v_i2c_set_addr / v_uart_* 会因
-- open_paths[fd] / uart_paths[fd] 为空而失败。
-- bus 决定登记到哪张 fd 表：缺省/"i2c" → open_paths + fd_addr；"spi" → spi_paths；
-- "uart" → uart_paths（UART 器件身份是 tty 路径，无地址）。器件模型由各状态机
-- 自己 attach（模型是状态局内的内存，本就不跨状态共享）。
-- C7（2026-09-20 审计）：旧实现把**除 uart 外的一切**都当 I2C 登记，于是
-- adopt_fd(fd, path, addr, "spi") 只写 open_paths/fd_addr、spi_paths[fd] 永远为空
-- ——该 fd 上的每一次 spi_* 调用都在 `spi_paths[fd] == nil` 处返回 -1
-- （"device absent"），而 txlog 里已记下一条成功的 "adopt"，故障现象与成因完全脱节。
function virtbus.adopt_fd(fd, path, addr, bus)
	fd = tonumber(fd)
	if fd == nil then return false end
	next_fd = math.max(next_fd, fd + 1)		-- 别让后续分配撞上采纳来的编号
	if bus == "uart" then
		if uart_paths[fd] == nil then
			uart_paths[fd] = tostring(path or "virt-adopted")
		end
		log_tx("adopt", nil, { raw = tostring(path) })
		return true
	end
	if bus == "spi" then
		if spi_paths[fd] == nil then
			spi_paths[fd] = tostring(path or "virt-adopted")
		end
		log_tx("adopt", nil, { raw = tostring(path) })
		return true
	end
	if open_paths[fd] == nil then
		open_paths[fd] = tostring(path or "virt-adopted")
	end
	addr = tonumber(addr)
	if addr ~= nil then fd_addr[fd] = addr end
	log_tx("adopt", addr, { raw = tostring(path) })
	return true
end

-- fd 泄漏检测（审计覆盖缺口 #4）：三类总线已登记虚拟 fd 的只读合计快照。
-- 真实 HAL 与虚拟 HAL 共享同一套驱动 open/close 调用模式——驱动若在
-- build/call 循环里 open 而不 close，此处计数即随轮次增长，可被
-- test_virtbus_fdleak.lua 在 destroy 后断言归零/回落基线。
function virtbus.fd_count()
	local n = 0
	for _ in pairs(open_paths) do n = n + 1 end
	for _ in pairs(spi_paths) do n = n + 1 end
	for _ in pairs(uart_paths) do n = n + 1 end
	return n
end

function virtbus.restore()
	if not virtbus._injected then return end
	for _, name in ipairs(REPLACED) do
		_G[name] = originals[name]
	end
	originals = {}
	virtbus._injected = false
end

-- 加载真实驱动文件并确保虚拟总线处于注入态。
-- 驱动顶部首次 dofile HAL.lua 会用真实 ffi 函数定义全局 i2c_*/spi_*/uart_*，
-- 把先前的虚拟注入覆盖掉；故加载后强制重注入。先加载再注入时，originals 捕获的是
-- 真实 HAL 函数，restore()/reset() 能真正还原 HAL（而不是把全局置空）。
-- 约定：一个 Lua 状态机内只走一次「加载驱动 + 注入」流程——多驱动并存请先
-- dofile 全部驱动再统一注入（run_all.sh 每个用例本就是独立 luajit 进程）。
function virtbus.load_driver(path)
	dofile(path)
	virtbus._injected = false
	virtbus.inject()
	return virtbus
end

__BOT4CJ_VIRTBUS = virtbus		-- 供文件头的重入口守卫取用
return virtbus
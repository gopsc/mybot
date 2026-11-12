-- bus_contract.lua - 总线契约单点（modules/lib/，HAL 与 virtbus 共用）
--
-- N-25：HAL.lua（真机路径）与 virtbus.lua（虚拟总线）此前**逐字手工镜像**
-- 同一组契约：参数归一化、三条总线的设备路径白名单、UART 波特率白名单、
-- 读数/写数长度上限、合并读的 2^53 精度上限。镜像一旦漂移，后果是静默的：
-- 虚拟总线接受（或拒绝）真机行为相反的调用，表现为「仿真绿真机红」且无报错。
-- 故收敛到此单点，两库共同 dofile。
--
-- 本文件为纯 Lua（不依赖 ffi / HAL / 沙箱外的库），可在任意状态机与任意顺序
-- 被加载；可被 lua5.4 独立调试。
--
-- 约定：函数只做「判定/归一化」，不做打印（打印口径属各库自己的错误文案）。

-- 重入口守卫：同一状态机内复用同一张表（纯常量，重复执行无副作用，
-- 但保证身份一致便于测试断言）
if __BOT4CJ_BUS_CONTRACT ~= nil then return __BOT4CJ_BUS_CONTRACT end

local M = {}
M._VERSION = "0.1.0"

------------------------------------------------------------------
-- 参数归一化
------------------------------------------------------------------

-- tonumber + **非有限值拒绝**（NaN / ±inf）单点。
-- 为什么必须显式判 n ~= n：LuaJIT 下 math.floor(NaN) 是 NaN，而 NaN 与任何
-- 数比较都为 false —— 只写 `n < 0 or n > 255` 这类区间判定时，NaN 会**穿过**
-- 检查被当作合法值返回（2026-09-20 审计 C2 实测）。后续一路走到
-- ffi.new("uint8_t", NaN) 就是静默的 0x00：寄存器写错值、舵机写 ON=0/OFF=0
-- 却返回 result="OK"。字符串 "nan"/"inf"/"1e400" 经 tonumber 同样得到
-- NaN/inf，故必须在 tonumber 之后、任何区间判定之前拦。
-- 接受合法的 0：调用方常写 `or def`，0 不能被 falsy 语义吞掉（本函数返回
-- number 或 nil，判空一律用 `== nil`）。
function M.finite_of(v)
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
	return n
end

-- 归一化为 0~255 的整数，非法（非数字/非有限/越界）返回 nil
function M.byte_of(v)
	local n = M.finite_of(v)
	if n == nil then return nil end
	n = math.floor(n)
	if n < 0 or n > 255 then return nil end
	return n
end

-- 归一化为非负整数，非法（非数字/非有限/负数）返回 nil
function M.uint_of(v)
	local n = M.finite_of(v)
	if n == nil then return nil end
	n = math.floor(n)
	if n < 0 then return nil end
	return n
end

-- 归一化为 [lo, hi] 闭区间内的**整数**：非数字/非有限/非整数/越界一律返回 nil。
-- 与 byte_of/uint_of 的分工：那两者对小数**静默 floor**（I2C 字节/合并读长度等
-- 既有语义，接受集与该行为保持逐字不变）；本函数对小数**显式拒绝**——SPI 的
-- mode/bits/speed 与字节参数走此口径，理由与 HAL 的 GPIO offset 先例一致：
-- 小数会被静默截断成另一个值（mode=1.9→1、val=300.7→44），配置笔误必须拒绝
-- 而非将错就错。hi 为 nil 时只判下界（如 speed 仅要求 >= 1）。
-- 下沉单点的意义同本文件头注：HAL 真机路径与 virtbus 仿真路径对**同一组入参**
-- 必须给出相同结论，判据散在两库手工镜像必然漂移（此前 spi_setup/spi_write*
-- 的反向漂移即实证）。返回 number 或 nil；0 是合法值，判空一律用 `== nil`。
-- 注意与 drv_common 的 `int_or(v, def, lo, hi)` 分工：那份是**钳制**语义
-- （越界吸附到边界、非法归缺省），本函数是**拒绝**语义（返 nil）。
-- 两者曾同名 int_of，在同一 Lua 状态里按 3 参调用会把 def 静默绑到 lo，
-- 故钳制那份已改名（见 docs/drivers.md 的越界语义三选一）。
function M.int_of(v, lo, hi)
	local n = M.finite_of(v)
	if n == nil then return nil end
	if n ~= math.floor(n) then return nil end
	if n < lo then return nil end
	if hi ~= nil and n > hi then return nil end
	return n
end

------------------------------------------------------------------
-- 设备路径白名单（Lua pattern）
------------------------------------------------------------------
M.PATH_I2C = "^/dev/i2c%-%d+$"				-- /dev/i2c-<N>
M.PATH_SPI = "^/dev/spidev%d+%.%d+$"			-- /dev/spidev<bus>.<cs>
M.PATH_UART_TTY = "^/dev/tty[A-Za-z0-9]+$"		-- /dev/ttyUSB0、/dev/ttyAMA0…
M.PATH_UART_SERIAL = "^/dev/serial%d+$"			-- /dev/serial0（树莓派软链惯例）

function M.i2c_path_ok(path)
	return type(path) == "string" and string.match(path, M.PATH_I2C) ~= nil
end

function M.spi_path_ok(path)
	return type(path) == "string" and string.match(path, M.PATH_SPI) ~= nil
end

function M.uart_path_ok(path)
	if type(path) ~= "string" then return false end
	return string.match(path, M.PATH_UART_TTY) ~= nil
		or string.match(path, M.PATH_UART_SERIAL) ~= nil
end

------------------------------------------------------------------
-- UART 波特率白名单（含 500k/1M）
------------------------------------------------------------------
M.UART_BAUDS = { 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 500000, 921600, 1000000 }

-- baud ∈ 白名单（入参先 tonumber，与 HAL 旧行为一致）
function M.baud_ok(baud)
	baud = tonumber(baud)
	for _, b in ipairs(M.UART_BAUDS) do
		if b == baud then return true end
	end
	return false
end

------------------------------------------------------------------
-- 长度上限
------------------------------------------------------------------

-- 合并读的长度上限：HAL 把 n 字节按大端拼成一个 double，7 字节起超 2^53
-- 精度（静默截断成错误的合并值），故三总线（I2C/SPI 寄存器族）一律限 1~6
M.MERGED_READ_MAX = 6

-- 字节表读（i2c_read_bytes / i2c_read_multi_bytes）的 n 上限：钳到 1~16
-- （返回的是字节表、长度对调用方可见，故为钳制而非拒绝）
M.BYTES_READ_MAX = 16

-- uart_write 单笔上限 / uart_read 单次上限（超出：写拒绝、读钳制）
M.UART_IO_MAX_BYTES = 512

-- spi_write / spi_read 单笔上限（spidev 逐字节缓冲区，超过即拒绝）
M.SPI_IO_MAX_BYTES = 64

-- i2c_write_multi / i2c_write_reg16 单笔**数据**字节上限（不含寄存器指针，
-- 2026-09-20 审计收口）：此前写函数对变参长度无约束，超长调用会被打包成
-- 超大 buf 发往内核后静默得到 EINVAL / 数据截断。越界即拒绝，而非静默截断。
-- 取值不能照搬 SPI_IO_MAX_BYTES：64 是 spidev 逐字节缓冲区的物理约束，
-- 而 I2C 侧的线上约束是 cj_i2c_msg.len（u16）。本值须覆盖现存最大合法单事务
-- ——VL53L4CD 默认配置流一次写 91 数据字节（+2 字节指针，见 modules/VL53L4CD.lua
-- 的 CONFIG_TABLE）——同时仍能拦住「配置笔误导致数百/数千字节写」。
-- 改动此值前先跑 test_driver_contract.lua 的单笔写字节数 sweep。
M.I2C_IO_MAX_BYTES = 256

-- uart_read 超时上限（ms）：iters = timeout_ms + 1 按 1ms 空转，配置笔误
-- （如少写一个单位）必须立即失败而非阻塞数小时
M.UART_READ_MAX_MS = 60000

__BOT4CJ_BUS_CONTRACT = M
return M

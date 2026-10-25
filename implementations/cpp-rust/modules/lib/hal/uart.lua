-- hal/uart.lua —— HAL 的 UART 域（termios raw 8N1）
-- bot4cj 仓颉语言机器人框架
--
-- 本文件是 modules/lib/HAL.lua 的**分块**，不是可独立加载的模块：由门面按序
-- loadfile 后以 ctx 表传入共享上下文（见门面「各总线域加载」段）。
-- 正文自 HAL.lua 逐字搬迁（26.2 按域拆分），注释与错误文案未改写。
local ctx = assert(..., "hal/uart.lua 须由 modules/lib/HAL.lua 聚合加载（不支持单独 dofile）")
local HAL, ffi, bus, _c = ctx.HAL, ctx.ffi, ctx.bus, ctx._c
local byte_of, uint_of, bus_quiesced = ctx.byte_of, ctx.uint_of, ctx.bus_quiesced

------------------------------------------------------------------
-- UART（termios raw 8N1：/dev/tty*、/dev/serial*；非阻塞轮询读）
-- 生命周期：open 时快照原始 termios（HAL.uart_orig[fd]），close 时先
-- tcsetattr 恢复再关闭——板载 UART 的 termios 跨 close 保留在 tty 上，
-- 残留 raw 模式/波特率会影响后续使用者（getty、其他程序）。
------------------------------------------------------------------
-- 常量经 test/test_uart_consts.c 与系统头文件实证（gpio 段同款方法）：
-- sizeof(struct termios)=60、c_line 偏移 16、c_cc 偏移 17、VMIN=6/VTIME=5、
-- O_RDWR=2 O_NOCTTY=256 O_NONBLOCK=2048、TCSANOW=0、TCIFLUSH=0、
-- CREAD=128 CLOCAL=2048 CS8=48。
-- 【波特率必须传当版 glibc 的 B* 常量编码，不能想当然】编码随 glibc 版本
-- 分叉（glibc 2025-06 commit 5cf101a8，2.42 起生效）：
--   < 2.42：B* 是旧 ABI 编号（B9600=13、B115200=0x1002）——cfsetispeed/
--           cfsetospeed 对字面 Hz（9600/115200/…）返回 EINVAL 且不修改
--           结构体，旧实现「传 Hz」看似成功实际波特率从未生效（真机
--           /dev/serial0 实证：请求 115200 后 B 字段仍为原值）；
--   ≥ 2.42：B* 即字面 Hz（B9600=9600）——反向地，旧编号 13 会被当成
--           「13 波特」静默生效。
-- 因此 UART_B_CONST 按运行时 glibc 版本（gnu_get_libc_version）二选一；
-- test_uart_consts.c 以 #if 分支与两套表同步断言（审计 P0-3）。
-- 2026-09-30 方案 A 重构：ffi.cdef、尺寸自检、UART/errno 常量全部下沉到后端。

-- UART 常量由后端 consts 表重导出
HAL.UART_O_FLAGS  = _c.UART_O_FLAGS
HAL.UART_TCSANOW  = _c.UART_TCSANOW
HAL.UART_TCIFLUSH = _c.UART_TCIFLUSH
HAL.UART_VMIN_IDX = _c.UART_VMIN_IDX
HAL.UART_VTIME_IDX = _c.UART_VTIME_IDX
HAL.UART_CREAD_CLOCAL = _c.UART_CREAD_CLOCAL
HAL.EAGAIN = _c.EAGAIN
HAL.EINTR  = _c.EINTR
HAL.ENOENT = _c.ENOENT
HAL.EACCES = _c.EACCES
HAL.EINVAL = _c.EINVAL
HAL.UART_READ_MAX_MS = bus.UART_READ_MAX_MS	-- uart_read 轮询上限：iters=timeout_ms+1 按 1ms 空转，
								-- 超长值（配置笔误）必须立即失败而非阻塞数小时

HAL.uart_baud = {}				-- fd -> 波特率（调试/生命周期摘要）
HAL.uart_orig = {}				-- fd -> open 前的原始 termios（close 恢复用）

-- UART 波特率白名单与长度上限均取自总线契约单点（bus_contract.lua，N-25）

-- Hz → speed_t 常量：旧 ABI 编码表（glibc < 2.42，test_uart_consts.c 旧分支断言）。
-- 白名单与映射表必须同步维护：白名单通过而映射缺失时 uart_open 明确失败，
-- 不会退回「静默不生效」的旧行为。
local UART_B_CONST_LEGACY = {
	[1200] = 9, [2400] = 11, [4800] = 12, [9600] = 13, [19200] = 14, [38400] = 15,
	[57600] = 0x1001, [115200] = 0x1002, [230400] = 0x1003, [460800] = 0x1004,
	[500000] = 0x1005, [921600] = 0x1007, [1000000] = 0x1008,
}
-- Hz → speed_t 常量：字面 Hz 编码表（glibc ≥ 2.42，test_uart_consts.c 新分支断言）
local UART_B_CONST_HZ = {
	[1200] = 1200, [2400] = 2400, [4800] = 4800, [9600] = 9600, [19200] = 19200,
	[38400] = 38400, [57600] = 57600, [115200] = 115200, [230400] = 230400,
	[460800] = 460800, [500000] = 500000, [921600] = 921600, [1000000] = 1000000,
}
-- 运行时探测：glibc ≥ 2.42 用 Hz 表，否则旧 ABI 编号表（见段首注释）。
-- 探测失败（非常规 libc 等）按旧编码处理：旧编码在 <2.42 上正确，在 ≥2.42
-- 上会静默设错——故本探测与 test_uart_baud.lua 回归、test_uart_consts.c
-- 构建期断言三重把关，编码分叉时尽可能早地暴露。
-- 阶段 A-1：版本探测经 HAL.sys.version()（后端接口；非 glibc 后端返 nil
-- 时按旧编码处理，musl 等平台行为与 glibc<2.42 一致）。
local function glibc_uses_hz_baud()
	local ok, ver = pcall(function()
		local v = HAL.sys.version()
		local major, minor = string.match(v ~= nil and v or "", "(%d+)%.(%d+)")
		if major == nil then return 0 end
		return tonumber(major) * 1000 + tonumber(minor)
	end)
	return ok == true and ver >= 2042	-- 2042 == glibc 2.42
end
local UART_B_CONST = glibc_uses_hz_baud() and UART_B_CONST_HZ or UART_B_CONST_LEGACY
HAL.UART_B_CONST = UART_B_CONST		-- 导出供 test_uart_baud.lua 回归核对

-- 打开串口（raw 8N1 + 波特率 + 非阻塞），成功返回 fd，失败返回 -1
function uart_open(path, baud)
	if type(path) ~= "string" then return -1 end
	baud = tonumber(baud)
	if not bus.baud_ok(baud) then
		print("HAL: invalid uart baud: " .. tostring(baud))
		return -1
	end
	local bconst = UART_B_CONST[baud]
	if bconst == nil then
		print("HAL: uart baud has no termios constant: " .. tostring(baud))
		return -1
	end
	-- 路径白名单：常规 tty 命名 + /dev/serialN（树莓派软链惯例）
	if not bus.uart_path_ok(path) then
		print("HAL: invalid uart path: " .. tostring(path))
		return -1
	end
	local fd = tonumber(HAL.sys.open(path, HAL.UART_O_FLAGS))
	if fd == nil or fd < 0 then
		print("HAL: failed to open uart: " .. path)
		return -1
	end
	local t = ffi.new("cj_termios[1]")	-- ffi.new 零初始化
	if HAL.sys.tcgetattr(fd, t) ~= 0 then
		print("HAL: tcgetattr failed: " .. path .. " (is this a serial device?)")
		HAL.sys.close(fd)
		return -1
	end
	-- 快照 open 前的原始 termios（整 60 字节按值拷贝；t 随后被 cfmakeraw
	-- 就地改写）。仅在内核侧配置成功后登记（见函数尾），失败路径不产生
	-- 残留快照。
	local orig = ffi.new("cj_termios[1]")
	ffi.copy(orig, t, ffi.sizeof("cj_termios"))
	HAL.sys.cfmakeraw(t)				-- raw 模式（无回显/无行缓冲/8N1 基础）
	-- CREAD|CLOCAL 用真位或置位（cfmakeraw 不清这两位，加法会进位污染高位；
	-- HAL 仅支持 LuaJIT，内建 bit 库可用）
	local bitlib = require("bit")
	t[0].c_cflag = bitlib.bor(tonumber(t[0].c_cflag) or 0, HAL.UART_CREAD_CLOCAL)
	t[0].c_cc[HAL.UART_VMIN_IDX] = 0	-- 非阻塞读：VMIN=0
	t[0].c_cc[HAL.UART_VTIME_IDX] = 1	-- 100ms 字间计时器（驱动层另有轮询超时）
	-- 传 glibc 常量而非 Hz（见段首注释）；返回码必查：EINVAL 时结构体未被
	-- 修改，放行等于「以为设了波特率其实没设」
	if HAL.sys.cfsetispeed(t, bconst) ~= 0 or HAL.sys.cfsetospeed(t, bconst) ~= 0 then
		print("HAL: failed to set uart speed: " .. path .. " @" .. tostring(baud) .. " baud")
		HAL.sys.close(fd)
		return -1
	end
	if HAL.sys.tcsetattr(fd, HAL.UART_TCSANOW, t) ~= 0 then
		print("HAL: tcsetattr failed: " .. path)
		HAL.sys.close(fd)
		return -1
	end
	HAL.uart_orig[fd] = orig
	HAL.uart_baud[fd] = baud
	return fd
end

-- 关闭串口：先恢复 open 前快照的 termios（销毁重置），再关闭 fd。
-- 恢复失败（设备已拔出等）告警但不阻断关闭，返回值仍是 close 的结果。
-- 注：多个变量共用同一物理串口时各自独立快照/恢复（每变量独立 lua_State），
-- 后关闭者以自己 open 时看到的配置为准，不做跨变量引用计数。
function uart_close(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 then return -1 end
	HAL.uart_baud[fd] = nil
	local orig = HAL.uart_orig[fd]
	if orig ~= nil then
		HAL.uart_orig[fd] = nil
		if HAL.sys.tcsetattr(fd, HAL.UART_TCSANOW, orig) ~= 0 then
			print("HAL: failed to restore uart termios on close (fd " .. tostring(fd) .. ")")
		end
	end
	return HAL.sys.close(fd)
end

-- 清空输入缓冲（丢弃未读字节，请求-应答协议发帧前用）
function uart_flush(fd)
	fd = tonumber(fd)
	if fd == nil or fd < 0 then return -1 end
	return HAL.sys.tcflush(fd, HAL.UART_TCIFLUSH)
end

-- 写一帧字节（data 为 1 基字节值表），返回写入字节数或 -1
function uart_write(fd, data)
	fd = tonumber(fd)
	if fd == nil or type(data) ~= "table" or #data == 0 then return -1 end
	if #data > bus.UART_IO_MAX_BYTES then return -1 end
	if bus_quiesced() then return -1 end
	local buf = ffi.new("uint8_t[?]", #data)
	for i = 1, #data do
		local b = byte_of(data[i])
		if b == nil then return -1 end
		buf[i - 1] = b
	end
	local r = tonumber(HAL.sys.write(fd, buf, #data))
	if r == nil or r < 0 then return -1 end
	return r
end

-- 读最多 n 字节（非阻塞轮询，1ms 步进直至 timeout_ms），返回 1 基字节表
-- （可能为空表 = 超时无数据）；fd 读取错误（EAGAIN/EINTR 之外的 errno）
-- 立即返回 nil——原实现把一切 read 失败当"无数据"空转到超时，错误被吞。
-- timeout_ms 超 UART_READ_MAX_MS 显式失败返回 nil（诊断打印）：iters 与参数
-- 线性增长，超长值会按 1ms 空转阻塞调用线程数小时，配置笔误必须立即暴露
function uart_read(fd, n, timeout_ms)
	fd = tonumber(fd)
	n = uint_of(n)
	-- C2（2026-09-20 审计）：非有限超时不得被静默当成"不等待"。旧写法
	-- `tonumber(timeout_ms) or 0` 让 NaN 穿过上限判定，随后 math.floor(NaN)=NaN
	-- 使 `for it = 1, NaN` 一次都不执行 —— 调用方看到的是"立即超时无数据"，
	-- 与配置里写坏一个字面量的真实成因完全脱节。
	if timeout_ms ~= nil then
		timeout_ms = bus.finite_of(timeout_ms)
		if timeout_ms == nil then
			print("HAL: uart_read timeout is not a finite number: "
				.. tostring(timeout_ms))
			return nil
		end
	else
		timeout_ms = 0
	end
	if fd == nil or n == nil or n < 1 then return nil end
	if bus_quiesced() then return nil end
	if timeout_ms > HAL.UART_READ_MAX_MS then
		print("HAL: uart_read timeout " .. tostring(timeout_ms) .. "ms exceeds max "
			.. tostring(HAL.UART_READ_MAX_MS) .. "ms")
		return nil
	end
	if n > bus.UART_IO_MAX_BYTES then n = bus.UART_IO_MAX_BYTES end
	local buf = ffi.new("uint8_t[?]", n)
	local out = {}
	local iters = math.max(0, math.floor(timeout_ms)) + 1
	local eof_streak = 0
	for it = 1, iters do
		local want = n - #out
		local r = tonumber(HAL.sys.read(fd, buf, want))
		if r ~= nil and r > 0 then
			eof_streak = 0
			for i = 0, r - 1 do out[#out + 1] = tonumber(buf[i]) end
			if #out >= n then break end
		elseif r == 0 then
			-- 审计 #10：read()==0 是 EOF（USB 串口拔出/对端关闭），不是
			-- "暂无数据"——旧实现当作空转满超时，拔线后错误被吞。连续
			-- 3 次 EOF 即判定设备已消失，立即失败。
			eof_streak = eof_streak + 1
			if eof_streak >= 3 then
				print("HAL: uart_read hit EOF (device gone?) fd=" .. tostring(fd))
				return nil
			end
		elseif r == nil or r < 0 then
			-- EAGAIN=暂无数据、EINTR=被信号打断：继续轮询；其余错误显式失败
			local e = HAL.sys.errno()
			if e ~= HAL.EAGAIN and e ~= HAL.EINTR then return nil end
		end
		if it < iters then HAL.sys.usleep(1000) end
	end
	return out
end

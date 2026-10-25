-- UART 硬件（串口总线矩阵）

--
-- 标准前导：HAL/print_table（部分驱动含 drv_common）经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 文件句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局）
-- 哨兵值必须是 -1 而非 0：HAL 约定 open 成功返回 fd >= 0（见 lib/hal/i2c.lua 的 i2c_open 注释），
-- 而 stdin 被关闭时（systemd StandardInput=null、--input 配合 0<&-）open 真实返回 0。
-- 用 0 当「未打开」哨兵会让 build 成功（build 里按 uart_open 返回 < 0 判失败）
-- 而 call/destroy 拒绝同一个合法句柄。
local fd = -1

-- 全局波特率（build 从元数据设置；call 随 fd 返回给引用本变量的设备驱动）
local baud = 9600

-- build 时缓存的总线路径（C-L6：call 返回 build 时保存的 path——原实现取
-- call 参数里的 path，调用方元数据与 build 不一致时 virt 模式会按错误路径
-- attach 模型）
local open_path = nil

-- fd 回滚（C-M3'）：build 中途抛 Lua error 时由 guard_build 调用（幂等）
local function rollback_fd()
	if fd ~= nil and fd >= 0 then
		uart_close(fd)
		fd = -1
	end
	open_path = nil
end

local function build_impl(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- UART.lua builder func get a table --------", data)

	local path = data.path
	if path == nil then
		return err("Invalid Arguments: path")
	end

	local uart_baud = finite_of(data.baud)
	if uart_baud == nil or uart_baud <= 0 then
		return err("Invalid Arguments: baud (positive number)")
	end

	-- 重复 build 先关旧句柄再开新（与 I2C/GPIO/SPI 的守卫一致；
	-- 否则旧 fd 泄漏且残留在 HAL.uart_baud 表中）
	if fd ~= nil and fd >= 0 then
		uart_close(fd)
		fd = -1
	end

	-- 打开串口（raw 8N1 + 非阻塞；波特率白名单在 HAL 内校验；
	-- open 前的 termios 由 HAL 快照，关闭时自动恢复）
	local opened = uart_open(path, uart_baud)
	if opened == nil or opened < 0 then
		return err("Failed to open UART file")
	end

	fd = opened
	baud = uart_baud
	open_path = path

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print("UART opened: " .. path .. " @ " .. tostring(baud) .. " baud, fd=" .. tostring(fd))
	end
	return {  result = "OK"  }

end

-- build 全程守卫：异常折成 ERR 契约并回滚已打开的 fd（drv_common.guard_build）
function build(data)
	return guard_build(rollback_fd, build_impl, data)
end

-- 【销毁UART】关闭串口句柄
-- uart_close 先恢复 build 时快照的原始 termios 再 close：板载 UART 的
-- raw 模式/波特率跨 close 保留在 tty 上，恢复后不残留给后续使用者
-- M3（2026-09-23 安全审计）+ D2-1 调和（2026-09-24）：fd 是文件级 upvalue、与
-- 入参无关且无第二次释放机会（HAL 无 ffi.gc 终结器），**释放先行**——任何早退
-- （含 arg_table 拒绝）都不得跳过 uart_close，否则泄漏 fd（M3 修的就是这个）。
-- arg_table 守卫保留在释放之后：非表入参返 ERR 契约（D2-1 契约 sweep 与
-- lint-driver-entry 都要求样板在位；M3 一度整体摘掉，属矫枉过正）。
function destroy(data)

	dbg_table("-------- UART.lua ender func get a table --------", data)

	if fd ~= nil and fd >= 0 then
		uart_close(fd)
		fd = -1
	end

	local ok, e = arg_table(data)
	if not ok then
		return e	-- 非表：ERR（fd 已尽力释放，泄漏无从谈起）
	end

	return {  result = "OK"  }

end


-- 【调用UART】把句柄与波特率交给引用本变量的设备驱动
-- NOTE: 接收一个参数（表），返回一个结果（表）
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- UART.lua caller func get a table --------", data)

	if fd == nil or fd < 0 then
		return err("UART not opened (build first)")
	end

	-- 返回字典（fd 经引用机制流入设备驱动元数据）。
	-- path 用 build 时缓存的值（C-L6）：virt 模式下设备驱动按 tty 路径定位
	-- 器件模型（drv_common proto=virt 前置的 attach_uart/adopt 需要），
	-- 以 build 时的真实打开路径为准，不信任 call 元数据。
 	return {
		result = "OK",
		fd     = fd,
		baud   = baud,
		path   = open_path or data.path
	}

end

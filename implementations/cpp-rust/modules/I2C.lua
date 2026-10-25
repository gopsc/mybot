-- I2C 硬件
--
-- 26.5 单测覆盖：无单元/端到端测试；仅出现在 robots/qs_rpi.sql + spider{1,2,3}.sql
-- （真机配置，非测试夹具）。HAL 层 i2c_open/read/write/close 由 test_uart.lua
-- 间接覆盖（termios 同族），但 I2C 驱动层 build/call/destroy 逻辑无守门。
--
-- 标准前导：HAL/print_table（部分驱动含 drv_common）经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- 文件句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局；
-- 每个硬件变量独立 lua_State，故天然隔离）
local fd = -1

-- fd 回滚（C-M3'）：build 中途抛 Lua error 时由 guard_build 调用——裸调用
-- 会跳过句柄回收，宿主 lua_close 后 fd 永久泄漏（HAL 无 ffi.gc 终结器）。
-- 幂等：重复 build 的「先关旧 fd」守卫已关过时是 no-op。
local function rollback_fd()
	if fd ~= nil and fd >= 0 then
		i2c_close(fd)
		fd = -1
	end
end

local function build_impl(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end
	dbg_table("-------- I2C.Lua builder func get a table --------", data)

	local path = data.path
	if path == nil then	-- 检查文件句柄参数是否存在
		return err("No I2C path")
	end


	-- 重复 build 先关旧 fd 再开新（防御：不依赖调用方保证 build 恰一次）
	if fd ~= nil and fd >= 0 then
		i2c_close(fd)
		fd = -1
	end

	-- 开始执行（i2c_open 成功返回 fd >= 0、失败返回 -1；fd 0 是合法句柄——
	-- stdin 被关闭时内核就返回 0，用 > 0 判定会把可用总线当成打开失败）
	fd = i2c_open(path)
	if fd < 0 then
		return err("Failed to open I2C file")
	end


	-- 返回结果
	return {
		result = "OK",
		fd = fd
	}

end

-- build 全程守卫：异常折成 ERR 契约并回滚已打开的 fd（drv_common.guard_build）
function build(data)
	return guard_build(rollback_fd, build_impl, data)
end




function destroy(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	i2c_close(fd)
	fd = -1

	return {  result = "OK"  }

end





function call(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	-- build 未成功不下发无效 fd（与 UART.lua 的校验对齐；fd 0 合法，故判 < 0）
	if fd == nil or fd < 0 then
		return err("I2C not opened (build first)")
	end

	return {  result = "OK",  fd = fd  }

end

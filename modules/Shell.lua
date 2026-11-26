-- Shell 宿主命令驱动（通用软件资源，非总线）
--
-- 输入一条命令字符串，经平台 shell（POSIX /bin/sh -c，Windows cmd.exe /c）
-- 执行，返回 out / err / code / truncated。非零退出码是正常完成（code 携带
-- 退出码），仅启动失败 / 超时 / 取消返回 ERR。
--
-- 安全口径：命令以宿主用户权限与环境在当前目录执行，**不是沙箱**——整个
-- 能力由宿主 runtime 门统一要求 --allow-hardware（与物理设备、非回环 HTTP
-- 同门），只在已审阅可信的结构脚本中声明。
--
-- SQL：
--   CREATE TABLE Shell (name String, timeout Number);
--   INSERT INTO Shell (name, timeout) VALUES ('sh', 10000);
-- MT（数据格文本必须 $("...")）：
--   sh.cmd;
--   $("echo hello");
--   @

--
-- 标准前导：HAL/print_table/drv_common 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))
local bus = dofile(mpath.resolve("lib/bus_contract.lua"))

-- 会话句柄（H-06：local upvalue 共享于本文件 build/call/destroy，不污染全局）
local fd = -1

-- build 时缓存的默认超时（ms）；call 可用 timeout 参数逐次覆盖
local timeout_ms = 10000

-- fd 回滚（C-M3'）：build 中途抛 Lua error 时由 guard_build 调用（幂等）
local function rollback_fd()
	if fd ~= nil and fd >= 0 then
		shell_close(fd)
		fd = -1
	end
end

local function build_impl(data)

	-- 检查该参数是否是一张表
	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Shell.lua builder func get a table --------", data)

	local tmo = finite_of(data.timeout)
	if tmo == nil then tmo = 10000 end
	if tmo < 1 or tmo > bus.SHELL_TIMEOUT_MAX_MS then
		return err("Invalid Arguments: timeout (1.." .. tostring(bus.SHELL_TIMEOUT_MAX_MS) .. " ms)")
	end

	-- 重复 build 先关旧会话再开新（与 I2C/UART/SPI/HTTP 的守卫一致）
	if fd ~= nil and fd >= 0 then
		shell_close(fd)
		fd = -1
	end

	local opened = shell_open(tmo)
	if opened == nil or opened < 0 then
		return err("Failed to open shell session")
	end

	fd = opened
	timeout_ms = tmo

	return {  result = "OK"  }

end

-- build 全程守卫：异常折成 ERR 契约并回滚已打开的会话（drv_common.guard_build）
function build(data)
	return guard_build(rollback_fd, build_impl, data)
end

-- 【销毁shell会话】句柄只是登记的默认配置（进程随每次 shell_run 结束已击杀），
-- close 即注销。释放先行（沿 HTTP.py 的 M3 顺序）：任何早退（含 arg_table
-- 拒绝）都不得跳过 shell_close，否则句柄滞留 HAL 表中。
function destroy(data)

	dbg_table("-------- Shell.lua ender func get a table --------", data)

	if fd ~= nil and fd >= 0 then
		shell_close(fd)
		fd = -1
	end

	local ok, e = arg_table(data)
	if not ok then
		return e	-- 非表：ERR（会话已尽力释放）
	end

	return {  result = "OK"  }

end

-- 【执行命令】cmd 为命令文本（必需）；timeout 可逐次覆盖 build 缺省（ms）。
-- 返回 shell_run 的 {result, code, out, err, truncated} 原样。
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dbg_table("-------- Shell.lua caller func get a table --------", data)

	if fd == nil or fd < 0 then
		return err("Shell session not opened (build first)")
	end

	local cmd = data.cmd
	if type(cmd) ~= "string" or cmd == "" or cmd == "-" then
		return err("Invalid Arguments: cmd (command text)")
	end
	if #cmd > bus.SHELL_MAX_CMD_BYTES then
		return err("Invalid Arguments: cmd (over " .. tostring(bus.SHELL_MAX_CMD_BYTES) .. " bytes)")
	end

	local tmo = finite_of(data.timeout)
	if tmo == nil then tmo = timeout_ms end
	if tmo < 1 or tmo > bus.SHELL_TIMEOUT_MAX_MS then
		return err("Invalid Arguments: timeout (1.." .. tostring(bus.SHELL_TIMEOUT_MAX_MS) .. " ms)")
	end

	return shell_run(fd, cmd, tmo)

end

-- LifetimeProbe.lua —— test/cpp/test_robot.cpp 的「析构兜底断电」探针驱动
--
-- 用途：让 destroy 在文件系统上留下可观测痕迹，C++ 侧据此断言
--   ① 调用方漏掉 deactivate 时，~RobotStruct 会补一次断电（标记出现）；
--   ② 已显式 deactivate 后再析构不会重复 destroy（标记恰好 1 字节）。
--
-- 每次 destroy 往 data.path 追加一个字节 'D'（O_APPEND，不截断），
-- 于是「destroy 次数」= 文件中 'D' 的个数，幂等性可直接断言；
-- 与 LifetimeTick.lua 追加的 'T'（守护每拍）同文件时，末字节还给出
-- 「守护退场」与「硬件去初始化」的先后顺序（断电屏障的判据）。
-- 标记路径经结构脚本的 path 列传入，不用环境变量：并行用例之间不互扰。
--
-- 写文件走 HAL 的 ffi open/write/close —— 驱动沙箱禁了 io.open（见 luasandbox），
-- 这正是真机驱动（如 SGP30 的基线存盘）的同款路径，顺带覆盖 HAL.O_CLOEXEC。

local ffi = require("ffi")
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
-- HAL.lua 是 `return HAL`（表不挂全局），要持有表的驱动必须接返回值——
-- SGP30.lua:46 / Camera.lua:18 同款写法。
local HAL = dofile(mpath.resolve("lib/HAL.lua"))

-- O_WRONLY(1) + O_CREAT(0x40) + O_APPEND(0x400) + O_CLOEXEC(HAL 单点)，权限 0644
local O_WRONLY_CREAT_APPEND = 1 + 0x40 + 0x400
local FILE_MODE = 0x1A4

local function append_marker(path)
	if type(path) ~= "string" or #path == 0 then return "path 缺失或非字符串" end
	local fd = HAL.sys.open(path, O_WRONLY_CREAT_APPEND + HAL.O_CLOEXEC, FILE_MODE)
	if fd == nil or tonumber(fd) < 0 then
		-- 注意 errno 成功时不清零，这里的值可能来自更早的失败调用
		return "open 失败 errno=" .. tostring(HAL.sys.errno()) .. " path=" .. path
	end
	local buf = ffi.new("char[1]", "D")
	local n = HAL.sys.write(fd, buf, 1)
	HAL.sys.close(fd)
	if n ~= 1 then return "write 短写 n=" .. tostring(n) end
	return nil
end

function build(data)
	return { result = "OK" }
end

function destroy(data)
	-- 不吞失败：标记没落下时必须让 C++ 侧看见原因，否则「末字节」判据
	-- 会在夹具自身故障时静默变成假绿/假红。
	local why = append_marker(data and data.path)
	if why then return { result = "ERR", message = "LifetimeProbe: " .. why } end
	return { result = "OK" }
end

function call(data)
	return { result = "OK" }
end

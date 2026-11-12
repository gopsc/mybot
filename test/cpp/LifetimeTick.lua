-- LifetimeTick.lua —— 断电屏障回归用的守护 chunk（test/cpp/test_robot.cpp）
--
-- 每拍往 BOT4CJ_LIFETIME_MARK 指定的文件追加一个 'T'；LifetimeProbe.lua 的
-- destroy 往同一文件追加 'D'。于是「末字节是谁写的」直接等价于顺序判据：
--   屏障在位 → 守护先退场、之后才 destroy 硬件 → 末字节 'D'
--   屏障缺失 → destroy 之后守护还在拍（join 延后到它自己的 destroy）→ 末字节 'T'
--
-- 写文件走 ffi 直调 libc：守护 chunk 与驱动同样跑在沙箱里，io.open 已被中和
-- （见 src/luasandbox.cpp），这也是真机驱动写文件的唯一通路。
-- 句柄是短命的（open→write→close 在同一拍内闭合），故不带 O_CLOEXEC 也无继承面。
--
-- 注意：本 chunk **刻意**在拍内 ffi usleep，违反 docs/daemon.md 对生产 chunk 的
-- 建议（拍间该用线程 sleep 让出）。测试要的正是「有一拍在途、且 stop 打不断它」
-- 这个形状——与 test/cpp/test_daemon.cpp 的慢拍夹具（usleep 3s）同理。

local ffi = require("ffi")
ffi.cdef[[
int open(const char *pathname, int flags, ...);
int write(int fd, const void *buf, unsigned long count);
int close(int fd);
int usleep(unsigned int usec);
]]

-- O_WRONLY(1) + O_CREAT(0x40) + O_APPEND(0x400)，权限 0644
local O_WRONLY_CREAT_APPEND = 1 + 0x40 + 0x400
local FILE_MODE = 0x1A4
local TICK_SLEEP_US = 150000	-- 每拍先睡 150ms

local function mark()
	local path = os.getenv("BOT4CJ_LIFETIME_MARK")
	if type(path) ~= "string" or #path == 0 then return end
	-- mode 必须显式 cast：open 的第三参是**变参**，裸 Lua 数字会按错误宽度
	-- 传给内核（实测建出 0000 权限的文件，之后所有写打开都是 EACCES）。
	-- hal_backend_glibc.lua 的 ioctl_i 注释警告的是同一类 ABI 陷阱。
	local fd = ffi.C.open(path, O_WRONLY_CREAT_APPEND, ffi.cast("unsigned int", FILE_MODE))
	if fd < 0 then return end
	local buf = ffi.new("char[1]", "T")
	ffi.C.write(fd, buf, 1)
	ffi.C.close(fd)
end

function daemon_tick()
	-- 标记刻意放在睡眠**之后**：requestStop 只能在两拍之间被看见
	-- （daemonvar.cpp 的 runTickLoop 循环条件），所以「先睡后写」保证
	-- 停机请求到来时总有一拍在途、且它的 'T' 会落在硬件 destroy 之后
	-- ——没有断电屏障时末字节必然是 'T'，判据才有判别力。
	ffi.C.usleep(TICK_SLEEP_US)
	mark()
	return 1
end

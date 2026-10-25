-- unix_socket_ffi.lua —— AF_UNIX socket 公共 FFI 声明与连接工具
--
-- 【为什么抽出来】Sim.lua 和 Camera.lua 都需要连 AF_UNIX socket 到仿真器，
-- 各自声明了一遍几乎相同的 FFI 结构（sockaddr_un、socket/connect/send/recv）。
-- 用前缀隔离（cj_ vs cam_）避免同名 struct 在同一个 lua_State 里重复 cdef 报错，
-- 但代码本身是重复的。提取到这里统一维护，新驱动不用再抄一遍。
--
-- 【前缀选择】usock_（unix socket 缩写），与已有的 cj_（Sim）和 cam_（Camera）
-- 不冲突。LuaJIT 对同名 struct 的重复 cdef 是硬错误，函数同签名重复则允许。
--
-- 【职责边界】只负责 FFI 声明 + 基础连接原语。协议语义（仿真器的命令格式、
-- 拍照的请求-响应流程）仍由各驱动自己处理，不在此层抽象。
local ffi = require("ffi")

-- 一次性 cdef：模块可能被多个驱动 require，但 ffi.cdef 对同签名函数允许重复，
-- 对 struct 则不允许。用 pcall 包住，第二次及以后的 cdef 失败时静默忽略
-- （结构已经声明过了，正是我们想要的状态）。
local cdef_done = false

local function ensure_cdef()
	if cdef_done then return end
	
	local ok, err = pcall(function()
		ffi.cdef[[
/* AF_UNIX 地址结构：sun_path 定长 108 字节（Linux 限制） */
typedef unsigned short usock_sa_family_t;
struct usock_sockaddr_un { usock_sa_family_t sun_family; char sun_path[108]; };

/* 基础 socket API：libc 标准调用，签名与内核 ABI 一致 */
int socket(int domain, int type, int protocol);
int connect(int fd, const struct usock_sockaddr_un *addr, unsigned int addrlen);
long send(int fd, const void *buf, unsigned long len, int flags);
long recv(int fd, void *buf, unsigned long len, int flags);
int close(int fd);
		]]
	-- errno 刻意**不在这里 cdef**：glibc 的 errno 是数据符号（宏 (*__errno_location())），
	-- 声明成 `int errno(void)` 再调 ffi.C.errno() 会把一个 int 当函数指针跳过去执行，
	-- 稳定 SIGSEGV——而且只在 socket 失败分支触发（仿真器没起来时打死整个宿主进程）。
	-- 用 LuaJIT 内建的 ffi.errno()，与 modules/lib/hal_backend_glibc.lua 同口径。
	end)
	
	if not ok then
		-- 失败原因：多半是 struct 已被其他模块用不同前缀声明过。
		-- 这种情况在实际运行中不应该发生（各驱动用不同前缀），但开发期
		-- 热重载 lua_State 时可能碰到。打印警告但不中断，让后续调用去发现。
		print("unix_socket_ffi: cdef 失败（可能已声明过）: " .. tostring(err))
	end
	
	cdef_done = true
end

ensure_cdef()

------------------------------------------------------------------
-- 常量
------------------------------------------------------------------
local AF_UNIX = 1
local SOCK_STREAM = 1
local POLLIN = 0x001

-- MSG_NOSIGNAL：对端没了时把 SIGPIPE 折成 EPIPE 返回值，别打死整个 mybot 进程。
-- Linux 特有（0x4000），BSD/macOS 没有这个标志（它们用 SO_NOSIGPIPE socket 选项）。
local MSG_NOSIGNAL = 0x4000

-- sun_path 定长 108 字节，留一位给 NUL 结尾；超长会被内核静默截断成另一个路径，
-- 显式拒绝比连错地方好定位。
local MAX_PATH_LEN = 107

------------------------------------------------------------------
-- 连接工具
------------------------------------------------------------------
-- 连到 AF_UNIX socket；成功返 fd，失败返 nil + 原因。
-- 路径长度校验 + socket/connect，失败时自动 close fd（不泄漏）。
local function connect(path)
	if type(path) ~= "string" or path == "" then
		return nil, "socket 路径为空"
	end
	if #path > MAX_PATH_LEN then
		return nil, "socket 路径超长（>" .. MAX_PATH_LEN .. " 字节）：" .. path
	end
	
	local s = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	if s < 0 then
		return nil, "socket() 失败 (errno=" .. tostring(ffi.errno()) .. ")"
	end
	
	local addr = ffi.new("struct usock_sockaddr_un")
	addr.sun_family = AF_UNIX
	ffi.copy(addr.sun_path, path)	-- 字符串形态的 ffi.copy 带上结尾 NUL
	-- addrlen = family(2) + 路径字节 + NUL；按实际长度传，别传满 110
	local addrlen = 2 + #path + 1
	
	if ffi.C.connect(s, addr, addrlen) ~= 0 then
		local e = ffi.errno()
		ffi.C.close(s)
		return nil, "connect 失败 (errno=" .. tostring(e) .. "，路径 " .. path .. ")"
	end
	
	return s
end

-- 带超时的 poll 等待：返回 true 表示就绪，false 表示超时，nil+原因 表示出错。
-- EINTR（被信号打断）自动重试，不视为错误。
-- 注意：pollfd 结构由各驱动自己声明（Sim.lua 用 cj_pollfd，Camera.lua 用 cam_pollfd），
-- 这里只调用 ffi.C.poll，签名由驱动侧的 cdef 决定。
local function poll_ready(fd, timeout_ms, pollfd_ptr)
	local fds = pollfd_ptr
	fds[0].fd = fd
	fds[0].events = POLLIN
	
	while true do
		local pr = ffi.C.poll(fds, 1, timeout_ms)
		if pr < 0 then
			local e = ffi.errno()
			if e == 4 then	-- EINTR：被信号打断，重试
				-- 继续循环
			else
				return nil, "poll 失败 (errno=" .. tostring(e) .. ")"
			end
		elseif pr == 0 then
			return false	-- 超时
		else
			return true		-- 就绪
		end
	end
end

-- 发送全部字节：send 可能部分发送（尤其大缓冲），循环直到发完或出错。
-- 成功返回 true，失败返回 nil + 原因。对端断开时返回 nil + "broken pipe"。
local function send_all(fd, data)
	local sent = 0
	local total = #data
	while sent < total do
		local n = ffi.C.send(fd, data:sub(sent + 1), total - sent, MSG_NOSIGNAL)
		if n < 0 then
			local e = ffi.errno()
			if e == 32 then	-- EPIPE：对端已关闭
				return nil, "broken pipe"
			end
			return nil, "send 失败 (errno=" .. tostring(e) .. ")"
		end
		sent = sent + n
	end
	return true
end

------------------------------------------------------------------
-- 导出
------------------------------------------------------------------
return {
	-- 常量
	AF_UNIX = AF_UNIX,
	SOCK_STREAM = SOCK_STREAM,
	POLLIN = POLLIN,
	MSG_NOSIGNAL = MSG_NOSIGNAL,
	MAX_PATH_LEN = MAX_PATH_LEN,
	
	-- 连接
	connect = connect,
	
	-- I/O（send_all 是通用的；recv 逻辑因 poll 结构差异由各驱动自己实现）
	send_all = send_all,
}
